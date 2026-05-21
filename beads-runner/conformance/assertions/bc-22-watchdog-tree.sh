#!/bin/bash
# BC-22 — Idle watchdog, RE-IMPLEMENTED: liveness = agent+child-process-tree
#         progress (CPU or output), NOT parent-stream silence. (T2.3,
#         claude-tools-9e7.)
# Binds: INTERFACE.md v1 §2.5 (during-task cadence — the watchdog runs within
#        the per-task window) · BC-22 (snapshot-BEFORE-signal, staged
#        SIGINT→poll→SIGKILL, soft tier, WATCHDOG_KILL marker — PRESERVED).
#
# TARGET — the T2.3 watchdog lives in the forward rewrite target runner.sh
# (the T2.1 state-machine skeleton), NOT v1 run-beads-tasks.sh (which the
# untouched bc-22-watchdog.sh keeps regression-green). Same re-point pattern as
# bc-01-fresh-process.sh: reuse the T1a harness *library*, reassign $RUNNER
# only, zero edits to harness.sh or any T1a-owned rig.
#
# SCAR being asserted (two halves, two isolated runs):
#  A) MECHANISM PRESERVED (exit-criterion 1): a genuinely stuck agent — no
#     stream output, zero CPU, no children — IS still killed at IDLE_TIMEOUT
#     with the proc snapshot captured BEFORE the signal and a staged
#     SIGINT→grace→SIGKILL, and the runner survives and drains.
#  B) THE 2026-05-16 CORRECTION (exit-criterion 2): an agent whose PARENT
#     STREAM IS SILENT but whose child-process tree is making CPU progress is
#     NOT killed at IDLE_TIMEOUT (the empirically load-bearing case — see
#     conformance/probes/t23-subagent-stream-warmth-probe.sh).
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"

# Shared rig-local `claude` recorder factory. The harness fake-bin claude has
# no CPU-burn-child behavior and is T1a-owned; per the bc-01 precedent a rig
# may ship its own claude stub shadowing it via PATH (prepended AFTER
# H_init_test). $1 selects the scenario.
_install_rig_claude() { # mode=hang|busychild|inflight_subagent
  local mode="$1" RIG_BIN="$WORKDIR/.rigbin"
  mkdir -p "$RIG_BIN"
  cat > "$RIG_BIN/claude" <<REC
#!/bin/bash
set -u
for a in "\$@"; do [[ "\$a" == "--version" ]] && { echo "rig claude 0.0.0"; exit 0; }; done
prompt=""; i=1
for a in "\$@"; do
  if [[ "\$a" == "-p" ]]; then eval "prompt=\\\${\$((i+1))}"; break; fi
  i=\$((i+1))
done
bead_id=\$(printf '%s' "\$prompt" | sed -n 's/.*beads issue \\([^ :]*\\):.*/\\1/p' | head -1)
n=\$(( \$(cat "\$HARNESS_OUT/claude-n" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "\$HARNESS_OUT/claude-n"

if [[ "$mode" == "hang" ]]; then
  if [[ "\$n" -eq 1 ]]; then
    # Genuinely stuck: NOTHING to the stream (parent-silent), zero CPU, no
    # children. \`exec\` so the watchdog's staged kill lands on this sleep
    # directly (SIGINT is SIG_IGN under POSIX async-background — exactly a
    # hard-wedged agent; SIGKILL ~10s later is the terminator). MUST be killed.
    exec sleep "\${WD_HANG:-86400}"
  fi
  # The retry after the watchdog kill: succeed so the queue drains and the
  # runner reaches its BC-21 exit-0 terminal (BC-24 "kill then retry" shape).
  [[ -n "\$bead_id" ]] && bd close "\$bead_id" >/dev/null 2>&1
  echo '{"type":"result","result":"recovered on retry","is_error":false,"stop_reason":"end_turn"}'
  exit 0
fi

if [[ "$mode" == "inflight_subagent" ]]; then
  # claude-tools-idg repro: a Task subagent is in-flight per the stream
  # (task_notification status=in_progress) but the PARENT stream then goes
  # byte-silent AND there is no CPU/child progress in the tree — the exact
  # shape that fooled the pre-fix watchdog into killing a legitimate long
  # subagent. Post-fix: while inflight>0, threshold is stretched to
  # IDLE_TIMEOUT × IDLE_TIMEOUT_INFLIGHT_MULT, so this MUST drain cleanly.
  echo '{"type":"system","subtype":"task_notification","task_id":"sub1","status":"in_progress","summary":"long subagent"}'
  sleep "\${WD_INFLIGHT:-22}"
  echo '{"type":"system","subtype":"task_updated","task_id":"sub1","patch":{"status":"completed"}}'
  [[ -n "\$bead_id" ]] && bd close "\$bead_id" >/dev/null 2>&1
  echo '{"type":"result","result":"subagent completed","is_error":false,"stop_reason":"end_turn"}'
  exit 0
fi

# mode=busychild — THE 2026-05-16 repro. Emit NOTHING to stdout/stderr (the
# parent stream stays byte-frozen, exactly the incident) but spawn a real
# CPU-burn CHILD process (a descendant of this claude pid). It accrues CPU
# across the watchdog's poll, so child-tree liveness must keep the agent ALIVE
# even though the parent stream never grows. Then finish cleanly.
bash -c 'while :; do :; done' &
BURN=\$!
for _ in \$(seq 1 "\${WD_BURN:-22}"); do sleep 1; done
kill "\$BURN" 2>/dev/null || true
wait "\$BURN" 2>/dev/null || true
[[ -n "\$bead_id" ]] && bd close "\$bead_id" >/dev/null 2>&1
exit 0
REC
  chmod +x "$RIG_BIN/claude"
  export PATH="$RIG_BIN:$PATH"
  # §2.5 control/heartbeat boundaries pushed far away (irrelevant to BC-22);
  # the watchdog poll cadence (15s) + soft tier (180s) are HARDCODED SCARs in
  # runner.sh and deliberately NOT tunable here — same stance as v1 bc-22.
  export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
         RECLAIM_POLL_INTERVAL=1 IDLE_TIMEOUT=1
}

# ── A · stuck (no tree progress) ⇒ killed; mechanism preserved ───────────────
bc22tree_stuck() {
  H_init_test "bc22tree-stuck"
  _install_rig_claude hang
  bd_seed wd0 "hangs with no tree progress" "no stream, zero CPU, no children"
  export WD_HANG=120          # must outlast first poll(≤15s)+snapshot+10s grace
  RUN_TIMEOUT=70 run_runner   # ~25-30s wall, RUN_TIMEOUT parity with v1 bc-22

  local ld="$WORKDIR/.beads/runner-logs" o; o="$(out)"
  _expect "BC-22" "§2.5" "stuck (no CPU/output progress in the tree) ⇒ WATCHDOG_KILL, snapshot-before-signal, staged kill, runner drains"
  _need "watchdog kill message printed"            matches "$o" "Killing after .* idle"
  _need "kill keyed on child-tree progress signal" matches "$o" "child-process tree"
  _need "proc snapshot retained"                   file_glob "$ld"/*.proc.txt
  _need "snapshot has ps section (captured pre-signal)" \
        bash -c 'grep -ql "=== ps" "'"$ld"'"/*.proc.txt 2>/dev/null'
  _need "snapshot has lsof section" \
        bash -c 'grep -ql "=== lsof" "'"$ld"'"/*.proc.txt 2>/dev/null'
  _need "snapshot captured a live pid row (ⓘ ps ran BEFORE the kill)" \
        bash -c 'grep -Eq "[0-9]+ +[0-9]+ +[A-Z]" "'"$ld"'"/*.proc.txt 2>/dev/null'
  _need "staged kill announced"                    matches "$o" "staged kill"
  _need "SIGINT actually sent"                     matches "$o" "watchdog: SIGINT sent"
  _need "SIGKILL actually sent after grace"        matches "$o" "watchdog: SIGKILL sent"
  _need "SIGINT precedes SIGKILL (staged ordering)" \
        line_before "watchdog: SIGINT sent" "watchdog: SIGKILL sent" "$HARNESS_OUT/runner.out"
  _need "runner survived the kill and drained exit 0" test "${RUN_EXIT:-1}" -eq 0
  _need "queue drained (retry after kill closed the bead)" \
        bash -c 'grep -q "no ready tasks" "'"$HARNESS_OUT"'/runner.out"'
  _emit
  H_cleanup
}

# ── B · parent-stream silent + child CPU progress ⇒ NOT killed (the fix) ─────
bc22tree_busychild() {
  H_init_test "bc22tree-busychild"
  _install_rig_claude busychild
  export WD_BURN=22           # child burns CPU across ≥1 watchdog poll (15s)
  bd_seed wd1 "busy child, silent parent" "spawns a CPU-burn child; emits no stream"
  RUN_TIMEOUT=70 run_runner

  local ld="$WORKDIR/.beads/runner-logs" o; o="$(out)"
  _expect "BC-22" "§2.5" "2026-05-16 repro: parent stream silent but child tree making CPU progress ⇒ NOT killed at IDLE_TIMEOUT"
  _need "watchdog did NOT print a kill"          notcontains "$o" "Killing after"
  _need "no proc snapshot written (watchdog never fired)" \
        bash -c '! ls "'"$ld"'"/*.proc.txt >/dev/null 2>&1'
  _need "healthy agent completed its work"       test "$(bd_status wd1)" = closed
  _need "runner drained exit 0 (not SIGKILLed mid-task)" test "${RUN_EXIT:-1}" -eq 0
  _emit
  H_cleanup
}

# ── C · parent silent + tree CPU-idle BUT Task subagent in-flight ⇒ NOT killed
#       (claude-tools-idg). With IDLE_TIMEOUT=1 the pre-fix watchdog kills at
#       the next 15s poll; the fix stretches by IDLE_TIMEOUT_INFLIGHT_MULT
#       while ≥1 task is in-flight so a legitimate 22s subagent survives. ─────
bc22tree_inflight_subagent() {
  H_init_test "bc22tree-inflight-subagent"
  _install_rig_claude inflight_subagent
  # 22s subagent ≫ IDLE_TIMEOUT=1; MULT=60 ⇒ effective 60s ≫ 22s ⇒ survives.
  export WD_INFLIGHT=22 IDLE_TIMEOUT_INFLIGHT_MULT=60
  bd_seed wd2 "subagent in-flight, parent stream + tree silent" \
              "emits task_notification then sleeps with no children"
  RUN_TIMEOUT=70 run_runner

  local ld="$WORKDIR/.beads/runner-logs" o; o="$(out)"
  _expect "BC-22" "§2.5" "claude-tools-idg: in-flight Task subagent stretches IDLE_TIMEOUT × MULT — legitimate long subagent NOT killed"
  _need "watchdog did NOT print a kill"          notcontains "$o" "Killing after"
  _need "no proc snapshot written (watchdog never fired)" \
        bash -c '! ls "'"$ld"'"/*.proc.txt >/dev/null 2>&1'
  _need "subagent completed and bead closed"     test "$(bd_status wd2)" = closed
  _need "runner drained exit 0 (not SIGKILLed mid-subagent)" test "${RUN_EXIT:-1}" -eq 0
  _emit
  H_cleanup
}

bc22tree_stuck
bc22tree_busychild
bc22tree_inflight_subagent
