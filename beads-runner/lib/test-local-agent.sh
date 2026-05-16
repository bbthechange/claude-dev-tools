#!/bin/bash
# beads-runner/lib/test-local-agent.sh — focused unit test for the Local Agent
# (T3, claude-tools-3al). This is T3's OWN test surface — deliberately NOT a
# member of the T1 conformance suite (beads-runner/conformance/, owned by
# T1a/T1b) and it does NOT touch the bc-ad2 lease-ARBITRATION rig (that flip is
# T4's). Anti-drift: it exercises only the Local Agent library.
#
# Asserts the EXIT CRITERIA T3 owns against INTERFACE.md v1:
#   • §8.2  terminal-reason re-home — each BC-21 class (and STUCK_NEEDS_HUMAN)
#           produces the correct durable record (EXIT crit 2)
#   • §6.2  capacity fails OPEN on every credential/API/keychain error (BC-34)
#   • §6.3  USAGE_THRESHOLD=0 disables the path entirely; hard 5h/7d ceiling;
#           low_priority spare-cycles SPARE_RAMP_PER_DAY soft ramp
#   • §6.2/AD2.2  bounded LOCAL lease fallback: Coordinator-unreachable ⇒
#           continue ONLY an already-held still-valid lease; refuse a NEW
#           claim; enforce LEASE_TTL locally (EXIT crit 3)
#   • §9.2  Coordinator bearer token read from the Keychain (distinct service,
#           account = runner_id), fail-OPEN, never from env/source
#
# Self-contained: writes its own `security`/`curl` stubs (controlled by T3T_*
# env, a separate vocabulary from the T1 harness's HARNESS_*), so it shares no
# state with the conformance harness.
set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/local-agent.sh"
[[ -f "$LIB" ]] || { echo "FATAL: local-agent.sh not found at $LIB"; exit 2; }

PASS=0; FAIL=0
ok()   { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
ck()   { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAKEBIN="$WORK/bin"; mkdir -p "$FAKEBIN"
export T3T_SEC_CALLS="$WORK/sec.calls" T3T_CURL_CALLS="$WORK/curl.calls"
: > "$T3T_SEC_CALLS"; : > "$T3T_CURL_CALLS"

# ── self-contained stubs ─────────────────────────────────────────────────────
cat > "$FAKEBIN/security" <<'EOF'
#!/bin/bash
# Records invocation; behaves per the requested -s service.
echo "$@" >> "${T3T_SEC_CALLS:-/dev/null}"
svc=""; i=1
for a in "$@"; do [[ "$a" == "-s" ]] && { eval "svc=\${$((i+1))}"; break; }; i=$((i+1)); done
case "$svc" in
  "Claude Code-credentials")
    case "${T3T_KEYCHAIN:-ok}" in
      fail)    exit 1 ;;
      notoken) echo '{"claudeAiOauth":{}}'; exit 0 ;;
      *)       echo '{"claudeAiOauth":{"accessToken":"anthropic-stub-token"}}'; exit 0 ;;
    esac ;;
  claude-beads-runner.coordinator-token)
    case "${T3T_COORD_TOKEN:-absent}" in
      absent) exit 1 ;;
      *)      printf '%s' "$T3T_COORD_TOKEN"; exit 0 ;;
    esac ;;
  *) exit 1 ;;
esac
EOF
cat > "$FAKEBIN/curl" <<'EOF'
#!/bin/bash
echo "$@" >> "${T3T_CURL_CALLS:-/dev/null}"
case "${T3T_USAGE:-under}" in
  fail) exit 22 ;;
  over) echo '{"five_hour":{"utilization":95},"seven_day":{"utilization":40}}'; exit 0 ;;
  *)    echo '{"five_hour":{"utilization":10},"seven_day":{"utilization":20}}'; exit 0 ;;
esac
EOF
chmod +x "$FAKEBIN/security" "$FAKEBIN/curl"
export PATH="$FAKEBIN:$PATH"

export LOG_DIR="$WORK/.beads/runner-logs"
export RUNNER_ID="test-runner-7"
mkdir -p "$LOG_DIR"
# shellcheck source=/dev/null
source "$LIB"

# Negation / env-scoped predicates that still see the sourced functions
# (subshell `( … )` inherits functions; `bash -c`/`env` would NOT).
nott()    { ! "$@"; }
errhas()  { [[ "$ERR" == *"$1"* ]]; }

TR="$LOG_DIR/terminal-reason"
OUTBOX="$LOG_DIR/coordinator-outbox.jsonl"

echo "── §8.2 terminal-reason re-home (each BC-21 class + STUCK) ──"
# class : exit : expected bc21_exit JSON
for spec in "AUTH_FAILURE:3:3" "BILLING_ERROR:4:4" "CIRCUIT_BREAKER:2:2" \
            "CLEAN:0:0" "INTERRUPTED:1:1" "STUCK_NEEDS_HUMAN::null"; do
  cls="${spec%%:*}"; rest="${spec#*:}"; ec="${rest%%:*}"; want="${rest#*:}"
  : > "$OUTBOX"
  la_report_terminal_reason "$cls" "$ec" "task-xyz" "proj-abc"
  got_cls=$(jq -r '.terminal_class' "$TR" 2>/dev/null)
  got_ec=$(jq -c '.bc21_exit' "$TR" 2>/dev/null)
  got_pr=$(jq -r '.principal' "$TR" 2>/dev/null)
  got_sv=$(jq -r '.tr_schema_version' "$TR" 2>/dev/null)
  got_rid=$(jq -r '.runner_id' "$TR" 2>/dev/null)
  ck "$cls: durable record exists"                 test -f "$TR"
  ck "$cls: terminal_class==$cls"                  test "$got_cls" = "$cls"
  ck "$cls: bc21_exit==$want"                      test "$got_ec" = "$want"
  ck "$cls: principal==brian (§9.1 constant)"      test "$got_pr" = "brian"
  ck "$cls: tr_schema_version==1 (§0.3)"           test "$got_sv" = "1"
  ck "$cls: runner_id stamped (§1.1 UP)"           test "$got_rid" = "test-runner-7"
  ck "$cls: appended to §1.1 UP outbox"            grep -q "\"terminal_class\":\"$cls\"" "$OUTBOX"
done

echo "── §6.2 capacity fails OPEN on every credential/API error (BC-34) ──"
run_cap() { # sets RC, ERR — env comes from the `VAR=val run_cap` prefix; the
  # `( … )` subshell inherits both that env AND the sourced functions.
  local err="$WORK/err"
  ( la_capacity_check "${COSTCLASS:-standard}" ) 2> "$err"; RC=$?
  ERR="$(cat "$err")"
}
USAGE_THRESHOLD=70 T3T_KEYCHAIN=fail   run_cap
ck "keychain unreadable ⇒ fail-OPEN (return 0)"  test "$RC" -eq 0
ck "keychain fail emits BC-34 contract note"     errhas "Could not read credentials for usage check — skipping"
USAGE_THRESHOLD=70 T3T_KEYCHAIN=notoken run_cap
ck "no OAuth token ⇒ fail-OPEN (return 0)"       test "$RC" -eq 0
ck "no-token emits BC-34 contract note"          errhas "No OAuth token found — skipping usage check"
USAGE_THRESHOLD=70 T3T_KEYCHAIN=ok T3T_USAGE=fail run_cap
ck "usage API failure ⇒ fail-OPEN (return 0)"    test "$RC" -eq 0
ck "API-fail emits BC-34 contract note"          errhas "Usage API call failed — skipping check"

echo "── §6.3 USAGE_THRESHOLD=0 disables the path entirely ──"
: > "$T3T_SEC_CALLS"; : > "$T3T_CURL_CALLS"
USAGE_THRESHOLD=0 T3T_KEYCHAIN=fail run_cap
ck "threshold 0 ⇒ proceed (return 0)"            test "$RC" -eq 0
ck "threshold 0 ⇒ security NEVER invoked"        test ! -s "$T3T_SEC_CALLS"
ck "threshold 0 ⇒ curl NEVER invoked"            test ! -s "$T3T_CURL_CALLS"

echo "── §6.3 hard 5h/7d ceiling (standard) ──"
USAGE_THRESHOLD=70 T3T_KEYCHAIN=ok T3T_USAGE=over  run_cap
ck "5h=95 ≥ 70 ⇒ over (return 1)"                test "$RC" -eq 1
USAGE_THRESHOLD=70 T3T_KEYCHAIN=ok T3T_USAGE=under run_cap
ck "5h=10/7d=20 < 70 ⇒ ok (return 0)"            test "$RC" -eq 0

echo "── §6.3 spare-cycles SPARE_RAMP_PER_DAY soft ramp (low_priority) ──"
# under hard ceiling (7d=20), but the day-N ramp gates low_priority only.
COSTCLASS=low_priority USAGE_THRESHOLD=70 SPARE_DAY_INDEX=1 T3T_KEYCHAIN=ok T3T_USAGE=under run_cap
ck "day1 ramp≈14 < 7d=20 ⇒ low_priority over (1)"  test "$RC" -eq 1
COSTCLASS=low_priority USAGE_THRESHOLD=70 SPARE_DAY_INDEX=7 T3T_KEYCHAIN=ok T3T_USAGE=under run_cap
ck "day7 ramp≈99 > 7d=20 ⇒ low_priority ok (0)"   test "$RC" -eq 0
COSTCLASS=standard USAGE_THRESHOLD=70 SPARE_DAY_INDEX=1 T3T_KEYCHAIN=ok T3T_USAGE=under run_cap
ck "standard ignores the ramp (still ok)"          test "$RC" -eq 0

echo "── §6.2/AD2.2 bounded LOCAL lease fallback ──"
expired_refused() ( LEASE_TTL=5; ! la_lease_fallback_allows FALL unreachable )
la_lease_release_local FALL
ck "reachable ⇒ allow (Coordinator arbitrates — T4)" la_lease_fallback_allows FALL reachable
ck "unreachable + NO held lease ⇒ refuse NEW claim"  nott la_lease_fallback_allows FALL unreachable
la_lease_note_held FALL "$(date +%s)"
ck "unreachable + held VALID lease ⇒ continue"       la_lease_fallback_allows FALL unreachable
la_lease_note_held FALL "$(( $(date +%s) - 1000 ))"
ck "unreachable + held EXPIRED lease ⇒ refuse (TTL)" expired_refused
la_lease_release_local FALL
ck "released local lease ⇒ refuse again"             nott la_lease_fallback_allows FALL unreachable

echo "── §9.2 Coordinator bearer token storage (Keychain, fail-OPEN) ──"
tok_present="$(T3T_COORD_TOKEN=coord-bearer-abc123 la_coordinator_token)"
ck "token read from distinct Keychain service"       test "$tok_present" = "coord-bearer-abc123"
absent_failopen() { local v rc; v="$(T3T_COORD_TOKEN=absent la_coordinator_token)"; rc=$?; [[ -z "$v" && $rc -eq 0 ]]; }
ck "absent token ⇒ empty + fail-OPEN (rc 0)"         absent_failopen
env_not_leaked()  ( export COORDINATOR_TOKEN=leak; [[ "$(T3T_COORD_TOKEN=absent la_coordinator_token)" != "leak" ]] )
ck "token never sourced from env"                    env_not_leaked
ck "Keychain probed with service+account (§9.2)"     grep -q 'claude-beads-runner.coordinator-token .*-a test-runner-7' "$T3T_SEC_CALLS"

echo ""
echo "── T3 Local Agent unit test: PASS=$PASS FAIL=$FAIL ──"
[[ $FAIL -eq 0 ]] || exit 1
echo "✓ Local Agent conforms to INTERFACE.md v1 §1.1/§6.2/§6.3/§8.2/§9.2"
