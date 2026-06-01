#!/bin/bash
# BC-23 — Uniform, greppable beads note on EVERY non-success classification
#         (v2 -tree coverage-hardening, claude-tools-v2cut.5).
# Faithful mirror of bc-23-greppable-notes.sh repointed to the v2 runner.sh.
# v2's append_runner_note (runner.sh:848-854) is byte-identical to v1: it emits
# the uniform `Runner: <CLASS> at <HH:MM:SSZ>` prefix and the `— log: <path>`
# (preserved class) vs `— no stream preserved` (routine) suffix dichotomy. This
# rig proves v2 matches v1 on that greppable §8.2 observability seam.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"   # repoint to v2
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# A PRESERVED class (SERVER_ERROR) ⇒ note carries the `— log: <path>` suffix.
H_init_test bc23tree-preserved-note
bd_seed T1 "server then ok" "x"
claude_plan server success
run_runner
_expect "BC-23" "§8.2" "v2: preserved class ⇒ 'Runner: <CLASS> at <HH:MM:SSZ> — log: <path>'"
_need "uniform Runner: prefix, anchored"      matches "$(notes_of T1)" '^Runner: SERVER_ERROR at [0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'
_need "preserved-stream log: path suffix"     matches "$(notes_of T1)" 'Runner: SERVER_ERROR at .* log: .*-SERVER_ERROR\.jsonl'
_emit
H_cleanup

# A NON-preserved routine class (RATE_LIMIT) ⇒ '— no stream preserved' suffix,
# SAME uniform prefix.
H_init_test bc23tree-nostream-note
bd_seed T1 "rate then ok" "x"
claude_plan ratelimit success
run_runner
_expect "BC-23" "§8.2" "v2: non-preserved class ⇒ same prefix + '— no stream preserved'"
_need "same uniform Runner: prefix shape"     matches "$(notes_of T1)" '^Runner: RATE_LIMIT at [0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'
_need "explicit 'no stream preserved' suffix" contains "$(notes_of T1)" "no stream preserved"
_need "greppable seam: every note line ^Runner:" bash -c '[[ -s "'"$BD_STORE"'/T1/notes" ]] && ! grep -qvE "^Runner: " "'"$BD_STORE"'/T1/notes"'
_emit
H_cleanup
