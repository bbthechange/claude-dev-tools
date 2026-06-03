#!/bin/bash
# beads-runner/lib/test-blueprint-view.sh — focused unit test for the Blueprint
# MAP renderer view-model (H2, claude-tools-uxvh2; DESIGN H = design/blueprint.md
# §3 + §4, UX-DESIGN-V2 §6.1, Contract B.2/B.4/C). It pins the ported Diagrammer
# IP: the node/edge/api SCHEMA, EDGE-RESOLUTION to the deepest VISIBLE ancestor
# (+ bundling + macro/focus density), the customization view-transform keyed by
# STABLE node id (§4), and focus/dim/drill. It does NOT assert layout geometry —
# the layout engine is [free]/swappable (§3.5); only that a layout is emitted.
#
# Mirrors lib/test-gates-view.sh's node-require technique (the s6 invariant on the
# bead: "Follow the board-view.js test pattern"): it `require`s the pure view-model
# (web/workspace/blueprint-view.js), feeds a hand-crafted blueprint-get RECORD body
# (the FROZEN B.2 derived:{nodes,edges,apis} shape — the record↔renderer seam, NOT
# the work-snapshot), and asserts the derived model. No bash coordinator is driven.
#
# Asserts: the §3.1 node taxonomy (top-level domains/client/store/vendor, drill-in
# capabilities, queues-as-edges); §3.2 edge resolution (deepest-visible-ancestor +
# duplicate bundling + macro=top-level-only + drill splits a bundle + a formerly-
# internal edge appears on drill); §3.3 APIs as boundary boxes; §3.4 focus/dim/drill
# (focus opens + dims the unconnected, density keeps only touching edges); the §5.2
# customization transform OVER derived keyed by STABLE id §4 (rename/regroup/pin/
# hide; a stale override is a no-op + soft note, never a throw or silent rewrite);
# R-H2 legibility (human capability labels, not function names, survive the port);
# B.4 tolerance (null record ⇒ honest empty; malformed node/edge ⇒ skip + degraded[],
# never throw); the ONE hard refusal = an unknown-HIGHER/missing/non-integer
# schema_version (§0.3).
#
# Self-contained: needs only node + jq. The test FILE lives in beads-runner/lib/
# (out of the deployed web/ dir). Run from the repo root.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIEW="$HERE/../web/workspace/blueprint-view.js"
HTML="$HERE/../web/workspace/index.html"
[[ -f "$VIEW" ]] || { echo "FATAL: blueprint-view.js not found at $VIEW"; exit 2; }
command -v node >/dev/null 2>&1 || { echo "FATAL: node required for the Blueprint view test"; exit 2; }
command -v jq   >/dev/null 2>&1 || { echo "FATAL: jq required for the Blueprint view test"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \xe2\x9c\x93 %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \xe2\x9c\x97 %s\n' "$1"; FAIL=$((FAIL+1)); }
ck()  { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
has()   { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }
hasnt() { case "$2" in *"$1"*) return 1;; *) return 0;; esac; }
eq()    { [[ "$1" == "$2" ]]; }

# A fixed "now" so updated_at relative ages are deterministic (2026-06-02T00:00:00Z).
NOW_MS="$(node -e 'process.stdout.write(String(Date.parse("2026-06-02T00:00:00Z")))')"

# bp <opts-json> <record-json> → the pure view-model JSON at the FIXED now-ms.
bp() { printf '%s' "$2" | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    const BV=require(process.argv[1]);
    let rec; try{rec=JSON.parse(s);}catch(e){rec=null;}
    let opts; try{opts=JSON.parse(process.argv[3]);}catch(e){opts={};}
    process.stdout.write(JSON.stringify(BV.deriveBlueprintView(rec, Number(process.argv[2]), opts)));
  });' "$VIEW" "$NOW_MS" "$1"; }

# ── The fixture: a blueprint-get RECORD body (B.2) for rhythmGame ───────────────
#   nodes: 2 product DOMAINS (Posts & Feed, Messaging), the CLIENT, a STORE, two
#     VENDORS (Twilio, Datadog) at top level; 4 CAPABILITIES nested as drill-in
#     children (human labels, NOT handler names — the R-H2 legibility rule).
#   edges (DEEPEST TRUE endpoints): a client→domain call; two capability→store
#     calls that BUNDLE at macro (same resolved domain→store); a capability→vendor
#     call; a CROSS-DOMAIN capability→capability call; and one INTERNAL
#     capability→capability edge inside Posts&Feed (dropped at macro, appears on
#     drill). apis: 3 boundary boxes. customization: empty (the base).
FIX="$(jq -cn '{
  schema_version: 1,
  project_ref: "rhythmGame",
  updated_by: "agent:blueprint-update",
  updated_at: "2026-06-01T20:00:00Z",
  derived: {
    nodes: [
      { id:"domain:posts-feed", label:"Posts & Feed", kind:"domain", parent:null,
        source_refs:["src/feed/**","handlers/posts.js"], auto_opened:false },
      { id:"domain:messaging", label:"Messaging", kind:"domain", parent:null,
        source_refs:["src/dm/**"], auto_opened:false },
      { id:"client:web-app", label:"Web App", kind:"client", parent:null, source_refs:["web/**"] },
      { id:"store:postgres", label:"Postgres", kind:"store", parent:null, source_refs:["db/**"] },
      { id:"vendor:twilio", label:"Twilio", kind:"vendor", parent:null, source_refs:[] },
      { id:"vendor:datadog", label:"Datadog", kind:"vendor", parent:null, source_refs:[] },
      { id:"capability:create-post", label:"Publish a post", kind:"capability",
        parent:"domain:posts-feed", source_refs:["handlers/posts.js:create"] },
      { id:"capability:rank-feed", label:"Rank the feed", kind:"capability",
        parent:"domain:posts-feed", source_refs:["src/feed/rank.js"] },
      { id:"capability:send-dm", label:"Send a DM", kind:"capability",
        parent:"domain:messaging", source_refs:["src/dm/send.js"] },
      { id:"capability:notify", label:"Notify", kind:"capability",
        parent:"domain:messaging", source_refs:["src/dm/notify.js"] }
    ],
    edges: [
      { from:"client:web-app", to:"domain:posts-feed", kind:"call", bundle_key:"web→posts" },
      { from:"capability:create-post", to:"store:postgres", kind:"call" },
      { from:"capability:rank-feed", to:"store:postgres", kind:"call" },
      { from:"capability:send-dm", to:"vendor:twilio", kind:"call" },
      { from:"capability:create-post", to:"capability:send-dm", kind:"call" },
      { from:"capability:rank-feed", to:"capability:create-post", kind:"data" }
    ],
    apis: [
      { id:"api:POST-/posts", domain:"domain:posts-feed", route:"POST /posts",
        calls:["capability:create-post"] },
      { id:"api:GET-/feed", domain:"domain:posts-feed", route:"GET /feed",
        calls:["capability:rank-feed"] },
      { id:"api:POST-/dm", domain:"domain:messaging", route:"POST /dm",
        calls:["capability:send-dm"] }
    ]
  },
  customization: { renames:{}, regroups:{}, pins:[], hidden:[], splits:[], merges:[] },
  narrative: { tldr:"how it fits", sections:[] },
  conflicts: []
}')"

V="$(bp '{}' "$FIX")"

echo "── A: a good (sv:1) record renders ok:true, scoped to the ref ──"
ck "good record ⇒ ok:true"                     eq "$(jq -r '.ok' <<<"$V")" "true"
ck "found:true (record present)"               eq "$(jq -r '.found' <<<"$V")" "true"
ck "not empty (it has nodes)"                  eq "$(jq -r '.empty' <<<"$V")" "false"
ck "schema_version echoed (1)"                 eq "$(jq -r '.schema_version' <<<"$V")" "1"
ck "project_ref echoed (rhythmGame)"           eq "$(jq -r '.project_ref' <<<"$V")" "rhythmGame"
ck "updated_by surfaced"                       eq "$(jq -r '.updated_by' <<<"$V")" "agent:blueprint-update"
ck "updated_at_age '4h ago' (deterministic now)" eq "$(jq -r '.updated_at_age' <<<"$V")" "4h ago"
ck "10 nodes"                                  eq "$(jq -r '.counts.nodes' <<<"$V")" "10"
ck "6 top-level boxes (2 domains + client + store + 2 vendors)" eq "$(jq -r '.counts.top_level' <<<"$V")" "6"

echo "── B: §0.3 — an unknown HIGHER (or missing/non-integer) sv is REFUSED ──"
VHI="$(bp '{}' "$(jq -c '.schema_version=99' <<<"$FIX")")"
ck "schema_version 99 ⇒ ok:false (refuse)"     eq "$(jq -r '.ok' <<<"$VHI")" "false"
ck "refusal names the unsupported version"     has "schema_version 99" "$(jq -r '.error' <<<"$VHI")"
ck "refusal cites §0.3"                         has "§0.3" "$(jq -r '.error' <<<"$VHI")"
ck "missing schema_version ⇒ ok:false"         eq "$(jq -r '.ok' <<<"$(bp '{}' "$(jq -c 'del(.schema_version)' <<<"$FIX")")")" "false"
ck "non-integer schema_version (1.5) ⇒ ok:false" eq "$(jq -r '.ok' <<<"$(bp '{}' "$(jq -c '.schema_version=1.5' <<<"$FIX")")")" "false"

echo "── C: §3.1 node taxonomy — top-level domains/client/store/vendor, capability children ──"
nd() { jq -c --arg id "$1" '.nodes[]|select(.id==$id)' <<<"$V"; }
ck "domain:posts-feed kind=domain"             eq "$(nd domain:posts-feed | jq -r '.kind')" "domain"
ck "domain:posts-feed is top_level"            eq "$(nd domain:posts-feed | jq -r '.top_level')" "true"
ck "domain:posts-feed is_top_kind:true"        eq "$(nd domain:posts-feed | jq -r '.is_top_kind')" "true"
ck "domain:posts-feed label 'Posts & Feed'"    eq "$(nd domain:posts-feed | jq -r '.label')" "Posts & Feed"
ck "domain:posts-feed has 2 children"          eq "$(nd domain:posts-feed | jq -r '.children|length')" "2"
ck "client:web-app kind=client (top-level box)" eq "$(nd client:web-app | jq -r '.kind')" "client"
ck "store:postgres kind=store"                 eq "$(nd store:postgres | jq -r '.kind')" "store"
ck "vendor:twilio kind=vendor (own box)"       eq "$(nd vendor:twilio | jq -r '.kind')" "vendor"
ck "capability:create-post kind=capability"    eq "$(nd capability:create-post | jq -r '.kind')" "capability"
ck "capability is NOT top_level"               eq "$(nd capability:create-post | jq -r '.top_level')" "false"
ck "capability is_top_kind:false (drill-in)"   eq "$(nd capability:create-post | jq -r '.is_top_kind')" "false"
ck "capability parent is its domain"           eq "$(nd capability:create-post | jq -r '.parent')" "domain:posts-feed"
ck "capability depth 1"                         eq "$(nd capability:create-post | jq -r '.depth')" "1"
# R-H2: a capability carries a HUMAN-MEANINGFUL label (not the handler name), and
# its source_refs (the conflict-detection basis) survive the port.
ck "R-H2 legible label survives ('Publish a post', not the handler)" \
   eq "$(nd capability:create-post | jq -r '.label')" "Publish a post"
ck "capability source_refs carried (conflict basis)" \
   eq "$(nd capability:create-post | jq -r '.source_refs[0]')" "handlers/posts.js:create"
# Queues are EDGES not nodes — no node carries kind 'queue' (that's an edge kind).
ck "no node has kind=queue (queues are edges)" eq "$(jq -r '[.nodes[]|select(.kind=="queue")]|length' <<<"$V")" "0"

echo "── D: MACRO edge resolution — deepest-visible-ancestor + bundle + internal-drop ──"
# At macro (all collapsed) every endpoint resolves to a TOP-LEVEL box.
ck "macro: 4 rendered edges"                   eq "$(jq -r '.counts.edges' <<<"$V")" "4"
ed() { jq -c --arg f "$1" --arg t "$2" '[.edges[]|select(.from==$f and .to==$t)]' <<<"$V"; }
ck "macro: client→domain edge present"         eq "$(ed client:web-app domain:posts-feed | jq -r 'length')" "1"
ck "macro: the two capability→store calls BUNDLE to one domain→store edge" \
   eq "$(ed domain:posts-feed store:postgres | jq -r '.[0].count')" "2"
ck "macro: cross-domain capability call resolves to domain↔domain" \
   eq "$(ed domain:posts-feed domain:messaging | jq -r 'length')" "1"
ck "macro: capability→vendor resolves to domain→vendor" \
   eq "$(ed domain:messaging vendor:twilio | jq -r 'length')" "1"
# The INTERNAL edge (rank-feed→create-post, both inside Posts&Feed) is DROPPED at
# macro — both endpoints collapse into the same visible box (no self-edge).
ck "macro: NO self-edge (internal edge dropped)" \
   eq "$(jq -r '[.edges[]|select(.from==.to)]|length' <<<"$V")" "0"
ck "macro: capabilities are NOT visible (parents collapsed)" \
   eq "$(nd capability:create-post | jq -r '.visible')" "false"
ck "macro: a domain IS visible"                eq "$(nd domain:posts-feed | jq -r '.visible')" "true"

echo "── E: DRILL-IN — opening a domain splits the bundle + reveals the internal edge ──"
VD="$(bp '{"opened":["domain:posts-feed"]}' "$FIX")"
ndd() { jq -c --arg id "$1" '.nodes[]|select(.id==$id)' <<<"$VD"; }
edd() { jq -c --arg f "$1" --arg t "$2" '[.edges[]|select(.from==$f and .to==$t)]' <<<"$VD"; }
ck "drill: posts-feed open (manual)"           eq "$(ndd domain:posts-feed | jq -r '.open')" "true"
ck "drill: open_source 'manual'"               eq "$(ndd domain:posts-feed | jq -r '.open_source')" "manual"
ck "drill: its capabilities are now visible"   eq "$(ndd capability:create-post | jq -r '.visible')" "true"
ck "drill: messaging's children stay collapsed" eq "$(ndd capability:send-dm | jq -r '.visible')" "false"
# The bundle splits: create-post→postgres and rank-feed→postgres are now distinct
# (both endpoints visible) instead of one bundled domain→store edge.
ck "drill: create-post→store edge now distinct" eq "$(edd capability:create-post store:postgres | jq -r 'length')" "1"
ck "drill: rank-feed→store edge now distinct"   eq "$(edd capability:rank-feed store:postgres | jq -r 'length')" "1"
# The formerly-INTERNAL edge now shows (both endpoints visible).
ck "drill: the internal edge now appears"        eq "$(edd capability:rank-feed capability:create-post | jq -r 'length')" "1"

echo "── F: FOCUS / DIM — focus opens the target + dims everything unconnected (§3.4) ──"
VF="$(bp '{"focus":"domain:messaging"}' "$FIX")"
ndf() { jq -c --arg id "$1" '.nodes[]|select(.id==$id)' <<<"$VF"; }
ck "focus echoed"                              eq "$(jq -r '.focus' <<<"$VF")" "domain:messaging"
ck "focus opens the target (zoom-into)"        eq "$(ndf domain:messaging | jq -r '.open')" "true"
ck "focus open_source 'focus' (auto, drill-out collapses it)" eq "$(ndf domain:messaging | jq -r '.open_source')" "focus"
ck "the focused node is marked focused"         eq "$(ndf domain:messaging | jq -r '.focused')" "true"
ck "a focused-subtree child is focused"         eq "$(ndf capability:send-dm | jq -r '.focused')" "true"
# Density: only edges TOUCHING the messaging subtree survive (2 of 6).
ck "focus: only touching edges show (2)"        eq "$(jq -r '.counts.edges' <<<"$VF")" "2"
ck "focus: send-dm→twilio kept"                 eq "$(jq -c '[.edges[]|select(.from=="capability:send-dm" and .to=="vendor:twilio")]|length' <<<"$VF")" "1"
ck "focus: the cross edge into send-dm kept"    eq "$(jq -c '[.edges[]|select(.to=="capability:send-dm")]|length' <<<"$VF")" "1"
# Dim: an unconnected visible box is dimmed; a connected one (posts-feed via the
# cross edge; twilio via send-dm) is NOT.
ck "focus: unconnected web-app DIMMED"          eq "$(ndf client:web-app | jq -r '.dimmed')" "true"
ck "focus: unconnected postgres DIMMED"         eq "$(ndf store:postgres | jq -r '.dimmed')" "true"
ck "focus: connected twilio NOT dimmed"         eq "$(ndf vendor:twilio | jq -r '.dimmed')" "false"
ck "focus: connected posts-feed NOT dimmed (via cross edge)" eq "$(ndf domain:posts-feed | jq -r '.dimmed')" "false"
ck "focus: the focused node is never dimmed"    eq "$(ndf domain:messaging | jq -r '.dimmed')" "false"
# REGRESSION (review wofkpxek2): focus a NON-top-level node. §3.4.4 opens the
# target + its ANCESTORS "so it is visible" and dims "everything NOT connected" —
# the focus-opened ancestor chain is part of "focus on it", so the container the
# renderer just opened to reveal the target must NOT be dimmed. Section F above
# only ever focuses a top-level domain (empty ancestor chain), so it never
# exercises this path; a non-top-level ?focus=<id> deep-link (§8.4) does.
VFC="$(bp '{"focus":"capability:create-post"}' "$FIX")"
ndfc() { jq -c --arg id "$1" '.nodes[]|select(.id==$id)' <<<"$VFC"; }
ck "focus(non-top): target capability is focused"        eq "$(ndfc capability:create-post | jq -r '.focused')" "true"
ck "focus(non-top): target capability is visible"        eq "$(ndfc capability:create-post | jq -r '.visible')" "true"
ck "focus(non-top): parent domain opened (open_source focus)" eq "$(ndfc domain:posts-feed | jq -r '.open_source')" "focus"
ck "focus(non-top): opened parent domain NOT dimmed (the container path focus opened)" \
   eq "$(ndfc domain:posts-feed | jq -r '.dimmed')" "false"
ck "focus(non-top): a genuinely unconnected box still dims" eq "$(ndfc client:web-app | jq -r '.dimmed')" "true"

echo "── G: §3.3 APIs as boundary boxes ('the way in') ──"
ck "3 apis"                                     eq "$(jq -r '.counts.apis' <<<"$V")" "3"
ap() { jq -c --arg id "$1" '.apis[]|select(.id==$id)' <<<"$V"; }
ck "api straddles its domain"                   eq "$(ap api:POST-/posts | jq -r '.domain')" "domain:posts-feed"
ck "api route surfaced"                         eq "$(ap api:POST-/posts | jq -r '.route')" "POST /posts"
ck "api calls the internal capability"          eq "$(ap api:POST-/posts | jq -r '.calls[0]')" "capability:create-post"
ck "api visible iff its domain visible"         eq "$(ap api:POST-/posts | jq -r '.visible')" "true"

echo "── H: §5.2 customization OVER derived, keyed by STABLE id §4 ──"
CUST="$(jq -c '.customization = {
  renames: { "capability:create-post":"Publish", "capability:ghost":"Phantom" },
  regroups: { "capability:notify":"domain:posts-feed" },
  pins: ["domain:posts-feed"],
  hidden: ["vendor:datadog"],
  splits: [], merges: []
}' <<<"$FIX")"
VC="$(bp '{}' "$CUST")"
ndc() { jq -c --arg id "$1" '.nodes[]|select(.id==$id)' <<<"$VC"; }
ck "hide: datadog removed from the view"        eq "$(jq -r '[.nodes[]|select(.id=="vendor:datadog")]|length' <<<"$VC")" "0"
ck "hide: counts.hidden is 1"                   eq "$(jq -r '.counts.hidden' <<<"$VC")" "1"
ck "hide: 9 nodes remain"                       eq "$(jq -r '.counts.nodes' <<<"$VC")" "9"
ck "rename: label is the human override 'Publish'" eq "$(ndc capability:create-post | jq -r '.label')" "Publish"
ck "rename: renamed flag set"                   eq "$(ndc capability:create-post | jq -r '.renamed')" "true"
ck "rename: derived_label kept (a rename is visibly a rename)" eq "$(ndc capability:create-post | jq -r '.derived_label')" "Publish a post"
ck "regroup: notify reparented to posts-feed"   eq "$(ndc capability:notify | jq -r '.parent')" "domain:posts-feed"
ck "regroup: notify is regrouped"               eq "$(ndc capability:notify | jq -r '.regrouped')" "true"
ck "regroup: notify now a child of posts-feed"  eq "$(ndc domain:posts-feed | jq -c '[.children[]|select(.=="capability:notify")]|length')" "1"
ck "regroup: notify NO LONGER a child of messaging" eq "$(ndc domain:messaging | jq -c '[.children[]|select(.=="capability:notify")]|length')" "0"
ck "pin: posts-feed pinned + locked open"       eq "$(ndc domain:posts-feed | jq -r '.pinned')" "true"
ck "pin: posts-feed open_source 'pin'"          eq "$(ndc domain:posts-feed | jq -r '.open_source')" "pin"
ck "pin: a pinned-open domain shows its children" eq "$(ndc capability:create-post | jq -r '.visible')" "true"
# A STALE override (id no longer in derived) is a NO-OP + a soft degraded note —
# never a throw, never a fabricated node (§4 reattach contract / §5.3 keep+FYI).
ck "stale rename did NOT fabricate a node"      eq "$(jq -r '[.nodes[]|select(.id=="capability:ghost")]|length' <<<"$VC")" "0"
ck "stale rename left a soft degraded note"     has "no longer maps to code" "$(jq -r '.degraded|join("|")' <<<"$VC")"

echo "── H2: hide + regroup-OUT — a node regrouped to safety survives the hide cascade ──"
# REGRESSION (code-review on H2): regroups must apply BEFORE the hide cascade so a
# child regrouped OUT of a hidden domain is RESCUED, not destroyed. Hide messaging
# AND regroup its child send-dm to posts-feed: send-dm survives (reparented),
# messaging's OTHER child (notify) is hidden with it, counts.hidden counts ONLY the
# real hides (NOT the rescued node), and NO false "no longer maps" note fires.
HRC="$(jq -c '.customization = {
  renames:{}, regroups:{ "capability:send-dm":"domain:posts-feed" },
  pins:[], hidden:["domain:messaging"], splits:[], merges:[]
}' <<<"$FIX")"
VHR="$(bp '{}' "$HRC")"
ndhr() { jq -c --arg id "$1" '.nodes[]|select(.id==$id)' <<<"$VHR"; }
ck "rescue: regrouped-out send-dm survives the hide"   eq "$(jq -r '[.nodes[]|select(.id=="capability:send-dm")]|length' <<<"$VHR")" "1"
ck "rescue: send-dm reparented to posts-feed"          eq "$(ndhr capability:send-dm | jq -r '.parent')" "domain:posts-feed"
ck "rescue: send-dm regrouped flag set"                eq "$(ndhr capability:send-dm | jq -r '.regrouped')" "true"
ck "rescue: hidden domain:messaging removed"           eq "$(jq -r '[.nodes[]|select(.id=="domain:messaging")]|length' <<<"$VHR")" "0"
ck "rescue: messaging's OTHER child (notify) hidden"   eq "$(jq -r '[.nodes[]|select(.id=="capability:notify")]|length' <<<"$VHR")" "0"
ck "rescue: counts.hidden=2 (messaging+notify, NOT the rescued send-dm)" eq "$(jq -r '.counts.hidden' <<<"$VHR")" "2"
ck "rescue: NO false 'no longer maps' note for the rescued node" hasnt "regroups for capability:send-dm" "$(jq -r '.degraded|join("|")' <<<"$VHR")"

echo "── I: STABLE node identity §4 — makeNodeId + reattach-by-id ──"
mk() { node -e 'const BV=require(process.argv[1]);process.stdout.write(String(BV.makeNodeId(process.argv[2],process.argv[3])))' "$VIEW" "$1" "$2"; }
ck "makeNodeId(domain,posts-feed) ⇒ domain:posts-feed" eq "$(mk domain posts-feed)" "domain:posts-feed"
ck "makeNodeId(store,postgres) ⇒ store:postgres"       eq "$(mk store postgres)" "store:postgres"
ck "makeNodeId rejects an uppercase kind (null)"       eq "$(mk Domain x)" "null"
ck "makeNodeId rejects a spaced slug (null)"           eq "$(mk capability 'Create Post')" "null"
# The same concept keeps the same id ⇒ a rename keyed to a PRESENT id reattaches
# (asserted in H); a rename keyed to an ABSENT id does not (the ghost no-op above).

echo "── J: B.4 tolerance — degrade, never throw, never fabricate ──"
VN="$(bp '{}' 'null')"
ck "null record ⇒ ok:true (honest empty, NOT a refusal)" eq "$(jq -r '.ok' <<<"$VN")" "true"
ck "null record ⇒ found:false"                  eq "$(jq -r '.found' <<<"$VN")" "false"
ck "null record ⇒ empty:true, 0 nodes"          eq "$(jq -r '.counts.nodes' <<<"$VN")" "0"
ck "null record ⇒ honest 'no Blueprint yet' note" has "no Blueprint yet" "$(jq -r '.degraded|join("|")' <<<"$VN")"
# derived.nodes not an array ⇒ empty + note (no throw).
VG1="$(bp '{}' "$(jq -c '.derived.nodes=5' <<<"$FIX")")"
ck "non-array derived.nodes ⇒ ok:true"          eq "$(jq -r '.ok' <<<"$VG1")" "true"
ck "non-array derived.nodes ⇒ 0 nodes"          eq "$(jq -r '.counts.nodes' <<<"$VG1")" "0"
ck "non-array derived.nodes ⇒ degraded note"    has "derived.nodes malformed" "$(jq -r '.degraded|join("|")' <<<"$VG1")"
# a null node entry ⇒ skipped + note; the valid ones still render.
VG2="$(bp '{}' "$(jq -c '.derived.nodes=[null,{id:"domain:ok",label:"OK",kind:"domain",parent:null}]' <<<"$FIX")")"
ck "null node entry ⇒ ok:true (no throw)"        eq "$(jq -r '.ok' <<<"$VG2")" "true"
ck "null node entry ⇒ the valid node still renders" eq "$(jq -r '.counts.nodes' <<<"$VG2")" "1"
ck "null node entry ⇒ a 'malformed' note"        has "malformed" "$(jq -r '.degraded|join("|")' <<<"$VG2")"
# an id-less node ⇒ dropped (un-addressable) + named in degraded[].
VG3="$(bp '{}' "$(jq -c '.derived.nodes=[{label:"no id",kind:"domain",parent:null}]' <<<"$FIX")")"
ck "id-less node ⇒ dropped"                      eq "$(jq -r '.counts.nodes' <<<"$VG3")" "0"
ck "id-less node ⇒ a 'no valid id' note"         has "no valid id" "$(jq -r '.degraded|join("|")' <<<"$VG3")"
# an edge endpoint that isn't a node ⇒ the edge is dropped + noted (never a throw).
VG4="$(bp '{}' "$(jq -c '.derived.edges += [{from:"domain:posts-feed",to:"ghost:x",kind:"call"}]' <<<"$FIX")")"
ck "edge to a non-node ⇒ ok:true"                eq "$(jq -r '.ok' <<<"$VG4")" "true"
ck "edge to a non-node ⇒ dropped + noted"        has "not a visible node" "$(jq -r '.degraded|join("|")' <<<"$VG4")"
# an out-of-set NODE kind ⇒ kept but flagged (never coerced away).
VG5="$(bp '{}' "$(jq -c '.derived.nodes += [{id:"weird:thing",label:"Weird",kind:"sidecar",parent:null}]' <<<"$FIX")")"
ck "out-of-set node kind ⇒ kept (rendered)"      eq "$(jq -r '[.nodes[]|select(.id=="weird:thing")]|length' <<<"$VG5")" "1"
ck "out-of-set node kind ⇒ kind_known:false"     eq "$(jq -r '.nodes[]|select(.id=="weird:thing")|.kind_known' <<<"$VG5")" "false"
ck "out-of-set node kind ⇒ a degraded note"      has "out-of-set kind" "$(jq -r '.degraded|join("|")' <<<"$VG5")"
# an out-of-set EDGE kind ⇒ drawn as a plain link + noted (never dropped silently).
VG6="$(bp '{}' "$(jq -c '.derived.edges += [{from:"client:web-app",to:"store:postgres",kind:"telepathy"}]' <<<"$FIX")")"
ck "out-of-set edge kind ⇒ a degraded note"      has "out-of-set kind" "$(jq -r '.degraded|join("|")' <<<"$VG6")"

echo "── K: pure helpers + anti-drift (structure) ──"
rel() { node -e 'const BV=require(process.argv[1]);process.stdout.write(String(BV.relAge(process.argv[2],Number(process.argv[3]))))' "$VIEW" "$1" "$NOW_MS"; }
ck "relAge 4h → '4h ago'"      eq "$(rel '2026-06-01T20:00:00Z')" "4h ago"
ck "relAge 30s → 'just now'"   eq "$(rel '2026-06-01T23:59:30Z')" "just now"
ck "relAge future → null"      eq "$(rel '2026-07-01T00:00:00Z')" "null"
ck "relAge garbage → null"     eq "$(rel 'not-a-date')" "null"
ck "blueprint-view.js makes NO network call (no fetch)"  hasnt "fetch(" "$(cat "$VIEW")"
ck "blueprint-view.js has no write/POST verb"            hasnt "postJSON" "$(cat "$VIEW")"
ck "blueprint-view.js touches NO DOM (no document.)"     hasnt "document." "$(cat "$VIEW")"
ck "blueprint-view.js has no timers (no setInterval)"    hasnt "setInterval" "$(cat "$VIEW")"

echo "── L: page wiring (absolute asset path — q6z7) ──"
ck "index.html loads /workspace/blueprint-view.js (absolute)" has 'src="/workspace/blueprint-view.js"' "$(cat "$HTML")"
ck "index.html has NO relative ./ asset path"                 hasnt 'src="./' "$(cat "$HTML")"
# Layout geometry is [free] (§3.5) — assert ONLY that a layout is emitted for a
# visible node, NEVER its coordinates.
ck "a visible node carries a layout object (geometry [free], not asserted)" \
   eq "$(nd domain:posts-feed | jq -r 'if (.layout and (.layout.w|type=="number")) then "y" else "n" end')" "y"

echo "── M: hardening — prototype-key safety + counts.hidden honesty + parent cycle ──"
# A hostile customization key (__proto__/constructor/…) must NOT throw and must
# degrade honestly (id-keyed maps are null-proto — review fix #1/#2).
VPP="$(bp '{}' "$(jq -c '.customization = {
  renames: { "__proto__":"Pwn" },
  regroups: { "domain:messaging":"constructor" },
  pins: ["hasOwnProperty"], hidden: ["toString"], splits:[], merges:[]
}' <<<"$FIX")")"
ck "prototype-key customization ⇒ ok:true (no throw)"   eq "$(jq -r '.ok' <<<"$VPP")" "true"
ck "prototype-key customization ⇒ all 10 nodes intact"  eq "$(jq -r '.counts.nodes' <<<"$VPP")" "10"
ck "prototype-key rename degrades honestly (no longer maps)" has "no longer maps to code" "$(jq -r '.degraded|join("|")' <<<"$VPP")"
ck "prototype-key regroup target is not a current node"  has "is not a current node" "$(jq -r '.degraded|join("|")' <<<"$VPP")"
ck "prototype-key messaging left in place (not reparented)" eq "$(jq -r '.nodes[]|select(.id=="domain:messaging")|.parent' <<<"$VPP")" "null"
# counts.hidden counts ONLY real hides — a malformed-node DROP must not inflate it
# (review fix #3). Base fixture has NO hidden; add a null node entry.
VHH="$(bp '{}' "$(jq -c '.derived.nodes += [null]' <<<"$FIX")")"
ck "malformed-drop with no hides ⇒ counts.hidden 0 (not inflated)" eq "$(jq -r '.counts.hidden' <<<"$VHH")" "0"
ck "malformed-drop ⇒ the 10 real nodes still render"    eq "$(jq -r '.counts.nodes' <<<"$VHH")" "10"
# A parent CYCLE must not vanish silently — promote + note (review Q1 / B.4).
VCY="$(bp '{}' "$(jq -cn '{schema_version:1, project_ref:"x", derived:{
  nodes:[
    {id:"domain:a",label:"A",kind:"domain",parent:"domain:b"},
    {id:"domain:b",label:"B",kind:"domain",parent:"domain:a"},
    {id:"domain:c",label:"C",kind:"domain",parent:null}
  ], edges:[], apis:[] }, customization:{}, conflicts:[] }')")"
ck "parent cycle ⇒ ok:true (no throw / no hang)"        eq "$(jq -r '.ok' <<<"$VCY")" "true"
ck "parent cycle ⇒ all 3 nodes counted"                 eq "$(jq -r '.counts.nodes' <<<"$VCY")" "3"
ck "parent cycle ⇒ a degraded 'parent cycle' note"      has "parent cycle" "$(jq -r '.degraded|join("|")' <<<"$VCY")"
ck "parent cycle ⇒ the good sibling stays visible"      eq "$(jq -r '.nodes[]|select(.id=="domain:c")|.visible' <<<"$VCY")" "true"

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " test-blueprint-view (blueprint map renderer H2):  PASS=$PASS  FAIL=$FAIL"
echo "══════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
