#!/bin/bash
# claude-tools-2fkp — close-discipline hook (--settings injection) PORTED to the
# v2 runner.sh (BC-21 state machine). The td0y hook was scoped to v1
# run-beads-tasks.sh only; this rig proves the v2 worker now receives the same
# enforcement seam: it is spawned WITH `--settings <file>`, the file holds the
# shared PreToolUse(Bash)+Stop shape pointed at close-checklist.sh, the
# BEADS_RUNNER_SESSION=1 + POST_TERMINAL_FILE env are present, and the
# current-task pointer is written at claim. (Acceptance #1/#2.)
#
# TARGET — runner.sh (v2), same re-point pattern as bc-22-watchdog-tree.sh:
# reuse the T1a harness LIBRARY, reassign $RUNNER only, ship a rig-local `claude`
# that records what the worker was actually spawned with.
#
# PARALLEL lane (default): this rig only runs a normal task to a clean drain and
# inspects the spawn — no mid-task signal, no fixed teardown bound — so it is NOT
# timing-fragile (same stance as bc-38-worker-prompt). The post-terminal SIGKILL
# (port items 4+5) is the timing-fragile half and lives in the SERIAL sibling
# bc-2fkp-post-terminal-kill-tree.sh.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"

# Rig-local `claude` recorder. RIG_BEAD (exported by the caller) is the seeded id
# the rig closes — avoids parsing the prompt.
_install_rig_claude() {
  local RIG_BIN="$WORKDIR/.rigbin"
  mkdir -p "$RIG_BIN"
  cat > "$RIG_BIN/claude" <<'REC'
#!/bin/bash
set -u
for a in "$@"; do [[ "$a" == "--version" ]] && { echo "rig claude 0.0.0"; exit 0; }; done

# Record argv + the close-discipline env + the injected --settings file + the
# current-task pointer (all written BEFORE this spawn, so they are observable
# here even though the runner cleans the per-task ephemera at task-end).
printf '%s\n' "$@" > "$HARNESS_OUT/last-argv.txt" 2>/dev/null || true
{ echo "BEADS_RUNNER_SESSION=${BEADS_RUNNER_SESSION:-<unset>}"
  echo "POST_TERMINAL_FILE=${POST_TERMINAL_FILE:-<unset>}"
} > "$HARNESS_OUT/last-env.txt" 2>/dev/null || true
sfile=""; prev=""
for a in "$@"; do [[ "$prev" == "--settings" ]] && { sfile="$a"; break; }; prev="$a"; done
[[ -n "$sfile" && -f "$sfile" ]] && cp "$sfile" "$HARNESS_OUT/last-settings.json" 2>/dev/null || true
cp ".beads/runner-logs/current-task" "$HARNESS_OUT/last-current-task.txt" 2>/dev/null || true

# A clean success that drains the queue.
echo '{"type":"assistant","message":"working"}'
echo '{"type":"tool_use","tool":"Bash"}'
[[ -n "${RIG_BEAD:-}" ]] && bd close "$RIG_BEAD" >/dev/null 2>&1
echo '{"type":"result","result":"done","is_error":false,"stop_reason":"end_turn"}'
exit 0
REC
  chmod +x "$RIG_BIN/claude"
  export PATH="$RIG_BIN:$PATH"
  # §2.5 control/heartbeat boundaries pushed far away (irrelevant here); the idle
  # watchdog is silenced so it can't interfere with a clean drain.
  export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
         RECLAIM_POLL_INTERVAL=1 IDLE_TIMEOUT=99999
}

fkp_injection() {
  H_init_test "2fkp-injection"
  export RIG_BEAD=inj1
  _install_rig_claude
  bd_seed inj1 "needs close discipline" "a normal task that closes cleanly"
  RUN_TIMEOUT=45 run_runner

  local argv env settings ctask
  argv="$(cat "$HARNESS_OUT/last-argv.txt" 2>/dev/null || true)"
  env="$(cat "$HARNESS_OUT/last-env.txt" 2>/dev/null || true)"
  settings="$(cat "$HARNESS_OUT/last-settings.json" 2>/dev/null || true)"
  ctask="$(cat "$HARNESS_OUT/last-current-task.txt" 2>/dev/null || true)"

  _expect "2fkp" "td0y-port" "v2 worker is spawned with --settings injecting the close-discipline hook"
  _need "worker argv carries --settings"          contains "$argv" "--settings"
  _need "the injected settings file existed at spawn (rig captured it)" \
        test -s "$HARNESS_OUT/last-settings.json"
  _need "settings wires a PreToolUse Bash matcher" contains "$settings" '"matcher": "Bash"'
  _need "settings wires a Stop hook"               contains "$settings" '"Stop"'
  _need "settings points at close-checklist.sh"    contains "$settings" "close-checklist.sh"
  _emit

  _expect "2fkp" "td0y-port" "v2 worker env gates the hook + carries the post-terminal stamp path"
  _need "BEADS_RUNNER_SESSION=1 in worker env"      contains "$env" "BEADS_RUNNER_SESSION=1"
  _need "POST_TERMINAL_FILE set in worker env"      notcontains "$env" "POST_TERMINAL_FILE=<unset>"
  _emit

  _expect "2fkp" "td0y-port" "current-task pointer written at claim (hook env-fallback) + task drains clean"
  _need "current-task pointer holds the claimed bead id" test "$ctask" = inj1
  _need "bead closed (clean success)"               test "$(bd_status inj1)" = closed
  _need "runner drained exit 0"                     test "${RUN_EXIT:-1}" -eq 0
  _emit
  H_cleanup
}

fkp_injection
