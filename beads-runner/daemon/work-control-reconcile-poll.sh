# shellcheck shell=bash
# beads-runner/daemon/work-control-reconcile-poll.sh — L2 (claude-tools-uxvl2)
# WORK→CONTROL auto-close reconciler — inbox-lifecycle §7 (Option 2).
#
# WHAT THIS IS (inbox-lifecycle §7 Stage 5 — Closure)
#   The daemon-side observer that drops a STALE dossier off the Inbox when its
#   underlying bead resolves OUTSIDE the dossier tap. The Inbox should contain
#   ONLY things that genuinely need Brian's attention (§7.1); today a blocking
#   decision dossier persists forever asking a dead question if the bead is
#   closed directly (`bd close`), self-unblocks (the worker satisfied the fork
#   another way), or is manually re-scoped — none of which flow back to the
#   dossier. This reconciler closes that gap.
#
#   On a cadence it asks the engine for the dossiers still on the Inbox
#   (`work-snapshot` → `waiting_on_you`, the TIMER-LESS tiers — blocking AND
#   digest; see daemon_wc__select_open_beads), checks each one's
#   bead status in its workspace's bd, and for every bead that has resolved
#   outside the flow it PUBLISHES a `bead_status_changed` event onto the daemon
#   outbox — the SAME zdxd D2 channel the machine_state telemetry rides
#   (USAGE_POLL_OUTBOX → daemon_outbox_drain_once → la_outbox_drain → co_request
#   → the engine `bead-status-changed` op, cf/src/dossier.js). The engine then
#   expires (open→expired) / applies-preserving (answered→applied) the stale
#   items and the card LEAVES the Inbox.
#
# WHAT THIS IS *NOT*
#   • NOT S-2 reconcile. S-2 (stuck.js / lib/stuck-routing.sh) is the ONE-WAY
#     CONTROL→WORK path (the stuck backstop re-asserts blocked+human on the
#     bead). This is the deliberately-separate INVERSE: WORK→CONTROL. It does
#     NOT reuse S-2's machinery (inbox-lifecycle §7.9: "the new flow is a NEW
#     reconciler").
#   • NOT a timed-fyi closer. A `timed-fyi` dossier (the Flow F
#     `overview-<bead_ref>` fired ON bead close) rides its own §2.2 24h
#     auto-proceed timer; this reconciler EXCLUDES it. It DOES consider `digest`
#     dossiers, though: a §5.6-DEFERRED decision card is lowered blocking→digest
#     WITHOUT arming any timer (claude-tools-o2mk), so — unlike timed-fyi — it has
#     no timer to ride and would otherwise strand on the Inbox forever when its
#     bead resolves outside the tap. digest can NEVER carry an armed timer
#     (timer.js tfArm soft-disarms every non-timed-fyi tier), so selecting it is
#     safe. The engine op (cf/src/dossier.js beadStatusChanged) re-checks per
#     dossier as defense-in-depth, skipping ONLY a still-armed auto-proceeder
#     (timer_fire_at != null).
#   • NOT a bd writer. It only READS bd status/labels; the bead lifecycle is the
#     workspace runner's / Brian's business.
#
# IDEMPOTENT (inbox-lifecycle §7.6.4)
#   Per-(bead_ref, status) marker files at
#   `$DAEMON_CACHE_DIR/work-control-published/<safe_key>.<status>.json` record a
#   published event so the SAME (bead_ref, status) tuple is never emitted twice
#   — no outbox spam in the window between emit and the engine processing it.
#   Belt-and-suspenders: the engine op is itself idempotent (monotonic state
#   machine), and once items expire the bead drops off `waiting_on_you` so it is
#   not reconsidered.
#
# ENGINE TRANSPORT — like daemon_outbox_drain_once: the daemon outbox is
#   machine-wide and `work-snapshot` is principal-keyed (NOT per-project), so
#   workspace[0]'s coordinator binding (COORDINATOR_URL + Keychain token)
#   addresses the same hosted engine for the read. The PUBLISH is just an
#   outbox append; the existing drain ships it.

DAEMON_REPO_DIR="${DAEMON_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}"
DAEMON_REPO_LIB_DIR="${DAEMON_REPO_LIB_DIR:-$DAEMON_REPO_DIR/lib}"

# DAEMON_CACHE_DIR is set by daemon.sh before sourcing; default for direct tests.
DAEMON_CACHE_DIR="${DAEMON_CACHE_DIR:-$HOME/.cache/claude-tools}"
DAEMON_WC_PUBLISHED_DIR="${DAEMON_WC_PUBLISHED_DIR:-$DAEMON_CACHE_DIR/work-control-published}"

# The daemon outbox — the SAME durable §1.1 queue usage-poll.sh emits onto and
# daemon_outbox_drain_once ships. Default matches usage-poll.sh's USAGE_POLL_OUTBOX.
USAGE_POLL_OUTBOX="${USAGE_POLL_OUTBOX:-$DAEMON_CACHE_DIR/coordinator-outbox.jsonl}"

# The §9.1 principal the engine stamps on writes (engine overwrites the wire
# value, but we carry it for parity with the other §1.1 reports).
DAEMON_WC_PRINCIPAL="${DAEMON_WC_PRINCIPAL:-${PRINCIPAL_V1:-brian}}"

# Test/canary hooks (mirror flow-f-overview-poll.sh's posture):
#   DAEMON_WC_DISABLED=1            — run the decision logic + markers but DO NOT
#                                     emit outbox lines (CI-safe no-token canary).
#   DAEMON_WC_SNAPSHOT_OVERRIDE     — executable that echoes, one per line,
#                                     "<bead_ref>" for each OWNED (blocking|digest)
#                                     dossier still on the Inbox — the post-tier-
#                                     filter list (replaces the work-snapshot read
#                                     AND daemon_wc__select_open_beads).
#   DAEMON_WC_BD_OVERRIDE           — executable called "<override> <bead_ref>"
#                                     that echoes "<status>\t<labels_csv>"
#                                     (replaces the per-workspace bd read).
DAEMON_WC_DISABLED="${DAEMON_WC_DISABLED:-0}"
DAEMON_WC_SNAPSHOT_OVERRIDE="${DAEMON_WC_SNAPSHOT_OVERRIDE:-}"
DAEMON_WC_BD_OVERRIDE="${DAEMON_WC_BD_OVERRIDE:-}"

# daemon_wc__safe_key <bead_ref> — sanitize for a filename component (mirrors
# daemon_flow_f__safe_key: no '/' or '..', conservative allowed-set).
daemon_wc__safe_key() {
  local in="${1:-}" out
  out="${in//\//_}"
  out="${out//../_}"
  printf '%s' "$out" | tr -c 'A-Za-z0-9._-' '_'
}

# daemon_wc_marker_for <bead_ref> <status> — echo the per-tuple marker path.
daemon_wc_marker_for() {
  local bref="${1:-}" status="${2:-}" key
  [[ -n "$bref" ]] || return 0
  key="$(daemon_wc__safe_key "$bref")"
  printf '%s/%s.%s.json' "$DAEMON_WC_PUBLISHED_DIR" "$key" "$(daemon_wc__safe_key "$status")"
}

# daemon_wc_already_published <bead_ref> <status> — true (0) iff a marker exists.
daemon_wc_already_published() {
  local mf
  mf="$(daemon_wc_marker_for "$1" "$2")"
  [[ -n "$mf" && -f "$mf" ]]
}

# daemon_wc_write_marker <bead_ref> <status> <outcome> — record a published
# event. ALWAYS returns 0 (a marker-write failure must not abort the loop).
daemon_wc_write_marker() {
  local bref="${1:-}" status="${2:-}" outcome="${3:-}" mf tmp
  mf="$(daemon_wc_marker_for "$bref" "$status")"
  [[ -n "$mf" ]] || return 0
  mkdir -p "$DAEMON_WC_PUBLISHED_DIR" 2>/dev/null || return 0
  tmp="$mf.$$.tmp"
  if jq -cn \
        --arg b   "$bref" \
        --arg s   "$status" \
        --arg o   "$outcome" \
        --arg ts  "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")" \
        '{bead_ref:$b, status:$s, outcome:$o, observed_at:$ts}' \
        > "$tmp" 2>/dev/null && mv -f "$tmp" "$mf" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  declare -F log >/dev/null 2>&1 && \
    log "work-control: WARN — could not write marker for bead_ref=$bref status=$status"
  return 0
}

# daemon_wc__workspace_for <bead_ref> — echo the registered workspace dir whose
# project_ref is the LONGEST prefix of <bead_ref> (bd ids are `<project_ref>-<id>`).
# Empty if no registered workspace owns the bead (a cross-machine bead).
daemon_wc__workspace_for() {
  local bref="${1:-}" n i pref dir best="" bestlen=0
  [[ -n "$bref" ]] || return 0
  declare -p REGISTRY_PROJECT_REFS >/dev/null 2>&1 || return 0
  n="${#REGISTRY_PROJECT_REFS[@]}"
  i=0
  while [[ "$i" -lt "$n" ]]; do
    pref="${REGISTRY_PROJECT_REFS[$i]:-}"
    dir="${REGISTRY_DIRS[$i]:-}"
    if [[ -n "$pref" && "$bref" == "$pref-"* && "${#pref}" -gt "$bestlen" ]]; then
      best="$dir"; bestlen="${#pref}"
    fi
    i=$((i + 1))
  done
  printf '%s' "$best"
}

# daemon_wc__select_open_beads — read a work-snapshot JSON on stdin, echo the
# unique bead_refs of the dossiers this reconciler OWNS, one per line. OWNED =
# the TIMER-LESS tiers: `blocking` (decision card, never arms a timer) AND
# `digest` (a §5.6-DEFERRED card, claude-tools-o2mk — also never armed: timer.js
# tfArm soft-disarms every non-timed-fyi tier). EXCLUDES `timed-fyi` (Flow F
# overview-<ref>) — it rides its own §2.2 24h auto-proceed timer and must NOT be
# force-expired on bead resolution. A pure tier predicate is exact here precisely
# because digest≡no-armed-timer, so it needs NO timer_fire_at projection field
# (Contract B stays frozen). Pure filter — extracted so the tier scoping is unit-
# testable without a live engine.
daemon_wc__select_open_beads() {
  jq -r '
    (.waiting_on_you // [])
    | map(select((.tier // "") == "blocking" or (.tier // "") == "digest"))
    | .[] | (.bead_ref // empty)' 2>/dev/null | awk 'NF' | sort -u
}

# daemon_wc__fetch_open_dossier_beads — echo the unique bead_refs of the OWNED
# dossiers still on the Inbox (waiting_on_you), one per line (see
# daemon_wc__select_open_beads for the tier scoping). Honors
# DAEMON_WC_SNAPSHOT_OVERRIDE for tests. ALWAYS returns 0 (empty on any failure
# — a transient engine outage just means "nothing to reconcile this pass").
daemon_wc__fetch_open_dossier_beads() {
  if [[ -n "$DAEMON_WC_SNAPSHOT_OVERRIDE" && -x "$DAEMON_WC_SNAPSHOT_OVERRIDE" ]]; then
    "$DAEMON_WC_SNAPSHOT_OVERRIDE" 2>/dev/null | awk 'NF' | sort -u
    return 0
  fi
  local curl_url tk_item lib_dir
  curl_url="${REGISTRY_COORDINATOR_URLS[0]:-}"
  tk_item="${REGISTRY_TOKEN_KEYCHAIN_ITEMS[0]:-}"
  [[ -n "$curl_url" ]] || return 0
  lib_dir="${DAEMON_REPO_LIB_DIR:-${DAEMON_REPO_DIR:-}/lib}"
  [[ -f "$lib_dir/co-http-transport.sh" ]] || return 0
  (
    set +e
    export COORDINATOR_URL="$curl_url"
    if [[ -n "$tk_item" ]] && command -v security >/dev/null 2>&1; then
      local _tk
      _tk="$(security find-generic-password -s "$tk_item" -w 2>/dev/null || true)"
      [[ -n "$_tk" ]] && export COORDINATOR_TOKEN="$_tk"
    fi
    # shellcheck source=/dev/null
    . "$lib_dir/co-http-transport.sh" 2>/dev/null || exit 0
    command -v co_request >/dev/null 2>&1 || exit 0
    local snap
    snap="$(co_request "${COORDINATOR_TOKEN:-}" work-snapshot "" 2>/dev/null)" || exit 0
    # OWNED tiers only — blocking + digest (timer-less); timed-fyi rides its own
    # §2.2 timer (Flow F) and is excluded. See daemon_wc__select_open_beads.
    printf '%s' "$snap" | daemon_wc__select_open_beads
    exit 0
  )
}

# daemon_wc__bd_status_labels <bead_ref> — echo "<status>\t<labels_csv>" for the
# bead in its workspace's bd. Honors DAEMON_WC_BD_OVERRIDE for tests.
# Subshell-isolated so a workspace's local .beads env does not leak back.
daemon_wc__bd_status_labels() {
  local bref="${1:-}"
  [[ -n "$bref" ]] || return 0
  if [[ -n "$DAEMON_WC_BD_OVERRIDE" && -x "$DAEMON_WC_BD_OVERRIDE" ]]; then
    "$DAEMON_WC_BD_OVERRIDE" "$bref" 2>/dev/null
    return 0
  fi
  local ws
  ws="$(daemon_wc__workspace_for "$bref")"
  [[ -n "$ws" && -d "$ws" ]] || return 0
  (
    cd "$ws" 2>/dev/null || exit 0
    local j
    j="$(bd show "$bref" --json 2>/dev/null)" || exit 0
    [[ -n "$j" ]] || exit 0
    printf '%s' "$j" | jq -r '
      (if type=="array" then .[0] else . end) as $b
      | (($b.status // "") | tostring) + "\t" + (($b.labels // []) | map(tostring) | join(","))' 2>/dev/null
  )
}

# daemon_wc__resolved_outside_flow <status> <labels_csv> — 0 (yes) iff the bead
# behind an OWNED (blocking|digest) dossier has resolved OUTSIDE the dossier tap:
#   • status == closed                                  → yes (close-without-decision)
#   • status != blocked AND no `human` label            → yes (self-unblocked / re-scoped)
#   • status == blocked WITH `human` label              → NO (still genuinely waiting)
daemon_wc__resolved_outside_flow() {
  local status="${1:-}" labels="${2:-}" human=no
  [[ "$status" == "closed" ]] && return 0
  case ",${labels}," in *",human,"*) human=yes ;; esac
  [[ "$status" != "blocked" && "$human" == "no" ]] && return 0
  return 1
}

# daemon_wc__emit_event <bead_ref> <status> — append ONE bead_status_changed
# §1.1 report line onto the daemon outbox (the zdxd D2 channel). Mirrors
# usage-poll.sh's _machine_state_emit shape/discipline. Returns 0 on append.
daemon_wc__emit_event() {
  local bref="${1:-}" status="${2:-}" ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"
  mkdir -p "$(dirname "$USAGE_POLL_OUTBOX")" 2>/dev/null || true
  jq -cn \
     --argjson sv 1 \
     --arg pr  "$DAEMON_WC_PRINCIPAL" \
     --arg b   "$bref" \
     --arg st  "$status" \
     --arg at  "$ts" \
     '{report:"bead_status_changed",schema_version:$sv,principal:$pr,
       bead_ref:$b,status:$st,observed_at:$at}' \
     >> "$USAGE_POLL_OUTBOX" 2>/dev/null || return 1
  return 0
}

# daemon_wc_reconcile_one <bead_ref> — evaluate ONE open-dossier bead and, if it
# has resolved outside the flow and was not already published, emit the event +
# write the (bead_ref, status) marker. ALWAYS returns 0 (per-bead failures must
# not abort the sweep). Echoes "1" on stdout iff an event was emitted, else "0".
daemon_wc_reconcile_one() {
  local bref="${1:-}" sl status labels
  [[ -n "$bref" ]] || { printf '0'; return 0; }
  sl="$(daemon_wc__bd_status_labels "$bref")"
  # No status resolvable (bead not on this machine / bd unreachable) ⇒ leave it.
  [[ -n "$sl" ]] || { printf '0'; return 0; }
  status="${sl%%$'\t'*}"
  labels="${sl#*$'\t'}"
  [[ "$labels" == "$sl" ]] && labels=""   # no TAB ⇒ no labels field
  [[ -n "$status" ]] || { printf '0'; return 0; }

  if ! daemon_wc__resolved_outside_flow "$status" "$labels"; then
    printf '0'; return 0   # still genuinely waiting on Brian
  fi
  if daemon_wc_already_published "$bref" "$status"; then
    printf '0'; return 0   # idempotent: this (bead_ref,status) already emitted
  fi

  if [[ "$DAEMON_WC_DISABLED" == "1" ]]; then
    declare -F log >/dev/null 2>&1 && \
      log "work-control: DAEMON_WC_DISABLED=1 ⇒ would publish bead_status_changed bead_ref=$bref status=$status (marker written, no outbox emit)"
    daemon_wc_write_marker "$bref" "$status" "canary-disabled"
    printf '1'; return 0
  fi

  if daemon_wc__emit_event "$bref" "$status"; then
    daemon_wc_write_marker "$bref" "$status" "published"
    declare -F log >/dev/null 2>&1 && \
      log "work-control: published bead_status_changed bead_ref=$bref status=$status — engine will expire/apply-preserve the stale Inbox card (inbox-lifecycle §7)"
    printf '1'; return 0
  fi
  # Emit failed ⇒ NO marker, retried next pass.
  declare -F log >/dev/null 2>&1 && \
    log "work-control: WARN — outbox append failed for bead_ref=$bref status=$status (no marker; retried next pass)"
  printf '0'; return 0
}

# daemon_wc_reconcile_once — single iteration: fetch the OWNED (blocking|digest)
# dossiers still on the Inbox, reconcile each. ALWAYS returns 0. Called from
# daemon.sh's main loop on the WORK_CONTROL_POLL_INTERVAL cadence.
daemon_wc_reconcile_once() {
  local bref total=0 c
  while IFS= read -r bref; do
    [[ -n "$bref" ]] || continue
    c="$(daemon_wc_reconcile_one "$bref" 2>/dev/null)"
    [[ "$c" =~ ^[0-9]+$ ]] || c=0
    total=$((total + c))
  done < <(daemon_wc__fetch_open_dossier_beads)
  if [[ "$total" -gt 0 ]]; then
    declare -F log >/dev/null 2>&1 && \
      log "work-control reconcile (inbox-lifecycle §7 / L2): published $total bead_status_changed event(s) — stale Inbox card(s) auto-closing on bead resolution"
  fi
  return 0
}
