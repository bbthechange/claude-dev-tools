#!/bin/bash
# BC-35 — SIGINT/SIGTERM resets the in-flight task to `open` and exits 1
#         (does not strand it `in_progress`).
# Binds: INTERFACE.md v1 §8.1 (exit 1 = SIGINT/SIGTERM row) and §6.1 (lease
#        release maps the bead back to open — same SCAR transition).
# SCAR (silent-when-wrong): Ctrl-C stranding the active task as a phantom
#        `in_progress` later masquerades as a crash orphan / vanishes from
#        `bd ready`.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

interrupt_case() {
  local sig="$1"
  H_init_test "bc35-$sig"
  bd_seed T1 "in flight" "x"
  claude_plan hang                       # claude stays alive (sleeps) → task in flight
  export HARNESS_HANG_SECONDS=60
  run_runner_bg
  if ! wait_audit '^T1 in_progress' 20; then
    _expect "BC-35" "§8.1" "$sig mid-task ⇒ reset to open + exit 1"
    _need "task should have started (in_progress) before signalling" false
    _emit; kill -KILL "$RUNNER_PID" 2>/dev/null; H_cleanup; return
  fi
  sleep 1
  kill "-$sig" "$RUNNER_PID" 2>/dev/null
  wait_runner_exit 20

  local last
  last="$(awk -v id=T1 '$1==id{v=$2} END{print v}' "$BD_AUDIT")"
  _expect "BC-35" "§8.1" "$sig mid-task ⇒ reset in-flight task to open + exit 1"
  _need "runner exit code 1"                     test "$RUN_EXIT" -eq 1
  _need "interrupt reset message printed"        contains "$(out)" "Interrupted — resetting T1 to open"
  _need "T1 released to open (not stranded)"     test "$last" = open
  _need "results line printed on cleanup"        contains "$(out)" "Results:"
  _emit
  H_cleanup
}

interrupt_case TERM
interrupt_case INT
