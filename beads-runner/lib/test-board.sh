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
PROXY="$HERE/../web/board/functions/api/board.js"
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
co_request "$GOOD" put dossier dOpen \
  '{"schema_version":2,"id":"dOpen","bead_ref":"claude-tools-99","tier":"blocking","items":[{"id":"i1","state":"open"},{"id":"i2","state":"applied"}]}' >/dev/null 2>&1
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
ck "machine reads HEALTHY (no stale/mismatch/failure)"           eq "$(jq -r '.health.ok' <<<"$V")" "true"

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

echo "── EXIT-3: NO Dolt write path — proven by STRUCTURE ──"
# The renderer is a pure function: no network, no mutation primitive at all.
ck "board-view.js makes NO network call (no fetch/XHR)"      hasnt "fetch(" "$(cat "$VIEW")"
ck "board-view.js has no write/POST verb"                    hasnt "POST" "$(cat "$VIEW")"
# The client app's ONLY call is a credential-less GET; no mutation verb.
ck "app.js issues a GET (read) ..."                          has "method: 'GET'" "$(cat "$APP")"
ck "... and NO POST/PUT/PATCH/DELETE anywhere"               hasnt "method: 'POST'" "$(cat "$APP")"
ck "app.js never sends a body (no write payload)"            hasnt "body:" "$(cat "$APP")"
# The Pages read proxy: GET-only handler + the §4.5 read op hard-coded.
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

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " test-board (T6a, claude-tools-p2m):  PASS=$PASS  FAIL=$FAIL"
echo "══════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
