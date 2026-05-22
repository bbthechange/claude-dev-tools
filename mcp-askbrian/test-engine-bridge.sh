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

echo "── 5. poll_once post-answer (N=1 dossier returns items[0]) ──"
OUT="$("$BRIDGE" poll_once "$DID")"; RC=$?
[[ "$RC" -eq 0 && -n "$OUT" ]] || fail "expected JSON on stdout, rc=$RC out=[$OUT]"
COUNT="$(printf '%s' "$OUT" | jq -r '.items | length')"
[[ "$COUNT" == "1" ]] || fail "expected items.length=1, got $COUNT (raw=$OUT)"
CHOSEN="$(printf '%s' "$OUT" | jq -r '.items[0].chosen')"
LABEL="$(printf '%s' "$OUT" | jq -r '.items[0].chosen_label')"
[[ "$CHOSEN" == "b" ]]      || fail "expected chosen=b, got $CHOSEN"
[[ "$LABEL"  == "Go B" ]]   || fail "expected label='Go B', got $LABEL"
echo "  items=$COUNT chosen=$CHOSEN label=$LABEL OK"

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

echo "── 8. multi-item dossier (N=3) regression for claude-tools-88e ─"
# Background: the original poll_once jq did `map(... ) | .[0]` and returned
# only the first resolved item, leaking the other N-1 answers. Worker would
# then re-ask the missing items → duplicate dossier in Brian's Inbox. Repro
# here: post a 3-item dossier, answer all 3, assert poll_once returns ALL 3
# with the right chosen values matched to the right item_ids.
TREF3="smoke-bead-003-multi"
DID3="$("$BRIDGE" id_for "$TREF3")"
GI3=$(jq -cn --arg id "$DID3" --arg bref "$TREF3" '
  { id:$id, kind:"decide", trigger:"worker_stuck", bead_ref:$bref,
    tier:"blocking", timer_fire_at:null,
    source:{
      tldr:"Three independent forks bundled into one ask.",
      ask:"Three forks: where, how, and which mechanism?",
      sections:[
        {heading:"What this is", prose:"A synthetic 3-item dossier exercising the multi-item return path."},
        {heading:"Why three", prose:"Real-world dossiers bundle related forks so Brian decides them together — see claude-tools-240."},
        {heading:"Why a human", prose:"It is a regression test for the multi-item leak in poll_once."}],
      diagrams:[{caption:"Trivial", content:"flowchart TD\n  A[\"Ask\"] --> B[\"Pick\"]"}],
      full_detail:"Three independent forks. Each is a pick-option item with two options. The bridge previously returned only item 1 — this test asserts it now returns all three. The 240 closing-gate test caught this in production at 11:10Z when Brian answered all three on his phone and the worker only saw the first answer, then re-emitted the entire dossier 6h later.",
      options:[],
      recommendation:null,
      reversible:"fully reversible — scratch store only"},
    items:[
      { id:($id + "-d1"), kind:"pick-option",
        framing:{ ask:"Where should the new file live?", why:"location matters" },
        context_anchor:{ where:"loc fork", expansion:"pick a directory" },
        options:[
          {option_id:"loc-a", label:"Under lib/", blast_radius:"co-locates with siblings",
           consequence_block:{creates:[], unblocks:[], labels:[], status_changes:[]}},
          {option_id:"loc-b", label:"Under helpers/", blast_radius:"clearer boundary",
           consequence_block:{creates:[], unblocks:[], labels:[], status_changes:[]}}],
        recommendation:{value:"loc-a", why:"matches the existing layout"},
        reversible:"trivially reversible",
        consequence_block:{creates:[], unblocks:[], labels:[], status_changes:[]}},
      { id:($id + "-d2"), kind:"pick-option",
        framing:{ ask:"Which format should the output use?", why:"format matters" },
        context_anchor:{ where:"fmt fork", expansion:"pick an output shape" },
        options:[
          {option_id:"fmt-a", label:"JSON object", blast_radius:"machine-readable",
           consequence_block:{creates:[], unblocks:[], labels:[], status_changes:[]}},
          {option_id:"fmt-b", label:"Plain text", blast_radius:"human-readable but fragile",
           consequence_block:{creates:[], unblocks:[], labels:[], status_changes:[]}}],
        recommendation:{value:"fmt-a", why:"the worker parses the result"},
        reversible:"reversible with a follow-up",
        consequence_block:{creates:[], unblocks:[], labels:[], status_changes:[]}},
      { id:($id + "-d3"), kind:"pick-option",
        framing:{ ask:"Which dispatch mechanism?", why:"mechanism matters" },
        context_anchor:{ where:"ref fork", expansion:"pick a transport" },
        options:[
          {option_id:"ref-a", label:"Inline call", blast_radius:"simplest possible",
           consequence_block:{creates:[], unblocks:[], labels:[], status_changes:[]}},
          {option_id:"ref-b", label:"Indirect via dispatcher", blast_radius:"more code, more flexibility",
           consequence_block:{creates:[], unblocks:[], labels:[], status_changes:[]}}],
        recommendation:{value:"ref-a", why:"YAGNI"},
        reversible:"reversible",
        consequence_block:{creates:[], unblocks:[], labels:[], status_changes:[]}}]}')
OUT="$("$BRIDGE" write_polished "$GI3" 2>&1)"; RC=$?
[[ "$RC" -eq 0 ]] || fail "write_polished N=3 rc=$RC stderr=$OUT"

# Pre-answer: poll_once should return empty (no items answered yet).
OUT="$("$BRIDGE" poll_once "$DID3")"; RC=$?
[[ "$RC" -eq 0 && -z "$OUT" ]] || fail "N=3 pre-answer expected empty, rc=$RC out=[$OUT]"

# Answer only item 1 and item 2; item 3 still open ⇒ poll_once must STILL
# return empty (the whole dossier is not yet resolved — this is the load-
# bearing fix; the old code would return item 1 alone).
do_item_set_state "$BEARER" "$DID3" "$DID3-d1" answered \
  '{"selected_option_id":"loc-a","decision":"loc-a"}' >/dev/null 2>&1 || fail "set d1 failed"
# d2 goes the full open→answered→applied path; covers the §4.1.1 applied
# state code path explicitly (the original bug used .[0] which would pick
# either answered or applied — the fix must accept both as resolved).
do_item_set_state "$BEARER" "$DID3" "$DID3-d2" answered \
  '{"selected_option_id":"fmt-a","decision":"fmt-a"}' >/dev/null 2>&1 || fail "set d2 (answered) failed"
do_item_set_state "$BEARER" "$DID3" "$DID3-d2" applied \
  '{"selected_option_id":"fmt-a","decision":"fmt-a"}' >/dev/null 2>&1 || fail "set d2 (applied) failed"
OUT="$("$BRIDGE" poll_once "$DID3")"; RC=$?
[[ "$RC" -eq 0 && -z "$OUT" ]] || fail "N=3 partial-answer must stay pending (the 88e bug); got rc=$RC out=[$OUT]"
echo "  partial-answer correctly held (2/3 answered, dossier still pending) OK"

# Answer item 3 ⇒ all 3 resolved ⇒ poll_once returns all three items.
do_item_set_state "$BEARER" "$DID3" "$DID3-d3" answered \
  '{"selected_option_id":"ref-a","decision":"ref-a"}' >/dev/null 2>&1 || fail "set d3 failed"
OUT="$("$BRIDGE" poll_once "$DID3")"; RC=$?
[[ "$RC" -eq 0 && -n "$OUT" ]] || fail "N=3 all-answered expected JSON, rc=$RC out=[$OUT]"
COUNT="$(printf '%s' "$OUT" | jq -r '.items | length')"
[[ "$COUNT" == "3" ]] || fail "expected items.length=3, got $COUNT (raw=$OUT)"
# Verify each item_id and chosen value came through correctly — the original
# bug returned the wrong (singular) shape with only item 1.
for spec in "d1:loc-a:Under lib/" "d2:fmt-a:JSON object" "d3:ref-a:Inline call"; do
  IFS=":" read -r suffix want_chosen want_label <<<"$spec"
  iid="$DID3-$suffix"
  got_chosen="$(printf '%s' "$OUT" | jq -r --arg iid "$iid" '.items[] | select(.item_id==$iid) | .chosen')"
  got_label="$(printf '%s' "$OUT" | jq -r --arg iid "$iid" '.items[] | select(.item_id==$iid) | .chosen_label')"
  [[ "$got_chosen" == "$want_chosen" ]] || fail "item $iid expected chosen=$want_chosen, got $got_chosen"
  [[ "$got_label"  == "$want_label"  ]] || fail "item $iid expected label='$want_label', got '$got_label'"
done
echo "  all 3 items returned with correct chosen/label OK"

echo
echo "ALL ENGINE-BRIDGE CHECKS PASSED"
