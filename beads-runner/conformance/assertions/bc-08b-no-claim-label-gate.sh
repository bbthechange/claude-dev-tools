#!/bin/bash
# BC-08b — RUNNER_NO_CLAIM_LABELS hard label gate (claude-tools-noj).
# Binds: BEHAVIORAL-CONTRACT.md §3 BC-08b. Hardens the failure class proved
# by claude-tools-240 / 0kr / 00t — a closing-gate fixture whose acceptance
# REQUIRES Brian on his phone, but which the runner re-claimed four times in
# one night (06:23/06:44/08:02/08:24Z, 2026-05-22) because text/defer/priority
# are all soft signals; only a labelled refusal sticks across reloads.
# SCAR (silent-when-wrong): a runner that re-claims a human-only fixture
# burns Brian's per-dossier spend and pollutes the Inbox with TASK_NOT_CLOSED
# noise on a bead that was never meant to be touched autonomously.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

# ── default label: a `human-live-session` task is never claimed ──────────────
# Seed ONE task carrying the default gate label. With no other ready work the
# runner will iterate the bd-ready snapshot, hit validate_task, skip, and
# loop. We expect: no status transition (bead stays open the whole run), the
# skip message in the output, and no incident logged (skip-not-fail posture
# matches BC-06/07/08). Backstop the runner at 5s so we don't sit in the hot
# loop forever — the assertion is on what happened DURING those 5s, not on
# clean exit.
H_init_test bc08b-default-label
bd_seed T1 "human-only fixture" "Brian-on-phone live session" open "human-live-session"
unset RUNNER_EXIT_ON_DRAIN   # the gated task is ALWAYS ready ⇒ never drains
RUN_TIMEOUT=5 run_runner
_expect "BC-08b" "BC-08b" "default RUNNER_NO_CLAIM_LABELS refuses 'human-live-session'"
_need "bead T1 must stay open (never claimed)"      test "$(bd_status T1)" = open
_need "no in_progress transition in audit"          bash -c '! grep -qE "^T1 in_progress" "'"$BD_AUDIT"'"'
_need "no closed transition in audit"               bash -c '! grep -qE "^T1 closed" "'"$BD_AUDIT"'"'
_need "runner must print the skip-label message"    contains "$(out)" "label 'human-live-session' present"
_need "no incident logged (skip-not-fail posture)"  bash -c '! grep -q "T1" "'"$WORKDIR"'/.beads/runner-logs/incidents.log" 2>/dev/null'
_emit
H_cleanup

# ── default label: `human-triage` (ir7 back-compat) also refused ─────────────
# av7/ir7 use `human-triage` to mark deferred runner-reliability fixtures. The
# gate must honor it so a future ir7 child that loses its defer date doesn't
# get auto-claimed. Same skip-not-fail posture.
H_init_test bc08b-human-triage
bd_seed T1 "ir7 child" "runner-reliability fixture" open "human-triage"
unset RUNNER_EXIT_ON_DRAIN
RUN_TIMEOUT=5 run_runner
_expect "BC-08b" "BC-08b" "default RUNNER_NO_CLAIM_LABELS refuses 'human-triage'"
_need "bead T1 must stay open"                      test "$(bd_status T1)" = open
_need "no in_progress transition"                   bash -c '! grep -qE "^T1 in_progress" "'"$BD_AUDIT"'"'
_need "skip message names the matched label"        contains "$(out)" "label 'human-triage' present"
_emit
H_cleanup

# ── env override: a project can extend the gate with extra labels ────────────
# RUNNER_NO_CLAIM_LABELS is comma-separated and overridable. A project that
# adds e.g. 'human-action' (the tkf failure class) gets it honored without
# editing the runner. Whitespace around commas is tolerated.
H_init_test bc08b-env-override
bd_seed T1 "human-action only" "label requested via project env" open "human-action"
export RUNNER_NO_CLAIM_LABELS=" human-live-session , human-action , human-triage "
unset RUNNER_EXIT_ON_DRAIN
RUN_TIMEOUT=5 run_runner
_expect "BC-08b" "BC-08b" "env-overridden RUNNER_NO_CLAIM_LABELS honors extra labels (comma-split, whitespace-tolerant)"
_need "bead T1 must stay open"                      test "$(bd_status T1)" = open
_need "no in_progress transition"                   bash -c '! grep -qE "^T1 in_progress" "'"$BD_AUDIT"'"'
_need "skip message names 'human-action'"           contains "$(out)" "label 'human-action' present"
unset RUNNER_NO_CLAIM_LABELS
_emit
H_cleanup

# ── happy path: an unlabelled task is still claimed normally ─────────────────
# Anti-regression: the gate must not affect tasks that lack the gating labels.
# A task with NO labels (or with a non-gating label) goes through validate_task
# and is claimed/closed by the normal flow. RUNNER_EXIT_ON_DRAIN restored so
# the runner drains and exits 0 once T1 closes.
H_init_test bc08b-happy-path
bd_seed T1 "normal work" "do a thing" open ""
claude_plan success
export RUNNER_EXIT_ON_DRAIN=1
run_runner
_expect "BC-08b" "BC-08b" "unlabelled task bypasses the gate and runs normally"
_need "runner exits cleanly on drain"               test "$RUN_EXIT" -eq 0
_need "bead T1 reached closed"                      test "$(bd_status T1)" = closed
_need "no skip-label message printed"               bash -c '! grep -qF "RUNNER_NO_CLAIM_LABELS" "'"$HARNESS_OUT"'/runner.out"'
_emit
H_cleanup
