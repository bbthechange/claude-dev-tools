#!/bin/bash
# beads-runner/lib/test-notification.sh — focused unit test for the T5.6
# NOTIFICATION: §4.3 persisted tiered record, one-per-Dossier,
# creation≠dispatch (claude-tools-ks2; epic claude-tools-glk).
#
# T5.6's OWN test surface. Deliberately NOT a member of the T1 conformance
# suite (beads-runner/conformance/, owned by T1a/T1b) and it touches NO
# sibling test (test-coordinator{,-lease,-reconcile,-capacity,-forensic}.sh,
# test-dossier.sh, test-dossier-gen.sh, test-consequence.sh,
# test-timed-fyi.sh). It exercises ONLY notification.sh, consuming the T5.2
# creation hook (dg_generate), the T5.1 substrate (do_dossier_*), and the T4
# §2.1/§4 store + §9.1 chokepoint as black boxes — the SAME self-contained
# CO_STORE pattern the sibling focused tests use.
#
# Asserts the EXIT CRITERIA T5.6 owns against INTERFACE.md v1 §4.3 / §0.3:
#   1. EXACTLY ONE Notification row per Dossier (NOT one-per-Item): a 15-item
#      dossier yields one Notification; re-emit is idempotent (still one).
#   2. created_at set with dispatched=false BEFORE any send (creation≠dispatch
#      — the C3 seam); dispatched/dispatched_at flip ONLY on send and only
#      false→true ONCE; fire-and-forget REJECTED.
#   3. tier mirrors the §4.1 dossier tier (blocking|timed-fyi|digest); the
#      Notification stays terse — it structurally CANNOT carry content (the
#      §5 dossier body does — principle 2).
#   4. schema_version=1 + principal stamped at the §9.1 chokepoint; an unknown
#      higher version REJECTED on BOTH write and read paths (§0.3).
#   5. Binds §4.3; channel is OPAQUE (stored verbatim — a later digest rollup
#      needs no schema change); NO §4 record type added; no_* not advertised
#      as a §2 capability. (Full no-regression is the SUITE's job — the
#      sibling lib tests + conformance, run as the gate.)
#
# Self-contained: its own CO_STORE under mktemp; shares NO state with the
# conformance harness or sibling tests.
set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/notification.sh"
[[ -f "$LIB" ]] || { echo "FATAL: notification.sh not found at $LIB"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
ck()  { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }   # expect SUCCESS
ckn() { if "${@:2}" >/dev/null 2>&1; then bad "$1"; else ok "$1"; fi; }   # expect FAILURE
eq()  { [[ "$1" == "$2" ]]; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CO_STORE="$WORK/store"
unset CO_EXPECTED_TOKEN PRINCIPAL_V1 2>/dev/null || true

# shellcheck source=/dev/null
source "$LIB"           # → dossier-gen.sh → dossier.sh → coordinator.sh

GOOD="bearer-runner-secret-xyz"
NID()  { no__notif_id "$1"; }
NREC() { co_request "$GOOD" get notification "$(NID "$1")" 2>/dev/null; }
NF()   { NREC "$1" | jq -r "$2" 2>/dev/null; }   # NF <dossier> <jq>
# Count §4.3 rows in the §4 store (proves one-per-Dossier structurally —
# notification.<id>.json is the only notification record file shape).
NCOUNT() { ls "$CO_STORE"/records/notification.*.json 2>/dev/null | wc -l | tr -d ' '; }

# §4.1 envelope — body OPAQUE (substrate round-trips it; §5 = T5.2). Used to
# seed a dossier via the T5.1 store directly (no_emit reads the tier off it).
mk() {  # mk <id> <tier> <items-json-array>
  jq -cn --arg id "$1" --arg tier "$2" --argjson items "$3" '
    { id:$id, schema_version:2, kind:"decide", trigger:"proactive_checkpoint",
      bead_ref:"claude-tools-65z", tier:$tier,
      created_at:"2026-05-16T00:00:00Z", timer_fire_at:null,
      body:{ dossier_schema_version:2, tldr:"opaque", sections:[],
             diagrams:[], full_detail:"T5.2 owns this" },
      items:$items }'
}
item() { jq -cn --arg i "$1" '
    { id:$i, kind:"approve-reject", framing:{}, context_anchor:{where:"x",expansion:"y"},
      consequence_block:{cb_schema_version:2,creates:[],unblocks:[],labels:[],status_changes:[]},
      state:"open", response:null, consequence_applied:false, applied_at:null }'; }
# 15 distinct items ⇒ a 15-item dossier (must still yield ONE Notification).
items15() { local a="" i; for i in $(seq 1 15); do a="$a$([[ -n "$a" ]] && echo ,)$(item "i$i")"; done; printf '[%s]' "$a"; }

echo "── EXIT-1: EXACTLY ONE Notification per Dossier (NOT one-per-Item) ──"
do_dossier_put "$GOOD" "$(mk d15 blocking "$(items15)")" >/dev/null
ck  "the seeded dossier really has 15 Items"            eq "$(co_request "$GOOD" get dossier d15 | jq -r '.items|length')" "15"
NID15="$(no_emit "$GOOD" d15)"
ck  "no_emit succeeds on a 15-item dossier"             test -n "$NID15"
ck  "exactly ONE Notification row exists (NOT 15, NOT one-per-Item)" eq "$(NCOUNT)" "1"
ck  "the row announces the dossier (dossier_ref=d15)"   eq "$(NF d15 .dossier_ref)" "d15"
ck  "notification id is derived one-per-Dossier"        eq "$NID15" "notif.d15"
# Re-emit is idempotent: still ONE row, created_at NOT reset.
CA1="$(NF d15 .created_at)"
NID15B="$(no_emit "$GOOD" d15)"
ck  "re-emit returns the SAME notification id"          eq "$NID15B" "$NID15"
ck  "re-emit did NOT create a second row (still one)"   eq "$(NCOUNT)" "1"
ck  "re-emit did NOT reset created_at (one fork ⇒ one Notification)" eq "$(NF d15 .created_at)" "$CA1"

echo ""
echo "── EXIT-2: creation≠dispatch (C3 seam) · false→true ONCE · no fire-&-forget ──"
do_dossier_put "$GOOD" "$(mk dC3 timed-fyi "[$(item a1)]")" >/dev/null
no_emit "$GOOD" dC3 >/dev/null
ck  "created_at set at creation (a row exists before any send)" test -n "$(NF dC3 .created_at)"
ck  "dispatched=false at creation (creation≠dispatch — C3)"     eq "$(NF dC3 .dispatched)" "false"
ck  "dispatched_at=null at creation"                            eq "$(NF dC3 .dispatched_at)" "null"
ck  "channel=null at creation"                                  eq "$(NF dC3 .channel)" "null"
# fire-and-forget FORBIDDEN: dispatch with NO row is rejected.
ckn "fire-and-forget REJECTED — dispatch a never-emitted Notification" \
    no_dispatch_for_dossier "$GOOD" dNeverEmitted
# send: dispatched/dispatched_at flip ONLY here.
ck  "no_dispatch succeeds (the send)"                   no_dispatch_for_dossier "$GOOD" dC3
ck  "dispatched flipped true ONLY on send"              eq "$(NF dC3 .dispatched)" "true"
ck  "dispatched_at stamped ONLY on send"                test -n "$(NF dC3 .dispatched_at)"
ckn "dispatched_at is no longer null"                   eq "$(NF dC3 .dispatched_at)" "null"
# false→true EXACTLY ONCE — a SECOND dispatch is rejected (single-writer-set).
ckn "SECOND dispatch REJECTED (false→true ONCE — C3 latch)" \
    no_dispatch_for_dossier "$GOOD" dC3
DA1="$(NF dC3 .dispatched_at)"
no_dispatch_for_dossier "$GOOD" dC3 >/dev/null 2>&1 || true
ck  "rejected re-dispatch did NOT re-stamp dispatched_at (NO write)" eq "$(NF dC3 .dispatched_at)" "$DA1"

echo ""
echo "── EXIT-3: tier mirrors §4.1 · terse by structure (principle 2) ──"
for T in blocking timed-fyi digest; do
  D="dT_${T//-/_}"
  do_dossier_put "$GOOD" "$(mk "$D" "$T" "[$(item q1)]")" >/dev/null
  no_emit "$GOOD" "$D" >/dev/null
  ck  "tier mirrors the §4.1 dossier tier ($T)"          eq "$(NF "$D" .tier)" "$T"
done
# Terse BY STRUCTURE: the §4.3 field set is closed — no body/content key. An
# injected content key is REJECTED by no__validate (principle 2: the §5
# dossier body carries the content, the Notification never does).
GOODREC="$(NREC dT_blocking)"
ck  "a well-formed §4.3 record validates"               no__validate "$GOODREC"
ckn "a record with an injected 'body' key REJECTED (terse — principle 2)" \
    no__validate "$(jq -c '.body={tldr:"leak"}' <<<"$GOODREC")"
ckn "a record with a 'content' key REJECTED (no content — principle 2)" \
    no__validate "$(jq -c '.content="payload"' <<<"$GOODREC")"
ck  "the §4.3 record carries NO content/body/payload key (closed set)" \
    eq "$(printf '%s' "$GOODREC" | jq -r '[keys[]|select(.=="body" or .=="content" or .=="payload" or .=="items")]|length')" "0"

echo ""
echo "── EXIT-4: schema_version=1 · principal stamped (§9.1) · §0.3 ──"
ck  "schema_version=1 persisted (§4.3)"                  eq "$(NF dT_blocking .schema_version)" "1"
ck  "bound version READ from the T4 §4 registry (not a local literal)" \
    eq "$(no__bound_sv)" "$(co__schema_version notification)"
ck  "T4 STAMPED principal=PRINCIPAL_V1 at the §9.1 chokepoint" \
    eq "$(NF dT_blocking .principal)" "brian"
# §0.3 — unknown HIGHER schema_version rejected on the WRITE path (no__validate
# is the producer-side gate; the T4 store re-enforces it too).
ckn "§0.3 — schema_version 2 REJECTED by no__validate (unknown higher)" \
    no__validate "$(jq -c '.schema_version=2' <<<"$GOODREC")"
ckn "§0.3 — string \"1\" schema_version REJECTED (jq type-check)" \
    no__validate "$(jq -c '.schema_version="1"' <<<"$GOODREC")"
# §0.3 also bound on the READ path: a v3 slipped directly into the store
# (bypassing the front door) must be REJECTED by no_get, not parsed.
mkdir -p "$CO_STORE/records"
printf '%s\n' "$(jq -c '.schema_version=3 | .principal="brian"' <<<"$GOODREC" | jq -c '.id="notif.dRd"')" \
  > "$CO_STORE/records/notification.notif.dRd.json"
ckn "§0.3 — no_get REJECTS an unknown-higher stored record (read path)" \
    no_get "$GOOD" notif.dRd
# §9.1 — no/invalid bearer ⇒ rejected (the ONE chokepoint, no second path).
ckn "§9.1 — missing bearer ⇒ no_emit REJECTED"          no_emit "" dT_blocking
ckn "§9.1 — emit on a MISSING dossier REJECTED (collapses 401/absent — C4)" \
    no_emit "$GOOD" noSuchDossier

echo ""
echo "── EXIT-5: binds §4.3 · channel OPAQUE · anti-drift (structural) ──"
# channel is an opaque transport tag: stored verbatim, never interpreted; a
# later read-side digest rollup keys off it with NO schema change (C3).
do_dossier_put "$GOOD" "$(mk dCh digest "[$(item z1)]")" >/dev/null
no_emit "$GOOD" dCh >/dev/null
OPAQUE='digest-rollup::weekly::xyz#42'
ck  "no_dispatch accepts an arbitrary OPAQUE channel tag" \
    no_dispatch_for_dossier "$GOOD" dCh "$OPAQUE"
ck  "the opaque channel tag round-trips VERBATIM (no schema change — C3)" \
    eq "$(NF dCh .channel)" "$OPAQUE"
# No §4 record type added; the registry is UNCHANGED (notification was already
# a T4-registered type — T5.6 adds none and never edits the registry).
ck  "T4 §4 registry UNCHANGED — notification⇒1 (no schema bump)" \
    eq "$(co__schema_version notification)" "1"
ck  "T4 §4 registry dossier⇒2 (v2 §11 Mermaid amend; T5.6/notification added no record type, no sibling GATE flipped)" \
    eq "$(co__schema_version dossier)" "2"
ck  "NO §4 record type added — 'notify' unregistered" \
    eq "$(co__schema_version notify)" ""
caps="$(co_capabilities 2>/dev/null || true)"
ckn "no_emit is NOT advertised as a §2 capability"     grep -q 'no_emit' <<<"$caps"
ckn "no_dispatch is NOT advertised as a §2 capability" grep -q 'no_dispatch' <<<"$caps"
ck  "T4 co_capabilities still EXACTLY four §2 lines"   eq "$(grep -c '§2' <<<"$caps" || true)" "4"
# The C3 creation hook: dg_generate (T5.2) → ONE Notification at creation.
GI="$(jq -cn '{ id:"dGen", trigger:"proactive_checkpoint", bead_ref:"claude-tools-65z",
                tier:"timed-fyi",
                source:{ tldr:"t", sections:[{heading:"H",prose:"P"}],
                         diagrams:[], full_detail:"FD" },
                items:[] }')"
NGEN="$(no_for_generation "$GOOD" "$GI")"
ck  "no_for_generation consumes the T5.2 hook + emits ONE Notification" \
    eq "$NGEN" "notif.dGen"
ck  "the generated dossier's Notification mirrors its tier (timed-fyi)" \
    eq "$(NF dGen .tier)" "timed-fyi"
ck  "creation≠dispatch holds via the hook (dispatched=false at creation)" \
    eq "$(NF dGen .dispatched)" "false"

echo ""
echo "── K3 (claude-tools-uxvk3): always-FYI digest rollup (read-side, by channel) ──"
# Seed a fresh batch of dossiers + emit + dispatch with channels covering all
# the rollup cases. Helper: emit then dispatch with a channel tag.
DIG_emit_disp() {  # DIG_emit_disp <dossier_id> <tier> <channel|"">
  do_dossier_put "$GOOD" "$(mk "$1" "$2" "[$(item k1)]")" >/dev/null
  no_emit "$GOOD" "$1" >/dev/null
  if [[ -n "${3:-}" ]]; then no_dispatch_for_dossier "$GOOD" "$1" "$3" >/dev/null
  else                       no_dispatch_for_dossier "$GOOD" "$1" >/dev/null; fi
}
XBE="$(no__xws_channel BE)"          # "xws:BE"
XFE="$(no__xws_channel FE)"          # "xws:FE"
# (a) N notifications on the SAME channel (timed-fyi) → ONE group, count N.
DIG_emit_disp digA1 timed-fyi "$XBE"
DIG_emit_disp digA2 timed-fyi "$XBE"
DIG_emit_disp digA3 timed-fyi "$XBE"
# (b) a blocking-tier notification on a channel → NEVER in any digest group.
DIG_emit_disp digBlock blocking "$XBE"
# (c) a timed-fyi notification with channel=null → excluded.
DIG_emit_disp digNull timed-fyi ""
# (d) a distinct channel (digest tier) → its own group.
DIG_emit_disp digD1 digest "$XFE"
DIG="$(no_digest "$GOOD")"
ck  "(e) no__xws_channel produces the xws: convention"  eq "$XBE" "xws:BE"
ck  "(e) no__digest_copy renders the 'N syncs' cross-WS line" \
    eq "$(no__digest_copy "$XBE" 6)" "BE: 6 syncs — all resolved, none needed you."
ck  "(e) no__digest_copy singular 'sync'" \
    eq "$(no__digest_copy "$XBE" 1)" "BE: 1 sync — all resolved, none needed you."
ck  "(a) same-channel timed-fyi rolls up to ONE group" \
    eq "$(printf '%s' "$DIG" | jq -r '[.digests[]|select(.channel=="xws:BE")]|length')" "1"
ck  "(a) that group's count is N (3 syncs on xws:BE)" \
    eq "$(printf '%s' "$DIG" | jq -r '.digests[]|select(.channel=="xws:BE")|.count')" "3"
ck  "(b) blocking-tier dossier_ref is NEVER in the xws:BE group" \
    eq "$(printf '%s' "$DIG" | jq -r '[.digests[]|select(.channel=="xws:BE")|.dossier_refs[]|select(.=="digBlock")]|length')" "0"
ckn "(c) a channel=null notification forms NO digest group" \
    test "$(printf '%s' "$DIG" | jq -r '[.digests[]|select(.channel==null or .channel=="")]|length')" -gt 0
ck  "(d) two distinct channels → two groups (xws:BE + xws:FE)" \
    eq "$(printf '%s' "$DIG" | jq -r '[.digests[]|select(.channel|startswith("xws:"))]|length')" "2"
ck  "(d) groups are in deterministic channel-asc order (xws:BE before xws:FE)" \
    eq "$(printf '%s' "$DIG" | jq -r '[.digests[]|select(.channel|startswith("xws:"))|.channel]|join(",")')" "xws:BE,xws:FE"
ck  "the xws:FE (digest-tier) group reports tier=digest" \
    eq "$(printf '%s' "$DIG" | jq -r '.digests[]|select(.channel=="xws:FE")|.tier')" "digest"
ck  "the xws:BE group's tier is timed-fyi (no digest-tier record mixed in)" \
    eq "$(printf '%s' "$DIG" | jq -r '.digests[]|select(.channel=="xws:BE")|.tier')" "timed-fyi"
ck  "dossier_refs are deterministically sorted (digA1,digA2,digA3)" \
    eq "$(printf '%s' "$DIG" | jq -r '.digests[]|select(.channel=="xws:BE")|.dossier_refs|join(",")')" "digA1,digA2,digA3"
# optional channel-prefix filter: scope to cross-WS only (here all are xws:).
DIGX="$(no_digest "$GOOD" "xws:")"
ck  "optional channel-prefix filter ('xws:') returns only xws: groups" \
    eq "$(printf '%s' "$DIGX" | jq -r '[.digests[]|select(.channel|startswith("xws:")|not)]|length')" "0"
# the rollup carries NO content — only channel/count/tier/dossier_refs keys.
ck  "a digest entry carries NO content (only channel/count/tier/dossier_refs)" \
    eq "$(printf '%s' "$DIG" | jq -r '[.digests[0]|keys[]|select(.=="channel" or .=="count" or .=="tier" or .=="dossier_refs"|not)]|length')" "0"

echo ""
echo "── N1 (claude-tools-uxvn1): §10.2 trigger catalog + producer batching spine ──"
# Catalog completeness (the CLOSED §10.2 enum, D.2) + the pure accessors.
for TR in new_dossier blueprint_changed cross_ws_exchange cross_ws_conflict \
          task_maybe_stuck runner_wedged intake_failed queue_alarm \
          agent_gate ready_to_pair; do
  ck "catalog knows §10.2 trigger '$TR'"                 notif_trigger_known "$TR"
done
ckn "an off-catalog trigger is REJECTED (closed enum — D.2)" notif_trigger_known not_a_trigger
ck  "new_dossier binds tier=blocking (§10.2 r1)"          eq "$(notif_trigger_tiers new_dossier)" "blocking"
ck  "blueprint_changed binds tier=timed-fyi (r2)"         eq "$(notif_trigger_tiers blueprint_changed)" "timed-fyi"
ck  "cross_ws_conflict binds tier=blocking (r4)"          eq "$(notif_trigger_tiers cross_ws_conflict)" "blocking"
ck  "runner_wedged binds tier=blocking (r6)"              eq "$(notif_trigger_tiers runner_wedged)" "blocking"
ck  "task_maybe_stuck binds BOTH tiers (r5 failure→tier map)" eq "$(notif_trigger_tiers task_maybe_stuck)" "timed-fyi blocking"
ckn "notif_trigger_tiers REJECTS an off-catalog trigger"  notif_trigger_tiers nope
# channel convention: cross_ws_exchange REUSES K3's xws: verbatim (no drift).
ck  "cross_ws_exchange channel == K3 no__xws_channel (shared spine)" \
    eq "$(notif_trigger_channel cross_ws_exchange BE)" "$(no__xws_channel BE)"
ck  "blueprint_changed channel is 'blueprint:<scope>'"    eq "$(notif_trigger_channel blueprint_changed projX)" "blueprint:projX"
ck  "queue_alarm channel is 'queue:<scope>'"              eq "$(notif_trigger_channel queue_alarm projX)" "queue:projX"
ck  "agent_gate channel is 'agent-gate:<scope>'"          eq "$(notif_trigger_channel agent_gate projX)" "agent-gate:projX"
ck  "a blocking trigger (new_dossier) has NO channel (never batched)" eq "$(notif_trigger_channel new_dossier projX)" ""
ck  "cross_ws_conflict (blocking) has NO channel"         eq "$(notif_trigger_channel cross_ws_conflict projX)" ""
ckn "notif_trigger_channel REJECTS an off-catalog trigger (closed enum on EVERY accessor)" \
    notif_trigger_channel nope x

# notif_fire: a BLOCKING trigger ⇒ emit, mirror blocking, left PENDING, no channel.
do_dossier_put "$GOOD" "$(mk nf_block blocking "[$(item b1)]")" >/dev/null
NFB="$(notif_fire "$GOOD" new_dossier nf_block)"
ck  "fire(new_dossier) emits the one Notification"        eq "$NFB" "notif.nf_block"
ck  "fire(new_dossier) mirrors tier=blocking"             eq "$(NF nf_block .tier)" "blocking"
ck  "fire(new_dossier) leaves it PENDING (blocking not auto-dispatched)" eq "$(NF nf_block .dispatched)" "false"
ck  "fire(new_dossier) stamps NO channel (never batched)" eq "$(NF nf_block .channel)" "null"

# notif_fire: a BATCHABLE timed-fyi trigger ⇒ emit + route the channel; idempotent.
do_dossier_put "$GOOD" "$(mk nf_bp1 timed-fyi "[$(item p1)]")" >/dev/null
NFP="$(notif_fire "$GOOD" blueprint_changed nf_bp1 projX)"
ck  "fire(blueprint_changed) emits the one Notification"  eq "$NFP" "notif.nf_bp1"
ck  "fire(blueprint_changed) routes the batching channel 'blueprint:projX'" eq "$(NF nf_bp1 .channel)" "blueprint:projX"
ck  "fire(blueprint_changed) is dispatched (routed into its digest channel)" eq "$(NF nf_bp1 .dispatched)" "true"
NFP2="$(notif_fire "$GOOD" blueprint_changed nf_bp1 projX)"
ck  "re-fire(blueprint_changed) is idempotent (same nid)" eq "$NFP2" "$NFP"
ck  "re-fire did NOT change the channel"                  eq "$(NF nf_bp1 .channel)" "blueprint:projX"
# re-fire to a DIFFERENT channel is REJECTED (one dossier ⇒ one batching channel).
ckn "re-fire(blueprint_changed) to a DIFFERENT channel REJECTED (one dossier ⇒ one channel)" \
    notif_fire "$GOOD" blueprint_changed nf_bp1 projY
ck  "rejected re-route did NOT change the channel"        eq "$(NF nf_bp1 .channel)" "blueprint:projX"

# the fired batchable notification ROLLS UP via K3's read engine (the shared spine).
NDIG="$(no_digest "$GOOD" "blueprint:")"
ck  "fired blueprint FYI appears in the K3 rollup (one blueprint:projX group)" \
    eq "$(printf '%s' "$NDIG" | jq -r '[.digests[]|select(.channel=="blueprint:projX")]|length')" "1"
ck  "that group's dossier_ref is the fired dossier" \
    eq "$(printf '%s' "$NDIG" | jq -r '.digests[]|select(.channel=="blueprint:projX")|.dossier_refs[0]')" "nf_bp1"

# cross_ws_exchange fired via the spine lands on the SAME xws: channel K3 uses.
do_dossier_put "$GOOD" "$(mk nf_xws timed-fyi "[$(item x1)]")" >/dev/null
NFX="$(notif_fire "$GOOD" cross_ws_exchange nf_xws BE)"
ck  "fire(cross_ws_exchange) succeeds"                    eq "$NFX" "notif.nf_xws"
ck  "fire(cross_ws_exchange) routes the K3 xws: channel"  eq "$(NF nf_xws .channel)" "$(no__xws_channel BE)"

# TIER GUARD: a trigger fired at the WRONG tier is REJECTED (catalog binds tier).
do_dossier_put "$GOOD" "$(mk nf_wrong blocking "[$(item w1)]")" >/dev/null
ckn "fire(blueprint_changed) on a BLOCKING dossier REJECTED (tier guard)" \
    notif_fire "$GOOD" blueprint_changed nf_wrong projX
do_dossier_put "$GOOD" "$(mk nf_wrong2 timed-fyi "[$(item w2)]")" >/dev/null
ckn "fire(new_dossier) on a TIMED-FYI dossier REJECTED (tier guard)" \
    notif_fire "$GOOD" new_dossier nf_wrong2
ckn "fire() with an off-catalog trigger REJECTED" \
    notif_fire "$GOOD" bogus_trigger nf_block

# task_maybe_stuck is VARIABLE (r5): timed-fyi ⇒ batched on stuck:; blocking ⇒ pending.
do_dossier_put "$GOOD" "$(mk nf_stuckf timed-fyi "[$(item s1)]")" >/dev/null
NFSF="$(notif_fire "$GOOD" task_maybe_stuck nf_stuckf jobZ)"
ck  "fire(task_maybe_stuck@timed-fyi) succeeds"           eq "$NFSF" "notif.nf_stuckf"
ck  "fire(task_maybe_stuck@timed-fyi) batches on 'stuck:jobZ'" eq "$(NF nf_stuckf .channel)" "stuck:jobZ"
do_dossier_put "$GOOD" "$(mk nf_stuckb blocking "[$(item s2)]")" >/dev/null
NFSB="$(notif_fire "$GOOD" task_maybe_stuck nf_stuckb jobZ)"
ck  "fire(task_maybe_stuck@blocking) succeeds (NOT a vacuous PENDING pass)" eq "$NFSB" "notif.nf_stuckb"
ck  "fire(task_maybe_stuck@blocking) is PENDING, no channel" eq "$(NF nf_stuckb .channel)" "null"
ck  "fire(task_maybe_stuck@blocking) not auto-dispatched"     eq "$(NF nf_stuckb .dispatched)" "false"

# TRIAGE ONLY: a fired notification carries NO content (the closed §4.3 set).
ck  "a fired notification carries NO content key (triage only — principle 2)" \
    eq "$(NREC nf_bp1 | jq -r '[keys[]|select(.=="body" or .=="content" or .=="payload" or .=="items")]|length')" "0"

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " test-notification (T5.6, claude-tools-ks2):  PASS=$PASS  FAIL=$FAIL"
echo "══════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
