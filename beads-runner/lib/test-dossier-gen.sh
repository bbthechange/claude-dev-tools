#!/bin/bash
# beads-runner/lib/test-dossier-gen.sh — focused unit test for T5.2 DOSSIER
# GENERATION (claude-tools-9gt; epic claude-tools-glk).
#
# T5.2's OWN test surface. Deliberately NOT a member of the T1 conformance
# suite (owned by T1a/T1b) and it touches NO sibling test. It exercises ONLY
# the §5/§5.1/§5.2/§5.2.1/§5.3 generation surface on dossier-gen.sh, consuming
# the T5.1 §4.1 envelope + T4 §2.1/§4 store + §9.1 chokepoint as a black box.
#
# Asserts the EXIT CRITERIA T5.2 owns against INTERFACE.md v1:
#   1. ONE generation call emits a Dossier whose `body` has ALL FOUR §5.1
#      tiers present + non-empty (diagrams[]=[] ONLY when genuinely
#      non-structural); a shrunk/decision-singular body is REJECTED.
#   2. EVERY emitted Item carries a non-empty context_anchor{where,expansion};
#      an Item lacking it is REJECTED and NOTHING is written (the
#      self-contained-context invariant — a contract violation, not a nit).
#   3. Each Item `kind` is in the CLOSED §5.2 enum and carries a
#      machine-applyable §5.3 ConsequenceBlock (the chosen-option block for
#      pick-option) — schema-validation, incl. §0.3 cb-version reject.
#   4. The Flow F overview profile (deep body + zero / all-fyi-objectable)
#      AND a mixed multi-item review BOTH emit from the SAME body⊃items[]
#      shape through the SAME validator — NO per-profile schema branch.
#   5. Binds the §5 SCHEMA + item-granularity, NEVER the pass count: a
#      swapped authoring seam (DG_AUTHOR_CMD) still yields a schema-valid
#      dossier, and a swapped author emitting an INVALID §5 is STILL
#      rejected (the schema is the contract, never the generator). Sibling
#      surfaces structurally untouched (no §4 record type added; the §7.2
#      worker-ask consumption path produces the §5.2.1 decision profile).
#  (Full T1 conformance + the sibling focused tests stay PASS/zero-FAIL with
#   no GATE flipped — the SUITE's job, run separately as the quality gate;
#   this change adds dossier-gen.sh + this file ONLY.)
#
# Self-contained: its own CO_STORE under mktemp; shares NO state with the T1
# harness or the sibling tests.
set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dossier-gen.sh"
[[ -f "$LIB" ]] || { echo "FATAL: dossier-gen.sh not found at $LIB"; exit 2; }

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
# claude-tools-69u8: isolate the dossier-author audit log from the TOP — the §5
# schema tests below (the `swap`/`swapbad` DG_AUTHOR_CMD fixtures) call
# dg_generate BEFORE the B3 section's own export, so without this they leaked
# fixture rows into the user's REAL $HOME/.cache audit log. The B3 section
# re-`rm`s this same path to assert on fresh lines.
export DG_AUDIT_LOG="$WORK/dossier-author-audit.jsonl"
unset CO_EXPECTED_TOKEN PRINCIPAL_V1 DG_AUTHOR_CMD 2>/dev/null || true

# shellcheck source=/dev/null
source "$LIB"          # sources dossier.sh → coordinator.sh (consumer binding)

GOOD="bearer-runner-secret-xyz"
GET()    { co_request "$GOOD" get dossier "$1" 2>/dev/null; }            # raw §4 record
JF()     { GET "$1" | jq -r "$2" 2>/dev/null; }                          # JF <id> <jq>

# A final machine-applyable §5.3 block (cb_schema_version stamped — these
# fixtures are POST-author §5 items, the form dg__validate_item gates; the
# author's `cb_schema_version //= sv` makes re-stamp via dg_generate a no-op).
# Sibling test-dossier.sh likewise hardcodes the bound `cb_schema_version`
# (v2 — the §11 Mermaid amend coarse single-source bump 1→2).
CB='{"cb_schema_version":2,"creates":[{"title":"follow-up","type":"task"}],"unblocks":[],"labels":[],"status_changes":[]}'

# §5.2 Item specs (generation-input form: §5 content, NO §4.1.1 record fields —
# dg_generate adds the clean open/null/false/null record).
item_ar() {  # approve-reject
  jq -cn --arg id "$1" --argjson cb "$CB" '
    { id:$id, kind:"approve-reject",
      framing:{ ask:"Approve the schema rename?", why:"It unblocks T6b." },
      context_anchor:{ where:"impl stage of claude-tools-xyz, the §5 renderer seam",
                       expansion:"The field was renamed in T5.1; T6b binds the new name." },
      reversible:"Reversible — a rename revert is one commit.",
      consequence_block:$cb }'
}
item_po() {  # pick-option (two options, each its own applyable block)
  jq -cn --arg id "$1" --argjson cb "$CB" '
    { id:$id, kind:"pick-option",
      framing:{ ask:"Which auth boundary?", why:"It forecloses the token model." },
      context_anchor:{ where:"design stage — reached the auth boundary on the coordinator",
                       expansion:"v1 is a constant principal (§9.1); the pick sets the C7 seam shape." },
      reversible:"Hard to reverse — the token model is load-bearing.",
      recommendation:{ value:"opt-bearer", why:"Matches the BC-34 keychain family." },
      options:[ { option_id:"opt-bearer", label:"Static bearer", blast_radius:"unblocks T3; forecloses per-call mint", consequence_block:$cb },
                { option_id:"opt-mint",   label:"Mint per call", blast_radius:"unblocks rotation; forecloses the no-migration C7", consequence_block:$cb } ] }'
}
item_rec() {  # approve-recommendation
  jq -cn --arg id "$1" --argjson cb "$CB" '
    { id:$id, kind:"approve-recommendation",
      framing:{ ask:"Adopt the recommended retry posture?", why:"Closes claude-tools-ntn." },
      context_anchor:{ where:"impl stage — runner classify_failure precedence",
                       expansion:"A 500 outage misclassifies as UNKNOWN; the rec adds backoff." },
      reversible:"Reversible — the posture is a config constant.",
      recommendation:{ value:"backoff+reclassify", why:"A >30s outage must not burn the retry budget." },
      consequence_block:$cb }'
}
item_ff() {  # freeform-edit
  jq -cn --arg id "$1" --argjson cb "$CB" '
    { id:$id, kind:"freeform-edit",
      framing:{ ask:"Edit the §5.2 framing wording.", why:"Tone pass." },
      context_anchor:{ where:"docs stage — the INTERFACE §5.2 prose",
                       expansion:"Reviewers want the self-contained-context line sharpened." },
      reversible:"Fully reversible — prose only.",
      consequence_block:$cb }'
}
item_fyi() {  # fyi-objectable
  jq -cn --arg id "$1" --argjson cb "$CB" '
    { id:$id, kind:"fyi-objectable",
      framing:{ ask:"Proceeding to ramp the spare-cycles line unless you object.", why:"Flow F overview." },
      context_anchor:{ where:"proactive checkpoint — the §6.3 spare-cycles ramp",
                       expansion:"Day N allows N×14.2% of the 7d budget; this is the auto-proceed." },
      reversible:"Reversible within the window — object to halt.",
      consequence_block:$cb }'
}

# A deep §5.1 body source (structural) + a non-structural variant.
SRC_STRUCT='{ "tldr":"Pick the auth boundary for the coordinator.",
  "ask":"Which token model does v1 adopt?",
  "sections":[{"heading":"Context","prose":"The runner reached the §9.1 chokepoint."},
              {"heading":"Trade-offs","prose":"Static bearer vs per-call mint."}],
  "diagrams":[{"caption":"Auth flow","content":"flowchart LR\n  runner --> authenticate --> principal"}],
  "full_detail":"Standalone: v1 uses a constant principal; the pick fixes the C7 seam so later is one if at the chokepoint, no migration.",
  "structural":true }'
SRC_NONSTRUCT='{ "tldr":"Approve the doc tone pass.",
  "ask":"Approve the §5.2 wording edits?",
  "sections":[{"heading":"Scope","prose":"Prose only; no schema or behavior change."}],
  "full_detail":"Standalone: the edits sharpen the self-contained-context line; nothing structural changes, so no diagram is warranted.",
  "structural":false }'

gi() {  # gi <id> <trigger> <tier> <source-json> <items-json-array>
  jq -cn --arg id "$1" --arg tr "$2" --arg ti "$3" --argjson s "$4" --argjson it "$5" '
    { id:$id, kind:"decide", trigger:$tr, bead_ref:"claude-tools-65z",
      tier:$ti, timer_fire_at:null, source:$s, items:$it }'
}

echo "── EXIT-1: §5.1 body — ALL FOUR tiers mandatory (AD7) ──"
G1="$(gi genA worker_stuck blocking "$SRC_STRUCT" "[$(item_po d1)]")"
id="$(dg_generate "$GOOD" "$G1")"; rc=$?
ck "ONE dg_generate call accepts a well-formed §5 dossier"   eq "$rc" "0"
ck "returns the dossier id"                                  eq "$id" "genA"
ck "envelope round-tripped THROUGH the T5.1 §4.1 store"      eq "$(JF genA '.id')" "genA"
ck "T5.1/§9.1 STAMPED principal (no second auth path here)"  eq "$(JF genA '.principal')" "brian"
ck "§5.1 tldr present + non-empty"                           ne "$(JF genA '.body.tldr')" ""
ck "§5.1 sections[] present + ≥1"                            test "$(JF genA '.body.sections|length')" -ge 1
ck "§5.1 sections[0] heading+prose non-empty"                ne "$(JF genA '.body.sections[0].prose')" ""
ck "§5.1 diagrams[] NON-empty for a STRUCTURAL source"       test "$(JF genA '.body.diagrams|length')" -ge 1
ck "§5.1 full_detail present + non-empty"                    ne "$(JF genA '.body.full_detail')" ""
ck "§5.1 dossier_schema_version stamped (=bound)"            eq "$(JF genA '.body.dossier_schema_version')" "$(do__bound_sv)"
# Non-structural source ⇒ diagrams[] == [] is VALID (other 3 tiers present).
G1b="$(gi genB proactive_checkpoint digest "$SRC_NONSTRUCT" "[$(item_ar d1)]")"
ck "non-structural source ⇒ dg_generate still succeeds"      dg_generate "$GOOD" "$G1b"
ck "§5.1 diagrams[]==[] ONLY when genuinely non-structural"  eq "$(JF genB '.body.diagrams|length')" "0"
ck "the other 3 tiers still present (non-structural)"        ne "$(JF genB '.body.full_detail')" ""
# A shrunk/decision-singular body (empty sections[]) is the AD7 regression.
BADBODY='{"tldr":"x","sections":[],"diagrams":[],"full_detail":"y"}'
ckn "§5.1 empty sections[] REJECTED (decision-singular AD7 regression)" \
   dg__validate_body "$(jq -c --argjson sv "$(do__bound_sv)" '.dossier_schema_version=$sv' <<<"$BADBODY")"
ckn "§5.1 missing full_detail REJECTED (not optional — AD7)" \
   dg__validate_body "$(jq -cn --argjson sv "$(do__bound_sv)" '{dossier_schema_version:$sv,tldr:"x",sections:[{heading:"h",prose:"p"}],diagrams:[]}')"
ckn "§0.3 — body dossier_schema_version=3 REJECTED (unknown higher; bound=2 v2)" \
   dg__validate_body "$(jq -cn '{dossier_schema_version:3,tldr:"x",sections:[{heading:"h",prose:"p"}],diagrams:[],full_detail:"f"}')"
# v2 §11 Mermaid amendment — diagrams[].content MUST be Mermaid source.
ckn "§5.1 v2 — diagrams[].content = PROSE REJECTED (not Mermaid, contract violation)" \
   dg__validate_body "$(jq -cn --argjson sv "$(do__bound_sv)" '{dossier_schema_version:$sv,tldr:"x",sections:[{heading:"h",prose:"p"}],diagrams:[{caption:"c",content:"This is just prose, not a diagram."}],full_detail:"f"}')"
ckn "§5.1 v2 — diagrams[].content = ASCII-art REJECTED (not Mermaid)" \
   dg__validate_body "$(jq -cn --argjson sv "$(do__bound_sv)" '{dossier_schema_version:$sv,tldr:"x",sections:[{heading:"h",prose:"p"}],diagrams:[{caption:"c",content:"+---+\n| A |\n+---+"}],full_detail:"f"}')"
ck  "§5.1 v2 — diagrams[].content = Mermaid flowchart ACCEPTED" \
   dg__validate_body "$(jq -cn --argjson sv "$(do__bound_sv)" '{dossier_schema_version:$sv,tldr:"x",sections:[{heading:"h",prose:"p"}],diagrams:[{caption:"c",content:"flowchart TD\n  A --> B"}],full_detail:"f"}')"
ck  "§5.1 v2 — Mermaid after %%{init}%% directive + ---frontmatter--- ACCEPTED" \
   dg__validate_body "$(jq -cn --argjson sv "$(do__bound_sv)" '{dossier_schema_version:$sv,tldr:"x",sections:[{heading:"h",prose:"p"}],diagrams:[{caption:"c",content:"---\ntitle: T\n---\n%%{init: {\"theme\":\"dark\"}}%%\nsequenceDiagram\n  A->>B: hi"}],full_detail:"f"}')"
ckn "§5.1 v2 — a STRUCTURAL dg_generate with non-Mermaid diagram ⇒ REJECTED, nothing written" \
   dg_generate "$GOOD" "$(gi genBadDg worker_stuck blocking "$(jq -c '.diagrams=[{caption:"x",content:"plain prose, not mermaid"}]' <<<"$SRC_STRUCT")" "[$(item_po d1)]")"
ckn "§5.1 v2 — the non-Mermaid-diagram dossier was NOT written" \
   co_request "$GOOD" get dossier genBadDg

echo ""
echo "── EXIT-2: MANDATORY context_anchor{where,expansion} — reject, no write ──"
NOCTX="$(jq -c 'del(.context_anchor)' <<<"$(item_ar d1)")"
ckn "Item with NO context_anchor ⇒ dg__validate_item REJECTS"  dg__validate_item "$NOCTX"
ckn "dg_generate REJECTS a dossier whose Item lacks context_anchor" \
   dg_generate "$GOOD" "$(gi genNoCtx human_flag blocking "$SRC_STRUCT" "[$NOCTX]")"
ckn "the REJECTED contextless dossier was NOT written"         co_request "$GOOD" get dossier genNoCtx
EMPTYW="$(jq -c '.context_anchor.where=""' <<<"$(item_ar d1)")"
ckn "empty context_anchor.where REJECTED (self-contained-context)"  dg__validate_item "$EMPTYW"
EMPTYE="$(jq -c '.context_anchor.expansion="   "' <<<"$(item_ar d1)")"
ckn "whitespace-only context_anchor.expansion REJECTED"             dg__validate_item "$EMPTYE"
ck  "a valid Item's context_anchor round-trips {where,expansion}" \
   ne "$(JF genA '.items[0].context_anchor.expansion')" ""
ck  "context_anchor.where round-tripped non-empty"             ne "$(JF genA '.items[0].context_anchor.where')" ""

echo ""
echo "── EXIT-3: §5.2 kind enum + machine-applyable §5.3 ConsequenceBlock ──"
ck "kind=approve-reject + applyable cb ⇒ valid"          dg__validate_item "$(item_ar a1)"
ck "kind=pick-option + per-option applyable cb ⇒ valid"  dg__validate_item "$(item_po a2)"
ck "kind=approve-recommendation ⇒ valid"                 dg__validate_item "$(item_rec a3)"
ck "kind=freeform-edit ⇒ valid"                          dg__validate_item "$(item_ff a4)"
ck "kind=fyi-objectable ⇒ valid"                         dg__validate_item "$(item_fyi a5)"
ckn "kind NOT in the CLOSED §5.2 enum ⇒ REJECTED" \
   dg__validate_item "$(jq -c '.kind="decide"' <<<"$(item_ar a6)")"
# pick-option: the chosen-option block is per-option + machine-applyable.
ck "pick-option each option carries a pre-declared consequence_block" \
   eq "$(JF genA '[.items[0].options[].consequence_block]|length')" "2"
ck "pick-option option cb_schema_version stamped (=bound, §0.3)" \
   eq "$(JF genA '.items[0].options[0].consequence_block.cb_schema_version')" "$(do__bound_sv)"
ckn "pick-option missing recommendation ⇒ REJECTED (§5.2)" \
   dg__validate_item "$(jq -c 'del(.recommendation)' <<<"$(item_po a7)")"
ckn "pick-option with NO options ⇒ REJECTED (§5.2)" \
   dg__validate_item "$(jq -c '.options=[]' <<<"$(item_po a8)")"
ckn "pick-option duplicate option_id ⇒ REJECTED (ambiguous chosen block)" \
   dg__validate_item "$(jq -c '.options[1].option_id=.options[0].option_id' <<<"$(item_po a9)")"
# §5.3 machine-applyability gate (the producer-side bind of the frozen schema).
ck  "dg__cb_applyable accepts a bound (v2) four-array block" \
   dg__cb_applyable "$(jq -cn --argjson sv "$(do__bound_sv)" '{cb_schema_version:$sv,creates:[],unblocks:[],labels:[],status_changes:[]}')"
ckn "§0.3 — cb_schema_version=3 REJECTED (unknown higher; bound=2 v2)" \
   dg__cb_applyable '{"cb_schema_version":3,"creates":[]}'
ckn "§5.3 — creates not an array ⇒ REJECTED (not machine-applyable)" \
   dg__cb_applyable "$(jq -cn --argjson sv "$(do__bound_sv)" '{cb_schema_version:$sv,creates:"nope"}')"
ckn "an Item whose cb is NOT machine-applyable ⇒ Item REJECTED" \
   dg__validate_item "$(jq -c '.consequence_block={"cb_schema_version":99}' <<<"$(item_ar a10)")"

echo ""
echo "── EXIT-4: §5.2.1 profiles — SAME body⊃items[] shape, NO schema branch ──"
# (a) Flow F overview — deep body + ZERO items.
ck "Flow F overview: deep body + ZERO items ⇒ valid (§5.2.1)" \
   dg_generate "$GOOD" "$(gi fF0 proactive_checkpoint timed-fyi "$SRC_STRUCT" '[]')"
ck "zero-item overview persisted with items[]==[] (same shape)" \
   eq "$(JF fF0 '.items|length')" "0"
ck "the zero-item overview STILL has a full deep §5.1 body" \
   ne "$(JF fF0 '.body.full_detail')" ""
# (b) Flow F overview — deep body + ALL fyi-objectable items.
ALLFYI="[$(item_fyi f1),$(item_fyi f2),$(item_fyi f3)]"
ck "Flow F overview: deep body + ALL-fyi-objectable ⇒ valid (§5.2.1)" \
   dg_generate "$GOOD" "$(gi fFa proactive_checkpoint timed-fyi "$SRC_STRUCT" "$ALLFYI")"
ck "all-fyi overview: 3 items, all kind=fyi-objectable" \
   eq "$(JF fFa '[.items[]|select(.kind=="fyi-objectable")]|length')" "3"
# (c) Mixed multi-item review — every affordance in ONE dossier.
MIX="[$(item_ar m1),$(item_po m2),$(item_rec m3),$(item_ff m4),$(item_fyi m5)]"
ck "mixed multi-item review (5 kinds) ⇒ valid (§5.2.1)" \
   dg_generate "$GOOD" "$(gi mix stage_gate blocking "$SRC_STRUCT" "$MIX")"
ck "mixed review persisted all 5 independently-respondable items" \
   eq "$(JF mix '.items|length')" "5"
ck "mixed review carries the SAME deep §5.1 body shape" \
   ne "$(JF mix '.body.full_detail')" ""
# (d) The §7.2 worker-ask → §5.2.1 decision dossier (deep body + 1 pick-option).
WASK='{ "tldr":"Worker hit the auth boundary on the fork.",
  "ask":"Pick the token model so the fork can resolve.",
  "options":[ {"option_id":"o-bearer","label":"Static bearer","blast_radius":"unblocks T3","consequence_block":'"$CB"'},
              {"option_id":"o-mint","label":"Mint per call","blast_radius":"forecloses no-migration C7","consequence_block":'"$CB"'} ],
  "recommendation":{"value":"o-bearer","why":"BC-34 keychain family; no migration."},
  "reversible":"Hard — token model is load-bearing." }'
wid="$(dg_from_worker_ask "$GOOD" wstuck claude-tools-65z "$WASK")"; wrc=$?
ck "dg_from_worker_ask consumes the §7.2 ask ⇒ a dossier"    eq "$wrc" "0"
ck "worker_stuck profile: trigger=worker_stuck"              eq "$(JF wstuck '.trigger')" "worker_stuck"
ck "worker_stuck profile: deep §5.1 body present"            ne "$(JF wstuck '.body.full_detail')" ""
ck "worker_stuck profile: exactly ONE pick-option item"      eq "$(JF wstuck '[.items[]|select(.kind=="pick-option")]|length')" "1"
ck "worker_stuck item carries the MANDATORY context_anchor"  ne "$(JF wstuck '.items[0].context_anchor.where')" ""
ck "ALL four profiles validated by the SAME dg__validate_dossier (no branch)" \
   dg__validate_dossier "$(GET mix)"
ck "the zero-item overview ALSO passes that very same validator" \
   dg__validate_dossier "$(GET fF0)"

echo ""
echo "── EXIT-5: binds the SCHEMA, never the pass count (§0.C / §0.2) ──"
# Swap the authoring seam: a DIFFERENT generator emitting a VALID §5 still
# yields a schema-valid dossier — the consumer binds the schema, not the pass.
FAKE="$WORK/fake-author.sh"
cat > "$FAKE" <<'EOF'
#!/bin/bash
# A wholly different "generator": ignores the raw material, emits its own
# valid §5 body+items. Proves dg_generate binds the SCHEMA, not the author.
jq -cn '{ body:{ dossier_schema_version:2, tldr:"swapped-author tldr",
            sections:[{heading:"S","prose":"swapped prose"}],
            diagrams:[{caption:"c","content":"flowchart TD\n  X --> Y"}],
            full_detail:"swapped full detail, stands alone." },
          items:[ { id:"sw1", kind:"approve-reject",
            framing:{ask:"swapped ask",why:"swapped why"},
            context_anchor:{where:"swapped where","expansion":"swapped expansion"},
            reversible:"swapped reversible",
            consequence_block:{cb_schema_version:2,creates:[],unblocks:[],labels:[],status_changes:[]} } ] }'
EOF
chmod +x "$FAKE"
DG_AUTHOR_CMD="$FAKE" dg_generate "$GOOD" "$(gi swap human_flag blocking "$SRC_STRUCT" "[$(item_ar ignored)]")" >/dev/null 2>&1
ck "a SWAPPED author still produces a schema-valid dossier (pass-count not bound)" \
   eq "$(JF swap '.body.tldr')" "swapped-author tldr"
ck "the swapped dossier still passes the SAME frozen §5 gate" \
   dg__validate_dossier "$(GET swap)"
# A swapped author emitting an INVALID §5 (no context_anchor) is STILL rejected
# — the schema is the contract regardless of which generator authored it.
FAKEBAD="$WORK/fake-bad.sh"
cat > "$FAKEBAD" <<'EOF'
#!/bin/bash
jq -cn '{ body:{ dossier_schema_version:2, tldr:"t",
            sections:[{heading:"h","prose":"p"}], diagrams:[], full_detail:"f" },
          items:[ { id:"bad1", kind:"approve-reject",
            framing:{ask:"a",why:"w"}, reversible:"r",
            consequence_block:{cb_schema_version:2,creates:[],unblocks:[],labels:[],status_changes:[]} } ] }'
EOF
chmod +x "$FAKEBAD"
ckn "swapped author emitting an Item w/o context_anchor ⇒ STILL REJECTED" \
   env DG_AUTHOR_CMD="$FAKEBAD" dg_generate "$GOOD" "$(gi swapbad human_flag blocking "$SRC_STRUCT" '[]')"
ckn "the schema-violating swapped dossier was NOT written"  co_request "$GOOD" get dossier swapbad
# §9.1 — no/invalid bearer ⇒ rejected at the ONE chokepoint (no second path).
ckn "§9.1 — dg_generate with NO bearer ⇒ REJECTED" \
   dg_generate "" "$(gi noTok human_flag blocking "$SRC_STRUCT" "[$(item_ar d1)]")"
ckn "§9.1 — nothing written on the auth-failed generate"    co_request "$GOOD" get dossier noTok

echo ""
echo "── Flow G — dg_from_analysis_task: runner-killed bead ⇒ analysis dossier (G2 / claude-tools-vez) ──"
# A runner-killed bead with a realistic Runner: note timeline (tool-errors
# folded under the next terminal classification line). The G2 contract: one
# §5 dossier with a deep body (incl. a "Runner timeline" section grouped by
# attempt + timestamps) and ONE approve-recommendation Item to ack the
# queued analysis bead. trigger=human_flag, tier=blocking, diagrams[]=[]
# (non-structural: a failure summary has no fork to diagram).
A_INPUT='{
  "task_title":"add the spare-only ramp gate",
  "reason":"task_not_closed",
  "classification":"TASK_NOT_CLOSED",
  "analysis_task_id":"claude-tools-zzz",
  "analysis_desc":"Investigate why the worker exited 0 without closing the bead. Check git log/diff, decide whether to split or retry on a fresh context.",
  "runner_notes":[
    "Runner: tool-error permission-denied (×3)",
    "Runner: TASK_NOT_CLOSED at 19:42:55Z — no stream preserved",
    "Runner: tool-error mcp-unavailable (×1)",
    "Runner: WATCHDOG_KILL at 19:48:12Z — log: .beads/logs/foo.jsonl"
  ]
}'
AID="analysis-claude-tools-xyz"
A_BEAD="claude-tools-xyz"
RID="$(dg_from_analysis_task "$GOOD" "$AID" "$A_BEAD" "$A_INPUT")"; ARC=$?
ck "dg_from_analysis_task accepts a well-formed analysis input"  eq "$ARC" "0"
ck "returns the dossier id (deterministic id passed in)"         eq "$RID" "$AID"
ck "envelope persisted through the T5.1 store"                   eq "$(JF "$AID" '.id')" "$AID"
ck "trigger=human_flag (closest fit for runner-flagged analysis)" eq "$(JF "$AID" '.trigger')" "human_flag"
ck "tier=blocking"                                               eq "$(JF "$AID" '.tier')" "blocking"
ck "bead_ref preserved (the failed bead)"                        eq "$(JF "$AID" '.bead_ref')" "$A_BEAD"
ck "diagrams[]=[] valid (non-structural failure summary)"        eq "$(JF "$AID" '.body.diagrams|length')" "0"
ck "§5.1 sections[] has ≥3 entries (what/timeline/plan)"         test "$(JF "$AID" '.body.sections|length')" -ge 3
ck "Runner timeline section is present"                          eq "$(JF "$AID" '[.body.sections[]|select(.heading=="Runner timeline")]|length')" "1"
TL="$(JF "$AID" '[.body.sections[]|select(.heading=="Runner timeline")][0].prose')"
WHATFAIL="$(JF "$AID" '[.body.sections[]|select(.heading=="What failed")][0].prose')"
PLAN="$(JF "$AID" '[.body.sections[]|select(.heading=="Analysis plan")][0].prose')"
ck "timeline groups by attempt — Attempt 1 line present"         grep -q "Attempt 1" <<<"$TL"
ck "timeline groups by attempt — Attempt 2 line present"         grep -q "Attempt 2" <<<"$TL"
ck "timeline carries the first attempt's timestamp"              grep -q "19:42:55Z" <<<"$TL"
ck "timeline carries the second attempt's timestamp"             grep -q "19:48:12Z" <<<"$TL"
ck "timeline carries the terminal classifications"               grep -q "TASK_NOT_CLOSED" <<<"$TL"
ck "timeline carries the watchdog kill classification"           grep -q "WATCHDOG_KILL" <<<"$TL"
ck "tool-error folded under the FIRST attempt (intra-attempt)"   grep -q "permission-denied" <<<"$TL"
ck "tool-error folded under the SECOND attempt (intra-attempt)"  grep -q "mcp-unavailable" <<<"$TL"
ck "human plain-English class summary in 'What failed' section"  grep -q "Exited clean but left the bead open" <<<"$WHATFAIL"
ck "Analysis plan section carries the analysis_desc"             grep -q "Investigate why the worker exited 0" <<<"$PLAN"
ck "exactly ONE item (the approve-recommendation ack)"           eq "$(JF "$AID" '.items|length')" "1"
ck "item kind=approve-recommendation (Brian ack/kickoff)"        eq "$(JF "$AID" '.items[0].kind')" "approve-recommendation"
ck "item context_anchor.where non-empty (AD7 mandatory)"         ne "$(JF "$AID" '.items[0].context_anchor.where')" ""
ck "item context_anchor.expansion non-empty (AD7 mandatory)"     ne "$(JF "$AID" '.items[0].context_anchor.expansion')" ""
ck "item recommendation{value,why} present (§5.2 approve-rec)"   eq "$(JF "$AID" '.items[0].recommendation|(has("value") and has("why"))')" "true"
ck "item consequence_block stamped (=bound; §0.3 / §5.3)"        eq "$(JF "$AID" '.items[0].consequence_block.cb_schema_version')" "$(do__bound_sv)"
ck "item starts in clean §4.1.1 state=open"                      eq "$(JF "$AID" '.items[0].state')" "open"
# Idempotent re-trigger — same id ⇒ overwrites with the same content (T5.5
# task_ref dedup is the upper layer; the deterministic id from the runner
# already gives us one-dossier-per-failed-bead under same-input retries).
ck "re-run with same id ⇒ still succeeds (idempotent)"           dg_from_analysis_task "$GOOD" "$AID" "$A_BEAD" "$A_INPUT"
# Reject paths.
ckn "missing dossier_id ⇒ REJECTED"                              dg_from_analysis_task "$GOOD" "" "$A_BEAD" "$A_INPUT"
ckn "missing bead_ref ⇒ REJECTED"                                dg_from_analysis_task "$GOOD" "analysis-x" "" "$A_INPUT"
ckn "non-object analysis input ⇒ REJECTED"                       dg_from_analysis_task "$GOOD" "analysis-x" "$A_BEAD" 'not-json'
# Empty runner_notes — still produces a valid dossier (a freshly-failed bead
# may have only one note; the dossier must still surface).
EMPTY_NOTES='{"task_title":"t","reason":"unknown","runner_notes":[]}'
ck "empty runner_notes ⇒ dossier still valid (fresh failure)"    dg_from_analysis_task "$GOOD" "analysis-empty" "bd-empty" "$EMPTY_NOTES"
ETL="$(JF analysis-empty '[.body.sections[]|select(.heading=="Runner timeline")][0].prose')"
ck "empty-notes timeline carries an honest 'no notes' placeholder" grep -q "No Runner" <<<"$ETL"

echo ""
echo "── ANTI-DRIFT (structural — sibling surfaces untouched) ──"
ck "T4 §4 registry: dossier⇒2 (v2 §11 Mermaid amend bump; NOT a T5.2 drift — T5.2 added NO §4 record type)" \
   eq "$(co__schema_version dossier)" "2"
ck "T5.2 added NO 'dossier_gen' §4 record type" \
   eq "$(co__schema_version dossier_gen)" ""
ck "the §5 sub-versions track the ONE bound source (§0.5; T5.3 precedent)" \
   eq "$(dg__sv)" "$(do__bound_sv)"
ckn "dossier-gen does NOT re-implement / advertise a §2 capability" \
   grep -q 'dg_generate' <(co_capabilities 2>/dev/null || true)
# Producer ONLY: dg_generate sets each Item's §4.1.1 record to a CLEAN open
# state and NEVER applies a ConsequenceBlock / moves state past open (that is
# T5.1 substrate + T5.3 apply LOGIC — siblings).
ck "emitted Items are CLEAN §4.1.1 records: state=open" \
   eq "$(JF mix '[.items[]|select(.state=="open")]|length')" "5"
ck "emitted Items: consequence_applied=false (T5.2 applies NOTHING)" \
   eq "$(JF mix '[.items[]|select(.consequence_applied==false)]|length')" "5"
ck "emitted Items: response=null, applied_at=null (substrate owns lifecycle)" \
   eq "$(JF mix '[.items[]|select(.response==null and .applied_at==null)]|length')" "5"

echo ""
echo "── B3 (claude-tools-95m) — jq fallback is explicit, observable, badged ──"
# DG_AUDIT_LOG is isolated to $WORK from the top (claude-tools-69u8). Clear it
# here so the B3 assertions below see ONLY their own fresh fixture rows.
rm -f "$DG_AUDIT_LOG"
unset DG_AUTHOR_CMD 2>/dev/null || true

# (1) DG_AUTHOR_CMD UNSET ⇒ jq fallback fires, body stamped, audit logged.
ck "no DG_AUTHOR_CMD ⇒ dg_generate still succeeds (jq fallback runs)" \
   dg_generate "$GOOD" "$(gi b3unset worker_stuck blocking "$SRC_STRUCT" "[$(item_po d1)]")"
ck "fallback stamps body.authored_by='fallback'" \
   eq "$(JF b3unset '.body.authored_by')" "fallback"
ck "fallback stamps body.authored_by_reason='no_DG_AUTHOR_CMD'" \
   eq "$(JF b3unset '.body.authored_by_reason')" "no_DG_AUTHOR_CMD"
ck "fallback dossier still passes the SAME frozen §5 gate (badge is opaque to it)" \
   dg__validate_dossier "$(GET b3unset)"
ck "audit log was created" test -f "$DG_AUDIT_LOG"
ck "audit log carries a no_DG_AUTHOR_CMD line for b3unset" \
   grep -q '"dossier_id":"b3unset".*"reason":"no_DG_AUTHOR_CMD"' "$DG_AUDIT_LOG"

# (2) DG_AUTHOR_CMD set to a script that EXITS NONZERO ⇒ agent_unavailable
#     reason, fallback fires, dossier still produced.
FAIL_AUTHOR="$WORK/fail-author.sh"
cat > "$FAIL_AUTHOR" <<'EOF'
#!/bin/bash
echo "simulated agent crash" >&2
exit 17
EOF
chmod +x "$FAIL_AUTHOR"
DG_AUTHOR_CMD="$FAIL_AUTHOR" dg_generate "$GOOD" \
   "$(gi b3fail worker_stuck blocking "$SRC_STRUCT" "[$(item_po d1)]")" >/dev/null 2>&1
ck "agent exit nonzero ⇒ jq fallback fires, dossier persisted" \
   eq "$(JF b3fail '.id')" "b3fail"
ck "agent failure ⇒ body.authored_by='fallback'" \
   eq "$(JF b3fail '.body.authored_by')" "fallback"
ck "agent failure ⇒ body.authored_by_reason='agent_unavailable'" \
   eq "$(JF b3fail '.body.authored_by_reason')" "agent_unavailable"
ck "audit log carries an agent_unavailable line for b3fail" \
   grep -q '"dossier_id":"b3fail".*"reason":"agent_unavailable"' "$DG_AUDIT_LOG"

# (3) DG_AUTHOR_CMD set to a script that emits NON-JSON output ⇒
#     agent_invalid_output reason, fallback fires.
JUNK_AUTHOR="$WORK/junk-author.sh"
cat > "$JUNK_AUTHOR" <<'EOF'
#!/bin/bash
echo "I refuse to author this — Brian, please clarify"
exit 0
EOF
chmod +x "$JUNK_AUTHOR"
DG_AUTHOR_CMD="$JUNK_AUTHOR" dg_generate "$GOOD" \
   "$(gi b3junk worker_stuck blocking "$SRC_STRUCT" "[$(item_po d1)]")" >/dev/null 2>&1
ck "agent emits non-JSON ⇒ jq fallback fires, dossier persisted" \
   eq "$(JF b3junk '.id')" "b3junk"
ck "agent invalid output ⇒ body.authored_by_reason='agent_invalid_output'" \
   eq "$(JF b3junk '.body.authored_by_reason')" "agent_invalid_output"
ck "audit log carries an agent_invalid_output line for b3junk" \
   grep -q '"dossier_id":"b3junk".*"reason":"agent_invalid_output"' "$DG_AUDIT_LOG"

# (4) DG_AUTHOR_CMD set to a script that emits VALID {body,items} JSON ⇒
#     agent path, body.authored_by='agent', audit logs agent_ok (NOT a fallback
#     fire — record_incident is NOT triggered for the success path).
GOOD_AUTHOR="$WORK/good-author.sh"
cat > "$GOOD_AUTHOR" <<'EOF'
#!/bin/bash
jq -cn '{ body:{ dossier_schema_version:2, tldr:"agent-authored tldr",
            sections:[{heading:"S","prose":"agent prose"}],
            diagrams:[{caption:"c","content":"flowchart TD\n  X --> Y"}],
            full_detail:"agent full detail." },
          items:[ { id:"a1", kind:"approve-reject",
            framing:{ask:"agent ask",why:"agent why"},
            context_anchor:{where:"agent where","expansion":"agent expansion"},
            reversible:"agent reversible",
            consequence_block:{cb_schema_version:2,creates:[],unblocks:[],labels:[],status_changes:[]} } ] }'
EOF
chmod +x "$GOOD_AUTHOR"
DG_AUTHOR_CMD="$GOOD_AUTHOR" dg_generate "$GOOD" \
   "$(gi b3ok worker_stuck blocking "$SRC_STRUCT" "[$(item_ar d1)]")" >/dev/null 2>&1
ck "agent success ⇒ dossier persisted with the AGENT's body"  eq "$(JF b3ok '.body.tldr')" "agent-authored tldr"
ck "agent success ⇒ body.authored_by='agent'"                  eq "$(JF b3ok '.body.authored_by')" "agent"
ck "agent success ⇒ body.authored_by_reason='agent_ok'"        eq "$(JF b3ok '.body.authored_by_reason')" "agent_ok"
ck "audit log carries an agent_ok line for b3ok" \
   grep -q '"dossier_id":"b3ok".*"reason":"agent_ok"' "$DG_AUDIT_LOG"

# (5) record_incident is wired when the runner has it; here we just check the
#     hook doesn't break dg__audit_fallback. Define a fake record_incident that
#     appends to a marker file; trigger a fallback; assert the marker landed.
INCIDENT_MARKER="$WORK/incident-marker.log"
record_incident() { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$INCIDENT_MARKER"; }
export -f record_incident
unset DG_AUTHOR_CMD
dg_generate "$GOOD" "$(gi b3hook worker_stuck blocking "$SRC_STRUCT" "[$(item_po d1)]")" >/dev/null 2>&1
ck "record_incident hook fires on a fallback (runner failure-visibility surface)" \
   grep -q '^b3hook|DOSSIER_FALLBACK:no_DG_AUTHOR_CMD|' "$INCIDENT_MARKER"
unset -f record_incident

# (6) Daily-rollup metric script reads the audit log we just populated.
METRIC="$(cd "$(dirname "$LIB")" && pwd)/dg-author-metric.sh"
ck "metric script exists + executable" test -x "$METRIC"
ROLL_JSON=$(DG_AUDIT_LOG="$DG_AUDIT_LOG" "$METRIC" --all --json 2>/dev/null)
ck "metric --json emits at least one daily row"     test -n "$ROLL_JSON"
ck "metric --json row carries agent + fallback counts" \
   eq "$(printf '%s' "$ROLL_JSON" | jq -r '[(.agent + .fallback)>0] | all' 2>/dev/null)" "true"
# We pushed >0 agent (b3ok) and >0 fallback (b3unset/b3fail/b3junk/b3hook) into
# the SAME UTC day; the daily rollup must reflect both populations.
ck "metric --json shows the agent population for today"    test "$(printf '%s' "$ROLL_JSON" | jq -r '.agent')"    -ge 1
ck "metric --json shows the fallback population for today" test "$(printf '%s' "$ROLL_JSON" | jq -r '.fallback')" -ge 4

# (7) ANTI-DRIFT: the existing "swapped author" test (line ~286) keeps passing
#     — the agent stamp does not clobber a fixture-set authored_by, but a
#     fixture that omits it MUST still get the stamp. We re-run the EXIT-5
#     fixture under a fresh did to assert the stamp lands.
DG_AUTHOR_CMD="$WORK/fake-author.sh" dg_generate "$GOOD" \
   "$(gi b3swap human_flag blocking "$SRC_STRUCT" "[$(item_ar ignored)]")" >/dev/null 2>&1
ck "swapped agent fixture (omitting authored_by) is stamped='agent'" \
   eq "$(JF b3swap '.body.authored_by')" "agent"
ck "swapped agent fixture preserves its own body.tldr verbatim" \
   eq "$(JF b3swap '.body.tldr')" "swapped-author tldr"

# (8) claude-tools-xdo: caller-supplied source.authored_by hint (the MCP
#     write_polished path stamps "agent" + a reason so the jq shape-coercer
#     does NOT mislabel the body as "fallback"). The hint must also suppress
#     the no_DG_AUTHOR_CMD incident fire (this is not a degraded path).
INCIDENT_MARKER2="$WORK/incident-marker-xdo.log"
record_incident() { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$INCIDENT_MARKER2"; }
export -f record_incident
unset DG_AUTHOR_CMD
SRC_PREAUTH=$(jq -c '. + {authored_by:"agent", authored_by_reason:"mcp_polished_builder"}' <<<"$SRC_STRUCT")
dg_generate "$GOOD" "$(gi b3xdo worker_stuck blocking "$SRC_PREAUTH" "[$(item_po d1)]")" >/dev/null 2>&1
ck "pre-authored gi ⇒ body.authored_by reflects the hint ('agent')" \
   eq "$(JF b3xdo '.body.authored_by')" "agent"
ck "pre-authored gi ⇒ body.authored_by_reason reflects the hint" \
   eq "$(JF b3xdo '.body.authored_by_reason')" "mcp_polished_builder"
ckn "pre-authored gi ⇒ NO no_DG_AUTHOR_CMD incident fired (jq is shape-coercer here)" \
    grep -q '^b3xdo|DOSSIER_FALLBACK' "$INCIDENT_MARKER2"
unset -f record_incident

# (9) claude-tools-69u8: the CHOKEPOINT auto-wire (DG_AUTHOR_AUTOWIRE). A runner
#     sets it ONCE at startup so every dg__author caller reaches the real-agent
#     bridge instead of per-call-site wiring — but it stays HERMETIC (off unless
#     opted in), claude-gated, and skip-when-pre-authored. ALL fakes here:
#     DG_AUTHOR_BRIDGE_PATH points at a stub "bridge" that emits {body,items}
#     WITHOUT spawning claude, and CLAUDE_BIN points at a present/absent stub —
#     so no real claude is ever invoked and the suite stays offline.
FAKE_CLAUDE="$WORK/fake-claude"
printf '#!/bin/bash\nexit 0\n' > "$FAKE_CLAUDE"; chmod +x "$FAKE_CLAUDE"
unset DG_AUTHOR_CMD DG_AUTHOR_AUTOWIRE CLAUDE_BIN DG_AUTHOR_BRIDGE_PATH

# (9a) default OFF: AUTOWIRE unset ⇒ pure jq path EVEN with a bridge present and
#      claude reachable (the hermetic-unit guarantee — test (1) generalized).
CLAUDE_BIN="$FAKE_CLAUDE" DG_AUTHOR_BRIDGE_PATH="$GOOD_AUTHOR" \
  dg_generate "$GOOD" "$(gi b3aw0 worker_stuck blocking "$SRC_STRUCT" "[$(item_po d1)]")" >/dev/null 2>&1
ck "autowire OFF by default ⇒ jq fallback (authored_by='fallback')" \
   eq "$(JF b3aw0 '.body.authored_by')" "fallback"
ck "autowire OFF by default ⇒ reason='no_DG_AUTHOR_CMD'" \
   eq "$(JF b3aw0 '.body.authored_by_reason')" "no_DG_AUTHOR_CMD"

# (9b) AUTOWIRE=1 + bridge executable + claude reachable ⇒ the chokepoint wires
#      the bridge ⇒ agent path (authored_by='agent', agent_ok) with NO per-call-
#      site DG_AUTHOR_CMD export anywhere.
DG_AUTHOR_AUTOWIRE=1 CLAUDE_BIN="$FAKE_CLAUDE" DG_AUTHOR_BRIDGE_PATH="$GOOD_AUTHOR" \
  dg_generate "$GOOD" "$(gi b3aw1 worker_stuck blocking "$SRC_STRUCT" "[$(item_po d1)]")" >/dev/null 2>&1
ck "autowire ON + bridge + claude ⇒ agent path (authored_by='agent')" \
   eq "$(JF b3aw1 '.body.authored_by')" "agent"
ck "autowire ON ⇒ audit logs agent_ok for b3aw1" \
   grep -q '"dossier_id":"b3aw1".*"reason":"agent_ok"' "$DG_AUDIT_LOG"

# (9c) AUTOWIRE=1 + bridge present but claude UNREACHABLE ⇒ auto-wire SKIPS (no
#      pointless spawn, no false 'agent' badge) ⇒ jq path / no_DG_AUTHOR_CMD.
DG_AUTHOR_AUTOWIRE=1 CLAUDE_BIN="$WORK/no-such-claude" DG_AUTHOR_BRIDGE_PATH="$GOOD_AUTHOR" \
  dg_generate "$GOOD" "$(gi b3aw2 worker_stuck blocking "$SRC_STRUCT" "[$(item_po d1)]")" >/dev/null 2>&1
ck "autowire ON but claude unreachable ⇒ jq fallback (authored_by='fallback')" \
   eq "$(JF b3aw2 '.body.authored_by')" "fallback"
ck "autowire ON but claude unreachable ⇒ reason='no_DG_AUTHOR_CMD'" \
   eq "$(JF b3aw2 '.body.authored_by_reason')" "no_DG_AUTHOR_CMD"

# (9d) AUTOWIRE=1 + bridge + claude reachable but gi is PRE-AUTHORED ⇒ skip the
#      auto-wire (don't re-spawn a builder over an already-authored body) ⇒ the
#      §xdo hint wins, no agent re-author (the Flow F overview shape).
DG_AUTHOR_AUTOWIRE=1 CLAUDE_BIN="$FAKE_CLAUDE" DG_AUTHOR_BRIDGE_PATH="$GOOD_AUTHOR" \
  dg_generate "$GOOD" "$(gi b3aw3 stage_gate blocking "$SRC_PREAUTH" "[$(item_po d1)]")" >/dev/null 2>&1
ck "autowire ON but pre-authored ⇒ no double-spawn (authored_by_reason = the hint)" \
   eq "$(JF b3aw3 '.body.authored_by_reason')" "mcp_polished_builder"

# (9e) an explicit DG_AUTHOR_CMD WINS over autowire (the MCP / per-call override
#      seam). Bridge path is bogus; the explicit author is what runs.
DG_AUTHOR_AUTOWIRE=1 CLAUDE_BIN="$FAKE_CLAUDE" DG_AUTHOR_BRIDGE_PATH="$WORK/no-such-bridge" \
  DG_AUTHOR_CMD="$GOOD_AUTHOR" dg_generate "$GOOD" \
  "$(gi b3aw4 worker_stuck blocking "$SRC_STRUCT" "[$(item_po d1)]")" >/dev/null 2>&1
ck "explicit DG_AUTHOR_CMD overrides autowire (uses the explicit author body)" \
   eq "$(JF b3aw4 '.body.tldr')" "agent-authored tldr"
unset DG_AUTHOR_CMD DG_AUTHOR_AUTOWIRE CLAUDE_BIN DG_AUTHOR_BRIDGE_PATH

# Clean up so later test runs / metric scripts don't see this run's noise.
unset DG_AUTHOR_CMD DG_AUDIT_LOG

# ── claude-tools-uxvl5 (inbox-lifecycle §4.4): the READABILITY LINT, and the
#    deterministic fallback template held to it (the residual no_DG_AUTHOR_CMD
#    jargon bug). dg__readability_lint flags untranslated internal jargon in the
#    HUMAN-FACING prose only; it is ADVISORY — never wired into do_dossier_put /
#    dg_generate (4xe write-gate/render-tolerance: the write path rejects on
#    SCHEMA, never on prose style; the renderer stays tolerant).
echo ""
echo "── claude-tools-uxvl5 — readability lint (§4.4) ──"
ckn "lint flags a section symbol (§)" \
    dg__readability_lint '{"body":{"tldr":"slipped past the §7.6 guardrail"}}'
ckn "lint flags contract IDs (AD7 / BC-34 / T5.3 / S-2)" \
    dg__readability_lint '{"tldr":"per AD7 and BC-34 and T5.3 and S-2"}'
ckn "lint flags raw state/enum tokens (blocked-for-human / worker_stuck)" \
    dg__readability_lint '{"body":{"full_detail":"the bead is blocked-for-human after a worker_stuck fire"}}'
ck  "lint PASSES clean plain-English prose" \
    dg__readability_lint '{"body":{"tldr":"A worker stopped at a decision only you can make.","full_detail":"It needs your call before it can continue."}}'
ck  "lint does NOT false-positive on an ISO timestamp / bead ref" \
    dg__readability_lint '{"tldr":"Worker on claude-tools-7xl stopped at 2026-05-26T17:45:52Z."}'
ck  "lint is clean when there is no reader-facing prose (only enum fields)" \
    dg__readability_lint '{"trigger":"worker_stuck","kind":"decide"}'
ck  "lint ignores the by-design machine field .trigger (worker_stuck there is not prose)" \
    dg__readability_lint '{"trigger":"worker_stuck","body":{"tldr":"A worker stopped at a decision only you can make."}}'
# The deterministic jq fallback body (DG_AUTHOR_CMD unset) is held to the lint:
# build a worker_stuck dossier from CLEAN raw material and assert it passes.
unset DG_AUTHOR_CMD
CLEAN_ASK='{"tldr":"A worker stopped at a decision only you can make.","ask":"What should happen next?","options":[{"option_id":"resume","label":"Resume the task","blast_radius":"Puts the task back in the queue once you have cleared the blocker.","consequence_block":{"creates":[],"unblocks":[],"labels":[],"status_changes":[]}},{"option_id":"stop","label":"Stop and re-scope","blast_radius":"Leaves the task parked until you re-scope it.","consequence_block":{"creates":[],"unblocks":[],"labels":[],"status_changes":[]}}],"recommendation":{"value":"resume","why":"Resume once you have decided; nothing failed."},"reversible":"Fully reversible until you pick an option."}'
dg_from_worker_ask "$GOOD" b3lint readability-bead "$CLEAN_ASK" >/dev/null 2>&1
ck  "the deterministic fallback dossier passes the readability lint (the fallback template is clean)" \
    dg__readability_lint "$(GET b3lint)"
ckn "the lint WOULD trip if jargon re-entered that real dossier body (guard works on the live shape)" \
    dg__readability_lint "$(GET b3lint | jq -c '.body.tldr="slipped past the §7.6 guardrail (blocked-for-human)"')"
unset DG_AUTHOR_CMD

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " test-dossier-gen (T5.2, claude-tools-9gt):  PASS=$PASS  FAIL=$FAIL"
echo "══════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
