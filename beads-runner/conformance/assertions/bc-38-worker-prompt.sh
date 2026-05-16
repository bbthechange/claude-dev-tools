#!/bin/bash
# BC-38 — Worker prompt forbids human-in-the-loop and prescribes
#         debrief-then-close; task fields substituted by literal replacement.
# Binds: INTERFACE.md v1 §7.6 (worker guardrail — the FORWARD contract adds
#        `--disallowedTools AskUserQuestion EnterPlanMode ExitPlanMode`;
#        the instructed prohibition in the prompt is the CURRENT behavior).
# SCAR (current behavior): the no-plan/no-ask rule + mandatory honest debrief
#        are load-bearing for unattended runs and human review.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

H_init_test bc38-worker-prompt
bd_seed T1 "Implement widget" "Build the widget per spec and tests."
claude_plan success
run_runner
p="$(prompt_text)"

_expect "BC-38" "§7.6" "prompt forbids EnterPlanMode/ExitPlanMode + AskUserQuestion, non-interactive"
_need "states running non-interactively"   contains "$p" "running non-interactively"
_need "forbids EnterPlanMode/ExitPlanMode"  contains "$p" "Do NOT use EnterPlanMode or ExitPlanMode"
_need "forbids AskUserQuestion"             contains "$p" "Do NOT use AskUserQuestion"
_need "says execute directly"               contains "$p" "Just execute the work directly"
_emit

_expect "BC-38" "§7.6" "prompt prescribes debrief-then-close with honesty directive"
_need "debrief via --append-notes"          contains "$p" "bd update T1 --append-notes="
_need "honesty directive present"           contains "$p" "Be honest"
_need "explicit close instruction"          contains "$p" "bd close T1"
_emit

_expect "BC-38" "§7.6" "task id/title/desc substituted by literal replacement"
_need "title substituted"                   contains "$p" "Implement widget"
_need "description substituted"             contains "$p" "Build the widget per spec and tests."
_need "no literal BEADS_ID token left"      notcontains "$p" "BEADS_ID"
_need "no literal BEADS_DESC token left"     notcontains "$p" "BEADS_DESC"
_emit

# ── FORWARD GATE (§7.6): worker guardrail flags ──────────────────────────────
# §7.6 mandates the worker run with --disallowedTools AskUserQuestion
# EnterPlanMode ExitPlanMode (defense-in-depth behind the instructed
# prohibition). The CURRENT script passes no such flag. T2 MUST add it.
_gate "BC-38" "§7.6" "worker invoked with --disallowedTools guardrail (T2 gate)"
_need "post-T2: --disallowedTools on the claude invocation" \
      grep -q -- "--disallowedTools" "$HARNESS_OUT/last-argv.txt"
_emit
H_cleanup
