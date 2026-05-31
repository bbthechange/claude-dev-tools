#!/bin/bash
# beads-runner/daemon/notif-delivery-poll.sh — N2 (claude-tools-uxg1).
#
# DESIGN N §2.3 — the delivery clock. The actual Web-Push crypto + the
# subscription store + the deliver-once ledger all live in the hosted engine
# (cf/src/push.js, the `notif-deliver` op); the daemon's only job here is to
# RING that op on a cadence — the singleton Coordinator DO is reachable, this
# is a Mac on Brian's network that already polls it, and a poll keeps the VAPID
# PRIVATE key server-side (it never touches this machine).
#
# TWO cadences (DESIGN N §2.3 tier-keyed):
#   • blocking sweep — frequent (~30s). `notif-deliver blocking`: ONE immediate
#     push per blocking notification not yet in the ledger. Latency ≤ the poll
#     interval (near-immediate; the load-bearing path).
#   • digest sweep   — ~daily. `notif-deliver digest`: the K3 rollup folded into
#     ONE push per channel group (N pending → 1, never N — must-protect #5).
#
# Engine reach mirrors the 1p0u outbox drain (usage-poll.sh daemon_outbox_drain_once):
# resolve workspace[0]'s coordinator_url + keychain bearer, export
# COORDINATOR_URL/COORDINATOR_TOKEN, source co-http-transport.sh, call
# co_request. The Coordinator is a singleton (idFromName("coordinator")), so ONE
# call reaches the one DO that owns every workspace's notifications — this is
# NOT per-workspace.
#
# Always returns 0. A delivery failure (auth, transport, VAPID-unconfigured 503)
# is logged and left for the next cadence; it must never abort the daemon loop.
# The engine's ledger is the idempotency guard, so re-running a sweep is safe.

# Resolved at source-time; daemon.sh sets these before sourcing (defaults let
# this file be unit-tested standalone).
DAEMON_REPO_DIR="${DAEMON_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}"
DAEMON_REPO_LIB_DIR="${DAEMON_REPO_LIB_DIR:-$DAEMON_REPO_DIR/lib}"

# Test/canary hook: disable the poll entirely (a kill switch parallel to
# DAEMON_WC_DISABLED). Off by default.
DAEMON_NOTIF_DELIVERY_DISABLED="${DAEMON_NOTIF_DELIVERY_DISABLED:-0}"

_notif_delivery_log() {
  if declare -F log >/dev/null 2>&1; then
    log "[notif-delivery] $*"
  else
    printf '%s [notif-delivery] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$*" >&2
  fi
}

# _notif_deliver_call <mode> — resolve the engine + bearer (workspace[0],
# 1p0u-drain pattern), source the HTTP transport, and `co_request notif-deliver
# <mode>`. Logs the engine's one-line summary. Returns 0 always.
_notif_deliver_call() {
  local mode="$1"

  local ws_count=0
  if declare -p REGISTRY_PROJECT_REFS >/dev/null 2>&1; then
    ws_count="${#REGISTRY_PROJECT_REFS[@]}"
  fi
  if [[ "$ws_count" -eq 0 ]]; then
    _notif_delivery_log "$mode: no workspaces registered ⇒ skipping (no engine to reach)"
    return 0
  fi

  local curl_url="${REGISTRY_COORDINATOR_URLS[0]:-}"
  local tk_item="${REGISTRY_TOKEN_KEYCHAIN_ITEMS[0]:-}"
  if [[ -z "$curl_url" ]]; then
    _notif_delivery_log "$mode: workspace[0] has no coordinator_url ⇒ skipping"
    return 0
  fi

  local lib_dir="${DAEMON_REPO_LIB_DIR:-${DAEMON_REPO_DIR:-}/lib}"
  if [[ ! -f "$lib_dir/co-http-transport.sh" ]]; then
    _notif_delivery_log "$mode: co-http-transport.sh not found at $lib_dir ⇒ skipping"
    return 0
  fi

  local out rc
  out="$(
    set +e
    export COORDINATOR_URL="$curl_url"
    if [[ -n "$tk_item" ]] && command -v security >/dev/null 2>&1; then
      _tk="$(security find-generic-password -s "$tk_item" -w 2>/dev/null || true)"
      [[ -n "$_tk" ]] && export COORDINATOR_TOKEN="$_tk"
    fi
    # shellcheck source=/dev/null
    . "$lib_dir/co-http-transport.sh" 2>/dev/null || exit 0
    command -v co_request >/dev/null 2>&1 || exit 0
    co_request "${COORDINATOR_TOKEN:-}" notif-deliver "$mode" 2>/dev/null
  )"
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    _notif_delivery_log "$mode: ${out:-ok}"
  else
    # rc 4 = a 5xx/transport LOUD failure (e.g. VAPID not configured ⇒ 503);
    # logged, retried next cadence (the ledger makes the retry safe).
    _notif_delivery_log "$mode: co_request rc=$rc ${out:+— }${out}"
  fi
  return 0
}

# Frequent blocking sweep — ONE immediate push per pending blocking notif.
daemon_notif_delivery_poll_once() {
  [[ "$DAEMON_NOTIF_DELIVERY_DISABLED" = "1" ]] && return 0
  _notif_deliver_call blocking
  return 0
}

# ~daily digest sweep — the K3 rollup as one push per channel group.
daemon_notif_digest_sweep_once() {
  [[ "$DAEMON_NOTIF_DELIVERY_DISABLED" = "1" ]] && return 0
  _notif_deliver_call digest
  return 0
}
