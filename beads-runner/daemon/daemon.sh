#!/bin/bash
# beads-runner/daemon/daemon.sh — per-machine Local Agent daemon (M1 skeleton,
# claude-tools-gim; epic claude-tools-kie).
#
# WHAT THIS IS
#   The per-machine supervisor process referenced by DESIGN §3.2 (AD1 §11
#   amend 2026-05-20). One long-lived process per computer; distinct from
#   every workspace runner (pid_daemon ≠ pid_any_workspace_runner). Launched
#   by launchd as a LaunchAgent on macOS (see launchd-plist.template) — it
#   runs in Brian's GUI login session, not as root, and is restarted on crash
#   by launchd's KeepAlive.
#
# WHAT THIS IS *NOT* — YET (M1 contract)
#   This file is the SKELETON: pidfile + signal handlers + heartbeat-only
#   main loop. The five jobs the daemon will own (DESIGN §3.2 / §7):
#     1. real Anthropic usage poll (one per machine)            — M2
#     2. workspace-registry-driven desired-state poll + spawn   — M3
#     3. heartbeat-actual-state(+liveness)                      — M3
#     4. hosted-resolution poll / resume dispatch / bd-surgery  — M4
#     5. publish-work-snapshot forwarding                       — M5
#   are intentionally NOT implemented here. The acceptance criteria for M1
#   are entirely about the process being a real, well-behaved daemon:
#   installs, runs, logs, single-instances, drains on SIGTERM.

set -uo pipefail

# ─── paths ────────────────────────────────────────────────────────────────
# Per task spec: pidfile + logs under ~/.cache/claude-tools/, workspace
# registry under ~/.config/claude-tools/. (DESIGN.md §3.2 names
# ~/.beads-runner/daemon.pid in narrative form; the M-track owns the
# concrete path choice and lands here in ~/.cache/claude-tools/ to follow
# the XDG-ish split between caches and configs on macOS.)
DAEMON_CACHE_DIR="${BEADS_DAEMON_CACHE_DIR:-$HOME/.cache/claude-tools}"
DAEMON_CONFIG_DIR="${BEADS_DAEMON_CONFIG_DIR:-$HOME/.config/claude-tools}"
DAEMON_LOG_DIR="$DAEMON_CACHE_DIR/daemon-logs"
DAEMON_PIDFILE="$DAEMON_CACHE_DIR/daemon.pid"
DAEMON_ROTATION_MARKER="$DAEMON_LOG_DIR/.rotation-marker"
WORKSPACES_JSON="$DAEMON_CONFIG_DIR/workspaces.json"

HEARTBEAT_INTERVAL="${BEADS_DAEMON_HEARTBEAT_INTERVAL:-10}"

# ─── source the per-machine library (DESIGN §3.2 retraction-of-topology
# is about TIER, not about the library — the daemon still source's it) ────
DAEMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DAEMON_DIR/workspace-registry.sh"

log() {
  # one-line log helper; stdout is redirected to daemon-logs/stdout.log by
  # launchd (see plist), so just emit a timestamped line.
  printf '%s [daemon pid=%d] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$*"
}

# ─── single-instance pidfile ──────────────────────────────────────────────
acquire_pidfile() {
  mkdir -p "$DAEMON_CACHE_DIR" "$DAEMON_LOG_DIR" "$DAEMON_CONFIG_DIR"
  if [ -f "$DAEMON_PIDFILE" ]; then
    local existing
    existing="$(cat "$DAEMON_PIDFILE" 2>/dev/null || true)"
    if [ -n "$existing" ] && kill -0 "$existing" 2>/dev/null; then
      log "FATAL: another daemon is already running (pid=$existing); refusing to double-start"
      exit 1
    fi
    log "stale pidfile found (pid=$existing not alive); reclaiming"
    rm -f "$DAEMON_PIDFILE"
  fi
  echo $$ > "$DAEMON_PIDFILE"
  log "pidfile written: $DAEMON_PIDFILE (pid=$$)"
}

release_pidfile() {
  # only release a pidfile we own — guards against a racing newer daemon
  # whose pid happens to land in this file.
  if [ -f "$DAEMON_PIDFILE" ]; then
    local current
    current="$(cat "$DAEMON_PIDFILE" 2>/dev/null || true)"
    if [ "$current" = "$$" ]; then
      rm -f "$DAEMON_PIDFILE"
      log "pidfile released"
    fi
  fi
}

# ─── log-rotation marker (M1: marker only; rotation policy lives in M5) ──
write_rotation_marker() {
  printf 'daemon-start %s pid=%d\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" \
    >> "$DAEMON_ROTATION_MARKER"
}

# ─── signal handling ─────────────────────────────────────────────────────
# SIGTERM = graceful drain. M1 has no in-flight work to drain, but the hook
# is wired so M2-M6 can attach drain logic (kill child workspace runners,
# flush usage caches, etc.) without reshaping the lifecycle.
DRAIN_REQUESTED=0
handle_sigterm() {
  log "SIGTERM received; entering graceful drain"
  DRAIN_REQUESTED=1
}
handle_sigint() {
  log "SIGINT received; entering graceful drain"
  DRAIN_REQUESTED=1
}
handle_sighup() {
  # SIGHUP is the reload signal in M3+ (re-read workspaces.json). M1 just
  # logs and re-loads the registry as a smoke test.
  log "SIGHUP received; reloading workspace registry"
  if registry_load "$WORKSPACES_JSON"; then
    log "workspace registry reload ok ($(registry_count) workspaces)"
  else
    log "WARN: workspace registry reload failed; keeping previous state"
  fi
}

on_exit() {
  log "daemon exiting"
  release_pidfile
}

# ─── main ────────────────────────────────────────────────────────────────
main() {
  trap on_exit EXIT
  trap handle_sigterm TERM
  trap handle_sigint  INT
  trap handle_sighup  HUP

  acquire_pidfile
  write_rotation_marker

  log "daemon starting; HEARTBEAT_INTERVAL=${HEARTBEAT_INTERVAL}s"
  log "pidfile=$DAEMON_PIDFILE"
  log "log_dir=$DAEMON_LOG_DIR"
  log "workspaces_json=$WORKSPACES_JSON"

  if registry_load "$WORKSPACES_JSON"; then
    log "workspace registry loaded ($(registry_count) workspaces)"
  else
    log "WARN: no workspace registry yet at $WORKSPACES_JSON (continuing — M1 has no work to do anyway)"
  fi

  # Empty main loop with a 10s heartbeat. Job logic lands here in M2-M6.
  while [ "$DRAIN_REQUESTED" -eq 0 ]; do
    log "heartbeat"
    # `sleep` is interruptible by signals; the loop condition is re-checked
    # immediately after wake.
    sleep "$HEARTBEAT_INTERVAL" &
    wait $! 2>/dev/null || true
  done

  log "drain complete; exiting 0"
  exit 0
}

main "$@"
