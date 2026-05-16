#!/bin/bash
# BC-23 — Uniform, greppable beads note on EVERY non-success classification.
# Binds: INTERFACE.md v1 §8.2 (terminal-reason re-home — the per-task
#        observability seam a human/tool greps `bd show` for `Runner:`).
# SCAR (silent-when-wrong): ad-hoc per-class note text breaks grep-based
#        triage — the uniform `Runner: <CLASS> at <ts> — …` prefix IS the seam.
#
# ANTI-OVERLAP (T1a non-overlap): T1a/bc-09 asserts the note EXISTS for the
# single TASK_NOT_CLOSED class. BC-23's distinct contract is the *uniform
# shape across DIFFERENT classes* and the `— log: <path>` ↔ `— no stream
# preserved` suffix dichotomy. Not a re-implementation of a runner-local rig.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

# A PRESERVED class (SERVER_ERROR) ⇒ note carries the `— log: <path>` suffix.
H_init_test bc23-preserved-note
bd_seed T1 "server then ok" "x"
claude_plan server success
run_runner
_expect "BC-23" "§8.2" "preserved class ⇒ 'Runner: <CLASS> at <HH:MM:SSZ> — log: <path>'"
_need "uniform Runner: prefix, anchored"      matches "$(notes_of T1)" '^Runner: SERVER_ERROR at [0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'
_need "preserved-stream log: path suffix"     matches "$(notes_of T1)" 'Runner: SERVER_ERROR at .* log: .*-SERVER_ERROR\.jsonl'
_emit
H_cleanup

# A NON-preserved routine class (RATE_LIMIT) ⇒ '— no stream preserved' suffix,
# SAME uniform prefix.
H_init_test bc23-nostream-note
bd_seed T1 "rate then ok" "x"
claude_plan ratelimit success
run_runner
_expect "BC-23" "§8.2" "non-preserved class ⇒ same prefix + '— no stream preserved'"
_need "same uniform Runner: prefix shape"     matches "$(notes_of T1)" '^Runner: RATE_LIMIT at [0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'
_need "explicit 'no stream preserved' suffix" contains "$(notes_of T1)" "no stream preserved"
_need "greppable seam: every note line ^Runner:" bash -c '! grep -qvE "^Runner: " "'"$BD_STORE"'/T1/notes"'
_emit
H_cleanup
