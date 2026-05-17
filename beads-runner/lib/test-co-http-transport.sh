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
      body:{ dossier_schema_version:1, tldr:"opaque to substrate",
             sections:[], diagrams:[], full_detail:"I1 transport proof" },
      items:$items }'; }
item() { jq -cn --arg i "$1" --arg s "$2" '
    { id:$i, kind:"approve-reject", framing:{}, context_anchor:{where:"x",expansion:"y"},
      consequence_block:{cb_schema_version:1,creates:[],unblocks:[],labels:[],status_changes:[]},
      state:$s, response:null, consequence_applied:false, applied_at:null }'; }

# ════════════════════════════════════════════════════════════════════════════
# PART A — LIVE deployed coordinator-cf: the I0 divergences CLOSED, reachable
#          posture (401), driven through the REUSED do_dossier_get.
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART A — LIVE deployed coordinator-cf · I0 D0–D3 closed (401 posture) ──"
echo "   target: $LIVE_URL  (no real token — the by-design D0 withholding)"

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
      D="$(mk dCT 1 "[$(item i1 open)]")"
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

      D="$(mk dCT 1 "[$(item i1 open),$(item i2 open)]")"
      id="$(do_dossier_put "$PLACEHOLDER" "$D")"; prc=$?
      echo "BPUT rc=$prc id=$id"

      rec="$(do_dossier_get "$PLACEHOLDER" dCT 2>/dev/null)"; grc=$?
      echo "BGETP rc=$grc"
      echo "BREC_SV=$(printf '%s' "$rec" | jq -r '.schema_version|tostring' 2>/dev/null)"
      echo "BREC_PR=$(printf '%s' "$rec" | jq -r 'has("principal")|tostring' 2>/dev/null)"
      echo "BREC_ITEMS=$(printf '%s' "$rec" | jq -r '.items|length' 2>/dev/null)"

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
    eq "$(grep -o 'BREC_SV=[0-9]*' "$B" | cut -d= -f2)" "1" "get-present record: schema_version is integer 1 (§0.3 binds — D2 record passes through verbatim)"
    eq "$(grep -o 'BREC_PR=[a-z]*' "$B" | cut -d= -f2)" "true" "get-present record: §9.1 principal stamped by the engine"
    eq "$(grep -o 'BREC_ITEMS=[0-9]*' "$B" | cut -d= -f2)" "2" "get-present record: items[] round-tripped (2)"
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
    D="$(mk "$DID" 1 "[$(item i1 open)]")"
    id="$(do_dossier_put "$PLACEHOLDER" "$D")"; prc=$?
    rec="$(do_dossier_get "$PLACEHOLDER" "$DID" 2>/dev/null)"; grc=$?
    echo "CLIVE put=$prc get=$grc id=$id"
    rm -rf "$W"
  ) > "$STATE_DIR/c.txt" 2>/dev/null || true
  if grep -q "CLIVE put=0 get=0 id=i1-live" "$STATE_DIR/c.txt" 2>/dev/null; then
    ok "LIVE deployed engine: reused do_dossier_put + get round-trip ⇒ rc 0 (the I5 hop, token present)"
  else
    bad "LIVE deployed success path ($(cat "$STATE_DIR/c.txt" 2>/dev/null | tr -d '\n' | head -c 120))"
  fi
fi

echo ""
echo "════════════════════════════════════════════════════════════════════════"
printf '  RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "════════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
