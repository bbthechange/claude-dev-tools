#!/bin/bash
# BC-24 — Append-only CROSS-RUN incidents log + per-run summary that a later
#         success cannot erase (v2 -tree coverage-hardening, claude-tools-v2cut.5).
# Faithful mirror of bc-24-incidents-log.sh repointed to the v2 runner.sh.
# v2's record_incident (runner.sh:840-846) appends a 4-field TSV row to
# INCIDENTS_LOG=.beads/runner-logs/incidents.log; print_incidents_summary
# (runner.sh:862-868) prints the byte-identical `Incidents this run (N):` block.
# v2 ships NO age-based log rotation, so the audit trail is rotation-exempt by
# construction (an ancient-mtime incidents.log survives the next startup). This
# rig proves v2 matches/exceeds v1 on the §8.2 forensic audit-trail seam.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"   # repoint to v2
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# ── append-only ACROSS two runner invocations + rotation-exempt ───────────────
H_init_test bc24tree-cross-run-append
ld="$WORKDIR/.beads/runner-logs"

bd_seed T1 "run-one" "x"
claude_plan ratelimit success
run_runner                                   # invocation #1 → 1 incident row (T1)
row1="$(incidents_log)"
n1=$(grep -c . "$ld/incidents.log" 2>/dev/null); n1=${n1:-0}

# Age the audit trail to ANCIENT mtime: a per-name rotation exemption (not an
# age decision) must keep it across the next invocation's startup prune.
touch -t 200001010000 "$ld/incidents.log" 2>/dev/null || true

: > "$HARNESS_CLAUDE_COUNT"                   # driver reset only (not an assertion)
bd_seed T2 "run-two" "x"
claude_plan ratelimit success
run_runner                                   # invocation #2 → appends T2 row
n2=$(grep -c . "$ld/incidents.log" 2>/dev/null); n2=${n2:-0}

_expect "BC-24" "§8.2" "v2: incidents.log is append-only across runs + rotation-exempt"
_need "run1 produced ≥1 TSV row"            test "$n1" -ge 1
_need "TSV shape <ts>\\\\t<task>\\\\t<class>\\\\t<log>" \
      bash -c 'awk -F"\t" "NF!=4{bad=1} END{exit bad?1:0}" "'"$ld"'/incidents.log"'
_need "run1's original T1 row still present (not rewritten)" contains "$(incidents_log)" "$(printf '%s' "$row1" | head -1)"
_need "run2 STRICTLY appended (row count grew)" test "$n2" -gt "$n1"
_need "both T1 and T2 rows persist"          bash -c 'awk -F"\t" "\$2==\"T1\"{a=1} \$2==\"T2\"{b=1} END{exit (a&&b)?0:1}" "'"$ld"'/incidents.log"'
_need "ancient incidents.log survived startup rotation (name-exempt)" test -f "$ld/incidents.log"
_emit
H_cleanup

# ── the summary survives a later success (watchdog-kill then retry-ok) ────────
H_init_test bc24tree-summary-survives-success
bd_seed T1 "hang then ok" "x"
claude_plan hang success
export IDLE_TIMEOUT=1
export HARNESS_HANG_SECONDS=60
RUN_TIMEOUT=70 run_runner
_expect "BC-24" "§8.2" "v2: earlier WATCHDOG_KILL surfaced in end-of-run summary despite later success"
_need "task ultimately succeeded (drained exit 0)"   test "$RUN_EXIT" -eq 0
_need "bead is closed (the retry won)"               test "$(bd_status T1)" = closed
_need "'Incidents this run (N):' block still printed" matches "$(out)" "Incidents this run \([0-9]+\):"
_need "the masked WATCHDOG_KILL is in the summary"    contains "$(out)" "WATCHDOG_KILL"
_need "persistent incidents.log row for it"           inc_has T1 WATCHDOG_KILL
_emit
H_cleanup
