#!/bin/bash
# BC-12 — MAX_OUTPUT_TOKENS arrives via two INDEPENDENT stream paths, both of
#         which collapse to the SAME single class. (v2 -tree coverage-hardening,
#         claude-tools-v2cut.5)
#
# Binds: BEHAVIORAL-CONTRACT.md §7 BC-12. The SDK reports output-token
# exhaustion two ways and the runner must detect BOTH:
#   (A) a `result` event with stop_reason=max_tokens (parse_stream_signals
#       emits RESULT_STOP_REASON=max_tokens; classify_failure §7.1 translates
#       that to MAX_OUTPUT_TOKENS — runner.sh:769-770);
#   (B) a `system`/`api_retry` event with error=max_output_tokens
#       (parse_stream_signals emits the MAX_OUTPUT_TOKENS= marker directly —
#       runner.sh:626; classify_failure consumes it at runner.sh:768).
# Both are in the FROZEN §7.1 precedence as one class. Collapsing/dropping
# either path silently loses a real detection (the SCAR) — so this rig drives
# each path in isolation and proves the IDENTICAL observable outcome:
#   - exactly one `inc_has T1 MAX_OUTPUT_TOKENS` incident (same class label),
#   - the no-retry escalation creates exactly one `htest-` analysis child,
#   - the task ultimately drains (the trailing `success` closes it).
#
# TARGET — the dual-path classifier lives in the forward rewrite runner.sh; the
# bc-13-14 rig already touches maxtok_result. This rig is the explicit BC-12
# DUAL-path differential (result-path vs api_retry-path → same class). Same
# re-point pattern as bc-58/bc-22: reuse the harness library, repoint $RUNNER.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# ── PATH A · result event, stop_reason=max_tokens ⇒ MAX_OUTPUT_TOKENS ─────────
H_init_test bc12tree-maxtok-result-path
bd_seed T1 "maxtok via result" "x"
claude_plan maxtok_result success
run_runner
_expect "BC-12" "§7" "result-path (stop_reason=max_tokens) ⇒ class MAX_OUTPUT_TOKENS, no-retry analysis child (runner.sh)"
_need "MAX_OUTPUT_TOKENS incident recorded for T1"   inc_has T1 MAX_OUTPUT_TOKENS
_need "classified as MAX_OUTPUT_TOKENS, NOT UNKNOWN" inc_not T1 UNKNOWN_FAILURE
_need "exactly one MAX_OUTPUT_TOKENS incident (skip-retry, occurs once)" \
                                                     test "$(inc_count T1 MAX_OUTPUT_TOKENS)" -eq 1
_need "one analysis child created (htest-…)"         test "$(analysis_count)" -eq 1
_need "analysis child id is an htest- bead"          matches "$(analysis_ids)" '^htest-'
_need "task ultimately drained (exit 0)"             test "$RUN_EXIT" -eq 0
_emit
H_cleanup

# ── PATH B · system/api_retry event, error=max_output_tokens ⇒ SAME class ─────
H_init_test bc12tree-maxtok-apiretry-path
bd_seed T1 "maxtok via api_retry" "x"
claude_plan maxtok_apiretry success
run_runner
_expect "BC-12" "§7" "api_retry-path (error=max_output_tokens) ⇒ SAME class MAX_OUTPUT_TOKENS, no-retry analysis child (runner.sh)"
_need "MAX_OUTPUT_TOKENS incident recorded for T1"   inc_has T1 MAX_OUTPUT_TOKENS
_need "classified as MAX_OUTPUT_TOKENS, NOT UNKNOWN" inc_not T1 UNKNOWN_FAILURE
_need "exactly one MAX_OUTPUT_TOKENS incident (skip-retry, occurs once)" \
                                                     test "$(inc_count T1 MAX_OUTPUT_TOKENS)" -eq 1
_need "one analysis child created (htest-…)"         test "$(analysis_count)" -eq 1
_need "analysis child id is an htest- bead"          matches "$(analysis_ids)" '^htest-'
_need "task ultimately drained (exit 0)"             test "$RUN_EXIT" -eq 0
_emit
H_cleanup

# ── COLLAPSE · both independent paths produce the IDENTICAL class string ──────
# Source-structural confirmation that BOTH triggers populate the ONE §7.1 slot:
# the result-path translation (RESULT_STOP_REASON=max_tokens|length) and the
# api_retry marker (MAX_OUTPUT_TOKENS=) both `echo "MAX_OUTPUT_TOKENS"` in
# classify_failure — collapsing two distinct stream shapes to one class
# (BC-12's whole point). This is the only place the collapse is decided, so it
# is asserted against runner.sh directly (the black-box runs above already prove
# each path reaches it; this proves they share the single slot, not two).
H_init_test bc12tree-dual-path-collapse-source
bd_seed T1 "collapse" "x"      # workspace only; this block asserts on $RUNNER
_expect "BC-12" "§7" "both detection paths collapse to the single class MAX_OUTPUT_TOKENS in classify_failure (runner.sh)"
_need "api_retry path emits the MAX_OUTPUT_TOKENS marker" \
      grep -qE 'max_output_tokens\)[^A-Za-z]*echo "MAX_OUTPUT_TOKENS=1"' "$RUNNER"
_need "result-path stop_reason=max_tokens translates to MAX_OUTPUT_TOKENS" \
      grep -qE 'RESULT_STOP_REASON=max_tokens.*echo "MAX_OUTPUT_TOKENS"' "$RUNNER"
_need "result-path stop_reason=length ALSO translates to MAX_OUTPUT_TOKENS" \
      grep -qE 'RESULT_STOP_REASON=length.*echo "MAX_OUTPUT_TOKENS"' "$RUNNER"
_need "the marker path emits the SAME class MAX_OUTPUT_TOKENS" \
      grep -qE "'\\^MAX_OUTPUT_TOKENS='.*echo \"MAX_OUTPUT_TOKENS\"" "$RUNNER"
_emit
H_cleanup
