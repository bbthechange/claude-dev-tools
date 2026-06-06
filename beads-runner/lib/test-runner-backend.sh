#!/bin/bash
# beads-runner/lib/test-runner-backend.sh — the REAL six-job backend adapter
# (lib/runner-backend-real.sh; T-final wiring, claude-tools-v2c2).
#
# WHY THIS TEST EXISTS
#   The default runner backend is `stub`, so the FROZEN conformance suite
#   (conformance/assertions/*-tree.sh) exercises ONLY the stub path — it would
#   stay GREEN even if the `real` adapter were broken. This test is the proof for
#   the `real` arm: it pins the exact invariant the stub headers' false "byte-for-
#   byte drop-in" claim hid — that EVERY function the runner's job_* wrappers
#   call is DEFINED by the real adapter (no `command not found` at the swap) and
#   round-trips against a live in-process Coordinator store + Local-Agent outbox.
#
# Asserts, against lib/runner-backend-real.sh sourced over a temp CO_STORE +
# temp LOG_DIR (hermetic; fake `bd`; COORDINATOR_TOKEN set so no Keychain):
#   • SURFACE: every runner-facing co_*/la_* name is defined (the swap surface).
#   • §3 j1/§6.1: co_lease_acquire echoes a NUMERIC generation (NOT the raw §4.4
#     Lease record) — the normalisation the runner's renew/release depend on.
#   • §4.4 fencing: a stale-generation renew is rejected; a fresh one accepted.
#   • §3 j4/§2.4: co_deliver_desired_state returns the STORED desired (not a
#     hardcoded string) and fails OPEN to "running" on a fresh project.
#   • §3 j3/§4.2: la_heartbeat reports UP (outbox) AND renews the held lease.
#   • §3 j5/§4.5 + §3 j6/§8.2: snapshot + terminal-reason produce their records.
#   • §2.1/§4: co_store_put derives the id from the record and stores it.
#
# Self-contained: own mktemp store, own fake `bd`, own env vocabulary — shares no
# state with the conformance harness or lib/test-local-agent.sh.
set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/runner-backend-real.sh"
[[ -f "$LIB" ]] || { echo "FATAL: runner-backend-real.sh not found at $LIB"; exit 2; }

PASS=0; FAIL=0
ok()   { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
ck()   { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
defined() { declare -F "$1" >/dev/null 2>&1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── hermetic env: temp store/log, fake bd (so the inventory producer never
#    touches a real beads workspace), explicit token (no Keychain probe). ──────
FAKEBIN="$WORK/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/bd" <<'EOF'
#!/bin/bash
# minimal fake: every list/ready query is an empty JSON array.
case " $* " in
  *" --json "*) echo "[]" ;;
  *) echo "[]" ;;
esac
exit 0
EOF
chmod +x "$FAKEBIN/bd"
export PATH="$FAKEBIN:$PATH"

export CO_STORE="$WORK/co-store"
export LOG_DIR="$WORK/.beads/runner-logs"
export BEADS_DAEMON_CACHE_DIR="$WORK/empty-daemon-cache"
export RUNNER_ID="test-runner-rb"
export PROJECT_REF="proj-rb"
export COORDINATOR_TOKEN="rb-bearer-xyz"   # → RB_BEARER; in-process co_authenticate accepts any non-empty
unset COORDINATOR_URL                       # in-process backend (no HTTP override)
mkdir -p "$CO_STORE" "$LOG_DIR" "$BEADS_DAEMON_CACHE_DIR"

OUTBOX="$LOG_DIR/coordinator-outbox.jsonl"
TR="$LOG_DIR/terminal-reason"

# shellcheck source=/dev/null
source "$LIB"

echo "── SURFACE: every runner-facing job function is defined (no command-not-found at the swap) ──"
for fn in co_authenticate co__PRINCIPAL_V1 co_lease_acquire co_lease_renew \
          co_lease_release co_deliver_desired_state co_store_put \
          la_runner_id la_capacity_check la_heartbeat \
          la_publish_work_snapshot la_report_terminal_reason; do
  ck "defined: $fn" defined "$fn"
done
ck "real backend sourced co_request (in-process dispatcher)" defined co_request
if defined co_aggregate_capacity; then
  bad "real backend leaked the stub-only co_aggregate_capacity (wrong file sourced)"
else
  ok "real backend is the real lib, not the stub (no stub-only co_aggregate_capacity)"
fi

echo "── §3 j1 / §6.1 / §4.4: claim-lease echoes a NUMERIC generation ──"
GEN="$(co_lease_acquire T1 "$RUNNER_ID")"; ACQ_RC=$?
ck "co_lease_acquire rc 0 (granted)"             test "$ACQ_RC" -eq 0
ck "generation is numeric (normalised, not the §4.4 record)" bash -c '[[ "'"$GEN"'" =~ ^[0-9]+$ ]]'

echo "── §4.4 fencing: stale-generation renew rejected, valid renew accepted ──"
ck "renew with current generation ⇒ accepted"    co_lease_renew T1 "$RUNNER_ID" "$GEN"
co_lease_renew T1 "$RUNNER_ID" 999999 && bad "stale-generation renew was ACCEPTED (fencing broken)" || ok "stale-generation renew ⇒ rejected (§4.4 fencing)"

echo "── §3 j4 / §2.4: reconcile-desired-state reads the STORED desired ──"
DES_FRESH="$(co_deliver_desired_state proj-fresh)"
ck "fresh project ⇒ fail-OPEN to running"        test "$DES_FRESH" = "running"
co_request "$RB_BEARER" set-desired "$PROJECT_REF" paused tester >/dev/null
DES_SET="$(co_deliver_desired_state "$PROJECT_REF")"
ck "stored desired=paused is delivered (not hardcoded)" test "$DES_SET" = "paused"

echo "── §3 j3 / §4.2: heartbeat reports UP and renews the held lease ──"
: > "$OUTBOX"
ck "la_heartbeat rc 0"                            la_heartbeat "$PROJECT_REF" running T1 "$GEN"
ck "heartbeat appended to the §1.1 UP outbox"     grep -q '"report":"heartbeat"' "$OUTBOX"
ck "heartbeat carries actual=running"             grep -q '"actual":"running"' "$OUTBOX"
# the heartbeat renewed the lease, so the generation is still current ⇒ a
# further renew with the SAME generation still succeeds.
ck "lease still valid after heartbeat-renew"      co_lease_renew T1 "$RUNNER_ID" "$GEN"

echo "── §4.4 renew-rc sidecar: la_heartbeat surfaces grant/deny/none (claude-tools-h9dl) ──"
# The runner's §6.2 lease-cache refresh re-stamps the local envelope ONLY on a
# GRANTED renew (LA_LEASE_RENEW_RC==0), so a reachable-but-DENIED renew (mid-outage
# takeover) cannot extend a stale local hold. Predicates are SHELL functions (a
# `bash -c` subshell would not see the non-exported sidecar global).
renew_rc_is()      { [[ "$LA_LEASE_RENEW_RC" == "$1" ]]; }
renew_rc_nonzero() { [[ -n "$LA_LEASE_RENEW_RC" && "$LA_LEASE_RENEW_RC" != 0 ]]; }
renew_rc_empty()   { [[ -z "$LA_LEASE_RENEW_RC" ]]; }
la_heartbeat "$PROJECT_REF" running T1 "$GEN" >/dev/null
ck "GRANTED heartbeat-renew ⇒ LA_LEASE_RENEW_RC=0"          renew_rc_is 0
la_heartbeat "$PROJECT_REF" running T1 999999 >/dev/null
ck "DENIED heartbeat-renew (stale gen) ⇒ RENEW_RC nonzero"  renew_rc_nonzero
la_heartbeat "$PROJECT_REF" idle "" "" >/dev/null
ck "no task/gen ⇒ RENEW_RC empty (no renew attempted)"      renew_rc_empty

echo "── §3 j5 / §4.5 + §3 j6 / §8.2: snapshot + terminal-reason records ──"
ck "la_publish_work_snapshot rc 0 (best-effort)"  la_publish_work_snapshot "$PROJECT_REF"
ck "snapshot appended workspace_inventory UP"     grep -q '"report":"workspace_inventory"' "$OUTBOX"
la_report_terminal_reason CLEAN 0 "" "$PROJECT_REF"
ck "terminal-reason durable record written"       test -f "$TR"
ck "terminal_class==CLEAN"                         bash -c '[[ "$(jq -r .terminal_class "'"$TR"'")" == CLEAN ]]'

echo "── §2.1 / §4: store-put derives the id from the record + routes to put ──"
# Mechanism only: the adapter derives the key from the record and calls
# `co_request put <kind> <id> <json>`. Proven with a store-ACCEPTED record (a
# §4.3 Notification); the dossier-specific §5.1 WRITE gate (claude-tools-4xe) is
# the store's own contract, exercised by lib/test-consequence.sh — not re-tested
# here (TESTING-STRATEGY §8: assert the mechanism, don't re-test a sibling).
co_store_put notification '{"id":"notif-1","schema_version":1,"principal":"brian","dossier_ref":"d1","tier":"blocking","created_at":"2026-05-30T00:00:00Z","dispatched":false}'
ck "record stored under its derived id (kind.id.json)"  test -f "$CO_STORE/records/notification.notif-1.json"

echo "── §4.4 monotonic fencing: same-owner re-acquire bumps the generation ──"
G_a="$(co_lease_acquire T2 "$RUNNER_ID")"   # fresh slot ⇒ 1
G_b="$(co_lease_acquire T2 "$RUNNER_ID")"   # same-owner re-acquire ⇒ 2 (BC-04 fencing)
ck "re-acquire bumps generation (G_b > G_a)"      bash -c '[ "'"$G_b"'" -gt "'"$G_a"'" ]'

echo "── §3 j1 pairing: release frees the slot, re-acquire succeeds ──"
ck "co_lease_release rc 0"                         co_lease_release T1 "$RUNNER_ID" "$GEN"
GEN2="$(co_lease_acquire T1 "$RUNNER_ID")"; RC2=$?
ck "re-acquire after release succeeds on the freed slot" bash -c '[ "'"$RC2"'" -eq 0 ] && [[ "'"$GEN2"'" =~ ^[0-9]+$ ]]'

echo ""
echo "── REAL backend adapter test: PASS=$PASS FAIL=$FAIL ──"
[[ $FAIL -eq 0 ]] || exit 1
echo "✓ lib/runner-backend-real.sh maps the six §3 jobs onto the real Local Agent + Coordinator"
