#!/bin/bash
# BC-10/BC-11 (FORWARD) — classification ORDER is correctness (first-match,
#   terminal-first over an accumulating signal set); CONTEXT_OVERFLOW is a
#   first-class terminal class, is_error-GUARDED; and the §7.1 STUCK_NEEDS_HUMAN
#   slot is LANDED (immediately below the two fleet-fatal classes, above every
#   per-task content class and above the exit-0 TASK_NOT_CLOSED path). (T2.2,
#   claude-tools-8nn.)
# Binds: INTERFACE.md v1 §7.1 (the FROZEN precedence, BC-10's order with
#        STUCK_NEEDS_HUMAN inserted). The order IS the logic; a reorder is a §0
#        escalation, never edited here.
#
# TARGET — the §7.1 classifier is THIS child's owned surface in runner.sh; the
# untouched bc-10-11-classification-precedence.sh keeps v1 regression-green and
# its STUCK slot stays a documented GATE-PENDING there. Same re-point precedent
# as bc-01-fresh-process.sh.
#
# EXIT criterion 2 + 4: classify returns the first §7.1 match over an
# accumulated multi-marker set; STUCK slots above CONTEXT_OVERFLOW and above
# TASK_NOT_CLOSED; the WORKER_STUCK_EXIT→STUCK_NEEDS_HUMAN slot is GREEN.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# rate_limit (transient) THEN context overflow (terminal) ⇒ CONTEXT_OVERFLOW
H_init_test bc10tree-rl-then-overflow
bd_seed T1 "multi signal" "x"
claude_plan rl_then_overflow success
run_runner
_expect "BC-10" "§7.1" "rate_limit→overflow ⇒ CONTEXT_OVERFLOW (terminal wins, not retry-forever) (runner.sh)"
_need "expected CONTEXT_OVERFLOW incident for T1" inc_has T1 CONTEXT_OVERFLOW
_need "must NOT classify as RATE_LIMIT"           inc_not T1 RATE_LIMIT
_emit
H_cleanup

# AUTH_FAILURE must win over a co-occurring RATE_LIMIT (fleet-fatal first)
H_init_test bc10tree-auth-then-rl
bd_seed T1 "auth wins" "x"
claude_plan auth_then_rl
run_runner
_expect "BC-10" "§7.1" "auth+rate_limit ⇒ AUTH_FAILURE (exit 3), not RATE_LIMIT (runner.sh)"
_need "expected runner exit 3 (AUTH terminal)" test "$RUN_EXIT" -eq 3
_need "expected AUTH_FAILURE incident"          inc_has T1 AUTH_FAILURE
_emit
H_cleanup

# CONTEXT_OVERFLOW is checked before MAX_OUTPUT_TOKENS (same family, overflow wins)
H_init_test bc10tree-overflow-before-maxtok
bd_seed T1 "overflow precedence" "x"
claude_plan overflow_then_maxtok success
run_runner
_expect "BC-11" "§7.1" "overflow text + max_tokens stop_reason ⇒ CONTEXT_OVERFLOW, not MAX_OUTPUT_TOKENS (runner.sh)"
_need "expected CONTEXT_OVERFLOW incident"  inc_has T1 CONTEXT_OVERFLOW
_need "must NOT be MAX_OUTPUT_TOKENS"        inc_not T1 MAX_OUTPUT_TOKENS
_emit
H_cleanup

# is_error guard: a benign summary quoting "prompt is too long" is NOT overflow
H_init_test bc11tree-iserror-guard
bd_seed T1 "benign phrase" "x"
claude_plan overflow_phrase_benign
run_runner
_expect "BC-11" "§7.1" "is_error=false result quoting the phrase ⇒ SUCCESS, not CONTEXT_OVERFLOW (runner.sh)"
_need "bead must close (treated SUCCESS)"      test "$(bd_status T1)" = closed
_need "no CONTEXT_OVERFLOW misclassification"  bash -c '! test -s "'"$WORKDIR"'/.beads/runner-logs/incidents.log"'
_emit
H_cleanup

# ── §7.1 STUCK slot — NOW GREEN (was the documented GATE on v1) ───────────────
# Worker-driven §7.2 primary: bd status=blocked → bd human → exit
# WORKER_STUCK_EXIT(7). T2.2 consumes 7 into the §7.1 STUCK slot (immediately
# below AUTH/BILLING, ABOVE every per-task content class and TASK_NOT_CLOSED).
H_init_test bc10tree-stuck-slot
bd_seed T1 "needs a human" "x"
claude_plan stuck_primary success
run_runner
_expect "BC-10/11" "§7.1" "WORKER_STUCK_EXIT ⇒ STUCK_NEEDS_HUMAN, slotted above content classes (runner.sh)"
_need "STUCK_NEEDS_HUMAN incident recorded"   inc_has T1 STUCK_NEEDS_HUMAN
_need "NOT misclassified UNKNOWN_FAILURE"     inc_not T1 UNKNOWN_FAILURE
_need "NOT masked as TASK_NOT_CLOSED"         inc_not T1 TASK_NOT_CLOSED
_emit
H_cleanup
