#!/bin/bash
# BC-34 — Usage/capacity check posture is fail-OPEN; a credential/usage outage
#         never halts processing (v2 -tree coverage-hardening, claude-tools-v2cut.5).
#
# RE-AUTHORED for v2 (NOT a clone of bc-34-usage-fail-open.sh). v2 has NO inline
# macOS-Keychain usage path — the v1 strings ("Could not read credentials …",
# "No OAuth token found", "Usage API call failed") DO NOT EXIST in runner.sh.
# v2's fail-OPEN posture lives in a different mechanism: the §6.2 CAPACITY GATE.
# At every pickup the runner asks `job_ask_capacity standard`
# (→ la_capacity_check). Under RUNNER_BACKEND=stub there is no real usage
# measurement, so la_capacity_check ALWAYS returns the fail-OPEN verdict `ok`
# (lib/local-agent-stub.sh:57-63). Consequence: a task with no measurable usage
# PROCEEDS and CLOSES — a usage/credential outage is fail-open, exactly as
# BEHAVIORAL-CONTRACT.md BC-34 (§6.2) requires.
#
# This rig asserts the v2 mechanism (capacity gate), not v1's keychain path:
#  A) BEHAVIORAL: a normal task proceeds to `closed` with a clean exit (fail-open
#     proceeds), and the runner prints NO v1-style `Above N% usage` halt line and
#     NONE of the v1 keychain skip-notes.
#  B) SOURCE-STRUCTURAL (§6.2 fail-open + honest-deny posture): job_ask_capacity
#     is consulted at pickup BEFORE the in_progress write, and the DENY branch
#     names which gate held (reason sidecar), releases the lease, backs off, and
#     continues — a deny holds work cleanly, it does not strand or crash.
#
# SCAR (silent-when-wrong): a fail-CLOSED capacity gate would let a credential /
# usage-API hiccup silently halt all task processing.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"   # repoint to v2
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# ── A · fail-OPEN behavioral: no measurable usage ⇒ task PROCEEDS and CLOSES ──
H_init_test bc34tree-fail-open-proceeds
bd_seed T1 "normal task" "do a thing"
claude_plan success
run_runner
o="$(out)"
_expect "BC-34" "§6.2" "v2 capacity gate fails OPEN: no usage measurement ⇒ task proceeds and closes (a usage/credential outage never halts processing)"
_need "task proceeded and closed (fail-open proceed)"  test "$(bd_status T1)" = closed
_need "clean exit 0"                                   test "$RUN_EXIT" -eq 0
_need "NO v1 'Above N% usage' halt line"               bash -c '! grep -qiE "Above [0-9]+% usage" <<< "$1"' _ "$o"
_need "NO v1 keychain 'Could not read credentials' note" notcontains "$o" "Could not read credentials"
_need "NO v1 'No OAuth token found' note"              notcontains "$o" "No OAuth token found"
_need "NO v1 'Usage API call failed' note"             notcontains "$o" "Usage API call failed"
_emit
H_cleanup

# ── B · SOURCE: §6.2 fail-open + honest-deny posture in runner.sh ─────────────
# Black-box cannot observe a deny (the stub always returns ok), so the deny-branch
# posture is asserted source-structurally — explicitly legitimate under the stub
# backend. These prove the call SITE and the clean-deny shape exist in v2.
H_init_test bc34tree-source-posture
_expect "BC-34" "§6.2" "runner.sh consults capacity at pickup and the deny branch names the gate + releases lease + backs off + continues (fail-open honest-deny posture)"
_need "job_ask_capacity wrapper delegates to la_capacity_check (fail-OPEN §6.2)" \
      grep -qE 'job_ask_capacity\(\)[[:space:]]*\{[[:space:]]*la_capacity_check' "$RUNNER"
_need "capacity consulted at pickup ('if ! job_ask_capacity standard')" \
      grep -qE 'if ! job_ask_capacity standard; then' "$RUNNER"
_need "deny line NAMES which gate held (reason sidecar, not a fixed threshold)" \
      grep -qE 'capacity verdict=over reason=\$\{LA_CAPACITY_REASON' "$RUNNER"
_need "deny releases the held lease (clean release, not strand)" \
      grep -qE 'job_release_lease "\$CANDIDATE_ID" "\$LEASE_GENERATION"' "$RUNNER"
_need "deny backs off then continues (transition RECONCILE; return — bead stays open)" \
      bash -c 'grep -A8 "if ! job_ask_capacity standard; then" "$1" | grep -qE "transition RECONCILE; return"' _ "$RUNNER"
_need "capacity consulted BEFORE the in_progress write (fail-open at pickup, AD2.1 order)" \
      bash -c 'a=$(grep -nF -- "if ! job_ask_capacity standard; then" "$1" | head -1 | cut -d: -f1); b=$(grep -nF -- "-- bd update \"\$CANDIDATE_ID\" --status=in_progress" "$1" | head -1 | cut -d: -f1); [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]' _ "$RUNNER"
_emit
H_cleanup
