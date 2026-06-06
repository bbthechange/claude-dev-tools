#!/bin/bash
# beads-runner/daemon/test-m3-desired-state.sh — M3 desired-state poll +
# spawn/SIGTERM state machine (claude-tools-cgh; epic claude-tools-kie).
#
# WHAT THIS PROVES
#   PART 0 — files exist, parse, are wired into daemon.sh.
#   PART A — daemon_m3_runner_pid classifies the pidfile correctly
#            (absent / stale / live).
#   PART B — daemon_m3_fetch_desired returns ONLY a valid §4.2 enum value
#            (running|paused|spare-cycles|stopped) or empty for no-action.
#            Uses the in-process bash coordinator store (no COORDINATOR_URL
#            ⇒ no HTTP override) so the test is hermetic.
#   PART C — the per-workspace state machine takes the right action for
#            each (desired, runner-alive?) pair, with transitions logged
#            using "<old> → <new>" and workspace identity. We exercise the
#            DAEMON_M3_DISABLED=1 canary branch so spawn/SIGTERM resolve to
#            log lines (no real processes touched in CI).
#   PART D — daemon survives a workspace runner crashing: a previously-
#            observed `running` workspace whose runner pid is now dead is
#            re-classified as absent + scheduled for re-spawn next cycle.
#   PART E — daemon-restart pidfile adoption: a workspace with a LIVE
#            pidfile (this shell's pid) + desired=stopped is correctly
#            recognized as alive-and-must-stop on the first reconcile.
#   PART F — daemon.sh wires desired-state-poll.sh into the main loop
#            (sourced + DESIRED_STATE_POLL_INTERVAL declared + driver call
#            site present) — the static checks that catch a refactor
#            silently unwiring the M3 path.
#
# Not part of the T1 conformance suite — its own focused acceptance,
# mirroring test-m4-hosted-resolution-poll.sh / test-m6-dispatch.sh.
# Run: bash beads-runner/daemon/test-m3-desired-state.sh
set -u

# Hermetic: this offline tier must use the IN-PROCESS bash oracle, never an
# ambient hosted endpoint. co-http-transport.sh overrides co_request when
# COORDINATOR_URL is set, so a dev machine with the daemon configured would
# otherwise leak its live URL into PART B's fetch subshell (returning empty for
# every stored record). Mirror test-agent-action-poll.sh's hermetic guard.
# (run-tests.sh already unsets these for the whole gate; this makes the test
# hermetic STANDALONE too — claude-tools-y6j9.)
unset COORDINATOR_URL COORDINATOR_TOKEN 2>/dev/null || true

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
LIB_DIR="$REPO_ROOT/lib"
DAEMON_SH="$HERE/daemon.sh"
M3_LIB="$HERE/desired-state-poll.sh"
REGISTRY_LIB="$HERE/workspace-registry.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
eq()  { [[ "$1" == "$2" ]] && ok "$3" || bad "$3 (got '$1' want '$2')"; }
has() { case "$1" in *"$2"*) ok "$3";; *) bad "$3 (missing '$2')";; esac; }
nothas() { case "$1" in *"$2"*) bad "$3 (unexpectedly contains '$2')";; *) ok "$3";; esac; }

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " M3 desired-state poll — claude-tools-cgh (epic claude-tools-kie)"
echo "════════════════════════════════════════════════════════════════════"

# ════════════════════════════════════════════════════════════════════════════
# PART 0 — files exist, parse, are wired
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART 0 — files exist, parse, are wired (static) ──"
[[ -f "$M3_LIB" ]] && ok "desired-state-poll.sh present" || bad "desired-state-poll.sh missing"
bash -n "$M3_LIB" 2>/dev/null && ok "desired-state-poll.sh parses (bash -n clean)" || bad "desired-state-poll.sh syntax"
bash -n "$DAEMON_SH" 2>/dev/null && ok "daemon.sh parses (bash -n clean) with M3 wiring" || bad "daemon.sh syntax"

for fn in daemon_m3_runner_pid daemon_m3_runner_pidfile daemon_m3_fetch_desired \
          daemon_m3_read_local_desired \
          daemon_m3_spawn daemon_m3_stop \
          daemon_m3_reconcile_workspace daemon_m3_reconcile_all \
          daemon_m3_reset_state_memory; do
  grep -q "^$fn()" "$M3_LIB" && ok "desired-state-poll.sh defines $fn" || bad "desired-state-poll.sh defines $fn"
done

# ════════════════════════════════════════════════════════════════════════════
# PART A — daemon_m3_runner_pid: pidfile classifier
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART A — daemon_m3_runner_pid classifies pidfile (absent/stale/live) ──"

# Source the M3 lib (also need REGISTRY_<arrays> from workspace-registry.sh
# so daemon_m3_fetch_desired's array reads don't trip set -u in callers).
# shellcheck source=/dev/null
. "$REGISTRY_LIB" 2>/dev/null || { bad "could not source workspace-registry.sh"; exit 1; }
# shellcheck source=/dev/null
. "$M3_LIB" 2>/dev/null || { bad "could not source desired-state-poll.sh"; exit 1; }

WA="$(mktemp -d)"
trap 'rm -rf "$WA"; rm -rf "${WB:-}" "${WC:-}" "${WD:-}" "${WE:-}" 2>/dev/null || true' EXIT
mkdir -p "$WA/.beads/runner-logs"

# A1 — no pidfile ⇒ empty
eq "$(daemon_m3_runner_pid "$WA")" "" "A1: no pidfile ⇒ daemon_m3_runner_pid empty"

# A2 — stale pidfile (very unlikely-alive pid 99999) ⇒ empty + pidfile reclaimed
echo "99999" > "$WA/.beads/runner-logs/detached-runner.pid"
out="$(daemon_m3_runner_pid "$WA")"
eq "$out" "" "A2: stale pidfile (dead pid) ⇒ daemon_m3_runner_pid empty"
[[ ! -f "$WA/.beads/runner-logs/detached-runner.pid" ]] \
  && ok "A2: stale pidfile reclaimed (no phantom-alive on next cadence)" \
  || bad "A2: stale pidfile must be removed by the classifier"

# A3 — live pidfile (this shell's own pid) ⇒ echoes that pid, leaves pidfile alone
echo "$$" > "$WA/.beads/runner-logs/detached-runner.pid"
eq "$(daemon_m3_runner_pid "$WA")" "$$" "A3: live pidfile ⇒ daemon_m3_runner_pid echoes the pid"
[[ -f "$WA/.beads/runner-logs/detached-runner.pid" ]] \
  && ok "A3: live pidfile preserved (only stale ones get reclaimed)" \
  || bad "A3: live pidfile must not be removed by the classifier"

# ════════════════════════════════════════════════════════════════════════════
# PART B — daemon_m3_fetch_desired: enum-only, hermetic via in-process store
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART B — daemon_m3_fetch_desired returns ONLY a §4.2 enum value ──"

WB="$(mktemp -d)"
WSB="$WB/workspace"
mkdir -p "$WSB/.beads/runner-logs"

# Seed the registry with one workspace pointing at WSB.
REGISTRY_PROJECT_REFS=("tools-m3test")
REGISTRY_DIRS=("$WSB")
REGISTRY_COORDINATOR_URLS=("")
REGISTRY_TOKEN_KEYCHAIN_ITEMS=("")
REGISTRY_LOADED=1

# B1 — empty store ⇒ co__poll returns desired:null ⇒ fetch echoes empty
out="$(daemon_m3_fetch_desired 0)"
eq "$out" "" "B1: empty store ⇒ desired empty (daemon will no-op, fail-safe)"

# Seed a RunnerState record with desired=stopped via the in-process store.
# Mimic co__store_put's on-disk shape: $CO_STORE/records/runner_state.<key>.json.
# (Anti-flake: we cannot call `co set-desired` here because that requires the
# §9.1 authenticate chokepoint to be wired; the test only cares that
# daemon_m3_fetch_desired READS the stored .desired field correctly.)
WS_STORE="$WSB/.beads/runner-logs/.co-store"
mkdir -p "$WS_STORE/records"
write_runner_state() {
  local desired="$1"
  jq -cn --arg p "tools-m3test" --arg d "$desired" \
    '{schema_version:1,project_ref:$p,desired:$d,actual:"running",
      last_heartbeat_at:"2026-05-20T00:00:00Z",last_desired_actor:"test",
      updated_at:"2026-05-20T00:00:00Z"}' \
    > "$WS_STORE/records/runner_state.tools-m3test.json"
}

write_runner_state "stopped"
eq "$(daemon_m3_fetch_desired 0)" "stopped" "B2: desired=stopped read via in-process poll"

write_runner_state "running"
eq "$(daemon_m3_fetch_desired 0)" "running" "B3: desired=running read via in-process poll"

write_runner_state "paused"
eq "$(daemon_m3_fetch_desired 0)" "paused" "B4: desired=paused read via in-process poll"

write_runner_state "spare-cycles"
eq "$(daemon_m3_fetch_desired 0)" "spare-cycles" "B5: desired=spare-cycles read via in-process poll"

# B6 — defense in depth: a malformed/out-of-enum value must be coerced to empty
# (the daemon would otherwise fall into the unrecognized-arm and no-op anyway,
# but the contract is "only act on enum values").
write_runner_state "weird-future-state"
eq "$(daemon_m3_fetch_desired 0)" "" "B6: out-of-enum desired coerced to empty (NO action on garbage)"

# ════════════════════════════════════════════════════════════════════════════
# PART C — per-workspace state machine. Uses DAEMON_M3_DISABLED=1 canary so
#          spawn/SIGTERM resolve to log lines without touching real processes.
#          We capture the daemon `log` function's stdout via redirection.
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART C — state machine (canary mode, no real processes) ──"

WC="$(mktemp -d)"
WSC="$WC/workspace"
mkdir -p "$WSC/.beads/runner-logs"
WS_STORE_C="$WSC/.beads/runner-logs/.co-store"
mkdir -p "$WS_STORE_C/records"

# Stub `log` to capture observable lines into a temp file (the daemon's real
# `log` writes to stdout; we proxy it the same way).
M3_LOGS="$WC/m3.log"
: > "$M3_LOGS"
log() { printf '[stub-log] %s\n' "$*" >> "$M3_LOGS"; }
export -f log 2>/dev/null || true

# Reset registry to a single fixture pointing at WSC.
REGISTRY_PROJECT_REFS=("tools-m3test-c")
REGISTRY_DIRS=("$WSC")
REGISTRY_COORDINATOR_URLS=("")
REGISTRY_TOKEN_KEYCHAIN_ITEMS=("")
REGISTRY_LOADED=1
daemon_m3_reset_state_memory

export DAEMON_M3_DISABLED=1

write_runner_state_c() {
  local desired="$1"
  jq -cn --arg p "tools-m3test-c" --arg d "$desired" \
    '{schema_version:1,project_ref:$p,desired:$d,actual:"running",
      last_heartbeat_at:"2026-05-20T00:00:00Z",last_desired_actor:"test",
      updated_at:"2026-05-20T00:00:00Z"}' \
    > "$WS_STORE_C/records/runner_state.tools-m3test-c.json"
}

# C1 — desired=running + no runner ⇒ "spawning" + transition <unset> → running.
write_runner_state_c "running"
rm -f "$WSC/.beads/runner-logs/detached-runner.pid"
: > "$M3_LOGS"
daemon_m3_reconcile_workspace 0
logs="$(cat "$M3_LOGS")"
has "$logs" "M3 transition: workspace=$WSC" "C1: transition logged with workspace path"
has "$logs" "desired <unset> → running"      "C1: transition logs <unset> → running on first observation"
has "$logs" "runner absent, spawning"        "C1: state-machine takes spawn action on (running, no runner)"
has "$logs" "DAEMON_M3_DISABLED=1"           "C1: canary branch fires (no real launch-detached.sh invocation)"

# C2 — desired=running + runner alive ⇒ no-op; no second transition line (prev=running).
echo "$$" > "$WSC/.beads/runner-logs/detached-runner.pid"
: > "$M3_LOGS"
daemon_m3_reconcile_workspace 0
logs="$(cat "$M3_LOGS")"
nothas "$logs" "M3 transition:"     "C2: no transition logged (prev=running, observed=running)"
nothas "$logs" "spawning"           "C2: no spawn (runner already alive)"
nothas "$logs" "SIGTERM"            "C2: no SIGTERM (running ≠ stopped)"

# C3 — desired=stopped + runner alive ⇒ SIGTERM + transition running → stopped.
write_runner_state_c "stopped"
: > "$M3_LOGS"
daemon_m3_reconcile_workspace 0
logs="$(cat "$M3_LOGS")"
has "$logs" "desired running → stopped" "C3: transition logs running → stopped"
has "$logs" "would SIGTERM pid=$$"      "C3: canary SIGTERM intent logged with correct pid"

# C4 — desired=stopped + no runner ⇒ no-op (already converged).
rm -f "$WSC/.beads/runner-logs/detached-runner.pid"
: > "$M3_LOGS"
daemon_m3_reconcile_workspace 0
logs="$(cat "$M3_LOGS")"
nothas "$logs" "M3 transition:"  "C4: no transition logged (prev=stopped, observed=stopped)"
nothas "$logs" "SIGTERM"         "C4: no SIGTERM (no runner to stop)"
nothas "$logs" "spawning"        "C4: no spawn (desired=stopped)"

# C5 — desired=paused + runner alive ⇒ no-op + transition stopped → paused.
echo "$$" > "$WSC/.beads/runner-logs/detached-runner.pid"
write_runner_state_c "paused"
: > "$M3_LOGS"
daemon_m3_reconcile_workspace 0
logs="$(cat "$M3_LOGS")"
has    "$logs" "desired stopped → paused" "C5: transition logs stopped → paused"
nothas "$logs" "SIGTERM"                  "C5: no SIGTERM (paused leaves runner alive)"
nothas "$logs" "spawning"                 "C5: no spawn (already alive)"

# C6 — desired=paused + no runner ⇒ no-op (do NOT spawn a paused workspace).
rm -f "$WSC/.beads/runner-logs/detached-runner.pid"
: > "$M3_LOGS"
daemon_m3_reconcile_workspace 0
logs="$(cat "$M3_LOGS")"
nothas "$logs" "spawning" "C6: paused + no runner ⇒ NO spawn (paused dead workspaces stay dead until running)"

# C7 — desired=spare-cycles + no runner ⇒ spawn (treated like running for lifecycle).
write_runner_state_c "spare-cycles"
: > "$M3_LOGS"
daemon_m3_reconcile_workspace 0
logs="$(cat "$M3_LOGS")"
has "$logs" "desired paused → spare-cycles"     "C7: transition logs paused → spare-cycles"
has "$logs" "desired=spare-cycles ⇒ runner absent, spawning" "C7: spare-cycles spawns like running"

# ════════════════════════════════════════════════════════════════════════════
# PART D — daemon survives a workspace runner crashing
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART D — daemon survives a workspace runner crashing ──"

WD="$(mktemp -d)"
WSD="$WD/workspace"
mkdir -p "$WSD/.beads/runner-logs"
WS_STORE_D="$WSD/.beads/runner-logs/.co-store"
mkdir -p "$WS_STORE_D/records"

REGISTRY_PROJECT_REFS=("tools-m3test-d")
REGISTRY_DIRS=("$WSD")
REGISTRY_COORDINATOR_URLS=("")
REGISTRY_TOKEN_KEYCHAIN_ITEMS=("")
REGISTRY_LOADED=1
daemon_m3_reset_state_memory

jq -cn --arg p "tools-m3test-d" --arg d "running" \
  '{schema_version:1,project_ref:$p,desired:$d,actual:"running",
    last_heartbeat_at:"2026-05-20T00:00:00Z",last_desired_actor:"test",
    updated_at:"2026-05-20T00:00:00Z"}' \
  > "$WS_STORE_D/records/runner_state.tools-m3test-d.json"

# Cycle 1: alive runner — no spawn.
echo "$$" > "$WSD/.beads/runner-logs/detached-runner.pid"
: > "$M3_LOGS"
daemon_m3_reconcile_workspace 0
logs="$(cat "$M3_LOGS")"
nothas "$logs" "spawning" "D-pre: cycle 1 with alive runner ⇒ no spawn"

# Cycle 2: runner "crashed" — pidfile points at a dead pid. We expect the
# next reconcile to recognize the runner as absent and re-spawn.
echo "99999" > "$WSD/.beads/runner-logs/detached-runner.pid"
: > "$M3_LOGS"
daemon_m3_reconcile_workspace 0
logs="$(cat "$M3_LOGS")"
has "$logs" "runner absent, spawning" "D: crashed runner ⇒ daemon re-spawns on next reconcile (survives crash)"
[[ ! -f "$WSD/.beads/runner-logs/detached-runner.pid" ]] \
  && ok "D: stale pidfile reclaimed on the cycle that observed the crash" \
  || bad "D: stale pidfile must be reclaimed when the runner is observed absent"

# ════════════════════════════════════════════════════════════════════════════
# PART E — daemon-restart pidfile adoption
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART E — daemon adopts existing pidfile + reconciles against desired ──"

WE="$(mktemp -d)"
WSE="$WE/workspace"
mkdir -p "$WSE/.beads/runner-logs"
WS_STORE_E="$WSE/.beads/runner-logs/.co-store"
mkdir -p "$WS_STORE_E/records"

REGISTRY_PROJECT_REFS=("tools-m3test-e")
REGISTRY_DIRS=("$WSE")
REGISTRY_COORDINATOR_URLS=("")
REGISTRY_TOKEN_KEYCHAIN_ITEMS=("")
REGISTRY_LOADED=1
daemon_m3_reset_state_memory

# Pre-existing live pidfile (this shell's pid) + desired=stopped: the very
# first reconcile after a daemon restart must SIGTERM the adopted runner.
echo "$$" > "$WSE/.beads/runner-logs/detached-runner.pid"
jq -cn --arg p "tools-m3test-e" \
  '{schema_version:1,project_ref:$p,desired:"stopped",actual:"running",
    last_heartbeat_at:"2026-05-20T00:00:00Z",last_desired_actor:"test",
    updated_at:"2026-05-20T00:00:00Z"}' \
  > "$WS_STORE_E/records/runner_state.tools-m3test-e.json"
: > "$M3_LOGS"
daemon_m3_reconcile_workspace 0
logs="$(cat "$M3_LOGS")"
has "$logs" "would SIGTERM pid=$$" "E: first reconcile after restart honors stopped against the adopted live pidfile"
has "$logs" "desired <unset> → stopped" "E: first observation logs <unset> → stopped (pidfile adoption + state observation)"

# ════════════════════════════════════════════════════════════════════════════
# PART G — v2 staged-cutover marker (claude-tools-v2c4): a per-workspace
#          use-runner-v2 marker flips daemon_m3_spawn to the v2 runner with the
#          mandatory RUNNER_BACKEND=real; absent ⇒ v1 default, byte-for-byte
#          unchanged. We exercise the DAEMON_M3_DISABLED=1 canary so the spawn
#          resolves to a log line (no real launch-detached invocation).
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART G — v2 cutover marker selection (canary branch) ──"
GWS="$WSC"   # reuse C's workspace (already has .beads/runner-logs)
GMARK="$GWS/.beads/runner-logs/use-runner-v2"
rm -f "$GMARK"

# G0 — marker-path helper + the uses-v2 predicate (absent marker).
eq "$(daemon_m3_v2_marker "$GWS")" "$GMARK" "G0: daemon_m3_v2_marker echoes the runner-logs/use-runner-v2 path"
if daemon_m3_uses_v2 "$GWS"; then bad "G0: absent marker must NOT select v2"; else ok "G0: absent marker ⇒ daemon_m3_uses_v2 false (v1 default)"; fi

# G1 — no marker ⇒ spawn selects v1 (default path unchanged, no backend pin).
: > "$M3_LOGS"
daemon_m3_spawn "$GWS" >/dev/null 2>&1
logs="$(cat "$M3_LOGS")"
has "$logs" "would launch v1 (run-beads-tasks.sh)" "G1: absent marker ⇒ canary spawn selects v1 (default unchanged)"
nothas "$logs" "RUNNER_BACKEND=real"               "G1: v1 spawn never pins RUNNER_BACKEND"

# G2 — marker present ⇒ uses_v2 true + spawn selects v2 with RUNNER_BACKEND=real.
: > "$GMARK"
if daemon_m3_uses_v2 "$GWS"; then ok "G2: marker present (+ runner.sh exists) ⇒ daemon_m3_uses_v2 true"; else bad "G2: marker present must select v2"; fi
: > "$M3_LOGS"
daemon_m3_spawn "$GWS" >/dev/null 2>&1
logs="$(cat "$M3_LOGS")"
has "$logs" "would launch v2 (runner.sh, RUNNER_BACKEND=real)" "G2: marker ⇒ canary spawn selects v2 with the mandatory real backend"
has "$logs" "use-runner-v2 marker"                              "G2: spawn log names the marker that flipped it"

# G3 — instant rollback: removing the marker reverts to v1 on the next spawn.
rm -f "$GMARK"
: > "$M3_LOGS"
daemon_m3_spawn "$GWS" >/dev/null 2>&1
logs="$(cat "$M3_LOGS")"
has "$logs" "would launch v1 (run-beads-tasks.sh)" "G3: marker removed ⇒ next spawn is v1 again (instant rollback)"

# ════════════════════════════════════════════════════════════════════════════
# PART F — daemon.sh wires desired-state-poll.sh into the main loop
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART F — daemon.sh wires the M3 path into its main loop (static) ──"
grep -q 'desired-state-poll.sh' "$DAEMON_SH" \
  && ok "F1: daemon.sh sources desired-state-poll.sh (the M3 wire-in)" \
  || bad "F1: daemon.sh must source desired-state-poll.sh"
grep -q 'DESIRED_STATE_POLL_INTERVAL' "$DAEMON_SH" \
  && ok "F2: daemon.sh declares DESIRED_STATE_POLL_INTERVAL (60s default matches the runner's S-5 cadence)" \
  || bad "F2: daemon.sh must declare DESIRED_STATE_POLL_INTERVAL"
grep -q 'daemon_m3_reconcile_all' "$DAEMON_SH" \
  && ok "F3: daemon.sh main loop calls daemon_m3_reconcile_all on cadence" \
  || bad "F3: daemon.sh must call daemon_m3_reconcile_all in main loop"
grep -q 'daemon_m3_reset_state_memory' "$DAEMON_SH" \
  && ok "F4: daemon.sh SIGHUP-reload drops the per-workspace last-desired memory (registry reload hygiene)" \
  || bad "F4: daemon.sh must call daemon_m3_reset_state_memory on SIGHUP reload"

# ════════════════════════════════════════════════════════════════════════════
# PART H — LOCAL-FIRST desired read (claude-tools-y6j9). The daemon reads the
#          local .co-store RunnerState FIRST; a present paused/stopped can NEVER
#          be flipped by a stale/unreachable network poll (the break-through-pause
#          fix, daemon half). The network is demoted to a COLD-START seed.
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART H — local-first desired read (break-through-pause, daemon half) ──"

WH="$(mktemp -d)"; WSH="$WH/workspace"
trap 'rm -rf "$WA" "${WB:-}" "${WC:-}" "${WD:-}" "${WE:-}" "${WH:-}" 2>/dev/null || true' EXIT
mkdir -p "$WSH/.beads/runner-logs/.co-store/records"
REGISTRY_PROJECT_REFS=("tools-m3test-h"); REGISTRY_DIRS=("$WSH")
REGISTRY_COORDINATOR_URLS=(""); REGISTRY_TOKEN_KEYCHAIN_ITEMS=("")
REGISTRY_LOADED=1
daemon_m3_reset_state_memory
WS_STORE_H="$WSH/.beads/runner-logs/.co-store"
write_runner_state_h() {
  jq -cn --arg p "tools-m3test-h" --arg d "$1" \
    '{schema_version:1,project_ref:$p,desired:$d,actual:"running"}' \
    > "$WS_STORE_H/records/runner_state.tools-m3test-h.json"
}

# H1 — daemon_m3_read_local_desired reads the local record directly (offline).
write_runner_state_h "paused"
eq "$(daemon_m3_read_local_desired "$WSH" "tools-m3test-h")" "paused" \
  "H1: daemon_m3_read_local_desired reads the local .co-store record directly"

# H2 — local=paused WINS over a network fetch that says running (THE bug: an
# unreachable engine fail-opened to running and broke through the pause). Stub
# the network fetch to 'running'; reconcile must read LOCAL and NOT spawn.
export DAEMON_M3_DISABLED=1
daemon_m3_fetch_desired() { echo "running"; }   # simulate stale / fail-open network
rm -f "$WSH/.beads/runner-logs/detached-runner.pid"
: > "$M3_LOGS"
daemon_m3_reconcile_workspace 0
logs="$(cat "$M3_LOGS")"
nothas "$logs" "spawning" "H2: local=paused WINS over a 'running' network fetch (NO break-through spawn)"
has    "$logs" "→ paused"  "H2: reconcile acted on the LOCAL paused value (not the network's running)"
unset -f daemon_m3_fetch_desired

# H3 — cold-start: NO local record ⇒ the network seed supplies desired.
rm -f "$WS_STORE_H/records/runner_state.tools-m3test-h.json"
daemon_m3_fetch_desired() { echo "stopped"; }   # cold-start network seed
echo "$$" > "$WSH/.beads/runner-logs/detached-runner.pid"
daemon_m3_reset_state_memory
: > "$M3_LOGS"
daemon_m3_reconcile_workspace 0
logs="$(cat "$M3_LOGS")"
has "$logs" "would SIGTERM pid=$$" "H3: cold-start (no local record) falls back to the network seed (stopped ⇒ SIGTERM)"
unset -f daemon_m3_fetch_desired
unset DAEMON_M3_DISABLED

# ────────────────────────────────────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────────────"
printf '  passed: %d  failed: %d\n' "$PASS" "$FAIL"
echo "──────────────────────────────────────────────────────────────────────"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
