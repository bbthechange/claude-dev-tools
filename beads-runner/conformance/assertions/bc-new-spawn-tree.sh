#!/bin/bash
# BC-NEW-SPAWN — exact `claude` flag assembly + BC-46 GUARDRAIL_FLAGS trio
#                (v2 -tree coverage-hardening, claude-tools-v2cut.5)
#
# PROVES: v2 runner.sh's st_run_task spawns the worker (~2123-2131) with the
# load-bearing flag set the contract §21 BC-NEW-SPAWN / BC-46 requires:
#   -p <prompt>  --output-format stream-json  --verbose  --model <DEFAULT_MODEL>
#   --disallowedTools AskUserQuestion EnterPlanMode ExitPlanMode   (GUARDRAIL_FLAGS, ~157)
# stream-json is load-bearing (a `text` format hides result.permission_denials[]
# the §7.2(b) backstop reads); --verbose is required by stream-json; the guardrail
# trio removes the three interactive tools at the tool layer (defense-in-depth
# behind BC-38's prompt prohibition). Black-box: the fake claude records its argv
# one-token-per-line to $HARNESS_OUT/last-argv.txt.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"   # repoint to v2
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# argv_after <flag> — the token the spawned claude received immediately after
# <flag> (one token per line in last-argv.txt).
argv_after() { awk -v f="$1" '$0==f{getline; print; exit}' "$HARNESS_OUT/last-argv.txt" 2>/dev/null; }
argv_text()  { cat "$HARNESS_OUT/last-argv.txt" 2>/dev/null || true; }
# argv_trio_after <flag> — the THREE tokens after <flag>, space-joined (for the
# --disallowedTools AskUserQuestion EnterPlanMode ExitPlanMode contiguous trio).
argv_trio_after() { awk -v f="$1" '$0==f{getline a; getline b; getline c; print a, b, c; exit}' \
                      "$HARNESS_OUT/last-argv.txt" 2>/dev/null; }

# ── the full flag assembly reaching the spawned worker ───────────────────────
H_init_test bcspawntree-flagset
bd_seed T1 "task one" "do a thing"
claude_plan success
export DEFAULT_MODEL="opus[1m]"
run_runner
av="$(argv_text)"
_expect "BC-NEW-SPAWN" "§21" "v2 st_run_task spawns claude with the load-bearing flag assembly (runner.sh ~2123)"
_need "worker actually spawned (T1 closed)"           test "$(bd_status T1)" = closed
_need "argv carries -p (the prompt flag)"             contains "$av" "-p"
_need "argv carries --output-format"                  contains "$av" "--output-format"
_need "--output-format value is stream-json (text would hide permission_denials[])" \
                                                      test "$(argv_after --output-format)" = "stream-json"
_need "argv carries --verbose (required by stream-json)" contains "$av" "--verbose"
_need "argv carries --model"                          contains "$av" "--model"
_need "--model value is DEFAULT_MODEL (opus[1m])"     test "$(argv_after --model)" = "opus[1m]"
_emit
H_cleanup

# ── BC-46 GUARDRAIL_FLAGS — the contiguous --disallowedTools trio ────────────
H_init_test bcspawntree-guardrail-trio
bd_seed T1 "task one" "do a thing"
claude_plan success
run_runner
av="$(argv_text)"
_expect "BC-46" "§21" "GUARDRAIL_FLAGS removes the three interactive tools at the tool layer (runner.sh ~157)"
_need "worker spawned (T1 closed)"                    test "$(bd_status T1)" = closed
_need "argv carries --disallowedTools"                contains "$av" "--disallowedTools"
_need "the trio after --disallowedTools is exactly Ask/Enter/Exit PlanMode" \
      test "$(argv_trio_after --disallowedTools)" = "AskUserQuestion EnterPlanMode ExitPlanMode"
_need "AskUserQuestion is disallowed"                 contains "$av" "AskUserQuestion"
_need "EnterPlanMode is disallowed"                   contains "$av" "EnterPlanMode"
_need "ExitPlanMode is disallowed"                    contains "$av" "ExitPlanMode"
# Source-structural: the guardrail is a SEPARATE array from EXTRA_CLAUDE_FLAGS so a
# project .beads/runner.sh overriding EXTRA_CLAUDE_FLAGS wholesale cannot drop it.
_need "GUARDRAIL_FLAGS defined as its own array in runner.sh" \
      grep -qE '^GUARDRAIL_FLAGS=\(--disallowedTools AskUserQuestion EnterPlanMode ExitPlanMode\)' "$RUNNER"
_emit
H_cleanup
