#!/bin/bash
# beads-runner/lib/test-board.sh — focused unit test for the T6a Board web app
# (claude-tools-p2m): the §4.5 projection → honest-state + S-1 liveness render.
#
# T6a's OWN test surface. Deliberately NOT a member of the T1 conformance
# suite (beads-runner/conformance/, owned by T1a/T1b) and it touches NO sibling
# test (anti-drift: each tier its own focused test). It exercises ONLY the
# Board renderer (web/board/board-view.js) AND proves the no-write-path /
# §9.1-chokepoint structure of the Pages app.
#
# WHY IT DRIVES THE REAL PRODUCER: the renderer is asserted against the
# ACTUAL §4.5 work-snapshot emitted by coordinator.sh co__work_snapshot — the
# producer↔renderer seam is tested against the FROZEN contract, never a
# hand-faked shape (the lesson the sibling T4 tests call out).
#
# Asserts the EXIT CRITERIA T6a owns against INTERFACE.md v1 §4.2/§4.5/§0.3:
#   1. The Board answers "is anything waiting on me, and is the machine
#      healthy?" in ONE screen (Flow E): one health headline + the
#      WAITING-ON-YOU lane, both derived from the real projection.
#   2. S-1: an OFFLINE runner (heartbeat older than STALE_AFTER) renders as
#      "stale (last seen Nh ago)" — its own state, structurally INCAPABLE of
#      reading as actual:running; honestly distinct from a live running runner.
#   3. NO Dolt write path: the renderer/app have no mutation; the Pages read
#      proxy is GET-only and hard-codes the §4.5 read producer op (proven by
#      STRUCTURE, not a defeatable source grep of prose).
#   4. Binds §4.2/§4.5/§0.3: consumes the exact projection shape; an
#      unknown-HIGHER schema_version is REFUSED (never best-effort-rendered).
#
# Self-contained: its own CO_STORE under mktemp; shares NO state with the T1
# conformance harness or the sibling tests.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/coordinator.sh"
VIEW="$HERE/../web/board/board-view.js"
PROXY="$HERE/../web/functions/api/board/index.js"
WPROXY="$HERE/../web/functions/api/board/set-desired.js"
APP="$HERE/../web/board/app.js"
SHELL_HTML="$HERE/../web/board/index.html"
[[ -f "$LIB"   ]] || { echo "FATAL: coordinator.sh not found at $LIB"; exit 2; }
[[ -f "$VIEW"  ]] || { echo "FATAL: board-view.js not found at $VIEW"; exit 2; }
command -v node >/dev/null 2>&1 || { echo "FATAL: node required for the Board renderer test"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
ck()  { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
has()   { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }
hasnt() { case "$2" in *"$1"*) return 1;; *) return 0;; esac; }
eq()    { [[ "$1" == "$2" ]]; }
nz()    { [[ -n "$1" ]]; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CO_STORE="$WORK/store"
unset CO_EXPECTED_TOKEN PRINCIPAL_V1 STALE_AFTER USAGE_THRESHOLD 2>/dev/null || true
# shellcheck source=/dev/null
source "$LIB"
GOOD="bearer-runner-secret-xyz"

ago() {  # an RFC-3339 UTC timestamp <n> seconds in the past (§0.4)
  local n="$1" e; e=$(( $(date -u +%s) - n ))
  date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}
hb_line() {  # T3 §1.1 outbox shape, consumed verbatim by co__heartbeat
  jq -cn --argjson sv 1 --arg pr "literal-overwritten" \
         --arg rid "$1" --arg prj "$2" --arg act "$3" \
         --arg cur "$4" --arg at "$5" \
     '{report:"heartbeat",schema_version:$sv,principal:$pr,runner_id:$rid,
       project_ref:$prj,actual:$act,current_task_ref:$cur,observed_at:$at}'
}
# Pipe a §4.5 projection JSON through the PURE renderer, emit the view model.
render() { printf '%s' "$1" | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    const BV=require(process.argv[1]);
    let snap; try{snap=JSON.parse(s);}catch(e){snap=s;}
    process.stdout.write(JSON.stringify(BV.deriveBoardView(snap)));
  });' "$VIEW"; }

echo "── EXIT-1: one-screen answer — waiting-on-you + machine health (Flow E) ──"
# Real projection: one live running runner, one bead per stage, one open
# Dossier (≥1 open item) for this principal ⇒ WAITING-ON-YOU lane non-empty.
co_request "$GOOD" set-desired projA running "ui:brian-laptop" >/dev/null 2>&1
co_request "$GOOD" heartbeat "$(hb_line hostA projA running ct-1 "$(ago 20)")" >/dev/null 2>&1
# claude-tools-4xe — type=dossier writes now run the §5.1-core WRITE GATE;
# a minimal conformant body round-trips and the §4.5 lane still reads items[].
co_request "$GOOD" put dossier dOpen \
  '{"schema_version":2,"id":"dOpen","bead_ref":"claude-tools-99","tier":"blocking","body":{"dossier_schema_version":2,"diagrams":[]},"items":[{"id":"i1","state":"open"},{"id":"i2","state":"applied"}]}' >/dev/null 2>&1
BEADS='[{"bead_ref":"claude-tools-99","title":"Impl X","stage":"impl","priority":1,"age":"2h","waiting_on":"review"},{"bead_ref":"claude-tools-12","title":"Idea Y","stage":"idea","priority":2,"age":"1d"},{"bead_ref":"claude-tools-77","title":"Loose","stage":"weird","priority":3,"age":"5m"}]'
SNAP="$(co_request "$GOOD" work-snapshot projA "$BEADS" 2>/dev/null)"
V="$(render "$SNAP")"
ck "renderer accepts the real §4.5 projection (ok:true)"        eq "$(jq -r '.ok' <<<"$V")" "true"
ck "exactly ONE health headline answers the screen question"    nz "$(jq -r '.health.headline' <<<"$V")"
ck "health headline names the waiting work"                     has "waiting" "$(jq -r '.health.headline' <<<"$V")"
ck "health headline states machine health"                      has "healthy" "$(jq -r '.health.headline' <<<"$V")"
ck "WAITING-ON-YOU lane surfaces the open Dossier"              eq "$(jq -r '.waiting_on_you|length' <<<"$V")" "1"
ck "lane carries the bead_ref it waits on"                       eq "$(jq -r '.waiting_on_you[0].bead_ref' <<<"$V")" "claude-tools-99"
ck "lane shows the open-item count (1 open of 2)"                eq "$(jq -r '.waiting_on_you[0].open_item_count' <<<"$V")" "1"
ck "lane is a POINTER into T6b's Inbox (deep-link, not body)"    has "/inbox#dOpen" "$(jq -r '.waiting_on_you[0].inbox_href' <<<"$V")"
ck "lane does NOT carry dossier body/items (T6b owns content)"   eq "$(jq -r '.waiting_on_you[0]|has("body") or has("items")' <<<"$V")" "false"
ck "lifecycle spine present, FROZEN idea→done (+\"\" honest)"     eq "$(jq -r '[.lifecycle[].stage]|join(",")' <<<"$V")" "idea,ux,design,impl,docs,tests,done,"
ck "impl column carries the bead, with its 'waiting_on'"         eq "$(jq -r '.lifecycle[]|select(.stage=="impl").cards[0].waiting_on' <<<"$V")" "review"
ck "unknown stage 'weird' bucketed honestly under \"\" (not impl)" eq "$(jq -r '.lifecycle[]|select(.stage=="").cards[0].bead_ref' <<<"$V")" "claude-tools-77"
# L3 (claude-tools-2bf): the legacy/un-staged bucket is rendered as a VISIBLE
# eighth lane labeled "unstaged" (was "untracked") so legacy beads with no
# stage label never disappear from the Board.
ck "unstaged lane labeled 'unstaged' (was 'untracked')"           eq "$(jq -r '.lifecycle[]|select(.stage=="").label' <<<"$V")" "unstaged"
ck "unstaged lane is the eighth column (after done)"              eq "$(jq -r '.lifecycle|length' <<<"$V")" "8"
ck "machine reads HEALTHY (no stale/mismatch/failure)"           eq "$(jq -r '.health.ok' <<<"$V")" "true"

echo "── EXIT-1b: L3 — per-card 'which workspace is running this bead' ──"
# Live runner with current_task_ref pointing at a bead in the projection ⇒
# that bead's card carries .runner=<project_ref>. A stale runner's last task
# does NOT propagate (S-1). A card without a live runner stays runner:null.
co_request "$GOOD" set-desired projW running "ui:brian-laptop" >/dev/null 2>&1
co_request "$GOOD" heartbeat "$(hb_line hostW projW running claude-tools-99 "$(ago 15)")" >/dev/null 2>&1
SNAP_L3="$(co_request "$GOOD" work-snapshot "" "$BEADS" 2>/dev/null)"
V_L3="$(render "$SNAP_L3")"
ck "live runner's current_task_ref attributes to the impl card" eq "$(jq -r '.lifecycle[]|select(.stage=="impl").cards[0].runner' <<<"$V_L3")" "projW"
ck "a card without a live runner keeps runner:null"             eq "$(jq -r '.lifecycle[]|select(.stage=="idea").cards[0].runner' <<<"$V_L3")" "null"
# Stale runner's last current_task_ref ≠ "currently working" (S-1). Re-anchor
# projW to a stale last-heartbeat AND a different live runner on a different
# bead to prove the stale assignment is dropped, not preserved.
co_request "$GOOD" heartbeat "$(hb_line hostW projW running claude-tools-99 "$(ago 99999)")" >/dev/null 2>&1
SNAP_L3S="$(co_request "$GOOD" work-snapshot "" "$BEADS" 2>/dev/null)"
V_L3S="$(render "$SNAP_L3S")"
ck "stale runner's last task is NOT attributed (S-1)"           eq "$(jq -r '.lifecycle[]|select(.stage=="impl").cards[0].runner' <<<"$V_L3S")" "null"

echo "── EXIT-2: S-1 — an OFFLINE runner shows STALE, never running ──"
# projA's last heartbeat ages past STALE_AFTER (no further beats) ⇒ the
# Coordinator derives liveness=stale at read time; add a SECOND live running
# runner so the contrast is explicit.
co_request "$GOOD" heartbeat "$(hb_line hostA projA running ct-1 "$(ago 99999)")" >/dev/null 2>&1
co_request "$GOOD" set-desired projLive running "ui:x" >/dev/null 2>&1
co_request "$GOOD" heartbeat "$(hb_line hostB projLive running ct-9 "$(ago 15)")" >/dev/null 2>&1
SNAP2="$(co_request "$GOOD" work-snapshot "" "$BEADS" 2>/dev/null)"
V2="$(render "$SNAP2")"
RA="$(jq -c '.runners[]|select(.project_ref=="projA")' <<<"$V2")"
RL="$(jq -c '.runners[]|select(.project_ref=="projLive")' <<<"$V2")"
ck "offline runner liveness is 'stale' (from §4.2, not re-derived)" eq "$(jq -r '.liveness' <<<"$RA")" "stale"
ck "offline runner state_class is 'stale' (its OWN state)"          eq "$(jq -r '.state_class' <<<"$RA")" "stale"
ck "offline runner label is 'stale (last seen Nh ago)'"             has "stale (last seen" "$(jq -r '.state_label' <<<"$RA")"
ck "offline runner label closes the 'last seen … ago' phrase"       has " ago)" "$(jq -r '.state_label' <<<"$RA")"
# THE S-1 LIE THIS FORBIDS: a stale runner whose last actual was 'running'
# must NOT read as a live running runner.
ck "stale runner state_label is NOT 'running'"                      hasnt "running" "$(jq -r '.state_label' <<<"$RA")"
ck "stale runner state_class is NOT 'live'"                         hasnt "live" "$(jq -r '.state_class' <<<"$RA")"
ck "stale runner's last actual kept only as muted context"          has "last reported: running" "$(jq -r '.actual_note' <<<"$RA")"
ck "the LIVE runner, by contrast, is liveness 'live'"               eq "$(jq -r '.liveness' <<<"$RL")" "live"
ck "the LIVE running runner reads 'running' (state_class live)"      eq "$(jq -r '.state_class' <<<"$RL")" "live"
ck "machine now reads NOT-healthy (a runner is stale) — honest"      eq "$(jq -r '.health.ok' <<<"$V2")" "false"
ck "health strip carries a 'stale' bad tag"                          has "stale" "$(jq -r '[.health.tags[]|select(.kind=="bad").text]|join(" ")' <<<"$V2")"
# Honest desired≠actual (principle 4): desired=stopped, actual=running, live.
co_request "$GOOD" set-desired projM stopped "ui:x" >/dev/null 2>&1
co_request "$GOOD" heartbeat "$(hb_line hostM projM running ctM "$(ago 10)")" >/dev/null 2>&1
VM="$(render "$(co_request "$GOOD" work-snapshot projM "[]" 2>/dev/null)")"
RM="$(jq -c '.runners[0]' <<<"$VM")"
ck "live desired≠actual surfaced honestly (actual + target)"        has "running (target: stopped)" "$(jq -r '.state_label' <<<"$RM")"
ck "honest mismatch is NOT masked to desired"                        hasnt "^stopped$" "$(jq -r '.state_label' <<<"$RM")"

echo "── EXIT-3: write path is the ONE narrow F1 seam — proven by STRUCTURE ──"
# T6a + F2 (claude-tools-8fh): the pure renderer is still purely pure — no
# network at all (so no fetch, no POST verb, even in prose). The browser app
# now has TWO calls: the credential-less GET to /api/board AND the narrow F2
# POST to /api/board/set-desired (and ONLY those two endpoints — never the
# Coordinator directly, never with a token). Each Pages proxy enforces its
# own narrow shape (GET-only read; POST-only write with the upstream op
# hard-coded). The Board has NO write path to Dolt; F1's set-desired writes
# RunnerState in D1 and the daemon (M3) converges actual→desired.
ck "board-view.js makes NO network call (no fetch/XHR)"      hasnt "fetch(" "$(cat "$VIEW")"
ck "board-view.js has no write/POST verb"                    hasnt "POST" "$(cat "$VIEW")"
ck "board-view.js has no PUT/PATCH/DELETE verb"              hasnt "PUT" "$(cat "$VIEW")"
# The client app's TWO calls — both same-origin, credential-less, narrow.
ck "app.js issues a GET to /api/board (read channel)"        has "fetch('/api/board'" "$(cat "$APP")"
ck "app.js issues a POST to /api/board/set-desired (F2 write)" has "fetch('/api/board/set-desired'" "$(cat "$APP")"
ck "app.js POST method is the F2 write only"                 has "method: 'POST'" "$(cat "$APP")"
# STRUCTURAL — the ONLY two endpoints reached are /api/board and
# /api/board/set-desired (a third fetch URL would be a write-path widening that
# bypasses the §9.1 chokepoint pattern).
ck "app.js fetches ONLY /api/board and /api/board/set-desired" eq "$(grep -cE "fetch\('/api/" "$APP")" "2"
ck "app.js carries NO upstream URL/Coordinator base"         hasnt "/request" "$(cat "$APP")"
ck "app.js never sets an authorization header (§9.2)"        hasnt "authorization" "$(cat "$APP")"
ck "app.js write body is the F1 named-shape (state/actor)"   has "desired: { state:" "$(cat "$APP")"
# The Pages READ proxy: GET-only handler + the §4.5 read op hard-coded.
ck "proxy exports ONLY onRequestGet (no mutate handler)"     has "export async function onRequestGet" "$(cat "$PROXY")"
ck "proxy exports NO onRequestPost/Put/Patch/Delete"         hasnt "onRequestPost" "$(cat "$PROXY")"
ck "proxy hard-codes the §4.5 READ producer op"              has "COORDINATOR_OP = 'work-snapshot'" "$(cat "$PROXY")"
# STRUCTURAL (not a prose grep — the anti-drift comments legitimately NAME the
# forbidden ops): the ONLY op the proxy can put on the wire is COORDINATOR_OP;
# there is no SECOND quoted op-literal and no write op as a CODE string. The
# prose lists write ops slash-joined+unquoted; a code op-literal is quoted.
ck "proxy sets the upstream op ONLY from COORDINATOR_OP"     has "set('op', COORDINATOR_OP)" "$(cat "$PROXY")"
ck "proxy has NO write op as a code string ('set-desired')" hasnt "'set-desired'" "$(cat "$PROXY")"
ck "proxy has NO write op as a code string ('heartbeat')"   hasnt "'heartbeat'" "$(cat "$PROXY")"
ck "proxy has NO write op as a code string ('lease-acquire')" hasnt "'lease-acquire'" "$(cat "$PROXY")"
ck "proxy has NO second searchParams.set('op',…) literal"    eq "$(grep -c "set('op'," "$PROXY")" "1"
ck "proxy upstream call is method GET (read channel)"        has "method: 'GET'" "$(cat "$PROXY")"
# §9.1: the bearer is a SERVER-side binding; never shipped to the client.
ck "the bearer token is a server-side env binding (§9.1/§9.2)" has "env.COORDINATOR_TOKEN" "$(cat "$PROXY")"
ck "no token literal in the client app (secret not client-side)" hasnt "COORDINATOR_TOKEN" "$(cat "$APP")"
ck "no token literal in the shipped shell HTML"                  hasnt "COORDINATOR_TOKEN" "$(cat "$SHELL_HTML")"
# The Pages WRITE proxy (F1, claude-tools-49w): POST-only handler + the
# set-desired write op hard-coded server-side; bearer never client-side.
[[ -f "$WPROXY" ]] || { bad "F1 write proxy file exists at $WPROXY"; }
ck "F1 write proxy exports ONLY onRequestPost"                has "export async function onRequestPost" "$(cat "$WPROXY")"
ck "F1 write proxy exports NO onRequestGet/Put/Patch/Delete"  hasnt "onRequestGet" "$(cat "$WPROXY")"
ck "F1 write proxy hard-codes upstream op 'set-desired'"      has "COORDINATOR_OP = 'set-desired'" "$(cat "$WPROXY")"
ck "F1 write proxy bearer is server-side env binding"         has "env.COORDINATOR_TOKEN" "$(cat "$WPROXY")"
ck "F1 write proxy pins the four desired-states (frozen set)" has "ALLOWED_STATES" "$(cat "$WPROXY")"
# STRUCTURAL (behavioral, not a prose grep — board-view.js's anti-drift
# comment legitimately says "forensic"): inject a §10-shaped forensic blob
# into a card AND the runner_state, render, and prove the renderer DROPS it —
# it maps only the §4.5 contract fields (failure class/retry_state is Flow G
# tiers 1–2, IN §4.5; the forensic STREAM is structurally never surfaced).
FOR_CANARY="FORENSIC-LEAK-CANARY-9b2"
SNAP_F="$(jq -c --arg c "$FOR_CANARY" '
   .lifecycle_columns.impl[0].failure.forensic_blob=$c
 | .projects[0].runner_state.forensic_blob=$c' <<<"$SNAP")"
VF="$(render "$SNAP_F")"
ck "a §10 forensic blob in the projection is DROPPED by the renderer" \
   hasnt "$FOR_CANARY" "$VF"
ck "the legit Flow-G failure class IS still surfaced (in §4.5)" \
   has "UNKNOWN" "$(jq -r '[.lifecycle[].cards[]?.failure?.class//empty]|join(",")' <<<"$(render "$(jq -c '.lifecycle_columns.impl[0].failure={class:"UNKNOWN_FAILURE",retry_state:"1/3"}' <<<"$SNAP")")")"

echo "── EXIT-4: §0.3 — an unknown HIGHER snapshot schema_version is REFUSED ──"
HI="$(jq -c '.schema_version=2' <<<"$SNAP")"
VHI="$(render "$HI")"
ck "schema_version 2 ⇒ renderer refuses (ok:false)"          eq "$(jq -r '.ok' <<<"$VHI")" "false"
ck "refusal cites the unsupported version (no best-effort)"  has "unsupported work-snapshot schema_version 2" "$(jq -r '.error' <<<"$VHI")"
ck "refusal cites §0.3"                                      has "§0.3" "$(jq -r '.error' <<<"$VHI")"
NOSV="$(jq -c 'del(.schema_version)' <<<"$SNAP")"
ck "missing integer schema_version ⇒ also refused"           eq "$(jq -r '.ok' <<<"$(render "$NOSV")")" "false"
# The KNOWN bound version v1 still renders (regression guard on the reject).
ck "schema_version 1 (bound) still renders ok"               eq "$(jq -r '.ok' <<<"$(render "$SNAP")")" "true"
ck "projection self-declares read_only:true (surfaced)"      eq "$(jq -r '.read_only' <<<"$(render "$SNAP")")" "true"

echo "── EXIT-5: F2 (claude-tools-8fh) — per-workspace toggles, honest-state ──"
# The renderer exposes a controls model per runner row: four buttons keyed to
# the FROZEN desired-states, with `active` reflecting CURRENT ACTUAL (never
# desired). A pending-desired overlay (the user just tapped) surfaces as a
# SECONDARY banner — it MUST NOT promote actual (principle 4: honest, never
# optimistic). A stale runner has no active button (S-1: stale is its own
# state) AND carries a "controls may not apply quickly" warning.
# Render with an explicit pending overlay so we can assert non-optimism:
render_with_pending() { printf '%s' "$1" | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    const BV=require(process.argv[1]);
    const pd=JSON.parse(process.argv[2]);
    let snap; try{snap=JSON.parse(s);}catch(e){snap=s;}
    process.stdout.write(JSON.stringify(BV.deriveBoardView(snap, Date.now(), {pending_desired: pd})));
  });' "$VIEW" "$2"; }
# Fresh fixture: live runner with actual=running, no mismatch.
co_request "$GOOD" set-desired projF2 running "ui:x" >/dev/null 2>&1
co_request "$GOOD" heartbeat "$(hb_line hostF2 projF2 running ctF2 "$(ago 10)")" >/dev/null 2>&1
SNAP_F2="$(co_request "$GOOD" work-snapshot projF2 "[]" 2>/dev/null)"
VF2="$(render "$SNAP_F2")"
RF2="$(jq -c '.runners[]|select(.project_ref=="projF2")' <<<"$VF2")"
ck "controls list is exactly four FROZEN states"            eq "$(jq -r '[.controls[].state]|join(",")' <<<"$RF2")" "running,paused,spare-only,stopped"
ck "control labels are mobile-friendly verbs"               eq "$(jq -r '[.controls[].label]|join(",")' <<<"$RF2")" "Run,Pause,Spare-only,Stop"
ck "active = the CURRENT ACTUAL state (running)"            eq "$(jq -r '.controls[]|select(.state=="running").active' <<<"$RF2")" "true"
ck "only ONE button is active per row"                       eq "$(jq -r '[.controls[]|select(.active)]|length' <<<"$RF2")" "1"
ck "no pending overlay ⇒ pending_label is null"              eq "$(jq -r '.pending_label' <<<"$RF2")" "null"
# Tap Stop: the user just POSTed desired=stopped. The projection still
# reports actual=running until the daemon converges. Honest rendering MUST
# NOT promote stopped to active; active must remain running, and a SECONDARY
# banner must surface the desired waiting state.
PD='{"projF2":{"state":"stopped"}}'
VF2P="$(render_with_pending "$SNAP_F2" "$PD")"
RF2P="$(jq -c '.runners[]|select(.project_ref=="projF2")' <<<"$VF2P")"
ck "pending desired surfaces as a 'waiting' banner"          has "desired: stopped (waiting for runner to honor)" "$(jq -r '.pending_label' <<<"$RF2P")"
ck "pending NEVER promotes actual — active stays on running" eq "$(jq -r '.controls[]|select(.state=="running").active' <<<"$RF2P")" "true"
ck "pending does NOT activate the tapped button (stopped)"   eq "$(jq -r '.controls[]|select(.state=="stopped").active' <<<"$RF2P")" "false"
ck "honest state_label is still the actual ('running')"      has "running" "$(jq -r '.state_label' <<<"$RF2P")"
ck "pending banner does NOT mutate state_label to desired"   hasnt "stopped" "$(jq -r '.state_label' <<<"$RF2P")"
# Once the projection's actual catches up to pending, the overlay clears
# (app.js does this; the view model just doesn't surface it if state==actual).
PD2='{"projF2":{"state":"running"}}'  # daemon has converged — pending == actual
VF2C="$(render_with_pending "$SNAP_F2" "$PD2")"
RF2C="$(jq -c '.runners[]|select(.project_ref=="projF2")' <<<"$VF2C")"
ck "pending==actual ⇒ no waiting banner (honest convergence)" eq "$(jq -r '.pending_label' <<<"$RF2C")" "null"
# Stale runner: controls render, NONE active, stale warning surfaces.
RS="$(jq -c '.runners[]|select(.project_ref=="projA")' <<<"$V2")"
ck "stale runner: NO control button is active (S-1)"         eq "$(jq -r '[.controls[]|select(.active)]|length' <<<"$RS")" "0"
ck "stale runner carries the 'may not apply quickly' note"   has "controls may not apply quickly" "$(jq -r '.stale_controls_note' <<<"$RS")"
ck "stale warning names a 'last seen … ago' duration"        has "last seen" "$(jq -r '.stale_controls_note' <<<"$RS")"
# Mobile-friendly CSS: ≥44px tap targets, no hover-only state.
CSS="$HERE/../web/board/board.css"
[[ -f "$CSS" ]] || bad "board.css present"
ck "control buttons declare min-height ≥44px (tap target)"   has "min-height:44px" "$(cat "$CSS")"
ck "control buttons set touch-action:manipulation (no 300ms)" has "touch-action:manipulation" "$(cat "$CSS")"
ck "control buttons are NOT hover-only (have :active style)"  has ".rbtn:active" "$(cat "$CSS")"
ck "shell HTML viewport tag enables mobile sizing"           has "width=device-width" "$(cat "$SHELL_HTML")"

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " test-board (T6a + F2 claude-tools-8fh):  PASS=$PASS  FAIL=$FAIL"
echo "══════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
