# shellcheck shell=bash
# beads-runner/daemon/m6-dispatch.sh — M6 bd-surgery dispatch
# (claude-tools-4iy; epic claude-tools-kie).
#
# WHAT THIS IS (DESIGN §3.3 / AD8 (b))
#   The daemon's response to "an answered dossier landed and the workspace
#   runner is busy on a DIFFERENT task." We cannot squat the in-flight worker
#   (it owns the worktree; we lack git-worktree machinery to fan out parallel
#   edits — explicitly AD8's deferred scope) and we cannot make the human wait
#   on a long `claude -p` to drain. So the daemon launches a SHORT-LIVED,
#   READ-ONLY `claude -p` against the same workspace in "bd-surgery" mode:
#   the agent (reconciler hat — agents/reconciler.system.md) reads the bead,
#   reads the captured resume-answer, reads enough docs to ground itself,
#   then emits `bd create / bd update / bd dep / bd label` calls reflecting
#   the human's decision. It does NOT edit code. It does NOT commit. Its
#   only side effects are `bd` subprocess calls (which write to .beads/).
#
# WHAT THIS IS *NOT*
#   • NOT the resume — the parked bead stays blocked-for-human; once the
#     workspace runner finishes its in-flight bead-A and idles, the existing
#     M5 idle-handoff (the runner's prompt-splice path) picks up the
#     resume-answer file and re-dispatches bead-B normally. M6 is "do the
#     bookkeeping NOW so the resumed worker sees the updated task graph,"
#     not "re-dispatch the worker NOW."
#   • NOT a worker. Permissions are deliberately narrow: Write/Edit/
#     MultiEdit/NotebookEdit/BashWriteEdits all denied, --permission-mode
#     default (no acceptEdits). The agent can `Read`, `Glob`, `Grep`, `LS`,
#     and `Bash` (for `bd` / read-only `git status`/`log`/`diff`), nothing
#     more.
#
# LIFECYCLE OWNERSHIP (per M6 task spec)
#   The DAEMON owns each dispatch:
#     - pidfile per task_ref:  $DAEMON_M6_PIDS/<safe_task_ref>.pid
#     - log file per dispatch: $DAEMON_M6_LOGS/<safe_task_ref>-<ts>.log
#     - context file per disp: $DAEMON_M6_LOGS/<safe_task_ref>-<ts>.context.json
#   `daemon_m6_kill_all` is wired into the daemon's drain handler so a
#   SIGTERM to the daemon also SIGTERMs every live bd-surgery child. Agents
#   are expected to self-terminate in a few minutes; the drain kill is a
#   backstop, not the primary exit path.
#
# IDEMPOTENCY
#   A second observation of the SAME task_ref's answer while the previous
#   bd-surgery is still alive is a no-op (skip with a log line). New_list
#   filtering in hosted-resolution-poll.sh already screens against re-acting
#   on stale answer files; this is belt-and-suspenders for the brief window
#   between answer-file capture and the previous agent's exit.

# Resolve sibling paths at source time so we don't depend on the daemon's
# cwd. DAEMON_CACHE_DIR is set by daemon.sh before sourcing this file (and
# defaulted in the test harness if it isn't).
DAEMON_M6_BASE="${DAEMON_M6_BASE:-${DAEMON_CACHE_DIR:-$HOME/.cache/claude-tools}/m6-dispatch}"
DAEMON_M6_PIDS="$DAEMON_M6_BASE/pids"
DAEMON_M6_LOGS="$DAEMON_M6_BASE/logs"
# The specialist shim — one binary, kind-selected prompts (S1, claude-tools-bk6).
DAEMON_M6_SPECIALIST="${DAEMON_M6_SPECIALIST:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../agents" 2>/dev/null && pwd)/specialist.sh}"
# Test/canary hook: set DAEMON_M6_DISABLED=1 to log the decision but skip the
# actual `claude -p` launch (used by the acceptance test so it can verify the
# call-site wiring without spawning a real agent).
DAEMON_M6_DISABLED="${DAEMON_M6_DISABLED:-0}"

# daemon_m6__safe_key <task_ref> — sanitize a task_ref for use as a filename
#   component. Mirrors do__safe_key's spirit (no '/' or '..', conservative
#   allowed-set) without sourcing the do__ surface here (this file is loaded
#   by the daemon at top level, before any per-workspace lib is sourced).
daemon_m6__safe_key() {
  local in="${1:-}" out
  out="${in//\//_}"
  out="${out//../_}"
  # collapse anything outside [A-Za-z0-9._-] to '_'.
  printf '%s' "$out" | tr -c 'A-Za-z0-9._-' '_'
}

# daemon_m6_pidfile_for <task_ref> — echo the per-task_ref pidfile path.
daemon_m6_pidfile_for() {
  local tref="${1:-}" key
  [[ -n "$tref" ]] || return 0
  key="$(daemon_m6__safe_key "$tref")"
  printf '%s/%s.pid' "$DAEMON_M6_PIDS" "$key"
}

# daemon_m6_already_in_flight <task_ref> — true (0) iff a previous dispatch
#   for the same task_ref still has a live pid. Stale pidfile is reclaimed.
daemon_m6_already_in_flight() {
  local pf pid
  pf="$(daemon_m6_pidfile_for "$1")"
  [[ -n "$pf" && -f "$pf" ]] || return 1
  pid="$(cat "$pf" 2>/dev/null || echo "")"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  rm -f "$pf" 2>/dev/null || true
  return 1
}

# daemon_m6_dispatch_busy <workspace_dir> <task_ref> <dossier_id> <item_id> <answer_file>
#   Launch a detached bd-surgery (reconciler hat) claude -p in the workspace.
#   ALWAYS returns 0 to the caller — a launch failure must not abort the
#   daemon's main loop; it logs and moves on (same posture as the M4 poll).
daemon_m6_dispatch_busy() {
  local ws="${1:-}" tref="${2:-}" did="${3:-}" iid="${4:-}" ans="${5:-}"
  if [[ -z "$ws" || ! -d "$ws" ]]; then
    declare -F log >/dev/null 2>&1 && log "M6 dispatch: reject — workspace '$ws' missing"
    return 0
  fi
  if [[ -z "$tref" ]]; then
    declare -F log >/dev/null 2>&1 && log "M6 dispatch: reject — no task_ref"
    return 0
  fi

  # The shim is the one binary that knows how to launch a hat-scoped claude -p.
  # If it isn't present, we cannot dispatch — log and bail (the parked bead
  # stays parked; the next idle-handoff still picks it up via M5).
  if [[ ! -x "$DAEMON_M6_SPECIALIST" ]]; then
    declare -F log >/dev/null 2>&1 && \
      log "M6 dispatch: specialist.sh not executable at $DAEMON_M6_SPECIALIST — refusing to dispatch (task_ref=$tref)"
    return 0
  fi

  # Test/canary hook: log the would-be launch but skip claude -p. This is the
  # only branch the M6 acceptance test exercises in CI (no claude binary, no
  # network); the runtime wiring (cwd, --add-dir, --disallowedTools) is
  # asserted via the recorded context file + the shim's known posture.
  if [[ "$DAEMON_M6_DISABLED" == "1" ]]; then
    declare -F log >/dev/null 2>&1 && \
      log "M6 dispatch: DAEMON_M6_DISABLED=1 ⇒ skipping claude -p launch (workspace=$ws task_ref=$tref) — context captured for inspection"
    # Still write the context file so the test (and a human inspecting why a
    # dispatch fired but no agent appeared) can see what would have run.
    mkdir -p "$DAEMON_M6_LOGS" 2>/dev/null || return 0
    local ts safe_tref ctx_file ans_json
    ts="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo run)"
    safe_tref="$(daemon_m6__safe_key "$tref")"
    ctx_file="$DAEMON_M6_LOGS/${safe_tref}-${ts}.context.json"
    ans_json="{}"
    [[ -n "$ans" && -f "$ans" ]] && ans_json="$(cat "$ans" 2>/dev/null || echo "{}")"
    printf '%s' "$ans_json" | jq -e . >/dev/null 2>&1 || ans_json="{}"
    _daemon_m6_write_context "$ctx_file" "$ws" "$tref" "$did" "$iid" "$ans_json" || true
    return 0
  fi

  if daemon_m6_already_in_flight "$tref"; then
    declare -F log >/dev/null 2>&1 && \
      log "M6 dispatch: a bd-surgery agent for task_ref=$tref is already in flight — skipping re-dispatch (idempotent)"
    return 0
  fi

  mkdir -p "$DAEMON_M6_PIDS" "$DAEMON_M6_LOGS" 2>/dev/null || {
    declare -F log >/dev/null 2>&1 && \
      log "M6 dispatch: could not create $DAEMON_M6_BASE — refusing to dispatch (task_ref=$tref)"
    return 0
  }

  local ts safe_tref pidfile log_file ctx_file ans_json
  ts="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo run)"
  safe_tref="$(daemon_m6__safe_key "$tref")"
  pidfile="$DAEMON_M6_PIDS/${safe_tref}.pid"
  log_file="$DAEMON_M6_LOGS/${safe_tref}-${ts}.log"
  ctx_file="$DAEMON_M6_LOGS/${safe_tref}-${ts}.context.json"

  ans_json="{}"
  if [[ -n "$ans" && -f "$ans" ]]; then
    ans_json="$(cat "$ans" 2>/dev/null || echo "{}")"
    printf '%s' "$ans_json" | jq -e . >/dev/null 2>&1 || ans_json="{}"
  fi

  if ! _daemon_m6_write_context "$ctx_file" "$ws" "$tref" "$did" "$iid" "$ans_json"; then
    declare -F log >/dev/null 2>&1 && \
      log "M6 dispatch: could not write context file $ctx_file — refusing to dispatch (task_ref=$tref)"
    return 0
  fi

  # THE DETACH — same idiom as launch-detached.sh. Subshell-background +
  # nohup + </dev/null + log redirect reparents the agent to PID 1 so the
  # daemon can return at once. PIDFILE crosses via the environment (never
  # string-spliced) so a workspace path with a quote/$() stays inert data.
  (
    cd "$ws" 2>/dev/null || exit 0
    M6_PIDFILE="$pidfile" \
    M6_SPECIALIST="$DAEMON_M6_SPECIALIST" \
    M6_WORKSPACE="$ws" \
    M6_CTX="$ctx_file" \
      nohup bash -c '
        echo "$$" > "$M6_PIDFILE"
        exec "$M6_SPECIALIST" \
          --kind=reconciler \
          --workspace="$M6_WORKSPACE" \
          --context-file="$M6_CTX"
      ' >"$log_file" 2>&1 </dev/null &
    disown 2>/dev/null || true
  )

  # Poll briefly for the bootstrap to write the pidfile (single sleep races a
  # loaded machine and prints a spurious "could not confirm" on a good launch
  # — the launch-detached.sh precedent).
  local newpid="" i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    newpid="$(cat "$pidfile" 2>/dev/null || echo "")"
    [[ -n "$newpid" ]] && kill -0 "$newpid" 2>/dev/null && break
    newpid=""
    sleep 0.2 2>/dev/null || true
  done

  if declare -F log >/dev/null 2>&1; then
    if [[ -n "$newpid" ]]; then
      log "M6 dispatch: bd-surgery agent LAUNCHED (pid=$newpid) for task_ref=$tref workspace=$ws — log=$log_file context=$ctx_file"
    else
      log "M6 dispatch: bd-surgery agent launch issued (could not confirm pid) for task_ref=$tref workspace=$ws — log=$log_file (inspect for cause)"
    fi
  fi
  return 0
}

# _daemon_m6_write_context <ctx_file> <ws> <task_ref> <dossier_id> <item_id> <answer_json>
#   Internal helper. Build the reconciler context JSON. Kept separate so the
#   test/canary branch can also write it without duplicating the jq script.
_daemon_m6_write_context() {
  local ctx="$1" ws="$2" tref="$3" did="$4" iid="$5" ans_json="$6" tmp
  tmp="$ctx.$$.tmp"
  if jq -cn \
      --arg ws    "$ws" \
      --arg tref  "$tref" \
      --arg did   "$did" \
      --arg iid   "$iid" \
      --argjson ans "$ans_json" \
      '{
         mode: "bd-surgery",
         workspace_dir: $ws,
         bead_ref: $tref,
         dossier_id: $did,
         item_id: $iid,
         answer: $ans,
         instructions: (
           "You are running in bd-surgery mode against workspace " + $ws +
           ". The bead `" + $tref + "` was parked blocked-for-human; a human " +
           "just answered the dossier. The captured answer record is in the " +
           "`answer` field of this context. " +
           "Your job: read the bead notes/design and any relevant docs to " +
           "ground yourself, then emit the bd create / bd update / bd dep / " +
           "bd label commands that reflect the human decision. " +
           "Do NOT edit code, do NOT commit, do NOT touch the worktree " +
           "outside .beads/. When finished, exit cleanly — the parked bead " +
           "is left for the workspace runner''s next idle-handoff (M5)."
         )
       }' > "$tmp" 2>/dev/null && mv -f "$tmp" "$ctx" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

# daemon_m6_kill_all — SIGTERM every live bd-surgery dispatch. Called from the
#   daemon's drain handler (SIGTERM/SIGINT). Best-effort: a stuck child is the
#   exception, and we log enough that a human can `kill -9` it by hand if so.
daemon_m6_kill_all() {
  [[ -d "$DAEMON_M6_PIDS" ]] || return 0
  local f pid killed=0
  for f in "$DAEMON_M6_PIDS"/*.pid; do
    [[ -e "$f" ]] || continue
    pid="$(cat "$f" 2>/dev/null || echo "")"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      killed=$((killed+1))
      declare -F log >/dev/null 2>&1 && \
        log "M6 dispatch: sent SIGTERM to bd-surgery pid=$pid (pidfile=$f) on daemon drain"
    fi
    rm -f "$f" 2>/dev/null || true
  done
  if [[ "$killed" -gt 0 ]]; then
    declare -F log >/dev/null 2>&1 && \
      log "M6 dispatch: drain killed $killed in-flight bd-surgery agent(s)"
  fi
  return 0
}
