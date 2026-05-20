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
# M4: hosted-resolution poll cadence. ~30s default, the AD8 latency promise
# (Brian answers the dossier ⇒ ≤60s to the resume-answer file lands in the
# workspace store), well-bounded against a long `claude -p` in any workspace.
HOSTED_RESOLUTION_POLL_INTERVAL="${BEADS_DAEMON_HOSTED_RESOLUTION_POLL_INTERVAL:-30}"

# ─── source the per-machine library (DESIGN §3.2 retraction-of-topology
# is about TIER, not about the library — the daemon still source's it) ────
DAEMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DAEMON_DIR/workspace-registry.sh"
# M4: per-workspace hosted-resolution poll (claude-tools-8jb). Defines
# daemon_poll_workspace_hosted_resolution + the runner-state classifier the
# M5/M6 dispatch branches off. Strict no-op until the main loop calls into it.
# shellcheck disable=SC1091
. "$DAEMON_DIR/hosted-resolution-poll.sh"
# M6 (claude-tools-4iy): bd-surgery dispatch — launch a fresh `claude -p` in
# the workspace cwd when an answered dossier lands while the runner is busy
# on a DIFFERENT task. Sourced AFTER hosted-resolution-poll.sh so the busy-
# branch in daemon_dispatch_for_state finds daemon_m6_dispatch_busy at call
# time. Drain hook (daemon_m6_kill_all) wired into on_exit below.
# shellcheck disable=SC1091
. "$DAEMON_DIR/m6-dispatch.sh"

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
  # M6 (claude-tools-4iy): SIGTERM any in-flight bd-surgery agents the daemon
  # spawned. They are short-lived (a few minutes) and self-terminate, but the
  # daemon OWNS their lifecycle per the M6 spec — a daemon shutdown must not
  # leave orphan claude -p children running against a workspace.
  if declare -F daemon_m6_kill_all >/dev/null 2>&1; then
    daemon_m6_kill_all || true
  fi
  release_pidfile
}

# ─── M4 hosted-resolution poll driver (claude-tools-8jb) ─────────────────
# Iterate REGISTRY_<arrays> and call the per-workspace poll for each. The
# poll itself is in hosted-resolution-poll.sh (`daemon_poll_workspace_hosted_
# resolution`); this driver is what binds it to the daemon's main loop and
# turns a per-workspace observed-count into a single observable-not-silent
# log line ("daemon observed N answered fork(s) across M workspace(s)") —
# the §7.3/AD8 surface the operator looks at.
run_hosted_resolution_poll() {
  local count workspaces total=0
  workspaces="$(registry_count 2>/dev/null || echo 0)"
  [ "$workspaces" -gt 0 ] 2>/dev/null || return 0
  local i=0
  while [ "$i" -lt "$workspaces" ]; do
    count="$(daemon_poll_workspace_hosted_resolution "$i" 2>/dev/null || echo 0)"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    total=$((total + count))
    i=$((i + 1))
  done
  if [ "$total" -gt 0 ]; then
    log "hosted-resolution poll (§7.3/AD8/M4): observed $total answered fork(s) across $workspaces workspace(s) — answer file(s) captured into the workspace store(s); resume dispatch decision logged per task_ref above"
  fi
  return 0
}

# ─── main ────────────────────────────────────────────────────────────────
main() {
  trap on_exit EXIT
  trap handle_sigterm TERM
  trap handle_sigint  INT
  trap handle_sighup  HUP

  acquire_pidfile
  write_rotation_marker

  log "daemon starting; HEARTBEAT_INTERVAL=${HEARTBEAT_INTERVAL}s HOSTED_RESOLUTION_POLL_INTERVAL=${HOSTED_RESOLUTION_POLL_INTERVAL}s"
  log "pidfile=$DAEMON_PIDFILE"
  log "log_dir=$DAEMON_LOG_DIR"
  log "workspaces_json=$WORKSPACES_JSON"

  if registry_load "$WORKSPACES_JSON"; then
    log "workspace registry loaded ($(registry_count) workspaces)"
  else
    log "WARN: no workspace registry yet at $WORKSPACES_JSON (continuing — M1/M4 have nothing to poll until a registry exists)"
  fi

  # Main loop. Heartbeat every HEARTBEAT_INTERVAL; the M4 hosted-resolution
  # poll runs every HOSTED_RESOLUTION_POLL_INTERVAL (per-workspace, AD8 §3.2
  # job 5). Other M2/M3/M5/M6 jobs land here in their own issues.
  local _last_hosted_poll=0
  while [ "$DRAIN_REQUESTED" -eq 0 ]; do
    log "heartbeat"
    # M4 (claude-tools-8jb): on cadence, poll every registered workspace for
    # answered dossiers and capture the resume-answer into the workspace's
    # local store. This is the "always listening" piece — the old
    # runner-side sr_poll_hosted_resolution call only fired BETWEEN tasks,
    # so a long claude -p stalled observation. The daemon polls regardless.
    local _now
    _now="$(date +%s 2>/dev/null || echo 0)"
    if [ "$((_now - _last_hosted_poll))" -ge "$HOSTED_RESOLUTION_POLL_INTERVAL" ]; then
      _last_hosted_poll="$_now"
      run_hosted_resolution_poll || true
    fi
    # `sleep` is interruptible by signals; the loop condition is re-checked
    # immediately after wake.
    sleep "$HEARTBEAT_INTERVAL" &
    wait $! 2>/dev/null || true
  done

  log "drain complete; exiting 0"
  exit 0
}

main "$@"
