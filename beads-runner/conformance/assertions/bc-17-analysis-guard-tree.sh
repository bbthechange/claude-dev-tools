#!/bin/bash
# BC-17 — Failed task is BLOCKED-BY a fresh analysis child; analysis-of-analysis
#         infinite chains are GUARDED (NAMED guard message). (v2 -tree
#         coverage-hardening, claude-tools-v2cut.5)
#
# Binds: BEHAVIORAL-CONTRACT.md §8 BC-17. create_analysis_task (runner.sh:799-
# 834) on an escalating class (here CONTEXT_OVERFLOW) creates a new beads issue
# titled "Analyze failure: <title>" with labels `model:opus,analysis`, runs
# `bd dep add <failed-task> <analysis-task>` so the failed task is BLOCKED BY
# the analysis child (won't be re-picked until the analysis closes), and
# appends a pointer note. The GUARD (runner.sh:803-806): if the failing task
# ALREADY carries the `analysis` label, NO child is created and the runner
# prints the exact line:
#   "  (Skipping analysis task creation — this is already an analysis task)"
# Without that guard an analysis-of-an-analysis spawns a grandchild → infinite
# chain (the SCAR). This rig drives both halves black-box (analysis_count +
# the guard message via out()).
#
# TARGET — the analysis/guard logic lives in the forward rewrite runner.sh.
# Same re-point pattern as bc-58/bc-22: reuse the harness library, repoint
# $RUNNER. The guard STRING is asserted against v2's ACTUAL output, not v1's.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# ── BLOCK 1 · NORMAL task overflows ⇒ exactly one analysis child, task BLOCKED-BY it
H_init_test bc17tree-normal-creates-analysis
bd_seed T1 "normal task" "x"
claude_plan overflow success
run_runner
o="$(out)"
_expect "BC-17" "§8" "normal task overflow ⇒ ONE analysis child (htest-) created and the failed task is blocked-by it (runner.sh)"
_need "CONTEXT_OVERFLOW incident recorded"           inc_has T1 CONTEXT_OVERFLOW
_need "exactly one analysis child created"           test "$(analysis_count)" -eq 1
_need "analysis child id is an htest- bead"          matches "$(analysis_ids)" '^htest-'
_need "the analysis child carries the 'analysis' label" \
      bash -c 'grep -qE "(^|,)analysis(,|$)" "'"$BD_STORE"'/$(ls -1 "'"$BD_STORE"'" | grep "^htest-" | head -1)/labels"'
_need "T1 was made blocked-by the analysis child (dep wired to an htest- id)" \
      bash -c 'grep -q "^htest-" "'"$BD_STORE"'/T1/deps" 2>/dev/null'
_need "runner printed the 'Created analysis task' line" \
                                                     contains "$o" "Created analysis task"
_need "runner did NOT print the analysis-guard skip on a normal task" \
                                                     notcontains "$o" "Skipping analysis task creation"
_emit
H_cleanup

# ── BLOCK 2 · task ALREADY labelled `analysis` overflows ⇒ NO grandchild + guard
# Seed T1 carrying the `analysis` label, then overflow it. The §8 guard must
# fire: create_analysis_task short-circuits BEFORE `bd create`, so NO new
# htest- child appears (analysis_count stays 0 — the seed itself is NOT an
# htest- id, so the count cleanly reflects "no grandchild spawned"), and the
# runner prints the EXACT named guard message. The trailing `success` drains
# the (re-opened) analysis task so the loop terminates instead of re-overflowing
# forever.
H_init_test bc17tree-analysis-guard-fires
bd_seed T1 "an analysis task" "x" open analysis
claude_plan overflow success
run_runner
o="$(out)"
_expect "BC-17" "§8" "a task already labelled 'analysis' that overflows ⇒ NO grandchild + the named guard message (runner.sh)"
_need "CONTEXT_OVERFLOW incident still recorded (it DID fail)" \
                                                     inc_has T1 CONTEXT_OVERFLOW
_need "NO analysis grandchild created (guard fired)" test "$(analysis_count)" -eq 0
_need "the EXACT v2 guard message printed" \
      contains "$o" "Skipping analysis task creation — this is already an analysis task"
_need "guard short-circuited BEFORE create (no 'Created analysis task' line)" \
                                                     notcontains "$o" "Created analysis task"
_need "task ultimately drained (exit 0)"             test "$RUN_EXIT" -eq 0
_emit
H_cleanup

# ── BLOCK 3 · SOURCE-STRUCTURAL · the guard is keyed on the `analysis` label and
# precedes the `bd create`, and the wiring (title / model:opus,analysis labels /
# dep add) is intact. This proves the guard's MECHANISM (the named string is
# v2's) rather than only its effect — defends against a future refactor that
# moves the skip-print without the label check, or wires the dep the wrong way.
H_init_test bc17tree-guard-source
bd_seed T1 "src" "x"
_expect "BC-17" "§8" "guard keyed on 'analysis' label, prints the named skip, and child wiring (title/labels/dep) intact (runner.sh)"
_need "guard selects on the 'analysis' label" \
      grep -qE 'select\(\. == "analysis"\)' "$RUNNER"
_need "guard prints the exact named skip message" \
      grep -qF 'Skipping analysis task creation — this is already an analysis task' "$RUNNER"
_need "child created with the model:opus,analysis labels" \
      grep -qE '\-\-labels "model:opus,analysis"' "$RUNNER"
_need "child titled 'Analyze failure: <title>'" \
      grep -qE '\-\-title "Analyze failure: \$task_title"' "$RUNNER"
_need "failed task wired blocked-by via 'bd dep add <task> <analysis>'" \
      grep -qE 'bd dep add "\$task_id" "\$analysis_id"' "$RUNNER"
_emit
H_cleanup
