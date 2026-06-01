#!/bin/bash
# BC-51 (FORWARD / v2) — walk past an UNWORKABLE head instead of starving on runner.sh.
#
# Binds: BEHAVIORAL-CONTRACT.md §2 BC-51 (claude-tools-uxqj/dzc starvation class).
# Selection is NOT a raw `.[0]` pick — the st_reconcile candidate walk advances
# past the first candidate that fails validation and selects the first WORKABLE
# bead below it. bc-08b-no-claim-label-gate-tree.sh already proved the walk for
# the LABEL-skip class; this rig proves it for the WORKABILITY classes that
# claude-tools-v2cut.1 added to the walk via _validate_workable — a late-blocked
# head (BC-06) and a parent/container head (BC-08). Without the walk a single
# unworkable head at ready[0] starves every workable bead beneath it (39
# skip-loops / 0 builds observed live 2026-05-30).
#
# Ordering: the fake `bd ready` sorts attempts-asc then id-asc, so T1 precedes
# T2 — T1 is the unworkable HEAD, T2 the workable bead below it.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# ── a late-blocked head (BC-06) does not starve a workable bead below it ──────
# T1 is force-blocked (ready but bd-blocked); the walk skips it and claims+closes
# T2. Once T2 is done only the permanently-blocked T1 remains ⇒ clean drain exit 0.
H_init_test bc51tree-blocked-head
bd_seed T1 "blocked head" "ready snapshot stale — dep added after" open ""
bd_seed T2 "workable below the head" "must still be picked up" open ""
claude_plan success
export HARNESS_FORCE_BLOCKED=T1
run_runner
unset HARNESS_FORCE_BLOCKED
_expect "BC-51" "claude-tools-uxqj" "a blocked ready[0] does not starve a workable bead below it (runner.sh)"
_need "workable T2 reached closed (not starved)"    test "$(bd_status T2)" = closed
_need "blocked T1 stayed open (skipped)"            test "$(bd_status T1)" = open
_need "T2 was claimed (in_progress in audit)"       grep -qE "^T2 in_progress" "$BD_AUDIT"
_need "T1 never claimed (no in_progress)"            bash -c '! grep -qE "^T1 in_progress" "'"$BD_AUDIT"'"'
_need "the skip names the unresolved-deps reason"   contains "$(out)" "has unresolved dependencies"
_emit
H_cleanup

# ── a parent/container head (BC-08) does not starve a workable bead below it ──
# T1 is a parent with a still-open (phantom) child ⇒ skipped "1 of 1"; the walk
# advances to T2 and claims+closes it. T1 stays open (a parent is never run).
H_init_test bc51tree-parent-head
bd_seed T1 "parent head" "container with an open child" open ""
bd_set_children T1 "T1c"
bd_seed T2 "workable below the head" "must still be picked up" open ""
claude_plan success
run_runner
_expect "BC-51" "claude-tools-uxqj" "a parent/container ready[0] does not starve a workable bead below it (runner.sh)"
_need "workable T2 reached closed (not starved)"    test "$(bd_status T2)" = closed
_need "parent T1 stayed open (skipped, not run)"    test "$(bd_status T1)" = open
_need "T2 was claimed (in_progress in audit)"       grep -qE "^T2 in_progress" "$BD_AUDIT"
_need "T1 never claimed (no in_progress)"            bash -c '! grep -qE "^T1 in_progress" "'"$BD_AUDIT"'"'
_need "the skip names the open-children reason"     contains "$(out)" "children still open"
_emit
H_cleanup
