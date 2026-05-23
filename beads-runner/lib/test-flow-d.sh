#!/bin/bash
# beads-runner/lib/test-flow-d.sh — F3 (claude-tools-6mx; epic claude-tools-kie).
#
# WHAT THIS PROVES — Flow D end-to-end inside one process. The §2.4 set-desired
# write seam (F1, Board side) is exercised against the in-process bash
# coordinator (the same engine logic the FROZEN CF Worker re-implements);
# the daemon's M3 per-workspace reconcile (claude-tools-cgh) is then driven
# against the resulting RunnerState; and the runner's C2 spare-only gate
# (claude-tools-oil) is exercised for the spare-cycles path. The loop:
#
#   set-desired (F1 op)
#        ↓ persists RunnerState.desired in the engine store
#   daemon M3 poll (reads .desired, runs state machine)
#        ↓ spawns / SIGTERMs / no-ops per the four-state matrix
#   runner C2 gate (reads .desired, gates pickup by cost_class)
#
# closes here. The four desired-state values:
#   running       → daemon spawns when no runner; runner picks up freely
#   paused        → daemon no-ops; runner's own job_reconcile holds the loop
#   spare-cycles  → daemon spawns like running; runner C2 gate denies
#                   non-low_priority pickups
#   stopped       → daemon SIGTERMs an alive runner; spawn refused while
#                   stopped
#
# UI ↔ WIRE — UX-DESIGN names the spare state `spare-only`; INTERFACE.md §4.2
# names it `spare-cycles`. The proxy (web/functions/api/board/set-desired.js,
# F3 patch) normalises UI→wire so the engine, the daemon, and the runner all
# read the canonical §4.2 enum. This test asserts the daemon and runner BOTH
# see `spare-cycles` after a `spare-only` UI tap is mediated by the proxy's
# WIRE_STATE map (we exercise that mapping in bash to avoid pulling in the
# Pages runtime).
#
# NOT THE LIVE SMOKE. The live exercise (workspace runner + daemon + DEPLOYED
# engine, flipped from Brian's phone) lives in daemon/live-smoke-flow-d.sh —
# documented + runnable, but human-driven. This file is the hermetic in-
# process assertion that the wire contract closes the loop.
#
# Run: bash beads-runner/lib/test-flow-d.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
LIB="$HERE/coordinator.sh"
RUNNER_SH="$REPO_ROOT/run-beads-tasks.sh"
M3_LIB="$REPO_ROOT/daemon/desired-state-poll.sh"
REGISTRY_LIB="$REPO_ROOT/daemon/workspace-registry.sh"
PROXY_JS="$REPO_ROOT/web/functions/api/board/set-desired.js"

[[ -f "$LIB" ]]          || { echo "FATAL: coordinator.sh not found at $LIB"; exit 2; }
[[ -f "$M3_LIB" ]]       || { echo "FATAL: desired-state-poll.sh not found at $M3_LIB"; exit 2; }
[[ -f "$RUNNER_SH" ]]    || { echo "FATAL: run-beads-tasks.sh not found at $RUNNER_SH"; exit 2; }
[[ -f "$PROXY_JS" ]]     || { echo "FATAL: set-desired.js proxy not found at $PROXY_JS"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
eq()  { [[ "$1" == "$2" ]] && ok "$3" || bad "$3 (got '$1' want '$2')"; }
has() { case "$1" in *"$2"*) ok "$3";; *) bad "$3 (missing '$2')";; esac; }
nothas() { case "$1" in *"$2"*) bad "$3 (unexpectedly contains '$2')";; *) ok "$3";; esac; }

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " Flow D end-to-end — F3 (claude-tools-6mx)"
echo "════════════════════════════════════════════════════════════════════"

# In-process coordinator. CO_STORE is workspace-scoped below so each workspace
# fixture has its own RunnerState; the four-state matrix runs against the same
# project_ref each time and we mutate `.desired` between cycles.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
unset CO_EXPECTED_TOKEN PRINCIPAL_V1 STALE_AFTER USAGE_THRESHOLD 2>/dev/null || true
GOOD="bearer-runner-secret-xyz"

# ════════════════════════════════════════════════════════════════════════════
# PART 0 — UI↔wire normalisation lives in the proxy
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART 0 — UI↔wire normalisation lives in the proxy (static) ──"

# The proxy validates the UI four-tuple (matches the Board's button labels)
# but sends the §4.2 enum (`spare-cycles`) on the wire. A grep is the
# anti-drift guard: a future refactor that re-introduces the silent
# `spare-only` wire send would land in the engine, fail the daemon's enum
# filter, and break Flow D for one of its four states.
has "$(cat "$PROXY_JS")" "'spare-only': 'spare-cycles'" \
    "0.1: proxy maps UI 'spare-only' → wire 'spare-cycles' (INTERFACE §4.2)"
has "$(cat "$PROXY_JS")" "WIRE_STATE[state]" \
    "0.2: proxy SENDS the normalised wire value, not the raw UI literal"
has "$(cat "$PROXY_JS")" "ALLOWED_STATES" \
    "0.3: proxy still validates the four UI states (F1 contract preserved)"

# ════════════════════════════════════════════════════════════════════════════
# PART A — F1 op: set-desired writes the §4.2 enum the engine reads back
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART A — set-desired writes RunnerState.desired the engine reads back ──"

CO_STORE_A="$WORK/store-A"
export CO_STORE="$CO_STORE_A"
# shellcheck source=/dev/null
source "$LIB"

for state in running paused spare-cycles stopped; do
  co_request "$GOOD" set-desired projF3 "$state" "ui:brian" >/dev/null 2>&1
  got="$(co_request "$GOOD" get runner_state projF3 2>/dev/null | jq -r '.desired // ""' 2>/dev/null)"
  eq "$got" "$state" "A: set-desired '$state' round-trips via co_request (§4.2)"
done

# An out-of-spec wire value (no UI→wire normalisation applied; demonstrates
# why the proxy MUST normalise — the engine accepts any string but the daemon
# refuses to act on non-§4.2 values).
co_request "$GOOD" set-desired projF3 "spare-only" "ui:brian" >/dev/null 2>&1
rawSpareOnly="$(co_request "$GOOD" get runner_state projF3 2>/dev/null | jq -r '.desired // ""' 2>/dev/null)"
eq "$rawSpareOnly" "spare-only" "A: an unnormalised wire write LANDS in the engine verbatim — the daemon will refuse to act on it (see PART C)"

# ════════════════════════════════════════════════════════════════════════════
# PART B — daemon M3 reconcile honours all four desired-states
#
# Uses the DAEMON_M3_DISABLED=1 canary so spawn/SIGTERM resolve to log lines —
# no real launch-detached.sh invocations. We seed each fixture's CO_STORE with
# the RunnerState the daemon will read on its poll, then drive
# daemon_m3_reconcile_workspace once per state and assert the action.
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART B — daemon M3 reconcile honours all four desired-states ──"

# PART A's CO_STORE is the coordinator's store; the daemon's M3 fetch runs in
# a subshell that defaults CO_STORE to <workspace>/.beads/runner-logs/.co-store
# IFF CO_STORE is unset. Unset it here so each per-workspace fixture's seeded
# RunnerState is the one the daemon reads — the production pattern.
unset CO_STORE

# Source the registry + M3 lib in this shell (we also already have coordinator.sh).
# shellcheck source=/dev/null
. "$REGISTRY_LIB"
# shellcheck source=/dev/null
. "$M3_LIB"

WSB="$WORK/ws-B"
mkdir -p "$WSB/.beads/runner-logs"
WS_STORE_B="$WSB/.beads/runner-logs/.co-store"
mkdir -p "$WS_STORE_B/records"

# Capture the daemon's `log` lines into a file (the daemon's real `log`
# writes to stdout; we proxy it).
B_LOGS="$WORK/b.log"
log() { printf '[stub-log] %s\n' "$*" >> "$B_LOGS"; }
export -f log 2>/dev/null || true

REGISTRY_PROJECT_REFS=("projF3-B")
REGISTRY_DIRS=("$WSB")
REGISTRY_COORDINATOR_URLS=("")
REGISTRY_TOKEN_KEYCHAIN_ITEMS=("")
REGISTRY_LOADED=1

# IMPORTANT: daemon_m3_fetch_desired CDs into the workspace and sets CO_STORE
# to <ws>/.beads/runner-logs/.co-store — so we seed THAT store, not the
# coordinator's $CO_STORE. Mimic co__store_put's on-disk shape.
write_rs_B() {
  local desired="$1"
  jq -cn --arg p "projF3-B" --arg d "$desired" \
    '{schema_version:1,project_ref:$p,desired:$d,actual:"running",
      last_heartbeat_at:"2026-05-20T00:00:00Z",last_desired_actor:"ui:brian",
      updated_at:"2026-05-20T00:00:00Z"}' \
    > "$WS_STORE_B/records/runner_state.projF3-B.json"
}

export DAEMON_M3_DISABLED=1
daemon_m3_reset_state_memory

# B1 — desired=running + no runner ⇒ daemon spawns.
write_rs_B "running"
rm -f "$WSB/.beads/runner-logs/detached-runner.pid"
: > "$B_LOGS"
daemon_m3_reconcile_workspace 0
logs="$(cat "$B_LOGS")"
has "$logs" "M3 transition" "B1: transition logged on first observation of running"
has "$logs" "runner absent, spawning" "B1: desired=running + no runner ⇒ spawn"
has "$logs" "DAEMON_M3_DISABLED=1" "B1: canary fired (no real launch)"

# B2 — desired=paused + runner alive ⇒ no-op (daemon does NOT signal; runner's
# own job_reconcile_desired holds the loop at idle).
echo "$$" > "$WSB/.beads/runner-logs/detached-runner.pid"
write_rs_B "paused"
: > "$B_LOGS"
daemon_m3_reconcile_workspace 0
logs="$(cat "$B_LOGS")"
has   "$logs" "running → paused" "B2: transition logs running → paused"
nothas "$logs" "spawning"       "B2: paused + alive ⇒ NO spawn"
nothas "$logs" "SIGTERM"        "B2: paused + alive ⇒ NO SIGTERM (runner holds itself)"

# B3 — desired=paused + no runner ⇒ no-op (a paused workspace stays dead).
rm -f "$WSB/.beads/runner-logs/detached-runner.pid"
: > "$B_LOGS"
daemon_m3_reconcile_workspace 0
logs="$(cat "$B_LOGS")"
nothas "$logs" "spawning" "B3: paused + dead ⇒ daemon does NOT spawn a paused workspace"

# B4 — desired=spare-cycles + no runner ⇒ spawn (lifecycle treated like
# running; the spare gate is per-pickup, not per-lifecycle).
write_rs_B "spare-cycles"
: > "$B_LOGS"
daemon_m3_reconcile_workspace 0
logs="$(cat "$B_LOGS")"
has "$logs" "paused → spare-cycles" "B4: transition logs paused → spare-cycles"
has "$logs" "desired=spare-cycles ⇒ runner absent, spawning" \
    "B4: spare-cycles + no runner ⇒ spawn (C2 gate fires per-pickup, NOT per-lifecycle)"

# B5 — desired=stopped + runner alive ⇒ SIGTERM.
echo "$$" > "$WSB/.beads/runner-logs/detached-runner.pid"
write_rs_B "stopped"
: > "$B_LOGS"
daemon_m3_reconcile_workspace 0
logs="$(cat "$B_LOGS")"
has "$logs" "spare-cycles → stopped" "B5: transition logs spare-cycles → stopped"
has "$logs" "would SIGTERM pid=$$"   "B5: stopped + alive ⇒ SIGTERM (canary intent logged with correct pid)"

# B6 — desired=stopped + no runner ⇒ no-op (already converged).
rm -f "$WSB/.beads/runner-logs/detached-runner.pid"
: > "$B_LOGS"
daemon_m3_reconcile_workspace 0
logs="$(cat "$B_LOGS")"
nothas "$logs" "SIGTERM" "B6: stopped + dead ⇒ no SIGTERM (already converged)"
nothas "$logs" "spawning" "B6: stopped + dead ⇒ no spawn"

# B7 — full round-trip: running → paused → spare-cycles → stopped → running
# in sequence, with the daemon logging EACH transition with the workspace
# identity AND the old → new pair. This is the "honest-state rendering
# reflects the live transition" acceptance criterion translated into log
# audit.
daemon_m3_reset_state_memory
: > "$B_LOGS"
for state in running paused spare-cycles stopped running; do
  write_rs_B "$state"
  daemon_m3_reconcile_workspace 0
done
logs="$(cat "$B_LOGS")"
has "$logs" "<unset> → running"          "B7-a: cycle logs initial <unset> → running"
has "$logs" "running → paused"           "B7-b: cycle logs running → paused"
has "$logs" "paused → spare-cycles"      "B7-c: cycle logs paused → spare-cycles"
has "$logs" "spare-cycles → stopped"     "B7-d: cycle logs spare-cycles → stopped"
has "$logs" "stopped → running"          "B7-e: cycle logs stopped → running (closing the Flow D round-trip)"

# B8 — an unnormalised wire write (the `spare-only` literal) is DROPPED by
# the daemon's enum filter — no action taken. This is exactly why the proxy
# must normalise: without PART 0, this is the silent break.
write_rs_B "spare-only"
echo "$$" > "$WSB/.beads/runner-logs/detached-runner.pid"
daemon_m3_reset_state_memory
: > "$B_LOGS"
daemon_m3_reconcile_workspace 0
logs="$(cat "$B_LOGS")"
nothas "$logs" "M3 transition"   "B8: unnormalised 'spare-only' wire value ⇒ daemon enum filter coerces to empty, NO transition logged"
nothas "$logs" "spawning"        "B8: unnormalised value ⇒ no spawn"
nothas "$logs" "SIGTERM"         "B8: unnormalised value ⇒ no SIGTERM (conservative posture on uncertainty)"

# ════════════════════════════════════════════════════════════════════════════
# PART C — runner C2 spare-only gate (claude-tools-oil) reads spare-cycles
#
# The runner exposes daemon_ask_capacity(cost_class, desired_state). The C2
# wiring asserts: when desired=spare-cycles and cost_class != low_priority,
# the gate denies with reason 'spare_only_standard_disallowed'. We exercise
# the gate directly (not via a full task pickup loop — that requires bd, a
# Dolt commit, etc.). PART B already proved the daemon reads spare-cycles
# from the engine.
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART C — runner C2 spare-only gate denies non-low_priority work ──"

# run-beads-tasks.sh is NOT a sourceable library (it has a top-level `while
# true` main loop). Extract daemon_ask_capacity in isolation — same idiom
# daemon/test-c2-spare-ramp-gate.sh uses.
run_capacity() {
  local cost_class="$1" desired_state="${2:-}"
  (
    set +e
    set -u
    # The gate's only dependency is la__capacity_via_daemon — stubbed here to
    # return a fully-allowed blob, so the ONLY surface capable of denying is
    # the spare-only branch (the failure mode this PART tests in isolation).
    la__capacity_via_daemon() {
      printf '%s' '{"pct_5h":10,"pct_7d":10,"spare_ramp_today":50,"allowed_cost_classes":["standard","high","low_priority"]}'
    }
    # Extract daemon_ask_capacity verbatim from the runner — anti-drift: if
    # the runner ever renames or relocates the function, this awk fails-loud
    # rather than silently shadowing a stale copy.
    eval "$(awk '
      /^daemon_ask_capacity\(\)/      {in_fn=1}
      in_fn                            {print}
      in_fn && /^}/ && !/^}.*{/        {if (NR>0) exit}
    ' "$RUNNER_SH")"
    out=$(daemon_ask_capacity "$cost_class" "$desired_state" 2>/dev/null); rc=$?
    printf '%s|%s' "$rc" "$out"
  )
}

# C1 — spare-cycles + standard ⇒ DENIED with the WHY (spare-only), not the
# downstream symptom (cost_class_not_allowed when standard would otherwise be
# fine machine-wide).
R="$(run_capacity standard spare-cycles)"
eq "${R##*|}" "spare_only_standard_disallowed" "C1: spare-cycles + standard ⇒ reason='spare_only_standard_disallowed'"
eq "${R%%|*}" "1" "C1: spare-cycles + standard ⇒ rc=1 (denied, caller releases lease)"

# C2 — spare-cycles + low_priority ⇒ ALLOWED (the spare-only mode IS the
# low-priority lane; the machine-wide ramp gate then bounds the throughput).
R="$(run_capacity low_priority spare-cycles)"
eq "${R##*|}" "ok" "C2: spare-cycles + low_priority ⇒ allowed"
eq "${R%%|*}" "0" "C2: spare-cycles + low_priority ⇒ rc=0 (proceed to claim)"

# C3 — running + standard ⇒ ALLOWED (the gate is OFF outside spare-only mode).
R="$(run_capacity standard running)"
eq "${R##*|}" "ok" "C3: running + standard ⇒ allowed (gate off outside spare-only)"
eq "${R%%|*}" "0" "C3: running + standard ⇒ rc=0"

# C4 — paused + standard ⇒ ALLOWED at the daemon_ask_capacity level (the
# pickup actually being suppressed is the runner's own job_reconcile_desired
# concern, which holds the loop BEFORE the capacity gate is consulted; the
# gate itself only fires when the runner has decided to consider a pickup).
R="$(run_capacity standard paused)"
eq "${R##*|}" "ok" "C4: paused + standard ⇒ gate itself ok (loop-hold is upstream)"

# C5 — desired absent / empty (standalone-runner posture) ⇒ ALLOWED (BC: the
# gate is opt-in by passing the desired-state arg).
R="$(run_capacity standard "")"
eq "${R##*|}" "ok" "C5: empty desired-state ⇒ allowed (BC for standalone runs)"

# C6 — an unnormalised 'spare-only' value DOES NOT trigger the gate (the
# gate's case-arm is keyed on the §4.2 enum exactly). Confirms the
# WIRE_STATE map in the proxy is load-bearing.
R="$(run_capacity standard "spare-only")"
eq "${R##*|}" "ok" "C6: unnormalised 'spare-only' literal ⇒ gate does NOT fire (proxy WIRE_STATE map is load-bearing — the gate keys on §4.2 'spare-cycles' literally)"

# ════════════════════════════════════════════════════════════════════════════
# PART D — Honest-state rendering: the Board's read path sees the new desired
# AFTER set-desired, with the runner's `actual` UNCHANGED (principle 4).
# Drives the same store the engine reads back via the §4.5 work-snapshot
# projection.
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART D — honest-state: write moves desired, never promotes actual ──"

CO_STORE_D="$WORK/store-D"
export CO_STORE="$CO_STORE_D"
# Re-source coordinator so the store change takes effect inside its helpers.
# shellcheck source=/dev/null
source "$LIB"

# Seed a RunnerState with actual=running, then set-desired=stopped via the F1
# op; the read MUST show desired=stopped + actual=running (write never
# promotes actual). The same property is what the Board's "target: stopped"
# label depends on (deriveRunner shows actual then unreached target).
co_request "$GOOD" put runner_state projF3-D \
  '{"schema_version":1,"desired":"running","actual":"running","last_heartbeat_at":"2026-05-20T00:00:00Z"}' >/dev/null 2>&1
co_request "$GOOD" set-desired projF3-D "stopped" "ui:brian" >/dev/null 2>&1
rs="$(co_request "$GOOD" get runner_state projF3-D 2>/dev/null)"
eq "$(printf '%s' "$rs" | jq -r .desired 2>/dev/null)" "stopped" "D: set-desired moved desired to stopped"
eq "$(printf '%s' "$rs" | jq -r .actual  2>/dev/null)" "running" "D: actual UNCHANGED by the write (principle 4 — honest)"
eq "$(printf '%s' "$rs" | jq -r .last_desired_actor 2>/dev/null)" "ui:brian" "D: last_desired_actor captured verbatim (C4 seam)"

# ────────────────────────────────────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────────────"
printf '  passed: %d  failed: %d\n' "$PASS" "$FAIL"
echo "──────────────────────────────────────────────────────────────────────"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
