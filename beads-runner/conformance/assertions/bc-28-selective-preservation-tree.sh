#!/bin/bash
# BC-28 — Selective stream preservation BY CLASS; PROC_SNAPSHOT retained iff
#         final CLASSIFICATION == WATCHDOG_KILL (v2 -tree coverage-hardening,
#         claude-tools-v2cut.5).
# Proves: v2 runner.sh st_post_task drives the §8.2 forensic policy — routine
#         classes (RATE_LIMIT) get an incident row but NO preserved .jsonl
#         (preserve_stream ~856-860 is reached only for the serious class list
#         WATCHDOG_KILL|UNKNOWN_FAILURE|SERVER_ERROR|MAX_OUTPUT_TOKENS|
#         CONTEXT_OVERFLOW, ~2287-2295); WATCHDOG_KILL keeps BOTH the stream
#         .jsonl AND the .proc.txt snapshot; and the precise SCAR — watchdog
#         FIRED but a more-decisive class (SERVER_ERROR) WINS classification ⇒
#         stream kept (SERVER_ERROR is serious) but .proc.txt DELETED, because
#         the proc-snapshot retention (~2424-2429) keys on CLASSIFICATION ==
#         WATCHDOG_KILL, NOT on whether the watchdog fired. Faithful mirror of
#         bc-28-selective-preservation.sh, RUNNER repointed to the v2 runner.
#
# v2-vs-v1 NOTE (block 1): v1 deletes the raw stream-capture after each task, so
# the plain rig could assert no `T1-*.jsonl` at all for a routine class. v2
# DELIBERATELY LEAVES the live `*.stream.jsonl` capture(s) under LOG_DIR
# (runner.sh ~2249-2253: classify/T2.2 consume STREAM_FILE post-task; still
# BC-27 git-ignored). The §8.2 PRESERVATION policy is about the post-mortem COPY
# that preserve_stream names `<base>-<CLASSIFICATION>.jsonl` — so the faithful v2
# observable is "no preserved `*-RATE_LIMIT.jsonl` copy", matching how blocks 2/3
# glob `*-WATCHDOG_KILL.jsonl` / `*-SERVER_ERROR.jsonl`.
#
# v2 -tree coverage-hardening for claude-tools-v2cut.5.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"   # repoint to v2
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# (1) ROUTINE class (RATE_LIMIT) ⇒ NO stream copy, but an incident row exists.
H_init_test bc28tree-routine-no-stream
bd_seed T1 "rate then ok" "x"
claude_plan ratelimit success
run_runner
ld="$WORKDIR/.beads/runner-logs"
_expect "BC-28" "§8.2" "v2 routine class (RATE_LIMIT) ⇒ no preserved post-mortem copy, but incident row kept"
_need "no preserved post-mortem copy for RATE_LIMIT" bash -c '! ls "'"$ld"'"/T1-*-RATE_LIMIT.jsonl >/dev/null 2>&1'
_need "RATE_LIMIT incident row still recorded"  inc_has T1 RATE_LIMIT
_emit
H_cleanup

# (2) WATCHDOG_KILL ⇒ BOTH .jsonl AND .proc.txt retained (policy corner). Small
# IDLE_TIMEOUT + HARNESS_HANG_SECONDS=60 makes the genuinely-stuck worker hit the
# watchdog; RUN_TIMEOUT=70 outlasts the poll+grace+SIGKILL window.
H_init_test bc28tree-watchdog-both
bd_seed T1 "hang then ok" "x"
claude_plan hang success
export IDLE_TIMEOUT=1
export HARNESS_HANG_SECONDS=60
RUN_TIMEOUT=70 run_runner
ld="$WORKDIR/.beads/runner-logs"      # per-rig: each H_init_test makes a NEW WORKDIR
_expect "BC-28" "§8.2" "v2 WATCHDOG_KILL ⇒ stream .jsonl AND proc .proc.txt both retained"
_need "WATCHDOG_KILL incident row recorded"    inc_has T1 WATCHDOG_KILL
_need "stream preserved for WATCHDOG_KILL"     file_glob "$ld/T1-*-WATCHDOG_KILL.jsonl"
_need "proc snapshot retained for WATCHDOG_KILL" file_glob "$ld/T1-*.proc.txt"
_emit
H_cleanup

# (3) EDGE — watchdog kills, but SERVER_ERROR (earlier, more decisive) WINS
# classification (§7.1: SERVER_ERROR before WATCHDOG_KILL). Stream IS kept
# (SERVER_ERROR is serious); proc snapshot is DELETED (retention keys on
# CLASSIFICATION, which is NOT WATCHDOG_KILL). This is the precise SCAR.
H_init_test bc28tree-watchdog-fired-server-wins
bd_seed T1 "server then hang" "x"
claude_plan server_then_hang success
export IDLE_TIMEOUT=1
export HARNESS_HANG_SECONDS=60
RUN_TIMEOUT=70 run_runner
ld="$WORKDIR/.beads/runner-logs"      # per-rig: each H_init_test makes a NEW WORKDIR
_expect "BC-28" "§8.2" "v2 watchdog fired but SERVER_ERROR wins ⇒ .jsonl kept, .proc.txt DELETED"
_need "classification is SERVER_ERROR (not WATCHDOG_KILL)" inc_has T1 SERVER_ERROR
_need "watchdog kill did NOT win classification"          inc_not T1 WATCHDOG_KILL
_need "stream preserved (SERVER_ERROR is serious)"        file_glob "$ld/T1-*-SERVER_ERROR.jsonl"
_need "proc snapshot DELETED (keyed on classification)"   bash -c '! ls "'"$ld"'"/T1-*.proc.txt >/dev/null 2>&1'
_emit
H_cleanup
