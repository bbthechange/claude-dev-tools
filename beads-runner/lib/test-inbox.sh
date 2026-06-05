#!/bin/bash
# beads-runner/lib/test-inbox.sh — focused unit test for the T6b Inbox +
# Flow-G web app (claude-tools-xre): the §5 Dossier render/respond + §4.5
# WAITING-ON-YOU + Flow-G failure visibility + §10.3 forensic.
#
# T6b's OWN test surface. Deliberately NOT a member of the T1 conformance
# suite (owned by T1a/T1b) and it touches NO sibling test (anti-drift: each
# tier its own focused test). It exercises ONLY the Inbox renderer
# (web/inbox/inbox-view.js) + the no-extra-write-path / §9.1-chokepoint
# STRUCTURE of the Pages app.
#
# WHY IT DRIVES THE REAL PRODUCER+APPLIER: the renderer is asserted against
# the ACTUAL §5 Dossier emitted by dossier-gen.sh `dg_generate`, the ACTUAL
# §4.5 projection from coordinator.sh `co__work_snapshot`, the ACTUAL
# idempotent per-Item applier consequence.sh `do_item_apply`, and the ACTUAL
# §10.3 forensic store — the producer↔renderer↔applier seam is tested against
# the FROZEN contract, never a hand-faked shape.
#
# Asserts the EXIT CRITERIA T6b owns against INTERFACE.md v1 §5/§4.5/§10.3:
#   1. A pure-checkbox decision ROUND-TRIPS: notify (lane) → open dossier →
#      approve → consequence applied (T5 do_item_apply) → ack — and the bead
#      unblocks with NO Dolt-lag lie: the ack + the cleared lane derive from
#      the CONTROL-PLANE record (the §7.4 latch), never a Dolt read (S-2).
#   2. Reject / edit is ONE tap (principle 3) — symmetric with approve.
#   3. Reads only the projection + the §4 Dossier it points at; binds §5
#      exactly; the ONLY render refusal is §0.3 unknown-HIGHER schema.
#   CONTRACT (claude-tools-4xe): the §5.1-core conformance gate is at the
#   engine WRITE path, not render-time. So an ACCEPTED dossier is ALWAYS
#   readable AND answerable — a missing §5 field degrades to a clearly-
#   LABELED best-effort fallback, NEVER a wall. The sole refusal is
#   §0.3 unknown-HIGHER, shown as a plain human message (no §/§11 jargon).
#
# Self-contained: its own CO_STORE + fake-bin under mktemp.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENLIB="$HERE/dossier-gen.sh"
CONLIB="$HERE/consequence.sh"
VIEW="$HERE/../web/inbox/inbox-view.js"
APP="$HERE/../web/inbox/app.js"
SHELL_HTML="$HERE/../web/inbox/index.html"
P_INBOX="$HERE/../web/functions/api/inbox/index.js"
P_DOSS="$HERE/../web/functions/api/inbox/dossier.js"
P_RESP="$HERE/../web/functions/api/inbox/respond.js"
P_FOR="$HERE/../web/functions/api/inbox/forensic.js"
P_EXP="$HERE/../web/functions/api/inbox/expire.js"
for f in "$GENLIB" "$CONLIB" "$VIEW" "$APP" "$P_INBOX" "$P_DOSS" "$P_RESP" "$P_FOR" "$P_EXP"; do
  [[ -f "$f" ]] || { echo "FATAL: missing $f"; exit 2; }
done
command -v node >/dev/null 2>&1 || { echo "FATAL: node required"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
ck()  { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
ckok(){ if "${@:2}" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
ckno(){ if "${@:2}" >/dev/null 2>&1; then bad "$1"; else ok "$1"; fi; }
eq()    { [[ "$1" == "$2" ]]; }
has()   { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }
hasnt() { case "$2" in *"$1"*) return 1;; *) return 0;; esac; }
nz()    { [[ -n "$1" && "$1" != "null" ]]; }
jqr()   { jq -r "$2" <<<"$1" 2>/dev/null; }                 # jqr <json> <prog>
opn()   { grep -c "searchParams.set('op'" "$1" 2>/dev/null; } # # of op-on-wire

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export CO_STORE="$WORK/store"
# claude-tools-69u8: isolate the dossier-author audit log so a STANDALONE run
# doesn't pollute the real $HOME/.cache production telemetry (the gate sets it
# itself; honor that). See run-tests.sh / conformance/lib/harness.sh.
export DG_AUDIT_LOG="${DG_AUDIT_LOG:-$WORK/.dossier-author-audit.jsonl}"
unset CO_EXPECTED_TOKEN PRINCIPAL_V1 2>/dev/null || true

# work-plane `bd` fake on PATH (the conformance / test-consequence pattern):
# every call logged so the §5.3 ConsequenceBlock application is OBSERVABLE.
FAKEBIN="$WORK/bin"; mkdir -p "$FAKEBIN"
export BD_LOG="$WORK/bd.log"; : > "$BD_LOG"
cat > "$FAKEBIN/bd" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${BD_LOG:-/dev/null}"
if [[ "${1:-}" == "create" ]]; then
  t=""; while [[ $# -gt 0 ]]; do case "$1" in --title) t="$2"; shift 2;; *) shift;; esac; done
  n=$(( $(wc -l < "${BD_LOG:-/dev/null}" 2>/dev/null || echo 0) ))
  echo "✓ Created issue: bd-fake-$n — $t"
fi
exit 0
EOF
chmod +x "$FAKEBIN/bd"; export PATH="$FAKEBIN:$PATH"

# shellcheck source=/dev/null
source "$GENLIB"
# shellcheck source=/dev/null
source "$CONLIB"
GOOD="bearer-runner-secret-xyz"
GET()  { co_request "$GOOD" get dossier "$1" 2>/dev/null; }
BDN()  { local c; c=$(grep -c -- "$1" "$BD_LOG" 2>/dev/null); echo "${c:-0}"; }
SNAPSHOT() { co_request "$GOOD" work-snapshot "" "[]" 2>/dev/null; }

# Call an inbox-view.js export with JSON args; print its JSON return.
iv() { node -e '
  const V=require(process.argv[1]); const fn=process.argv[2];
  const a=process.argv.slice(3).map(s=>{ try{return JSON.parse(s);}catch(e){return s;} });
  process.stdout.write(JSON.stringify(V[fn].apply(null,a)));' "$VIEW" "$@"; }

CB='{"cb_schema_version":2,"creates":[{"title":"impl from dossier","type":"task"}],"unblocks":["claude-tools-dep"],"labels":[],"status_changes":[]}'
SRC='{ "tldr":"Pick the auth boundary for the coordinator.",
  "ask":"Which token model does v1 adopt?",
  "sections":[{"heading":"Context","prose":"The runner reached the §9.1 chokepoint and must not guess."},
              {"heading":"Trade-offs","prose":"Static bearer vs per-call mint — load-bearing for C7."}],
  "diagrams":[{"caption":"Auth flow","content":"flowchart LR\n  runner --> authenticate --> principal"}],
  "full_detail":"Standalone: v1 uses a constant principal; the pick fixes the C7 seam so later is one if at the chokepoint, no migration.",
  "structural":true }'
item_ar() { jq -cn --arg id "$1" --argjson cb "$CB" '
  { id:$id, kind:"approve-reject",
    framing:{ ask:"Approve the static-bearer boundary?", why:"Unblocks T3." },
    context_anchor:{ where:"design stage — the §9.1 coordinator boundary",
                     expansion:"v1 is a constant principal; this fixes the C7 seam shape." },
    reversible:"Reversible — a config seam in v1.",
    consequence_block:$cb }'; }
item_fyi() { jq -cn --arg id "$1" --argjson cb "$CB" '
  { id:$id, kind:"fyi-objectable",
    framing:{ ask:"Proceeding to ramp unless you object.", why:"Flow F overview." },
    context_anchor:{ where:"proactive checkpoint — the spare-cycles ramp",
                     expansion:"Auto-proceeds on the timer; object to halt." },
    reversible:"Reversible within the window — object to halt.",
    consequence_block:$cb }'; }
item_rec() { jq -cn --arg id "$1" --argjson cb "$CB" '
  { id:$id, kind:"approve-recommendation",
    framing:{ ask:"Adopt the recommended retry posture?", why:"Closes the gap." },
    context_anchor:{ where:"impl stage — classify_failure precedence",
                     expansion:"A >30s outage must not burn the retry budget." },
    reversible:"Reversible — a config constant.",
    recommendation:{ value:"backoff+reclassify", why:"Outage is not a content failure." },
    consequence_block:$cb }'; }
gi() {  # gi <id> <trigger> <tier> <items-json-array>
  jq -cn --arg id "$1" --arg tr "$2" --arg ti "$3" --argjson s "$SRC" --argjson it "$4" '
    { id:$id, kind:"decide", trigger:$tr, bead_ref:"claude-tools-glk",
      tier:$ti, timer_fire_at:null, source:$s, items:$it }'; }

echo "── EXIT-1: pure-checkbox ROUND-TRIP — notify→open→approve→applied→ack, no Dolt-lag lie ──"
DID="$(dg_generate "$GOOD" "$(gi dRT worker_stuck blocking "[$(item_ar a1)]")")"
ck "T5 dg_generate produced the §5 Dossier"                  eq "$DID" "dRT"
SNAP="$(SNAPSHOT)"
L="$(iv deriveInboxList "$SNAP")"
ck "Inbox renders the §4.5 projection (ok)"                  eq "$(jqr "$L" .ok)" "true"
ck "WAITING-ON-YOU lane surfaces the open Dossier"           eq "$(jqr "$L" '.items|length')" "1"
ck "lane row is a deep-link POINTER (no body — principle 2)" has "#/d/dRT" "$(jqr "$L" '.items[0].dossier_href')"
ck "lane row carries NO dossier body/items"                  eq "$(jqr "$L" '.items[0]|(has("body") or has("items"))')" "false"
REC="$(GET dRT)"
D="$(iv deriveDossierView "$REC")"
ck "dossier renders (ok) — binds §5"                         eq "$(jqr "$D" .ok)" "true"
ck "§5.1 body — ALL FOUR tiers present (AD7)"                eq "$(jqr "$D" '[(.body.tldr|length>0),(.body.sections|length>0),(.body.diagrams|length>0),(.body.full_detail|length>0)]|all')" "true"
ck "§5.2 item affordance derived from kind (approve/reject)" has "approve" "$(jqr "$D" '.items[0].affordances|join(",")')"
ck "§5.2 affordance includes reject (first-class, principle 3)" has "reject" "$(jqr "$D" '.items[0].affordances|join(",")')"
ck "§5.2 MANDATORY context_anchor rendered inline (AD7)"     nz "$(jqr "$D" '.items[0].context_anchor.where')"
ITEM="$(jq -c '.items[0]' <<<"$D")"
R="$(iv buildItemResponse "$ITEM" '{"action":"approve"}' 0)"
ck "buildItemResponse(approve) ⇒ ok"                         eq "$(jqr "$R" .ok)" "true"
ck "approve is DETERMINISTIC (§5.2.2 — instant, trustworthy)" eq "$(jqr "$R" .mode)" "deterministic"
RESP="$(jq -c .response <<<"$R")"
ckok "T5 do_item_apply(approve) succeeds"                    do_item_apply "$GOOD" dRT a1 "$RESP"
AREC="$(GET dRT)"
ck "Item state open→applied (T5 §4.1.1)"                      eq "$(jqr "$AREC" '.items[0].state')" "applied"
ck "§7.4 per-Item latch flipped false→true"                  eq "$(jqr "$AREC" '.items[0].consequence_applied')" "true"
ck "consequence APPLIED to the work plane (CB create ran)"   eq "$(BDN '^create ')" "1"
ck "consequence APPLIED — dep bead unblocked (control→work)" has "claude-tools-dep --status=open" "$(cat "$BD_LOG")"
C="$(iv deriveConfirm "$AREC")"
ck "ack renders (ok)"                                        eq "$(jqr "$C" .ok)" "true"
ck "ack: item in the deterministic-applied receipt"          eq "$(jqr "$C" '.receipt.deterministic_count')" "1"
ck "ack states control→work reconcile S-2 (no Dolt-lag lie)" has "Dolt-lag lie" "$(jqr "$C" '.honest_note')"
ck "ack honest: you don’t need to go check (S-2)"            has "go check" "$(jqr "$C" '.honest_note')"
# S-2 STRUCTURAL: the ack is a PURE function of the §4 record's §7.4 latch —
# inbox-view.js has no network/exec at all, so it CANNOT read (lagging) Dolt.
ck "inbox-view.js is pure: no network call"                  hasnt "fetch(" "$(cat "$VIEW")"
ck "inbox-view.js is pure: no child_process/exec"            hasnt "child_process" "$(cat "$VIEW")"
ck "app ack path re-fetches the §4 record, not a beads read" has "/api/inbox/dossier?id=" "$(cat "$APP")"
# The lane is HONEST: once every item resolves the projection drops it (the
# control-plane item-state drives §4.5 — no Dolt lag in the latency path).
ck "resolved Dossier leaves the lane (honest, S-2)"          eq "$(jqr "$(iv deriveInboxList "$(SNAPSHOT)")" '.items|length')" "0"
ckok "double-tap apply ⇒ idempotent success"                 do_item_apply "$GOOD" dRT a1 "$RESP"
ck "CB create STILL ran exactly once (§7.4 exactly-once)"     eq "$(BDN '^create ')" "1"

echo "── EXIT-2: reject / edit is ONE tap — symmetric with approve, not a penalty path ──"
DID2="$(dg_generate "$GOOD" "$(gi dRJ human_flag blocking "[$(item_ar r1),$(item_rec e1)]")")"
D2="$(iv deriveDossierView "$(GET dRJ)")"
AR_ITEM="$(jq -c '.items[]|select(.id=="r1")' <<<"$D2")"
REC_ITEM="$(jq -c '.items[]|select(.id=="e1")' <<<"$D2")"
ck "approve-reject offers reject as a FIRST-CLASS affordance"   has "reject" "$(jqr "$AR_ITEM" '.affordances|join(",")')"
RJ="$(iv buildItemResponse "$AR_ITEM" '{"action":"reject"}' 0)"
ck "buildItemResponse(reject) ⇒ ok in ONE call"                 eq "$(jqr "$RJ" .ok)" "true"
ck "reject is DETERMINISTIC too (its block applies — not slow)" eq "$(jqr "$RJ" .mode)" "deterministic"
ck "reject payload has NO extra field beyond approve (no penalty)" eq "$(jqr "$RJ" '.response|keys|sort|join(",")')" "decision,responded_at"
ckok "T5 do_item_apply(reject) applies just like approve"       do_item_apply "$GOOD" dRJ r1 "$(jq -c .response <<<"$RJ")"
ck "rejected item reached applied (same weight as approve)"      eq "$(jqr "$(GET dRJ)" '.items[]|select(.id=="r1").state')" "applied"
ED="$(iv buildItemResponse "$REC_ITEM" '{"action":"edit","edited_value":"backoff but cap at 3"}' 0)"
ck "buildItemResponse(edit) ⇒ ok in ONE call"                   eq "$(jqr "$ED" .ok)" "true"
ck "edit routes to the RECONCILER (§5.2.2 — honest, not false-instant)" eq "$(jqr "$ED" .mode)" "reconciler"
ckok "T5 do_item_apply(edit) ⇒ reconciler path succeeds"        do_item_apply "$GOOD" dRJ e1 "$(jq -c .response <<<"$ED")"
ck "edited item resolved; sibling r1 UNTOUCHED (partial, AD7)"   eq "$(jqr "$(GET dRJ)" '.items[]|select(.id=="r1").state')" "applied"
DID3="$(dg_generate "$GOOD" "$(gi dPA stage_gate blocking "[$(item_ar p1),$(item_ar p2)]")")"
do_item_apply "$GOOD" dPA p1 '{"decision":"approve","responded_at":"x"}' >/dev/null 2>&1
CPA="$(iv deriveConfirm "$(GET dPA)")"
ck "partial ack: 1 still open — NOT a failure (AD7)"            eq "$(jqr "$CPA" '.receipt.still_open')" "1"
ck "partial ack frames the open item as first-class, not penalty" has "first-class" "$(jqr "$CPA" '.honest_note')"
ck "the still-open Dossier REMAINS in the lane (honest partial)" eq "$(jqr "$(iv deriveInboxList "$(SNAPSHOT)")" '[.items[]|select(.dossier_ref=="dPA")]|length')" "1"

echo "── REVIEW-FIX: object ⇒ RECONCILER (exact mirror of do__is_deterministic) ──"
# An explicit objection is NOT in {approve,reject,pick} (consequence.sh:287) ⇒
# the RECONCILER path. The preview must never falsely promise "instant".
DIDO="$(dg_generate "$GOOD" "$(gi dOB proactive_checkpoint timed-fyi "[$(item_fyi o1)]")")"
DO="$(iv deriveDossierView "$(GET dOB)")"
FYI_ITEM="$(jq -c '.items[]|select(.id=="o1")' <<<"$DO")"
ck "fyi-objectable affordance is 'object' (§5.2)"             has "object" "$(jqr "$FYI_ITEM" '.affordances|join(",")')"
OB="$(iv buildItemResponse "$FYI_ITEM" '{"action":"object","text":"halt: ramps too fast"}' 0)"
ck "buildItemResponse(object) ⇒ ok"                           eq "$(jqr "$OB" .ok)" "true"
ck "object is RECONCILER, NOT a false-instant promise"        eq "$(jqr "$OB" .mode)" "reconciler"
ck "object preview does NOT claim 'instantly trustworthy'"    hasnt "instantly trustworthy" "$(jqr "$OB" .preview)"
ckok "T5 do_item_apply(object) ⇒ reconciler path succeeds"    do_item_apply "$GOOD" dOB o1 "$(jq -c .response <<<"$OB")"
OREC="$(GET dOB)"
ck "objected item resolved (latch flipped, applied)"          eq "$(jqr "$OREC" '.items[0].consequence_applied')" "true"
COB="$(iv deriveConfirm "$OREC")"
ck "ack classifies the object as RECONCILER (not deterministic)" eq "$(jqr "$COB" '.receipt.reconciler_count')" "1"
ck "ack deterministic_count is 0 for an objection (no lie)"    eq "$(jqr "$COB" '.receipt.deterministic_count')" "0"
# An un-edited approve-recommendation is still deterministic (regression guard
# on the shared predicate — the fix must not over-correct).
RG="$(iv buildItemResponse "$(jq -c '.items[]|select(.id=="e1")' <<<"$D2")" '{"action":"approve"}' 0)"
ck "un-edited approve-recommendation STILL deterministic"     eq "$(jqr "$RG" .mode)" "deterministic"

echo "── claude-tools-4xe: an ACCEPTED dossier ALWAYS renders (only §0.3-higher refuses) ──"
# A non-positive / odd envelope schema_version is NOT unknown-HIGHER (§0.3):
# the renderer no longer walls it — it renders best-effort (the gate is at
# WRITE now, never render-time). Only a STRICTLY-HIGHER version refuses.
Z="$(jq -c '.schema_version=0' <<<"$(GET dRT)")"
ck "dossier schema_version 0 ⇒ RENDERS (§0.3: 0 is not unknown-higher)" eq "$(jqr "$(iv deriveDossierView "$Z")" .ok)" "true"
ck "renders the body it accepted (no wall)"                   nz "$(jqr "$(iv deriveDossierView "$Z")" '.body.tldr')"
# Snapshot/Inbox-list (§4.5, a DIFFERENT record type) is unchanged: it still
# binds §0.3 strictly (the dossier-render tolerance is claude-tools-4xe-scoped).
ZS="$(jq -c '.schema_version=0' <<<"$SNAP")"
ck "snapshot schema_version 0 ⇒ Inbox list REFUSED (§4.5 unchanged)" eq "$(jqr "$(iv deriveInboxList "$ZS")" .ok)" "false"
ZB="$(jq -c '.body.dossier_schema_version=-1' <<<"$(GET dRT)")"
ck "negative body dossier_schema_version ⇒ RENDERS (not unknown-higher)" eq "$(jqr "$(iv deriveDossierView "$ZB")" .ok)" "true"

echo "── EXIT-3: reads only the projection + binds §5 · §0.3 reject · ONE write path ──"
ck "schema_version 2 dossier (bound; v2 §11 Mermaid amend) renders ok" eq "$(jqr "$(iv deriveDossierView "$(GET dRT)")" .ok)" "true"
HI="$(jq -c '.schema_version=3' <<<"$(GET dRT)")"
ck "envelope schema_version 3 REFUSED (unknown higher; bound=2 v2 §0.3)" eq "$(jqr "$(iv deriveDossierView "$HI")" .ok)" "false"
ck "the ONE refusal is flagged too_new (claude-tools-4xe)"    eq "$(jqr "$(iv deriveDossierView "$HI")" .too_new)" "true"
# criterion 3: human-meaningful on the phone — NO §/§11/contract/65z jargon.
ck "unknown-higher message is human (says 'newer version')"   has "newer version" "$(jqr "$(iv deriveDossierView "$HI")" .error)"
ck "unknown-higher message carries NO § jargon"               hasnt "§" "$(jqr "$(iv deriveDossierView "$HI")" .error)"
ck "unknown-higher message carries NO §11/65z jargon"         hasnt "65z" "$(jqr "$(iv deriveDossierView "$HI")" .error)"
HIB="$(jq -c '.body.dossier_schema_version=3' <<<"$(GET dRT)")"
ck "BODY dossier_schema_version 3 REFUSED (unknown higher; bound=2 v2 §5.1/§0.3)" eq "$(jqr "$(iv deriveDossierView "$HIB")" .ok)" "false"
ck "BODY unknown-higher also flagged too_new"                 eq "$(jqr "$(iv deriveDossierView "$HIB")" .too_new)" "true"
ck "snapshot schema_version 2 ⇒ Inbox list REFUSED (§4.5/§0.3)" eq "$(jqr "$(iv deriveInboxList "$(jq -c '.schema_version=2' <<<"$SNAP")")" .ok)" "false"
ck "inbox-view.js makes NO network call (pure core)"          hasnt "fetch(" "$(cat "$VIEW")"
ck "inbox-view.js has no POST verb"                           hasnt "POST" "$(cat "$VIEW")"
ck "app.js issues NO direct beads/bd write"                   hasnt "bd update" "$(cat "$APP")"
ck "app.js POSTs only to /api/inbox/{respond,forensic,expire,snooze} (no Dolt; defer/escalate use a variable path)" eq "$(grep -oE "postJSON\('/api/inbox/[a-z]+'" "$APP" | sort -u | paste -sd, -)" "postJSON('/api/inbox/expire',postJSON('/api/inbox/forensic',postJSON('/api/inbox/respond',postJSON('/api/inbox/snooze'"
ck "inbox proxy exports ONLY onRequestGet"                    has "export async function onRequestGet" "$(cat "$P_INBOX")"
ck "inbox proxy exports NO onRequestPost"                     hasnt "onRequestPost" "$(cat "$P_INBOX")"
ck "inbox proxy hard-codes the §4.5 read op"                  has "COORDINATOR_OP = 'work-snapshot'" "$(cat "$P_INBOX")"
ck "inbox proxy: exactly ONE op literal on the wire"          eq "$(opn "$P_INBOX")" "1"
ck "dossier proxy exports ONLY onRequestGet"                  has "export async function onRequestGet" "$(cat "$P_DOSS")"
ck "dossier proxy exports NO onRequestPost"                   hasnt "onRequestPost" "$(cat "$P_DOSS")"
ck "dossier proxy hard-codes op 'get' + type 'dossier'"       has "COORDINATOR_OP = 'get'" "$(cat "$P_DOSS")"
ck "respond proxy exports ONLY onRequestPost"                 has "export async function onRequestPost" "$(cat "$P_RESP")"
ck "respond proxy exports NO onRequestGet (no read/mutate mix)" hasnt "onRequestGet" "$(cat "$P_RESP")"
ck "respond proxy pins the ONE write op 'item-apply'"         has "COORDINATOR_OP = 'item-apply'" "$(cat "$P_RESP")"
ck "respond proxy: exactly ONE op literal on the wire"        eq "$(opn "$P_RESP")" "1"
ck "respond proxy strips any client-sent principal (§9.1)"    has "delete response.principal" "$(cat "$P_RESP")"
ck "respond proxy HARD-REJECTS a decisionless payload (claude-tools-uxvl1 §5.6)" \
                                                              has "typeof response.decision !== 'string'" "$(cat "$P_RESP")"
ck "bearer is a server-side env binding in ALL 5 proxies"     eq "$(grep -l 'env.COORDINATOR_TOKEN' "$P_INBOX" "$P_DOSS" "$P_RESP" "$P_FOR" "$P_EXP" | wc -l | tr -d ' ')" "5"
ck "no token literal in the client app"                       hasnt "COORDINATOR_TOKEN" "$(cat "$APP")"
ck "no token literal in the shipped shell HTML"               hasnt "COORDINATOR_TOKEN" "$(cat "$SHELL_HTML")"
ck "client never selects an op (no searchParams op in app.js)" hasnt "set('op'" "$(cat "$APP")"

echo "── claude-tools-4xe: an accepted dossier with a gap RENDERS best-effort, LABELED ──"
# THE BUG this kills: pre-4xe the renderer WALLED a dossier the engine had
# already accepted (false-success put + a wall on the phone). Now the gate is
# at WRITE; an accepted-but-imperfect dossier is ALWAYS readable AND answerable,
# every substitution clearly LABELED in .degraded[] (never silently fabricated).
NO_FULL="$(jq -c 'del(.body.full_detail)' <<<"$(GET dRT)")"
EF="$(iv deriveDossierView "$NO_FULL")"
ck "missing §5.1 full_detail ⇒ RENDERS (ok:true, no wall)"   eq "$(jqr "$EF" .ok)" "true"
ck "it still produces a readable body"                       nz "$(jqr "$EF" '.body.full_detail')"
ck "the substitution is LABELED, not silently fabricated"    nz "$(jqr "$EF" '.degraded[0]')"
ck "tldr/sections still render (skim path intact)"           eq "$(jqr "$EF" '[(.body.tldr|length>0),(.body.sections|length>0)]|all')" "true"
NO_CA="$(jq -c '.items[0]|=del(.context_anchor)' <<<"$(GET dRT)")"
EC="$(iv deriveDossierView "$NO_CA")"
ck "missing MANDATORY context_anchor ⇒ RENDERS (item answerable)" eq "$(jqr "$EC" .ok)" "true"
ck "the item keeps its response affordances (answerable)"    nz "$(jqr "$EC" '.items[0].affordances[0]')"
ck "the missing context is LABELED on the item"              nz "$(jqr "$EC" '.items[0].degraded[0]')"
ck "context_anchor shows a clear placeholder (not blank)"    nz "$(jqr "$EC" '.items[0].context_anchor.where')"
# criterion 2: a non-Mermaid diagram on an accepted dossier degrades to a
# LABELED block (note present) — never dropped, never a silent <pre>.
NO_MM="$(jq -c '.body.diagrams=[{"caption":"ascii","content":"+--+\n|box|\n+--+"}]' <<<"$(GET dRT)")"
EM="$(iv deriveDossierView "$NO_MM")"
ck "non-Mermaid diagram ⇒ RENDERS (ok:true, not walled)"     eq "$(jqr "$EM" .ok)" "true"
ck "the diagram is kept, flagged degraded (criterion 2)"     eq "$(jqr "$EM" '.body.diagrams[0].degraded')" "true"
ck "the degraded diagram carries a human note"               nz "$(jqr "$EM" '.body.diagrams[0].note')"
ck "its raw text is preserved (labeled, not dropped)"        nz "$(jqr "$EM" '.body.diagrams[0].content')"
# the §5.2.2 opaque reconcile-pointer renders a best-effort summary, answerable.
RP="$(jq -c '.body={"reconcile_of":"d-orig","reconcile_item":"d-orig-d1","reason":"freeform answer needs interpretation"}' <<<"$(GET dRT)")"
ER="$(iv deriveDossierView "$RP")"
ck "reconcile-pointer body ⇒ RENDERS best-effort (ok:true)"  eq "$(jqr "$ER" .ok)" "true"
ck "reconcile-pointer flagged + summarized (not a wall)"     eq "$(jqr "$ER" .reconcile_pointer)" "true"
ck "reconcile-pointer keeps its carried item answerable"     nz "$(jqr "$ER" '.items[0].affordances[0]')"
# Flow-G STRUCTURAL leak guard (mirrors the T6a forensic-drop test): a §10
# forensic blob injected into a failure card is DROPPED — the Inbox surfaces
# only §4.5 tiers 1–2 (class/retry/notes); the tier-3 STREAM is never here.
FOR_CANARY="FORENSIC-LEAK-CANARY-7c3"
BEADS="[{\"bead_ref\":\"claude-tools-91\",\"title\":\"reconciler\",\"stage\":\"impl\",\"priority\":2,\"age\":\"1h\",\"failure\":{\"class\":\"WATCHDOG_KILL\",\"retry_state\":\"2/3\",\"runner_notes\":[\"watchdog kill @attempt2\"],\"forensic_blob\":\"$FOR_CANARY\",\"stream_json\":\"$FOR_CANARY\"}}]"
SNAPF="$(co_request "$GOOD" work-snapshot "" "$BEADS" 2>/dev/null)"
LF="$(iv deriveInboxList "$SNAPF")"
ck "Flow-G tier-1/2 metadata IS surfaced (class in §4.5)"    has "WATCHDOG_KILL" "$(jqr "$LF" '.failures[0].badge')"
ck "Flow-G tier-2 Runner: note timeline surfaced (§4.5)"     has "watchdog kill" "$(jqr "$LF" '.failures[0].runner_notes|join(" ")')"
ck "the §10 forensic STREAM is DROPPED by the renderer"      hasnt "$FOR_CANARY" "$LF"
FV="$(iv deriveFailureView "$SNAPF" '"claude-tools-91"')"
ck "tier-3 forensic is an ON-DEMAND affordance only (§10.3)" eq "$(jqr "$FV" '.forensic.available and (.forensic.fetched|not)')" "true"
ck "failure view carries NO forensic stream inline"          hasnt "$FOR_CANARY" "$FV"

echo "── claude-tools-23r: at-the-shell DISMISS-AS-STALE affordance ──"
# A stale Dossier was wedging itself in the user's face forever (claude-tools-vxs
# saw 9 i1-live-* on claude-tools-txj). Dismiss flips every still-open item to
# state=expired (a §4.1 terminal sink, already legal for the lane projection
# from T5.4's timed-fyi auto-proceed) — gated behind a confirm in the UI, no
# §5.2 contract change. The engine's stateCheck (open→expired only) is the
# floor: an answered item is mid-reconcile and is NOT this affordance's target.
DID_DM="$(dg_generate "$GOOD" "$(gi dDM human_flag blocking "[$(item_ar s1),$(item_ar s2)]")")"
ck "T5 dg_generate produced the stale-fixture Dossier"        eq "$DID_DM" "dDM"
ck "stale Dossier surfaces in the lane (before dismiss)"      eq "$(jqr "$(iv deriveInboxList "$(SNAPSHOT)")" '[.items[]|select(.dossier_ref=="dDM")]|length')" "1"
do_item_set_state "$GOOD" dDM s1 expired >/dev/null 2>&1
do_item_set_state "$GOOD" dDM s2 expired >/dev/null 2>&1
DM_REC="$(GET dDM)"
ck "open item s1 → expired (§4.1 terminal)"                    eq "$(jqr "$DM_REC" '.items[]|select(.id=="s1").state')" "expired"
ck "open item s2 → expired (§4.1 terminal)"                    eq "$(jqr "$DM_REC" '.items[]|select(.id=="s2").state')" "expired"
ck "dismissed Dossier LEAVES the lane (honest, S-2)"          eq "$(jqr "$(iv deriveInboxList "$(SNAPSHOT)")" '[.items[]|select(.dossier_ref=="dDM")]|length')" "0"
# Already-answered items are mid-reconcile: stateCheck refuses answered→expired,
# so the dismiss honestly skips them. The lane MUST stay honest (still surfaces
# the dossier while ≥1 item is non-terminal — open OR answered).
DID_DM2="$(dg_generate "$GOOD" "$(gi dDM2 human_flag blocking "[$(item_ar t1)]")")"
do_item_set_state "$GOOD" dDM2 t1 answered >/dev/null 2>&1
EXP_REJ="$(do_item_set_state "$GOOD" dDM2 t1 expired 2>&1)"
ck "answered→expired REJECTED by stateCheck (honest gate)"     has "illegal transition" "$EXP_REJ"
ck "dossier with only-answered items STAYS in the lane (honest)" eq "$(jqr "$(iv deriveInboxList "$(SNAPSHOT)")" '[.items[]|select(.dossier_ref=="dDM2")]|length')" "1"
# §9.1 chokepoint discipline (the expire proxy must match respond.js' shape).
ck "expire proxy exports ONLY onRequestPost"                  has "export async function onRequestPost" "$(cat "$P_EXP")"
ck "expire proxy exports NO onRequestGet (no read/mutate mix)" hasnt "onRequestGet" "$(cat "$P_EXP")"
ck "expire proxy pins op 'item-set-state'"                    has "COORDINATOR_OP = 'item-set-state'" "$(cat "$P_EXP")"
ck "expire proxy hard-codes target state 'expired'"           has "TARGET_STATE = 'expired'" "$(cat "$P_EXP")"
ck "expire proxy: exactly ONE op literal on the wire"         eq "$(opn "$P_EXP")" "1"
ck "expire proxy bearer is a server-side env binding"         has "env.COORDINATOR_TOKEN" "$(cat "$P_EXP")"
ck "expire proxy carries NO client-supplied state (foot-gun)"  hasnt "payload.state" "$(cat "$P_EXP")"
ck "app.js dismiss flow gates behind window.confirm (foot-gun)" has "window.confirm" "$(cat "$APP")"
ck "app.js dismiss never targets non-open items (stateCheck floor)" has "state === 'open'" "$(cat "$APP")"

echo "── §10.3 forensic round-trip (the binding the forensic proxy depends on) ──"
RED='{"redacted":true,"tool_use":["Read(x.ts)"],"errors":["WATCHDOG"],"last_turn":"…"}'
co_request "$GOOD" forensic-put fb-1 dRT "$RED" >/dev/null 2>&1
ck "§10.3 forensic-fetch returns the redacted blob"          has "redacted" "$(co_request "$GOOD" forensic-fetch fb-1 2>/dev/null)"
co_request "$GOOD" forensic-dismiss fb-1 >/dev/null 2>&1
ckno "§10.3 dismiss ⇒ blob GONE (irrecoverable, no tombstone)" co_request "$GOOD" forensic-fetch fb-1
ck "forensic proxy pins forensic-fetch + forensic-dismiss"   eq "$(grep -c "= 'forensic-" "$P_FOR")" "2"
ck "forensic proxy exports BOTH GET+POST (no put/sweep)"      eq "$(grep -c 'export async function onRequest' "$P_FOR")" "2"
ck "forensic proxy has NO forensic-put as a client op"        hasnt "'forensic-put'" "$(cat "$P_FOR")"

echo ""
echo "── N3 (claude-tools-uxg6) ready-to-pair: the Inbox THIRD mode (upcoming→ready) ──"
# DESIGN N §4.4 — a `kind:"pair"` SESSION CARD (0 items, surfaced via the §4.5
# lane's kind-visibility) renders as "ready to pair on X", NOT "decide X". Two
# sub-states off scheduled_at, derived PURELY from the injected clock: before
# the appointment ⇒ 'upcoming' (deferred); at/after ⇒ 'ready' (foreground).
PSCHED="2099-05-16T15:00:00Z"
co_request "$GOOD" put dossier dPair \
  "{\"schema_version\":2,\"id\":\"dPair\",\"kind\":\"pair\",\"bead_ref\":\"claude-tools-uxg6\",\"tier\":\"blocking\",\"scheduled_at\":\"$PSCHED\",\"body\":{\"dossier_schema_version\":2,\"tldr\":\"pair on the activity blueprint\",\"diagrams\":[]},\"items\":[]}" >/dev/null 2>&1
PSNAP="$(SNAPSHOT)"
NOW_BEFORE="$(node -e 'console.log(Date.parse("2099-05-16T12:00:00Z"))')"
NOW_AFTER="$(node -e 'console.log(Date.parse("2099-05-17T00:00:00Z"))')"
LB="$(iv deriveInboxList "$PSNAP" "$NOW_BEFORE")"
LA="$(iv deriveInboxList "$PSNAP" "$NOW_AFTER")"
ck "a 0-item kind:'pair' card surfaces in the Inbox lane (visibility by kind)" \
   eq "$(jqr "$LB" '[.items[]|select(.dossier_id=="dPair")]|length')" "1"
ck "the pair row is flagged pair:true (the Inbox third mode)" \
   eq "$(jqr "$LB" '.items[]|select(.dossier_id=="dPair").pair')" "true"
ck "BEFORE scheduled_at ⇒ pair_mode 'upcoming' (deferred, not waiting-right-now)" \
   eq "$(jqr "$LB" '.items[]|select(.dossier_id=="dPair").pair_mode')" "upcoming"
ck "AT/AFTER scheduled_at ⇒ pair_mode 'ready' (promoted to foreground)" \
   eq "$(jqr "$LA" '.items[]|select(.dossier_id=="dPair").pair_mode')" "ready"
ck "the pair row carries scheduled_at (the appointment time)" \
   eq "$(jqr "$LB" '.items[]|select(.dossier_id=="dPair").scheduled_at')" "$PSCHED"
ck "a pair row never auto_proceeds (blocking-ish session, not timed-fyi)" \
   eq "$(jqr "$LB" '.items[]|select(.dossier_id=="dPair").auto_proceeds')" "false"
ck "the pair row title is the session tldr ('pair on …'), not a 'decide' phrase" \
   has "pair on" "$(jqr "$LB" '.items[]|select(.dossier_id=="dPair").tldr')"
ck "a non-pair lane row is pair:false / pair_mode:null (the mode is pair-only)" \
   eq "$(jqr "$LB" '[.items[]|select(.kind!="pair" and ((.pair!=false) or (.pair_mode!=null)))]|length')" "0"

echo ""
echo "── claude-tools-uxg3: the dossier↔Blueprint bridge — context_anchor.link ?focus=<id> (§6.4) ──"
# UX-DESIGN-V2 §6.4: a Flow B decision dossier SITUATES its decision on the map
# by carrying the Blueprint facet's ?focus=<id> deep-link in context_anchor.link.
# H3 (claude-tools-uxvh3) owns the ROUTE that resolves /ws/<ref>/blueprint?focus=<id>;
# this bead is the dossier (consumer) side — classify + surface + paint the link.
BPL="$(iv blueprintFocusLink '"/ws/projA/blueprint?focus=domain:auth"')"
ck "a /ws/<ref>/blueprint?focus=<id> link classifies as a focus slice" eq "$(jqr "$BPL" '.node_id')" "domain:auth"
ck "the workspace ref is parsed from the path"                eq "$(jqr "$BPL" '.ref')" "projA"
ck "href is preserved verbatim (the producer's link, used as-is)" eq "$(jqr "$BPL" '.href')" "/ws/projA/blueprint?focus=domain:auth"
# a full URL works too (scheme+host stripped); a url-encoded focus id is decoded.
BPL2="$(iv blueprintFocusLink '"https://claude-wrangler.pages.dev/ws/projA/blueprint?focus=domain%3Aauth"')"
ck "a full-URL blueprint deep-link also classifies"           eq "$(jqr "$BPL2" '.ref')" "projA"
ck "a url-encoded focus id is decoded"                        eq "$(jqr "$BPL2" '.node_id')" "domain:auth"
# NON-blueprint / bare-blueprint / empty links are NOT a focus slice (null) — TOLERANT.
ck "a bare /ws/<ref>/blueprint (no ?focus) is NOT a slice"    eq "$(iv blueprintFocusLink '"/ws/projA/blueprint"')" "null"
ck "a non-blueprint link is NOT a slice"                      eq "$(iv blueprintFocusLink '"https://example.com/docs"')" "null"
ck "an empty focus value is NOT a slice"                      eq "$(iv blueprintFocusLink '"/ws/projA/blueprint?focus="')" "null"
ck "an empty/absent link is NOT a slice (never throws)"       eq "$(iv blueprintFocusLink '""')" "null"
# foot-gun guard: a non-http(s) scheme NEVER classifies (no clickable js: href).
ck "a javascript: scheme over a /blueprint path is NOT a bridge" eq "$(iv blueprintFocusLink '"javascript://x/ws/projA/blueprint?focus=y"')" "null"
# end-to-end: a dossier item carrying the link surfaces blueprint_focus on its
# rendered context_anchor (the bridge the app paints) — render stays answerable.
BP_REC="$(jq -c '.items[0].context_anchor.link="/ws/claude-tools/blueprint?focus=domain:runner"' <<<"$(GET dRT)")"
BPV="$(iv deriveDossierView "$BP_REC")"
ck "a dossier item's blueprint ?focus link surfaces blueprint_focus" eq "$(jqr "$BPV" '.items[0].context_anchor.blueprint_focus.node_id')" "domain:runner"
ck "the bridge carries the workspace ref for the deep-link"   eq "$(jqr "$BPV" '.items[0].context_anchor.blueprint_focus.ref')" "claude-tools"
ck "the item stays answerable (the bridge is additive, not a gate)" nz "$(jqr "$BPV" '.items[0].affordances[0]')"
# a NON-blueprint link leaves blueprint_focus null; the raw link is still passed
# through on the item (the view model preserves it — the app just doesn't paint a
# bridge for it; the bridge affordance is Blueprint-?focus only).
PLAIN_REC="$(jq -c '.items[0].context_anchor.link="https://example.com/spec"' <<<"$(GET dRT)")"
PLV="$(iv deriveDossierView "$PLAIN_REC")"
ck "a non-blueprint link ⇒ blueprint_focus null (no bridge minted)" eq "$(jqr "$PLV" '.items[0].context_anchor.blueprint_focus')" "null"
ck "the raw link is still preserved on the item (view model)"  eq "$(jqr "$PLV" '.items[0].context_anchor.link')" "https://example.com/spec"
# the app PAINTS the bridge (producer ⇆ consumer seam, like the #/d/ route pin).
ck "app.js renders the blueprint_focus bridge affordance"     has "blueprint_focus" "$(cat "$APP")"
ck "app.js opens the bridge via its href (the deep-link target)" has "bp.href" "$(cat "$APP")"

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " test-inbox (T6b, claude-tools-xre):  PASS=$PASS  FAIL=$FAIL"
echo "══════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
