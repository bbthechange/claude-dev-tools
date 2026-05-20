#!/usr/bin/env bash
# Focused test for mcp-askbrian/helpers/engine-bridge.sh.
#
# Exercises each sub-command (id_for, write_polished, write_fallback,
# poll_once) against the in-process bash store (the standalone / oracle /
# conformance fallback that activates when COORDINATOR_URL is unset). Mirrors
# the test-*.sh convention in beads-runner/lib/.
set -uo pipefail

ME_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$ME_DIR/.." && pwd)"
SCRATCH="${TEST_SCRATCH:-$ME_DIR/.test-scratch/engine-bridge}"
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
export CO_STORE="$SCRATCH/store"

BRIDGE="$ME_DIR/helpers/engine-bridge.sh"
TREF="smoke-bead-001"

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "── 1. id_for ────────────────────────────────────────────"
DID="$("$BRIDGE" id_for "$TREF")" || fail "id_for rc=$?"
[[ "$DID" == "stuck-$TREF" ]] || fail "expected stuck-$TREF, got $DID"
echo "  did=$DID OK"

echo "── 2. write_fallback (jq deterministic / B3) ─────────────"
ASK=$(jq -cn '{tldr:"Worker hit a fork on smoke.", ask:"Pick A or B?",
               options:[
                 {option_id:"a", label:"Go A", blast_radius:"locks in A; reversible",
                  consequence_block:{creates:[], unblocks:[], labels:[], status_changes:[]}},
                 {option_id:"b", label:"Go B", blast_radius:"locks in B; not reversible",
                  consequence_block:{creates:[], unblocks:[], labels:[], status_changes:[]}}],
               recommendation:{value:"a", why:"A is reversible"},
               reversible:"A is reversible; B is not."}')
OUT="$("$BRIDGE" write_fallback "$DID" "$TREF" "$ASK" 2>&1)"
RC=$?
[[ "$RC" -eq 0 ]] || fail "write_fallback rc=$RC stderr=$OUT"
echo "  $OUT OK"

echo "── 3. poll_once pre-answer (empty stdout, rc 0) ──────────"
OUT="$("$BRIDGE" poll_once "$DID")"; RC=$?
[[ "$RC" -eq 0 && -z "$OUT" ]] || fail "expected empty stdout rc 0, got rc=$RC out=[$OUT]"
echo "  OK"

echo "── 4. simulate human answer via do_item_set_state ────────"
. "$ROOT/beads-runner/lib/stuck-routing.sh"
. "$ROOT/beads-runner/lib/notification.sh"
. "$ROOT/beads-runner/lib/co-http-transport.sh"
BEARER="bearer-runner-mcp-askbrian"
do_item_set_state "$BEARER" "$DID" "$DID-d1" answered \
  '{"selected_option_id":"b","decision":"b"}' \
  >/dev/null 2>&1 || fail "do_item_set_state failed"
echo "  flipped $DID-d1 → answered OK"

echo "── 5. poll_once post-answer ──────────────────────────────"
OUT="$("$BRIDGE" poll_once "$DID")"; RC=$?
[[ "$RC" -eq 0 && -n "$OUT" ]] || fail "expected JSON on stdout, rc=$RC out=[$OUT]"
CHOSEN="$(printf '%s' "$OUT" | jq -r '.chosen')"
LABEL="$(printf '%s' "$OUT" | jq -r '.chosen_label')"
[[ "$CHOSEN" == "b" ]]      || fail "expected chosen=b, got $CHOSEN"
[[ "$LABEL"  == "Go B" ]]   || fail "expected label='Go B', got $LABEL"
echo "  chosen=$CHOSEN label=$LABEL OK"

echo "── 6. write_polished (synthetic builder output) ──────────"
TREF2="smoke-bead-002"
DID2="$("$BRIDGE" id_for "$TREF2")"
GI=$(jq -cn --arg id "$DID2" --arg bref "$TREF2" '
  { id:$id, kind:"decide", trigger:"worker_stuck", bead_ref:$bref,
    tier:"blocking", timer_fire_at:null,
    source:{
      tldr:"Polished-path smoke.",
      ask:"Should the smoke ship?",
      sections:[
        {heading:"What this is", prose:"A synthetic builder-style envelope to exercise write_polished."},
        {heading:"Why a human", prose:"It is a smoke test; the human is the test harness."}],
      diagrams:[
        {caption:"Trivial flowchart", content:"flowchart TD\n  A[\"Ask\"] --> B[\"Pick\"]"}],
      full_detail:"This is the synthetic full-detail prose body for the smoke test. It is several sentences long so the §5.1 gate accepts it as a stand-alone tier.",
      options:[
        {option_id:"yes", label:"Ship", blast_radius:"smoke passes; mark B2 ready",
         consequence_block:{creates:[], unblocks:[], labels:[], status_changes:[]}},
        {option_id:"no",  label:"Hold", blast_radius:"smoke fails; iterate before merging",
         consequence_block:{creates:[], unblocks:[], labels:[], status_changes:[]}}],
      recommendation:{value:"yes", why:"the bridge passes its checks"},
      reversible:"fully reversible — scratch CO_STORE only"},
    items:[
      { id:($id + "-d1"),
        kind:"pick-option",
        framing:{ ask:"Ship the smoke?", why:"the harness needs a respondable item for poll_once" },
        context_anchor:{
          where:"Smoke test of mcp-askbrian write_polished",
          expansion:"This item exists only so the §5.2 gate has something to validate."},
        options:[
          {option_id:"yes", label:"Ship", blast_radius:"smoke passes; mark B2 ready",
           consequence_block:{creates:[], unblocks:[], labels:[], status_changes:[]}},
          {option_id:"no",  label:"Hold", blast_radius:"smoke fails; iterate before merging",
           consequence_block:{creates:[], unblocks:[], labels:[], status_changes:[]}}],
        recommendation:{value:"yes", why:"the bridge passes its checks"},
        reversible:"fully reversible",
        consequence_block:{creates:[], unblocks:[], labels:[], status_changes:[]}}]}')
OUT="$("$BRIDGE" write_polished "$GI" 2>&1)"; RC=$?
[[ "$RC" -eq 0 ]] || fail "write_polished rc=$RC stderr=$OUT"
echo "  $OUT OK"

echo "── 7. dg__validate_dossier accepts both persisted records ─"
for did in "$DID" "$DID2"; do
  REC="$(do_dossier_get "$BEARER" "$did")" || fail "could not fetch $did"
  dg__validate_dossier "$REC" >/dev/null 2>&1 || fail "dg__validate_dossier rejected $did"
done
echo "  OK"

echo
echo "ALL ENGINE-BRIDGE CHECKS PASSED"
