#!/bin/bash
# BC-34 — Usage check posture is fail-OPEN on every credential/API error;
#         USAGE_THRESHOLD=0 disables it entirely.
# Binds: INTERFACE.md v1 §6.2 (capacity check fails OPEN — Coordinator
#        unreachable ⇒ proceed) and §6.3 (USAGE_THRESHOLD gate, TTL cache).
#        (T1a owns the BC-34 assertion per its OWNS list; §6.* change-binding
#        is T1b's — citing the section here is the EXIT-crit-3 binding, not a
#        change to it.)
# SCAR (silent-when-wrong): fail-CLOSED would let a credential hiccup
#        silently halt all task processing.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

# keychain unreadable ⇒ proceed
H_init_test bc34-keychain-fail
bd_seed T1 t x
claude_plan success
export USAGE_THRESHOLD=70 HARNESS_KEYCHAIN=fail
run_runner
_expect "BC-34" "§6.2" "keychain unreadable ⇒ fail-OPEN (proceed, stderr note)"
_need "explicit skip note on stderr"  contains "$(out)" "Could not read credentials for usage check — skipping"
_need "task proceeded and closed"     test "$(bd_status T1)" = closed
_need "clean exit 0"                  test "$RUN_EXIT" -eq 0
_emit
H_cleanup

# creds present but no token ⇒ proceed
H_init_test bc34-no-token
bd_seed T1 t x
claude_plan success
export USAGE_THRESHOLD=70 HARNESS_KEYCHAIN=notoken
run_runner
_expect "BC-34" "§6.2" "no OAuth token ⇒ fail-OPEN (proceed, stderr note)"
_need "no-token skip note on stderr"  contains "$(out)" "No OAuth token found — skipping usage check"
_need "task proceeded and closed"     test "$(bd_status T1)" = closed
_emit
H_cleanup

# usage API call fails ⇒ proceed
H_init_test bc34-curl-fail
bd_seed T1 t x
claude_plan success
export USAGE_THRESHOLD=70 HARNESS_KEYCHAIN=ok HARNESS_USAGE=fail
run_runner
_expect "BC-34" "§6.2" "usage API failure ⇒ fail-OPEN (proceed, stderr note)"
_need "API-failed skip note on stderr" contains "$(out)" "Usage API call failed — skipping check"
_need "task proceeded and closed"      test "$(bd_status T1)" = closed
_emit
H_cleanup

# USAGE_THRESHOLD=0 disables the gate entirely (no keychain/API touched)
H_init_test bc34-disabled
bd_seed T1 t x
claude_plan success
export USAGE_THRESHOLD=0 HARNESS_KEYCHAIN=fail
run_runner
_expect "BC-34" "§6.3" "USAGE_THRESHOLD=0 disables the gate (no usage path at all)"
_need "no usage-limit banner printed"  bash -c '! grep -q "Usage limit:" "'"$HARNESS_OUT"'/runner.out"'
_need "no credential note emitted"     bash -c '! grep -q "Could not read credentials" "'"$HARNESS_OUT"'/runner.out"'
_need "task proceeded and closed"      test "$(bd_status T1)" = closed
_emit
H_cleanup
