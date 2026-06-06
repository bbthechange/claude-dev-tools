#!/bin/bash
# BC-13/BC-14 (FORWARD) — per-class retry asymmetry + the consecutive-failure
#   circuit breaker, AND the §7.5 STUCK_NEEDS_HUMAN retry+breaker EXEMPTION.
#   (T2.2, claude-tools-8nn.)
# Binds: INTERFACE.md v1 §7.5 (STUCK retry- AND breaker-exempt — was the
#        documented GATE on v1; T2.2 flips it GREEN) and the §8.1 breaker exit 2.
#
# TARGET — the retry/breaker logic is THIS child's owned surface in runner.sh;
# the untouched bc-13-14-retry-asymmetry.sh keeps v1 regression-green and its
# §7.5 STUCK gate stays GATE-PENDING there. Same re-point precedent as
# bc-01-fresh-process.sh.
#
# SCAR (silent-when-wrong): wrong asymmetry ⇒ burn the retry budget on infinite
# rate-limits, retry a deterministic overflow forever, or trip the FLEET breaker
# on N legitimate human-decision tasks (turning the normal path into an outage).
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1
# claude-tools-309l: make this rig HERMETIC like bc-43/bc-49-50-…-tree.sh. v2
# (runner.sh) gates task pickup on a §6.1 lease via `co_lease_acquire`; with a
# leaked ambient COORDINATOR_URL/TOKEN + RUNNER_BACKEND=real (present on a live
# fleet box — e.g. the daemon's own shell) the runner talks to the HOSTED
# coordinator, can't lease the fake `T1`, and EVERY assertion below goes falsely
# RED (lease unavailable ⇒ no claim ⇒ no incidents ⇒ empty `inc_count` ⇒
# `test: integer expression expected`). Force the in-process stub backend (whose
# lease always grants) so the rig tests the runner, not the box's environment.
unset COORDINATOR_URL COORDINATOR_TOKEN 2>/dev/null || true
export RUNNER_BACKEND=stub

# RATE_LIMIT is invisible to the per-task retry counter and never escalates
H_init_test bc13tree-ratelimit-invisible
bd_seed T1 "rl" "x"
claude_plan ratelimit ratelimit ratelimit success
run_runner
_expect "BC-13" "§7.5" "RATE_LIMIT ×3 then success: no analysis, no max-retries, drains exit 0 (runner.sh)"
_need "no analysis task created"             test "$(analysis_count)" -eq 0
_need "never hit exceeded_max_retries"        bash -c '! grep -q "exceeded_max_retries" "'"$BD_STORE"'/T1/notes" 2>/dev/null'
_need "no \"Skipping after\" retry-exhaust"   bash -c '! grep -q "Skipping after" "'"$HARNESS_OUT"'/runner.out"'
_need "RATE_LIMIT incident recorded"          test "$(inc_count T1 RATE_LIMIT)" -ge 1
_need "task ultimately drained (exit 0)"      test "$RUN_EXIT" -eq 0
_emit
H_cleanup

# CONTEXT_OVERFLOW skips retry — analysis child on the FIRST occurrence
H_init_test bc13tree-overflow-skip-retry
bd_seed T1 "ov" "x"
claude_plan overflow success
run_runner
_expect "BC-13" "§7.5" "CONTEXT_OVERFLOW ⇒ immediate analysis child (no retry), occurs once (runner.sh)"
_need "exactly one analysis child"           test "$(analysis_count)" -eq 1
_need "overflow not retried (1 incident)"     test "$(inc_count T1 CONTEXT_OVERFLOW)" -eq 1
_emit
H_cleanup

# MAX_OUTPUT_TOKENS likewise skips retry
H_init_test bc13tree-maxtok-skip-retry
bd_seed T1 "mt" "x"
claude_plan maxtok_result success
run_runner
_expect "BC-13" "§7.5" "MAX_OUTPUT_TOKENS ⇒ immediate analysis child (no retry) (runner.sh)"
_need "exactly one analysis child"           test "$(analysis_count)" -eq 1
_need "max-tokens not retried (1 incident)"   test "$(inc_count T1 MAX_OUTPUT_TOKENS)" -eq 1
_emit
H_cleanup

# TASK_NOT_CLOSED: first occurrence retries (NO analysis)
H_init_test bc13tree-tnc-retry-once
bd_seed T1 "tnc1" "x"
claude_plan noclose success
run_runner
_expect "BC-13" "§7.5" "first TASK_NOT_CLOSED retries, creates NO analysis child (runner.sh)"
_need "no analysis on first occurrence"      test "$(analysis_count)" -eq 0
_need "exactly one TASK_NOT_CLOSED"          test "$(inc_count T1 TASK_NOT_CLOSED)" -eq 1
_need "drained after retry (exit 0)"         test "$RUN_EXIT" -eq 0
_emit
H_cleanup

# TASK_NOT_CLOSED: second consecutive occurrence escalates to analysis
H_init_test bc13tree-tnc-escalate
bd_seed T1 "tnc2" "x"
claude_plan noclose noclose success
run_runner
_expect "BC-13" "§7.5" "second consecutive TASK_NOT_CLOSED ⇒ analysis child (runner.sh)"
_need "one analysis child after 2nd"         test "$(analysis_count)" -eq 1
_need "two TASK_NOT_CLOSED incidents"        test "$(inc_count T1 TASK_NOT_CLOSED)" -eq 2
_emit
H_cleanup

# Breaker trips on 3 DISTINCT generic failures (§8.1 exit 2)
H_init_test bc14tree-distinct-breaker
bd_seed T1 "g1" "x"; bd_seed T2 "g2" "x"; bd_seed T3 "g3" "x"
claude_plan unknown
RUN_TIMEOUT=40 run_runner
_expect "BC-14" "§7.5" "3 distinct generic failures ⇒ circuit breaker exit 2 (runner.sh)"
_need "expected exit 2"                      test "$RUN_EXIT" -eq 2
_need "breaker message printed"              contains "$(out)" "consecutive failures"
_emit
H_cleanup

# Same task failing generically 3× does NOT trip the breaker (per-task path)
H_init_test bc14tree-same-task-no-breaker
bd_seed T1 "same" "x"
claude_plan unknown unknown unknown success
run_runner
_expect "BC-14" "§7.5" "same-task generic ×N ⇒ exceeded_max_retries, NOT breaker exit 2 (runner.sh)"
_need "did NOT exit 2"                       test "$RUN_EXIT" -ne 2
_need "no breaker message"                   bash -c '! grep -q "consecutive failures" "'"$HARNESS_OUT"'/runner.out"'
_need "exceeded_max_retries path taken"      bash -c 'grep -q "exceeded_max_retries" "'"$BD_STORE"'/T1/notes" 2>/dev/null'
_emit
H_cleanup

# A CONTEXT_OVERFLOW storm across distinct tasks never trips the breaker
H_init_test bc14tree-overflow-storm-no-breaker
bd_seed T1 "o1" "x"; bd_seed T2 "o2" "x"; bd_seed T3 "o3" "x"
claude_plan overflow_then_fixed
RUN_TIMEOUT=60 run_runner
_expect "BC-14" "§7.5" "overflow storm over distinct tasks ⇒ analysis-per-task, NOT breaker (runner.sh)"
_need "did NOT exit 2"                       test "$RUN_EXIT" -ne 2
_need "no breaker message"                   bash -c '! grep -q "consecutive failures" "'"$HARNESS_OUT"'/runner.out"'
_need "three analysis children"              test "$(analysis_count)" -eq 3
_emit
H_cleanup

# ── §7.5 STUCK retry+breaker EXEMPTION — NOW GREEN (was the GATE on v1) ───────
# 3 DISTINCT worker-driven stuck tasks. v1: exit 7 → UNKNOWN → generic ⇒ each
# advances the breaker ⇒ exit 2 (the §7.5 regression). T2.2: STUCK is breaker-
# AND retry-exempt — no exit 2, no analysis child, bead stays blocked-for-human
# so it is not re-picked (3 stuck ⇒ clean drain, fleet keeps running).
H_init_test bc14tree-stuck-exempt
bd_seed T1 "s1" "x"; bd_seed T2 "s2" "x"; bd_seed T3 "s3" "x"
claude_plan stuck_primary
RUN_TIMEOUT=40 run_runner
_expect "BC-13/14" "§7.5" "STUCK_NEEDS_HUMAN retry+breaker exempt (no exit 2, no analysis) (runner.sh)"
_need "3 stuck tasks must NOT trip the breaker"   test "$RUN_EXIT" -ne 2
_need "no analysis child for a stuck bead"        test "$(analysis_count)" -eq 0
_need "STUCK_NEEDS_HUMAN incident recorded"       inc_has T1 STUCK_NEEDS_HUMAN
_need "STUCK never advanced the breaker"          bash -c '! grep -q "consecutive failures" "'"$HARNESS_OUT"'/runner.out"'
_emit
H_cleanup

# ── claude-tools-1vnx: a blocked+human EXIT-0 fork is UN-THRASHABLE (v2) ───────
# The compliant worker leaves status=blocked + a real `human` label + a structured
# ask and ENDS ITS TURN — `claude -p` exits 0 (NOT WORKER_STUCK_EXIT(7), and no
# STUCK_NEEDS_HUMAN= stream marker). v2's classify_failure folded this to
# TASK_NOT_CLOSED → st_post_task reset --status=open + (retry) analysis child whose
# close re-armed the bead → the m3xi thrash (v2 had the IDENTICAL hole to v1; v2 is
# piloting live, so the hole was reachable). The fix reads the sticky `human` label
# in classify_failure and classifies STUCK_NEEDS_HUMAN, reusing v2's breaker/retry-
# EXEMPT STUCK dispatch (_drive_blocked_for_human — no reset, no analysis).
H_init_test bc13tree-1vnx-blocked-human-exit0-unthrash
bd_seed T1 "human fork" "x"
claude_plan stuck_primary_exit0
run_runner
_expect "BC-13/14" "§7.5" "blocked+human EXIT-0 fork ⇒ STUCK_NEEDS_HUMAN, NO reset-to-open, NO analysis, breaker/retry-exempt (claude-tools-1vnx) (runner.sh)"
_need "STUCK_NEEDS_HUMAN incident recorded"          inc_has T1 STUCK_NEEDS_HUMAN
_need "ZERO analysis children (not thrashed)"        test "$(analysis_count)" -eq 0
_need "bead left status=blocked (NOT reset to open)" test "$(bd_status T1)" = "blocked"
_need "no TASK_NOT_CLOSED reset taken"               test "$(inc_count T1 TASK_NOT_CLOSED)" -eq 0
_need "breaker never tripped (exit != 2)"            test "$RUN_EXIT" -ne 2
_emit
H_cleanup

# ── claude-tools-309l: an AGED-OUT human+NOT-blocked fork is UN-THRASHABLE (v2) ─
# v2 had NO Case-3 analogue at ALL — its STUCK path is sig/exit-code + (1vnx)
# blocked+human only. So a worker that slipped step 1 (human label + a structured
# ask carrying a STUCK_NEEDS_HUMAN marker, but NEVER status=blocked — the m3xi
# vector) folded straight to TASK_NOT_CLOSED → reset + analysis (thrash), and no
# recency window even mattered. 309l extends classify_failure to recognise it on
# the durable signals — the sticky `human` LABEL (resolution removes it) + the
# worker's OWN non-audit STUCK_NEEDS_HUMAN note, RECENCY-INDEPENDENT — and route it
# through the SAME breaker/retry-EXEMPT STUCK dispatch (_drive_blocked_for_human:
# flips blocked + authors the §7.4/69u8 dossier). The marker is aged on purpose to
# prove recency is irrelevant to the v2 recogniser.
H_init_test bc13tree-309l-aged-human-notblocked-unthrash
bd_seed T1 "aged human fork" "x"
claude_plan stuck_slipped_aged
run_runner
_expect "BC-13/14" "§7.5" "aged-out human+NOT-blocked fork ⇒ STUCK_NEEDS_HUMAN, pinned blocked, NO reset, NO analysis (claude-tools-309l) (runner.sh)"
_need "STUCK_NEEDS_HUMAN incident recorded"          inc_has T1 STUCK_NEEDS_HUMAN
_need "ZERO analysis children (not thrashed)"        test "$(analysis_count)" -eq 0
_need "dispatch FLIPPED bead to status=blocked"      test "$(bd_status T1)" = "blocked"
_need "no TASK_NOT_CLOSED reset taken"               test "$(inc_count T1 TASK_NOT_CLOSED)" -eq 0
_need "breaker never tripped (exit != 2)"            test "$RUN_EXIT" -ne 2
_emit
H_cleanup
