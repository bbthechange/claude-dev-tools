#!/bin/bash
# beads-runner/daemon/test-i5cap-aux-capacity-gate.sh — I5-cap aux-pool capacity
# gate (claude-tools-pof7; epic claude-tools-mhcp; gap-audit wzejgmopj).
#
# WHAT THIS PROVES
#   PART 0 — aux-dispatch-gate.sh exists, parses, defines daemon_aux_capacity_ok
#            + daemon_aux_dispatch_guard, and is sourced by daemon.sh (ready for
#            I5/uxvi5 to consume).
#   PART A — fresh permissive cache ⇒ aux dispatch ALLOWED (rc=0, reason='ok'),
#            and the guard RUNS the dispatch command (marker created).
#   PART B — fresh OVER-BUDGET cache ⇒ aux dispatch SUPPRESSED (THE acceptance
#            criterion). Predicate rc=1 with an observable §6.3 reason; the guard
#            does NOT spawn (marker absent). Covers the hard-ceiling (allowed=[])
#            and spare-ramp-exhausted (allowed=["standard"]) verdicts.
#   PART C — CHEAPER-than-writer proof: against ONE allowed=["standard"] cache the
#            writer class (standard) is allowed but the aux class (low_priority)
#            is suppressed; and the predicate's DEFAULT cost-class is the cheaper
#            low_priority. The aux pool is strictly tighter than the writer lane
#            (design/activity.md §5).
#   PART D — fail-OPEN on an unavailable signal: missing cache ⇒ dispatch allowed
#            (reason='fail_open_unavailable'); stale cache (> 2× TTL) ⇒ allowed
#            even though its content says over-budget (reason='fail_open_stale').
#            BC-34 §6.2 posture preserved — we never suppress on an absent signal.
#
# Offline + deterministic: no Keychain, no network. Plants capacity.json fixtures
# under a temp BEADS_DAEMON_CACHE_DIR. Mirrors test-c1-capacity-gate.sh.
# Run: bash beads-runner/daemon/test-i5cap-aux-capacity-gate.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE_SH="$HERE/aux-dispatch-gate.sh"
DAEMON_SH="$HERE/daemon.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
eq()  { [[ "$1" == "$2" ]] && ok "$3" || bad "$3 (got '$1' want '$2')"; }

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " I5-cap aux-pool capacity gate — claude-tools-pof7"
echo "════════════════════════════════════════════════════════════════════"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── Helpers ───────────────────────────────────────────────────────────────
# run_gate <cache_dir> <cost_class> — source the gate in a clean subshell against
#   a planted cache dir, run the predicate, echo "rc|AUX_GATE_REASON".
run_gate() {
  local cache_dir="$1" cost_class="$2"
  (
    set +e; set -u
    export BEADS_DAEMON_CACHE_DIR="${cache_dir:-/nonexistent-pof7-$$}"
    unset DAEMON_CACHE_DIR 2>/dev/null || true
    export USAGE_THRESHOLD=70
    export USAGE_CACHE_SECONDS=300
    # shellcheck source=/dev/null
    . "$GATE_SH"
    daemon_aux_capacity_ok "$cost_class"; rc=$?
    printf '%s|%s' "$rc" "$AUX_GATE_REASON"
  )
}

# run_guard <cache_dir> — exercise the guard with a marker-creating dispatch
#   command; echo PRESENT|ABSENT according to whether the command actually ran.
run_guard() {
  local cache_dir="$1" marker="$WORK/guard-marker.$$"
  rm -f "$marker"
  (
    set +e; set -u
    export BEADS_DAEMON_CACHE_DIR="${cache_dir:-/nonexistent-pof7-$$}"
    unset DAEMON_CACHE_DIR 2>/dev/null || true
    export USAGE_THRESHOLD=70
    export USAGE_CACHE_SECONDS=300
    # shellcheck source=/dev/null
    . "$GATE_SH"
    daemon_aux_dispatch_guard blueprint-update touch "$marker"
  ) >/dev/null 2>&1
  [[ -f "$marker" ]] && printf 'PRESENT' || printf 'ABSENT'
}

plant() {  # plant <dir> <allowed_json_body> <pct_5h> <pct_7d> <ramp>
  local dir="$1" allowed="$2" p5="$3" p7="$4" ramp="$5"
  mkdir -p "$dir"
  cat > "$dir/capacity.json" <<EOF
{"schema_version":1,"pct_5h":$p5,"pct_7d":$p7,"spare_ramp_today":$ramp,"allowed_cost_classes":[$allowed],"observed_at":"2026-01-01T00:00:00Z","expires_at":"2026-01-01T00:05:00Z"}
EOF
  touch "$dir/capacity.json"
}

# ════════════════════════════════════════════════════════════════════════════
# PART 0 — static
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART 0 — file exists, parses, functions defined, sourced by daemon.sh ──"
[[ -f "$GATE_SH" ]] && ok "aux-dispatch-gate.sh present" || bad "aux-dispatch-gate.sh missing"
bash -n "$GATE_SH" 2>/dev/null && ok "aux-dispatch-gate.sh parses (bash -n clean)" || bad "aux-dispatch-gate.sh syntax"
grep -q '^daemon_aux_capacity_ok()' "$GATE_SH" \
  && ok "defines daemon_aux_capacity_ok" || bad "missing daemon_aux_capacity_ok"
grep -q '^daemon_aux_dispatch_guard()' "$GATE_SH" \
  && ok "defines daemon_aux_dispatch_guard" || bad "missing daemon_aux_dispatch_guard"
grep -q 'aux-dispatch-gate.sh' "$DAEMON_SH" \
  && ok "daemon.sh sources aux-dispatch-gate.sh (ready for I5)" \
  || bad "daemon.sh does NOT source aux-dispatch-gate.sh"

# ════════════════════════════════════════════════════════════════════════════
# PART A — fresh permissive cache ⇒ aux ALLOWED, guard runs
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART A — permissive cache ⇒ aux dispatch allowed ──"
PART_A="$WORK/partA"
plant "$PART_A" '"standard","low_priority"' 5 10 100
R="$(run_gate "$PART_A" low_priority)"
eq "${R%%|*}" "0" "permissive: aux(low_priority) rc=0 (allowed)"
eq "${R##*|}" "ok" "permissive: reason='ok'"
eq "$(run_guard "$PART_A")" "PRESENT" "permissive: guard RUNS the dispatch (marker created)"

# ════════════════════════════════════════════════════════════════════════════
# PART B — fresh OVER-BUDGET cache ⇒ aux SUPPRESSED  (the acceptance criterion)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART B — over-budget cache ⇒ aux dispatch SUPPRESSED ──"

# B.1 — hard 5h ceiling: allowed_cost_classes=[]
PART_B1="$WORK/partB1"
plant "$PART_B1" '' 95 40 100
R="$(run_gate "$PART_B1" low_priority)"
eq "${R%%|*}" "1" "5h ceiling: aux(low_priority) rc=1 (SUPPRESSED)"
eq "${R##*|}" "5h_hard_ceiling" "5h ceiling: reason='5h_hard_ceiling' (observable)"
eq "$(run_guard "$PART_B1")" "ABSENT" "5h ceiling: guard does NOT spawn (marker absent)"

# B.2 — spare-cycles ramp exhausted: allowed=["standard"] (aux dropped, writer kept)
PART_B2="$WORK/partB2"
plant "$PART_B2" '"standard"' 20 50 30
R="$(run_gate "$PART_B2" low_priority)"
eq "${R%%|*}" "1" "spare-ramp exhausted: aux(low_priority) rc=1 (SUPPRESSED)"
eq "${R##*|}" "spare_cycles_today_exhausted" "spare-ramp exhausted: reason='spare_cycles_today_exhausted'"
eq "$(run_guard "$PART_B2")" "ABSENT" "spare-ramp exhausted: guard does NOT spawn"

# ════════════════════════════════════════════════════════════════════════════
# PART C — CHEAPER-than-writer: aux gate is strictly tighter than the writer lane
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART C — aux gates on a cheaper cost-class than the writer ──"
# Reuse PART_B2 (allowed=["standard"]): the writer's standard is allowed, the
# aux's low_priority is suppressed — on the SAME machine-wide signal.
R="$(run_gate "$PART_B2" standard)"
eq "${R%%|*}" "0" "cheaper-than-writer: writer(standard) ALLOWED on the same cache"
R="$(run_gate "$PART_B2" low_priority)"
eq "${R%%|*}" "1" "cheaper-than-writer: aux(low_priority) SUPPRESSED on the same cache"
# Default cost-class (no arg) must be the cheaper low_priority ⇒ suppressed here.
R="$(run_gate "$PART_B2" "")"
eq "${R%%|*}" "1" "default cost-class is the cheaper low_priority ⇒ suppressed on allowed=[standard]"

# ════════════════════════════════════════════════════════════════════════════
# PART D — fail-OPEN on an unavailable signal (BC-34 §6.2)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART D — unavailable signal ⇒ fail-OPEN (never suppress on absence) ──"

# D.1 — missing cache
PART_D1="$WORK/partD1-empty"
mkdir -p "$PART_D1"   # exists, no capacity.json inside
R="$(run_gate "$PART_D1" low_priority)"
eq "${R%%|*}" "0" "missing cache: fail-OPEN (rc=0, dispatch allowed)"
eq "${R##*|}" "fail_open_unavailable" "missing cache: reason='fail_open_unavailable'"
eq "$(run_guard "$PART_D1")" "PRESENT" "missing cache: guard RUNS (fail-OPEN)"

# D.2 — stale cache (> 2 × USAGE_CACHE_SECONDS). Content says over-budget
# (allowed=[]) on purpose: staleness must win, proving we never trust — nor
# suppress on — a dead signal.
PART_D2="$WORK/partD2-stale"
plant "$PART_D2" '' 95 95 0
touch -t 197001010000 "$PART_D2/capacity.json" 2>/dev/null \
  || touch -d "2 hours ago" "$PART_D2/capacity.json" 2>/dev/null || true
R="$(run_gate "$PART_D2" low_priority)"
eq "${R%%|*}" "0" "stale cache: fail-OPEN despite over-budget content (rc=0)"
eq "${R##*|}" "fail_open_stale" "stale cache: reason='fail_open_stale'"
eq "$(run_guard "$PART_D2")" "PRESENT" "stale cache: guard RUNS (fail-OPEN)"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════════════════════════════"
printf "  I5-cap result: \033[32m%d passed\033[0m" "$PASS"
[[ "$FAIL" -gt 0 ]] && printf ", \033[31m%d failed\033[0m" "$FAIL"
printf "\n"
echo "════════════════════════════════════════════════════════════════════"
echo ""

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
