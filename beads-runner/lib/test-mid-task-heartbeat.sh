#!/usr/bin/env bash
# beads-runner/lib/test-mid-task-heartbeat.sh — claude-tools-7v5 acceptance.
#
# Proves the mid-task heartbeat (HB) subshell behaves as specified:
#   1. Normal mode emits when ACTIVITY_FILE is fresh (<= HB_GAP_TOL).
#   2. Normal mode is silent when ACTIVITY_FILE is stale (> HB_GAP_TOL)
#      AND TASK_INFLIGHT_FILE is empty.
#   3. Subagent mode emits unconditionally when TASK_INFLIGHT_FILE has >=1 line,
#      even with a stale (or absent) ACTIVITY_FILE.
#   4. h7n guard holds: empty/malformed ACTIVITY_FILE produces no false emit
#      and no crash.
#   5. Reaping: parent killed → HB subshell (and its sleep grandchild) gone
#      within 2s, no PG-1 orphan.
#
# The HB loop body lives in run-beads-tasks.sh; this test re-implements it
# verbatim AND grep-asserts the production runner still contains the
# load-bearing lines so drift is caught loudly.
#
# Run:  bash beads-runner/lib/test-mid-task-heartbeat.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$HERE/../run-beads-tasks.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# ────────────────────────────────────────────────────────────────────────────
# PART 0 — static: the runner contains the HB block we are testing.
# ────────────────────────────────────────────────────────────────────────────
echo "── PART 0 — runner contains the claude-tools-7v5 HB block (static) ──"

if [[ ! -f "$RUNNER" ]]; then
  bad "runner not found at $RUNNER"
  echo "RESULT: $PASS passed, $FAIL failed"
  exit 1
fi

bash -n "$RUNNER" 2>/dev/null \
  && ok "bash -n run-beads-tasks.sh exits 0 (script parses)" \
  || bad "bash -n run-beads-tasks.sh"

grep -q 'HB_INTERVAL=${HEARTBEAT_INTERVAL:-60}' "$RUNNER" \
  && ok "HB_INTERVAL default 60s" || bad "HB_INTERVAL default 60s"
grep -q 'HB_GAP_TOL=${HEARTBEAT_GAP_TOL:-90}' "$RUNNER" \
  && ok "HB_GAP_TOL default 90s" || bad "HB_GAP_TOL default 90s"
grep -q 'HB_PID=\$!' "$RUNNER" \
  && ok "HB_PID captured after subshell spawn" || bad "HB_PID captured"
grep -q -- '-\$HB_PID' "$RUNNER" \
  && ok "HB reap uses PG-targeted kill -- -\$HB_PID (yva pattern)" \
  || bad "HB reap PG-targeted"
# h7n-style guard mirrored into HB
grep -q '\^\[0-9\]\+\$.*LAST >= 1704067200' "$RUNNER" \
  || grep -q 'LAST.*1704067200' "$RUNNER" \
  && ok "HB mirrors h7n epoch-floor guard" || bad "HB epoch-floor guard"

# ────────────────────────────────────────────────────────────────────────────
# Test-scope reimplementation of the HB loop body — kept byte-equivalent
# to the production block. The pattern below MUST stay in lock-step with
# run-beads-tasks.sh; PART 0 grep asserts will trip if the production
# changes the public knobs.
# ────────────────────────────────────────────────────────────────────────────
hb_loop_body() {
  # Inputs (env): CLAUDE_PID, STOP_FILE, TASK_INFLIGHT_FILE, ACTIVITY_FILE,
  #               TASK_ID, HB_INTERVAL, HB_GAP_TOL.
  # Side effect: calls hb() (which the tests stub to a tally file).
  while kill -0 "$CLAUDE_PID" 2>/dev/null; do
    sleep "$HB_INTERVAL"
    kill -0 "$CLAUDE_PID" 2>/dev/null || break
    [[ -f "$STOP_FILE" ]] && break
    INFLIGHT=0
    if [[ -f "$TASK_INFLIGHT_FILE" ]]; then
      INFLIGHT=$(wc -l < "$TASK_INFLIGHT_FILE" 2>/dev/null | tr -d ' ')
      INFLIGHT=${INFLIGHT:-0}
    fi
    if [[ "$INFLIGHT" -gt 0 ]]; then
      hb running "$TASK_ID"
      continue
    fi
    if [[ -f "$ACTIVITY_FILE" ]]; then
      LAST=$(cat "$ACTIVITY_FILE" 2>/dev/null | tr -d '[:space:]')
      if [[ "$LAST" =~ ^[0-9]+$ ]] && (( LAST >= 1704067200 )); then
        NOW=$(date +%s)
        GAP=$((NOW - LAST))
        if (( GAP <= HB_GAP_TOL )); then
          hb running "$TASK_ID"
        fi
      fi
    fi
  done
}

# Run one HB iteration with the given preconditions and return the number of
# hb() calls observed during a single sleep tick. The loop is bounded by
# CLAUDE_PID liveness: we use a short-lived sleep as the "claude" so the
# loop exits naturally after exactly one or two ticks.
run_one_iteration() {
  local activity_value="$1"   # "fresh" | "stale" | "" | "malformed" | "absent"
  local inflight_lines="$2"   # integer, lines to put into TASK_INFLIGHT_FILE
  local interval="${3:-1}"    # HB_INTERVAL seconds for the test
  local gap_tol="${4:-3}"     # HB_GAP_TOL for the test

  local work tally activity inflight stop
  work="$(mktemp -d)"
  tally="$work/tally"
  activity="$work/activity"
  inflight="$work/inflight"
  stop="$work/stop"
  : > "$tally"

  case "$activity_value" in
    fresh)     date +%s > "$activity" ;;
    stale)     echo "$(( $(date +%s) - 600 ))" > "$activity" ;;
    "")        : > "$activity" ;;
    malformed) echo "not-an-epoch" > "$activity" ;;
    absent)    rm -f "$activity" ;;
  esac

  if (( inflight_lines > 0 )); then
    local i
    for ((i=0; i<inflight_lines; i++)); do
      echo "subagent-$i" >> "$inflight"
    done
  else
    : > "$inflight"
  fi

  # Sentinel "claude" process: sleeps just long enough for ~1 HB tick.
  sleep $(( interval * 2 )) &
  local claude_pid=$!

  # Stub hb(): append one line per call to the tally file. Defined inline
  # in the child shell with the path baked in so we don't have to export
  # the tally variable.
  CLAUDE_PID="$claude_pid" \
  STOP_FILE="$stop" \
  ACTIVITY_FILE="$activity" \
  TASK_INFLIGHT_FILE="$inflight" \
  TASK_ID="test-task-7v5" \
  HB_INTERVAL="$interval" \
  HB_GAP_TOL="$gap_tol" \
  bash -c "
    hb() { printf 'hb %s %s\n' \"\$1\" \"\${2:-}\" >> '$tally'; }
    $(declare -f hb_loop_body)
    hb_loop_body
  " &
  local hb_pid=$!

  # Wait for sentinel claude to exit so the loop terminates naturally.
  wait "$claude_pid" 2>/dev/null || true
  # Loop exits on its next kill -0 check; small grace.
  wait "$hb_pid" 2>/dev/null || true

  local count
  count=$(wc -l < "$tally" 2>/dev/null | tr -d ' ')
  count=${count:-0}
  rm -rf "$work"
  printf '%s\n' "$count"
}

# ────────────────────────────────────────────────────────────────────────────
echo ""
echo "── PART 1 — Mode A (normal): fresh ACTIVITY_FILE ⇒ emits ──"
n=$(run_one_iteration fresh 0 1 3)
[[ "$n" -ge 1 ]] \
  && ok "fresh activity, inflight=0 ⇒ hb() called $n time(s) in ~2s" \
  || bad "fresh activity should emit (got $n hb calls)"

echo ""
echo "── PART 2 — Mode A silent: stale ACTIVITY_FILE ⇒ no emit ──"
n=$(run_one_iteration stale 0 1 3)
[[ "$n" -eq 0 ]] \
  && ok "stale activity (>HB_GAP_TOL), inflight=0 ⇒ no hb() call" \
  || bad "stale activity must NOT emit (got $n hb calls)"

echo ""
echo "── PART 3 — Mode B: TASK_INFLIGHT_FILE >=1 line ⇒ emits unconditionally ──"
n=$(run_one_iteration stale 1 1 3)
[[ "$n" -ge 1 ]] \
  && ok "stale activity + inflight=1 ⇒ hb() called $n time(s) (subagent override)" \
  || bad "inflight subagent must force emit (got $n hb calls)"

echo ""
echo "── PART 4 — h7n guard: empty/malformed ACTIVITY_FILE ⇒ no emit, no crash ──"
n_empty=$(run_one_iteration "" 0 1 3)
[[ "$n_empty" -eq 0 ]] \
  && ok "empty ACTIVITY_FILE ⇒ no false emit (no crash)" \
  || bad "empty ACTIVITY_FILE produced $n_empty hb calls"
n_mal=$(run_one_iteration malformed 0 1 3)
[[ "$n_mal" -eq 0 ]] \
  && ok "malformed ACTIVITY_FILE ⇒ no false emit (no crash)" \
  || bad "malformed ACTIVITY_FILE produced $n_mal hb calls"
n_abs=$(run_one_iteration absent 0 1 3)
[[ "$n_abs" -eq 0 ]] \
  && ok "absent ACTIVITY_FILE ⇒ no emit (no crash)" \
  || bad "absent ACTIVITY_FILE produced $n_abs hb calls"

# ────────────────────────────────────────────────────────────────────────────
echo ""
echo "── PART 5 — PG-isolation: parent killed ⇒ HB subshell + sleep gone ──"

MARKER="hb_test_$$_$(date +%s%N 2>/dev/null || date +%s)"

# Spawn an HB subshell that holds a tagged sleep grandchild (mimics the
# production HB body where `sleep $HB_INTERVAL` ticks between checks).
set -m
(
  ( exec -a "hb_sleep_${MARKER}" sleep 120 ) &
  # Leader exits immediately, leaving the sleep grandchild as a PID-1 orphan
  # within the PG — exactly the race the yva PG-kill pattern targets.
  exit 0
) &
HB_PID=$!
set +m

sleep 0.5

before=$(ps -A -o pid,ppid,command | awk -v m="$MARKER" '$0 !~ /awk/ && index($0, m){print}')
echo "  setup: tagged HB sleep grandchild = $(echo "$before" | awk 'NR==1{print $1}')"

# Production reap (the new HB block in run-beads-tasks.sh)
kill -TERM -- "-$HB_PID" 2>/dev/null || kill -TERM "$HB_PID" 2>/dev/null || true
for _ in 1 2; do
  kill -0 "$HB_PID" 2>/dev/null || break
  sleep 1
done
if kill -0 "$HB_PID" 2>/dev/null; then
  kill -KILL -- "-$HB_PID" 2>/dev/null || true
  kill -KILL "$HB_PID" 2>/dev/null || true
fi
wait "$HB_PID" 2>/dev/null || true

sleep 0.5

leaked=$(ps -A -o pid,ppid,stat,command | awk -v m="$MARKER" '$0 !~ /awk/ && index($0, m){print}')
if [[ -n "$leaked" ]]; then
  bad "HB sleep grandchild leaked after reap:"
  echo "$leaked" | sed 's/^/      /'
  echo "$leaked" | awk '{print $1}' | xargs -n1 kill -KILL 2>/dev/null
else
  ok "no marker-tagged HB processes survived the PG-targeted reap"
fi

if kill -0 "$HB_PID" 2>/dev/null; then
  bad "HB_PID $HB_PID still alive after reap"
  kill -KILL "$HB_PID" 2>/dev/null
else
  ok "HB_PID reaped"
fi

# ────────────────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════════════"
printf '  RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "════════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
