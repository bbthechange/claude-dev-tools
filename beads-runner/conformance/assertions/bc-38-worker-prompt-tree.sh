#!/bin/bash
# BC-38 (FORWARD) — Worker prompt forbids human-in-the-loop, prescribes the
#   §7.2(a) instructed STUCK primary path + debrief-then-close, and the worker
#   is launched with the §7.6 --disallowedTools guardrail keeping stream-json.
#   (T2.5, claude-tools-kqn.)
# Binds: INTERFACE.md v1 §7.6 (guardrail) + §7.2(a) (instructed primary path)
#        + BC-38 (prompt content, literal substitution).
#
# TARGET — the worker prompt + AD3.5 guardrail live in the forward rewrite
# target runner.sh, NOT v1 run-beads-tasks.sh (the untouched
# bc-38-worker-prompt.sh keeps v1 regression-green and its --disallowedTools
# clause stays a GATE there). Same re-point precedent as bc-21-exit-codes-tree
# / bc-09-…-tree: reuse the T1a harness *library*, reassign $RUNNER only.
#
# SCAR (silent-when-wrong): an unattended worker that plans/asks instead of
# executing silently stalls; a missing honest debrief blinds human review; a
# worker with no instructed STUCK path silently abandons a real human-decision
# fork. The rewrite must do NONE of these — and the guardrail is
# defense-in-depth BEHIND the instructed prohibition, not instead of it.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

H_init_test bc38tree-worker-prompt
bd_seed T1 "Implement widget" "Build the widget per spec and tests."
claude_plan success
run_runner
p="$(prompt_text)"

_expect "BC-38" "§7.6" "prompt forbids EnterPlanMode/ExitPlanMode + AskUserQuestion, non-interactive (runner.sh)"
_need "states running non-interactively"   contains "$p" "running non-interactively"
_need "forbids EnterPlanMode/ExitPlanMode"  contains "$p" "Do NOT use EnterPlanMode or ExitPlanMode"
_need "forbids AskUserQuestion"             contains "$p" "Do NOT use AskUserQuestion"
_need "says execute directly"               contains "$p" "Just execute the work directly"
_emit

# §7.2(a) step 3 is the LABEL op `bd label add <id> human`, not `bd human <id>`:
# `bd human <id>` no-ops in this bd build (human is a command GROUP; the
# human-needed signal is the `human` LABEL the §7.2 PRIMARY detector keys on).
# Owner decision — commit 9377103 "I5 rehearsal" D4 (INTERFACE.md §7.2 reconciled).
_expect "BC-38" "§7.2" "prompt prescribes the instructed STUCK primary path (AD3.1) (runner.sh)"
_need "ordered: status=blocked first"       contains "$p" "bd update T1 --status=blocked"
_need "structured ask: TL;DR"               contains "$p" "TL;DR"
_need "structured ask: options"             contains "$p" "the options"
_need "structured ask: recommendation+why"  contains "$p" "your recommendation and why"
_need "structured ask: reversibility"       contains "$p" "how reversible each option is"
_need "then bd label add human"             contains "$p" "bd label add T1 human"
_need "then exit the stuck sentinel"        contains "$p" "Exit with status code 7"
_emit

# claude-tools-gqyp — the ask must be HEADED by the canonical machine marker
# `HUMAN DECISION NEEDED`. The runner's recency-independent backstop (Net 2:
# _bead_has_stuck_ask_note / _bead_blocked_for_human) keys on this marker; 309l
# keyed on STUCK_NEEDS_HUMAN, which this protocol NEVER emits, so a correctly-
# escalated fork could still thrash through TASK_NOT_CLOSED→reset→analysis when
# Net 1's single status read lost the race (casualty claude-tools-o0yq). This pins
# the PRODUCER side of the contract; the consumer side is locked by
# lib/test-309l-v2-classify.sh + lib/test-belt-aged-human.sh.
_expect "BC-38" "§7.2" "the human-fork ask is headed by the canonical HUMAN DECISION NEEDED marker (claude-tools-gqyp) (runner.sh)"
_need "prompt names the HUMAN DECISION NEEDED marker"   contains "$p" "HUMAN DECISION NEEDED"
_need "marker is in the --append-notes ask, kept verbatim" contains "$p" "keep that marker verbatim"
_emit

_expect "BC-38" "§7.6" "prompt prescribes debrief-then-close with honesty directive (runner.sh)"
_need "debrief via --append-notes"          contains "$p" "bd update T1 --append-notes="
_need "honesty directive present"           contains "$p" "Be honest"
_need "explicit close instruction"          contains "$p" "bd close T1"
_emit

_expect "BC-38" "§7.6" "task id/title/desc substituted by literal replacement (runner.sh)"
_need "title substituted"                   contains "$p" "Implement widget"
_need "description substituted"             contains "$p" "Build the widget per spec and tests."
_need "no literal BEADS_ID token left"      notcontains "$p" "BEADS_ID"
_need "no literal BEADS_DESC token left"    notcontains "$p" "BEADS_DESC"
_need "no literal BEADS_STUCK_EXIT left"    notcontains "$p" "BEADS_STUCK_EXIT"
_emit

# claude-tools-m0yv — same gate-wait discipline carried into the forward
# rewrite prompt. The v1 worker consumed the offline gate via `| tail -40`
# (non-streaming), saw nothing, declared it wedged, and RELAUNCHED it. The
# shared prompt now pins: run once · stream-watch · non-blocking wait · never
# relaunch a quiet gate. Kept in lockstep with bc-38-worker-prompt.sh.
_expect "BC-38" "§7.6" "prompt pins gate-wait discipline (claude-tools-m0yv) (runner.sh)"
_need "names the gate-wait discipline"      contains "$p" "gate-wait discipline"
_need "run a long command exactly once"     contains "$p" "Run it EXACTLY ONCE"
_need "never relaunch a quiet gate"         contains "$p" "NEVER relaunch a long-running command because it looks quiet"
_need "forbids non-streaming tail -N"       contains "$p" "buffers ALL its input and emits nothing until the pipe closes"
_need "blessed wait: run_in_background"      contains "$p" "run_in_background"
_need "forbids sleep-chaining"              contains "$p" "the harness blocks sleep-chaining"
_emit

# ── §7.6 guardrail — now MET on runner.sh (a hard assertion, not a gate) ──────
_expect "BC-38" "§7.6" "worker invoked with --disallowedTools guardrail + KEEPS stream-json (runner.sh)"
_need "--disallowedTools on the claude invocation" \
      grep -q -- "--disallowedTools" "$HARNESS_OUT/last-argv.txt"
_need "AskUserQuestion disallowed"   grep -q -- "AskUserQuestion"  "$HARNESS_OUT/last-argv.txt"
_need "EnterPlanMode disallowed"     grep -q -- "EnterPlanMode"    "$HARNESS_OUT/last-argv.txt"
_need "ExitPlanMode disallowed"      grep -q -- "ExitPlanMode"     "$HARNESS_OUT/last-argv.txt"
_need "stream-json KEPT (backstop needs permission_denials[])" \
      grep -q -- "stream-json" "$HARNESS_OUT/last-argv.txt"
_emit
H_cleanup
