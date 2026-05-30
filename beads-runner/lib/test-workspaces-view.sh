#!/bin/bash
# beads-runner/lib/test-workspaces-view.sh — focused unit test for the
# Workspaces Hub view-model (label: workspaces-hub; Brian ask B6;
# UX-DESIGN-V2 §2.1/§2.2): the §4.5 projection → per-workspace cards + the
# global decision total, with honest S-1 liveness and a DERIVED-from-board
# lifecycle tally.
#
# Mirrors lib/test-board.sh's node-require technique: it does a node `require`
# of the pure view-model (web/workspaces/workspaces-view.js), feeds a
# hand-crafted fixture snapshot JSON (the §4.5 shape in .cshell-brief), and
# asserts the derived model. The bash coordinator is NOT driven here — the hub
# reads the SAME /api/board projection the Board does; the producer↔Board seam
# is already covered by test-board.sh, so this test fixes the hub's OWN
# rendering contract against a frozen shape.
#
# Asserts:
#   1. ok:true on a good (schema_version:1) snapshot; ok:false on schema_version:99
#      (§0.3 — an unknown HIGHER version is REFUSED, never best-effort-rendered),
#      and ok:false on a missing/non-integer schema_version.
#   2. cards length == projects length (one card per project).
#   3. a STALE project's current_task is null (S-1: a stale runner is honestly
#      "we don't know what it's doing now").
#   4. decisions counted by bead_ref prefix (the per-workspace slice of the
#      global Inbox) + decisions_total across the whole queue.
#
# Self-contained: needs only node + jq. Keeps the test FILE out of the deployed
# web/ dir (it lives in beads-runner/lib/). Run from the repo root.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIEW="$HERE/../web/workspaces/workspaces-view.js"
APP="$HERE/../web/workspaces/app.js"
HTML="$HERE/../web/workspaces/index.html"
CSS="$HERE/../web/workspaces/workspaces.css"
[[ -f "$VIEW" ]] || { echo "FATAL: workspaces-view.js not found at $VIEW"; exit 2; }
command -v node >/dev/null 2>&1 || { echo "FATAL: node required for the Workspaces view test"; exit 2; }
command -v jq   >/dev/null 2>&1 || { echo "FATAL: jq required for the Workspaces view test"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \xe2\x9c\x93 %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \xe2\x9c\x97 %s\n' "$1"; FAIL=$((FAIL+1)); }
ck()  { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
has()   { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }
hasnt() { case "$2" in *"$1"*) return 1;; *) return 0;; esac; }
eq()    { [[ "$1" == "$2" ]]; }
nz()    { [[ -n "$1" ]]; }

# Pipe a §4.5 projection JSON through the PURE view-model at a FIXED now-ms so
# the formatAgo bucketing is deterministic. nowMs = 2026-05-29T00:00:00Z epoch*1000.
NOW_MS=1779148800000
render() { printf '%s' "$1" | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    const WV=require(process.argv[1]);
    let snap; try{snap=JSON.parse(s);}catch(e){snap=s;}
    process.stdout.write(JSON.stringify(WV.deriveWorkspacesView(snap, Number(process.argv[2]))));
  });' "$VIEW" "$NOW_MS"; }

# ── The fixture: a hand-crafted §4.5 work-snapshot ─────────────────────────────
# Two projects:
#   • alpha  — LIVE, running, current_task_ref=alpha-12 (no mismatch) ⇒ health ok
#   • bravo  — STALE (heartbeat far in the past), last actual=running,
#              current_task_ref=bravo-7 ⇒ S-1 must DROP the current_task.
# A third project (charlie) — LIVE but desired≠actual (mismatch) ⇒ attention.
# waiting_on_you: two entries on alpha (3 + 1 open) and one on bravo (2 open) ⇒
# alpha decisions=4, bravo decisions=2, decisions_total=6.
# lifecycle_columns: impl carries alpha-12 + bravo-7; idea carries charlie-3.
STALE_HB="2026-01-01T00:00:00Z"   # ~5 months before NOW_MS ⇒ Coordinator-stale here we set liveness explicitly
FIX="$(jq -cn --arg shb "$STALE_HB" '{
  schema_version: 1,
  read_only: true,
  principal: "PRINCIPAL_V1",
  projects: [
    { project_ref: "alpha",
      runner_state: { liveness:"live", actual:"running", desired:"running",
        desired_actual_mismatch:false, last_heartbeat_at:"2026-05-29T00:00:00Z",
        current_task_ref:"alpha-12", current_task_title:"Wire the thing" } },
    { project_ref: "bravo",
      runner_state: { liveness:"stale", actual:"running", desired:"running",
        desired_actual_mismatch:false, last_heartbeat_at:$shb,
        current_task_ref:"bravo-7", current_task_title:"Should not show" } },
    { project_ref: "charlie",
      runner_state: { liveness:"live", actual:"running", desired:"stopped",
        desired_actual_mismatch:true, last_heartbeat_at:"2026-05-29T00:00:00Z",
        current_task_ref:"charlie-3", current_task_title:"Stopping soon" } }
  ],
  waiting_on_you: [
    { dossier_ref:"dA1", bead_ref:"alpha-12", tier:"blocking", open_item_count:3 },
    { dossier_ref:"dA2", bead_ref:"alpha-44", tier:"decide",   open_item_count:1 },
    { dossier_ref:"dB1", bead_ref:"bravo-7",  tier:"decide",   open_item_count:2 }
  ],
  lifecycle_columns: {
    "idea":   [ { bead_ref:"charlie-3", title:"Idea", stage:"idea" } ],
    "ux":     [],
    "design": [],
    "impl":   [ { bead_ref:"alpha-12", title:"Impl A", stage:"impl" },
                { bead_ref:"bravo-7",  title:"Impl B", stage:"impl" } ],
    "docs":   [],
    "tests":  [],
    "done":   [ { bead_ref:"alpha-9", title:"Done A", stage:"done" } ],
    "":       []
  },
  machines: []
}')"

V="$(render "$FIX")"

echo "── A: a good (sv:1) snapshot renders ok:true with the expected shape ──"
ck "good snapshot ⇒ ok:true"                          eq "$(jq -r '.ok' <<<"$V")" "true"
ck "principal surfaced verbatim"                       eq "$(jq -r '.principal' <<<"$V")" "PRINCIPAL_V1"
ck "schema_version echoed (1)"                         eq "$(jq -r '.schema_version' <<<"$V")" "1"
ck "cards length matches projects length (3)"          eq "$(jq -r '.cards|length' <<<"$V")" "3"
ck "every card carries an href into /ws/<ref>/board"   eq "$(jq -r '[.cards[]|select(.href|startswith("/ws/") and endswith("/board"))]|length' <<<"$V")" "3"

echo "── B: §0.3 — an unknown HIGHER (or missing/non-integer) sv is REFUSED ──"
HI="$(jq -c '.schema_version=99' <<<"$FIX")"
VHI="$(render "$HI")"
ck "schema_version 99 ⇒ ok:false (refuse, no best-effort)" eq "$(jq -r '.ok' <<<"$VHI")" "false"
ck "refusal names the unsupported version"                 has "schema_version 99" "$(jq -r '.error' <<<"$VHI")"
ck "refusal cites §0.3"                                    has "§0.3" "$(jq -r '.error' <<<"$VHI")"
NOSV="$(jq -c 'del(.schema_version)' <<<"$FIX")"
ck "missing schema_version ⇒ also ok:false"                eq "$(jq -r '.ok' <<<"$(render "$NOSV")")" "false"
FLOATSV="$(jq -c '.schema_version=1.5' <<<"$FIX")"
ck "non-integer schema_version (1.5) ⇒ also ok:false"      eq "$(jq -r '.ok' <<<"$(render "$FLOATSV")")" "false"

echo "── C: S-1 — a STALE project's current_task is null, its own honest state ──"
CB="$(jq -c '.cards[]|select(.project_ref=="bravo")' <<<"$V")"
ck "bravo liveness is 'stale' (from §4.2, consumed verbatim)" eq "$(jq -r '.liveness' <<<"$CB")" "stale"
ck "bravo is_stale flag is true"                              eq "$(jq -r '.is_stale' <<<"$CB")" "true"
ck "bravo health is 'stale'"                                  eq "$(jq -r '.health' <<<"$CB")" "stale"
ck "bravo state_label is 'stale (last seen … ago)'"           has "stale (last seen" "$(jq -r '.state_label' <<<"$CB")"
# THE S-1 LIE THIS FORBIDS: a stale runner's last task is NOT "currently working".
ck "bravo current_task is NULL (S-1 drops the stale task)"    eq "$(jq -r '.current_task' <<<"$CB")" "null"
ck "bravo current_task_title is NULL (S-1)"                   eq "$(jq -r '.current_task_title' <<<"$CB")" "null"
ck "stale current_task_ref does NOT leak into the card"       hasnt "bravo-7" "$(jq -r '.current_task // ""' <<<"$CB")"

echo "── C2: a LIVE project keeps its current_task; mismatch is honest ──"
CA="$(jq -c '.cards[]|select(.project_ref=="alpha")' <<<"$V")"
ck "alpha liveness is 'live'"                                 eq "$(jq -r '.liveness' <<<"$CA")" "live"
ck "alpha health is 'ok' (live, no mismatch, no failure)"     eq "$(jq -r '.health' <<<"$CA")" "ok"
ck "alpha current_task is the live current_task_ref"          eq "$(jq -r '.current_task' <<<"$CA")" "alpha-12"
ck "alpha mode is the ACTUAL runner state (running)"          eq "$(jq -r '.mode' <<<"$CA")" "running"
CC="$(jq -c '.cards[]|select(.project_ref=="charlie")' <<<"$V")"
ck "charlie mismatch ⇒ health 'attention'"                    eq "$(jq -r '.health' <<<"$CC")" "attention"
ck "charlie state_label is honest 'actual (target: desired)'" has "running (target: stopped)" "$(jq -r '.state_label' <<<"$CC")"
ck "charlie label does NOT collapse actual onto desired"      hasnt "^stopped$" "$(jq -r '.state_label' <<<"$CC")"

echo "── D: decisions counted by bead_ref prefix + the global decisions_total ──"
ck "decisions_total = 6 (3+1+2 across the whole queue)"       eq "$(jq -r '.decisions_total' <<<"$V")" "6"
ck "alpha decisions = 4 (alpha-12:3 + alpha-44:1)"            eq "$(jq -r '.cards[]|select(.project_ref=="alpha").decisions' <<<"$V")" "4"
ck "bravo decisions = 2 (bravo-7:2)"                          eq "$(jq -r '.cards[]|select(.project_ref=="bravo").decisions' <<<"$V")" "2"
ck "charlie decisions = 0 (no queue entry prefixed charlie-)"  eq "$(jq -r '.cards[]|select(.project_ref=="charlie").decisions' <<<"$V")" "0"
# Prefix discipline: a sibling-prefixed ref must NOT bleed across workspaces.
BLEED="$(jq -c '.projects+=[{project_ref:"alph",runner_state:{liveness:"live",actual:"running",desired:"running",desired_actual_mismatch:false,last_heartbeat_at:"2026-05-29T00:00:00Z",current_task_ref:"",current_task_title:null}}]' <<<"$FIX")"
VB="$(render "$BLEED")"
ck "prefix 'alph' does NOT swallow 'alpha-*' decisions (0)"   eq "$(jq -r '.cards[]|select(.project_ref=="alph").decisions' <<<"$VB")" "0"

echo "── E: stage_counts is DERIVED (labeled) and tallied by prefix ──"
ck "alpha impl stage_count = 1 (alpha-12)"                    eq "$(jq -r '.cards[]|select(.project_ref=="alpha").stage_counts.impl' <<<"$V")" "1"
ck "alpha done stage_count = 1 (alpha-9)"                     eq "$(jq -r '.cards[]|select(.project_ref=="alpha").stage_counts.done' <<<"$V")" "1"
ck "bravo impl stage_count = 1 (bravo-7)"                     eq "$(jq -r '.cards[]|select(.project_ref=="bravo").stage_counts.impl' <<<"$V")" "1"
ck "charlie idea stage_count = 1 (charlie-3)"                 eq "$(jq -r '.cards[]|select(.project_ref=="charlie").stage_counts.idea' <<<"$V")" "1"
ck "every card flags stage_counts as derived (honesty label)" eq "$(jq -r '[.cards[]|select(.derived==true)]|length' <<<"$V")" "3"

echo "── F: sort — attention/stale first, then live, then by project_ref ──"
ck "card order is bravo(stale), charlie(attention), alpha(ok-live)" \
   eq "$(jq -r '[.cards[].project_ref]|join(",")' <<<"$V")" "bravo,charlie,alpha"

echo "── G: pure module + page wiring (anti-drift / structure) ──"
ck "workspaces-view.js makes NO network call (no fetch)"      hasnt "fetch(" "$(cat "$VIEW")"
ck "workspaces-view.js has no write/POST verb"               hasnt "POST" "$(cat "$VIEW")"
ck "workspaces-view.js touches NO DOM (no document.)"        hasnt "document." "$(cat "$VIEW")"
ck "app.js reads the §4.5 projection via Net.getJSON('/api/board')" has "Net.getJSON('/api/board')" "$(cat "$APP")"
ck "app.js mounts the persistent shell as active:'workspaces'" has "active: 'workspaces'" "$(cat "$APP")"
ck "app.js owns a 30s auto-refresh"                          has "REFRESH_MS = 30000" "$(cat "$APP")"
ck "app.js has NO write path (no POST / set-desired)"        hasnt "set-desired" "$(cat "$APP")"
# Absolute asset paths (q6z7) — a relative ./x would 404 under /workspaces.
ck "index.html links /shared/tokens.css FIRST"               has 'href="/shared/tokens.css"' "$(cat "$HTML")"
ck "index.html links /workspaces/workspaces.css"             has 'href="/workspaces/workspaces.css"' "$(cat "$HTML")"
ck "index.html loads /shared/net.js (absolute)"              has 'src="/shared/net.js"' "$(cat "$HTML")"
ck "index.html loads /shared/dom.js (absolute)"              has 'src="/shared/dom.js"' "$(cat "$HTML")"
ck "index.html loads /shared/shell.js (absolute)"            has 'src="/shared/shell.js"' "$(cat "$HTML")"
ck "index.html loads /workspaces/workspaces-view.js"         has 'src="/workspaces/workspaces-view.js"' "$(cat "$HTML")"
ck "index.html loads /workspaces/app.js (absolute)"          has 'src="/workspaces/app.js"' "$(cat "$HTML")"
ck "index.html has NO relative ./ asset path"                hasnt 'src="./' "$(cat "$HTML")"
ck "index.html header is the .apphead 'Workspaces' chrome"   has 'class="apphead"' "$(cat "$HTML")"
ck "css labels the derived-from-board tally honestly"        has "derived from board" "$(cat "$APP")"

echo "── H: empty / degenerate inputs degrade honestly (no throw) ──"
EMPTY='{"schema_version":1,"principal":"PRINCIPAL_V1","read_only":true,"projects":[],"waiting_on_you":[],"lifecycle_columns":{},"machines":[]}'
VE="$(render "$EMPTY")"
ck "no projects ⇒ ok:true, cards empty"                      eq "$(jq -r '.ok' <<<"$VE")" "true"
ck "no projects ⇒ cards length 0"                            eq "$(jq -r '.cards|length' <<<"$VE")" "0"
ck "no waiting ⇒ decisions_total 0"                          eq "$(jq -r '.decisions_total' <<<"$VE")" "0"

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " test-workspaces-view (workspaces-hub):  PASS=$PASS  FAIL=$FAIL"
echo "══════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
