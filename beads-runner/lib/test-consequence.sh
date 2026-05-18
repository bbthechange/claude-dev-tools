#!/bin/bash
# beads-runner/lib/test-consequence.sh — focused unit test for the T5.3
# IDEMPOTENT per-Item CONSEQUENCE APPLIER (claude-tools-o0u; epic claude-
# tools-glk).
#
# T5.3's OWN test surface. Deliberately NOT a member of the T1 conformance
# suite (beads-runner/conformance/, owned by T1a/T1b) and it touches NO
# sibling test (test-coordinator{,-lease,-reconcile,-capacity,-forensic}.sh,
# test-dossier.sh, test-local-agent.sh). It exercises ONLY the §5.3 / §7.4
# per-Item / §5.2.2 surface on consequence.sh, consuming the T5.1 substrate
# (dossier.sh) and the T4 §2.1/§4 store as a black box, and the WORK plane
# `bd` surface via a PATH-injected logging fake — the SAME fake-bin pattern
# the conformance harness and test-local-agent.sh use.
#
# Asserts the EXIT CRITERIA T5.3 owns against INTERFACE.md v1:
#   1. Same item response applied TWICE (human double-tap, AND §2.2 alarm
#      racing poll-fallback / S-6) ⇒ consequence applied EXACTLY ONCE;
#      `consequence_applied` flips false→true ONCE (parent EXIT 1).
#   2. Resolving 6 of 15 items applies exactly those 6 blocks once each; the
#      other 9 stay open and block nothing (partial application clean — AD7).
#   3. PURE un-edited approve/pick/recommendation ⇒ DETERMINISTIC apply;
#      freeform / edited / object ⇒ RECONCILER path emitting a follow-up
#      Dossier scoped to the item with resolved siblings UNTOUCHED — both.
#   4. §5.3 application performs creates / unblocks / labels / status_changes
#      against the WORK plane (control→work).
#   5. Binds the FROZEN §5.3 schema (cb_schema_version; an unknown-higher cb
#      REJECTED, no write, latch NOT flipped); idempotency key = Item id
#      (§0.4) — applying X never latches a sibling; no §4 record type added
#      (anti-drift); reconciler synthesises NO §5 content (T5.2 boundary).
#
# Self-contained: its own CO_STORE + fake-bin under mktemp; shares NO state
# with the conformance harness or sibling tests.
set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/consequence.sh"
[[ -f "$LIB" ]] || { echo "FATAL: consequence.sh not found at $LIB"; exit 2; }

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
unset CO_EXPECTED_TOKEN PRINCIPAL_V1 2>/dev/null || true

# ── work-plane `bd` fake on PATH (conformance / test-local-agent pattern) ────
# Logs every invocation to $BD_LOG (one line per call) so creates/unblocks/
# labels/status_changes against the work plane are OBSERVABLE; emits the BC-18
# `✓ Created issue: <id> — <title>` stdout shape so the deps[] id-scrape (the
# run-beads-tasks.sh scrape consequence.sh reuses) resolves.
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
source "$LIB"           # sources dossier.sh → coordinator.sh (consumer binding)

GOOD="bearer-runner-secret-xyz"
GET()    { co_request "$GOOD" get dossier "$1" 2>/dev/null; }
ISTATE() { GET "$1" | jq -r --arg i "$2" '.items[]|select(.id==$i).state'              2>/dev/null; }
ICA()    { GET "$1" | jq -r --arg i "$2" '.items[]|select(.id==$i).consequence_applied' 2>/dev/null; }
IAT()    { GET "$1" | jq -r --arg i "$2" '.items[]|select(.id==$i).applied_at'          2>/dev/null; }
BDN()    { local c; c=$(grep -c -- "$1" "$BD_LOG" 2>/dev/null); echo "${c:-0}"; }  # BDN <re>

# §4.1 envelope; `body` OPAQUE (substrate round-trips it; §5 = T5.2).
mk() {  # mk <id> <sv> <items-json-array>
  jq -cn --arg id "$1" --argjson sv "$2" --argjson items "$3" '
    { id:$id, schema_version:$sv, kind:"decide", trigger:"worker_stuck",
      bead_ref:"claude-tools-65z", tier:"blocking",
      created_at:"2026-05-16T00:00:00Z", timer_fire_at:null,
      body:{ dossier_schema_version:2, tldr:"opaque", sections:[],
             diagrams:[], full_detail:"T5.2 owns this" },
      items:$items }'
}
# A §5.3 block exercising ALL FOUR action kinds, tagged <tag> so a per-item
# "applied exactly once" is countable in the bd log.
cb() {  # cb <tag> <cbsv>
  jq -cn --arg t "$1" --argjson v "$2" '
    { cb_schema_version:$v,
      creates:[ { title:("new "+$t), type:"task", priority:2,
                  labels:["auto"], description:"d", deps:["claude-tools-dep"] } ],
      unblocks:["unb-"+$t],
      labels:[ { bead_ref:("lbl-"+$t), add:["go"], remove:["wait"] } ],
      status_changes:[ { bead_ref:("st-"+$t), to_status:"in_progress" } ] }'
}
# approve-reject item carrying its own block (deterministic path).
item_ar() { jq -cn --arg i "$1" --arg s "$2" --argjson cb "$(cb "$1" 2)" '
    { id:$i, kind:"approve-reject", framing:{}, context_anchor:{where:"x",expansion:"y"},
      consequence_block:$cb, reversible:"r",
      state:$s, response:null, consequence_applied:false, applied_at:null }'; }
# pick-option item: two options each with its OWN block.
item_po() { jq -cn --arg i "$1" --arg s "$2" \
      --argjson a "$(cb "${1}A" 2)" --argjson b "$(cb "${1}B" 2)" '
    { id:$i, kind:"pick-option", framing:{}, context_anchor:{where:"x",expansion:"y"},
      options:[ {option_id:"opt-a",label:"A",blast_radius:"x",consequence_block:$a},
                {option_id:"opt-b",label:"B",blast_radius:"y",consequence_block:$b} ],
      recommendation:{value:"opt-a",why:"because"},
      consequence_block:$a, reversible:"r",
      state:$s, response:null, consequence_applied:false, applied_at:null }'; }
# freeform-edit item (reconciler path).
item_ff() { jq -cn --arg i "$1" --arg s "$2" --argjson cb "$(cb "$1" 2)" '
    { id:$i, kind:"freeform-edit", framing:{}, context_anchor:{where:"x",expansion:"y"},
      consequence_block:$cb, reversible:"r",
      state:$s, response:null, consequence_applied:false, applied_at:null }'; }
# approve-recommendation item (deterministic UNLESS the value is edited).
item_rec() { jq -cn --arg i "$1" --arg s "$2" --argjson cb "$(cb "$1" 2)" '
    { id:$i, kind:"approve-recommendation", framing:{}, context_anchor:{where:"x",expansion:"y"},
      recommendation:{value:"v",why:"w"}, consequence_block:$cb, reversible:"r",
      state:$s, response:null, consequence_applied:false, applied_at:null }'; }
# fyi-objectable item — auto-proceeds on the §2.2 timer (T5.4) UNLESS objected.
item_obj() { jq -cn --arg i "$1" --arg s "$2" --argjson cb "$(cb "$1" 2)" '
    { id:$i, kind:"fyi-objectable", framing:{}, context_anchor:{where:"x",expansion:"y"},
      consequence_block:$cb, reversible:"r",
      state:$s, response:null, consequence_applied:false, applied_at:null }'; }
# A §5.3 block with NO type/priority/description — Issue-4: those MUST be
# OMITTED from `bd create` (bd's default), never synthesised by the applier.
cb_bare() { jq -cn --arg t "$1" '
    { cb_schema_version:2,
      creates:[ { title:("bare "+$t), labels:["x"] } ],
      unblocks:[], labels:[], status_changes:[] }'; }
item_bare() { jq -cn --arg i "$1" --arg s "$2" --argjson cb "$(cb_bare "$1")" '
    { id:$i, kind:"approve-reject", framing:{}, context_anchor:{where:"x",expansion:"y"},
      consequence_block:$cb, reversible:"r",
      state:$s, response:null, consequence_applied:false, applied_at:null }'; }
RESP_APPROVE='{"decision":"approve","responded_at":"2026-05-16T01:00:00Z","principal":"brian"}'
RESP_PICK_A='{"decision":"pick","selected_option_id":"opt-a","responded_at":"2026-05-16T01:00:00Z","principal":"brian"}'
RESP_PICK_B='{"decision":"pick","selected_option_id":"opt-b","responded_at":"2026-05-16T01:00:00Z","principal":"brian"}'
RESP_FREEFORM='{"decision":"freeform","freeform_text":"do it another way","responded_at":"2026-05-16T01:00:00Z","principal":"brian"}'
RESP_EDITED='{"decision":"approve","edited_value":"changed by human","responded_at":"2026-05-16T01:00:00Z","principal":"brian"}'
RESP_OBJECT='{"decision":"object","freeform_text":"I object to this auto-proceed","responded_at":"2026-05-16T01:00:00Z","principal":"brian"}'

echo "── EXIT-1: idempotency — double-tap AND alarm+poll ⇒ applied ONCE ──"
do_dossier_put "$GOOD" "$(mk dA 2 "[$(item_ar i1 open)]")" >/dev/null
: > "$BD_LOG"
ck  "do_item_apply (approve) succeeds"                 do_item_apply "$GOOD" dA i1 "$RESP_APPROVE"
ck  "i1 consequence_applied flipped false→true"        eq "$(ICA dA i1)" "true"
ck  "i1 state answered→applied"                        eq "$(ISTATE dA i1)" "applied"
ck  "i1 applied_at stamped (§4.1.1)"                   ne "$(IAT dA i1)" "null"
ck  "§5.3 create ran ONCE for this item"               eq "$(BDN 'create --title new i1')" "1"
AT1="$(IAT dA i1)"; CREATES_AFTER1="$(BDN 'create --title new i1')"
# DOUBLE-TAP — identical call again: idempotent no-op, NO new work-plane op.
ck  "2nd identical apply (double-tap) returns success" do_item_apply "$GOOD" dA i1 "$RESP_APPROVE"
ck  "consequence_applied STILL true (flipped ONCE)"    eq "$(ICA dA i1)" "true"
ck  "applied_at UNCHANGED (no re-apply)"               eq "$(IAT dA i1)" "$AT1"
ck  "NO additional §5.3 create on double-tap"          eq "$(BDN 'create --title new i1')" "$CREATES_AFTER1"
# ALARM + POLL (S-6): the entrypoint T5.4 calls from BOTH alarm-fire and the
# poll-fallback — concurrently. Exactly one applier; consequence ONCE.
do_dossier_put "$GOOD" "$(mk dC 2 "[$(item_ar c1 open)]")" >/dev/null
: > "$BD_LOG"
RD="$WORK/race"; mkdir -p "$RD"
for k in a b c d e f g h; do
  ( do_item_apply "$GOOD" dC c1 "$RESP_APPROVE" >/dev/null 2>&1; echo $? > "$RD/$k" ) &
done
wait
ck  "C1 consequence_applied true exactly once"         eq "$(ICA dC c1)" "true"
ck  "§5.3 create ran EXACTLY ONCE under 8-way race (S-6)" eq "$(BDN 'create --title new c1')" "1"
ck  "every concurrent caller returned success (idempotent)" \
   bash -c 'for f in "$1"/*; do [[ "$(cat "$f")" == 0 ]] || exit 1; done' _ "$RD"

echo ""
echo "── EXIT-4: §5.3 application hits ALL FOUR work-plane action kinds ──"
ck  "creates[]        ⇒ bd create"                     test "$(BDN 'create --title new c1')" -ge 1
ck  "creates[].deps[] ⇒ bd dep add <new> <dep>"        test "$(BDN 'dep add bd-fake-.* claude-tools-dep')" -ge 1
ck  "unblocks[]       ⇒ bd update <ref> --status=open" test "$(BDN 'update unb-c1 --status=open')" -ge 1
ck  "labels[]         ⇒ bd update --add-label/--remove-label" \
   test "$(BDN 'update lbl-c1 --add-label go --remove-label wait')" -ge 1
ck  "status_changes[] ⇒ bd update <ref> --status=<to>" test "$(BDN 'update st-c1 --status=in_progress')" -ge 1

echo ""
echo "── EXIT-3: §5.2.2 PER-ITEM routing — deterministic vs reconciler ──"
# (a) pick-option: the CHOSEN option's block, not the other's.
do_dossier_put "$GOOD" "$(mk dP 2 "[$(item_po p1 open)]")" >/dev/null
: > "$BD_LOG"
ck  "pick opt-a ⇒ deterministic apply succeeds"        do_item_apply "$GOOD" dP p1 "$RESP_PICK_A"
ck  "chosen option-A block applied"                    eq "$(BDN 'create --title new p1A')" "1"
ck  "the NON-chosen option-B block NOT applied"        eq "$(BDN 'create --title new p1B')" "0"
ck  "p1 applied + latched"                             eq "$(ISTATE dP p1)" "applied"
ckn "no follow-up dossier on the deterministic path"   do_dossier_get "$GOOD" dP-fu-p1
# (b) RECONCILER: freeform ⇒ NO block applied, follow-up scoped to the item,
#     resolved siblings UNTOUCHED.
do_dossier_put "$GOOD" "$(mk dR 2 "[$(item_ar sib1 open),$(item_ff ff1 open),$(item_ar sib2 open)]")" >/dev/null
# resolve sib1 deterministically FIRST so it is a RESOLVED sibling.
do_item_apply "$GOOD" dR sib1 "$RESP_APPROVE" >/dev/null
SIB1_AT="$(IAT dR sib1)"
: > "$BD_LOG"
ck  "freeform-edit ⇒ reconciler path succeeds"         do_item_apply "$GOOD" dR ff1 "$RESP_FREEFORM"
ck  "reconciler applied NO §5.3 block (no bd create)"  eq "$(BDN 'create --title new ff1')" "0"
ck  "ff1 marked applied+latched (consequence=dispatch, once)" eq "$(ISTATE dR ff1)" "applied"
ck  "ff1 latch true"                                   eq "$(ICA dR ff1)" "true"
FU="$(do_dossier_get "$GOOD" dR-fu-ff1 2>/dev/null)"
ck  "a follow-up Dossier was emitted (dR-fu-ff1)"      test -n "$FU"
ck  "follow-up is SCOPED to the one item (exactly 1)"  eq "$(jq -r '.items|length' <<<"$FU")" "1"
ck  "follow-up carries a fresh re-decide item id"      eq "$(jq -r '.items[0].id' <<<"$FU")" "ff1-r1"
ck  "follow-up item reset to open for re-decision"     eq "$(jq -r '.items[0].state' <<<"$FU")" "open"
ck  "follow-up body is an OPAQUE reconcile pointer (NOT §5 content — T5.2)" \
   eq "$(jq -r '.body.reconcile_of' <<<"$FU")" "dR"
ck  "RESOLVED sibling sib1 UNTOUCHED (state)"           eq "$(ISTATE dR sib1)" "applied"
ck  "RESOLVED sibling sib1 UNTOUCHED (applied_at)"      eq "$(IAT dR sib1)" "$SIB1_AT"
ck  "OPEN sibling sib2 still open (never reopened/closed)" eq "$(ISTATE dR sib2)" "open"
ck  "OPEN sibling sib2 latch still false"               eq "$(ICA dR sib2)" "false"
# (c) EDITED approve-recommendation ⇒ reconciler (edited, not pure).
do_dossier_put "$GOOD" "$(mk dE 2 "[$(item_rec e1 open)]")" >/dev/null
: > "$BD_LOG"
ck  "approve-recommendation w/ edited_value ⇒ succeeds" do_item_apply "$GOOD" dE e1 "$RESP_EDITED"
ck  "edited ⇒ RECONCILER (no deterministic block applied)" eq "$(BDN 'create --title new e1')" "0"
ck  "edited ⇒ a follow-up dossier emitted"             do_dossier_get "$GOOD" dE-fu-e1
# (d) un-edited approve-recommendation ⇒ DETERMINISTIC.
do_dossier_put "$GOOD" "$(mk dD 2 "[$(item_rec d1 open)]")" >/dev/null
: > "$BD_LOG"
ck  "un-edited approve-recommendation ⇒ deterministic"  do_item_apply "$GOOD" dD d1 "$RESP_APPROVE"
ck  "deterministic block applied (bd create ran)"       eq "$(BDN 'create --title new d1')" "1"
ckn "no follow-up on the deterministic recommendation"  do_dossier_get "$GOOD" dD-fu-d1
# (e) decision:"object" on a fyi-objectable item ⇒ RECONCILER (the human
#     objected to an auto-proceed; the objection is interpreted, not applied).
do_dossier_put "$GOOD" "$(mk dO 2 "[$(item_obj o1 open)]")" >/dev/null
: > "$BD_LOG"
ck  "fyi-objectable + decision:object ⇒ reconciler succeeds" do_item_apply "$GOOD" dO o1 "$RESP_OBJECT"
ck  "objected ⇒ NO §5.3 block applied (no bd create)"   eq "$(BDN 'create --title new o1')" "0"
ck  "objected ⇒ a follow-up dossier emitted (objection interpreted)" do_dossier_get "$GOOD" dO-fu-o1
ck  "objected o1 marked applied+latched (exactly once)" eq "$(ISTATE dO o1)" "applied"

echo ""
echo "── EXIT-2: partial application clean — 6 of 15, the other 9 untouched ──"
fifteen="$(for n in $(seq 1 15); do item_ar "q$n" open; done | paste -sd, -)"
do_dossier_put "$GOOD" "$(mk d15 2 "[$fifteen]")" >/dev/null
: > "$BD_LOG"
for n in 1 2 3 4 5 6; do do_item_apply "$GOOD" d15 "q$n" "$RESP_APPROVE" >/dev/null; done
ck  "exactly 6 items consequence_applied"              eq "$(GET d15 | jq -r '[.items[]|select(.consequence_applied==true)]|length')" "6"
ck  "exactly 6 items state=applied"                    eq "$(GET d15 | jq -r '[.items[]|select(.state=="applied")]|length')" "6"
ck  "the other 9 items STILL open (AD7 partial)"       eq "$(GET d15 | jq -r '[.items[]|select(.state=="open")]|length')" "9"
ck  "the other 9 latches STILL false"                  eq "$(GET d15 | jq -r '[.items[]|select(.consequence_applied==false)]|length')" "9"
g=0; for n in 1 2 3 4 5 6; do [[ "$(BDN "new q$n --type")" == 1 ]] && g=$((g+1)); done
ck  "each of the 6 blocks applied EXACTLY once"        eq "$g" "6"
ck  "no block applied for the 9 unresolved (q7)"       eq "$(BDN 'new q7 --type')" "0"
# the 9 still accept an op — partial resolution NEVER gates a sibling.
ck  "a 7th item still applies (no sibling gate — AD7)"  do_item_apply "$GOOD" d15 q7 "$RESP_APPROVE"
ck  "q7 now applied"                                   eq "$(ISTATE d15 q7)" "applied"

echo ""
echo "── EXIT-5: FROZEN §5.3 binding · key=Item id · anti-drift ──"
# Unknown-higher cb_schema_version REJECTED — NO bd op, latch NOT flipped.
do_dossier_put "$GOOD" "$(jq -c '.items[0].consequence_block.cb_schema_version=3' \
   <<<"$(mk dV 2 "[$(item_ar v1 open)]")")" >/dev/null
: > "$BD_LOG"
ckn "cb_schema_version 3 ⇒ apply REJECTED (§0.3 unknown higher; bound=2 v2)" do_item_apply "$GOOD" dV v1 "$RESP_APPROVE"
ck  "the §0.3-rejected block ran NO work-plane op"      eq "$(BDN 'create')" "0"
ck  "the §0.3-rejected item latch NOT flipped"          eq "$(ICA dV v1)" "false"
ck  "the §0.3-rejected item NOT moved to applied"       ne "$(ISTATE dV v1)" "applied"
# §5.3 has NO declared defaults — an ABSENT type/priority/description is
# OMITTED from `bd create` (bd's default), NEVER synthesised by the applier.
do_dossier_put "$GOOD" "$(mk dB 2 "[$(item_bare b1 open)]")" >/dev/null
: > "$BD_LOG"
ck  "bare create (no type/priority/desc) ⇒ apply succeeds" do_item_apply "$GOOD" dB b1 "$RESP_APPROVE"
ck  "absent §5.3 type   NOT synthesised (no --type in bd create)" eq "$(BDN 'create --title bare b1 --type')" "0"
ck  "absent §5.3 prio   NOT synthesised (no -p in bd create)"     eq "$(BDN 'create --title bare b1 .* -p ')" "0"
ck  "absent §5.3 desc   NOT synthesised (no -d in bd create)"     eq "$(BDN 'create --title bare b1 .* -d ')" "0"
ck  "the bare create DID run (title + present labels only)"       eq "$(BDN 'create --title bare b1 --labels x')" "1"
# Idempotency key = the Item id (§0.4): applying one item never latches another.
do_dossier_put "$GOOD" "$(mk dK 2 "[$(item_ar k1 open),$(item_ar k2 open)]")" >/dev/null
do_item_apply "$GOOD" dK k1 "$RESP_APPROVE" >/dev/null
ck  "applying k1 latched k1"                            eq "$(ICA dK k1)" "true"
ck  "applying k1 did NOT latch sibling k2 (key=Item id; §0.4)" eq "$(ICA dK k2)" "false"
ck  "sibling k2 still open"                             eq "$(ISTATE dK k2)" "open"
# answered-path: response recorded by T5.1 set-state, then applied w/ NO arg.
do_dossier_put "$GOOD" "$(mk dN 2 "[$(item_ar n1 open)]")" >/dev/null
do_item_set_state "$GOOD" dN n1 answered "$RESP_APPROVE" >/dev/null
: > "$BD_LOG"
ck  "answered Item applies from its RECORDED .response (no arg)" do_item_apply "$GOOD" dN n1
ck  "answered-path applied the block"                  eq "$(BDN 'create --title new n1')" "1"
ck  "answered-path n1 now applied"                     eq "$(ISTATE dN n1)" "applied"
# expired Item cannot be applied (auto-proceed already lapsed).
do_dossier_put "$GOOD" "$(mk dX 2 "[$(item_ar x1 open)]")" >/dev/null
do_item_set_state "$GOOD" dX x1 expired >/dev/null
ckn "expired Item ⇒ apply REJECTED"                    do_item_apply "$GOOD" dX x1 "$RESP_APPROVE"
# missing Item id rejected (§0.4).
ckn "apply on a MISSING Item id REJECTED (§0.4)"       do_item_apply "$GOOD" dN nope "$RESP_APPROVE"
ckn "apply on a MISSING dossier REJECTED"              do_item_apply "$GOOD" nodoss x "$RESP_APPROVE"

echo ""
echo "── ANTI-DRIFT (structural — sibling surfaces untouched) ──"
ck  "T4 §4 registry dossier⇒2 (v2 §11 Mermaid amend; applier added no record type)"  eq "$(co__schema_version dossier)" "2"
ck  "applier added NO §4 record type — 'dossier_fu' unregistered" \
   eq "$(co__schema_version dossier_fu)" ""
# reconciler synthesises NO §5 content: the carried item's §5 fields are the
# ORIGINAL's verbatim, and the follow-up body has none of the §5 body tiers.
FU2="$(do_dossier_get "$GOOD" dR-fu-ff1 2>/dev/null)"
ck  "follow-up carries the ORIGINAL item kind verbatim (no §5 synthesis)" \
   eq "$(jq -r '.items[0].kind' <<<"$FU2")" "freeform-edit"
ck  "follow-up body has NONE of the §5 tiers (generation = T5.2, not T5.3)" \
   eq "$(jq -r '.body|(has("tldr") or has("sections") or has("diagrams") or has("full_detail"))' <<<"$FU2")" "false"
caps="$(co_capabilities 2>/dev/null || true)"
ckn "do_item_apply is NOT advertised as a §2 capability"    grep -q 'do_item_apply' <<<"$caps"

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " test-consequence (T5.3, claude-tools-o0u):  PASS=$PASS  FAIL=$FAIL"
echo "══════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
