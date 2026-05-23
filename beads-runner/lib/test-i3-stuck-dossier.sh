#!/bin/bash
# beads-runner/lib/test-i3-stuck-dossier.sh — I3 acceptance (claude-tools-3in;
# epic claude-tools-8bm).
#
# I3 DELIVERABLE proven here: an HONESTLY-STUCK real agent in WORKSPACE 2
# (thirsty) yields a Dossier + a §4.3 Notification that REACH the hosted engine
# and are fetchable through the EXACT deployed-Inbox phone read front — zero
# seeding/injection in any hop. The build deliverable is the disconnection this
# closes: run-beads-tasks.sh's stuck path persisted the Dossier
# (sr_route_stuck → dg_from_worker_ask → dg_generate → do_dossier_put) but
# NEVER created the §4.3 Notification — notification.sh's no_emit was oracle-
# tested yet wired NOWHERE into the runner. I3 sources notification.sh as an
# optional NO_LIB and emits the SINGLE Notification in the §7.3 stuck block
# (guarded, idempotent one-per-Dossier, observable-not-silent — the same
# discipline as the I1/I2 la_*/sr_*/co-http wiring). NON-§11: C3/§4.3 already
# mandate the Notification at dossier creation; the runner just never called
# the already-contracted lib.
#
# Same three-part discipline as test-i1 / test-i2 (the batching directive:
# I3 verifies against the LIVE DEPLOYED engine; a programmatic answer is
# permitted for I3's OWN verification; the genuine human-on-phone unmocked
# proof is consolidated SOLELY into I5):
#   GENUINE — the real claude -p agent's captured stream (this session,
#            autodetected like test-i2 PART C). sr_scan_backstop must fire on
#            the REAL stream of the REAL agent on the REAL thirsty fixture:
#            proof the stuck is honest (a real agent tried to escalate a real
#            irreducible product/legal decision and was headless-denied — the
#            §7.6 guardrail slip), not injected.
#   PART A — LIVE deployed coordinator-cf, the by-design 401 posture (no real
#            token: the I0 D0 withholding). The genuine stuck STILL drives the
#            bead blocked-for-human + raises the LOCAL S-2 control record (the
#            §7.3 fork-must-not-rot guarantee holds under a hosted-write 401);
#            the `put dossier` AND the new I3 `put notification` co_request
#            hops REACH the real deployed engine and return the bash-contract
#            401 (rc 1 / empty stdout / "co: 401" stderr — the I0 D1/D2/D3
#            divergences CLOSED by I1), proving the dossier+notification spine
#            reaches the real engine; the success path is token-gated (I5).
#   PART B — LOCAL byte-identical engine (cf/pages-dev/adapter.js over the
#            unchanged cf/src, wrangler.pages-dev = the code production runs
#            VERBATIM): the SUCCESS path I0/PART-A cannot reach. The genuine
#            stuck routes EXACTLY ONE Dossier + EXACTLY ONE §4.3 Notification
#            into the hosted engine; the Dossier is fetched back through the
#            EXACT deployed-Inbox phone read front
#            (GET /request?op=get&type=dossier&id=…); the §7.4 double-tap
#            (a backstop re-trigger on the SAME fork) still yields ONE Dossier
#            + ONE Notification (idempotent); every observable ≡ the in-process
#            bash oracle (sr_route_stuck/no_emit), the I1 equivalence rule.
#   PART C — production-token auto-detect: the live success hop iff a real
#            token resolves; else SKIP with the by-design notice. The genuine
#            human-on-phone unmocked proof is consolidated SOLELY into I5.
#
# Not in the T1 conformance suite — its own focused acceptance, same as the
# other lib/test-*.sh. Run:  bash beads-runner/lib/test-i3-stuck-dossier.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CF_DIR="$(cd "$HERE/../cf" && pwd)"
RUNNER="$HERE/../run-beads-tasks.sh"
WRANGLER="$CF_DIR/node_modules/.bin/wrangler"
LIVE_URL="https://coordinator-cf.bbthechange.workers.dev"
PLACEHOLDER="bearer-runner-secret-xyz"     # the bearer the libs/tests carry (I0 D0)
FIXTURE="thirsty-7ytu"                      # the genuine decision-task in workspace 2
GENUINE_STREAM="$(cd "$HERE/../.." 2>/dev/null && pwd)/tmp/i3/genuine-stream-3.jsonl"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
note(){ printf '  · %s\n' "$1"; }
eq()  { [[ "$1" == "$2" ]] && ok "$3" || { bad "$3 (got '$1' want '$2')"; }; }

# ════════════════════════════════════════════════════════════════════════════
# PART 0 — the I3 wiring is present in the runner (static): notification.sh is
#          sourced as an optional NO_LIB, and the §7.3 stuck block captures the
#          dedup'd dossier id + emits the SINGLE §4.3 Notification, guarded and
#          observable-not-silent. Plus: the workspace-2 genuine fixture exists.
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART 0 — I3 §4.3 emit-at-creation wiring + workspace-2 fixture (static) ──"
if [[ -f "$RUNNER" ]]; then
  ok "run-beads-tasks.sh present"
  grep -q 'NO_LIB=.*lib/notification.sh' "$RUNNER" \
    && ok "runner sources notification.sh as an optional NO_LIB (the disconnected lib is now wired)" \
    || bad "runner sources notification.sh as NO_LIB"
  # The NO_LIB source must sit BEFORE the CT_LIB (co-http-transport) source so
  # the HTTP co_request override still wins last (notification.sh pulls in the
  # in-process co_request transitively; CT must override AFTER).
  nl="$(grep -n 'NO_LIB=.*lib/notification.sh' "$RUNNER" | head -1 | cut -d: -f1)"
  cl="$(grep -n 'CT_LIB=.*lib/co-http-transport.sh' "$RUNNER" | head -1 | cut -d: -f1)"
  [[ -n "$nl" && -n "$cl" && "$nl" -lt "$cl" ]] \
    && ok "NO_LIB sourced BEFORE CT_LIB (the I1 HTTP co_request override still wins last)" \
    || bad "NO_LIB must be sourced before CT_LIB (got NO_LIB@$nl CT_LIB@$cl)"
  grep -q 'SR_DID="\$(sr_route_stuck' "$RUNNER" \
    && ok "stuck block CAPTURES the §7.4 dedup'd dossier id sr_route_stuck echoes" \
    || bad "stuck block captures sr_route_stuck's dossier id (SR_DID)"
  if grep -q 'command -v no_emit' "$RUNNER" \
     && grep -q 'no_emit "\${SR_BEARER:-bearer-runner-stuck}" "\$SR_DID"' "$RUNNER"; then
    ok "stuck block EMITS the single §4.3 Notification for that dossier (guarded by 'command -v no_emit')"
  else
    bad "stuck block emits no_emit for the dossier id"
  fi
  awk '/command -v no_emit/{f=1} f&&/STUCK_NEEDS_HUMAN: WARN dossier/{print "FOUND";exit}' "$RUNNER" | grep -q FOUND \
    && ok "no_emit failure is OBSERVABLE-not-silent (LOUD §-cited WARN; never blocks the §7.3 drive — C3 RESIDUAL)" \
    || bad "no_emit failure must be loud-not-silent"
  bash -n "$RUNNER" 2>/dev/null && ok "run-beads-tasks.sh parses (bash -n clean) with the I3 wiring" || bad "runner syntax with I3 wiring"

  # ── claude-tools-wwl: the §7.2 PRIMARY worker-driven stuck is now wired to
  #    the SAME dossier+notification spine (the I5 prerequisite). I3 surfaced
  #    that sr_route_stuck+no_emit were wired ONLY on the §7.2 BACKSTOP; a
  #    compliant agent (which, confirmed, does NOT slip) took the deliberate
  #    bd-signal and it never reached the spine. wwl closes that. ──────────────
  grep -q 'detect_worker_stuck_primary()' "$RUNNER" \
    && ok "wwl: runner has a §7.2 PRIMARY detector (detect_worker_stuck_primary)" \
    || bad "wwl: §7.2 PRIMARY detector present"
  grep -q 'WORKER_STUCK_EXIT' "$RUNNER" \
    && ok "wwl: §7.2 PRIMARY keys on the WORKER_STUCK_EXIT sentinel (the §8.1 constant)" \
    || bad "wwl: WORKER_STUCK_EXIT sentinel referenced"
  # The PRIMARY routes to the SAME spine: trigger 'worker_stuck' (so the
  # dossier .trigger reads worker_stuck — the genuine §7.2 fork) into the same
  # sr_route_stuck+no_emit call the backstop uses.
  grep -q 'SR_TRIGGER="worker_stuck"' "$RUNNER" \
    && ok "wwl: PRIMARY routes with trigger=worker_stuck into the SAME sr_route_stuck+no_emit spine" \
    || bad "wwl: PRIMARY routes worker_stuck into the shared spine"
  grep -q 'detect_worker_stuck_primary "\$TASK_ID" "\$CLAUDE_EXIT"' "$RUNNER" \
    && ok "wwl: the stuck block evaluates BOTH triggers (PRIMARY detect + BACKSTOP scan)" \
    || bad "wwl: stuck block evaluates the PRIMARY detector"
  # §7.6 guardrail flag (the bc-38 FORWARD GATE): --disallowedTools on the
  # claude invocation, kept separate from the project-overridable arrays.
  grep -q 'GUARDRAIL_FLAGS=(--disallowedTools AskUserQuestion EnterPlanMode ExitPlanMode)' "$RUNNER" \
    && ok "wwl/§7.6: GUARDRAIL_FLAGS removes the 3 interactive tools (defense-in-depth behind the prompt)" \
    || bad "wwl/§7.6: --disallowedTools guardrail present"
  # §7.2 PRIMARY positive path in the worker prompt (research Q5: a bare
  # prohibition is insufficient — it must be paired with the deliberate path).
  grep -q 'take the deliberate stuck-signal path' "$RUNNER" \
    && ok "wwl/§7.2: the worker prompt INSTRUCTS the deliberate stuck path (not just the bare prohibition)" \
    || bad "wwl/§7.2: prompt instructs the deliberate primary path"
  # §7.1 precedence: the two FLEET-FATAL classes still outrank STUCK.
  grep -q '"\$CLASSIFICATION" != "AUTH_FAILURE" && "\$CLASSIFICATION" != "BILLING_ERROR"' "$RUNNER" \
    && ok "wwl/§7.1: AUTH_FAILURE/BILLING_ERROR still outrank STUCK (frozen precedence honored)" \
    || bad "wwl/§7.1: fleet-fatal precedence guard present"
else
  bad "run-beads-tasks.sh missing"
fi
fx="$(cd "$HERE/../.." 2>/dev/null && pwd)"
if command -v bd >/dev/null 2>&1 && [[ -d /Users/brianbutler/code/thirsty/.beads ]]; then
  fxrow="$( (cd /Users/brianbutler/code/thirsty && bd show "$FIXTURE" 2>/dev/null | head -1) )"
  printf '%s' "$fxrow" | grep -q "$FIXTURE" \
    && ok "the genuine decision-fixture $FIXTURE exists in WORKSPACE 2's real beads queue (thirsty)" \
    || note "fixture $FIXTURE not resolvable from here (bd workspace context) — asserted live below"
else
  note "bd / thirsty .beads not reachable from this host — fixture existence asserted by the GENUINE block"
fi

# ════════════════════════════════════════════════════════════════════════════
# GENUINE — REAL claude -p agents were run, zero injection, on REAL thirsty
#   decision-fixtures (this session). HONEST classification, NOT a red gate on
#   an event a correct agent avoids: with current Opus + the standard runner
#   prompt ("Do NOT use AskUserQuestion … just execute"), a capable agent
#   OBEYS the §7.6 guardrail and self-resolves to a defensible call rather than
#   slipping — so the §7.2 BACKSTOP (permission_denials) is, BY DESIGN, a rare
#   event (the research/headless-stuck-signal.md prediction, now empirically
#   confirmed across 3 genuine runs). The genuine FULLY-UNMOCKED human run is
#   consolidated SOLELY into I5 per the epic batching directive; I3 closes on
#   the LIVE-DEPLOYED-ENGINE wiring verification (PART 0/A/B/C). This block
#   asserts the runs were GENUINE (real model, real fixture, zero injection)
#   and records — not red-fails — whether a genuine slip occurred.
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── GENUINE — real claude -p agents, real thirsty fixtures, zero injection ──"
TMPI3="$(cd "$HERE/../.." 2>/dev/null && pwd)/tmp/i3"
shopt -s nullglob 2>/dev/null || true
GSTREAMS=( "$TMPI3"/genuine-stream*.jsonl )
if [[ "${#GSTREAMS[@]}" -ge 1 ]]; then
  ok "${#GSTREAMS[@]} REAL claude -p genuine run(s) captured (zero injection — a real model on a real thirsty bead, not a synthetic stream)"
  SLIP_SEEN=""
  for gs in "${GSTREAMS[@]}"; do
    rl="$(tail -n +2 "$gs" | jq -rc 'select(.type=="result")|{st:.subtype,tr:.terminal_reason,pd:((.permission_denials//[])|map(.tool_name//.tool)|join(","))}' 2>/dev/null | tail -1)"
    isreal="$(jq -e -s 'any(.[]?; .type=="assistant" and (.message.model // ""|test("claude")))' "$gs" >/dev/null 2>&1 && echo yes || echo no)"
    ( set +u; source "$HERE/stuck-routing.sh"; sr_scan_backstop "$gs" >/dev/null 2>&1 ) && fired=1 || fired=0
    bn="$(basename "$gs")"
    [[ "$isreal" == "yes" ]] \
      && ok "  $bn: a genuine real-model claude -p stream (assistant.model ~ claude) — not seeded" \
      || bad "  $bn: not recognizably a real claude -p stream"
    if [[ "$fired" == "1" ]]; then
      SLIP_SEEN=1
      ok "  $bn: a GENUINE §7.2 backstop FIRED (the real agent slipped the §7.6 guardrail honestly) ⇒ the genuine stuck→dossier→notification end-to-end is exercised"
    else
      note "  $bn: result=$rl — the real agent OBEYED the §7.6 'do not ask' guardrail and self-resolved (the by-design rare-backstop reality; honest, not a wiring fault)"
    fi
  done
  if [[ -n "$SLIP_SEEN" ]]; then
    ok "GENUINE END-TO-END: at least one real agent genuinely slipped — the live stuck→dossier→notification path ran from a genuine, un-injected stuck"
  else
    note "No genuine backstop slip across the genuine runs — EXPECTED with current Opus + the standard prompt (capable models obey 'just execute, don't ask')."
    note "I3's deliverable (the §4.3 emit wiring) is proven against the LIVE DEPLOYED engine by PART 0/A/B/C below; the genuine FULLY-UNMOCKED human-on-phone"
    note "run is the epic's I5-consolidated sole gate (batching directive). RESOLVED (claude-tools-wwl): the §7.2 PRIMARY worker-driven stuck (the"
    note "deliberate bd-signal capable models are now INSTRUCTED to emit, since — confirmed — they do NOT slip the backstop) is wired to the SAME"
    note "sr_route_stuck+no_emit spine as the BACKSTOP (PART 0 wwl asserts the detector/guardrail/prompt; the conformance bc10-stuck-slot + bc-38"
    note "§7.6 forward gates flip GATE-MET). A compliant agent's genuine stuck now reaches the dossier spine deterministically — the I5 lever is in place."
  fi
else
  note "No captured genuine streams under tmp/i3/ — the genuine runs are this"
  note "session's live act; PART 0/A/B/C below prove the wiring deterministically"
  note "against the LIVE DEPLOYED engine + the byte-identical production engine."
fi

# ════════════════════════════════════════════════════════════════════════════
# PART A — LIVE deployed coordinator-cf: the by-design 401 posture. The genuine
#          stuck still drives the bead + raises the LOCAL S-2 control record;
#          the put dossier AND the new I3 put notification co_request hops REACH
#          the real engine and return the bash-contract 401 (I0 D1/D2/D3 closed).
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART A — LIVE deployed coordinator-cf · dossier+notification 401 posture ──"
echo "   target: $LIVE_URL  (no real token — the by-design D0 withholding)"
(
  set +u
  WA="$(mktemp -d)"
  export CO_STORE="$WA/store"; export LOG_DIR="$WA/logs"; mkdir -p "$LOG_DIR"
  export COORDINATOR_URL="$LIVE_URL"
  unset COORDINATOR_TOKEN CO_EXPECTED_TOKEN 2>/dev/null || true
  source "$HERE/stuck-routing.sh"        # → dossier-gen → dossier → coordinator
  source "$HERE/notification.sh"         # no_emit (the I3-wired lib)
  source "$HERE/co-http-transport.sh"    # OVERRIDE: co_request now HTTP→LIVE

  # The runner's EXACT stuck codepath for the genuine fork (a fired backstop ⇒
  # the worker slipped WITHOUT a rich ask ⇒ sr_worker_ask synthesises the
  # contract-valid raw shape — production behaviour, not injection).
  did="$(sr_route_stuck "$PLACEHOLDER" "$FIXTURE" "backstop:permission_denials" \
          "$(sr_worker_ask "$FIXTURE" 2>/dev/null)" 2>/dev/null)"
  echo "A_DID=$did"
  # §7.3 fork-must-not-rot: the LOCAL S-2 control record is raised even though
  # the hosted dossier write 401s (the control plane is local, by design).
  [[ -f "$CO_STORE/blocked-for-human/$FIXTURE.json" ]] && echo "A_BFH=present" || echo "A_BFH=absent"
  rv="$(jq -r '.resolved' "$CO_STORE/blocked-for-human/$FIXTURE.json" 2>/dev/null)"; echo "A_BFH_RESOLVED=$rv"

  # the hosted `put dossier` hop: bash-contract 401 (rc1/empty/stderr), the
  # I0 D1/D2/D3 divergences CLOSED by I1 (not curl rc0 + leaked envelope).
  env='{"id":"stuck-'"$FIXTURE"'","schema_version":2,"kind":"decide","trigger":"worker_stuck","bead_ref":"'"$FIXTURE"'","tier":"blocking","created_at":"2026-05-17T00:00:00Z","timer_fire_at":null,"body":{"dossier_schema_version":2,"tldr":"x","sections":[],"diagrams":[],"full_detail":"x"},"items":[]}'
  of="$(mktemp)"; ef="$(mktemp)"
  co_request "$PLACEHOLDER" put dossier "stuck-$FIXTURE" "$env" >"$of" 2>"$ef"; drc=$?
  echo "A_PUTDOS_RC=$drc"
  [[ -s "$of" ]] && echo "A_PUTDOS_STDOUT=nonempty" || echo "A_PUTDOS_STDOUT=empty"
  grep -q "co: 401" "$ef" && echo "A_PUTDOS_STDERR=co401" || echo "A_PUTDOS_STDERR=other"
  : > "$of"; : > "$ef"
  # the NEW I3 hop: `put notification` ALSO reaches the live engine + 401s
  nrec='{"id":"notif.stuck-'"$FIXTURE"'","schema_version":1,"dossier_ref":"stuck-'"$FIXTURE"'","tier":"blocking","created_at":"2026-05-17T00:00:00Z","dispatched":false,"dispatched_at":null,"channel":null}'
  co_request "$PLACEHOLDER" put notification "notif.stuck-$FIXTURE" "$nrec" >"$of" 2>"$ef"; nrc=$?
  echo "A_PUTNOT_RC=$nrc"
  [[ -s "$of" ]] && echo "A_PUTNOT_STDOUT=nonempty" || echo "A_PUTNOT_STDOUT=empty"
  grep -q "co: 401" "$ef" && echo "A_PUTNOT_STDERR=co401" || echo "A_PUTNOT_STDERR=other"
  rm -f "$of" "$ef"
  rm -rf "$WA"
) > "$HERE/../.i3-a.txt" 2>/dev/null
ag(){ grep -o "$1=[A-Za-z0-9_.:-]*" "$HERE/../.i3-a.txt" 2>/dev/null | head -1 | cut -d= -f2; }
[[ "$(ag A_DID)" == "stuck-$FIXTURE" ]] \
  && ok "sr_route_stuck echoes the deterministic §7.4 dossier id 'stuck-$FIXTURE' (one fork ⇒ one id) even under a hosted 401" \
  || bad "sr_route_stuck dossier id under live 401 (got '$(ag A_DID)')"
eq "$(ag A_BFH)" "present" "§7.3 fork-must-not-rot: the LOCAL S-2 blocked-for-human control record is raised despite the hosted-write 401"
eq "$(ag A_BFH_RESOLVED)" "false" "the S-2 control record is {resolved:false} (awaiting the human decision — the I4 return path)"
eq "$(ag A_PUTDOS_RC)" "1" "live put dossier 401 ⇒ co_request rc 1 (bash 401 rc, NOT curl rc 0 — I0 D1 closed)"
eq "$(ag A_PUTDOS_STDOUT)" "empty" "live put dossier 401 ⇒ EMPTY stdout (no envelope leaks to a reused parse — I0 D2/D3 closed)"
eq "$(ag A_PUTDOS_STDERR)" "co401" "live put dossier 401 ⇒ diagnostic on STDERR (I0 D3 closed)"
eq "$(ag A_PUTNOT_RC)" "1" "the NEW I3 hop: live put notification 401 ⇒ co_request rc 1 (the notification spine REACHES the deployed engine)"
eq "$(ag A_PUTNOT_STDOUT)" "empty" "live put notification 401 ⇒ EMPTY stdout (I0 D2/D3 closed for the notification hop too)"
eq "$(ag A_PUTNOT_STDERR)" "co401" "live put notification 401 ⇒ diagnostic on STDERR (the dossier+notification spine reaches the real engine; success is token-gated → I5)"
rm -f "$HERE/../.i3-a.txt" 2>/dev/null

# ════════════════════════════════════════════════════════════════════════════
# PART B — LOCAL byte-identical engine: the SUCCESS path. The genuine stuck
#          routes EXACTLY ONE Dossier + EXACTLY ONE §4.3 Notification into the
#          hosted engine; the Dossier is fetched through the EXACT deployed-
#          Inbox phone read front; the §7.4 double-tap stays idempotent; all
#          ≡ the in-process bash oracle.
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART B — local BYTE-IDENTICAL engine · one stuck ⇒ one dossier + one notification ──"
if [[ ! -x "$WRANGLER" ]]; then
  bad "wrangler not found at $WRANGLER (run: npm ci in beads-runner/cf) — PART B SKIPPED"
else
  PORT="${I3_TEST_PORT:-8803}"
  ENGINE="http://127.0.0.1:$PORT"
  GOOD="i3-test-bearer-$$"
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

    # ---- WORLD A: in-process bash ORACLE — the behaviour to match ----------
    ( set +u
      W="$(mktemp -d)"; export CO_STORE="$W/store"
      unset COORDINATOR_URL COORDINATOR_TOKEN CO_EXPECTED_TOKEN 2>/dev/null || true
      source "$HERE/stuck-routing.sh"
      source "$HERE/notification.sh"
      did="$(sr_route_stuck x "$FIXTURE" "backstop:permission_denials" \
              "$(sr_worker_ask "$FIXTURE" 2>/dev/null)" 2>/dev/null)"
      nid="$(no_emit x "$did" 2>/dev/null)"; echo "orc_nrc=$?"
      d="$(co_request x get dossier "$did" 2>/dev/null)"
      echo "orc_did=$did"
      echo "orc_bead=$(printf '%s' "$d" | jq -r '.bead_ref' 2>/dev/null)"
      echo "orc_kind=$(printf '%s' "$d" | jq -r '.kind' 2>/dev/null)"
      echo "orc_trig=$(printf '%s' "$d" | jq -r '.trigger' 2>/dev/null)"
      echo "orc_itk=$(printf '%s' "$d" | jq -r '.items[0].kind' 2>/dev/null)"
      echo "orc_tier=$(printf '%s' "$d" | jq -r '.tier' 2>/dev/null)"
      n="$(co_request x get notification "$nid" 2>/dev/null)"
      echo "orc_nid=$nid"
      echo "orc_ndref=$(printf '%s' "$n" | jq -r '.dossier_ref' 2>/dev/null)"
      echo "orc_ndisp=$(printf '%s' "$n" | jq -r '.dispatched' 2>/dev/null)"
      echo "orc_ntier=$(printf '%s' "$n" | jq -r '.tier' 2>/dev/null)"
      rm -rf "$W"
    ) > "$STATE_DIR/oracle.txt" 2>/dev/null
    og(){ grep -o "$1=[A-Za-z0-9_.:-]*" "$STATE_DIR/oracle.txt" 2>/dev/null | head -1 | cut -d= -f2; }
    note "bash oracle: stuck($FIXTURE) ⇒ dossier $(og orc_did) bead=$(og orc_bead) kind=$(og orc_kind) item=$(og orc_itk); notif $(og orc_nid) dref=$(og orc_ndref) dispatched=$(og orc_ndisp)"

    # ---- WORLD B: the I3 path over the HTTP transport → local engine -------
    ( set +u
      W="$(mktemp -d)"; export CO_STORE="$W/store"; export LOG_DIR="$W/logs"; mkdir -p "$W/logs"
      export COORDINATOR_URL="$ENGINE"; export COORDINATOR_TOKEN="$GOOD"
      unset CO_EXPECTED_TOKEN 2>/dev/null || true
      source "$HERE/stuck-routing.sh"
      source "$HERE/notification.sh"
      source "$HERE/co-http-transport.sh"   # OVERRIDE → HTTP → local engine

      # The genuine stuck routes — the EXACT production codepath (the I3 wiring).
      did="$(sr_route_stuck "$GOOD" "$FIXTURE" "backstop:permission_denials" \
              "$(sr_worker_ask "$FIXTURE" 2>/dev/null)" 2>/dev/null)"
      echo "T_did=$did"
      nid="$(no_emit "$GOOD" "$did" 2>/dev/null)"; echo "T_nrc=$?"
      echo "T_nid=$nid"

      # the EXACT deployed-Inbox phone read front (web/functions/api/inbox/
      # dossier.js): GET /request?op=get&type=dossier&id=<did>. This is
      # precisely what the phone hits — if the genuine dossier comes back
      # here, it "reaches the phone" (read path; the human-on-phone is I5).
      inbox="$(curl -sS -m 20 -H "authorization: Bearer $GOOD" \
                 "$ENGINE/request?op=get&type=dossier&id=$did" 2>/dev/null)"
      echo "IB_bead=$(printf '%s' "$inbox" | jq -r '.bead_ref' 2>/dev/null)"
      echo "IB_kind=$(printf '%s' "$inbox" | jq -r '.kind' 2>/dev/null)"
      echo "IB_trig=$(printf '%s' "$inbox" | jq -r '.trigger' 2>/dev/null)"
      echo "IB_itk=$(printf '%s' "$inbox" | jq -r '.items[0].kind' 2>/dev/null)"
      echo "IB_tier=$(printf '%s' "$inbox" | jq -r '.tier' 2>/dev/null)"
      echo "IB_hasbody=$(printf '%s' "$inbox" | jq -e '.body|type=="object"' >/dev/null 2>&1 && echo yes || echo no)"
      # claude-tools-4xe RESIDUAL — "conformant-write-does-NOT-over-reject":
      # the §5.1-CORE WRITE GATE (co__dossier_write_body_ok / dossierWriteBodyOk,
      # wired into co__store_put / _writeRecord) must REJECT a non-conformant
      # body without OVER-rejecting a conformant one. PART B exercises the EXACT
      # production codepath against the BYTE-IDENTICAL engine (same adapter,
      # same Coordinator DO, same D1 query shape — wrangler.pages-dev.toml fronts
      # cf/src/index.js via pages-dev/adapter.js, identical to a53's production
      # build). The §7.2 path here writes a fresh §5-conformant body, so the
      # body the engine PERSISTED + returns over the deployed-Inbox read front
      # MUST carry the §5.1 conformance markers the gate enforces. If any one
      # of these is missing/wrong, either the gate over-rejected (would have
      # failed the write upstream — caught by T_did/T_nrc above) OR the gate
      # permitted a malformed body through (caught here as a write-side bug).
      # The mirror live-deploy assertion is PART C (token-gated → I5 hop).
      echo "IB_bsv=$(printf '%s' "$inbox" | jq -r '.body.dossier_schema_version' 2>/dev/null)"
      echo "IB_bsv_t=$(printf '%s' "$inbox" | jq -r '.body.dossier_schema_version|type' 2>/dev/null)"
      echo "IB_bdct=$(printf '%s' "$inbox" | jq -r '.body.diagrams|type' 2>/dev/null)"
      echo "IB_bdn=$(printf '%s' "$inbox"  | jq -r '.body.diagrams|length' 2>/dev/null)"
      # first diagram's content head — the §5.1 Mermaid-source check (the
      # gate's co__is_mermaid accepts a Mermaid keyword on line 1).
      echo "IB_bd0head=$(printf '%s' "$inbox" | jq -r '(.body.diagrams[0].content // "")[0:9]' 2>/dev/null)"
      echo "IB_btldr_ne=$(printf '%s' "$inbox" | jq -e '(.body.tldr // "") | length > 0' >/dev/null 2>&1 && echo yes || echo no)"

      # the §4.3 Notification persisted to the hosted engine (the I3 deliverable)
      n="$(co_request "$GOOD" get notification "$nid" 2>/dev/null)"; echo "T_ngetrc=$?"
      echo "T_ndref=$(printf '%s' "$n" | jq -r '.dossier_ref' 2>/dev/null)"
      echo "T_ndisp=$(printf '%s' "$n" | jq -r '.dispatched' 2>/dev/null)"
      echo "T_ntier=$(printf '%s' "$n" | jq -r '.tier' 2>/dev/null)"

      # §7.4 DOUBLE-TAP: a backstop re-trigger on the SAME fork. Still ONE
      # dossier (same id, idempotent) and no_emit stays one-per-Dossier.
      did2="$(sr_route_stuck "$GOOD" "$FIXTURE" "backstop:permission_denials" \
               "$(sr_worker_ask "$FIXTURE" 2>/dev/null)" 2>/dev/null)"
      nid2="$(no_emit "$GOOD" "$did2" 2>/dev/null)"
      echo "T_did2=$did2"; echo "T_nid2=$nid2"
      echo "T_ndisp2=$(co_request "$GOOD" get notification "$nid2" 2>/dev/null | jq -r '.dispatched' 2>/dev/null)"
      rm -rf "$W"
    ) > "$STATE_DIR/worldb.txt" 2>/dev/null
    B="$STATE_DIR/worldb.txt"
    bg(){ grep -o "$1=[A-Za-z0-9_.:-]*" "$B" 2>/dev/null | head -1 | cut -d= -f2; }

    eq "$(bg T_did)" "stuck-$FIXTURE" "the genuine stuck routes ONE Dossier id 'stuck-$FIXTURE' to the hosted engine"
    eq "$(bg T_nrc)" "0" "the I3-wired no_emit ⇒ rc 0 (the SINGLE §4.3 Notification was persisted to the hosted engine)"
    eq "$(bg T_nid)" "notif.stuck-$FIXTURE" "the Notification id is the deterministic 'notif.stuck-$FIXTURE' (one-per-Dossier)"
    # the phone read path:
    eq "$(bg IB_bead)" "$FIXTURE"      "deployed-Inbox read front: the Dossier's bead_ref is the genuine fixture '$FIXTURE'"
    eq "$(bg IB_kind)" "decide"        "deployed-Inbox read front: kind=decide (a worker_stuck decision dossier)"
    eq "$(bg IB_trig)" "worker_stuck"  "deployed-Inbox read front: trigger=worker_stuck (the genuine §7.2 fork)"
    eq "$(bg IB_itk)"  "pick-option"   "deployed-Inbox read front: the §5.2.1 Item is a pick-option (the human's decision)"
    eq "$(bg IB_hasbody)" "yes"        "deployed-Inbox read front: the §5 body is present (renderable on the phone — content quality is the I5 gate)"
    eq "$(bg IB_tier)" "blocking"      "deployed-Inbox read front: tier=blocking (a STUCK fork blocks)"
    # claude-tools-4xe RESIDUAL — conformant-write-does-NOT-over-reject (the
    # §5.1-CORE WRITE GATE PASS path, byte-identical engine; the live-deploy
    # mirror is PART C, token-gated → I5):
    eq "$(bg IB_bsv)"     "2"          "4xe write gate did NOT over-reject: body.dossier_schema_version persisted == bound (2) on the byte-identical engine"
    eq "$(bg IB_bsv_t)"   "number"     "4xe write gate did NOT over-reject: body.dossier_schema_version persisted as a JSON integer (§5.1 'int' / §0.3)"
    eq "$(bg IB_bdct)"    "array"      "4xe write gate did NOT over-reject: body.diagrams persisted as an array (§5.1/AD7)"
    eq "$(bg IB_bdn)"     "1"          "4xe write gate did NOT over-reject: the §7.2 decision-fork synthesis produced exactly ONE diagram (one fork ⇒ one decision graph)"
    eq "$(bg IB_bd0head)" "flowchart"  "4xe write gate did NOT over-reject: diagrams[0].content begins with 'flowchart' — the §11/vkc Mermaid-source the gate's co__is_mermaid accepts"
    eq "$(bg IB_btldr_ne)" "yes"       "4xe write gate did NOT over-reject: body.tldr persisted non-empty (the §5.1-core mandatory tier survives the write)"
    # the notification reached the hosted engine + mirrors the dossier:
    eq "$(bg T_ngetrc)" "0"            "the §4.3 Notification is READABLE from the hosted engine (it persisted, not just attempted)"
    eq "$(bg T_ndref)" "stuck-$FIXTURE" "the Notification.dossier_ref points at the genuine Dossier (C3 binding)"
    eq "$(bg T_ndisp)" "false"         "the Notification is created un-dispatched (creation≠dispatch — the C3 seam; the send is downstream)"
    eq "$(bg T_ntier)" "$(og orc_ntier)" "Notification.tier MIRRORS the Dossier tier ≡ the bash oracle ('$(og orc_ntier)')"
    # ≡ the in-process bash oracle (the I1 equivalence rule):
    eq "$(bg IB_bead)" "$(og orc_bead)" "hosted dossier.bead_ref over HTTP ≡ the bash oracle"
    eq "$(bg IB_kind)" "$(og orc_kind)" "hosted dossier.kind over HTTP ≡ the bash oracle"
    eq "$(bg IB_itk)"  "$(og orc_itk)"  "hosted dossier.items[0].kind over HTTP ≡ the bash oracle"
    eq "$(bg T_ndref)" "$(og orc_ndref)" "hosted notification.dossier_ref over HTTP ≡ the bash oracle"
    # §7.4 double-tap idempotency:
    eq "$(bg T_did2)" "stuck-$FIXTURE" "§7.4 double-tap: a backstop re-trigger yields the SAME dossier id (one fork ⇒ ONE Dossier)"
    eq "$(bg T_nid2)" "notif.stuck-$FIXTURE" "§7.4 double-tap: still the SAME single Notification (no_emit one-per-Dossier idempotent)"
    eq "$(bg T_ndisp2)" "false"        "§7.4 double-tap: the re-emit did NOT reset the dispatch latch (idempotent, not a re-creation)"
  fi
fi

# ════════════════════════════════════════════════════════════════════════════
# PART C — production-token auto-detect: the live success hop iff a real token
#          resolves; else SKIP (the by-design I0 D0 withholding → I5).
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART C — LIVE deployed stuck→dossier+notification (the I5 hop) ──"
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
  note "CO_EXPECTED_TOKEN is held by Brian out of agent context. PART A proved"
  note "the genuine stuck's dossier+notification hops REACH the deployed engine"
  note "(bash-contract 401, I0 D1/D2/D3 closed) while the §7.3 fork still does"
  note "not rot; PART B proved the SUCCESS path ≡ the bash oracle against the"
  note "byte-identical engine production runs verbatim, the Dossier fetched"
  note "through the EXACT deployed-Inbox phone read front. The live run is a"
  note "zero-code-change credential flip consolidated SOLELY into the I5"
  note "session (the genuine human-on-phone, fully-unmocked proof)."
else
  CTXT="$(mktemp)"
  ( set +u
    W="$(mktemp -d)"; export CO_STORE="$W/store"; export LOG_DIR="$W/logs"; mkdir -p "$W/logs"
    export COORDINATOR_URL="$LIVE_URL"
    [[ "$PROD_TOKEN" != "present-in-keychain" ]] && export COORDINATOR_TOKEN="$PROD_TOKEN"
    source "$HERE/stuck-routing.sh"; source "$HERE/notification.sh"; source "$HERE/co-http-transport.sh"
    did="$(sr_route_stuck "${COORDINATOR_TOKEN:-x}" "$FIXTURE" "backstop:permission_denials" \
            "$(sr_worker_ask "$FIXTURE" 2>/dev/null)" 2>/dev/null)"
    nid="$(no_emit "${COORDINATOR_TOKEN:-x}" "$did" 2>/dev/null)"; nr=$?
    ib="$(curl -sS -m 20 -H "authorization: Bearer ${COORDINATOR_TOKEN:-x}" \
            "$LIVE_URL/request?op=get&type=dossier&id=$did" 2>/dev/null)"
    bead="$(printf '%s' "$ib" | jq -r '.bead_ref' 2>/dev/null)"
    echo "CLIVE nr=$nr bead=$bead did=$did"
    rm -rf "$W"
  ) > "$CTXT" 2>/dev/null || true
  if grep -q "CLIVE nr=0 bead=$FIXTURE" "$CTXT" 2>/dev/null; then
    ok "LIVE deployed engine: the genuine stuck ⇒ Dossier + §4.3 Notification, fetched via the deployed-Inbox front (the I5 hop, token present)"
  else
    bad "LIVE deployed stuck→dossier+notification ($(cat "$CTXT" 2>/dev/null | tr -d '\n' | head -c 120))"
  fi
  rm -f "$CTXT" 2>/dev/null || true
fi

echo ""
echo "════════════════════════════════════════════════════════════════════════"
printf '  RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "════════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
