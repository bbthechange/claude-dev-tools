# shellcheck shell=bash
# beads-runner/daemon/agent-action-poll.sh — I4 (claude-tools-uxvi4) the
# daemon-side EXECUTOR for the control-plane `agent-action` queue
# (design/agent-action.md §4; epic claude-tools-mhcp).
#
# WHAT THIS IS
#   The host-side reconciler for the transient `agent_actions` command queue.
#   The web tier holds NO host access (Local==remote): it can only POST an
#   `agent-action` intent into the engine. This poller is the daemon that reads
#   those pending intents out-of-band and performs the actual host effect —
#   identical in shape to how desired-state-poll.sh reconciles `set-desired`.
#   For each registered workspace, every AGENT_ACTION_POLL_INTERVAL we hit the
#   engine's `agent-action-pending <project_ref>` op, dispatch each pending
#   action on its §3 intent, and `agent-action-ack` the outcome.
#
# THE TWO HOST MECHANISMS (§3 / §4)
#   • PROCESS intents (nudge / kill-retry / kill-gate's kill): the daemon does
#     NOT signal the worker itself (that would race the runner's bookkeeping and
#     blunt-kill its tail/heartbeat subshells). It drops a CONTROL MARKER in
#     <ws>/.beads/runner-logs/agent-action/<action_id>.json; the runner's
#     watchdog — the always-alive subshell that OWNS CLAUDE_PID and already does
#     the staged SIGINT→SIGKILL — reads the marker each tick and performs the
#     signal (the runner-side honor is I4's runner seam, runner.sh).
#   • LABEL intents (gate-apply / gate-lift / kill-gate's gate): the daemon runs
#     gate-defer.sh apply/lift in $ws itself (the work-control precedent). No
#     runner involvement — gate-defer mutates `bd` directly. kill-gate applies
#     the gate FIRST (synchronously) THEN drops the kill marker, so J4's
#     `gate:*` pickup-refusal blocks re-dispatch with NO race (§3).
#
# AT-MOST-ONCE (§4, the work-control local-marker precedent)
#   The non-idempotent process intents must never double-fire across a daemon
#   restart. The daemon writes a per-action_id LOCAL marker the instant it
#   handles an action and SKIPS the host effect for any action_id it has already
#   marked (re-acking only, so a missed ack still lands). The irreversible step
#   (the kill control-marker) is preceded by the local marker: if the daemon
#   dies in the gap the action is LOST, not DOUBLED — the user re-taps. (The
#   marker write is best-effort; on the rare disk-full/permission edge where BOTH
#   the marker write AND the engine ack fail, a re-poll could re-drop the kill
#   marker — but the runner-side `mbead != current_bead` stale-check absorbs that:
#   a re-dropped marker for a worker that already moved on is consumed without effect.)
#   The gate intents are naturally idempotent (a label add/remove twice is a no-op).
#
# WEDGED ≠ STUCK (§4): this path serves the common case (worker stuck, watchdog
#   alive). A truly WEDGED runner (the watchdog subshell itself dead) cannot read
#   the marker — that escalates to the existing set-desired=stopped + respawn
#   lifecycle (desired-state-poll.sh), NOT agent-action.
#
# DISCIPLINE: ALWAYS returns 0 — a per-action failure must not abort the sweep
#   (the daemon's standing posture). Subshell-isolated per workspace (the
#   desired-state-poll.sh idiom) so env/token from workspace A never leaks to B.

# Resolve sibling paths at source time (matches desired-state-poll.sh).
DAEMON_REPO_DIR="${DAEMON_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}"
DAEMON_REPO_LIB_DIR="${DAEMON_REPO_LIB_DIR:-$DAEMON_REPO_DIR/lib}"
DAEMON_GATE_DEFER="${DAEMON_GATE_DEFER:-$DAEMON_REPO_DIR/gate-defer.sh}"

# The local at-most-once marker dir (the work-control-published precedent) —
# OUTSIDE any workspace, keyed on action_id. Default under the daemon cache.
DAEMON_CACHE_DIR="${DAEMON_CACHE_DIR:-$HOME/.cache/claude-tools}"
DAEMON_AA_DONE_DIR="${DAEMON_AA_DONE_DIR:-$DAEMON_CACHE_DIR/agent-action-handled}"

# Test/canary hook: set DAEMON_AGENT_ACTION_DISABLED=1 to dispatch-decide + ack
# WITHOUT performing the real host effect (no marker drop, no gate-defer). The
# acceptance test exercises real effects against a temp workspace; this is the
# wiring-only escape hatch the daemon main-loop tick can use during bring-up.
DAEMON_AGENT_ACTION_DISABLED="${DAEMON_AGENT_ACTION_DISABLED:-0}"

# daemon_aa__safe_key <s> — filename-safe slug (the work-control daemon_wc__safe_key
# shape): non-empty, closed charset, no traversal. action_ids are engine-minted
# UUIDs so this is belt-and-braces.
daemon_aa__safe_key() {
  local s="${1:-}"
  s="${s//[^A-Za-z0-9._-]/_}"
  printf '%s' "${s:-_}"
}

# daemon_aa_control_marker_dir <ws> → the runner-honored control-marker dir.
daemon_aa_control_marker_dir() {
  local ws="${1:-}"
  [[ -n "$ws" ]] || return 0
  printf '%s/.beads/runner-logs/agent-action' "$ws"
}

# daemon_aa_local_marker <action_id> → the daemon's at-most-once handled marker.
daemon_aa_local_marker() {
  local aid="${1:-}"
  [[ -n "$aid" ]] || return 0
  printf '%s/%s.json' "$DAEMON_AA_DONE_DIR" "$(daemon_aa__safe_key "$aid")"
}

# daemon_aa_already_handled <action_id> — true (0) iff the local marker exists.
daemon_aa_already_handled() {
  local mf
  mf="$(daemon_aa_local_marker "$1")"
  [[ -n "$mf" && -f "$mf" ]]
}

# daemon_aa_mark_handled <action_id> <intent> <workspace> — write the at-most-once
# marker. Best-effort (rc 0 even on failure — a missing marker only risks a
# re-do, never a crash).
daemon_aa_mark_handled() {
  local aid="${1:-}" intent="${2:-}" ws="${3:-}" mf tmp ts
  mf="$(daemon_aa_local_marker "$aid")"
  [[ -n "$mf" ]] || return 0
  mkdir -p "$DAEMON_AA_DONE_DIR" 2>/dev/null || return 0
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"
  tmp="$mf.$$.tmp"
  if jq -cn --arg a "$aid" --arg i "$intent" --arg w "$ws" --arg ts "$ts" \
        '{action_id:$a, intent:$i, workspace:$w, handled_at:$ts}' \
        > "$tmp" 2>/dev/null && mv -f "$tmp" "$mf" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 0
}

# daemon_aa_drop_control_marker <ws> <action_id> <intent> <bead_ref> <reason>
#   Write the runner-honored control marker. The runner's watchdog consumes it.
#   Returns 0 on write, 1 on failure (caller acks 'failed').
daemon_aa_drop_control_marker() {
  local ws="${1:-}" aid="${2:-}" intent="${3:-}" bead="${4:-}" reason="${5:-}"
  local dir mf tmp ts
  dir="$(daemon_aa_control_marker_dir "$ws")"
  [[ -n "$dir" && -n "$aid" ]] || return 1
  mkdir -p "$dir" 2>/dev/null || return 1
  # Self-gitignore the runner-logs subdir defensively (raw control state must
  # never reach git) — the runner already self-gitignores runner-logs/, this is
  # belt-and-braces for the agent-action subdir the daemon creates.
  [[ -f "$ws/.beads/runner-logs/.gitignore" ]] || \
    printf '*\n!.gitignore\n' > "$ws/.beads/runner-logs/.gitignore" 2>/dev/null || true
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"
  mf="$dir/$(daemon_aa__safe_key "$aid").json"
  tmp="$mf.$$.tmp"
  if jq -cn --arg a "$aid" --arg i "$intent" --arg b "$bead" --arg r "$reason" --arg ts "$ts" \
        '{action_id:$a, intent:$i, bead_ref:$b, reason:$r, dropped_at:$ts}' \
        > "$tmp" 2>/dev/null && mv -f "$tmp" "$mf" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

# daemon_aa_gate_defer <ws> <subcmd> <args…> — run gate-defer.sh in $ws (so its
# `bd` mutates THAT workspace's beads). A thin wrapper the acceptance test can
# override to assert invocation without a real `bd`. Returns gate-defer's rc.
daemon_aa_gate_defer() {
  local ws="${1:-}"; shift || true
  [[ -n "$ws" ]] || return 1
  [[ -x "$DAEMON_GATE_DEFER" || -f "$DAEMON_GATE_DEFER" ]] || return 1
  ( cd "$ws" 2>/dev/null || exit 1
    bash "$DAEMON_GATE_DEFER" "$@" >/dev/null 2>&1 )
}

# daemon_aa_dispatch_one <ws> <action_json> → perform the host effect for ONE
# pending action. Echoes the ack status ("done"|"failed"); returns 0 always.
# Honors the at-most-once local marker. Pure dispatch — the caller does the
# engine ack. Directly unit-testable (a temp $ws + a hand-built action_json).
daemon_aa_dispatch_one() {
  local ws="${1:-}" aj="${2:-}"
  local aid intent bead gate date reason refs
  aid="$(printf '%s' "$aj"  | jq -r '.action_id // ""' 2>/dev/null)"
  intent="$(printf '%s' "$aj" | jq -r '.intent // ""' 2>/dev/null)"
  bead="$(printf '%s' "$aj"   | jq -r '.target.bead_ref // ""' 2>/dev/null)"
  gate="$(printf '%s' "$aj"   | jq -r '.target.gate_id // ""' 2>/dev/null)"
  date="$(printf '%s' "$aj"   | jq -r '.args.date // ""' 2>/dev/null)"
  reason="$(printf '%s' "$aj" | jq -r '.args.reason // ""' 2>/dev/null)"
  [[ -n "$aid" && -n "$intent" ]] || { echo "failed"; return 0; }

  # At-most-once: if we already handled this action_id, do NOT re-do the host
  # effect — just report 'done' so the (previously-missed) ack lands and the
  # action drops out of pending. Lost-not-doubled (§4).
  if daemon_aa_already_handled "$aid"; then
    echo "done"; return 0
  fi

  # Wiring-only mode: mark + report done without a real effect (bring-up hook).
  if [[ "$DAEMON_AGENT_ACTION_DISABLED" == "1" ]]; then
    daemon_aa_mark_handled "$aid" "$intent" "$ws"
    echo "done"; return 0
  fi

  case "$intent" in
    nudge|kill-retry)
      # Process intent: mark FIRST (the irreversible kill is preceded by the
      # local marker), then drop the control marker the watchdog honors.
      daemon_aa_mark_handled "$aid" "$intent" "$ws"
      if daemon_aa_drop_control_marker "$ws" "$aid" "$intent" "$bead" "$reason"; then
        echo "done"
      else
        echo "failed"
      fi
      ;;
    kill-gate)
      # Apply the gate FIRST (synchronously) so J4's pickup-refusal blocks
      # re-dispatch; THEN drop the kill marker. If the gate apply fails, do NOT
      # kill (the bead would just re-pickup ungated) — ack failed, user re-taps.
      daemon_aa_mark_handled "$aid" "$intent" "$ws"
      if [[ -z "$gate" || -z "$bead" || -z "$date" ]]; then echo "failed"; return 0; fi
      if ! daemon_aa_gate_defer "$ws" apply "$gate" "$bead" "$date"; then
        echo "failed"; return 0
      fi
      if daemon_aa_drop_control_marker "$ws" "$aid" "$intent" "$bead" "$reason"; then
        echo "done"
      else
        echo "failed"
      fi
      ;;
    gate-apply)
      # Label intent: apply the gate to the single bead OR each bead in the
      # cohort. Naturally idempotent; mark for bookkeeping symmetry.
      daemon_aa_mark_handled "$aid" "$intent" "$ws"
      if [[ -z "$gate" || -z "$date" ]]; then echo "failed"; return 0; fi
      refs="$(printf '%s' "$aj" | jq -r '(.target.bead_refs // []) | .[]?' 2>/dev/null)"
      [[ -z "$refs" && -n "$bead" ]] && refs="$bead"
      [[ -n "$refs" ]] || { echo "failed"; return 0; }
      local b any_fail=0
      while IFS= read -r b; do
        [[ -n "$b" ]] || continue
        daemon_aa_gate_defer "$ws" apply "$gate" "$b" "$date" || any_fail=1
      done <<< "$refs"
      [[ "$any_fail" -eq 0 ]] && echo "done" || echo "failed"
      ;;
    gate-lift)
      daemon_aa_mark_handled "$aid" "$intent" "$ws"
      if [[ -z "$gate" ]]; then echo "failed"; return 0; fi
      if daemon_aa_gate_defer "$ws" lift "$gate" --commit; then
        echo "done"
      else
        echo "failed"
      fi
      ;;
    *)
      echo "failed"
      ;;
  esac
  return 0
}

# _daemon_aa_poll_one <ws> <project_ref> <coord_url> <tk_item>
#   Subshell that fetches pending actions for ONE workspace, dispatches each, and
#   acks the outcome. ALWAYS exits 0. Mirrors _daemon_m3_fetch_desired_one's
#   token/transport idiom (cd $ws, Keychain bearer, source coordinator.sh +
#   co-http-transport.sh, co_request).
_daemon_aa_poll_one() {
  local ws="$1" pref="$2" curl="$3" tk_item="$4"
  (
    set +e
    cd "$ws" 2>/dev/null || exit 0
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
    . "$DAEMON_REPO_LIB_DIR/coordinator.sh" 2>/dev/null || exit 0
    # shellcheck source=/dev/null
    [[ -f "$DAEMON_REPO_LIB_DIR/co-http-transport.sh" ]] \
      && . "$DAEMON_REPO_LIB_DIR/co-http-transport.sh" 2>/dev/null
    command -v co_request >/dev/null 2>&1 || exit 0
    local bearer resp n i aj aid status
    bearer="${COORDINATOR_TOKEN:-bearer-daemon-agent-action}"
    resp="$(co_request "$bearer" agent-action-pending "$pref" 2>/dev/null)" || resp=""
    [[ -n "$resp" ]] || exit 0
    n="$(printf '%s' "$resp" | jq -r 'if type=="object" then ((.actions // []) | length) else 0 end' 2>/dev/null)" || n=0
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    i=0
    while [[ "$i" -lt "$n" ]]; do
      aj="$(printf '%s' "$resp" | jq -c ".actions[$i]" 2>/dev/null)" || aj=""
      i=$((i + 1))
      [[ -n "$aj" && "$aj" != "null" ]] || continue
      aid="$(printf '%s' "$aj" | jq -r '.action_id // ""' 2>/dev/null)"
      [[ -n "$aid" ]] || continue
      status="$(daemon_aa_dispatch_one "$ws" "$aj")"
      [[ "$status" == "done" || "$status" == "failed" ]] || status="failed"
      co_request "$bearer" agent-action-ack "$aid" "$status" \
        "$(jq -cn --arg s "$status" '{ok:($s=="done"), message:("daemon "+$s)}' 2>/dev/null)" \
        >/dev/null 2>&1 || true
    done
    exit 0
  )
  return 0
}

# daemon_agent_action_poll_once — the per-pass driver over the registry. Mirrors
# daemon_m3_reconcile_all. ALWAYS returns 0.
daemon_agent_action_poll_once() {
  local n i ws pref curl tk_item
  n="$(registry_count 2>/dev/null || echo 0)"
  [[ "$n" -gt 0 ]] 2>/dev/null || return 0
  i=0
  while [[ "$i" -lt "$n" ]]; do
    ws="${REGISTRY_DIRS[$i]:-}"
    pref="${REGISTRY_PROJECT_REFS[$i]:-}"
    curl="${REGISTRY_COORDINATOR_URLS[$i]:-}"
    tk_item="${REGISTRY_TOKEN_KEYCHAIN_ITEMS[$i]:-}"
    i=$((i + 1))
    [[ -n "$ws" && -n "$pref" ]] || continue
    _daemon_aa_poll_one "$ws" "$pref" "$curl" "$tk_item" || true
  done
  return 0
}
