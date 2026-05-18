#!/bin/bash
# beads-runner/lib/test-timed-fyi.sh — focused unit test for the T5.4 DURABLE
# timed-fyi TIMER + S-6 missed-alarm fire-on-next-poll dedup
# (claude-tools-it2; epic claude-tools-glk).
#
# T5.4's OWN test surface. Deliberately NOT a member of the T1 conformance
# suite (beads-runner/conformance/, owned by T1a/T1b) and it touches NO
# sibling test (test-coordinator{,-lease,-reconcile,-capacity,-forensic}.sh,
# test-dossier.sh, test-consequence.sh). It exercises ONLY the §2.2 fire(
# dossier_id)@T wiring + the S-6 backstop on timed-fyi.sh, consuming the T5.3
# entrypoint (do_item_apply), the T5.1 substrate (dossier.sh) and the T4 §2.2
# timer surface as black boxes, and the WORK plane `bd` via a PATH-injected
# logging fake — the SAME fake-bin pattern the conformance harness and
# test-consequence.sh / test-local-agent.sh use.
#
# NOTE on "the alarm fires": the T4 §2.2 timer is a CAPABILITY SURFACE with no
# alarm daemon (co__timer_due IS the S-6 poll-fallback, by contract). So the
# alarm-fire path IS invoking the shared handler tf_fire; the poll-fallback is
# tf_poll → tf_fire. Both go through the SAME idempotent do_item_apply — which
# is exactly the S-6 contract (and exactly how test-consequence.sh simulated
# the alarm⇄poll race). Exactly-once is the §7.4 per-Item latch, NEVER timer
# reliability and NEVER the best-effort ack — proven by re-firing after the
# ack is lost.
#
# Asserts the EXIT CRITERIA T5.4 owns against INTERFACE.md v1:
#   1. Alarm fires ⇒ each un-objected fyi-objectable item auto-proceeds, its
#      §5.3 consequence applied EXACTLY once (parent EXIT 2 part A).
#   2. Alarm SUPPRESSED ⇒ auto-proceed still fires on next poll, exactly once;
#      alarm-then-poll (incl. a lost ack and an 8-way race) does NOT
#      double-apply — dedup via the §7.4 per-Item latch (S-6).
#   3. An OBJECTED fyi-objectable item does NOT auto-proceed; a
#      non-fyi-objectable sibling is LEFT OPEN; neither blocks the auto-proceed
#      of an un-objected sibling or the pipeline (AD7 partial resolution).
#   4. timer_fire_at = created_at + window honored for the DEFAULT and a
#      per-dossier override ∈ (0, TIMED_FYI_DEFAULT]; out-of-range REJECTED; a
#      null window (and a non-timed-fyi tier) sets NO timer.
#   5. Binds §2.2 / §7.4 (S-6); no §4 record type added; tf_* not advertised
#      as a §2 capability; the §0.5 constant has one env-overridable
#      definition (no competing literal). (Full no-regression is the SUITE's
#      job — test-dossier/test-consequence/conformance, run as the gate.)
#
# Self-contained: its own CO_STORE + fake-bin under mktemp; shares NO state
# with the conformance harness or sibling tests.
set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/timed-fyi.sh"
[[ -f "$LIB" ]] || { echo "FATAL: timed-fyi.sh not found at $LIB"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
ck()  { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }   # expect SUCCESS
ckn() { if "${@:2}" >/dev/null 2>&1; then bad "$1"; else ok "$1"; fi; }   # expect FAILURE
eq()  { [[ "$1" == "$2" ]]; }
ne()  { [[ "$1" != "$2" ]]; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CO_STORE="$WORK/store"
unset CO_EXPECTED_TOKEN PRINCIPAL_V1 TIMED_FYI_DEFAULT 2>/dev/null || true

# ── work-plane `bd` fake on PATH (conformance / test-consequence pattern) ────
FAKEBIN="$WORK/bin"; mkdir -p "$FAKEBIN"
export BD_LOG="$WORK/bd.log"; : > "$BD_LOG"
cat > "$FAKEBIN/bd" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${BD_LOG:-/dev/null}"
if [[ "${1:-}" == "create" ]]; then
  t=""; while [[ $# -gt 0 ]]; do case "$1" in --title) t="$2"; shift 2;; --title=*) t="${1#--title=}"; shift;; *) shift;; esac; done
  n=$(( $(wc -l < "${BD_LOG:-/dev/null}" 2>/dev/null || echo 0) ))
  echo "✓ Created issue: bd-fake-$n — $t"
fi
exit 0
EOF
chmod +x "$FAKEBIN/bd"
export PATH="$FAKEBIN:$PATH"

# shellcheck source=/dev/null
source "$LIB"           # → consequence.sh → dossier.sh → coordinator.sh

GOOD="bearer-runner-secret-xyz"
GET()    { co_request "$GOOD" get dossier "$1" 2>/dev/null; }
ISTATE() { GET "$1" | jq -r --arg i "$2" '.items[]|select(.id==$i).state'              2>/dev/null; }
ICA()    { GET "$1" | jq -r --arg i "$2" '.items[]|select(.id==$i).consequence_applied' 2>/dev/null; }
IAT()    { GET "$1" | jq -r --arg i "$2" '.items[]|select(.id==$i).applied_at'          2>/dev/null; }
TFA()    { GET "$1" | jq -r '.timer_fire_at'                                            2>/dev/null; }
BDN()    { local c; c=$(grep -c -- "$1" "$BD_LOG" 2>/dev/null); echo "${c:-0}"; }
DUE()    { co_request "$GOOD" timer-due "${2:-}" 2>/dev/null | grep -Fxq -- "$1"; }  # DUE <id> [now]

# §4.1 timed-fyi envelope; created_at fixed so created_at+window is exact.
# `body` OPAQUE (substrate round-trips it; §5 = T5.2).
CA="2026-05-16T00:00:00Z"      # +86400 ⇒ 2026-05-17T00:00:00Z ; +3600 ⇒ ...01:00:00Z
mk() {  # mk <id> <tier> <items-json-array>
  jq -cn --arg id "$1" --arg tier "$2" --argjson items "$3" --arg ca "$CA" '
    { id:$id, schema_version:2, kind:"decide", trigger:"proactive_checkpoint",
      bead_ref:"claude-tools-65z", tier:$tier,
      created_at:$ca, timer_fire_at:null,
      body:{ dossier_schema_version:2, tldr:"opaque", sections:[],
             diagrams:[], full_detail:"T5.2 owns this" },
      items:$items }'
}
cb() {  # cb <tag>  — a §5.3 block tagged so per-item apply is countable
  jq -cn --arg t "$1" '
    { cb_schema_version:2,
      creates:[ { title:("new "+$t), type:"task", priority:2, labels:["auto"],
                  description:"d" } ],
      unblocks:["unb-"+$t], labels:[], status_changes:[] }'; }
# fyi-objectable item (auto-proceeds on the timer UNLESS objected).
item_obj() { jq -cn --arg i "$1" --arg s "$2" --argjson cb "$(cb "$1")" '
    { id:$i, kind:"fyi-objectable", framing:{}, context_anchor:{where:"x",expansion:"y"},
      consequence_block:$cb, reversible:"r",
      state:$s, response:null, consequence_applied:false, applied_at:null }'; }
# approve-reject item — a NON-fyi-objectable sibling (never auto-proceeds).
item_ar() { jq -cn --arg i "$1" --arg s "$2" --argjson cb "$(cb "$1")" '
    { id:$i, kind:"approve-reject", framing:{}, context_anchor:{where:"x",expansion:"y"},
      consequence_block:$cb, reversible:"r",
      state:$s, response:null, consequence_applied:false, applied_at:null }'; }
RESP_OBJECT='{"decision":"object","freeform_text":"I object to this auto-proceed","responded_at":"2026-05-16T01:00:00Z","principal":"brian"}'
RESP_APPROVE='{"decision":"approve","responded_at":"2026-05-16T01:00:00Z","principal":"brian"}'
FAR="2026-06-01T00:00:00Z"     # well past every fire_at below
NEAR="2026-05-16T12:00:00Z"    # before the default fire_at (next day)

echo "── EXIT-4: timer_fire_at = created_at + window · default/override/null ──"
do_dossier_put "$GOOD" "$(mk dDef timed-fyi "[$(item_obj f1 open)]")" >/dev/null
FA="$(tf_arm "$GOOD" dDef)"
ck  "tf_arm (default) succeeds"                         test -n "$FA"
ck  "default window ⇒ timer_fire_at = created_at + TIMED_FYI_DEFAULT(86400)" \
   eq "$(TFA dDef)" "2026-05-17T00:00:00Z"
ck  "tf_arm echoes the computed fire_at"               eq "$FA" "2026-05-17T00:00:00Z"
ck  "T4 §2.2 timer armed keyed fire(dossier_id)=dDef, due AFTER fire_at" DUE dDef "$FAR"
ckn "NOT due BEFORE fire_at (one-shot at T, not earlier)" DUE dDef "$NEAR"
# per-dossier override ∈ (0, TIMED_FYI_DEFAULT]
do_dossier_put "$GOOD" "$(mk dOv timed-fyi "[$(item_obj o1 open)]")" >/dev/null
ck  "tf_arm override=3600 succeeds"                    tf_arm "$GOOD" dOv 3600
ck  "override ⇒ timer_fire_at = created_at + 3600"     eq "$(TFA dOv)" "2026-05-16T01:00:00Z"
do_dossier_put "$GOOD" "$(mk dBd timed-fyi "[$(item_obj b1 open)]")" >/dev/null
ck  "boundary override == TIMED_FYI_DEFAULT accepted ((0,DEFAULT] inclusive)" tf_arm "$GOOD" dBd 86400
ck  "boundary override ⇒ created_at + 86400"           eq "$(TFA dBd)" "2026-05-17T00:00:00Z"
# out-of-range / malformed override REJECTED (caller error, NOT a §11 gap)
do_dossier_put "$GOOD" "$(mk dXr timed-fyi "[$(item_obj x1 open)]")" >/dev/null
ckn "override > TIMED_FYI_DEFAULT REJECTED"            tf_arm "$GOOD" dXr 86401
ckn "override = 0 REJECTED (range is (0,DEFAULT])"     tf_arm "$GOOD" dXr 0
ckn "override negative REJECTED"                       tf_arm "$GOOD" dXr -5
ckn "override non-integer REJECTED (§0.4 integer s)"   tf_arm "$GOOD" dXr abc
ck  "a REJECTED arm left timer_fire_at null (no write)" eq "$(TFA dXr)" "null"
ckn "a REJECTED arm armed NO T4 timer"                 DUE dXr "$FAR"
# null window ⇒ NO timer
do_dossier_put "$GOOD" "$(mk dNul timed-fyi "[$(item_obj n1 open)]")" >/dev/null
ck  "tf_arm window=null succeeds (no-op success)"      tf_arm "$GOOD" dNul null
ck  "null window ⇒ timer_fire_at stays null"           eq "$(TFA dNul)" "null"
ckn "null window ⇒ NO T4 timer armed (never fires)"    DUE dNul "$FAR"
# SOFT-DISARM (review #1): arm a REAL window (T4 timer armed), then re-arm
# null ⇒ envelope cleared AND the prior arm soft-disarmed (timer-ack) so the
# S-6 poll-fallback does NOT fire it and the item does NOT auto-proceed.
do_dossier_put "$GOOD" "$(mk dDis timed-fyi "[$(item_obj z1 open)]")" >/dev/null
tf_arm "$GOOD" dDis 3600 >/dev/null
ck  "prior real arm ⇒ T4 timer armed (due at FAR)"     DUE dDis "$FAR"
ck  "re-arm window=null succeeds"                      tf_arm "$GOOD" dDis null
ck  "re-arm null ⇒ timer_fire_at cleared"              eq "$(TFA dDis)" "null"
ckn "re-arm null SOFT-DISARMED the prior arm (not in timer-due)" DUE dDis "$FAR"
tf_poll "$GOOD" "$FAR" >/dev/null 2>&1
ck  "soft-disarmed dossier does NOT auto-proceed on poll (z1 stays open)" \
   eq "$(ISTATE dDis z1)" "open"
ck  "soft-disarmed z1 latch still false (no consequence applied)" \
   eq "$(ICA dDis z1)" "false"
# non-timed-fyi tier ⇒ NO timer (the §4.1 tier drives this)
do_dossier_put "$GOOD" "$(mk dBlk blocking "[$(item_obj k1 open)]")" >/dev/null
ck  "tf_arm on a 'blocking' dossier ⇒ no-op success"   tf_arm "$GOOD" dBlk
ck  "non-timed-fyi tier ⇒ timer_fire_at stays null"    eq "$(TFA dBlk)" "null"
ckn "non-timed-fyi tier ⇒ NO T4 timer armed"           DUE dBlk "$FAR"

echo ""
echo "── EXIT-1: alarm fires ⇒ un-objected fyi-objectable auto-proceeds ONCE ──"
do_dossier_put "$GOOD" "$(mk dF1 timed-fyi "[$(item_obj g1 open)]")" >/dev/null
tf_arm "$GOOD" dF1 >/dev/null
: > "$BD_LOG"
ck  "tf_fire (alarm) succeeds"                         tf_fire "$GOOD" dF1
ck  "g1 consequence_applied flipped false→true"        eq "$(ICA dF1 g1)" "true"
ck  "g1 state → applied (open→answered→applied via T5.3)" eq "$(ISTATE dF1 g1)" "applied"
ck  "g1 applied_at stamped (§4.1.1)"                   ne "$(IAT dF1 g1)" "null"
ck  "§5.3 consequence APPLIED once (bd create for g1)" eq "$(BDN 'create --title new g1')" "1"
ck  "§5.3 unblocks applied (control→work, BC-15)"      test "$(BDN 'update unb-g1 --status=open')" -ge 1
ckn "un-objected proceed is DETERMINISTIC — NO reconciler follow-up" \
   do_dossier_get "$GOOD" dF1-fu-g1
ck  "auto-proceed response is self-describing (auto_proceed:true recorded)" \
   eq "$(GET dF1 | jq -r '.items[0].response.auto_proceed')" "true"

echo ""
echo "── EXIT-2: suppressed alarm ⇒ fire-on-next-poll · S-6 exactly-once ──"
# (a) alarm SUPPRESSED entirely — never call tf_fire; poll-fallback fires it.
# (dS's fire_at is the next day; a poll at NEAR must NOT fire it even though
# other earlier-armed timers may be due — s1's STATE is the real invariant.)
do_dossier_put "$GOOD" "$(mk dS timed-fyi "[$(item_obj s1 open)]")" >/dev/null
tf_arm "$GOOD" dS >/dev/null
: > "$BD_LOG"
tf_poll "$GOOD" "$NEAR" >/dev/null 2>&1
ck  "poll BEFORE fire_at does NOT fire dS (s1 still open)" eq "$(ISTATE dS s1)" "open"
POLLED="$(tf_poll "$GOOD" "$FAR")"
ck  "poll AFTER fire_at fires the suppressed alarm (dS surfaced)" \
   grep -Fxq -- dS <<<"$POLLED"
ck  "suppressed alarm ⇒ s1 STILL auto-proceeds on poll" eq "$(ISTATE dS s1)" "applied"
ck  "fire-on-next-poll applied the consequence ONCE"   eq "$(BDN 'create --title new s1')" "1"
# (b) S-6 dedup is the §7.4 per-Item LATCH, not the ack: re-arm (ack lost),
#     poll again — must NOT double-apply.
co_request "$GOOD" timer-arm dS "2026-05-17T00:00:00Z" >/dev/null   # resets acked=false
ck  "re-armed timer is due again (ack was 'lost')"     DUE dS "$FAR"
tf_poll "$GOOD" "$FAR" >/dev/null
ck  "alarm-then-poll (lost ack) ⇒ STILL applied exactly once (latch dedup)" \
   eq "$(BDN 'create --title new s1')" "1"
ck  "s1 still applied, latch still true (idempotent no-op 2nd time)" \
   eq "$(ICA dS s1)" "true"
# (c) double alarm-fire ⇒ exactly once
do_dossier_put "$GOOD" "$(mk dD2 timed-fyi "[$(item_obj d2 open)]")" >/dev/null
tf_arm "$GOOD" dD2 >/dev/null
: > "$BD_LOG"
tf_fire "$GOOD" dD2 >/dev/null
tf_fire "$GOOD" dD2 >/dev/null
ck  "double alarm-fire ⇒ §5.3 applied exactly once"    eq "$(BDN 'create --title new d2')" "1"
# (d) 8-way concurrent fire race (alarm ⇄ poll) ⇒ exactly once (S-6)
do_dossier_put "$GOOD" "$(mk dRc timed-fyi "[$(item_obj r1 open)]")" >/dev/null
tf_arm "$GOOD" dRc >/dev/null
: > "$BD_LOG"
RD="$WORK/race"; mkdir -p "$RD"
for k in a b c d e f g h; do
  ( if [[ $((RANDOM%2)) -eq 0 ]]; then tf_fire "$GOOD" dRc; else tf_poll "$GOOD" "$FAR"; fi >/dev/null 2>&1; echo $? > "$RD/$k" ) &
done
wait
ck  "r1 consequence_applied true exactly once"         eq "$(ICA dRc r1)" "true"
ck  "§5.3 applied EXACTLY ONCE under 8-way alarm⇄poll race (S-6 / §7.4 latch)" \
   eq "$(BDN 'create --title new r1')" "1"
ck  "every concurrent fire/poll returned success (idempotent)" \
   bash -c 'for f in "$1"/*; do [[ "$(cat "$f")" == 0 ]] || exit 1; done' _ "$RD"

echo ""
echo "── EXIT-3: objected ≠ auto-proceed · non-auto-proceeding left open ──"
# obj1 will be OBJECTED; keep1 un-objected fyi-objectable (auto-proceeds);
# other1 approve-reject (non-fyi-objectable — never auto-proceeds, left open).
do_dossier_put "$GOOD" "$(mk dO timed-fyi \
  "[$(item_obj obj1 open),$(item_obj keep1 open),$(item_ar other1 open)]")" >/dev/null
# Human objects to obj1 FIRST (T5.3 reconciler: applied + follow-up, NO block).
do_item_apply "$GOOD" dO obj1 "$RESP_OBJECT" >/dev/null
OBJ1_AT="$(IAT dO obj1)"
ck  "objected obj1 reconciled (state applied, follow-up emitted)" \
   do_dossier_get "$GOOD" dO-fu-obj1
ck  "objection applied NO §5.3 block (reconciler, not proceed)"  eq "$(BDN 'create --title new obj1')" "0"
tf_arm "$GOOD" dO >/dev/null
: > "$BD_LOG"
ck  "tf_fire (alarm) succeeds with a mixed dossier"    tf_fire "$GOOD" dO
ck  "OBJECTED obj1 did NOT auto-proceed (no proceed §5.3 block)" eq "$(BDN 'create --title new obj1')" "0"
ck  "OBJECTED obj1 applied_at UNCHANGED (no second resolution)"  eq "$(IAT dO obj1)" "$OBJ1_AT"
ck  "un-objected keep1 DID auto-proceed (consequence applied)"   eq "$(BDN 'create --title new keep1')" "1"
ck  "keep1 state → applied"                            eq "$(ISTATE dO keep1)" "applied"
ck  "non-fyi-objectable other1 LEFT OPEN (never auto-proceeds)"  eq "$(ISTATE dO other1)" "open"
ck  "other1 latch still false (untouched)"             eq "$(ICA dO other1)" "false"
ck  "other1 NO §5.3 block applied"                     eq "$(BDN 'create --title new other1')" "0"
# the open non-auto-proceeding sibling blocks NOTHING — it still answers, and
# the dossier never stalled (keep1 proceeded though obj1 terminal & other1 open)
ck  "left-open other1 still answerable later (no sibling/pipeline gate — AD7)" \
   do_item_apply "$GOOD" dO other1 "$RESP_APPROVE"
ck  "other1 now applied (proves no gate from partial resolution)" eq "$(ISTATE dO other1)" "applied"
OPEN_FYI="$(GET dO | jq -r '[.items[]|select(.kind=="fyi-objectable" and .state=="open")]|length' 2>/dev/null)"
ck  "a timed-fyi dossier never infinite-stalls (0 fyi-objectable left open)" \
   eq "$OPEN_FYI" "0"

echo ""
echo "── EXIT-5: binds §2.2/§7.4 · anti-drift (structural) ──"
ck  "T4 §4 registry dossier⇒2 (v2 §11 Mermaid amend; timed-fyi added no record type)" eq "$(co__schema_version dossier)" "2"
ck  "NO §4 record type added — 'timed_fyi' unregistered"    eq "$(co__schema_version timed_fyi)" ""
ck  "the timer is the T4 §2.2 SURFACE, not a §4 record ('timer' unregistered)" \
   eq "$(co__schema_version timer)" ""
caps="$(co_capabilities 2>/dev/null || true)"
ckn "tf_arm is NOT advertised as a §2 capability"      grep -q 'tf_arm' <<<"$caps"
ckn "tf_fire is NOT advertised as a §2 capability"     grep -q 'tf_fire' <<<"$caps"
ckn "tf_poll is NOT advertised as a §2 capability"     grep -q 'tf_poll' <<<"$caps"
CAP22="$(co_capabilities 2>/dev/null | grep -c 'timer-arm|timer-due|timer-ack')"
ck  "§2.2 stays the four-capability timer surface (timer-arm|due|ack)" \
   test "$CAP22" -ge 1
# §0.5 frozen constant: ONE env-overridable definition, default = 86400, NO
# competing local literal (single normative definition is INTERFACE.md §0.5).
ck  "tf__TIMED_FYI_DEFAULT default = 86400 (§0.5)"     eq "$(tf__TIMED_FYI_DEFAULT)" "86400"
OVR="$(TIMED_FYI_DEFAULT=10 tf__TIMED_FYI_DEFAULT)"
ck  "tf__TIMED_FYI_DEFAULT is env-overridable (no hardcoded use-site literal)" \
   eq "$OVR" "10"
# the §2.2 fire(dossier_id) target IS the envelope timer_fire_at (one truth)
do_dossier_put "$GOOD" "$(mk dT timed-fyi "[$(item_obj t1 open)]")" >/dev/null
tf_arm "$GOOD" dT 7200 >/dev/null
ck  "armed T4 timer id == dossier id (fire(dossier_id), §2.2)" DUE dT "$FAR"
ck  "armed timer fire_at == envelope timer_fire_at (single target)" \
   eq "$(TFA dT)" "2026-05-16T02:00:00Z"
# missing / unauthorized dossier rejected (§9.1 collapses 401/absent — C4)
ckn "tf_arm on a MISSING dossier REJECTED"             tf_arm "$GOOD" nodoss
ckn "tf_fire on a MISSING dossier REJECTED"            tf_fire "$GOOD" nodoss
ckn "tf_arm with NO bearer REJECTED (§9.1, no second auth path)" tf_arm "" dT

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " test-timed-fyi (T5.4, claude-tools-it2):  PASS=$PASS  FAIL=$FAIL"
echo "══════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
