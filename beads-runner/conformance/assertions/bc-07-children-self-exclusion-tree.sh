#!/bin/bash
# BC-07 (FORWARD / v2) — `bd show --children` self-inclusion is filtered on runner.sh.
#
# Binds: BEHAVIORAL-CONTRACT.md §3 BC-07. `bd show --children` INCLUDES the task
# itself in the returned list (a bd quirk); before counting children the runner
# must exclude self (`map(select(.id? != $id))`) so a LEAF task is never treated
# as its own parent. Observable only as the ABSENCE of a false "skipping parent
# task" on a childless bead. claude-tools-v2cut.1 ported the filter into
# _validate_workable; this rig proves it on the v2 state-machine runner.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# ── a childless leaf is NOT treated as its own parent ─────────────────────────
# The fake `bd show --children` returns [self] for a leaf (no children file);
# after the runner's self-exclusion that is 0 children, so the bead is workable.
# It must claim + close, and must NOT print any "skipping parent task" line.
H_init_test bc07tree-leaf-not-parent
bd_seed T1 "leaf task" "no children — bd --children still echoes self" open ""
claude_plan success
run_runner
_expect "BC-07" "BC-07" "a childless leaf is not treated as its own parent (self-exclusion) (runner.sh)"
_need "runner exits cleanly on drain"               test "$RUN_EXIT" -eq 0
_need "bead T1 reached closed (claimed + ran)"      test "$(bd_status T1)" = closed
_need "no false 'skipping parent task' printed"     bash -c '! grep -qF "skipping parent task" "'"$HARNESS_OUT"'/runner.out" 2>/dev/null'
_need "no 'Skipping parent task' (case) printed"    bash -c '! grep -qiF "skipping parent task" "'"$HARNESS_OUT"'/runner.out" 2>/dev/null'
_emit
H_cleanup

# ── a real parent's child list excludes self before counting ──────────────────
# A parent with one OPEN child must count exactly 1 child (self filtered out, the
# {<id>:[self,child]} object flattened) — proving the exclusion fires in the
# OBJECT branch too. The phantom open child T1c reads 'open' but is not itself a
# ready bead, so the parent is the only candidate ⇒ it is validated and skipped
# with a "1 of 1" message (self never inflates the count to 2).
H_init_test bc07tree-parent-excludes-self
bd_seed T1 "parent with one open child" "container" open ""
bd_set_children T1 "T1c"
run_runner
_expect "BC-07" "BC-07" "self is excluded from a parent's child count (object-flatten branch) (runner.sh)"
_need "runner exits cleanly on drain"               test "$RUN_EXIT" -eq 0
_need "parent T1 stays open (skipped, not claimed)" test "$(bd_status T1)" = open
_need "no in_progress transition in audit"          bash -c '! grep -qE "^T1 in_progress" "'"$BD_AUDIT"'"'
_need "child count excludes self (1 of 1, not 2)"   contains "$(out)" "1 of 1 children still open"
_emit
H_cleanup
