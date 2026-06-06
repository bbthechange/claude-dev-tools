#!/bin/bash
# beads-runner/lib/test-desired-local-first-v1.sh — claude-tools-efu3 regression-lock.
#
# The v1 sibling of test-desired-local-first.sh (which locks the v2/adapter
# co_deliver_desired_state). v1 run-beads-tasks.sh has its OWN desired-state
# resolver, workspace_desired_state(), which USED to read network desired via a
# `co_request poll` with a 30s cache and fail-OPEN to empty (⇒ callers treat as
# `running`) on any failure once the cache aged out — the break-through-pause bug
# (BC-50), milder in v1 only because the cache bounded it.
#
# THE FIX (efu3): workspace_desired_state reads the LOCAL .co-store
# RunnerState.desired FIRST (co__store_get runner_state "$PROJECT_REF"), so a
# present paused/stopped/spare-cycles SURVIVES a Coordinator-unreachable window.
# The network is demoted to a cold-start seed (no local record yet). A cold-start
# network MISS still echoes empty (= the v1 bootstrap-to-running posture — a
# launched runner's implicit desired is running; nothing to break through).
#
# Offline + deterministic: BEADS_RUNNER_TEST_MODE=1 lets us `source` the runner
# to load its functions WITHOUT entering the task loop; a temp CO_STORE; co_request
# is stubbed where the cold-start network path is exercised; jq only.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
result() { echo "RESULT: $PASS passed, $FAIL failed"; [[ "$FAIL" -eq 0 ]]; }

command -v jq >/dev/null 2>&1 || { echo "  (skip) jq not available"; echo "RESULT: 0 passed, 0 failed"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
unset COORDINATOR_URL 2>/dev/null || true     # keep co_request in-process / stubbable
export CO_STORE="$TMP/.co-store"
mkdir -p "$CO_STORE/records"
export PROJECT_REF="ct-v1-localfirst"
export ASK_BRIAN_ENABLED=0                     # keep the loop-top feedback poll dead
export USAGE_POLL_DISABLED=1                   # source-only; never hit the keychain

# Source the v1 runner in test mode: defines workspace_desired_state + sources the
# coordinator.sh store primitives (co__store_get) via the SR/LA guard chain, but
# returns at the gk17 source-guard before `hb starting`/`while true`.
export BEADS_RUNNER_TEST_MODE=1
# shellcheck source=/dev/null
source "$REPO/run-beads-tasks.sh" >/dev/null 2>&1 \
  || { bad "could not source run-beads-tasks.sh in test mode"; result; exit 1; }

command -v workspace_desired_state >/dev/null 2>&1 \
  || { bad "workspace_desired_state not defined after source"; result; exit 1; }
command -v co__store_get >/dev/null 2>&1 \
  || { bad "co__store_get not available (coordinator.sh guard chain did not load)"; result; exit 1; }

REC="$CO_STORE/records/runner_state.$PROJECT_REF.json"
write_desired() { # <state>
  printf '{"schema_version":1,"project_ref":"%s","principal":"brian","desired":"%s","actual":"running","last_heartbeat_at":"2026-06-06T00:00:00Z"}\n' \
    "$PROJECT_REF" "$1" > "$REC"
}
reset_cache() { DESIRED_STATE_CACHE_VALUE=""; DESIRED_STATE_CACHE_TIME=0; }

echo "── A. break-through-pause: local desired wins, even when UNREACHABLE ──"
# Stub co_request as the genuinely-unreachable transport. With a LOCAL value
# present this path must NEVER be consulted — local wins outright — so the
# unreachable engine cannot break through the pause.
co_request() { CO_HTTP_UNREACHABLE=1; return 4; }

for st in paused stopped spare-cycles running; do
  reset_cache
  write_desired "$st"
  out="$(workspace_desired_state)"
  if [[ "$out" == "$st" ]]; then
    ok "local desired=$st SURVIVES an unreachable engine (the fix)"
  else
    bad "BREAK-THROUGH REGRESSION: local desired=$st but got '$out'"
  fi
done

# A poisoned cache (a stale network 'running' latched before the pause) must NOT
# override a present local pause — the local read precedes the cache check.
reset_cache
DESIRED_STATE_CACHE_VALUE="running"; DESIRED_STATE_CACHE_TIME=$(date +%s)
write_desired paused
out="$(workspace_desired_state)"
[[ "$out" == "paused" ]] && ok "local paused beats a fresh cached 'running' (local read precedes cache)" \
  || bad "cache poisoning: expected paused, got '$out'"
unset -f co_request 2>/dev/null || true

echo "── B. cold-start (no local record): network seed, else empty bootstrap ──"
rm -f "$REC"
reset_cache
co_request() { printf '{"desired":"paused"}\n'; return 0; }   # reachable poll
out="$(workspace_desired_state)"
[[ "$out" == "paused" ]] && ok "cold-start: a reachable engine SEEDS desired=paused" \
  || bad "cold-start seed: expected paused, got '$out'"
unset -f co_request 2>/dev/null || true

reset_cache
co_request() { CO_HTTP_UNREACHABLE=1; return 4; }             # unreachable
out="$(workspace_desired_state)"
[[ -z "$out" ]] && ok "cold-start + unreachable: empty echo (v1 bootstrap-to-running)" \
  || bad "bootstrap: expected empty, got '$out'"
unset -f co_request 2>/dev/null || true

echo "── C. a corrupt/garbled local record falls through (no crash) ──"
reset_cache
printf 'not json{' > "$REC"
co_request() { CO_HTTP_UNREACHABLE=1; return 4; }
out="$(workspace_desired_state)"
[[ -z "$out" ]] && ok "corrupt local record degrades to cold-start (empty, no crash)" \
  || bad "corrupt record: expected empty, got '$out'"
unset -f co_request 2>/dev/null || true

reset_cache
# An UNRECOGNIZED local desired (a garbage enum) is not a usable value ⇒ fall
# through to cold-start handling rather than returning the garbage verbatim.
printf '{"schema_version":1,"project_ref":"%s","desired":"halt"}\n' "$PROJECT_REF" > "$REC"
co_request() { printf '{"desired":"stopped"}\n'; return 0; }
out="$(workspace_desired_state)"
[[ "$out" == "stopped" ]] && ok "unrecognized local desired falls through to the network seed" \
  || bad "unrecognized local: expected stopped (seed), got '$out'"
unset -f co_request 2>/dev/null || true
rm -f "$REC"

echo "── D. CO_STORE exported at startup (read hits the daemon's store, not /tmp) ──"
# The runner's startup export must point co_store_dir() at the per-workspace store
# the daemon writes — NOT the /tmp scratch default. We sourced with CO_STORE set,
# so the resolver's record path must live under our temp CO_STORE.
got_dir="$(co_store_dir 2>/dev/null)"
[[ "$got_dir" == "$CO_STORE" ]] \
  && ok "co_store_dir() resolves to the exported CO_STORE ($CO_STORE)" \
  || bad "co_store_dir() = '$got_dir' (expected '$CO_STORE') — startup export missing/overridden"

result
