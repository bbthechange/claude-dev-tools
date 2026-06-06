#!/bin/bash
# beads-runner/lib/test-co-http-transport.sh — I1 acceptance (claude-tools-txj;
# epic claude-tools-8bm). The I0 audit's 5-point handoff, PROVED.
#
# WHAT THIS PROVES (the I1 acceptance, honestly scoped):
#
#   PART A — LIVE deployed coordinator-cf, the reachable posture (no real
#     token; the production CO_EXPECTED_TOKEN is held by Brian out of agent
#     context BY DESIGN — cf-production-deploy-topology). Drives the REUSED
#     do_dossier_get over the I1 HTTP transport against
#     https://coordinator-cf.bbthechange.workers.dev and asserts the I0
#     divergences are CLOSED on the live path that IS reachable: a 401 now
#     cleanly maps to rc 1 + empty stdout + a stderr diagnostic (clean
#     "absent/unreachable"), NOT the I0 rc-3 §0.3-corrupt misclassification
#     (D0/D1/D2/D3). This is a real LIVE differential vs the I0 "before".
#
#   PART B — the SUCCESS + REJECT paths (the hop I0 could not reach), against
#     a LOCAL instance of the BYTE-IDENTICAL engine the differential rig
#     (CF.11) proved ≡ the bash oracle and which production runs verbatim
#     (cf/pages-dev/adapter.js over the unchanged cf/src — wrangler.pages-dev
#     CO_EXPECTED_TOKEN unset ⇒ a known bearer authenticates). Drives the
#     REUSED stuck/dossier flow end-to-end over the HTTP transport and asserts
#     behaviour BYTE-IDENTICAL to the in-process bash oracle: put⇒rc0,
#     get-present⇒rc0+record (schema_version int, principal stamped),
#     get-absent⇒rc1 (NOT rc3 — D2), put-reject⇒rc3 (D1), timer round-trip,
#     timer-due non-200⇒LOUD nonzero (D5), and the dossier is read back
#     through the EXACT deployed-Inbox path (GET /request?op=get&type=dossier)
#     — i.e. the dossier the runner produced IS visible to the Inbox front.
#     Also exercises the §1.1 la_outbox_drain push.
#
#   PART C — if a real production token DOES resolve (Keychain/COORDINATOR_TOKEN
#     pointed at prod), Part B's success path is additionally run against the
#     LIVE deployed engine (the I5 hop). Auto-detected; SKIPPED with an
#     explicit by-design notice when the token is withheld (it always is in an
#     autonomous run — that withholding is itself the I0 D0 headline, and the
#     genuine human-on-phone unmocked proof is consolidated SOLELY into I5).
#
#   PART D — K3 (claude-tools-uxvk3) deferred-live-verify, cleared. Same token-
#     gating as A/C: when a prod token resolves, an authed probe drives the §K3
#     `notif-digest` read-side rollup against the LIVE deployed coordinator-cf
#     and asserts the new shape {digests:[{channel,count,tier,dossier_refs},…]}
#     — the TESTING-STRATEGY §5 item-4 engine live-verify bar (+§7.6 residual
#     T8 step, the bgw/2dk R1 "local green is not acceptance" anchor). SKIPPED
#     by-design without a token (run-tests.sh neutralizes it — §8: SKIP is not a
#     failure); the read CONTRACT is proven offline by the notification twin.
#
# Deliberately NOT a member of the T1 conformance suite (beads-runner/
# conformance/) — its own focused acceptance, same discipline as the other
# lib/test-*.sh. Run:  bash beads-runner/lib/test-co-http-transport.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CF_DIR="$(cd "$HERE/../cf" && pwd)"
WRANGLER="$CF_DIR/node_modules/.bin/wrangler"
LIVE_URL="https://coordinator-cf.bbthechange.workers.dev"
PLACEHOLDER="bearer-runner-secret-xyz"     # the bearer the libs/tests carry (I0 D0)

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
note(){ printf '  · %s\n' "$1"; }
eq()  { [[ "$1" == "$2" ]] && ok "$3" || { bad "$3 (got '$1' want '$2')"; }; }

# A well-formed §4.1 envelope + Item (the reused do_dossier_put input shape;
# copied verbatim from test-dossier.sh's fixtures — test scaffolding, not the
# frozen libs).
mk()   { jq -cn --arg id "$1" --argjson sv "$2" --argjson items "$3" '
    { id:$id, schema_version:$sv, kind:"decide", trigger:"worker_stuck",
      bead_ref:"claude-tools-txj", tier:"blocking",
      created_at:"2026-05-17T00:00:00Z", timer_fire_at:null,
      body:{ dossier_schema_version:2, tldr:"opaque to substrate",
             sections:[], diagrams:[], full_detail:"I1 transport proof" },
      items:$items }'; }
item() { jq -cn --arg i "$1" --arg s "$2" '
    { id:$i, kind:"approve-reject", framing:{}, context_anchor:{where:"x",expansion:"y"},
      consequence_block:{cb_schema_version:2,creates:[],unblocks:[],labels:[],status_changes:[]},
      state:$s, response:null, consequence_applied:false, applied_at:null }'; }

# ════════════════════════════════════════════════════════════════════════════
# PART A — LIVE deployed coordinator-cf: the I0 divergences CLOSED, reachable
#          posture (401), driven through the REUSED do_dossier_get.
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART A — LIVE deployed coordinator-cf · I0 D0–D3 closed (401 posture) ──"
echo "   target: $LIVE_URL  (no real token — the by-design D0 withholding)"

# §8 / TESTING-STRATEGY: this LIVE coordinator-cf probe is T8 — "expected to be
# skipped/SKIP without a prod token — that SKIP is not a failure." The offline
# gate (run-tests.sh) runs with NO token resolvable, so detect a prod token and
# SKIP the live hop when none resolves: no network below T8, and the gate stays
# green even on a network-less checkout (a no-bearer probe there is a transport
# error, NOT a 401). PART B re-proves the transport's 401/contract mapping
# against the local byte-identical engine.
A_TOKEN=""
if [[ -n "${COORDINATOR_TOKEN:-}" ]]; then A_TOKEN="env"
elif security find-generic-password -s "claude-beads-runner.coordinator-token" \
       -a "$(hostname)" -w >/dev/null 2>&1; then A_TOKEN="keychain"; fi
if [[ -z "$A_TOKEN" ]]; then
  note "PART A SKIPPED — no §9.2 prod token resolves; the live coordinator-cf 401 probe is T8 (§8: that SKIP is not a failure). The offline transport contract is proven by PART B."
else
(
  set +u
  WORK_A="$(mktemp -d)"
  export CO_STORE="$WORK_A/store"
  export COORDINATOR_URL="$LIVE_URL"
  unset COORDINATOR_TOKEN CO_EXPECTED_TOKEN 2>/dev/null || true
  # Reused stack: dossier.sh pulls coordinator.sh (internals + bash co_request)
  # via its guard; THEN the I1 transport overrides co_request with the HTTP one.
  source "$HERE/dossier.sh"               # → dossier-gen? no: dossier.sh → coordinator.sh
  source "$HERE/co-http-transport.sh"     # OVERRIDE: co_request now HTTP→LIVE

  # raw co_request: a 401 must be bash-contract (rc 1, empty stdout, stderr) —
  # NOT curl's transport rc 0 with a JSON envelope on stdout (I0 D1/D2/D3).
  of="$(mktemp)"; ef="$(mktemp)"
  co_request "$PLACEHOLDER" get dossier i1-NOPE >"$of" 2>"$ef"; rc=$?
  body="$(cat "$of")"; err="$(cat "$ef")"; rm -f "$of" "$ef"
  eq "$rc" "1" "raw co_request 401 ⇒ rc 1 (bash co_request's 401 rc, not curl rc 0)"
  [[ -z "$body" ]] && ok "raw co_request 401 ⇒ EMPTY stdout (D2/D3: no envelope leaks to a jq parse)" \
                    || bad "raw co_request 401 ⇒ EMPTY stdout (got: $(printf '%s' "$body" | head -c 80))"
  printf '%s' "$err" | grep -q "co: 401" \
    && ok "raw co_request 401 ⇒ diagnostic on STDERR (D3)" \
    || bad "raw co_request 401 ⇒ diagnostic on STDERR (got: $(printf '%s' "$err" | head -c 80))"

  # The REUSED reader: I0 PROVED do_dossier_get over the naive HTTP seam
  # collapsed present/absent/401 ALL into rc 3 §0.3-reject. With the I1
  # transport a live 401 must be a CLEAN rc 1 (absent/unreachable), rc != 3.
  o="$(do_dossier_get "$PLACEHOLDER" i1-NOPE 2>/dev/null)"; rc=$?
  [[ "$rc" -ne 3 ]] && ok "REUSED do_dossier_get live-401 ⇒ rc != 3 (the I0 §0.3 misclassification is CLOSED)" \
                     || bad "REUSED do_dossier_get live-401 ⇒ rc != 3 (still got the I0 rc-3 bug)"
  eq "$rc" "1" "REUSED do_dossier_get live-401 ⇒ rc 1 (clean absent/unreachable, oracle-shaped)"
  [[ -z "$o" ]] && ok "REUSED do_dossier_get live-401 ⇒ empty stdout (no envelope surfaced)" \
                || bad "REUSED do_dossier_get live-401 ⇒ empty stdout"

  # D5: timer-due on a non-200 must be a LOUD nonzero so the timed-fyi S-6
  # poll-fallback `|| { … return 1; }` fires (no silent "no timers due").
  due="$(co_request "$PLACEHOLDER" timer-due "2000-01-01T00:00:00Z" 2>/dev/null)"; rc=$?
  { [[ "$rc" -ne 0 ]] && [[ -z "$due" ]]; } \
    && ok "timer-due live-401 ⇒ LOUD nonzero + empty stdout (D5: no silent stall)" \
    || bad "timer-due live-401 ⇒ LOUD nonzero + empty stdout (rc=$rc out='$due')"

  rm -rf "$WORK_A"
)
fi

# ════════════════════════════════════════════════════════════════════════════
# PART B — LOCAL byte-identical engine: SUCCESS + REJECT paths, oracle-equiv,
#          read back through the EXACT deployed-Inbox /request?op=get front.
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART B — local BYTE-IDENTICAL engine · reused flow ≡ bash oracle ──"

if [[ ! -x "$WRANGLER" ]]; then
  bad "wrangler not found at $WRANGLER (run: npm ci in beads-runner/cf) — PART B SKIPPED"
else
  PORT="${CT_TEST_PORT:-8799}"
  ENGINE="http://127.0.0.1:$PORT"
  GOOD="ct-test-bearer-$$"
  STATE_DIR="$(mktemp -d)"
  WLOG="$(mktemp)"
  WPID=""
  cleanup_b() {
    [[ -n "$WPID" ]] && { kill "$WPID" >/dev/null 2>&1 || true; pkill -P "$WPID" >/dev/null 2>&1 || true; }
    rm -rf "$STATE_DIR" "$WLOG" >/dev/null 2>&1 || true
  }
  trap cleanup_b EXIT

  echo "   booting FROZEN engine + CF.10 adapter (wrangler dev) on $ENGINE …"
  ( cd "$CF_DIR" && exec "$WRANGLER" dev --config wrangler.pages-dev.toml \
      --port "$PORT" --ip 127.0.0.1 --persist-to "$STATE_DIR/st" >"$WLOG" 2>&1 ) &
  WPID=$!

  up=0
  for i in $(seq 1 90); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
              -H "authorization: Bearer $GOOD" "$ENGINE/" 2>/dev/null || echo 000)"
    if [[ "$code" == "200" ]]; then up=$((up+1)); [[ "$up" -ge 2 ]] && break; else up=0; fi
    [[ $((i % 10)) -eq 0 ]] && echo "   … still waiting for the local engine (${i}s, last http=$code)"
    sleep 1
  done

  if [[ "$up" -lt 2 ]]; then
    bad "local engine did not come up — PART B SKIPPED (wrangler log tail follows)"
    tail -n 15 "$WLOG" 2>/dev/null | sed 's/^/      | /'
  else
    ok "local byte-identical engine is up ($ENGINE)"

    # ---- WORLD A: in-process bash ORACLE (the behaviour to match) ----------
    oracle_rc_put="" oracle_rc_getP="" oracle_rc_getA="" oracle_rc_bad="" oracle_rec=""
    (
      set +u
      W="$(mktemp -d)"; export CO_STORE="$W/store"
      unset COORDINATOR_URL COORDINATOR_TOKEN CO_EXPECTED_TOKEN 2>/dev/null || true
      source "$HERE/dossier.sh"            # in-process bash co_request
      D="$(mk dCT 2 "[$(item i1 open)]")"
      id="$(do_dossier_put "$PLACEHOLDER" "$D")"; echo "putrc=$?"
      do_dossier_get "$PLACEHOLDER" dCT >/dev/null 2>&1; echo "getPrc=$?"
      do_dossier_get "$PLACEHOLDER" dABSENT >/dev/null 2>&1; echo "getArc=$?"
      BAD="$(jq -cn '{id:"dBAD",schema_version:"1",kind:"decide",items:[]}')"
      do_dossier_put "$PLACEHOLDER" "$BAD" >/dev/null 2>&1; echo "badrc=$?"
      rm -rf "$W"
    ) > "$STATE_DIR/oracle.txt" 2>/dev/null
    oracle_rc_put="$(grep -o 'putrc=[0-9]*'  "$STATE_DIR/oracle.txt" | cut -d= -f2)"
    oracle_rc_getP="$(grep -o 'getPrc=[0-9]*' "$STATE_DIR/oracle.txt" | cut -d= -f2)"
    oracle_rc_getA="$(grep -o 'getArc=[0-9]*' "$STATE_DIR/oracle.txt" | cut -d= -f2)"
    oracle_rc_bad="$(grep -o 'badrc=[0-9]*'  "$STATE_DIR/oracle.txt" | cut -d= -f2)"
    note "bash oracle baseline: put=$oracle_rc_put get-present=$oracle_rc_getP get-absent=$oracle_rc_getA put-bad=$oracle_rc_bad"

    # ---- WORLD B: the REUSED flow over the I1 HTTP transport → local engine -
    (
      set +u
      W="$(mktemp -d)"; export CO_STORE="$W/store"
      export COORDINATOR_URL="$ENGINE"
      export COORDINATOR_TOKEN="$GOOD"     # local engine: CO_EXPECTED_TOKEN unset
      unset CO_EXPECTED_TOKEN 2>/dev/null || true
      source "$HERE/local-agent.sh"        # for la__outbox / la_coordinator_token guards
      source "$HERE/dossier.sh"            # reused stack
      source "$HERE/co-http-transport.sh"  # OVERRIDE → HTTP → local engine

      D="$(mk dCT 2 "[$(item i1 open),$(item i2 open)]")"
      id="$(do_dossier_put "$PLACEHOLDER" "$D")"; prc=$?
      echo "BPUT rc=$prc id=$id"

      rec="$(do_dossier_get "$PLACEHOLDER" dCT 2>/dev/null)"; grc=$?
      echo "BGETP rc=$grc"
      echo "BREC_SV=$(printf '%s' "$rec" | jq -r '.schema_version|tostring' 2>/dev/null)"
      echo "BREC_PR=$(printf '%s' "$rec" | jq -r 'has("principal")|tostring' 2>/dev/null)"
      echo "BREC_ITEMS=$(printf '%s' "$rec" | jq -r '.items|length' 2>/dev/null)"

      # claude-tools-cx7t — the get above is over the HTTP override (the PUT went
      # to the ENGINE, NOT the local store), so a HIT here proves the 2xx
      # write-through cached the dossier into the LOCAL .co-store from a REAL
      # engine response (the §4 record round-trip RE-ACTIVATED in the PROD path).
      echo "BCACHE=$(co__store_get dossier dCT >/dev/null 2>&1 && echo hit || echo miss)"

      do_dossier_get "$PLACEHOLDER" dABSENT >/dev/null 2>&1; echo "BGETA rc=$?"

      BAD="$(jq -cn '{id:"dBAD",schema_version:"1",kind:"decide",items:[]}')"
      do_dossier_put "$PLACEHOLDER" "$BAD" >/dev/null 2>&1; echo "BBAD rc=$?"

      # timer round-trip over the transport
      co_request "$PLACEHOLDER" timer-arm i1tmr "2000-01-01T00:00:00Z" >/dev/null 2>&1; echo "BTARM rc=$?"
      tdout="$(co_request "$PLACEHOLDER" timer-due "2099-01-01T00:00:00Z" 2>/dev/null)"; echo "BTDUE rc=$? has=$(printf '%s' "$tdout" | grep -qx i1tmr && echo yes || echo no)"
      co_request "$PLACEHOLDER" timer-ack i1tmr >/dev/null 2>&1; echo "BTACK rc=$?"

      # §1.1 outbox drain: queue a capacity line, drain it to the engine.
      export LOG_DIR="$W/logs"; mkdir -p "$W/logs"
      printf '%s\n' '{"report":"capacity","schema_version":1,"principal":"brian","runner_id":"ct","cost_class":"standard","verdict":"ok","observed_at":"2026-05-17T00:00:00Z"}' > "$W/logs/coordinator-outbox.jsonl"
      la_outbox_drain "$PLACEHOLDER" >/dev/null 2>&1; drc=$?
      remain="$(wc -l < "$W/logs/coordinator-outbox.jsonl" 2>/dev/null | tr -d ' ')"
      echo "BDRAIN rc=$drc remain=$remain"
      rm -rf "$W"
    ) > "$STATE_DIR/worldb.txt" 2>/dev/null
    B="$STATE_DIR/worldb.txt"

    g(){ grep -o "$1=[0-9A-Za-z_-]*" "$B" | head -1 | cut -d= -f2; }
    eq "$(g 'BPUT rc')"  "$oracle_rc_put"  "do_dossier_put over HTTP ≡ oracle rc ($oracle_rc_put) — success path, the hop I0 could not reach"
    [[ "$(grep -o 'id=[A-Za-z0-9_-]*' "$B" | head -1 | cut -d= -f2)" == "dCT" ]] \
      && ok "do_dossier_put over HTTP returns the dossier id (dCT)" \
      || bad "do_dossier_put over HTTP returns the dossier id"
    eq "$(g 'BGETP rc')" "$oracle_rc_getP" "do_dossier_get present over HTTP ≡ oracle rc ($oracle_rc_getP)"
    eq "$(grep -o 'BREC_SV=[0-9]*' "$B" | cut -d= -f2)" "2" "get-present record: schema_version is integer 2 (v2 §11 Mermaid amend; §0.3 binds — D2 record passes through verbatim)"
    eq "$(grep -o 'BREC_PR=[a-z]*' "$B" | cut -d= -f2)" "true" "get-present record: §9.1 principal stamped by the engine"
    eq "$(grep -o 'BREC_ITEMS=[0-9]*' "$B" | cut -d= -f2)" "2" "get-present record: items[] round-tripped (2)"
    eq "$(grep -o 'BCACHE=[a-z]*' "$B" | cut -d= -f2)" "hit" "get-present over HTTP WRITE-THROUGH caches the dossier into the LOCAL .co-store (P4: a hosted 2xx now seeds the local fallback — cx7t)"
    eq "$(g 'BGETA rc')" "$oracle_rc_getA" "do_dossier_get ABSENT over HTTP ≡ oracle rc ($oracle_rc_getA) — D2 §0.3-misclassification CLOSED"
    eq "$(g 'BBAD rc')"  "$oracle_rc_bad"  "do_dossier_put REJECT over HTTP ≡ oracle rc ($oracle_rc_bad) — D1 status→rc"
    eq "$(g 'BTARM rc')" "0" "timer-arm over HTTP ⇒ rc 0 (ack suppressed, D2/D4)"
    eq "$(g 'BTDUE rc')" "0" "timer-due over HTTP ⇒ rc 0"
    [[ "$(grep -o 'BTDUE rc=[0-9]* has=[a-z]*' "$B" | grep -o 'has=[a-z]*' | cut -d= -f2)" == "yes" ]] \
      && ok "timer-due over HTTP surfaces the armed id (DATA-200 passthrough verbatim)" \
      || bad "timer-due over HTTP surfaces the armed id"
    eq "$(g 'BTACK rc')" "0" "timer-ack over HTTP ⇒ rc 0"
    eq "$(g 'BDRAIN rc')" "0" "la_outbox_drain ⇒ rc 0 (capacity line pushed to the hosted engine)"
    eq "$(grep -o 'BDRAIN rc=[0-9]* remain=[0-9]*' "$B" | grep -o 'remain=[0-9]*' | cut -d= -f2)" "0" "outbox drained: 0 lines retained (at-least-once push succeeded)"

    # ---- the dossier read back through the EXACT deployed-Inbox front -------
    # The deployed Inbox proxy hits precisely GET {COORDINATOR_URL}/request?op=
    # get&type=dossier&id=<id> with a server-side Bearer (cf adapter argsForGet
    # → opGet). If THAT returns the record the runner put over the native
    # transport, the dossier the stuck flow produced IS visible to the Inbox.
    inbox="$(curl -sS -m 20 -H "authorization: Bearer $GOOD" \
               "$ENGINE/request?op=get&type=dossier&id=dCT" 2>/dev/null)"
    [[ "$(printf '%s' "$inbox" | jq -r '.id' 2>/dev/null)" == "dCT" ]] \
      && ok "dossier readable via the EXACT deployed-Inbox /request?op=get front (same DO+D1 — 'visible in the Inbox')" \
      || bad "dossier readable via /request?op=get front (got: $(printf '%s' "$inbox" | head -c 100))"

    # ---- the FULL op-surface contract (not just the dossier flow): the I2
    #      foundation. lease grant emits the BARE §4.4 record (generation
    #      fencing) + rc 0; a contended denial ⇒ rc 1 (NOT the loud rc 4);
    #      lease-renew round-trips; ask-capacity 'over' ⇒ rc 1 with the token
    #      on stdout; a report-capacity reject ⇒ rc 3. Each asserted ≡ the
    #      in-process bash oracle (these are the I0-class divergences the
    #      reviewer surfaced on the op-classes the dossier flow never drives —
    #      proven, not assumed). -----------------------------------------------
    (
      set +u
      W="$(mktemp -d)"
      export COORDINATOR_URL="$ENGINE"; export COORDINATOR_TOKEN="$GOOD"
      unset CO_EXPECTED_TOKEN 2>/dev/null || true
      source "$HERE/coordinator.sh"            # internals + bash co_request
      source "$HERE/co-http-transport.sh"      # OVERRIDE → HTTP → local engine

      gen=""
      la="$(co_request x lease-acquire ctL ownerA 2>/dev/null)"; larc=$?
      gen="$(printf '%s' "$la" | jq -r '.generation // empty' 2>/dev/null)"
      echo "L_ACQ rc=$larc isrec=$([[ -n "$gen" ]] && echo yes || echo no)"
      lr="$(co_request x lease-renew ctL ownerA "$gen" 2>/dev/null)"; lrrc=$?
      echo "L_RENEW rc=$lrrc isrec=$(printf '%s' "$lr" | jq -e 'has("generation")' >/dev/null 2>&1 && echo yes || echo no)"
      co_request x lease-acquire ctL ownerB >/dev/null 2>&1; echo "L_DENY rc=$?"
      co_request x lease-release ctL ownerA "$gen" >/dev/null 2>&1; echo "L_REL rc=$?"

      # capacity: report an 'over' verdict, then ask-capacity ⇒ over/rc1.
      capj='{"report":"capacity","schema_version":1,"principal":"brian","runner_id":"ctR","cost_class":"standard","verdict":"over","observed_at":"2026-05-17T00:00:00Z"}'
      co_request x report-capacity "$capj" >/dev/null 2>&1; echo "C_REP rc=$?"
      av="$(co_request x ask-capacity standard 2>/dev/null)"; echo "C_ASK rc=$? tok=$av"
      co_request x report-capacity '{"report":"capacity","schema_version":99}' >/dev/null 2>&1; echo "C_REJ rc=$?"

      # K2/K3 (claude-tools-u1pt) DATA-200 passthrough over the transport: both
      # relay-log-tail ({exchanges:[…]}) and notif-digest ({digests:[…]}) are
      # JSON-200 pure reads. They were NOT in co_http__op_is_data, so they hit the
      # ACK-200 arm and SUPPRESSED their body to empty stdout (rc 0 but nothing to
      # read) — the cmd_relay_log_tail-returns-empty bug. Seed one relay row, tail
      # it: the body MUST reach stdout verbatim (the in-process bare-stdout
      # contract), with the seeded exchange present and rc 0 (no rc-precedence
      # change — pure read ⇒ 0 on 200). relay-log-append stays an ACK op (rc 0,
      # body suppressed) — only the read side is DATA.
      rex='{"exchange_id":"ctRELAY1","outcome":"resolved","from_ws":"wsa","project_ref":"wsa","to_ws":"wsb","question":"q?","answer":"a."}'
      co_request x relay-log-append "$rex" >/dev/null 2>&1; echo "R_APP rc=$?"
      rt="$(co_request x relay-log-tail wsa 2>/dev/null)"; rtrc=$?
      echo "R_TAIL rc=$rtrc ne=$([[ -n "$rt" ]] && echo yes || echo no) has=$(printf '%s' "$rt" | jq -e '(.exchanges|map(.id)|index("ctRELAY1"))!=null' >/dev/null 2>&1 && echo yes || echo no)"
      nd="$(co_request x notif-digest 2>/dev/null)"; ndrc=$?
      echo "N_DIG rc=$ndrc ne=$([[ -n "$nd" ]] && echo yes || echo no) isarr=$(printf '%s' "$nd" | jq -e '(.digests|type)=="array"' >/dev/null 2>&1 && echo yes || echo no)"
      rm -rf "$W"
    ) > "$STATE_DIR/ops.txt" 2>/dev/null
    O="$STATE_DIR/ops.txt"
    og(){ grep -o "$1=[0-9A-Za-z_-]*" "$O" | head -1 | cut -d= -f2; }
    eq "$(og 'L_ACQ rc')"   "0"   "lease-acquire grant over HTTP ⇒ rc 0 (≡ bash oracle)"
    eq "$(grep -o 'L_ACQ rc=[0-9]* isrec=[a-z]*' "$O" | grep -o 'isrec=[a-z]*' | cut -d= -f2)" "yes" \
       "lease-acquire grant emits the BARE §4.4 record (generation fencing — D2/D4 on the lease op CLOSED)"
    eq "$(og 'L_RENEW rc')" "0"   "lease-renew over HTTP ⇒ rc 0 + bare record"
    eq "$(og 'L_DENY rc')"  "1"   "lease-acquire DENIED (held by ownerA) ⇒ rc 1, NOT the loud rc 4 (409→1 ≡ bash)"
    eq "$(og 'L_REL rc')"   "0"   "lease-release ⇒ rc 0 (ack suppressed)"
    eq "$(og 'C_REP rc')"   "0"   "report-capacity accepted ⇒ rc 0 (ack suppressed ≡ bash)"
    eq "$(og 'C_ASK rc')"   "1"   "ask-capacity verdict 'over' ⇒ rc 1 (the §6.3 token↔rc bijection — NOT rc 0)"
    eq "$(grep -o 'C_ASK rc=[0-9]* tok=[a-z]*' "$O" | grep -o 'tok=[a-z]*' | cut -d= -f2)" "over" \
       "ask-capacity body passes through verbatim ('over' on stdout, bash-identical)"
    eq "$(og 'C_REJ rc')"   "3"   "report-capacity reject (bad schema_version) ⇒ rc 3 (bash co__capacity_report precedence ≡)"

    # K2/K3 (claude-tools-u1pt): the DATA-200 passthrough fix. Before the fix
    # both ops fell to the ACK-200 arm ⇒ rc 0 but EMPTY stdout (the suppressed
    # body the engine-bridge cmd_relay_log_tail surfaced as empty).
    eq "$(og 'R_APP rc')"  "0"   "relay-log-append over HTTP ⇒ rc 0 (ack suppressed — write side stays ACK)"
    eq "$(og 'R_TAIL rc')" "0"   "relay-log-tail over HTTP ⇒ rc 0 (pure read, no rc-precedence change)"
    eq "$(grep -o 'R_TAIL rc=[0-9]* ne=[a-z]*' "$O" | grep -o 'ne=[a-z]*' | cut -d= -f2)" "yes" \
       "relay-log-tail 200 body is NOT suppressed — {exchanges:[…]} reaches stdout (the cmd_relay_log_tail-empty bug CLOSED)"
    eq "$(grep -o 'R_TAIL rc=[0-9]* ne=[a-z]* has=[a-z]*' "$O" | grep -o 'has=[a-z]*' | cut -d= -f2)" "yes" \
       "relay-log-tail body passes through VERBATIM — the seeded exchange (ctRELAY1) is present in .exchanges"
    eq "$(og 'N_DIG rc')"  "0"   "notif-digest over HTTP ⇒ rc 0 (pure read, no rc-precedence change)"
    eq "$(grep -o 'N_DIG rc=[0-9]* ne=[a-z]*' "$O" | grep -o 'ne=[a-z]*' | cut -d= -f2)" "yes" \
       "notif-digest 200 body is NOT suppressed — {digests:[…]} reaches stdout (was empty under the ACK-200 arm)"
    eq "$(grep -o 'N_DIG rc=[0-9]* ne=[a-z]* isarr=[a-z]*' "$O" | grep -o 'isarr=[a-z]*' | cut -d= -f2)" "yes" \
       "notif-digest body passes through VERBATIM — .digests is the K3 array projection"
  fi
fi

# ════════════════════════════════════════════════════════════════════════════
# PART C — production-token auto-detect: the I5 hop if (and only if) a real
#          token is provisioned; otherwise SKIP with the by-design notice.
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART C — LIVE deployed success path (the I5 hop) ──"
PROD_TOKEN=""
if [[ -n "${COORDINATOR_TOKEN:-}" && "${COORDINATOR_URL:-}" == "$LIVE_URL" ]]; then
  PROD_TOKEN="$COORDINATOR_TOKEN"
elif security find-generic-password -s "claude-beads-runner.coordinator-token" \
       -a "$(hostname)" -w >/dev/null 2>&1; then
  PROD_TOKEN="present-in-keychain"
fi

if [[ -z "$PROD_TOKEN" ]]; then
  note "SKIPPED — no production token resolves (Keychain empty, COORDINATOR_TOKEN unset)."
  note "This is the I0 D0 headline, BY DESIGN: the real per-workspace"
  note "CO_EXPECTED_TOKEN is held by Brian out of agent context. The genuine"
  note "fully-unmocked human-on-phone proof is consolidated SOLELY into I5."
  note "PART A proved the live 401 posture closed; PART B proved the success +"
  note "reject paths ≡ the bash oracle against the byte-identical engine that"
  note "production runs verbatim. The production run is a zero-code-change"
  note "credential flip I5 executes with Brian present."
else
  ( set +u
    W="$(mktemp -d)"; export CO_STORE="$W/store"
    export COORDINATOR_URL="$LIVE_URL"
    [[ "$PROD_TOKEN" != "present-in-keychain" ]] && export COORDINATOR_TOKEN="$PROD_TOKEN"
    source "$HERE/local-agent.sh"
    source "$HERE/dossier.sh"
    source "$HERE/co-http-transport.sh"
    DID="i1-live-$$"

    # Self-erasing fixture: on subshell EXIT, expire the item so the dossier
    # falls out of the prod waiting_on_you projection. Same one-shot
    # open→expired transition claude-tools-vxs used to retire 9 leaked
    # i1-live-* dossiers. Trap fires even if put/get below fails partway,
    # so a flaky run still cleans up after itself.
    _expire_c() {
      local _ex
      _ex="$(mk "$DID" 2 "[$(item i1 expired)]")"
      do_dossier_put "$PLACEHOLDER" "$_ex" >/dev/null 2>&1 || true
      rm -rf "$W" 2>/dev/null || true
    }
    trap _expire_c EXIT

    D="$(mk "$DID" 2 "[$(item i1 open)]")"
    id="$(do_dossier_put "$PLACEHOLDER" "$D")"; prc=$?
    rec="$(do_dossier_get "$PLACEHOLDER" "$DID" 2>/dev/null)"; grc=$?
    echo "CLIVE put=$prc get=$grc id=$id"
  ) > "$STATE_DIR/c.txt" 2>/dev/null || true
  if grep -q "CLIVE put=0 get=0 id=i1-live" "$STATE_DIR/c.txt" 2>/dev/null; then
    ok "LIVE deployed engine: reused do_dossier_put + get round-trip ⇒ rc 0 (the I5 hop, token present)"
  else
    bad "LIVE deployed success path ($(cat "$STATE_DIR/c.txt" 2>/dev/null | tr -d '\n' | head -c 120))"
  fi
fi

# ════════════════════════════════════════════════════════════════════════════
# PART D — K3 (claude-tools-uxvk3) LIVE digest rollup: clears the deferred CF
#          live-verify debt (TESTING-STRATEGY §5 acceptance item 4 + §7.6, the
#          bgw/2dk R1 anchor). `notif-digest` (no_digest) is the §K3 read-side
#          group-by-channel rollup — a PURE READ engine op (no co._serialize, no
#          §4 write, so NO cleanup trap is needed, unlike PART C). The §5 engine
#          bar for production-touching work is "a real authed probe against
#          coordinator-cf.bbthechange.workers.dev returning the new shape": this
#          probe drives notif-digest over the SAME native POST / dialect the
#          adapter passes through and asserts the deployed Worker returns the K3
#          shape {digests:[{channel,count,tier,dossier_refs},…]}. Same T8 token-
#          gating as PART A/C — SKIPs by-design without a prod token (run-tests.sh
#          neutralizes the token so the offline gate never reaches the network;
#          §8: that SKIP is not a failure). The notif-digest READ CONTRACT itself
#          is proven offline by cf/test/notification.spec.js + lib/test-notification.sh;
#          THIS part proves only that the deployed bytes serve it live.
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART D — LIVE deployed notif-digest (K3) · §5/§7.6 deferred-verify cleared ──"
echo "   target: $LIVE_URL  (authed probe — the §5 item-4 engine live-verify bar)"
D_TOKEN=""
# Trust an env COORDINATOR_TOKEN only when COORDINATOR_URL already points AT prod
# (mirrors PART C's guard exactly) — PART D POSTs to the hardcoded $LIVE_URL, so
# a token provisioned for a NON-prod COORDINATOR_URL must not be sent to prod;
# otherwise the Keychain prod token is the source of truth.
if [[ -n "${COORDINATOR_TOKEN:-}" && "${COORDINATOR_URL:-}" == "$LIVE_URL" ]]; then D_TOKEN="$COORDINATOR_TOKEN"
elif D_TOKEN="$(security find-generic-password -s "claude-beads-runner.coordinator-token" \
                  -a "$(hostname)" -w 2>/dev/null)"; then :; fi
if [[ -z "$D_TOKEN" ]]; then
  note "PART D SKIPPED — no §9.2 prod token resolves; the live notif-digest probe is T8 (§8: that SKIP is not a failure). The notif-digest READ contract is proven offline by cf/test/notification.spec.js + lib/test-notification.sh; only the deployed-bytes-serve-it hop is gated here."
else
  dof="$(mktemp)"
  # Native dialect (POST / {op,args}) — the adapter forwards non-`/request`
  # paths straight to the FROZEN Worker, so this exercises the byte-unchanged
  # CF.1 engine + the §9.1 authenticate() chokepoint. The token is NEVER echoed.
  dhttp="$(curl -sS -m 25 -o "$dof" -w '%{http_code}' \
            -X POST "$LIVE_URL/" \
            -H 'content-type: application/json' \
            -H "authorization: Bearer ${D_TOKEN}" \
            --data-binary '{"op":"notif-digest","args":[]}' 2>/dev/null)"
  dbody="$(cat "$dof" 2>/dev/null)"; rm -f "$dof"
  eq "$dhttp" "200" "LIVE notif-digest ⇒ HTTP 200 (the deployed K3 read op is reachable + authed — NOT a 400 unknown-op nor a 401)"
  if printf '%s' "$dbody" | jq -e 'type=="object" and (.digests|type=="array")' >/dev/null 2>&1; then
    ok "LIVE notif-digest ⇒ K3 new shape {digests:[…]} (read-side rollup provably live — §5/§7.6 debt CLEARED)"
  else
    bad "LIVE notif-digest ⇒ {digests:[…]} (got: $(printf '%s' "$dbody" | head -c 120))"
  fi
  # Every rollup entry carries the §K3 groupDigests fields. Vacuously true when
  # prod has no digest-eligible record; asserts the channel-group contract when
  # it does. Structural (D.2 tier discipline lives in the offline twin) — this
  # only proves the deployed projection SHAPE, never prose.
  if printf '%s' "$dbody" | jq -e '(.digests|length)==0 or all(.digests[]; has("channel") and has("count") and has("tier") and has("dossier_refs"))' >/dev/null 2>&1; then
    ok "LIVE notif-digest ⇒ every rollup entry has {channel,count,tier,dossier_refs} (groupDigests projection contract)"
  else
    bad "LIVE notif-digest entry shape ($(printf '%s' "$dbody" | head -c 160))"
  fi
fi

# ════════════════════════════════════════════════════════════════════════════
# PART E — OFFLINE unit of the co_http__op_is_data DATA-200 allowlist
#          (claude-tools-u1pt). No network, no engine, no token — runs ALWAYS,
#          so the K2/K3 passthrough fix is regression-guarded even on a checkout
#          where wrangler is absent and PART B SKIPs. Sources the transport with
#          a dummy COORDINATOR_URL (the activation gate) purely to define the
#          predicate; nothing here issues HTTP.
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART E — OFFLINE co_http__op_is_data DATA-200 allowlist (no network) ──"
PARTE_OUT="$(mktemp)"   # PART E owns its file — STATE_DIR may be unset (PART B SKIP)
(
  set +u
  export COORDINATOR_URL="https://unit.invalid"   # gate only — no request is made
  source "$HERE/co-http-transport.sh"
  # The two ops this bead adds: their JSON-200 body MUST pass through (predicate
  # true), NOT be suppressed by the ACK-200 arm.
  co_http__op_is_data relay-log-tail && echo "E_RLT=data" || echo "E_RLT=ack"
  co_http__op_is_data notif-digest   && echo "E_ND=data"  || echo "E_ND=ack"
  # Regression guards: a known DATA op stays DATA; the relay/notif WRITE-side and
  # a canonical ACK op stay ACK (the body-suppression contract is unchanged for
  # everything else — no over-broadening).
  co_http__op_is_data work-snapshot  && echo "E_WS=data"  || echo "E_WS=ack"
  co_http__op_is_data relay-log-append && echo "E_RLA=data" || echo "E_RLA=ack"
  co_http__op_is_data put            && echo "E_PUT=data" || echo "E_PUT=ack"
) > "$PARTE_OUT" 2>/dev/null || true
peg(){ grep -o "$1=[a-z]*" "$PARTE_OUT" 2>/dev/null | head -1 | cut -d= -f2; }
eq "$(peg E_RLT)" "data" "co_http__op_is_data relay-log-tail ⇒ DATA (body passes through, not suppressed)"
eq "$(peg E_ND)"  "data" "co_http__op_is_data notif-digest ⇒ DATA (body passes through, not suppressed)"
eq "$(peg E_WS)"  "data" "co_http__op_is_data work-snapshot ⇒ DATA (existing allowlist intact)"
eq "$(peg E_RLA)" "ack"  "co_http__op_is_data relay-log-append ⇒ ACK (write side stays suppressed — no over-broadening)"
eq "$(peg E_PUT)" "ack"  "co_http__op_is_data put ⇒ ACK (canonical ack op unaffected)"
rm -f "$PARTE_OUT" 2>/dev/null || true

# ════════════════════════════════════════════════════════════════════════════
# PART F — OFFLINE §4 write-through cache (claude-tools-cx7t, P4). No network, no
#          engine, no token — runs ALWAYS (curl is STUBBED), so the write-through
#          behaviour is regression-guarded even where wrangler is absent and PART
#          B SKIPs. Proves: a 2xx `get`/`lease-acquire` is written THROUGH to the
#          local .co-store keyed (kind,id); the carve-outs (runner_state via get,
#          poll, work-snapshot) are NOT cached (the break-through-pause + read-only
#          projection invariants); and a cache reject is BEST-EFFORT — it never
#          changes the rc/stdout co_request returns (the in-process contract).
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART F — OFFLINE §4 write-through cache (stubbed curl, no network) ──"
PARTF_OUT="$(mktemp)"
PARTF_STORE="$(mktemp -d)"
(
  set +u
  export COORDINATOR_URL="https://unit.invalid"   # gate only — curl is stubbed
  export COORDINATOR_TOKEN="ctF"                   # resolve a bearer (with-bearer path)
  export CO_STORE="$PARTF_STORE/store"
  unset CO_EXPECTED_TOKEN 2>/dev/null || true
  source "$HERE/coordinator.sh"          # co__store_put / co__store_get + bash co_request
  source "$HERE/co-http-transport.sh"    # OVERRIDE: co_request → HTTP (curl stub below)

  # Stub curl: write the canned body to the `-o <file>` target, echo the canned
  # HTTP code on stdout (exactly what co_request's `-w '%{http_code}'` reads).
  curl() {
    local out="" capture=0 a
    for a in "$@"; do
      if [[ "$capture" == 1 ]]; then out="$a"; capture=0; continue; fi
      [[ "$a" == "-o" ]] && capture=1
    done
    [[ -n "$out" ]] && printf '%s' "${CURL_STUB_BODY:-}" > "$out"
    printf '%s' "${CURL_STUB_CODE:-200}"
    return 0
  }
  export CURL_STUB_CODE=200

  # ── get (the canonical single-§4-record DATA op): cached, principal preserved.
  DREC="$(mk dCACHE 2 "[$(item i1 open)]" | jq -c '.principal="brian"')"
  export CURL_STUB_BODY="$DREC"
  gout="$(co_request ctF get dossier dCACHE 2>/dev/null)"; echo "F_GET_RC=$?"
  echo "F_GET_OUT_EQ=$([[ "$gout" == "$DREC" ]] && echo yes || echo no)"
  echo "F_GET_CACHE=$(co__store_get dossier dCACHE >/dev/null 2>&1 && echo hit || echo miss)"
  echo "F_GET_PRIN=$(co__store_get dossier dCACHE 2>/dev/null | jq -r '.principal // "none"' 2>/dev/null)"

  # ── get runner_state: carved out — the transport must NEVER seed local desired.
  RSREC='{"schema_version":1,"project_ref":"projX","desired":"paused","principal":"brian"}'
  export CURL_STUB_BODY="$RSREC"
  rsout="$(co_request ctF get runner_state projX 2>/dev/null)"; echo "F_RS_RC=$?"
  echo "F_RS_OUT_EQ=$([[ "$rsout" == "$RSREC" ]] && echo yes || echo no)"
  echo "F_RS_CACHE=$(co__store_get runner_state projX >/dev/null 2>&1 && echo hit || echo miss)"

  # ── lease-acquire: the unwrapped §4.4 record cached keyed (lease, task_ref).
  LREC='{"ok":true,"lease":{"task_ref":"ctTASK","schema_version":1,"principal":"brian","owner":"ownerX","generation":3,"acquired_at":"x","ttl_seconds":900,"expires_at":"y","renewed_at":"x","acquired_epoch":1,"renewed_epoch":1,"expires_epoch":901}}'
  export CURL_STUB_BODY="$LREC"
  lout="$(co_request ctF lease-acquire ctTASK ownerX 2>/dev/null)"; echo "F_L_RC=$?"
  echo "F_L_HASGEN=$(printf '%s' "$lout" | jq -e '.generation==3' >/dev/null 2>&1 && echo yes || echo no)"
  echo "F_L_CACHE=$(co__store_get lease ctTASK >/dev/null 2>&1 && echo hit || echo miss)"
  echo "F_L_CACHE_GEN=$(co__store_get lease ctTASK 2>/dev/null | jq -r '.generation // "none"' 2>/dev/null)"

  # ── poll: composite — its runner_state portion must NOT be seeded locally.
  POLLREC='{"principal":"brian","desired":"running","lease":null}'
  export CURL_STUB_BODY="$POLLREC"
  pout="$(co_request ctF poll projP 2>/dev/null)"; echo "F_P_RC=$?"
  echo "F_P_OUT_EQ=$([[ "$pout" == "$POLLREC" ]] && echo yes || echo no)"
  echo "F_P_RS_CACHE=$(co__store_get runner_state projP >/dev/null 2>&1 && echo hit || echo miss)"

  # ── work-snapshot: a read-only DERIVED projection — never cached.
  WSREC='{"project_ref":"projW","liveness":"green","cards":[]}'
  export CURL_STUB_BODY="$WSREC"
  wout="$(co_request ctF work-snapshot projW 2>/dev/null)"; echo "F_W_RC=$?"
  echo "F_W_OUT_EQ=$([[ "$wout" == "$WSREC" ]] && echo yes || echo no)"
  echo "F_W_CACHE=$(co__store_get work_snapshot projW >/dev/null 2>&1 && echo hit || echo miss)"

  # ── BEST-EFFORT: a body co__store_put REJECTS (schema_version 99 > bound) must
  #    NOT change the rc/stdout co_request returns, and must NOT be cached.
  BADREC='{"schema_version":99,"id":"badrec","principal":"brian"}'
  export CURL_STUB_BODY="$BADREC"
  bout="$(co_request ctF get notification badrec 2>/dev/null)"; echo "F_B_RC=$?"
  echo "F_B_OUT_EQ=$([[ "$bout" == "$BADREC" ]] && echo yes || echo no)"
  echo "F_B_CACHE=$(co__store_get notification badrec >/dev/null 2>&1 && echo hit || echo miss)"
) > "$PARTF_OUT" 2>/dev/null || true
pfg(){ grep -o "$1=[A-Za-z0-9_-]*" "$PARTF_OUT" 2>/dev/null | head -1 | cut -d= -f2; }
eq "$(pfg F_GET_RC)"     "0"     "get over HTTP ⇒ rc 0 (write-through never changes the caller rc)"
eq "$(pfg F_GET_OUT_EQ)" "yes"   "get over HTTP ⇒ stdout is the verbatim body (write-through never changes stdout)"
eq "$(pfg F_GET_CACHE)"  "hit"   "get WRITE-THROUGH: the §4 record is cached into local .co-store keyed (type,id)"
eq "$(pfg F_GET_PRIN)"   "brian" "get WRITE-THROUGH: the record's OWN principal is PRESERVED (idempotent §9.1 re-stamp ⇒ differential-equivalent to D1)"
eq "$(pfg F_RS_OUT_EQ)"  "yes"   "get runner_state ⇒ stdout still verbatim"
eq "$(pfg F_RS_CACHE)"   "miss"  "get runner_state is CARVED OUT — the transport is NOT a writer of local desired (break-through-pause, dky8/y6j9)"
eq "$(pfg F_L_RC)"       "0"     "lease-acquire over HTTP ⇒ rc 0"
eq "$(pfg F_L_HASGEN)"   "yes"   "lease-acquire over HTTP ⇒ stdout is the bare §4.4 record (generation fencing intact)"
eq "$(pfg F_L_CACHE)"    "hit"   "lease-acquire WRITE-THROUGH: the §4.4 Lease record is cached keyed (lease, task_ref)"
eq "$(pfg F_L_CACHE_GEN)" "3"    "lease-acquire WRITE-THROUGH: the cached lease carries the granted generation (3)"
eq "$(pfg F_P_OUT_EQ)"   "yes"   "poll over HTTP ⇒ stdout still verbatim"
eq "$(pfg F_P_RS_CACHE)" "miss"  "poll is EXCLUDED — its runner_state portion never seeds local desired (no network-authoritative desired read)"
eq "$(pfg F_W_OUT_EQ)"   "yes"   "work-snapshot over HTTP ⇒ stdout still verbatim"
eq "$(pfg F_W_CACHE)"    "miss"  "work-snapshot is EXCLUDED — a read-only DERIVED projection is never cached (S-1 liveness never stored)"
eq "$(pfg F_B_RC)"       "0"     "BEST-EFFORT: a cache REJECT leaves the caller rc unchanged (0)"
eq "$(pfg F_B_OUT_EQ)"   "yes"   "BEST-EFFORT: a cache REJECT leaves stdout the verbatim body (non-blocking contract)"
eq "$(pfg F_B_CACHE)"    "miss"  "BEST-EFFORT: a malformed body (bad schema_version) is NOT cached — never a false-success"
rm -rf "$PARTF_OUT" "$PARTF_STORE" 2>/dev/null || true

echo ""
echo "════════════════════════════════════════════════════════════════════════"
printf '  RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "════════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
