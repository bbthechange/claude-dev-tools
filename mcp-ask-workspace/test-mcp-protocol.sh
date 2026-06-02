#!/usr/bin/env bash
# End-to-end MCP-protocol smoke for mcp-ask-workspace/server.mjs (K1,
# claude-tools-uxvk1). Fork-parity with mcp-askbrian/test-mcp-protocol.sh.
#
# Spawns the Node server, drives JSON-RPC 2.0 over stdio, and verifies the
# REQUEST/RESPONSE FRAMING + the verdict split with a STUBBED responder (no
# real `claude`, no network):
#   • tools/list advertises the ask-workspace tool with the cross-WS input shape
#     (to_ws / question / context_dump / bead_ref).
#   • ANSWER path (the 80%): a tools/call routed to a registered workspace
#     spawns the stub responder, which returns verdict:"answer"; the server
#     returns the answer text as the tool_result and result.isError is ABSENT
#     (R1 §Q1 parity — is_error null, not false).
#   • ESCALATE path (the 20%): a tools/call whose stub returns verdict:"escalate"
#     routes to the INHERITED dossier publish-and-block path: the server
#     persists a §5-conformant blocking dossier (write_fallback) and blocks on
#     the poll. With a short poll ceiling and no human ruling, it returns the
#     "escalated → dossier durable" message — proving the SPLIT routed to the
#     escalation leg and the §5 gate accepted the record. (The full
#     ruling-returns round-trip is K4 / claude-tools-uxvk4's conformance.)
#     result.isError ABSENT here too.
#   • ROUTE MISS: an unregistered to_ws returns a terse actionable error, never
#     a fabricated answer.
set -uo pipefail

ME_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$ME_DIR/.." && pwd)"
SCRATCH="${TEST_SCRATCH:-$ME_DIR/.test-scratch/mcp-protocol}"
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"

# A registered target workspace dir (B) the responder would run inside.
BWS="$SCRATCH/ws-BE"; mkdir -p "$BWS/.beads"
cat > "$SCRATCH/workspaces.json" <<JSON
{ "workspaces": [ { "project_ref": "BE", "dir": "$BWS" } ] }
JSON

# Stub responder: stands in for specialist.sh. Reads the context JSON on stdin
# and prints ONE verdict object on stdout — exactly what the real shim prints
# (the model's result text). Branches on the question so one stub serves both
# paths: an "ESCALATE" question → escalate verdict; otherwise → answer verdict.
cat > "$SCRATCH/stub-responder.sh" <<'STUB'
#!/usr/bin/env bash
ctx="$(cat)"
if printf '%s' "$ctx" | grep -q 'ESCALATE'; then
  printf '%s\n' '{"verdict":"escalate","reason":"conflict","summary":"FE assumes DELETE->204 empty; BE returns 200 + {ok,refunded_cents}. Contract drift.","conflicting_claims":["FE: DELETE->204 empty","BE orders.js:88: 200 + body"],"options":[{"label":"FE adopts BE 200+body","blast_radius":"FE parsing change; BE already deployed"},{"label":"BE changes to 204","blast_radius":"BE redeploy + other consumers"}],"recommendation":"FE adopts BE shape"}'
else
  printf '%s\n' '{"verdict":"answer","answer":"Deployed since commit a1b2c3. Shape: {ok, refunded_cents}.","evidence":["cf/src/orders.js:88","thirsty-be-12f closed"]}'
fi
exit 0
STUB
chmod +x "$SCRATCH/stub-responder.sh"

export CO_STORE="$SCRATCH/store"
export XWS_REGISTRY_PATH="$SCRATCH/workspaces.json"
export XWS_SPECIALIST_BIN="$SCRATCH/stub-responder.sh"
export PROJECT_REF="FE"                       # from_ws resolved server-side
export POLL_INTERVAL_MS=200
export POLL_MAX_MS=3000                        # short ceiling: escalate returns the durable-dossier message fast

[[ -d "$ME_DIR/node_modules/@modelcontextprotocol" ]] || {
  echo "node_modules missing — run 'npm install' in mcp-ask-workspace/ first" >&2
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
  # Hard-kill the server immediately (no drain) AND reap any bridge child it
  # spawned (a runBridge write_fallback/poll child is reparented to init when
  # node dies, otherwise — a slow child would leak and thrash the next run).
  kill -9 "$SRV_PID" 2>/dev/null || true
  pkill -9 -f "$ME_DIR/helpers/engine-bridge.sh" 2>/dev/null || true
  pkill -9 -f "$SCRATCH/stub-responder.sh" 2>/dev/null || true
  wait "$SRV_PID" 2>/dev/null || true
}
trap cleanup EXIT

send() { printf '%s\n' "$1" >&9; }
wait_for() {  # wait_for <grep-pattern> <seconds>
  local pat="$1" secs="$2" deadline
  deadline=$(( $(date +%s) + secs ))
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    grep -q "$pat" "$OUT" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}'
send '{"jsonrpc":"2.0","method":"notifications/initialized"}'
send '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

wait_for '"id":2' 10 || { echo "FAIL: no tools/list response"; cat "$LOG"; exit 1; }
grep -F '"name":"ask-workspace"' "$OUT" >/dev/null || { echo "FAIL: ask-workspace not advertised"; exit 1; }
# The cross-WS routing key must be in the advertised input schema.
grep -F '"to_ws"' "$OUT" >/dev/null || { echo "FAIL: to_ws not in advertised input schema"; exit 1; }
echo "tools/list: ask-workspace advertised with to_ws OK"

# ── ANSWER path (the 80%) ────────────────────────────────────────────────────
send '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ask-workspace","arguments":{"to_ws":"BE","question":"Is DELETE /orders/:id deployed and what does it return?","context_dump":"FE assumes 204 empty.","bead_ref":"thirsty-fe-93o"}}}'
wait_for '"id":3' 30 || { echo "FAIL: no answer-path tools/call response"; cat "$LOG"; exit 1; }
RESP3="$(grep -F '"id":3' "$OUT" | tail -1)"
TEXT3="$(printf '%s' "$RESP3" | jq -r '.result.content[0].text // ""')"
echo "answer tool_result: $TEXT3"
printf '%s' "$TEXT3" | grep -q "Workspace BE answered:" || { echo "FAIL: expected 'Workspace BE answered:'"; cat "$LOG"; exit 1; }
printf '%s' "$TEXT3" | grep -q "Deployed since commit a1b2c3" || { echo "FAIL: answer text not relayed"; exit 1; }
HAS_ISERR3="$(printf '%s' "$RESP3" | jq -r '.result | has("isError")')"
[[ "$HAS_ISERR3" == "false" ]] || { echo "FAIL: R1 §Q1 — answer result.isError must be absent (got $HAS_ISERR3)"; exit 1; }
echo "ANSWER path: answer relayed + isError absent (R1 §Q1) OK"

# ── ESCALATE path (the 20%) — split routes to the inherited dossier leg ───────
# The escalate leg runs the INHERITED dossier-publish path (write_fallback), the
# jq-heavy in-process store op that is ~tens of seconds wall on a loaded machine
# (identical cost in the ask-brian fork). It is therefore OPT-IN so the core
# fork-parity framing test above stays fast + deterministic in the offline gate.
# Set XWS_SMOKE_ESCALATE=1 to exercise the full split → blocking-dossier write.
# (The full ruling-returns round-trip is K4 / claude-tools-uxvk4's conformance.)
if [[ "${XWS_SMOKE_ESCALATE:-0}" == "1" ]]; then
  TREF="thirsty-fe-77e"
  send "$(jq -cn --arg t "$TREF" '
    {jsonrpc:"2.0", id:4, method:"tools/call", params:{
      name:"ask-workspace",
      arguments:{ to_ws:"BE",
        question:("ESCALATE: cancel endpoint contract — does it 204 or 200+body? ("+$t+")"),
        context_dump:"FE assumes DELETE->204 empty.",
        bead_ref:$t }}}')"
  wait_for '"id":4' 240 || { echo "FAIL: no escalate-path tools/call response"; cat "$LOG"; exit 1; }
  RESP4="$(grep -F '"id":4' "$OUT" | tail -1)"
  TEXT4="$(printf '%s' "$RESP4" | jq -r '.result.content[0].text // ""')"
  echo "escalate tool_result: $TEXT4"
  printf '%s' "$TEXT4" | grep -q "escalated to Brian" || { echo "FAIL: escalate verdict did not route to the escalation leg"; cat "$LOG"; exit 1; }
  printf '%s' "$TEXT4" | grep -q "durable on the engine" || { echo "FAIL: escalation did not persist a durable dossier"; cat "$LOG"; exit 1; }
  HAS_ISERR4="$(printf '%s' "$RESP4" | jq -r '.result | has("isError")')"
  [[ "$HAS_ISERR4" == "false" ]] || { echo "FAIL: R1 §Q1 — escalate result.isError must be absent (got $HAS_ISERR4)"; exit 1; }
  echo "ESCALATE path: verdict split → blocking dossier persisted + isError absent OK"

  # The inherited §5 gate must accept the persisted escalation dossier (proves
  # the split actually wrote a conformant blocking dossier via the reused path).
  . "$ROOT/beads-runner/lib/stuck-routing.sh"
  . "$ROOT/beads-runner/lib/notification.sh"
  . "$ROOT/beads-runner/lib/co-http-transport.sh"
  REC="$(do_dossier_get bearer-runner-mcp-ask-workspace "stuck-$TREF")" \
    || { echo "FAIL: persisted escalation dossier not found"; exit 1; }
  dg__validate_dossier "$REC" >/dev/null 2>&1 \
    || { echo "FAIL: dg__validate_dossier rejected the escalation record"; exit 1; }
  TIER="$(printf '%s' "$REC" | jq -r '.tier')"
  [[ "$TIER" == "blocking" ]] || { echo "FAIL: escalation dossier tier must be 'blocking', got '$TIER'"; exit 1; }
  echo "escalation dossier accepted by the §5 gate (tier=blocking) OK"
else
  echo "ESCALATE path: SKIPPED (set XWS_SMOKE_ESCALATE=1 to run the full split→blocking-dossier write; slow on loaded machines — the write path is inherited from the ask-brian fork)"
fi

# ── ROUTE MISS — unregistered to_ws → actionable error, no fabricated answer ──
send '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"ask-workspace","arguments":{"to_ws":"NOPE","question":"anything?","context_dump":"x","bead_ref":"thirsty-fe-zzz"}}}'
wait_for '"id":5' 10 || { echo "FAIL: no route-miss response"; cat "$LOG"; exit 1; }
RESP5="$(grep -F '"id":5' "$OUT" | tail -1)"
TEXT5="$(printf '%s' "$RESP5" | jq -r '.result.content[0].text // ""')"
printf '%s' "$TEXT5" | grep -q "could not route to workspace 'NOPE'" || { echo "FAIL: route miss not surfaced (got: $TEXT5)"; exit 1; }
echo "ROUTE MISS: actionable error, no fabricated answer OK"

echo
echo "MCP PROTOCOL SMOKE PASSED"
