#!/bin/bash
# conformance-lane: serial
# claude-tools-2fkp — post-terminal SIGKILL backstop PORTED to v2 runner.sh
# (port items 4+5). A worker that emits the SDK terminal record (`type":"result"`)
# then WEDGES alive (the krxv orphan-child shape) is SIGKILLed by the watchdog
# POST_TERMINAL_GRACE seconds later; the runner recovers and drains. This is the
# safety mechanism the whole bead exists for — without it a v2 worker that hangs
# post-terminal on a run_in_background child never releases.
#
# TARGET — runner.sh (v2). The injection half (acceptance #1/#2) is the PARALLEL
# sibling bc-2fkp-close-discipline-tree.sh; this file is the timing-fragile half.
#
# SERIAL LANE (claude-tools-91pi): like bc-22/bc-35, it drives the LIVE watchdog
# and asserts a SIGKILL within a fixed wall-clock bound — it flakes under the
# parallel lane's CPU oversubscription, so it runs alone on the drained machine.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"

# Rig-local `claude`: invocation 1 emits the terminal record then wedges WITHOUT
# closing the bead (orphan-child shape) so the watchdog must SIGKILL it; the
# retry (invocation 2) succeeds so the runner recovers and the queue drains.
# RIG_BEAD (exported by the caller) is the seeded id the retry closes.
_install_rig_claude() {
  local RIG_BIN="$WORKDIR/.rigbin"
  mkdir -p "$RIG_BIN"
  cat > "$RIG_BIN/claude" <<'REC'
#!/bin/bash
set -u
for a in "$@"; do [[ "$a" == "--version" ]] && { echo "rig claude 0.0.0"; exit 0; }; done
n=$(( $(cat "$HARNESS_OUT/claude-n" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$HARNESS_OUT/claude-n"

if [[ "$n" -eq 1 ]]; then
  # Emit the SDK terminal record (so the watchdog stamps POST_TERMINAL_FILE), do
  # NOT close the bead, then wedge ALIVE past the grace. `exec` so the watchdog's
  # SIGKILL lands on this directly (a hard-wedged, contract-done worker).
  echo '{"type":"result","result":"contract done but wedged","is_error":false,"stop_reason":"end_turn"}'
  exec sleep 600
fi

# The recovery retry: a clean success that drains the queue.
echo '{"type":"assistant","message":"working"}'
echo '{"type":"tool_use","tool":"Bash"}'
[[ -n "${RIG_BEAD:-}" ]] && bd close "$RIG_BEAD" >/dev/null 2>&1
echo '{"type":"result","result":"done","is_error":false,"stop_reason":"end_turn"}'
exit 0
REC
  chmod +x "$RIG_BIN/claude"
  export PATH="$RIG_BIN:$PATH"
  # IDLE_TIMEOUT large ⇒ the idle path is silent, proving it is the POST-TERMINAL
  # backstop specifically (not the idle watchdog) that fires. Small grace so the
  # SIGKILL lands within a couple of the (HARDCODED 15s) watchdog polls.
  export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
         RECLAIM_POLL_INTERVAL=1 IDLE_TIMEOUT=99999 POST_TERMINAL_GRACE=1
}

fkp_post_terminal_kill() {
  H_init_test "2fkp-post-terminal-kill"
  export RIG_BEAD=wedge1
  _install_rig_claude
  bd_seed wedge1 "wedges after terminal record" "emits result then orphan-child hangs"
  RUN_TIMEOUT=90 run_runner

  local o; o="$(out)"
  _expect "2fkp" "td0y-port" "post-terminal backstop: SDK terminal record then wedge ⇒ stamp + SIGKILL, runner recovers"
  _need "watchdog detected the SDK terminal record"  matches "$o" "SDK terminal record detected"
  _need "post-terminal SIGKILL fired"                matches "$o" "POST-TERMINAL SIGKILL"
  _need "kill was NOT the idle path (IDLE_TIMEOUT silent)" notcontains "$o" "Killing after"
  _need "runner survived and drained exit 0"         test "${RUN_EXIT:-1}" -eq 0
  _need "bead closed on the recovery retry"          test "$(bd_status wedge1)" = closed
  _emit
  H_cleanup
}

fkp_post_terminal_kill
