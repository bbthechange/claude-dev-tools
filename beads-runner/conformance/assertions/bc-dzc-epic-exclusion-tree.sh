#!/bin/bash
# claude-tools-dzc (port-forward, claude-tools-v2c1) — runner.sh must NOT starve
# on an epic-topped `bd ready` queue.
#
# Epics are CONTAINERS, not workable. v1 (run-beads-tasks.sh) once logged 158
# epic-skip spin-cycles in a single detached run because next_task() returned
# epics interleaved with real work and the loop kept re-picking the epic on top
# (claude-tools-dzc, detached-20260524T003251Z.log). v1 fix: run-beads-tasks.sh
# :708-709 (`--exclude-type=epic` + a jq `select(... != "epic")` belt). The v2
# port lives at runner.sh st_reconcile's ONE selection point (no scattered
# downstream skip) — this rig proves it.
#
# TARGET: runner.sh (the rewrite), stub backend, no daemon. The fake `bd ready`
# (lib/fake-bin/bd) deliberately IGNORES `--exclude-type` — so a PASS proves the
# RUNNER's own jq epic filter excludes the epic, not bd's flag (robust to flag
# drift). The fake `bd` now emits `issue_type` and bd_seed takes it as arg 7.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"

# ── Acceptance #1 — epic on top + workable task beneath → claim the TASK, NEVER
#    the epic (the dzc starvation class). `bd ready` orders by attempts then id
#    (both attempts=0), so the lexically-first id is `.[0]`; seed the epic
#    lexically FIRST ("e-…") so the UNFIXED runner would pick it, with the
#    workable task ("z-…") beneath. The fixed runner filters the epic and claims
#    the task; this rig FAILS on a runner that still picks `.[0]` blindly. ─────
H_init_test dzc-epic-top-workable-beneath
export RUNNER_EXIT_ON_DRAIN=1        # bounded rig: exit 0 once the queue drains
export RECLAIM_POLL_INTERVAL=2
export CONTROL_POLL_INTERVAL=999
export HEARTBEAT_INTERVAL=999
claude_plan success                  # worker closes its bead ⇒ queue drains

bd_seed e-cap-epic  "container epic" "." open "" "" epic
bd_seed z-work-task "real work task" "." open "" "" task

run_runner

_expect "BC-dzc" "claude-tools-dzc / v2c1" "epic-topped queue: claims the workable task, never the epic"
_need "workable task driven to in_progress" grep -q '^z-work-task in_progress$' "$BD_AUDIT"
_need "epic NEVER claimed (no in_progress transition)" test -z "$(audit_seq e-cap-epic)"
_emit

# ── Acceptance #2 — ONLY epics ready → DRAIN/idle, claim NOTHING. Matches v1's
#    empty-after-filter behaviour (nothing workable ⇒ honest idle, no spin, no
#    epic claim). Guards against a naive filter that mis-handles the all-epic
#    case (e.g. claims an epic, or hot-spins instead of draining). ────────────
H_init_test dzc-all-epics-drain
export RUNNER_EXIT_ON_DRAIN=1
export RECLAIM_POLL_INTERVAL=2
export CONTROL_POLL_INTERVAL=999
export HEARTBEAT_INTERVAL=999
claude_plan success

bd_seed e-epic-a "epic A" "." open "" "" epic
bd_seed e-epic-b "epic B" "." open "" "" epic

run_runner

_expect "BC-dzc" "claude-tools-dzc / v2c1" "all-epic ready queue drains/idles, claims no epic"
_need "epic A never claimed" test -z "$(audit_seq e-epic-a)"
_need "epic B never claimed" test -z "$(audit_seq e-epic-b)"
_need "runner reported drain/idle" grep -qiE "drain|idl" "$HARNESS_OUT/runner.out"
_emit

H_cleanup
