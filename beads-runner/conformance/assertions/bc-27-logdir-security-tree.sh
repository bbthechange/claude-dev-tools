#!/bin/bash
# BC-27 — LOG_DIR is a self-gitignoring SECURITY boundary (v2 -tree coverage-
#         hardening, claude-tools-v2cut.5).
# Proves: v2 runner.sh creates the self-gitignore (st_claim ~line 399 and
#         st_run_task) with EXACTLY `*` then `!.gitignore`, so a preserved
#         post-mortem stream-json (raw model output / tool I/O) is git-ignored
#         and never reaches history, while the .gitignore boundary file itself
#         stays committable. Faithful mirror of bc-27-logdir-security.sh,
#         RUNNER repointed to the v2 state-machine runner.
#
# v2 -tree coverage-hardening for claude-tools-v2cut.5.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"   # repoint to v2
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# Helpers (kept out of _need to avoid nested-quote fragility) — reused verbatim
# from the plain rig's gi_exact/git_ignored/no_jsonl_in_status.
gi_exact()    { [[ "$(cat "$1" 2>/dev/null)" == $'*\n!.gitignore' ]]; }
git_ignored() { git -C "$WORKDIR" check-ignore -q "$1"; }
no_jsonl_in_status() { ! git -C "$WORKDIR" status --porcelain --ignored=no 2>/dev/null | grep -q '\.jsonl'; }

# A preserved class (SERVER_ERROR) writes a stream-json under LOG_DIR. The
# .gitignore is created-if-absent (we never seed it) and must gitignore that
# artifact while leaving the boundary file itself committable.
H_init_test bc27tree-self-gitignore
bd_seed T1 "leak check" "x"
claude_plan server success
run_runner

ld="$WORKDIR/.beads/runner-logs"
stream=$(ls "$ld"/T1-*-SERVER_ERROR.jsonl 2>/dev/null | head -1)
rel_stream="${stream#"$WORKDIR"/}"

_expect "BC-27" "§10" "v2 LOG_DIR self-gitignores every artifact; boundary created if absent"
_need "a stream artifact was actually written"        test -n "$stream"
_need ".gitignore created if absent"                  test -f "$ld/.gitignore"
_need ".gitignore content EXACTLY '*' then '!.gitignore'" gi_exact "$ld/.gitignore"
_need "stream-json IS git-ignored (boundary holds)"   git_ignored "$rel_stream"
_need ".gitignore itself NOT ignored (persists in-tree)" bash -c '! git -C "'"$WORKDIR"'" check-ignore -q ".beads/runner-logs/.gitignore"'
_need "git status never surfaces a .jsonl artifact"   no_jsonl_in_status
_emit
H_cleanup
