#!/bin/bash
# beads-runner/lib/test-i4-feedback-return.sh — I4 acceptance (claude-tools-ryz;
# epic claude-tools-8bm).
#
# I4 DELIVERABLE proven here — THE FEEDBACK RETURN PATH (the closed loop's
# return leg, the slice epic 8bm names "has never been wired"):
#   • PARK already existed (§7.3: sr__raise_bfh {resolved:false} + the bead
#     driven blocked; the runner moves on §7.5).
#   • AWAIT is NEW: sr_poll_hosted_resolution READS each parked Dossier back
#     over the SAME §2.1 `co_request get dossier` surface the I1 transport
#     carries (→ the HOSTED deployed engine). When Brian answers on his phone
#     the deployed Inbox `/api/inbox/respond` proxy POSTs the FROZEN `item-apply`
#     op upstream and §5.2.2/§7.4 moves the Item answered→applied IN THE
#     ENGINE — the runner observes that and flips the S-2 record resolved:true.
#   • RESUME is NEW: the decision is captured the moment it is observed (a
#     T5-owned SIBLING namespace under the same store, the bfh/dedup/forensic
#     precedent — NO new §4 record type, NO new op) and the runner splices it
#     into the re-dispatched worker prompt so the agent ACTS on the answer
#     instead of re-hitting the fork — "Brian's phone answer demonstrably
#     changes what the parked agent does next".
#
# Same three-part discipline as test-i1 / test-i2 / test-i3 (the epic batching
# directive: I4 verifies against the LIVE DEPLOYED engine; a programmatic
# answer is permitted for I4's OWN verification ONLY; the genuine
# human-on-phone, fully-unmocked proof is consolidated SOLELY into I5):
#   PART 0 — the I4 machinery exists in stuck-routing.sh and is WIRED into the
#            runner: poll+reconcile at the loop top (the parked runner observes
#            while busy), the resume splice in the prompt build, guarded /
#            observable-not-silent, the I3 NO_LIB<CT_LIB ordering preserved.
#   PART A — LIVE deployed coordinator-cf, the by-design 401 posture (no real
#            token — the I0 D0 withholding). The §7.3 PARK still raises the
#            LOCAL S-2 record; the return-leg READ hop (do_dossier_get) REACHES
#            the real deployed engine and returns the bash-contract 401
#            (rc1/empty/"co: 401" — I0 D1/D2/D3 closed by I1) ⇒ the fork stays
#            PARKED: bfh resolved:false, NO answer captured, NO false resume.
#            The success/answer path is token-gated (I5).
#   PART B — LOCAL byte-identical engine (cf/pages-dev over the unchanged
#            cf/src = the code production runs VERBATIM): the FULL closed loop.
#            A stuck routes a Dossier into the hosted engine; the phone answer
#            is stood in PROGRAMMATICALLY via the EXACT deployed front
#            (POST /request?op=item-apply — precisely what web/functions/api/
#            inbox/respond.js forwards; permitted for I4's OWN verification). The
#            parked runner's poll OBSERVES it over HTTP, captures the decision,
#            flips S-2; the existing reconcile lifts the bead (→ open) and the
#            resume directive carries the human's choice. Every observable ≡
#            the in-process bash oracle (the I1 equivalence rule). Negative: an
#            UNANSWERED fork is NOT resolved (the parked agent stays parked);
#            a second poll is idempotent (no double-resume).
#   PART C — production-token auto-detect: the live success hop iff a real
#            token resolves; else SKIP with the by-design notice (the I5 hop).
#
# Not in the T1 conformance suite — its own focused acceptance, same as the
# other lib/test-*.sh. Run:  bash beads-runner/lib/test-i4-feedback-return.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CF_DIR="$(cd "$HERE/../cf" && pwd)"
RUNNER="$HERE/../run-beads-tasks.sh"
SR_LIB="$HERE/stuck-routing.sh"
WRANGLER="$CF_DIR/node_modules/.bin/wrangler"
LIVE_URL="https://coordinator-cf.bbthechange.workers.dev"
PLACEHOLDER="bearer-runner-secret-xyz"     # the bearer the libs/tests carry (I0 D0)
FIXTURE="thirsty-7ytu"                      # the genuine decision-task in workspace 2 (I3 continuity)

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
note(){ printf '  · %s\n' "$1"; }
eq()  { [[ "$1" == "$2" ]] && ok "$3" || { bad "$3 (got '$1' want '$2')"; }; }
has() { case "$1" in *"$2"*) ok "$3";; *) bad "$3 (missing '$2')";; esac; }

# ════════════════════════════════════════════════════════════════════════════
# PART 0 — the I4 park/await/resume machinery exists + is WIRED (static)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART 0 — I4 feedback-return machinery + runner wiring (static) ──"
if [[ -f "$SR_LIB" ]]; then
  ok "stuck-routing.sh present"
  for fn in sr_poll_hosted_resolution sr_resume_answer sr_format_resume_directive \
            sr_consume_resume_answer sr__answer_dir; do
    grep -q "^$fn()" "$SR_LIB" \
      && ok "stuck-routing.sh defines $fn (the I4 await/resume machinery)" \
      || bad "stuck-routing.sh defines $fn"
  done
  grep -q 'do_dossier_get "\$bearer" "\$did"' "$SR_LIB" \
    && ok "the poll AWAITs over the §2.1 'co_request get dossier' READ surface (no new op — I1 transport carries it to the hosted engine)" \
    || bad "poll reads via do_dossier_get (§2.1 surface)"
  grep -q 'blocked-for-human-answer' "$SR_LIB" \
    && ok "the resume-answer is a T5-owned SIBLING namespace (the bfh/dedup/forensic precedent — NO new §4 record type)" \
    || bad "resume-answer sibling namespace present"
  bash -n "$SR_LIB" 2>/dev/null && ok "stuck-routing.sh parses (bash -n clean) with the I4 machinery" || bad "stuck-routing.sh syntax"
else
  bad "stuck-routing.sh missing"
fi
if [[ -f "$RUNNER" ]]; then
  ok "run-beads-tasks.sh present"
  # The PARKED runner observes while busy: poll + reconcile at the loop top,
  # BEFORE next_task, so a just-answered fork re-enters the very next pick.
  pl="$(grep -n 'sr_poll_hosted_resolution' "$RUNNER" | head -1 | cut -d: -f1)"
  rc="$(grep -n 'sr_reconcile_blocked_for_human' "$RUNNER" | head -1 | cut -d: -f1)"
  nt="$(grep -n 'TASK_JSON=\$(next_task)' "$RUNNER" | head -1 | cut -d: -f1)"
  { [[ -n "$pl" && -n "$rc" && -n "$nt" && "$pl" -lt "$nt" && "$rc" -lt "$nt" ]]; } \
    && ok "runner polls hosted resolution + reconciles BEFORE next_task (the parked runner observes while busy on other beads)" \
    || bad "poll+reconcile must run before next_task (got poll@$pl reconcile@$rc next_task@$nt)"
  grep -q 'command -v sr_poll_hosted_resolution >/dev/null 2>&1' "$RUNNER" \
    && ok "the poll/reconcile block is guarded-optional (absent lib ⇒ runner unchanged — the §8.2 la_* discipline)" \
    || bad "poll/reconcile guarded by command -v"
  grep -q 'FEEDBACK RETURN (§7.3/S-2/I4)' "$RUNNER" \
    && ok "the feedback-return is OBSERVABLE-not-silent (a §-cited line when a fork Brian answered re-enters)" \
    || bad "feedback-return observable-not-silent"
  # RESUME: the captured decision is spliced into the worker prompt and the
  # answer is one-shot consumed (no stale re-inject on a later pickup).
  grep -q 'sr_format_resume_directive "\$TASK_ID"' "$RUNNER" \
    && ok "the runner SPLICES the captured human decision into the resumed worker prompt (acts on the answer, not the fork)" \
    || bad "runner splices sr_format_resume_directive into PROMPT"
  awk '/sr_format_resume_directive "\$TASK_ID"/{f=1} f&&/PROMPT="\$SR_DIRECTIVE/{print "P";exit}' "$RUNNER" | grep -q P \
    && ok "the decision is PREPENDED to the prompt (highest salience — the first thing the resumed agent reads)" \
    || bad "resume directive prepended to PROMPT"
  grep -q 'sr_consume_resume_answer "\$TASK_ID"' "$RUNNER" \
    && ok "the resume-answer is one-shot consumed after splicing (a later unrelated pickup never re-injects a stale decision)" \
    || bad "runner consumes the resume-answer one-shot"
  grep -q 'RESUME (§7.3/S-2/I4)' "$RUNNER" \
    && ok "the resume is OBSERVABLE-not-silent (a §-cited line when the agent is resumed with the answer)" \
    || bad "resume observable-not-silent"
  # I3 regression: NO_LIB (notification.sh) must still be sourced BEFORE CT_LIB
  # (co-http-transport) so the I1 HTTP co_request override still wins last.
  nlx="$(grep -n 'NO_LIB=.*lib/notification.sh' "$RUNNER" | head -1 | cut -d: -f1)"
  clx="$(grep -n 'CT_LIB=.*lib/co-http-transport.sh' "$RUNNER" | head -1 | cut -d: -f1)"
  { [[ -n "$nlx" && -n "$clx" && "$nlx" -lt "$clx" ]]; } \
    && ok "I3 regression: NO_LIB still sourced BEFORE CT_LIB (the I1 HTTP co_request override still wins last)" \
    || bad "NO_LIB must precede CT_LIB (got NO_LIB@$nlx CT_LIB@$clx)"
  bash -n "$RUNNER" 2>/dev/null && ok "run-beads-tasks.sh parses (bash -n clean) with the I4 wiring" || bad "runner syntax with I4 wiring"
else
  bad "run-beads-tasks.sh missing"
fi

# ════════════════════════════════════════════════════════════════════════════
# GENUINE — the fully-unmocked human-on-phone proof is the epic's I5-
#   consolidated SOLE gate (batching directive). I4 is a BUILD task: it closes
#   on the LIVE-DEPLOYED-ENGINE wiring verification (PART 0/A/B/C); the
#   programmatic phone-answer stand-in below is the EXACT deployed front
#   (POST /request?op=item-apply — what web/functions/api/inbox/respond.js
#   forwards), permitted for I4's OWN verification ONLY. Nothing about the
#   return PATH is mocked: the parked runner's poll really reads the Dossier
#   back from the byte-identical production engine over the I1 HTTP transport.
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── GENUINE — the human-on-phone unmocked proof is I5's sole gate (batching directive) ──"
note "I4 closes on the wiring proven LIVE (PART A) + against the byte-identical"
note "production engine (PART B). The phone answer is stood in via the EXACT"
note "deployed item-apply front; the return PATH (poll → observe → capture →"
note "S-2 flip → reconcile → resume splice) is exercised UNMOCKED end to end."

# ════════════════════════════════════════════════════════════════════════════
# PART A — LIVE deployed coordinator-cf: the by-design 401 posture. The PARK
#          still raises the LOCAL S-2 record; the return-leg READ hop REACHES
#          the real engine and 401s ⇒ the fork stays PARKED (no false resume).
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART A — LIVE deployed coordinator-cf · the return-leg READ 401 posture ──"
echo "   target: $LIVE_URL  (no real token — the by-design D0 withholding)"
(
  set +u
  WA="$(mktemp -d)"
  export CO_STORE="$WA/store"; export LOG_DIR="$WA/logs"; mkdir -p "$LOG_DIR"
  export COORDINATOR_URL="$LIVE_URL"
  unset COORDINATOR_TOKEN CO_EXPECTED_TOKEN 2>/dev/null || true
  source "$HERE/stuck-routing.sh"
  source "$HERE/co-http-transport.sh"    # OVERRIDE: co_request now HTTP→LIVE

  # §7.3 PARK (the same as I3 PART A): a fired backstop raises the LOCAL S-2
  # control record even though the hosted dossier write 401s.
  did="$(sr_route_stuck "$PLACEHOLDER" "$FIXTURE" "backstop:permission_denials" \
          "$(sr_worker_ask "$FIXTURE" 2>/dev/null)" 2>/dev/null)"
  echo "A_DID=$did"
  [[ -f "$CO_STORE/blocked-for-human/$FIXTURE.json" ]] && echo "A_BFH=present" || echo "A_BFH=absent"
  echo "A_BFH_RESOLVED0=$(jq -r '.resolved' "$CO_STORE/blocked-for-human/$FIXTURE.json" 2>/dev/null)"

  # the I4 return-leg READ surface, probed at the §2.1 `co_request get dossier`
  # boundary the poll uses (the I3 PART A discipline, on the READ verb): the
  # hop REACHES the LIVE engine and returns the bash-contract 401
  # (rc1/empty/"co: 401" — I0 D1/D2/D3 closed by I1).
  of="$(mktemp)"; ef="$(mktemp)"
  co_request "$PLACEHOLDER" get dossier "$did" >"$of" 2>"$ef"; crc=$?
  echo "A_GETCO_RC=$crc"
  [[ -s "$of" ]] && echo "A_GETCO_STDOUT=nonempty" || echo "A_GETCO_STDOUT=empty"
  grep -q "co: 401" "$ef" && echo "A_GETCO_STDERR=co401" || echo "A_GETCO_STDERR=other"
  # the wrapper the poll actually calls: do_dossier_get maps the 401 to its
  # own rc1/empty contract (it suppresses co_request stderr by design — the
  # poll keys on rc, never on a parsed envelope).
  : > "$of"
  do_dossier_get "$PLACEHOLDER" "$did" >"$of" 2>/dev/null; grc=$?
  echo "A_GETDOS_RC=$grc"
  [[ -s "$of" ]] && echo "A_GETDOS_STDOUT=nonempty" || echo "A_GETDOS_STDOUT=empty"
  rm -f "$of" "$ef"

  # the AWAIT under the live 401: the fork must stay PARKED — NOT falsely
  # resumed (the success/answer is token-gated → I5).
  pn="$(sr_poll_hosted_resolution "$PLACEHOLDER" "$FIXTURE" 2>/dev/null)"
  echo "A_POLL_N=$pn"
  echo "A_BFH_RESOLVED1=$(jq -r '.resolved' "$CO_STORE/blocked-for-human/$FIXTURE.json" 2>/dev/null)"
  [[ -f "$CO_STORE/blocked-for-human-answer/$FIXTURE.json" ]] && echo "A_ANSWER=present" || echo "A_ANSWER=absent"
  sr_resume_answer "$FIXTURE" >/dev/null 2>&1 && echo "A_RESUME=present" || echo "A_RESUME=absent"
  rm -rf "$WA"
) > "$HERE/../.i4-a.txt" 2>/dev/null
ag(){ grep -o "$1=[A-Za-z0-9_.:-]*" "$HERE/../.i4-a.txt" 2>/dev/null | head -1 | cut -d= -f2; }
eq "$(ag A_DID)" "stuck-$FIXTURE" "§7.3 PARK: sr_route_stuck echoes the deterministic dossier id even under a hosted 401"
eq "$(ag A_BFH)" "present" "§7.3 fork-must-not-rot: the LOCAL S-2 blocked-for-human record is raised despite the hosted-write 401"
eq "$(ag A_BFH_RESOLVED0)" "false" "the parked S-2 record is {resolved:false} (awaiting the human decision)"
eq "$(ag A_GETCO_RC)" "1" "the return-leg READ at the §2.1 co_request boundary ⇒ rc 1 against the LIVE engine (bash 401 rc — I0 D1 closed)"
eq "$(ag A_GETCO_STDOUT)" "empty" "live return-leg READ 401 ⇒ EMPTY stdout (no envelope leaks to the reused parse — I0 D2/D3 closed)"
eq "$(ag A_GETCO_STDERR)" "co401" "live return-leg READ 401 ⇒ diagnostic on STDERR (the return path REACHES the deployed engine)"
eq "$(ag A_GETDOS_RC)" "1" "the do_dossier_get wrapper the poll calls maps the live 401 to rc 1 (the poll keys on rc, never a parsed envelope)"
eq "$(ag A_GETDOS_STDOUT)" "empty" "the do_dossier_get wrapper ⇒ EMPTY stdout under the live 401 (the poll correctly observes nothing to resolve)"
eq "$(ag A_POLL_N)" "0" "the AWAIT under the live 401 resolves NOTHING (the fork stays PARKED — success is token-gated → I5)"
eq "$(ag A_BFH_RESOLVED1)" "false" "after the poll the S-2 record is STILL {resolved:false} (no false resume on an unreachable engine)"
eq "$(ag A_ANSWER)" "absent" "NO answer captured under the 401 (the parked agent must not resume without a real decision)"
eq "$(ag A_RESUME)" "absent" "sr_resume_answer yields nothing (the §7.3 must-not-rot discipline mirrored on the return leg)"
rm -f "$HERE/../.i4-a.txt" 2>/dev/null

# ════════════════════════════════════════════════════════════════════════════
# PART B — LOCAL byte-identical engine: the FULL closed loop, ≡ the bash oracle
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART B — local BYTE-IDENTICAL engine · the full park→answer→resume loop ──"
if [[ ! -x "$WRANGLER" ]]; then
  bad "wrangler not found at $WRANGLER (run: npm ci in beads-runner/cf) — PART B SKIPPED"
else
  PORT="${I4_TEST_PORT:-8804}"
  ENGINE="http://127.0.0.1:$PORT"
  GOOD="i4-test-bearer-$$"
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

    # a STATEFUL `bd` fake on PATH (the established T5.5 test precedent —
    # test-stuck-routing.sh) so the existing S-2 reconcile's bead lift
    # (blocked→open) is OBSERVABLE. The fake bd is NOT a mock of the I4 code
    # under test (the poll really reads the byte-identical engine over HTTP) —
    # it stands in only for the work-plane CLI, exactly as the frozen
    # reconcile test does.
    FAKEBIN="$STATE_DIR/bin"; mkdir -p "$FAKEBIN"
    cat > "$FAKEBIN/bd" <<'BDEOF'
#!/bin/bash
cmd="${1:-}"; shift || true
case "$cmd" in
  update)
    id="${1:-}"; shift || true
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --status=*) printf '%s' "${1#--status=}" > "${BDST}/$id"; shift;;
        --status)   printf '%s' "${2:-}"        > "${BDST}/$id"; shift 2;;
        *) shift;;
      esac
    done ;;
  human) : ;;
  show)
    id="${1:-}"; s="open"; [[ -f "${BDST}/$id" ]] && s="$(cat "${BDST}/$id")"
    jq -cn --arg id "$id" --arg s "$s" '[{id:$id,status:$s}]' ;;
  *) : ;;
esac
exit 0
BDEOF
    chmod +x "$FAKEBIN/bd"
    # The option label is a single hyphen-joined token ON PURPOSE: the test's
    # line-oriented `bg()`/`og()` extraction (and the ≡-oracle compare) carries
    # the value faithfully. The label still proves the point — it is resolved
    # by sr_poll_hosted_resolution FROM THE ITEM'S OWN §5.2 options[] (not from
    # the bare response), i.e. the resume directive is self-contained.
    ASK='{"tldr":"Worker hit a product fork it must not resolve.","ask":"Adopt approach A or B for '"$FIXTURE"'?","options":[{"option_id":"a","label":"Approach-A-recommended-reversible","blast_radius":"low-fully-reversible","consequence_block":{"cb_schema_version":2,"creates":[],"unblocks":[],"labels":[],"status_changes":[]}},{"option_id":"b","label":"Approach-B","blast_radius":"medium","consequence_block":{"cb_schema_version":2,"creates":[],"unblocks":[],"labels":[],"status_changes":[]}}],"recommendation":{"value":"a","why":"A is reversible and lower blast radius."},"reversible":"Nothing applied until a human picks (§5.3 = T5.3)."}'

    # ---- WORLD A: in-process bash ORACLE — the behaviour the HTTP path must match
    ( set +u
      W="$(mktemp -d)"; export CO_STORE="$W/store"
      export BDST="$W/bdst"; mkdir -p "$BDST"
      export PATH="$FAKEBIN:$PATH"
      unset COORDINATOR_URL COORDINATOR_TOKEN CO_EXPECTED_TOKEN 2>/dev/null || true
      source "$HERE/stuck-routing.sh"
      source "$HERE/consequence.sh"            # do_item_apply = the bash item-apply
      did="$(sr_route_stuck "$GOOD" "$FIXTURE" worker_stuck "$ASK" 2>/dev/null)"
      echo "orc_did=$did"
      echo "orc_bead_parked=$(cat "$BDST/$FIXTURE" 2>/dev/null)"
      # NEGATIVE: poll BEFORE the answer — the parked agent stays parked.
      echo "orc_poll_pre=$(sr_poll_hosted_resolution "$GOOD" "$FIXTURE" 2>/dev/null)"
      echo "orc_bfh_pre=$(sr_bfh_get "$FIXTURE" | jq -r '.resolved' 2>/dev/null)"
      # the PHONE ANSWER stand-in (bash equivalent of op=item-apply):
      do_item_apply "$GOOD" "$did" "${did}-d1" '{"decision":"pick","selected_option_id":"a"}' >/dev/null 2>&1
      d="$(co_request "$GOOD" get dossier "$did" 2>/dev/null)"
      echo "orc_item_state=$(printf '%s' "$d" | jq -r '.items[0].state' 2>/dev/null)"
      echo "orc_rollup=$(do_dossier_rollup "$d" 2>/dev/null)"
      # the AWAIT observes it:
      echo "orc_poll_post=$(sr_poll_hosted_resolution "$GOOD" "$FIXTURE" 2>/dev/null)"
      echo "orc_bfh_post=$(sr_bfh_get "$FIXTURE" | jq -r '.resolved' 2>/dev/null)"
      echo "orc_chosen=$(sr_resume_answer "$FIXTURE" | jq -r '.chosen' 2>/dev/null)"
      echo "orc_chosen_label=$(sr_resume_answer "$FIXTURE" | jq -r '.chosen_label' 2>/dev/null)"
      # the existing S-2 reconcile lifts the bead (blocked→open):
      sr_reconcile_blocked_for_human "$GOOD" "$FIXTURE" >/dev/null 2>&1
      echo "orc_bead_lifted=$(cat "$BDST/$FIXTURE" 2>/dev/null)"
      # idempotent re-poll:
      echo "orc_poll_idem=$(sr_poll_hosted_resolution "$GOOD" "$FIXTURE" 2>/dev/null)"
      rm -rf "$W"
    ) > "$STATE_DIR/oracle.txt" 2>/dev/null
    og(){ grep -o "$1=[A-Za-z0-9_.:@+-]*" "$STATE_DIR/oracle.txt" 2>/dev/null | head -1 | cut -d= -f2; }
    note "bash oracle: park($FIXTURE)→$(og orc_bead_parked); pre-poll=$(og orc_poll_pre)/bfh=$(og orc_bfh_pre); answer⇒item=$(og orc_item_state) rollup=$(og orc_rollup); post-poll=$(og orc_poll_post)/bfh=$(og orc_bfh_post) chose '$(og orc_chosen)'; reconcile⇒$(og orc_bead_lifted); idem=$(og orc_poll_idem)"

    # ---- WORLD B: the I4 return path over HTTP → the byte-identical engine ----
    ( set +u
      W="$(mktemp -d)"; export CO_STORE="$W/store"; export LOG_DIR="$W/logs"; mkdir -p "$W/logs"
      export BDST="$W/bdst"; mkdir -p "$BDST"
      export PATH="$FAKEBIN:$PATH"
      export COORDINATOR_URL="$ENGINE"; export COORDINATOR_TOKEN="$GOOD"
      unset CO_EXPECTED_TOKEN 2>/dev/null || true
      source "$HERE/stuck-routing.sh"
      source "$HERE/co-http-transport.sh"     # OVERRIDE → HTTP → the local engine

      # §7.3 PARK — the genuine stuck routes a Dossier into the hosted engine
      # and drives the bead blocked (fake bd) + raises the S-2 record.
      did="$(sr_route_stuck "$GOOD" "$FIXTURE" worker_stuck "$ASK" 2>/dev/null)"
      echo "T_did=$did"
      echo "T_bead_parked=$(cat "$BDST/$FIXTURE" 2>/dev/null)"

      # NEGATIVE: the parked runner polls BEFORE Brian answers — it observes the
      # hosted Dossier over HTTP, sees NO answered Item, and correctly does NOT
      # resume (the parked agent stays parked).
      echo "T_poll_pre=$(sr_poll_hosted_resolution "$GOOD" "$FIXTURE" 2>/dev/null)"
      echo "T_bfh_pre=$(sr_bfh_get "$FIXTURE" | jq -r '.resolved' 2>/dev/null)"
      echo "T_ans_pre=$(sr_resume_answer "$FIXTURE" >/dev/null 2>&1 && echo present || echo absent)"

      # THE PHONE ANSWER — the EXACT deployed front: web/functions/api/inbox/
      # respond.js POSTs {dossier_id,item_id,response} to the FROZEN literal
      # op `item-apply` upstream. This curl IS that upstream POST verbatim
      # (programmatic stand-in permitted for I4's OWN verification only).
      ap="$(curl -sS -m 20 -X POST -H "authorization: Bearer $GOOD" \
             -H 'content-type: application/json' \
             --data '{"dossier_id":"'"$did"'","item_id":"'"$did"'-d1","response":{"decision":"pick","selected_option_id":"a"}}' \
             "$ENGINE/request?op=item-apply" 2>/dev/null)"
      echo "T_apply_ok=$(printf '%s' "$ap" | jq -e '.' >/dev/null 2>&1 && echo yes || echo no)"

      # the EXACT deployed-Inbox phone READ front shows the Item now applied
      # (the same hosted engine the phone reads reflects the answer).
      ib="$(curl -sS -m 20 -H "authorization: Bearer $GOOD" \
             "$ENGINE/request?op=get&type=dossier&id=$did" 2>/dev/null)"
      echo "IB_item_state=$(printf '%s' "$ib" | jq -r '.items[0].state' 2>/dev/null)"

      # the AWAIT — the parked runner's poll READS it back over HTTP and
      # observes the resolution; captures the decision; flips S-2.
      echo "T_poll_post=$(sr_poll_hosted_resolution "$GOOD" "$FIXTURE" 2>/dev/null)"
      echo "T_bfh_post=$(sr_bfh_get "$FIXTURE" | jq -r '.resolved' 2>/dev/null)"
      echo "T_chosen=$(sr_resume_answer "$FIXTURE" | jq -r '.chosen' 2>/dev/null)"
      echo "T_chosen_label=$(sr_resume_answer "$FIXTURE" | jq -r '.chosen_label' 2>/dev/null)"
      echo "T_item_state=$(co_request "$GOOD" get dossier "$did" 2>/dev/null | jq -r '.items[0].state' 2>/dev/null)"
      echo "T_rollup=$(do_dossier_rollup "$(co_request "$GOOD" get dossier "$did" 2>/dev/null)" 2>/dev/null)"

      # the RESUME directive the runner splices — must carry the human's choice.
      DIR="$(sr_format_resume_directive "$FIXTURE" 2>/dev/null)"
      printf '%s' "$DIR" | grep -q 'HUMAN DECISION' && echo "T_dir_hdr=yes" || echo "T_dir_hdr=no"
      printf '%s' "$DIR" | grep -q 'Approach-A-recommended-reversible' && echo "T_dir_choice=yes" || echo "T_dir_choice=no"
      printf '%s' "$DIR" | grep -q 'NOT re-raise the fork' && echo "T_dir_noreraise=yes" || echo "T_dir_noreraise=no"

      # the existing S-2 reconcile LIFTS the parked bead (blocked→open) ⇒ it
      # re-enters `bd ready` and the runner re-dispatches it WITH the decision.
      sr_reconcile_blocked_for_human "$GOOD" "$FIXTURE" >/dev/null 2>&1
      echo "T_bead_lifted=$(cat "$BDST/$FIXTURE" 2>/dev/null)"

      # idempotent: a second poll resolves nothing new (no double-resume).
      echo "T_poll_idem=$(sr_poll_hosted_resolution "$GOOD" "$FIXTURE" 2>/dev/null)"
      rm -rf "$W"
    ) > "$STATE_DIR/worldb.txt" 2>/dev/null
    B="$STATE_DIR/worldb.txt"
    bg(){ grep -o "$1=[A-Za-z0-9_.:@+-]*" "$B" 2>/dev/null | head -1 | cut -d= -f2; }

    # ---- the closed loop over HTTP, end to end ----
    eq "$(bg T_did)" "stuck-$FIXTURE" "§7.3 PARK: the genuine stuck routes ONE Dossier to the hosted engine"
    eq "$(bg T_bead_parked)" "blocked" "§7.3 PARK: the bead is driven blocked-for-human (parked out of the ready set)"
    eq "$(bg T_poll_pre)" "0" "NEGATIVE: a poll BEFORE the phone answer resolves NOTHING (the parked agent stays parked)"
    eq "$(bg T_bfh_pre)" "false" "NEGATIVE: the S-2 record is still {resolved:false} before the answer"
    eq "$(bg T_ans_pre)" "absent" "NEGATIVE: no resume-answer captured before the human decides"
    eq "$(bg T_apply_ok)" "yes" "THE PHONE ANSWER lands via the EXACT deployed front (POST /request?op=item-apply — what respond.js forwards)"
    eq "$(bg IB_item_state)" "applied" "the same hosted engine the PHONE READS (GET ?op=get&type=dossier) shows the Item applied"
    eq "$(bg T_poll_post)" "1" "the AWAIT: the parked runner's poll OBSERVES the answer over HTTP (1 fork newly resolved)"
    eq "$(bg T_bfh_post)" "true" "the poll flips the S-2 record resolved:true (the control→work lift is now armed)"
    eq "$(bg T_chosen)" "a" "the captured decision is the human's chosen option_id ('a')"
    eq "$(bg T_chosen_label)" "Approach-A-recommended-reversible" "the captured decision resolves the option LABEL from the Item's own §5.2 options[] (self-contained — no second hosted fetch)"
    eq "$(bg T_dir_hdr)" "yes" "the RESUME directive renders the HUMAN DECISION header"
    eq "$(bg T_dir_choice)" "yes" "the RESUME directive carries the human's actual choice (Approach-A-recommended-reversible)"
    eq "$(bg T_dir_noreraise)" "yes" "the RESUME directive tells the agent NOT to re-raise the fork (acts on the answer, not the fork)"
    eq "$(bg T_bead_lifted)" "open" "the existing S-2 reconcile LIFTS the parked bead blocked→open ⇒ it re-enters bd ready and RESUMES"
    eq "$(bg T_poll_idem)" "0" "idempotent: a second poll resolves nothing new (no double-resume)"

    # ---- ≡ the in-process bash oracle (the I1 equivalence rule) ----
    eq "$(bg T_item_state)" "$(og orc_item_state)" "hosted item.state over HTTP ≡ the bash oracle ('$(og orc_item_state)')"
    eq "$(bg T_rollup)"     "$(og orc_rollup)"     "hosted dossier rollup over HTTP ≡ the bash oracle ('$(og orc_rollup)')"
    eq "$(bg T_poll_pre)"   "$(og orc_poll_pre)"   "pre-answer poll over HTTP ≡ the bash oracle (both park, resolve 0)"
    eq "$(bg T_poll_post)"  "$(og orc_poll_post)"  "post-answer poll over HTTP ≡ the bash oracle (both observe exactly 1)"
    eq "$(bg T_bfh_post)"   "$(og orc_bfh_post)"   "S-2 resolved flip over HTTP ≡ the bash oracle"
    eq "$(bg T_chosen)"     "$(og orc_chosen)"     "the captured decision over HTTP ≡ the bash oracle ('$(og orc_chosen)')"
    eq "$(bg T_chosen_label)" "$(og orc_chosen_label)" "the captured option label over HTTP ≡ the bash oracle"
    eq "$(bg T_bead_lifted)" "$(og orc_bead_lifted)" "the reconcile bead-lift over HTTP ≡ the bash oracle ('$(og orc_bead_lifted)')"
    eq "$(bg T_poll_idem)"  "$(og orc_poll_idem)"  "the idempotent re-poll over HTTP ≡ the bash oracle"
  fi
fi

# ════════════════════════════════════════════════════════════════════════════
# PART C — production-token auto-detect: the live success hop iff a real token
#          resolves; else SKIP (the by-design I0 D0 withholding → I5).
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART C — LIVE deployed full feedback-return loop (the I5 hop) ──"
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
  note "the return-leg READ hop REACHES the deployed engine (bash-contract 401,"
  note "I0 D1/D2/D3 closed) and the fork correctly stays PARKED; PART B proved"
  note "the FULL closed loop ≡ the bash oracle against the byte-identical engine"
  note "production runs verbatim, the phone answer via the EXACT deployed"
  note "item-apply front. The live run is a zero-code-change credential flip"
  note "consolidated SOLELY into the I5 session (the genuine human-on-phone,"
  note "fully-unmocked proof — Brian answers, the parked agent resumes)."
else
  note "A production token resolves — the LIVE full-loop hop is the I5 session's"
  note "act (a real stuck → a real dossier on Brian's phone → Brian answers →"
  note "the parked agent resumes). I4 does not consume the human touchpoint;"
  note "PART A + PART B already prove the wiring. Deferred to I5 by the"
  note "batching directive (the sole epic-closing gate)."
fi

# ════════════════════════════════════════════════════════════════════════════
# PART D — M5 idle-handoff via the daemon (claude-tools-0ll). With the daemon
#          observing and the workspace runner IDLE (or about to come around to
#          pick the same parked task), the daemon must capture the answer file
#          INTO THE WORKSPACE STORE and emit the structured `idle-handoff:
#          workspace=X bead=Y dossier=Z` observable — and the splice path the
#          runner already carries (PART 0 above proves it is wired) must read
#          that file back as the HUMAN DECISION block the resumed agent sees.
#          The test uses the in-process bash store (no COORDINATOR_URL ⇒ no
#          HTTP override) so it is hermetic and runs in seconds. We call the
#          daemon's per-workspace driver directly — equivalent to one tick of
#          the daemon's main loop — without launching a real daemon process.
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART D — M5 idle-handoff end-to-end · daemon poll → answer file → HUMAN DECISION splice (claude-tools-0ll) ──"
DAEMON_DIR="$(cd "$HERE/../daemon" 2>/dev/null && pwd)"
POLL_LIB="$DAEMON_DIR/hosted-resolution-poll.sh"
REG_LIB="$DAEMON_DIR/workspace-registry.sh"
if [[ ! -f "$POLL_LIB" || ! -f "$REG_LIB" ]]; then
  bad "M5 daemon libs missing (need $POLL_LIB and $REG_LIB) — PART D SKIPPED"
else
  # M5 is the LOG line + the idempotent splice path; assert both surface.
  grep -q 'idle-handoff:' "$POLL_LIB" \
    && ok "hosted-resolution-poll.sh declares the M5 structured 'idle-handoff:' observable" \
    || bad "hosted-resolution-poll.sh must emit an 'idle-handoff:' line on the M5 branch"
  grep -q 'M5 (claude-tools-0ll)' "$POLL_LIB" \
    && ok "hosted-resolution-poll.sh marks the M5 branch (claude-tools-0ll) so a reader can trace the wiring" \
    || bad "hosted-resolution-poll.sh must cite claude-tools-0ll on the M5 branch"

  (
    set +u
    WD="$(mktemp -d)"
    WS="$WD/workspace"
    mkdir -p "$WS/.beads/runner-logs"
    WS_STORE="$WS/.beads/runner-logs/.co-store"
    mkdir -p "$WS_STORE/records" "$WS_STORE/blocked-for-human" "$WS_STORE/blocked-for-human-answer"

    # Shadow `bd` so the daemon's reconcile (which the per-workspace poll also
    # runs) is a no-op — same precedent as test-m4-hosted-resolution-poll.sh
    # PART B and lib/test-i4 PART B oracle. The fake bd is NOT a mock of the
    # M5 code under test (the daemon really captures the answer + emits the
    # log line); it only stands in for the work-plane CLI so we can inspect
    # the bfh observable without the reconcile deleting it on us.
    FAKEBIN="$WD/bin"; mkdir -p "$FAKEBIN"
    cat > "$FAKEBIN/bd" <<'BDEOF'
#!/bin/bash
exit 0
BDEOF
    chmod +x "$FAKEBIN/bd"
    export PATH="$FAKEBIN:$PATH"

    FIXTURE="tools-m5test"
    DID="stuck-$FIXTURE"
    NOW="2026-05-20T00:00:00Z"

    # Seed a parked S-2 bfh record (the SOURCE OF TRUTH the poll keys on).
    jq -cn --arg tr "$FIXTURE" --arg d "$DID" --arg at "$NOW" \
      '{task_ref:$tr,dossier_id:$d,principal:"brian",
        trigger:"backstop:permission_denials",
        raised_at:$at,resolved:false,resolved_at:null}' \
      > "$WS_STORE/blocked-for-human/$FIXTURE.json"

    # Seed an answered dossier (one item state=answered with a real options[]
    # + response) — exactly what the deployed engine returns after the human
    # answers on the phone via `item-apply`. Schema_version=2 (the dossier
    # bound).
    jq -cn --arg id "$DID" '{
      schema_version:2,id:$id,kind:"worker_stuck",principal:"brian",
      body:{},
      items:[{
        id:"d1",kind:"pick-option",state:"answered",
        framing:{ask:"Adopt approach A or B for tools-m5test?"},
        options:[
          {option_id:"a",label:"Approach-A-recommended-reversible",
           blast_radius:"low-fully-reversible",
           consequence_block:{cb_schema_version:2,creates:[],unblocks:[],labels:[],status_changes:[]}},
          {option_id:"b",label:"Approach-B",
           blast_radius:"medium",
           consequence_block:{cb_schema_version:2,creates:[],unblocks:[],labels:[],status_changes:[]}}
        ],
        response:{decision:"pick",selected_option_id:"a"}
      }]}' > "$WS_STORE/records/dossier.$DID.json"

    # IDLE workspace: live pidfile (this shell's own pid) + last heartbeat
    # actual=idle. This is the M5 "easy path" — no current_task_ref, splice
    # picks it up on the next loop top.
    echo "$$" > "$WS/.beads/runner-logs/detached-runner.pid"
    printf '%s\n' '{"report":"heartbeat","actual":"idle","observed_at":"2026-05-20T00:00:05Z"}' \
      > "$WS/.beads/runner-logs/coordinator-outbox.jsonl"

    # Build a one-entry registry pointing at this workspace.
    REG="$WD/workspaces.json"
    jq -cn --arg dir "$WS" --arg pref "claude-tools-m5test" \
      '{workspaces:[{project_ref:$pref,dir:$dir,coordinator_url:"",coordinator_token_keychain:""}]}' \
      > "$REG"

    # shellcheck source=/dev/null
    . "$REG_LIB"
    # shellcheck source=/dev/null
    . "$POLL_LIB"
    registry_load "$REG" >/dev/null 2>&1 || { echo "D_REG=fail"; rm -rf "$WD"; exit 0; }

    # ONE TICK of the daemon's main loop, captured. The function emits the M4
    # dispatch line + the M5 idle-handoff line on stderr-via-log() (no log()
    # in this scope ⇒ the printf fallback writes to stdout).
    OUT="$(daemon_poll_workspace_hosted_resolution 0 2>&1)"
    printf '%s\n' "$OUT" > "$WD/tick.log"
    echo "D_TICK_HAS_M4=$(grep -q 'M4 dispatch' "$WD/tick.log" && echo yes || echo no)"
    echo "D_TICK_HAS_IDLE=$(grep -q 'idle-handoff:' "$WD/tick.log" && echo yes || echo no)"
    echo "D_TICK_HAS_WS=$(grep -q "workspace=$WS" "$WD/tick.log" && echo yes || echo no)"
    echo "D_TICK_HAS_BEAD=$(grep -q "bead=$FIXTURE" "$WD/tick.log" && echo yes || echo no)"
    echo "D_TICK_HAS_DID=$(grep -q "dossier=$DID" "$WD/tick.log" && echo yes || echo no)"
    echo "D_TICK_HAS_RUNNER_IDLE=$(grep -q 'runner_state=idle' "$WD/tick.log" && echo yes || echo no)"

    ANS="$WS_STORE/blocked-for-human-answer/$FIXTURE.json"
    [[ -f "$ANS" ]] && echo "D_ANS=present" || echo "D_ANS=absent"
    if [[ -f "$ANS" ]]; then
      echo "D_ANS_TREF=$(jq -r '.task_ref' "$ANS" 2>/dev/null)"
      echo "D_ANS_CHOSEN=$(jq -r '.chosen' "$ANS" 2>/dev/null)"
      echo "D_ANS_LABEL=$(jq -r '.chosen_label' "$ANS" 2>/dev/null)"
    fi

    # And — the heart of the acceptance — the SAME splice path the runner uses
    # (sr_format_resume_directive, which reads $CO_STORE/blocked-for-human-
    # answer/<tref>.json) renders the HUMAN DECISION block from the file the
    # daemon captured. This is "the workspace runner re-picks the bead and the
    # prompt contains the HUMAN DECISION block" without launching claude -p.
    (
      set +u
      export CO_STORE="$WS_STORE"
      # shellcheck source=/dev/null
      . "$HERE/stuck-routing.sh"
      DIR="$(sr_format_resume_directive "$FIXTURE" 2>/dev/null)"
      printf '%s' "$DIR" | grep -q 'HUMAN DECISION' && echo "D_DIR_HDR=yes" || echo "D_DIR_HDR=no"
      printf '%s' "$DIR" | grep -q 'Approach-A-recommended-reversible' && echo "D_DIR_CHOICE=yes" || echo "D_DIR_CHOICE=no"
      printf '%s' "$DIR" | grep -q 'NOT re-raise the fork' && echo "D_DIR_NOREraise=yes" || echo "D_DIR_NOREraise=no"
    )

    # Idempotent — a SECOND tick must not re-emit a stale idle-handoff for the
    # same already-captured answer (new_list filtering in the poll keys off
    # before/after listing; verify the contract).
    OUT2="$(daemon_poll_workspace_hosted_resolution 0 2>&1)"
    printf '%s\n' "$OUT2" > "$WD/tick2.log"
    echo "D_TICK2_HAS_IDLE=$(grep -q 'idle-handoff:' "$WD/tick2.log" && echo yes || echo no)"

    rm -rf "$WD"
  ) > "$HERE/../.i4-d.txt" 2>/dev/null
  dg(){ grep -o "$1=[A-Za-z0-9_./:-]*" "$HERE/../.i4-d.txt" 2>/dev/null | head -1 | cut -d= -f2; }

  eq "$(dg D_TICK_HAS_M4)"           "yes" "M4 dispatch line still emitted under the M5 branch (regression guard)"
  eq "$(dg D_TICK_HAS_IDLE)"         "yes" "M5 daemon emits the structured 'idle-handoff:' observable on the IDLE workspace branch"
  eq "$(dg D_TICK_HAS_WS)"           "yes" "idle-handoff carries the WORKSPACE path (operator can disambiguate across N workspaces)"
  eq "$(dg D_TICK_HAS_BEAD)"         "yes" "idle-handoff carries the PARKED BEAD (task_ref)"
  eq "$(dg D_TICK_HAS_DID)"          "yes" "idle-handoff carries the DOSSIER id (the §2.1 record the human answered)"
  eq "$(dg D_TICK_HAS_RUNNER_IDLE)"  "yes" "M4 dispatch line still records runner_state=idle (the M5 branch fires only when the runner is idle/parked)"
  eq "$(dg D_ANS)"                   "present" "the answer file landed at the WORKSPACE'S CO_STORE/blocked-for-human-answer/ — the EXACT path sr_format_resume_directive reads"
  eq "$(dg D_ANS_TREF)"              "tools-m5test" "the captured answer is bound to the parked bead (task_ref=tools-m5test)"
  eq "$(dg D_ANS_CHOSEN)"            "a" "the captured decision is the human's chosen option_id"
  eq "$(dg D_ANS_LABEL)"             "Approach-A-recommended-reversible" "chosen_label resolved from the item's own §5.2 options[] (self-contained — no second hosted fetch at resume)"
  eq "$(dg D_DIR_HDR)"               "yes" "sr_format_resume_directive (the runner's splice — run-beads-tasks.sh:875-888) renders the HUMAN DECISION block from the daemon-captured file"
  eq "$(dg D_DIR_CHOICE)"            "yes" "the resumed worker prompt carries the human's actual choice (Approach-A-recommended-reversible) — 'demonstrably changes what the parked agent does next'"
  eq "$(dg D_DIR_NOREraise)"         "yes" "the resumed worker prompt tells the agent NOT to re-raise the fork (acts on the answer, not the fork)"
  eq "$(dg D_TICK2_HAS_IDLE)"        "no"  "idempotent: a SECOND daemon tick on the same captured answer does NOT re-emit idle-handoff (new-list filtering holds)"
  rm -f "$HERE/../.i4-d.txt" 2>/dev/null
fi

echo ""
echo "════════════════════════════════════════════════════════════════════════"
printf '  RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "════════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
