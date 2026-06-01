#!/bin/bash
# BC-61 (FORWARD / v2) — rate_limit_event is a SUBSCRIPTION-window snapshot
#   (5h/7d quota), collapsed to one line — NOT a 429 throttle. (claude-tools-
#   v2cut.4 port — v2's parse_stream_signals had no rate_limit_event case.)
#
# Binds: BEHAVIORAL-CONTRACT.md §9 BC-61. parse_stream_signals (runner.sh)
# branches on .rate_limit_info.status: `allowed`⇒ONE terse `[rate_limit] … ok`
# line (anti-spam); `allowed_warning`⇒a loud `[rate_limit:WARN]`; `rejected|
# exceeded`⇒a `[rate_limit:QUOTA]` line PLUS a forward-compat RATE_LIMIT_QUOTA
# marker. NO classification marker for allowed/allowed_warning, and the
# RATE_LIMIT_QUOTA marker is NOT a classifier input — so classification is
# UNAFFECTED in every case (a subscription snapshot is not the 429 path, which
# is api_retry.error=rate_limit ⇒ the RATE_LIMIT class).
# SCAR (intent): "don't conflate subscription-window with 429" + the visible
# 7-day-quota warning (claude-tools-t5k).
#
# TARGET — the forward rewrite runner.sh.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# ── allowed ⇒ ONE terse `[rate_limit] … ok` line; classification UNAFFECTED ────
H_init_test bc61tree-allowed-collapsed
bd_seed T1 "allowed snapshot" "x"
claude_plan rate_limit_event_allowed
run_runner
o="$(out)"
_expect "BC-61" "§9" "rate_limit_event status=allowed ⇒ terse ok line, no marker, classification unaffected (runner.sh)"
_need "terse '[rate_limit] … ok' line emitted"   matches "$o" "\[rate_limit\] .*ok"
_need "NOT conflated with a 429 (no 'Rate limited' RATE_LIMIT message)" notcontains "$o" "Rate limited"
_need "classification unaffected (bead closed SUCCESS)" test "$(bd_status T1)" = closed
_need "clean exit 0"                             test "$RUN_EXIT" -eq 0
_emit
H_cleanup

# ── allowed_warning ⇒ a LOUD `[rate_limit:WARN]` line; still no class change ───
H_init_test bc61tree-warning-loud
bd_seed T1 "approaching 7d quota" "x"
claude_plan rate_limit_event_warning
run_runner
o="$(out)"
_expect "BC-61" "§9" "rate_limit_event status=allowed_warning ⇒ loud [rate_limit:WARN] line, classification unaffected (runner.sh)"
_need "loud '[rate_limit:WARN]' line emitted"    contains "$o" "[rate_limit:WARN]"
_need "warning carries the utilization/threshold" matches "$o" "utilization=.*>="
_need "classification unaffected (bead closed SUCCESS)" test "$(bd_status T1)" = closed
_need "clean exit 0"                             test "$RUN_EXIT" -eq 0
_emit
H_cleanup

# ── rejected/exceeded ⇒ a `[rate_limit:QUOTA]` line; forward-compat marker is
#    NOT a classifier input, so the bead still closes SUCCESS. ─────────────────
H_init_test bc61tree-quota-forward-compat
bd_seed T1 "quota rejected" "x"
claude_plan rate_limit_event_quota
run_runner
o="$(out)"
_expect "BC-61" "§9" "rate_limit_event status=rejected ⇒ [rate_limit:QUOTA] line; RATE_LIMIT_QUOTA marker is not a classifier input (runner.sh)"
_need "'[rate_limit:QUOTA]' line emitted"        contains "$o" "[rate_limit:QUOTA]"
_need "forward-compat: classification still unaffected (bead closed SUCCESS)" test "$(bd_status T1)" = closed
_need "clean exit 0"                             test "$RUN_EXIT" -eq 0
_emit
H_cleanup
