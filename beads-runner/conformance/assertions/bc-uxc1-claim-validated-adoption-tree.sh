#!/bin/bash
# claude-tools-uxc1 — Mechanism A: PID claim files validate orphans before the
# runner adopts them (inbox-lifecycle §8.3.3, amends BEHAVIORAL-CONTRACT BC-02).
#
# THE HAZARD this closes: the startup in_progress snapshot used to adopt EVERY
# in_progress bead as "this runner's crash orphan". A task left in_progress by a
# LIVE external Claude session, by another LIVE runner in the same workspace, or by
# a manual `bd update` was therefore ADOPTED → two workers on one bead → commit
# fights. Now adoption is PID-VALIDATED via a per-task claim file the runner stamps
# at in_progress and removes on close/reset/teardown:
#   • no claim file            → in_progress set by a non-runner       → SKIP
#   • claim, OUR id, LIVE pid  → a live sibling runner owns it         → SKIP
#   • claim, FOREIGN runner_id → another workspace's runner            → SKIP (closed)
#   • claim, OUR id, DEAD pid  → our previous self crashed here        → ADOPT
#
# TARGET: runner.sh, stub backend, no daemon. `bd ready` never returns an
# in_progress bead, so any adoption is the RUNNER's startup snapshot, not bd ready.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"

# ── Acceptance #1 — the adoption matrix: of four in_progress beads at startup, ONLY
#    the one carrying our-id + dead-pid claim is adopted; the live-pid, foreign, and
#    no-claim ones are all skipped (never re-driven to in_progress, never worked). ─
H_init_test uxc1-adoption-matrix
export RUNNER_EXIT_ON_DRAIN=1        # bounded rig: exit 0 once the queue drains
export RECLAIM_POLL_INTERVAL=2
export CONTROL_POLL_INTERVAL=999
export HEARTBEAT_INTERVAL=999
export RUNNER_ID=test-runner PROJECT_REF=test-ws   # the identity the runner stamps + checks
claude_plan success                  # the adopted orphan's worker closes it ⇒ drains

bd_seed orphan-dead    "our crashed claim (dead pid)" "." in_progress
plant_claim orphan-dead    "$(dead_pid)"                       # our id + DEAD pid  ⇒ ADOPT
bd_seed orphan-live    "live sibling claim (live pid)" "." in_progress
plant_claim orphan-live    "$$"                                # our id + LIVE pid  ⇒ SKIP (sibling alive)
bd_seed orphan-foreign "foreign runner's claim"        "." in_progress
plant_claim orphan-foreign "$(dead_pid)" other-runner test-ws  # FOREIGN runner_id  ⇒ SKIP (default-closed)
bd_seed orphan-noclaim "no claim file at all"          "." in_progress
                                                               # NO claim file      ⇒ SKIP (non-runner in_progress)

run_runner

_expect "BC-02/uxc1" "claude-tools-uxc1 / §8.3.3" "only our-id+dead-pid in_progress orphan is adopted; live/foreign/no-claim skipped"
_need "startup snapshot PID-validated the set (1 of 4 in_progress seen)" \
      bash -c 'grep -q "PID-validated crash-orphan" "'"$HARNESS_OUT"'/runner.out" && grep -q "of 4 in_progress" "'"$HARNESS_OUT"'/runner.out"'
_need "dead-pid orphan ADOPTED (resumed → worker → closed)" \
      grep -q '^orphan-dead closed$' "$BD_AUDIT"
_need "runner announced the dead-pid adoption" \
      grep -q "orphan-adopt orphan-dead" "$HARNESS_OUT/runner.out"
_need "live-pid orphan SKIPPED (live sibling) — never re-claimed, never closed" \
      bash -c '! grep -qE "^orphan-live (in_progress|closed)$" "'"$BD_AUDIT"'"'
_need "runner gave the live-pid skip reason" \
      grep -q "orphan-skip orphan-live .* ALIVE" "$HARNESS_OUT/runner.out"
_need "foreign-runner orphan SKIPPED (default-closed) — never re-claimed, never closed" \
      bash -c '! grep -qE "^orphan-foreign (in_progress|closed)$" "'"$BD_AUDIT"'"'
_need "runner gave the foreign skip reason" \
      grep -q "orphan-skip orphan-foreign .* FOREIGN" "$HARNESS_OUT/runner.out"
_need "no-claim orphan SKIPPED (non-runner in_progress) — never re-claimed, never closed" \
      bash -c '! grep -qE "^orphan-noclaim (in_progress|closed)$" "'"$BD_AUDIT"'"'
_need "runner gave the no-claim skip reason" \
      grep -q "orphan-skip orphan-noclaim .* no claim file" "$HARNESS_OUT/runner.out"
_need "runner drained to a clean BC-21 exit 0 (skipped beads do not wedge it)" \
      test "${RUN_EXIT:-99}" -eq 0
_emit

# ── Acceptance #2 — claim-file lifecycle: the adopted orphan's stale claim is
#    OVERWRITTEN at re-claim and REMOVED on close (no debris that could later
#    false-adopt); the skipped orphans' claims are LEFT intact (the startup walk is
#    READ-ONLY — it must not strand the one-per-loop-drained orphans 2..K). ────────
_expect "uxc1" "claude-tools-uxc1 / §8.3.3" "adopted claim removed on close; skipped claims left intact (read-only walk)"
# NB: call harness functions / test DIRECTLY here, never via `bash -c` — a child
# shell does not inherit shell functions (claim_exists would be "command not
# found", silently negating to a false pass).
_need "adopted orphan's claim removed after its SUCCESS close" \
      test ! -f "$WORKDIR/.beads/runner-logs/claims/orphan-dead.json"
_need "skipped live-sibling claim left UNTOUCHED (walk is read-only)" \
      claim_exists orphan-live
_need "skipped foreign claim left UNTOUCHED (walk is read-only)" \
      claim_exists orphan-foreign
_emit

H_cleanup
