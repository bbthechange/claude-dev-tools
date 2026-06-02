#!/bin/bash
# beads-runner/lib/test-gates-view.sh — focused unit test for the Gates facet
# view-model (J3, claude-tools-uxvj3; DESIGN J §4 + UX-DESIGN-V2 §7.2/§7.3): the
# §4.5 projection's projects[].holds[] → one unified Hold list per workspace where
# the GATE is editable and the beads-native DEPENDENCY + SCHEDULED holds are
# READ-ONLY (the C3 honesty constraint), with a gate-owned Scheduled hold nested
# under its Gate.
#
# Mirrors lib/test-activity-view.sh's node-require technique: it does a node
# `require` of the pure view-model (web/workspace/gates-view.js), feeds a
# hand-crafted fixture snapshot JSON (the FROZEN B.1 holds[] shape the J2 unifier
# emits in cf/src/reconcile.js buildHolds), and asserts the derived model. The
# bash coordinator is NOT driven here — the facet reads the SAME /api/board
# projection the Board does; this test fixes the facet's OWN rendering contract
# against the frozen shape.
#
# Asserts (the s6 invariant from the bead): gate rows EDITABLE (editable:true,
# carried verbatim); dependency + scheduled rows READ-ONLY (editable:false) with
# their native note; a gate-owned Scheduled hold nested UNDER its Gate; a
# metadata-less gate degrades (missing_meta + honest placeholders, never dropped);
# an out-of-set hold type lands in other[] shown raw (never coerced); B.4
# tolerance (missing/garbled holds ⇒ honest placeholder + degraded[], never throw);
# the ONE hard refusal is an unknown-HIGHER (or missing/non-integer) schema_version.
#
# Self-contained: needs only node + jq. Keeps the test FILE out of the deployed
# web/ dir (it lives in beads-runner/lib/). Run from the repo root.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIEW="$HERE/../web/workspace/gates-view.js"
APP="$HERE/../web/workspace/app.js"
HTML="$HERE/../web/workspace/index.html"
CSS="$HERE/../web/workspace/workspace.css"
PROXY="$HERE/../web/functions/api/control/gate-action.js"
[[ -f "$VIEW" ]] || { echo "FATAL: gates-view.js not found at $VIEW"; exit 2; }
command -v node >/dev/null 2>&1 || { echo "FATAL: node required for the Gates view test"; exit 2; }
command -v jq   >/dev/null 2>&1 || { echo "FATAL: jq required for the Gates view test"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \xe2\x9c\x93 %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \xe2\x9c\x97 %s\n' "$1"; FAIL=$((FAIL+1)); }
ck()  { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
has()   { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }
hasnt() { case "$2" in *"$1"*) return 1;; *) return 0;; esac; }
eq()    { [[ "$1" == "$2" ]]; }

# A fixed "now" so set_at relative ages are deterministic (2026-06-02T00:00:00Z).
NOW_MS="$(node -e 'process.stdout.write(String(Date.parse("2026-06-02T00:00:00Z")))')"

# Pipe a §4.5 projection JSON + a workspace ref through the PURE view-model at the
# FIXED now-ms. render <ref> < json.
render() { printf '%s' "$2" | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    const GV=require(process.argv[1]);
    let snap; try{snap=JSON.parse(s);}catch(e){snap=s;}
    process.stdout.write(JSON.stringify(GV.deriveGatesView(snap, process.argv[3], Number(process.argv[2]))));
  });' "$VIEW" "$NOW_MS" "$1"; }

# ── The fixture: a §4.5 work-snapshot with the B.1 holds[] shape (buildHolds) ───
#   • rhythmGame — three GATES (full meta / agent-placed / metadata-less), one
#     DEPENDENCY, one gate-owned SCHEDULED (nests under its gate), one standalone
#     SCHEDULED, and one out-of-set hold (other[]). The full surface.
#   • beQuiet    — holds:[] (the honest "nothing held" empty state).
#   • noHolds    — a project with NO holds key (an old producer ⇒ B.4 degraded).
FIX="$(jq -cn '{
  schema_version: 1,
  read_only: true,
  principal: "PRINCIPAL_V1",
  projects: [
    { project_ref: "rhythmGame",
      holds: [
        { type:"gate", id:"gate:audio-redesign", task_count:3, owner:"you",
          set_at:"2026-05-29T00:00:00Z", why:"waiting on the audio-engine decision",
          unblocks_when:"that decision lands (or you lift this)", scope:"cohort",
          editable:true, degraded:[] },
        { type:"gate", id:"gate:enricher-hold", task_count:1, owner:"agent:enricher",
          set_at:"2026-06-01T21:00:00Z", why:"intake needs triage first",
          unblocks_when:"triage done", scope:"task", editable:true, degraded:[] },
        { type:"gate", id:"gate:bare-gate", task_count:2, owner:null, set_at:null,
          why:null, unblocks_when:null, scope:null, editable:true,
          degraded:["gate placed before metadata existed"] },
        { type:"dependency", task_ref:"rhythmGame-77p", blocked_on:"rhythmGame-77a",
          unblocks_when:"rhythmGame-77a closes", editable:false },
        { type:"scheduled", task_ref:"rhythmGame-5kq", deferred_until:"2026-07-01",
          owning_gate:"gate:audio-redesign", unblocks_when:"2026-07-01", editable:false },
        { type:"scheduled", task_ref:"rhythmGame-9zz", deferred_until:"2026-08-01",
          owning_gate:null, unblocks_when:"2026-08-01", editable:false },
        { type:"mystery", task_ref:"rhythmGame-xx", editable:false }
      ] },
    { project_ref: "beQuiet", holds: [] },
    { project_ref: "noHolds",
      runner_state: { liveness:"live", actual:"running", desired:"running" } }
  ],
  waiting_on_you: [],
  lifecycle_columns: {},
  machines: []
}')"

V="$(render rhythmGame "$FIX")"

echo "── A: a good (sv:1) snapshot renders ok:true, scoped to the ref ──"
ck "good snapshot ⇒ ok:true"                          eq "$(jq -r '.ok' <<<"$V")" "true"
ck "principal surfaced verbatim"                       eq "$(jq -r '.principal' <<<"$V")" "PRINCIPAL_V1"
ck "schema_version echoed (1)"                         eq "$(jq -r '.schema_version' <<<"$V")" "1"
ck "project_ref echoed (rhythmGame)"                   eq "$(jq -r '.project_ref' <<<"$V")" "rhythmGame"
ck "found:true (project present)"                      eq "$(jq -r '.found' <<<"$V")" "true"
ck "not empty (it has holds)"                          eq "$(jq -r '.empty' <<<"$V")" "false"

echo "── B: §0.3 — an unknown HIGHER (or missing/non-integer) sv is REFUSED ──"
HI="$(jq -c '.schema_version=99' <<<"$FIX")"
VHI="$(render rhythmGame "$HI")"
ck "schema_version 99 ⇒ ok:false (refuse, no best-effort)" eq "$(jq -r '.ok' <<<"$VHI")" "false"
ck "refusal names the unsupported version"                 has "schema_version 99" "$(jq -r '.error' <<<"$VHI")"
ck "refusal cites §0.3"                                    has "§0.3" "$(jq -r '.error' <<<"$VHI")"
ck "missing schema_version ⇒ also ok:false"                eq "$(jq -r '.ok' <<<"$(render rhythmGame "$(jq -c 'del(.schema_version)' <<<"$FIX")")")" "false"
ck "non-integer schema_version (1.5) ⇒ also ok:false"      eq "$(jq -r '.ok' <<<"$(render rhythmGame "$(jq -c '.schema_version=1.5' <<<"$FIX")")")" "false"

echo "── C: bucket counts — gate / dependency / scheduled / other ──"
ck "3 gates"                                           eq "$(jq -r '.gates|length' <<<"$V")" "3"
ck "1 dependency"                                      eq "$(jq -r '.dependencies|length' <<<"$V")" "1"
ck "1 standalone scheduled (the gate-owned one nests away)" eq "$(jq -r '.scheduled|length' <<<"$V")" "1"
ck "1 out-of-set hold in other[]"                      eq "$(jq -r '.other|length' <<<"$V")" "1"
ck "counts.total is 6"                                 eq "$(jq -r '.counts.total' <<<"$V")" "6"
ck "counts.gates is 3"                                 eq "$(jq -r '.counts.gates' <<<"$V")" "3"

echo "── D: the GATE is editable (verbatim from the projection) + its labels ──"
ck "gate[0] type gate"                                 eq "$(jq -r '.gates[0].type' <<<"$V")" "gate"
ck "gate[0] full label id (gate:audio-redesign)"       eq "$(jq -r '.gates[0].id' <<<"$V")" "gate:audio-redesign"
ck "gate[0] BARE gate_id (audio-redesign — agent-action target)" eq "$(jq -r '.gates[0].gate_id' <<<"$V")" "audio-redesign"
ck "gate[0] name is the bare id"                       eq "$(jq -r '.gates[0].name' <<<"$V")" "audio-redesign"
ck "gate[0] editable:true (the only editable hold)"    eq "$(jq -r '.gates[0].editable' <<<"$V")" "true"
ck "gate[0] task_count_label '3 tasks'"                eq "$(jq -r '.gates[0].task_count_label' <<<"$V")" "3 tasks"
ck "gate[0] owner_label 'you'"                         eq "$(jq -r '.gates[0].owner_label' <<<"$V")" "you"
ck "gate[0] set_at_age '4d ago' (deterministic now)"   eq "$(jq -r '.gates[0].set_at_age' <<<"$V")" "4d ago"
ck "gate[0] why_label surfaced"                        eq "$(jq -r '.gates[0].why_label' <<<"$V")" "waiting on the audio-engine decision"
ck "gate[0] unblocks_when_label surfaced"              has "that decision lands" "$(jq -r '.gates[0].unblocks_when_label' <<<"$V")"
ck "gate[0] scope cohort"                              eq "$(jq -r '.gates[0].scope' <<<"$V")" "cohort"
ck "gate[0] missing_meta:false (it has metadata)"      eq "$(jq -r '.gates[0].missing_meta' <<<"$V")" "false"
# An AGENT-placed gate surfaces its owner (the thirsty invisible-defer fix, §7.3).
ck "gate[1] owner_label 'agent: enricher'"             eq "$(jq -r '.gates[1].owner_label' <<<"$V")" "agent: enricher"
ck "gate[1] set_at_age '3h ago'"                       eq "$(jq -r '.gates[1].set_at_age' <<<"$V")" "3h ago"

echo "── E: a metadata-less gate DEGRADES (B.4) — never dropped, never thrown ──"
ck "gate[2] is the bare-gate (still rendered)"         eq "$(jq -r '.gates[2].gate_id' <<<"$V")" "bare-gate"
ck "gate[2] still editable:true"                       eq "$(jq -r '.gates[2].editable' <<<"$V")" "true"
ck "gate[2] missing_meta:true"                         eq "$(jq -r '.gates[2].missing_meta' <<<"$V")" "true"
ck "gate[2] why_label honest placeholder"              eq "$(jq -r '.gates[2].why_label' <<<"$V")" "(no why recorded)"
ck "gate[2] unblocks_when_label honest placeholder"    eq "$(jq -r '.gates[2].unblocks_when_label' <<<"$V")" "(no unblock condition recorded)"
ck "gate[2] owner_label '(owner unrecorded)'"          eq "$(jq -r '.gates[2].owner_label' <<<"$V")" "(owner unrecorded)"
ck "gate[2] set_at_age null (no timestamp)"            eq "$(jq -r '.gates[2].set_at_age' <<<"$V")" "null"
ck "a degraded[] note names the metadata-less gate"    has "metadata missing" "$(jq -r '.degraded|join("|")' <<<"$V")"

echo "── F: DEPENDENCY is read-only with its native note (C3) ──"
ck "dep type dependency"                               eq "$(jq -r '.dependencies[0].type' <<<"$V")" "dependency"
ck "dep editable:false (beads-native — read-only)"     eq "$(jq -r '.dependencies[0].editable' <<<"$V")" "false"
ck "dep task_ref surfaced"                             eq "$(jq -r '.dependencies[0].task_ref' <<<"$V")" "rhythmGame-77p"
ck "dep blocked_on surfaced"                           eq "$(jq -r '.dependencies[0].blocked_on' <<<"$V")" "rhythmGame-77a"
ck "dep unblocks_when_label native condition"          eq "$(jq -r '.dependencies[0].unblocks_when_label' <<<"$V")" "rhythmGame-77a closes"
ck "dep native_note 'beads-native — read-only'"        eq "$(jq -r '.dependencies[0].native_note' <<<"$V")" "beads-native — read-only"

echo "── G: SCHEDULED — standalone read-only + gate-owned NESTS under its Gate (§7.2) ──"
ck "standalone sched editable:false"                   eq "$(jq -r '.scheduled[0].editable' <<<"$V")" "false"
ck "standalone sched task_ref (9zz)"                   eq "$(jq -r '.scheduled[0].task_ref' <<<"$V")" "rhythmGame-9zz"
ck "standalone sched gate_owned:false"                 eq "$(jq -r '.scheduled[0].gate_owned' <<<"$V")" "false"
ck "standalone sched native_note read-only"            eq "$(jq -r '.scheduled[0].native_note' <<<"$V")" "beads-native — read-only"
# The gate-owned scheduled hold is NESTED under gate[0], NOT in the top-level list.
ck "gate[0] has 1 nested scheduled_under hold"         eq "$(jq -r '.gates[0].scheduled_under|length' <<<"$V")" "1"
ck "nested sched is the gate-owned defer (5kq)"        eq "$(jq -r '.gates[0].scheduled_under[0].task_ref' <<<"$V")" "rhythmGame-5kq"
ck "nested sched gate_owned:true"                      eq "$(jq -r '.gates[0].scheduled_under[0].gate_owned' <<<"$V")" "true"
ck "nested sched native_note 'beads-native; gate-owned'" eq "$(jq -r '.gates[0].scheduled_under[0].native_note' <<<"$V")" "beads-native; gate-owned"
ck "nested sched editable:false (still read-only)"     eq "$(jq -r '.gates[0].scheduled_under[0].editable' <<<"$V")" "false"
# The OTHER gates own no defers.
ck "gate[1] has 0 nested scheduled holds"              eq "$(jq -r '.gates[1].scheduled_under|length' <<<"$V")" "0"

echo "── H: an out-of-set hold type lands in other[] shown raw (B.4, never coerced) ──"
ck "other[0] type preserved raw (mystery)"             eq "$(jq -r '.other[0].type' <<<"$V")" "mystery"
ck "other[0] editable:false (unknown ⇒ never editable)" eq "$(jq -r '.other[0].editable' <<<"$V")" "false"
ck "a degraded[] note names the out-of-set type"       has "out-of-set type" "$(jq -r '.degraded|join("|")' <<<"$V")"
# The unknown type was NOT coerced into a gate (which would fake editability).
ck "no gate has id gate:rhythmGame-xx (not coerced)"   eq "$(jq -r '[.gates[].id]|index("gate:rhythmGame-xx")' <<<"$V")" "null"

echo "── I: honest empty + missing-block degrade (never refuse) ──"
VE="$(render beQuiet "$FIX")"
ck "beQuiet ok:true"                                   eq "$(jq -r '.ok' <<<"$VE")" "true"
ck "beQuiet found:true"                                eq "$(jq -r '.found' <<<"$VE")" "true"
ck "beQuiet empty:true (holds:[])"                     eq "$(jq -r '.empty' <<<"$VE")" "true"
ck "beQuiet 0 gates"                                   eq "$(jq -r '.gates|length' <<<"$VE")" "0"
VNH="$(render noHolds "$FIX")"
ck "noHolds ok:true (degrade, never refuse)"           eq "$(jq -r '.ok' <<<"$VNH")" "true"
ck "noHolds found:true (project present)"              eq "$(jq -r '.found' <<<"$VNH")" "true"
ck "noHolds empty:true"                                eq "$(jq -r '.empty' <<<"$VNH")" "true"
ck "noHolds degraded note 'holds[] not reported'"      has "holds[] not reported" "$(jq -r '.degraded|join("|")' <<<"$VNH")"

echo "── J: an unknown ref ⇒ found:false honest empty (NOT a refusal) ──"
VU="$(render ghostWorkspace "$FIX")"
ck "unknown ref ⇒ ok:true (not a refusal)"             eq "$(jq -r '.ok' <<<"$VU")" "true"
ck "unknown ref ⇒ found:false"                         eq "$(jq -r '.found' <<<"$VU")" "false"
ck "unknown ref ⇒ empty:true"                          eq "$(jq -r '.empty' <<<"$VU")" "true"
ck "unknown ref ⇒ a degraded 'no runner reported' note" has "no runner reported for ghostWorkspace" "$(jq -r '.degraded|join("|")' <<<"$VU")"

echo "── K: B.4 — malformed holds degrade to placeholders + notes (no throw) ──"
# holds is not an array ⇒ honest empty + a degraded note.
GARB1="$(jq -c '.projects[0].holds=5' <<<"$FIX")"
VG1="$(render rhythmGame "$GARB1")"
ck "non-array holds ⇒ ok:true (no throw)"              eq "$(jq -r '.ok' <<<"$VG1")" "true"
ck "non-array holds ⇒ 0 gates"                         eq "$(jq -r '.gates|length' <<<"$VG1")" "0"
ck "non-array holds ⇒ degraded 'holds[] malformed'"    has "holds[] malformed" "$(jq -r '.degraded|join("|")' <<<"$VG1")"
# a null entry inside holds[] ⇒ skipped + a degraded note (never a throw).
GARB2="$(jq -c '.projects[0].holds=[null, {type:"gate", id:"gate:ok", task_count:1, why:"w", unblocks_when:"u", owner:"you", scope:"task", set_at:"2026-05-29T00:00:00Z", editable:true, degraded:[]}]' <<<"$FIX")"
VG2="$(render rhythmGame "$GARB2")"
ck "null hold entry ⇒ ok:true (no throw)"              eq "$(jq -r '.ok' <<<"$VG2")" "true"
ck "null hold entry ⇒ the valid gate still renders"    eq "$(jq -r '.gates|length' <<<"$VG2")" "1"
ck "null hold entry ⇒ a degraded 'malformed' note"     has "malformed" "$(jq -r '.degraded|join("|")' <<<"$VG2")"
# a gate with no valid id ⇒ NOT rendered (un-addressable) but named in degraded[].
GARB3="$(jq -c '.projects[0].holds=[{type:"gate", task_count:1, editable:true}]' <<<"$FIX")"
VG3="$(render rhythmGame "$GARB3")"
ck "id-less gate ⇒ ok:true (no throw)"                 eq "$(jq -r '.ok' <<<"$VG3")" "true"
ck "id-less gate ⇒ dropped from gates[] (un-addressable)" eq "$(jq -r '.gates|length' <<<"$VG3")" "0"
ck "id-less gate ⇒ a degraded note names it"           has "no valid id" "$(jq -r '.degraded|join("|")' <<<"$VG3")"

echo "── L: pure helpers (relAge / ownerLabel / countLabel) ──"
rel() { node -e 'const GV=require(process.argv[1]);process.stdout.write(String(GV.relAge(process.argv[2], Number(process.argv[3]))))' "$VIEW" "$1" "$NOW_MS"; }
ck "relAge 4d → '4d ago'"      eq "$(rel '2026-05-29T00:00:00Z')" "4d ago"
ck "relAge 3h → '3h ago'"      eq "$(rel '2026-06-01T21:00:00Z')" "3h ago"
ck "relAge 30s → 'just now'"   eq "$(rel '2026-06-01T23:59:30Z')" "just now"
ck "relAge future → null"      eq "$(rel '2026-07-01T00:00:00Z')" "null"
ck "relAge garbage → null"     eq "$(rel 'not-a-date')" "null"
ownr() { node -e 'const GV=require(process.argv[1]);process.stdout.write(String(GV.ownerLabel(process.argv[2]===""?null:process.argv[2])))' "$VIEW" "$1"; }
ck "ownerLabel you → 'you'"            eq "$(ownr 'you')" "you"
ck "ownerLabel agent:x → 'agent: x'"   eq "$(ownr 'agent:enricher')" "agent: enricher"
ck "ownerLabel null → unrecorded"      eq "$(ownr '')" "(owner unrecorded)"
cnt() { node -e 'const GV=require(process.argv[1]);process.stdout.write(String(GV.countLabel(Number(process.argv[2]))))' "$VIEW" "$1"; }
ck "countLabel(3) '3 tasks'"   eq "$(cnt 3)" "3 tasks"
ck "countLabel(1) '1 task'"    eq "$(cnt 1)" "1 task"
ck "countLabel(0) 'no tasks'"  eq "$(cnt 0)" "no tasks"

echo "── M: pure module + page wiring (anti-drift / structure) ──"
ck "gates-view.js makes NO network call (no fetch)"    hasnt "fetch(" "$(cat "$VIEW")"
ck "gates-view.js has no write/POST verb"              hasnt "postJSON" "$(cat "$VIEW")"
ck "gates-view.js touches NO DOM (no document.)"       hasnt "document." "$(cat "$VIEW")"
ck "app.js routes the 'gates' facet to a live mount"   has "ctx.facet === 'gates'" "$(cat "$APP")"
ck "app.js mounts the gates facet"                     has "mountGatesFacet" "$(cat "$APP")"
ck "app.js reads /api/board for the facet"             has "Net.getJSON('/api/board')" "$(cat "$APP")"
ck "app.js owns a 30s auto-refresh"                    has "REFRESH_MS = 30000" "$(cat "$APP")"
# The why/unblock metadata is an engine-DIRECT write (gate-meta-set); the label
# lift/apply is the HOST-effecting agent-action (gate-defer.sh via the daemon).
ck "app.js posts gate metadata to the engine-direct gate-meta proxy" \
   has "/api/ws/gate-meta" "$(cat "$APP")"
ck "app.js posts the label lift/apply to the gate-action control proxy" \
   has "/api/control/gate-action" "$(cat "$APP")"
ck "app.js renders edit affordances only on an editable gate (g.editable)" \
   has "if (g.editable)" "$(cat "$APP")"
ck "FACET_TRACK no longer lists gates (it graduated)"  hasnt "gates: 'J3'" "$(cat "$APP")"
# The J3 control proxy hard-allows ONLY the two label intents.
ck "gate-action proxy allows gate-apply"               has "gate-apply" "$(cat "$PROXY")"
ck "gate-action proxy allows gate-lift"                has "gate-lift" "$(cat "$PROXY")"
ck "gate-action proxy hard-codes op agent-action"      has "agent-action" "$(cat "$PROXY")"
# Absolute asset paths (q6z7) — a relative ./x would 404 under /ws/<ref>/gates.
ck "index.html loads /workspace/gates-view.js (absolute)" has 'src="/workspace/gates-view.js"' "$(cat "$HTML")"
ck "index.html has NO relative ./ asset path"          hasnt 'src="./' "$(cat "$HTML")"
# CSS draws the editable gate + the read-only register + the lift action.
ck "css styles the gate card (.gf-gate)"               has ".gf-gate" "$(cat "$CSS")"
ck "css styles the read-only register (.gf-readonly)"  has ".gf-readonly" "$(cat "$CSS")"
ck "css styles the lift action (.gf-act-lift)"         has ".gf-act-lift" "$(cat "$CSS")"

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " test-gates-view (gates-facet J3):  PASS=$PASS  FAIL=$FAIL"
echo "══════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
