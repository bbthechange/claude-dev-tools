#!/bin/bash
# BC-25 (FORWARD / v2) — scan_tool_errors: PATTERN-matched, side-effect-only,
#   NEVER changes classification or exit code. Raw is_error counts deliberately
#   unused. (claude-tools-v2cut.4 port — v2 had no scan_tool_errors at all.)
#
# Binds: BEHAVIORAL-CONTRACT.md §9 BC-25. v2's scan_tool_errors (runner.sh) is
# called UNCONDITIONALLY after the st_post_task dispatch case — so even a SUCCESS
# (exit 0, bead closed) still surfaces an inline-recovered tool failure as an
# incident + greppable note (+ subagent notify), without touching the verdict.
# SCAR (silent-when-wrong): an inline-recovered missing-subagent still means the
# agent didn't do what we asked; but raw is_error COUNTS would be dominated by
# routine probes (Read-on-missing-file, grep-no-match).
#
# TARGET — the forward rewrite runner.sh (same re-point pattern as bc-58/bc-22:
# reuse the harness lib, repoint $RUNNER). Asserted against v2's ACTUAL output.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# ── POSITIVE: a matched signature (subagent-not-found) is surfaced as a
#    TOOL_ERROR incident + beads note while classification stays SUCCESS/exit 0.
H_init_test bc25tree-subagent-surfaced
bd_seed T1 "recovers inline" "x"
claude_plan subagent_err_then_success
run_runner
ld="$WORKDIR/.beads/runner-logs"
_expect "BC-25" "§9" "matched tool-error surfaced as side-effect; classification/exit UNCHANGED (runner.sh)"
_need "classification stayed SUCCESS (bead closed)"   test "$(bd_status T1)" = closed
_need "exit code unchanged by the scan (0)"           test "$RUN_EXIT" -eq 0
_need "TOOL_ERROR:subagent-unavailable incident row"  contains "$(incidents_log)" "TOOL_ERROR:subagent-unavailable"
_need "greppable 'tool-error' beads note appended"    matches "$(notes_of T1)" "Runner: tool-error subagent-unavailable"
_need "subagent case fired a desktop notification"    contains "$(notify_log)" "subagent unavailable"
_need "scan did NOT manufacture a failure class"      bash -c '! grep -qE "(SERVER_ERROR|UNKNOWN_FAILURE|TASK_NOT_CLOSED|RATE_LIMIT)" "'"$ld"'/incidents.log" 2>/dev/null'
# side-effect-only: a recovered tool-error under a SUCCESS must NOT escalate to
# post-mortem stream PRESERVATION (BC-28). v2 names the WORKING stream
# `<id>-<ts>.stream.jsonl` inside LOG_DIR (v1 used mktemp outside it), so the
# observable is the absence of the "Stream preserved:" line, not the glob.
_need "side-effect-only: SUCCESS preserved no stream" notcontains "$(out)" "Stream preserved"
_emit
H_cleanup

# ── NEGATIVE (the precise SCAR): TWO is_error:true tool_results that match NONE
#    of the three signatures (routine probes). Raw-count logic would flag 2;
#    pattern logic must surface ZERO.
H_init_test bc25tree-pattern-not-count
bd_seed T1 "benign probes" "x"
claude_plan benign_err_then_success
run_runner
_expect "BC-25" "§9" "raw is_error count NOT used — unmatched routine probes surface nothing (runner.sh)"
_need "bead closed (SUCCESS)"                         test "$(bd_status T1)" = closed
_need "exit 0"                                        test "$RUN_EXIT" -eq 0
_need "NO TOOL_ERROR incident despite 2 is_error:true" bash -c '! grep -q "TOOL_ERROR" "'"$WORKDIR"'/.beads/runner-logs/incidents.log" 2>/dev/null'
_need "NO 'tool-error' note (pattern-not-count)"      bash -c '! grep -q "tool-error" "'"$BD_STORE"'/T1/notes" 2>/dev/null'
_need "no spurious notification for benign probes"    notcontains "$(notify_log)" "subagent unavailable"
_emit
H_cleanup
