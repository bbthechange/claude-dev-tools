#!/bin/bash
# BC-22 — Idle-stream watchdog: snapshot-before-signal, staged kill,
#         classification WATCHDOG_KILL.
# Binds: INTERFACE.md v1 §3 job 6 / §8.2 (watchdog feeds the terminal-reason
#        WATCHDOG_KILL class that report-terminal-reason re-homes).
# SCAR (silent-when-wrong): a hung agent burns the queue invisibly; the
#        proc snapshot is destroyed if you signal before capturing it.
#
# NOTE on timing: the watchdog polls every 15s and the 180s soft-warn tier is
# hardcoded (BC-22) — not env-tunable. We drive only the KILL path via
# IDLE_TIMEOUT=1 + a long silent hang. CRITICAL: the runner launches `claude`
# as a non-job-control background job, so its SIGINT is SIG_IGN on entry
# (POSIX async-background) and cannot be trapped or reset — exactly modelling a
# hard-stuck agent. The watchdog's staged kill is therefore SIGINT (a no-op
# here, as on a truly wedged process) THEN SIGKILL ~10s later; SIGKILL is the
# terminator (exit 137). The silent hang MUST outlast that whole sequence
# (first poll ≤15s + snapshot + 10s grace ≈ 27s) or the stub would self-exit 0
# before the kill and classify_failure would short-circuit to TASK_NOT_CLOSED
# (exit 0 never consults the signal file). Hence HARNESS_HANG_SECONDS=60 with
# the RUN_TIMEOUT=70 backstop (~30s wall time). The 180s soft-warn tier is
# acknowledged-untestable within a fast gate and left to manual / T1b
# longitudinal testing; this asserts the load-bearing kill behavior.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

H_init_test bc22-watchdog-kill
bd_seed T1 "hangs" "x"
claude_plan hang success
export IDLE_TIMEOUT=1
export HARNESS_HANG_SECONDS=60   # must outlast SIGINT(≤15s)+grace(10s)→SIGKILL
RUN_TIMEOUT=70 run_runner

ld="$WORKDIR/.beads/runner-logs"
_expect "BC-22" "§8.2" "silent idle ⇒ WATCHDOG_KILL, snapshot-before-signal, staged kill"
_need "WATCHDOG_KILL incident recorded"        inc_has T1 WATCHDOG_KILL
_need "watchdog kill message printed"          matches "$(out)" "Killing after .* idle"
_need "stream preserved for WATCHDOG_KILL"      file_glob "$ld/T1-*-WATCHDOG_KILL.jsonl"
_need "proc snapshot retained (ps+lsof before kill)" file_glob "$ld/T1-*.proc.txt"
_need "snapshot captured ps state section"     bash -c 'grep -ql "=== ps" "'"$ld"'"/T1-*.proc.txt 2>/dev/null'
_need "runner survived the kill and drained"   test "$RUN_EXIT" -eq 0
_emit
H_cleanup
