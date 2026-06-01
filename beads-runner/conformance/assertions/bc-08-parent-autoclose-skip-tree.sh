#!/bin/bash
# BC-08 (FORWARD / v2) — parent auto-close-if-all-children-closed-else-skip on runner.sh.
#
# Binds: BEHAVIORAL-CONTRACT.md §3 BC-08. If a task has children and ALL are
# closed, the runner auto-closes the parent (`bd close --reason="All children
# completed"`) and skips it; if some children are still open the parent is
# skipped with an "N of M children still open" message. Either way the parent is
# never executed and no failure is counted. The v2c3 coverage audit found this
# ABSENT from runner.sh; claude-tools-v2cut.1 ported it into _validate_workable.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# ── all children closed ⇒ the parent is AUTO-CLOSED (not run) ─────────────────
# Parent T1, children C1+C2 both closed (⇒ not themselves ready). T1 is the only
# ready bead; the runner validates it, sees all children closed, auto-closes it,
# and drains. The close must be the AUTO-CLOSE (a `bd close`, audited "closed")
# with NO in_progress — the parent was never claimed / handed to a worker.
H_init_test bc08tree-autoclose-all-closed
bd_seed T1 "done parent" "all children finished" open ""
bd_seed C1 "child one" "" closed ""
bd_seed C2 "child two" "" closed ""
bd_set_children T1 "C1,C2"
run_runner
_expect "BC-08" "BC-08" "all-children-closed ⇒ parent auto-closed, never run (runner.sh)"
_need "runner exits cleanly on drain"               test "$RUN_EXIT" -eq 0
_need "parent T1 reached closed (auto-closed)"      test "$(bd_status T1)" = closed
_need "T1 was NOT claimed (no in_progress)"         bash -c '! grep -qE "^T1 in_progress" "'"$BD_AUDIT"'"'
_need "runner names the auto-close (all 2 done)"    contains "$(out)" "Auto-closing parent task: all 2 children completed"
_emit
H_cleanup

# ── some children open ⇒ the parent is SKIPPED (left open, not run) ───────────
# Parent T1 with C1 closed + phantom-open child C2x (reads 'open', not itself a
# ready bead). T1 is the only candidate ⇒ validated, skipped "1 of 2", stays
# open, never claimed, no failure counted (drains exit 0 under the harness).
H_init_test bc08tree-skip-some-open
bd_seed T1 "in-flight parent" "one child still open" open ""
bd_seed C1 "child one" "" closed ""
bd_set_children T1 "C1,C2x"
run_runner
_expect "BC-08" "BC-08" "some-children-open ⇒ parent skipped (not run, not failed) (runner.sh)"
_need "runner exits cleanly on drain"               test "$RUN_EXIT" -eq 0
_need "parent T1 stays open (skipped)"              test "$(bd_status T1)" = open
_need "T1 was never claimed (no in_progress)"       bash -c '! grep -qE "^T1 in_progress" "'"$BD_AUDIT"'"'
_need "T1 was not auto-closed (no closed)"          bash -c '! grep -qE "^T1 closed" "'"$BD_AUDIT"'"'
_need "runner names the open-children skip (1 of 2)" contains "$(out)" "Skipping parent task: 1 of 2 children still open"
_need "no incident logged (skip-not-fail posture)"  bash -c '! grep -q "T1" "'"$WORKDIR"'/.beads/runner-logs/incidents.log" 2>/dev/null'
_emit
H_cleanup
