#!/usr/bin/env bash
# End-to-end MCP-protocol smoke for mcp-askbrian/server.mjs.
#
# Spawns the Node server, drives JSON-RPC 2.0 over stdio, and verifies:
#   • initialize / tools/list advertise the ask-brian tool
#   • a tools/call with a worker-style ask persists a contract-conformant
#     dossier (via the B3 fallback — the builder is intentionally skipped),
#     blocks on the poll loop, and returns Brian's answer once a sidecar
#     coroutine hand-flips the item state via do_item_set_state
#   • result.isError is ABSENT in the tool_result envelope (so the consumer's
#     is_error is null, not false — R1 §Q1 contract)
#   • dg__validate_dossier accepts the persisted record
set -uo pipefail

ME_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$ME_DIR/.." && pwd)"
SCRATCH="${TEST_SCRATCH:-$ME_DIR/.test-scratch/mcp-protocol}"
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"

export CO_STORE="$SCRATCH/store"
export DOSSIER_BUILDER_PROMPT_PATH="/nonexistent/skip-builder.md"
export POLL_INTERVAL_MS=200
export POLL_MAX_MS=20000

[[ -d "$ME_DIR/node_modules/@modelcontextprotocol" ]] || {
  echo "node_modules missing — run 'npm install' in mcp-askbrian/ first" >&2
  exit 1
}

SERVER="$ME_DIR/server.mjs"
LOG="$SCRATCH/server.log"
IN="$SCRATCH/server.in"
OUT="$SCRATCH/server.out"
mkfifo "$IN"

node "$SERVER" <"$IN" >"$OUT" 2>"$LOG" &
SRV_PID=$!
exec 9>"$IN"

cleanup() {
  exec 9>&- || true
  kill "$SRV_PID" 2>/dev/null || true
  wait "$SRV_PID" 2>/dev/null || true
}
trap cleanup EXIT

send() { printf '%s\n' "$1" >&9; }

send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}'
send '{"jsonrpc":"2.0","method":"notifications/initialized"}'
send '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

deadline=$(( $(date +%s) + 10 ))
while [[ "$(date +%s)" -lt "$deadline" ]]; do
  grep -q '"id":2' "$OUT" 2>/dev/null && break
  sleep 0.1
done
grep -q '"id":2' "$OUT" 2>/dev/null || { echo "FAIL: no tools/list response"; cat "$LOG"; exit 1; }
grep -F '"name":"ask-brian"' "$OUT" >/dev/null || { echo "FAIL: ask-brian not advertised"; exit 1; }
echo "tools/list: ask-brian advertised OK"

TREF="proto-bead-001"
send "$(jq -cn --arg t "$TREF" '
  {jsonrpc:"2.0", id:3, method:"tools/call", params:{
    name:"ask-brian",
    arguments:{
      question:"Smoke: should the protocol test pass?",
      context_dump:"smoke",
      bead_ref:$t,
      options:[
        {option_id:"yes", label:"Pass", blast_radius:"smoke passes"},
        {option_id:"no",  label:"Fail", blast_radius:"smoke fails"}],
      recommendation:"yes",
      reversible:"fully reversible"}}}')"

# Sidecar answerer: wait for the dossier to land, then flip item state so
# the server's poll loop observes "answered" and returns the answer text.
(
  sleep 2
  . "$ROOT/beads-runner/lib/stuck-routing.sh"
  . "$ROOT/beads-runner/lib/notification.sh"
  . "$ROOT/beads-runner/lib/co-http-transport.sh"
  DID="stuck-$TREF"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if do_dossier_get bearer-runner-mcp-askbrian "$DID" >/dev/null 2>&1; then
      do_item_set_state bearer-runner-mcp-askbrian "$DID" "$DID-d1" answered \
        '{"selected_option_id":"yes","decision":"yes"}' \
        && echo "answerer: flipped $DID-d1 → answered" \
        || echo "answerer: flip failed ($?)"
      break
    fi
    sleep 0.5
  done
) >>"$LOG" 2>&1 &
ANS_PID=$!

deadline=$(( $(date +%s) + 25 ))
while [[ "$(date +%s)" -lt "$deadline" ]]; do
  grep -q '"id":3' "$OUT" 2>/dev/null && break
  sleep 0.2
done
wait "$ANS_PID" 2>/dev/null || true
grep -q '"id":3' "$OUT" 2>/dev/null || { echo "FAIL: no tools/call response"; cat "$LOG"; exit 1; }

RESP="$(grep -F '"id":3' "$OUT" | tail -1)"
TEXT="$(printf '%s' "$RESP" | jq -r '.result.content[0].text // ""')"
echo "tools/call text: $TEXT"
echo "$TEXT" | grep -q "Brian's answer: Pass" || { echo "FAIL: expected 'Brian's answer: Pass'"; cat "$LOG"; exit 1; }

HAS_ISERR="$(printf '%s' "$RESP" | jq -r '.result | has("isError")')"
[[ "$HAS_ISERR" == "false" ]] || { echo "FAIL: R1 §Q1 — result.isError must be absent (got $HAS_ISERR)"; exit 1; }
echo "result.isError absent (R1 §Q1) OK"

# Validate the persisted dossier against the §5 gate.
. "$ROOT/beads-runner/lib/stuck-routing.sh"
. "$ROOT/beads-runner/lib/notification.sh"
. "$ROOT/beads-runner/lib/co-http-transport.sh"
REC="$(do_dossier_get bearer-runner-mcp-askbrian "stuck-$TREF")" \
  || { echo "FAIL: persisted dossier not found"; exit 1; }
dg__validate_dossier "$REC" >/dev/null 2>&1 \
  || { echo "FAIL: dg__validate_dossier rejected persisted record"; exit 1; }
echo "dg__validate_dossier accepts persisted record OK"

NID="$(no__notif_id "stuck-$TREF")"
NREC="$(no_get bearer-runner-mcp-askbrian "$NID")" \
  || { echo "FAIL: notification row missing"; exit 1; }
DISP="$(printf '%s' "$NREC" | jq -r '.dispatched')"
CHAN="$(printf '%s' "$NREC" | jq -r '.channel')"
[[ "$DISP" == "true" ]]    || { echo "FAIL: notification not dispatched"; exit 1; }
[[ "$CHAN" == "mcp-askbrian" ]] || { echo "FAIL: expected channel='mcp-askbrian', got $CHAN"; exit 1; }
echo "notification dispatched (channel=$CHAN) OK"

echo
echo "MCP PROTOCOL SMOKE PASSED"
