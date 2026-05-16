#!/bin/bash
# BC-27 — LOG_DIR is a self-gitignoring SECURITY boundary.
# Binds: INTERFACE.md v1 §8.2 / §10 (forensic boundary — stream-json holds raw
#        model output, file contents, tool I/O; it must never reach git).
# SCAR (security, must survive in spirit AND strength): a rewrite that writes
#        post-mortems to any committable path leaks source/secrets into history.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

# Helpers (kept out of _need to avoid nested-quote fragility).
gi_exact()    { [[ "$(cat "$1" 2>/dev/null)" == $'*\n!.gitignore' ]]; }
git_ignored() { git -C "$WORKDIR" check-ignore -q "$1"; }
no_jsonl_in_status() { ! git -C "$WORKDIR" status --porcelain --ignored=no 2>/dev/null | grep -q '\.jsonl'; }

# A preserved class (SERVER_ERROR) writes a stream-json under LOG_DIR. The
# .gitignore is created-if-absent (we never seed it) and must gitignore that
# artifact while leaving the boundary file itself committable.
H_init_test bc27-self-gitignore
bd_seed T1 "leak check" "x"
claude_plan server success
run_runner

ld="$WORKDIR/.beads/runner-logs"
stream=$(ls "$ld"/T1-*-SERVER_ERROR.jsonl 2>/dev/null | head -1)
rel_stream="${stream#"$WORKDIR"/}"

_expect "BC-27" "§10" "LOG_DIR self-gitignores every artifact; boundary created if absent"
_need "a stream artifact was actually written"        test -n "$stream"
_need ".gitignore created if absent"                  test -f "$ld/.gitignore"
_need ".gitignore content EXACTLY '*' then '!.gitignore'" gi_exact "$ld/.gitignore"
_need "stream-json IS git-ignored (boundary holds)"   git_ignored "$rel_stream"
_need ".gitignore itself NOT ignored (persists in-tree)" bash -c '! git -C "'"$WORKDIR"'" check-ignore -q ".beads/runner-logs/.gitignore"'
_need "git status never surfaces a .jsonl artifact"   no_jsonl_in_status
_emit
H_cleanup
