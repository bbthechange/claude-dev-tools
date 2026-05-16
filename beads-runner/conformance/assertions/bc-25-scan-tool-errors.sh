#!/bin/bash
# BC-25 — `scan_tool_errors`: PATTERN-matched, side-effect-only, never changes
#         classification or exit code. Raw is_error counts deliberately unused.
# Binds: INTERFACE.md v1 §8.2 (forensic side-channel — surface an
#        inline-recovered tool failure WITHOUT failing the run).
# SCAR (silent-when-wrong): an inline-recovered missing-subagent still means
#        the agent didn't do what we asked — surface it; but raw is_error
#        counts would be dominated by routine probes (Read-miss, grep-no-match).
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

# POSITIVE: a pattern-matched signature (subagent-not-found) is surfaced as a
# TOOL_ERROR incident + beads note, while classification stays SUCCESS, exit 0.
H_init_test bc25-subagent-surfaced
bd_seed T1 "recovers inline" "x"
claude_plan subagent_err_then_success
run_runner
ld="$WORKDIR/.beads/runner-logs"
_expect "BC-25" "§8.2" "matched tool-error surfaced as side-effect; classification/exit UNCHANGED"
_need "classification stayed SUCCESS (bead closed)"   test "$(bd_status T1)" = closed
_need "exit code unchanged by the scan (0)"           test "$RUN_EXIT" -eq 0
_need "TOOL_ERROR:subagent-unavailable incident row"  contains "$(incidents_log)" "TOOL_ERROR:subagent-unavailable"
_need "greppable 'tool-error' beads note appended"    matches "$(notes_of T1)" "Runner: tool-error subagent-unavailable"
_need "scan did NOT manufacture a failure class"      bash -c '! grep -qE "(SERVER_ERROR|UNKNOWN_FAILURE|TASK_NOT_CLOSED|RATE_LIMIT)" "'"$ld"'/incidents.log" 2>/dev/null'
_need "side-effect-only: SUCCESS preserved no stream" bash -c '! ls "'"$ld"'"/T1-*.jsonl >/dev/null 2>&1'
_emit
H_cleanup

# NEGATIVE (the precise SCAR): TWO is_error:true tool_results that match NONE
# of the three signatures (routine probes). Raw-count logic would flag 2;
# pattern logic must surface ZERO.
H_init_test bc25-pattern-not-count
bd_seed T1 "benign probes" "x"
claude_plan benign_err_then_success
run_runner
_expect "BC-25" "§8.2" "raw is_error count NOT used — unmatched routine probes surface nothing"
_need "bead closed (SUCCESS)"                         test "$(bd_status T1)" = closed
_need "exit 0"                                        test "$RUN_EXIT" -eq 0
_need "NO TOOL_ERROR incident despite 2 is_error:true" bash -c '! grep -q "TOOL_ERROR" "'"$WORKDIR"'/.beads/runner-logs/incidents.log" 2>/dev/null'
_need "NO 'tool-error' note (pattern-not-count)"      bash -c '! grep -q "tool-error" "'"$BD_STORE"'/T1/notes" 2>/dev/null'
_emit
H_cleanup
