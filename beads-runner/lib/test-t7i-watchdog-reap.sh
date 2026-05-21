#!/usr/bin/env bash
# claude-tools-t7i acceptance test: a runner that has finished a `claude -p`
# task and has .stop-beads present must exit cleanly within one watchdog tick
# (~15s) and leave no orphan watchdog or `sleep` grandchild behind.
#
# This mirrors the *exact* scaffold from run-beads-tasks.sh's task block:
# stand-in "claude" exits 0 immediately (agent finished cleanly), .stop-beads
# is present, and the parent's bounded reap must complete fast. Pre-fix, the
# `wait $WATCHDOG_PID` could block forever because the subshell was mid-sleep
# and a pid-only SIGTERM raced; post-fix, the bounded reap escalates to
# SIGKILL and never blocks.

set -uo pipefail

TMPDIR_T="$(mktemp -d -t t7i-XXXXXX)"
cd "$TMPDIR_T" || exit 99
STOP_FILE=".stop-beads"
ACTIVITY_FILE="$TMPDIR_T/activity"
TASK_INFLIGHT_FILE="$TMPDIR_T/inflight"
IDLE_TIMEOUT=600
IDLE_TIMEOUT_INFLIGHT_MULT=4

date +%s > "$ACTIVITY_FILE"

( exit 0 ) &
CLAUDE_PID=$!

# Patched watchdog body — byte-identical to the one now in run-beads-tasks.sh.
(
  while kill -0 "$CLAUDE_PID" 2>/dev/null; do
    sleep 15
    kill -0 "$CLAUDE_PID" 2>/dev/null || break
    [[ -f "$STOP_FILE" ]] && break
    if [[ -f "$ACTIVITY_FILE" ]]; then
      LAST=$(cat "$ACTIVITY_FILE"); NOW=$(date +%s); IDLE=$((NOW - LAST))
      INFLIGHT=0
      if [[ -f "$TASK_INFLIGHT_FILE" ]]; then
        INFLIGHT=$(wc -l < "$TASK_INFLIGHT_FILE" 2>/dev/null | tr -d ' ')
        INFLIGHT=${INFLIGHT:-0}
      fi
      if [[ "$INFLIGHT" -gt 0 ]]; then
        EFFECTIVE_TIMEOUT=$(( IDLE_TIMEOUT * IDLE_TIMEOUT_INFLIGHT_MULT ))
      else
        EFFECTIVE_TIMEOUT=$IDLE_TIMEOUT
      fi
      [[ $IDLE -ge $EFFECTIVE_TIMEOUT ]] && break
    fi
  done
) &
WATCHDOG_PID=$!

# Pre-fix bug condition: user already touched .stop-beads.
touch "$STOP_FILE"

START=$(date +%s)

wait "$CLAUDE_PID" 2>/dev/null && CLAUDE_EXIT=0 || CLAUDE_EXIT=$?
sleep 1
kill -TERM "$WATCHDOG_PID" 2>/dev/null || true
pkill -P "$WATCHDOG_PID" 2>/dev/null || true
for _ in 1 2; do
  kill -0 "$WATCHDOG_PID" 2>/dev/null || break
  sleep 1
done
if kill -0 "$WATCHDOG_PID" 2>/dev/null; then
  pkill -KILL -P "$WATCHDOG_PID" 2>/dev/null || true
  kill -KILL "$WATCHDOG_PID" 2>/dev/null || true
fi
wait "$WATCHDOG_PID" 2>/dev/null || true

END=$(date +%s)
ELAPSED=$((END - START))

fails=0
if (( ELAPSED > 30 )); then
  echo "FAIL: reap took ${ELAPSED}s (>30s) — watchdog outlived its claude child"
  fails=$((fails+1))
else
  echo "ok: reap completed in ${ELAPSED}s (claude_exit=$CLAUDE_EXIT)"
fi
if kill -0 "$WATCHDOG_PID" 2>/dev/null; then
  echo "FAIL: WATCHDOG_PID $WATCHDOG_PID still alive after reap"
  fails=$((fails+1))
else
  echo "ok: WATCHDOG_PID $WATCHDOG_PID reaped"
fi
orphans=$(pgrep -P "$WATCHDOG_PID" 2>/dev/null | wc -l | tr -d ' ')
if (( orphans > 0 )); then
  echo "FAIL: $orphans orphan child(ren) under WATCHDOG_PID"
  fails=$((fails+1))
else
  echo "ok: no orphan children under WATCHDOG_PID"
fi

rm -rf "$TMPDIR_T"
exit "$fails"
