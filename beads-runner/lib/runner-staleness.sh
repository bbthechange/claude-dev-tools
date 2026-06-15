#!/bin/bash
# beads-runner/lib/runner-staleness.sh — claude-tools-5772
#
# SELF-STALENESS re-exec for the per-workspace runner — the sibling of the daemon's
# claude-tools-jzzw fix. A runner is long-lived bash that SOURCES its libs ONCE at
# spawn and never re-reads them, so after a lib/runner code update a RUNNING runner
# keeps executing STALE code until something respawns it. The daemon's own self
# re-exec (jzzw) refreshes ONLY the daemon — its `exec` does NOT reap the runner
# process group the way `launchctl kickstart -k` does — so a daemon code-refresh
# leaves the runners on old code (the open follow-up daemon.md flagged: "a
# stale-RUNNER detector is a separate open follow-up").
#
# THE CHOSEN DESIGN (the low-risk option in the bead's open question): the runner
# self-detects stale source and re-execs BETWEEN TASKS — at the loop top / idle
# re-poll in v1, and in st_reconcile in v2 — where the runner is idle between
# `claude -p` spawns. A re-exec there loses NO in-flight worker. (The rejected
# alternative — a daemon force-bounce of all runners on a code update — is fresher
# but SIGKILLs any live worker = lost work.) This MIRRORS the daemon fix: compare
# the sourced-file mtimes against the runner's start epoch and re-exec when newer.
#
# Sourced by BOTH v1 (run-beads-tasks.sh) and v2 (runner.sh). The pure helpers are
# arg-injectable so test-runner-staleness.sh can exercise them without exec'ing.
# Mirrors the daemon's _daemon_file_mtime / daemon_newest_source_mtime /
# daemon_source_is_stale / daemon_reexec_if_stale.

# _runner_file_mtime <path> → integer mtime (epoch s); 0 if missing/unreadable.
# BSD (macOS — the runner's real home) stat first, then GNU stat (Linux/CI).
_runner_file_mtime() {
  local f="${1:-}"
  [[ -n "$f" && -e "$f" ]] || { echo 0; return 0; }
  stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0
}

# runner_newest_source_mtime <self_path> <runner_dir> → the newest mtime among the
# files THIS process sourced at boot: the runner script itself + every lib/*.sh
# (the layer the runner sources — INCLUDING the transitively-sourced coordinator.sh
# / local-agent.sh / co-http-transport.sh / stuck-routing.sh / dossier-gen.sh, the
# exact "after a lib update" case the bead targets) + the one sourced hook helper
# hooks/build-settings.sh. The lib/*.sh GLOB auto-enrolls future libs (same
# rationale as the daemon's *-poll.sh glob), so a new lib never silently escapes
# the staleness net. test-*.sh basenames are EXCLUDED so editing/running a test
# never bounces a live runner. hooks/close-checklist.sh is deliberately NOT watched
# — the runner re-reads it FRESH per worker spawn (it is injected via --settings,
# never sourced into the runner PROCESS), so it cannot go stale in this process.
runner_newest_source_mtime() {
  local self="${1:-}" dir="${2:-}" newest=0 f b m
  for f in "$self" "$dir"/lib/*.sh "$dir/hooks/build-settings.sh"; do
    [[ -e "$f" ]] || continue
    b="${f##*/}"
    [[ "$b" == test-* ]] && continue
    m="$(_runner_file_mtime "$f")"
    [[ "$m" =~ ^[0-9]+$ ]] || m=0
    [[ "$m" -gt "$newest" ]] && newest="$m"
  done
  echo "$newest"
}

# runner_source_is_stale <boot> <now> <self_path> <runner_dir> → rc 0 (STALE) iff a
# sourced file's mtime is STRICTLY NEWER than this process's start AND not in the
# future. A future mtime is clock-skew, never a real edit — rejecting it
# (newest ≤ now) prevents a re-exec loop on a bad clock. Pure ⇒ unit-testable.
runner_source_is_stale() {
  local boot="${1:-0}" now="${2:-0}" self="${3:-}" dir="${4:-}" newest
  newest="$(runner_newest_source_mtime "$self" "$dir")"
  [[ "$boot" =~ ^[0-9]+$ && "$newest" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] || return 1
  [[ "$newest" -gt "$boot" && "$newest" -le "$now" ]]
}

# runner_reexec_if_stale — the self-heal. Call ONLY at between-tasks points (the
# loop-top / idle re-poll in v1, st_reconcile in v2 — NEVER while a worker is live),
# so a re-exec here can lose no in-flight `claude -p`. If the source is newer than
# boot, log loudly and RE-EXEC: `exec` replaces the process image keeping the SAME
# PID, so the launch-detached pidfile (written by launch-detached.sh — the daemon's
# liveness oracle) stays valid and the launch-detached double-start guard does not
# trip (we re-exec the runner DIRECTLY, not via launch-detached.sh). `exec` does NOT
# fire any EXIT trap. Reads globals the runner sets before its loop:
#   RUNNER_SELF_REEXEC      off-switch (1=on; from BEADS_RUNNER_SELF_REEXEC)
#   RUNNER_SELF_START_EPOCH epoch captured ONCE at spawn (NOT exported ⇒ the child
#                           recomputes a fresh value ⇒ no re-exec loop)
#   RUNNER_SELF_PATH        abs path to the running script (the re-exec target)
#   RUNNER_SELF_DIR         the beads-runner dir (the lib/ + hooks/ glob root)
#   RUNNER_SELF_ARGV        array of the original argv (preserved across exec)
# Returns 1 (did nothing) when disabled / not stale.
runner_reexec_if_stale() {
  [[ "${RUNNER_SELF_REEXEC:-1}" == "1" ]] || return 1
  local now; now="$(date +%s 2>/dev/null || echo 0)"
  runner_source_is_stale "${RUNNER_SELF_START_EPOCH:-0}" "$now" \
    "${RUNNER_SELF_PATH:-}" "${RUNNER_SELF_DIR:-}" || return 1
  local newest; newest="$(runner_newest_source_mtime "${RUNNER_SELF_PATH:-}" "${RUNNER_SELF_DIR:-}")"
  echo "STALE SOURCE DETECTED (claude-tools-5772): a sourced runner/lib file mtime=$newest is newer than this process start=${RUNNER_SELF_START_EPOCH:-0} — re-executing BETWEEN TASKS to load fresh code (sibling of the claude-tools-jzzw daemon fix; a long-lived runner otherwise keeps running stale lib/runner code after an update until it is respawned). No worker is running at this point, so no in-flight task is lost."
  # shellcheck disable=SC2086  # the +"${arr[@]}" idiom is the bash-3.2-safe empty-array expansion
  exec /bin/bash "${RUNNER_SELF_PATH}" ${RUNNER_SELF_ARGV[@]+"${RUNNER_SELF_ARGV[@]}"}
}
