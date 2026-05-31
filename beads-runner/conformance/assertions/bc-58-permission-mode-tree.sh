#!/bin/bash
# BC-58 (FORWARD / v2) — per-task permission-mode auto-selection (claude-tools-qcoe).
#
# Binds: BEHAVIORAL-CONTRACT.md §12 BC-58. v1 resolves the worker's
# `--permission-mode` from the task MODEL: Opus supports `--permission-mode
# auto` (LLM-classified auto-approval, still honoring permissions.deny); Sonnet
# silently downgrades auto→default in headless (= blocks on the first prompt =
# watchdog kill), so non-Opus keeps the workspace acceptEdits+allowlist flags.
#
# This is a claude-tools-v2c1 PORT-FORWARD fix (runner.sh:186-198) that had NO
# regression assertion — the claude-tools-v2c3 deliverable "a NEW regression
# assertion for every v2c1-ported fix." v2's mechanism differs from v1: it
# resolves TASK_PERMISSION_FLAGS ONCE at startup against DEFAULT_MODEL (v2 has a
# single per-runner model, not v1's per-task `model:` label — that per-task
# split is BC-32, filed as a separate v2 port). So this rig drives DEFAULT_MODEL
# and asserts the resolved flag reaching the spawned `claude` argv.
#
# SCAR (silent-when-wrong): pass Sonnet `--permission-mode auto` and every
# worker blocks headless on its first tool call; pass Opus only acceptEdits and
# it loses the auto auto-approval the runner depends on.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# argv_after <flag> — the token the spawned claude received immediately after
# <flag> (the fake claude records argv one-per-line to last-argv.txt).
argv_after() { awk -v f="$1" '$0==f{getline; print; exit}' "$HARNESS_OUT/last-argv.txt" 2>/dev/null; }
argv_text()  { cat "$HARNESS_OUT/last-argv.txt" 2>/dev/null || true; }

# ── Opus (the skeleton default opus[1m]) ⇒ --permission-mode auto ────────────
H_init_test bc58tree-opus-auto
bd_seed T1 "task one" "do a thing"
claude_plan success
export DEFAULT_MODEL="opus[1m]"
run_runner
_expect "BC-58" "§12" "Opus DEFAULT_MODEL ⇒ worker spawned with --permission-mode auto (runner.sh)"
_need "T1 closed (worker actually spawned)"          test "$(bd_status T1)" = closed
_need "claude got --permission-mode auto"            test "$(argv_after --permission-mode)" = "auto"
_need "Opus must NOT carry acceptEdits"              notcontains "$(argv_text)" "acceptEdits"
_emit
H_cleanup

# ── bare `opus` form also matches the opus*) case ────────────────────────────
H_init_test bc58tree-opus-bare
bd_seed T1 "task one" "do a thing"
claude_plan success
export DEFAULT_MODEL="opus"
run_runner
_expect "BC-58" "§12" "bare 'opus' DEFAULT_MODEL also ⇒ --permission-mode auto (opus*) glob) (runner.sh)"
_need "T1 closed"                                    test "$(bd_status T1)" = closed
_need "claude got --permission-mode auto"            test "$(argv_after --permission-mode)" = "auto"
_emit
H_cleanup

# ── Sonnet ⇒ keeps the workspace acceptEdits flags (NOT auto) ─────────────────
H_init_test bc58tree-sonnet-acceptedits
bd_seed T1 "task one" "do a thing"
claude_plan success
export DEFAULT_MODEL="sonnet"
run_runner
_expect "BC-58" "§12" "Sonnet DEFAULT_MODEL ⇒ acceptEdits, NOT --permission-mode auto (runner.sh)"
_need "T1 closed"                                    test "$(bd_status T1)" = closed
_need "claude got --permission-mode acceptEdits"     test "$(argv_after --permission-mode)" = "acceptEdits"
_need "Sonnet must NOT get auto"                     bash -c '[[ "$(awk -v f=--permission-mode '"'"'$0==f{getline;print;exit}'"'"' "'"$HARNESS_OUT"'/last-argv.txt")" != "auto" ]]'
_emit
H_cleanup
