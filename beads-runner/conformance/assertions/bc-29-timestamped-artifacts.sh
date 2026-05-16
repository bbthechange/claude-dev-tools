#!/bin/bash
# BC-29 — Per-iteration timestamped artifact basenames prevent retry collisions.
# Binds: INTERFACE.md v1 §8.2 (forensic/terminal artifacts around the
#        terminal-reason re-home — distinct post-mortems per attempt).
# SCAR (silent-when-wrong): a 2nd failure's post-mortem clobbers the 1st's —
#        exactly when you most need both.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

# Two SERVER_ERROR failures of the SAME task. `server_slow` spans ~2s so the
# per-iteration UTC ITER_TS differs ⇒ two DISTINCT preserved .jsonl basenames.
H_init_test bc29-distinct-basenames
bd_seed T1 "collides?" "x"
claude_plan server_slow server_slow success
RUN_TIMEOUT=50 run_runner

ld="$WORKDIR/.beads/runner-logs"
n=$(ls -1 "$ld"/T1-*-SERVER_ERROR.jsonl 2>/dev/null | wc -l | tr -d ' ')
_expect "BC-29" "§8.2" "same task failed twice ⇒ two distinct timestamped .jsonl artifacts"
_need "two SERVER_ERROR incidents for T1"      test "$(inc_count T1 SERVER_ERROR)" -eq 2
_need "two distinct preserved stream files (got $n)" test "$n" -eq 2
_emit
H_cleanup
