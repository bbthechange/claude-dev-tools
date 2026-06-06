#!/bin/bash
# beads-runner/lib/test-paused-consumer-v1.sh — claude-tools-yuwe regression-lock.
#
# The CONSUMER sibling of test-desired-local-first-v1.sh (which locks the v1 READ,
# workspace_desired_state local-first). efu3 made v1 READ a local desired=paused
# reliably but deliberately left the CONSUMER gap open: v1's pickup path acted on
# `spare-cycles` (daemon_ask_capacity) and `stopped` (idle/skip + the daemon
# SIGTERM) but NOT on `paused` — so a v1 runner with desired=paused AND a workable
# bead would still CLAIM and spawn (paused was a no-op on a live v1 runner). The
# daemon delegates paused-honoring to the runner and no-ops on paused+alive, so
# nothing else covered it. See BC-50.
#
# THE FIX (claude-tools-yuwe): the loop-top `runner_should_hold_paused` predicate +
# a pickup gate that, on desired=paused, heartbeats idle, sleeps, and re-loops —
# NEVER claiming. Mirrors runner.sh st_reconcile's `paused) … hold` arm. The gate
# sits AFTER the feedback-return reconcile but BEFORE select_workable_task /
# lease_acquire, so a paused runner never claims, never churns acquire/release,
# and never pops a crash-orphan off ORPHANED_IDS only to drop it.
#
# This file locks (A) the predicate decision — paused HOLDS, every other desired
# PROCEEDS; (B) the break-through-pause posture AT THE CONSUMER — a local paused
# holds even when the engine is unreachable; (C) the structural ordering — the
# gate is called before select AND before lease (so a refactor can't reintroduce
# claim-through-pause).
#
# Offline + deterministic: BEADS_RUNNER_TEST_MODE=1 lets us `source` the runner to
# load its functions WITHOUT entering the task loop; a temp CO_STORE; co_request is
# stubbed; jq only.

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
export PROJECT_REF="ct-v1-paused-consumer"
export ASK_BRIAN_ENABLED=0                     # keep the loop-top feedback poll dead
export USAGE_POLL_DISABLED=1                   # source-only; never hit the keychain

# Source the v1 runner in test mode: defines runner_should_hold_paused +
# workspace_desired_state + the coordinator.sh store primitives (co__store_get),
# but returns at the source-guard before `hb starting` / `while true`.
export BEADS_RUNNER_TEST_MODE=1
# shellcheck source=/dev/null
source "$REPO/run-beads-tasks.sh" >/dev/null 2>&1 \
  || { bad "could not source run-beads-tasks.sh in test mode"; result; exit 1; }

command -v runner_should_hold_paused >/dev/null 2>&1 \
  || { bad "runner_should_hold_paused not defined after source"; result; exit 1; }
command -v workspace_desired_state >/dev/null 2>&1 \
  || { bad "workspace_desired_state not defined after source"; result; exit 1; }

echo "── A. predicate decision: paused HOLDS, every other desired PROCEEDS ──"
# Drive the predicate by overriding the resolver — a pure unit test of the gate
# decision, independent of where the desired value came from. (Section B exercises
# the real resolver under an unreachable engine.)
for st in running spare-cycles stopped ""; do
  eval "workspace_desired_state() { printf '%s' '$st'; }"
  if runner_should_hold_paused; then
    bad "desired='${st:-<empty>}' must PROCEED (rc 1) but the gate held"
  else
    ok "desired='${st:-<empty>}' → PROCEED (not the paused gate's job)"
  fi
done
workspace_desired_state() { printf 'paused'; }
if runner_should_hold_paused; then
  ok "desired=paused → HOLD (rc 0) — the consumer gate fires"
else
  bad "desired=paused must HOLD (rc 0) but the gate let the pickup through"
fi
unset -f workspace_desired_state 2>/dev/null || true
# Re-source to restore the REAL resolver for section B.
# shellcheck source=/dev/null
source "$REPO/run-beads-tasks.sh" >/dev/null 2>&1 || true

echo "── B. break-through-pause AT THE CONSUMER: local paused holds even UNREACHABLE ──"
REC="$CO_STORE/records/runner_state.$PROJECT_REF.json"
write_desired() { # <state>
  printf '{"schema_version":1,"project_ref":"%s","principal":"brian","desired":"%s","actual":"running","last_heartbeat_at":"2026-06-06T00:00:00Z"}\n' \
    "$PROJECT_REF" "$1" > "$REC"
}
reset_cache() { DESIRED_STATE_CACHE_VALUE=""; DESIRED_STATE_CACHE_TIME=0; }
# Stub co_request as the genuinely-unreachable transport. With a LOCAL value
# present the resolver never consults it — so an unreachable engine cannot break
# through the pause AT THE CONSUMER either (the whole point of the local-first read).
co_request() { CO_HTTP_UNREACHABLE=1; return 4; }

reset_cache; write_desired paused
if runner_should_hold_paused; then
  ok "local desired=paused + UNREACHABLE engine → HOLD (no claim-through-pause)"
else
  bad "BREAK-THROUGH REGRESSION: local paused but the consumer gate let the pickup through"
fi

for st in running spare-cycles stopped; do
  reset_cache; write_desired "$st"
  if runner_should_hold_paused; then
    bad "local desired=$st must PROCEED but the paused gate held"
  else
    ok "local desired=$st → PROCEED (only paused holds at this gate)"
  fi
done

# Cold-start (no local record) + unreachable ⇒ resolver echoes empty ⇒ bootstrap
# to running ⇒ the gate must PROCEED (a launched runner's implicit desired is
# running; there is no local pause to honor).
rm -f "$REC"; reset_cache
if runner_should_hold_paused; then
  bad "cold-start + unreachable must PROCEED (bootstrap-to-running) but the gate held"
else
  ok "cold-start + unreachable → PROCEED (bootstrap-to-running, no phantom pause)"
fi
unset -f co_request 2>/dev/null || true

echo "── C. structural ordering: the gate is called BEFORE select AND BEFORE lease ──"
SRC="$REPO/run-beads-tasks.sh"
gate_line=$(grep -n 'if runner_should_hold_paused;' "$SRC" | head -1 | cut -d: -f1)
select_line=$(grep -n 'select_workable_task ||' "$SRC" | head -1 | cut -d: -f1)
lease_line=$(grep -n 'if ! lease_acquire_ok' "$SRC" | head -1 | cut -d: -f1)

if [[ -n "$gate_line" && -n "$select_line" && -n "$lease_line" ]]; then
  if [[ "$gate_line" -lt "$select_line" ]]; then
    ok "paused gate ($gate_line) is called BEFORE select_workable_task ($select_line)"
  else
    bad "ORDERING REGRESSION: paused gate ($gate_line) is NOT before select ($select_line) — a paused runner could pop/drop an orphan or select work"
  fi
  if [[ "$gate_line" -lt "$lease_line" ]]; then
    ok "paused gate ($gate_line) is called BEFORE lease_acquire_ok ($lease_line)"
  else
    bad "ORDERING REGRESSION: paused gate ($gate_line) is NOT before lease ($lease_line) — a paused runner would churn acquire/release"
  fi
else
  bad "could not locate the gate/select/lease call sites (gate=$gate_line select=$select_line lease=$lease_line)"
fi

# The paused branch must HEARTBEAT IDLE and CONTINUE (hold), never fall through to
# a claim. Lock the gate construct itself — bounded by [gate_line, select_line) so
# the slice cannot escape into a later loop's `continue` even if the body grows.
gate_block="$(awk 'NR>='"$gate_line"' && NR<'"${select_line:-$((gate_line + 30))}"'' "$SRC")"
printf '%s' "$gate_block" | grep -q 'hb idle' \
  && ok "paused branch heartbeats idle (engine sees an idle, alive, paused runner)" \
  || bad "paused branch does NOT 'hb idle' — a held runner would look stuck, not idle"
printf '%s' "$gate_block" | grep -q 'continue' \
  && ok "paused branch re-loops (continue) — re-reconciles each poll interval" \
  || bad "paused branch does NOT 'continue' — it would fall through to the claim path"

result
