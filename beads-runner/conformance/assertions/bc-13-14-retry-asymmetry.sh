#!/bin/bash
# BC-13 — Per-class retry asymmetry (rate-limit invisible to retry counter;
#         overflow/max-tokens skip retry; task-not-closed retry-once).
# BC-14 — Consecutive-failure breaker counts DISTINCT tasks only, resets on
#         success; overflow storm across distinct tasks never trips it.
# Binds: INTERFACE.md v1 §7.5 (STUCK_NEEDS_HUMAN retry- AND breaker-exempt) —
#        encoded as the forward GATE T2/T3 cite.
# SCAR (silent-when-wrong): wrong asymmetry ⇒ burn retry budget on infinite
#        rate-limits, or trip the fleet breaker on the normal path.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

# RATE_LIMIT does not consume a retry and never escalates
H_init_test bc13-ratelimit-invisible
bd_seed T1 "rl" "x"
claude_plan ratelimit ratelimit ratelimit success
run_runner
_expect "BC-13" "§7.5" "RATE_LIMIT ×3 then success: no analysis, no max-retries, drains exit 0"
_need "no analysis task created"            test "$(analysis_count)" -eq 0
_need "never hit exceeded_max_retries"       bash -c '! grep -q "exceeded_max_retries" "'"$BD_STORE"'/T1/notes" 2>/dev/null'
_need "no \"Skipping after\" retry-exhaust"  bash -c '! grep -q "Skipping after" "'"$HARNESS_OUT"'/runner.out"'
_need "RATE_LIMIT incident recorded"         test "$(inc_count T1 RATE_LIMIT)" -ge 1
_need "task ultimately drained (exit 0)"     test "$RUN_EXIT" -eq 0
_emit
H_cleanup

# CONTEXT_OVERFLOW skips retry — analysis child created on the FIRST occurrence
H_init_test bc13-overflow-skip-retry
bd_seed T1 "ov" "x"
claude_plan overflow success
run_runner
_expect "BC-13" "§7.5" "CONTEXT_OVERFLOW ⇒ immediate analysis child (no retry), occurs once"
_need "exactly one analysis child"          test "$(analysis_count)" -eq 1
_need "overflow not retried (1 incident)"    test "$(inc_count T1 CONTEXT_OVERFLOW)" -eq 1
_emit
H_cleanup

# MAX_OUTPUT_TOKENS likewise skips retry
H_init_test bc13-maxtok-skip-retry
bd_seed T1 "mt" "x"
claude_plan maxtok_result success
run_runner
_expect "BC-13" "§7.5" "MAX_OUTPUT_TOKENS ⇒ immediate analysis child (no retry)"
_need "exactly one analysis child"          test "$(analysis_count)" -eq 1
_need "max-tokens not retried (1 incident)"  test "$(inc_count T1 MAX_OUTPUT_TOKENS)" -eq 1
_emit
H_cleanup

# TASK_NOT_CLOSED: first occurrence retries (NO analysis)
H_init_test bc13-tnc-retry-once
bd_seed T1 "tnc1" "x"
claude_plan noclose success
run_runner
_expect "BC-13" "§7.5" "first TASK_NOT_CLOSED retries, creates NO analysis child"
_need "no analysis on first occurrence"     test "$(analysis_count)" -eq 0
_need "exactly one TASK_NOT_CLOSED"          test "$(inc_count T1 TASK_NOT_CLOSED)" -eq 1
_need "drained after retry (exit 0)"         test "$RUN_EXIT" -eq 0
_emit
H_cleanup

# TASK_NOT_CLOSED: second consecutive occurrence escalates to analysis
H_init_test bc13-tnc-escalate
bd_seed T1 "tnc2" "x"
claude_plan noclose noclose success
run_runner
_expect "BC-13" "§7.5" "second consecutive TASK_NOT_CLOSED ⇒ analysis child"
_need "one analysis child after 2nd"        test "$(analysis_count)" -eq 1
_need "two TASK_NOT_CLOSED incidents"        test "$(inc_count T1 TASK_NOT_CLOSED)" -eq 2
_emit
H_cleanup

# Breaker trips on 3 DISTINCT generic failures (exit 2)
H_init_test bc14-distinct-breaker
bd_seed T1 "g1" "x"; bd_seed T2 "g2" "x"; bd_seed T3 "g3" "x"
claude_plan unknown
RUN_TIMEOUT=40 run_runner
_expect "BC-14" "§7.5" "3 distinct generic failures ⇒ circuit breaker exit 2"
_need "expected exit 2"                      test "$RUN_EXIT" -eq 2
_need "breaker message printed"              contains "$(out)" "consecutive failures"
_emit
H_cleanup

# Same task failing generically 3× does NOT trip the breaker (per-task path)
H_init_test bc14-same-task-no-breaker
bd_seed T1 "same" "x"
claude_plan unknown unknown unknown success
run_runner
_expect "BC-14" "§7.5" "same-task generic ×N ⇒ exceeded_max_retries, NOT breaker exit 2"
_need "did NOT exit 2"                       test "$RUN_EXIT" -ne 2
_need "no breaker message"                   bash -c '! grep -q "consecutive failures" "'"$HARNESS_OUT"'/runner.out"'
_need "exceeded_max_retries path taken"      bash -c 'grep -q "exceeded_max_retries" "'"$BD_STORE"'/T1/notes" 2>/dev/null'
_emit
H_cleanup

# A CONTEXT_OVERFLOW storm across distinct tasks never trips the breaker.
# Driver is BEAD-keyed (overflow_then_fixed), not invocation-positional: the
# fake `bd ready` interleaves analysis children into the queue, so a positional
# `overflow overflow overflow` plan would mis-feed a slot to an analysis child
# (BC-17 guard ⇒ no grandchild) and a real task would never overflow. This
# keeps the asserted behavior identical — 3 DISTINCT overflows ⇒ one analysis
# child each ⇒ breaker untouched (CONTEXT_OVERFLOW never advances it).
H_init_test bc14-overflow-storm-no-breaker
bd_seed T1 "o1" "x"; bd_seed T2 "o2" "x"; bd_seed T3 "o3" "x"
claude_plan overflow_then_fixed
RUN_TIMEOUT=60 run_runner
_expect "BC-14" "§7.5" "overflow storm over distinct tasks ⇒ analysis-per-task, NOT breaker"
_need "did NOT exit 2"                       test "$RUN_EXIT" -ne 2
_need "no breaker message"                   bash -c '! grep -q "consecutive failures" "'"$HARNESS_OUT"'/runner.out"'
_need "three analysis children"              test "$(analysis_count)" -eq 3
_emit
H_cleanup

# ── FORWARD GATE (§7.5): STUCK_NEEDS_HUMAN is retry- AND breaker-exempt ───────
# Today a worker-driven stuck (exit WORKER_STUCK_EXIT) classifies UNKNOWN ⇒
# generic ⇒ advances the breaker. Over 3 distinct stuck tasks the CURRENT
# script trips the breaker (exit 2) — exactly the §7.5 regression. T2 MUST
# make STUCK breaker-exempt (no exit 2) and retry-exempt (no analysis child,
# bead stays blocked-for-human). This is the literal close-criterion T2 cites.
H_init_test bc14-stuck-exempt-gate
bd_seed T1 "s1" "x"; bd_seed T2 "s2" "x"; bd_seed T3 "s3" "x"
claude_plan stuck_primary
RUN_TIMEOUT=40 run_runner
_gate "BC-13/14" "§7.5" "STUCK_NEEDS_HUMAN retry+breaker exempt (no exit 2, no analysis) — T2 gate"
_need "post-T2: 3 stuck tasks must NOT trip breaker" test "$RUN_EXIT" -ne 2
_need "post-T2: no analysis child for a stuck bead"  test "$(analysis_count)" -eq 0
_emit
H_cleanup
