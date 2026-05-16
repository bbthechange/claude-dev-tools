#!/bin/bash
# BC-01 — Fresh process + fresh context per task.
# Binds: INTERFACE.md v1 §1.2 (the runner PROCESS preserves BC-05/BC-21:
#        a drained `bd ready` exits 0) and §3 (the runner as caller of the six
#        jobs against the in-process NO-OP stubs).
# SCAR (the entire reason the runner exists): every task is executed by a
#        brand-new `claude -p` invocation; NO conversation/context/memory
#        carries between tasks; there is NO --continue/--resume; a retried
#        task starts from an empty window. A rewrite that pools/threads
#        context across tasks defeats the tool's purpose.
#
# TARGET — this rig binds to the T2.1 state-machine skeleton (runner.sh), the
# forward rewrite target, NOT the characterized v1 `run-beads-tasks.sh` (which
# every OTHER rig regression-tests, untouched by T2.1). It reuses the T1a
# harness *library* (isolated workspace, fake `bd`, RESULT protocol) and only
# re-points $RUNNER — zero modification to any T1a-owned rig or to harness.sh.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

# Re-point the runner under test at the T2.1 skeleton. ($RUNNER is a plain
# harness.sh global referenced at spawn time by _spawn_runner; reassigning it
# here is the documented, side-effect-free way to target a different runner
# without touching the shared library.)
RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"

bc01_run() {
  H_init_test "bc01-fresh-process"

  # Rig-local `claude` recorder: shadows the harness fake-bin claude (PATH is
  # prepended AFTER H_init_test so this wins). Records, per invocation, its own
  # PID, full argv, and the -p prompt; then closes the bead so the loop drains.
  local RIG_BIN="$WORKDIR/.rigbin"
  mkdir -p "$RIG_BIN"
  cat > "$RIG_BIN/claude" <<'REC'
#!/bin/bash
set -u
for a in "$@"; do [[ "$a" == "--version" ]] && { echo "rig claude 0.0.0"; exit 0; }; done
prompt=""; i=1
for a in "$@"; do
  if [[ "$a" == "-p" ]]; then eval "prompt=\${$((i+1))}"; break; fi
  i=$((i+1))
done
bead_id=$(printf '%s' "$prompt" | sed -n 's/.*beads issue \([^ :]*\):.*/\1/p' | head -1)
n=$(( $(cat "$HARNESS_OUT/claude-n" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$HARNESS_OUT/claude-n"
echo "$$"           >> "$HARNESS_OUT/claude-pids"
printf '%s\n' "$*"  >> "$HARNESS_OUT/claude-argv"
printf '%s' "$prompt" > "$HARNESS_OUT/claude-prompt-$n.txt"
[[ -n "$bead_id" ]] && bd close "$bead_id" >/dev/null 2>&1
echo '{"type":"result","result":"done","is_error":false,"stop_reason":"end_turn"}'
exit 0
REC
  chmod +x "$RIG_BIN/claude"
  export PATH="$RIG_BIN:$PATH"

  # Fast, deterministic cadence (the §2.5 during-task poll boundaries are far
  # away so the fake worker — which exits immediately — never trips them).
  export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
         RECLAIM_POLL_INTERVAL=1
  export RUN_TIMEOUT=30

  # Two distinct ready tasks. Deterministic order (fake `bd ready` sorts by
  # attempts then id): bc01a then bc01b, then a genuine empty drain.
  bd_seed bc01a "alpha task" "do the alpha work"
  bd_seed bc01b "bravo task" "do the bravo work"

  run_runner

  local n pids upids
  n="$(cat "$HARNESS_OUT/claude-n" 2>/dev/null || echo 0)"
  pids="$(wc -l < "$HARNESS_OUT/claude-pids" 2>/dev/null | tr -d ' ')"
  upids="$(sort -u "$HARNESS_OUT/claude-pids" 2>/dev/null | grep -c . || echo 0)"

  _expect "BC-01" "§1.2/§3" "fresh distinct \`claude -p\` process + fresh context per task; no --continue/--resume; drains exit 0"
  # Both tasks ran, each in its own brand-new process (distinct PIDs).
  _need "two claude invocations (one per task)"        test "$n" -eq 2
  _need "two distinct claude PIDs (fresh process/task)" test "$upids" -eq 2
  # No context threading: BC-01's black-box observable is that NO recorded
  # invocation argv ever carried --continue/--resume (each task is a fresh,
  # un-threaded process — the second has zero knowledge of the first).
  _need "no --continue/--resume in any invocation argv" \
        bash -c '! grep -Eq -- "--continue|--resume" "'"$HARNESS_OUT"'/claude-argv"'
  # Fresh context: each prompt is built from scratch for its own task — task B
  # carries no knowledge of task A and vice-versa.
  _need "prompt 1 is about bc01a"          grep -q "beads issue bc01a:" "$HARNESS_OUT/claude-prompt-1.txt"
  _need "prompt 1 has no bc01b carryover"  bash -c '! grep -q "bc01b" "'"$HARNESS_OUT"'/claude-prompt-1.txt"'
  _need "prompt 2 is about bc01b"          grep -q "beads issue bc01b:" "$HARNESS_OUT/claude-prompt-2.txt"
  _need "prompt 2 has no bc01a carryover"  bash -c '! grep -q "bc01a" "'"$HARNESS_OUT"'/claude-prompt-2.txt"'
  # §1.2 / BC-05 / BC-21: a drained queue exits 0 (exit-0 ≠ stop the project).
  _need "drained run exits 0 (§1.2/BC-21)" test "${RUN_EXIT:-1}" -eq 0
  # The loop actually processed both beads to closed.
  _need "bc01a closed" test "$(bd_status bc01a)" = closed
  _need "bc01b closed" test "$(bd_status bc01b)" = closed
  _emit

  H_cleanup
}

bc01_run
