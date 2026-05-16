#!/bin/bash
# beads-runner/lib/test-notification.sh — focused unit test for the T5.6
# NOTIFICATION: §4.3 persisted tiered record, one-per-Dossier,
# creation≠dispatch (claude-tools-ks2; epic claude-tools-glk).
#
# T5.6's OWN test surface. Deliberately NOT a member of the T1 conformance
# suite (beads-runner/conformance/, owned by T1a/T1b) and it touches NO
# sibling test (test-coordinator{,-lease,-reconcile,-capacity,-forensic}.sh,
# test-dossier.sh, test-dossier-gen.sh, test-consequence.sh,
# test-timed-fyi.sh). It exercises ONLY notification.sh, consuming the T5.2
# creation hook (dg_generate), the T5.1 substrate (do_dossier_*), and the T4
# §2.1/§4 store + §9.1 chokepoint as black boxes — the SAME self-contained
# CO_STORE pattern the sibling focused tests use.
#
# Asserts the EXIT CRITERIA T5.6 owns against INTERFACE.md v1 §4.3 / §0.3:
#   1. EXACTLY ONE Notification row per Dossier (NOT one-per-Item): a 15-item
#      dossier yields one Notification; re-emit is idempotent (still one).
#   2. created_at set with dispatched=false BEFORE any send (creation≠dispatch
#      — the C3 seam); dispatched/dispatched_at flip ONLY on send and only
#      false→true ONCE; fire-and-forget REJECTED.
#   3. tier mirrors the §4.1 dossier tier (blocking|timed-fyi|digest); the
#      Notification stays terse — it structurally CANNOT carry content (the
#      §5 dossier body does — principle 2).
#   4. schema_version=1 + principal stamped at the §9.1 chokepoint; an unknown
#      higher version REJECTED on BOTH write and read paths (§0.3).
#   5. Binds §4.3; channel is OPAQUE (stored verbatim — a later digest rollup
#      needs no schema change); NO §4 record type added; no_* not advertised
#      as a §2 capability. (Full no-regression is the SUITE's job — the
#      sibling lib tests + conformance, run as the gate.)
#
# Self-contained: its own CO_STORE under mktemp; shares NO state with the
# conformance harness or sibling tests.
set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/notification.sh"
[[ -f "$LIB" ]] || { echo "FATAL: notification.sh not found at $LIB"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
ck()  { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }   # expect SUCCESS
ckn() { if "${@:2}" >/dev/null 2>&1; then bad "$1"; else ok "$1"; fi; }   # expect FAILURE
eq()  { [[ "$1" == "$2" ]]; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CO_STORE="$WORK/store"
unset CO_EXPECTED_TOKEN PRINCIPAL_V1 2>/dev/null || true

# shellcheck source=/dev/null
source "$LIB"           # → dossier-gen.sh → dossier.sh → coordinator.sh

GOOD="bearer-runner-secret-xyz"
NID()  { no__notif_id "$1"; }
NREC() { co_request "$GOOD" get notification "$(NID "$1")" 2>/dev/null; }
NF()   { NREC "$1" | jq -r "$2" 2>/dev/null; }   # NF <dossier> <jq>
# Count §4.3 rows in the §4 store (proves one-per-Dossier structurally —
# notification.<id>.json is the only notification record file shape).
NCOUNT() { ls "$CO_STORE"/records/notification.*.json 2>/dev/null | wc -l | tr -d ' '; }

# §4.1 envelope — body OPAQUE (substrate round-trips it; §5 = T5.2). Used to
# seed a dossier via the T5.1 store directly (no_emit reads the tier off it).
mk() {  # mk <id> <tier> <items-json-array>
  jq -cn --arg id "$1" --arg tier "$2" --argjson items "$3" '
    { id:$id, schema_version:1, kind:"decide", trigger:"proactive_checkpoint",
      bead_ref:"claude-tools-65z", tier:$tier,
      created_at:"2026-05-16T00:00:00Z", timer_fire_at:null,
      body:{ dossier_schema_version:1, tldr:"opaque", sections:[],
             diagrams:[], full_detail:"T5.2 owns this" },
      items:$items }'
}
item() { jq -cn --arg i "$1" '
    { id:$i, kind:"approve-reject", framing:{}, context_anchor:{where:"x",expansion:"y"},
      consequence_block:{cb_schema_version:1,creates:[],unblocks:[],labels:[],status_changes:[]},
      state:"open", response:null, consequence_applied:false, applied_at:null }'; }
# 15 distinct items ⇒ a 15-item dossier (must still yield ONE Notification).
items15() { local a="" i; for i in $(seq 1 15); do a="$a$([[ -n "$a" ]] && echo ,)$(item "i$i")"; done; printf '[%s]' "$a"; }

echo "── EXIT-1: EXACTLY ONE Notification per Dossier (NOT one-per-Item) ──"
do_dossier_put "$GOOD" "$(mk d15 blocking "$(items15)")" >/dev/null
ck  "the seeded dossier really has 15 Items"            eq "$(co_request "$GOOD" get dossier d15 | jq -r '.items|length')" "15"
NID15="$(no_emit "$GOOD" d15)"
ck  "no_emit succeeds on a 15-item dossier"             test -n "$NID15"
ck  "exactly ONE Notification row exists (NOT 15, NOT one-per-Item)" eq "$(NCOUNT)" "1"
ck  "the row announces the dossier (dossier_ref=d15)"   eq "$(NF d15 .dossier_ref)" "d15"
ck  "notification id is derived one-per-Dossier"        eq "$NID15" "notif.d15"
# Re-emit is idempotent: still ONE row, created_at NOT reset.
CA1="$(NF d15 .created_at)"
NID15B="$(no_emit "$GOOD" d15)"
ck  "re-emit returns the SAME notification id"          eq "$NID15B" "$NID15"
ck  "re-emit did NOT create a second row (still one)"   eq "$(NCOUNT)" "1"
ck  "re-emit did NOT reset created_at (one fork ⇒ one Notification)" eq "$(NF d15 .created_at)" "$CA1"

echo ""
echo "── EXIT-2: creation≠dispatch (C3 seam) · false→true ONCE · no fire-&-forget ──"
do_dossier_put "$GOOD" "$(mk dC3 timed-fyi "[$(item a1)]")" >/dev/null
no_emit "$GOOD" dC3 >/dev/null
ck  "created_at set at creation (a row exists before any send)" test -n "$(NF dC3 .created_at)"
ck  "dispatched=false at creation (creation≠dispatch — C3)"     eq "$(NF dC3 .dispatched)" "false"
ck  "dispatched_at=null at creation"                            eq "$(NF dC3 .dispatched_at)" "null"
ck  "channel=null at creation"                                  eq "$(NF dC3 .channel)" "null"
# fire-and-forget FORBIDDEN: dispatch with NO row is rejected.
ckn "fire-and-forget REJECTED — dispatch a never-emitted Notification" \
    no_dispatch_for_dossier "$GOOD" dNeverEmitted
# send: dispatched/dispatched_at flip ONLY here.
ck  "no_dispatch succeeds (the send)"                   no_dispatch_for_dossier "$GOOD" dC3
ck  "dispatched flipped true ONLY on send"              eq "$(NF dC3 .dispatched)" "true"
ck  "dispatched_at stamped ONLY on send"                test -n "$(NF dC3 .dispatched_at)"
ckn "dispatched_at is no longer null"                   eq "$(NF dC3 .dispatched_at)" "null"
# false→true EXACTLY ONCE — a SECOND dispatch is rejected (single-writer-set).
ckn "SECOND dispatch REJECTED (false→true ONCE — C3 latch)" \
    no_dispatch_for_dossier "$GOOD" dC3
DA1="$(NF dC3 .dispatched_at)"
no_dispatch_for_dossier "$GOOD" dC3 >/dev/null 2>&1 || true
ck  "rejected re-dispatch did NOT re-stamp dispatched_at (NO write)" eq "$(NF dC3 .dispatched_at)" "$DA1"

echo ""
echo "── EXIT-3: tier mirrors §4.1 · terse by structure (principle 2) ──"
for T in blocking timed-fyi digest; do
  D="dT_${T//-/_}"
  do_dossier_put "$GOOD" "$(mk "$D" "$T" "[$(item q1)]")" >/dev/null
  no_emit "$GOOD" "$D" >/dev/null
  ck  "tier mirrors the §4.1 dossier tier ($T)"          eq "$(NF "$D" .tier)" "$T"
done
# Terse BY STRUCTURE: the §4.3 field set is closed — no body/content key. An
# injected content key is REJECTED by no__validate (principle 2: the §5
# dossier body carries the content, the Notification never does).
GOODREC="$(NREC dT_blocking)"
ck  "a well-formed §4.3 record validates"               no__validate "$GOODREC"
ckn "a record with an injected 'body' key REJECTED (terse — principle 2)" \
    no__validate "$(jq -c '.body={tldr:"leak"}' <<<"$GOODREC")"
ckn "a record with a 'content' key REJECTED (no content — principle 2)" \
    no__validate "$(jq -c '.content="payload"' <<<"$GOODREC")"
ck  "the §4.3 record carries NO content/body/payload key (closed set)" \
    eq "$(printf '%s' "$GOODREC" | jq -r '[keys[]|select(.=="body" or .=="content" or .=="payload" or .=="items")]|length')" "0"

echo ""
echo "── EXIT-4: schema_version=1 · principal stamped (§9.1) · §0.3 ──"
ck  "schema_version=1 persisted (§4.3)"                  eq "$(NF dT_blocking .schema_version)" "1"
ck  "bound version READ from the T4 §4 registry (not a local literal)" \
    eq "$(no__bound_sv)" "$(co__schema_version notification)"
ck  "T4 STAMPED principal=PRINCIPAL_V1 at the §9.1 chokepoint" \
    eq "$(NF dT_blocking .principal)" "brian"
# §0.3 — unknown HIGHER schema_version rejected on the WRITE path (no__validate
# is the producer-side gate; the T4 store re-enforces it too).
ckn "§0.3 — schema_version 2 REJECTED by no__validate (unknown higher)" \
    no__validate "$(jq -c '.schema_version=2' <<<"$GOODREC")"
ckn "§0.3 — string \"1\" schema_version REJECTED (jq type-check)" \
    no__validate "$(jq -c '.schema_version="1"' <<<"$GOODREC")"
# §0.3 also bound on the READ path: a v3 slipped directly into the store
# (bypassing the front door) must be REJECTED by no_get, not parsed.
mkdir -p "$CO_STORE/records"
printf '%s\n' "$(jq -c '.schema_version=3 | .principal="brian"' <<<"$GOODREC" | jq -c '.id="notif.dRd"')" \
  > "$CO_STORE/records/notification.notif.dRd.json"
ckn "§0.3 — no_get REJECTS an unknown-higher stored record (read path)" \
    no_get "$GOOD" notif.dRd
# §9.1 — no/invalid bearer ⇒ rejected (the ONE chokepoint, no second path).
ckn "§9.1 — missing bearer ⇒ no_emit REJECTED"          no_emit "" dT_blocking
ckn "§9.1 — emit on a MISSING dossier REJECTED (collapses 401/absent — C4)" \
    no_emit "$GOOD" noSuchDossier

echo ""
echo "── EXIT-5: binds §4.3 · channel OPAQUE · anti-drift (structural) ──"
# channel is an opaque transport tag: stored verbatim, never interpreted; a
# later read-side digest rollup keys off it with NO schema change (C3).
do_dossier_put "$GOOD" "$(mk dCh digest "[$(item z1)]")" >/dev/null
no_emit "$GOOD" dCh >/dev/null
OPAQUE='digest-rollup::weekly::xyz#42'
ck  "no_dispatch accepts an arbitrary OPAQUE channel tag" \
    no_dispatch_for_dossier "$GOOD" dCh "$OPAQUE"
ck  "the opaque channel tag round-trips VERBATIM (no schema change — C3)" \
    eq "$(NF dCh .channel)" "$OPAQUE"
# No §4 record type added; the registry is UNCHANGED (notification was already
# a T4-registered type — T5.6 adds none and never edits the registry).
ck  "T4 §4 registry UNCHANGED — notification⇒1 (no schema bump)" \
    eq "$(co__schema_version notification)" "1"
ck  "dossier registry entry UNTOUCHED (no sibling GATE flipped)" \
    eq "$(co__schema_version dossier)" "1"
ck  "NO §4 record type added — 'notify' unregistered" \
    eq "$(co__schema_version notify)" ""
caps="$(co_capabilities 2>/dev/null || true)"
ckn "no_emit is NOT advertised as a §2 capability"     grep -q 'no_emit' <<<"$caps"
ckn "no_dispatch is NOT advertised as a §2 capability" grep -q 'no_dispatch' <<<"$caps"
ck  "T4 co_capabilities still EXACTLY four §2 lines"   eq "$(grep -c '§2' <<<"$caps" || true)" "4"
# The C3 creation hook: dg_generate (T5.2) → ONE Notification at creation.
GI="$(jq -cn '{ id:"dGen", trigger:"proactive_checkpoint", bead_ref:"claude-tools-65z",
                tier:"timed-fyi",
                source:{ tldr:"t", sections:[{heading:"H",prose:"P"}],
                         diagrams:[], full_detail:"FD" },
                items:[] }')"
NGEN="$(no_for_generation "$GOOD" "$GI")"
ck  "no_for_generation consumes the T5.2 hook + emits ONE Notification" \
    eq "$NGEN" "notif.dGen"
ck  "the generated dossier's Notification mirrors its tier (timed-fyi)" \
    eq "$(NF dGen .tier)" "timed-fyi"
ck  "creation≠dispatch holds via the hook (dispatched=false at creation)" \
    eq "$(NF dGen .dispatched)" "false"

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " test-notification (T5.6, claude-tools-ks2):  PASS=$PASS  FAIL=$FAIL"
echo "══════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
