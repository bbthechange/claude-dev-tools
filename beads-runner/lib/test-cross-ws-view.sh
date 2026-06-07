#!/bin/bash
# beads-runner/lib/test-cross-ws-view.sh — focused unit test for the C-shell
# CROSS-WS global view (unit label: cross-ws-view; K5 / claude-tools-uxvk5;
# DESIGN K §6 / UX-DESIGN-V2 §8.4).
#
# Mirrors lib/test-capacity-view.sh's technique: a node `require` of the PURE
# view-model (web/cross-ws/cross-ws-view.js), fed hand-crafted relay-log-tail
# (B.3) + blueprint-get (B.2) inputs, asserting the derived model. Lives OUTSIDE
# the deployed web/ dir (here in lib/), auto-enrolled in the `lib` tier by glob.
#
# Asserts the K5 unit contract:
#   RELAY LOG (deriveRelayView, B.3 → display, B.4 tolerant)
#     • counts (total/resolved/escalated), pair_label "FE → BE", at_label age
#     • escalated row body points at the decision (dossier_ref), never fabricated
#     • a proxy {ok:false} envelope ⇒ unavailable banner (never a fake log)
#     • an out-of-set outcome degrades to "unknown" + a degraded[] note (no throw)
#   COUPLING MAP (federateCoupling → BlueprintView.deriveBlueprintView — the H2
#     renderer REUSED verbatim, DESIGN K §6.1)
#     • each workspace in the relay log becomes a top-level box
#     • each from→to relay becomes a coupling edge (bundled count = #exchanges)
#     • a workspace's blueprint top-level domains ride along as drill-in children
#     • an empty relay log ⇒ honest empty federation + empty H2 view (no coupling)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIEW="$HERE/../web/cross-ws/cross-ws-view.js"
BP="$HERE/../web/workspace/blueprint-view.js"
[[ -f "$VIEW" ]] || { echo "FATAL: cross-ws-view.js not found at $VIEW"; exit 2; }
[[ -f "$BP"   ]] || { echo "FATAL: blueprint-view.js not found at $BP"; exit 2; }
command -v node >/dev/null 2>&1 || { echo "FATAL: node required for the Cross-WS view test"; exit 2; }
command -v jq   >/dev/null 2>&1 || { echo "FATAL: jq required for assertions"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \xe2\x9c\x93 %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \xe2\x9c\x97 %s\n' "$1"; FAIL=$((FAIL+1)); }
ck()  { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
has()   { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }
hasnt() { case "$2" in *"$1"*) return 1;; *) return 0;; esac; }
eq()    { [[ "$1" == "$2" ]]; }

# A FIXED clock so at_label age buckets are deterministic.
NOW='Date.parse("2026-06-06T12:00:00Z")'

# relay(): pipe { } JSON {relay,blueprints} → deriveRelayView(relay).
relay() { printf '%s' "$1" | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    const CW=require(process.argv[1]);
    const inp=JSON.parse(s);
    process.stdout.write(JSON.stringify(CW.deriveRelayView(inp.relay, '"$NOW"')));
  });' "$VIEW"; }

# couple(): federate THEN feed the record to deriveBlueprintView (the H2 reuse),
# emitting a compact { fed, view } for assertions.
couple() { printf '%s' "$1" | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    const CW=require(process.argv[1]); const BV=require(process.argv[2]);
    const inp=JSON.parse(s);
    const fed=CW.federateCoupling(inp.relay, inp.blueprints||{});
    const view=BV.deriveBlueprintView(fed.record, '"$NOW"', {});
    const topVis=view.nodes.filter(n=>n.top_level&&n.visible)
      .map(n=>({id:n.id,label:n.label,children:n.children.length}));
    process.stdout.write(JSON.stringify({
      fed:{workspace_count:fed.workspace_count,coupling_edges_raw:fed.coupling_edges_raw,
           empty:fed.empty,refs:fed.workspace_refs,degraded:fed.degraded},
      view:{ok:view.ok,empty:view.empty,top:view.counts.top_level,edges:view.counts.edges,
            nodes:topVis,edgeList:view.edges.map(e=>({from:e.from,to:e.to,count:e.count}))}
    }));
  });' "$VIEW" "$BP"; }

# refs(): relayWorkspaceRefs(relay) → JSON array.
refs() { printf '%s' "$1" | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    const CW=require(process.argv[1]);
    process.stdout.write(JSON.stringify(CW.relayWorkspaceRefs(JSON.parse(s).relay)));
  });' "$VIEW"; }

# A good relay log: FE→BE resolved, FE→BE escalated (→ dossier), BE→FE resolved.
GOOD='{"relay":{"exchanges":[
  {"id":"x1","from_ws":"FE","to_ws":"BE","at":"2026-06-06T09:00:00Z","question":"cancel endpoint shape?","answer":"204 on already-cancelled","outcome":"resolved","dossier_ref":null},
  {"id":"x2","from_ws":"FE","to_ws":"BE","at":"2026-06-06T11:30:00Z","question":"refund field name?","answer":"","outcome":"escalated","dossier_ref":"thirsty-be-12f"},
  {"id":"x3","from_ws":"BE","to_ws":"FE","at":"2026-06-06T11:50:00Z","question":"auth header?","answer":"Bearer in Authorization","outcome":"resolved","dossier_ref":null}
]},
"blueprints":{"FE":{"schema_version":1,"project_ref":"FE","derived":{"nodes":[
  {"id":"domain:posts","label":"Posts","kind":"domain","parent":null},
  {"id":"domain:profile","label":"Profile","kind":"domain","parent":null},
  {"id":"capability:create-post","label":"Create Post","kind":"capability","parent":"domain:posts"}
],"edges":[],"apis":[]}}}}'

echo "── EXIT-1: relay log — counts, pair label, escalation pointer ──"
RV="$(relay "$GOOD")"
ck "deriveRelayView ok:true"                              eq "$(jq -r '.ok' <<<"$RV")" "true"
ck "not unavailable on a good log"                        eq "$(jq -r '.unavailable' <<<"$RV")" "false"
ck "total exchanges = 3"                                  eq "$(jq -r '.counts.total' <<<"$RV")" "3"
ck "resolved count = 2"                                   eq "$(jq -r '.counts.resolved' <<<"$RV")" "2"
ck "escalated count = 1"                                  eq "$(jq -r '.counts.escalated' <<<"$RV")" "1"
ck "row 0 pair_label 'FE → BE'"                           eq "$(jq -r '.exchanges[0].pair_label' <<<"$RV")" "FE → BE"
ck "row 0 resolved body = the answer"                     has "204 on already-cancelled" "$(jq -r '.exchanges[0].body' <<<"$RV")"
ck "row 0 at_label '3h ago' (fixed clock)"               eq "$(jq -r '.exchanges[0].at_label' <<<"$RV")" "3h ago"
ck "row 1 escalated flag true"                            eq "$(jq -r '.exchanges[1].escalated' <<<"$RV")" "true"
ck "row 1 body points at the decision (dossier_ref)"     has "thirsty-be-12f" "$(jq -r '.exchanges[1].body' <<<"$RV")"
ck "row 1 body says escalated (not a fabricated answer)" has "escalated to a decision" "$(jq -r '.exchanges[1].body' <<<"$RV")"
ck "row 1 at_label '30m ago'"                            eq "$(jq -r '.exchanges[1].at_label' <<<"$RV")" "30m ago"
ck "empty:false on a non-empty log"                      eq "$(jq -r '.empty' <<<"$RV")" "false"

echo "── EXIT-2: coupling map — federate THEN reuse the H2 renderer ──"
CP="$(couple "$GOOD")"
ck "federate workspace_count = 2 (FE, BE)"               eq "$(jq -r '.fed.workspace_count' <<<"$CP")" "2"
ck "federate raw coupling edges = 3 (one per exchange)"  eq "$(jq -r '.fed.coupling_edges_raw' <<<"$CP")" "3"
ck "H2 view ok:true (federated record renders)"          eq "$(jq -r '.view.ok' <<<"$CP")" "true"
ck "H2 view NOT empty"                                    eq "$(jq -r '.view.empty' <<<"$CP")" "false"
ck "H2 top-level boxes = 2 (the two workspaces)"         eq "$(jq -r '.view.top' <<<"$CP")" "2"
ck "domain:fe box present"                                eq "$(jq -r '[.view.nodes[].id]|index("domain:fe")|type' <<<"$CP")" "number"
ck "domain:be box present"                                eq "$(jq -r '[.view.nodes[].id]|index("domain:be")|type' <<<"$CP")" "number"
ck "FE box carries 2 drill-in domains (blueprint slice)" eq "$(jq -r '.view.nodes[]|select(.id=="domain:fe").children' <<<"$CP")" "2"
ck "BE box (no blueprint) carries 0 drill-in domains"    eq "$(jq -r '.view.nodes[]|select(.id=="domain:be").children' <<<"$CP")" "0"
ck "H2 bundles edges to 2 (FE→BE, BE→FE)"                eq "$(jq -r '.view.edges' <<<"$CP")" "2"
ck "FE→BE coupling edge count = 2 (two exchanges)"       eq "$(jq -r '.view.edgeList[]|select(.from=="domain:fe" and .to=="domain:be").count' <<<"$CP")" "2"
ck "BE→FE coupling edge count = 1"                       eq "$(jq -r '.view.edgeList[]|select(.from=="domain:be" and .to=="domain:fe").count' <<<"$CP")" "1"

echo "── EXIT-3: relayWorkspaceRefs — unique, first-seen order ──"
RF="$(refs "$GOOD")"
ck "refs = [FE, BE] (unique, in order)"                  eq "$(jq -c '.' <<<"$RF")" '["FE","BE"]'

echo "── EXIT-4: empty relay log ⇒ honest no-coupling, never a phantom ──"
EMPTY='{"relay":{"exchanges":[]}}'
RVE="$(relay "$EMPTY")"; CPE="$(couple "$EMPTY")"
ck "relay empty:true"                                     eq "$(jq -r '.empty' <<<"$RVE")" "true"
ck "relay counts.total 0"                                 eq "$(jq -r '.counts.total' <<<"$RVE")" "0"
ck "federate empty:true"                                  eq "$(jq -r '.fed.empty' <<<"$CPE")" "true"
ck "federate workspace_count 0"                           eq "$(jq -r '.fed.workspace_count' <<<"$CPE")" "0"
ck "H2 view empty:true (no workspaces ⇒ no map)"         eq "$(jq -r '.view.empty' <<<"$CPE")" "true"
ck "H2 view ok:true even when empty (no refusal)"        eq "$(jq -r '.view.ok' <<<"$CPE")" "true"

echo "── EXIT-5: proxy error envelope ⇒ unavailable, never a fake log (B.4) ──"
DOWN='{"relay":{"ok":false,"error":"Coordinator unreachable from the Cross-WS relay read proxy"}}'
RVD="$(relay "$DOWN")"
ck "relay unavailable:true on an {ok:false} envelope"    eq "$(jq -r '.unavailable' <<<"$RVD")" "true"
ck "relay surfaces the proxy error verbatim"             has "Coordinator unreachable" "$(jq -r '.error' <<<"$RVD")"
ck "relay exchanges empty (no fabricated rows)"          eq "$(jq -r '.exchanges|length' <<<"$RVD")" "0"
ck "relay still ok:true (degrade, never throw)"          eq "$(jq -r '.ok' <<<"$RVD")" "true"

echo "── EXIT-6: tolerance — out-of-set outcome + missing exchanges array ──"
WEIRD='{"relay":{"exchanges":[{"id":"w1","from_ws":"FE","to_ws":"BE","at":"2026-06-06T11:00:00Z","question":"q","answer":"a","outcome":"maybe","dossier_ref":null}]}}'
RVW="$(relay "$WEIRD")"
ck "out-of-set outcome shown as 'unknown' (not coerced)" eq "$(jq -r '.exchanges[0].outcome' <<<"$RVW")" "unknown"
ck "out-of-set outcome counted as unknown"               eq "$(jq -r '.counts.unknown' <<<"$RVW")" "1"
ck "out-of-set outcome adds a degraded[] note"           has "not in {resolved,escalated}" "$(jq -r '.degraded|join(" ")' <<<"$RVW")"
NOARR='{"relay":{}}'
RVN="$(relay "$NOARR")"
ck "missing exchanges[] ⇒ empty (tolerant, no throw)"    eq "$(jq -r '.empty' <<<"$RVN")" "true"
ck "missing exchanges[] ⇒ degraded[] note"               has "no exchanges[] array" "$(jq -r '.degraded|join(" ")' <<<"$RVN")"

echo "── EXIT-7: slugify — a spaced workspace ref → a valid §4 node id ──"
SPACED='{"relay":{"exchanges":[{"id":"s1","from_ws":"Frontend App","to_ws":"BE","question":"q","answer":"a","outcome":"resolved"}]}}'
CPS="$(couple "$SPACED")"
ck "spaced ref 'Frontend App' → box domain:frontend-app" eq "$(jq -r '[.view.nodes[].id]|index("domain:frontend-app")|type' <<<"$CPS")" "number"
ck "label stays the human ref 'Frontend App'"            eq "$(jq -r '.view.nodes[]|select(.id=="domain:frontend-app").label' <<<"$CPS")" "Frontend App"

echo "── EXIT-8: a newer-schema workspace blueprint degrades children, keeps box ──"
NEWER='{"relay":{"exchanges":[{"id":"n1","from_ws":"FE","to_ws":"BE","question":"q","answer":"a","outcome":"resolved"}]},
"blueprints":{"FE":{"schema_version":99,"project_ref":"FE","derived":{"nodes":[{"id":"domain:x","label":"X","kind":"domain","parent":null}],"edges":[],"apis":[]}}}}'
CPN="$(couple "$NEWER")"
ck "newer-schema FE box STILL present (not refused)"     eq "$(jq -r '[.view.nodes[].id]|index("domain:fe")|type' <<<"$CPN")" "number"
ck "newer-schema FE drill-in children omitted (degrade)" eq "$(jq -r '.view.nodes[]|select(.id=="domain:fe").children' <<<"$CPN")" "0"
ck "newer-schema adds a federation degraded[] note"      has "newer than this view" "$(jq -r '.fed.degraded|join(" ")' <<<"$CPN")"

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " test-cross-ws-view (unit: cross-ws-view):  PASS=$PASS  FAIL=$FAIL"
echo "══════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
