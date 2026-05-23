#!/usr/bin/env bash
# claude-tools-yva acceptance test: after the per-task reap, NO `sleep`
# grandchildren of the WATCHDOG/TAIL subshells survive — even when the
# subshell leader has already exited and the grandchild has been reparented
# to PID 1. The t7i test missed this class (it only checked `pgrep -P
# $WATCHDOG_PID`, which by definition cannot see reparented orphans).
#
# Pattern under test:
# 1. Spawn TAIL+WATCHDOG subshells (with `set -m` so each gets its own PG)
# 2. Each subshell holds a `sleep` grandchild
# 3. Force the subshell leaders to exit (mimic break/loop-exit between iters)
# 4. Run the new PG-targeted reap
# 5. Verify zero orphan `sleep` processes tagged with our marker remain

set -uo pipefail

MARKER="yva_test_$$_$(date +%s%N 2>/dev/null || date +%s)"
fails=0

# ── Setup: spawn TAIL and WATCHDOG in their own PGs (mirror run-beads-tasks.sh) ─

set -m
(
  exec -a "tail_${MARKER}" sleep 120
) &
TAIL_PID=$!
set +m

set -m
(
  # Mimic watchdog mid-sleep: spawn a sleep grandchild, then have the leader
  # itself exit while the grandchild is still alive. This is the race the
  # production code hits: the loop body exits between iterations while a
  # `sleep 15` is still ticking down as a separate process.
  ( exec -a "watchdog_sleep_${MARKER}" sleep 120 ) &
  exit 0
) &
WATCHDOG_PID=$!
set +m

# Give the spawns a moment to settle.
sleep 0.5

# ── Confirm setup: orphan grandchild now exists (PPID=1) ─────────────────────

GRANDCHILDREN_BEFORE=$(ps -A -o pid,ppid,command | awk -v m="$MARKER" '$0 !~ /awk/ && index($0, m){print}')
WATCHDOG_ORPHAN_BEFORE=$(echo "$GRANDCHILDREN_BEFORE" | awk -v m="watchdog_sleep_$MARKER" '$2==1 && index($0, m){print $1}')
if [[ -z "$WATCHDOG_ORPHAN_BEFORE" ]]; then
  # On some bash builds the subshell may not have exited yet; tolerate by
  # giving another beat.
  sleep 0.5
  WATCHDOG_ORPHAN_BEFORE=$(ps -A -o pid,ppid,command | awk -v m="watchdog_sleep_$MARKER" '$2==1 && index($0, m){print $1}')
fi
echo "setup: watchdog orphan grandchild = ${WATCHDOG_ORPHAN_BEFORE:-<none>}"

# ── Run the new PG-targeted reap (mirror run-beads-tasks.sh post-yva) ────────

kill -TERM -- "-$WATCHDOG_PID" 2>/dev/null || kill -TERM "$WATCHDOG_PID" 2>/dev/null || true
for _ in 1 2; do
  kill -0 "$WATCHDOG_PID" 2>/dev/null || break
  sleep 1
done
if kill -0 "$WATCHDOG_PID" 2>/dev/null; then
  kill -KILL -- "-$WATCHDOG_PID" 2>/dev/null || true
  kill -KILL "$WATCHDOG_PID" 2>/dev/null || true
fi
kill -TERM -- "-$TAIL_PID" 2>/dev/null || kill -TERM "$TAIL_PID" 2>/dev/null || true
sleep 1
kill -KILL -- "-$TAIL_PID" 2>/dev/null || true
kill -KILL "$TAIL_PID" 2>/dev/null || true
wait "$TAIL_PID" 2>/dev/null || true
wait "$WATCHDOG_PID" 2>/dev/null || true

# ── Assertions ───────────────────────────────────────────────────────────────

# Give the kernel a moment to reflect the kills.
sleep 0.5

LEAKED=$(ps -A -o pid,ppid,stat,command | awk -v m="$MARKER" '$0 !~ /awk/ && index($0, m){print}')
if [[ -n "$LEAKED" ]]; then
  echo "FAIL: marker-tagged process(es) survived the reap:"
  echo "$LEAKED" | sed 's/^/  /'
  # Clean up so we don't strand them
  echo "$LEAKED" | awk '{print $1}' | xargs -n1 kill -KILL 2>/dev/null
  fails=$((fails+1))
else
  echo "ok: no marker-tagged processes survived the PG-targeted reap"
fi

if kill -0 "$WATCHDOG_PID" 2>/dev/null; then
  echo "FAIL: WATCHDOG_PID $WATCHDOG_PID still alive after reap"
  kill -KILL "$WATCHDOG_PID" 2>/dev/null
  fails=$((fails+1))
else
  echo "ok: WATCHDOG_PID reaped"
fi

if kill -0 "$TAIL_PID" 2>/dev/null; then
  echo "FAIL: TAIL_PID $TAIL_PID still alive after reap"
  kill -KILL "$TAIL_PID" 2>/dev/null
  fails=$((fails+1))
else
  echo "ok: TAIL_PID reaped"
fi

exit "$fails"
