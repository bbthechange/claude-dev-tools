#!/bin/bash
# beads-runner/daemon/test-outbox-drain-wire.sh — claude-tools-1p0u
# Smoke test for the daemon-side outbox drain WIRING (no network):
#   1. Sources usage-poll.sh + workspace-registry.sh exactly as daemon.sh does.
#   2. Verifies daemon_outbox_drain_once is defined and a no-op when the
#      outbox is missing or empty.
#   3. Verifies it correctly skips when no workspace is registered (the M1-
#      only posture).
#   4. With a fake workspace + stubbed co_request, verifies it dispatches the
#      machine_state line to op="report-machine-state" and drains it.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib"

export DAEMON_REPO_DIR="$(cd "$HERE/.." && pwd)"
export DAEMON_REPO_LIB_DIR="$LIB"

TMPCACHE="$(mktemp -d)"
export BEADS_DAEMON_CACHE_DIR="$TMPCACHE"

# Stub `log` so usage-poll's _usage_poll_log writes here.
log() { printf 'LOG %s\n' "$*"; }

. "$HERE/workspace-registry.sh"
. "$HERE/usage-poll.sh"

PASS=0; FAIL=0
ok() { echo "  OK: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# 1. Function exists.
declare -F daemon_outbox_drain_once >/dev/null 2>&1 && ok "daemon_outbox_drain_once defined" || bad "daemon_outbox_drain_once missing"

# 2. Missing outbox ⇒ silent no-op.
rm -f "$USAGE_POLL_OUTBOX"
OUT="$(daemon_outbox_drain_once 2>&1)"; RC=$?
[[ "$RC" == "0" && -z "$OUT" ]] && ok "missing outbox is silent no-op" || bad "missing outbox: rc=$RC out='$OUT'"

# 3. Empty outbox ⇒ silent no-op.
: > "$USAGE_POLL_OUTBOX"
OUT="$(daemon_outbox_drain_once 2>&1)"; RC=$?
[[ "$RC" == "0" && -z "$OUT" ]] && ok "empty outbox is silent no-op" || bad "empty outbox: rc=$RC out='$OUT'"

# 4. Non-empty outbox + no workspace registered ⇒ skip + log, lines retained.
echo '{"report":"machine_state","schema_version":1,"pct_5h":1,"pct_7d":2,"spare_ramp_today":50,"threshold_in_effect":95,"runner_id":"smoke","observed_at":"2026-05-24T00:00:00Z"}' > "$USAGE_POLL_OUTBOX"
OUT="$(daemon_outbox_drain_once 2>&1)"; RC=$?
[[ "$RC" == "0" ]] && ok "no-workspace skip returns 0" || bad "no-workspace skip rc=$RC"
echo "$OUT" | grep -q "no workspaces registered" && ok "no-workspace skip logs the reason" || bad "no-workspace skip log missing: $OUT"
[[ -s "$USAGE_POLL_OUTBOX" ]] && ok "no-workspace skip retains the line" || bad "no-workspace skip lost the line"

# 5. Fake workspace, stub co_request → verify drain dispatches.
DISPATCH_LOG="$(mktemp)"
# Override co_request by injecting it into a shim co-http-transport.sh.
SHIM_LIB="$(mktemp -d)"
mkdir -p "$SHIM_LIB"
cat > "$SHIM_LIB/co-http-transport.sh" <<'SHIM'
co_request() {
  local bearer="$1" op="$2"; shift 2
  printf 'OP=%s\n' "$op" >> "$DISPATCH_LOG_PATH"
  return 0
}
la_outbox_drain() {
  local bearer="$1" obx="$2" kept rc=0
  kept="$(mktemp)"
  local line report op
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    report="$(printf '%s' "$line" | jq -r '.report // ""' 2>/dev/null)"
    case "$report" in
      capacity)      op="report-capacity" ;;
      heartbeat)     op="heartbeat" ;;
      machine_state) op="report-machine-state" ;;
      *) printf '%s\n' "$line" >> "$kept"; rc=1; continue ;;
    esac
    if co_request "$bearer" "$op" "$line" >/dev/null 2>&1; then :
    else printf '%s\n' "$line" >> "$kept"; rc=1
    fi
  done < "$obx"
  mv -f "$kept" "$obx" 2>/dev/null
  return "$rc"
}
SHIM
export DISPATCH_LOG_PATH="$DISPATCH_LOG"
export DAEMON_REPO_LIB_DIR="$SHIM_LIB"

# Register a fake workspace[0] (curl set, tk_item unset so no Keychain hit).
REGISTRY_PROJECT_REFS=("fake-ws")
REGISTRY_DIRS=("/tmp")
REGISTRY_COORDINATOR_URLS=("http://stub.invalid/")
REGISTRY_TOKEN_KEYCHAIN_ITEMS=("")
REGISTRY_LOADED=1

echo '{"report":"machine_state","schema_version":1,"pct_5h":1,"pct_7d":2,"spare_ramp_today":50,"threshold_in_effect":95,"runner_id":"smoke","observed_at":"2026-05-24T00:00:00Z"}' > "$USAGE_POLL_OUTBOX"
daemon_outbox_drain_once >/dev/null 2>&1
RC=$?
LOG="$(cat "$DISPATCH_LOG" 2>/dev/null || echo)"

[[ "$RC" == "0" ]] && ok "drain-with-workspace returns 0" || bad "drain-with-workspace rc=$RC"
[[ "$LOG" == *"OP=report-machine-state"* ]] && ok "machine_state dispatched to report-machine-state" || bad "no report-machine-state in dispatch log: '$LOG'"
[[ -s "$USAGE_POLL_OUTBOX" ]] && bad "drained line still in outbox" || ok "drained line removed from outbox"

rm -rf "$TMPCACHE" "$SHIM_LIB" "$DISPATCH_LOG"
echo ""
echo "RESULT: $PASS pass, $FAIL fail"
exit "$FAIL"
