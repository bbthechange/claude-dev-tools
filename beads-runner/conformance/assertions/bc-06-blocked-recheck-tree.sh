#!/bin/bash
# BC-06 (FORWARD / v2) — validate_task re-checks `bd blocked` on runner.sh.
#
# Binds: BEHAVIORAL-CONTRACT.md §3 BC-06. Even though a task came from
# `bd ready`, the runner re-queries `bd blocked` immediately before execution;
# if a dependency was added AFTER the ready snapshot the task is SKIPPED with no
# failure counted (no FAILED++, no retry tracking, no incident). The v2c3
# coverage audit found this TOCTOU re-check ABSENT from runner.sh (v2 picked
# `.[0]` and claimed it); claude-tools-v2cut.1 folds it into _validate_workable
# in the st_reconcile candidate walk. This rig proves the SAME contract on the
# v2 state-machine runner.
#
# Harness seam: HARNESS_FORCE_BLOCKED makes the fake `bd` report a bead as
# blocked on `bd blocked` while `bd ready` still surfaces it (the bead has no
# REAL dep) — the only way to make ready/blocked disagree within one loop, which
# is precisely the TOCTOU window BC-06 closes.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# ── late-blocked: a ready bead that bd blocked now reports is skipped-not-failed ─
# T1 is ready (no real dep) but force-blocked, so the runner's re-check sees it
# blocked and must walk past it. With nothing else claimable the queue idles
# (T1 is ALWAYS ready ⇒ never a clean drain), so back-stop at 5s and assert the
# skip-not-fail posture: open, never in_progress, named message, no incident.
H_init_test bc06tree-late-blocked
bd_seed T1 "late-blocked task" "was ready, a dep was added after the snapshot" open ""
export HARNESS_FORCE_BLOCKED=T1
unset RUNNER_EXIT_ON_DRAIN
RUN_TIMEOUT=5 run_runner
unset HARNESS_FORCE_BLOCKED
_expect "BC-06" "BC-06" "a late-blocked ready bead is skipped (TOCTOU re-check), not claimed (runner.sh)"
_need "bead T1 stays open (never claimed)"          test "$(bd_status T1)" = open
_need "no in_progress transition in audit"          bash -c '! grep -qE "^T1 in_progress" "'"$BD_AUDIT"'"'
_need "no closed transition in audit"               bash -c '! grep -qE "^T1 closed" "'"$BD_AUDIT"'"'
_need "runner names the unresolved-deps skip"       contains "$(out)" "has unresolved dependencies"
_need "no incident logged (skip-not-fail posture)"  bash -c '! grep -q "T1" "'"$WORKDIR"'/.beads/runner-logs/incidents.log" 2>/dev/null'
_emit
H_cleanup

# ── anti-regression: an UN-blocked ready bead is claimed + run normally ───────
# The re-check must not block ordinary work. With HARNESS_FORCE_BLOCKED unset
# the bead is genuinely workable: it claims, the fake worker closes it, the
# queue drains exit 0.
H_init_test bc06tree-unblocked-claimed
bd_seed T1 "ordinary task" "no deps" open ""
claude_plan success
run_runner
_expect "BC-06" "BC-06" "an unblocked ready bead is claimed + closed normally (re-check is skip-not-block) (runner.sh)"
_need "runner exits cleanly on drain"               test "$RUN_EXIT" -eq 0
_need "bead T1 reached closed (claimed + ran)"      test "$(bd_status T1)" = closed
_need "no unresolved-deps message printed"          bash -c '! grep -qF "has unresolved dependencies" "'"$HARNESS_OUT"'/runner.out"'
_emit
H_cleanup
