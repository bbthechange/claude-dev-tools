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
# GAP G2 (claude-tools-uxg2) — the two trailing `done` beads exercise the
# rendered done·verified vs done·code split (§3 / principle 11): d1's probe
# passed (verified:true); d2 has no probe fact (→ done·code).
BEADS='[{"bead_ref":"claude-tools-99","title":"Impl X","stage":"impl","priority":1,"age":"2h","waiting_on":"review"},{"bead_ref":"claude-tools-12","title":"Idea Y","stage":"idea","priority":2,"age":"1d"},{"bead_ref":"claude-tools-77","title":"Loose","stage":"weird","priority":3,"age":"5m"},{"bead_ref":"claude-tools-d1","title":"Shipped","stage":"done","priority":1,"age":"3h","verified":true},{"bead_ref":"claude-tools-d2","title":"Landed","stage":"done","priority":2,"age":"4h"}]'
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
# GAP G2 (claude-tools-uxg2): the renderer splits `done` into done·verified vs
# done·code off the per-card `verified` flag (§3 / principle 11). The sub-state
# label is the FROZEN §5.2 DONE_SUBSTATE vocabulary; only the done lane carries
# it (null elsewhere — so the split never leaks onto idea/impl/etc.).
ck "G2 — done card whose probe passed renders done·verified" eq "$(jq -r '.lifecycle[]|select(.stage=="done").cards[0].done_substate' <<<"$V")" "done·verified"
ck "G2 — done card with no probe renders done·code"          eq "$(jq -r '.lifecycle[]|select(.stage=="done").cards[1].done_substate' <<<"$V")" "done·code"
ck "G2 — done·verified card carries verified:true"           eq "$(jq -r '.lifecycle[]|select(.stage=="done").cards[0].verified' <<<"$V")" "true"
ck "G2 — the split is done-lane ONLY (impl card has no sub-state)" eq "$(jq -r '.lifecycle[]|select(.stage=="impl").cards[0].done_substate' <<<"$V")" "null"
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

echo "── EXIT-6: 8ag — workspace strip surfaces a LIVE runner's current_task_ref ──"
# The §4.5 projection's runner_state.current_task_ref is the bead the runner
# last reported it was working on. On the workspace strip, a LIVE runner's
# task is presented as a secondary "currently working on" line under the
# state pill (ref-only — no title lookup yet; see board-view.js comment).
# A STALE runner's last-reported task is honestly unknown (S-1) and MUST
# NOT be promoted as "currently working".
#
# Case D — liveness=live, current_task_ref non-empty ⇒ row.current_task=<ref>.
co_request "$GOOD" set-desired projD running "ui:x" >/dev/null 2>&1
co_request "$GOOD" heartbeat "$(hb_line hostD projD running claude-tools-h7n "$(ago 10)")" >/dev/null 2>&1
SNAP_D="$(co_request "$GOOD" work-snapshot projD "[]" 2>/dev/null)"
VD="$(render "$SNAP_D")"
RD="$(jq -c '.runners[]|select(.project_ref=="projD")' <<<"$VD")"
ck "Case D — live runner exposes current_task on the row"        eq "$(jq -r '.current_task' <<<"$RD")" "claude-tools-h7n"
ck "Case D — view model carries the ref verbatim (no decoration)" eq "$(jq -r '.current_task' <<<"$RD")" "claude-tools-h7n"
# Case E — liveness=stale + current_task_ref present ⇒ row.current_task null.
# Re-anchor projD's last heartbeat past STALE_AFTER so the Coordinator marks
# it stale at read time; the renderer must DROP the current_task per S-1.
co_request "$GOOD" heartbeat "$(hb_line hostD projD running claude-tools-h7n "$(ago 99999)")" >/dev/null 2>&1
SNAP_E="$(co_request "$GOOD" work-snapshot projD "[]" 2>/dev/null)"
VE="$(render "$SNAP_E")"
RE="$(jq -c '.runners[]|select(.project_ref=="projD")' <<<"$VE")"
ck "Case E — stale runner's current_task is null (S-1)"          eq "$(jq -r '.current_task' <<<"$RE")" "null"
ck "Case E — view model does NOT carry the ref for stale runner" hasnt "claude-tools-h7n" "$(jq -r '.current_task // ""' <<<"$RE")"
# Case F — liveness=live, current_task_ref empty/missing ⇒ current_task null.
# A live runner that reports actual=idle and an empty current_task_ref must
# not produce a secondary line (nothing to say).
co_request "$GOOD" set-desired projF running "ui:x" >/dev/null 2>&1
co_request "$GOOD" heartbeat "$(hb_line hostF projF idle "" "$(ago 10)")" >/dev/null 2>&1
SNAP_F8="$(co_request "$GOOD" work-snapshot projF "[]" 2>/dev/null)"
VFF="$(render "$SNAP_F8")"
RF="$(jq -c '.runners[]|select(.project_ref=="projF")' <<<"$VFF")"
ck "Case F — live runner with no task: liveness is live"         eq "$(jq -r '.liveness' <<<"$RF")" "live"
ck "Case F — live runner with empty task ⇒ current_task null"    eq "$(jq -r '.current_task' <<<"$RF")" "null"
# STRUCTURAL — app.js renders the secondary line from r.current_task using
# the .workspace-current-task class so a future renderer change cannot
# silently drop the line for live runners.
ck "app.js renders r.current_task as the secondary line"         has "r.current_task" "$(cat "$APP")"
ck "app.js uses the .workspace-current-task class for the line"  has "workspace-current-task" "$(cat "$APP")"
ck "board.css styles .workspace-current-task (secondary text)"   has "workspace-current-task" "$(cat "$CSS")"

echo "── EXIT-6b: 4g5o — workspace strip surfaces TITLE alongside current_task_ref ──"
# claude-tools-4g5o — the CF projection now joins workspace_inventory's
# in_progress_beads[] to add `current_task_title` on each runner_state.
# The view model carries it through and the app renders it after the ref as
# a visually subordinate span. Falls back to ref-only when the title is
# absent (graceful — the producer may not have published yet).
#
# These cases drive the renderer through crafted snapshots (the bash
# coordinator has no workspace_inventory store; CF tests cover the join).
render_snap() { printf '%s' "$1" | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    const BV=require(process.argv[1]);
    let snap; try{snap=JSON.parse(s);}catch(e){snap=s;}
    process.stdout.write(JSON.stringify(BV.deriveBoardView(snap)));
  });' "$VIEW"; }
mk_snap_rs() {  # <ref> <title-or-null-literal>
  local ref="$1" title_lit="$2"
  jq -cn --arg ref "$ref" --argjson title "$title_lit" \
    '{schema_version:1,principal:"PRINCIPAL_V1",read_only:true,
      lifecycle_columns:{},waiting_on_you:[],machines:[],
      projects:[{project_ref:"projG5",
        runner_state:{desired:"running",actual:"running",liveness:"live",
                      last_heartbeat_at:(now|todateiso8601),
                      current_task_ref:$ref,current_task_title:$title,
                      desired_actual_mismatch:false},
        lease:null}]}'
}
# Case E — ref + title BOTH set ⇒ view carries both; rendered line contains
# both. (The render check is structural: app.js must emit a span with the
# title-subordinate class so the title actually paints in the live DOM.)
VE_SNAP="$(mk_snap_rs claude-tools-xyz '"Short title"')"
VE_M="$(render_snap "$VE_SNAP")"
RE_M="$(jq -c '.runners[]|select(.project_ref=="projG5")' <<<"$VE_M")"
ck "Case E — view model carries current_task ref"               eq "$(jq -r '.current_task' <<<"$RE_M")" "claude-tools-xyz"
ck "Case E — view model carries current_task_title"             eq "$(jq -r '.current_task_title' <<<"$RE_M")" "Short title"
ck "Case E — app.js renders r.current_task_title (uses field)"  has "r.current_task_title" "$(cat "$APP")"
ck "Case E — app.js uses .workspace-current-task-title class"   has "workspace-current-task-title" "$(cat "$APP")"
ck "Case E — board.css styles the subordinate title span"       has "workspace-current-task-title" "$(cat "$CSS")"
# Case F — ref present, no title ⇒ view's title=null (fallback to ref-only).
VF_SNAP="$(mk_snap_rs claude-tools-xyz 'null')"
RF_M="$(jq -c '.runners[]|select(.project_ref=="projG5")' <<<"$(render_snap "$VF_SNAP")")"
ck "Case F — ref-only fallback: current_task carries ref"       eq "$(jq -r '.current_task' <<<"$RF_M")" "claude-tools-xyz"
ck "Case F — ref-only fallback: current_task_title is null"     eq "$(jq -r '.current_task_title' <<<"$RF_M")" "null"
# Case G — neither ref nor title ⇒ no current-task line at all (current
# behavior preserved; app.js gates the line on r.current_task being truthy).
VG_SNAP="$(mk_snap_rs '' 'null')"
RG_M="$(jq -c '.runners[]|select(.project_ref=="projG5")' <<<"$(render_snap "$VG_SNAP")")"
ck "Case G — no ref ⇒ current_task is null (no line at all)"    eq "$(jq -r '.current_task' <<<"$RG_M")" "null"
ck "Case G — no ref ⇒ current_task_title is also null"          eq "$(jq -r '.current_task_title' <<<"$RG_M")" "null"
# Case H — a >60-char title is truncated with an ellipsis when rendered.
# The view model preserves the full title (truncation is a presentation
# decision in app.js); STRUCTURAL: app.js carries a length>60 guard and
# appends an ellipsis so a runaway title cannot push the row off-screen.
LONG='A very long workspace_inventory bead title that is well past sixty characters in length'
VH_SNAP="$(mk_snap_rs claude-tools-xyz "$(jq -n --arg t "$LONG" '$t')")"
RH_M="$(jq -c '.runners[]|select(.project_ref=="projG5")' <<<"$(render_snap "$VH_SNAP")")"
ck "Case H — view preserves the full long title"                eq "$(jq -r '.current_task_title|length' <<<"$RH_M")" "${#LONG}"
ck "Case H — app.js truncates titles >60 chars"                 has ".length > 60" "$(cat "$APP")"
ck "Case H — app.js appends an ellipsis after truncation"       has "'…'" "$(cat "$APP")"
# A STALE runner's last-reported task is honestly unknown (S-1) — and so is
# any joined title. The view model must drop BOTH for a stale runner.
STALE_SNAP="$(jq -cn '{schema_version:1,principal:"PRINCIPAL_V1",read_only:true,
  lifecycle_columns:{},waiting_on_you:[],machines:[],
  projects:[{project_ref:"projStale",
    runner_state:{desired:"running",actual:"running",liveness:"stale",
                  last_heartbeat_at:"2026-05-23T00:00:00Z",
                  current_task_ref:"claude-tools-xyz",
                  current_task_title:"Shouldnt show",
                  desired_actual_mismatch:false},
    lease:null}]}')"
RST_M="$(jq -c '.runners[]|select(.project_ref=="projStale")' <<<"$(render_snap "$STALE_SNAP")")"
ck "Stale runner — current_task dropped (S-1)"                  eq "$(jq -r '.current_task' <<<"$RST_M")" "null"
ck "Stale runner — current_task_title dropped (S-1)"            eq "$(jq -r '.current_task_title' <<<"$RST_M")" "null"

echo "── EXIT-7: g2s — soft 'thinking' visual between 90s and 180s heartbeat age ──"
# A purely-presentational threshold: when liveness=='live' AND the heartbeat
# is between 90s and 180s old AND actual=='running', the renderer paints a
# third visual class ('thinking') so the pill doesn't jump live→stale at the
# 180s cliff for a long legitimate stream gap. The wire `liveness` stays
# binary (§4.2 frozen); S-1 control-button gating still keys off `liveness`,
# never state_class.
#
#   Case A — age=10s,  live  → state_class='live',     label='running'
#   Case B — age=120s, live  → state_class='thinking', label contains 'last event'
#   Case C — age=300s, stale → state_class='stale',    label='stale (last seen …)'
co_request "$GOOD" set-desired projTA running "ui:x" >/dev/null 2>&1
co_request "$GOOD" heartbeat "$(hb_line hostTA projTA running ctA "$(ago 10)")" >/dev/null 2>&1
SNAP_TA="$(co_request "$GOOD" work-snapshot projTA "[]" 2>/dev/null)"
RTA="$(jq -c '.runners[]|select(.project_ref=="projTA")' <<<"$(render "$SNAP_TA")")"
ck "Case A — age=10s liveness is 'live'"                       eq "$(jq -r '.liveness' <<<"$RTA")" "live"
ck "Case A — state_class is 'live' (under thinking threshold)" eq "$(jq -r '.state_class' <<<"$RTA")" "live"
ck "Case A — state_label is 'running' (existing branch)"       eq "$(jq -r '.state_label' <<<"$RTA")" "running"
ck "Case A — state_label does NOT contain 'last event'"        hasnt "last event" "$(jq -r '.state_label' <<<"$RTA")"

co_request "$GOOD" set-desired projTB running "ui:x" >/dev/null 2>&1
co_request "$GOOD" heartbeat "$(hb_line hostTB projTB running ctB "$(ago 120)")" >/dev/null 2>&1
SNAP_TB="$(co_request "$GOOD" work-snapshot projTB "[]" 2>/dev/null)"
RTB="$(jq -c '.runners[]|select(.project_ref=="projTB")' <<<"$(render "$SNAP_TB")")"
ck "Case B — age=120s liveness is STILL 'live' (wire binary)"  eq "$(jq -r '.liveness' <<<"$RTB")" "live"
ck "Case B — state_class is 'thinking' (90s≤age<180s window)"  eq "$(jq -r '.state_class' <<<"$RTB")" "thinking"
ck "Case B — state_label contains 'last event'"                has "last event" "$(jq -r '.state_label' <<<"$RTB")"
ck "Case B — S-1 unchanged: live-keyed control still active"   eq "$(jq -r '.controls[]|select(.state=="running").active' <<<"$RTB")" "true"

co_request "$GOOD" set-desired projTC running "ui:x" >/dev/null 2>&1
co_request "$GOOD" heartbeat "$(hb_line hostTC projTC running ctC "$(ago 300)")" >/dev/null 2>&1
SNAP_TC="$(co_request "$GOOD" work-snapshot projTC "[]" 2>/dev/null)"
RTC="$(jq -c '.runners[]|select(.project_ref=="projTC")' <<<"$(render "$SNAP_TC")")"
ck "Case C — age=300s liveness is 'stale' (past STALE_AFTER)"  eq "$(jq -r '.liveness' <<<"$RTC")" "stale"
ck "Case C — state_class is 'stale' (its own state, §4.2)"     eq "$(jq -r '.state_class' <<<"$RTC")" "stale"
ck "Case C — state_label is 'stale (last seen … ago)'"         has "stale (last seen" "$(jq -r '.state_label' <<<"$RTC")"
# Edge: actual=idle in the thinking window MUST NOT paint 'thinking' (idle
# silence is honest, not "thinking after a tool_result"); stays 'live'.
co_request "$GOOD" set-desired projTI running "ui:x" >/dev/null 2>&1
co_request "$GOOD" heartbeat "$(hb_line hostTI projTI idle "" "$(ago 120)")" >/dev/null 2>&1
RTI="$(jq -c '.runners[]|select(.project_ref=="projTI")' <<<"$(render "$(co_request "$GOOD" work-snapshot projTI "[]" 2>/dev/null)")")"
ck "Edge — actual=idle in thinking window stays 'live'"        eq "$(jq -r '.state_class' <<<"$RTI")" "live"
# CSS — the new class is declared with a presentation matching the live family
# but visibly distinct (opacity/animation), and is reduced-motion safe.
ck "board.css declares .pill.thinking"                         has ".pill.thinking" "$(cat "$CSS")"
ck "board.css thinking style is reduced-motion safe"           has "prefers-reduced-motion" "$(cat "$CSS")"

echo "── EXIT-8: MACHINE-STATE.md v1 §4 — top-of-board capacity strip (zdxd.5) ──"
# The §4.A per-machine strip is the ONE place per-machine usage surfaces; the
# per-runner 'capacity: <verdict>' pill is removed (§4.F). Color bands are
# driven by threshold_in_effect, NEVER a Board constant (§4.B). Staleness +
# gate-disabled degrade per-field, NEVER all-or-nothing (§4.C/§4.D/§4.E).
# Empty-state ⇒ explicit "no telemetry yet" banner (§3.C), not a phantom ok.

# render_snap() pipes an arbitrary snapshot object (we craft these directly
# here, since the bash producer doesn't emit machine_state — that's CF.3 +
# the daemon's separate channel; the renderer just consumes the C3 shape).
render_snap() { printf '%s' "$1" | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    const BV=require(process.argv[1]);
    let snap; try{snap=JSON.parse(s);}catch(e){snap=s;}
    process.stdout.write(JSON.stringify(BV.deriveBoardView(snap)));
  });' "$VIEW"; }

# Minimal valid §4.5 snapshot wrapper: bound schema, no projects/lifecycle.
empty_snap='{"schema_version":1,"principal":"PRINCIPAL_V1","read_only":true,"projects":[],"lifecycle_columns":{},"waiting_on_you":[],"machines":[]}'

# §A canonical fixture entry: runner_id=macbook-pro.local, pct_5h=24, pct_7d=82,
# spare_ramp_today=56, threshold_in_effect=70, fresh=true, age_seconds=42.
fix='{"runner_id":"macbook-pro.local","observed_at":"2026-05-24T06:38:20Z","pct_5h":24,"pct_7d":82,"spare_ramp_today":56,"threshold_in_effect":70,"gate_disabled":false,"keychain_ok":true,"usage_api_ok":true,"fresh":true,"age_seconds":42}'

# ─ Fixture-driven render: one strip, expected text + bands ─
ONE_SNAP="$(jq -c --argjson m "$fix" '.machines=[$m]' <<<"$empty_snap")"
V8="$(render_snap "$ONE_SNAP")"
ck "fixture: deriveBoardView accepts a machines[] array (ok:true)" eq "$(jq -r '.ok' <<<"$V8")" "true"
ck "fixture: machines view has exactly one row"                    eq "$(jq -r '.machines|length' <<<"$V8")" "1"
ck "fixture: machines_empty=false when one row present"            eq "$(jq -r '.machines_empty' <<<"$V8")" "false"
M0="$(jq -c '.machines[0]' <<<"$V8")"
ck "fixture: runner_id surfaced verbatim"                          eq "$(jq -r '.runner_id' <<<"$M0")" "macbook-pro.local"
ck "fixture: pct_5h_text formatted as '24%'"                       eq "$(jq -r '.pct_5h_text' <<<"$M0")" "24%"
ck "fixture: pct_7d_text formatted as '82%'"                       eq "$(jq -r '.pct_7d_text' <<<"$M0")" "82%"
ck "fixture: ramp_text formatted as '56%'"                         eq "$(jq -r '.ramp_text' <<<"$M0")" "56%"
# §4.B bands at threshold 70: 0.5×T=35.
#   pct_5h=24 < 35           ⇒ green
#   ramp=56  ∈ [35,70)        — ramp is intentionally NEUTRAL (§4.B only bands pct_<n>)
#   pct_7d=82 ≥ 70            ⇒ red
ck "fixture: pct_5h band is green (24 < 35 = 0.5×70)"              eq "$(jq -r '.pct_5h_band' <<<"$M0")" "green"
ck "fixture: pct_7d band is red (82 ≥ 70)"                         eq "$(jq -r '.pct_7d_band' <<<"$M0")" "red"
ck "fixture: ramp band is neutral (§4.B only bands pct_<n>)"        eq "$(jq -r '.ramp_band' <<<"$M0")" "neutral"
# Fixture pct_7d=82 ≥ threshold=70 ⇒ <allowed>='(none — over)' (mirrors
# daemon/usage-poll.sh:_usage_poll_compute_allowed: pct ≥ T zeros allowed).
ck "fixture: <allowed> = '(none — over)' (pct_7d=82 ≥ T=70)"         eq "$(jq -r '.allowed_text' <<<"$M0")" "(none — over)"
ck "fixture: 'observed <age> ago' uses age_seconds (42s)"           eq "$(jq -r '.age_text' <<<"$M0")" "42s"
ck "fixture: composite strip_text matches §4.A format"              has "macbook-pro.local · 5h 24% · 7d 82% · ramp 56% · (none — over) · observed 42s ago" "$(jq -r '.strip_text' <<<"$M0")"
ck "fixture: fresh=true ⇒ no stale_label"                           eq "$(jq -r '.stale_label' <<<"$M0")" "null"
ck "fixture: gate enabled ⇒ no gate-disabled chip"                  eq "$(jq -r '.gate_disabled_chip' <<<"$M0")" "null"
ck "fixture: keychain_ok=true ⇒ no keychain chip"                   eq "$(jq -r '.keychain_chip' <<<"$M0")" "null"
ck "fixture: usage_api_ok=true ⇒ no api chip"                       eq "$(jq -r '.api_chip' <<<"$M0")" "null"
ck "fixture: all fields present ⇒ no 'partial' chip"                eq "$(jq -r '.partial_chip' <<<"$M0")" "null"

# ─ Stale render: fresh=false ⇒ grayed numbers + 'stale Nm ago' badge ─
stale_fix='{"runner_id":"macbook-pro.local","observed_at":"2026-05-24T06:00:00Z","pct_5h":24,"pct_7d":82,"spare_ramp_today":56,"threshold_in_effect":70,"gate_disabled":false,"keychain_ok":true,"usage_api_ok":true,"fresh":false,"age_seconds":1800}'
S_SNAP="$(jq -c --argjson m "$stale_fix" '.machines=[$m]' <<<"$empty_snap")"
MS="$(jq -c '.machines[0]' <<<"$(render_snap "$S_SNAP")")"
ck "stale: pct_5h band is 'stale' (grayed, NOT a color band)"      eq "$(jq -r '.pct_5h_band' <<<"$MS")" "stale"
ck "stale: pct_7d band is 'stale' (grayed)"                        eq "$(jq -r '.pct_7d_band' <<<"$MS")" "stale"
ck "stale: ramp band is 'stale' (grayed)"                          eq "$(jq -r '.ramp_band' <<<"$MS")" "stale"
ck "stale: stale_label present, names age"                         has "stale " "$(jq -r '.stale_label' <<<"$MS")"
ck "stale: stale_label uses the formatted age"                     has "30m" "$(jq -r '.stale_label' <<<"$MS")"
ck "stale: fresh=false propagates to view"                         eq "$(jq -r '.fresh' <<<"$MS")" "false"

# ─ Gate-disabled render: threshold=0 ⇒ neutral palette + 'gate disabled' chip,
#   strip MUST still render ─
gd_fix='{"runner_id":"macbook-pro.local","observed_at":"2026-05-24T06:38:20Z","pct_5h":24,"pct_7d":82,"spare_ramp_today":56,"threshold_in_effect":0,"gate_disabled":true,"keychain_ok":true,"usage_api_ok":true,"fresh":true,"age_seconds":42}'
GD_SNAP="$(jq -c --argjson m "$gd_fix" '.machines=[$m]' <<<"$empty_snap")"
GV="$(render_snap "$GD_SNAP")"
MGD="$(jq -c '.machines[0]' <<<"$GV")"
ck "gate-disabled: machines view STILL has one row (never voided)" eq "$(jq -r '.machines|length' <<<"$GV")" "1"
ck "gate-disabled: pct_5h band is neutral (un-banded)"             eq "$(jq -r '.pct_5h_band' <<<"$MGD")" "neutral"
ck "gate-disabled: pct_7d band is neutral (un-banded)"             eq "$(jq -r '.pct_7d_band' <<<"$MGD")" "neutral"
ck "gate-disabled: 'gate disabled' chip present"                   eq "$(jq -r '.gate_disabled_chip' <<<"$MGD")" "gate disabled"
ck "gate-disabled: gate_disabled flag exposed on row"              eq "$(jq -r '.gate_disabled' <<<"$MGD")" "true"
ck "gate-disabled: <allowed> = 'standard,low_priority' (all allowed)" eq "$(jq -r '.allowed_text' <<<"$MGD")" "standard,low_priority"
ck "gate-disabled: numbers STILL formatted (degrade per-field, not row)" eq "$(jq -r '.pct_5h_text' <<<"$MGD")" "24%"

# ─ Multi-machine: two entries ⇒ two rows, deterministic order (projection
#   sorts by runner_id; the renderer iterates in input order) ─
alpha_fix='{"runner_id":"alpha-host","observed_at":"2026-05-24T06:38:20Z","pct_5h":10,"pct_7d":20,"spare_ramp_today":80,"threshold_in_effect":70,"gate_disabled":false,"keychain_ok":true,"usage_api_ok":true,"fresh":true,"age_seconds":10}'
zeta_fix='{"runner_id":"zeta-host","observed_at":"2026-05-24T06:38:20Z","pct_5h":80,"pct_7d":90,"spare_ramp_today":40,"threshold_in_effect":70,"gate_disabled":false,"keychain_ok":true,"usage_api_ok":true,"fresh":true,"age_seconds":20}'
MULTI_SNAP="$(jq -c --argjson a "$alpha_fix" --argjson z "$zeta_fix" '.machines=[$a,$z]' <<<"$empty_snap")"
MV="$(render_snap "$MULTI_SNAP")"
ck "multi: two rows present"                                       eq "$(jq -r '.machines|length' <<<"$MV")" "2"
ck "multi: row 0 is alpha-host (projection-determined order kept)" eq "$(jq -r '.machines[0].runner_id' <<<"$MV")" "alpha-host"
ck "multi: row 1 is zeta-host"                                     eq "$(jq -r '.machines[1].runner_id' <<<"$MV")" "zeta-host"
ck "multi: alpha pct_5h band is green (10 < 35)"                   eq "$(jq -r '.machines[0].pct_5h_band' <<<"$MV")" "green"
ck "multi: zeta pct_5h band is red (80 ≥ 70)"                      eq "$(jq -r '.machines[1].pct_5h_band' <<<"$MV")" "red"
# zeta: pct_5h ≥ T ⇒ over ⇒ <allowed>='(none — over)'.
ck "multi: zeta <allowed> = '(none — over)' (over the cap)"         eq "$(jq -r '.machines[1].allowed_text' <<<"$MV")" "(none — over)"

# ─ Empty-state: machines=[] ⇒ machines_empty=true (banner present in DOM
#   via app.js render path); NOT silent. ─
EV="$(render_snap "$empty_snap")"
ck "empty: machines view is the empty array (NOT absent/null)"     eq "$(jq -r '.machines|length' <<<"$EV")" "0"
ck "empty: machines_empty flag is true (drives the §3.C banner)"   eq "$(jq -r '.machines_empty' <<<"$EV")" "true"

# ─ Per-runner pill removed (§4.F): grep app.js for 'rcap' / 'capacity:'
#   returns no LIVE render-side reference. Comments naming the removal are
#   legitimate and use distinguishing text; the live render path used the
#   className 'rcap' and the prefix "capacity: ", so we assert those are gone. ─
# The className token shouldn't appear in any code position. The only legitimate
# residual is the CSS deletion-marker comment; app.js + board-view.js must be clean.
ck "app.js no longer references the rcap className"                hasnt "rcap" "$(cat "$APP")"
ck "app.js no longer renders the 'capacity: ' pill text"           hasnt "'capacity: '" "$(cat "$APP")"
ck "board-view.js no longer emits capacity_verdict on rows"        hasnt "capacity_verdict:" "$(cat "$VIEW")"

# ─ Missing-field degrade (§4.E): a record without pct_5h still renders the
#   strip with '—' for that slot and a 'partial' chip; row is NOT collapsed. ─
miss_fix='{"runner_id":"missing-host","observed_at":"2026-05-24T06:38:20Z","pct_7d":50,"spare_ramp_today":60,"threshold_in_effect":70,"gate_disabled":false,"keychain_ok":true,"usage_api_ok":true,"fresh":true,"age_seconds":15}'
MS_SNAP="$(jq -c --argjson m "$miss_fix" '.machines=[$m]' <<<"$empty_snap")"
MM="$(jq -c '.machines[0]' <<<"$(render_snap "$MS_SNAP")")"
ck "missing-field: row STILL present (no all-or-nothing collapse)"  eq "$(jq -r '.runner_id' <<<"$MM")" "missing-host"
ck "missing-field: absent pct_5h ⇒ '—' (per-field degrade)"         eq "$(jq -r '.pct_5h_text' <<<"$MM")" "—"
ck "missing-field: absent pct_5h ⇒ band='missing' (no false color)" eq "$(jq -r '.pct_5h_band' <<<"$MM")" "missing"
ck "missing-field: pct_7d still rendered honestly"                  eq "$(jq -r '.pct_7d_text' <<<"$MM")" "50%"
ck "missing-field: 'partial' chip surfaces (breadcrumb)"            eq "$(jq -r '.partial_chip' <<<"$MM")" "partial"

# ─ keychain_ok/usage_api_ok breadcrumb chips (§4.C) ─
kc_fix='{"runner_id":"degraded-host","observed_at":"2026-05-24T06:38:20Z","pct_5h":24,"pct_7d":40,"spare_ramp_today":80,"threshold_in_effect":70,"gate_disabled":false,"keychain_ok":false,"usage_api_ok":false,"fresh":true,"age_seconds":12}'
KC_SNAP="$(jq -c --argjson m "$kc_fix" '.machines=[$m]' <<<"$empty_snap")"
KM="$(jq -c '.machines[0]' <<<"$(render_snap "$KC_SNAP")")"
ck "breadcrumb: keychain_ok=false ⇒ 'keychain unreadable' chip"     has "keychain" "$(jq -r '.keychain_chip' <<<"$KM")"
ck "breadcrumb: usage_api_ok=false ⇒ 'usage API failed' chip"       has "usage API" "$(jq -r '.api_chip' <<<"$KM")"
ck "breadcrumb: strip STILL renders the numbers (degrade, not collapse)" eq "$(jq -r '.pct_5h_text' <<<"$KM")" "24%"

# ─ STRUCTURAL — app.js + index.html wire the top-of-board strip; the empty
#   banner element exists in the shell so renderMachines can toggle it. ─
ck "index.html declares the #machines container"                   has 'id="machines"' "$(cat "$SHELL_HTML")"
ck "index.html declares the #ms-empty banner (no telemetry yet)"   has "no telemetry yet" "$(cat "$SHELL_HTML")"
ck "app.js exposes a renderMachines() pipeline"                    has "renderMachines" "$(cat "$APP")"
ck "app.js calls renderMachines with view.machines + machines_empty" has "view.machines" "$(cat "$APP")"
ck "board.css declares the .machines container"                    has ".machines{" "$(cat "$CSS")"
ck "board.css declares per-band classes (green/amber/red)"         has ".band-red" "$(cat "$CSS")"

echo "── EXIT-9: Q1 (claude-tools-uxvq1) — §9 queue_health strip (empty-queue + net-velocity) ──"
# queue_health is per-project (B.1); deriveBoardView aggregates the projects
# into the board-level view.queue_health strip + health-strip chips. The bash
# twin emits a ZEROED queue_health (no workspace_inventory store — CF fills the
# real values), so — like the machine-state EXIT-8 strip — we craft snapshots
# directly to exercise real queue_health values through the renderer.
qh_snap() {  # <ready> <gate> <dep> <sched> <hidden> <net> <epics-json-array>
  jq -cn --argjson ready "$1" --argjson gate "$2" --argjson dep "$3" \
         --argjson sched "$4" --argjson hidden "$5" --argjson net "$6" \
         --argjson epics "$7" \
    '{schema_version:1,principal:"PRINCIPAL_V1",read_only:true,
      lifecycle_columns:{},waiting_on_you:[],machines:[],
      projects:[{project_ref:"projQ",
        runner_state:{desired:"running",actual:"running",liveness:"live",
                      last_heartbeat_at:(now|todateiso8601),
                      current_task_ref:null,current_task_title:null,
                      desired_actual_mismatch:false},
        queue_health:{ready:$ready,held:{gate:$gate,dependency:$dep,scheduled:$sched},
                      hidden_under_deferred_parent:$hidden,net_velocity_7d:$net,
                      epics_with_zero_ready_children:$epics},
        lease:null}]}'
}

# ─ Runaway net-velocity (positive) ⇒ velocity_alarm + a 'bad' health chip ─
RUNAWAY="$(qh_snap 4 3 1 2 5 8 '["rg-aaa"]')"
VQ="$(render_snap "$RUNAWAY")"
ck "queue_health: board strip view present (ok:true)"            eq "$(jq -r '.ok' <<<"$VQ")" "true"
ck "queue_health: board-level aggregate exposed"                 eq "$(jq -r '.queue_health.ready' <<<"$VQ")" "4"
ck "queue_health: net_velocity_7d surfaced verbatim (COMPUTED, not a cutoff)" eq "$(jq -r '.queue_health.net_velocity_7d' <<<"$VQ")" "8"
ck "queue_health: positive net ⇒ velocity_alarm true (runaway, §9)" eq "$(jq -r '.queue_health.velocity_alarm' <<<"$VQ")" "true"
ck "queue_health: runaway surfaces a 'bad' health chip"           has "runaway" "$(jq -r '[.health.tags[]|select(.kind=="bad").text]|join(" ")' <<<"$VQ")"
ck "queue_health: velocity_text carries a signed number"          has "+8/7d net" "$(jq -r '.queue_health.velocity_text' <<<"$VQ")"
ck "queue_health: held_total = gate+dep+sched (3+1+2=6)"          eq "$(jq -r '.queue_health.held_total' <<<"$VQ")" "6"
ck "queue_health: epics-zero-ready count surfaced"               eq "$(jq -r '.queue_health.epics_zero_ready_count' <<<"$VQ")" "1"
ck "queue_health: epics-zero-ready surfaces a warn chip"          has "0-ready" "$(jq -r '[.health.tags[]|select(.kind=="warn").text]|join(" ")' <<<"$VQ")"
# per-project (B.1): the runner row carries its own queue_health.
RQ="$(jq -c '.runners[]|select(.project_ref=="projQ")' <<<"$VQ")"
ck "queue_health: per-project row carries queue_health (B.1)"     eq "$(jq -r '.queue_health.ready' <<<"$RQ")" "4"
ck "queue_health: per-project velocity_alarm set"                eq "$(jq -r '.queue_health.velocity_alarm' <<<"$RQ")" "true"

# ─ Empty queue (0 ready, work held) ⇒ empty_queue + a warn chip ─
EMPTY="$(qh_snap 0 2 1 0 3 -1 '[]')"
VE9="$(render_snap "$EMPTY")"
ck "queue_health: 0 ready + held/hidden ⇒ empty_queue true"       eq "$(jq -r '.queue_health.empty_queue' <<<"$VE9")" "true"
ck "queue_health: empty-queue explainer chip present (warn)"      has "0 ready" "$(jq -r '[.health.tags[]|select(.kind=="warn").text]|join(" ")' <<<"$VE9")"
ck "queue_health: negative net ⇒ NO velocity_alarm (draining)"    eq "$(jq -r '.queue_health.velocity_alarm' <<<"$VE9")" "false"
ck "queue_health: explainer names the held breakdown"            has "gate" "$(jq -r '.queue_health.explainer' <<<"$VE9")"

# ─ All-zero queue ⇒ NO empty-queue chip (no work at all is not an alarm) ─
ZERO="$(qh_snap 0 0 0 0 0 0 '[]')"
VZ="$(render_snap "$ZERO")"
ck "queue_health: all-zero ⇒ empty_queue false (no false alarm)"  eq "$(jq -r '.queue_health.empty_queue' <<<"$VZ")" "false"
ck "queue_health: all-zero ⇒ no velocity_alarm"                  eq "$(jq -r '.queue_health.velocity_alarm' <<<"$VZ")" "false"

# ─ Aggregate across TWO projects: net sums, epics union ─
TWO="$(jq -cn '{schema_version:1,principal:"PRINCIPAL_V1",read_only:true,
  lifecycle_columns:{},waiting_on_you:[],machines:[],
  projects:[
    {project_ref:"pA",runner_state:{desired:"running",actual:"running",liveness:"live",last_heartbeat_at:(now|todateiso8601),current_task_ref:null,current_task_title:null,desired_actual_mismatch:false},
     queue_health:{ready:1,held:{gate:1,dependency:0,scheduled:0},hidden_under_deferred_parent:0,net_velocity_7d:3,epics_with_zero_ready_children:["e1"]},lease:null},
    {project_ref:"pB",runner_state:{desired:"running",actual:"running",liveness:"live",last_heartbeat_at:(now|todateiso8601),current_task_ref:null,current_task_title:null,desired_actual_mismatch:false},
     queue_health:{ready:2,held:{gate:0,dependency:1,scheduled:0},hidden_under_deferred_parent:0,net_velocity_7d:5,epics_with_zero_ready_children:["e2"]},lease:null}
  ]}')"
VT="$(render_snap "$TWO")"
ck "queue_health: aggregate ready sums across projects (1+2=3)"  eq "$(jq -r '.queue_health.ready' <<<"$VT")" "3"
ck "queue_health: aggregate net_velocity sums (3+5=8)"           eq "$(jq -r '.queue_health.net_velocity_7d' <<<"$VT")" "8"
ck "queue_health: aggregate epics union (e1,e2 = 2)"             eq "$(jq -r '.queue_health.epics_zero_ready_count' <<<"$VT")" "2"

# ─ Missing queue_health block ⇒ tolerant zeroed view (render-tolerance) ─
NOQH="$(jq -cn '{schema_version:1,principal:"PRINCIPAL_V1",read_only:true,
  lifecycle_columns:{},waiting_on_you:[],machines:[],
  projects:[{project_ref:"pNo",runner_state:{desired:"running",actual:"running",liveness:"live",last_heartbeat_at:(now|todateiso8601),current_task_ref:null,current_task_title:null,desired_actual_mismatch:false},lease:null}]}')"
VN="$(render_snap "$NOQH")"
ck "queue_health: absent block ⇒ tolerant zeroed view (ok:true)" eq "$(jq -r '.ok' <<<"$VN")" "true"
ck "queue_health: absent block ⇒ per-project row still has block" eq "$(jq -r '.runners[0].queue_health.ready' <<<"$VN")" "0"

# ─ STRUCTURAL — app.js + index.html + css wire the §9 strip ─
ck "index.html declares the #qh queue-health container"          has 'id="qh"' "$(cat "$SHELL_HTML")"
ck "app.js exposes a renderQueueHealth() painter"                has "renderQueueHealth" "$(cat "$APP")"
ck "app.js paints the board-level view.queue_health"             has "view.queue_health" "$(cat "$APP")"
ck "app.js renders the per-runner r.queue_health line"           has "r.queue_health" "$(cat "$APP")"
ck "board.css declares the .qh strip container"                  has ".qh{" "$(cat "$CSS")"
ck "board.css declares the runaway .qh-vel.alarm style"          has ".qh-vel.alarm" "$(cat "$CSS")"

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " test-board (T6a + F2 8fh + C4 zdxd.5 + Q1 uxvq1):  PASS=$PASS  FAIL=$FAIL"
echo "══════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
