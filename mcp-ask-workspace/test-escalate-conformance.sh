#!/usr/bin/env bash
# K4 conformance — the two-path branch (claude-tools-uxvk4; cross-ws.md §5/§5.3;
# UX-DESIGN-V2 §8.3 is the bead's product anchor).
#
# Brian's s6/s4 invariant on the bead: "two-path branch: a mechanical answer ->
# batched timed-fyi + relay entry; a conflict / missing-design -> BLOCKING Flow B
# dossier. Test BOTH branches." K1 (claude-tools-uxvk1) shipped the split + the
# answer path and routed the escalate verdict through the inherited dossier path,
# but its escalate smoke is OPT-IN (the real jq write_fallback is slow on a loaded
# box) and stops at "dossier durable, no ruling". K1 explicitly deferred "the full
# ruling-returns round-trip" to K4 (test-mcp-protocol.sh:20,126).
#
# This test closes that gap deterministically and ALWAYS-ON: it stubs BOTH the
# responder (XWS_SPECIALIST_BIN — each verdict shape on demand) AND the engine
# bridge (XWS_BRIDGE_BIN — records every leg + returns a canned ruling), so the
# server's K4 conformance is exercised end-to-end with no real `claude`, no
# network, and no slow store op. It asserts, per the §5 contract:
#
#   ANSWER (the 80%):    relay-log-append(resolved) ONLY — NO dossier leg fires
#                        (no id_for / write_fallback / poll); answer is relayed;
#                        result.isError ABSENT (R1 §Q1).
#   CONFLICT (the 20%):  the escalate verdict maps onto a §5 worker_ask (summary +
#                        conflicting_claims + options + recommendation), is written
#                        as a BLOCKING dossier, relay-log-append(escalated) carries
#                        the dossier_ref, the poll returns Brian's ruling, and the
#                        ruling is formatted back to A as the tool_result. THE FULL
#                        RULING ROUND-TRIP. isError ABSENT.
#   MISSING_DESIGN:      same escalate path, reason="missing_design" (the bead
#                        title's second escalate shape, untested by K1).
#   ESCALATE-TO-SAFE:    a responder that emits non-verdict PROSE is treated as
#                        escalate(missing_design) — never a fabricated answer (the
#                        conservative default, §2.2). Routes to the dossier path.
#
# The real-store §5-gate proof (dg__validate_dossier accepts the persisted record,
# tier=blocking) stays in test-mcp-protocol.sh's opt-in XWS_SMOKE_ESCALATE leg;
# this test owns the split routing + the verdict→worker_ask→ruling conformance.
set -uo pipefail

ME_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRATCH="${TEST_SCRATCH:-$ME_DIR/.test-scratch/escalate-conformance}"
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"

# A registered target workspace dir (B) the responder would run inside.
BWS="$SCRATCH/ws-BE"; mkdir -p "$BWS/.beads"
cat > "$SCRATCH/workspaces.json" <<JSON
{ "workspaces": [ { "project_ref": "BE", "dir": "$BWS" } ] }
JSON

# ── Stub responder (stands in for specialist.sh) ──────────────────────────────
# Reads the responder context JSON on stdin and prints exactly what the real shim
# prints: the model's final result text. Branches on a marker in the question so
# one stub serves all four cases.
cat > "$SCRATCH/stub-responder.sh" <<'STUB'
#!/usr/bin/env bash
ctx="$(cat)"
case "$ctx" in
  *CONFLICT_CASE*)
    printf '%s\n' '{"verdict":"escalate","reason":"conflict","summary":"FE assumes DELETE->204 empty; BE orders.js:88 returns 200 + {ok,refunded_cents}. Contract drift.","conflicting_claims":["FE: DELETE->204 empty","BE orders.js:88: 200 + {ok,refunded_cents}"],"options":[{"label":"FE adopts BE 200+body shape","blast_radius":"FE parsing change; BE already deployed"},{"label":"BE changes to 204 empty","blast_radius":"BE redeploy + other consumers"}],"recommendation":"FE adopts BE shape (already deployed)"}'
    ;;
  *MISSING_CASE*)
    printf '%s\n' '{"verdict":"escalate","reason":"missing_design","summary":"Neither side has decided the cancel-refund webhook shape; the endpoint does not exist and no bd task owns it.","conflicting_claims":[],"options":[{"label":"Define webhook now (BE owns)","blast_radius":"new BE endpoint + FE consumer"},{"label":"Defer; FE polls order state","blast_radius":"FE polling loop"}],"recommendation":"Define the webhook (BE owns the source of truth)"}'
    ;;
  *PROSE_CASE*)
    # A persona/prose leak — NOT a clean verdict object. The server must treat
    # this as escalate-to-safe (never fabricate an answer).
    printf '%s\n' 'I looked through the backend code and I think the endpoint probably returns a 200 with a body, but I am not fully certain so here is my reasoning...'
    ;;
  *)
    printf '%s\n' '{"verdict":"answer","answer":"Deployed since commit a1b2c3. Shape: {ok, refunded_cents}. 204 on already-cancelled.","evidence":["cf/src/orders.js:88","thirsty-be-12f closed"]}'
    ;;
esac
exit 0
STUB
chmod +x "$SCRATCH/stub-responder.sh"

# ── Stub engine bridge (stands in for helpers/engine-bridge.sh) ───────────────
# Records every leg the server fires (one word per line in $XWS_STUB_CALLS),
# captures the write_fallback worker_ask + every relay-log-append exchange, and
# returns a canned single-item ruling on poll_once so the FULL escalate round-trip
# completes on the first poll cycle (no store, no human, no wall-clock wait).
cat > "$SCRATCH/stub-bridge.sh" <<'BRIDGE'
#!/usr/bin/env bash
set -uo pipefail
sub="${1:-}"; shift 2>/dev/null || true
printf '%s\n' "$sub" >> "$XWS_STUB_CALLS"
case "$sub" in
  id_for)
    # $1 = bead_ref. Deterministic dossier id (the server uses this verbatim).
    printf '%s' "STUBDID"
    ;;
  write_fallback)
    # $1 = dossier_id, $2 = bead_ref, $3 = worker_ask_json. Capture the worker_ask
    # so the test can assert the §5 mapping; echo the id back (the server reads
    # write_fallback's stdout as the persisted dossier id).
    printf '%s' "${3:-}" > "$XWS_STUB_WORKER_ASK"
    printf '%s' "${1:-}"
    ;;
  write_polished)
    printf '%s' "${1:-STUBDID}"
    ;;
  relay_log_append)
    # $1 = exchange_json. Append-only audit line; rc 0, no stdout (matches the
    # real bridge's contract).
    printf '%s\n' "${1:-}" >> "$XWS_STUB_RELAY"
    ;;
  poll_once)
    # $1 = dossier_id. Return Brian's ruling immediately (the {items:[...]} shape
    # formatRuling consumes) so the server breaks its poll loop on cycle 1.
    printf '%s' '{"items":[{"item_id":"i1","state":"answered","ask":"Which contract shape wins?","chosen":"opt-1","chosen_label":"STUB-RULING-CHOICE","chosen_blast_radius":"FE parsing change","free_text":""}]}'
    ;;
  *)
    printf 'stub-bridge: unknown subcommand %s\n' "$sub" >&2
    exit 2
    ;;
esac
exit 0
BRIDGE
chmod +x "$SCRATCH/stub-bridge.sh"

export XWS_REGISTRY_PATH="$SCRATCH/workspaces.json"
export XWS_SPECIALIST_BIN="$SCRATCH/stub-responder.sh"
export XWS_BRIDGE_BIN="$SCRATCH/stub-bridge.sh"
export PROJECT_REF="FE"                       # from_ws resolved server-side
export POLL_INTERVAL_MS=50
export POLL_MAX_MS=10000                       # never reached: stub poll rules on cycle 1
# These three are read by the stub bridge at runtime (inherited via the server's
# env: process.env passthrough to the bridge child).
export XWS_STUB_CALLS="$SCRATCH/bridge-calls.log"
export XWS_STUB_WORKER_ASK="$SCRATCH/worker-ask.json"
export XWS_STUB_RELAY="$SCRATCH/relay-appends.jsonl"

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
  # SIGTERM first: in_flight is 0 by the time we reach cleanup, so the server's
  # graceful-drain latch exits 0 cleanly instead of leaving a job-control
  # 'Killed: 9' line on the terminal (which reads like a crash). SIGKILL only as
  # a fallback if it doesn't exit within a brief grace window.
  kill -TERM "$SRV_PID" 2>/dev/null || true
  for _ in $(seq 1 15); do kill -0 "$SRV_PID" 2>/dev/null || break; sleep 0.2; done
  kill -9 "$SRV_PID" 2>/dev/null || true
  pkill -9 -f "$SCRATCH/stub-bridge.sh" 2>/dev/null || true
  pkill -9 -f "$SCRATCH/stub-responder.sh" 2>/dev/null || true
  wait "$SRV_PID" 2>/dev/null || true
}
trap cleanup EXIT

FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS+1)); }

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
reset_logs() { : > "$XWS_STUB_CALLS"; rm -f "$XWS_STUB_WORKER_ASK"; : > "$XWS_STUB_RELAY"; }
calls()      { tr '\n' ' ' < "$XWS_STUB_CALLS" 2>/dev/null; }
resp_text()  { grep -F "\"id\":$1" "$OUT" | tail -1 | jq -r '.result.content[0].text // ""'; }
resp_has_iserr() { grep -F "\"id\":$1" "$OUT" | tail -1 | jq -r '.result | has("isError")'; }

# ── handshake + tools/list ────────────────────────────────────────────────────
send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}'
send '{"jsonrpc":"2.0","method":"notifications/initialized"}'
send '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
wait_for '"id":2' 10 || { echo "FAIL: no tools/list response"; cat "$LOG"; exit 1; }
grep -F '"name":"ask-workspace"' "$OUT" >/dev/null || fail "ask-workspace not advertised"

# ── 1. ANSWER branch (the 80%): relay entry, NO dossier leg ───────────────────
reset_logs
send '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ask-workspace","arguments":{"to_ws":"BE","question":"ANSWER_CASE: is DELETE /orders/:id deployed and what does it return?","context_dump":"FE assumes 204 empty.","bead_ref":"thirsty-fe-93o"}}}'
wait_for '"id":3' 20 || { echo "FAIL: no answer-path response"; cat "$LOG"; exit 1; }
T3="$(resp_text 3)"
echo "[answer] tool_result: $T3"
printf '%s' "$T3" | grep -q "Workspace BE answered:" || fail "[answer] expected 'Workspace BE answered:'"
printf '%s' "$T3" | grep -q "Deployed since commit a1b2c3" || fail "[answer] answer text not relayed"
[[ "$(resp_has_iserr 3)" == "false" ]] || fail "[answer] R1 §Q1 — result.isError must be absent"
C3="$(calls)"
echo "[answer] bridge legs: $C3"
printf '%s' "$C3" | grep -q "relay_log_append" || fail "[answer] no relay-log-append fired"
printf '%s' "$C3" | grep -Eq "id_for|write_fallback|write_polished|poll_once" && fail "[answer] a DOSSIER leg fired on the mechanical answer path (must not)"
[[ "$(jq -r '.outcome' < "$XWS_STUB_RELAY" 2>/dev/null)" == "resolved" ]] || fail "[answer] relay outcome must be 'resolved'"
[[ "$(jq -r '.dossier_ref' < "$XWS_STUB_RELAY" 2>/dev/null)" == "" ]] || fail "[answer] resolved relay row must carry no dossier_ref"
echo "[answer] OK — relay(resolved) only, no dossier leg, isError absent"

# ── 2. CONFLICT branch (the 20%): full escalate → ruling round-trip ───────────
reset_logs
send '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"ask-workspace","arguments":{"to_ws":"BE","question":"CONFLICT_CASE: cancel endpoint — 204 or 200+body?","context_dump":"FE assumes DELETE->204 empty.","bead_ref":"thirsty-fe-77e"}}}'
wait_for '"id":4' 20 || { echo "FAIL: no conflict-path response"; cat "$LOG"; exit 1; }
T4="$(resp_text 4)"
echo "[conflict] tool_result: $T4"
printf '%s' "$T4" | grep -q "surfaced a conflict" || fail "[conflict] tool_result must name the conflict"
printf '%s' "$T4" | grep -q "escalated to Brian, who ruled:" || fail "[conflict] full ruling round-trip not returned"
printf '%s' "$T4" | grep -q "Brian's answer: STUB-RULING-CHOICE" || fail "[conflict] Brian's ruling not formatted back to A"
[[ "$(resp_has_iserr 4)" == "false" ]] || fail "[conflict] R1 §Q1 — result.isError must be absent"
C4="$(calls)"
echo "[conflict] bridge legs: $C4"
for leg in id_for write_fallback relay_log_append poll_once; do
  printf '%s' "$C4" | grep -q "$leg" || fail "[conflict] escalate leg '$leg' did not fire"
done
# §5 mapping: the responder's escalate verdict became a worker_ask the dossier
# path consumes (summary + conflicting_claims + options + recommendation).
WA="$XWS_STUB_WORKER_ASK"
[[ -s "$WA" ]] || fail "[conflict] write_fallback received no worker_ask"
[[ "$(jq -r '.options | length' < "$WA" 2>/dev/null)" -ge 2 ]] || fail "[conflict] worker_ask must carry the responder's options"
jq -e '.ask | test("Conflicting claims")' < "$WA" >/dev/null 2>&1 || fail "[conflict] worker_ask.ask must surface the conflicting claims"
[[ -n "$(jq -r '.recommendation.value // ""' < "$WA" 2>/dev/null)" ]] || fail "[conflict] worker_ask must carry a recommendation"
[[ -n "$(jq -r '.tldr // ""' < "$WA" 2>/dev/null)" ]] || fail "[conflict] worker_ask must carry a tldr (the responder summary)"
# §5.2: the relay row records the escalation with the dossier_ref linked.
[[ "$(jq -r '.outcome' < "$XWS_STUB_RELAY" 2>/dev/null)" == "escalated" ]] || fail "[conflict] relay outcome must be 'escalated'"
[[ "$(jq -r '.dossier_ref' < "$XWS_STUB_RELAY" 2>/dev/null)" == "STUBDID" ]] || fail "[conflict] escalated relay row must link the dossier_ref"
echo "[conflict] OK — verdict→§5 worker_ask, blocking dossier, relay(escalated+ref), ruling returned"

# ── 3. MISSING_DESIGN branch: same escalate path, reason=missing_design ───────
reset_logs
send '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"ask-workspace","arguments":{"to_ws":"BE","question":"MISSING_CASE: what is the cancel-refund webhook shape?","context_dump":"FE has no assumption; asking what BE decided.","bead_ref":"thirsty-fe-88e"}}}'
wait_for '"id":5' 20 || { echo "FAIL: no missing-design-path response"; cat "$LOG"; exit 1; }
T5="$(resp_text 5)"
echo "[missing] tool_result: $T5"
printf '%s' "$T5" | grep -q "surfaced a missing_design" || fail "[missing] tool_result must name the missing_design"
printf '%s' "$T5" | grep -q "escalated to Brian, who ruled:" || fail "[missing] ruling round-trip not returned"
[[ "$(resp_has_iserr 5)" == "false" ]] || fail "[missing] R1 §Q1 — result.isError must be absent"
C5="$(calls)"
echo "[missing] bridge legs: $C5"
printf '%s' "$C5" | grep -q "write_fallback" || fail "[missing] blocking dossier was not written"
[[ "$(jq -r '.outcome' < "$XWS_STUB_RELAY" 2>/dev/null)" == "escalated" ]] || fail "[missing] relay outcome must be 'escalated'"
echo "[missing] OK — missing-design escalates to a blocking dossier"

# ── 4. ESCALATE-TO-SAFE: non-verdict prose → escalate, never a fabricated answer ─
reset_logs
send '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"ask-workspace","arguments":{"to_ws":"BE","question":"PROSE_CASE: does cancel return 204?","context_dump":"FE assumes 204.","bead_ref":"thirsty-fe-pro"}}}'
wait_for '"id":6' 20 || { echo "FAIL: no escalate-to-safe response"; cat "$LOG"; exit 1; }
T6="$(resp_text 6)"
echo "[safe] tool_result: $T6"
printf '%s' "$T6" | grep -q "Workspace BE answered:" && fail "[safe] a prose-leak was fabricated into an answer (must escalate)"
printf '%s' "$T6" | grep -q "escalated to Brian" || fail "[safe] non-verdict prose must escalate-to-safe"
# R1 §Q1 matters MOST here: this branch is reached via a responder PARSE FAILURE
# + a server-SYNTHESIZED verdict, the path most likely to regress to is_error.
[[ "$(resp_has_iserr 6)" == "false" ]] || fail "[safe] R1 §Q1 — result.isError must be absent"
C6="$(calls)"
echo "[safe] bridge legs: $C6"
printf '%s' "$C6" | grep -q "write_fallback" || fail "[safe] escalate-to-safe did not route to the dossier path"
[[ "$(jq -r '.outcome' < "$XWS_STUB_RELAY" 2>/dev/null)" == "escalated" ]] || fail "[safe] relay outcome must be 'escalated'"
echo "[safe] OK — non-verdict prose → escalate(missing_design), no fabricated answer"

echo
if [[ "$FAILS" -eq 0 ]]; then
  echo "K4 ESCALATE-CONFORMANCE PASSED — both branches verified (answer + escalate; conflict + missing_design + escalate-to-safe)"
  exit 0
else
  echo "K4 ESCALATE-CONFORMANCE FAILED — $FAILS assertion(s) failed"; cat "$LOG"
  exit 1
fi
