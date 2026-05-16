#!/bin/bash
# BC-31 — Preflight asset snapshot surfaces silent agent failure from line 1
#         but is DIAGNOSTIC-ONLY: a 0-agent count does NOT abort the run.
# Binds: INTERFACE.md v1 §8.2 (preflight/forensic snapshot; non-aborting is
#        itself characterized behavior — hard-gating it is a behavior change).
# SCAR (silent-when-wrong): wrong cwd / empty .claude/agents ⇒ agents that
#        worked interactively silently fail inside `claude`. The non-abort is
#        deliberate (a count of 0 still proceeds).
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

# 0 project agents (the WORKDIR has no .claude/) ⇒ count printed, run PROCEEDS.
H_init_test bc31-zero-agents-proceeds
bd_seed T1 "still runs" "x"
claude_plan success
run_runner
ld="$WORKDIR/.beads/runner-logs"
_expect "BC-31" "§8.2" "0 project agents ⇒ count surfaced, run NOT aborted (diagnostic-only)"
_need "one-line count printed (0 agents, 0 skills)" matches "$(out)" "Pre-flight: 0 project agent\(s\), 0 project skill\(s\)"
_need "preflight.log written with env snapshot"     bash -c 'grep -q "=== preflight" "'"$ld"'/preflight.log" 2>/dev/null'
_need "preflight.log records missing agents dir"    contains "$(cat "$ld/preflight.log" 2>/dev/null)" "(no .claude/agents directory)"
_need "NON-ABORTING: the task still ran + closed"   test "$(bd_status T1)" = closed
_need "NON-ABORTING: clean drain exit 0"            test "$RUN_EXIT" -eq 0
_emit
H_cleanup

# The count reflects REALITY (not a constant): seed a real agent + skill ⇒ the
# line reports 1/1. Proves the "0 ⇒ proceed" case is a genuine measurement.
H_init_test bc31-count-is-real
mkdir -p "$WORKDIR/.claude/agents" "$WORKDIR/.claude/skills/demo"
printf 'name: x\n' > "$WORKDIR/.claude/agents/foo.md"
bd_seed T1 "counts assets" "x"
claude_plan success
run_runner
_expect "BC-31" "§8.2" "preflight count is a real measurement (1 agent, 1 skill)"
_need "count line reflects the seeded assets" matches "$(out)" "Pre-flight: 1 project agent\(s\), 1 project skill\(s\)"
_need "run still proceeded + closed"          test "$(bd_status T1)" = closed
_emit
H_cleanup
