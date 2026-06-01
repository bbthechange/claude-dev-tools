#!/bin/bash
# claude-tools-v2cut.2 (v2c3 coverage-audit gap) — runner.sh must RECOVER a
# prior-crash orphan: a bead left `in_progress` by a SIGKILLed/crashed run.
#
# BC-02/03/04 (BEHAVIORAL-CONTRACT §2). v1 (run-beads-tasks.sh:670-697) snapshots
# `bd list --status=in_progress` at STARTUP (crash orphans), guards the empty
# case, and drains ONE orphan per loop with a resume-time `bd show` status
# re-check. v2's rewrite shipped without this layer: `st_reconcile` only ever
# polls `bd ready` (which returns `open`), so an `in_progress` orphan was
# invisible and NEVER retried. The §6.1 lease orphan-recovery
# (test-coordinator-lease.sh EXIT-3) recovers only the STRONG plane (a new owner
# can re-acquire the crashed owner's EXPIRED lease) and is reached only when some
# runner re-attempts that task_ref — which nothing did, because the WORK-plane
# bead status was never reset. This rig proves the ported v2 work-plane half:
# `st_starting` snapshot (BC-02/03) + the `st_reconcile` `_drain_one_orphan`
# pass (BC-04) re-present the orphan so st_claim's lease re-acquire composes with
# the strong-plane recovery.
#
# TARGET: runner.sh (the rewrite), stub backend, no daemon. The fake `bd ready`
# never returns an `in_progress` bead — so a PASS proves the RUNNER's startup
# snapshot re-presented the orphan, not `bd ready`. The fake `bd list
# --status=in_progress` + `bd show` drive the snapshot and the re-check.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"

# ── Acceptance #1 — BC-02/04: a crash orphan (in_progress AT STARTUP) is
#    RESUMED, orphans-FIRST. Seed one orphan (in_progress) + one open ready task.
#    The orphan is absent from `bd ready`, so the UNFIXED runner never touches it
#    (`audit_seq orphan` empty); the fixed runner snapshots it, resumes it BEFORE
#    polling ready, and its worker drives it to closed. ──────────────────────────
H_init_test orphan-resume-first
export RUNNER_EXIT_ON_DRAIN=1        # bounded rig: exit 0 once the queue drains
export RECLAIM_POLL_INTERVAL=2
export CONTROL_POLL_INTERVAL=999
export HEARTBEAT_INTERVAL=999
claude_plan success                  # each worker closes its own bead ⇒ drains

bd_seed orphan-crash "stranded crash orphan" "." in_progress
bd_seed z-ready-task "fresh ready task"      "." open

run_runner

_expect "BC-02/04" "claude-tools-v2cut.2 / v2c3" "crash orphan (in_progress@startup) is resumed orphans-first"
_need "orphan was resumed (snapshot re-presented an in_progress bead bd ready hides)" \
      test -n "$(audit_seq orphan-crash)"
_need "orphan driven to closed (resumed → worker → SUCCESS)" \
      grep -q '^orphan-crash closed$' "$BD_AUDIT"
_need "runner announced the crash-orphan resume" \
      grep -q "resuming crash-orphan orphan-crash" "$HARNESS_OUT/runner.out"
_need "orphan resumed BEFORE the fresh ready task is claimed (orphans-first)" \
      line_before '^orphan-crash in_progress$' '^z-ready-task in_progress$' "$BD_AUDIT"
_need "fresh ready task still completed after the orphan" \
      grep -q '^z-ready-task closed$' "$BD_AUDIT"
_emit

# ── Acceptance #2 — BC-04 one-per-loop + remaining-orphan preservation: TWO
#    orphans are BOTH resumed, across successive loops, in snapshot order. Proves
#    the drain resumes exactly one per reconcile and PRESERVES the orphans after
#    the resumed one (a naive "resume all at once" or "lose the tail" both fail). ─
H_init_test orphan-two-one-per-loop
export RUNNER_EXIT_ON_DRAIN=1
export RECLAIM_POLL_INTERVAL=2
export CONTROL_POLL_INTERVAL=999
export HEARTBEAT_INTERVAL=999
claude_plan success

bd_seed orphan-a "first crash orphan"  "." in_progress
bd_seed orphan-b "second crash orphan" "." in_progress

run_runner

_expect "BC-04" "claude-tools-v2cut.2 / v2c3" "two orphans both resumed, one-per-loop, snapshot order"
_need "orphan-a resumed → closed"  grep -q '^orphan-a closed$' "$BD_AUDIT"
_need "orphan-b resumed → closed (NOT lost when orphan-a was resumed first)" \
      grep -q '^orphan-b closed$' "$BD_AUDIT"
_need "orphan-a resumed BEFORE orphan-b (one-per-loop, snapshot order preserved)" \
      line_before '^orphan-a in_progress$' '^orphan-b in_progress$' "$BD_AUDIT"
_emit

# ── Acceptance #3 — BC-03 empty-orphan guard: with ZERO in_progress beads at
#    startup, the runner takes NO orphan path — no snapshot line, no spurious
#    resume, no phantom empty-id claim — and proceeds straight to `bd ready`. The
#    v2 list-construction (while-read skipping blanks) cannot produce a phantom
#    empty element, so the v1 `read -ra` one-empty-field guard is not needed. ────
H_init_test orphan-empty-guard
export RUNNER_EXIT_ON_DRAIN=1
export RECLAIM_POLL_INTERVAL=2
export CONTROL_POLL_INTERVAL=999
export HEARTBEAT_INTERVAL=999
claude_plan success

bd_seed open-only "ordinary open task" "." open

run_runner

_expect "BC-03" "claude-tools-v2cut.2 / v2c3" "no in_progress at startup ⇒ no orphan path, clean bd ready run"
_need "no crash-orphan snapshot reported (empty set)" \
      bash -c '! grep -q "crash-orphan(s) eligible" "'"$HARNESS_OUT"'/runner.out"'
_need "no spurious orphan resume" \
      bash -c '! grep -q "resuming crash-orphan" "'"$HARNESS_OUT"'/runner.out"'
_need "no phantom empty-id claim (no bd show \"\" → \" in_progress\" audit line)" \
      bash -c '! grep -qE "^[[:space:]]+(in_progress|closed)$" "'"$BD_AUDIT"'"'
_need "the ordinary open task completed normally" \
      grep -q '^open-only closed$' "$BD_AUDIT"
_emit

# ── Acceptance #4 — BC-04 flaky-show KEEP: an orphan whose `bd show` returns no
#    parseable status at re-check time must be KEPT for a later retry, never
#    silently dropped (a flaky bd show must not lose an orphan) and never crash
#    the runner. The harness `HARNESS_BD_SHOW_STATUS_EMPTY` makes `bd show
#    <id>` return `[]`. The orphan stays unresumed (status unparseable) while the
#    queue otherwise drains; the runner exits 0 cleanly, not hot-spinning. ───────
H_init_test orphan-flaky-show-keep
export RUNNER_EXIT_ON_DRAIN=1
export RECLAIM_POLL_INTERVAL=2
export CONTROL_POLL_INTERVAL=999
export HEARTBEAT_INTERVAL=999
export HARNESS_BD_SHOW_STATUS_EMPTY=orphan-flaky   # bd show orphan-flaky ⇒ []
claude_plan success

bd_seed orphan-flaky "orphan with a flaky bd show" "." in_progress

run_runner

_expect "BC-04" "claude-tools-v2cut.2 / v2c3" "flaky bd show ⇒ orphan KEPT for retry, not dropped/crashed"
_need "flaky orphan NOT resumed this run (unparseable status ⇒ keep, do not resume)" \
      test -z "$(audit_seq orphan-flaky)"
_need "runner did NOT crash — drained to a clean BC-21 exit 0" \
      test "${RUN_EXIT:-99}" -eq 0
_need "no spurious resume of the flaky orphan" \
      bash -c '! grep -q "resuming crash-orphan orphan-flaky" "'"$HARNESS_OUT"'/runner.out"'
_emit

H_cleanup
