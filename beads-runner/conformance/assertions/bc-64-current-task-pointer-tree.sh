#!/bin/bash
# BC-64 — current-task pointer hygiene: exported env + file fallback, cleared at
#         startup / loop-end / interrupt
#         (v2 -tree coverage-hardening, claude-tools-v2cut.5)
#
# PROVES (black-box file-state + source-structural):
#  (a) A STALE $LOG_DIR/current-task pre-planted before startup is CLEARED by
#      st_starting (runner.sh ~1454) — a previous runner that died (SIGKILL,
#      crash) must not let the close-discipline hook enforce against the wrong
#      bead on the next task's first tool call.
#  (b) After a normal drained run, the pointer is cleared at LOOP-END
#      (st_post_task ~2456) — the file is gone / empty once the queue drains.
#  (c) SOURCE — at claim (st_claim ~1999-2008) CURRENT_TASK_ID is set, `export`ed
#      (so the `claude -p` worker + hook subprocesses inherit it), AND written to
#      $LOG_DIR/current-task as a file fallback for a hook that lost its env.
#  (d) SOURCE — the interrupt path (runner_teardown ~1173-1178 / ~1196) resets
#      CURRENT_TASK_ID and removes the file on signal/abort/EXIT.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"   # repoint to v2
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# pointer_path — the current-task file the runner writes (LOG_DIR is relative to
# the runner's cwd == $WORKDIR).
pointer_path() { printf '%s' "$WORKDIR/.beads/runner-logs/current-task"; }
# pointer_clear — true iff the file is ABSENT or EMPTY (both are "cleared").
pointer_clear() { local p; p="$(pointer_path)"; [[ ! -s "$p" ]]; }

# ── (a) stale pre-planted pointer is CLEARED after a normal run ───────────────
H_init_test bc64tree-stale-cleared-at-startup
bd_seed T1 "task one" "do a thing"
claude_plan success
# Pre-plant a stale id BEFORE the runner starts (a prior crashed runner residue).
mkdir -p "$WORKDIR/.beads/runner-logs"
printf '%s' "ghost-prev-task-999" > "$(pointer_path)"
run_runner
_expect "BC-64" "§541" "a stale current-task pre-planted before startup is cleared (st_starting, runner.sh ~1454)"
_need "worker spawned (T1 closed)"                    test "$(bd_status T1)" = closed
_need "the ghost id no longer occupies the pointer"   bash -c '! grep -q "ghost-prev-task-999" "'"$(pointer_path)"'" 2>/dev/null'
_need "pointer is cleared (absent or empty) after the run" pointer_clear
_emit
H_cleanup

# ── (b) after a successful drained run the pointer is cleared at loop-end ─────
H_init_test bc64tree-cleared-at-loop-end
bd_seed T1 "task one" "do a thing"
claude_plan success
run_runner   # no pre-plant; the runner sets it at claim then clears at task-end
_expect "BC-64" "§541" "after a successful drained run the current-task pointer is cleared at loop-end (st_post_task ~2456)"
_need "worker spawned (T1 closed)"                    test "$(bd_status T1)" = closed
_need "pointer cleared (absent or empty) once the queue drained" pointer_clear
_emit
H_cleanup

# ── (c)+(d) source-structural: export + file fallback + interrupt reset ───────
H_init_test bc64tree-source-shape
_expect "BC-64" "§541" "st_claim sets+exports CURRENT_TASK_ID + writes the file fallback; teardown clears both (runner.sh ~1999-2008,~1173-1196)"
_need "CURRENT_TASK_ID is assigned the claimed candidate" \
      grep -qE 'CURRENT_TASK_ID="\$CANDIDATE_ID"' "$RUNNER"
_need "CURRENT_TASK_ID is exported (worker + hook subprocs inherit it)" \
      grep -qE '^[[:space:]]*export CURRENT_TASK_ID' "$RUNNER"
_need "the id is written to \$LOG_DIR/current-task (file fallback)" \
      grep -qE 'printf .*"\$CURRENT_TASK_ID" > "\$LOG_DIR/current-task"' "$RUNNER"
_need "st_starting clears a stale pointer at startup" \
      grep -qE 'rm -f "\$LOG_DIR/current-task"' "$RUNNER"
_need "the interrupt path resets CURRENT_TASK_ID to open" \
      grep -qE 'Interrupted .* resetting \$CURRENT_TASK_ID to open' "$RUNNER"
_need "teardown removes the current-task pointer file" \
      grep -qE 'rm -f .*"\$LOG_DIR/current-task"' "$RUNNER"
_emit
H_cleanup
