#!/bin/bash
# Conformance harness runner — T1a (claude-tools-ooc).
#
# Runs every assertion rig against the CURRENT beads-runner/run-beads-tasks.sh
# and prints a per-BC verdict. This is the shared regression gate the
# beads-runner overhaul (epic claude-tools-glk) binds to; T1b reuses this same
# framework for the coordinator/observability SCARs.
#
# RESULT protocol (see lib/harness.sh):
#   PASS          regression green — current script exhibits the SCAR
#   FAIL          regression broken (harness bug OR a real script regression)
#   GATE-PENDING  forward criterion not yet satisfiable on the CURRENT script —
#                 the LITERAL close-criterion T2/T3 must flip GREEN (expected
#                 here, pre-rewrite; does NOT fail the current-script verdict)
#   GATE-MET      forward criterion already satisfied (informational)
#
# EXIT-criterion-1 verdict (this runner's exit code):
#   0  iff  zero FAIL  AND  every GATE produced its documented pre-rewrite
#           state — i.e. the harness is proven correct against the frozen
#           current behavior and ready to gate the rewrite.
#   1  otherwise (a regression assertion failed → harness or script is wrong).
#
# Usage:
#   bash beads-runner/conformance/run-conformance.sh            # all
#   bash beads-runner/conformance/run-conformance.sh bc-21 bc-35 # subset (substr)
set -u

CONF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSERT_DIR="$CONF_DIR/assertions"
RESULTS="$(mktemp)"
RIGOUT="$(mktemp -d)"           # per-rig captured stdout/stderr + .done markers
trap 'rm -f "$RESULTS"; rm -rf "$RIGOUT"' EXIT

filter=("$@")
match() {
  [[ ${#filter[@]} -eq 0 ]] && return 0
  local f; for f in "${filter[@]}"; do [[ "$1" == *"$f"* ]] && return 0; done
  return 1
}

echo "═══════════════════════════════════════════════════════════════════════"
echo " beads-runner conformance harness — T1a (claude-tools-ooc)"
echo " target: $(cd "$CONF_DIR/.." && pwd)/run-beads-tasks.sh"
echo " binds : INTERFACE.md v1 §3, §7.1, §7.5, §8.1/§8.2 (terminal-reason /"
echo "         classification precedence) — assertions are the literal"
echo "         close-criteria T2/T3 cite by BC id."
echo " O-1   : AD3 §7.2/§7.6 backstops are version-pinned & live-claude — NOT"
echo "         in the offline rigs below. Re-run on every claude upgrade:"
echo "         bash $CONF_DIR/probes/o1-headless-version-probe.sh"
echo "═══════════════════════════════════════════════════════════════════════"

# ── bounded-PARALLEL rig execution (claude-tools-91pi) ───────────────────────
# The BC rigs are hermetic: harness.sh:H_init_test gives each its own mktemp
# WORKDIR + BD_STORE + isolated daemon/XDG caches, and `bd`/`claude` are FAKES on
# FAKE_BIN with NO shared server, port, or lock (the fake `bd` is a per-WORKDIR
# file store — there is no Dolt sql-server in this tier). So they parallelize
# cleanly; only CPU is shared. We run up to $JOBS at once, capture each rig's
# stdout/stderr to a per-rig file, then REPLAY the captures in deterministic GLOB
# ORDER. The tally, the per-BC rollup, and the printed blocks are therefore
# identical regardless of completion order — only wall-clock shrinks (the serial
# loop made the conformance tier the entire ~14-min long-pole of run-tests.sh).
#
# Concurrency is a FILE-MARKER pool (each rig's subshell drops $base.done as its
# last act), NOT a `kill -0`/`wait -n` pool: macOS /bin/bash is 3.2 (no `wait -n`),
# and a `kill -0` liveness check counts a not-yet-reaped zombie child as "alive",
# which would wedge the pool. Counting .done markers sidesteps both and stays
# 3.2-clean with no util-linux-only deps.

# resolve concurrency: cores-2, floor 1; CONFORMANCE_JOBS overrides (tests/CI/serial repro).
_ncpu="$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
case "$_ncpu" in *[!0-9]*|"") _ncpu=4 ;; esac
JOBS="${CONFORMANCE_JOBS:-$((_ncpu-2))}"
case "$JOBS" in *[!0-9]*|"") JOBS=1 ;; esac
[[ "$JOBS" -lt 1 ]] && JOBS=1

# DELIBERATELY NOT scaling the harness wall-clock backstops (claude-tools-91pi).
# Loosening wait_runner_exit / RUN_TIMEOUT to absorb parallel CPU load masks a
# genuinely hung runner AND still flaked ~1-in-5 in testing. Instead the handful
# of timing-fragile rigs (those that signal the LIVE runner mid-task and assert
# its teardown within a fixed wall-clock bound) are QUARANTINED to a serial lane
# below — they run alone on the drained machine, exactly as the old serial loop
# did, so the fixed backstops stay correct and never fire on slow-but-correct work.

# discover rigs in GLOB ORDER, honoring the substring filter. Partition into the
# PARALLEL lane (default) and a SERIAL lane (claude-tools-91pi): a rig self-declares
# serial with a `# conformance-lane: serial` marker. The serial lane holds the
# timing-fragile rigs that signal the LIVE runner mid-task and assert its teardown
# completes within a fixed wall-clock backstop (bc-35/36 wait_runner_exit, bc-05
# idle-drain `waited<=20`). Those are green ALONE but flake ~1-in-5 under the
# parallel lane's CPU oversubscription, so they run sequentially on the drained
# machine AFTER the parallel batch. New rigs auto-enroll PARALLEL (glob discovery
# preserved); a fragile rig opts into serial with the one-line marker.
rigs=(); parallel_rigs=(); serial_rigs=()
for rig in "$ASSERT_DIR"/bc-*.sh; do
  base="$(basename "$rig" .sh)"
  match "$base" || continue
  rigs+=("$rig")
  if grep -qiE '^#[[:space:]]*conformance-lane:[[:space:]]*serial' "$rig"; then
    serial_rigs+=("$rig")
  else
    parallel_rigs+=("$rig")
  fi
done
ran=${#rigs[@]}
if [[ $ran -eq 0 ]]; then
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════"
  echo " no rigs matched filter: ${filter[*]:-<none>}"
  exit 1
fi
echo " concurrency: $JOBS job(s) over ${#parallel_rigs[@]} parallel + ${#serial_rigs[@]} serial rig(s) (cores=$_ncpu, total=$ran)"

# count completed rigs by their .done markers (0 when none match).
_done_count() { ls "$RIGOUT"/*.done 2>/dev/null | wc -l | tr -d ' '; }

# JOB CONTROL (`set -m`) for the parallel lane: a command backgrounded with `&`
# from a shell WITHOUT job control is an "asynchronous list" — POSIX requires its
# SIGINT/SIGQUIT to be set to IGNORED, and a signal ignored at shell entry CANNOT
# be trapped or reset. Enabling job control puts each `( … ) &` in its own process
# group and exempts it from that rule, so any runner a parallel rig spawns inherits
# a DEFAULT (trappable) SIGINT. The rigs that actually depend on this (BC-35/36's
# `kill -INT` interrupt-cleanup) are quarantined to the serial lane, where they run
# as foreground commands and get the same trappable disposition for free — so this
# is now defensive for the parallel lane, kept so a future signal-sensitive rig
# isn't silently broken by the async-list ignore rule.
set -m
launched=0
_nparallel=${#parallel_rigs[@]}
for rig in "${parallel_rigs[@]}"; do
  # throttle: block until in-flight (launched - completed) < JOBS.
  while :; do
    d="$(_done_count)"
    [[ $((launched - d)) -lt $JOBS ]] && break
    sleep 0.2
  done
  base="$(basename "$rig" .sh)"
  # Each rig prints RESULT|… on stdout, diagnostics on stderr; the trailing
  # `: > .done` runs after the rig returns (any exit code), marking the slot free.
  ( bash "$rig" > "$RIGOUT/$base.out" 2> "$RIGOUT/$base.err"; : > "$RIGOUT/$base.done" ) &
  launched=$((launched+1))
  printf '   … launched %-34s (%d/%d)\n' "$base" "$launched" "$_nparallel" >&2
done

# drain: wait for every marker, printing on each change so the watchdog sees life.
_last=-1
while :; do
  d="$(_done_count)"
  if [[ "$d" != "$_last" ]]; then printf '   … %d/%d parallel rigs complete\n' "$d" "$_nparallel" >&2; _last="$d"; fi
  [[ "$d" -ge "$launched" ]] && break
  sleep 0.5
done
wait 2>/dev/null || true        # reap parallel subshells (markers already written)
set +m                          # job control no longer needed (parallel launch over)

# ── SERIAL LANE (claude-tools-91pi) ──────────────────────────────────────────
# The timing-fragile rigs run ONE AT A TIME on the now-drained machine — no CPU
# contention, so their signal-teardown wall-clock behaves exactly as it does when
# the rig is run standalone (where it is green). Plain foreground execution is the
# faithful reproduction of a standalone `bash rig` run: it inherits the gate's
# normal INT/HUP disposition, so the runner's interrupt trap is trappable just as
# in a real (worker-driven) gate invocation. Captured to the same per-rig files so
# the deterministic replay below treats parallel and serial rigs alike.
for rig in "${serial_rigs[@]}"; do
  base="$(basename "$rig" .sh)"
  printf '   … serial   %-34s (serial lane, %d rig(s))\n' "$base" "${#serial_rigs[@]}" >&2
  bash "$rig" > "$RIGOUT/$base.out" 2> "$RIGOUT/$base.err"
  : > "$RIGOUT/$base.done"
done

# REPLAY captures in deterministic glob order: header, indented stderr, then the
# formatted RESULT icons — byte-identical output to the old serial loop.
for rig in "${rigs[@]}"; do
  base="$(basename "$rig" .sh)"
  echo ""
  echo "▶ $base"
  [[ -s "$RIGOUT/$base.err" ]] && sed 's/^/    /' "$RIGOUT/$base.err" >&2
  # Determinism guard: a rig that emitted NO RESULT line crashed or was killed
  # (e.g. starved under load). Make that a NAMED red, never a silent coverage
  # drop — a missing rig must turn the tier RED, not quietly shrink the tally.
  if ! grep -q '^RESULT|' "$RIGOUT/$base.out" 2>/dev/null; then
    echo "RESULT|FAIL|$base|-|rig produced no RESULT line (crashed or killed)" >> "$RESULTS"
    printf '   %s %-9s %-7s %s\n' "✗ FAIL       " "$base" "-" "rig produced no RESULT line"
    continue
  fi
  tee -a "$RESULTS" < "$RIGOUT/$base.out" \
    | while IFS='|' read -r tag status bc cite desc; do
        [[ "$tag" == RESULT ]] || continue
        case "$status" in
          PASS)         icon="✓ PASS       " ;;
          FAIL)         icon="✗ FAIL       " ;;
          GATE-PENDING) icon="◌ GATE(pend) " ;;
          GATE-MET)     icon="◑ GATE(met)  " ;;
          *)            icon="? $status " ;;
        esac
        printf '   %s %-9s %-7s %s\n' "$icon" "$bc" "$cite" "$desc"
      done
done

echo ""
echo "═══════════════════════════════════════════════════════════════════════"
pass=$(grep -c '^RESULT|PASS|'         "$RESULTS" || true)
fail=$(grep -c '^RESULT|FAIL|'         "$RESULTS" || true)
gpen=$(grep -c '^RESULT|GATE-PENDING|' "$RESULTS" || true)
gmet=$(grep -c '^RESULT|GATE-MET|'     "$RESULTS" || true)

echo " Summary:  PASS=$pass  FAIL=$fail  GATE-PENDING=$gpen  GATE-MET=$gmet"
echo ""

# Per-BC rollup (a BC is GREEN iff it has ≥1 PASS and 0 FAIL).
echo " Per-BC regression rollup:"
awk -F'|' '
  $1=="RESULT"{
    bc=$3;
    if(!(bc in seen)){ seen[bc]=1; order[++n]=bc }
    if($2=="PASS")       p[bc]++
    else if($2=="FAIL")  f[bc]++
    else if($2 ~ /^GATE/) g[bc]++
  }
  END{
    for(i=1;i<=n;i++){
      bc=order[i];
      st=(f[bc]>0?"RED   ":(p[bc]>0?"GREEN ":"gate  "));
      printf("   %-10s %s   (pass=%d fail=%d gate=%d)\n",bc,st,p[bc]+0,f[bc]+0,g[bc]+0)
    }
  }' "$RESULTS"

echo ""
if [[ "$fail" -eq 0 ]]; then
  echo " ✓ HARNESS GREEN — every regression assertion passes against the"
  echo "   current run-beads-tasks.sh; $gpen forward gate(s) correctly PENDING"
  echo "   (the literal close-criteria T2/T3 must flip to GREEN)."
  echo "═══════════════════════════════════════════════════════════════════════"
  exit 0
else
  echo " ✗ HARNESS RED — $fail regression assertion(s) failed. Either the"
  echo "   harness is wrong or run-beads-tasks.sh regressed a SCAR. Per"
  echo "   ANTI-DRIFT, a changed EXPECTED behavior escalates to"
  echo "   claude-tools-65z — never edit the assertion to make it pass."
  echo "═══════════════════════════════════════════════════════════════════════"
  exit 1
fi
