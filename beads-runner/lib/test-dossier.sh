#!/bin/bash
# beads-runner/lib/test-dossier.sh — focused unit test for the T5.1
# Dossier/Item DO SUBSTRATE (claude-tools-fuy; epic claude-tools-glk).
#
# T5.1's OWN test surface. Deliberately NOT a member of the T1 conformance
# suite (beads-runner/conformance/, owned by T1a/T1b) and it does NOT touch
# the sibling T4 tests (test-coordinator{,-lease,-reconcile,-capacity,
# -forensic}.sh). Anti-drift: each tier its own focused test. It exercises
# ONLY the §4.1/§4.1.1/§0.3/§0.4 substrate surface on dossier.sh, consuming
# the T4 §2.1/§4 store + §9.1 chokepoint as a black box.
#
# Asserts the EXIT CRITERIA T5.1 owns against INTERFACE.md v1:
#   1. §4.1{body,items[]} + §4.1.1 Item round-trip THROUGH the T4 store with
#      `principal` + `schema_version=2` STAMPED (v2 — §11 Mermaid amend
#      single-source bump); an unknown HIGHER schema_version is REJECTED
#      (§0.3) on BOTH write and read.
#   2. The per-Item state machine permits ONLY open→answered→applied and
#      open→expired; every illegal transition (skip / terminal-escape /
#      no-op / unknown) is REJECTED (no write).
#   3. `consequence_applied` is single-writer false→true-ONCE (2nd latch
#      REJECTED, no write); the dossier-level task_ref DEDUP record is a
#      single-writer structure (2nd writer w/ different dossier REJECTED;
#      same-dossier idempotent) — latch/structure PRIMITIVES only; the
#      apply/dedup LOGIC is T5.3/T5.5 and is NOT exercised here.
#   4. Derived rollup = `open` while ≥1 item non-terminal, `resolved` when
#      all terminal, and it NEVER gates a sibling op or the pipeline
#      (resolving 6 of 15 applies exactly those; the other 9 stay open and
#      block nothing; an op still succeeds when the rollup reads `resolved`).
#   5. (Full T1 conformance stays PASS / zero-FAIL with no GATE flipped — the
#      conformance SUITE's job, run as the quality gate; this change adds
#      dossier.sh + this file ONLY and touches NO sibling surface.)
#
# Anti-drift proven by STRUCTURE (a source grep is defeated by this file's
# own correct anti-drift prose — the lesson the sibling T4 tests call out):
#   • the substrate adds NO §4 record type — co__schema_version is unchanged
#     (`dossier`⇒1 still; no `dossier_dedup` type); the dedup record is a
#     T5 sibling namespace, the §10.3-forensic precedent, NOT a §4 record;
#   • it NEVER synthesises §5 body/items content — a valid OPAQUE body
#     round-trips untouched; a malformed envelope is rejected, never
#     "repaired" with generated §5 fields;
#   • it NEVER applies a ConsequenceBlock — do_item_latch flips ONLY the
#     boolean+applied_at; `creates/unblocks/labels/status_changes` are
#     untouched and `.state` is NOT moved by the latch (state↔latch are
#     orthogonal primitives — coupling is §7.4 LOGIC = T5.3);
#   • §9.1 — no/invalid token ⇒ do_dossier_put / do_dedup_record rejected
#     BEFORE any write (reuses the ONE chokepoint; no second auth path);
#   • the DERIVED rollup gates NOTHING (AD7) — every Item op succeeds
#     regardless of the rollup value.
#
# Self-contained: its own CO_STORE under mktemp; shares NO state with the T1
# conformance harness or the sibling T4 tests.
set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dossier.sh"
COORD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/coordinator.sh"
[[ -f "$LIB"   ]] || { echo "FATAL: dossier.sh not found at $LIB"; exit 2; }
[[ -f "$COORD" ]] || { echo "FATAL: coordinator.sh not found at $COORD"; exit 2; }

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

# shellcheck source=/dev/null
source "$LIB"          # sources coordinator.sh transitively (consumer binding)

GOOD="bearer-runner-secret-xyz"
GET()    { co_request "$GOOD" get dossier "$1" 2>/dev/null; }   # raw stored §4 record
ISTATE() { GET "$1" | jq -r --arg i "$2" '.items[]|select(.id==$i).state'   2>/dev/null; }
ICA()    { GET "$1" | jq -r --arg i "$2" '.items[]|select(.id==$i).consequence_applied' 2>/dev/null; }
JFIELD() { GET "$1" | jq -r "$2" 2>/dev/null; }                 # JFIELD <id> <jq-expr>

# same-shell compound predicates (NEVER `bash -c` — it would not inherit the
# sourced substrate functions; the sibling T4 tests note this trap):
setstate_then_is() {  # <bearer> <did> <iid> <to> — succeed iff move+persist OK
  do_item_set_state "$1" "$2" "$3" "$4" >/dev/null 2>&1 && [[ "$(ISTATE "$2" "$3")" == "$4" ]]
}
latch_then_true() {   # <bearer> <did> <iid> — succeed iff flip+persist OK
  do_item_latch "$1" "$2" "$3" >/dev/null 2>&1 && [[ "$(ICA "$2" "$3")" == true ]]
}

# A well-formed §4.1 envelope. `body` is OPAQUE (object) — the substrate must
# round-trip it untouched; §5 item content keys are present-but-ignored.
mk() {  # mk <id> <schema_version> <items-json-array>
  jq -cn --arg id "$1" --argjson sv "$2" --argjson items "$3" '
    { id:$id, schema_version:$sv, kind:"decide", trigger:"worker_stuck",
      bead_ref:"claude-tools-65z", tier:"blocking",
      created_at:"2026-05-16T00:00:00Z", timer_fire_at:null,
      body:{ dossier_schema_version:2, tldr:"opaque to substrate",
             sections:[], diagrams:[], full_detail:"T5.2 owns this" },
      items:$items }'
}
item() { # item <id> <state> — §5 keys present but substrate-irrelevant
  jq -cn --arg i "$1" --arg s "$2" '
    { id:$i, kind:"approve-reject", framing:{}, context_anchor:{where:"x",expansion:"y"},
      consequence_block:{cb_schema_version:2,creates:[],unblocks:[],labels:[],status_changes:[]},
      state:$s, response:null, consequence_applied:false, applied_at:null }'
}

echo "── EXIT-1: §4.1/§4.1.1 round-trip · principal+sv stamped · §0.3 ──"
D1="$(mk dossA 2 "[$(item it1 open),$(item it2 open)]")"
id="$(do_dossier_put "$GOOD" "$D1")"; rc=$?
ck "do_dossier_put accepts a well-formed v2 envelope"        eq "$rc" "0"
ck "returns the dossier id"                                  eq "$id" "dossA"
S="$(GET dossA)"
ck "envelope round-tripped through the T4 §4 store"          eq "$(jq -r .id <<<"$S")" "dossA"
ck "T4 STAMPED principal=PRINCIPAL_V1 (§9.1)"                eq "$(jq -r .principal <<<"$S")" "brian"
ck "schema_version=2 persisted (§4.1; v2 §11 amend)"         eq "$(jq -r .schema_version <<<"$S")" "2"
ck "items[] round-tripped (2 Items)"                         eq "$(jq -r '.items|length' <<<"$S")" "2"
ck "OPAQUE body round-tripped UNTOUCHED (no §5 synthesis)" \
   eq "$(jq -r '.body.full_detail' <<<"$S")" "T5.2 owns this"
ck "per-Item §4.1.1 record shape persisted"                  eq "$(jq -r '.items[0].consequence_applied' <<<"$S")" "false"
ck "do_dossier_get returns the record"                       eq "$(do_dossier_get "$GOOD" dossA | jq -r .id)" "dossA"
# §0.3 — unknown HIGHER schema_version rejected on the WRITE path, NO write.
BAD2="$(mk dossHi 3 "[$(item it1 open)]")"
ckn "§0.3 — schema_version 3 REJECTED on write (unknown higher; bound=2 v2)"  do_dossier_put "$GOOD" "$BAD2"
ckn "§0.3 — the rejected higher-version dossier was NOT written"  co_request "$GOOD" get dossier dossHi
# §0.3 also bound on the READ path (defense): a v3 slipped directly into the
# store (bypassing put) must be rejected by do_dossier_get, not parsed.
RAW3="$(mk dossRd 3 "[$(item it1 open)]")"
mkdir -p "$CO_STORE/records"
printf '%s\n' "$(jq -c '.principal="brian"' <<<"$RAW3")" > "$CO_STORE/records/dossier.dossRd.json"
ckn "§0.3 — do_dossier_get REJECTS an unknown-higher stored record"  do_dossier_get "$GOOD" dossRd
# Non-integer / missing schema_version rejected (§4.1 'int' / §0.3).
ckn "§0.3 — string \"1\" schema_version REJECTED (jq type-check)" \
   do_dossier_put "$GOOD" "$(jq -c '.schema_version="1"' <<<"$D1")"
# §9.1 — no/invalid token ⇒ rejected BEFORE any write (reuse ONE chokepoint).
ckn "§9.1 — missing bearer ⇒ do_dossier_put REJECTED" \
   do_dossier_put "" "$(mk dossNoTok 2 "[$(item it1 open)]")"
ckn "§9.1 — nothing written on the auth-failed path"  co_request "$GOOD" get dossier dossNoTok

echo ""
echo "── EXIT-2: per-Item STATE MACHINE — only legal transitions ──"
# PURE checker — the entire legal set, and the illegal complement.
ck  "open→answered LEGAL"                  do_item_state_check open answered
ck  "answered→applied LEGAL"               do_item_state_check answered applied
ck  "open→expired LEGAL"                   do_item_state_check open expired
ckn "open→applied ILLEGAL (skip)"          do_item_state_check open applied
ckn "answered→expired ILLEGAL"             do_item_state_check answered expired
ckn "open→open ILLEGAL (no-op not legal)"  do_item_state_check open open
ckn "applied→answered ILLEGAL (terminal)"  do_item_state_check applied answered
ckn "expired→open ILLEGAL (terminal)"      do_item_state_check expired open
ckn "answered→open ILLEGAL (no rewind)"    do_item_state_check answered open
ckn "unknown→answered ILLEGAL"             do_item_state_check bogus answered
# Applied through the store: open→answered→applied succeeds; an illegal jump
# is rejected with NO write (the stored state is unchanged).
do_dossier_put "$GOOD" "$(mk dossSM 2 "[$(item s1 open),$(item s2 open)]")" >/dev/null
ck  "set-state s1 open→answered ⇒ persisted"     setstate_then_is "$GOOD" dossSM s1 answered
ck  "set-state s1 answered→applied ⇒ persisted"  setstate_then_is "$GOOD" dossSM s1 applied
ckn "set-state s2 open→applied REJECTED (illegal skip)"        do_item_set_state "$GOOD" dossSM s2 applied
ck  "the REJECTED illegal transition wrote NOTHING (s2 open)"  eq "$(ISTATE dossSM s2)" "open"
ckn "set-state s1 applied→answered REJECTED (terminal escape)" do_item_set_state "$GOOD" dossSM s1 answered
ckn "set-state on a MISSING Item id REJECTED (§0.4)"           do_item_set_state "$GOOD" dossSM nope answered

echo ""
echo "── EXIT-3: PRIMITIVE 1 latch · PRIMITIVE 2 task_ref dedup ──"
do_dossier_put "$GOOD" "$(mk dossL 2 "[$(item L1 open),$(item L2 open)]")" >/dev/null
ck  "do_item_latch flips consequence_applied false→true once"  do_item_latch "$GOOD" dossL L1
ck  "L1.consequence_applied is now true"                       eq "$(ICA dossL L1)" "true"
ck  "L1.applied_at stamped (§4.1.1)"                           ne "$(JFIELD dossL '.items[]|select(.id=="L1").applied_at')" "null"
ckn "SECOND latch on L1 REJECTED (single-writer-set; once)"    do_item_latch "$GOOD" dossL L1
ck  "the rejected 2nd latch wrote NOTHING (still true, once)"  eq "$(ICA dossL L1)" "true"
# anti-drift: the latch is a PRIMITIVE — it moved NO state and applied NO block
ck  "latch did NOT move .state (state↔latch orthogonal; LOGIC=T5.3)" eq "$(ISTATE dossL L1)" "open"
ck  "latch applied NO ConsequenceBlock (creates[] untouched)" \
   eq "$(JFIELD dossL '.items[]|select(.id=="L1").consequence_block.creates|length')" "0"
ck  "L2 latch independent (per-Item key = Item id; §0.4)"      latch_then_true "$GOOD" dossL L2
# PRIMITIVE 2 — dossier-level task_ref dedup structure (single-writer).
ck  "do_dedup_record binds task_ref→dossier (first writer)"    do_dedup_record "$GOOD" claude-tools-65z dossL
ck  "do_dedup_get returns the bound dossier id"                eq "$(do_dedup_get claude-tools-65z)" "dossL"
ck  "re-bind SAME dossier ⇒ idempotent (one fork⇒one dossier)" do_dedup_record "$GOOD" claude-tools-65z dossL
ckn "2nd writer, DIFFERENT dossier ⇒ REJECTED (no 2 dossiers)" do_dedup_record "$GOOD" claude-tools-65z dossOTHER
ck  "the rejected 2nd writer did NOT overwrite the binding"    eq "$(do_dedup_get claude-tools-65z)" "dossL"
ckn "§9.1 — do_dedup_record with no bearer REJECTED"           do_dedup_record "" claude-tools-zzz dossZ
ck  "§9.1 — the auth-failed dedup wrote NOTHING"               ne "$(do_dedup_get claude-tools-zzz 2>/dev/null || echo NONE)" "dossZ"

echo ""
echo "── EXIT-4: DERIVED rollup — informational, NEVER a gate (AD7) ──"
ck "rollup = open while ≥1 item non-terminal" \
   eq "$(do_dossier_rollup "$(mk x 2 "[$(item a applied),$(item b open)]")")" "open"
ck "rollup = open while an item is merely answered (non-terminal)" \
   eq "$(do_dossier_rollup "$(mk x 2 "[$(item a answered)]")")" "open"
ck "rollup = resolved when ALL items terminal (applied|expired)" \
   eq "$(do_dossier_rollup "$(mk x 2 "[$(item a applied),$(item b expired)]")")" "resolved"
do_dossier_put "$GOOD" "$(mk dossR 2 "[$(item r1 open)]")" >/dev/null
ck "rollup persisted onto the stored envelope (T6a projection datum)" \
   eq "$(JFIELD dossR '.state')" "open"
# THE AD7 invariant: the rollup gates NOTHING. Build a 15-item dossier,
# resolve exactly 6, prove the other 9 still accept ops; then prove an op
# STILL succeeds when the rollup reads resolved.
fifteen="$(for n in $(seq 1 15); do item "q$n" open; done | paste -sd, -)"
do_dossier_put "$GOOD" "$(mk doss15 2 "[$fifteen]")" >/dev/null
for n in 1 2 3 4 5 6; do
  do_item_set_state "$GOOD" doss15 "q$n" answered >/dev/null
  do_item_latch     "$GOOD" doss15 "q$n"          >/dev/null
  do_item_set_state "$GOOD" doss15 "q$n" applied  >/dev/null
done
ck "resolving 6 of 15 ⇒ exactly 6 consequence_applied latched" \
   eq "$(JFIELD doss15 '[.items[]|select(.consequence_applied==true)]|length')" "6"
ck "the other 9 items stay open (partial resolution — AD7)" \
   eq "$(JFIELD doss15 '[.items[]|select(.state=="open")]|length')" "9"
ck "rollup is still 'open' (≥1 non-terminal) — informational" \
   eq "$(JFIELD doss15 '.state')" "open"
ck "a 7th item still transitions — rollup NEVER blocked a sibling op" \
   setstate_then_is "$GOOD" doss15 q7 answered
# Drive ALL 15 terminal ⇒ rollup resolved; a late op on it STILL works.
for n in $(seq 1 15); do
  st="$(ISTATE doss15 "q$n")"
  [[ "$st" == open     ]] && do_item_set_state "$GOOD" doss15 "q$n" expired >/dev/null
  [[ "$st" == answered ]] && do_item_set_state "$GOOD" doss15 "q$n" applied >/dev/null
done
ck "rollup now 'resolved' (all 15 terminal)"               eq "$(JFIELD doss15 '.state')" "resolved"
ck "do_dossier_get STILL serves a 'resolved' dossier (not a gate)" \
   eq "$(do_dossier_get "$GOOD" doss15 | jq -r '.items|length')" "15"
ck "do_dedup_record STILL works against a 'resolved' dossier (AD7)" \
   do_dedup_record "$GOOD" doss15-fork doss15

echo ""
echo "── EXIT-3/4 CONCURRENCY — single-writer is single-WRITER, not just"
echo "   single-value (S-6 timer-fire vs poll-fallback; AD7 under load) ──"
# A sequential 2nd-latch rejection only proves single-VALUE idempotence on a
# quiescent store; S-6 (§2.2 timer-fire racing poll-fallback) is a genuine
# CONCURRENCY scenario, so the latch must reject the 2nd *concurrent* writer.
do_dossier_put "$GOOD" "$(mk dossC 2 "[$(item C1 open)]")" >/dev/null
RD="$WORK/race-latch"; mkdir -p "$RD"
for k in a b c d e f g h; do
  ( do_item_latch "$GOOD" dossC C1 >/dev/null 2>&1; echo "$?" > "$RD/$k" ) &
done
wait
g=0; for f in "$RD"/*; do [[ "$(cat "$f")" == 0 ]] && g=$((g+1)); done
ck "EXACTLY ONE of 8 concurrent latch flips won (single-WRITER; §7.4/S-6)" eq "$g" "1"
ck "the 7 racing losers were REJECTED (false→true ONCE under concurrency)" eq "$((8-g))" "7"
ck "C1.consequence_applied is true exactly once"            eq "$(ICA dossC C1)" "true"
ck "C1.applied_at stamped once (no torn/duplicate apply)"   ne "$(JFIELD dossC '.items[]|select(.id=="C1").applied_at')" "null"
# AD7 partial resolution must hold UNDER CONCURRENCY: parallel set-state on
# DIFFERENT sibling Items must NOT clobber each other (the per-dossier
# single-writer lock makes the shared envelope a single-writer object).
fifteen2="$(for n in $(seq 1 12); do item "p$n" open; done | paste -sd, -)"
do_dossier_put "$GOOD" "$(mk dossP 2 "[$fifteen2]")" >/dev/null
for n in $(seq 1 12); do
  ( do_item_set_state "$GOOD" dossP "p$n" answered >/dev/null 2>&1 ) &
done
wait
ck "12 concurrent sibling-Item moves ALL persisted (no lost update — AD7)" \
   eq "$(JFIELD dossP '[.items[]|select(.state=="answered")]|length')" "12"
# PRIMITIVE 2 under concurrency (the reviewer's already-correct path, pinned):
RD2="$WORK/race-dedup"; mkdir -p "$RD2"
for k in a b c d e; do
  ( do_dedup_record "$GOOD" forkRace "doss-$k" >/dev/null 2>&1; echo "$?" > "$RD2/$k" ) &
done
wait
gd=0; for f in "$RD2"/*; do [[ "$(cat "$f")" == 0 ]] && gd=$((gd+1)); done
ck "EXACTLY ONE of 5 concurrent different-dossier dedup writers won" eq "$gd" "1"
ck "the surviving binding is internally consistent (one fork⇒one dossier)" \
   eq "$(do_dedup_get forkRace | sed 's/^doss-.$/OK/')" "OK"

echo ""
echo "── EXIT-DEFER: §5.6 defer/escalate attention verbs (claude-tools-uxl1b) ──"
# The two remaining Inbox verbs as DISTINCT ops: adjust the §4.1 attention tier
# (defer→digest, escalate→blocking) AND disarm the §2.2 timer — no §5.2
# resolution, no §7.4 latch. A real move nulls timer_fire_at (both targets are
# non-auto-proceed tiers, claude-tools-fyci). Total + idempotent. JS twin:
# cf/src/dossier.js dossierSetAttention (cf/test/defer-escalate.spec.js).
TIER() { JFIELD "$1" '.tier'; }
defer_then_tier()    { do_dossier_defer    "$1" "$2" >/dev/null 2>&1 && [[ "$(TIER "$2")" == "$3" ]]; }
escalate_then_tier() { do_dossier_escalate "$1" "$2" >/dev/null 2>&1 && [[ "$(TIER "$2")" == "$3" ]]; }
# seed a BLOCKING decision dossier; answer one item (recommendation recorded).
do_dossier_put "$GOOD" "$(mk deA 2 "[$(item da1 open),$(item da2 open)]")" >/dev/null
do_item_set_state "$GOOD" deA da2 answered '{"decision":"approve"}' >/dev/null 2>&1
ck "defer: blocking→digest (push out without resolution)"      defer_then_tier "$GOOD" deA digest
ck "  open item left untouched (no resolution)"                eq "$(ISTATE deA da1)" "open"
ck "  answered item left untouched (recommendation NOT consumed)"  eq "$(ISTATE deA da2)" "answered"
ck "  recorded .response preserved verbatim" \
   eq "$(JFIELD deA '.items[]|select(.id=="da2").response.decision')" "approve"
ck "  every consequence_applied latch still false"             eq "$(JFIELD deA '[.items[]|select(.consequence_applied==false)]|length')" "2"
ck "  timer_fire_at null (deA never armed; disarm is a no-op here)"  eq "$(JFIELD deA '.timer_fire_at')" "null"
ck "defer idempotent at the digest floor (success, no move)"   defer_then_tier "$GOOD" deA digest
ck "escalate: digest→blocking (the reverse)"                   escalate_then_tier "$GOOD" deA blocking
ck "escalate idempotent at the blocking ceiling"               escalate_then_tier "$GOOD" deA blocking
ck "round-trip preserved the item set (2 items, da1 open, da2 answered)" \
   eq "$(JFIELD deA '[.items[]]|length')" "2"
# timed-fyi is the auto-proceed lane — the verbs move OUT of it AND disarm it.
# Plant with an ARMED timer so the §2.2 disarm (timer_fire_at→null) is observable
# (claude-tools-fyci — kill the digest+armed-timer edge at the source). deF ALSO
# arms a REAL §2.2 substrate timer (id==dossier id, past fire_at ⇒ timer-due) so
# escalate's soft-disarm (timer-ack) is proven end-to-end, not just the envelope
# field (code-review #1). The timer-due output is fed to grep via ck's stdin.
do_dossier_put "$GOOD" "$(jq -c '.tier="timed-fyi"|.timer_fire_at="2026-06-01T00:00:00Z"' <<<"$(mk deF 2 "[$(item df1 open)]")")" >/dev/null
co_request "$GOOD" timer-arm deF "2026-06-01T00:00:00Z" >/dev/null 2>&1
ck "  BEFORE escalate: deF's armed §2.2 timer surfaces in timer-due" \
   grep -qx deF <<<"$(co_request "$GOOD" timer-due "2030-01-01T00:00:00Z" 2>/dev/null)"
ck "escalate(timed-fyi)→blocking (out of the auto-proceed lane)"  escalate_then_tier "$GOOD" deF blocking
ck "  escalate DISARMED the timer_fire_at field (→null — fyci)"   eq "$(JFIELD deF '.timer_fire_at')" "null"
ckn "  escalate SOFT-DISARMED the §2.2 substrate timer (gone from timer-due — fyci)" \
   grep -qx deF <<<"$(co_request "$GOOD" timer-due "2030-01-01T00:00:00Z" 2>/dev/null)"
do_dossier_put "$GOOD" "$(jq -c '.tier="timed-fyi"|.timer_fire_at="2026-06-01T00:00:00Z"' <<<"$(mk deG 2 "[$(item dg1 open)]")")" >/dev/null
ck "defer(timed-fyi)→digest (out of the auto-proceed lane, never stays timed-fyi)"  defer_then_tier "$GOOD" deG digest
ck "  defer DISARMED the timer (timer_fire_at→null — fyci)"       eq "$(JFIELD deG '.timer_fire_at')" "null"
# rejection arms — a missing/empty dossier is rejected (no write).
ckn "defer on a missing dossier ⇒ reject"     do_dossier_defer "$GOOD" deNope
ckn "escalate on a missing dossier ⇒ reject"  do_dossier_escalate "$GOOD" deNope

echo ""
echo "── ANTI-DRIFT (structural — sibling surfaces untouched) ──"
ck "T4 §4 registry dossier⇒2 (v2 §11 Mermaid amend; substrate added no record type)"  eq "$(co__schema_version dossier)" "2"
ck "substrate added NO §4 record type — 'dossier_dedup' unregistered" \
   eq "$(co__schema_version dossier_dedup)" ""
ck "dedup record is a T5 sibling namespace, NOT records/ (§10.3 precedent)" \
   test -f "$CO_STORE/dossier-dedup/claude-tools-65z.json"
ckn "dedup record is NOT a §4 records/ entry" \
   test -f "$CO_STORE/records/dossier_dedup.claude-tools-65z.json"
caps="$(co_capabilities 2>/dev/null || true)"
ck "T4 co_capabilities still EXACTLY four §2 lines"         eq "$(grep -c '§2' <<<"$caps" || true)" "4"
ckn "dossier-* is NOT advertised as a §2 capability"        grep -q 'do_dossier' <<<"$caps"

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " test-dossier (T5.1, claude-tools-fuy):  PASS=$PASS  FAIL=$FAIL"
echo "══════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
