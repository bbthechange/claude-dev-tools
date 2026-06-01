#!/bin/bash
# BC-19 (FORWARD / v2) — the CONTEXT_OVERFLOW analysis reason carries class-
#   specific SALVAGE guidance, including the model:opus RELABEL sentence that the
#   pre-BC-32 v2 skeleton had truncated. (claude-tools-v2cut.4 — keep/restore
#   decision: RESTORE, now that BC-32 makes the relabel meaningful.)
#
# Binds: BEHAVIORAL-CONTRACT.md §8 BC-19. On CONTEXT_OVERFLOW, st_post_task calls
# create_analysis_task with a reason string that (a) tells the next agent to
# inspect git log/diff for already-committed work, (b) re-scope to ONLY the
# remaining steps, (c) split if too large, and (d) RELABEL the re-scoped task
# model:opus (the runner now auto-selects the 1M-context Opus variant — BC-32).
# create_analysis_task embeds `$reason` verbatim into the analysis bead's
# description, so the restored salvage prose is observable there.
# SCAR: losing this prose makes the next agent redo or discard completed work.
#
# TARGET — the forward rewrite runner.sh.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# Overflow T1 ⇒ an analysis child (htest-) is created; its description embeds the
# overflow reason string. `overflow success` drains cleanly (the analysis child
# then succeeds, T1 unblocks + succeeds), so the run terminates.
H_init_test bc19tree-salvage-restored
bd_seed T1 "overflow task" "x"
claude_plan overflow success
run_runner
aid="$(analysis_ids | head -1)"
adesc="$(cat "$BD_STORE/$aid/desc" 2>/dev/null)"
_expect "BC-19" "§8" "CONTEXT_OVERFLOW analysis reason carries the FULL salvage guidance incl. the model:opus relabel (runner.sh)"
_need "an analysis child was created"                       matches "$aid" "^htest-"
_need "salvage: inspect git log/diff for committed work"    contains "$adesc" "inspect git log / git diff"
_need "salvage: re-scope to ONLY the remaining steps"       contains "$adesc" "re-scope this task to ONLY the remaining steps"
_need "salvage: split into smaller dependent tasks"         contains "$adesc" "split it into smaller dependent tasks"
_need "salvage: the RESTORED model:opus relabel sentence"   contains "$adesc" "relabel the re-scoped task model:opus"
_need "salvage: names the 1M-context Opus variant"          contains "$adesc" "1M-context Opus variant"
_emit
H_cleanup
