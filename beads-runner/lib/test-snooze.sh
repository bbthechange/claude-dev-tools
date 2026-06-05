#!/bin/bash
# beads-runner/lib/test-snooze.sh — focused unit test for the §5.6 SNOOZE verb
# (claude-tools-653d): the §5.6 verb family's third member — DEFER a blocking
# decision card NOW + arm the §2.2 timer to RE-SURFACE it (NOT auto-proceed) at a
# user-set snooze_until. The bash oracle for cf/src/timer.js dossierSnooze /
# snoozeSurface (the differential twin cf/test/snooze.spec.js drives the SAME
# scenarios through the real engine). Consumes the §2.2 timer surface + the N1
# catalog spine (notif_fire) + the T5.1 store as black boxes, and the WORK-plane
# `bd` via a PATH-injected logging fake (the test-ready-to-pair.sh pattern).
#
# Asserts the EXIT CRITERIA snooze owns:
#   A. do_dossier_snooze DEFERS (tier→digest) + writes timer_fire_at AND the
#      snoozed_until routing discriminator = snooze_until + arms the §2.2 timer
#      (DUE after, not before); items untouched; a missing dossier / no id /
#      missing|unparseable|PAST snooze_until / no bearer is REJECTED, fail-closed
#      (NO write, NO timer).
#   B. SURFACE ≠ auto-proceed. snooze_surface RE-tiers digest→blocking, CLEARS the
#      snooze fields, fires the blocking `new_dossier` notif, and applies NO item /
#      NO §5.3 consequence. A no-longer-snoozed card is a no-op success.
#   C. The shared timer-due poll ROUTES a snoozed card to SURFACE; a due timed-fyi
#      still AUTO-PROCEEDS (the existing handler), in ONE poll.
#   D. Idempotent: a re-poll after the surface applies nothing more.
#   E. Anti-drift: do_dossier_snooze/snooze_surface are NOT §2 capabilities; the
#      re-surface fires the §10.2 r1 `new_dossier` (blocking) trigger; NO §4
#      record type added (snooze rides the dossier type + the §2.2 timers ns).
#
# Self-contained: its own CO_STORE + fake-bin under mktemp; shares NO state.
# NOTE: snooze_until must be in the FUTURE of the REAL wall clock (do_dossier_snooze
# fails-closed on a past instant), so the fixtures pin it to the far future (2099).
set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/timed-fyi.sh"
[[ -f "$LIB" ]] || { echo "FATAL: timed-fyi.sh not found at $LIB"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
ck()  { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }   # expect SUCCESS
ckn() { if "${@:2}" >/dev/null 2>&1; then bad "$1"; else ok "$1"; fi; }   # expect FAILURE
eq()  { [[ "$1" == "$2" ]]; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CO_STORE="$WORK/store"
unset CO_EXPECTED_TOKEN PRINCIPAL_V1 TIMED_FYI_DEFAULT 2>/dev/null || true

# ── work-plane `bd` fake on PATH (test-ready-to-pair pattern) ─────────────────
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
TFA()    { GET "$1" | jq -r '.timer_fire_at' 2>/dev/null; }
SNZU()   { GET "$1" | jq -r '.snoozed_until // "null"' 2>/dev/null; }
NOTIF()  { co_request "$GOOD" get notification "notif.$1" 2>/dev/null; }                 # raw §4.3 row | ""
NHAS()   { [[ -n "$(NOTIF "$1")" ]]; }
NTIER()  { NOTIF "$1" | jq -r '.tier' 2>/dev/null; }
BDN()    { local c; c=$(grep -c -- "$1" "$BD_LOG" 2>/dev/null); echo "${c:-0}"; }
DUE()    { co_request "$GOOD" timer-due "${2:-}" 2>/dev/null | grep -Fxq -- "$1"; }      # DUE <id> [now]

NEAR="2099-05-01T00:00:00Z"   # before the snooze fires
SNZ="2099-06-01T00:00:00Z"    # snooze_until (the re-surface time)
FAR="2099-07-01T00:00:00Z"    # well past snooze_until (poll fires it)

cb() { jq -cn --arg t "$1" '
  { cb_schema_version:2, creates:[{title:("new "+$t),type:"task",priority:2,labels:["auto"],description:"d"}],
    unblocks:[], labels:[], status_changes:[] }'; }
item_open() { jq -cn --arg i "$1" --argjson cb "$(cb "$1")" '
  { id:$i, kind:"fyi-objectable", framing:{}, context_anchor:{where:"x",expansion:"y"},
    consequence_block:$cb, reversible:"r", state:"open", response:null,
    consequence_applied:false, applied_at:null }'; }
item_ans() { jq -cn --arg i "$1" --argjson cb "$(cb "$1")" '
  { id:$i, kind:"approve-reject", framing:{}, context_anchor:{where:"x",expansion:"y"},
    consequence_block:$cb, reversible:"r", state:"answered",
    response:{decision:"approve",responded_at:"2026-05-30T01:00:00Z",principal:"brian"},
    consequence_applied:false, applied_at:null }'; }
mkdecide() {  # mkdecide <id> <bref> <items-json>  — a BLOCKING decision card
  jq -cn --arg id "$1" --arg br "$2" --argjson items "$3" '
    { id:$id, schema_version:2, kind:"decide", trigger:"worker_stuck",
      bead_ref:$br, tier:"blocking", created_at:"2026-05-30T00:00:00Z", timer_fire_at:null,
      body:{ dossier_schema_version:2, tldr:"t", sections:[], diagrams:[], full_detail:"f" },
      items:$items }'; }
mkfyi() {  # a timed-fyi (auto-proceed lane) dossier; far-future created_at so
           # tf_arm's computed fire_at (created_at+86400) is also future.
  jq -cn --arg id "$1" --argjson it "$2" '
    { id:$id, schema_version:2, kind:"decide", trigger:"proactive_checkpoint",
      bead_ref:"thirsty-653d-fyi", tier:"timed-fyi", created_at:"2099-05-30T00:00:00Z", timer_fire_at:null,
      body:{ dossier_schema_version:2, tldr:"x", sections:[], diagrams:[], full_detail:"y" },
      items:[$it] }'; }

echo "── EXIT-A: do_dossier_snooze defers + arms the §2.2 re-surface timer @ snooze_until ──"
do_dossier_put "$GOOD" "$(mkdecide snz-d1 thirsty-653d-a "[$(item_open open1),$(item_ans ans1)]")" >/dev/null
: > "$BD_LOG"
SU="$(do_dossier_snooze "$GOOD" snz-d1 "$SNZ")"
ck  "do_dossier_snooze succeeds, echoes snooze_until"        eq "$SU" "$SNZ"
ck  "snooze set tier→digest (deferred out of the foreground)" eq "$(GET snz-d1 | jq -r '.tier')" "digest"
ck  "snooze wrote timer_fire_at = snooze_until"             eq "$(TFA snz-d1)" "$SNZ"
ck  "snooze wrote snoozed_until = snooze_until (routing discriminator)" eq "$(SNZU snz-d1)" "$SNZ"
ck  "§2.2 timer armed fire(dossier_id)=snz-d1, DUE after snooze_until" DUE snz-d1 "$FAR"
ckn "NOT due BEFORE snooze_until (snoozed, not yet re-surfaced)" DUE snz-d1 "$NEAR"
ck  "snooze left the OPEN item untouched (no resolution)"   eq "$(ISTATE snz-d1 open1)" "open"
ck  "snooze left the ANSWERED item untouched (recommendation NOT consumed)" eq "$(ISTATE snz-d1 ans1)" "answered"
ck  "snooze preserved the recorded .response verbatim"      eq "$(GET snz-d1 | jq -r '.items[]|select(.id=="ans1").response.decision')" "approve"
ck  "snooze fired NO work-plane ConsequenceBlock op"        eq "$(BDN 'create')" "0"
# re-snooze to a LATER time re-schedules (NOT idempotent — always re-arms)
SNZ2="2099-06-15T00:00:00Z"
ck  "re-snooze to a later time succeeds (re-schedule)"      do_dossier_snooze "$GOOD" snz-d1 "$SNZ2"
ck  "re-snooze updated snoozed_until + timer_fire_at"       eq "$(SNZU snz-d1)|$(TFA snz-d1)" "$SNZ2|$SNZ2"
# rejections — fail-closed (NO write, NO timer)
ckn "snooze on a missing dossier REJECTED"                  do_dossier_snooze "$GOOD" snz-nope "$SNZ"
ckn "snooze with no id REJECTED"                            do_dossier_snooze "$GOOD" "" "$SNZ"
ckn "snooze with no snooze_until REJECTED"                  do_dossier_snooze "$GOOD" snz-d1 ""
ckn "snooze with an unparseable snooze_until REJECTED"      do_dossier_snooze "$GOOD" snz-d1 "not-a-date"
ckn "snooze with a PAST snooze_until REJECTED (re-surfaces LATER, not now)" do_dossier_snooze "$GOOD" snz-d1 "2000-01-01T00:00:00Z"
ckn "snooze with NO bearer REJECTED (§9.1)"                 do_dossier_snooze "" snz-d1 "$SNZ"

echo ""
echo "── EXIT-B: snooze_surface re-tiers to blocking + pings; NO auto-proceed, NO consequence ──"
: > "$BD_LOG"
NID="$(snooze_surface "$GOOD" snz-d1)"
ck  "snooze_surface succeeds"                               test -n "$NID"
ck  "surface RE-tiered the card back to the foreground (digest→blocking)" eq "$(GET snz-d1 | jq -r '.tier')" "blocking"
ck  "surface CLEARED timer_fire_at (the timer fired, no longer snoozed)" eq "$(TFA snz-d1)" "null"
ck  "surface CLEARED snoozed_until (no longer snoozed)"     eq "$(SNZU snz-d1)" "null"
ck  "surface applied NO item — open1 stays OPEN (re-surface, not auto-proceed)" eq "$(ISTATE snz-d1 open1)" "open"
ck  "surface left the answered item answered (recommendation NOT consumed)" eq "$(ISTATE snz-d1 ans1)" "answered"
ck  "surface fired NO §5.3 consequence (no bd create — surface is not auto-proceed)" eq "$(BDN 'create --title new open1')" "0"
ck  "surface fired the blocking new_dossier notification (re-ping)" NHAS snz-d1
ck  "the surfaced notification is tier 'blocking' (new_dossier binds blocking — §10.2 r1)" eq "$(NTIER snz-d1)" "blocking"
# a no-longer-snoozed card ⇒ informational no-op success (does not re-fire)
ck  "snooze_surface on a no-longer-snoozed card ⇒ no-op success" snooze_surface "$GOOD" snz-d1

echo ""
echo "── EXIT-C: the shared timer-due poll ROUTES a snoozed card to re-surface (NOT auto-proceed) ──"
do_dossier_put "$GOOD" "$(mkdecide snz-C thirsty-653d-c "[$(item_open c1)]")" >/dev/null
do_dossier_snooze "$GOOD" snz-C "$SNZ" >/dev/null
do_dossier_put "$GOOD" "$(mkfyi fyi-C "$(item_open y1)")" >/dev/null
tf_arm "$GOOD" fyi-C >/dev/null
: > "$BD_LOG"
POLLED="$(tf_poll "$GOOD" "$FAR")"
ck  "poll surfaced the snoozed snz-C (in the fired list)"   grep -Fxq -- snz-C <<<"$POLLED"
ck  "poll surfaced the timed-fyi fyi-C (in the fired list)" grep -Fxq -- fyi-C <<<"$POLLED"
ck  "ROUTED: snoozed snz-C RE-SURFACED — re-tiered to blocking" eq "$(GET snz-C | jq -r '.tier')" "blocking"
ck  "ROUTED: snoozed snz-C item c1 left OPEN (NO auto-proceed)" eq "$(ISTATE snz-C c1)" "open"
ck  "ROUTED: snoozed snz-C applied NO §5.3 consequence (no bd create for c1)" eq "$(BDN 'create --title new c1')" "0"
ck  "ROUTED: snoozed snz-C cleared snoozed_until on surface" eq "$(SNZU snz-C)" "null"
ck  "ROUTED: timed-fyi fyi-C AUTO-PROCEEDED — y1 applied (the OTHER fire-action still works)" eq "$(ISTATE fyi-C y1)" "applied"
ck  "ROUTED: timed-fyi fyi-C applied its §5.3 consequence (bd create for y1)" eq "$(BDN 'create --title new y1')" "1"

echo ""
echo "── EXIT-D: idempotent — a re-poll after the surface applies nothing more ──"
: > "$BD_LOG"
tf_poll "$GOOD" "$FAR" >/dev/null 2>&1
ck  "re-poll applied NO new consequence for the already-surfaced snooze" eq "$(BDN 'create --title new c1')" "0"
ck  "snz-C still OPEN + blocking after re-poll (idempotent)" eq "$(ISTATE snz-C c1)" "open"

echo ""
echo "── EXIT-E: anti-drift (structural) ──"
caps="$(co_capabilities 2>/dev/null || true)"
ckn "do_dossier_snooze is NOT advertised as a §2 capability" grep -qE 'do_dossier_snooze|dossier-snooze' <<<"$caps"
ckn "snooze_surface is NOT advertised as a §2 capability"   grep -qE 'snooze_surface|snooze-surface' <<<"$caps"
ck  "the re-surface fires the §10.2 r1 new_dossier trigger bound to 'blocking'" eq "$(notif_trigger_tiers new_dossier)" "blocking"
ck  "§4 registry dossier⇒2 (snooze added NO record type; rides the dossier type)" eq "$(co__schema_version dossier)" "2"

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " test-snooze (§5.6, claude-tools-653d):  PASS=$PASS  FAIL=$FAIL"
echo "══════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
