#!/usr/bin/env bash
# beads-runner/test-bd-ready-ordering.sh — empirically pin `bd ready` ordering.
# Originating task: claude-tools-7my (runner-reliability residual at claude-tools-1yt close).
#
# WHAT THIS ASSERTS — about the REAL bd binary on PATH, against the LIVE workspace:
#
#   1. Priority sort is ascending — for any two beads in `bd ready --json`,
#      the bead with the numerically-lower priority appears first (P0 < P1 < ...).
#      This is the assumption the ah8/R5 priority-band workaround was built on
#      and the assumption that shielded the entire ir7 subtree from
#      autonomous-runner mishandling. It has never been empirically verified.
#
#   2. Order is DETERMINISTIC across repeated invocations — N back-to-back
#      `bd ready --json` calls return the same sequence. If determinism fails,
#      a runner that pulls `next_task` from the head of the queue can flap
#      between candidates and burn SKIP_BACKOFF cycles without progress.
#
#   3. The within-priority tiebreak is OBSERVED and REPORTED — the script
#      prints the inferred tiebreak (created-at-desc / created-at-asc / id /
#      none) but does NOT enforce one. The bd CLI documents `--sort
#      priority|hybrid|oldest`; this script pins what `priority` (default)
#      actually does in practice.
#
# WHY NOT A FAKE bd — the question this answers is empirical about the real
# binary. test-bd-stage.sh / test-gate-defer.sh / test-defer-cascade-audit.sh
# use stateful fakes because they test the LOGIC OF A HELPER SCRIPT; this
# script tests the CONTRACT OF bd ITSELF. A fake would tautologically pass.
#
# SAFETY — runs against the LIVE workspace. To keep the autonomous runner from
# burning cycles on the test fixtures:
#   • Test beads are created at P4 (lowest priority) so they sort BELOW
#     anything currently in `bd ready` and never become the runner's
#     `next_task` head.
#   • Test beads carry the `human-triage` label so even if everything else
#     drains and they DO surface at the head, validate_task() refuses to
#     claim them (runner-NO-CLAIM gate, run-beads-tasks.sh:626).
#   • Test beads carry a unique fixture label TEST_LABEL and the script
#     scopes every `bd ready` query with `--label "$TEST_LABEL"` so the
#     ordering inspection ignores anything else in the workspace.
#   • Cleanup is unconditional via an EXIT trap; a Ctrl-C mid-run still
#     deletes the fixtures.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

FAILED=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; FAILED=1; }
info() { printf '  INFO  %s\n' "$*"; }

command -v bd >/dev/null 2>&1 || { echo "test-bd-ready-ordering.sh: reject — bd not on PATH" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "test-bd-ready-ordering.sh: reject — jq not on PATH" >&2; exit 2; }

TEST_LABEL="test-bd-ready-ordering-$$"
CREATED_IDS=()

cleanup() {
  if [[ ${#CREATED_IDS[@]} -gt 0 ]]; then
    for id in "${CREATED_IDS[@]}"; do
      bd delete "$id" --force >/dev/null 2>&1 || true
    done
  fi
}
trap cleanup EXIT INT TERM

# ── startup self-heal (claude-tools-fxsweep) ─────────────────────────────────
# The EXIT/INT/TERM trap above does NOT fire on SIGKILL, and the runner watchdog
# kills stuck workers with `kill -9` — so a prior run killed mid-flight leaks its
# fixtures permanently. Delete any such orphans BEFORE we seed (idempotent; the
# current run's own per-PID label has no beads yet, so this only catches prior
# orphans). The sweep matches the real .labels array via jq — bd's
# --label-pattern/--label-regex are no-ops in this binary (full doc in the helper).
# Guarded like the run-tests.sh call site: the sweep is auxiliary self-heal, so a
# missing/broken helper must degrade to a no-op rather than abort the ordering
# contract test (the helper's "a sweep failure can NEVER fail its caller" promise).
# shellcheck source=lib/sweep-fixtures.sh
. "$SCRIPT_DIR/lib/sweep-fixtures.sh" 2>/dev/null || true
if command -v sweep_fixtures >/dev/null 2>&1; then
  _swept="$(sweep_fixtures)"
  [[ -n "$_swept" ]] && info "$_swept"
fi

# ── seed N beads at varied priority and varied created_at ────────────────────
# Order of creation matters — created_at is monotonically increasing across
# the loop, so we can read off which createdAt is "older" / "newer" from the
# CREATED_IDS array index.
#
# Priority pattern (index → priority): interleaved so neither
# created-at-asc nor created-at-desc accidentally matches priority-asc.
PRIORITIES=(2 3 1 2 3 1 2 3)
# Titles deliberately avoid the word "test" — bd has a heuristic warning
# (see `bd q` / `bd create` source) that nags about creating "test issues
# in production database" when titles look like fixtures. Harmless but it
# pollutes stdout. Keep the unique fixture label TEST_LABEL as the join key
# instead; titles are descriptive but generic.
TITLES=(
  "ordering-fixture: P2 first"
  "ordering-fixture: P3 second"
  "ordering-fixture: P1 third"
  "ordering-fixture: P2 fourth"
  "ordering-fixture: P3 fifth"
  "ordering-fixture: P1 sixth"
  "ordering-fixture: P2 seventh"
  "ordering-fixture: P3 eighth"
)

# NOTE on P0/P4 absence — we deliberately avoid P0 (the live runner treats
# P0 as critical/escalate and we do not want test fixtures triggering that
# even briefly) and avoid P4 here too, even though P4 would be "safer"
# bottom-of-queue, because P4 ties up against existing P4 beads in the
# workspace and we want the label filter — not the priority — to be the
# isolator. P1/P2/P3 give us three distinct bands to verify ordering across.

echo "Seeding ${#PRIORITIES[@]} beads with label '$TEST_LABEL' ..."
for i in "${!PRIORITIES[@]}"; do
  pri="${PRIORITIES[$i]}"
  title="${TITLES[$i]}"
  # Use `bd q` — it emits ONLY the bead id on success (no JSON wrapper, no
  # warning preface). Saves us from having to strip bd's heuristic
  # "test issue in production" advisory out of mixed stdout.
  id=$(bd q "$title" --priority="$pri" --type=task --labels="$TEST_LABEL,human-triage" 2>/dev/null \
       | tr -d '[:space:]')
  [[ -n "$id" ]] || { fail "bd q returned no id at index $i"; exit 1; }
  CREATED_IDS+=("$id")

  # Labels were attached via `bd q --labels=...` at create time.

  # A small sleep between creates so created_at timestamps differ — bd's
  # created_at has second-level resolution; without this beads share a
  # timestamp and any created-at-based tiebreak collapses to a secondary
  # rule we cannot observe.
  sleep 1.1
done

info "Seeded ids in creation order (oldest → newest):"
for i in "${!CREATED_IDS[@]}"; do
  info "  [$i] ${CREATED_IDS[$i]} P${PRIORITIES[$i]}"
done

# ── capture N back-to-back `bd ready` snapshots ──────────────────────────────
N_RUNS=5
SNAPSHOTS=()

for run in $(seq 1 "$N_RUNS"); do
  snap=$(bd ready --label "$TEST_LABEL" --limit 50 --json 2>/dev/null \
         | jq -r '.[] | "\(.id)|\(.priority)|\(.created_at)"' 2>/dev/null) || {
    fail "bd ready --label $TEST_LABEL failed on run $run"
    exit 1
  }
  SNAPSHOTS+=("$snap")
done

# ── ASSERT 1: each snapshot is priority-ascending ────────────────────────────
for run in $(seq 1 "$N_RUNS"); do
  snap="${SNAPSHOTS[$((run-1))]}"
  prev_pri=-1
  ok=1
  while IFS='|' read -r id pri _; do
    [[ -z "$id" ]] && continue
    if (( pri < prev_pri )); then
      ok=0
      fail "run $run: priority sort violation — $id P$pri followed a P$prev_pri (priority is not ascending)"
      break
    fi
    prev_pri=$pri
  done <<< "$snap"
  [[ "$ok" == "1" ]] && pass "run $run: priority is ascending"
done

# ── ASSERT 2: every snapshot is identical (deterministic) ────────────────────
first="${SNAPSHOTS[0]}"
all_same=1
for run in $(seq 2 "$N_RUNS"); do
  if [[ "${SNAPSHOTS[$((run-1))]}" != "$first" ]]; then
    all_same=0
    fail "run $run differs from run 1 — order is NOT deterministic across calls"
    info "run 1:"; printf '%s\n' "$first" | sed 's/^/        /'
    info "run $run:"; printf '%s\n' "${SNAPSHOTS[$((run-1))]}" | sed 's/^/        /'
    break
  fi
done
[[ "$all_same" == "1" ]] && pass "all $N_RUNS runs return identical ordering (deterministic)"

# ── REPORT the observed tiebreak ─────────────────────────────────────────────
# For each priority band that contains >1 bead in our fixture set, check the
# observed creation-time direction of consecutive same-priority beads.
info "Observed ordering (run 1):"
printf '%s\n' "$first" | sed 's/^/        /'

declare -a P1_IDS=() P2_IDS=() P3_IDS=()
while IFS='|' read -r id pri _; do
  [[ -z "$id" ]] && continue
  case "$pri" in
    1) P1_IDS+=("$id");;
    2) P2_IDS+=("$id");;
    3) P3_IDS+=("$id");;
  esac
done <<< "$first"

# CREATED_IDS array index = creation rank (lower index = older).
rank_of() {
  local needle="$1"
  for i in "${!CREATED_IDS[@]}"; do
    [[ "${CREATED_IDS[$i]}" == "$needle" ]] && { echo "$i"; return; }
  done
  echo "-1"
}

infer_band_direction() {
  local band_name="$1"; shift
  local ids=("$@")
  [[ ${#ids[@]} -lt 2 ]] && { info "band $band_name: only ${#ids[@]} bead — cannot infer tiebreak"; return; }
  local prev_rank=-1 dir="" inconsistent=0
  for id in "${ids[@]}"; do
    local r; r=$(rank_of "$id")
    if (( prev_rank >= 0 )); then
      if (( r < prev_rank )); then
        # observed bead is OLDER than previous → newer-first
        [[ -z "$dir" ]] && dir="newest-first (created-at desc)"
        [[ "$dir" == "newest-first (created-at desc)" ]] || inconsistent=1
      elif (( r > prev_rank )); then
        [[ -z "$dir" ]] && dir="oldest-first (created-at asc)"
        [[ "$dir" == "oldest-first (created-at asc)" ]] || inconsistent=1
      fi
    fi
    prev_rank=$r
  done
  if (( inconsistent )); then
    info "band $band_name: tiebreak direction is INCONSISTENT within the band"
  elif [[ -z "$dir" ]]; then
    info "band $band_name: identical creation ranks (should not happen with the 1.1s sleep)"
  else
    info "band $band_name: within-priority tiebreak = $dir"
  fi
}

infer_band_direction "P1" "${P1_IDS[@]}"
infer_band_direction "P2" "${P2_IDS[@]}"
infer_band_direction "P3" "${P3_IDS[@]}"

# ── done ─────────────────────────────────────────────────────────────────────
if [[ "$FAILED" == "0" ]]; then
  echo "OK — bd ready ordering assertions pass"
  exit 0
else
  echo "FAIL — bd ready ordering assertions failed (see above)" >&2
  exit 1
fi
