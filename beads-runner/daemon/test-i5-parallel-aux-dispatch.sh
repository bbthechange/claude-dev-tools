#!/bin/bash
# beads-runner/daemon/test-i5-parallel-aux-dispatch.sh — I5 parallel auxiliary
# dispatch (claude-tools-uxvi5; epic claude-tools-mhcp). DESIGN I
# design/activity.md §5 + ARCH §9.1 (daemon-driven, NO runner rewrite).
#
# WHAT THIS PROVES (the bead's s6/s4 testing invariant — "parallel aux dispatch
# never spawns a 2nd WRITER; the dispatched aux carries the read-only hat (no
# Write/Edit/mutating-Bash). Assert the capability SET, not intent."):
#   PART 0 — the I5 functions exist in flow-f-overview-poll.sh, it parses, and
#            daemon.sh is wired (source, interval, call site, last-poll memory,
#            drain hook) + the H5 canary default is flipped to 0 (live).
#   PART A — per-bead dedup marker round-trip (write_marker ⇄ already_fired) +
#            mark-by-outcome policy (terminal marks; transient does NOT).
#   PART B — single-flight pidfile: a live pid ⇒ already_in_flight true; a stale
#            pid ⇒ false + reclaimed.
#   PART C — seed-on-first-run marks the structural-close BACKLOG WITHOUT
#            dispatching (the hat override is NOT called), drops the flag,
#            idempotent.
#   PART D — capacity gate routing (§I5(b)): a FRESH over-budget capacity.json
#            (low_priority dropped) ⇒ poll SUPPRESSES (hat NOT spawned, NO
#            marker — retried next cadence); fail-OPEN (no cache) ⇒ dispatch.
#   PART E — per-bead dedup across polls (§I5(c) — THE spawn-suppressor): a
#            structural close dispatches the read-only hat ONCE; a second poll
#            does NOT re-spawn it (the marker, not the hat's idempotent regen, is
#            what stops the expensive every-poll re-spawn).
#   PART F — READ-ONLY BY CONSTRUCTION + never-a-2nd-writer (assert the
#            capability SET): the dispatch spawns specialist.sh
#            --kind=blueprint-update; specialist.sh's blueprint-update permission
#            branch disallows the full NO_CODE_EDITS set at --permission-mode
#            default; and the I5 dispatch path never spawns a runner / claims a
#            bead / takes a lease.
#   PART G — operator off-switch: DAEMON_BLUEPRINT_UPDATE_DISABLED=1 ⇒ the poll
#            early-returns (no enumeration, no spawn) even with NEW closes.
#
# Offline + deterministic: no Keychain, no network, no real claude. A bd shim on
# PATH answers the structural-close enumeration; override stubs replace the hat /
# blueprint-put / engine write; the DAEMON_BU_SYNC_DISPATCH seam runs the
# dispatch foreground so there is no nohup/disown race to assert against.
# Run: bash beads-runner/daemon/test-i5-parallel-aux-dispatch.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
F_LIB="$HERE/flow-f-overview-poll.sh"
GATE_SH="$HERE/aux-dispatch-gate.sh"
REGISTRY_LIB="$HERE/workspace-registry.sh"
DAEMON_SH="$HERE/daemon.sh"
SPECIALIST="$HERE/../agents/specialist.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
eq()  { [[ "$1" == "$2" ]] && ok "$3" || bad "$3 (got '$1' want '$2')"; }
has() { case "$1" in *"$2"*) ok "$3";; *) bad "$3 (missing '$2')";; esac; }
nothas() { case "$1" in *"$2"*) bad "$3 (unexpectedly contains '$2')";; *) ok "$3";; esac; }

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " I5 parallel auxiliary dispatch — claude-tools-uxvi5"
echo "════════════════════════════════════════════════════════════════════"

# ════════════════════════════════════════════════════════════════════════════
# PART 0 — files exist, parse, helpers defined, daemon.sh wired, canary flipped
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART 0 — files exist, parse, helpers defined, daemon.sh wired ──"
[[ -f "$F_LIB" ]] && ok "flow-f-overview-poll.sh present" || bad "flow-f-overview-poll.sh missing"
bash -n "$F_LIB" 2>/dev/null && ok "flow-f-overview-poll.sh parses (bash -n clean)" || bad "flow-f-overview-poll.sh syntax"
bash -n "$DAEMON_SH" 2>/dev/null && ok "daemon.sh parses with I5 wiring" || bad "daemon.sh syntax"

for fn in daemon_bu_marker_for daemon_bu_already_fired daemon_bu_write_marker \
          daemon_bu__mark_by_outcome daemon_bu_seed_if_needed \
          daemon_bu_pidfile_for daemon_bu_already_in_flight \
          daemon_bu__bead_stage daemon_bu_dispatch_detached \
          daemon_bu__poll_workspace daemon_blueprint_update_poll_once \
          daemon_bu_kill_all \
          daemon_bu_pending_marker_for daemon_bu_pending_exists \
          daemon_bu_write_pending daemon_bu_clear_pending \
          daemon_bu_retry_pending_fyi; do
  grep -q "^$fn()" "$F_LIB" && ok "defines $fn" || bad "missing $fn"
done

# daemon.sh wiring (the live-or-it-never-fires guard).
grep -q 'BLUEPRINT_UPDATE_POLL_INTERVAL=' "$DAEMON_SH" && ok "daemon.sh declares BLUEPRINT_UPDATE_POLL_INTERVAL" || bad "daemon.sh missing interval"
grep -q 'daemon_blueprint_update_poll_once' "$DAEMON_SH" && ok "daemon.sh calls daemon_blueprint_update_poll_once from main loop" || bad "daemon.sh missing call site"
grep -q '_last_blueprint_update_poll' "$DAEMON_SH" && ok "daemon.sh keeps the per-cadence last-poll memory" || bad "daemon.sh missing _last_blueprint_update_poll"
grep -q 'daemon_bu_kill_all' "$DAEMON_SH" && ok "daemon.sh wires daemon_bu_kill_all into the drain handler" || bad "daemon.sh missing drain hook"

# The canary MUST be flipped to live (default 0) — else nothing fires in prod.
grep -q 'DAEMON_BLUEPRINT_UPDATE_DISABLED="${DAEMON_BLUEPRINT_UPDATE_DISABLED:-0}"' "$F_LIB" \
  && ok "H5 canary flipped to live (DAEMON_BLUEPRINT_UPDATE_DISABLED default 0)" \
  || bad "canary not flipped to 0 — the blueprint-update path would stay inert in prod"

# ════════════════════════════════════════════════════════════════════════════
# Hermetic cache + libs.
# ════════════════════════════════════════════════════════════════════════════
CACHE_DIR="$(mktemp -d)"
WD="$(mktemp -d)"
trap 'rm -rf "$CACHE_DIR" "$WD" 2>/dev/null || true' EXIT

export DAEMON_CACHE_DIR="$CACHE_DIR"
export DAEMON_BU_FIRED_DIR="$CACHE_DIR/blueprint-update-fired"
export DAEMON_BU_SEED_FLAG="$CACHE_DIR/blueprint-update-seeded.flag"
export DAEMON_BU_BASE="$CACHE_DIR/blueprint-update-dispatch"
export DAEMON_BU_PENDING_DIR="$CACHE_DIR/blueprint-update-fyi-pending"  # claude-tools-49rx
export DAEMON_BU_SYNC_DISPATCH=1          # run the dispatch foreground (no detach race)
export USAGE_THRESHOLD=70 USAGE_CACHE_SECONDS=300

# shellcheck source=/dev/null
. "$REGISTRY_LIB" 2>/dev/null || { bad "could not source workspace-registry.sh"; exit 1; }
# shellcheck source=/dev/null
. "$F_LIB"        2>/dev/null || { bad "could not source flow-f-overview-poll.sh"; exit 1; }
# shellcheck source=/dev/null
. "$GATE_SH"      2>/dev/null || { bad "could not source aux-dispatch-gate.sh"; exit 1; }

# Capture the daemon `log` output so we can assert the per-bead launch/suppress
# lines + the one-line summary actually fire (the claude-tools-uxvi5 review caught
# that a `$()`-captured __poll_workspace swallowed them — these assertions guard
# the fix). The lib emits via `declare -F log && log …`, so defining it here turns
# those lines on into LOG_CAPTURE.
LOG_CAPTURE="$WD/daemon.log"
log() { printf '%s\n' "$*" >> "$LOG_CAPTURE"; }

reset_state() {
  rm -rf "$DAEMON_BU_FIRED_DIR" "$DAEMON_BU_SEED_FLAG" "$DAEMON_BU_BASE" "$DAEMON_BU_PENDING_DIR" 2>/dev/null
  mkdir -p "$DAEMON_BU_FIRED_DIR" "$DAEMON_BU_BASE/pids" "$DAEMON_BU_BASE/logs" 2>/dev/null
  : > "$LOG_CAPTURE" 2>/dev/null || true
}
plant_capacity() {  # plant_capacity <allowed_json> <pct5> <pct7> <ramp>
  cat > "$CACHE_DIR/capacity.json" <<EOF
{"schema_version":1,"pct_5h":$2,"pct_7d":$3,"spare_ramp_today":$4,"allowed_cost_classes":[$1],"observed_at":"2026-01-01T00:00:00Z","expires_at":"2026-01-01T00:05:00Z"}
EOF
  touch "$CACHE_DIR/capacity.json"
}

# ════════════════════════════════════════════════════════════════════════════
# PART A — marker round-trip + mark-by-outcome policy
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART A — dedup marker round-trip + mark-by-outcome ──"
reset_state
mf="$(daemon_bu_marker_for "rhythmGame-abc")"
case "$mf" in
  "$DAEMON_BU_FIRED_DIR/rhythmGame-abc.json") ok "A1: marker path lives under DAEMON_BU_FIRED_DIR" ;;
  *) bad "A1: unexpected marker path '$mf'" ;;
esac
daemon_bu_already_fired "rhythmGame-abc" && bad "A2: not-yet-fired bead reported as fired" || ok "A2: not-yet-fired ⇒ false"
daemon_bu_write_marker "rhythmGame-abc" "/ws/a" "dispatched"
daemon_bu_already_fired "rhythmGame-abc" && ok "A3: write_marker ⇒ already_fired true" || bad "A3: marker write did not register"
jq -e '.outcome=="dispatched"' "$mf" >/dev/null 2>&1 && ok "A4: marker carries outcome" || bad "A4: marker outcome"

# mark-by-outcome: terminal outcomes mark; transient do not.
for oc in dispatched no-change refused parse-failed; do
  reset_state
  daemon_bu__mark_by_outcome "bead-$oc" "/ws" "$oc"
  daemon_bu_already_fired "bead-$oc" && ok "A5: terminal outcome '$oc' ⇒ marker written" || bad "A5: '$oc' should mark"
done
for oc in disabled spawn-failed write-failed fyi-failed; do
  reset_state
  daemon_bu__mark_by_outcome "bead-$oc" "/ws" "$oc"
  daemon_bu_already_fired "bead-$oc" && bad "A6: transient '$oc' should NOT mark (retry)" || ok "A6: transient '$oc' ⇒ NO marker (retried)"
done

# ════════════════════════════════════════════════════════════════════════════
# PART B — single-flight pidfile
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART B — single-flight pidfile ──"
reset_state
# A live pid (this shell) ⇒ in-flight true.
pf="$(daemon_bu_pidfile_for "bead-live")"
mkdir -p "$(dirname "$pf")"; echo "$$" > "$pf"
daemon_bu_already_in_flight "bead-live" && ok "B1: live pid ⇒ already_in_flight true (single-flight holds)" || bad "B1: live pid not detected"
# A stale pid (impossible pid) ⇒ false + reclaimed.
pf2="$(daemon_bu_pidfile_for "bead-stale")"
echo "999999" > "$pf2"
daemon_bu_already_in_flight "bead-stale" && bad "B2: stale pid wrongly reported in-flight" || ok "B2: stale pid ⇒ false"
[[ ! -f "$pf2" ]] && ok "B3: stale pidfile reclaimed" || bad "B3: stale pidfile not cleaned"

# ════════════════════════════════════════════════════════════════════════════
# Build the bd shim + override stubs used by the dispatch parts.
# ════════════════════════════════════════════════════════════════════════════
SHIM_DIR="$WD/shim"; BIN="$WD/bin"
mkdir -p "$SHIM_DIR" "$BIN"
WS_DIR="$WD/ws"; mkdir -p "$WS_DIR"

export BD_CLOSED_FILE="$WD/bd-closed.json"
printf '%s' '[{"id":"rg-impl-1","status":"closed","labels":["stage:impl"]}]' > "$BD_CLOSED_FILE"

cat > "$SHIM_DIR/bd" <<'EOF'
#!/usr/bin/env bash
args="$*"
# bd label list <id> --json  →  the bead's structural stage label
if [[ "$args" == *"label list"* ]]; then printf '%s\n' '["stage:impl"]'; exit 0; fi
# bd list --label stage:impl --status closed ...  →  the structural-close set
if [[ "$args" == *"list"* && "$args" == *"stage:impl"* && "$args" == *"closed"* ]]; then
  cat "$BD_CLOSED_FILE" 2>/dev/null || printf '[]\n'; exit 0
fi
printf '[]\n'
EOF
chmod +x "$SHIM_DIR/bd"
export PATH="$SHIM_DIR:$PATH"

# hat-stub: record argv (so we can assert --kind), print $HAT_OUT_FILE contents.
export HAT_OUT_FILE="$WD/hat-out.json"
export HAT_CALLS_LOG="$WD/hat-calls.log"
cat > "$BIN/hat-stub.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HAT_CALLS_LOG"
cat "$HAT_OUT_FILE"
exit 0
EOF
chmod +x "$BIN/hat-stub.sh"

cat > "$BIN/get-stub.sh" <<'EOF'
#!/usr/bin/env bash
printf 'null'
EOF
chmod +x "$BIN/get-stub.sh"

export BP_SENTINEL="$WD/bp-write.called"
cat > "$BIN/bp-write-stub.sh" <<'EOF'
#!/usr/bin/env bash
touch "$BP_SENTINEL"
exit 0
EOF
chmod +x "$BIN/bp-write-stub.sh"

export FYI_SENTINEL="$WD/fyi.gi"
export FYI_FAIL_FLAG="$WD/fyi-fail.flag"   # claude-tools-49rx: when present ⇒ transient emit failure
cat > "$BIN/fyi-engine-stub.sh" <<'EOF'
#!/usr/bin/env bash
# Transient-failure seam (claude-tools-49rx): if FYI_FAIL_FLAG names an existing
# file, simulate a transient engine failure (no id, nonzero rc) so the caller
# sees an empty written id. Otherwise record the gi + print a fake dossier id.
if [[ -n "${FYI_FAIL_FLAG:-}" && -f "$FYI_FAIL_FLAG" ]]; then
  exit 1
fi
cp "$2" "$FYI_SENTINEL" 2>/dev/null
printf 'overview-written-fake'
exit 0
EOF
chmod +x "$BIN/fyi-engine-stub.sh"

export DAEMON_BLUEPRINT_UPDATE_HAT_OVERRIDE="$BIN/hat-stub.sh"
export DAEMON_BLUEPRINT_UPDATE_GET_OVERRIDE="$BIN/get-stub.sh"
export DAEMON_BLUEPRINT_UPDATE_BP_WRITE_OVERRIDE="$BIN/bp-write-stub.sh"
export DAEMON_FLOW_F_ENGINE_OVERRIDE="$BIN/fyi-engine-stub.sh"

# Material-change hat output ⇒ dispatch_one returns outcome=dispatched.
HAT_MATERIAL='{"material_change":true,
  "derived":{"nodes":[{"id":"domain:messaging"}],"edges":[],"apis":[]},
  "narrative":{"tldr":"grew messaging","sections":[]},
  "conflicts_append":[],
  "focus_id":"domain:messaging",
  "overview":{"tldr":"grew a Messaging domain.","sections":[],"full_detail":"prose"}}'

# Registry: one workspace.
REGISTRY_PROJECT_REFS=("rhythmGame")
REGISTRY_DIRS=("$WS_DIR")
REGISTRY_COORDINATOR_URLS=("")
REGISTRY_TOKEN_KEYCHAIN_ITEMS=("")
REGISTRY_LOADED=1

# ════════════════════════════════════════════════════════════════════════════
# PART C — seed-on-first-run marks the backlog WITHOUT dispatching
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART C — seed-on-first-run marks backlog WITHOUT dispatching ──"
reset_state
rm -f "$HAT_CALLS_LOG"
# Sanity: the enumerator returns the seeded id.
listed="$(daemon_blueprint_update__list_structural_closes "$WS_DIR" | tr '\n' ',' | sed 's/,$//')"
eq "$listed" "rg-impl-1" "C1: __list_structural_closes returns the closed structural bead"
daemon_bu_seed_if_needed
[[ -f "$DAEMON_BU_SEED_FLAG" ]] && ok "C2: seed flag dropped" || bad "C2: seed flag missing"
daemon_bu_already_fired "rg-impl-1" && ok "C3: backlog bead marked during seed" || bad "C3: backlog bead not marked"
jq -e '.outcome=="seeded"' "$DAEMON_BU_FIRED_DIR/rg-impl-1.json" >/dev/null 2>&1 && ok "C4: marker outcome=seeded" || bad "C4: marker outcome wrong"
[[ ! -f "$HAT_CALLS_LOG" ]] && ok "C5: hat NOT spawned during seed (no backlog dispatch)" || bad "C5: hat spawned during seed"
# Idempotent.
prev="$(stat -f %m "$DAEMON_BU_SEED_FLAG" 2>/dev/null || stat -c %Y "$DAEMON_BU_SEED_FLAG" 2>/dev/null)"
daemon_bu_seed_if_needed
cur="$(stat -f %m "$DAEMON_BU_SEED_FLAG" 2>/dev/null || stat -c %Y "$DAEMON_BU_SEED_FLAG" 2>/dev/null)"
eq "$prev" "$cur" "C6: seed idempotent (flag not re-touched)"

# ════════════════════════════════════════════════════════════════════════════
# PART D — capacity gate routing (§I5(b))
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART D — capacity gate routing (low_priority; fail-OPEN) ──"
# D1: FRESH over-budget cache (low_priority dropped) ⇒ SUPPRESS — no spawn, no marker.
reset_state
rm -f "$HAT_CALLS_LOG"
printf '%s' "$HAT_MATERIAL" > "$HAT_OUT_FILE"
: > "$DAEMON_BU_SEED_FLAG"   # skip seed so the poll considers the bead
plant_capacity '"standard"' 50 50 100
daemon_blueprint_update_poll_once
[[ ! -f "$HAT_CALLS_LOG" ]] && ok "D1: over-budget low_priority ⇒ hat SUPPRESSED (not spawned)" || bad "D1: hat spawned despite over-budget"
daemon_bu_already_fired "rg-impl-1" && bad "D2: suppressed bead must NOT be marked (retry next cadence)" || ok "D2: suppressed ⇒ NO marker (retried)"
has "$(cat "$LOG_CAPTURE" 2>/dev/null)" "SUPPRESSED" "D2b: suppression is logged (reaches the daemon log, not swallowed by a \$() capture)"

# D3: fail-OPEN (no capacity.json) ⇒ dispatch happens.
reset_state
rm -f "$HAT_CALLS_LOG" "$BP_SENTINEL" "$FYI_SENTINEL" "$CACHE_DIR/capacity.json"
: > "$DAEMON_BU_SEED_FLAG"
daemon_blueprint_update_poll_once
[[ -f "$HAT_CALLS_LOG" ]] && ok "D3: missing capacity signal ⇒ fail-OPEN, hat dispatched" || bad "D3: fail-open did not dispatch"
daemon_bu_already_fired "rg-impl-1" && ok "D4: dispatched bead marked (outcome=dispatched)" || bad "D4: dispatched bead not marked"

# ════════════════════════════════════════════════════════════════════════════
# PART E — per-bead dedup across polls (THE spawn-suppressor)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART E — one-per-structural-close dedup across polls ──"
reset_state
rm -f "$HAT_CALLS_LOG" "$BP_SENTINEL" "$FYI_SENTINEL" "$CACHE_DIR/capacity.json"
: > "$DAEMON_BU_SEED_FLAG"
printf '%s' "$HAT_MATERIAL" > "$HAT_OUT_FILE"
daemon_blueprint_update_poll_once   # poll #1 — dispatches
daemon_blueprint_update_poll_once   # poll #2 — must be a no-op (already fired)
n_calls="$(wc -l < "$HAT_CALLS_LOG" 2>/dev/null | tr -d ' ')"
eq "${n_calls:-0}" "1" "E1: hat spawned EXACTLY once across two polls (marker stops re-spawn)"
[[ -f "$BP_SENTINEL" ]] && ok "E2: blueprint-put transport was called (material change ⇒ map redrawn)" || bad "E2: blueprint-put not called"
[[ -f "$FYI_SENTINEL" ]] && ok "E3: exactly one timed-fyi emitted via the shared Flow F engine write" || bad "E3: no timed-fyi emitted"
has "$(cat "$LOG_CAPTURE" 2>/dev/null)" "dispatched 1" "E3b: the one-line summary fires (count not swallowed — the review fix)"

# A genuinely NEW close (different bead) DOES dispatch — dedup is per-bead.
printf '%s' '[{"id":"rg-impl-1","status":"closed","labels":["stage:impl"]},{"id":"rg-impl-2","status":"closed","labels":["stage:impl"]}]' > "$BD_CLOSED_FILE"
daemon_blueprint_update_poll_once
n_calls2="$(wc -l < "$HAT_CALLS_LOG" 2>/dev/null | tr -d ' ')"
eq "${n_calls2:-0}" "2" "E4: a NEW structural close dispatches (dedup is per-bead, not global)"
# restore the single-bead fixture
printf '%s' '[{"id":"rg-impl-1","status":"closed","labels":["stage:impl"]}]' > "$BD_CLOSED_FILE"

# ════════════════════════════════════════════════════════════════════════════
# PART F — READ-ONLY BY CONSTRUCTION + never a 2nd writer (the capability SET)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART F — read-only hat + never-a-2nd-writer (assert the capability SET) ──"
# Dynamic: the dispatch invokes the hat with --kind=blueprint-update.
has "$(cat "$HAT_CALLS_LOG" 2>/dev/null)" "--kind=blueprint-update" "F1: aux is spawned as --kind=blueprint-update"

# Static: specialist.sh gives the blueprint-update kind the read-only permission
# set — assert the SET, not intent (Brian's s6/s4 invariant).
[[ -f "$SPECIALIST" ]] && ok "F2: specialist.sh present" || bad "F2: specialist.sh missing"
# The reconciler|enricher|blueprint-update case → COMMON_ALLOWED + full NO_CODE_EDITS.
spec_branch="$(awk '/reconciler\|enricher\|blueprint-update\)/{f=1} f{print} /;;/{if(f)exit}' "$SPECIALIST" 2>/dev/null)"
has "$spec_branch" 'DISALLOWED=("${GUARDRAIL[@]}" "${NO_CODE_EDITS[@]}")' "F3: blueprint-update DISALLOWS the NO_CODE_EDITS set"
has "$spec_branch" '--permission-mode default' "F4: blueprint-update runs at --permission-mode default (no acceptEdits)"
# NO_CODE_EDITS actually covers the mutating tools.
no_code="$(grep -E '^NO_CODE_EDITS=' "$SPECIALIST" 2>/dev/null)"
for tool in Write Edit MultiEdit NotebookEdit BashWriteEdits; do
  has "$no_code" "$tool" "F5: NO_CODE_EDITS covers $tool"
done

# Never a 2nd writer: the I5 dispatch path never spawns a runner / claims a bead
# / takes a lease. Scan the I5 section's CODE (comment lines stripped — the prose
# legitimately says "takes no lease") for those forbidden call tokens.
i5_section="$(awk '/I5 \(claude-tools-uxvi5\) — parallel auxiliary dispatch \(the LIVE wiring\)/{f=1} f{print}' "$F_LIB" 2>/dev/null)"
[[ -n "$i5_section" ]] && ok "F6: located the I5 section of flow-f-overview-poll.sh" || bad "F6: I5 section not found"
i5_code="$(printf '%s\n' "$i5_section" | grep -v '^[[:space:]]*#')"
nothas "$i5_code" "launch-detached" "F7: I5 code never spawns a workspace runner (no launch-detached)"
nothas "$i5_code" "runner.sh"       "F8: I5 code never spawns runner.sh"
nothas "$i5_code" "--claim"         "F9: I5 code never claims a bead (no writer lease)"
nothas "$i5_code" "lease"           "F10: I5 code takes no writer lease"

# ════════════════════════════════════════════════════════════════════════════
# PART G — operator off-switch (DAEMON_BLUEPRINT_UPDATE_DISABLED=1)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART G — off-switch (DAEMON_BLUEPRINT_UPDATE_DISABLED=1) ──"
reset_state
rm -f "$HAT_CALLS_LOG" "$CACHE_DIR/capacity.json"
: > "$DAEMON_BU_SEED_FLAG"
DAEMON_BLUEPRINT_UPDATE_DISABLED=1 daemon_blueprint_update_poll_once
[[ ! -f "$HAT_CALLS_LOG" ]] && ok "G1: DISABLED=1 ⇒ poll early-returns (no spawn even with NEW closes)" || bad "G1: poll dispatched despite DISABLED=1"

# ════════════════════════════════════════════════════════════════════════════
# PART H — claude-tools-49rx: a transient timed-fyi emit failure does NOT drop
#          the overview ping. Poll #1's FYI emit fails (the map is still written)
#          ⇒ a fyi-pending marker is parked, NO terminal fired marker, the hat
#          ran once. Poll #2's FYI emit succeeds ⇒ the ping is re-emitted from the
#          parked gi WITHOUT re-running the hat, the pending marker is cleared,
#          and the bead is promoted to a terminal fired marker. Poll #3 is a clean
#          no-op (the ping landed exactly once on recovery).
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART H — fyi-pending recovery (transient FYI failure ⇒ ping not dropped) ──"
reset_state
rm -f "$HAT_CALLS_LOG" "$BP_SENTINEL" "$FYI_SENTINEL" "$CACHE_DIR/capacity.json"
: > "$DAEMON_BU_SEED_FLAG"                  # skip seed so the bead is considered
printf '%s' "$HAT_MATERIAL" > "$HAT_OUT_FILE"
: > "$FYI_FAIL_FLAG"                        # arm the transient FYI failure

daemon_blueprint_update_poll_once          # poll #1 — map written, FYI emit fails
n_h1="$(wc -l < "$HAT_CALLS_LOG" 2>/dev/null | tr -d ' ')"
eq "${n_h1:-0}" "1" "H1: hat spawned once on poll #1 (the material-change dispatch)"
[[ -f "$BP_SENTINEL" ]] && ok "H2: blueprint-put WAS called — the map is written despite the FYI failure" \
  || bad "H2: map not written"
daemon_bu_pending_exists "rg-impl-1" && ok "H3: a fyi-pending marker is parked (the ping is owed)" \
  || bad "H3: no fyi-pending marker parked — the ping would be lost"
daemon_bu_already_fired "rg-impl-1" && bad "H4: bead must NOT be terminally fired while the ping is owed" \
  || ok "H4: NO terminal fired marker (the bead is retried, not stranded)"
has "$(cat "$LOG_CAPTURE" 2>/dev/null)" "parked fyi-pending" "H4b: the fyi-pending park is logged"

rm -f "$FYI_FAIL_FLAG" "$FYI_SENTINEL"      # the engine recovers
daemon_blueprint_update_poll_once          # poll #2 — re-emit ONLY the FYI
n_h2="$(wc -l < "$HAT_CALLS_LOG" 2>/dev/null | tr -d ' ')"
eq "${n_h2:-0}" "1" "H5: hat NOT re-spawned on poll #2 (the FYI is re-emitted WITHOUT the hat — the fix)"
[[ -f "$FYI_SENTINEL" ]] && ok "H6: the overview ping WAS re-emitted on poll #2 (not dropped — claude-tools-49rx)" \
  || bad "H6: ping still missing after the engine recovered"
if [[ -f "$FYI_SENTINEL" ]]; then
  eq "$(jq -r '.kind' "$FYI_SENTINEL")"            "overview"         "H6b: re-emitted FYI is the unified kind=overview"
  eq "$(jq -r '.source.focus_id' "$FYI_SENTINEL")" "domain:messaging" "H6c: re-emitted FYI preserves the parked focus_id deep-link"
fi
daemon_bu_pending_exists "rg-impl-1" && bad "H7: fyi-pending marker should be cleared after a successful re-emit" \
  || ok "H7: fyi-pending marker cleared"
daemon_bu_already_fired "rg-impl-1" && ok "H8: bead promoted to a terminal fired marker (no more retries)" \
  || bad "H8: bead not promoted to fired"

rm -f "$FYI_SENTINEL"
daemon_blueprint_update_poll_once          # poll #3 — fully settled
n_h3="$(wc -l < "$HAT_CALLS_LOG" 2>/dev/null | tr -d ' ')"
eq "${n_h3:-0}" "1" "H9: poll #3 is a clean no-op (hat not spawned again)"
[[ ! -f "$FYI_SENTINEL" ]] && ok "H10: poll #3 emits no further FYI (the ping landed exactly once on recovery)" \
  || bad "H10: spurious FYI on poll #3"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " RESULT — PASS=$PASS FAIL=$FAIL"
echo "════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]] && { echo "ALL_PASS (I5 parallel auxiliary dispatch — claude-tools-uxvi5)"; exit 0; } \
                    || { echo "SOME_FAIL"; exit 1; }
