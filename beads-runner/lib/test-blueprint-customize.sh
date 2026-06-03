#!/bin/bash
# beads-runner/lib/test-blueprint-customize.sh — focused unit test for the
# Blueprint CUSTOMIZATION controller view-model (H4, claude-tools-uxvh4; DESIGN H
# = design/blueprint.md §5 + §4, UX-DESIGN-V2 §6.3/§14.2, Contract B.2/B.4). It
# pins the WRITE-SIDE seam H2's blueprint-view.js reads back:
#   • the six override builders (rename/regroup/pin/hide/split/merge) — each PURE
#     (never mutates its input — the in-memory analogue of never-clobber, §2.3),
#     each emitting a POST-ready customization sub-object, each refusing an
#     out-of-§4-shape node id;
#   • conflict resolution (§5.3 keep / drop): DROP removes the backing override;
#     KEEP records a persisted ack and is NEVER a revert (the §14.2 default);
#   • deriveLiveConflicts — the honest projection over the append-only conflicts[]
#     log: dedup, ack-suppress (keep), drop-suppress, and the §4 reattach
#     auto-resolve (node id back in derived ⇒ no FYI, no churn).
#
# Mirrors lib/test-blueprint-view.sh / test-gates-view.sh: node-`require` the pure
# module (web/workspace/blueprint-customize.js), no DOM, no network, no bash
# coordinator. The composed scenarios run in a STATIC node dispatcher (a fixed
# scenario table — no eval / no new Function); bash tallies the JSON results.
# Self-contained: needs only node + jq. Run from the repo root.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="$HERE/../web/workspace/blueprint-customize.js"
HTML="$HERE/../web/workspace/index.html"
[[ -f "$MOD" ]] || { echo "FATAL: blueprint-customize.js not found at $MOD"; exit 2; }
command -v node >/dev/null 2>&1 || { echo "FATAL: node required"; exit 2; }
command -v jq   >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \xe2\x9c\x93 %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \xe2\x9c\x97 %s\n' "$1"; FAIL=$((FAIL+1)); }
ck()  { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
eq()  { [[ "$1" == "$2" ]]; }

# The STATIC scenario dispatcher: a fixed table of named scenarios, each composed
# of plain module calls (no dynamic code). scn <name> → JSON result on stdout.
# Written outside the repo tree so a hard-kill never leaves an artifact in lib/.
DRIVER="$(mktemp "${TMPDIR:-/tmp}/bp-customize-driver.XXXXXX.js")"
cat > "$DRIVER" <<'JS'
// argv: [node, <this driver>, <module path>, <scenario name>]
const BC = require(process.argv[2]);
const EMPTY = () => ({ renames:{}, regroups:{}, pins:[], hidden:[], splits:[], merges:[] });

// fixtures (functions so each scenario gets a fresh, unshared copy)
const recOrphan = () => ({
  schema_version:1, project_ref:"rg",
  derived:{ nodes:[{id:"domain:posts-feed",label:"Posts",kind:"domain",parent:null}], edges:[], apis:[] },
  customization:{ renames:{"capability:create-post":"Publish"}, regroups:{}, pins:[], hidden:[], splits:[], merges:[] },
  conflicts:[
    {kind:"rename-orphan", node_id:"capability:create-post", custom:"Publish", note:"no longer maps to code — keep / drop?"},
    {kind:"rename-orphan", node_id:"capability:create-post", custom:"Publish", note:"DUPLICATE from a 2nd regen"}
  ]
});
const recReattach = () => ({
  schema_version:1, project_ref:"rg",
  derived:{ nodes:[
    {id:"domain:posts-feed",label:"Posts",kind:"domain",parent:null},
    {id:"capability:create-post",label:"Create",kind:"capability",parent:"domain:posts-feed"}
  ], edges:[], apis:[] },
  customization:{ renames:{"capability:create-post":"Publish"}, regroups:{}, pins:[], hidden:[], splits:[], merges:[] },
  conflicts:[ {kind:"rename-orphan", node_id:"capability:create-post", custom:"Publish", note:"stale"} ]
});
const recNoBack = () => ({
  schema_version:1, project_ref:"rg",
  derived:{ nodes:[{id:"domain:posts-feed",label:"Posts",kind:"domain",parent:null}], edges:[], apis:[] },
  customization:{ renames:{}, regroups:{}, pins:[], hidden:[], splits:[], merges:[] },
  conflicts:[ {kind:"rename-orphan", node_id:"capability:create-post", custom:"Publish", note:"already dropped"} ]
});
const recMixed = () => ({
  schema_version:1, project_ref:"rg",
  derived:{ nodes:[{id:"domain:posts-feed",label:"Posts",kind:"domain",parent:null}], edges:[], apis:[] },
  customization:{ renames:{}, regroups:{}, pins:[], hidden:["vendor:gone"], splits:[], merges:[] },
  conflicts:[ {kind:"bogus"}, null, "nope", {kind:"hide-orphan", node_id:"vendor:gone", custom:null, note:"hidden vendor no longer in code"} ]
});

const T = {
  rename() {
    const b = EMPTY(); const r = BC.rename(b, "capability:create-post", "Publish");
    return { ok:r.ok, name:r.customization.renames["capability:create-post"], inputUntouched:Object.keys(b.renames).length===0 };
  },
  renameClear() {
    const b = { renames:{"capability:create-post":"Publish"}, regroups:{}, pins:[], hidden:[], splits:[], merges:[] };
    const r = BC.rename(b, "capability:create-post", "");
    return { has:("capability:create-post" in r.customization.renames) };
  },
  renameBadId()  { return { ok: BC.rename(EMPTY(), "not-a-node-id", "X").ok }; },
  regroup()      { const r = BC.regroup(EMPTY(), "capability:notify", "domain:posts-feed"); return { ok:r.ok, p:r.customization.regroups["capability:notify"] }; },
  regroupSelf()  { return { ok: BC.regroup(EMPTY(), "domain:x", "domain:x").ok }; },
  togglePin() {
    const r = BC.togglePin(EMPTY(), "domain:posts-feed"); const on = r.customization.pins.indexOf("domain:posts-feed")>=0;
    const r2 = BC.togglePin(r.customization, "domain:posts-feed"); const off = r2.customization.pins.indexOf("domain:posts-feed")<0;
    return { on, off };
  },
  toggleHide() {
    const r = BC.toggleHide(EMPTY(), "vendor:datadog");
    return { hidden:r.customization.hidden.indexOf("vendor:datadog")>=0, isHidden:BC.isHidden(r.customization,"vendor:datadog") };
  },
  splitMerge() {
    const r = BC.addSplit(EMPTY(), {id:"domain:big", into:["domain:a","domain:b"]});
    const m = BC.addMerge(r.customization, {from:["domain:a","domain:b"], into:"domain:ab"});
    return { splits:m.customization.splits.length, merges:m.customization.merges.length };
  },
  serialize() {
    const s = BC.serializeCustomization(EMPTY());
    return { isObj:(s.renames && typeof s.renames==="object" && !Array.isArray(s.renames)), hasAcked:("acked" in s) };
  },
  liveOrphan() {
    const lc = BC.deriveLiveConflicts(recOrphan()); const c = lc[0]||{};
    return { n:lc.length, kind:c.kind, resolvable:c.resolvable, key:c.key };
  },
  keep() {
    const r = recOrphan(); const kept = BC.keepConflict(r.customization, r.conflicts[0]);
    const r2 = Object.assign({}, r, { customization:kept.customization });
    const lc = BC.deriveLiveConflicts(r2);
    return { live:lc.length, renameKept:kept.customization.renames["capability:create-post"], acked:(kept.customization.acked||[]).length };
  },
  drop() {
    const r = recOrphan(); const dropped = BC.dropConflict(r.customization, r.conflicts[0]);
    const r2 = Object.assign({}, r, { customization:dropped.customization });
    const lc = BC.deriveLiveConflicts(r2);
    return { live:lc.length, has:("capability:create-post" in dropped.customization.renames) };
  },
  reattach()  { return { live: BC.deriveLiveConflicts(recReattach()).length }; },
  noBacking() { return { live: BC.deriveLiveConflicts(recNoBack()).length }; },
  mixed()     { const lc = BC.deriveLiveConflicts(recMixed()); return { live:lc.length, kind:(lc[0]||{}).kind }; },
  tolerance() {
    return { nullRec:BC.deriveLiveConflicts(null).length, garbledCust:Object.keys(BC.normalizeCustomization("nope").renames).length, badConflictKey:BC.conflictKey({kind:"x"}) };
  },
  neverClobber() {
    const c = { renames:{"capability:create-post":"Publish"}, regroups:{}, pins:["domain:posts-feed"], hidden:[], splits:[], merges:[] };
    const before = JSON.stringify(c);
    const rec = { schema_version:1, derived:{nodes:[],edges:[],apis:[]}, customization:c, conflicts:[] };
    for (let i=0;i<5;i++) BC.deriveLiveConflicts(rec);
    return { unchanged: JSON.stringify(c)===before };
  },
  protoSafe() {
    // a hostile "__proto__" rename key is an honest miss (dropped at normalize),
    // a valid id survives, and serialize never pollutes Object.prototype.
    const n = BC.normalizeCustomization({ renames:{ "__proto__":"evil", "capability:a":"L" }, regroups:{} });
    const s = BC.serializeCustomization(n);
    return { keys:Object.keys(s.renames), polluted:({}).evil !== undefined };
  },
  entryDeepCopy() {
    // a split/merge entry object shares NO reference with the input (total purity).
    const e = { id:"domain:big", note:"x" };
    const r = BC.addSplit(EMPTY(), e);
    e.note = "MUT"; // mutate the ORIGINAL after the builder ran
    return { outNote: r.customization.splits[0].note };
  }
};

const name = process.argv[3];
const fn = Object.prototype.hasOwnProperty.call(T, name) ? T[name] : null;
process.stdout.write(JSON.stringify(fn ? fn() : { err:"unknown scenario "+name }));
JS
trap 'rm -f "$DRIVER"' EXIT

scn() { node "$DRIVER" "$MOD" "$1"; }

echo "── builders: rename / regroup / pin / hide (§5.1), each PURE ──"
OUT="$(scn rename)"
ck "rename sets renames[id]=label"                          eq "$(jq -r '.name' <<<"$OUT")" "Publish"
ck "rename returns ok"                                      eq "$(jq -r '.ok' <<<"$OUT")" "true"
ck "rename does NOT mutate its input (pure / never-clobber)" eq "$(jq -r '.inputUntouched' <<<"$OUT")" "true"
ck "empty rename label CLEARS the rename (revert to derived)" eq "$(jq -r '.has' <<<"$(scn renameClear)")" "false"
ck "rename REFUSES an out-of-§4-shape node id"              eq "$(jq -r '.ok' <<<"$(scn renameBadId)")" "false"
OUT="$(scn regroup)"
ck "regroup sets regroups[id]=parent"                       eq "$(jq -r '.p' <<<"$OUT")" "domain:posts-feed"
ck "regroup REFUSES self-parent"                            eq "$(jq -r '.ok' <<<"$(scn regroupSelf)")" "false"
ck "togglePin adds then removes from pins[]"                eq "$(jq -r '.on and .off' <<<"$(scn togglePin)")" "true"
ck "toggleHide adds to hidden[] (isHidden agrees)"          eq "$(jq -r '.hidden and .isHidden' <<<"$(scn toggleHide)")" "true"
ck "addSplit/addMerge record the entries (model complete)"  eq "$(jq -r '(.splits|tostring)+"/"+(.merges|tostring)' <<<"$(scn splitMerge)")" "1/1"

echo "── serialize: POST-ready shape, empty acked omitted (stays B.2-shaped) ──"
OUT="$(scn serialize)"
ck "serialize emits renames as an OBJECT"                   eq "$(jq -r '.isObj' <<<"$OUT")" "true"
ck "serialize OMITS an empty acked (B.2 six-kind shape)"    eq "$(jq -r '.hasAcked' <<<"$OUT")" "false"

echo "── deriveLiveConflicts: dedup, drop, keep(ack), §4 reattach auto-resolve ──"
OUT="$(scn liveOrphan)"
ck "orphan with a present override ⇒ 1 LIVE conflict"       eq "$(jq -r '.n' <<<"$OUT")" "1"
ck "live conflict carries its kind"                         eq "$(jq -r '.kind' <<<"$OUT")" "rename-orphan"
ck "recognised kind is resolvable (drop offered)"           eq "$(jq -r '.resolvable' <<<"$OUT")" "true"
ck "conflictKey is <kind>:<node_id>"                        eq "$(jq -r '.key' <<<"$OUT")" "rename-orphan:capability:create-post"
OUT="$(scn keep)"
ck "KEEP suppresses the FYI (0 live after ack)"             eq "$(jq -r '.live' <<<"$OUT")" "0"
ck "KEEP is NEVER a revert (the rename persists)"           eq "$(jq -r '.renameKept' <<<"$OUT")" "Publish"
ck "KEEP records exactly one ack"                           eq "$(jq -r '.acked' <<<"$OUT")" "1"
OUT="$(scn drop)"
ck "DROP removes the backing rename override"               eq "$(jq -r '.has' <<<"$OUT")" "false"
ck "DROP clears the FYI (0 live after drop)"                eq "$(jq -r '.live' <<<"$OUT")" "0"
ck "§4 reattach (node back in derived) auto-resolves (0 live)" eq "$(jq -r '.live' <<<"$(scn reattach)")" "0"
ck "a conflict whose override is already gone is NOT surfaced" eq "$(jq -r '.live' <<<"$(scn noBacking)")" "0"

echo "── tolerance (B.4): garbage never throws ──"
OUT="$(scn tolerance)"
ck "deriveLiveConflicts(null) ⇒ [] (honest empty, no throw)" eq "$(jq -r '.nullRec' <<<"$OUT")" "0"
ck "a garbled customization normalizes to the empty shape"   eq "$(jq -r '.garbledCust' <<<"$OUT")" "0"
ck "conflictKey of a malformed entry is null"                eq "$(jq -r '.badConflictKey' <<<"$OUT")" "null"
OUT="$(scn mixed)"
ck "malformed conflicts skipped; a valid hide-orphan still surfaces" eq "$(jq -r '.live' <<<"$OUT")" "1"
ck "the surfaced one is the hide-orphan"                     eq "$(jq -r '.kind' <<<"$OUT")" "hide-orphan"

echo "── never-clobber by construction: N renders never touch customization ──"
ck "customization survives 5 render cycles unchanged (never-clobber)" eq "$(jq -r '.unchanged' <<<"$(scn neverClobber)")" "true"

echo "── hardening: hostile keys are honest misses; entries are deep-copied ──"
OUT="$(scn protoSafe)"
ck "a hostile __proto__ rename key is dropped; the valid id survives" eq "$(jq -r '.keys|join(",")' <<<"$OUT")" "capability:a"
ck "serialize never pollutes Object.prototype"                        eq "$(jq -r '.polluted' <<<"$OUT")" "false"
ck "split/merge entries are deep-copied (input mutation does not leak)" eq "$(jq -r '.outNote' <<<"$(scn entryDeepCopy)")" "x"

echo "── wiring: index.html loads the customization controller before app.js ──"
ck "index.html includes the blueprint-customize.js script tag" \
   grep -q 'blueprint-customize.js' "$HTML"
ORDER="$(grep -nE 'blueprint-view.js|blueprint-customize.js|/workspace/app.js' "$HTML" | grep -oE 'blueprint-view|blueprint-customize|app' | tr '\n' ' ')"
ck "load order is view → customize → app" eq "$ORDER" "blueprint-view blueprint-customize app "

echo
echo "blueprint-customize: pass=$PASS fail=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
