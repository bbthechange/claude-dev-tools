#!/bin/bash
# BC-09 (FORWARD) — Exit 0 ≠ success; truth is `bd` task status, incl. the
#   explicit fail-OPEN-to-SUCCESS on an unverifiable status. (T2.2,
#   claude-tools-8nn.)
# Binds: INTERFACE.md v1 §8.2 (terminal-reason re-home — classification truth,
#        not the OS exit code) · §6.1 (lease release ⇒ bead→open).
#
# TARGET — the §7.1 classifier lives in the forward rewrite target runner.sh,
# NOT v1 run-beads-tasks.sh (the untouched bc-09-exit0-not-success.sh keeps v1
# regression-green). Same re-point precedent as bc-01-fresh-process.sh /
# bc-22-watchdog-tree.sh: reuse the T1a harness *library*, reassign $RUNNER
# only, zero edits to harness.sh or any T1a-owned rig.
#
# SCAR being asserted (silent-when-wrong): trusting exit 0 silently marks
# incomplete work done; treating an unverifiable status as a failure invents a
# phantom one. The rewrite must do NEITHER.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# ── exit 0 + bead closed ⇒ SUCCESS (no Runner: note, clean drain) ─────────────
H_init_test bc09tree-success
bd_seed T1 "task one" "do a thing"
claude_plan success
run_runner
_expect "BC-09" "§8.2" "exit0 + bead closed ⇒ SUCCESS (no Runner: note, drains exit0) (runner.sh)"
_need "expected exit 0, got ${RUN_EXIT:-?}"          test "$RUN_EXIT" -eq 0
_need "bead T1 should be closed"                     test "$(bd_status T1)" = closed
_need "SUCCESS must not emit a Runner: note"         bash -c '! grep -q "^Runner:" "'"$BD_STORE"'/T1/notes" 2>/dev/null'
_need "no incidents.log on pure success"             bash -c '! test -s "'"$WORKDIR"'/.beads/runner-logs/incidents.log"'
_emit
H_cleanup

# ── exit 0 + bead still open ⇒ TASK_NOT_CLOSED (NOT trusted as success) ───────
H_init_test bc09tree-notclosed
bd_seed T1 "task one" "do a thing"
claude_plan noclose success
run_runner
_expect "BC-09" "§8.2" "exit0 + bead open ⇒ TASK_NOT_CLOSED, not SUCCESS (runner.sh)"
_need "TASK_NOT_CLOSED recorded as an incident"        contains "$(incidents_log)" "TASK_NOT_CLOSED"
_need "a Runner: TASK_NOT_CLOSED note appended"        matches "$(notes_of T1)" "Runner: TASK_NOT_CLOSED at"
_need "exit-0 alone never closed the bead by itself"   matches "$(audit_seq T1)" "open"
_emit
H_cleanup

# ── exit 0 + bd-show status unparseable ⇒ explicit fail-OPEN to SUCCESS ───────
H_init_test bc09tree-failopen
bd_seed T1 "task one" "do a thing"
claude_plan bdshow_empty success
export HARNESS_BD_SHOW_STATUS_EMPTY=T1
run_runner
_expect "BC-09" "§8.2" "empty bd-show status ⇒ explicit fail-OPEN SUCCESS + stderr note (runner.sh)"
_need "explicit fail-open note on the merged stream" contains "$(out)" "Could not verify task status — assuming success"
_need "must NOT be classified TASK_NOT_CLOSED"       bash -c '! grep -q "TASK_NOT_CLOSED" "'"$WORKDIR"'/.beads/runner-logs/incidents.log" 2>/dev/null'
_need "runner ends cleanly (exit 0), no phantom fail" test "$RUN_EXIT" -eq 0
_emit
H_cleanup
