# shellcheck shell=bash
# beads-runner/daemon/desired-state-poll.sh — M3 desired-state poll +
# workspace-runner lifecycle (claude-tools-cgh; epic claude-tools-kie).
#
# WHAT THIS IS (DESIGN §3.2 job 2 + 3 / AD1 §11)
#   The daemon-side per-workspace desired-state poll. For each workspace in
#   the registry, we hit the engine's `poll` op (§2.4 deliver-desired-state-
#   on-reconnect) on a 60s cadence — matching the runner's S-5 in-process
#   cadence — read `RunnerState.desired`, then drive the per-workspace
#   process state machine:
#
#     desired=running       + no runner alive  ⇒ spawn via launch-detached.sh
#     desired=running       + runner alive     ⇒ no-op (runner reports HB itself)
#     desired=paused        + runner alive     ⇒ no-op (runner's own
#                                                 job_reconcile_desired honors
#                                                 it: holds, no pickup)
#     desired=paused        + no runner        ⇒ no-op (no spawn while paused)
#     desired=spare-cycles  + no runner alive  ⇒ spawn (gating is C-track's job)
#     desired=spare-cycles  + runner alive     ⇒ no-op
#     desired=stopped       + runner alive     ⇒ SIGTERM (clean drain) — the
#                                                 runner's _on_signal handler
#                                                 reports actual=stopped on
#                                                 the way out, so the daemon
#                                                 does not write the heartbeat
#                                                 itself (single-writer rule).
#     desired=stopped       + no runner        ⇒ no-op (already converged)
#
# WHAT THIS IS *NOT*
#   • NOT the heartbeat writer. The runner owns its own §4.2 actual-state
#     heartbeat (la_report_heartbeat → coordinator-outbox.jsonl). The daemon
#     observes; it does not double-write.
#   • NOT the per-task lease arbiter. Lease acquire/renew/release stay in
#     the runner — the daemon only owns process lifecycle.
#   • NOT a worker. desired=spare-cycles is treated like running here; the
#     work-pickup gate on spare-only mode is wired in C2 (claude-tools-oil).
#
# PIDFILE HYGIENE (per task spec)
#   The daemon adopts the pidfile written by launch-detached.sh —
#   `<workspace>/.beads/runner-logs/detached-runner.pid`. On daemon restart
#   we re-discover live runners via that file and reconcile against the
#   current desired-state. We do NOT write the pidfile ourselves; we read
#   what launch-detached.sh wrote and key kill -0 / kill -TERM off it.
#
# ENGINE TRANSPORT
#   Each per-workspace poll runs in a SUBSHELL — same idiom as the M4
#   hosted-resolution poll. Inside the subshell we cd into the workspace,
#   set workspace-scoped env (PROJECT_REF, CO_STORE, COORDINATOR_URL,
#   COORDINATOR_TOKEN from Keychain via the registry's coordinator_token_
#   keychain item), source lib/coordinator.sh + lib/co-http-transport.sh
#   (the HTTP override wins when COORDINATOR_URL is set), and call
#   `co_request <bearer> poll <project_ref>` — the §2.4 transport. The
#   response is JSON: `{principal, desired, runner_state, lease}`; we
#   extract `.desired`. Subshell isolation guarantees env from workspace A
#   never leaks into workspace B's poll on the next iteration.
#
# DEPENDENCIES
#   `jq`, `curl`, `security` (Keychain) — same set the rest of beads-runner
#   carries.

# Resolve sibling paths at source time (matches hosted-resolution-poll.sh).
DAEMON_REPO_DIR="${DAEMON_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}"
DAEMON_REPO_LIB_DIR="${DAEMON_REPO_LIB_DIR:-$DAEMON_REPO_DIR/lib}"
DAEMON_LAUNCH_DETACHED="${DAEMON_LAUNCH_DETACHED:-$DAEMON_REPO_DIR/launch-detached.sh}"

# Per-workspace observed-desired memory — parallel to REGISTRY_<arrays>.
# Cleared on registry reload; only used to detect transitions for the
# "every state transition logged with workspace + old/new" requirement.
DAEMON_M3_LAST_DESIRED=()

# Test/canary hook: set DAEMON_M3_DISABLED=1 to log decisions but skip the
# actual spawn / SIGTERM. The acceptance test exercises this branch so it
# can verify call-site wiring without touching real processes.
DAEMON_M3_DISABLED="${DAEMON_M3_DISABLED:-0}"

# daemon_m3_reset_state_memory
#   Drop the per-workspace last-desired tracking. Called when the registry
#   is reloaded so a removed workspace doesn't keep a phantom slot.
daemon_m3_reset_state_memory() {
  DAEMON_M3_LAST_DESIRED=()
}

# daemon_m3_runner_pidfile <workspace_dir> → echo the pidfile path
#   The launch-detached.sh convention is the source of truth.
daemon_m3_runner_pidfile() {
  local ws="${1:-}"
  [[ -n "$ws" ]] || return 0
  printf '%s/.beads/runner-logs/detached-runner.pid' "$ws"
}

# daemon_m3_runner_pid <workspace_dir>
#   Echo a LIVE pid for the workspace's runner, or empty. Reclaims a stale
#   pidfile (pid present but not alive) — the same hygiene launch-
#   detached.sh applies, mirrored here so the daemon's view never lies.
daemon_m3_runner_pid() {
  local ws="${1:-}" pf pid
  [[ -n "$ws" ]] || return 0
  pf="$(daemon_m3_runner_pidfile "$ws")"
  [[ -f "$pf" ]] || { printf ''; return 0; }
  pid="$(cat "$pf" 2>/dev/null || echo "")"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    printf '%s' "$pid"
    return 0
  fi
  # Stale — reclaim. (launch-detached.sh also does this on next spawn; we
  # do it here so a `pidfile=stale + desired=running` observation doesn't
  # see a phantom-alive pid and skip the spawn.)
  if [[ -n "$pid" ]]; then
    rm -f "$pf" 2>/dev/null || true
  fi
  printf ''
  return 0
}

# daemon_m3_fetch_desired <workspace_idx> → echo desired state (or empty)
#   Run the §2.4 poll for the given workspace in a fresh subshell. The
#   subshell's stdout is the bare desired-state string; stderr is dropped.
#   An empty echo means: could not determine (coordinator unreachable,
#   token missing, etc.) — the caller defaults to NO ACTION on empty
#   (fail-safe: never SIGTERM a runner on a poll failure, never spawn one
#   on a poll failure either).
daemon_m3_fetch_desired() {
  local idx="${1:-}" ws pref curl tk_item
  [[ -n "$idx" ]] || return 0
  ws="${REGISTRY_DIRS[$idx]:-}"
  pref="${REGISTRY_PROJECT_REFS[$idx]:-}"
  curl="${REGISTRY_COORDINATOR_URLS[$idx]:-}"
  tk_item="${REGISTRY_TOKEN_KEYCHAIN_ITEMS[$idx]:-}"
  [[ -n "$ws" && -n "$pref" ]] || return 0
  _daemon_m3_fetch_desired_one "$ws" "$pref" "$curl" "$tk_item"
}

# _daemon_m3_fetch_desired_one <ws> <project_ref> <coord_url> <tk_item>
#   Internal helper: subshell that hits the engine's poll op. ALWAYS exits
#   0 to its parent (we want to echo "" on failure, not propagate). The
#   bearer is resolved from the Keychain item when provided; otherwise we
#   fall back to a placeholder (the HTTP transport ignores the passed
#   bearer when it can resolve a per-workspace token, but a no-token call
#   must still produce a clean rc 1 — the §9.1 401 path — rather than a
#   missing-arg curl invocation).
_daemon_m3_fetch_desired_one() {
  local ws="$1" pref="$2" curl="$3" tk_item="$4"
  (
    set +e
    cd "$ws" 2>/dev/null || exit 0
    export PROJECT_REF="$pref"
    : "${CO_STORE:=$ws/.beads/runner-logs/.co-store}"
    export CO_STORE
    if [[ -n "$curl" ]]; then export COORDINATOR_URL="$curl"; fi
    if [[ -n "$tk_item" ]] && command -v security >/dev/null 2>&1; then
      local _tk
      _tk="$(security find-generic-password -s "$tk_item" -w 2>/dev/null || true)"
      [[ -n "$_tk" ]] && export COORDINATOR_TOKEN="$_tk"
    fi
    # In-process coordinator (defines co_request poll → co__poll). The HTTP
    # transport (sourced last) OVERRIDES co_request when COORDINATOR_URL is
    # set, identical to run-beads-tasks.sh's source order.
    # shellcheck source=/dev/null
    . "$DAEMON_REPO_LIB_DIR/coordinator.sh" 2>/dev/null || exit 0
    # shellcheck source=/dev/null
    [[ -f "$DAEMON_REPO_LIB_DIR/co-http-transport.sh" ]] \
      && . "$DAEMON_REPO_LIB_DIR/co-http-transport.sh" 2>/dev/null
    command -v co_request >/dev/null 2>&1 || exit 0
    local bearer resp desired
    bearer="${COORDINATOR_TOKEN:-bearer-daemon-m3}"
    # `poll` is a DATA op (D2): 2xx body passes through verbatim as the
    # {desired,…} JSON envelope; 401/404/422 ⇒ rc≠0 + empty stdout.
    resp="$(co_request "$bearer" poll "$pref" 2>/dev/null)" || resp=""
    [[ -n "$resp" ]] || exit 0
    desired="$(printf '%s' "$resp" | jq -r 'if type=="object" then (.desired // "") else "" end' 2>/dev/null)" || desired=""
    # Defensive: accept ONLY the §4.2 enum values. Anything else (incl. the
    # stub default that may echo a bare string) gets coerced to empty so
    # the daemon falls into NO-ACTION rather than acting on garbage.
    case "$desired" in
      running|paused|spare-cycles|stopped) printf '%s' "$desired" ;;
      *) printf '' ;;
    esac
  )
}

# ── v2 staged cutover (claude-tools-v2c4) ──────────────────────────────────
# A per-workspace, MACHINE-LOCAL opt-in flips that workspace's runner from v1
# (run-beads-tasks.sh, the launch-detached default) to the v2 state-machine
# runner (runner.sh). The marker lives under the gitignored runner-logs/ dir,
# so the choice is a property of THIS machine and is never committed to the
# project (a clone on another machine stays on v1 until its own operator opts
# in). Instant rollback = remove the marker; the next respawn is v1 again.
#
# daemon_m3_v2_marker <workspace_dir> → echo the marker path
daemon_m3_v2_marker() {
  local ws="${1:-}"
  [[ -n "$ws" ]] || return 0
  printf '%s/.beads/runner-logs/use-runner-v2' "$ws"
}

# daemon_m3_uses_v2 <workspace_dir>
#   rc 0 iff this workspace is flipped to v2 AND the v2 runner script is
#   actually present. A missing runner.sh must NEVER strand a workspace, so we
#   fall back to v1 (BC-43 guarded-optional posture) rather than spawn nothing.
daemon_m3_uses_v2() {
  local ws="${1:-}" marker
  [[ -n "$ws" ]] || return 1
  marker="$(daemon_m3_v2_marker "$ws")"
  [[ -f "$marker" ]] || return 1
  [[ -f "$DAEMON_REPO_DIR/runner.sh" ]] || return 1
  return 0
}

# daemon_m3_spawn <workspace_dir>
#   Spawn a runner via launch-detached.sh. Returns 0 on launch (regardless
#   of whether confirm-pid races us); 1 on a precondition failure. Honors
#   DAEMON_M3_DISABLED=1 by logging the would-be spawn and returning 0.
daemon_m3_spawn() {
  local ws="${1:-}"
  if [[ -z "$ws" || ! -d "$ws" ]]; then
    declare -F log >/dev/null 2>&1 && log "M3 spawn: refuse — workspace missing '$ws'"
    return 1
  fi
  if [[ ! -x "$DAEMON_LAUNCH_DETACHED" ]]; then
    declare -F log >/dev/null 2>&1 && \
      log "M3 spawn: refuse — launch-detached.sh missing at $DAEMON_LAUNCH_DETACHED"
    return 1
  fi
  # Resolve which runner this workspace gets (v1 default / v2 opt-in marker).
  # CRITICAL SAFETY (claude-tools-v2c4 bead notes): a v2 runner MUST run with
  # RUNNER_BACKEND=real. Under the default stub backend la_capacity_check is a
  # hardcoded no-op, so a v2 runner wired to the hosted engine would have NO
  # 5h/7d usage ceiling and could burn Anthropic quota unguarded. v1 ignores
  # RUNNER_BACKEND (it always sources the real capacity lib), so pinning it on
  # the v2 path is correct and load-bearing.
  local runner_label="v1 (run-beads-tasks.sh)"
  local use_v2=0
  if daemon_m3_uses_v2 "$ws"; then
    use_v2=1
    runner_label="v2 (runner.sh, RUNNER_BACKEND=real) [use-runner-v2 marker]"
  fi
  if [[ "$DAEMON_M3_DISABLED" == "1" ]]; then
    declare -F log >/dev/null 2>&1 && \
      log "M3 spawn: DAEMON_M3_DISABLED=1 ⇒ would launch $runner_label via $DAEMON_LAUNCH_DETACHED for workspace=$ws"
    return 0
  fi
  declare -F log >/dev/null 2>&1 && \
    log "M3 spawn: workspace=$ws ⇒ launching $runner_label via $DAEMON_LAUNCH_DETACHED"
  # The launcher itself detaches; we don't hold onto the child. The workspace's
  # .beads/runner.sh supplies COORDINATOR_URL/PROJECT_REF/permissions — we don't
  # override those here. For the v2 opt-in we add the RUNNER_CMD selection plus
  # the mandatory RUNNER_BACKEND=real, scoped to this one launch via a subshell
  # export so v1 spawns stay byte-for-byte identical to before.
  if [[ "$use_v2" == "1" ]]; then
    ( export RUNNER_CMD="$DAEMON_REPO_DIR/runner.sh" RUNNER_BACKEND=real
      "$DAEMON_LAUNCH_DETACHED" "$ws" >/dev/null 2>&1 )
  else
    "$DAEMON_LAUNCH_DETACHED" "$ws" >/dev/null 2>&1
  fi
  return 0
}

# daemon_m3_stop <workspace_dir> <pid>
#   SIGTERM the runner. The runner's _on_signal handler drains cleanly and
#   writes its own `actual=stopped` heartbeat on the way out (single-writer
#   rule — the daemon does NOT also write a heartbeat). Returns 0 if the
#   signal was delivered, 1 if the pid had already exited.
daemon_m3_stop() {
  local ws="${1:-}" pid="${2:-}"
  if [[ -z "$pid" ]]; then
    declare -F log >/dev/null 2>&1 && log "M3 stop: refuse — no pid given for workspace=$ws"
    return 1
  fi
  if [[ "$DAEMON_M3_DISABLED" == "1" ]]; then
    declare -F log >/dev/null 2>&1 && \
      log "M3 stop: DAEMON_M3_DISABLED=1 ⇒ would SIGTERM pid=$pid for workspace=$ws"
    return 0
  fi
  declare -F log >/dev/null 2>&1 && log "M3 stop: SIGTERM pid=$pid for workspace=$ws"
  kill -TERM "$pid" 2>/dev/null || return 1
  return 0
}

# daemon_m3_reconcile_workspace <idx>
#   The per-workspace state machine. Called once per cadence per workspace.
#   ALWAYS returns 0 (a per-workspace failure must not abort the driver).
daemon_m3_reconcile_workspace() {
  local idx="${1:-}" ws pref desired pid prev
  [[ -n "$idx" ]] || return 0
  ws="${REGISTRY_DIRS[$idx]:-}"
  pref="${REGISTRY_PROJECT_REFS[$idx]:-}"
  [[ -n "$ws" && -n "$pref" ]] || return 0

  desired="$(daemon_m3_fetch_desired "$idx")"
  if [[ -z "$desired" ]]; then
    # Coordinator-unreachable or empty stored RunnerState. Per the runner's
    # §6.2 fail-OPEN posture (safe_capture COORD_UNREACHABLE running), we
    # would treat this as `running`. The DAEMON's posture is more
    # conservative: NO ACTION on a poll failure — we will neither spawn
    # nor kill on uncertainty. The next cadence retries; if the engine
    # stays unreachable indefinitely a runner already up keeps running,
    # and a runner already down stays down. This matches the daemon's
    # observe-first contract — we are not the source of truth.
    return 0
  fi

  pid="$(daemon_m3_runner_pid "$ws")"

  prev="${DAEMON_M3_LAST_DESIRED[$idx]:-}"
  if [[ "$prev" != "$desired" ]]; then
    declare -F log >/dev/null 2>&1 && \
      log "M3 transition: workspace=$ws project_ref=$pref desired ${prev:-<unset>} → $desired (runner_pid=${pid:-absent})"
    DAEMON_M3_LAST_DESIRED[$idx]="$desired"
  fi

  case "$desired" in
    running|spare-cycles)
      if [[ -z "$pid" ]]; then
        declare -F log >/dev/null 2>&1 && \
          log "M3 action: workspace=$ws desired=$desired ⇒ runner absent, spawning"
        daemon_m3_spawn "$ws" || true
      fi
      # alive ⇒ no-op
      ;;
    paused)
      # Leave a running runner alive (its own job_reconcile_desired loop
      # holds it at idle). Do NOT spawn a paused workspace — pausing a
      # dead workspace is identical to leaving it dead until a human
      # flips desired back to running.
      :
      ;;
    stopped)
      if [[ -n "$pid" ]]; then
        declare -F log >/dev/null 2>&1 && \
          log "M3 action: workspace=$ws desired=stopped ⇒ SIGTERM runner pid=$pid"
        daemon_m3_stop "$ws" "$pid" || true
      fi
      # already-stopped ⇒ no-op
      ;;
    *)
      # Defensive: daemon_m3_fetch_desired already filters to the §4.2
      # enum, but keep the unreachable arm explicit so a future widening
      # of the enum is flagged in the logs instead of silently mis-acted.
      declare -F log >/dev/null 2>&1 && \
        log "M3 action: workspace=$ws desired='$desired' is not in the §4.2 enum — no-op"
      ;;
  esac
  return 0
}

# daemon_m3_reconcile_all
#   Iterate the registry and reconcile each workspace. Driver entry point;
#   called from daemon.sh's main loop on the DESIRED_STATE_POLL_INTERVAL
#   cadence. ALWAYS returns 0.
daemon_m3_reconcile_all() {
  local n i
  n="$(registry_count 2>/dev/null || echo 0)"
  [[ "$n" -gt 0 ]] 2>/dev/null || return 0
  i=0
  while [[ "$i" -lt "$n" ]]; do
    daemon_m3_reconcile_workspace "$i" || true
    i=$((i + 1))
  done
  return 0
}
