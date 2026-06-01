#!/bin/bash
# BC-26 (FORWARD / v2) — notification policy: noisy classes notify, routine
#   classes are DELIBERATELY silent. (claude-tools-v2cut.4 port — v2 had no
#   notify_user; only a `command -v` guarded call in post_close_audit.)
#
# Binds: BEHAVIORAL-CONTRACT.md §9 BC-26. notify_user (terminal bell + macOS
# osascript, best-effort, never fails the run) is invoked for AUTH_FAILURE,
# BILLING_ERROR, MAX_OUTPUT_TOKENS, CONTEXT_OVERFLOW, generic failures,
# exceeded_max_retries, subagent-unavailable, discipline-bypass, and the
# consecutive-breaker stop. It is DELIBERATELY NOT invoked for SUCCESS,
# RATE_LIMIT, the FIRST TASK_NOT_CLOSED, or the deliberate-stuck path. The
# SILENCE choices are the SCAR (alert fatigue from routine retries). The fake
# osascript records each notification's AppleScript string to notify_log.
#
# TARGET — runner.sh. The notify call POLICY (which class notifies) is the
# SCAR; osascript/bell is platform SCAFFOLDING.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1 RETRY_BACKOFF_BASE=1 RETRY_BACKOFF_MAX=2

# ── NOISY: AUTH_FAILURE notifies (fleet-fatal — Brian must know). ─────────────
H_init_test bc26tree-auth-notifies
bd_seed T1 "auth dies" "x"
claude_plan auth
run_runner
_expect "BC-26" "§9" "AUTH_FAILURE fires a desktop notification (runner.sh)"
_need "auth-failure notification fired"          contains "$(notify_log)" "auth failure"
_need "fleet-fatal exit 3 (terminal)"            test "$RUN_EXIT" -eq 3
_emit
H_cleanup

# ── NOISY: the consecutive-failure breaker notifies on stop. Same driver as
#    bc-21-exit2-breaker: 3 DISTINCT unknown-failure tasks + the default
#    MAX_CONSECUTIVE_FAILURES (3) ⇒ the breaker trips (exit 2) and notifies.
H_init_test bc26tree-breaker-notifies
bd_seed T1 "boom one"   "x"
bd_seed T2 "boom two"   "x"
bd_seed T3 "boom three" "x"
claude_plan unknown
run_runner
_expect "BC-26" "§9" "consecutive-failure breaker stop fires a notification (runner.sh)"
_need "breaker 'stopped' notification fired"     contains "$(notify_log)" "consecutive failures"
_need "breaker exit 2"                           test "$RUN_EXIT" -eq 2
_emit
H_cleanup

# ── SILENT (the SCAR): SUCCESS + RATE_LIMIT never notify. Plan rate-limits once
#    (RATE_LIMIT, invisible to retry counter) then succeeds — neither notifies.
H_init_test bc26tree-routine-silent
bd_seed T1 "ratelimited then ok" "x"
claude_plan ratelimit success
run_runner
_expect "BC-26" "§9" "SUCCESS and RATE_LIMIT are DELIBERATELY silent — no notification (runner.sh)"
_need "task ultimately closed (SUCCESS)"         test "$(bd_status T1)" = closed
_need "clean drain exit 0"                       test "$RUN_EXIT" -eq 0
_need "NO notification fired (routine classes silent)" bash -c '[[ -z "$(cat "'"$HARNESS_OUT"'/notify.log" 2>/dev/null)" ]]'
_emit
H_cleanup

# ── SILENT: the FIRST TASK_NOT_CLOSED is silent (often "agent forgot bd close");
#    plan noclose→success so the first occurrence retries silently and closes.
H_init_test bc26tree-first-notclosed-silent
bd_seed T1 "forgets to close" "x"
claude_plan noclose success
run_runner
_expect "BC-26" "§9" "the FIRST TASK_NOT_CLOSED is silent (no notification) (runner.sh)"
_need "task ultimately closed"                   test "$(bd_status T1)" = closed
_need "clean drain exit 0"                       test "$RUN_EXIT" -eq 0
_need "no notification on the first not-closed"  bash -c '[[ -z "$(cat "'"$HARNESS_OUT"'/notify.log" 2>/dev/null)" ]]'
_emit
H_cleanup
