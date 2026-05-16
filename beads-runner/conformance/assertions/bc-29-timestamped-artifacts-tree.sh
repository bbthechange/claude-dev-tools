#!/bin/bash
# BC-29 (FORWARD) — Per-iteration timestamped artifact basenames prevent retry
#         collisions, in runner.sh. (T2.4, claude-tools-7hx.)
# Binds: INTERFACE.md v1 §8.2 (forensic/terminal artifacts around the
#        terminal-reason re-home — distinct post-mortems per attempt).
#
# TARGET — the BC-29 `<TASK_ID>-<ITER_TS>` basename scheme is THIS child's
# owned surface in the forward rewrite target runner.sh, NOT v1
# run-beads-tasks.sh (the untouched bc-29-timestamped-artifacts.sh keeps v1
# regression-green; that rig asserts SERVER_ERROR retention which is T2.2's
# classification surface — deliberately NOT depended on here, since
# classification is out of this child's scope). Same re-point precedent as
# bc-22-watchdog-tree.sh.
#
# SCAR being asserted (silent-when-wrong): without per-iteration timestamped
# basenames a 2nd attempt's preserved stream clobbers the 1st's — exactly when
# you most need both. The runner re-opens a not-closed task (§6.1 pairing) and
# re-attempts it; each attempt MUST write a distinct `<TASK_ID>-<ITER_TS>`
# basename inside the BC-27 self-gitignored log_dir (NOT a random mktemp).
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"

H_init_test bc29tree-distinct-basenames

# Rig-local `claude` (the bc-01/bc-22-tree precedent: a rig may ship its own
# claude shadowing the T1a fake-bin via PATH prepended AFTER H_init_test).
# Attempts 1 & 2: span ~2s (so the per-iteration UTC ITER_TS DIFFERS) and exit
# WITHOUT closing the bead ⇒ the runner's coarse outcome is NOT_CLOSED ⇒ §6.1
# lease-release returns it to `open` ⇒ it is re-picked. Attempt 3: close ⇒
# SUCCESS ⇒ the queue drains to the BC-21 exit-0 terminal.
RIG_BIN="$WORKDIR/.rigbin"
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
echo '{"type":"assistant","message":"working"}'
if [[ "$n" -le 2 ]]; then
  sleep 2                                  # span >1s ⇒ distinct ITER_TS
  echo '{"type":"result","result":"left open on purpose","is_error":false,"stop_reason":"end_turn"}'
  exit 0                                    # bead NOT closed ⇒ NOT_CLOSED
fi
[[ -n "$bead_id" ]] && bd close "$bead_id" >/dev/null 2>&1
echo '{"type":"result","result":"done","is_error":false,"stop_reason":"end_turn"}'
exit 0
REC
chmod +x "$RIG_BIN/claude"
export PATH="$RIG_BIN:$PATH"
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

bd_seed T1 "collides?" "x"
RUN_TIMEOUT=60 run_runner

ld="$WORKDIR/.beads/runner-logs"
streams=$(ls -1 "$ld"/T1-*.stream.jsonl 2>/dev/null | wc -l | tr -d ' ')
sigs=$(ls -1 "$ld"/T1-*.signal 2>/dev/null | wc -l | tr -d ' ')
# Distinct ITER_TS embedded in the stream basenames (collision ⇒ overwrite ⇒
# fewer distinct names than attempts; the SCAR is exactly that clobber).
distinct_ts=$(ls -1 "$ld"/T1-*.stream.jsonl 2>/dev/null \
  | sed -E 's#.*/T1-([0-9TZ]+)\.stream\.jsonl#\1#' | sort -u | grep -c . || echo 0)

_expect "BC-29" "§8.2" "same task re-attempted ⇒ distinct timestamped <TASK_ID>-<ITER_TS> artifacts, no collision (runner.sh)"
_need "queue drained exit 0 (BC-21 §8.1, FROZEN)"        test "${RUN_EXIT:-1}" -eq 0
_need "T1 eventually closed"                             test "$(bd_status T1)" = closed
_need "≥2 preserved stream files for T1 (got $streams)"  test "$streams" -ge 2
_need "≥2 preserved signal files for T1 (got $sigs)"     test "$sigs" -ge 2
_need "≥2 DISTINCT ITER_TS basenames (no clobber; got $distinct_ts)" test "$distinct_ts" -ge 2
_need "basenames embed <TASK_ID>-<ITER_TS> in the self-gitignored log_dir" \
      bash -c 'ls "'"$ld"'"/T1-*Z.stream.jsonl >/dev/null 2>&1 && test -f "'"$ld"'/.gitignore"'
_emit
H_cleanup
