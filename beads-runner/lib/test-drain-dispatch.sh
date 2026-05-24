#!/bin/bash
# beads-runner/lib/test-drain-dispatch.sh — claude-tools-1p0u
# Focused smoke test for la_outbox_drain dispatch table:
#   capacity      → report-capacity
#   heartbeat     → heartbeat
#   machine_state → report-machine-state   (the 1p0u gap)
#   unknown       → retained (not 422'd)
# Also covers the optional [outbox_path] arg (the daemon's path-override).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export COORDINATOR_URL="http://stub.invalid/"   # activates the override
source "$HERE/co-http-transport.sh"

DISPATCH_LOG="$(mktemp)"
# shellcheck disable=SC2317
co_request() {
  local bearer="$1" op="$2"; shift 2
  printf 'OP=%s ARG=%s\n' "$op" "$1" >> "$DISPATCH_LOG"
  return 0
}

W="$(mktemp -d)"
OBX="$W/outbox.jsonl"
cat > "$OBX" <<JSON
{"report":"capacity","verdict":"ok"}
{"report":"heartbeat","ts":"x"}
{"report":"machine_state","pct_5h":1.0,"pct_7d":2.0}
{"report":"weird","x":1}
JSON

la_outbox_drain "test-bearer" "$OBX" >/dev/null 2>/dev/null
DRC=$?

PASS=0; FAIL=0
chk() {
  local desc="$1" want="$2" got="$3"
  if [[ "$got" == *"$want"* ]]; then echo "  OK: $desc"; PASS=$((PASS+1))
  else echo "  FAIL: $desc want=$want got=$got"; FAIL=$((FAIL+1)); fi
}
LOG="$(cat "$DISPATCH_LOG")"
chk "capacity to report-capacity"           "OP=report-capacity"      "$LOG"
chk "heartbeat to heartbeat"                "OP=heartbeat"            "$LOG"
chk "machine_state to report-machine-state" "OP=report-machine-state" "$LOG"

WEIRD_DISPATCH="$(echo "$LOG" | grep weird || true)"
[[ -z "$WEIRD_DISPATCH" ]] && { echo "  OK: weird not dispatched"; PASS=$((PASS+1)); } \
  || { echo "  FAIL: weird dispatched: $WEIRD_DISPATCH"; FAIL=$((FAIL+1)); }

REMAIN="$(cat "$OBX")"
chk "weird line retained" "weird" "$REMAIN"

CAP_REM="$(echo "$REMAIN" | grep capacity || true)"
[[ -z "$CAP_REM" ]] && { echo "  OK: capacity drained from outbox"; PASS=$((PASS+1)); } \
  || { echo "  FAIL: capacity still in outbox"; FAIL=$((FAIL+1)); }

MS_REM="$(echo "$REMAIN" | grep machine_state || true)"
[[ -z "$MS_REM" ]] && { echo "  OK: machine_state drained from outbox"; PASS=$((PASS+1)); } \
  || { echo "  FAIL: machine_state still in outbox"; FAIL=$((FAIL+1)); }

[[ "$DRC" == "1" ]] && { echo "  OK: rc=1 (retained line)"; PASS=$((PASS+1)); } \
  || { echo "  FAIL: rc want 1 got $DRC"; FAIL=$((FAIL+1)); }

rm -rf "$W" "$DISPATCH_LOG"
echo ""
echo "RESULT: $PASS pass, $FAIL fail"
exit "$FAIL"
