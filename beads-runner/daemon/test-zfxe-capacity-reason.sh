#!/bin/bash
# beads-runner/daemon/test-zfxe-capacity-reason.sh — capacity-deny log line
# must name the gate that tripped (claude-tools-zfxe).
#
# THE BUG (observed 2026-05-24)
#   Runner sat idle 30min with 6 ready beads. The log said:
#       Usage (via daemon): 5h=12.0% 7d=85.0% — standard over
#       Above 95% usage — sleeping 30min before rechecking...
#   "Above 95% usage" was a lie: neither 5h (12%) nor 7d (85%) was ≥95. The
#   gate that actually fired was the daemon-side cost-class verdict (a daemon
#   loaded with USAGE_THRESHOLD=85 emitted allowed_cost_classes=[]). The
#   runner-side USAGE_THRESHOLD (95) was conflated with the daemon-side gate,
#   and la_capacity_check returned only 0|1 so the REASON was discarded.
#
# WHAT THIS PROVES
#   PART A — la_capacity_check sets the sidecar reason (LA_CAPACITY_REASON +
#            LA_CAPACITY_PCT_5H/7D) alongside its exit code, with the same
#            5-token vocabulary daemon_ask_capacity already prints. Two+
#            distinct trip conditions (7d_hard_ceiling, 5h_hard_ceiling,
#            spare_cycles_today_exhausted) each yield the expected token.
#   PART B — the regression itself: a daemon cache that gates standard while
#            the runner's USAGE_THRESHOLD is HIGHER than the numbers (the
#            12%/85% symptom) yields the HONEST cost_class_not_allowed — never
#            a 5h/7d_hard_ceiling claim the local threshold cannot justify.
#   PART C — v1 check_usage propagates the reason into USAGE_REASON, and a
#            cached `over` hit serves the SAME retained reason (so the loop-top
#            sleep line stays truthful across the USAGE_CACHE_SECONDS window).
#   PART D — both deny log lines (v2 runner.sh, v1 run-beads-tasks.sh loop-top)
#            name reason= + the 5h/7d numbers, and the old "Above
#            ${USAGE_THRESHOLD}% usage" lie is gone.
#
# Mirrors the structure of test-c2-spare-ramp-gate.sh / test-m2-usage-poll.sh.
# Run: bash beads-runner/daemon/test-zfxe-capacity-reason.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
RUNNER_SH="$REPO_ROOT/run-beads-tasks.sh"
RUNNER_V2_SH="$REPO_ROOT/runner.sh"
LOCAL_AGENT_LIB="$REPO_ROOT/lib/local-agent.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
eq()  { [[ "$1" == "$2" ]] && ok "$3" || bad "$3 (got '$1' want '$2')"; }

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " capacity-deny reason token — claude-tools-zfxe"
echo "════════════════════════════════════════════════════════════════════"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ════════════════════════════════════════════════════════════════════════════
# Helpers — drive la_capacity_check against a written daemon cache and report
# the sidecar globals as `rc|reason|5h|7d` (stdout's human line is discarded).
# ════════════════════════════════════════════════════════════════════════════
write_cache() {  # $1=dir $2=pct_5h $3=pct_7d $4=ramp $5=allowed_body(no brackets)
  mkdir -p "$1"
  cat > "$1/capacity.json" <<EOF
{"schema_version":1,"pct_5h":$2,"pct_7d":$3,"spare_ramp_today":$4,"allowed_cost_classes":[$5],"observed_at":"2026-01-01T00:00:00Z","expires_at":"2026-01-01T00:05:00Z"}
EOF
}

run_la() {  # $1=cache_dir $2=cost_class $3=threshold(default 70)
  (
    set +e
    set -u
    export BEADS_DAEMON_CACHE_DIR="$1"
    export USAGE_THRESHOLD="${3:-70}"
    export USAGE_CACHE_SECONDS=300
    # shellcheck source=/dev/null
    . "$LOCAL_AGENT_LIB"
    la_capacity_check "$2" >/dev/null 2>&1; rc=$?
    printf '%s|%s|%s|%s' "$rc" "${LA_CAPACITY_REASON:-UNSET}" "${LA_CAPACITY_PCT_5H:-}" "${LA_CAPACITY_PCT_7D:-}"
  )
}

# ════════════════════════════════════════════════════════════════════════════
# PART A — la_capacity_check sidecar reason, distinct trip conditions.
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART A — la_capacity_check names the gate that tripped ──"

# A.1 — 7d hard ceiling (7d ≥ threshold, daemon gated both classes ⇒ allowed=[]).
write_cache "$WORK/a1" 10 95 100 ""
eq "$(run_la "$WORK/a1" standard 70)" "1|7d_hard_ceiling|10|95" \
   "7d=95 ≥ 70 ⇒ rc=1 reason=7d_hard_ceiling, numbers surfaced"

# A.2 — 5h hard ceiling (5h ≥ threshold).
write_cache "$WORK/a2" 99 10 100 ""
eq "$(run_la "$WORK/a2" standard 70)" "1|5h_hard_ceiling|99|10" \
   "5h=99 ≥ 70 ⇒ rc=1 reason=5h_hard_ceiling"

# A.3 — spare-cycles exhausted: standard allowed, low_priority dropped because
#       7d ≥ today's ramp (the daemon emits allowed=["standard"]).
write_cache "$WORK/a3" 10 50 40 '"standard"'
eq "$(run_la "$WORK/a3" low_priority 70)" "1|spare_cycles_today_exhausted|10|50" \
   "low_priority, 7d=50 ≥ ramp=40 ⇒ rc=1 reason=spare_cycles_today_exhausted"
# …and standard on the SAME cache is allowed (proves the reason is class-aware).
eq "$(run_la "$WORK/a3" standard 70)" "0|ok|10|50" \
   "standard on the same cache ⇒ rc=0 reason=ok (class-aware)"

# A.4 — fully permissive cache ⇒ ok, numbers still surfaced.
write_cache "$WORK/a4" 10 20 100 '"standard","low_priority"'
eq "$(run_la "$WORK/a4" standard 70)" "0|ok|10|20" \
   "both classes allowed ⇒ rc=0 reason=ok"

# ════════════════════════════════════════════════════════════════════════════
# PART B — the claude-tools-zfxe regression: the 12%/85% symptom.
# A daemon (loaded with a LOWER threshold) gated standard ⇒ allowed=[], but the
# runner's USAGE_THRESHOLD is 95. The deny reason must NOT claim a 5h/7d ceiling
# the local threshold cannot justify — it must be the honest cost_class_not_allowed.
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART B — the 12%/85% symptom yields the HONEST reason ──"

write_cache "$WORK/b1" 12 85 100 ""
RESULT_B="$(run_la "$WORK/b1" standard 95)"
eq "$RESULT_B" "1|cost_class_not_allowed|12|85" \
   "5h=12 / 7d=85 < runner threshold 95, daemon gated ⇒ reason=cost_class_not_allowed (honest)"
case "$RESULT_B" in
  *hard_ceiling*) bad "regression: deny line claims a hard ceiling the runner threshold (95) cannot justify" ;;
  *)              ok  "no false hard-ceiling claim when 5h/7d are below the runner threshold" ;;
esac

# ════════════════════════════════════════════════════════════════════════════
# PART C — v1 check_usage propagates the reason; a cached `over` retains it.
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART C — v1 check_usage carries the reason across the cache window ──"

RESULT_C="$(
  set +e
  set -u
  export BEADS_DAEMON_CACHE_DIR="$WORK/a1"     # the 7d_hard_ceiling cache
  export USAGE_THRESHOLD=70
  export USAGE_CACHE_SECONDS=300
  # shellcheck source=/dev/null
  . "$LOCAL_AGENT_LIB"
  # Module globals check_usage reads/writes (declared at top of run-beads-tasks.sh).
  USAGE_CACHE_FILE=""; USAGE_CACHE_TIME=0
  USAGE_REASON=ok; USAGE_PCT_5H=""; USAGE_PCT_7D=""
  # Load check_usage in isolation (mirrors test-c2's daemon_ask_capacity extract).
  eval "$(awk '
    /^check_usage\(\)/         {in_fn=1}
    in_fn                       {print}
    in_fn && /^}/ && !/^}.*{/   {exit}
  ' "$RUNNER_SH")"
  check_usage >/dev/null 2>&1; rc1=$?
  fresh="$rc1|$USAGE_REASON|$USAGE_PCT_5H|$USAGE_PCT_7D"
  # Second call within the TTL window ⇒ cached `over` hit (no recompute). It must
  # serve the SAME retained reason — do NOT touch USAGE_REASON between calls
  # (the real loop doesn't either; it just sleeps).
  check_usage >/dev/null 2>&1; rc2=$?
  cached="$rc2|$USAGE_REASON|$USAGE_PCT_5H|$USAGE_PCT_7D"
  printf '%s ## %s' "$fresh" "$cached"
)"
FRESH="${RESULT_C%% ## *}"; CACHED="${RESULT_C##* ## }"
eq "$FRESH"  "1|7d_hard_ceiling|10|95" "check_usage fresh check ⇒ USAGE_REASON=7d_hard_ceiling"
eq "$CACHED" "1|7d_hard_ceiling|10|95" "cached over-hit serves the SAME retained reason+numbers"

# ════════════════════════════════════════════════════════════════════════════
# PART D — both deny log lines name reason= + numbers; the old lie is gone.
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART D — deny log lines are honest (static source assertions) ──"

# v2 runner.sh — the §3 j2 deny line.
grep -q 'capacity verdict=over reason=${LA_CAPACITY_REASON' "$RUNNER_V2_SH" \
  && ok "runner.sh deny line names reason=\${LA_CAPACITY_REASON}" \
  || bad "runner.sh deny line missing reason=\${LA_CAPACITY_REASON}"
grep -q '5h=${LA_CAPACITY_PCT_5H' "$RUNNER_V2_SH" \
  && ok "runner.sh deny line includes the 5h/7d numbers" \
  || bad "runner.sh deny line missing the 5h/7d numbers"

# v1 run-beads-tasks.sh — the loop-top sleep line.
grep -q 'Capacity verdict=over reason=${USAGE_REASON' "$RUNNER_SH" \
  && ok "run-beads-tasks.sh loop-top names reason=\${USAGE_REASON}" \
  || bad "run-beads-tasks.sh loop-top missing reason=\${USAGE_REASON}"
grep -q '5h=${USAGE_PCT_5H' "$RUNNER_SH" \
  && ok "run-beads-tasks.sh loop-top includes the 5h/7d numbers" \
  || bad "run-beads-tasks.sh loop-top missing the 5h/7d numbers"

# The lie must be gone (this is the exact wording the bug filed against). Match
# the EMITTED line (`echo "  Above …`), not the comments that quote it to explain
# why it was removed.
grep -q 'echo "  Above ${USAGE_THRESHOLD}% usage' "$RUNNER_SH" \
  && bad "the old 'Above \${USAGE_THRESHOLD}% usage' lie is STILL emitted" \
  || ok "the old 'Above \${USAGE_THRESHOLD}% usage' lie is no longer emitted"

# The factored deny-reason helper exists in the lib.
grep -q '^la__capacity_deny_reason()' "$LOCAL_AGENT_LIB" \
  && ok "la__capacity_deny_reason helper present in local-agent.sh" \
  || bad "la__capacity_deny_reason helper missing"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " RESULT: $PASS passed, $FAIL failed"
echo "════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
