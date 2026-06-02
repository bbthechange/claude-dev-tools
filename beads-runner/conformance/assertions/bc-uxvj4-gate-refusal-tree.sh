#!/bin/bash
# uxvj4 (FORWARD / v2) — runner refuses a gate:<id> Gate label on pickup.
#
# Binds: design/gates.md §5 (J4 runner-respect) + §5.3 (the mandatory BC
# assertion) + BEHAVIORAL-CONTRACT.md BC-08c (now written; this is its rig). A Gate is our native
# hold: the bare `gate:<id>` bd label, GUI/agent add-and-lift-able, that the
# runner must respect ("the runner respects them" — Brian B8). Authored HERE as
# part of the claude-tools-v2c3 green bar (the conformance cutover gate), and
# implemented in runner.sh _candidate_label_gated alongside the BC-08b human-*
# gate (one hoisted `bd label list`, both gates).
#
# SCAR (silent-when-wrong): a runner that auto-claims a gated bead defeats the
# Gate — the same per-dossier-spend / Inbox-noise burn the bc-08b header
# documents, applied to Gates (gates.md §5.3).
#
# TARGET — re-point $RUNNER to runner.sh (the same precedent as the other
# -tree rigs). The gate:* rule is a PREFIX match (ids are dynamic) and is
# ALWAYS-ON, independent of RUNNER_NO_CLAIM_LABELS.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# ── a gate:<id>-labelled task is never claimed ───────────────────────────────
H_init_test uxvj4-gate-refused
bd_seed T1 "gated work" "held behind the audio-redesign gate" open "gate:audio-redesign"
run_runner
_expect "uxvj4" "gates.md§5" "runner refuses a gate:<id>-labelled ready task (runner.sh)"
_need "bead T1 must stay open (never claimed)"      test "$(bd_status T1)" = open
_need "no in_progress transition"                   bash -c '! grep -qE "^T1 in_progress" "'"$BD_AUDIT"'"'
_need "no closed transition"                        bash -c '! grep -qE "^T1 closed" "'"$BD_AUDIT"'"'
_need "skip message names the matched gate label"   contains "$(out)" "gate label 'gate:audio-redesign' present"
_need "no incident logged (skip-not-fail)"          bash -c '! grep -q "T1" "'"$WORKDIR"'/.beads/runner-logs/incidents.log" 2>/dev/null'
_emit
H_cleanup

# ── ALWAYS-ON: the gate is refused even when RUNNER_NO_CLAIM_LABELS is empty ──
# The load-bearing correctness point (gates.md §5.2): the Gate rule must NOT be
# coupled to the human-* list — reading a noj-block-scoped label var would
# silently no-op the gate when RUNNER_NO_CLAIM_LABELS="". _candidate_label_gated
# evaluates the gate:* rule unconditionally, first.
H_init_test uxvj4-gate-always-on
bd_seed T1 "gated work" "held" open "gate:db-migration"
export RUNNER_NO_CLAIM_LABELS=""
run_runner
unset RUNNER_NO_CLAIM_LABELS
_expect "uxvj4" "gates.md§5.2" "gate:* refusal is ALWAYS-ON (independent of RUNNER_NO_CLAIM_LABELS) (runner.sh)"
_need "bead T1 must stay open"                      test "$(bd_status T1)" = open
_need "no in_progress transition"                   bash -c '! grep -qE "^T1 in_progress" "'"$BD_AUDIT"'"'
_need "skip message names the gate label"           contains "$(out)" "gate label 'gate:db-migration' present"
_emit
H_cleanup

# ── anti-regression: `gateway` (and other non-gate labels) are NOT over-matched
# The ^gate:<id-shape>$ anchor must reject `gateway` — a real label a bead may
# carry — so the prefix rule does not falsely refuse ordinary work.
H_init_test uxvj4-no-overmatch
bd_seed T1 "gateway service work" "label happens to start with 'gate'" open "gateway"
claude_plan success
run_runner
_expect "uxvj4" "gates.md§5.3" "the ^gate: anchor does NOT over-match 'gateway' — claimed normally (runner.sh)"
_need "bead T1 is closed (claimed + ran, not gated)" test "$(bd_status T1)" = closed
_need "no gate-skip message printed"                 bash -c '! grep -qF "runner respects Gates" "'"$HARNESS_OUT"'/runner.out"'
_emit
H_cleanup

# ── no-starvation: a gated head must not starve a workable bead below it ──────
H_init_test uxvj4-no-starvation
bd_seed T1 "gated work"    "held behind a gate" open "gate:audio-redesign"
bd_seed T2 "workable task" "do a thing"         open ""
claude_plan success
run_runner
_expect "uxvj4" "BC-51" "gated head skipped, workable bead below it claimed (no starvation) (runner.sh)"
_need "gated T1 stays open"                          test "$(bd_status T1)" = open
_need "workable T2 is closed (claimed past the gate)" test "$(bd_status T2)" = closed
_need "the skip names T1's gate label"               contains "$(out)" "gate label 'gate:audio-redesign' present"
_emit
H_cleanup
