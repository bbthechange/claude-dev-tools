#!/bin/bash
# beads-runner/lib/test-ready-to-pair.sh — focused unit test for N3
# READY-TO-PAIR (claude-tools-uxg6): the reserved `kind:"pair"` discriminator
# realized as a SCHEDULED collaborative-stage session, armed on the §2.2 timer
# with a SURFACE (not auto-proceed) fire-action. DESIGN N §4
# (design/notifications.md).
#
# The bash oracle for cf/src/timer.js pairArm/pairSurface (the differential
# twin cf/test/ready-to-pair.spec.js drives the SAME scenarios through the real
# engine). Exercises ONLY the pair fire-action on timed-fyi.sh, consuming the
# §2.2 timer surface + the N1 catalog spine (notif_fire) + the T5.1 store as
# black boxes, and the WORK-plane `bd` via a PATH-injected logging fake (the
# test-timed-fyi.sh / conformance pattern).
#
# Asserts the EXIT CRITERIA N3 owns against DESIGN N §4 + INTERFACE.md v1:
#   A. pair_arm arms the §2.2 fire(dossier_id) at the envelope `scheduled_at`
#      (DUE after, not before); a non-pair dossier / missing|unparseable
#      scheduled_at / no bearer is REJECTED, fail-closed (NO timer).
#   B. SURFACE ≠ auto-proceed. Before surface NO §4.3 notification exists (so
#      N2 cannot push early — the "upcoming" state). pair_surface fires the
#      blocking `ready_to_pair` notification (tier=blocking, PENDING for N2)
#      and applies NO item / NO §5.3 consequence (a pair envelope is not
#      iterated as §5 Items — §4.2).
#   C. The shared timer-due poll ROUTES by kind: a due pair SURFACES; a due
#      timed-fyi AUTO-PROCEEDS (the existing handler), in ONE poll.
#   D. Idempotent: re-surfacing (S-6 re-poll, no ack at fire) keeps ONE
#      notification (one-per-Dossier) and applies nothing twice.
#   E. Anti-drift: pair_arm/pair_surface are NOT §2 capabilities; NO §4 record
#      type 'pair' added (pair rides the dossier type + the §2.2 timers ns).
#
# Self-contained: its own CO_STORE + fake-bin under mktemp; shares NO state.
set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/timed-fyi.sh"
[[ -f "$LIB" ]] || { echo "FATAL: timed-fyi.sh not found at $LIB"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
ck()  { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }   # expect SUCCESS
ckn() { if "${@:2}" >/dev/null 2>&1; then bad "$1"; else ok "$1"; fi; }   # expect FAILURE
eq()  { [[ "$1" == "$2" ]]; }
ne()  { [[ "$1" != "$2" ]]; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CO_STORE="$WORK/store"
unset CO_EXPECTED_TOKEN PRINCIPAL_V1 TIMED_FYI_DEFAULT 2>/dev/null || true

# ── work-plane `bd` fake on PATH (conformance / test-timed-fyi pattern) ───────
FAKEBIN="$WORK/bin"; mkdir -p "$FAKEBIN"
export BD_LOG="$WORK/bd.log"; : > "$BD_LOG"
cat > "$FAKEBIN/bd" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${BD_LOG:-/dev/null}"
if [[ "${1:-}" == "create" ]]; then
  t=""; while [[ $# -gt 0 ]]; do case "$1" in --title) t="$2"; shift 2;; --title=*) t="${1#--title=}"; shift;; *) shift;; esac; done
  n=$(( $(wc -l < "${BD_LOG:-/dev/null}" 2>/dev/null || echo 0) ))
  echo "✓ Created issue: bd-fake-$n — $t"
fi
exit 0
EOF
chmod +x "$FAKEBIN/bd"
export PATH="$FAKEBIN:$PATH"

# shellcheck source=/dev/null
source "$LIB"           # → consequence.sh → dossier.sh → coordinator.sh + notification.sh

GOOD="bearer-runner-secret-xyz"
GET()    { co_request "$GOOD" get dossier "$1" 2>/dev/null; }
ISTATE() { GET "$1" | jq -r --arg i "$2" '.items[]|select(.id==$i).state'              2>/dev/null; }
ICA()    { GET "$1" | jq -r --arg i "$2" '.items[]|select(.id==$i).consequence_applied' 2>/dev/null; }
NOTIF()  { co_request "$GOOD" get notification "notif.$1" 2>/dev/null; }                 # raw §4.3 row | ""
NHAS()   { [[ -n "$(NOTIF "$1")" ]]; }                                                   # a notif row exists
NTIER()  { NOTIF "$1" | jq -r '.tier'       2>/dev/null; }
NDISP()  { NOTIF "$1" | jq -r '.dispatched' 2>/dev/null; }
BDN()    { local c; c=$(grep -c -- "$1" "$BD_LOG" 2>/dev/null); echo "${c:-0}"; }
DUE()    { co_request "$GOOD" timer-due "${2:-}" 2>/dev/null | grep -Fxq -- "$1"; }      # DUE <id> [now]
PSF()    { GET "$1" | jq -r '.pair_surfaced_for // ""' 2>/dev/null; }                    # the 7n5c one-shot re-ping marker

CA="2026-05-16T00:00:00Z"
SCHED="2026-05-16T15:00:00Z"   # the appointment
FAR="2026-06-01T00:00:00Z"     # well past the appointment
NEAR="2026-05-16T12:00:00Z"    # before the appointment

# §4.1 kind:"pair" SESSION CARD — tier blocking (§10.2 r10), a `scheduled_at`
# appointment, a conformant §5 body, NOT iterated as response Items (§4.2). One
# fyi-objectable item is carried ONLY to PROVE surface applies nothing.
cb() { jq -cn --arg t "$1" '
  { cb_schema_version:2, creates:[{title:("new "+$t),type:"task",priority:2,labels:["auto"],description:"d"}],
    unblocks:["unb-"+$t], labels:[], status_changes:[] }'; }
item_obj() { jq -cn --arg i "$1" --argjson cb "$(cb "$1")" '
  { id:$i, kind:"fyi-objectable", framing:{}, context_anchor:{where:"x",expansion:"y"},
    consequence_block:$cb, reversible:"r", state:"open", response:null,
    consequence_applied:false, applied_at:null }'; }
mkpair() {  # mkpair <id> <scheduled_at|""> [items-json]
  jq -cn --arg id "$1" --arg sa "$2" --argjson items "${3:-[]}" --arg ca "$CA" '
    { id:$id, schema_version:2, kind:"pair", trigger:"proactive_checkpoint",
      bead_ref:"claude-tools-uxg6", tier:"blocking",
      created_at:$ca, timer_fire_at:null }
    + (if $sa=="" then {} else {scheduled_at:$sa} end)
    + { body:{ dossier_schema_version:2, tldr:"pair on the activity blueprint",
               sections:[], diagrams:[], full_detail:"a scheduled working session" },
        items:$items }'; }
mkdecide() {  # a normal kind:"decide" dossier (pair_arm must reject it)
  jq -cn --arg id "$1" --arg ca "$CA" '
    { id:$id, schema_version:2, kind:"decide", trigger:"proactive_checkpoint",
      bead_ref:"claude-tools-uxg6", tier:"blocking", created_at:$ca, timer_fire_at:null,
      scheduled_at:"2026-05-16T15:00:00Z",
      body:{ dossier_schema_version:2, tldr:"x", sections:[], diagrams:[], full_detail:"y" },
      items:[] }'; }

echo "── EXIT-A: pair_arm arms the §2.2 timer @ scheduled_at; bad input rejected ──"
do_dossier_put "$GOOD" "$(mkpair dP1 "$SCHED" "[$(item_obj p1)]")" >/dev/null
FA="$(pair_arm "$GOOD" dP1)"
ck  "pair_arm succeeds"                                 test -n "$FA"
ck  "pair_arm echoes the scheduled_at as fire_at"       eq "$FA" "$SCHED"
ck  "§2.2 timer armed keyed fire(dossier_id)=dP1, due AFTER scheduled_at" DUE dP1 "$FAR"
ckn "NOT due BEFORE scheduled_at (upcoming, not ready)" DUE dP1 "$NEAR"
# pair_arm writes NO envelope field (scheduled_at is the producer's; no timer_fire_at)
ck  "pair_arm did NOT write timer_fire_at (scheduled_at is the pair's own field)" \
   eq "$(GET dP1 | jq -r '.timer_fire_at')" "null"
# a non-pair dossier is REJECTED
do_dossier_put "$GOOD" "$(mkdecide dDec)" >/dev/null
ckn "pair_arm on a kind:'decide' dossier REJECTED"      pair_arm "$GOOD" dDec
ckn "rejected non-pair armed NO timer"                  DUE dDec "$FAR"
# missing scheduled_at REJECTED, fail-closed
do_dossier_put "$GOOD" "$(mkpair dNo "" "[]")" >/dev/null
ckn "pair_arm on a pair with NO scheduled_at REJECTED"  pair_arm "$GOOD" dNo
ckn "missing-scheduled_at armed NO timer"               DUE dNo "$FAR"
# unparseable scheduled_at REJECTED
do_dossier_put "$GOOD" "$(mkpair dBad "not-a-date" "[]")" >/dev/null
ckn "pair_arm with unparseable scheduled_at REJECTED"   pair_arm "$GOOD" dBad
# missing dossier / no bearer rejected (§9.1, no second auth path)
ckn "pair_arm on a MISSING dossier REJECTED"            pair_arm "$GOOD" nodoss
ckn "pair_arm with NO bearer REJECTED (§9.1)"           pair_arm "" dP1

echo ""
echo "── EXIT-B: SURFACE ≠ auto-proceed (upcoming→ready fires the blocking notif) ──"
ckn "BEFORE surface: NO §4.3 notification exists (cannot push early — upcoming)" NHAS dP1
: > "$BD_LOG"
NID="$(pair_surface "$GOOD" dP1)"
ck  "pair_surface succeeds"                             test -n "$NID"
ck  "AFTER surface: a §4.3 notification now exists for the pair dossier"  NHAS dP1
ck  "the surfaced notification is tier 'blocking' (§10.2 r10 — N2 pushes it)" \
   eq "$(NTIER dP1)" "blocking"
ck  "the blocking notification is left PENDING (dispatched=false; N2's latch)" \
   eq "$(NDISP dP1)" "false"
ck  "SURFACE applied NO item — p1 stays OPEN (not iterated as §5 Items — §4.2)" \
   eq "$(ISTATE dP1 p1)" "open"
ck  "p1 latch still false (NO §7.4 auto-apply on a pair surface)" eq "$(ICA dP1 p1)" "false"
ck  "NO §5.3 consequence applied (no bd create — surface is not auto-proceed)" \
   eq "$(BDN 'create --title new p1')" "0"

echo ""
echo "── EXIT-C: the shared timer-due poll ROUTES by kind (pair vs timed-fyi) ──"
# A fresh pair (armed) + a timed-fyi (armed) both come DUE; ONE poll must
# SURFACE the pair (fire its notif, apply nothing) AND auto-proceed the fyi.
do_dossier_put "$GOOD" "$(mkpair dP2 "$SCHED" "[$(item_obj q1)]")" >/dev/null
pair_arm "$GOOD" dP2 >/dev/null
# a timed-fyi dossier (the existing handler's territory)
mkfyi() { jq -cn --arg id "$1" --argjson it "$2" --arg ca "$CA" '
  { id:$id, schema_version:2, kind:"decide", trigger:"proactive_checkpoint",
    bead_ref:"claude-tools-uxg6", tier:"timed-fyi", created_at:$ca, timer_fire_at:null,
    body:{ dossier_schema_version:2, tldr:"x", sections:[], diagrams:[], full_detail:"y" },
    items:[$it] }'; }
do_dossier_put "$GOOD" "$(mkfyi dY1 "$(item_obj y1)")" >/dev/null
tf_arm "$GOOD" dY1 >/dev/null
: > "$BD_LOG"
POLLED="$(tf_poll "$GOOD" "$FAR")"
ck  "poll surfaced the pair dP2 (in the fired list)"    grep -Fxq -- dP2 <<<"$POLLED"
ck  "poll surfaced the timed-fyi dY1 (in the fired list)" grep -Fxq -- dY1 <<<"$POLLED"
ck  "ROUTED: pair dP2 fired its blocking ready_to_pair notification"  NHAS dP2
ck  "ROUTED: pair dP2 SURFACED — its item q1 left OPEN (no auto-proceed)" eq "$(ISTATE dP2 q1)" "open"
ck  "ROUTED: pair dP2 applied NO §5.3 consequence (no bd create for q1)" eq "$(BDN 'create --title new q1')" "0"
ck  "ROUTED: timed-fyi dY1 AUTO-PROCEEDED — y1 applied"  eq "$(ISTATE dY1 y1)" "applied"
ck  "ROUTED: timed-fyi dY1 applied its §5.3 consequence (bd create for y1)" eq "$(BDN 'create --title new y1')" "1"
ckn "a pair surface NEVER fires a ready_to_pair notif for the timed-fyi (only blocking)" \
   eq "$(NTIER dY1)" "blocking"

echo ""
echo "── EXIT-D: idempotent re-surface (S-6 re-poll, no ack at fire) ──"
# dP1 was surfaced once in EXIT-B; surface again + re-poll → still ONE notif,
# nothing applied twice (one-per-Dossier; notif_fire emit is idempotent).
: > "$BD_LOG"
NID2="$(pair_surface "$GOOD" dP1)"
ck  "re-surface succeeds (idempotent)"                  test -n "$NID2"
ck  "re-surface binds the SAME notification id (one-per-Dossier)" eq "$NID2" "$NID"
ck  "re-surface kept the notification PENDING (dispatched still false)" eq "$(NDISP dP1)" "false"
tf_poll "$GOOD" "$FAR" >/dev/null 2>&1
ck  "re-poll still applied NO consequence (surface never auto-proceeds)" \
   eq "$(BDN 'create --title new p1')" "0"
ck  "p1 still OPEN after re-poll (idempotent surface)"  eq "$(ISTATE dP1 p1)" "open"

echo ""
echo "── EXIT-REPING: the one-shot pair_surfaced_for re-ping marker (7n5c) ──"
# The guard that lets a RE-SCHEDULED pair re-ping the phone EXACTLY once without
# the per-poll storm a naive deliver-once eviction would cause. The push ledger
# is CF-only (no bash twin — h8e6); bash mirrors only the MARKER state machine
# (the above-INTERFACE half, so the differential stays equal): stamped on the
# first surface, unchanged on a same-appointment re-poll, wiped by a re-schedule
# (producer re-put), re-stamped on the next surface. The CF twin ALSO evicts the
# CF.9 row on each (re)stamp — proven in cf/test/push.spec.js.
do_dossier_put "$GOOD" "$(mkpair dRP "$SCHED" "[$(item_obj rp1)]")" >/dev/null
pair_arm "$GOOD" dRP >/dev/null
ck  "BEFORE any surface: NO pair_surfaced_for marker"   eq "$(PSF dRP)" ""
pair_surface "$GOOD" dRP >/dev/null
ck  "first surface STAMPS pair_surfaced_for = scheduled_at (re-ping armed→consumed)" eq "$(PSF dRP)" "$SCHED"
ck  "first surface left rp1 OPEN (surface never auto-proceeds)" eq "$(ISTATE dRP rp1)" "open"
pair_surface "$GOOD" dRP >/dev/null
ck  "a same-appointment re-poll keeps the SAME marker (no per-poll re-arm → no storm)" eq "$(PSF dRP)" "$SCHED"
# RE-SCHEDULE: the producer re-puts with a NEW scheduled_at, wiping the stale marker.
SCHEDR="2026-05-16T20:00:00Z"
do_dossier_put "$GOOD" "$(mkpair dRP "$SCHEDR" "[$(item_obj rp1)]")" >/dev/null
ck  "a re-schedule (producer re-put) WIPED the stale marker"  eq "$(PSF dRP)" ""
pair_surface "$GOOD" dRP >/dev/null
ck  "the re-scheduled surface RE-STAMPS the marker to the new appointment" eq "$(PSF dRP)" "$SCHEDR"
pair_surface "$GOOD" dRP >/dev/null
ck  "steady-state re-poll at the new appointment keeps the new marker" eq "$(PSF dRP)" "$SCHEDR"

echo ""
echo "── EXIT-PROJ: a kind:'pair' card surfaces in the §4.5 lane (0 items) + scheduled_at ──"
# A 0-item pair SESSION CARD (not iterated as §5 Items — §4.2) MUST still
# surface in waiting_on_you (visibility by kind, DESIGN N §4.4), carrying the
# scheduled_at the Inbox renders upcoming→ready off. A 0-item NON-pair dossier
# stays HIDDEN (the open-item gate still holds for everything but pair).
do_dossier_put "$GOOD" "$(mkpair dPV "$SCHED" "[]")" >/dev/null
do_dossier_put "$GOOD" "$(mkdecide dNV0)" >/dev/null   # kind:decide, items:[] (0 open)
SNAP="$(co_request "$GOOD" work-snapshot projA '[]' 2>/dev/null)"
ck  "a 0-item kind:'pair' card APPEARS in waiting_on_you (visibility by kind)" \
   eq "$(jq -r '[.waiting_on_you[]|select(.dossier_id=="dPV")]|length' <<<"$SNAP")" "1"
ck  "the pair lane entry carries kind:'pair'" \
   eq "$(jq -r '.waiting_on_you[]|select(.dossier_id=="dPV").kind' <<<"$SNAP")" "pair"
ck  "the pair lane entry carries scheduled_at (the appointment — §4.4)" \
   eq "$(jq -r '.waiting_on_you[]|select(.dossier_id=="dPV").scheduled_at' <<<"$SNAP")" "$SCHED"
ck  "the pair lane entry's open_item_count is 0 (a session card, not a form)" \
   eq "$(jq -r '.waiting_on_you[]|select(.dossier_id=="dPV").open_item_count' <<<"$SNAP")" "0"
ck  "a 0-item kind:'decide' dossier is NOT in the lane (the open-item gate holds)" \
   eq "$(jq -r '[.waiting_on_you[]|select(.dossier_id=="dNV0")]|length' <<<"$SNAP")" "0"

echo ""
echo "── EXIT-PROD: the PRODUCER (pair_create) creates a kind:'pair' card + arms it, end-to-end (N10-10) ──"
# N10-10 (claude-tools-l6vx): the producer N3 left as a follow-up. ONE call
# builds the canonical kind:"pair" SESSION CARD AND arms the §2.2 timer at
# scheduled_at; the EXISTING uxg6/N3 path (timer-due → pair_surface → §4.3
# blocking notif + §4.5 lane visibility) then carries it through UNCHANGED.
: > "$BD_LOG"
PD="$(pair_create "$GOOD" claude-tools-l6vx "$SCHED" "pair on the producer")"
ck  "pair_create succeeds, echoes the deterministic id"     eq "$PD" "pair-claude-tools-l6vx"
ck  "the produced dossier exists with kind:'pair'"          eq "$(GET "$PD" | jq -r '.kind')" "pair"
ck  "produced tier is 'blocking' (§10.2 r10)"               eq "$(GET "$PD" | jq -r '.tier')" "blocking"
ck  "produced trigger is 'proactive_checkpoint' (N3 fixture shape)" eq "$(GET "$PD" | jq -r '.trigger')" "proactive_checkpoint"
ck  "produced carries the scheduled_at appointment"         eq "$(GET "$PD" | jq -r '.scheduled_at')" "$SCHED"
ck  "produced is a 0-item SESSION CARD (not a form — §4.2)" eq "$(GET "$PD" | jq -r '.items|length')" "0"
ck  "produced body tldr is the session topic"               eq "$(GET "$PD" | jq -r '.body.tldr')" "pair on the producer"
ck  "produced wrote NO timer_fire_at (scheduled_at is the pair's field)" eq "$(GET "$PD" | jq -r '.timer_fire_at')" "null"
ck  "PRODUCER armed the §2.2 timer — DUE after scheduled_at"  DUE "$PD" "$FAR"
ckn "NOT due BEFORE scheduled_at (upcoming, not ready)"      DUE "$PD" "$NEAR"
ckn "BEFORE its appointment: NO §4.3 notification (upcoming — N2 cannot push early)" NHAS "$PD"
# the produced card flows through the EXISTING uxg6/N3 surface path UNCHANGED:
NIDP="$(pair_surface "$GOOD" "$PD")"
ck  "produced card SURFACES through the N3 path (blocking ready_to_pair notif fires)" NHAS "$PD"
ck  "surfaced producer notif is tier 'blocking'"           eq "$(NTIER "$PD")" "blocking"
ck  "produced card applied NO §5.3 consequence (a session card, not a decide)" eq "$(BDN 'create')" "0"
# the produced card is visible in the §4.5 lane (visibility by kind)
SNAPP="$(co_request "$GOOD" work-snapshot projA '[]' 2>/dev/null)"
ck  "produced card APPEARS in waiting_on_you with kind:'pair' + scheduled_at" \
   eq "$(jq -r --arg id "$PD" '.waiting_on_you[]|select(.dossier_id==$id)|.kind+"|"+.scheduled_at' <<<"$SNAPP")" "pair|$SCHED"
# producer rejects, fail-closed (NO dossier): missing bead_ref / bad scheduled_at / unsafe id
ckn "pair_create REJECTS a missing bead_ref"               pair_create "$GOOD" "" "$SCHED"
ckn "pair_create REJECTS an unparseable scheduled_at"      pair_create "$GOOD" claude-tools-l6vx "not-a-date"
ckn "pair_create REJECTS an unsafe dossier id"             pair_create "$GOOD" claude-tools-l6vx "$SCHED" "t" "fd" "../evil"
# idempotent re-create = re-schedule (deterministic id; overwrites the same card)
SCHED2="2026-05-16T18:00:00Z"
PD2="$(pair_create "$GOOD" claude-tools-l6vx "$SCHED2")"
ck  "re-create returns the SAME deterministic id"          eq "$PD2" "$PD"
ck  "re-create RE-SCHEDULED the appointment (scheduled_at updated)" eq "$(GET "$PD" | jq -r '.scheduled_at')" "$SCHED2"

echo ""
echo "── EXIT-E: binds §2.2/§10.2 · anti-drift (structural) ──"
ck  "§4 registry dossier⇒2 (pair added NO record type; rides the dossier type)" eq "$(co__schema_version dossier)" "2"
ck  "NO §4 record type added — 'pair' unregistered"     eq "$(co__schema_version pair)" ""
caps="$(co_capabilities 2>/dev/null || true)"
ckn "pair_arm is NOT advertised as a §2 capability"     grep -q 'pair_arm' <<<"$caps"
ckn "pair_surface is NOT advertised as a §2 capability" grep -q 'pair_surface' <<<"$caps"
# ready_to_pair is a §10.2 catalog trigger bound to 'blocking' (N1) — pair just fires it
ck  "ready_to_pair is the §10.2 r10 trigger bound to 'blocking'" \
   eq "$(notif_trigger_tiers ready_to_pair)" "blocking"

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " test-ready-to-pair (N3, claude-tools-uxg6):  PASS=$PASS  FAIL=$FAIL"
echo "══════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
