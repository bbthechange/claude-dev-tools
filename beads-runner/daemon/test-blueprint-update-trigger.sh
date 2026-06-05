#!/bin/bash
# beads-runner/daemon/test-blueprint-update-trigger.sh — H5
# (claude-tools-uxvh5; epic claude-tools-mhcp). DESIGN H design/blueprint.md §7.
#
# WHAT THIS PROVES (the bead's s6/s4 testing invariant — "drive the trigger
# predicate directly; a change emits ONE timed-fyi unified with Flow F, not a
# 2nd mechanism"):
#   PART 0 — the H5 functions exist in flow-f-overview-poll.sh and it parses.
#   PART A — daemon_blueprint_update_should_trigger: stage:design|impl|docs FIRE;
#            stage:idea|ux|tests, a bare value, and the empty string do NOT.
#            A trivial close ⇒ no redraw (§7.3 coarse gate).
#   PART B — daemon_blueprint_update__build_hat_input emits the §7.1 hat input
#            {project_ref,bead_ref,trigger_stage,current_blueprint}; a
#            missing/garbage current_blueprint degrades to JSON null (first
#            creation), never a broken object.
#   PART C — daemon_blueprint_update__shape_timed_fyi UNIFIES with Flow F: a
#            material change shapes the SAME generation_input shape as the Flow F
#            overview (kind=overview, tier=timed-fyi, trigger=stage_gate), threads
#            focus_id for the deep-link, and emits an empty items[] (pure FYI). A
#            NON-material hat output shapes to EMPTY (no FYI). This is the §6.5
#            "not a second mechanism" guarantee, asserted by equality against the
#            Flow F builder's own discriminators.
#   PART D — daemon_blueprint_update_dispatch_one happy path (overrides): hat
#            emits material_change:true ⇒ blueprint-put transport IS called with
#            the {derived,narrative,conflicts_append} payload, exactly ONE
#            timed-fyi is emitted through the SHARED _daemon_flow_f_engine_write
#            (same machinery), gi carries kind=overview/tier=timed-fyi,
#            outcome=dispatched.
#   PART E — idempotent + refuse: hat emits material_change:false ⇒ NO
#            blueprint-put, NO FYI, outcome=no-change; hat emits refuse:true ⇒
#            NO writes, outcome=refused (the real redraw gate is the hat's regen).
#   PART F — canary: DAEMON_BLUEPRINT_UPDATE_DISABLED=1 ⇒ no spawn,
#            outcome=disabled. (I5/uxvi5 flipped the DEFAULT to 0 = live; this
#            part sets =1 explicitly to prove the off-switch still short-circuits.)
#
# Run: bash beads-runner/daemon/test-blueprint-update-trigger.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
F_LIB="$HERE/flow-f-overview-poll.sh"
REGISTRY_LIB="$HERE/workspace-registry.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
eq()  { [[ "$1" == "$2" ]] && ok "$3" || bad "$3 (got '$1' want '$2')"; }
has() { case "$1" in *"$2"*) ok "$3";; *) bad "$3 (missing '$2')";; esac; }
nothas() { case "$1" in *"$2"*) bad "$3 (unexpectedly contains '$2')";; *) ok "$3";; esac; }

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " H5 blueprint-update trigger + change→timed-fyi — claude-tools-uxvh5"
echo "════════════════════════════════════════════════════════════════════"

# ════════════════════════════════════════════════════════════════════════════
# PART 0 — files exist, parse, helpers defined
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART 0 — files exist, parse, helpers defined ──"
[[ -f "$F_LIB" ]] && ok "flow-f-overview-poll.sh present" || bad "flow-f-overview-poll.sh missing"
bash -n "$F_LIB" 2>/dev/null && ok "flow-f-overview-poll.sh parses (bash -n clean)" || bad "flow-f-overview-poll.sh syntax"

for fn in daemon_blueprint_update_should_trigger \
          daemon_blueprint_update__list_structural_closes \
          daemon_blueprint_update__build_hat_input \
          daemon_blueprint_update__shape_timed_fyi \
          daemon_blueprint_update__extract_json \
          _daemon_blueprint_update_write_blueprint \
          daemon_blueprint_update_dispatch_one; do
  grep -q "^$fn()" "$F_LIB" && ok "defines $fn" || bad "missing $fn"
done

CACHE_DIR="$(mktemp -d)"
WD="$(mktemp -d)"
trap 'rm -rf "$CACHE_DIR" "$WD" 2>/dev/null || true' EXIT
export DAEMON_CACHE_DIR="$CACHE_DIR"

# shellcheck source=/dev/null
. "$REGISTRY_LIB" 2>/dev/null || { bad "could not source workspace-registry.sh"; exit 1; }
# shellcheck source=/dev/null
. "$F_LIB" 2>/dev/null || { bad "could not source flow-f-overview-poll.sh"; exit 1; }

# ════════════════════════════════════════════════════════════════════════════
# PART A — the structure-change coarse predicate (the bead's "drive it directly")
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART A — daemon_blueprint_update_should_trigger (coarse gate, §7.3) ──"
for s in stage:design stage:impl stage:docs; do
  daemon_blueprint_update_should_trigger "$s" && ok "FIRES on $s (structural close)" \
    || bad "should FIRE on $s"
done
for s in stage:idea stage:ux stage:tests stage:done; do
  daemon_blueprint_update_should_trigger "$s" && bad "should NOT fire on $s (trivial close ⇒ no redraw)" \
    || ok "no redraw on $s (trivial close, §7.3)"
done
# bare value form (accepts "impl" as "stage:impl")
daemon_blueprint_update_should_trigger "impl" && ok "bare 'impl' normalises to stage:impl ⇒ fires" \
  || bad "bare 'impl' should fire"
daemon_blueprint_update_should_trigger "tests" && bad "bare 'tests' should NOT fire" \
  || ok "bare 'tests' ⇒ no fire"
# empty / missing ⇒ no fire (defensive)
daemon_blueprint_update_should_trigger "" && bad "empty stage should NOT fire" \
  || ok "empty stage ⇒ no fire (defensive)"
daemon_blueprint_update_should_trigger && bad "missing arg should NOT fire" \
  || ok "missing arg ⇒ no fire (defensive)"

# ════════════════════════════════════════════════════════════════════════════
# PART B — the hat input contract (§7.1)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART B — daemon_blueprint_update__build_hat_input ──"
CUR='{"schema_version":1,"derived":{"nodes":[{"id":"domain:x"}],"edges":[],"apis":[]},"customization":{"renames":{}}}'
HI="$(daemon_blueprint_update__build_hat_input "rhythmGame" "rhythmGame-abc" "stage:impl" "$CUR")"
eq "$(jq -r '.project_ref' <<<"$HI")"   "rhythmGame"      "hat input carries project_ref"
eq "$(jq -r '.bead_ref' <<<"$HI")"      "rhythmGame-abc"  "hat input carries bead_ref"
eq "$(jq -r '.trigger_stage' <<<"$HI")" "stage:impl"      "hat input carries trigger_stage"
eq "$(jq -r '.current_blueprint.derived.nodes[0].id' <<<"$HI")" "domain:x" "hat input embeds the current blueprint"
# missing current_blueprint ⇒ JSON null (first creation)
HI0="$(daemon_blueprint_update__build_hat_input "ws" "ws-1" "stage:design" "")"
eq "$(jq -r '.current_blueprint' <<<"$HI0")" "null" "empty current_blueprint ⇒ null (first creation)"
# garbage current_blueprint ⇒ degrades to null, not a broken object
HIG="$(daemon_blueprint_update__build_hat_input "ws" "ws-1" "stage:design" "{not json")"
eq "$(jq -r '.current_blueprint' <<<"$HIG")" "null" "garbage current_blueprint ⇒ null (no broken object)"

# ════════════════════════════════════════════════════════════════════════════
# PART C — change→ONE-timed-fyi shaping UNIFIES with Flow F (§6.5/§7.4)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART C — daemon_blueprint_update__shape_timed_fyi (the §6.5 unification) ──"
HAT_MATERIAL='{"material_change":true,
  "derived":{"nodes":[{"id":"domain:messaging"}],"edges":[],"apis":[]},
  "narrative":{"tldr":"grew messaging","sections":[]},
  "conflicts_append":[],
  "focus_id":"domain:messaging",
  "summary":"Added the Messaging domain.",
  "overview":{"tldr":"The architecture grew a Messaging domain.","sections":[{"heading":"What changed","prose":"..."}],"full_detail":"A cold-readable paragraph."}}'
GI="$(daemon_blueprint_update__shape_timed_fyi "overview-rhythmGame-abc" "rhythmGame-abc" "$HAT_MATERIAL")"
eq "$(jq -r '.id' <<<"$GI")"       "overview-rhythmGame-abc" "shaped gi carries the deterministic dossier id"
eq "$(jq -r '.kind' <<<"$GI")"     "overview"                "shaped gi kind=overview (Flow F profile)"
eq "$(jq -r '.tier' <<<"$GI")"     "timed-fyi"               "shaped gi tier=timed-fyi (24h auto-proceed)"
eq "$(jq -r '.trigger' <<<"$GI")"  "stage_gate"              "shaped gi trigger=stage_gate (the §4.1 enum value)"
eq "$(jq -r '.bead_ref' <<<"$GI")" "rhythmGame-abc"          "shaped gi carries bead_ref"
eq "$(jq -r '.source.focus_id' <<<"$GI")" "domain:messaging" "shaped gi threads focus_id for the ?focus deep-link (§8.4)"
eq "$(jq -r '.source.tldr' <<<"$GI")" "The architecture grew a Messaging domain." "shaped gi preserves the authored overview tldr"
eq "$(jq -r '.source.authored_by' <<<"$GI")" "agent"          "shaped gi authored_by=agent (no fallback badge, 69u8)"
eq "$(jq -r '.source.authored_by_reason' <<<"$GI")" "blueprint_update_overview" "authored_by_reason names THIS producer"
eq "$(jq -r '.items | length' <<<"$GI")" "0"                  "shaped gi items[] empty (pure FYI; silence auto-proceeds)"

# THE UNIFICATION PROOF: the three discriminators MATCH what the Flow F overview
# builder itself produces ⇒ it is the SAME notification mechanism, not a 2nd one.
FLOW_F_GI="$(daemon_flow_f__build_generation_input "overview-x" "x" \
  '{"body":{"tldr":"t","sections":[],"diagrams":[],"full_detail":"d"},"items":[]}')"
eq "$(jq -r '.kind' <<<"$GI")"    "$(jq -r '.kind' <<<"$FLOW_F_GI")"    "kind matches the Flow F overview (unified, not a 2nd mechanism)"
eq "$(jq -r '.tier' <<<"$GI")"    "$(jq -r '.tier' <<<"$FLOW_F_GI")"    "tier matches the Flow F overview (one timed-fyi)"
eq "$(jq -r '.trigger' <<<"$GI")" "$(jq -r '.trigger' <<<"$FLOW_F_GI")" "trigger matches the Flow F overview (stage_gate)"

# A NON-material hat output shapes to EMPTY ⇒ the caller emits NO FYI.
GI_NONE="$(daemon_blueprint_update__shape_timed_fyi "overview-y" "y" '{"material_change":false}')"
eq "$GI_NONE" "" "non-material hat output ⇒ empty gi (no FYI emitted)"

# ════════════════════════════════════════════════════════════════════════════
# Build override stubs for the dispatch tests
# ════════════════════════════════════════════════════════════════════════════
BIN="$WD/bin"; mkdir -p "$BIN"
HAT_OUT_FILE="$WD/hat-out.json"
GET_OUT_FILE="$WD/get-out.json"
BP_SENTINEL="$WD/bp-write.called"
FYI_SENTINEL="$WD/fyi.gi"

# hat-stub: ignore args, print the contents of $HAT_OUT_FILE (env-passed path).
cat > "$BIN/hat-stub.sh" <<'EOF'
#!/bin/bash
cat "$HAT_OUT_FILE"
exit 0
EOF
chmod +x "$BIN/hat-stub.sh"

# get-stub: print the contents of $GET_OUT_FILE (the "current blueprint").
cat > "$BIN/get-stub.sh" <<'EOF'
#!/bin/bash
cat "$GET_OUT_FILE" 2>/dev/null || printf 'null'
exit 0
EOF
chmod +x "$BIN/get-stub.sh"

# bp-write-stub: record that blueprint-put was called + with what payload, rc 0.
cat > "$BIN/bp-write-stub.sh" <<'EOF'
#!/bin/bash
cp "$2" "$BP_SENTINEL" 2>/dev/null
exit 0
EOF
chmod +x "$BIN/bp-write-stub.sh"

# fyi-engine-stub: the reused DAEMON_FLOW_F_ENGINE_OVERRIDE — record the gi +
# print a fake dossier id (non-empty ⇒ "written") + rc 0.
cat > "$BIN/fyi-engine-stub.sh" <<'EOF'
#!/bin/bash
cp "$2" "$FYI_SENTINEL" 2>/dev/null
printf 'overview-written-fake'
exit 0
EOF
chmod +x "$BIN/fyi-engine-stub.sh"

export HAT_OUT_FILE GET_OUT_FILE BP_SENTINEL FYI_SENTINEL
export DAEMON_BLUEPRINT_UPDATE_HAT_OVERRIDE="$BIN/hat-stub.sh"
export DAEMON_BLUEPRINT_UPDATE_GET_OVERRIDE="$BIN/get-stub.sh"
export DAEMON_BLUEPRINT_UPDATE_BP_WRITE_OVERRIDE="$BIN/bp-write-stub.sh"
export DAEMON_FLOW_F_ENGINE_OVERRIDE="$BIN/fyi-engine-stub.sh"
printf 'null' > "$GET_OUT_FILE"

# ════════════════════════════════════════════════════════════════════════════
# PART D — dispatch_one happy path (material change ⇒ write + ONE timed-fyi)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART D — daemon_blueprint_update_dispatch_one (material ⇒ write + 1 FYI) ──"
printf '%s' "$HAT_MATERIAL" > "$HAT_OUT_FILE"
rm -f "$BP_SENTINEL" "$FYI_SENTINEL"
daemon_blueprint_update_dispatch_one "$WD" "rhythmGame" "" "" "rhythmGame-abc" "stage:impl"
OUTCOME="$DAEMON_BLUEPRINT_UPDATE_LAST_OUTCOME"
eq "$OUTCOME" "dispatched" "material change ⇒ outcome=dispatched"
[[ -f "$BP_SENTINEL" ]] && ok "blueprint-put transport WAS called (the map was written)" \
  || bad "blueprint-put transport not called on a material change"
if [[ -f "$BP_SENTINEL" ]]; then
  eq "$(jq -r '.derived.nodes[0].id' "$BP_SENTINEL")" "domain:messaging" "blueprint-put payload carries the regenerated derived"
fi
[[ -f "$FYI_SENTINEL" ]] && ok "exactly one timed-fyi emitted via the SHARED Flow F engine write" \
  || bad "no timed-fyi emitted on a material change"
if [[ -f "$FYI_SENTINEL" ]]; then
  eq "$(jq -r '.kind' "$FYI_SENTINEL")" "overview"  "emitted FYI gi kind=overview (unified with Flow F)"
  eq "$(jq -r '.tier' "$FYI_SENTINEL")" "timed-fyi" "emitted FYI gi tier=timed-fyi"
  eq "$(jq -r '.source.focus_id' "$FYI_SENTINEL")" "domain:messaging" "emitted FYI deep-links the changed slice (focus_id)"
fi

# ════════════════════════════════════════════════════════════════════════════
# PART E — idempotent no-op + honest refuse (the real redraw gate)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART E — idempotent no-op + refuse (no write, no FYI) ──"
printf '%s' '{"material_change":false}' > "$HAT_OUT_FILE"
rm -f "$BP_SENTINEL" "$FYI_SENTINEL"
daemon_blueprint_update_dispatch_one "$WD" "rhythmGame" "" "" "rhythmGame-abc" "stage:impl"
OUTCOME="$DAEMON_BLUEPRINT_UPDATE_LAST_OUTCOME"
eq "$OUTCOME" "no-change" "material_change:false ⇒ outcome=no-change (idempotent gate)"
[[ ! -f "$BP_SENTINEL" ]] && ok "NO blueprint-put on a non-material close (no redraw)" \
  || bad "blueprint-put called on a non-material close (must no-op)"
[[ ! -f "$FYI_SENTINEL" ]] && ok "NO timed-fyi on a non-material close (no spam)" \
  || bad "timed-fyi emitted on a non-material close (must no-op)"

printf '%s' '{"material_change":false,"refuse":true,"reason":"bare scaffold, no honest map yet"}' > "$HAT_OUT_FILE"
rm -f "$BP_SENTINEL" "$FYI_SENTINEL"
daemon_blueprint_update_dispatch_one "$WD" "rhythmGame" "" "" "rhythmGame-abc" "stage:design"
OUTCOME="$DAEMON_BLUEPRINT_UPDATE_LAST_OUTCOME"
eq "$OUTCOME" "refused" "refuse:true ⇒ outcome=refused"
[[ ! -f "$BP_SENTINEL" && ! -f "$FYI_SENTINEL" ]] && ok "refuse ⇒ no write, no FYI (honest empty state preserved)" \
  || bad "refuse must not write or emit"

# ════════════════════════════════════════════════════════════════════════════
# PART G — tolerant parse: a prose preamble before the JSON still dispatches
#          (claude-tools-03q2 — opus prepended a sentence; the parser must not
#          silently no-op a good run to parse-failed)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART G — tolerant stdout parse (prose preamble ⇒ still dispatched) ──"

# Unit: the extractor recovers the object from drifted stdout, untouched on the
# obedient path, and yields nothing on genuine non-object output.
eq "$(daemon_blueprint_update__extract_json '{"material_change":true}')" \
   '{"material_change":true}' "extract: obedient single object passes through unchanged"
eq "$(daemon_blueprint_update__extract_json "$(printf 'I now have a confirmed picture. Emitting v1.\n\n{"a":1}')" | jq -r '.a')" \
   "1" "extract: leading prose preamble ⇒ object recovered"
eq "$(daemon_blueprint_update__extract_json "$(printf '{"a":2}\n\nThat is the v1 map.')" | jq -r '.a')" \
   "2" "extract: trailing prose ⇒ object recovered"
eq "$(daemon_blueprint_update__extract_json 'preamble {"x":{"y":3}} trailer' | jq -r '.x.y')" \
   "3" "extract: nested object preserved through first-{..last-} slice"
eq "$(daemon_blueprint_update__extract_json "$(printf '```json\n{"a":4}\n```')" | jq -r '.a')" \
   "4" "extract: a Markdown-fenced object is recovered"
eq "$(daemon_blueprint_update__extract_json '[1,2,3]')" "" "extract: a scalar JSON array is not an object ⇒ empty"
eq "$(daemon_blueprint_update__extract_json '[{"a":1},{"b":2}]')" "" \
   "extract: an ARRAY OF OBJECTS fails safe (slice is a 2-value stream ⇒ empty, not the first element)"
eq "$(daemon_blueprint_update__extract_json '{"a":1}{"b":2}')" "" \
   "extract: two bare objects ⇒ ambiguous ⇒ empty (no silent first-value pick)"
eq "$(daemon_blueprint_update__extract_json 'no json here at all')" "" "extract: pure prose ⇒ empty (parse-failed)"

# Integration: dispatch_one with the real opus drift shape ⇒ writes + ONE FYI.
PREAMBLE='I now have a confirmed, accurate picture: the Messaging domain is real. Emitting v1.'
printf '%s\n\n%s' "$PREAMBLE" "$HAT_MATERIAL" > "$HAT_OUT_FILE"
rm -f "$BP_SENTINEL" "$FYI_SENTINEL"
daemon_blueprint_update_dispatch_one "$WD" "rhythmGame" "" "" "rhythmGame-abc" "stage:impl"
OUTCOME="$DAEMON_BLUEPRINT_UPDATE_LAST_OUTCOME"
eq "$OUTCOME" "dispatched" "prose-prefixed hat stdout ⇒ outcome=dispatched (NOT parse-failed)"
[[ -f "$BP_SENTINEL" ]] && ok "blueprint-put WAS called despite the preamble" \
  || bad "blueprint-put not called — preamble was rejected"
if [[ -f "$BP_SENTINEL" ]]; then
  eq "$(jq -r '.derived.nodes[0].id' "$BP_SENTINEL")" "domain:messaging" "recovered payload carries the regenerated derived"
fi
[[ -f "$FYI_SENTINEL" ]] && ok "exactly one timed-fyi emitted despite the preamble" \
  || bad "no timed-fyi emitted — preamble was rejected"

# ════════════════════════════════════════════════════════════════════════════
# PART H — claude-tools-49rx: a transient timed-fyi emit failure stashes the gi
#          (the map is written; the ping is OWED, not lost). On a material change
#          the unit writes the Blueprint FIRST, then emits ONE timed-fyi; if that
#          emit transiently fails, outcome=fyi-failed AND the shaped gi is parked
#          in DAEMON_BLUEPRINT_UPDATE_LAST_GI so the next cadence (the I5 poll)
#          re-emits ONLY the FYI instead of re-running the idempotent hat (which
#          would see no material change and silently drop the overview ping).
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART H — transient FYI failure stashes the gi (claude-tools-49rx) ──"
# A failing engine override: print no id, nonzero rc (the transient emit failure).
cat > "$BIN/fyi-engine-fail-stub.sh" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$BIN/fyi-engine-fail-stub.sh"
printf '%s' "$HAT_MATERIAL" > "$HAT_OUT_FILE"
rm -f "$BP_SENTINEL" "$FYI_SENTINEL"
SAVE_ENGINE="$DAEMON_FLOW_F_ENGINE_OVERRIDE"
export DAEMON_FLOW_F_ENGINE_OVERRIDE="$BIN/fyi-engine-fail-stub.sh"
daemon_blueprint_update_dispatch_one "$WD" "rhythmGame" "" "" "rhythmGame-abc" "stage:impl"
OUTCOME="$DAEMON_BLUEPRINT_UPDATE_LAST_OUTCOME"
STASHED="$DAEMON_BLUEPRINT_UPDATE_LAST_GI"
export DAEMON_FLOW_F_ENGINE_OVERRIDE="$SAVE_ENGINE"
eq "$OUTCOME" "fyi-failed" "H1: transient FYI emit failure ⇒ outcome=fyi-failed"
[[ -f "$BP_SENTINEL" ]] && ok "H2: the map WAS written before the FYI (blueprint-put called)" \
  || bad "H2: map not written (5a must precede 5b)"
[[ ! -f "$FYI_SENTINEL" ]] && ok "H3: no FYI landed (the emit failed)" \
  || bad "H3: FYI unexpectedly landed"
[[ -n "$STASHED" ]] && ok "H4: the shaped gi is stashed for an FYI-only retry (ping owed, not lost)" \
  || bad "H4: gi not stashed — the ping would be silently dropped on the no-change retry"
if [[ -n "$STASHED" ]]; then
  eq "$(jq -r '.kind' <<<"$STASHED")" "overview"               "H5: stashed gi is the unified kind=overview"
  eq "$(jq -r '.tier' <<<"$STASHED")" "timed-fyi"              "H6: stashed gi tier=timed-fyi"
  eq "$(jq -r '.id' <<<"$STASHED")"   "overview-rhythmGame-abc" "H7: stashed gi carries the deterministic id (idempotent re-emit)"
fi
# A clean dispatch (success path) leaves the stash empty — no stale gi leaks.
printf '%s' "$HAT_MATERIAL" > "$HAT_OUT_FILE"
rm -f "$BP_SENTINEL" "$FYI_SENTINEL"
daemon_blueprint_update_dispatch_one "$WD" "rhythmGame" "" "" "rhythmGame-abc" "stage:impl"
eq "$DAEMON_BLUEPRINT_UPDATE_LAST_OUTCOME" "dispatched" "H8: the engine recovers ⇒ outcome=dispatched"
eq "$DAEMON_BLUEPRINT_UPDATE_LAST_GI" "" "H9: a successful dispatch leaves NO stashed gi (reset per call)"

# ════════════════════════════════════════════════════════════════════════════
# PART F — canary: disabled ⇒ no spawn (I5 turns it live + parallel)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART F — canary (DAEMON_BLUEPRINT_UPDATE_DISABLED) ──"
rm -f "$BP_SENTINEL" "$FYI_SENTINEL"
# With the HAT override UNSET + the canary set =1, dispatch must short-circuit.
SAVE_OV="$DAEMON_BLUEPRINT_UPDATE_HAT_OVERRIDE"
DAEMON_BLUEPRINT_UPDATE_HAT_OVERRIDE=""
DAEMON_BLUEPRINT_UPDATE_DISABLED=1
daemon_blueprint_update_dispatch_one "$WD" "rhythmGame" "" "" "rhythmGame-abc" "stage:impl"
OUTCOME="$DAEMON_BLUEPRINT_UPDATE_LAST_OUTCOME"
DAEMON_BLUEPRINT_UPDATE_HAT_OVERRIDE="$SAVE_OV"
eq "$OUTCOME" "disabled" "canary off-switch (=1) ⇒ outcome=disabled, no spawn (default is now 0=live, I5/uxvi5)"
[[ ! -f "$BP_SENTINEL" && ! -f "$FYI_SENTINEL" ]] && ok "canary ⇒ no write, no FYI" \
  || bad "canary must not write or emit"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " RESULT — PASS=$PASS FAIL=$FAIL"
echo "════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]] && { echo "ALL_PASS (H5 blueprint-update trigger — claude-tools-uxvh5)"; exit 0; } \
                    || { echo "SOME_FAIL"; exit 1; }
