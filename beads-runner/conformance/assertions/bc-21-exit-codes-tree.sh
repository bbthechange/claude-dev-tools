#!/bin/bash
# BC-21 (FORWARD) — exact, distinct exit codes per terminal condition. T2.2
#   (claude-tools-8nn) owns the §8.1 *producers* the classifier drives: the
#   breaker→2, AUTH_FAILURE→3, BILLING_ERROR→4 codes, the clean-drain 0, and
#   the invariant that the worker WORKER_STUCK_EXIT(7) sentinel never leaks as
#   a runner code (§7.5/§8.1). (The EXIT-trap code-PRESERVATION funnel is
#   T2.4's; the §8.2 durable terminal-reason record is T3's — NOT asserted
#   here.)
# Binds: INTERFACE.md v1 §8.1 (the BC-21 exit-code table — FROZEN, verbatim).
#
# TARGET — the fatal-class producers live in this child's runner.sh dispatch;
# the untouched bc-21-exit-codes.sh keeps v1 regression-green (and its §8.2
# terminal-reason gate stays GATE-PENDING there for T3). Same re-point
# precedent as bc-01-fresh-process.sh. exit 1 (SIGINT/SIGTERM) is owned and
# asserted by bc-35-interrupt-cleanup-tree.sh (T2.4) — not duplicated here.
#
# SCAR (silent-when-wrong): a supervisor switching on these codes misroutes if
# "credentials bad (3)" ≡ "queue drained (0)" ≡ "billing dead (4)".
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# exit 0 — empty ready queue (clean drain; exit-0-on-drain ≠ stop the project)
H_init_test bc21tree-exit0-drained
claude_plan success
run_runner
_expect "BC-21" "§8.1" "drained bd ready ⇒ exit 0 (runner.sh)"
_need "exit 0"                       test "$RUN_EXIT" -eq 0
_need "reached the drain terminal"   contains "$(out)" "draining"
_emit
H_cleanup

# exit 2 — consecutive-failure circuit breaker
H_init_test bc21tree-exit2-breaker
bd_seed T1 a x; bd_seed T2 b x; bd_seed T3 c x
claude_plan unknown
RUN_TIMEOUT=40 run_runner
_expect "BC-21" "§8.1" "circuit breaker ⇒ exit 2 (runner.sh)"
_need "exit 2"                       test "$RUN_EXIT" -eq 2
_emit
H_cleanup

# exit 3 — AUTH_FAILURE terminal
H_init_test bc21tree-exit3-auth
bd_seed T1 auth x
claude_plan auth
run_runner
_expect "BC-21" "§8.1" "AUTH_FAILURE ⇒ exit 3 (runner.sh)"
_need "exit 3"                       test "$RUN_EXIT" -eq 3
_emit
H_cleanup

# exit 4 — BILLING_ERROR terminal
H_init_test bc21tree-exit4-billing
bd_seed T1 bill x
claude_plan billing
run_runner
_expect "BC-21" "§8.1" "BILLING_ERROR ⇒ exit 4 (runner.sh)"
_need "exit 4"                       test "$RUN_EXIT" -eq 4
_emit
H_cleanup

# The worker WORKER_STUCK_EXIT(7) sentinel is NOT a runner exit code (§7.5/§8.1)
H_init_test bc21tree-stuck-no-new-code
bd_seed T1 s x
claude_plan stuck_primary success
run_runner
_expect "BC-21" "§8.1" "worker-stuck sentinel never leaks as a runner exit code (runner.sh)"
_need "runner exit ∈ {0,1,2,3,4}"    bash -c "case ${RUN_EXIT:-99} in 0|1|2|3|4) exit 0;; *) exit 1;; esac"
_need "STUCK adds no exit code (clean continue ⇒ 0)" test "$RUN_EXIT" -eq 0
_emit
H_cleanup
