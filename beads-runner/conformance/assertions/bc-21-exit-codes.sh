#!/bin/bash
# BC-21 — Exact, distinct exit codes per terminal condition (outward contract).
# Binds: INTERFACE.md v1 §8.1 (BC-21 exit-code table preserved VERBATIM) and
#        §3 job 6 / §8.2 (report-terminal-reason re-home — a durable
#        control-plane record, the literal close-criterion T3 cites).
# SCAR (silent-when-wrong): a coordinator switching on these codes
#        misroutes if "credentials bad (3)" ≡ "queue drained (0)".
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

# exit 0 — empty ready queue ("No more ready tasks")
H_init_test bc21-exit0-drained
claude_plan success
run_runner
_expect "BC-21" "§8.1" "drained bd ready ⇒ exit 0 + \"No more ready tasks.\""
_need "exit 0"                       test "$RUN_EXIT" -eq 0
_need "drain message printed"        contains "$(out)" "No more ready tasks."
_emit
H_cleanup

# exit 2 — consecutive-failure circuit breaker
H_init_test bc21-exit2-breaker
bd_seed T1 a x; bd_seed T2 b x; bd_seed T3 c x
claude_plan unknown
RUN_TIMEOUT=40 run_runner
_expect "BC-21" "§8.1" "circuit breaker ⇒ exit 2"
_need "exit 2"                       test "$RUN_EXIT" -eq 2
_emit
H_cleanup

# exit 3 — AUTH_FAILURE terminal
H_init_test bc21-exit3-auth
bd_seed T1 auth x
claude_plan auth
run_runner
_expect "BC-21" "§8.1" "AUTH_FAILURE ⇒ exit 3"
_need "exit 3"                       test "$RUN_EXIT" -eq 3
_emit
H_cleanup

# exit 4 — BILLING_ERROR terminal
H_init_test bc21-exit4-billing
bd_seed T1 bill x
claude_plan billing
run_runner
_expect "BC-21" "§8.1" "BILLING_ERROR ⇒ exit 4"
_need "exit 4"                       test "$RUN_EXIT" -eq 4
_emit
H_cleanup

# exit 1 (SIGINT/SIGTERM) is exercised by bc-35-interrupt-cleanup.sh (BC-35).

# Runner process exit code stays within the BC-21 contract {0..4}; the worker
# WORKER_STUCK_EXIT sentinel is NOT a runner exit code (§8.1).
H_init_test bc21-stuck-no-new-code
bd_seed T1 s x
claude_plan stuck_primary success
run_runner
_expect "BC-21" "§8.1" "worker-stuck sentinel never leaks as a runner exit code"
_need "runner exit ∈ {0,1,2,3,4}"    bash -c "case $RUN_EXIT in 0|1|2|3|4) exit 0;; *) exit 1;; esac"
_emit
H_cleanup

# ── FORWARD GATE (§3 job 6 / §8.2): terminal-reason re-home ───────────────────
# §8.2 re-homes BC-21 from an unobservable OS exit code to a DURABLE
# control-plane record written before the process exits (so a heartbeat-absence
# channel can tell AUTH=3 from clean=0). The current script has no such record;
# T3 MUST add report-terminal-reason. Literal close-criterion T3 cites.
H_init_test bc21-terminal-reason-gate
bd_seed T1 auth x
claude_plan auth
run_runner
_gate "BC-21" "§8.2" "report-terminal-reason durable record emitted before exit (T3 gate)"
_need "post-T3: a terminal-reason record exists"  test -f "$WORKDIR/.beads/runner-logs/terminal-reason"
_emit
H_cleanup
