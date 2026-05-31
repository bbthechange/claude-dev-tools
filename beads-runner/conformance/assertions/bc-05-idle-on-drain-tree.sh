#!/bin/bash
# conformance-lane: serial  (claude-tools-91pi — asserts the runner exits within a
#   fixed wall-clock bound (waited<=20) after .stop-beads; green alone but flakes
#   under the parallel lane's CPU load → quarantined to the serial lane. Do NOT
#   loosen the bound to mask load.)
# claude-tools-giu — runner stays alive on empty queue (UX §0.A), picks up
# work added later without restart, and honors .stop-beads + Coordinator
# desired=stopped within RECLAIM_POLL_INTERVAL when idle.
# TARGET: runner.sh (the rewrite). The v1 run-beads-tasks.sh shares the same
# RUNNER_EXIT_ON_DRAIN opt-in; this rig covers the rewrite path.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"

# Acceptance #1, #2: idle on drain → pick up new task → .stop-beads exits clean
H_init_test giu-idle-pickup-and-stop
unset RUNNER_EXIT_ON_DRAIN          # the new UX §0.A production default
export RECLAIM_POLL_INTERVAL=2
export CONTROL_POLL_INTERVAL=999
export HEARTBEAT_INTERVAL=999
claude_plan success

set -m
( cd "$WORKDIR" && exec bash "$RUNNER" ) > "$HARNESS_OUT/runner.out" 2>&1 &
RUNNER_PID=$!
set +m

# Drain → idle
sleep 5
idle_alive=0
if kill -0 "$RUNNER_PID" 2>/dev/null && grep -q "idling" "$HARNESS_OUT/runner.out"; then
  idle_alive=1
fi
_expect "BC-05/UX-0.A" "UX §0.A" "runner.sh idles on empty queue (does NOT exit)"
_need "process alive + 'idling' line printed" test "$idle_alive" -eq 1
_emit

# Seed a task — runner should pick it up within RECLAIM_POLL_INTERVAL
bd_seed T1 "idle-pickup-task" "."
sleep 6
picked=0
grep -q "idle-pickup-task" "$HARNESS_OUT/runner.out" && picked=1
_expect "BC-05/UX-0.A" "UX §0.A" "idle runner picks up new ready task without restart"
_need "task title appears in runner.out" test "$picked" -eq 1
_emit

# .stop-beads while idle → clean exit within ~RECLAIM_POLL_INTERVAL
# Let the task complete so we drain back to idle, then signal stop.
sleep 4
touch "$WORKDIR/.stop-beads"
waited=0
while kill -0 "$RUNNER_PID" 2>/dev/null; do
  sleep 1; waited=$((waited+1))
  if [[ $waited -gt 20 ]]; then
    kill -KILL -- -"$RUNNER_PID" 2>/dev/null || true
    break
  fi
done
wait "$RUNNER_PID" 2>/dev/null; RUN_EXIT=$?
stop_ok=0
[[ "$RUN_EXIT" -eq 0 ]] && [[ $waited -le 20 ]] && stop_ok=1
_expect "BC-05/UX-0.A" "UX §0.A" ".stop-beads from idle exits cleanly within RECLAIM_POLL_INTERVAL"
_need "exit 0 within bounded wait" test "$stop_ok" -eq 1
_emit

H_cleanup
