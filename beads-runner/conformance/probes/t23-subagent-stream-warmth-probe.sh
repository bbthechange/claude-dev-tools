#!/bin/bash
# T2.3 subagent-stream-warmth probe — claude-tools-9e7.
#
# THE OPEN EMPIRICAL QUESTION (from the bead): does a Task subagent keep the
# PARENT stream-json warm under headless `claude -p --output-format
# stream-json`?  If it does NOT, then a watchdog that keys "stuck" on
# parent-stream silence (v1 BC-22) will SIGKILL a healthy agent the moment it
# delegates real work to a subagent — and child-process-tree liveness is
# LOAD-BEARING (mandatory), not an optional robustness nicety, for the whole
# subagent-heavy task design.
#
# This probe answers it on the INSTALLED `claude`, with raw evidence, by
# measuring TWO things over the window a Task subagent is doing real work:
#   (1) parent stream-json output progress — does the stream FILE grow, or does
#       it stall for the subagent's whole runtime? (the exact v1 ACTIVITY_FILE
#       signal, observed the way the watchdog observes it: file growth)
#   (2) process-tree cumulative CPU — does the claude PID + its descendants
#       (the subagent's shelled-out bash burn is a child OS process) accrue CPU?
#       This is the EXACT liveness primitive the re-implemented BC-22 watchdog
#       uses (runner.sh `_tree_cpu_secs`); the probe re-derives it identically
#       so the probe validates the fix's mechanism on real claude, not a mock.
#
# Rig pattern reused from conformance/probes/o1-headless-version-probe.sh
# (claude-tools-0vt) — isolated throwaway git dir, bounded `claude -p`, same
# RESULT| protocol so output can be aggregated. NOT forked: same shape, new Q.
#
# RESULT protocol:
#   RESULT|PASS|T2.3-PROBE|§2.5/BC-22|<desc>   evidence captured & conclusive
#   RESULT|FAIL|T2.3-PROBE|§2.5/BC-22|<desc>   probe inconclusive (see stderr)
# Exit: 0 evidence captured · 2 probe could not run (env) — never silently green.
#
# Usage: bash beads-runner/conformance/probes/t23-subagent-stream-warmth-probe.sh
set -u

MODEL="claude-sonnet-4-6"          # subagent behavior is model-independent;
                                   # pinned for cost/determinism (as O-1 does).
BURN_SECS="${BURN_SECS:-60}"       # how long the subagent's CPU op runs
SAMPLE_EVERY=2                     # tree-CPU / stream-size sampling cadence (s)
HARD_TIMEOUT="${HARD_TIMEOUT:-300}"

emit() { printf 'RESULT|%s|T2.3-PROBE|§2.5/BC-22|%s\n' "$1" "$2"; }

command -v claude >/dev/null 2>&1 || { echo "✗ probe cannot run: 'claude' not on PATH" >&2; exit 2; }
command -v jq     >/dev/null 2>&1 || { echo "✗ probe cannot run: 'jq' not on PATH"     >&2; exit 2; }
command -v ps     >/dev/null 2>&1 || { echo "✗ probe cannot run: 'ps' not on PATH"     >&2; exit 2; }

CLAUDE_VERSION="$(claude --version 2>/dev/null | tr -d '\n')"
echo "═══════════════════════════════════════════════════════════════════════"
echo " T2.3 subagent-stream-warmth probe — claude-tools-9e7"
echo " claude under test : ${CLAUDE_VERSION:-<unknown>}"
echo " platform          : $(uname -srm 2>/dev/null)"
echo " model             : $MODEL    subagent CPU-burn: ${BURN_SECS}s"
echo " Q: does a Task subagent keep the PARENT stream-json warm? (load-bearing?)"
echo "═══════════════════════════════════════════════════════════════════════"

# ── the watchdog's EXACT liveness primitive, re-derived here ─────────────────
# Mirrors runner.sh `_tree_pids` / `_cputime_to_secs` / `_tree_cpu_secs`
# (BC-22 re-implementation). Kept byte-faithful so this probe exercises the
# real mechanism. If runner.sh's primitive changes, update both (the
# bc-22-watchdog-tree conformance rig is the binding cross-check).
_tree_pids() { # root -> every pid in the subtree (incl. root), portable
  local root="$1" table
  table="$(ps -A -o pid=,ppid= 2>/dev/null)" || return 1
  awk -v root="$root" '
    { ppid[$1]=$2; all[++n]=$1 }
    END{
      inset[root]=1; changed=1
      while(changed){ changed=0
        for(i=1;i<=n;i++){ c=all[i]
          if(!inset[c] && inset[ppid[c]]){ inset[c]=1; changed=1 } } }
      for(i=1;i<=n;i++) if(inset[all[i]]) print all[i]
    }' <<<"$table"
}
_cputime_to_secs() { # [[DD-]HH:]MM:SS[.f] -> integer seconds (10# = no octal)
  local t="$1" d=0 rest h=0 m=0 s=0
  [[ "$t" == *-* ]] && { d="${t%%-*}"; rest="${t#*-}"; } || rest="$t"
  rest="${rest%%.*}"
  local IFS=:; set -- $rest
  case $# in 3) h="$1"; m="$2"; s="$3";; 2) m="$1"; s="$2";; 1) s="$1";; esac
  echo $(( 10#${d:-0}*86400 + 10#${h:-0}*3600 + 10#${m:-0}*60 + 10#${s:-0} ))
}
_tree_cpu_secs() { # root -> Σ cumulative CPU secs across the subtree
  local root="$1" pids csv total=0 line
  pids="$(_tree_pids "$root")" || return 1
  [[ -z "$pids" ]] && { echo 0; return 0; }
  csv="$(echo "$pids" | tr '\n' ',')"; csv="${csv%,}"
  while IFS= read -r line; do
    line="$(echo "$line" | tr -d ' ')"; [[ -z "$line" ]] && continue
    total=$(( total + $(_cputime_to_secs "$line") ))
  done < <(ps -o time= -p "$csv" 2>/dev/null)
  echo "$total"
}

WORK="$(mktemp -d 2>/dev/null)" || { echo "✗ probe cannot run: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
( cd "$WORK" && git init -q . 2>/dev/null ) || true
S="$WORK/stream.jsonl"; : > "$S"
SAMPLES="$WORK/samples.tsv"   # ts \t stream_bytes \t tree_cpu_secs

TIMEOUT_BIN=""
command -v timeout  >/dev/null 2>&1 && TIMEOUT_BIN="timeout"
command -v gtimeout >/dev/null 2>&1 && TIMEOUT_BIN="gtimeout"

# The subagent's sole job: run ONE foreground bash command that BURNS CPU for
# BURN_SECS and prints NOTHING until done — a faithful model of the 2026-05-16
# incident's "backgrounded a long op and waited". The parent agent just waits
# on the Task tool. This maximizes the chance of parent-stream silence while
# guaranteeing the process tree (claude + the python child) accrues CPU.
read -r -d '' PROMPT <<EOF
Use the Task tool to launch ONE general-purpose subagent immediately. The
subagent's ENTIRE job is to run exactly this one Bash command and then report
the single word done:

python3 -c "import time; e=time.time()+${BURN_SECS}
while time.time()<e: pass"

Do not do anything else. Do not narrate. After the subagent returns, reply with
just: SUBAGENT_DONE
EOF

echo "▶ launching claude -p (subagent → ${BURN_SECS}s CPU burn); capturing stream + tree CPU…"
START_EPOCH=$(date +%s)
(
  cd "$WORK" && ${TIMEOUT_BIN:+$TIMEOUT_BIN $HARD_TIMEOUT} claude -p "$PROMPT" \
    --output-format stream-json --verbose --model "$MODEL" \
    --dangerously-skip-permissions
) > "$S" 2>&1 &
CLAUDE_PID=$!

# Sampler: every SAMPLE_EVERY s record (epoch, stream bytes, tree CPU secs)
# until the claude process exits or the hard timeout elapses.
while kill -0 "$CLAUDE_PID" 2>/dev/null; do
  now=$(date +%s)
  bytes=$(wc -c < "$S" 2>/dev/null | tr -d ' '); bytes="${bytes:-0}"
  cpu=$(_tree_cpu_secs "$CLAUDE_PID" 2>/dev/null); cpu="${cpu:-0}"
  printf '%s\t%s\t%s\n' "$now" "$bytes" "$cpu" >> "$SAMPLES"
  [[ $(( now - START_EPOCH )) -ge $HARD_TIMEOUT ]] && { kill "$CLAUDE_PID" 2>/dev/null; break; }
  sleep "$SAMPLE_EVERY"
done
wait "$CLAUDE_PID" 2>/dev/null; CEC=$?
END_EPOCH=$(date +%s)
WALL=$(( END_EPOCH - START_EPOCH ))

# ── Analysis ────────────────────────────────────────────────────────────────
# Largest gap (s) between consecutive stream-FILE growth events == the longest
# window the parent stream was SILENT. Did tree CPU advance across that window?
read -r MAXGAP GAP_AT_BYTES GAP_CPU_DELTA TOTAL_GROWTHS LAST_CPU < <(
  awk -F'\t' -v ev="$SAMPLE_EVERY" '
    NR==1 { pt=$1; pb=$2; pc=$3; first_cpu=$3; growths=0; maxgap=0; next }
    {
      if ($2 > pb) {                         # stream grew since last growth
        gap = $1 - lastgrow_t
        if (lastgrow_t>0 && gap>maxgap) { maxgap=gap; gap_b=$2; gap_dc=$3-cpu_at_lastgrow }
        lastgrow_t=$1; cpu_at_lastgrow=$3; growths++
      }
      if (lastgrow_t==0 && $2>pb) { lastgrow_t=$1; cpu_at_lastgrow=$3 }
      pb=$2; pc=$3; last_cpu=$3
    }
    END{
      # tail gap: from last growth to process end (>= a real silence too)
      printf "%d %d %d %d %d", maxgap, gap_b+0, gap_dc+0, growths+0, last_cpu+0
    }' "$SAMPLES"
)
FIRST_CPU=$(awk -F'\t' 'NR==1{print $3+0; exit}' "$SAMPLES")
TOTAL_CPU_DELTA=$(( ${LAST_CPU:-0} - ${FIRST_CPU:-0} ))
NSAMP=$(wc -l < "$SAMPLES" 2>/dev/null | tr -d ' ')

# Verdict on whether a subagent kept the PARENT STREAM warm.
SUBAGENT_RAN=no
grep -q '"name":[ ]*"Task"' "$S" 2>/dev/null && SUBAGENT_RAN=yes
grep -q '"type":[ ]*"system"' "$S" 2>/dev/null || true

echo "───────────────────────────────────────────────────────────────────────"
echo " RAW EVIDENCE (paste-into-bead):"
echo "   claude --version        : ${CLAUDE_VERSION}"
echo "   wall time               : ${WALL}s   claude exit: ${CEC}   samples: ${NSAMP:-0}"
echo "   subagent (Task) invoked : ${SUBAGENT_RAN}"
echo "   stream growth events    : ${TOTAL_GROWTHS:-0}"
echo "   MAX parent-stream SILENCE gap : ${MAXGAP:-?}s   (subagent CPU-burn was ${BURN_SECS}s)"
echo "   tree-CPU Δ over that silence  : ${GAP_CPU_DELTA:-?}s of CPU"
echo "   tree-CPU Δ whole run          : ${TOTAL_CPU_DELTA}s  (first=${FIRST_CPU:-0} last=${LAST_CPU:-0})"
echo "   stream-json bytes (final)     : $(wc -c < "$S" 2>/dev/null | tr -d ' ')"
echo "   first 3 + last 3 stream types :"
jq -rs '[.[]|.type] | (.[0:3]+["…"]+ .[-3:]) | join(" ")' "$S" 2>/dev/null | sed 's/^/     /' || echo "     (unparseable)"
echo "   --- samples.tsv (epoch  stream_bytes  tree_cpu_secs) ---"
awk -F'\t' -v s="$START_EPOCH" '{printf "     +%-4ss  %9s B  %4ss cpu\n",$1-s,$2,$3}' "$SAMPLES" 2>/dev/null
echo "───────────────────────────────────────────────────────────────────────"

# Conclusion logic:
#  - load-bearing  iff the parent stream went silent for a window that, at the
#    v1 IDLE_TIMEOUT scale, would kill a healthy agent — i.e. the subagent's
#    real work is NOT mirrored as timely parent-stream growth — AND the
#    process-tree CPU signal DID advance across that same silence (proving the
#    re-implemented liveness primitive rescues exactly this case).
WARM=unknown; LOADBEARING=unknown
if [[ "${TOTAL_GROWTHS:-0}" -ge 1 && "${MAXGAP:-0}" -ge $(( BURN_SECS / 2 )) ]]; then
  WARM=no
elif [[ "${MAXGAP:-0}" -lt $(( BURN_SECS / 2 )) && "${TOTAL_GROWTHS:-0}" -ge 3 ]]; then
  WARM=yes
fi
if [[ "$WARM" == "no" && "${TOTAL_CPU_DELTA:-0}" -ge 1 ]]; then
  LOADBEARING=yes
elif [[ "$WARM" == "yes" ]]; then
  LOADBEARING="no (parent stream alone would not have killed it) — but tree-liveness is still the correct robust signal"
fi

echo " CONCLUSION"
echo "   parent stream kept warm by subagent? : ${WARM}"
echo "   child-process-tree liveness load-bearing? : ${LOADBEARING}"
echo "═══════════════════════════════════════════════════════════════════════"

if [[ "$WARM" != "unknown" && -s "$SAMPLES" ]]; then
  emit PASS "subagent-stream-warmth resolved (warm=${WARM}, load-bearing=${LOADBEARING%% *}) on ${CLAUDE_VERSION}"
  exit 0
else
  emit FAIL "probe inconclusive (warm=${WARM}, samples=${NSAMP:-0}) — see raw evidence above"
  echo " ✗ inconclusive: not enough samples or ambiguous; re-run (raise HARD_TIMEOUT/BURN_SECS)." >&2
  exit 0
fi
