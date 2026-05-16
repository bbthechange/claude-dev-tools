#!/bin/bash
# BC-35 (FORWARD) — SIGINT/SIGTERM/SIGHUP mid-task resets the in-flight task to
#         `open` and exits 1; it is NOT stranded `in_progress`. (T2.4,
#         claude-tools-7hx.)
# Binds: INTERFACE.md v1 §8.1 (exit 1 = SIGINT/SIGTERM row — FROZEN) and §6.1
#        (lease release maps the bead back to open — same SCAR transition).
#
# TARGET — the T2.4 teardown lives in the forward rewrite target runner.sh, NOT
# v1 run-beads-tasks.sh (the untouched bc-35-interrupt-cleanup.sh keeps v1
# regression-green). Same re-point pattern as bc-22-watchdog-tree.sh /
# bc-01-fresh-process.sh: reuse the T1a harness *library*, reassign $RUNNER
# only, zero edits to harness.sh or any T1a-owned rig.
#
# SCAR being asserted (silent-when-wrong): Ctrl-C stranding the active task as
# a phantom `in_progress` later masquerades as a crash orphan / vanishes from
# `bd ready`. T2.4 routes the signal path through the ONE symmetric EXIT-trap
# teardown funnel; this asserts the BC-35 observable on BOTH INT and TERM.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"

interrupt_case() {
  local sig="$1"
  H_init_test "bc35tree-$sig"
  bd_seed T1 "in flight" "x"
  claude_plan hang                       # fake-bin claude `hang` = exec sleep
  export HARNESS_HANG_SECONDS=60
  # Fast cadence; watchdog silent (IDLE_TIMEOUT default 99999 from H_init_test)
  # so the ONLY thing that can end the task is our signal.
  export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
         RECLAIM_POLL_INTERVAL=1
  run_runner_bg
  if ! wait_audit '^T1 in_progress' 20; then
    _expect "BC-35" "§8.1" "$sig mid-task ⇒ reset to open + exit 1 (runner.sh)"
    _need "task should have started (in_progress) before signalling" false
    _emit; kill -KILL "$RUNNER_PID" 2>/dev/null; H_cleanup; return
  fi
  sleep 1
  kill "-$sig" "$RUNNER_PID" 2>/dev/null
  wait_runner_exit 20

  local last
  last="$(awk -v id=T1 '$1==id{v=$2} END{print v}' "$BD_AUDIT")"
  _expect "BC-35" "§8.1" "$sig mid-task ⇒ reset in-flight task to open + exit 1 (runner.sh)"
  _need "runner exit code 1 (BC-21 §8.1 row 1, FROZEN)"  test "$RUN_EXIT" -eq 1
  _need "interrupt reset message printed"                contains "$(out)" "Interrupted — resetting T1 to open"
  _need "T1 released to open (NOT stranded in_progress)"  test "$last" = open
  _need "T1 never left stranded in_progress"             test "$last" != in_progress
  _need "results line printed on cleanup"                contains "$(out)" "Results:"
  _emit
  H_cleanup
}

# TERM/INT are the BC-35 SCAR signals; HUP is the contract's named
# parent-death path (a controlling-process hangup) — T2.4 traps it through the
# SAME symmetric funnel so parent death also resets-to-open and never strands.
interrupt_case TERM
interrupt_case INT
interrupt_case HUP
