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
# M3: per-workspace desired-state poll cadence. 60s default — matches the
# in-runner S-5 cadence (runner.sh's CONTROL_POLL_INTERVAL) so the daemon
# observes desired-state mutations at the same rate the runner used to
# self-reconcile, and the AD8/Flow-D loop closes within ~60s end-to-end.
DESIRED_STATE_POLL_INTERVAL="${BEADS_DAEMON_DESIRED_STATE_POLL_INTERVAL:-60}"
# I3: intake-request poll cadence. ~30s default per the task spec, so an
# intake tap on the phone lands ⇒ enricher fires ⇒ a new bd task appears
# the runner can pick up within ~60s end-to-end (cf claude-tools-06i
# acceptance).
INTAKE_POLL_INTERVAL="${BEADS_DAEMON_INTAKE_POLL_INTERVAL:-30}"
# P1: Flow F stage-change observer poll cadence (claude-tools-3pq). 60s
# default — the trigger (a bd task with stage:design closing) is a low-rate
# event; the dossier-builder dispatch is synchronous + can be slow, so a
# tight cadence buys nothing. Matches the M3 desired-state cadence so the
# daemon's per-workspace bd reads cluster at the same beat.
FLOW_F_POLL_INTERVAL="${BEADS_DAEMON_FLOW_F_POLL_INTERVAL:-60}"
# L2 (claude-tools-uxvl2): WORK→CONTROL auto-close reconcile cadence. On this
# beat the daemon asks the engine which blocking dossiers are still on the Inbox
# and auto-closes any whose bead has resolved outside the dossier tap. Matches
# the Flow F / M3 cadence so the per-workspace bd reads cluster at the same beat
# (the trigger — a bd close/unblock — is a low-rate event; ~30s lag is fine).
WORK_CONTROL_POLL_INTERVAL="${BEADS_DAEMON_WORK_CONTROL_POLL_INTERVAL:-60}"
# M2: Anthropic-usage poll cadence (claude-tools-8mz). Default tracks
# §0.5 USAGE_CACHE_SECONDS so the daemon's cache refresh rate matches the
# constant the runner-side cache used to honour. One central poll per
# machine; workspaces consult $DAEMON_CACHE_DIR/capacity.json via
# la__capacity_via_daemon (lib/local-agent.sh) instead of hitting the
# Keychain+API themselves.
USAGE_POLL_INTERVAL="${BEADS_DAEMON_USAGE_POLL_INTERVAL:-${USAGE_CACHE_SECONDS:-300}}"
# N2 (claude-tools-uxg1): notification DELIVERY cadences (DESIGN N §2.3). The
# blocking sweep is frequent (~30s) so a real decision pings the phone near-
# immediately (latency ≤ this interval). The digest sweep is ~daily (ARCH §9
# "assumed daily"; the cadence is [free]) — it folds the K3 timed-fyi/digest
# rollup into ONE push per channel group (must-protect #5). The actual push +
# the deliver-once ledger live in the engine (notif-deliver); these only ring it.
NOTIF_DELIVERY_POLL_INTERVAL="${BEADS_DAEMON_NOTIF_DELIVERY_POLL_INTERVAL:-30}"
NOTIF_DIGEST_SWEEP_INTERVAL="${BEADS_DAEMON_NOTIF_DIGEST_SWEEP_INTERVAL:-86400}"

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
# M3 (claude-tools-cgh): per-workspace desired-state poll + spawn/SIGTERM
# state machine. Defines daemon_m3_reconcile_all + daemon_m3_* helpers.
# shellcheck disable=SC1091
. "$DAEMON_DIR/desired-state-poll.sh"
# I3 (claude-tools-06i): intake-request poll + enricher dispatch. Defines
# daemon_intake_poll_once + daemon_intake_* helpers. Same sourcing posture
# as the M3 poll above — strict no-op until the main loop calls into it.
# shellcheck disable=SC1091
. "$DAEMON_DIR/intake-dispatch-poll.sh"
# P1 (claude-tools-3pq): Flow F stage-change observer — when a bd task with
# stage:design closes, dispatch a dossier-builder (B-track) and push the
# result as a timed-fyi (24h auto-proceed) overview dossier. Defines
# daemon_flow_f_poll_once + daemon_flow_f_* helpers. Strict no-op until the
# main loop calls into it.
# shellcheck disable=SC1091
. "$DAEMON_DIR/flow-f-overview-poll.sh"
# L2 (claude-tools-uxvl2): WORK→CONTROL auto-close reconciler — when a bead
# behind a BLOCKING dossier resolves outside the dossier tap (bd close /
# self-unblock / human-label drop), publish a bead_status_changed event over the
# zdxd D2 outbox so the engine expires/applies-preserving the stale Inbox card
# (inbox-lifecycle §7 Option 2). Defines daemon_wc_reconcile_once +
# daemon_wc_* helpers. Strict no-op until the main loop calls into it.
# shellcheck disable=SC1091
. "$DAEMON_DIR/work-control-reconcile-poll.sh"
# M2 (claude-tools-8mz): the Anthropic-usage poll — one Keychain read +
# one API call per machine per USAGE_POLL_INTERVAL, with the verdict
# published atomically to $DAEMON_CACHE_DIR/capacity.json (UX 0.A "one
# central runner per computer"). Defines daemon_usage_poll_once +
# daemon_usage_drain.
# shellcheck disable=SC1091
. "$DAEMON_DIR/usage-poll.sh"
# I5-cap (claude-tools-pof7): the aux-pool capacity gate — the budget guard the
# parallel auxiliary dispatch (I5/uxvi5) consults before each read-only aux spawn
# so the pool can't blow the 5h/7d budget. Reads the capacity.json the usage-poll
# above publishes; gates on the cheaper `low_priority` cost-class (suppressed
# before the writer's `standard`). Defines daemon_aux_capacity_ok +
# daemon_aux_dispatch_guard. Strict no-op until a caller (I5) invokes it.
# shellcheck disable=SC1091
. "$DAEMON_DIR/aux-dispatch-gate.sh"
# N2 (claude-tools-uxg1): the notification DELIVERY clock — on cadence, ring the
# engine's notif-deliver op (blocking sweep frequently, digest sweep ~daily) so
# a dispatched §4.3 Notification becomes a real Web Push on Brian's installed
# Inbox PWA. Defines daemon_notif_delivery_poll_once + daemon_notif_digest_sweep_once.
# Strict no-op until the main loop calls into it (and when no workspace is
# registered / no subscription exists).
# shellcheck disable=SC1091
. "$DAEMON_DIR/notif-delivery-poll.sh"

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
    # M3 (claude-tools-cgh): drop the per-workspace last-observed-desired
    # memory on a registry reload so a removed workspace doesn't keep a
    # phantom slot and an added workspace's first observation logs as
    # "<unset> → <desired>" (the real transition into observed-state).
    daemon_m3_reset_state_memory 2>/dev/null || true
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
  # M2 (claude-tools-8mz): clear the capacity cache so a workspace that
  # checks $DAEMON_CACHE_DIR/capacity.json during the daemon-down window
  # falls back to its own direct Keychain+API path (BC-34 fail-OPEN
  # preserved) instead of trusting a stale verdict from a previous run.
  if declare -F daemon_usage_drain >/dev/null 2>&1; then
    daemon_usage_drain || true
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

  log "daemon starting; HEARTBEAT_INTERVAL=${HEARTBEAT_INTERVAL}s HOSTED_RESOLUTION_POLL_INTERVAL=${HOSTED_RESOLUTION_POLL_INTERVAL}s DESIRED_STATE_POLL_INTERVAL=${DESIRED_STATE_POLL_INTERVAL}s INTAKE_POLL_INTERVAL=${INTAKE_POLL_INTERVAL}s FLOW_F_POLL_INTERVAL=${FLOW_F_POLL_INTERVAL}s WORK_CONTROL_POLL_INTERVAL=${WORK_CONTROL_POLL_INTERVAL}s USAGE_POLL_INTERVAL=${USAGE_POLL_INTERVAL}s NOTIF_DELIVERY_POLL_INTERVAL=${NOTIF_DELIVERY_POLL_INTERVAL}s NOTIF_DIGEST_SWEEP_INTERVAL=${NOTIF_DIGEST_SWEEP_INTERVAL}s"
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
  # job 5); the M3 desired-state poll runs every DESIRED_STATE_POLL_INTERVAL
  # (per-workspace spawn/SIGTERM state machine, §3.2 job 2+3); the M2 usage
  # poll runs every USAGE_POLL_INTERVAL (one Keychain read + one Anthropic
  # API call per machine, §3.2 job 1).
  local _last_hosted_poll=0
  local _last_desired_poll=0
  local _last_intake_poll=0
  local _last_flow_f_poll=0
  local _last_wc_poll=0
  local _last_usage_poll=0
  local _last_notif_delivery_poll=0
  local _last_notif_digest_sweep=0
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
    # M3 (claude-tools-cgh): on cadence, poll every registered workspace's
    # RunnerState.desired and drive the per-workspace process state machine
    # (spawn via launch-detached.sh / SIGTERM the existing runner / no-op).
    # On daemon-startup the FIRST iteration runs at boot (when both
    # _last_desired_poll and _now are within INTERVAL of each other) — this
    # is intentional: the daemon must immediately reconcile any pidfile it
    # adopted against current desired-state (an orphan stopped-workspace
    # runner from a prior boot must be SIGTERMed at boot, not 60s later).
    if [ "$((_now - _last_desired_poll))" -ge "$DESIRED_STATE_POLL_INTERVAL" ] || [ "$_last_desired_poll" -eq 0 ]; then
      _last_desired_poll="$_now"
      daemon_m3_reconcile_all || true
    fi
    # I3 (claude-tools-06i): on cadence (~30s), scan the engine for unprocessed
    # intake-request records and dispatch the enricher hat in the chosen
    # workspace for each one whose project_ref is registered on this machine.
    # The acceptance contract is end-to-end ≤60s from phone tap → new bd task
    # the runner can pick up, so a 30s cadence keeps the worst-case under 60s
    # (poll discovery + the enricher's bd create both fit inside the budget).
    if [ "$((_now - _last_intake_poll))" -ge "$INTAKE_POLL_INTERVAL" ] || [ "$_last_intake_poll" -eq 0 ]; then
      _last_intake_poll="$_now"
      daemon_intake_poll_once || true
    fi
    # P1 (claude-tools-3pq): on cadence, walk every registered workspace for
    # closed beads carrying the watched stage label (default stage:design)
    # and dispatch a Flow F overview-dossier build for any not yet observed.
    # First-run backlog suppression: the seed flag at $DAEMON_FLOW_F_SEED_FLAG
    # marks the existing closed-at-stage backlog as already-fired WITHOUT
    # dispatching, so a fresh install does not dump historical closes onto
    # the phone in one shot.
    if [ "$((_now - _last_flow_f_poll))" -ge "$FLOW_F_POLL_INTERVAL" ] || [ "$_last_flow_f_poll" -eq 0 ]; then
      _last_flow_f_poll="$_now"
      daemon_flow_f_poll_once || true
    fi
    # L2 (claude-tools-uxvl2): on cadence, ask the engine which blocking dossiers
    # are still on the Inbox and auto-close any whose bead has resolved outside
    # the dossier tap — publish bead_status_changed onto the daemon outbox; the
    # 1p0u drain below ships it to the engine bead-status-changed op. The first
    # iteration runs at boot so a bead that closed while the daemon was down is
    # reconciled promptly. Strict no-op when nothing is stale.
    if [ "$((_now - _last_wc_poll))" -ge "$WORK_CONTROL_POLL_INTERVAL" ] || [ "$_last_wc_poll" -eq 0 ]; then
      _last_wc_poll="$_now"
      if declare -F daemon_wc_reconcile_once >/dev/null 2>&1; then
        daemon_wc_reconcile_once || true
      fi
    fi
    # M2 (claude-tools-8mz): on cadence, refresh the machine-level
    # Anthropic-usage cache so workspaces' la__capacity_via_daemon picks
    # up a fresh verdict. The first iteration runs at boot (when both
    # _last_usage_poll and _now are within INTERVAL) — intentional: the
    # cache is empty at startup, and workspaces would otherwise fall back
    # to their direct Keychain+API path for the first INTERVAL seconds,
    # defeating the purpose of M2.
    if [ "$((_now - _last_usage_poll))" -ge "$USAGE_POLL_INTERVAL" ] || [ "$_last_usage_poll" -eq 0 ]; then
      _last_usage_poll="$_now"
      daemon_usage_poll_once || true
    fi
    # N2 (claude-tools-uxg1): the BLOCKING delivery sweep — on cadence (~30s, and
    # at boot so a decision that fired while the daemon was down pings promptly),
    # ring notif-deliver blocking so each pending blocking §4.3 Notification
    # becomes ONE immediate Web Push on the installed Inbox PWA. Strict no-op
    # when there are no pending blocking notifs / no subscriptions; the engine
    # ledger makes a repeated sweep idempotent.
    if [ "$((_now - _last_notif_delivery_poll))" -ge "$NOTIF_DELIVERY_POLL_INTERVAL" ] || [ "$_last_notif_delivery_poll" -eq 0 ]; then
      _last_notif_delivery_poll="$_now"
      if declare -F daemon_notif_delivery_poll_once >/dev/null 2>&1; then
        daemon_notif_delivery_poll_once || true
      fi
    fi
    # N2 (claude-tools-uxg1): the DIGEST sweep — on the ~daily cadence (NOT at
    # boot, to avoid dumping an accumulated backlog), ring notif-deliver digest
    # so the K3 timed-fyi/digest rollup delivers as ONE push per channel group
    # (N pending → 1, never N — must-protect #5).
    if [ "$_last_notif_digest_sweep" -eq 0 ]; then
      # Seed on the first iteration so the first digest fires ONE interval after
      # boot — never at boot (a boot fire would dump the accumulated backlog).
      _last_notif_digest_sweep="$_now"
    elif [ "$((_now - _last_notif_digest_sweep))" -ge "$NOTIF_DIGEST_SWEEP_INTERVAL" ]; then
      _last_notif_digest_sweep="$_now"
      if declare -F daemon_notif_digest_sweep_once >/dev/null 2>&1; then
        daemon_notif_digest_sweep_once || true
      fi
    fi
    # claude-tools-1p0u: drain the daemon's OWN §1.1 outbox to the deployed
    # Coordinator. The usage-poll above appends capacity + machine_state lines
    # to USAGE_POLL_OUTBOX every USAGE_POLL_INTERVAL; nothing else drained them
    # (run-beads-tasks.sh drains only the workspace outbox), so the daemon
    # outbox grew without bound and the Worker's /work-snapshot machines[]
    # stayed empty. Runs every heartbeat: cheap no-op when the outbox is empty
    # (common path), ships any just-appended line within ~HEARTBEAT_INTERVAL.
    if declare -F daemon_outbox_drain_once >/dev/null 2>&1; then
      daemon_outbox_drain_once || true
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
