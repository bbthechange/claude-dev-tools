#!/bin/bash
# BC-32 (FORWARD / v2) — per-task label-driven model selection, with the
#   bare-opus→opus[1m] upgrade, the deliberate sonnet non-upgrade, and the
#   BC-58-coupled per-task permission flags. (claude-tools-v2cut.4 port — v2
#   previously had only a single per-runner DEFAULT_MODEL.)
#
# Binds: BEHAVIORAL-CONTRACT.md §12 BC-32 (+ BC-58 coupling). _resolve_task_model
# (runner.sh) reads a `model:<X>` label off EACH task at the top of st_run_task,
# defaults to DEFAULT_MODEL, upgrades bare `opus`→`opus[1m]` (the 1M variant; bare
# opus is the 200K alias), leaves `sonnet`/`sonnet[1m]` EXACTLY as-is (sonnet[1m]
# needs "extra usage" this org disabled), and re-derives TASK_PERMISSION_FLAGS
# from the resolved model: Opus⇒`--permission-mode auto`, else the workspace
# acceptEdits allowlist. The fake claude records its argv to last-argv.txt.
# SCAR: both the silent opus→opus[1m] upgrade and the refusal to touch sonnet
# encode org-billing + window-size lessons.
#
# TARGET — the forward rewrite runner.sh (same re-point pattern as bc-58).
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# argv_after <flag> — the token the spawned claude received right after <flag>.
argv_after() { awk -v f="$1" '$0==f{getline; print; exit}' "$HARNESS_OUT/last-argv.txt" 2>/dev/null; }

# ── model:opus label ⇒ upgraded to opus[1m] AND --permission-mode auto ────────
H_init_test bc32tree-opus-upgrade
bd_seed T1 "opus task" "x" open "model:opus"
claude_plan success
run_runner
_expect "BC-32" "§12" "model:opus label ⇒ bare opus upgraded to opus[1m] + --permission-mode auto (runner.sh)"
_need "T1 closed (worker actually spawned)"          test "$(bd_status T1)" = closed
_need "bare opus upgraded to the 1M variant"         test "$(argv_after --model)" = "opus[1m]"
_need "Opus ⇒ --permission-mode auto (BC-58 coupling)" test "$(argv_after --permission-mode)" = "auto"
_emit
H_cleanup

# ── model:sonnet label ⇒ left EXACTLY as-is + keeps acceptEdits (NOT auto) ─────
H_init_test bc32tree-sonnet-untouched
bd_seed T1 "sonnet task" "x" open "model:sonnet"
claude_plan success
run_runner
_expect "BC-32" "§12" "model:sonnet ⇒ runs sonnet (200K, NOT upgraded) + acceptEdits, not auto (runner.sh)"
_need "T1 closed"                                    test "$(bd_status T1)" = closed
_need "sonnet passed through verbatim (no [1m] upgrade)" test "$(argv_after --model)" = "sonnet"
_need "non-Opus keeps acceptEdits (NOT auto)"        test "$(argv_after --permission-mode)" = "acceptEdits"
_emit
H_cleanup

# ── no model: label ⇒ DEFAULT_MODEL (the skeleton opus[1m]) ───────────────────
H_init_test bc32tree-no-label-default
bd_seed T1 "default model" "x"
claude_plan success
run_runner
_expect "BC-32" "§12" "no model: label ⇒ DEFAULT_MODEL (opus[1m]) (runner.sh)"
_need "T1 closed"                                    test "$(bd_status T1)" = closed
_need "defaults to DEFAULT_MODEL opus[1m]"           test "$(argv_after --model)" = "opus[1m]"
_need "Opus default ⇒ --permission-mode auto"        test "$(argv_after --permission-mode)" = "auto"
_emit
H_cleanup

# ── explicit model:opus[1m] ⇒ passed verbatim (already the 1M variant) + auto ──
H_init_test bc32tree-opus1m-explicit
bd_seed T1 "explicit 1m" "x" open "model:opus[1m]"
claude_plan success
run_runner
_expect "BC-32" "§12" "explicit model:opus[1m] ⇒ verbatim opus[1m] + auto (opus*) glob) (runner.sh)"
_need "T1 closed"                                    test "$(bd_status T1)" = closed
_need "opus[1m] passed through verbatim"             test "$(argv_after --model)" = "opus[1m]"
_need "opus*) glob ⇒ --permission-mode auto"         test "$(argv_after --permission-mode)" = "auto"
_emit
H_cleanup

# ── per-task: a sonnet task and an opus task in ONE run get DIFFERENT models ───
# Proves the resolution is genuinely PER-TASK (not a single per-runner value).
H_init_test bc32tree-per-task-distinct
bd_seed T1 "sonnet one" "x" open "model:sonnet"
claude_plan success
run_runner
m1="$(argv_after --model)"
H_cleanup
H_init_test bc32tree-per-task-distinct-2
bd_seed T1 "opus one" "x" open "model:opus"
claude_plan success
run_runner
m2="$(argv_after --model)"
_expect "BC-32" "§12" "model is resolved PER-TASK — sonnet task ⇒ sonnet, opus task ⇒ opus[1m] (runner.sh)"
_need "sonnet task ran sonnet"  test "$m1" = "sonnet"
_need "opus task ran opus[1m]"  test "$m2" = "opus[1m]"
_emit
H_cleanup
