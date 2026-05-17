#!/bin/bash
# BC-ntn (FORWARD) — terminal API-5xx ⇒ SERVER_ERROR  +  bounded exponential
#   inter-retry backoff.  (claude-tools-ntn, epic claude-tools-glk.)
#
# Binds: INTERFACE.md v1 §7.1 (the SERVER_ERROR slot — this adds the MISSING
#        SECOND producer of the EXISTING frozen slot; no slot is added,
#        removed, or reordered, and §7.2 already anticipates "two independent
#        triggers", so this is NOT a §0/§11 escalation) + §7.5/§8.1 (the
#        backoff only SPACES same-task attempts: it changes no classification,
#        no retry budget, no breaker counter, no exit code).
#
# TARGET — the fix lives in the rewrite target runner.sh (parse_stream_signals
# + st_claim). Same re-point precedent as the other -tree rigs; the v1
# run-beads-tasks.sh is intentionally NOT patched (it is being replaced).
#
# SCAR (silent-when-wrong, the 2026-05-16 incident): when the SDK's own
# retries are exhausted the platform-500 failure arrives as an ERRORED result
# carrying api_error_status:500 (+ "API Error: 500" text) with NO preceding
# system/api_retry event. The §7.1 SERVER_ERROR slot's only pre-fix producer
# is the api_retry branch, so a pure outage fell through to UNKNOWN_FAILURE
# AND the zero-delay back-to-back retries burned the whole MAX_RETRIES budget
# in seconds — healthy tasks spuriously marked exceeded_max_retries + spurious
# analysis children. Both halves are asserted here.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# ── EXIT-crit 1: terminal errored 5xx result ⇒ SERVER_ERROR (NOT UNKNOWN) ─────
# {is_error:true, api_error_status:500, result:"API Error: 500 ..."} with NO
# api_retry event — pre-fix this was UNKNOWN_FAILURE (incidents.log proof on
# the real 2026-05-16 outage). Post-fix the §7.1 SERVER_ERROR slot fires.
H_init_test ntn-classify-terminal-500
bd_seed T1 "hits a platform 500" "x"
export MAX_RETRIES=2 RETRY_BACKOFF_BASE=1 RETRY_BACKOFF_MAX=2
claude_plan server500_terminal success
run_runner
_expect "BC-ntn" "§7.1" "terminal errored 5xx result ⇒ SERVER_ERROR, not UNKNOWN_FAILURE (runner.sh)"
_need "classified SERVER_ERROR"                  inc_has T1 SERVER_ERROR
_need "NOT misclassified UNKNOWN_FAILURE"         inc_not T1 UNKNOWN_FAILURE
_need "fleet drained (exit 0, not budget-burned)" test "$RUN_EXIT" -eq 0
_emit
H_cleanup

# ── EXIT-crit 2: consecutive SERVER_ERROR retries are SPACED by a growing,
#    bounded delay (delay>0 and strictly increases) — the budget is NOT
#    consumed back-to-back within a few seconds. base=1,max=8 ⇒ 1,2,4. ───────
H_init_test ntn-growing-backoff
bd_seed T1 "platform 500 outage" "x"
export MAX_RETRIES=5 RETRY_BACKOFF_BASE=1 RETRY_BACKOFF_MAX=8
claude_plan server500_terminal server500_terminal server500_terminal success
RUN_TIMEOUT=40 run_runner
_expect "BC-ntn" "§7.5" "consecutive SERVER_ERROR retries separated by a growing bounded backoff (runner.sh)"
_need "still classified SERVER_ERROR"             inc_has T1 SERVER_ERROR
_need "NOT UNKNOWN_FAILURE"                        inc_not T1 UNKNOWN_FAILURE
_need ">=3 backoff delays, each >0 and strictly increasing" \
  bash -c 'grep -oE "retry backoff [0-9]+s" "'"$HARNESS_OUT"'/runner.out" \
           | grep -oE "[0-9]+" \
           | awk "{v=\$1+0;n++;if(v<=0)b=1;if(n>1&&v<=p)b=1;p=v}
                  END{exit (n>=3 && !b)?0:1}"'
_need "did NOT exceed_max_retries (budget spanned the outage)" \
  bash -c '! grep -q "exceeded_max_retries" "'"$BD_STORE"'/T1/notes" 2>/dev/null'
_need "no spurious analysis child"                test "$(analysis_count)" -eq 0
_need "did NOT trip the breaker (exit != 2)"      test "$RUN_EXIT" -ne 2
_need "ultimately drained (exit 0)"               test "$RUN_EXIT" -eq 0
_emit
H_cleanup

# ── No-regression A (is_error guard / BC-11 + BC-25): a SUCCESSFUL result that
#    merely QUOTES "API Error: 500" must NOT be manufactured into SERVER_ERROR. ─
H_init_test ntn-iserror-guard-benign
bd_seed T1 "mentions API Error 500 in prose" "x"
export MAX_RETRIES=2 RETRY_BACKOFF_BASE=1 RETRY_BACKOFF_MAX=2
claude_plan server500_benign
run_runner
_expect "BC-ntn" "§7.1" "benign result quoting 'API Error: 500' ⇒ SUCCESS, NOT SERVER_ERROR (runner.sh)"
_need "bead closed (SUCCESS)"                     test "$(bd_status T1)" = closed
_need "no SERVER_ERROR manufactured from prose"   inc_not T1 SERVER_ERROR
_need "no UNKNOWN_FAILURE either"                 inc_not T1 UNKNOWN_FAILURE
_emit
H_cleanup

# ── No-regression B (§7.1 first trigger intact): the EXISTING api_retry
#    server_error producer must STILL classify SERVER_ERROR on runner.sh. ──────
H_init_test ntn-apiretry-still-server-error
bd_seed T1 "api_retry server_error path" "x"
export MAX_RETRIES=2 RETRY_BACKOFF_BASE=1 RETRY_BACKOFF_MAX=2
claude_plan server success
run_runner
_expect "BC-ntn" "§7.1" "pre-existing api_retry server_error trigger STILL ⇒ SERVER_ERROR (no regression) (runner.sh)"
_need "api_retry path still classified SERVER_ERROR" inc_has T1 SERVER_ERROR
_need "not UNKNOWN_FAILURE"                          inc_not T1 UNKNOWN_FAILURE
_emit
H_cleanup
