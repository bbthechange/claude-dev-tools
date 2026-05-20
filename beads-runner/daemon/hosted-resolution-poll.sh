# shellcheck shell=bash
# beads-runner/daemon/hosted-resolution-poll.sh — M4 hosted-resolution poll
# (claude-tools-8jb; epic claude-tools-kie).
#
# WHAT THIS IS (DESIGN §3.2 job 5 / AD8 build pointer)
#   The daemon-side job that observes Coordinator-side answered dossiers and
#   drives resume dispatch into the affected workspace. Moved here from
#   run-beads-tasks.sh:~746, which only polled BETWEEN tasks — meaning a long
#   `claude -p` could hold the runner busy for hours while a phone-answered
#   dossier sat unobserved. The daemon polls continuously, per workspace,
#   regardless of what any runner is busy doing — the "always listening"
#   piece the AD8 latency promise demands.
#
# WHAT THIS IS *NOT*
#   • NOT the await/capture LOGIC. That logic — read the dossier back over
#     the §2.1 surface, detect answered/applied items, capture the decision
#     into the resume-answer sibling namespace, flip the S-2 bfh record — is
#     `sr_poll_hosted_resolution` in lib/stuck-routing.sh:490. We do not
#     duplicate it; we run it per workspace under the workspace's own
#     environment (CO_STORE / COORDINATOR_URL / COORDINATOR_TOKEN).
#   • NOT the resume dispatch decision. Whether the daemon hands off to M5
#     (idle/parked workspace ⇒ existing prompt-splice path picks it up) or
#     M6 (busy on a DIFFERENT task ⇒ bd-surgery agent) is decided HERE but
#     the actual dispatch lands in those issues. M4 surfaces the decision in
#     the log (observable-not-silent) so the daemon's wake-up plus the
#     decision are visible, but does not yet take the M6 action.
#
# ISOLATION
#   The workspace runner sources lib/stuck-routing.sh under workspace-scoped
#   env (CO_STORE under the workspace's runner-logs dir; COORDINATOR_URL +
#   COORDINATOR_TOKEN from `.beads/runner.sh`). The daemon process services N
#   workspaces, each with DIFFERENT env. To avoid cross-workspace bleed we
#   run each poll in a SUBSHELL: env is set fresh per workspace, libs sourced
#   fresh, and the subshell exits before the next workspace is touched.
#
# DEPENDENCIES
#   The daemon ships in the same repo as lib/stuck-routing.sh and friends, so
#   the sourced paths are stable relative to this file. `jq`, `security`, and
#   `curl` are the same dependencies the rest of beads-runner already carries.

# DAEMON_REPO_LIB_DIR — the libs are siblings of the daemon dir. Resolve at
# source time so we don't depend on the daemon's cwd.
DAEMON_REPO_LIB_DIR="${DAEMON_REPO_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)}"

# daemon_workspace_runner_state <workspace_dir>
#   Inspect a workspace's runner pidfile + most-recent heartbeat in its
#   coordinator-outbox to classify the runner. Echoes one of:
#     absent           — no pidfile or pid not alive
#     idle             — pidfile alive, last heartbeat actual=idle (or no
#                        current_task_ref recorded)
#     busy:<task_ref>  — pidfile alive, last heartbeat actual=running with a
#                        current_task_ref
#   The pidfile lives at <workspace>/.beads/runner-logs/detached-runner.pid
#   (launch-detached.sh's PIDFILE convention); heartbeats live at
#   <workspace>/.beads/runner-logs/coordinator-outbox.jsonl (la__outbox).
#   Fail-open: a malformed outbox / unreadable pidfile ⇒ absent (we'd rather
#   miss a busy classification and fall through to the existing prompt-splice
#   path than block on parsing).
daemon_workspace_runner_state() {
  local ws="${1:-}" pidfile outbox pid last_hb actual cur
  [[ -n "$ws" && -d "$ws" ]] || { echo absent; return 0; }
  pidfile="$ws/.beads/runner-logs/detached-runner.pid"
  outbox="$ws/.beads/runner-logs/coordinator-outbox.jsonl"
  pid=""
  if [[ -f "$pidfile" ]]; then
    pid="$(cat "$pidfile" 2>/dev/null || echo "")"
  fi
  if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
    echo absent
    return 0
  fi
  if [[ ! -f "$outbox" ]]; then
    echo idle
    return 0
  fi
  # Last heartbeat record (report=="heartbeat") in the outbox — the most recent
  # actual+current_task_ref pair the workspace runner emitted.
  last_hb="$(tac "$outbox" 2>/dev/null | jq -c 'select(.report=="heartbeat")' 2>/dev/null | head -1)" || last_hb=""
  if [[ -z "$last_hb" ]]; then
    # macOS BSD has no `tac`; fall back to a tail-reverse via awk.
    last_hb="$(awk '/"report":"heartbeat"/' "$outbox" 2>/dev/null | tail -1)" || last_hb=""
  fi
  if [[ -z "$last_hb" ]]; then
    echo idle
    return 0
  fi
  actual="$(printf '%s' "$last_hb" | jq -r '.actual // ""' 2>/dev/null)" || actual=""
  cur="$(printf '%s' "$last_hb" | jq -r '.current_task_ref // ""' 2>/dev/null)" || cur=""
  if [[ "$actual" == "running" && -n "$cur" ]]; then
    echo "busy:$cur"
  else
    echo idle
  fi
}

# daemon_poll_workspace_hosted_resolution <workspace_idx>
#   Run the per-workspace hosted-resolution poll for REGISTRY_<arrays>[idx].
#   This is the migration of run-beads-tasks.sh's old loop-top
#   sr_poll_hosted_resolution call into the daemon, with two additions:
#     1. Continuous cadence regardless of what the workspace runner is doing
#        (the daemon's main loop drives this; the runner's loop top no longer
#        does — a busy `claude -p` cannot stall observation).
#     2. Per-observation dispatch decision (M5 vs M6) logged before exit so
#        the operator can see "idle/parked → splice will pick up" vs
#        "busy on a DIFFERENT task → M6 bd-surgery needed".
#   Echoes the count of newly-captured answer records (same shape as the
#   stuck-routing function's echo); never aborts the daemon.
daemon_poll_workspace_hosted_resolution() {
  local idx="${1:-}" ws pref curl tk_item state n adir
  local before_list after_list new_list
  [[ -n "$idx" ]] || return 0
  ws="${REGISTRY_DIRS[$idx]:-}"
  pref="${REGISTRY_PROJECT_REFS[$idx]:-}"
  curl="${REGISTRY_COORDINATOR_URLS[$idx]:-}"
  tk_item="${REGISTRY_TOKEN_KEYCHAIN_ITEMS[$idx]:-}"
  [[ -n "$ws" && -d "$ws" ]] || return 0

  # Snapshot the answer-namespace dir BEFORE the poll so we can attribute any
  # NEWLY-appeared answer files to this poll cycle (and log the dispatch
  # decision per-new-task only). Without this we'd re-log decisions on every
  # cadence for old answers the workspace runner hasn't consumed yet.
  adir="$ws/.beads/runner-logs/.co-store/blocked-for-human-answer"
  before_list=""
  if [[ -d "$adir" ]]; then
    before_list="$(ls -1 "$adir" 2>/dev/null | sort)"
  fi

  # The poll runs in a SUBSHELL so the env (CO_STORE, COORDINATOR_URL,
  # COORDINATOR_TOKEN, PROJECT_REF) is workspace-scoped and does not leak
  # across iterations. Subshell prints the observed count on stdout; parent
  # captures it and logs the dispatch decision. Subshell body is delegated to
  # the `_daemon_poll_one` helper so we don't nest parens inside `$(...)`.
  n="$(_daemon_poll_one "$ws" "$pref" "$curl" "$tk_item")"
  [[ -n "$n" ]] || n=0

  # Always also reconcile in the daemon: the existing
  # sr_reconcile_blocked_for_human in the runner still runs, but if the runner
  # is between tasks (idle) it may be hours before its next loop top — so the
  # daemon performs the reconcile too. Both calls are idempotent; doing it
  # twice is the §7.3 discipline (must not rot).
  _daemon_reconcile_one "$ws" "$pref" "$curl" "$tk_item" >/dev/null 2>&1 || true

  if [[ "$n" != "0" ]] && [[ -d "$adir" ]]; then
    after_list="$(ls -1 "$adir" 2>/dev/null | sort)"
    # Files present after but not before = answers newly captured by this poll.
    new_list="$(comm -13 <(printf '%s\n' "$before_list") <(printf '%s\n' "$after_list"))"
    if [[ -n "$new_list" ]]; then
      state="$(daemon_workspace_runner_state "$ws")"
      daemon_dispatch_for_state "$ws" "$state" "$adir" "$new_list"
    fi
  fi

  echo "$n"
  return 0
}

# _daemon_poll_one <ws> <pref> <curl> <tk_item>
#   Run sr_poll_hosted_resolution in a fresh subshell with workspace-scoped
#   env. Internal helper for daemon_poll_workspace_hosted_resolution; not for
#   direct use outside this file.
_daemon_poll_one() {
  local ws="$1" pref="$2" curl="$3" tk_item="$4"
  (
    set +e
    cd "$ws" 2>/dev/null || { echo 0; exit 0; }
    export PROJECT_REF="$pref"
    : "${CO_STORE:=$ws/.beads/runner-logs/.co-store}"
    export CO_STORE
    if [[ -n "$curl" ]]; then export COORDINATOR_URL="$curl"; fi
    if [[ -n "$tk_item" ]] && command -v security >/dev/null 2>&1; then
      local _tk
      _tk="$(security find-generic-password -s "$tk_item" -w 2>/dev/null || true)"
      [[ -n "$_tk" ]] && export COORDINATOR_TOKEN="$_tk"
    fi
    # shellcheck source=/dev/null
    . "$DAEMON_REPO_LIB_DIR/stuck-routing.sh" 2>/dev/null || { echo 0; exit 0; }
    # I3 ordering preserved: co-http-transport sourced LAST so its HTTP
    # co_request wins when COORDINATOR_URL is set.
    # shellcheck source=/dev/null
    [[ -f "$DAEMON_REPO_LIB_DIR/notification.sh" ]] && . "$DAEMON_REPO_LIB_DIR/notification.sh" 2>/dev/null
    # shellcheck source=/dev/null
    [[ -f "$DAEMON_REPO_LIB_DIR/co-http-transport.sh" ]] && . "$DAEMON_REPO_LIB_DIR/co-http-transport.sh" 2>/dev/null
    command -v sr_poll_hosted_resolution >/dev/null 2>&1 || { echo 0; exit 0; }
    sr_poll_hosted_resolution "${SR_BEARER:-bearer-runner-stuck}" 2>/dev/null || echo 0
  )
}

# _daemon_reconcile_one <ws> <pref> <curl> <tk_item>
#   Run sr_reconcile_blocked_for_human in a fresh subshell. Internal helper.
_daemon_reconcile_one() {
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
    # shellcheck source=/dev/null
    . "$DAEMON_REPO_LIB_DIR/stuck-routing.sh" 2>/dev/null || exit 0
    command -v sr_reconcile_blocked_for_human >/dev/null 2>&1 || exit 0
    sr_reconcile_blocked_for_human "${SR_BEARER:-bearer-runner-stuck}" >/dev/null 2>&1 || true
  )
}

# daemon_dispatch_for_state <workspace_dir> <runner_state> <answer_dir> <newline-separated-filenames>
#   Print a §7.3/AD8-cited dispatch-decision line per NEWLY-captured answer.
#   M4 surfaces the BRANCH; the actual dispatch action is M5 (idle/parked
#   workspace, the easy path) or M6 (busy on a different task ⇒ bd-surgery).
#   Only acts on the newline-separated list of filenames passed in (the diff
#   between before- and after-poll snapshots) so each dispatch decision logs
#   exactly once per captured answer.
daemon_dispatch_for_state() {
  local ws="${1:-}" state="${2:-}" adir="${3:-}" newlist="${4:-}"
  local busy_task fname tref decision
  busy_task=""
  case "$state" in busy:*) busy_task="${state#busy:}";; esac
  [[ -d "$adir" ]] || return 0
  [[ -n "$newlist" ]] || return 0
  while IFS= read -r fname; do
    [[ -n "$fname" ]] || continue
    [[ -f "$adir/$fname" ]] || continue
    tref="$(jq -r '.task_ref // ""' "$adir/$fname" 2>/dev/null)" || tref=""
    [[ -n "$tref" ]] || continue
    if [[ "$state" == "absent" || "$state" == "idle" ]]; then
      decision="M5 (idle/parked): the workspace runner is idle or absent; the existing prompt-splice path in run-beads-tasks.sh picks it up on its next loop top"
    elif [[ -n "$busy_task" && "$busy_task" == "$tref" ]]; then
      decision="M5 (busy on the parked task): the workspace runner is currently on $tref itself — splice will pick the answer up at the next iteration; no surgery needed"
    elif [[ -n "$busy_task" ]]; then
      decision="M6 (busy on a DIFFERENT task $busy_task): a bd-surgery agent must apply the answer to $tref in parallel (AD8 (b)) — M6 dispatch needed"
    else
      decision="M5/M6 (unknown runner state): defaulting to M5 splice path"
    fi
    if declare -F log >/dev/null 2>&1; then
      log "M4 dispatch: workspace=$ws task_ref=$tref runner_state=$state ⇒ $decision"
    else
      printf '%s M4 dispatch: workspace=%s task_ref=%s runner_state=%s ⇒ %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$ws" "$tref" "$state" "$decision"
    fi
  done <<< "$newlist"
  return 0
}
