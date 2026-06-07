#!/bin/bash
# beads-runner/lib/test-activity-view.sh — focused unit test for the Activity
# facet view-model (I3, claude-tools-uxvi3; DESIGN I §2 + UX-DESIGN-V2
# §5.1/§5.2/§5.4): the §4.5 projection → a per-workspace writer lane (exactly
# one|null) + auxiliary pool (0..N) + per-agent liveness dots + a DISTINCT
# runner-health pip, with derived state shown as "looks like" and B.4 tolerance.
#
# Mirrors lib/test-workspaces-view.sh's node-require technique: it does a node
# `require` of the pure view-model (web/workspace/activity-view.js), feeds a
# hand-crafted fixture snapshot JSON (the FROZEN B.1 activity{}/runner_health{}
# shape the I2 producer emits in cf/src/reconcile.js), and asserts the derived
# model. The bash coordinator is NOT driven here — the facet reads the SAME
# /api/board projection the Board does; this test fixes the facet's OWN
# rendering contract against the frozen shape.
#
# Asserts (the s6 invariant from the bead): EXACTLY ONE writer lane (or null);
# aux pool 0..N; liveness dots green/amber/red; derived shown as looks-like;
# runner-health pip distinct from agent activity; B.4 tolerance (missing/garbled
# field ⇒ honest placeholder + degraded[], never throw); the ONE hard refusal is
# an unknown-HIGHER (or missing/non-integer) schema_version (§0.3).
#
# Self-contained: needs only node + jq. Keeps the test FILE out of the deployed
# web/ dir (it lives in beads-runner/lib/). Run from the repo root.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIEW="$HERE/../web/workspace/activity-view.js"
APP="$HERE/../web/workspace/app.js"
HTML="$HERE/../web/workspace/index.html"
CSS="$HERE/../web/workspace/workspace.css"
[[ -f "$VIEW" ]] || { echo "FATAL: activity-view.js not found at $VIEW"; exit 2; }
command -v node >/dev/null 2>&1 || { echo "FATAL: node required for the Activity view test"; exit 2; }
command -v jq   >/dev/null 2>&1 || { echo "FATAL: jq required for the Activity view test"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \xe2\x9c\x93 %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \xe2\x9c\x97 %s\n' "$1"; FAIL=$((FAIL+1)); }
ck()  { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
has()   { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }
hasnt() { case "$2" in *"$1"*) return 1;; *) return 0;; esac; }
eq()    { [[ "$1" == "$2" ]]; }

# Pipe a §4.5 projection JSON + a workspace ref through the PURE view-model at a
# FIXED now-ms (deterministic). render <ref> < json.
NOW_MS=1779148800000
render() { printf '%s' "$2" | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    const AV=require(process.argv[1]);
    let snap; try{snap=JSON.parse(s);}catch(e){snap=s;}
    process.stdout.write(JSON.stringify(AV.deriveActivityView(snap, process.argv[3], Number(process.argv[2]))));
  });' "$VIEW" "$NOW_MS" "$1"; }

# ── The fixture: a hand-crafted §4.5 work-snapshot with the B.1 activity shapes ─
# Three projects:
#   • rhythmGame — a WRITER (writing-code, green) + 2 aux (blueprint-update amber,
#     enricher red) + runner_health working. The happy path.
#   • beQuiet    — NO writer (writer:null) + 0 aux + runner_health WEDGED. The
#     "stuck loop" + "no writer" honest-empty path.
#   • noActivity — a project with runner_state but NO activity block + NO
#     runner_health (an old producer) ⇒ B.4 degraded, not a throw.
FIX="$(jq -cn '{
  schema_version: 1,
  read_only: true,
  principal: "PRINCIPAL_V1",
  projects: [
    { project_ref: "rhythmGame",
      runner_state: { liveness:"live", actual:"running", desired:"running",
        desired_actual_mismatch:false, last_heartbeat_at:"2026-05-29T00:00:00Z",
        current_task_ref:"rhythmGame-93o", current_task_title:"DrawingOverlay restart" },
      runner_health: { process:"alive", heartbeat:"fresh", last_pickup_at:null, state:"working" },
      activity: {
        writer: { bead_ref:"rhythmGame-93o", title:"DrawingOverlay restart", stage:"impl",
          state:"writing-code", state_confidence:"derived", liveness_dot:"green",
          seconds_in_state:132, touching:["Gameplay","Input"] },
        auxiliary: [
          { kind:"blueprint-update", label:"refresh map after 93o",
            state:"exploring", state_confidence:"derived", liveness_dot:"amber" },
          { kind:"enricher", label:"intake 09-30",
            state:"maybe-stuck", state_confidence:"derived", liveness_dot:"red" }
        ]
      } },
    { project_ref: "beQuiet",
      runner_state: { liveness:"stale", actual:"running", desired:"running",
        desired_actual_mismatch:false, last_heartbeat_at:"2026-01-01T00:00:00Z",
        current_task_ref:"beQuiet-7", current_task_title:"x" },
      runner_health: { process:"alive", heartbeat:"stale", last_pickup_at:null, state:"wedged" },
      activity: { writer: null, auxiliary: [] } },
    { project_ref: "noActivity",
      runner_state: { liveness:"live", actual:"idle", desired:"running",
        desired_actual_mismatch:true, last_heartbeat_at:"2026-05-29T00:00:00Z",
        current_task_ref:"", current_task_title:null } }
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
ck "found:true (project present in projection)"        eq "$(jq -r '.found' <<<"$V")" "true"

echo "── B: §0.3 — an unknown HIGHER (or missing/non-integer) sv is REFUSED ──"
HI="$(jq -c '.schema_version=99' <<<"$FIX")"
VHI="$(render rhythmGame "$HI")"
ck "schema_version 99 ⇒ ok:false (refuse, no best-effort)" eq "$(jq -r '.ok' <<<"$VHI")" "false"
ck "refusal names the unsupported version"                 has "schema_version 99" "$(jq -r '.error' <<<"$VHI")"
ck "refusal cites §0.3"                                    has "§0.3" "$(jq -r '.error' <<<"$VHI")"
ck "missing schema_version ⇒ also ok:false"                eq "$(jq -r '.ok' <<<"$(render rhythmGame "$(jq -c 'del(.schema_version)' <<<"$FIX")")")" "false"
ck "non-integer schema_version (1.5) ⇒ also ok:false"      eq "$(jq -r '.ok' <<<"$(render rhythmGame "$(jq -c '.schema_version=1.5' <<<"$FIX")")")" "false"

echo "── C: WRITER LANE — exactly one, the 8-key shape, derived as looks-like ──"
ck "writer is present (one object, not an array)"      eq "$(jq -r '.writer|type' <<<"$V")" "object"
ck "writer bead_ref surfaced"                          eq "$(jq -r '.writer.bead_ref' <<<"$V")" "rhythmGame-93o"
ck "writer title surfaced"                             eq "$(jq -r '.writer.title' <<<"$V")" "DrawingOverlay restart"
ck "writer stage surfaced"                             eq "$(jq -r '.writer.stage' <<<"$V")" "impl"
ck "writer raw state preserved (writing-code)"         eq "$(jq -r '.writer.state' <<<"$V")" "writing-code"
# DERIVED shown as LOOKS-LIKE (the bead's s6 invariant + §5.2 honesty rule).
ck "writer state_label is 'looks like: writing code'"  eq "$(jq -r '.writer.state_label' <<<"$V")" "looks like: writing code"
ck "writer looks_like flag is true (tool-derived)"     eq "$(jq -r '.writer.looks_like' <<<"$V")" "true"
ck "writer state_confidence is ALWAYS 'derived'"       eq "$(jq -r '.writer.state_confidence' <<<"$V")" "derived"
ck "writer liveness_dot is green (consumed verbatim)"  eq "$(jq -r '.writer.liveness_dot' <<<"$V")" "green"
ck "writer seconds_in_state surfaced (132)"            eq "$(jq -r '.writer.seconds_in_state' <<<"$V")" "132"
ck "writer duration_label is '2m12s'"                  eq "$(jq -r '.writer.duration_label' <<<"$V")" "2m12s"
ck "writer touching[] surfaced (Gameplay,Input)"       eq "$(jq -r '.writer.touching|join(",")' <<<"$V")" "Gameplay,Input"

echo "── D: AUXILIARY POOL — 0..N, narrower 5-key shape, looks-like + dots ──"
ck "aux_count is 2"                                    eq "$(jq -r '.aux_count' <<<"$V")" "2"
ck "auxiliary is an array of length 2"                 eq "$(jq -r '.auxiliary|length' <<<"$V")" "2"
ck "aux[0] kind=blueprint-update"                      eq "$(jq -r '.auxiliary[0].kind' <<<"$V")" "blueprint-update"
ck "aux[0] label surfaced"                             eq "$(jq -r '.auxiliary[0].label' <<<"$V")" "refresh map after 93o"
ck "aux[0] state_label 'looks like: exploring'"        eq "$(jq -r '.auxiliary[0].state_label' <<<"$V")" "looks like: exploring"
ck "aux[0] liveness_dot amber (verbatim)"              eq "$(jq -r '.auxiliary[0].liveness_dot' <<<"$V")" "amber"
ck "aux[1] kind=enricher"                              eq "$(jq -r '.auxiliary[1].kind' <<<"$V")" "enricher"
# maybe-stuck is a FACTUAL liveness signal (>180s) — not a 'looks like' guess.
ck "aux[1] state_label 'maybe stuck' (NOT looks-like)" eq "$(jq -r '.auxiliary[1].state_label' <<<"$V")" "maybe stuck"
ck "aux[1] looks_like flag is false"                   eq "$(jq -r '.auxiliary[1].looks_like' <<<"$V")" "false"
ck "aux[1] state_confidence still 'derived'"           eq "$(jq -r '.auxiliary[1].state_confidence' <<<"$V")" "derived"
ck "aux[1] liveness_dot red (verbatim)"                eq "$(jq -r '.auxiliary[1].liveness_dot' <<<"$V")" "red"
# An aux carries NO bead_ref/title/seconds to the UI (§1.4 — must-protect #2).
ck "aux carries NO bead_ref key (§1.4 projection-drop)" eq "$(jq -r '[.auxiliary[]|has("bead_ref")]|any' <<<"$V")" "false"
ck "aux carries NO seconds_in_state key (§1.4)"        eq "$(jq -r '[.auxiliary[]|has("seconds_in_state")]|any' <<<"$V")" "false"

echo "── E: RUNNER-HEALTH PIP — distinct from agent activity (§5.4) ──"
ck "runner_health present"                             eq "$(jq -r '.runner_health.present' <<<"$V")" "true"
ck "runner_health state working"                       eq "$(jq -r '.runner_health.state' <<<"$V")" "working"
ck "runner_health state_label working"                 eq "$(jq -r '.runner_health.state_label' <<<"$V")" "working"
ck "runner_health process alive"                       eq "$(jq -r '.runner_health.process' <<<"$V")" "alive"
ck "runner_health heartbeat fresh"                     eq "$(jq -r '.runner_health.heartbeat' <<<"$V")" "fresh"
# A WEDGED runner reads 'stuck' (§5.4 verbatim) — the distinct loop-process signal.
VB="$(render beQuiet "$FIX")"
ck "beQuiet runner_health state wedged"                eq "$(jq -r '.runner_health.state' <<<"$VB")" "wedged"
ck "beQuiet WEDGED reads label 'stuck' (§5.4)"         eq "$(jq -r '.runner_health.state_label' <<<"$VB")" "stuck"
ck "beQuiet runner_health heartbeat stale"             eq "$(jq -r '.runner_health.heartbeat' <<<"$VB")" "stale"

echo "── F: writer:null + empty pool render an honest empty state (not a throw) ──"
ck "beQuiet writer is null (no writer)"                eq "$(jq -r '.writer' <<<"$VB")" "null"
ck "beQuiet aux_count is 0"                            eq "$(jq -r '.aux_count' <<<"$VB")" "0"
ck "beQuiet still ok:true (null writer is in-contract)" eq "$(jq -r '.ok' <<<"$VB")" "true"
ck "beQuiet found:true"                                eq "$(jq -r '.found' <<<"$VB")" "true"

echo "── G: B.4 tolerance — a missing activity/runner_health block degrades ──"
VN="$(render noActivity "$FIX")"
ck "noActivity ok:true (degrade, never refuse)"        eq "$(jq -r '.ok' <<<"$VN")" "true"
ck "noActivity found:true (project IS present)"        eq "$(jq -r '.found' <<<"$VN")" "true"
ck "noActivity writer null (no activity block)"        eq "$(jq -r '.writer' <<<"$VN")" "null"
ck "noActivity aux empty"                              eq "$(jq -r '.aux_count' <<<"$VN")" "0"
ck "noActivity runner_health present:false (unknown)"  eq "$(jq -r '.runner_health.present' <<<"$VN")" "false"
ck "noActivity runner_health label 'unknown'"          eq "$(jq -r '.runner_health.state_label' <<<"$VN")" "unknown"
ck "noActivity emits a degraded[] note for activity"   has "activity not reported" "$(jq -r '.degraded|join("|")' <<<"$VN")"
ck "noActivity emits a degraded[] note for health"     has "runner_health not reported" "$(jq -r '.degraded|join("|")' <<<"$VN")"

echo "── H: an unknown ref ⇒ found:false honest empty (NOT a refusal) ──"
VU="$(render ghostWorkspace "$FIX")"
ck "unknown ref ⇒ ok:true (not a refusal)"             eq "$(jq -r '.ok' <<<"$VU")" "true"
ck "unknown ref ⇒ found:false"                         eq "$(jq -r '.found' <<<"$VU")" "false"
ck "unknown ref ⇒ writer null"                         eq "$(jq -r '.writer' <<<"$VU")" "null"
ck "unknown ref ⇒ a degraded 'no runner reported' note" has "no runner reported for ghostWorkspace" "$(jq -r '.degraded|join("|")' <<<"$VU")"

echo "── I: a garbled field degrades to a placeholder + a degraded note (no throw) ──"
# liveness_dot out of the closed set ⇒ 'unknown' dot + a degraded note.
GARB="$(jq -c '.projects[0].activity.writer.liveness_dot="chartreuse" | .projects[0].activity.writer.state="not-a-state"' <<<"$FIX")"
VG="$(render rhythmGame "$GARB")"
ck "garbled snapshot still ok:true (no throw)"         eq "$(jq -r '.ok' <<<"$VG")" "true"
ck "out-of-set dot ⇒ 'unknown' (not a fabricated green)" eq "$(jq -r '.writer.liveness_dot' <<<"$VG")" "unknown"
ck "out-of-set dot emits a degraded note"              has "liveness dot missing/unknown" "$(jq -r '.degraded|join("|")' <<<"$VG")"
ck "out-of-set state ⇒ state_confidence still derived" eq "$(jq -r '.writer.state_confidence' <<<"$VG")" "derived"

echo "── J: duration formatting (presentation of seconds_in_state) ──"
fmt() { node -e 'const AV=require(process.argv[1]);process.stdout.write(String(AV.formatDuration(Number(process.argv[2]))))' "$VIEW" "$1"; }
ck "formatDuration(45) = 45s"                          eq "$(fmt 45)" "45s"
ck "formatDuration(132) = 2m12s"                       eq "$(fmt 132)" "2m12s"
ck "formatDuration(3725) = 1h02m"                      eq "$(fmt 3725)" "1h02m"
ck "formatDuration(-1) = null (honest absence)"        eq "$(fmt -1)" "null"

echo "── K: pure module + page wiring (anti-drift / structure) ──"
ck "activity-view.js makes NO network call (no fetch)" hasnt "fetch(" "$(cat "$VIEW")"
ck "activity-view.js has no write/POST verb"           hasnt "POST" "$(cat "$VIEW")"
ck "activity-view.js touches NO DOM (no document.)"    hasnt "document." "$(cat "$VIEW")"
ck "activity-view.js has no set-desired write path"    hasnt "set-desired" "$(cat "$VIEW")"
ck "app.js routes the 'activity' facet to a live mount" has "ctx.facet === 'activity'" "$(cat "$APP")"
ck "app.js reads /api/board for the facet"             has "Net.getJSON('/api/board')" "$(cat "$APP")"
ck "app.js owns a 30s auto-refresh"                    has "REFRESH_MS = 30000" "$(cat "$APP")"
# I3 was read-only; I4 (claude-tools-uxvi4) ADDS the ONE write affordance — the
# four stuck actions on a maybe-stuck writer. The write path must route through
# the CONTROL PLANE (an agent-action intent / a dossier write), NEVER a direct
# web→process kill, and NEVER widen to the runner-lifecycle set-desired verb here.
ck "app.js posts the stuck actions to the agent-action control proxy" \
   has "/api/control/agent-action" "$(cat "$APP")"
ck "app.js posts 'escalate' to the dossier-write control proxy" \
   has "/api/control/escalate" "$(cat "$APP")"
ck "app.js stuck-actions render only on a maybe-stuck writer" \
   has "writer.state === 'maybe-stuck'" "$(cat "$APP")"
# (We deliberately do NOT assert hasnt "set-desired" on app.js — since
# claude-tools-758l the per-workspace Board facet DOES carry the F2 set-desired
# write (the Run/Pause/Spare-only/Stop controls now live one tap from the
# workspace card; UX-DESIGN-V2 §2/§4 Flow D). The ACTIVITY facet's own writes are
# still only the two /api/control/* proxies asserted above; neither is set-desired.)
# The pure view-model stays write-free regardless (the producer↔renderer seam).
ck "activity-view.js (the pure core) still makes no write call" \
   hasnt "postJSON" "$(cat "$VIEW")"
# Header pip lights ONLY on the contract's named alarm states (§5.3/§5.4): a
# WEDGED runner or a MAYBE-STUCK writer — NEVER a benign process:'dead' stop.
ck "app.js header alarm keys on rh.state==='wedged'"   has "rh.state === 'wedged'" "$(cat "$APP")"
ck "app.js header alarm keys on a maybe-stuck writer"  has "w.state === 'maybe-stuck'" "$(cat "$APP")"
ck "app.js header does NOT alarm on process==='dead'"  hasnt "rh.process === 'dead'" "$(cat "$APP")"
ck "FACET_TRACK no longer lists activity (it graduated)" hasnt "activity: 'I3'" "$(cat "$APP")"
# Absolute asset paths (q6z7) — a relative ./x would 404 under /ws/<ref>/activity.
ck "index.html loads /workspace/activity-view.js (absolute)" has 'src="/workspace/activity-view.js"' "$(cat "$HTML")"
ck "index.html links /shared/tokens.css FIRST"          has 'href="/shared/tokens.css"' "$(cat "$HTML")"
ck "index.html has NO relative ./ asset path"           hasnt 'src="./' "$(cat "$HTML")"
# CSS draws the runner-health pip DISTINCT (square indicator) from the round dots.
ck "css styles the runner-health pip (.af-rh-pip)"      has ".af-rh-pip" "$(cat "$CSS")"
ck "css styles green/amber/red liveness dots"           has ".af-dot.dot-red" "$(cat "$CSS")"

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " test-activity-view (activity-facet I3):  PASS=$PASS  FAIL=$FAIL"
echo "══════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
