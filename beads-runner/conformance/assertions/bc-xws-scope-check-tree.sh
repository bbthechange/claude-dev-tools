#!/bin/bash
# BC-08d (FORWARD / v2) — cross-workspace scope check on runner.sh.
#
# Binds: BEHAVIORAL-CONTRACT.md §3 BC-08d (claude-tools-uxg8, GAP G8) /
# UX-DESIGN-V2 §8.5 / design/cross-ws.md §2.4. A bead that references a
# CROSS-REPO id (an id belonging to a declared sibling workspace) and is not a
# tracking-only bead is FLAGGED, not silently claimed, by the wrong workspace's
# runner. The v1 regression rig bc-xws-scope-check.sh proves this on
# run-beads-tasks.sh; this FORWARD rig proves the SAME contract on the v2
# state-machine runner after the claude-tools-v2cut.1 port into _validate_workable
# (the v2c3 coverage audit found bc-xws-scope-check.sh was v1-only).
#
# v2 mechanism note: runner.sh flags in the st_reconcile candidate WALK — a
# flagged-only queue DRAINS cleanly (exit 0 under the harness RUNNER_EXIT_ON_DRAIN=1)
# having claimed nothing, strictly better than v1's skip-spin, same observable
# contract: never claimed. RUNNER_SIBLING_PREFIXES empty ⇒ a complete no-op.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# ── flagged: a cross-repo ref with no exemption is never claimed ──────────────
H_init_test bc08dtree-flag-cross-repo
bd_seed T1 "wire the cancel endpoint" "FE side of thirsty-be-12f — calls DELETE /orders/:id" open ""
export RUNNER_SIBLING_PREFIXES="thirsty-be,thirsty-fe"
run_runner
unset RUNNER_SIBLING_PREFIXES
_expect "BC-08d" "BC-08d" "cross-repo ref (no exemption) is flagged, not claimed (runner.sh)"
_need "bead T1 must stay open (never claimed)"      test "$(bd_status T1)" = open
_need "no in_progress transition in audit"          bash -c '! grep -qE "^T1 in_progress" "'"$BD_AUDIT"'"'
_need "no closed transition in audit"               bash -c '! grep -qE "^T1 closed" "'"$BD_AUDIT"'"'
_need "runner flags the cross-repo id by name"      contains "$(out)" "references cross-repo id 'thirsty-be-12f'"
_need "no incident logged (skip-not-fail posture)"  bash -c '! grep -q "T1" "'"$WORKDIR"'/.beads/runner-logs/incidents.log" 2>/dev/null'
_emit
H_cleanup

# ── exemption: a tracking-only bead may reference sibling ids ─────────────────
H_init_test bc08dtree-tracking-only-exempt
bd_seed T1 "track FE↔BE cancel rollout" "couples FE to thirsty-be-12f" open "tracking-only"
claude_plan success
export RUNNER_SIBLING_PREFIXES="thirsty-be,thirsty-fe"
run_runner
unset RUNNER_SIBLING_PREFIXES
_expect "BC-08d" "BC-08d" "tracking-only label exempts a cross-repo ref (claimed normally) (runner.sh)"
_need "runner exits cleanly on drain"               test "$RUN_EXIT" -eq 0
_need "bead T1 reached closed (claimed, not flagged)" test "$(bd_status T1)" = closed
_need "runner notes the exemption"                  contains "$(out)" "tracking-only"
_need "no 'Not claimed' refusal printed"            bash -c '! grep -qF "Not claimed" "'"$HARNESS_OUT"'/runner.out"'
_emit
H_cleanup

# ── default (single-repo): NO sibling config ⇒ the check is a complete no-op ──
H_init_test bc08dtree-default-noop
bd_seed T1 "normal local work" "implements feature, see thirsty-be-12f for context" open ""
claude_plan success
unset RUNNER_SIBLING_PREFIXES   # explicit: single-repo default
run_runner
_expect "BC-08d" "BC-08d" "no sibling config ⇒ cross-WS check is a no-op (single-repo unaffected) (runner.sh)"
_need "runner exits cleanly on drain"               test "$RUN_EXIT" -eq 0
_need "bead T1 reached closed (claimed normally)"   test "$(bd_status T1)" = closed
_need "no cross-repo flag printed"                  bash -c '! grep -qF "references cross-repo id" "'"$HARNESS_OUT"'/runner.out"'
_emit
H_cleanup

# ── anti-over-match: own-prefix refs + hyphenated prose are NOT flagged ───────
H_init_test bc08dtree-no-false-positive
bd_seed thirsty-fe-1 "read-only refactor" "follow-up to thirsty-fe-2; skip-not-fail, cross-repo notes; no real BE ref" open ""
claude_plan success
export RUNNER_SIBLING_PREFIXES="thirsty-fe,thirsty-be"
run_runner
unset RUNNER_SIBLING_PREFIXES
_expect "BC-08d" "BC-08d" "own-prefix ref + hyphenated prose are not false-positives (runner.sh)"
_need "runner exits cleanly on drain"               test "$RUN_EXIT" -eq 0
_need "bead reached closed (claimed normally)"      test "$(bd_status thirsty-fe-1)" = closed
_need "no cross-repo flag printed"                  bash -c '! grep -qF "references cross-repo id" "'"$HARNESS_OUT"'/runner.out"'
_emit
H_cleanup

# ── STARVATION (claude-tools-uxqj class): a flagged HEAD must not block work ──
# A flagged bead at ready[0] must NOT starve a workable bead below it. The fake
# `bd ready` sorts attempts-asc then id-asc, so T1 precedes T2. Seed a flagged
# head ABOVE a normal task; the walk skips T1 and claims+closes T2, leaving T1
# open. Once T2 is done only the flagged T1 remains ⇒ clean drain exit 0.
H_init_test bc08dtree-starvation-skip-continue
bd_seed T1 "BE-rooted head" "blocks the queue if we starve — owns thirsty-be-99" open ""
bd_seed T2 "workable below the head" "must still get picked up" open ""
claude_plan success
export RUNNER_SIBLING_PREFIXES="thirsty-be"
run_runner
unset RUNNER_SIBLING_PREFIXES
_expect "BC-08d" "claude-tools-uxqj" "a flagged ready[0] does NOT starve a workable bead below it (runner.sh)"
_need "workable T2 reached closed (not starved)"   test "$(bd_status T2)" = closed
_need "flagged T1 stayed open (skipped)"            test "$(bd_status T1)" = open
_need "T2 was claimed (in_progress in audit)"       grep -qE "^T2 in_progress" "$BD_AUDIT"
_need "T1 never claimed (no in_progress)"            bash -c '! grep -qE "^T1 in_progress" "'"$BD_AUDIT"'"'
_need "flag names the cross-repo id"               contains "$(out)" "references cross-repo id 'thirsty-be-99'"
_emit
H_cleanup
