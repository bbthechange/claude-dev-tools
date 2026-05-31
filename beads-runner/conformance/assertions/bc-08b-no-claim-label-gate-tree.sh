#!/bin/bash
# BC-08b (FORWARD / v2) — RUNNER_NO_CLAIM_LABELS hard label gate on runner.sh.
#
# Binds: BEHAVIORAL-CONTRACT.md §3 BC-08b (claude-tools-noj / tkf / 240). The
# v1 regression rig bc-08b-no-claim-label-gate.sh proves the gate on
# run-beads-tasks.sh; this FORWARD rig proves the SAME contract on the v2
# state-machine runner after the claude-tools-v2c3 port (the coverage audit
# found the gate entirely ABSENT from runner.sh — its worst cutover-blocker:
# without it v2 auto-claims a phone-gated human fixture, the exact 240/0kr/00t
# SCAR that re-claimed a human-only bead four times in one night).
#
# TARGET — re-point $RUNNER to runner.sh; reuse the T1a harness *library*
# unchanged (same precedent as bc-09-exit0-not-success-tree.sh).
#
# v2 mechanism note: runner.sh refuses the gate in st_reconcile's candidate
# WALK (_candidate_label_gated) — it skips-not-fails PAST the gated bead and
# advances to the next workable candidate (no starvation), draining/idling only
# when EVERY candidate is gated/epic. So a gated-only queue DRAINS cleanly
# (exit 0 under the harness RUNNER_EXIT_ON_DRAIN=1) having claimed nothing —
# strictly better than v1's skip-spin, same observable contract: never claimed.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# ── default label: a `human-live-session` task is never claimed (runner.sh) ───
H_init_test bc08btree-default-label
bd_seed T1 "human-only fixture" "Brian-on-phone live session" open "human-live-session"
run_runner
_expect "BC-08b" "BC-08b" "default RUNNER_NO_CLAIM_LABELS refuses 'human-live-session' (runner.sh)"
_need "bead T1 must stay open (never claimed)"      test "$(bd_status T1)" = open
_need "no in_progress transition in audit"          bash -c '! grep -qE "^T1 in_progress" "'"$BD_AUDIT"'"'
_need "no closed transition in audit"               bash -c '! grep -qE "^T1 closed" "'"$BD_AUDIT"'"'
_need "runner must print the skip-label message"    contains "$(out)" "label 'human-live-session' present"
_need "no incident logged (skip-not-fail posture)"  bash -c '! grep -q "T1" "'"$WORKDIR"'/.beads/runner-logs/incidents.log" 2>/dev/null'
_emit
H_cleanup

# ── default label: `human-triage` (ir7 back-compat) also refused ─────────────
H_init_test bc08btree-human-triage
bd_seed T1 "ir7 child" "runner-reliability fixture" open "human-triage"
run_runner
_expect "BC-08b" "BC-08b" "default RUNNER_NO_CLAIM_LABELS refuses 'human-triage' (runner.sh)"
_need "bead T1 must stay open"                      test "$(bd_status T1)" = open
_need "no in_progress transition"                   bash -c '! grep -qE "^T1 in_progress" "'"$BD_AUDIT"'"'
_need "skip message names the matched label"        contains "$(out)" "label 'human-triage' present"
_emit
H_cleanup

# ── default label: `human-action` (claude-tools-tkf) also refused ────────────
H_init_test bc08btree-human-action
bd_seed T1 "human-action blocker" "human decision required" open "human-action"
run_runner
_expect "BC-08b" "BC-08b" "default RUNNER_NO_CLAIM_LABELS refuses 'human-action' (runner.sh)"
_need "bead T1 must stay open"                      test "$(bd_status T1)" = open
_need "no in_progress transition"                   bash -c '! grep -qE "^T1 in_progress" "'"$BD_AUDIT"'"'
_need "skip message names 'human-action'"           contains "$(out)" "label 'human-action' present"
_emit
H_cleanup

# ── env override: a project can extend the gate with extra labels ────────────
# Same comma-split / whitespace-tolerance contract as v1 (FE workspace appending
# 'backend' so a backend-impl bead is never claimed from a FE sandbox — tkf).
H_init_test bc08btree-env-override
bd_seed T1 "backend impl" "code lives in thirsty-backend" open "backend"
export RUNNER_NO_CLAIM_LABELS=" human-live-session , human-triage , human-action , backend "
run_runner
unset RUNNER_NO_CLAIM_LABELS
_expect "BC-08b" "BC-08b" "env-overridden RUNNER_NO_CLAIM_LABELS honors extra labels (comma-split, ws-tolerant) (runner.sh)"
_need "bead T1 must stay open"                      test "$(bd_status T1)" = open
_need "no in_progress transition"                   bash -c '! grep -qE "^T1 in_progress" "'"$BD_AUDIT"'"'
_need "skip message names 'backend'"                contains "$(out)" "label 'backend' present"
_emit
H_cleanup

# ── anti-regression: an UNLABELLED bead is still claimed + run normally ───────
# The gate must not block ordinary work. A clean task claims, the fake worker
# closes it (SUCCESS), the queue drains exit 0.
H_init_test bc08btree-unlabelled-claimed
bd_seed T1 "ordinary task" "do a thing" open ""
claude_plan success
run_runner
_expect "BC-08b" "BC-08b" "an unlabelled ready bead is claimed + closed normally (gate is skip-not-block) (runner.sh)"
_need "bead T1 must be closed (claimed + ran)"      test "$(bd_status T1)" = closed
_need "no skip-label message printed"               bash -c '! grep -qF "human-driven fixture" "'"$HARNESS_OUT"'/runner.out"'
_emit
H_cleanup

# ── no-starvation: a gated head must NOT starve a workable bead below it ──────
# T1 (gated) sorts ahead of T2 by id; the candidate walk skips T1 (named line)
# and claims+closes T2. This is the v1 select_workable_task posture for the
# label-skip class — the gate advances, it does not wedge the loop.
H_init_test bc08btree-no-starvation
bd_seed T1 "phone-gated fixture" "human only" open "human-live-session"
bd_seed T2 "workable task"       "do a thing"  open ""
claude_plan success
run_runner
_expect "BC-08b" "BC-51" "gated head is skipped, workable bead below it is claimed (no starvation) (runner.sh)"
_need "gated T1 stays open"                          test "$(bd_status T1)" = open
_need "workable T2 is closed (claimed past the gate)" test "$(bd_status T2)" = closed
_need "the skip names T1's gate label"               contains "$(out)" "label 'human-live-session' present"
_emit
H_cleanup
