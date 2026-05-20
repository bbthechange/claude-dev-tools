#!/bin/bash
# beads-runner/daemon/test-flow-f-overview.sh — P1 Flow F stage-change observer
# (claude-tools-3pq; epic claude-tools-kie).
#
# WHAT THIS PROVES
#   PART 0 — files exist, parse, helpers are defined, daemon.sh is wired.
#   PART A — daemon_flow_f__safe_key sanitises bd ids for filename use;
#            daemon_flow_f_marker_for echoes a path under the cache dir;
#            already_fired ⇄ write_marker round-trip is idempotent.
#   PART B — daemon_flow_f__build_builder_input emits a JSON object with
#            the dossier-builder's expected shape (dossier_id, bead_ref,
#            workspace_dir, question, context_dump) and the context_dump
#            explicitly forbids pick-option (Flow F discipline).
#   PART C — daemon_flow_f__build_generation_input wraps {body,items[]}
#            into a generation_input with kind=overview, tier=timed-fyi,
#            trigger=stage_<stage>_close.
#   PART D — daemon_flow_f_seed_if_needed creates per-bead markers for the
#            existing closed-at-stage backlog WITHOUT dispatching, and drops
#            the seed flag; idempotent on second call.
#   PART E — daemon_flow_f_dispatch_one happy path: builder override emits
#            a real {body,items[]}, engine override is called with the gi
#            JSON, marker lands with outcome=dispatched.
#   PART F — refusal path: builder emits {refuse:true,reason:...}; marker
#            lands with outcome=builder-refused; engine is NOT called.
#   PART G — failure paths: builder exit!=0 ⇒ marker outcome=builder-failed;
#            non-JSON stdout ⇒ outcome=parse-failed; missing body ⇒
#            outcome=shape-failed; engine returning empty ⇒ NO marker
#            (retried next poll).
#   PART H — daemon_flow_f_poll_once skips already-fired beads on a second
#            call (one-per-bead-ever dedup holds across polls).
#   PART I — daemon.sh wires flow-f-overview-poll.sh into the main loop
#            (sourced + FLOW_F_POLL_INTERVAL declared + driver call site).
#
# Run: bash beads-runner/daemon/test-flow-f-overview.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
DAEMON_SH="$HERE/daemon.sh"
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
echo " P1 Flow F stage-change observer — claude-tools-3pq (epic claude-tools-kie)"
echo "════════════════════════════════════════════════════════════════════"

# ════════════════════════════════════════════════════════════════════════════
# PART 0 — files exist, parse, are wired
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART 0 — files exist, parse, helpers defined ──"
[[ -f "$F_LIB" ]] && ok "flow-f-overview-poll.sh present" || bad "flow-f-overview-poll.sh missing"
bash -n "$F_LIB" 2>/dev/null && ok "flow-f-overview-poll.sh parses (bash -n clean)" || bad "flow-f-overview-poll.sh syntax"
bash -n "$DAEMON_SH" 2>/dev/null && ok "daemon.sh parses with Flow F wiring" || bad "daemon.sh syntax"

for fn in daemon_flow_f__safe_key daemon_flow_f_marker_for \
          daemon_flow_f_already_fired daemon_flow_f_write_marker \
          daemon_flow_f__list_closed_at_stage daemon_flow_f_seed_if_needed \
          daemon_flow_f__build_builder_input \
          daemon_flow_f__build_generation_input \
          _daemon_flow_f_engine_write \
          daemon_flow_f_dispatch_one \
          daemon_flow_f__poll_workspace \
          daemon_flow_f_poll_once; do
  grep -q "^$fn()" "$F_LIB" && ok "flow-f-overview-poll.sh defines $fn" || bad "flow-f-overview-poll.sh defines $fn"
done

# ════════════════════════════════════════════════════════════════════════════
# Set up a hermetic cache dir + load the registry + the lib.
# ════════════════════════════════════════════════════════════════════════════
CACHE_DIR="$(mktemp -d)"
trap 'rm -rf "$CACHE_DIR" "${WD:-}" 2>/dev/null || true' EXIT
export DAEMON_CACHE_DIR="$CACHE_DIR"
export DAEMON_FLOW_F_FIRED_DIR="$CACHE_DIR/flow-f-overview-fired"
export DAEMON_FLOW_F_SEED_FLAG="$CACHE_DIR/flow-f-overview-seeded.flag"

# shellcheck source=/dev/null
. "$REGISTRY_LIB" 2>/dev/null || { bad "could not source workspace-registry.sh"; exit 1; }
# shellcheck source=/dev/null
. "$F_LIB" 2>/dev/null || { bad "could not source flow-f-overview-poll.sh"; exit 1; }

# ════════════════════════════════════════════════════════════════════════════
# PART A — safe_key + marker round-trip
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART A — safe_key + marker round-trip ──"

eq "$(daemon_flow_f__safe_key "claude-tools-3pq")" "claude-tools-3pq" "A1: ordinary bd id passes through"
eq "$(daemon_flow_f__safe_key "evil/../path")" "evil___path" "A2: '/' and '..' get neutralised (no path-traversal)"
eq "$(daemon_flow_f__safe_key "ok name with space")" "ok_name_with_space" "A3: spaces collapsed to '_'"

mf="$(daemon_flow_f_marker_for "claude-tools-3pq")"
case "$mf" in
  "$CACHE_DIR/flow-f-overview-fired/claude-tools-3pq.json") ok "A4: marker path lives under DAEMON_FLOW_F_FIRED_DIR" ;;
  *) bad "A4: unexpected marker path '$mf'" ;;
esac

daemon_flow_f_already_fired "claude-tools-3pq" && bad "A5: not-yet-fired bead reported as already-fired" || ok "A5: not-yet-fired bead correctly reports false"
daemon_flow_f_write_marker "claude-tools-3pq" "/ws/a" "dispatched" "overview-claude-tools-3pq"
daemon_flow_f_already_fired "claude-tools-3pq" && ok "A6: marker write ⇒ already_fired true on next read" || bad "A6: marker write did NOT make already_fired true"
[[ -f "$mf" ]] && ok "A7: marker file exists on disk" || bad "A7: marker file missing"

# Marker content sanity.
jq -e --arg b "claude-tools-3pq" '.bead_ref==$b' "$mf" >/dev/null 2>&1 && ok "A8: marker carries bead_ref" || bad "A8: marker bead_ref"
jq -e '.outcome=="dispatched"' "$mf" >/dev/null 2>&1 && ok "A9: marker carries outcome" || bad "A9: marker outcome"
jq -e '.dossier_id=="overview-claude-tools-3pq"' "$mf" >/dev/null 2>&1 && ok "A10: marker carries dossier_id" || bad "A10: marker dossier_id"

# Idempotent re-write (a second call doesn't crash; payload is overwritten).
daemon_flow_f_write_marker "claude-tools-3pq" "/ws/a" "dispatched" "overview-claude-tools-3pq"
ok "A11: write_marker is idempotent on re-call"

# ════════════════════════════════════════════════════════════════════════════
# PART B — build_builder_input shape
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART B — build_builder_input shape ──"

bi="$(daemon_flow_f__build_builder_input "overview-claude-tools-zzz" "claude-tools-zzz" "/tmp/ws")"
printf '%s' "$bi" | jq -e 'type=="object"' >/dev/null 2>&1 && ok "B1: builder input is a JSON object" || bad "B1: builder input not JSON"
eq "$(printf '%s' "$bi" | jq -r '.dossier_id')"   "overview-claude-tools-zzz" "B2: dossier_id passed through"
eq "$(printf '%s' "$bi" | jq -r '.bead_ref')"     "claude-tools-zzz"          "B3: bead_ref passed through"
eq "$(printf '%s' "$bi" | jq -r '.workspace_dir')" "/tmp/ws"                  "B4: workspace_dir passed through"
[[ -n "$(printf '%s' "$bi" | jq -r '.question')" ]] && ok "B5: question is non-empty (overview framing)" || bad "B5: empty question"
cd_text="$(printf '%s' "$bi" | jq -r '.context_dump')"
has "$cd_text" "FLOW F TRIGGER"      "B6: context_dump declares the Flow F trigger explicitly"
has "$cd_text" "stage:design"        "B7: context_dump names the watched stage label"
has "$cd_text" "DO NOT emit a"       "B8: context_dump forbids pick-option (Flow F item discipline)"
has "$cd_text" "fyi-objectable"      "B9: context_dump names the allowed item kind"
has "$cd_text" "timed-fyi"           "B10: context_dump names the tier"

# ════════════════════════════════════════════════════════════════════════════
# PART C — build_generation_input shape
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART C — build_generation_input shape (kind=overview, tier=timed-fyi) ──"

# A polished builder output: deep body + ONE fyi-objectable item.
builder_out=$(jq -cn '{
  body: { tldr: "the deep body", sections: [{heading:"How it fits",prose:"…"}], diagrams: [], full_detail: "…stand-alone prose…" },
  items: [ { id:"overview-claude-tools-zzz-i1", kind:"fyi-objectable", framing:{ask:"a small claim",why:"why"}, context_anchor:{where:"…",expansion:"…"}, consequence_block:{creates:[],unblocks:[],labels:[],status_changes:[]}, reversible:"fully reversible" } ]
}')
gi="$(daemon_flow_f__build_generation_input "overview-claude-tools-zzz" "claude-tools-zzz" "$builder_out")"
printf '%s' "$gi" | jq -e 'type=="object"' >/dev/null 2>&1 && ok "C1: gi is a JSON object" || bad "C1: gi not JSON"
eq "$(printf '%s' "$gi" | jq -r '.id')"        "overview-claude-tools-zzz" "C2: gi.id == deterministic dossier id"
eq "$(printf '%s' "$gi" | jq -r '.bead_ref')"  "claude-tools-zzz"          "C3: gi.bead_ref"
eq "$(printf '%s' "$gi" | jq -r '.kind')"      "overview"                  "C4: gi.kind == overview (C2 OPEN discriminator)"
eq "$(printf '%s' "$gi" | jq -r '.trigger')"   "stage_gate"                "C5: gi.trigger == stage_gate (the §4.1 enum value; INTERFACE.md line 242)"
eq "$(printf '%s' "$gi" | jq -r '.tier')"      "timed-fyi"                 "C6: gi.tier == timed-fyi (24h auto-proceed)"
eq "$(printf '%s' "$gi" | jq -r '.timer_fire_at')" "null"                   "C7: timer_fire_at left null — tf_arm computes it"
eq "$(printf '%s' "$gi" | jq -r '.source.tldr')" "the deep body"            "C8: source.tldr preserved from builder body"
eq "$(printf '%s' "$gi" | jq -r '.source.full_detail')" "…stand-alone prose…" "C9: source.full_detail preserved"
eq "$(printf '%s' "$gi" | jq -r '.source.sections|length')" "1"             "C10: source.sections preserved"
eq "$(printf '%s' "$gi" | jq -r '.items|length')"  "1"                      "C11: items[] preserved"
eq "$(printf '%s' "$gi" | jq -r '.items[0].kind')" "fyi-objectable"         "C12: item kind preserved as fyi-objectable"

# Stage-label override is preserved as a daemon-side observation knob (e.g.,
# extending to stage:impl), but the §4.1 trigger field is the FROZEN enum
# value `stage_gate` regardless of which stage tripped the observer — the
# stage-granular info travels via the bead's labels + bead_ref, never the
# trigger field (P2/claude-tools-0wy: the dossier substrate refuses an
# out-of-enum trigger; nothing downstream branches on the value).
gi2="$(DAEMON_FLOW_F_STAGE_LABEL='stage:impl' daemon_flow_f__build_generation_input "overview-claude-tools-zzz" "claude-tools-zzz" "$builder_out")"
eq "$(printf '%s' "$gi2" | jq -r '.trigger')" "stage_gate" "C13: trigger stays stage_gate across stage-label overrides"

# ════════════════════════════════════════════════════════════════════════════
# PART D — seed-on-first-run does NOT dispatch; it just lays markers
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART D — seed-on-first-run marks backlog WITHOUT dispatching ──"

# Reset the cache state from PART A.
rm -rf "$DAEMON_FLOW_F_FIRED_DIR" "$DAEMON_FLOW_F_SEED_FLAG" 2>/dev/null
mkdir -p "$DAEMON_FLOW_F_FIRED_DIR"

# Build a fake workspace whose `bd` shim returns two closed stage:design
# beads. The shim lives in a temp dir prepended to PATH.
WD="$(mktemp -d)"
WS_DIR="$WD/ws"
SHIM_DIR="$WD/shim"
mkdir -p "$WS_DIR" "$SHIM_DIR"
cat > "$SHIM_DIR/bd" <<EOF
#!/usr/bin/env bash
# Test shim: emulate \`bd list --label stage:design --status closed --all --flat --no-pager --json\`.
# Logs every invocation so failures are debuggable.
echo "BD-SHIM-CALLED args=\$*" >> "$WD/bd-shim.log"
# Pattern-match any list call carrying both --label stage:design AND
# --status closed; everything else echoes [] so secondary calls are no-ops.
args="\$*"
if [[ "\$args" == *"list"* && "\$args" == *"stage:design"* && "\$args" == *"closed"* ]]; then
  printf '%s\n' '[{"id":"claude-tools-aa1","status":"closed","labels":["stage:design"]},{"id":"claude-tools-bb2","status":"closed","labels":["stage:design"]}]'
else
  printf '[]\n'
fi
EOF
chmod +x "$SHIM_DIR/bd"
export PATH="$SHIM_DIR:$PATH"

REGISTRY_PROJECT_REFS=("alpha")
REGISTRY_DIRS=("$WS_DIR")
REGISTRY_COORDINATOR_URLS=("")
REGISTRY_TOKEN_KEYCHAIN_ITEMS=("")
REGISTRY_LOADED=1

# Sanity check: the list helper returns the two ids.
listed="$(daemon_flow_f__list_closed_at_stage "$WS_DIR" | tr '\n' ',' | sed 's/,$//')"
eq "$listed" "claude-tools-aa1,claude-tools-bb2" "D1: list_closed_at_stage returns both seeded ids"

# Seed. Should create two markers and the flag file; NO dispatch even with
# an aggressive engine-override (we set one and verify it was NOT called).
called_flag="$WD/engine-called.flag"
cat > "$WD/engine-override.sh" <<EOF
#!/usr/bin/env bash
echo "ENGINE-CALLED" > "$called_flag"
printf 'overview-fake'
EOF
chmod +x "$WD/engine-override.sh"
export DAEMON_FLOW_F_ENGINE_OVERRIDE="$WD/engine-override.sh"
# Builder override too — should also NOT be called during seed.
cat > "$WD/builder-override.sh" <<EOF
#!/usr/bin/env bash
echo "BUILDER-CALLED" >> "$WD/builder-called.log"
echo '{"refuse":true,"reason":"should not be called during seed"}'
EOF
chmod +x "$WD/builder-override.sh"
export DAEMON_FLOW_F_BUILDER_OVERRIDE="$WD/builder-override.sh"

daemon_flow_f_seed_if_needed
[[ -f "$DAEMON_FLOW_F_SEED_FLAG" ]] && ok "D2: seed flag dropped" || bad "D2: seed flag missing"
daemon_flow_f_already_fired "claude-tools-aa1" && ok "D3: aa1 marker landed during seed" || bad "D3: aa1 marker missing"
daemon_flow_f_already_fired "claude-tools-bb2" && ok "D4: bb2 marker landed during seed" || bad "D4: bb2 marker missing"
jq -e '.outcome=="seeded"' "$DAEMON_FLOW_F_FIRED_DIR/claude-tools-aa1.json" >/dev/null 2>&1 \
  && ok "D5: aa1 marker outcome=seeded (no dispatch)" || bad "D5: aa1 marker outcome wrong"
[[ ! -f "$called_flag" ]] && ok "D6: engine override was NOT called during seed (no dispatch on backlog)" || bad "D6: engine called during seed"
[[ ! -f "$WD/builder-called.log" ]] && ok "D7: builder override was NOT called during seed" || bad "D7: builder called during seed"

# Idempotent: second seed is a no-op.
prev_mtime="$(stat -f %m "$DAEMON_FLOW_F_SEED_FLAG" 2>/dev/null || stat -c %Y "$DAEMON_FLOW_F_SEED_FLAG" 2>/dev/null)"
daemon_flow_f_seed_if_needed
cur_mtime="$(stat -f %m "$DAEMON_FLOW_F_SEED_FLAG" 2>/dev/null || stat -c %Y "$DAEMON_FLOW_F_SEED_FLAG" 2>/dev/null)"
eq "$prev_mtime" "$cur_mtime" "D8: seed is idempotent (flag not re-touched)"

# Clear overrides for the next parts.
unset DAEMON_FLOW_F_ENGINE_OVERRIDE DAEMON_FLOW_F_BUILDER_OVERRIDE

# ════════════════════════════════════════════════════════════════════════════
# PART E — dispatch_one happy path (builder + engine overrides)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART E — dispatch_one happy path (override builder + engine) ──"

# Capture the gi the engine override receives so we can assert on it.
captured_gi="$WD/captured-gi.json"
captured_ws="$WD/captured-ws.txt"
cat > "$WD/engine-override.sh" <<EOF
#!/usr/bin/env bash
echo "\$1" > "$captured_ws"
cp "\$2" "$captured_gi"
printf 'overview-claude-tools-cc3'
EOF
chmod +x "$WD/engine-override.sh"
export DAEMON_FLOW_F_ENGINE_OVERRIDE="$WD/engine-override.sh"

# Builder override echoes a real polished body+items[] on stdout.
cat > "$WD/builder-override.sh" <<'EOF'
#!/usr/bin/env bash
# Read --context-file=PATH so we don't depend on stdin pipe shape; the lib
# passes --context-file in argv. We do not actually need to read it for the
# test — just emit a deterministic polished output.
cat <<'JSON'
{ "body": { "tldr":"how cc3 fits together", "sections":[{"heading":"What landed","prose":"…"}], "diagrams":[], "full_detail":"…stand-alone prose…" },
  "items": [ { "id":"overview-claude-tools-cc3-i1", "kind":"fyi-objectable", "framing":{"ask":"is this right?","why":"because Brian should know"}, "context_anchor":{"where":"epic kie","expansion":"…"}, "consequence_block":{"creates":[],"unblocks":[],"labels":[],"status_changes":[]}, "reversible":"fully reversible" } ] }
JSON
EOF
chmod +x "$WD/builder-override.sh"
export DAEMON_FLOW_F_BUILDER_OVERRIDE="$WD/builder-override.sh"

# Issue the dispatch.
rm -f "$DAEMON_FLOW_F_FIRED_DIR/claude-tools-cc3.json" 2>/dev/null
daemon_flow_f_dispatch_one "$WS_DIR" "alpha" "" "" "claude-tools-cc3"

# Engine was called.
[[ -f "$captured_gi" ]] && ok "E1: engine override was called with a gi JSON file" || bad "E1: engine override not called"
eq "$(cat "$captured_ws" 2>/dev/null)" "$WS_DIR" "E2: engine override was called with the workspace path"

# Captured gi has the right shape.
eq "$(jq -r '.id'      "$captured_gi" 2>/dev/null)" "overview-claude-tools-cc3" "E3: gi.id is the deterministic dossier id"
eq "$(jq -r '.kind'    "$captured_gi" 2>/dev/null)" "overview"                  "E4: gi.kind == overview"
eq "$(jq -r '.tier'    "$captured_gi" 2>/dev/null)" "timed-fyi"                 "E5: gi.tier == timed-fyi"
eq "$(jq -r '.trigger' "$captured_gi" 2>/dev/null)" "stage_gate"                "E6: gi.trigger == stage_gate (§4.1 enum)"
eq "$(jq -r '.bead_ref' "$captured_gi" 2>/dev/null)" "claude-tools-cc3"         "E7: gi.bead_ref"
eq "$(jq -r '.items[0].kind' "$captured_gi" 2>/dev/null)" "fyi-objectable"     "E8: item kind preserved as fyi-objectable"

# Marker landed with outcome=dispatched.
mf3="$DAEMON_FLOW_F_FIRED_DIR/claude-tools-cc3.json"
[[ -f "$mf3" ]] && ok "E9: marker written" || bad "E9: marker missing"
jq -e '.outcome=="dispatched"' "$mf3" >/dev/null 2>&1 && ok "E10: marker outcome=dispatched" || bad "E10: marker outcome wrong ($(jq -r '.outcome' "$mf3" 2>/dev/null))"
jq -e '.dossier_id=="overview-claude-tools-cc3"' "$mf3" >/dev/null 2>&1 && ok "E11: marker captures returned dossier id" || bad "E11: marker dossier_id wrong"

# Already-fired ⇒ a second dispatch_one is a no-op (already checked by the
# poll-level loop, but exercising directly here).
> "$captured_ws"
> "$captured_gi"

# ════════════════════════════════════════════════════════════════════════════
# PART F — refusal path
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART F — builder refusal ⇒ marker outcome=builder-refused, NO engine call ──"

cat > "$WD/builder-override.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"refuse":true,"reason":"the bead is too thin to anchor a real overview"}'
EOF
chmod +x "$WD/builder-override.sh"
> "$captured_gi"
> "$captured_ws"
daemon_flow_f_dispatch_one "$WS_DIR" "alpha" "" "" "claude-tools-dd4"
mf4="$DAEMON_FLOW_F_FIRED_DIR/claude-tools-dd4.json"
[[ -f "$mf4" ]] && ok "F1: refusal marker written" || bad "F1: refusal marker missing"
jq -e '.outcome=="builder-refused"' "$mf4" >/dev/null 2>&1 && ok "F2: marker outcome=builder-refused" || bad "F2: marker outcome wrong"
[[ ! -s "$captured_gi" ]] && ok "F3: engine override NOT called on refusal" || bad "F3: engine called despite refusal"

# ════════════════════════════════════════════════════════════════════════════
# PART G — failure paths
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART G — failure paths ──"

# G1: builder exits non-zero ⇒ marker outcome=builder-failed.
cat > "$WD/builder-override.sh" <<'EOF'
#!/usr/bin/env bash
echo "broken output"
exit 7
EOF
chmod +x "$WD/builder-override.sh"
daemon_flow_f_dispatch_one "$WS_DIR" "alpha" "" "" "claude-tools-ee5"
mf5="$DAEMON_FLOW_F_FIRED_DIR/claude-tools-ee5.json"
jq -e '.outcome=="builder-failed"' "$mf5" >/dev/null 2>&1 && ok "G1: builder exit!=0 ⇒ marker outcome=builder-failed" || bad "G1: builder fail marker wrong"

# G2: non-JSON stdout ⇒ marker outcome=parse-failed.
cat > "$WD/builder-override.sh" <<'EOF'
#!/usr/bin/env bash
echo "this is not JSON at all"
EOF
chmod +x "$WD/builder-override.sh"
daemon_flow_f_dispatch_one "$WS_DIR" "alpha" "" "" "claude-tools-ff6"
mf6="$DAEMON_FLOW_F_FIRED_DIR/claude-tools-ff6.json"
jq -e '.outcome=="parse-failed"' "$mf6" >/dev/null 2>&1 && ok "G2: non-JSON stdout ⇒ marker outcome=parse-failed" || bad "G2: parse fail marker wrong"

# G3: missing body ⇒ marker outcome=shape-failed (NOT refused).
cat > "$WD/builder-override.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"items":[]}'
EOF
chmod +x "$WD/builder-override.sh"
daemon_flow_f_dispatch_one "$WS_DIR" "alpha" "" "" "claude-tools-gg7"
mf7="$DAEMON_FLOW_F_FIRED_DIR/claude-tools-gg7.json"
jq -e '.outcome=="shape-failed"' "$mf7" >/dev/null 2>&1 && ok "G3: missing body ⇒ marker outcome=shape-failed" || bad "G3: shape fail marker wrong (got $(jq -r .outcome "$mf7" 2>/dev/null))"

# G4: engine returns empty ⇒ NO marker (retried next poll). Use a real
# polished output but make the engine override print nothing + return 1.
cat > "$WD/builder-override.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"body":{"tldr":"x","sections":[{"heading":"h","prose":"p"}],"diagrams":[],"full_detail":"y"},"items":[]}'
EOF
chmod +x "$WD/builder-override.sh"
cat > "$WD/engine-override.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$WD/engine-override.sh"
rm -f "$DAEMON_FLOW_F_FIRED_DIR/claude-tools-hh8.json" 2>/dev/null
daemon_flow_f_dispatch_one "$WS_DIR" "alpha" "" "" "claude-tools-hh8"
[[ ! -f "$DAEMON_FLOW_F_FIRED_DIR/claude-tools-hh8.json" ]] && ok "G4: engine failure ⇒ NO marker (retried next poll)" || bad "G4: marker written despite engine failure"

# ════════════════════════════════════════════════════════════════════════════
# PART H — poll_once skips already-fired beads on a second call
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART H — poll_once skips already-fired beads ──"

# Build a fresh hermetic cache + workspace shim. The shim returns ONE id;
# the marker pre-seeds it as already-fired ⇒ poll_once does NOT dispatch.
CACHE_DIR2="$(mktemp -d)"
export DAEMON_CACHE_DIR="$CACHE_DIR2"
export DAEMON_FLOW_F_FIRED_DIR="$CACHE_DIR2/flow-f-overview-fired"
export DAEMON_FLOW_F_SEED_FLAG="$CACHE_DIR2/flow-f-overview-seeded.flag"
mkdir -p "$DAEMON_FLOW_F_FIRED_DIR"
# Seed flag set so seed-on-first-run is a no-op for this PART.
: > "$DAEMON_FLOW_F_SEED_FLAG"

cat > "$SHIM_DIR/bd" <<EOF
#!/usr/bin/env bash
args="\$*"
if [[ "\$args" == *"list"* && "\$args" == *"stage:design"* && "\$args" == *"closed"* ]]; then
  printf '%s\n' '[{"id":"claude-tools-ii9","status":"closed","labels":["stage:design"]}]'
else
  printf '[]\n'
fi
EOF
chmod +x "$SHIM_DIR/bd"

# Pre-mark ii9 as already-fired.
daemon_flow_f_write_marker "claude-tools-ii9" "$WS_DIR" "dispatched" "overview-claude-tools-ii9"

# Builder override should NOT be called.
rm -f "$WD/builder-called.flag" 2>/dev/null
cat > "$WD/builder-override.sh" <<EOF
#!/usr/bin/env bash
echo "BUILDER-CALLED" > "$WD/builder-called.flag"
echo '{"refuse":true,"reason":"x"}'
EOF
chmod +x "$WD/builder-override.sh"

REGISTRY_PROJECT_REFS=("alpha")
REGISTRY_DIRS=("$WS_DIR")
REGISTRY_COORDINATOR_URLS=("")
REGISTRY_TOKEN_KEYCHAIN_ITEMS=("")
REGISTRY_LOADED=1

daemon_flow_f_poll_once
[[ ! -f "$WD/builder-called.flag" ]] && ok "H1: already-fired bead is skipped on poll_once (builder NOT invoked)" || bad "H1: builder invoked for already-fired bead"

# ════════════════════════════════════════════════════════════════════════════
# PART I — daemon.sh wires flow-f-overview-poll.sh into the main loop
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART I — daemon.sh wiring ──"

grep -q 'flow-f-overview-poll.sh' "$DAEMON_SH" && ok "I1: daemon.sh sources flow-f-overview-poll.sh" || bad "I1: daemon.sh missing source line"
grep -q 'FLOW_F_POLL_INTERVAL=' "$DAEMON_SH" && ok "I2: daemon.sh declares FLOW_F_POLL_INTERVAL" || bad "I2: daemon.sh missing FLOW_F_POLL_INTERVAL"
grep -q 'daemon_flow_f_poll_once' "$DAEMON_SH" && ok "I3: daemon.sh calls daemon_flow_f_poll_once from the main loop" || bad "I3: daemon.sh missing call site"
grep -q '_last_flow_f_poll' "$DAEMON_SH" && ok "I4: daemon.sh keeps per-cadence last-poll memory" || bad "I4: daemon.sh missing _last_flow_f_poll"

echo ""
echo "════════════════════════════════════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then
  printf ' \033[32mALL_PASS\033[0m  %d/%d\n' "$PASS" "$((PASS+FAIL))"
  exit 0
else
  printf ' \033[31mFAIL\033[0m  %d/%d (failures: %d)\n' "$PASS" "$((PASS+FAIL))" "$FAIL"
  exit 1
fi
