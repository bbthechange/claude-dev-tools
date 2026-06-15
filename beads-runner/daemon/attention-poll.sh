#!/bin/bash
# beads-runner/daemon/attention-poll.sh — iz36 (claude-tools-iz36).
#
# THE GAP (incident claude-tools-jzzw, 2026-06-14): runners went process-alive
# but heartbeat-stale for DAYS while desired=running across every workspace, and
# NOTHING alerted Brian. The jzzw fixes closed the two MECHANICAL recurrences
# (daemon self-staleness re-exec; agent_actions TTL/GC) and added a cheap
# queue-backlog WARN. This poll closes the OBSERVABILITY half: it reads the
# engine's NEW top-level `attention` read-model field (the precise, sustained
# "wanted running but wedged" signal derived in workSnapshot()/co__derive_attention)
# and emits an EDGE-TRIGGERED structured WARN to the daemon log — the exact log
# where this incident was diagnosed (`ps … daemon.pid` vs the *-poll.sh mtimes).
#
# TWO HALVES: the WARN below is the OBSERVABILITY half (iz36) — a passive
# daemon-log signal. claude-tools-tv88 bolted the ACTIVE PHONE PUSH onto the SAME
# detection: on the EDGE the poll ALSO shapes a kind=overview / tier=digest §4.1
# dossier and emits a digest §4.3 notification on the shared "machine-attention"
# channel (dg_generate + no_emit + no_dispatch — the _daemon_flow_f_engine_write
# SEQUENCE, digest-flavored, NO tf_arm). The body is DETERMINISTIC (the
# stale-runner remediation is fixed/operational, not bead-specific — so a
# dossier-builder spawn buys nothing here; see the tv88 design note); the §5.1
# write gate (Mermaid + dossier_schema_version — the 4xe scar) still runs at
# dg_generate, so a malformed body is rejected, never shipped. The shared channel
# folds N alerts → ONE daily push (must-protect #5). See _daemon_attention_push.
#
# CANARY-DISABLED by default (DAEMON_ATTENTION_PUSH_DISABLED=1): the producer is
# offline-green but DORMANT in prod until the §2.5 DEVICE live-verify
# (notifications.md first invariant — "done = lands on the phone"), which cannot
# be done autonomously. A follow-up bead flips it to 0 in the plist env after the
# real-device verify (and flipping it live pages any currently-wedged runner via
# the .pushed retry lane). This mirrors the h8e6/7n5c "additive + dormant until
# verified" close and the H5→I5 canary→live split.
#
# THE SIGNAL IS ALREADY SUSTAINED at the engine: an `attention` alert fires only
# when the heartbeat has been silent for HOURS (ATTENTION_STALE_SECONDS, default
# 1h ≫ STALE_AFTER 180s) — the heartbeat AGE *is* the duration, so no cross-poll
# debounce is needed. This poll only avoids LOG spam: it logs once on the EDGE
# (first detection per project+kind), re-logs at most hourly while the alert
# persists (an operator heartbeat without a 60s storm), and logs RESOLVED when it
# clears.
#
# ENGINE REACH: the singleton Coordinator (workspace[0] url + Keychain bearer,
# the notif-delivery-poll/1p0u-drain pattern) — ONE `work-snapshot` call reaches
# the one DO that owns every workspace's runner state. Always returns 0; a
# transport/auth failure is logged and retried next cadence, never aborts the loop.

# Resolved at source-time; daemon.sh sets these before sourcing (defaults let this
# file be unit-tested standalone).
DAEMON_REPO_DIR="${DAEMON_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}"
DAEMON_REPO_LIB_DIR="${DAEMON_REPO_LIB_DIR:-$DAEMON_REPO_DIR/lib}"

# DAEMON_CACHE_DIR is set by daemon.sh before sourcing; default for standalone tests.
DAEMON_CACHE_DIR="${DAEMON_CACHE_DIR:-$HOME/.cache/claude-tools}"
# The edge-trigger marker dir (one file per alerting project+kind), parallel to
# flow-f-overview-fired/. A marker means "we have already WARNed about this alert."
DAEMON_ATTENTION_FIRED_DIR="${DAEMON_ATTENTION_FIRED_DIR:-$DAEMON_CACHE_DIR/attention-fired}"

# Re-log an ongoing alert at most this often (an hourly operator heartbeat, not a
# 60s storm). Env-overridable; 0 disables re-logging (edge + resolve only).
DAEMON_ATTENTION_RELOG_SECONDS="${DAEMON_ATTENTION_RELOG_SECONDS:-3600}"

# Test/canary kill switch (parallel to DAEMON_NOTIF_DELIVERY_DISABLED). Off by default.
DAEMON_ATTENTION_DISABLED="${DAEMON_ATTENTION_DISABLED:-0}"

# Override hook: a test injects a canned work-snapshot JSON instead of hitting the
# engine. When set (non-empty), _attention_fetch_snapshot echoes it verbatim.
DAEMON_ATTENTION_SNAPSHOT_OVERRIDE="${DAEMON_ATTENTION_SNAPSHOT_OVERRIDE:-}"

# ── claude-tools-tv88: the DIGEST-tier PHONE PUSH half ───────────────────────
# The WARN above (iz36) is the OBSERVABILITY half — a passive daemon-log signal.
# This is the ACTIVE PAGE half: on the EDGE (a NEW sustained alert) the poll ALSO
# shapes a kind=overview / tier=digest §4.1 dossier (deterministic body — the
# stale-runner remediation is FIXED/operational, NOT bead-specific; see the bead
# design note for why deterministic over a dossier-builder spawn) and emits a
# digest §4.3 notification on the SHARED "machine-attention" channel via
# dg_generate + no_emit + no_dispatch (the _daemon_flow_f_engine_write SEQUENCE,
# digest-flavored — NO tf_arm; digest has no armed timer). The shared channel is
# what lets no__group_digests fold N alerts → ONE daily push (must-protect #5).
#
# CANARY-DISABLED by default (=1): the producer is offline-green but DORMANT in
# prod until the §2.5 DEVICE live-verify (notifications.md first invariant —
# "done = lands on the PHONE"), which cannot be done autonomously. A follow-up
# bead flips this to 0 in the plist env after the real-device verify. Flipping it
# live also pages any currently-wedged runner (the .pushed retry lane below).
DAEMON_ATTENTION_PUSH_DISABLED="${DAEMON_ATTENTION_PUSH_DISABLED:-1}"

# The ONE opaque digest channel every machine-attention notification carries, so
# K3's read-side rollup (no__group_digests) groups them ALL into a SINGLE channel
# entry ⇒ one daily push, never N (must-protect #5). Env-overridable for tests.
DAEMON_ATTENTION_PUSH_CHANNEL="${DAEMON_ATTENTION_PUSH_CHANNEL:-machine-attention}"

# Test hook (mirrors DAEMON_FLOW_F_ENGINE_OVERRIDE): replaces the engine-write
# subshell. Called as "<override> <gi.json>"; rc 0 + a non-empty stdout id ⇒
# "emitted". Lets a focused test assert the dossier/notification SHAPE without a
# live engine — though the primary test drives the REAL dg_generate against a
# local CO_STORE (no override) to prove the §5.1 write gate actually passes.
DAEMON_ATTENTION_ENGINE_OVERRIDE="${DAEMON_ATTENTION_ENGINE_OVERRIDE:-}"

_attention_log() {
  if declare -F log >/dev/null 2>&1; then
    log "[attention] $*"
  else
    printf '%s [attention] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$*" >&2
  fi
}

# A filesystem-safe key for a project+kind pair (the marker filename).
_attention_safe_key() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

# _attention_fetch_snapshot — echo the engine's work-snapshot JSON (all projects,
# no inline beads), or the test override. Empty string on any failure (the caller
# treats an empty/unparseable snapshot as "no alerts" — observe-first, never act
# on uncertainty).
_attention_fetch_snapshot() {
  if [[ -n "$DAEMON_ATTENTION_SNAPSHOT_OVERRIDE" ]]; then
    printf '%s' "$DAEMON_ATTENTION_SNAPSHOT_OVERRIDE"
    return 0
  fi
  local ws_count=0
  if declare -p REGISTRY_PROJECT_REFS >/dev/null 2>&1; then
    ws_count="${#REGISTRY_PROJECT_REFS[@]}"
  fi
  [[ "$ws_count" -eq 0 ]] && return 0
  local curl_url="${REGISTRY_COORDINATOR_URLS[0]:-}"
  local tk_item="${REGISTRY_TOKEN_KEYCHAIN_ITEMS[0]:-}"
  [[ -n "$curl_url" ]] || return 0
  local lib_dir="${DAEMON_REPO_LIB_DIR:-${DAEMON_REPO_DIR:-}/lib}"
  [[ -f "$lib_dir/co-http-transport.sh" ]] || return 0
  (
    set +e
    export COORDINATOR_URL="$curl_url"
    if [[ -n "$tk_item" ]] && command -v security >/dev/null 2>&1; then
      _tk="$(security find-generic-password -s "$tk_item" -w 2>/dev/null || true)"
      [[ -n "$_tk" ]] && export COORDINATOR_TOKEN="$_tk"
    fi
    # shellcheck source=/dev/null
    . "$lib_dir/co-http-transport.sh" 2>/dev/null || exit 0
    command -v co_request >/dev/null 2>&1 || exit 0
    co_request "${COORDINATOR_TOKEN:-}" work-snapshot "" "" 2>/dev/null
  )
  return 0
}

# _daemon_attention_build_gi <dossier_id> <project_ref> <kind> <detail> <age>
#   Shape the DETERMINISTIC §4.1 generation_input for a digest machine-attention
#   FYI. kind=overview / trigger=proactive_checkpoint / tier=digest /
#   timer_fire_at=null / items=[] (pure FYI). The body is hand-shaped (NOT a
#   dossier-builder spawn): the stale-runner remediation is fixed/operational, so
#   the TL;DR is the alert detail and the deep body is the jzzw-incident runbook.
#   authored_by="daemon" renders clean (the Inbox only badges authored_by=="fallback"
#   as degraded) AND the §xdo pre-author hint suppresses a misleading
#   no_DG_AUTHOR_CMD incident. Echoes the gi JSON; empty on failure.
_daemon_attention_build_gi() {
  local did="${1:-}" ref="${2:-}" kind="${3:-}" detail="${4:-}" age="${5:-}"
  [[ -n "$did" ]] || return 0
  [[ -n "$detail" ]] || detail="A runner the machine wants running has gone quiet."
  [[ -n "$age" ]] || age="unknown"
  local tldr full sections wedged checks
  tldr="machine attention: ${ref} (${kind}) — ${detail}"
  wedged="${detail} Workspace=${ref}, kind=${kind}, heartbeat_age_seconds=${age}, desired=running. Autonomous work on this runner has silently stalled — the process can be alive while its heartbeat is stale for hours."
  checks="Per the jzzw incident runbook (daemon.md): (1) Is the per-machine daemon alive AND running current code — compare the daemon-pid start time against the daemon *-poll.sh mtimes; if the process predates the code, launchctl kickstart -k of the LaunchAgent self-heals it (drains the agent_actions queue, rewrites local desired, respawns the runners). (2) Inspect the workspace runner log under .beads/runner-logs/. (3) Confirm desired=running is still intended — a Stop tap that never reconciled looks identical from here. This is a DIGEST FYI: it folds with any other wedged runner into ONE daily push; open the Board for the live machine-attention banner."
  full="${wedged}"$'\n\n'"${checks}"
  sections="$(jq -cn --arg w "$wedged" --arg c "$checks" \
    '[{heading:"What is wedged", prose:$w},{heading:"What to check", prose:$c}]' 2>/dev/null)" || return 0
  jq -cn \
    --arg id   "$did" \
    --arg bref "machine-attention:${ref}:${kind}" \
    --arg tldr "$tldr" \
    --arg full "$full" \
    --argjson sections "$sections" '
    { id: $id,
      kind: "overview",
      trigger: "proactive_checkpoint",
      bead_ref: $bref,
      tier: "digest",
      timer_fire_at: null,
      source: {
        tldr:        $tldr,
        sections:    $sections,
        diagrams:    [],
        full_detail: $full,
        authored_by:        "daemon",
        authored_by_reason: "machine_attention_alert"
      },
      items: [] }
  ' 2>/dev/null
}

# _daemon_attention_engine_write <project_ref> <gi_json>
#   The digest emit sequence — the _daemon_flow_f_engine_write SHAPE but
#   digest-flavored: dg_generate (persist the §4.1/§5 dossier) → no_emit (the §4.3
#   notification, mirrors the dossier's digest tier) → no_dispatch with the shared
#   "machine-attention" channel (so K3's rollup batches it). NO tf_arm — digest has
#   no armed timer (the §5.6/work-control "digest≡no-armed-timer" invariant).
#   Singleton engine reach (workspace[0] url+bearer, the snapshot-fetch pattern);
#   PROJECT_REF = the ALERTING workspace so the card is attributed correctly. The
#   DAEMON_ATTENTION_ENGINE_OVERRIDE hook short-circuits this for tests. Echoes the
#   dossier id on success; empty/nonzero on any failure (caller logs, never aborts).
_daemon_attention_engine_write() {
  local pref="${1:-}" gi="${2:-}"
  if [[ -n "$DAEMON_ATTENTION_ENGINE_OVERRIDE" && -x "$DAEMON_ATTENTION_ENGINE_OVERRIDE" ]]; then
    local tmp; tmp="$(mktemp 2>/dev/null)" || return 1
    printf '%s' "$gi" > "$tmp" 2>/dev/null
    "$DAEMON_ATTENTION_ENGINE_OVERRIDE" "$tmp"; local rc=$?
    rm -f "$tmp" 2>/dev/null
    return "$rc"
  fi
  local curl_url="${REGISTRY_COORDINATOR_URLS[0]:-}"
  local tk_item="${REGISTRY_TOKEN_KEYCHAIN_ITEMS[0]:-}"
  local lib_dir="${DAEMON_REPO_LIB_DIR:-${DAEMON_REPO_DIR:-}/lib}"
  [[ -f "$lib_dir/stuck-routing.sh" ]] || return 1
  (
    set +e
    export PROJECT_REF="$pref"
    : "${CO_STORE:=$DAEMON_CACHE_DIR/attention-co-store}"
    export CO_STORE
    if [[ -n "$curl_url" ]]; then export COORDINATOR_URL="$curl_url"; fi
    if [[ -n "$tk_item" ]] && command -v security >/dev/null 2>&1; then
      local _tk
      _tk="$(security find-generic-password -s "$tk_item" -w 2>/dev/null || true)"
      [[ -n "$_tk" ]] && export COORDINATOR_TOKEN="$_tk"
    fi
    # Source order mirrors _daemon_flow_f_engine_write: stuck-routing pulls
    # dossier-gen → dossier → coordinator; notification owns §4.3; co-http-transport
    # overrides co_request when COORDINATOR_URL is set (else the local oracle). NO
    # timed-fyi source — a digest card arms no §2.2 timer.
    # shellcheck source=/dev/null
    . "$lib_dir/stuck-routing.sh"     2>/dev/null || exit 1
    # shellcheck source=/dev/null
    . "$lib_dir/notification.sh"      2>/dev/null || exit 1
    # shellcheck source=/dev/null
    . "$lib_dir/co-http-transport.sh" 2>/dev/null || true
    command -v dg_generate >/dev/null 2>&1 || exit 1
    command -v no_emit     >/dev/null 2>&1 || exit 1
    command -v no_dispatch >/dev/null 2>&1 || exit 1
    local bearer did nid
    bearer="${COORDINATOR_TOKEN:-bearer-daemon-attention}"
    # dg_generate runs the §5.1 write gate (Mermaid + dossier_schema_version — the
    # 4xe scar); a malformed deterministic body is REJECTED here, never shipped.
    did="$(dg_generate "$bearer" "$gi" 2>/dev/null)" || exit 2
    [[ -n "$did" ]] || exit 2
    nid="$(no_emit "$bearer" "$did" 2>/dev/null)" || exit 3
    [[ -n "$nid" ]] || exit 3
    # Route into the shared digest channel ⇒ K3 folds N alerts → 1 push.
    no_dispatch "$bearer" "$nid" "$DAEMON_ATTENTION_PUSH_CHANNEL" >/dev/null 2>&1 || exit 4
    printf '%s' "$did"
    exit 0
  )
}

# _daemon_attention_push <project_ref> <kind> <detail> <age> <marker>
#   Fire (or RETRY) the digest push for one sustained alert, once. Gated by the
#   canary; idempotent across polls via the <marker>.pushed sentinel:
#     • disabled ⇒ no-op (and .pushed is NOT written, so flipping the canary live
#       later pages this still-wedged runner on the next poll — the retry lane).
#     • already pushed (<marker>.pushed exists) ⇒ no-op (one push per sustained
#       alert — the per-(project,kind) marker IS the dedup, must-protect #5).
#     • engine write fails ⇒ WARN, leave .pushed ABSENT so the ONGOING branch
#       retries next cadence (the blueprint-update fyi-pending discipline).
#   ALWAYS returns 0.
_daemon_attention_push() {
  local ref="${1:-}" kind="${2:-}" detail="${3:-}" age="${4:-}" marker="${5:-}"
  [[ "$DAEMON_ATTENTION_PUSH_DISABLED" = "1" ]] && return 0
  [[ -n "$marker" && -f "$marker.pushed" ]] && return 0
  local safe did gi written
  safe="$(_attention_safe_key "${ref}::${kind}")"
  did="attention-$safe"
  gi="$(_daemon_attention_build_gi "$did" "$ref" "$kind" "$detail" "$age")"
  if [[ -z "$gi" ]]; then
    _attention_log "PUSH WARN — could not assemble digest gi workspace=$ref kind=$kind (no push; retried next cadence)"
    return 0
  fi
  written="$(_daemon_attention_engine_write "$ref" "$gi" 2>/dev/null)"
  if [[ -n "$written" ]]; then
    [[ -n "$marker" ]] && : > "$marker.pushed" 2>/dev/null
    _attention_log "PUSH digest dossier+notification emitted dossier_id=$written tier=digest channel=$DAEMON_ATTENTION_PUSH_CHANNEL (folds N→1 daily push) workspace=$ref kind=$kind"
  else
    _attention_log "PUSH WARN — digest emit failed workspace=$ref kind=$kind (.pushed left absent ⇒ retried next cadence)"
  fi
  return 0
}

# daemon_attention_poll_once — the one cadence step. Reads the engine `attention`
# field, edge-logs new alerts, hourly-re-logs ongoing ones, and RESOLVED-logs
# cleared ones. Always returns 0.
daemon_attention_poll_once() {
  [[ "$DAEMON_ATTENTION_DISABLED" = "1" ]] && return 0

  local snap
  snap="$(_attention_fetch_snapshot)" || snap=""
  # No snapshot reachable ⇒ observe-first: do NOT touch markers, do NOT clear —
  # uncertainty must not flap RESOLVED on a transient transport failure.
  [[ -n "$snap" ]] || return 0
  printf '%s' "$snap" | jq -e 'type=="object"' >/dev/null 2>&1 || return 0
  # An OLDER engine without the field ⇒ no `.attention` ⇒ honest no-op (additive).
  printf '%s' "$snap" | jq -e 'has("attention")' >/dev/null 2>&1 || return 0

  mkdir -p "$DAEMON_ATTENTION_FIRED_DIR" 2>/dev/null || return 0

  local now; now=$(date -u +%s 2>/dev/null || echo "")
  # Build the CURRENT alert set as `key\tjson` lines (key = project_ref::kind).
  local alerts_tsv
  alerts_tsv="$(printf '%s' "$snap" | jq -r '
    (.attention.alerts // [])
    | .[] | select(type=="object")
    | ((.project_ref // "?") + "::" + (.kind // "?")) + "\t" + (@json)
  ' 2>/dev/null)" || alerts_tsv=""

  # Track which marker keys are still active this cycle (to detect resolutions).
  local active_keys=""
  if [[ -n "$alerts_tsv" ]]; then
    local line key ajson safe marker detail ref kind age logged_at relog
    while IFS=$'\t' read -r key ajson; do
      [[ -n "$key" ]] || continue
      safe="$(_attention_safe_key "$key")"
      marker="$DAEMON_ATTENTION_FIRED_DIR/$safe.json"
      active_keys="$active_keys $safe"
      ref="$(printf '%s' "$ajson" | jq -r '.project_ref // "?"' 2>/dev/null)"
      kind="$(printf '%s' "$ajson" | jq -r '.kind // "?"' 2>/dev/null)"
      detail="$(printf '%s' "$ajson" | jq -r '.detail // ""' 2>/dev/null)"
      age="$(printf '%s' "$ajson" | jq -r '.heartbeat_age_seconds // "?"' 2>/dev/null)"
      if [[ ! -f "$marker" ]]; then
        # EDGE — first detection of this alert.
        _attention_log "WARN MACHINE ATTENTION workspace=$ref kind=$kind heartbeat_age_seconds=$age — ${detail:-needs attention}"
        printf '%s\n' "$ajson" > "$marker" 2>/dev/null
        [[ -n "$now" ]] && printf '%s\n' "$now" > "$marker.at" 2>/dev/null
        # tv88: ALSO fire the digest PHONE PUSH on the edge (one per sustained
        # alert — canary-gated; .pushed sentinel makes it once-only + retryable).
        _daemon_attention_push "$ref" "$kind" "$detail" "$age" "$marker"
      else
        # ONGOING — re-log at most once per DAEMON_ATTENTION_RELOG_SECONDS so an
        # operator sees it is still broken, without a 60s storm.
        relog="$DAEMON_ATTENTION_RELOG_SECONDS"
        if [[ -n "$now" && "$relog" =~ ^[0-9]+$ && "$relog" -gt 0 ]]; then
          logged_at="$(cat "$marker.at" 2>/dev/null || echo 0)"
          [[ "$logged_at" =~ ^[0-9]+$ ]] || logged_at=0
          if [[ "$(( now - logged_at ))" -ge "$relog" ]]; then
            _attention_log "WARN MACHINE ATTENTION (ongoing) workspace=$ref kind=$kind heartbeat_age_seconds=$age — ${detail:-needs attention}"
            printf '%s\n' "$ajson" > "$marker" 2>/dev/null
            printf '%s\n' "$now" > "$marker.at" 2>/dev/null
          fi
        fi
        # tv88: RETRY a push that never landed on the edge (or page a still-wedged
        # runner right after the canary is flipped live). No-op once .pushed exists.
        _daemon_attention_push "$ref" "$kind" "$detail" "$age" "$marker"
      fi
    done <<< "$alerts_tsv"
  fi

  # RESOLVED — any marker whose key is no longer in the active set has cleared.
  local f base
  for f in "$DAEMON_ATTENTION_FIRED_DIR"/*.json; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"; base="${base%.json}"
    case " $active_keys " in
      *" $base "*) : ;; # still active
      *)
        local rref rkind
        rref="$(jq -r '.project_ref // "?"' "$f" 2>/dev/null || echo "?")"
        rkind="$(jq -r '.kind // "?"' "$f" 2>/dev/null || echo "?")"
        _attention_log "RESOLVED machine attention cleared workspace=$rref kind=$rkind"
        rm -f "$f" "$f.at" "$f.pushed" 2>/dev/null
        ;;
    esac
  done
  return 0
}
