#!/bin/bash
# BC-36 (FORWARD) — the cleanup-ASYMMETRY hazard is CONSCIOUSLY RESOLVED:
#   runner_cleanup runs SYMMETRICALLY on EVERY exit path (normal completion AND
#   signal), and NO exit path strands the in-flight task `in_progress`. (T2.4,
#   claude-tools-7hx.)
# Binds: INTERFACE.md v1 §8.1 (exit-code table — FROZEN) · BC-36 (the
#        characterized v1 hazard: NO `EXIT` trap ⇒ runner_cleanup ran on
#        INT/TERM+fatal but NOT on normal completion, and an unguarded `set -e`
#        abort stranded `in_progress`) · BC-35 (interrupt reset-to-open).
#
# TARGET — the conscious BC-36 decision is THIS child's owned surface in the
# forward rewrite target runner.sh. v1's documented behavior (cleanup NOT run
# on normal completion) is the SCAR being inverted: the rewrite MUST run it on
# ALL paths. Same re-point precedent as bc-22-watchdog-tree.sh; the broader
# BC-37 config seam is NOT exercised — only the runner_cleanup hook the BC-36
# symmetry decision invokes (sourced from `.beads/runner.sh`, already T2.1
# behavior).
#
# This is the directly-observable proof of EXIT criterion 2 (no exit path —
# normal, signal — strands a task; the BC-36 asymmetry is resolved): a noisy
# project `runner_cleanup` MUST fire on BOTH the clean-drain path (v1 did NOT)
# and the signal path, and the signal path MUST reset the in-flight bead.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"

# A project `.beads/runner.sh` defining a NOISY runner_cleanup. runner.sh
# defines the no-op default BEFORE sourcing this, so this override wins.
_seed_cleanup_hook() {
  printf 'runner_cleanup() { echo "RUNNER_CLEANUP_RAN"; }\n' > "$WORKDIR/.beads/runner.sh"
}

# ── A · NORMAL completion ⇒ runner_cleanup STILL runs (the v1 asymmetry,
#        consciously inverted) and nothing is stranded ───────────────────────
bc36_normal() {
  H_init_test "bc36tree-normal"
  _seed_cleanup_hook
  bd_seed T1 "drains cleanly" "x"
  claude_plan success
  export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
         RECLAIM_POLL_INTERVAL=1
  RUN_TIMEOUT=40 run_runner

  local o; o="$(out)"
  _expect "BC-36" "§8.1" "runner_cleanup runs on NORMAL completion (v1 did NOT — asymmetry consciously resolved)"
  _need "drained exit 0 (BC-21 §8.1, FROZEN)"            test "${RUN_EXIT:-1}" -eq 0
  _need "runner_cleanup RAN on the clean path"           contains "$o" "RUNNER_CLEANUP_RAN"
  _need "T1 closed (clean success)"                      test "$(bd_status T1)" = closed
  _need "no spurious reset on the clean path"            notcontains "$o" "Interrupted — resetting"
  _need "results line printed (symmetric teardown)"      contains "$o" "Results:"
  _emit
  H_cleanup
}

# ── B · SIGNAL mid-task ⇒ runner_cleanup ALSO runs, task reset to open, exit 1
#        (the SAME symmetric funnel; NO exit path strands) ──────────────────
bc36_signal() {
  H_init_test "bc36tree-signal"
  _seed_cleanup_hook
  bd_seed T1 "in flight" "x"
  claude_plan hang
  export HARNESS_HANG_SECONDS=60
  export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
         RECLAIM_POLL_INTERVAL=1
  run_runner_bg
  if ! wait_audit '^T1 in_progress' 20; then
    _expect "BC-36" "§8.1" "signal path: cleanup symmetric + no strand (runner.sh)"
    _need "task should have started before signalling" false
    _emit; kill -KILL "$RUNNER_PID" 2>/dev/null; H_cleanup; return
  fi
  sleep 1
  kill -TERM "$RUNNER_PID" 2>/dev/null
  wait_runner_exit 20

  local o last; o="$(out)"
  last="$(awk -v id=T1 '$1==id{v=$2} END{print v}' "$BD_AUDIT")"
  _expect "BC-36" "§8.1" "signal path runs the SAME symmetric teardown: cleanup + reset-to-open + exit 1"
  _need "runner exit code 1 (BC-21 §8.1 row 1, FROZEN)"  test "$RUN_EXIT" -eq 1
  _need "runner_cleanup RAN on the signal path too"      contains "$o" "RUNNER_CLEANUP_RAN"
  _need "in-flight T1 reset to open (BC-35)"             test "$last" = open
  _need "T1 NOT stranded in_progress (no exit path strands)" test "$last" != in_progress
  _need "interrupt reset message printed"               contains "$o" "Interrupted — resetting T1 to open"
  _emit
  H_cleanup
}

bc36_normal
bc36_signal
