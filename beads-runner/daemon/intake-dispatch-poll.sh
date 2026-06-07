# shellcheck shell=bash
# beads-runner/daemon/intake-dispatch-poll.sh — I3 intake-request poll +
# enricher dispatch (claude-tools-06i; epic claude-tools-kie).
#
# WHAT THIS IS (UX-DESIGN.md Flow A; task spec)
#   The daemon-side per-machine intake-request poll. On a ~30s cadence the
#   daemon hits the engine's `intake-pending` op (lib/coordinator.sh +
#   cf/src/coordinator.js) for the JSON array of unprocessed intake-request
#   records. For each one whose `project_ref` matches a workspace in the
#   per-machine registry, we:
#
#     1. Resolve project_ref → workspace dir via the registry.
#     2. Spawn agents/specialist.sh --kind=enricher --workspace=<dir> with a
#        context JSON containing {intake_id, idea_text, project_ref, preset,
#        submitted_at} — exactly the shape enricher.system.md (S3) expects.
#     3. Parse the enricher's one-line stdout summary to capture the bd id
#        it produced (or augmented / refused-to).
#     4. Mark the intake-request as processed in the engine — by re-PUTting
#        the same record with `processed: true` + an `enricher_bd_id` /
#        `enricher_outcome` annotation. (Re-using `put` avoids inventing a
#        second write surface; the engine re-stamps the principal on the
#        way through, but every other field round-trips intact.)
#
#   On any miscarriage — unknown project_ref, specialist non-zero exit, parse
#   failure on the stdout summary — the record is NOT marked processed, so
#   the next cadence retries it. (This matches the daemon's observe-first
#   posture: if we are not sure the dispatch was clean, leave the queue
#   marker in place and try again.)
#
# WHAT THIS IS *NOT*
#   • NOT the enricher itself. The enricher is `claude -p` invoked by
#     specialist.sh with the S3 (claude-tools-bnq) system prompt; it is the
#     one writing bd commands. This file is only the dispatch site.
#   • NOT a workspace-runner spawner. M3 (claude-tools-cgh) owns the
#     workspace-runner lifecycle via launch-detached.sh + the desired-state
#     state machine. The intake dispatch fires a SHORT-LIVED specialist agent
#     in the workspace cwd, independent of whether the workspace runner is
#     up or paused — phone-intake is a Flow A surface, not a runner action.
#   • NOT a backfill / replay tool. We process ONLY records that the engine
#     reports as `processed: false`. A historical record that someone has
#     already marked processed by hand stays processed.
#
# LOGGING (task spec)
#   Every dispatch attempt is logged with workspace + an SHA-256-truncated
#   hash of the idea_text (NOT the full text — privacy) + the resulting bd
#   id (or the failure reason). The full enricher stdout/stderr stream is
#   already captured in <workspace>/.beads/runner-logs/specialist-enricher-
#   *.jsonl (BC-27 self-gitignore) by the shim, so we do NOT duplicate it
#   in the daemon log.
#
# ENGINE TRANSPORT
#   We do NOT pin to a single workspace's coordinator binding — `intake-
#   pending` is a per-machine query (the engine knows nothing about
#   workspaces; it has whatever intake-requests have landed). We piggy-back
#   on the FIRST registered workspace's coordinator binding to reach the
#   engine. If the registry is empty there is nothing this daemon could
#   dispatch to anyway, so the poll is a no-op.

# Resolve sibling paths at source time (matches desired-state-poll.sh).
DAEMON_REPO_DIR="${DAEMON_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}"
DAEMON_REPO_LIB_DIR="${DAEMON_REPO_LIB_DIR:-$DAEMON_REPO_DIR/lib}"
DAEMON_SPECIALIST_SH="${DAEMON_SPECIALIST_SH:-$DAEMON_REPO_DIR/agents/specialist.sh}"

# Test/canary hook: set DAEMON_INTAKE_DISABLED=1 to log decisions but skip
# the actual specialist.sh invocation. The acceptance test exercises this
# branch so it can verify call-site wiring without spending API tokens.
# When set, a synthetic stdout summary `enricher: created <fake-id> ...` is
# used so the mark-processed path still exercises.
DAEMON_INTAKE_DISABLED="${DAEMON_INTAKE_DISABLED:-0}"

# Optional test override: a path to a script that replaces specialist.sh
# (e.g., a bash stub that echoes a deterministic summary to stdout). When
# set, this takes precedence over DAEMON_INTAKE_DISABLED — the override IS
# the dispatch path, exercised end-to-end.
DAEMON_INTAKE_SPECIALIST_OVERRIDE="${DAEMON_INTAKE_SPECIALIST_OVERRIDE:-}"

# Max enricher-dispatch attempts before the daemon GIVES UP on an intake-request
# (inbox-lifecycle §9.5 #1/#4; L3 claude-tools-uxvl3). The overnight e5aq
# incident retried one intake 19+ times at ~$1/retry, all invisible to Brian —
# this cap turns that silent money-burn into a terminal `gave_up` state the
# phone surfaces. Each FAILED dispatch (specialist non-zero exit OR unparseable
# enricher summary) increments `dispatch_attempts`; once it reaches the cap the
# record is marked `gave_up:true` (still processed=false, but the dispatch loop
# skips it from then on). Pre-dispatch SKIPS (unknown project_ref — another
# machine's workspace; malformed record) do NOT count: this daemon never owns
# that record's retry budget. Set to 0 to disable the cap (retry forever — the
# pre-L3 behaviour; not recommended).
INTAKE_MAX_ATTEMPTS="${INTAKE_MAX_ATTEMPTS:-3}"

# L4 (claude-tools-uxvl4) — the SPECIAL `overview-request` preset. An intake
# carrying this preset produces NO bd task: instead of the enricher, the daemon
# routes it to a dossier-builder that authors a proactive_checkpoint timed-fyi
# (a Blueprint refresh / FYI) and publishes it to the engine + phone. This is
# the daemon-side branch the catalog's `routing:"overview-fyi"` row points at
# (test-intake-presets.sh check 10 enforces this value is branched on here). The
# enricher is never spawned for it (dedup-against-bd is meaningless for an FYI;
# inbox-lifecycle §3.4 Gap B "skip the enricher" resolution).
INTAKE_OVERVIEW_PRESET="${INTAKE_OVERVIEW_PRESET:-overview-request}"

# Test override: a script replacing the engine-write subshell for the overview
# FYI emit. Called as "<override> <ws> <gi.json>", rc 0 ⇒ written, and it should
# echo the dossier id on stdout (mirrors DAEMON_FLOW_F_ENGINE_OVERRIDE). Lets the
# overview-branch test verify dispatch wiring without sourcing the coordinator
# stack or hitting an engine.
DAEMON_INTAKE_OVERVIEW_ENGINE_OVERRIDE="${DAEMON_INTAKE_OVERVIEW_ENGINE_OVERRIDE:-}"

# daemon_intake_idea_hash <idea_text> → short hex hash (privacy-preserving)
#   sha256 first 12 hex chars. The full text is NEVER logged. The hash gives
#   a stable handle for grepping a specific tap across logs (Brian: "did
#   that idea I sent at 09:14 actually dispatch?") without exposing the
#   sentence to whoever ends up reading the daemon stdout.log.
daemon_intake_idea_hash() {
  local text="${1:-}" h
  if command -v shasum >/dev/null 2>&1; then
    h="$(printf '%s' "$text" | shasum -a 256 2>/dev/null | awk '{print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    h="$(printf '%s' "$text" | sha256sum 2>/dev/null | awk '{print $1}')"
  else
    h=""
  fi
  printf '%s' "${h:0:12}"
}

# daemon_intake_workspace_for <project_ref> → echo the workspace dir or ""
#   Linear scan over REGISTRY_PROJECT_REFS — N is small (~handful of
#   workspaces per machine), so a hash table would be over-engineered.
daemon_intake_workspace_for() {
  local pref="${1:-}" n i
  [[ -n "$pref" ]] || return 0
  n="${#REGISTRY_PROJECT_REFS[@]}"
  i=0
  while [[ "$i" -lt "$n" ]]; do
    if [[ "${REGISTRY_PROJECT_REFS[$i]:-}" == "$pref" ]]; then
      printf '%s' "${REGISTRY_DIRS[$i]:-}"
      return 0
    fi
    i=$((i + 1))
  done
  printf ''
}

# daemon_intake_fetch_pending → echo a JSON array of pending intake records
#   Subshell-isolated like the M3 fetch. We piggy-back on workspace 0's
#   coordinator binding (PROJECT_REF/CO_STORE/COORDINATOR_URL/_TOKEN) since
#   `intake-pending` is a per-machine read that the engine answers
#   identically regardless of which workspace token authorises it. If the
#   registry is empty, we have no engine binding to reach and echo `[]`.
#
#   Echoes `[]` on any failure path (coordinator unreachable, jq missing,
#   token absent) so the caller's iteration is naturally a no-op without
#   needing an extra "did this succeed?" branch.
daemon_intake_fetch_pending() {
  local n ws pref curl tk_item
  n="${#REGISTRY_PROJECT_REFS[@]}"
  if [[ "$n" -eq 0 ]]; then
    printf '[]'
    return 0
  fi
  ws="${REGISTRY_DIRS[0]:-}"
  pref="${REGISTRY_PROJECT_REFS[0]:-}"
  curl="${REGISTRY_COORDINATOR_URLS[0]:-}"
  tk_item="${REGISTRY_TOKEN_KEYCHAIN_ITEMS[0]:-}"
  [[ -n "$ws" && -n "$pref" ]] || { printf '['']'; return 0; }
  _daemon_intake_fetch_pending_one "$ws" "$pref" "$curl" "$tk_item"
}

_daemon_intake_fetch_pending_one() {
  local ws="$1" pref="$2" curl="$3" tk_item="$4"
  (
    set +e
    cd "$ws" 2>/dev/null || { printf '[]'; exit 0; }
    export PROJECT_REF="$pref"
    : "${CO_STORE:=$ws/.beads/runner-logs/.co-store}"
    export CO_STORE
    if [[ -n "$curl" ]]; then export COORDINATOR_URL="$curl"; fi
    if [[ -n "$tk_item" ]] && command -v security >/dev/null 2>&1; then
      local _tk
      _tk="$(security find-generic-password -s "$tk_item" -w 2>/dev/null || true)"
      [[ -n "$_tk" ]] && export COORDINATOR_TOKEN="$_tk"
    fi
    # shellcheck source=/dev/null
    . "$DAEMON_REPO_LIB_DIR/coordinator.sh" 2>/dev/null || { printf '[]'; exit 0; }
    # shellcheck source=/dev/null
    [[ -f "$DAEMON_REPO_LIB_DIR/co-http-transport.sh" ]] \
      && . "$DAEMON_REPO_LIB_DIR/co-http-transport.sh" 2>/dev/null
    command -v co_request >/dev/null 2>&1 || { printf '[]'; exit 0; }
    local bearer resp
    bearer="${COORDINATOR_TOKEN:-bearer-daemon-i3}"
    resp="$(co_request "$bearer" intake-pending 2>/dev/null)" || resp=""
    [[ -n "$resp" ]] || { printf '[]'; exit 0; }
    # Defensive: only echo if it parses as a JSON array.
    if printf '%s' "$resp" | jq -e 'type=="array"' >/dev/null 2>&1; then
      printf '%s' "$resp"
    else
      printf '[]'
    fi
  )
}

# _daemon_intake_put_record <ws> <pref> <curl> <tk_item> <intake_id> <record_json>
#   The shared subshell that re-PUTs ONE intake-request record through the
#   per-workspace coordinator binding (piggy-backing on workspace 0's engine as
#   everywhere in this file). Returns 0 on success, 1 on any failure. Both the
#   terminal mark-processed put AND the L3 intermediate state-writes (enriching
#   marker, failing/gave_up annotations) go through this one path so they share
#   identical transport/auth wiring. The engine re-stamps `principal` on the put
#   (§9.1); every other field round-trips verbatim.
_daemon_intake_put_record() {
  local ws="$1" pref="$2" curl="$3" tk_item="$4" intake_id="$5" record="$6"
  (
    set +e
    cd "$ws" 2>/dev/null || exit 1
    export PROJECT_REF="$pref"
    : "${CO_STORE:=$ws/.beads/runner-logs/.co-store}"
    export CO_STORE
    if [[ -n "$curl" ]]; then export COORDINATOR_URL="$curl"; fi
    if [[ -n "$tk_item" ]] && command -v security >/dev/null 2>&1; then
      local _tk
      _tk="$(security find-generic-password -s "$tk_item" -w 2>/dev/null || true)"
      [[ -n "$_tk" ]] && export COORDINATOR_TOKEN="$_tk"
    fi
    # shellcheck source=/dev/null
    . "$DAEMON_REPO_LIB_DIR/coordinator.sh" 2>/dev/null || exit 1
    # shellcheck source=/dev/null
    [[ -f "$DAEMON_REPO_LIB_DIR/co-http-transport.sh" ]] \
      && . "$DAEMON_REPO_LIB_DIR/co-http-transport.sh" 2>/dev/null
    command -v co_request >/dev/null 2>&1 || exit 1
    local bearer
    bearer="${COORDINATOR_TOKEN:-bearer-daemon-i3}"
    co_request "$bearer" put intake-request "$intake_id" "$record" >/dev/null 2>&1
  )
}

# daemon_intake_mark_processed <ws> <pref> <curl> <tk_item> <intake_id> \
#                              <updated_record_json>
#   Re-PUT the intake-request record with `processed:true` and dispatch
#   annotations. Returns 0 on success, 1 on any failure (caller logs but
#   does NOT abort the rest of the dispatch loop — a single mark-processed
#   failure stranding one record is preferable to walling the whole queue).
daemon_intake_mark_processed() {
  _daemon_intake_put_record "$1" "$2" "$3" "$4" "$5" "$6"
}

# daemon_intake_mark_failed <ws> <pref> <curl> <tk_item> <rec_json> \
#                           <intake_id> <attempt_n> <reason>
#   L3 (claude-tools-uxvl3) — record a FAILED enricher dispatch on the
#   intake-request so the phone surfaces `failing(n)` and eventually `gave-up`.
#   The record stays processed=false (so the happy-path retry on the next
#   cadence still works) UNLESS the attempt count has reached
#   INTAKE_MAX_ATTEMPTS, in which case it flips to the terminal `gave_up:true`
#   (the dispatch loop skips it from then on — closing the silent-retry leak).
#   Best-effort: returns the put's status but the caller does not abort the loop
#   on a telemetry-write failure (the record simply retries with a stale count).
daemon_intake_mark_failed() {
  local ws="$1" pref="$2" curl="$3" tk_item="$4" rec="$5" intake_id="$6"
  local n="$7" reason="$8" now_iso gave updated
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"
  # gave-up when a positive cap is set and this attempt reached it.
  if [[ "${INTAKE_MAX_ATTEMPTS:-3}" =~ ^[0-9]+$ ]] \
     && [[ "${INTAKE_MAX_ATTEMPTS:-3}" -gt 0 ]] \
     && [[ "$n" -ge "${INTAKE_MAX_ATTEMPTS:-3}" ]]; then
    gave="true"
  else
    gave="false"
  fi
  updated="$(printf '%s' "$rec" \
              | jq -c \
                  --argjson na "$n" \
                  --arg la "$now_iso" \
                  --arg er "$reason" \
                  --argjson gu "$gave" \
                  'if $gu then
                     . + {processed:false, dispatch_attempts:$na, last_attempt_at:$la,
                          last_error:$er, dispatch_state:"gave_up", gave_up:true, gave_up_at:$la}
                   else
                     . + {processed:false, dispatch_attempts:$na, last_attempt_at:$la,
                          last_error:$er, dispatch_state:"failing"}
                   end' \
              2>/dev/null)"
  [[ -n "$updated" ]] || return 1
  _daemon_intake_put_record "$ws" "$pref" "$curl" "$tk_item" "$intake_id" "$updated"
}

# daemon_intake_parse_bd_id <stdout> → echo the bd id from the one-line summary
#   The enricher (S3, enricher.system.md) emits one of:
#     enricher: created <bead-id> (intake <intake_id>, preset=<p>, ...)
#     enricher: dedup → augmented <existing-bead-id> (intake <intake_id>, ...)
#     enricher: refuse → filed Inbox question <bead-id> (intake <intake_id>): ...
#   We pull the FIRST bead-id-shaped token (project-prefix-NNN: alnum-dash plus
#   a digits suffix is a common shape but we stay liberal — anything after the
#   verb that looks like a bd id). Empty echo = not parseable (caller treats
#   as a failed dispatch and does NOT mark processed).
daemon_intake_parse_bd_id() {
  local stdout="${1:-}" line
  # Take only the last non-empty line (the enricher contract says exactly one
  # line on stdout, but a stray blank from a wrapper shouldn't break us).
  line="$(printf '%s' "$stdout" | awk 'NF{last=$0} END{print last}')"
  [[ -n "$line" ]] || { printf ''; return 0; }
  case "$line" in
    *"enricher: created "*)
      printf '%s' "$line" | sed -n 's/.*enricher: created \([A-Za-z0-9_.-]*\).*/\1/p'
      ;;
    *"enricher: dedup"*"augmented "*)
      printf '%s' "$line" | sed -n 's/.*augmented \([A-Za-z0-9_.-]*\).*/\1/p'
      ;;
    *"enricher: refuse"*"filed Inbox question "*)
      printf '%s' "$line" | sed -n 's/.*filed Inbox question \([A-Za-z0-9_.-]*\).*/\1/p'
      ;;
    *) printf '' ;;
  esac
}

# daemon_intake_outcome <stdout> → echo a short outcome tag
#   (created|augmented|refused|error|unknown)
#   `error` (claude-tools-t956 / inbox-lifecycle §9.5 #2) is the enricher's CLEAN
#   self-reported terminal error — `enricher: error → <reason>` — distinct from
#   `unknown` (a summary we simply could not parse). Both are failed dispatches
#   (no bd id), but `error` lets the daemon surface the enricher's STATED reason
#   on the phone instead of a generic "unparseable".
daemon_intake_outcome() {
  local stdout="${1:-}" line
  line="$(printf '%s' "$stdout" | awk 'NF{last=$0} END{print last}')"
  case "$line" in
    *"enricher: created "*)                        printf 'created' ;;
    *"enricher: dedup"*"augmented "*)              printf 'augmented' ;;
    *"enricher: refuse"*"filed Inbox question "*)  printf 'refused' ;;
    *"enricher: error"*)                           printf 'error' ;;
    *)                                             printf 'unknown' ;;
  esac
}

# daemon_intake_parse_error_reason <stdout> → echo the <reason> from a clean
#   `enricher: error → <reason>` (or ASCII `enricher: error -> <reason>`) line,
#   or empty for any non-error line. The enricher (enricher.system.md Output)
#   emits this when it can neither enrich NOR even file an Inbox question (e.g. a
#   tool/permission denial, a bd subprocess failure) — a self-reported terminal
#   error. Pure parameter-expansion (no sed/awk) so the multibyte → arrow is
#   matched byte-wise without a locale dependency. Liberal: the reason is free
#   text. Still a failed dispatch ⇒ counts toward INTAKE_MAX_ATTEMPTS / gave-up.
daemon_intake_parse_error_reason() {
  local stdout="${1:-}" line rest
  line="$(printf '%s' "$stdout" | awk 'NF{last=$0} END{print last}')"
  case "$line" in
    *"enricher: error"*)
      rest="${line#*enricher: error}"
      # strip leading whitespace
      rest="${rest#"${rest%%[![:space:]]*}"}"
      # strip a leading arrow token (unicode → or ASCII ->), if present
      case "$rest" in
        "→"*)  rest="${rest#→}" ;;
        "->"*) rest="${rest#->}" ;;
      esac
      # strip leading whitespace again, then emit the remaining free-text reason
      rest="${rest#"${rest%%[![:space:]]*}"}"
      printf '%s' "$rest"
      ;;
    *) printf '' ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════
# L4 (claude-tools-uxvl4) — the `overview-request` preset path: NO bd task,
# route to a dossier-builder → proactive_checkpoint timed-fyi (Blueprint refresh
# / FYI). inbox-lifecycle §3.4 Gap B. The machinery deliberately mirrors Flow F's
# proactive overview dispatch (daemon/flow-f-overview-poll.sh): same builder I/O
# (specialist.sh --kind=dossier-builder → {body,items}), same §4.1 generation
# envelope (kind=overview, tier=timed-fyi), same engine emit (dg_generate +
# no_emit/no_dispatch + tf_arm). The differences are (1) trigger=proactive_check-
# point (this is a human-initiated FYI, not a stage close), (2) bead_ref is the
# synthetic intake_id (an overview-request has no bd task — §4.1 only needs a
# non-empty string), and (3) it rides the I3 intake retry/state machine
# (failing(n)→gave_up) so a flaky builder can't silently burn money.
# ════════════════════════════════════════════════════════════════════════════

# daemon_intake__build_overview_builder_input <dossier_id> <bead_ref> <ws> <idea_text>
#   The dossier-builder stdin (agents/dossier-builder.system.md input contract).
#   Framed as a PROACTIVE OVERVIEW (like Flow F) rather than worker-stuck, and —
#   crucially — telling the builder that bead_ref is a SYNTHETIC intake id, NOT a
#   bd task: it must survey the workspace broadly instead of `bd show`-ing a
#   nonexistent bead.
daemon_intake__build_overview_builder_input() {
  local did="${1:-}" bref="${2:-}" ws="${3:-}" idea="${4:-}"
  local context_dump
  context_dump="OVERVIEW REQUEST (UX-DESIGN Flow A, claude-tools-uxvl4 / L4): Brian asked from his phone to be CAUGHT UP — he tapped the \"just catch me up\" intake preset, which makes NO bd task. This is a PROACTIVE OVERVIEW / status FYI dossier, NOT a worker-stuck decision dossier and NOT a request to start work. Brian's framing of what he wants briefed: \"${idea}\". IMPORTANT: \`bead_ref\` (\`$bref\`) is a SYNTHETIC intake id, NOT a bd task — do NOT \`bd show $bref\` (it does not exist). Instead survey the WORKSPACE: \`bd ready\`, \`bd list --status open\`, \`bd blocked\`, the recent history (\`git log --oneline -n 30\`), and the design/status docs (\`CLAUDE.md\`, \`README.md\`, any \`DESIGN.md\`/\`UX-DESIGN.md\`/\`INTERFACE.md\`/\`HANDOFF*.md\`). Produce the deep body Brian will read on his phone to understand 'here is where things stand and what is in flight', focused through the lens of his framing above. ITEMS DISCIPLINE: emit either an empty items[] (pure FYI) or items all of kind \`fyi-objectable\` (each a small claim Brian can push back on inside the 24h window). DO NOT emit a \`pick-option\` item — the human is not being asked to pick or to approve starting work. The tier is \`timed-fyi\`: silence auto-proceeds in 24h, an objection cancels follow-on. If the workspace is genuinely too thin/empty to anchor a real overview, refuse cleanly via the {\"refuse\":true,\"reason\":\"...\"} channel."
  jq -cn \
    --arg did "$did" \
    --arg b   "$bref" \
    --arg w   "$ws" \
    --arg q   "Catch me up on this workspace: ${idea}" \
    --arg cd  "$context_dump" \
    '{dossier_id:$did, bead_ref:$b, workspace_dir:$w, question:$q, context_dump:$cd}'
}

# daemon_intake__build_overview_generation_input <dossier_id> <bead_ref> <builder_json>
#   Wrap the dossier-builder's {body, items[]} into the §4.1 envelope
#   (dg_generate's generation_input). Mirrors flow-f's builder, EXCEPT
#   trigger=proactive_checkpoint (a human-initiated FYI; the §4.1 enum value for
#   this path — inbox-lifecycle §3.4 step 3) and authored_by_reason names THIS
#   producer so the §xdo no-fallback-badge fix (claude-tools-69u8) credits the
#   agent body instead of logging a degraded jq fallback.
daemon_intake__build_overview_generation_input() {
  local did="${1:-}" bref="${2:-}" out="${3:-}"
  printf '%s' "$out" | jq -c \
    --arg did "$did" \
    --arg b   "$bref" '
      .body  as $body
    | (.items // []) as $items
    | { id: $did,
        kind: "overview",
        trigger: "proactive_checkpoint",
        bead_ref: $b,
        tier: "timed-fyi",
        timer_fire_at: null,
        source: {
          tldr:        ($body.tldr // ""),
          sections:    ($body.sections // []),
          diagrams:    ($body.diagrams // []),
          full_detail: ($body.full_detail // ""),
          authored_by:        "agent",
          authored_by_reason: "intake_overview_request"
        },
        items: $items }
  ' 2>/dev/null
}

# _daemon_intake_overview_engine_write <ws> <pref> <curl> <tk_item> <gi_json>
#   Persist the FYI dossier + emit/dispatch the §4.3 notification + arm the §2.2
#   24h timed-fyi window. Byte-for-byte the same engine sequence as Flow F's
#   _daemon_flow_f_engine_write (dg_generate → no_emit → no_dispatch → tf_arm);
#   kept intake-local (with its own override hook) so the I3 path + its test stay
#   self-contained rather than coupling to the flow-f file. Echoes the dossier id
#   on success; nonzero exit on any failure (caller marks the intake failing).
_daemon_intake_overview_engine_write() {
  local ws="$1" pref="$2" curl="$3" tk_item="$4" gi="$5"
  if [[ -n "$DAEMON_INTAKE_OVERVIEW_ENGINE_OVERRIDE" && -x "$DAEMON_INTAKE_OVERVIEW_ENGINE_OVERRIDE" ]]; then
    local tmp
    tmp="$(mktemp 2>/dev/null)" || return 1
    printf '%s' "$gi" > "$tmp" 2>/dev/null
    "$DAEMON_INTAKE_OVERVIEW_ENGINE_OVERRIDE" "$ws" "$tmp"
    local rc=$?
    rm -f "$tmp" 2>/dev/null
    return "$rc"
  fi
  (
    set +e
    cd "$ws" 2>/dev/null || exit 1
    export PROJECT_REF="$pref"
    : "${CO_STORE:=$ws/.beads/runner-logs/.co-store}"
    export CO_STORE
    if [[ -n "$curl" ]]; then export COORDINATOR_URL="$curl"; fi
    if [[ -n "$tk_item" ]] && command -v security >/dev/null 2>&1; then
      local _tk
      _tk="$(security find-generic-password -s "$tk_item" -w 2>/dev/null || true)"
      [[ -n "$_tk" ]] && export COORDINATOR_TOKEN="$_tk"
    fi
    # shellcheck source=/dev/null
    . "$DAEMON_REPO_LIB_DIR/stuck-routing.sh"     2>/dev/null || exit 1
    # shellcheck source=/dev/null
    . "$DAEMON_REPO_LIB_DIR/notification.sh"      2>/dev/null || exit 1
    # shellcheck source=/dev/null
    . "$DAEMON_REPO_LIB_DIR/co-http-transport.sh" 2>/dev/null || true
    # shellcheck source=/dev/null
    . "$DAEMON_REPO_LIB_DIR/timed-fyi.sh"         2>/dev/null || exit 1
    command -v dg_generate >/dev/null 2>&1 || exit 1
    command -v tf_arm      >/dev/null 2>&1 || exit 1
    local bearer did nid
    bearer="${COORDINATOR_TOKEN:-bearer-daemon-intake-overview}"
    did="$(dg_generate "$bearer" "$gi" 2>/dev/null)" || exit 2
    [[ -n "$did" ]] || exit 2
    nid="$(no_emit "$bearer" "$did" 2>/dev/null)" || true
    [[ -n "$nid" ]] && no_dispatch "$bearer" "$nid" "intake-overview" >/dev/null 2>&1 || true
    tf_arm "$bearer" "$did" >/dev/null 2>&1 || exit 3
    printf '%s' "$did"
    exit 0
  )
}

# daemon_intake_dispatch_overview <rec> <ws> <pref> <curl> <tk_item> \
#                                 <intake_id> <idea_text> <hash> <attempts>
#   The `overview-request` dispatch unit. ALWAYS returns 0 (a per-record failure
#   must not abort the loop). Rides the I3 retry/state machine: counts the
#   attempt + writes an in-flight `overview-building` marker before spawning;
#   marks the record FAILING(n)/gave_up via daemon_intake_mark_failed on any
#   miscarriage; marks it PROCESSED with dispatch_state="overview" (NO
#   enricher_bd_id — the s6/s4 testing invariant: no bead is ever created) on a
#   written FYI or a clean builder refusal.
daemon_intake_dispatch_overview() {
  local rec="$1" ws="$2" pref="$3" curl="$4" tk_item="$5"
  local intake_id="$6" idea_text="$7" hash="$8" attempts="$9"
  local n now_iso did marker ctx_file builder_out rc parsed refuse body items gi written updated reason

  n=$((attempts + 1))
  did="overview-intake-$(printf '%s' "$intake_id" | tr -c 'A-Za-z0-9._-' '_')"
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"

  declare -F log >/dev/null 2>&1 && \
    log "I3 overview-dispatch: workspace=$ws intake_id=$intake_id idea_hash=$hash dossier_id=$did (preset=$INTAKE_OVERVIEW_PRESET — NO bd task; proactive_checkpoint timed-fyi)"

  # In-flight marker (best-effort) — the phone sees `overview-building` while the
  # dossier-builder runs. dispatch_attempts counted at the START (matches the
  # enricher path: an attempt that crashes still consumed a dispatch).
  marker="$(printf '%s' "$rec" \
              | jq -c \
                  --argjson na "$n" \
                  --arg la "$now_iso" \
                  '. + {processed:false, dispatch_attempts:$na, last_attempt_at:$la, dispatch_state:"overview-building"} | del(.last_error)' \
              2>/dev/null)"
  [[ -n "$marker" ]] && \
    _daemon_intake_put_record "$ws" "$pref" "$curl" "$tk_item" "$intake_id" "$marker" >/dev/null 2>&1

  # Resolve the spawner: override > disabled-canary > real specialist.sh. The
  # override reuses DAEMON_INTAKE_SPECIALIST_OVERRIDE (both the enricher and the
  # dossier-builder are specialist.sh hats), so the I3 test stub covers both.
  local spawner=() _override _disabled
  _override="${DAEMON_INTAKE_SPECIALIST_OVERRIDE:-}"
  _disabled="${DAEMON_INTAKE_DISABLED:-0}"
  if [[ -n "$_override" ]]; then
    if [[ ! -x "$_override" ]]; then
      declare -F log >/dev/null 2>&1 && \
        log "I3 overview-dispatch: refuse — DAEMON_INTAKE_SPECIALIST_OVERRIDE='$_override' not executable"
      return 0
    fi
    spawner=("$_override")
  elif [[ "$_disabled" == "1" ]]; then
    # Canary: synthesise a stub dossier id, SKIP the real spawn + engine write,
    # and mark processed so the mark-processed wiring is exercised without tokens
    # or an engine. NO bd task is created (the invariant holds in the canary too).
    declare -F log >/dev/null 2>&1 && \
      log "I3 overview-dispatch: DAEMON_INTAKE_DISABLED=1 ⇒ would invoke $DAEMON_SPECIALIST_SH --kind=dossier-builder --workspace=$ws + write a proactive_checkpoint timed-fyi (intake_id=$intake_id idea_hash=$hash); synthesising a stub so mark-processed exercises"
    updated="$(printf '%s' "$rec" \
                | jq -c \
                    --arg did "stub-$did" \
                    --argjson na "$n" \
                    --arg pa "$now_iso" \
                    '. + {processed:true, overview_dossier_id:$did, overview_outcome:"canary",
                          processed_at:$pa, dispatch_attempts:$na, dispatch_state:"overview"} | del(.last_error)' \
                2>/dev/null)"
    if [[ -n "$updated" ]] && daemon_intake_mark_processed "$ws" "$pref" "$curl" "$tk_item" "$intake_id" "$updated"; then
      declare -F log >/dev/null 2>&1 && \
        log "I3 overview-dispatch: OK (canary) — workspace=$ws intake_id=$intake_id idea_hash=$hash dossier_id=stub-$did (no bd task; record marked processed)"
    fi
    return 0
  else
    if [[ ! -x "$DAEMON_SPECIALIST_SH" ]]; then
      declare -F log >/dev/null 2>&1 && \
        log "I3 overview-dispatch: refuse — specialist.sh missing/non-executable at $DAEMON_SPECIALIST_SH"
      return 0
    fi
    spawner=("$DAEMON_SPECIALIST_SH")
  fi

  # Build the builder context + spawn the dossier-builder hat.
  ctx_file="$(mktemp 2>/dev/null)" || {
    declare -F log >/dev/null 2>&1 && \
      log "I3 overview-dispatch: refuse — mktemp failed for intake_id=$intake_id idea_hash=$hash"
    return 0
  }
  daemon_intake__build_overview_builder_input "$did" "$intake_id" "$ws" "$idea_text" > "$ctx_file" 2>/dev/null

  builder_out="$("${spawner[@]}" \
                  --kind=dossier-builder \
                  --workspace="$ws" \
                  --context-file="$ctx_file" \
                  2>/dev/null)"
  rc=$?
  rm -f "$ctx_file" 2>/dev/null

  if [[ "$rc" -ne 0 ]]; then
    reason="dossier-builder exit=$rc"
    daemon_intake_mark_failed "$ws" "$pref" "$curl" "$tk_item" "$rec" "$intake_id" "$n" "$reason" >/dev/null 2>&1 || true
    declare -F log >/dev/null 2>&1 && \
      log "I3 overview-dispatch: FAIL — dossier-builder exit=$rc workspace=$ws intake_id=$intake_id idea_hash=$hash attempt=$n/${INTAKE_MAX_ATTEMPTS:-3} (record left unprocessed; next cadence retries unless gave_up)"
    return 0
  fi

  parsed="$(printf '%s' "$builder_out" | jq -c 'if type=="object" then . else null end' 2>/dev/null)"
  if [[ -z "$parsed" || "$parsed" == "null" ]]; then
    reason="dossier-builder stdout not a JSON object"
    daemon_intake_mark_failed "$ws" "$pref" "$curl" "$tk_item" "$rec" "$intake_id" "$n" "$reason" >/dev/null 2>&1 || true
    declare -F log >/dev/null 2>&1 && \
      log "I3 overview-dispatch: FAIL — builder stdout not JSON object workspace=$ws intake_id=$intake_id idea_hash=$hash attempt=$n/${INTAKE_MAX_ATTEMPTS:-3} (record left unprocessed; retries unless gave_up)"
    return 0
  fi

  refuse="$(printf '%s' "$parsed" | jq -r '.refuse // false' 2>/dev/null)"
  if [[ "$refuse" == "true" ]]; then
    # A clean refusal (workspace too thin to brief) is TERMINAL, not a failure to
    # retry — re-dispatching would just refuse again and burn money. Mark the
    # intake PROCESSED with no dossier + no bead. Honest outcome surfaced on the
    # record for forensics.
    reason="$(printf '%s' "$parsed" | jq -r '.reason // ""' 2>/dev/null)"
    updated="$(printf '%s' "$rec" \
                | jq -c \
                    --argjson na "$n" \
                    --arg pa "$now_iso" \
                    --arg rs "${reason:0:240}" \
                    '. + {processed:true, overview_outcome:"refused", overview_refuse_reason:$rs,
                          processed_at:$pa, dispatch_attempts:$na, dispatch_state:"overview"} | del(.last_error)' \
                2>/dev/null)"
    if [[ -n "$updated" ]]; then
      daemon_intake_mark_processed "$ws" "$pref" "$curl" "$tk_item" "$intake_id" "$updated" >/dev/null 2>&1 || true
    fi
    declare -F log >/dev/null 2>&1 && \
      log "I3 overview-dispatch: REFUSED workspace=$ws intake_id=$intake_id idea_hash=$hash reason='${reason:0:120}' (no bd task, no dossier — honest refusal; record marked processed so it does not retry)"
    return 0
  fi

  body="$(printf '%s' "$parsed"  | jq -c '.body // null' 2>/dev/null)"
  items="$(printf '%s' "$parsed" | jq -c '.items // null' 2>/dev/null)"
  if [[ "$body" == "null" || -z "$body" || "$items" == "null" ]]; then
    reason="builder output missing body or items[]"
    daemon_intake_mark_failed "$ws" "$pref" "$curl" "$tk_item" "$rec" "$intake_id" "$n" "$reason" >/dev/null 2>&1 || true
    declare -F log >/dev/null 2>&1 && \
      log "I3 overview-dispatch: FAIL — builder output missing body or items[] workspace=$ws intake_id=$intake_id idea_hash=$hash attempt=$n/${INTAKE_MAX_ATTEMPTS:-3} (retries unless gave_up)"
    return 0
  fi

  gi="$(daemon_intake__build_overview_generation_input "$did" "$intake_id" "$parsed")"
  if [[ -z "$gi" ]]; then
    reason="could not assemble generation input"
    daemon_intake_mark_failed "$ws" "$pref" "$curl" "$tk_item" "$rec" "$intake_id" "$n" "$reason" >/dev/null 2>&1 || true
    declare -F log >/dev/null 2>&1 && \
      log "I3 overview-dispatch: FAIL — could not assemble generation input workspace=$ws intake_id=$intake_id idea_hash=$hash attempt=$n/${INTAKE_MAX_ATTEMPTS:-3}"
    return 0
  fi

  written="$(_daemon_intake_overview_engine_write "$ws" "$pref" "$curl" "$tk_item" "$gi" 2>/dev/null)"
  if [[ -z "$written" ]]; then
    reason="engine write returned no dossier id"
    daemon_intake_mark_failed "$ws" "$pref" "$curl" "$tk_item" "$rec" "$intake_id" "$n" "$reason" >/dev/null 2>&1 || true
    declare -F log >/dev/null 2>&1 && \
      log "I3 overview-dispatch: FAIL — engine write returned no id workspace=$ws intake_id=$intake_id idea_hash=$hash attempt=$n/${INTAKE_MAX_ATTEMPTS:-3} (retries unless gave_up)"
    return 0
  fi

  # Success: mark processed with NO enricher_bd_id (the invariant: no bd task).
  updated="$(printf '%s' "$rec" \
              | jq -c \
                  --arg did "$written" \
                  --argjson na "$n" \
                  --arg pa "$now_iso" \
                  '. + {processed:true, overview_dossier_id:$did, overview_outcome:"written",
                        processed_at:$pa, dispatch_attempts:$na, dispatch_state:"overview"} | del(.last_error)' \
              2>/dev/null)"
  if [[ -n "$updated" ]] && daemon_intake_mark_processed "$ws" "$pref" "$curl" "$tk_item" "$intake_id" "$updated"; then
    declare -F log >/dev/null 2>&1 && \
      log "I3 overview-dispatch: OK — workspace=$ws intake_id=$intake_id idea_hash=$hash dossier_id=$written tier=timed-fyi (no bd task; FYI published + 24h timer armed; record marked processed)"
  else
    declare -F log >/dev/null 2>&1 && \
      log "I3 overview-dispatch: WARN — FYI dossier_id=$written written but mark-processed put FAILED workspace=$ws intake_id=$intake_id idea_hash=$hash (will re-dispatch next cadence — engine write is idempotent on the deterministic dossier id)"
  fi
  return 0
}

# daemon_intake_dispatch_one <record_json>
#   Process one intake-request record. ALWAYS returns 0 (a per-record failure
#   must not abort the loop). Logs the dispatch attempt + outcome.
daemon_intake_dispatch_one() {
  local rec="${1:-}" intake_id idea_text pref preset submitted_at gave_up attempts
  local ws curl tk_item idx i hash outcome bd_id stdout rc ctx_file updated
  local n now_iso marker reason

  [[ -n "$rec" ]] || return 0

  intake_id="$(printf '%s' "$rec"     | jq -r 'if type=="object" then (.id // "") else "" end' 2>/dev/null)"
  idea_text="$(printf '%s' "$rec"     | jq -r 'if type=="object" then (.idea_text // "") else "" end' 2>/dev/null)"
  pref="$(printf '%s' "$rec"          | jq -r 'if type=="object" then (.project_ref // "") else "" end' 2>/dev/null)"
  preset="$(printf '%s' "$rec"        | jq -r 'if type=="object" then (.preset // "") else "" end' 2>/dev/null)"
  submitted_at="$(printf '%s' "$rec"  | jq -r 'if type=="object" then (.submitted_at // "") else "" end' 2>/dev/null)"
  gave_up="$(printf '%s' "$rec"       | jq -r 'if type=="object" then (.gave_up // false) else false end' 2>/dev/null)"
  attempts="$(printf '%s' "$rec"      | jq -r 'if type=="object" and (.dispatch_attempts|type)=="number" then .dispatch_attempts else 0 end' 2>/dev/null)"
  [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=0

  if [[ -z "$intake_id" || -z "$idea_text" || -z "$pref" ]]; then
    declare -F log >/dev/null 2>&1 && \
      log "I3 dispatch: refuse — record missing id/idea_text/project_ref (intake_id='${intake_id:-?}' project_ref='${pref:-?}')"
    return 0
  fi

  # L3 (claude-tools-uxvl3) — a record that has already GIVEN UP is terminal:
  # `intake-pending` still returns it (processed stays false) but the dispatch
  # loop must NOT re-spawn the enricher (that is the silent-retry leak this
  # whole change closes). Skip silently — the `gave_up` state is already on the
  # phone; re-logging it every ~30s cadence would just spam the daemon log.
  if [[ "$gave_up" == "true" ]]; then
    return 0
  fi

  hash="$(daemon_intake_idea_hash "$idea_text")"

  # Look up the workspace + per-workspace coordinator binding by project_ref.
  ws=""
  idx=-1
  i=0
  while [[ "$i" -lt "${#REGISTRY_PROJECT_REFS[@]}" ]]; do
    if [[ "${REGISTRY_PROJECT_REFS[$i]:-}" == "$pref" ]]; then
      ws="${REGISTRY_DIRS[$i]:-}"
      idx="$i"
      break
    fi
    i=$((i + 1))
  done

  if [[ -z "$ws" || ! -d "$ws" ]]; then
    declare -F log >/dev/null 2>&1 && \
      log "I3 dispatch: skip — unknown project_ref='$pref' for intake_id=$intake_id idea_hash=$hash (no registered workspace on this machine)"
    return 0
  fi
  curl="${REGISTRY_COORDINATOR_URLS[$idx]:-}"
  tk_item="${REGISTRY_TOKEN_KEYCHAIN_ITEMS[$idx]:-}"

  # L4 (claude-tools-uxvl4) — the `overview-request` preset BRANCHES here: it
  # makes NO bd task, so it never touches the enricher path below. Route it to a
  # dossier-builder → proactive_checkpoint timed-fyi (Blueprint refresh / FYI).
  # This is the daemon-side branch the catalog's routing:"overview-fyi" row
  # points at (test-intake-presets.sh check 10 enforces this value is handled).
  if [[ "$preset" == "$INTAKE_OVERVIEW_PRESET" ]]; then
    daemon_intake_dispatch_overview "$rec" "$ws" "$pref" "$curl" "$tk_item" \
      "$intake_id" "$idea_text" "$hash" "$attempts"
    return 0
  fi

  # Build the enricher context JSON — exactly the shape enricher.system.md
  # expects: intake_id, idea_text, project_ref, preset, submitted_at.
  ctx_file="$(mktemp 2>/dev/null)" || {
    declare -F log >/dev/null 2>&1 && \
      log "I3 dispatch: refuse — mktemp failed for intake_id=$intake_id idea_hash=$hash"
    return 0
  }
  jq -cn \
    --arg id "$intake_id" \
    --arg it "$idea_text" \
    --arg pr "$pref" \
    --arg ps "$preset" \
    --arg sa "$submitted_at" \
    '{intake_id:$id, idea_text:$it, project_ref:$pr, preset:$ps, submitted_at:$sa}' \
    > "$ctx_file" 2>/dev/null

  declare -F log >/dev/null 2>&1 && \
    log "I3 dispatch: workspace=$ws intake_id=$intake_id idea_hash=$hash preset=${preset:-<none>} project_ref=$pref"

  # L3 — count this attempt + write the in-flight `enriching` marker BEFORE we
  # spawn. The enricher (claude -p) runs synchronously here, so for its whole
  # duration the record honestly reads `dispatch_state:"enriching"` on the
  # phone. `dispatch_attempts` is incremented at the START (an attempt that the
  # daemon then crashes through still counted — it consumed a dispatch). The
  # marker write is best-effort: a telemetry-put failure must not block the
  # actual enricher work, so we log nothing and press on.
  n=$((attempts + 1))
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"
  marker="$(printf '%s' "$rec" \
              | jq -c \
                  --argjson na "$n" \
                  --arg la "$now_iso" \
                  '. + {processed:false, dispatch_attempts:$na, last_attempt_at:$la, dispatch_state:"enriching"} | del(.last_error)' \
              2>/dev/null)"
  [[ -n "$marker" ]] && \
    _daemon_intake_put_record "$ws" "$pref" "$curl" "$tk_item" "$intake_id" "$marker" >/dev/null 2>&1

  # Spawn the enricher hat. The override path wins; then the canary; then real.
  # Use `${var:-}` everywhere — a caller running under `set -u` may have
  # `unset` these between source time and call time.
  local spawner=() _override _disabled
  _override="${DAEMON_INTAKE_SPECIALIST_OVERRIDE:-}"
  _disabled="${DAEMON_INTAKE_DISABLED:-0}"
  if [[ -n "$_override" ]]; then
    if [[ ! -x "$_override" ]]; then
      declare -F log >/dev/null 2>&1 && \
        log "I3 dispatch: refuse — DAEMON_INTAKE_SPECIALIST_OVERRIDE='$_override' not executable"
      rm -f "$ctx_file" 2>/dev/null
      return 0
    fi
    spawner=("$_override")
  elif [[ "$_disabled" == "1" ]]; then
    declare -F log >/dev/null 2>&1 && \
      log "I3 dispatch: DAEMON_INTAKE_DISABLED=1 ⇒ would invoke $DAEMON_SPECIALIST_SH --kind=enricher --workspace=$ws (intake_id=$intake_id idea_hash=$hash); synthesising a stub summary so mark-processed exercises"
    # Synthesise a deterministic "created" summary so the rest of the pipeline
    # (parse bd id, mark processed, log outcome) is exercised end-to-end.
    stdout="enricher: created stub-${hash} (intake $intake_id, preset=$preset, stage=stub, prio=P2)"
    rc=0
    spawner=()  # signal to skip real invocation below
  else
    if [[ ! -x "$DAEMON_SPECIALIST_SH" ]]; then
      declare -F log >/dev/null 2>&1 && \
        log "I3 dispatch: refuse — specialist.sh missing/non-executable at $DAEMON_SPECIALIST_SH"
      rm -f "$ctx_file" 2>/dev/null
      return 0
    fi
    spawner=("$DAEMON_SPECIALIST_SH")
  fi

  if [[ "${#spawner[@]}" -gt 0 ]]; then
    # Capture stdout (the enricher's one-line summary). The shim already writes
    # the full claude stream to <workspace>/.beads/runner-logs/specialist-
    # enricher-*.jsonl, so we do NOT need to keep stderr here.
    stdout="$("${spawner[@]}" \
                --kind=enricher \
                --workspace="$ws" \
                --context-file="$ctx_file" \
                2>/dev/null)"
    rc=$?
  fi
  rm -f "$ctx_file" 2>/dev/null

  outcome="$(daemon_intake_outcome "$stdout")"
  bd_id="$(daemon_intake_parse_bd_id "$stdout")"

  if [[ "$rc" -ne 0 ]] || [[ -z "$bd_id" ]]; then
    # L3 — record the failure on the intake so the phone shows failing(n) /
    # gave-up. `n` is the attempt count written by the enriching marker above.
    # claude-tools-t956 / §9.5 #2 — a clean `enricher: error → <reason>` summary
    # surfaces the enricher's STATED reason (honest) instead of a generic
    # "unparseable"; it is still a failed dispatch (no bd id ⇒ counts to the cap).
    local err_reason
    if [[ "$rc" -ne 0 ]]; then
      reason="specialist exit=$rc"
    elif [[ "$outcome" == "error" ]]; then
      err_reason="$(daemon_intake_parse_error_reason "$stdout")"
      reason="enricher error: ${err_reason:-<no reason given>}"
    else
      reason="unparseable enricher summary (outcome=$outcome)"
    fi
    daemon_intake_mark_failed "$ws" "$pref" "$curl" "$tk_item" "$rec" "$intake_id" "$n" "$reason" \
      >/dev/null 2>&1 || true
    if [[ "$rc" -ne 0 ]]; then
      declare -F log >/dev/null 2>&1 && \
        log "I3 dispatch: FAIL — specialist exit=$rc workspace=$ws intake_id=$intake_id idea_hash=$hash attempt=$n/${INTAKE_MAX_ATTEMPTS:-3} (record left unprocessed; next cadence retries unless gave_up)"
    elif [[ "$outcome" == "error" ]]; then
      declare -F log >/dev/null 2>&1 && \
        log "I3 dispatch: FAIL — enricher self-reported error workspace=$ws intake_id=$intake_id idea_hash=$hash reason='${err_reason:-<no reason given>}' attempt=$n/${INTAKE_MAX_ATTEMPTS:-3} (record left unprocessed; next cadence retries unless gave_up)"
    else
      declare -F log >/dev/null 2>&1 && \
        log "I3 dispatch: FAIL — could not parse bd id from enricher summary workspace=$ws intake_id=$intake_id idea_hash=$hash outcome=$outcome attempt=$n/${INTAKE_MAX_ATTEMPTS:-3} (record left unprocessed; next cadence retries unless gave_up)"
    fi
    return 0
  fi

  # Build the updated record: original fields + processed:true + dispatch
  # annotations. The engine re-stamps `principal` on the put (§9.1); every
  # other field round-trips verbatim. `dispatch_state:"created"` is the terminal
  # success state the L3 phone thread renders (received→enriching→created).
  updated="$(printf '%s' "$rec" \
              | jq -c \
                  --arg bd "$bd_id" \
                  --arg oc "$outcome" \
                  --argjson na "$n" \
                  --arg pa "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")" \
                  '. + {processed:true, enricher_bd_id:$bd, enricher_outcome:$oc, processed_at:$pa,
                        dispatch_attempts:$na, dispatch_state:"created"} | del(.last_error)' \
              2>/dev/null)"
  if [[ -z "$updated" ]]; then
    declare -F log >/dev/null 2>&1 && \
      log "I3 dispatch: FAIL — could not build updated record JSON for intake_id=$intake_id"
    return 0
  fi

  if daemon_intake_mark_processed "$ws" "$pref" "$curl" "$tk_item" "$intake_id" "$updated"; then
    declare -F log >/dev/null 2>&1 && \
      log "I3 dispatch: OK — workspace=$ws intake_id=$intake_id idea_hash=$hash outcome=$outcome bd_id=$bd_id (record marked processed)"
  else
    declare -F log >/dev/null 2>&1 && \
      log "I3 dispatch: WARN — enricher produced bd_id=$bd_id but mark-processed put FAILED workspace=$ws intake_id=$intake_id idea_hash=$hash (record will be re-dispatched on next cadence — bd_id duplication risk; enricher's own dedup pass is the safety net)"
  fi
  return 0
}

# daemon_intake_poll_once
#   Single iteration: fetch pending, dispatch each. ALWAYS returns 0.
#   Called from daemon.sh's main loop on the INTAKE_POLL_INTERVAL cadence.
daemon_intake_poll_once() {
  local pending count i rec
  pending="$(daemon_intake_fetch_pending)"
  [[ -n "$pending" ]] || return 0
  count="$(printf '%s' "$pending" | jq 'if type=="array" then length else 0 end' 2>/dev/null)"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  [[ "$count" -gt 0 ]] || return 0
  declare -F log >/dev/null 2>&1 && \
    log "I3 poll: $count pending intake-request(s) to dispatch"
  i=0
  while [[ "$i" -lt "$count" ]]; do
    rec="$(printf '%s' "$pending" | jq -c --argjson i "$i" '.[$i]' 2>/dev/null)"
    daemon_intake_dispatch_one "$rec" || true
    i=$((i + 1))
  done
  return 0
}
