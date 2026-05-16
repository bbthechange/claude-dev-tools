#!/bin/bash
# BC-28 — Selective stream preservation BY CLASS; PROC_SNAPSHOT retained iff
#         final classification == WATCHDOG_KILL (keys on classification, NOT
#         on whether the watchdog fired).
# Binds: INTERFACE.md v1 §8.2 (forensic artifact policy — tuned cost/value:
#        disk-spam vs losing post-mortems on serious failures).
# SCAR (silent-when-wrong): the watchdog-killed-but-SERVER_ERROR-wins edge is a
#        precise, non-obvious behavior a rewrite can easily get wrong.
#
# ANTI-OVERLAP: T1a/bc-22 asserts the watchdog *mechanism* (snapshot-before-
# signal, staged kill). BC-28 asserts the *preservation POLICY by class* — the
# contrast set routine⇒none / WATCHDOG_KILL⇒both / watchdog-fired-but-other-
# class-wins ⇒ stream-kept-but-proc-deleted.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

# (1) ROUTINE class (RATE_LIMIT) ⇒ NO stream copy, but an incident row exists.
H_init_test bc28-routine-no-stream
bd_seed T1 "rate then ok" "x"
claude_plan ratelimit success
run_runner
ld="$WORKDIR/.beads/runner-logs"
_expect "BC-28" "§8.2" "routine class (RATE_LIMIT) ⇒ no .jsonl, but incident row kept"
_need "no stream-json copied for RATE_LIMIT"   bash -c '! ls "'"$ld"'"/T1-*.jsonl >/dev/null 2>&1'
_need "RATE_LIMIT incident row still recorded"  inc_has T1 RATE_LIMIT
_emit
H_cleanup

# (2) WATCHDOG_KILL ⇒ BOTH .jsonl AND .proc.txt retained (policy corner).
H_init_test bc28-watchdog-both
bd_seed T1 "hang then ok" "x"
claude_plan hang success
export IDLE_TIMEOUT=1
export HARNESS_HANG_SECONDS=60
RUN_TIMEOUT=70 run_runner
ld="$WORKDIR/.beads/runner-logs"      # per-rig: each H_init_test makes a NEW WORKDIR
_expect "BC-28" "§8.2" "WATCHDOG_KILL ⇒ stream .jsonl AND proc .proc.txt both retained"
_need "stream preserved for WATCHDOG_KILL"     file_glob "$ld/T1-*-WATCHDOG_KILL.jsonl"
_need "proc snapshot retained for WATCHDOG_KILL" file_glob "$ld/T1-*.proc.txt"
_emit
H_cleanup

# (3) EDGE — watchdog kills, but SERVER_ERROR (earlier, more decisive) WINS
# classification (§7.1: SERVER_ERROR before WATCHDOG_KILL). Stream IS kept
# (SERVER_ERROR is serious); proc snapshot is DELETED (keyed on classification,
# which is NOT WATCHDOG_KILL). This is the precise SCAR.
H_init_test bc28-watchdog-fired-server-wins
bd_seed T1 "server then hang" "x"
claude_plan server_then_hang success
export IDLE_TIMEOUT=1
export HARNESS_HANG_SECONDS=60
RUN_TIMEOUT=70 run_runner
ld="$WORKDIR/.beads/runner-logs"      # per-rig: each H_init_test makes a NEW WORKDIR
_expect "BC-28" "§8.2" "watchdog fired but SERVER_ERROR wins ⇒ .jsonl kept, .proc.txt DELETED"
_need "classification is SERVER_ERROR (not WATCHDOG_KILL)" inc_has T1 SERVER_ERROR
_need "watchdog kill did NOT win classification"          inc_not T1 WATCHDOG_KILL
_need "stream preserved (SERVER_ERROR is serious)"        file_glob "$ld/T1-*-SERVER_ERROR.jsonl"
_need "proc snapshot DELETED (keyed on classification)"   bash -c '! ls "'"$ld"'"/T1-*.proc.txt >/dev/null 2>&1'
_emit
H_cleanup
