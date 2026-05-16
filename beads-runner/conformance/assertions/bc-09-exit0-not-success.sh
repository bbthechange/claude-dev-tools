#!/bin/bash
# BC-09 — Exit 0 ≠ success; truth is bd task status (incl. fail-open on empty).
# Binds: INTERFACE.md v1 §8.2 (terminal-reason re-home — classification truth,
#        not OS exit code) and §6.1 (lease release ⇒ bead→open SCAR).
# SCAR (silent-when-wrong): trusting exit 0 silently marks incomplete work done.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

# ── exit 0 + bead closed ⇒ SUCCESS ───────────────────────────────────────────
H_init_test bc09-success
bd_seed T1 "task one" "do a thing"
claude_plan success
run_runner
_expect "BC-09" "§8.2" "exit0 + bead closed ⇒ SUCCESS (no Runner: note, drains exit0)"
_need "expected exit 0, got $RUN_EXIT"               test "$RUN_EXIT" -eq 0
_need "bead T1 should be closed"                     test "$(bd_status T1)" = closed
_need "SUCCESS must not emit a Runner: note"         bash -c '! grep -q "^Runner:" "'"$BD_STORE"'/T1/notes"'
_need "no incidents.log on pure success"             bash -c '! test -s "'"$WORKDIR"'/.beads/runner-logs/incidents.log"'
_emit
H_cleanup

# ── exit 0 + bead still open ⇒ TASK_NOT_CLOSED (NOT trusted as success) ───────
H_init_test bc09-notclosed
bd_seed T1 "task one" "do a thing"
# inv1 exits 0 without closing; inv2 closes so the queue drains.
claude_plan noclose success
run_runner
_expect "BC-09" "§8.2" "exit0 + bead open ⇒ TASK_NOT_CLOSED, not SUCCESS"
_need "TASK_NOT_CLOSED must be recorded as an incident" contains "$(incidents_log)" "TASK_NOT_CLOSED"
_need "a Runner: TASK_NOT_CLOSED note must be appended" matches "$(notes_of T1)" "Runner: TASK_NOT_CLOSED at"
_need "exit-0 alone never closed the bead by itself"   matches "$(audit_seq T1)" "open"
_emit
H_cleanup

# ── exit 0 + bd-show status unparseable ⇒ fail-OPEN to SUCCESS ────────────────
H_init_test bc09-failopen
bd_seed T1 "task one" "do a thing"
claude_plan bdshow_empty success         # 2nd line unused (drains at loop2) — resilience only
export HARNESS_BD_SHOW_STATUS_EMPTY=T1   # classify path sees empty status
run_runner
_expect "BC-09" "§8.2" "empty bd-show status ⇒ explicit fail-OPEN SUCCESS (stderr note)"
_need "stderr must carry the explicit fail-open note" contains "$(out)" "Could not verify task status — assuming success"
_need "must NOT be classified TASK_NOT_CLOSED"        bash -c '! grep -q "TASK_NOT_CLOSED" "'"$WORKDIR"'/.beads/runner-logs/incidents.log" 2>/dev/null'
_need "runner ends cleanly (exit 0), not a phantom failure" test "$RUN_EXIT" -eq 0
_emit
H_cleanup
