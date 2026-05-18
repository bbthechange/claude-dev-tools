#!/bin/bash
# beads-runner/launch-detached.sh — start a runner DETACHED from any process
# tree (I2 deliverable b; epic claude-tools-8bm).
#
# WHY THIS EXISTS
#   The runner reaps its whole child process tree on teardown (BC-39/40): a
#   runner started *by* an ephemeral task agent dies the instant that agent
#   exits — it can never be a long-lived workspace runner. The long-lived
#   launch MUST therefore be a separate, non-ephemeral act that reparents the
#   runner to init (PID 1), detached from the launching shell's session and
#   controlling terminal, so it survives the launcher returning. This is that
#   mechanism, committed and reusable (used by I3/I5 staging or an explicit
#   one-time human launch — NEVER invoked by a task agent: a task agent that
#   ran this would itself be reaped while the grandchild keeps running, which
#   is the point, but the *decision* to start a long-lived runner is not a
#   task agent's to make — see the epic CONSTRAINT note on the I3 fixture).
#
# WHAT IT DOES
#   Double-fork / nohup / </dev/null detach (portable; macOS has no `setsid`):
#   `( nohup CMD >LOG 2>&1 </dev/null & )` — the inner job is backgrounded in
#   a subshell that exits immediately, so the job reparents to PID 1; nohup
#   ignores SIGHUP and the /dev/null stdin drops the controlling tty. This is
#   exactly the PPID-1, no-tty state the existing claude-tools runners run in.
#   A pidfile guards against a duplicate runner for the same workspace.
#
# USAGE
#   beads-runner/launch-detached.sh [WORKSPACE_DIR]
#     WORKSPACE_DIR  workspace to run in (default: $PWD). Its .beads/runner.sh
#                    supplies config (COORDINATOR_URL/PROJECT_REF/perms).
#   Env:
#     RUNNER_CMD     runner to exec (default: this repo's run-beads-tasks.sh,
#                    else `run-beads-tasks` on PATH). Extra args after the
#                    workspace dir are passed through to the runner verbatim.
#     COORDINATOR_TOKEN  if exported, inherited by the detached runner (the
#                    §9.2 server-side bearer; otherwise the runner resolves it
#                    from the Keychain — NEVER hard-code it here).
#
# Prints the pid + log path and RETURNS (does not hold the process). Exit 0 on
# launch, 2 on a usage/precondition error, 3 if a live runner already owns the
# workspace.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

WORKSPACE_DIR="${1:-$PWD}"
[[ $# -gt 0 ]] && shift
if [[ ! -d "$WORKSPACE_DIR" ]]; then
  echo "launch-detached: '$WORKSPACE_DIR' is not a directory" >&2
  exit 2
fi
WORKSPACE_DIR="$(cd "$WORKSPACE_DIR" 2>/dev/null && pwd)" || {
  echo "launch-detached: cannot resolve workspace dir" >&2; exit 2; }
if [[ ! -f "$WORKSPACE_DIR/.beads/runner.sh" ]]; then
  echo "launch-detached: $WORKSPACE_DIR/.beads/runner.sh missing — not a wired workspace" >&2
  exit 2
fi

# Resolve the runner command: this repo's script first (so the I2 §4.2
# heartbeat path is exercised), else the installed `run-beads-tasks`.
if [[ -n "${RUNNER_CMD:-}" ]]; then
  # Deliberate word-split (RUNNER_CMD may be "bash /path/run.sh --flag"); but
  # NO pathname expansion — a `*`/`?`/`[` in the operator's command must stay
  # literal, never glob against the launcher's cwd.
  set -f; RUNNER=( ${RUNNER_CMD} ); set +f
elif [[ -x "$HERE/run-beads-tasks.sh" ]]; then
  RUNNER=( "$HERE/run-beads-tasks.sh" )
elif command -v run-beads-tasks >/dev/null 2>&1; then
  RUNNER=( run-beads-tasks )
else
  echo "launch-detached: no runner found (set RUNNER_CMD, or install run-beads-tasks)" >&2
  exit 2
fi

LOG_DIR="$WORKSPACE_DIR/.beads/runner-logs"
mkdir -p "$LOG_DIR" 2>/dev/null || { echo "launch-detached: cannot create $LOG_DIR" >&2; exit 2; }
PIDFILE="$LOG_DIR/detached-runner.pid"

# Refuse a duplicate: a live pid in the pidfile owns this workspace.
if [[ -f "$PIDFILE" ]]; then
  OLD_PID="$(cat "$PIDFILE" 2>/dev/null || echo "")"
  if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "launch-detached: a runner (pid $OLD_PID) already owns $WORKSPACE_DIR — refusing to start a second" >&2
    echo "  stop it first: kill $OLD_PID   (or rm $PIDFILE if it is stale)" >&2
    exit 3
  fi
  rm -f "$PIDFILE" 2>/dev/null || true
fi

TS="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo run)"
LOG="$LOG_DIR/detached-$TS.log"

echo "launch-detached: workspace = $WORKSPACE_DIR"
echo "launch-detached: runner    = ${RUNNER[*]} $*"
echo "launch-detached: log       = $LOG"

# THE DETACH. The subshell `( … & )` backgrounds the job then exits at once,
# orphaning it onto PID 1; nohup + </dev/null sever SIGHUP and the tty. A
# tiny bootstrap cd's into the workspace, records its own pid, and execs the
# runner so the runner process itself is the pid we track (no wrapper layer).
(
  cd "$WORKSPACE_DIR" || exit 0
  # PIDFILE crosses into the bootstrap via the ENVIRONMENT, not string-spliced
  # into the single-quoted body — a workspace path containing a quote/`$(`
  # then stays inert data, never reparsed by the inner shell.
  DETACHED_PIDFILE="$PIDFILE" nohup bash -c '
    echo "$$" > "$DETACHED_PIDFILE"
    exec "$@"
  ' _ "${RUNNER[@]}" "$@" >"$LOG" 2>&1 </dev/null &
  disown 2>/dev/null || true
)

# Poll briefly for the bootstrap to write the pidfile (a single sleep races a
# loaded machine and prints a spurious "could not confirm" on a good launch).
NEW_PID=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  NEW_PID="$(cat "$PIDFILE" 2>/dev/null || echo "")"
  [[ -n "$NEW_PID" ]] && kill -0 "$NEW_PID" 2>/dev/null && break
  NEW_PID=""
  sleep 0.3
done
if [[ -n "$NEW_PID" ]] && kill -0 "$NEW_PID" 2>/dev/null; then
  echo "launch-detached: STARTED — runner pid $NEW_PID (detached; PPID will reparent to 1)"
  echo "launch-detached: tail -f $LOG"
  exit 0
fi
echo "launch-detached: launched but could not confirm the pid — check $LOG" >&2
exit 0
