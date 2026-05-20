#!/bin/bash
# beads-runner/cf/pages-dev/verify.sh — CF.10 (claude-tools-7g0.10).
#
# THE observable EXIT proof. Stands up, locally and with NO Cloudflare
# account (workerd+miniflare):
#   • the FROZEN CF.1 engine, fronted by the CF.10 re-frame adapter
#     (`wrangler dev --config wrangler.pages-dev.toml`) — COORDINATOR_URL;
#   • `wrangler pages dev web/board`  — the FROZEN Board proxy + UI;
#   • `wrangler pages dev web/inbox`  — the FROZEN Inbox proxies + UI;
# with COORDINATOR_TOKEN bound SERVER-SIDE only (a pages -b binding; never
# client-shipped — §9.2). It then drives the FROZEN proxies END-TO-END through
# the Pages origins exactly as the browser would, and asserts the four EXIT
# criteria + the §7.4 double-tap exactly-once + the §9.1 chokepoint +
# bearer-never-client + no-frozen-edit. Behaviour-identical to the same
# proxies' ops against the bash oracle (lib/test-board.sh / lib/test-inbox.sh
# co_request work-snapshot / get dossier / item-apply / forensic-*).
#
# Stops at LOCALLY-GREEN. NO production deploy (the a53 gate, EXCLUDED).
# Exit 0 iff every assertion passes.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CF_DIR="$(cd "$HERE/.." && pwd)"
WEB_DIR="$(cd "$CF_DIR/../web" && pwd)"
WRANGLER="$CF_DIR/node_modules/.bin/wrangler"
GOOD="bearer-runner-secret-xyz"          # oracle bearer (CO_EXPECTED_TOKEN unset)
ADAPTER_PORT="${CF10_ADAPTER_PORT:-8787}"
BOARD_PORT="${CF10_BOARD_PORT:-8788}"
INBOX_PORT="${CF10_INBOX_PORT:-8789}"
A="http://127.0.0.1:$ADAPTER_PORT"
B="http://127.0.0.1:$BOARD_PORT"
I="http://127.0.0.1:$INBOX_PORT"

[[ -x "$WRANGLER" ]] || { echo "FATAL: wrangler not found at $WRANGLER (run npm install in cf/)"; exit 2; }
command -v node >/dev/null 2>&1 || { echo "FATAL: node required"; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "FATAL: curl required"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \xE2\x9C\x93 %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \xE2\x9C\x97 %s\n' "$1"; FAIL=$((FAIL+1)); }
ck()  { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
eq()    { [[ "$1" == "$2" ]]; }
has()   { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }
hasnt() { case "$2" in *"$1"*) return 1;; *) return 0;; esac; }

TMP="$(mktemp -d)"
PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" >/dev/null 2>&1 || true; done
  # wrangler spawns a workerd child; sweep the temp-persist tree's procs too.
  for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && pkill -P "$p" >/dev/null 2>&1 || true; done
  rm -rf "$TMP" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# wait_ready <url> <label> <want_code> [extra curl args...] — poll until the
# URL returns EXACTLY <want_code> on TWO consecutive probes ~1s apart. The
# two-in-a-row gate steps past wrangler's startup window, where `dev`/`pages
# dev` open the proxy port and answer a transient 5xx (or restart the socket
# after the first bundle) BEFORE the worker is actually live — the prior
# "any answered code = up" check let the seed fire into that window and undici
# threw "fetch failed". Requiring the real success code, stable, removes it.
wait_ready() {
  local url="$1" label="$2" want="$3"; shift 3
  local i hits=0 code
  for i in $(seq 1 150); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" "$url" 2>/dev/null || echo 000)"
    if [[ "$code" == "$want" ]]; then
      hits=$((hits + 1))
      [[ "$hits" -ge 2 ]] && return 0
    else
      hits=0
    fi
    sleep 1
  done
  echo "FATAL: $label not ready at $url (want HTTP $want; last=$code) within 150s"
  return 1
}

echo "── CF.10 boot: FROZEN engine + re-frame adapter (no account) ──"
(
  cd "$CF_DIR" || exit 2
  exec "$WRANGLER" dev --config wrangler.pages-dev.toml \
    --port "$ADAPTER_PORT" --ip 127.0.0.1 \
    --persist-to "$TMP/adapter-state" \
    >"$TMP/adapter.log" 2>&1
) &
PIDS+=("$!")
wait_ready "$A/" "Coordinator adapter" 200 -H "authorization: Bearer $GOOD" || { tail -25 "$TMP/adapter.log"; exit 2; }
# Engine bundle truly executes (the ../src import + the singleton DO), not just
# the proxy shell: the native capabilities op must return the real §2 listing
# (text/plain — the four §2 capability lines, NOT JSON) BEFORE seeding.
CAPS="$(curl -s -X POST -H "authorization: Bearer $GOOD" -H 'content-type: application/json' -d '{"op":"capabilities","args":[]}' "$A/" 2>/dev/null)"
echo "$CAPS" | grep -q 'POST /' || { echo "FATAL: adapter native dialect not live (caps=$CAPS)"; tail -25 "$TMP/adapter.log"; exit 2; }

# Boot the Pages servers SEQUENTIALLY — each fully ready before the next.
# Two `wrangler pages dev` started concurrently race wrangler's GLOBAL dev
# registry and one silently never binds its port; staggering removes it.
# `pages dev` must run with cwd = the web-app dir + directory arg `.`: it
# detects `./functions` RELATIVE TO CWD (any other cwd ⇒ "No Functions.
# Shimming...", the FROZEN proxies never served) and a cwd holding a Worker
# wrangler.toml (e.g. cf/) is mis-read as the Pages config (its Coordinator DO
# can't export from the pages-shim ⇒ fatal). web/board|inbox has none.
echo "── CF.10 boot: wrangler pages dev — Board (FROZEN web/board) ──"
(
  cd "$WEB_DIR/board" || exit 2
  exec "$WRANGLER" pages dev . \
    --port "$BOARD_PORT" --ip 127.0.0.1 \
    --compatibility-date 2026-05-01 \
    -b "COORDINATOR_URL=$A" -b "COORDINATOR_TOKEN=$GOOD" \
    >"$TMP/board.log" 2>&1
) &
PIDS+=("$!")
wait_ready "$B/" "Board Pages" 200 || { tail -25 "$TMP/board.log"; exit 2; }

echo "── CF.10 boot: wrangler pages dev — Inbox (FROZEN web/inbox) ──"
(
  cd "$WEB_DIR/inbox" || exit 2
  exec "$WRANGLER" pages dev . \
    --port "$INBOX_PORT" --ip 127.0.0.1 \
    --compatibility-date 2026-05-01 \
    -b "COORDINATOR_URL=$A" -b "COORDINATOR_TOKEN=$GOOD" \
    >"$TMP/inbox.log" 2>&1
) &
PIDS+=("$!")
wait_ready "$I/" "Inbox Pages" 200 || { tail -25 "$TMP/inbox.log"; exit 2; }
echo "  (all three local services live: adapter=$A board=$B inbox=$I)"

echo "── seed the FROZEN engine (native dialect, the co_request analogue) ──"
SEED="$(node "$HERE/seed.mjs" "$A" "$GOOD" dRT 2>"$TMP/seed.err")" || { echo "FATAL: seed failed"; cat "$TMP/seed.err"; exit 2; }
echo "  seed: $SEED"
DID="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).dossier_id)' "$SEED" 2>/dev/null)"
[[ "$DID" == "dRT" ]] || { echo "FATAL: seed did not return dossier dRT (got '$DID')"; exit 2; }

echo ""
echo "── EXIT-1: Board renders the LIVE §4.5 projection; WAITING-ON-YOU lane = a partly-answered dossier ──"
BH="$(curl -s -D "$TMP/bh" "$B/api/board")"
ck "GET /api/board returns the §4.5 projection (schema_version 1)"  eq "$(jq -r '.schema_version' <<<"$BH")" "1"
ck "projection self-declares read_only:true (§4.5)"                 eq "$(jq -r '.read_only' <<<"$BH")" "true"
ck "§9.1 principal STAMPED by the FROZEN chokepoint (=brian)"       eq "$(jq -r '.principal' <<<"$BH")" "brian"
ck "Board proxy stamps the no-write-path header (§4.5)"             has "x-board-read-only: true" "$(tr 'A-Z' 'a-z' <"$TMP/bh")"
ck "WAITING-ON-YOU lane surfaces the seeded Dossier"               eq "$(jq -r '[.waiting_on_you[]|select(.dossier_ref=="dRT")]|length' <<<"$BH")" "1"
ck "lane shows it partly-OPEN: 2 open items of 2"                   eq "$(jq -r '.waiting_on_you[]|select(.dossier_ref=="dRT").open_item_count' <<<"$BH")" "2"
ck "lane carries NO dossier body/items (pointer only — principle 2)" eq "$(jq -r '.waiting_on_you[]|select(.dossier_ref=="dRT")|(has("body") or has("items"))' <<<"$BH")" "false"
ck "live runner projA surfaced (machine health, §4.2 derived)"     eq "$(jq -r '.projects[]|select(.project_ref=="projA").runner_state.liveness' <<<"$BH")" "live"

echo ""
echo "── EXIT-2: Inbox loads a Dossier (op get) + submits ONE per-Item response (op item-apply) e2e ──"
IH="$(curl -s -D "$TMP/ih" "$I/api/inbox")"
ck "GET /api/inbox returns the SAME §4.5 projection (op work-snapshot)" eq "$(jq -r '.schema_version' <<<"$IH")" "1"
ck "Inbox lane shows the partly-answered dossier (AD7)"            eq "$(jq -r '[.waiting_on_you[]|select(.dossier_ref=="dRT")]|length' <<<"$IH")" "1"
ck "Inbox proxy stamps x-inbox-read-only:true"                     has "x-inbox-read-only: true" "$(tr 'A-Z' 'a-z' <"$TMP/ih")"

DOSS="$(curl -s "$I/api/dossier?id=dRT")"
ck "GET /api/dossier?id=dRT returns the §4 Dossier RECORD (op get)" eq "$(jq -r '.id' <<<"$DOSS")" "dRT"
ck "§9.1 principal stamped on the stored dossier (=brian)"          eq "$(jq -r '.principal' <<<"$DOSS")" "brian"
ck "§5 body⊃items rendered unit present (4-tier body)"             eq "$(jq -r '[(.body.tldr|length>0),(.body.full_detail|length>0)]|all' <<<"$DOSS")" "true"
ck "two §4.1.1 Items round-tripped (a1,a2 — partial possible)"     eq "$(jq -r '.items|length' <<<"$DOSS")" "2"
ck "item a1 starts open; latch false (pre-response §4.1.1)"        eq "$(jq -r '.items[]|select(.id=="a1")|.state+"/"+(.consequence_applied|tostring)' <<<"$DOSS")" "open/false"

RESP='{"dossier_id":"dRT","item_id":"a1","response":{"decision":"approve","responded_at":"2026-05-17T00:00:00Z"}}'
AP1="$(curl -s -X POST -H 'content-type: application/json' -d "$RESP" "$I/api/respond")"
ck "POST /api/respond (op item-apply) applies ONE Item — ok"        eq "$(jq -r '.ok' <<<"$AP1")" "true"
DOSS2="$(curl -s "$I/api/dossier?id=dRT")"
ck "item a1 open→applied (T5 §4.1.1, via the FROZEN proxy)"        eq "$(jq -r '.items[]|select(.id=="a1").state' <<<"$DOSS2")" "applied"
ck "§7.4 per-Item latch flipped false→true"                       eq "$(jq -r '.items[]|select(.id=="a1").consequence_applied' <<<"$DOSS2")" "true"
ck "sibling a2 UNTOUCHED — open (partial, AD7)"                    eq "$(jq -r '.items[]|select(.id=="a2").state' <<<"$DOSS2")" "open"
APPLIED_AT1="$(jq -r '.items[]|select(.id=="a1").applied_at' <<<"$DOSS2")"
ck "a1.applied_at stamped (§4.1.1)"                                test -n "$APPLIED_AT1"

# the partly-answered dossier STILL shows on the Board lane (AD7) — now 1 open
BH2="$(curl -s "$B/api/board")"
ck "Board lane STILL shows dRT, now 1 open item (partly-answered)" eq "$(jq -r '.waiting_on_you[]|select(.dossier_ref=="dRT").open_item_count' <<<"$BH2")" "1"

echo ""
echo "── EXIT-2 (§7.4): a double-tap of the SAME Item is EXACTLY-ONCE ──"
AP2="$(curl -s -X POST -H 'content-type: application/json' -d "$RESP" "$I/api/respond")"
ck "double-tap /api/respond ⇒ idempotent success (not an error)"   eq "$(jq -r '.ok' <<<"$AP2")" "true"
DOSS3="$(curl -s "$I/api/dossier?id=dRT")"
ck "a1 still applied + latched true after the double-tap"          eq "$(jq -r '.items[]|select(.id=="a1")|.state+"/"+(.consequence_applied|tostring)' <<<"$DOSS3")" "applied/true"
ck "a1.applied_at UNCHANGED ⇒ the §7.4 latch made it exactly-once" eq "$(jq -r '.items[]|select(.id=="a1").applied_at' <<<"$DOSS3")" "$APPLIED_AT1"

echo ""
echo "── EXIT-3: forensic fetch/dismiss is AUTHED-only via the proxy; client holds NO bearer ──"
F1="$(curl -s -w '\n%{http_code}' "$I/api/forensic?id=fb-1")"
F1B="$(sed '$d' <<<"$F1")"; F1C="$(tail -1 <<<"$F1")"
ck "GET /api/forensic?id=fb-1 ⇒ 200 (authed pull, §10.3)"          eq "$F1C" "200"
ck "the §10.3 redacted blob crossed the authed channel"           has "redacted" "$F1B"
DIS="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d '{"id":"fb-1"}' "$I/api/forensic")"
ck "POST /api/forensic {id} ⇒ 200 dismiss (hard-delete now, §10.3)" eq "$DIS" "200"
F2="$(curl -s -w '\n%{http_code}' "$I/api/forensic?id=fb-1")"
F2B="$(sed '$d' <<<"$F2")"; F2C="$(tail -1 <<<"$F2")"
ck "post-dismiss fetch ⇒ 410 gone (irrecoverable, no tombstone)"   eq "$F2C" "410"
ck "the gone response is honest, not masked"                       has "gone" "$F2B"

# bearer-never-client: the SHIPPED assets carry no secret (§9.2) ...
IDX="$(curl -s "$I/")"; IAPP="$(curl -s "$I/app.js")"; BIDX="$(curl -s "$B/")"; BAPP="$(curl -s "$B/app.js")"
ck "shipped Inbox HTML carries NO COORDINATOR_TOKEN"               hasnt "COORDINATOR_TOKEN" "$IDX"
ck "shipped Inbox app.js carries NO COORDINATOR_TOKEN"             hasnt "COORDINATOR_TOKEN" "$IAPP"
ck "shipped Inbox app.js carries NO bearer literal"                hasnt "$GOOD" "$IAPP"
ck "shipped Board HTML carries NO COORDINATOR_TOKEN"               hasnt "COORDINATOR_TOKEN" "$BIDX"
ck "shipped Board app.js carries NO bearer literal"                hasnt "$GOOD" "$BAPP"
# ... and the §9.1 chokepoint is REAL: a credential-less /request is rejected
# 401 BY THE FROZEN WORKER (before any §4 write); only the server-side binding
# (never the client) is what authorises the Pages path.
NOAUTH="$(curl -s -o /dev/null -w '%{http_code}' "$A/request?op=work-snapshot")"
ck "credential-less /request ⇒ 401 (§9.1 chokepoint, FROZEN worker)" eq "$NOAUTH" "401"
WITHAUTH="$(curl -s -o /dev/null -w '%{http_code}' -H "authorization: Bearer $GOOD" "$A/request?op=work-snapshot")"
ck "same /request WITH the server-side bearer ⇒ 200 (authed)"      eq "$WITHAUTH" "200"

echo ""
echo "── EXIT-4: no FROZEN edit (READ proxies / engine / INTERFACE) — additive wiring only ──"
# F2 (claude-tools-8fh) legitimately edits the BOARD CLIENT (board-view.js /
# app.js / board.css) to add the per-workspace toggle row, so the prior
# "web/ UNMODIFIED" blanket is REPLACED with a narrower check: the FROZEN
# READ proxies (functions/api/board.js, the inbox proxies) and the engine
# source remain untouched. The Board client surfaces are now an evolving
# UI layer (test-board.sh owns its structural invariants).
# F3 (claude-tools-6mx) further narrows: web/board/functions/api/set-desired.js
# is the WRITE proxy (F1) — legitimately evolving with the desired-state wire
# contract (e.g. F3's UI→§4.2 normalisation). Only the READ proxies (board.js,
# inbox/*) remain in the frozen set; the WRITE proxies live on board.js's
# sibling path but are NOT frozen.
DIRTY="$(cd "$CF_DIR/../.." && git status --porcelain \
  -- beads-runner/web/board/functions/api/board.js \
     beads-runner/web/inbox/functions \
     beads-runner/cf/src \
     beads-runner/cf/wrangler.toml \
     beads-runner/INTERFACE.md \
  2>/dev/null | grep -E '^( M|MM|AM|D )' || true)"
ck "READ proxies + cf/src + wrangler.toml + INTERFACE.md UNMODIFIED" test -z "$DIRTY"
# Flow D (F1, claude-tools-49w) legitimized set-desired as the Board-side
# write proxy, so the adapter NOW names it as a mapped write op — the prior
# "no set-desired literal" CF.10-era assertion has been REPLACED with a
# positive mapping check (the proxy file owns the validation; this just
# asserts the adapter has the unwrap to the engine's positional args).
ck "adapter maps set-desired writes (Flow D Board-side, F1)"        has "\"set-desired\"" "$(cat "$HERE/adapter.js")"
ck "the adapter never holds/injects a bearer (copies header thru)" hasnt "Bearer " "$(cat "$HERE/adapter.js")"
# F2 (claude-tools-8fh): a fresh GET /api/board after a real /api/set-desired
# POST reflects the new desired-state on the SAME RunnerState the daemon will
# converge against — the Board↔engine write loop is wired end-to-end (the
# convergence itself is M3's job and gated by claude-tools-6mx). The actual
# stays whatever the runner last reported — NEVER promoted by the write.
SD_BODY='{"project_ref":"projA","desired":{"state":"paused","actor":"ui:verify"}}'
SDOUT="$(curl -s -X POST -H 'content-type: application/json' -d "$SD_BODY" "$B/api/set-desired")"
ck "POST /api/set-desired (F2 client→F1 proxy→engine) ⇒ ok"          eq "$(jq -r '.ok' <<<"$SDOUT")" "true"
BH3="$(curl -s "$B/api/board")"
ck "next /api/board reflects new desired=paused (engine round-trip)" eq "$(jq -r '.projects[]|select(.project_ref=="projA").runner_state.desired' <<<"$BH3")" "paused"
# Honest-state: the actual is NOT promoted by the write — it is whatever the
# runner last reported (here `running` from the seed) until M3 converges.
ck "actual NOT promoted by the write (principle 4 — honest)"         eq "$(jq -r '.projects[]|select(.project_ref=="projA").runner_state.actual' <<<"$BH3")" "running"
# The §9.1 chokepoint also covers the WRITE path — credential-less direct
# POST to the engine /request must 401, exactly like the read.
NOAUTH_W="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d "$SD_BODY" "$A/request?op=set-desired")"
ck "credential-less /request?op=set-desired ⇒ 401 (§9.1 covers write)" eq "$NOAUTH_W" "401"
# An invalid desired-state is rejected at the proxy with 422 BEFORE a
# Coordinator round-trip (the cheap-and-honest first gate — F1).
SD_BAD='{"project_ref":"projA","desired":{"state":"bogus","actor":"ui:verify"}}'
BADC="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d "$SD_BAD" "$B/api/set-desired")"
ck "POST set-desired with bogus state ⇒ 422 (proxy frozen-set gate)"  eq "$BADC" "422"
# F3 (claude-tools-6mx) — UI ↔ wire normalisation: a UI `spare-only` MUST land
# in the engine as the §4.2 enum `spare-cycles` so the daemon's M3 enum filter
# accepts it and the runner's C2 gate fires. The proxy validates `spare-only`
# at the gate, then sends `spare-cycles` on the wire — confirmed by the next
# /api/board read echoing the normalised value.
SD_SPARE='{"project_ref":"projA","desired":{"state":"spare-only","actor":"ui:verify"}}'
SDS="$(curl -s -X POST -H 'content-type: application/json' -d "$SD_SPARE" "$B/api/set-desired")"
ck "POST set-desired spare-only ⇒ ok"                                  eq "$(jq -r '.ok' <<<"$SDS")" "true"
BH4="$(curl -s "$B/api/board")"
ck "engine stored §4.2 wire enum 'spare-cycles' (UI normalised in proxy, F3)" \
    eq "$(jq -r '.projects[]|select(.project_ref=="projA").runner_state.desired' <<<"$BH4")" "spare-cycles"

echo ""
echo "======================================================================"
echo " CF.10 pages-dev verify (claude-tools-7g0.10):  PASS=$PASS  FAIL=$FAIL"
echo "======================================================================"
[[ "$FAIL" -eq 0 ]]
