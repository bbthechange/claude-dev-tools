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

# claude-tools-m0yv — the worker consumed the offline gate via `| tail -40`
# (non-streaming), saw zero output, declared it wedged, and RELAUNCHED it,
# stampeding run-tests.sh. The fix is consumption-side: the shared prompt now
# pins gate-wait discipline (run once · stream-watch · non-blocking wait · no
# relaunch). SCAR: a worker that blinds itself to a long gate stalls or piles
# concurrent gates that contend the shared workSnapshot()/Dolt seam.
_expect "BC-38" "§7.6" "prompt pins gate-wait discipline (claude-tools-m0yv)"
_need "names the gate-wait discipline"      contains "$p" "gate-wait discipline"
_need "run a long command exactly once"     contains "$p" "Run it EXACTLY ONCE"
_need "never relaunch a quiet gate"         contains "$p" "NEVER relaunch a long-running command because it looks quiet"
_need "forbids non-streaming tail -N"       contains "$p" "buffers ALL its input and emits nothing until the pipe closes"
_need "blessed wait: run_in_background"      contains "$p" "run_in_background"
_need "forbids sleep-chaining"              contains "$p" "the harness blocks sleep-chaining"
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
