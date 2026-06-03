#!/bin/bash
# conformance-lane: serial  (claude-tools-91pi — signals the LIVE runner mid-task
#   and asserts teardown within a fixed wall-clock backstop; green alone but flakes
#   under the parallel lane's CPU load → quarantined to the serial lane. Do NOT
#   loosen the harness backstop to mask load.)
# BC-35 — SIGINT/SIGTERM/SIGHUP resets the in-flight task to `open` and exits 1
#         (does not strand it `in_progress`).
# Binds: INTERFACE.md v1 §8.1 (exit 1 = SIGINT/SIGTERM row) and §6.1 (lease
#        release maps the bead back to open — same SCAR transition).
# HUP row added by claude-tools-j0r0: v1's `trap cleanup INT TERM HUP` now matches
#        v2's `trap _on_signal INT TERM HUP` (the tree assertion already covers v2
#        HUP). The harness `_spawn_runner` resets HUP→SIG_DFL (claude-tools-54ei),
#        so HUP is trappable here even though it is SIG_IGN in a detached prod
#        runner — this regression-locks the foreground/interactive parity fix.
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

# TERM/INT are the BC-35 SCAR signals; HUP is the contract's named parent-death
# path (a controlling-process hangup) — claude-tools-j0r0 added HUP to v1's trap
# list so it routes through the SAME cleanup funnel (reset-to-open + exit 1),
# matching v2. Parity with bc-35-interrupt-cleanup-tree.sh's HUP case.
interrupt_case TERM
interrupt_case INT
interrupt_case HUP
