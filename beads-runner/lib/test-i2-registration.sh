#!/bin/bash
# beads-runner/lib/test-i2-registration.sh — I2 acceptance (claude-tools-smp;
# epic claude-tools-8bm).
#
# I2 DELIVERABLE proven here: a runner in a SECOND workspace REGISTERS +
# heartbeats RunnerState (§4.2 actual / §2.4 reconcile) to the HOSTED
# coordinator under its OWN distinct project_ref. "Coordinate across
# workspaces" = N runners, ONE hosted authority — claude-tools and thirsty
# are independent runner_state rows the deployed read path surfaces side by
# side, neither clobbering the other.
#
# Same three-part discipline as test-co-http-transport.sh (I1), same reason:
#   PART A — LIVE deployed coordinator-cf, the by-design 401 posture (no real
#            token: the I0 D0 withholding). Proves the I2 §4.2 heartbeat line
#            + the §2.4 reconcile read REACH the real deployed engine with the
#            right shape + the right per-workspace project_ref, and that the
#            durable §1.1 outbox RETAINS the line at-least-once on the 401
#            (registration is never lost — it drains on a later authed
#            reconnect, the §2.4 contract).
#   PART B — LOCAL byte-identical engine (cf/pages-dev/adapter.js over the
#            unchanged cf/src, wrangler.pages-dev = the code production runs
#            VERBATIM): the SUCCESS path I0 could not reach. A `thirsty`
#            heartbeat REGISTERS RunnerState; the §2.4 reconcile + the EXACT
#            deployed-Board read front (GET /request?op=work-snapshot&
#            project=thirsty) show it as a LIVE runner; a second `claude-tools`
#            registration is an INDEPENDENT row (distinct project_ref, one
#            authority). Every observable asserted ≡ the in-process bash
#            oracle (co__heartbeat/co__reconcile), the I1 equivalence rule.
#   PART C — production-token auto-detect: the live success hop iff a real
#            token resolves; else SKIP with the by-design notice. The genuine
#            human-on-phone unmocked proof is consolidated SOLELY into I5.
#
# Not in the T1 conformance suite — its own focused acceptance, same as the
# other lib/test-*.sh. Run:  bash beads-runner/lib/test-i2-registration.sh
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

# ════════════════════════════════════════════════════════════════════════════
# PART 0 — the wired second workspace + the detached launcher (deliverables
#          a + b), asserted statically (no live runner started — the epic
#          CONSTRAINT keeps thirsty's runner OFF / its ready queue intact as
#          the I3 fixture; the long-lived launch is a separate non-ephemeral
#          act folded into I3/I5, never a task agent's).
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART 0 — workspace 2 wired + detached launcher present (static) ──"
TW="/Users/brianbutler/code/thirsty/.beads/runner.sh"
if [[ -f "$TW" ]]; then
  ok "thirsty/.beads/runner.sh exists (workspace 2 config seam)"
  grep -q '^COORDINATOR_URL=' "$TW" \
    && ok "thirsty config sets COORDINATOR_URL (hosted transport activates there)" \
    || bad "thirsty config sets COORDINATOR_URL"
  pr="$(grep -o '^PROJECT_REF="[^"]*"' "$TW" | head -1 | cut -d'"' -f2)"
  [[ "$pr" == "thirsty" && "$pr" != "claude-tools" ]] \
    && ok "thirsty pins a DISTINCT project_ref ('$pr' ≠ 'claude-tools')" \
    || bad "thirsty pins a distinct project_ref (got '$pr')"
  # The config may (should) DOCUMENT the §9.2 token mechanism by name, but
  # MUST NOT assign COORDINATOR_TOKEN a value or carry a literal secret.
  if grep -Eq 'security|Keychain|COORDINATOR_TOKEN' "$TW" \
     && ! grep -Eq '^[[:space:]]*(export[[:space:]]+)?COORDINATOR_TOKEN=[^[:space:]#]' "$TW" \
     && ! grep -q 'secret-xyz' "$TW"; then
    ok "thirsty config documents the §9.2 server-side token WITHOUT embedding one (out of agent context)"
  else
    bad "thirsty config must not embed a token"
  fi
else
  bad "thirsty/.beads/runner.sh missing — workspace 2 not wired"
fi
LAUNCH="$HERE/../launch-detached.sh"
if [[ -x "$LAUNCH" ]]; then
  ok "launch-detached.sh present + executable (deliverable b)"
  bash -n "$LAUNCH" 2>/dev/null && ok "launch-detached.sh parses (bash -n clean)" || bad "launch-detached.sh syntax"
  grep -q 'nohup' "$LAUNCH" && grep -q '/dev/null' "$LAUNCH" \
    && ok "launcher detaches (nohup + </dev/null subshell → reparents off the task-agent tree, BC-39/40)" \
    || bad "launcher detach idiom"
  # Refuses without a wired workspace (precondition guard) — and refuses to
  # start a duplicate. Cheap to assert: a bogus dir exits 2, never launches.
  ( "$LAUNCH" /nonexistent/zzz >/dev/null 2>&1 ); rc=$?
  [[ "$rc" -eq 2 ]] && ok "launcher refuses a non-workspace dir (exit 2 — no stray runner)" \
                     || bad "launcher precondition guard (rc=$rc want 2)"
else
  bad "launch-detached.sh missing/not executable"
fi

# ════════════════════════════════════════════════════════════════════════════
# PART A — LIVE deployed coordinator-cf: the by-design 401 posture. The I2
#          §4.2 heartbeat + §2.4 reconcile REACH the real engine; the durable
#          §1.1 outbox retains the line at-least-once (nothing lost).
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART A — LIVE deployed coordinator-cf · I2 heartbeat/reconcile 401 posture ──"
echo "   target: $LIVE_URL  (no real token — the by-design D0 withholding)"

(
  set +u
  WORK_A="$(mktemp -d)"
  export LOG_DIR="$WORK_A/logs"; mkdir -p "$LOG_DIR"
  export PROJECT_REF="thirsty"
  export COORDINATOR_URL="$LIVE_URL"
  unset COORDINATOR_TOKEN CO_EXPECTED_TOKEN 2>/dev/null || true
  source "$HERE/local-agent.sh"           # la_report_heartbeat / la__outbox / la_outbox_drain guard
  source "$HERE/co-http-transport.sh"     # OVERRIDE: co_request now HTTP→LIVE

  # 1. the §4.2 heartbeat line is well-formed for the hosted co__heartbeat:
  #    report=="heartbeat", integer schema_version, the distinct project_ref,
  #    an actual in the §4.2 enum, an observed_at (= last_heartbeat_at, S-1).
  la_report_heartbeat starting "" 2>/dev/null
  obx="$LOG_DIR/coordinator-outbox.jsonl"
  line="$(tail -n1 "$obx" 2>/dev/null)"
  rep="$(printf '%s' "$line" | jq -r '.report' 2>/dev/null)"
  prj="$(printf '%s' "$line" | jq -r '.project_ref' 2>/dev/null)"
  act="$(printf '%s' "$line" | jq -r '.actual' 2>/dev/null)"
  svt="$(printf '%s' "$line" | jq -r '.schema_version|type' 2>/dev/null)"
  obs="$(printf '%s' "$line" | jq -r 'has("observed_at")' 2>/dev/null)"
  eq "$rep" "heartbeat"  "§4.2 line: report==\"heartbeat\" (the la_outbox_drain → hosted heartbeat discriminator)"
  eq "$prj" "thirsty"    "§4.2 line: project_ref is the workspace-2 distinct key 'thirsty'"
  eq "$svt" "number"     "§4.2 line: schema_version is an integer (§0.3 — co__heartbeat binds v1)"
  case "$act" in starting|running|idle|stopping|stopped|crashed)
    ok "§4.2 line: actual '$act' ∈ the closed §4.2 enum (co__heartbeat would accept it)";;
  *) bad "§4.2 line: actual '$act' not in the §4.2 enum";; esac
  eq "$obs" "true"       "§4.2 line: carries observed_at (becomes last_heartbeat_at — THE S-1 liveness datum)"

  # 2. draining it to the LIVE engine with no real token: an authentic 401.
  #    co_request must be the bash-contract 401 (rc 1, empty stdout, stderr),
  #    NOT curl rc 0 + a leaked envelope (I0 D1/D2/D3).
  of="$(mktemp)"; ef="$(mktemp)"
  co_request "$PLACEHOLDER" heartbeat "$line" >"$of" 2>"$ef"; rc=$?
  body="$(cat "$of")"; err="$(cat "$ef")"; rm -f "$of" "$ef"
  eq "$rc" "1" "live heartbeat 401 ⇒ co_request rc 1 (bash 401 rc, not curl rc 0)"
  [[ -z "$body" ]] && ok "live heartbeat 401 ⇒ EMPTY stdout (no envelope leaks to a reused parse — D2/D3)" \
                    || bad "live heartbeat 401 ⇒ EMPTY stdout (got: $(printf '%s' "$body" | head -c 80))"
  printf '%s' "$err" | grep -q "co: 401" \
    && ok "live heartbeat 401 ⇒ diagnostic on STDERR (D3)" \
    || bad "live heartbeat 401 ⇒ diagnostic on STDERR (got: $(printf '%s' "$err" | head -c 80))"

  # 3. la_outbox_drain over the live 401: the line is RETAINED (registration
  #    is durable — at-least-once; a missing token never loses a heartbeat).
  la_outbox_drain "$PLACEHOLDER" >/dev/null 2>&1; drc=$?
  remain="$(wc -l < "$obx" 2>/dev/null | tr -d ' ')"
  [[ "$drc" -ne 0 ]] && ok "la_outbox_drain live-401 ⇒ rc≠0 (a line was retained, caller may retry)" \
                      || bad "la_outbox_drain live-401 ⇒ rc≠0 (got $drc)"
  [[ "$remain" -ge 1 ]] && ok "the §4.2 heartbeat is RETAINED in the durable §1.1 outbox (drains on a later authed reconnect — §2.4; registration never lost)" \
                        || bad "heartbeat retained on 401 (remain=$remain)"

  # 4. the §2.4 reconcile READ for the distinct project_ref also reaches the
  #    live engine and 401s CLEANLY (rc 1 — absent/unreachable, NOT the I0
  #    rc-3 §0.3 misclassification reconcile is a DATA-200 op-class).
  ro="$(co_request "$PLACEHOLDER" reconcile thirsty 2>/dev/null)"; rrc=$?
  [[ "$rrc" -ne 3 ]] && ok "live reconcile(thirsty) 401 ⇒ rc≠3 (the I0 §0.3 misclassification is CLOSED on the read path too)" \
                      || bad "live reconcile(thirsty) 401 ⇒ rc≠3 (still the I0 rc-3 bug)"
  eq "$rrc" "1" "live reconcile(thirsty) 401 ⇒ rc 1 (clean absent/unreachable, oracle-shaped)"
  [[ -z "$ro" ]] && ok "live reconcile(thirsty) 401 ⇒ empty stdout (no envelope surfaced)" \
                 || bad "live reconcile(thirsty) 401 ⇒ empty stdout"

  rm -rf "$WORK_A"
)

# ════════════════════════════════════════════════════════════════════════════
# PART B — LOCAL byte-identical engine: the SUCCESS path. thirsty REGISTERS;
#          reconcile + the EXACT deployed-Board read front show it LIVE;
#          claude-tools is an independent row. All ≡ the bash oracle.
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART B — local BYTE-IDENTICAL engine · register ≡ bash oracle ──"

if [[ ! -x "$WRANGLER" ]]; then
  bad "wrangler not found at $WRANGLER (run: npm ci in beads-runner/cf) — PART B SKIPPED"
else
  PORT="${I2_TEST_PORT:-8801}"
  ENGINE="http://127.0.0.1:$PORT"
  GOOD="i2-test-bearer-$$"
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
    # co__heartbeat(thirsty, starting) then co__reconcile(thirsty): the oracle
    # actual/liveness/project_ref are what the HTTP path MUST reproduce.
    (
      set +u
      W="$(mktemp -d)"; export CO_STORE="$W/store"
      unset COORDINATOR_URL COORDINATOR_TOKEN CO_EXPECTED_TOKEN 2>/dev/null || true
      source "$HERE/coordinator.sh"        # in-process bash co_request + co__*
      hb='{"report":"heartbeat","schema_version":1,"principal":"p","runner_id":"r","project_ref":"thirsty","actual":"starting","observed_at":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}'
      co_request x heartbeat "$hb" >/dev/null 2>&1; echo "orc_hb=$?"
      rec="$(co_request x reconcile thirsty 2>/dev/null)"; echo "orc_rec=$?"
      echo "orc_actual=$(printf '%s' "$rec" | jq -r '.actual' 2>/dev/null)"
      echo "orc_live=$(printf '%s' "$rec" | jq -r '.liveness' 2>/dev/null)"
      echo "orc_proj=$(printf '%s' "$rec" | jq -r '.project_ref' 2>/dev/null)"
      rm -rf "$W"
    ) > "$STATE_DIR/oracle.txt" 2>/dev/null
    og(){ grep -o "$1=[0-9A-Za-z_.:-]*" "$STATE_DIR/oracle.txt" | head -1 | cut -d= -f2; }
    o_actual="$(og orc_actual)"; o_live="$(og orc_live)"; o_proj="$(og orc_proj)"
    note "bash oracle: heartbeat→reconcile(thirsty) ⇒ actual=$o_actual liveness=$o_live project_ref=$o_proj"

    # ---- WORLD B: the I2 path over the HTTP transport → local engine -------
    (
      set +u
      W="$(mktemp -d)"; export LOG_DIR="$W/logs"; mkdir -p "$W/logs"
      export COORDINATOR_URL="$ENGINE"; export COORDINATOR_TOKEN="$GOOD"
      unset CO_EXPECTED_TOKEN 2>/dev/null || true
      source "$HERE/local-agent.sh"        # la_report_heartbeat / la_outbox_drain
      source "$HERE/coordinator.sh"        # co__* + bash co_request (then overridden)
      source "$HERE/co-http-transport.sh"  # OVERRIDE → HTTP → local engine

      # thirsty registers: emit `starting`, drain → hosted co__heartbeat.
      export PROJECT_REF="thirsty"
      la_report_heartbeat starting "" 2>/dev/null
      la_outbox_drain "$GOOD" >/dev/null 2>&1; echo "T_DRAIN1 rc=$?"
      echo "T_REMAIN1=$(wc -l < "$W/logs/coordinator-outbox.jsonl" 2>/dev/null | tr -d ' ')"

      # §2.4 reconcile read-back over the transport.
      rec="$(co_request "$GOOD" reconcile thirsty 2>/dev/null)"; echo "T_REC rc=$?"
      echo "T_actual=$(printf '%s' "$rec" | jq -r '.actual' 2>/dev/null)"
      echo "T_live=$(printf '%s' "$rec" | jq -r '.liveness' 2>/dev/null)"
      echo "T_proj=$(printf '%s' "$rec" | jq -r '.project_ref' 2>/dev/null)"

      # a `running` heartbeat carries current_task_ref + keeps it live.
      la_report_heartbeat running "thirsty-99" 2>/dev/null
      la_outbox_drain "$GOOD" >/dev/null 2>&1
      rec2="$(co_request "$GOOD" reconcile thirsty 2>/dev/null)"
      echo "T_actual2=$(printf '%s' "$rec2" | jq -r '.actual' 2>/dev/null)"
      echo "T_cur2=$(printf '%s' "$rec2" | jq -r '.current_task_ref' 2>/dev/null)"
      echo "T_live2=$(printf '%s' "$rec2" | jq -r '.liveness' 2>/dev/null)"

      # SECOND workspace, SAME hosted authority: claude-tools registers under
      # ITS own project_ref. Must NOT clobber thirsty's row.
      export PROJECT_REF="claude-tools"
      la_report_heartbeat idle "" 2>/dev/null
      la_outbox_drain "$GOOD" >/dev/null 2>&1
      recC="$(co_request "$GOOD" reconcile claude-tools 2>/dev/null)"
      echo "C_actual=$(printf '%s' "$recC" | jq -r '.actual' 2>/dev/null)"
      echo "C_proj=$(printf '%s' "$recC" | jq -r '.project_ref' 2>/dev/null)"
      recT="$(co_request "$GOOD" reconcile thirsty 2>/dev/null)"
      echo "T_actual3=$(printf '%s' "$recT" | jq -r '.actual' 2>/dev/null)"
      echo "T_proj3=$(printf '%s' "$recT" | jq -r '.project_ref' 2>/dev/null)"
      rm -rf "$W"
    ) > "$STATE_DIR/worldb.txt" 2>/dev/null
    B="$STATE_DIR/worldb.txt"
    bg(){ grep -o "$1=[0-9A-Za-z_.:-]*" "$B" | head -1 | cut -d= -f2; }

    eq "$(bg 'T_DRAIN1 rc')" "0" "la_outbox_drain(thirsty heartbeat) ⇒ rc 0 (registered to the hosted engine)"
    eq "$(bg 'T_REMAIN1')"   "0" "outbox drained: 0 retained — the §4.2 line was accepted (REGISTERED)"
    eq "$(bg 'T_REC rc')"    "0" "§2.4 reconcile(thirsty) over HTTP ⇒ rc 0 (DATA-200 read passthrough)"
    eq "$(bg 'T_actual')" "$o_actual" "reconcile(thirsty).actual over HTTP ≡ bash oracle ('$o_actual')"
    eq "$(bg 'T_live')"   "$o_live"   "reconcile(thirsty).liveness over HTTP ≡ bash oracle ('$o_live' — appears as a LIVE runner)"
    eq "$(bg 'T_proj')"   "$o_proj"   "reconcile(thirsty).project_ref over HTTP ≡ bash oracle ('$o_proj' — the distinct key)"
    eq "$(bg 'T_live')"   "live"      "the registered thirsty runner reads back liveness=live (S-1: now−last_heartbeat_at ≤ STALE_AFTER)"
    eq "$(bg 'T_actual2')" "running"  "a follow-up 'running' heartbeat updates RunnerState.actual (the heartbeat sequence works)"
    eq "$(bg 'T_cur2')"   "thirsty-99" "the 'running' heartbeat carries current_task_ref through to RunnerState"
    eq "$(bg 'T_live2')"  "live"      "still live after the second heartbeat (continuous registration)"
    # distinct project_ref / N-runners-one-authority:
    eq "$(bg 'C_proj')"   "claude-tools" "claude-tools registers under ITS OWN project_ref (one hosted authority, two runners)"
    eq "$(bg 'C_actual')" "idle"       "claude-tools RunnerState.actual is its own ('idle'), independent of thirsty"
    eq "$(bg 'T_actual3')" "running"   "thirsty's row is UNCLOBBERED by claude-tools registering (distinct project_ref — no cross-talk)"
    eq "$(bg 'T_proj3')"  "thirsty"    "thirsty still keys 'thirsty' after the second workspace registered"

    # ---- the EXACT deployed-Board read front: GET /request?op=work-snapshot
    #      &project=<pr>. This is precisely what the deployed screens hit
    #      (cf adapter argsForGet → reconcile.js workSnapshot). If THIS shows
    #      thirsty live + distinct from claude-tools, a real runner in
    #      workspace 2 "appears as a live runner via the deployed read path".
    snapT="$(curl -sS -m 20 -H "authorization: Bearer $GOOD" \
               "$ENGINE/request?op=work-snapshot&project=thirsty" 2>/dev/null)"
    pT="$(printf '%s' "$snapT" | jq -r '.projects[0].project_ref' 2>/dev/null)"
    lT="$(printf '%s' "$snapT" | jq -r '.projects[0].runner_state.liveness' 2>/dev/null)"
    aT="$(printf '%s' "$snapT" | jq -r '.projects[0].runner_state.actual' 2>/dev/null)"
    eq "$pT" "thirsty" "deployed-Board front (work-snapshot?project=thirsty): project_ref=thirsty"
    eq "$lT" "live"    "deployed-Board front: thirsty shows liveness=live (THE I2 acceptance — a live runner via the deployed read path)"
    eq "$aT" "running" "deployed-Board front: thirsty.actual=running (the heartbeat-reported state)"

    snapAll="$(curl -sS -m 20 -H "authorization: Bearer $GOOD" \
                 "$ENGINE/request?op=work-snapshot" 2>/dev/null)"
    nproj="$(printf '%s' "$snapAll" | jq -r '[.projects[].project_ref]|sort|join(",")' 2>/dev/null)"
    [[ "$nproj" == "claude-tools,thirsty" ]] \
      && ok "deployed-Board front (no filter): BOTH project_refs surface side by side ('$nproj' — N runners, ONE hosted authority)" \
      || bad "deployed-Board front shows both distinct runners (got '$nproj')"
  fi
fi

# ════════════════════════════════════════════════════════════════════════════
# PART C — production-token auto-detect: the I5 hop iff a real token resolves.
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART C — LIVE deployed registration (the I5 hop) ──"
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
  note "the live 401 posture (heartbeat + reconcile reach the deployed engine"
  note "with the right distinct project_ref; the line is durably retained);"
  note "PART B proved the registration SUCCESS path ≡ the bash oracle against"
  note "the byte-identical engine production runs verbatim, visible via the"
  note "EXACT deployed-Board read front. The live run is a zero-code-change"
  note "credential flip consolidated SOLELY into the I5 session."
else
  # PART-C-local scratch: PART C is independent of PART B, so it must NOT
  # reach for PART B's $STATE_DIR — that is assigned only inside the
  # wrangler-present branch (line ~183). Under the file's `set -u`, the I5
  # hop on a wrangler-less host (real token, no local engine) would abort
  # with `STATE_DIR: unbound` BEFORE the RESULT line. Own temp file ⇒ safe.
  CTXT="$(mktemp)"
  ( set +u
    W="$(mktemp -d)"; export LOG_DIR="$W/logs"; mkdir -p "$W/logs"
    export COORDINATOR_URL="$LIVE_URL"
    export PROJECT_REF="thirsty"
    [[ "$PROD_TOKEN" != "present-in-keychain" ]] && export COORDINATOR_TOKEN="$PROD_TOKEN"
    source "$HERE/local-agent.sh"
    source "$HERE/coordinator.sh"
    source "$HERE/co-http-transport.sh"
    la_report_heartbeat starting "" 2>/dev/null
    la_outbox_drain "${COORDINATOR_TOKEN:-x}" >/dev/null 2>&1; dr=$?
    rec="$(co_request "${COORDINATOR_TOKEN:-x}" reconcile thirsty 2>/dev/null)"; rr=$?
    live="$(printf '%s' "$rec" | jq -r '.liveness' 2>/dev/null)"
    echo "CLIVE drain=$dr rec=$rr live=$live"
    rm -rf "$W"
  ) > "$CTXT" 2>/dev/null || true
  if grep -q "CLIVE drain=0 rec=0 live=live" "$CTXT" 2>/dev/null; then
    ok "LIVE deployed engine: thirsty heartbeat REGISTERED + reconcile ⇒ liveness=live (the I5 hop, token present)"
  else
    bad "LIVE deployed registration ($(cat "$CTXT" 2>/dev/null | tr -d '\n' | head -c 120))"
  fi
  rm -f "$CTXT" 2>/dev/null || true
fi

echo ""
echo "════════════════════════════════════════════════════════════════════════"
printf '  RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "════════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
