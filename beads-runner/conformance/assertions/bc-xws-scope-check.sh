#!/bin/bash
# BC-08d — cross-workspace scope check (claude-tools-uxg8, GAP G8).
# Binds: UX-DESIGN-V2.md §8.5 ("Workspace-scope check on claims") /
# design/cross-ws.md §2.4. A bead that references a CROSS-REPO id (a bead id
# belonging to a declared sibling workspace) and is not a tracking-only bead is
# FLAGGED, not silently claimed, by the wrong workspace's runner — the "why is
# there a backend task in the frontend tracking" frustration, a silent-misclaim
# hazard amplified by parallel FE/BE runners.
# SCAR (silent-when-wrong): a FE runner that silently claims a bead whose code
# lives in the BE repo burns a worker + per-dossier spend, bails with nothing
# written, and pollutes the Inbox — the exact mis-pickup §8.5 exists to stop.
# Rides the same skip-not-fail suppression the no-claim-label gate (BC-08b)
# uses; opt-in via RUNNER_SIBLING_PREFIXES (empty default ⇒ single-repo no-op).
# (BC-08c, now written, is the J4 Gate-respect sibling — gates.md §5.2.)
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

# ── flagged: a cross-repo ref with no exemption is never claimed ──────────────
# Seed ONE bead whose description references a sibling-workspace id
# (thirsty-be-12f) with the sibling list declared. With no other ready work the
# runner iterates the snapshot, hits validate_task's scope check, skips, and
# loops. Expect: no status transition (stays open), the flag message naming the
# cross-repo id, and no incident (skip-not-fail, matches BC-08b posture).
# Backstop at 5s — the flagged bead is ALWAYS ready ⇒ never drains.
H_init_test bc08d-flag-cross-repo
bd_seed T1 "wire the cancel endpoint" "FE side of thirsty-be-12f — calls DELETE /orders/:id" open ""
export RUNNER_SIBLING_PREFIXES="thirsty-be,thirsty-fe"
unset RUNNER_EXIT_ON_DRAIN   # the flagged task is ALWAYS ready ⇒ never drains
RUN_TIMEOUT=5 run_runner
_expect "BC-08d" "BC-08d" "cross-repo ref (no exemption) is flagged, not claimed"
_need "bead T1 must stay open (never claimed)"      test "$(bd_status T1)" = open
_need "no in_progress transition in audit"          bash -c '! grep -qE "^T1 in_progress" "'"$BD_AUDIT"'"'
_need "no closed transition in audit"               bash -c '! grep -qE "^T1 closed" "'"$BD_AUDIT"'"'
_need "runner flags the cross-repo id by name"      contains "$(out)" "references cross-repo id 'thirsty-be-12f'"
_need "no incident logged (skip-not-fail posture)"  bash -c '! grep -q "T1" "'"$WORKDIR"'/.beads/runner-logs/incidents.log" 2>/dev/null'
unset RUNNER_SIBLING_PREFIXES
_emit
H_cleanup

# ── exemption: a tracking-only bead may reference sibling ids ─────────────────
# A coordination / tracking bead is MEANT to reference cross-repo ids (the
# "isn't a tracking-only task" carve-out, §8.5). The 'tracking-only' label
# exempts it: the runner prints a Note and claims it normally. Anti-regression
# against the flag over-firing on legitimate cross-WS coordination beads.
H_init_test bc08d-tracking-only-exempt
bd_seed T1 "track FE↔BE cancel rollout" "couples FE to thirsty-be-12f" open "tracking-only"
claude_plan success
export RUNNER_SIBLING_PREFIXES="thirsty-be,thirsty-fe"
export RUNNER_EXIT_ON_DRAIN=1
run_runner
_expect "BC-08d" "BC-08d" "tracking-only label exempts a cross-repo ref (claimed normally)"
_need "runner exits cleanly on drain"               test "$RUN_EXIT" -eq 0
_need "bead T1 reached closed (claimed, not flagged)" test "$(bd_status T1)" = closed
_need "runner notes the exemption"                  contains "$(out)" "tracking-only"
_need "no 'Not claimed' refusal printed"            bash -c '! grep -qF "Not claimed" "'"$HARNESS_OUT"'/runner.out"'
unset RUNNER_SIBLING_PREFIXES
_emit
H_cleanup

# ── default (single-repo): NO sibling config ⇒ the check is a complete no-op ──
# THE critical anti-regression: with RUNNER_SIBLING_PREFIXES unset (the default
# for every single-repo project), a bead that happens to contain an id-shaped
# token is claimed normally. The cross-WS check must cost a single-repo runner
# nothing and never change its behaviour.
H_init_test bc08d-default-noop
bd_seed T1 "normal local work" "implements feature, see thirsty-be-12f for context" open ""
claude_plan success
unset RUNNER_SIBLING_PREFIXES   # explicit: single-repo default
export RUNNER_EXIT_ON_DRAIN=1
run_runner
_expect "BC-08d" "BC-08d" "no sibling config ⇒ cross-WS check is a no-op (single-repo unaffected)"
_need "runner exits cleanly on drain"               test "$RUN_EXIT" -eq 0
_need "bead T1 reached closed (claimed normally)"   test "$(bd_status T1)" = closed
_need "no cross-repo flag printed"                  bash -c '! grep -qF "references cross-repo id" "'"$HARNESS_OUT"'/runner.out"'
_emit
H_cleanup

# ── anti-over-match: own-prefix refs + hyphenated prose are NOT flagged ───────
# Defence against false positives. A bead in the thirsty-fe workspace that
# references its OWN prefix (thirsty-fe-2 — sibling==local is skipped) and is
# full of ordinary hyphenated prose ('read-only', 'skip-not-fail', 'cross-repo')
# must be claimed normally. The token matcher must only fire on a *declared
# sibling* prefix followed by a real id, not on English compounds.
H_init_test bc08d-no-false-positive
bd_seed thirsty-fe-1 "read-only refactor" "follow-up to thirsty-fe-2; skip-not-fail, cross-repo notes; no real BE ref" open ""
claude_plan success
export RUNNER_SIBLING_PREFIXES="thirsty-fe,thirsty-be"
export RUNNER_EXIT_ON_DRAIN=1
run_runner
_expect "BC-08d" "BC-08d" "own-prefix ref + hyphenated prose are not false-positives"
_need "runner exits cleanly on drain"               test "$RUN_EXIT" -eq 0
_need "bead reached closed (claimed normally)"      test "$(bd_status thirsty-fe-1)" = closed
_need "no cross-repo flag printed"                  bash -c '! grep -qF "references cross-repo id" "'"$HARNESS_OUT"'/runner.out"'
unset RUNNER_SIBLING_PREFIXES
_emit
H_cleanup

# ── STARVATION (claude-tools-uxqj class): a flagged HEAD must not block work ──
# Same starvation guard BC-08b proved for the label gate, applied to the
# scope check: a flagged bead at ready[0] must NOT starve a workable bead below
# it. The fake `bd ready` sorts attempts-asc then id-asc, so T1 precedes T2.
# Seed a flagged head (cross-repo ref) ABOVE a normal task and assert the runner
# walks PAST T1 and actually runs+closes T2, leaving T1 open.
H_init_test bc08d-starvation-skip-continue
bd_seed T1 "BE-rooted head" "blocks the queue if we starve — owns thirsty-be-99" open ""
bd_seed T2 "workable below the head" "must still get picked up" open ""
claude_plan success
export RUNNER_SIBLING_PREFIXES="thirsty-be"
export SKIP_BACKOFF=1          # don't sit idling on T1 after T2 drains
unset RUNNER_EXIT_ON_DRAIN     # T1 is permanently ready ⇒ never a clean drain
RUN_TIMEOUT=12 run_runner
_expect "BC-08d" "claude-tools-uxqj" "a flagged ready[0] does NOT starve a workable bead below it"
_need "workable T2 reached closed (not starved)"   test "$(bd_status T2)" = closed
_need "flagged T1 stayed open (skipped)"            test "$(bd_status T1)" = open
_need "T2 was claimed (in_progress in audit)"       grep -qE "^T2 in_progress" "$BD_AUDIT"
_need "T1 never claimed (no in_progress)"           bash -c '! grep -qE "^T1 in_progress" "'"$BD_AUDIT"'"'
_need "flag names the cross-repo id"               contains "$(out)" "references cross-repo id 'thirsty-be-99'"
unset SKIP_BACKOFF RUNNER_SIBLING_PREFIXES
_emit
H_cleanup
