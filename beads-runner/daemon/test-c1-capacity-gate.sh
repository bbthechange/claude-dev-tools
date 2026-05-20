#!/bin/bash
# beads-runner/daemon/test-c1-capacity-gate.sh — C1 per-pickup daemon
# ask-capacity gate in the workspace runner (claude-tools-g98; epic
# claude-tools-kie).
#
# WHAT THIS PROVES
#   PART 0 — files exist, parse, daemon_ask_capacity is wired into the
#            workspace runner; the gate sits AFTER lease_acquire_ok and
#            BEFORE the WRITE to in_progress (the structural assertion the
#            C1 acceptance keys on — "before each task pickup").
#   PART A — daemon_ask_capacity returns 0 with reason='ok' when the daemon
#            cache permits the requested cost_class.
#   PART B — daemon_ask_capacity returns 1 with a §6.3 reason
#            ('5h_hard_ceiling' / '7d_hard_ceiling' /
#            'spare_cycles_today_exhausted' / 'cost_class_not_allowed')
#            when the daemon cache denies it. The denied reason is
#            observable (returned on stdout — the runner logs it).
#   PART C — daemon_ask_capacity returns 2 with reason='daemon_unreachable'
#            when the daemon capacity.json is missing — the signal that the
#            runner needs to fall back to la_capacity_check (BC-34).
#   PART D — staleness: a capacity.json older than 2 × USAGE_CACHE_SECONDS
#            is treated as daemon_unreachable (same fallback contract as
#            M2 PART E for la__capacity_via_daemon).
#
# Mirrors the structure of test-m2-usage-poll.sh.
# Run: bash beads-runner/daemon/test-c1-capacity-gate.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
RUNNER_SH="$REPO_ROOT/run-beads-tasks.sh"
LOCAL_AGENT_LIB="$REPO_ROOT/lib/local-agent.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
eq()  { [[ "$1" == "$2" ]] && ok "$3" || bad "$3 (got '$1' want '$2')"; }
has() { case "$1" in *"$2"*) ok "$3";; *) bad "$3 (missing '$2')";; esac; }

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " C1 per-pickup daemon ask-capacity gate — claude-tools-g98"
echo "════════════════════════════════════════════════════════════════════"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ════════════════════════════════════════════════════════════════════════════
# PART 0 — files exist, parse, gate is wired in the right place
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART 0 — files exist, parse, gate is wired (static) ──"
[[ -f "$RUNNER_SH" ]] && ok "run-beads-tasks.sh present" || bad "run-beads-tasks.sh missing"
bash -n "$RUNNER_SH" 2>/dev/null && ok "run-beads-tasks.sh parses (bash -n clean)" || bad "run-beads-tasks.sh syntax"

grep -q "^daemon_ask_capacity()" "$RUNNER_SH" \
  && ok "run-beads-tasks.sh defines daemon_ask_capacity" \
  || bad "run-beads-tasks.sh defines daemon_ask_capacity"

grep -q "CAPACITY_DENY_BACKOFF" "$RUNNER_SH" \
  && ok "run-beads-tasks.sh declares CAPACITY_DENY_BACKOFF tunable" \
  || bad "run-beads-tasks.sh declares CAPACITY_DENY_BACKOFF tunable"

# STRUCTURAL: the per-pickup gate MUST appear AFTER lease_acquire_ok and
# BEFORE the 'bd update --status=in_progress' write. The C1 acceptance
# hinges on that placement ("before each task pickup … after lease, before
# in_progress"). awk-find line numbers, then assert order.
LEASE_LINE=$(awk '/if ! lease_acquire_ok "\$TASK_ID"/{print NR; exit}' "$RUNNER_SH")
GATE_LINE=$(awk '/daemon_ask_capacity "\$TASK_COST_CLASS"/{print NR; exit}' "$RUNNER_SH")
INPROG_LINE=$(awk '/bd update "\$TASK_ID" --status=in_progress/{print NR; exit}' "$RUNNER_SH")
if [[ -n "$LEASE_LINE" && -n "$GATE_LINE" && -n "$INPROG_LINE" \
      && "$LEASE_LINE" -lt "$GATE_LINE" && "$GATE_LINE" -lt "$INPROG_LINE" ]]; then
  ok "daemon_ask_capacity sits AFTER lease_acquire_ok and BEFORE bd update --status=in_progress (line $LEASE_LINE < $GATE_LINE < $INPROG_LINE)"
else
  bad "gate placement wrong (lease=$LEASE_LINE gate=$GATE_LINE in_progress=$INPROG_LINE)"
fi

# Denied verdict MUST release the lease before sleeping (no claim leakage).
awk '/Capacity DENIED by daemon/,/continue/' "$RUNNER_SH" | grep -q 'lease_release_seam' \
  && ok "denied branch releases the lease before sleeping" \
  || bad "denied branch does not release the lease"

# Unreachable branch MUST fall back to la_capacity_check (BC-34).
awk '/Capacity \(daemon unreachable\)/,/^  esac/' "$RUNNER_SH" | grep -q 'la_capacity_check' \
  && ok "unreachable branch falls back to la_capacity_check (BC-34)" \
  || bad "unreachable branch does not fall back to la_capacity_check"

# ════════════════════════════════════════════════════════════════════════════
# Common scaffolding for runtime PARTs — extract the function in isolation.
# We source the runner's bashfile in a guarded subshell that early-exits
# before the main loop runs. The functions and globals get defined; nothing
# fires.
# ════════════════════════════════════════════════════════════════════════════

run_capacity() {  # $1 = cache_dir (empty ⇒ skip planting cache) · $2 = cost_class
  local cache_dir="$1" cost_class="$2"
  (
    set +e
    set -u
    export BEADS_DAEMON_CACHE_DIR="${cache_dir:-/nonexistent-c1-test-dir-$$}"
    # USAGE_THRESHOLD non-zero so the gate logic runs.
    export USAGE_THRESHOLD=70
    export USAGE_CACHE_SECONDS=300
    # The runner sources local-agent.sh and runs to main loop. We need the
    # function definitions only — short-circuit the main loop by setting a
    # noop bd binary on the PATH AND swapping the runner's entry by
    # extracting only the function definitions. Simplest: source the runner
    # with a guard. Since run-beads-tasks.sh has top-level statements, we
    # set BEADS_RUNNER_NO_RUN=1 → if that gate is absent we just exit early
    # after sourcing functions by trapping EXIT.
    #
    # Instead, source the LA lib directly + extract daemon_ask_capacity via
    # awk into a tmpfile. Cleaner, no top-level execution of the runner.
    . "$LOCAL_AGENT_LIB"
    eval "$(awk '
      /^daemon_ask_capacity\(\)/      {in_fn=1}
      in_fn                            {print}
      in_fn && /^}/ && !/^}.*{/        {if (NR>0) exit}
    ' "$RUNNER_SH")"
    out=$(daemon_ask_capacity "$cost_class"); rc=$?
    printf '%s|%s' "$rc" "$out"
  )
}

# ════════════════════════════════════════════════════════════════════════════
# PART A — daemon cache permits ⇒ rc=0, reason='ok'
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART A — daemon permissive cache ⇒ allowed ──"

PART_A="$WORK/partA"
mkdir -p "$PART_A"
cat > "$PART_A/capacity.json" <<EOF
{"schema_version":1,"pct_5h":5,"pct_7d":10,"spare_ramp_today":100,"allowed_cost_classes":["standard","low_priority"],"observed_at":"2026-01-01T00:00:00Z","expires_at":"2026-01-01T00:05:00Z"}
EOF
# Make sure the file is fresh (mtime ≈ now). mktemp dirs are fresh; explicit
# touch is belt-and-suspenders for slow filesystems.
touch "$PART_A/capacity.json"

R="$(run_capacity "$PART_A" standard)"
eq "${R%%|*}" "0" "standard: rc=0 (allowed)"
eq "${R##*|}" "ok" "standard: reason='ok'"

R="$(run_capacity "$PART_A" low_priority)"
eq "${R%%|*}" "0" "low_priority: rc=0 (allowed when ramp permits)"
eq "${R##*|}" "ok" "low_priority: reason='ok'"

# ════════════════════════════════════════════════════════════════════════════
# PART B — daemon cache denies ⇒ rc=1, observable reason
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART B — daemon denied cache ⇒ observable §6.3 reasons ──"

PART_B="$WORK/partB"
mkdir -p "$PART_B"

# B.1 — 5h hard ceiling hit ⇒ allowed_cost_classes=[]
cat > "$PART_B/capacity.json" <<EOF
{"schema_version":1,"pct_5h":95,"pct_7d":40,"spare_ramp_today":100,"allowed_cost_classes":[],"observed_at":"2026-01-01T00:00:00Z","expires_at":"2026-01-01T00:05:00Z"}
EOF
touch "$PART_B/capacity.json"
R="$(run_capacity "$PART_B" standard)"
eq "${R%%|*}" "1" "5h ceiling: rc=1 (denied)"
eq "${R##*|}" "5h_hard_ceiling" "5h ceiling: reason='5h_hard_ceiling' (observable)"

# B.2 — 7d hard ceiling hit
cat > "$PART_B/capacity.json" <<EOF
{"schema_version":1,"pct_5h":30,"pct_7d":95,"spare_ramp_today":100,"allowed_cost_classes":[],"observed_at":"2026-01-01T00:00:00Z","expires_at":"2026-01-01T00:05:00Z"}
EOF
touch "$PART_B/capacity.json"
R="$(run_capacity "$PART_B" standard)"
eq "${R%%|*}" "1" "7d ceiling: rc=1 (denied)"
eq "${R##*|}" "7d_hard_ceiling" "7d ceiling: reason='7d_hard_ceiling' (observable)"

# B.3 — spare-cycles ramp exhausted: standard allowed, low_priority denied.
# pct_7d ≥ spare_ramp_today AND below threshold ⇒ allowed_cost_classes=["standard"].
cat > "$PART_B/capacity.json" <<EOF
{"schema_version":1,"pct_5h":20,"pct_7d":50,"spare_ramp_today":30,"allowed_cost_classes":["standard"],"observed_at":"2026-01-01T00:00:00Z","expires_at":"2026-01-01T00:05:00Z"}
EOF
touch "$PART_B/capacity.json"
R="$(run_capacity "$PART_B" standard)"
eq "${R%%|*}" "0" "spare-ramp exhausted: standard still allowed"
R="$(run_capacity "$PART_B" low_priority)"
eq "${R%%|*}" "1" "spare-ramp exhausted: low_priority denied"
eq "${R##*|}" "spare_cycles_today_exhausted" "spare-ramp exhausted: reason='spare_cycles_today_exhausted'"

# B.4 — unknown cost_class (defensive) ⇒ cost_class_not_allowed
cat > "$PART_B/capacity.json" <<EOF
{"schema_version":1,"pct_5h":5,"pct_7d":10,"spare_ramp_today":100,"allowed_cost_classes":["standard"],"observed_at":"2026-01-01T00:00:00Z","expires_at":"2026-01-01T00:05:00Z"}
EOF
touch "$PART_B/capacity.json"
R="$(run_capacity "$PART_B" some_unknown_class)"
eq "${R%%|*}" "1" "unknown cost class: rc=1"
eq "${R##*|}" "cost_class_not_allowed" "unknown cost class: reason='cost_class_not_allowed'"

# ════════════════════════════════════════════════════════════════════════════
# PART C — daemon cache MISSING ⇒ rc=2, reason='daemon_unreachable'
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART C — daemon absent ⇒ rc=2 daemon_unreachable (runner falls back) ──"

PART_C="$WORK/partC-empty"
mkdir -p "$PART_C"   # exists, no capacity.json inside

R="$(run_capacity "$PART_C" standard)"
eq "${R%%|*}" "2" "missing cache: rc=2 (daemon unreachable)"
eq "${R##*|}" "daemon_unreachable" "missing cache: reason='daemon_unreachable'"

# ════════════════════════════════════════════════════════════════════════════
# PART D — stale cache (> 2 × USAGE_CACHE_SECONDS) ⇒ also daemon_unreachable
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART D — stale cache treated as unreachable (BC-34 fallback) ──"

PART_D="$WORK/partD"
mkdir -p "$PART_D"
cat > "$PART_D/capacity.json" <<EOF
{"schema_version":1,"pct_5h":5,"pct_7d":10,"spare_ramp_today":100,"allowed_cost_classes":["standard","low_priority"],"observed_at":"2026-01-01T00:00:00Z","expires_at":"2026-01-01T00:05:00Z"}
EOF
# Backdate by 2 hours (well past 2 × USAGE_CACHE_SECONDS default = 600s)
touch -t 197001010000 "$PART_D/capacity.json" 2>/dev/null || \
  touch -d "2 hours ago" "$PART_D/capacity.json" 2>/dev/null || true

R="$(run_capacity "$PART_D" standard)"
eq "${R%%|*}" "2" "stale cache: rc=2 (daemon unreachable)"
eq "${R##*|}" "daemon_unreachable" "stale cache: reason='daemon_unreachable'"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════════════════════════════"
printf "  C1 result: \033[32m%d passed\033[0m" "$PASS"
[[ "$FAIL" -gt 0 ]] && printf ", \033[31m%d failed\033[0m" "$FAIL"
printf "\n"
echo "════════════════════════════════════════════════════════════════════"
echo ""

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
