#!/bin/bash
# beads-runner/daemon/live-smoke-flow-d.sh — F3 LIVE smoke (claude-tools-6mx).
#
# WHAT THIS IS — the human-driven live exercise of Flow D against the DEPLOYED
# engine + a running daemon + a running workspace runner. The hermetic
# integration test (lib/test-flow-d.sh) proves the wire contract is correct;
# this script proves the LOOP closes on a real machine: a desired-state flip
# on the deployed engine causes the daemon to converge the workspace's
# actual-state within ~60s.
#
# It is intentionally NOT plugged into any automated test runner — running it
# touches a live workspace's lifecycle (spawn / SIGTERM) and only makes sense
# when a human can watch.
#
# WHAT IT DOES
#   1. Reads desired-state from the deployed engine via co_request poll.
#      (sanity: the proxy + adapter + engine chain answers.)
#   2. For each of the four desired-states, in order:
#         running → paused → spare-cycles → stopped → running
#      a. POSTs set-desired via the deployed engine (the same op the F1
#         /api/set-desired proxy posts under the hood).
#      b. Polls `co_request poll <project_ref>` every 5s for up to 90s and
#         confirms `.desired` reaches the expected value (transport round-
#         trip).
#      c. Polls the runner's pidfile + heartbeat for up to 90s (default 90;
#         override via SMOKE_CONVERGE_TIMEOUT) and confirms the workspace
#         converged (alive after running/paused/spare-cycles; dead after
#         stopped). The 60s daemon cadence + the runner's drain window means
#         90s is a comfortable bound.
#   3. Leaves the workspace in `desired=running` (a tidy default) and prints
#      a one-line PASS/FAIL summary.
#
# REQUIRES (env)
#   COORDINATOR_URL     — the deployed engine origin (e.g. https://co.example).
#   COORDINATOR_TOKEN   — the server-side bearer (read from the Keychain
#                         outside this script; never committed).
#   PROJECT_REF         — the workspace's project ref (e.g. claude-tools).
#   WORKSPACE_DIR       — the workspace's repo root (so we can find the
#                         detached-runner.pid file). Defaults to $PWD.
#   SMOKE_CONVERGE_TIMEOUT — seconds to wait per transition (default 90).
#
# DOES NOT REQUIRE
#   • bd, Dolt, jq workspace state — this is a control-plane exercise.
#   • A phone — the engine's set-desired POST is the same one the Board's
#     proxy posts. The phone vs curl distinction is presentation, not
#     transport, so a curl simulation is faithful to the production path.
#
# Exit code: 0 if every transition converged, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
LIB_DIR="$REPO_ROOT/lib"

: "${COORDINATOR_URL:?need COORDINATOR_URL (deployed engine origin)}"
: "${COORDINATOR_TOKEN:?need COORDINATOR_TOKEN (server-side bearer; read from Keychain)}"
: "${PROJECT_REF:?need PROJECT_REF (workspace project ref)}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$PWD}"
SMOKE_CONVERGE_TIMEOUT="${SMOKE_CONVERGE_TIMEOUT:-90}"

# shellcheck source=/dev/null
. "$LIB_DIR/coordinator.sh"
# shellcheck source=/dev/null
. "$LIB_DIR/co-http-transport.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

PIDFILE="$WORKSPACE_DIR/.beads/runner-logs/detached-runner.pid"

runner_alive() {
  local pid
  [[ -f "$PIDFILE" ]] || return 1
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# poll_desired <expected_state>
#   Polls the engine until RunnerState.desired == expected, or SMOKE_CONVERGE_TIMEOUT seconds.
poll_desired() {
  local want="$1" deadline got
  deadline=$(( $(date +%s) + SMOKE_CONVERGE_TIMEOUT ))
  while [[ $(date +%s) -lt $deadline ]]; do
    got="$(co_request "$COORDINATOR_TOKEN" poll "$PROJECT_REF" 2>/dev/null \
            | jq -r '.desired // ""' 2>/dev/null)" || got=""
    [[ "$got" == "$want" ]] && return 0
    sleep 5
  done
  printf '  (last observed desired=%s)\n' "$got" >&2
  return 1
}

# wait_runner_state <alive|dead>
wait_runner_state() {
  local want="$1" deadline
  deadline=$(( $(date +%s) + SMOKE_CONVERGE_TIMEOUT ))
  while [[ $(date +%s) -lt $deadline ]]; do
    if [[ "$want" == "alive" ]]; then
      runner_alive && return 0
    else
      runner_alive || return 0
    fi
    sleep 5
  done
  return 1
}

set_and_check() {
  local wire="$1" expect_runner="$2" label="$3"
  echo ""
  echo "── transition → $wire ($label) ──"
  co_request "$COORDINATOR_TOKEN" set-desired "$PROJECT_REF" "$wire" "live-smoke" >/dev/null \
    && ok "set-desired wire='$wire' accepted by the engine" \
    || { bad "set-desired wire='$wire' rejected (transport / auth?)"; return; }
  if poll_desired "$wire"; then
    ok "engine RunnerState.desired == '$wire' within ${SMOKE_CONVERGE_TIMEOUT}s (transport round-trip)"
  else
    bad "engine did not echo desired='$wire' within ${SMOKE_CONVERGE_TIMEOUT}s"
    return
  fi
  if wait_runner_state "$expect_runner"; then
    ok "workspace runner converged to $expect_runner within ${SMOKE_CONVERGE_TIMEOUT}s (daemon M3 acted)"
  else
    bad "workspace runner did NOT converge to $expect_runner within ${SMOKE_CONVERGE_TIMEOUT}s"
  fi
}

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " Flow D LIVE smoke — F3 (claude-tools-6mx)"
echo "════════════════════════════════════════════════════════════════════"
echo "  engine:        $COORDINATOR_URL"
echo "  project_ref:   $PROJECT_REF"
echo "  workspace_dir: $WORKSPACE_DIR"
echo "  timeout/state: ${SMOKE_CONVERGE_TIMEOUT}s"

# Sanity: a poll succeeds. If this fails, the rest will too — fail fast with
# a clearer message than 'set-desired rejected' on every line.
INITIAL="$(co_request "$COORDINATOR_TOKEN" poll "$PROJECT_REF" 2>/dev/null \
            | jq -r '.desired // ""' 2>/dev/null)" || INITIAL=""
if [[ -z "$INITIAL" ]]; then
  echo ""
  echo "FATAL: cannot poll engine (got empty .desired). Check COORDINATOR_URL,"
  echo "       COORDINATOR_TOKEN, PROJECT_REF, and the engine's reachability."
  exit 2
fi
echo "  starting desired: $INITIAL"

# The four-state round-trip. Each transition is independent; a failure in one
# does not abort the rest (we want the full picture in one run).
#
# stopped expects the runner to EXIT, then we re-enter `running` which expects
# the daemon to spawn it back — proving both kill AND spawn legs of M3.
set_and_check "running"      "alive" "the loop starts; runner picks up"
set_and_check "paused"       "alive" "daemon no-op; runner holds via its own job_reconcile"
set_and_check "spare-cycles" "alive" "daemon spawns (already alive); C2 gate fires per-pickup"
set_and_check "stopped"      "dead"  "daemon SIGTERMs; runner drains then exits"
set_and_check "running"      "alive" "daemon spawns the workspace back from dead (kill→spawn loop closed)"

echo ""
echo "──────────────────────────────────────────────────────────────────────"
printf '  passed: %d  failed: %d\n' "$PASS" "$FAIL"
echo "──────────────────────────────────────────────────────────────────────"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
