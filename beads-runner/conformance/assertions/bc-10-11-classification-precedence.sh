#!/bin/bash
# BC-10 — Classification order is correctness, not cosmetics (first-match,
#         terminal-first over an accumulating signal file).
# BC-11 — Context overflow is a first-class terminal class, is_error-guarded.
# Binds: INTERFACE.md v1 §7.1 (FROZEN classification precedence, BC-10's order
#        with STUCK_NEEDS_HUMAN inserted). The STUCK slot is the literal
#        close-criterion T2 cites — encoded here as a forward GATE.
# SCAR (silent-when-wrong): reordering flips stop/escalate ↔ retry-forever.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT
# inc_has / inc_not provided by harness.sh

# rate_limit (transient) THEN context overflow (terminal) ⇒ CONTEXT_OVERFLOW
H_init_test bc10-rl-then-overflow
bd_seed T1 "multi signal" "x"
claude_plan rl_then_overflow success
run_runner
_expect "BC-10" "§7.1" "rate_limit→overflow classifies CONTEXT_OVERFLOW (terminal wins, not retry-forever)"
_need "expected CONTEXT_OVERFLOW incident for T1" inc_has T1 CONTEXT_OVERFLOW
_need "must NOT classify as RATE_LIMIT"           inc_not T1 RATE_LIMIT
_emit
H_cleanup

# AUTH_FAILURE must win over a co-occurring RATE_LIMIT (fleet-fatal first)
H_init_test bc10-auth-then-rl
bd_seed T1 "auth wins" "x"
claude_plan auth_then_rl
run_runner
_expect "BC-10" "§7.1" "auth+rate_limit classifies AUTH_FAILURE (exit 3), not RATE_LIMIT"
_need "expected runner exit 3 (AUTH terminal)" test "$RUN_EXIT" -eq 3
_need "expected AUTH_FAILURE incident"          inc_has T1 AUTH_FAILURE
_emit
H_cleanup

# CONTEXT_OVERFLOW is checked before MAX_OUTPUT_TOKENS (same family, overflow wins)
H_init_test bc10-overflow-before-maxtok
bd_seed T1 "overflow precedence" "x"
claude_plan overflow_then_maxtok success
run_runner
_expect "BC-11" "§7.1" "overflow text + max_tokens stop_reason ⇒ CONTEXT_OVERFLOW, not MAX_OUTPUT_TOKENS"
_need "expected CONTEXT_OVERFLOW incident"  inc_has T1 CONTEXT_OVERFLOW
_need "must NOT be MAX_OUTPUT_TOKENS"        inc_not T1 MAX_OUTPUT_TOKENS
_emit
H_cleanup

# is_error guard: a benign summary quoting "prompt is too long" is NOT overflow
H_init_test bc11-iserror-guard
bd_seed T1 "benign phrase" "x"
claude_plan overflow_phrase_benign
run_runner
_expect "BC-11" "§7.1" "is_error=false result quoting the phrase ⇒ SUCCESS, not CONTEXT_OVERFLOW"
_need "bead must close (treated SUCCESS)"          test "$(bd_status T1)" = closed
_need "no CONTEXT_OVERFLOW misclassification"      bash -c '! test -s "'"$WORKDIR"'/.beads/runner-logs/incidents.log"'
_emit
H_cleanup

# ── FORWARD GATE (§7.1): STUCK_NEEDS_HUMAN slot above per-task content classes ─
# Current script has no STUCK class; a worker-driven stuck (exit WORKER_STUCK_EXIT,
# bd→blocked, bd human) classifies UNKNOWN_FAILURE today. T2 MUST make this
# classify STUCK_NEEDS_HUMAN (§7.1 slot immediately below AUTH/BILLING, above
# CONTEXT_OVERFLOW/TASK_NOT_CLOSED). This is the literal close-criterion T2 cites.
H_init_test bc10-stuck-slot-gate
bd_seed T1 "needs a human" "x"
claude_plan stuck_primary success
run_runner
_gate "BC-10/11" "§7.1" "STUCK_NEEDS_HUMAN classified + slotted above content classes (T2 gate)"
_need "STUCK_NEEDS_HUMAN incident expected post-T2" inc_has T1 STUCK_NEEDS_HUMAN
_emit
H_cleanup
