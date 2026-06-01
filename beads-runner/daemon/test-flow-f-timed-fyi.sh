#!/bin/bash
# beads-runner/daemon/test-flow-f-timed-fyi.sh — P2 verification
# (claude-tools-0wy; epic claude-tools-kie).
#
# WHAT THIS PROVES
#   The P2 acceptance for "Flow F dossiers ride the existing timed-fyi tier
#   mechanism unchanged" — end-to-end. P1's test-flow-f-overview.sh stops at
#   the engine-write subshell (it stubs the engine call); test-timed-fyi.sh
#   proves tf_arm/tf_fire on hand-built dossiers. Neither test connects the
#   two layers. This test does: it takes the SAME `daemon_flow_f__build_gener
#   ation_input` helper P1's dispatch path uses, feeds the gi through the
#   REAL dg_generate + tf_arm chain (no override, no stub), and then drives
#   tf_fire down both branches — silence ⇒ auto-proceed, objection ⇒ that
#   item is left to the reconciler while siblings auto-proceed. ALL of this
#   uses existing ops; the test would fail if Flow F had to introduce a new
#   record type or co_request op.
#
#   Asserts the P2 acceptance criteria verbatim:
#     1. P1 dossiers persist with tier='timed-fyi' AND timer_fire_at =
#        created_at + 86400 (the §0.5 TIMED_FYI_DEFAULT, 24h) after tf_arm.
#     2. The substrate timer is armed: timer-due returns the dossier id at a
#        far-future "now" (the §2.2 fire(dossier_id) wiring is in place).
#     3. Silence path: tf_fire ⇒ every fyi-objectable item has
#        consequence_applied=true (the all-fyi-objectable / overview profile
#        is what "proceed" means for an unobjected overview).
#     4. Objection path: human do_item_apply(decision:"object") on one item
#        BEFORE the window lapses; tf_fire then leaves that item alone (its
#        latch reflects the reconciler-routed apply, NOT auto-proceed) while
#        an un-objected sibling DOES auto-proceed. AD7 partial resolution.
#     5. No new record type / no new co_request op: dg_generate, tf_arm,
#        tf_fire, and do_item_apply use ONLY ops the existing co.sh /
#        timed-fyi.sh / consequence.sh surface — exactly the P2 contract.
#
# Self-contained: own CO_STORE under mktemp; shares NO state with the
# conformance harness or sibling tests. Uses test-timed-fyi.sh's bd-on-PATH
# fake so record_incident is reachable from do_item_apply.
#
# Run: bash beads-runner/daemon/test-flow-f-timed-fyi.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
LIB_DIR="$REPO_ROOT/lib"
F_LIB="$HERE/flow-f-overview-poll.sh"

[[ -f "$LIB_DIR/dossier-gen.sh" ]] || { echo "FATAL: $LIB_DIR/dossier-gen.sh missing"; exit 2; }
[[ -f "$LIB_DIR/timed-fyi.sh"  ]] || { echo "FATAL: $LIB_DIR/timed-fyi.sh missing";  exit 2; }
[[ -f "$F_LIB"                 ]] || { echo "FATAL: $F_LIB missing";                 exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
eq()  { [[ "$1" == "$2" ]] && ok "$3" || bad "$3 (got '$1' want '$2')"; }
ck()  { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
ckn() { if "${@:2}" >/dev/null 2>&1; then bad "$1"; else ok "$1"; fi; }

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " P2 Flow F × timed-fyi tier integration — claude-tools-0wy (epic claude-tools-kie)"
echo "════════════════════════════════════════════════════════════════════"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CO_STORE="$WORK/store"
# claude-tools-69u8: isolate the dossier-author audit log so a STANDALONE run
# doesn't pollute the real $HOME/.cache production telemetry (the gate sets it
# itself; honor that). See run-tests.sh / conformance/lib/harness.sh.
export DG_AUDIT_LOG="${DG_AUDIT_LOG:-$WORK/.dossier-author-audit.jsonl}"
unset CO_EXPECTED_TOKEN PRINCIPAL_V1 TIMED_FYI_DEFAULT 2>/dev/null || true

# work-plane `bd` fake on PATH so the consequence apply path's incidental
# `bd create` calls (reconciler follow-up emission, etc.) succeed.
FAKEBIN="$WORK/bin"; mkdir -p "$FAKEBIN"
export BD_LOG="$WORK/bd.log"; : > "$BD_LOG"
cat > "$FAKEBIN/bd" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${BD_LOG:-/dev/null}"
if [[ "${1:-}" == "create" ]]; then
  n=$(wc -l < "${BD_LOG:-/dev/null}" 2>/dev/null || echo 0)
  echo "✓ Created issue: bd-fake-$n"
fi
exit 0
EOF
chmod +x "$FAKEBIN/bd"
export PATH="$FAKEBIN:$PATH"

# Source the real engine + Flow F helpers. dossier-gen pulls dossier→coordinator;
# timed-fyi pulls consequence→dossier→coordinator. flow-f-overview-poll gives
# us daemon_flow_f__build_generation_input — the SAME helper P1's dispatch
# path uses, so we're exercising the actual gi shape.
# shellcheck source=/dev/null
. "$LIB_DIR/dossier-gen.sh"
# shellcheck source=/dev/null
. "$LIB_DIR/timed-fyi.sh"
# shellcheck source=/dev/null
. "$F_LIB"

BEARER="bearer-flow-f-p2"

# Helpers (test-timed-fyi.sh shape).
GET()    { co_request "$BEARER" get dossier "$1" 2>/dev/null; }
ISTATE() { GET "$1" | jq -r --arg i "$2" '.items[]|select(.id==$i).state' 2>/dev/null; }
ICA()    { GET "$1" | jq -r --arg i "$2" '.items[]|select(.id==$i).consequence_applied' 2>/dev/null; }
TFA()    { GET "$1" | jq -r '.timer_fire_at' 2>/dev/null; }
TIER()   { GET "$1" | jq -r '.tier' 2>/dev/null; }
KIND()   { GET "$1" | jq -r '.kind' 2>/dev/null; }
DUE()    { co_request "$BEARER" timer-due "${2:-}" 2>/dev/null | grep -Fxq -- "$1"; }
FAR="2099-01-01T00:00:00Z"     # well past any computed fire_at
NEAR="1999-01-01T00:00:00Z"    # before any computed fire_at

# `builder_out` — a Flow F builder output of the exact shape P1's dispatch
# path emits and ingests via daemon_flow_f__build_generation_input. Two
# fyi-objectable items, one of which we'll object to in PART C.
builder_out() {
  jq -cn '
    { body: {
        tldr: "How design-stage close on bead X fits with the rest of the system.",
        sections: [
          { heading: "What just landed",
            prose:   "design stage closed: routing + envelope wiring; ready for impl pickup." },
          { heading: "Where the seams are",
            prose:   "the §2.3 front door is unchanged; only the dispatch trigger is new." }
        ],
        diagrams: [],
        full_detail: "Flow F is the daemon-side overview brief on stage:design close." },
      items: [
        { id: "i1",
          kind: "fyi-objectable",
          framing: { ask: "does the dispatch trigger shape look right?",
                     why: "Brian should push back if the predicate is wrong." },
          context_anchor: { where: "flow-f-overview-poll.sh:daemon_flow_f__poll_workspace",
                            expansion: "label-based detection on stage:design until L-track lands a stage column." },
          consequence_block: {
            cb_schema_version: 2,
            creates: [], unblocks: [],
            labels: ["flow-f-overview-i1"],
            status_changes: [] },
          reversible: "fully reversible — the marker file can be removed and the bead re-observed." },
        { id: "i2",
          kind: "fyi-objectable",
          framing: { ask: "is the 24h window the right default?",
                     why: "shorter windows starve Brian; longer ones stall design pickup." },
          context_anchor: { where: "lib/timed-fyi.sh:TIMED_FYI_DEFAULT",
                            expansion: "§0.5 default, per-dossier override allowed in (0, 86400]." },
          consequence_block: {
            cb_schema_version: 2,
            creates: [], unblocks: [],
            labels: ["flow-f-overview-i2"],
            status_changes: [] },
          reversible: "fully reversible — the tier window can be re-armed null at any time." }
      ] }'
}

# ════════════════════════════════════════════════════════════════════════════
# PART A — Flow F gi flows through dg_generate; envelope lands timed-fyi
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART A — Flow F gi → dg_generate → timed-fyi envelope ──"

BREF_A="claude-tools-aaa"
DID_A="overview-$(daemon_flow_f__safe_key "$BREF_A")"
# Wrap the builder output, exactly as daemon_flow_f_dispatch_one does.
GI_A="$(daemon_flow_f__build_generation_input "$DID_A" "$BREF_A" "$(builder_out)")"

[[ -n "$GI_A" ]] && ok "A1: daemon_flow_f__build_generation_input returned non-empty gi" \
                 || bad "A1: gi build failed"
eq "$(printf '%s' "$GI_A" | jq -r '.tier')"       "timed-fyi"          "A2: gi.tier == timed-fyi (P1 wires this)"
eq "$(printf '%s' "$GI_A" | jq -r '.kind')"       "overview"           "A3: gi.kind == overview"
eq "$(printf '%s' "$GI_A" | jq -r '.timer_fire_at')" "null"            "A4: gi.timer_fire_at left null — tf_arm fills it"

written="$(dg_generate "$BEARER" "$GI_A" 2>&1)"; rc=$?
[[ "$rc" -eq 0 && "$written" == "$DID_A" ]] && ok "A5: dg_generate accepted the Flow F gi (rc=0, echoes id)" \
                                            || bad "A5: dg_generate failed (rc=$rc, out=$written)"
eq "$(KIND "$DID_A")" "overview"   "A6: persisted .kind == overview (kind seam preserved through write)"
eq "$(TIER "$DID_A")" "timed-fyi"  "A7: persisted .tier == timed-fyi"
eq "$(TFA "$DID_A")"  "null"       "A8: persisted timer_fire_at == null PRE-arm (tf_arm has not run yet)"

# ════════════════════════════════════════════════════════════════════════════
# PART B — tf_arm: timer_fire_at = created_at + 86400 (24h) AND substrate armed
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART B — tf_arm fills timer_fire_at and arms the §2.2 timer ──"

# Snapshot the substrate created_at so the +86400s assertion is exact.
CA_A="$(GET "$DID_A" | jq -r '.created_at')"
[[ -n "$CA_A" && "$CA_A" != "null" ]] && ok "B1: dossier has a non-null created_at" \
                                     || bad "B1: created_at missing"

FA_A="$(tf_arm "$BEARER" "$DID_A" 2>/dev/null)"
[[ -n "$FA_A" ]] && ok "B2: tf_arm succeeded (echoed fire_at)" || bad "B2: tf_arm failed"

# Compute expected fire_at = created_at + 86400 in pure shell.
e0="$(date -u -d "$CA_A" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$CA_A" +%s 2>/dev/null)"
ex="$(date -u -d "@$((e0+86400))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$((e0+86400))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
eq "$FA_A"            "$ex" "B3: tf_arm echoed fire_at == created_at + 86400 (the §0.5 24h default)"
eq "$(TFA "$DID_A")"  "$ex" "B4: persisted timer_fire_at == created_at + 86400"
ck "B5: substrate §2.2 timer armed (timer-due returns the id at far-future now)" DUE "$DID_A" "$FAR"
ckn "B6: timer NOT due at a NEAR (pre-fire) now (one-shot at T, not earlier)"    DUE "$DID_A" "$NEAR"

# ════════════════════════════════════════════════════════════════════════════
# PART C — silence path: tf_fire ⇒ every fyi-objectable item auto-proceeds
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART C — silence ⇒ every fyi-objectable item auto-proceeds (parent EXIT 2) ──"

tf_fire "$BEARER" "$DID_A" >/dev/null 2>&1
rc=$?
[[ "$rc" -eq 0 ]] && ok "C1: tf_fire (silence path) returned 0" || bad "C1: tf_fire returned $rc"

eq "$(ICA   "$DID_A" i1)" "true"    "C2: silence path — item i1 consequence_applied=true"
eq "$(ICA   "$DID_A" i2)" "true"    "C3: silence path — item i2 consequence_applied=true"
eq "$(ISTATE "$DID_A" i1)" "applied" "C4: silence path — item i1 state == applied"
eq "$(ISTATE "$DID_A" i2)" "applied" "C5: silence path — item i2 state == applied"

# ════════════════════════════════════════════════════════════════════════════
# PART D — objection path: object on i1 BEFORE fire; sibling i2 still auto-proceeds
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART D — objection on one item ⇒ reconciler routes that item; sibling auto-proceeds ──"

BREF_D="claude-tools-ddd"
DID_D="overview-$(daemon_flow_f__safe_key "$BREF_D")"
GI_D="$(daemon_flow_f__build_generation_input "$DID_D" "$BREF_D" "$(builder_out)")"
dg_generate "$BEARER" "$GI_D" >/dev/null 2>&1
[[ "$(KIND "$DID_D")" == "overview" && "$(TIER "$DID_D")" == "timed-fyi" ]] \
  && ok "D1: second dossier persisted (overview / timed-fyi)" \
  || bad "D1: second dossier failed to persist"
tf_arm "$BEARER" "$DID_D" >/dev/null 2>&1
ck "D2: second dossier armed" DUE "$DID_D" "$FAR"

# Brian objects on i1 inside the 24h window. The objection routes via the
# reconciler hat (§5.2.2: fyi-objectable + decision:"object" ⇒ reconciler);
# the per-Item latch flips so a subsequent tf_fire treats i1 as already
# resolved and DOES NOT auto-proceed it.
RESP_OBJECT='{"decision":"object","freeform_text":"actually 24h is too long for this one","responded_at":"2026-05-20T01:00:00Z","principal":"brian"}'
do_item_apply "$BEARER" "$DID_D" i1 "$RESP_OBJECT" >/dev/null 2>&1
rc=$?
[[ "$rc" -eq 0 ]] && ok "D3: do_item_apply(object) on i1 returned 0 (reconciler routed)" \
                  || bad "D3: do_item_apply(object) returned $rc"

# Snapshot i1 latch BEFORE tf_fire so we can prove the auto-proceed handler
# did NOT touch it (it was already settled by the human's objection).
ica_i1_pre="$(ICA "$DID_D" i1)"
ist_i1_pre="$(ISTATE "$DID_D" i1)"
eq "$ica_i1_pre" "true" "D4: pre-fire — i1 latch already true (the objection's reconciler-dispatch IS the §7.4 once)"

# Now fire the window. i1's latch is already true ⇒ tf_fire's per-Item §7.4
# gate makes it an idempotent no-op for i1; i2 is still open and proceeds.
tf_fire "$BEARER" "$DID_D" >/dev/null 2>&1
rc=$?
[[ "$rc" -eq 0 ]] && ok "D5: tf_fire post-objection returned 0 (partial AD7)" \
                  || bad "D5: tf_fire returned $rc"

# i1 untouched (still reflects the reconciler-routed apply, NOT auto-proceed).
eq "$(ICA   "$DID_D" i1)" "$ica_i1_pre" "D6: objection path — i1 latch UNCHANGED by tf_fire (idempotent §7.4)"
eq "$(ISTATE "$DID_D" i1)" "$ist_i1_pre" "D7: objection path — i1 state UNCHANGED by tf_fire"
# Confirm the objected item's recorded response is the OBJECTION, not an
# auto-proceed approve (this is what proves "objection cancels the auto-
# proceed" for that specific item).
i1_decision="$(GET "$DID_D" | jq -r '.items[]|select(.id=="i1").response.decision // ""')"
eq "$i1_decision" "object" "D8: objection path — i1.response.decision == 'object' (NOT 'approve')"
i1_auto="$(GET "$DID_D" | jq -r '[.items[]|select(.id=="i1")][0].response.auto_proceed')"
# `null` ⇒ field absent ⇒ NOT a timer auto-proceed. `true` would mean tf_fire
# overwrote the human's objection (the exact regression we're guarding).
[[ "$i1_auto" != "true" ]] && ok "D9: objection path — i1.response.auto_proceed != true (it was NOT a timer auto-proceed; got '$i1_auto')" \
                           || bad "D9: objection path — i1.response.auto_proceed == true (tf_fire WRONGLY overwrote the objection)"

# Sibling i2 was un-objected ⇒ it DID auto-proceed.
eq "$(ICA   "$DID_D" i2)" "true"    "D10: objection path — un-objected sibling i2 auto-proceeds (AD7 partial)"
eq "$(ISTATE "$DID_D" i2)" "applied" "D11: objection path — sibling i2 state == applied"

# Both i1 and i2 are now off-`open` ⇒ the dossier never infinite-stalls (S-6
# AD7 invariant for a timed-fyi all-fyi-objectable overview).
open_fyi="$(GET "$DID_D" | jq -r '[.items[]|select(.kind=="fyi-objectable" and .state=="open")]|length' 2>/dev/null)"
eq "$open_fyi" "0" "D12: a timed-fyi overview never infinite-stalls — 0 fyi-objectable left open"

# ════════════════════════════════════════════════════════════════════════════
# PART E — NO new record type / NO new co op for Flow F (P2 contract proof)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART E — no new record type / no new co op (the contract proof) ──"

# A new record TYPE would have shown up as a sub-directory of $CO_STORE
# that isn't one of the existing §4 namespaces (`records/` is coordinator.sh's
# flat §4 record bucket; `timers/` is the §2.2 timer surface; `forensic/` is
# §10.3). The fact that everything above succeeded against the existing T4
# surface IS the proof; assert the structural shape so a future refactor that
# quietly introduces a new record namespace trips this guard.
new_type=""
while IFS= read -r d; do
  [[ -z "$d" ]] && continue
  case "$d" in
    records|timers|forensic|lease|desired|incidents|store|dossier-locks|locks|.*) ;;
    *) new_type="$d"; break ;;
  esac
done < <(find "$CO_STORE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | xargs -n1 basename 2>/dev/null)
[[ -z "$new_type" ]] && ok "E1: no new §4 record namespace introduced (subdirs ⊆ {records,timers,forensic,lease,desired,incidents,dossier-locks})" \
                    || bad "E1: NEW record namespace '$new_type' under $CO_STORE — Flow F MUST ride existing ops"

# The capability surface advertised by co.sh did NOT grow a tf_*/Flow-F op —
# binds the same §2 capability check test-timed-fyi.sh asserts.
caps="$(co_request "$BEARER" capabilities 2>/dev/null || true)"
case "$caps" in *tf_arm*|*flow-f*|*flow_f*) bad "E2: co capabilities advertise a Flow F / tf_* op (must not)";; *) ok "E2: co capabilities advertise NO Flow F / tf_* op (P2 contract: existing ops only)" ;; esac

# ════════════════════════════════════════════════════════════════════════════
echo ""
TOTAL=$((PASS+FAIL))
if [[ "$FAIL" -eq 0 ]]; then
  echo "════════════════════════════════════════════════════════════════════"
  echo " ALL_PASS $PASS/$TOTAL — claude-tools-0wy P2 acceptance verified"
  echo "════════════════════════════════════════════════════════════════════"
  exit 0
else
  echo "════════════════════════════════════════════════════════════════════"
  echo " FAIL $FAIL/$TOTAL — claude-tools-0wy P2 acceptance NOT verified"
  echo "════════════════════════════════════════════════════════════════════"
  exit 1
fi
