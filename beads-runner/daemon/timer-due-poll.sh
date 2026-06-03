#!/bin/bash
# beads-runner/daemon/timer-due-poll.sh — N10-11 (claude-tools-buoz).
#
# DESIGN N §2.2 / §4.3 + INTERFACE §2.2 / S-6 — the §2.2 timer's DAEMON CLOCK.
# The hosted engine has the timer-due logic (cf/src/timer.js, deployed
# 2026-05-31 version 1cd1e294): `timed-fyi-poll` IS the S-6 poll-fallback DRIVER
# (timer.js `fireDueTimers`) — it asks the §2.2 substrate for every armed,
# un-acked timer whose fire_at ≤ now and, ROUTING BY the dossier's §4.1 `kind`,
# runs the right fire-action for each:
#   • kind != "pair"  → the SHARED auto-proceed handler (`fireDossier`): every
#     un-objected fyi-objectable Item's §5.3 consequence is applied via CF.6's
#     §7.4 per-Item latch (timed-fyi S-6 fire-on-next-poll). This is the
#     deterministic backstop for the best-effort `ctx.storage.setAlarm()` —
#     a missed/suppressed alarm degrades to fire-on-THIS-poll.
#   • kind == "pair"  → the SURFACE fire-action (`pairSurface`): promote the
#     scheduled ready-to-pair session from upcoming→ready and fire the blocking
#     `ready_to_pair` notification (N2's notif-delivery sweep pushes it). The
#     OPPOSITE of auto-proceed — nothing is consequence-applied; the point is to
#     get Brian INTO the session (§4.3).
#
# WHAT WAS MISSING (audit wzejgmopj — the GAP this closes): the engine half was
# live but NO daemon job rang it in production, so the §2.2 timer never fired
# for timed-fyi (S-6) and the ready-to-pair surface never appeared live. This
# file is the missing clock — exactly as N2's notif-delivery-poll.sh is the
# delivery clock that rings `notif-deliver`. There is no alarm daemon; this poll
# IS the S-6 backstop. (cf/src/timer.js: "there is no alarm daemon".)
#
# WHY RING THE COMPOSITE `timed-fyi-poll` OP (not the bare `timer-due`): the
# substrate `timer-due` op only LISTS due timer ids; it does not fire. The
# fire-action + kind-routing live in the engine (`fireDueTimers`), the ONE
# source of truth (the bash `tf_poll` in lib/timed-fyi.sh is its differential
# ORACLE twin, NOT a second daemon impl). One engine round-trip drives BOTH
# fire-actions server-side. No `now` arg is passed — opTimerDue defaults to the
# engine's own clock (coordinator.js: `now || new Date()…`), so the engine owns
# the comparison instant and there is no Mac↔engine clock-skew window.
#
# Engine reach mirrors N2 / the 1p0u outbox drain: resolve workspace[0]'s
# coordinator_url + Keychain bearer, export COORDINATOR_URL/COORDINATOR_TOKEN,
# source co-http-transport.sh, call co_request. The Coordinator is a SINGLETON
# (idFromName("coordinator")) and the §2.2 `timers` namespace lives in that one
# DO's D1 — so ONE call reaches the one DO that owns every workspace's timers.
# This is NOT per-workspace.
#
# Always returns 0. A failure (auth, transport, a per-dossier WARN) is logged
# and left for the next cadence; it must never abort the daemon loop. The §7.4
# per-Item latch (auto-proceed) and notif-fire's one-per-dossier emit + N2's
# deliver-once ledger (pair-surface) make a re-run idempotent, so a repeated
# poll — including the boot-fire that catches a fire window missed while the
# daemon was down — is safe.

# Resolved at source-time; daemon.sh sets these before sourcing (defaults let
# this file be unit-tested standalone).
DAEMON_REPO_DIR="${DAEMON_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}"
DAEMON_REPO_LIB_DIR="${DAEMON_REPO_LIB_DIR:-$DAEMON_REPO_DIR/lib}"

# Test/canary hook: disable the poll entirely (a kill switch parallel to
# DAEMON_NOTIF_DELIVERY_DISABLED). Off by default — unlike the canary-disabled
# blueprint-update path, the §2.2 timer clock is meant to be LIVE in production
# (that IS the gap claude-tools-buoz closes); the switch exists only for tests
# and a fast operator kill.
DAEMON_TIMER_DUE_DISABLED="${DAEMON_TIMER_DUE_DISABLED:-0}"

_timer_due_log() {
  if declare -F log >/dev/null 2>&1; then
    log "[timer-due] $*"
  else
    printf '%s [timer-due] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$*" >&2
  fi
}

# daemon_timer_due_poll_once — resolve the engine + bearer (workspace[0],
# N2 / 1p0u-drain pattern), source the HTTP transport, and ring the engine's
# `timed-fyi-poll` driver op. The engine does the timer-due query + kind-routing
# + fire server-side; the daemon only RINGS it on a cadence. Logs the engine's
# one-line summary ({ok,fired,warned}). Returns 0 always.
daemon_timer_due_poll_once() {
  [[ "$DAEMON_TIMER_DUE_DISABLED" = "1" ]] && return 0

  local ws_count=0
  if declare -p REGISTRY_PROJECT_REFS >/dev/null 2>&1; then
    ws_count="${#REGISTRY_PROJECT_REFS[@]}"
  fi
  if [[ "$ws_count" -eq 0 ]]; then
    _timer_due_log "no workspaces registered ⇒ skipping (no engine to reach)"
    return 0
  fi

  local curl_url="${REGISTRY_COORDINATOR_URLS[0]:-}"
  local tk_item="${REGISTRY_TOKEN_KEYCHAIN_ITEMS[0]:-}"
  if [[ -z "$curl_url" ]]; then
    _timer_due_log "workspace[0] has no coordinator_url ⇒ skipping"
    return 0
  fi

  local lib_dir="${DAEMON_REPO_LIB_DIR:-${DAEMON_REPO_DIR:-}/lib}"
  if [[ ! -f "$lib_dir/co-http-transport.sh" ]]; then
    _timer_due_log "co-http-transport.sh not found at $lib_dir ⇒ skipping"
    return 0
  fi

  # Ring the composite firing driver with NO `now` arg — the engine's
  # opTimerDue defaults to its own clock, so the engine owns the comparison
  # instant (no Mac vs engine skew window). (This comment stays OUTSIDE the
  # command substitution below: bash mis-parses an apostrophe/backtick in a
  # comment INSIDE $(...) — keep the subshell body comment-clean.)
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
    co_request "${COORDINATOR_TOKEN:-}" timed-fyi-poll 2>/dev/null
  )"
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    _timer_due_log "${out:-ok}"
  else
    # rc 4 = a 5xx/transport LOUD failure; logged, retried next cadence (the
    # §7.4 latch + notif deliver-once ledger make the retry safe).
    _timer_due_log "co_request rc=$rc ${out:+— }${out}"
  fi
  return 0
}
