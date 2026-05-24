#!/bin/bash
# beads-runner/daemon/test-c2-spare-ramp-gate.sh — C2 spare-only daily
# ramp gate (claude-tools-oil; epic claude-tools-kie).
#
# WHAT THIS PROVES
#   PART 0 — files exist, parse, workspace_desired_state + spare-only gate
#            are wired into daemon_ask_capacity; agents/capacity.md exists
#            and references the daily-ramp formula.
#   PART A — UX 0.A daily-ramp math: day N × SPARE_RAMP_PER_DAY% lands
#            EXACTLY where the spec says (14, 28, 42, ..., 100), and the
#            daemon emits that formula to its logs (verifiable from logs,
#            not just from code).
#   PART B — workspace desired=spare-cycles + low_priority + usage UNDER
#            today's ramp ⇒ allowed (rc=0, reason='ok').
#   PART C — workspace desired=spare-cycles + low_priority + usage OVER
#            today's ramp ⇒ denied (rc=1, reason='spare_cycles_today_
#            exhausted') — the daemon dropped low_priority from
#            allowed_cost_classes because pct_7d ≥ spare_ramp_today.
#   PART D — workspace desired=spare-cycles + standard (any usage) ⇒ denied
#            (rc=1, reason='spare_only_standard_disallowed') — the spare-
#            only mode bites BEFORE the global allowed-classes lookup so the
#            reason names the WHY (spare-only), not the symptom (globally-
#            allowed standard "not allowed" for this workspace).
#   PART E — backwards compat: pre-C2 callers (one-arg daemon_ask_capacity)
#            keep working — no desired-state ⇒ no spare-only gate applied.
#
# Mirrors the structure of test-c1-capacity-gate.sh.
# Run: bash beads-runner/daemon/test-c2-spare-ramp-gate.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
RUNNER_SH="$REPO_ROOT/run-beads-tasks.sh"
LOCAL_AGENT_LIB="$REPO_ROOT/lib/local-agent.sh"
USAGE_LIB="$REPO_ROOT/daemon/usage-poll.sh"
CAPACITY_DOC="$REPO_ROOT/agents/capacity.md"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
eq()  { [[ "$1" == "$2" ]] && ok "$3" || bad "$3 (got '$1' want '$2')"; }

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " C2 spare-only daily-ramp gate — claude-tools-oil"
echo "════════════════════════════════════════════════════════════════════"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ════════════════════════════════════════════════════════════════════════════
# PART 0 — files exist, parse, wiring is present
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART 0 — files exist, parse, wiring (static) ──"

[[ -f "$RUNNER_SH" ]] && ok "run-beads-tasks.sh present" || bad "run-beads-tasks.sh missing"
bash -n "$RUNNER_SH" 2>/dev/null && ok "run-beads-tasks.sh parses (bash -n clean)" || bad "run-beads-tasks.sh syntax"

grep -q "^workspace_desired_state()" "$RUNNER_SH" \
  && ok "run-beads-tasks.sh defines workspace_desired_state" \
  || bad "run-beads-tasks.sh defines workspace_desired_state"

grep -q "spare_only_standard_disallowed" "$RUNNER_SH" \
  && ok "daemon_ask_capacity emits spare_only_standard_disallowed reason" \
  || bad "daemon_ask_capacity emits spare_only_standard_disallowed reason"

grep -q 'daemon_ask_capacity "\$TASK_COST_CLASS" "\$WORKSPACE_DESIRED"' "$RUNNER_SH" \
  && ok "C2 callsite passes WORKSPACE_DESIRED into daemon_ask_capacity" \
  || bad "C2 callsite passes WORKSPACE_DESIRED into daemon_ask_capacity"

# Priority → cost-class mapping (UX 0.A "Low-priority tasks run only when there
# are spare cycles").
grep -q 'TASK_PRIORITY:-2.*-ge 3' "$RUNNER_SH" \
  && ok "priority ≥ 3 maps to low_priority cost class" \
  || bad "priority ≥ 3 maps to low_priority cost class"

[[ -f "$CAPACITY_DOC" ]] && ok "agents/capacity.md present" || bad "agents/capacity.md present"
grep -q "14.2" "$CAPACITY_DOC" \
  && ok "agents/capacity.md documents the 14.2%/day formula" \
  || bad "agents/capacity.md documents the 14.2%/day formula"

# ════════════════════════════════════════════════════════════════════════════
# Helper — extract daemon_ask_capacity in isolation (mirrors test-c1 pattern).
# ════════════════════════════════════════════════════════════════════════════
run_capacity() {  # $1=cache_dir · $2=cost_class · $3=desired_state
  local cache_dir="$1" cost_class="$2" desired="${3:-}"
  (
    set +e
    set -u
    export BEADS_DAEMON_CACHE_DIR="${cache_dir:-/nonexistent-c2-test-dir-$$}"
    export USAGE_THRESHOLD=70
    export USAGE_CACHE_SECONDS=300
    . "$LOCAL_AGENT_LIB"
    eval "$(awk '
      /^daemon_ask_capacity\(\)/      {in_fn=1}
      in_fn                            {print}
      in_fn && /^}/ && !/^}.*{/        {if (NR>0) exit}
    ' "$RUNNER_SH")"
    out=$(daemon_ask_capacity "$cost_class" "$desired"); rc=$?
    printf '%s|%s' "$rc" "$out"
  )
}

# ════════════════════════════════════════════════════════════════════════════
# PART A — UX 0.A daily-ramp math: day N × 14.2% lands exactly where the spec
# says, AND the daemon logs the formula so it is verifiable from logs.
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART A — UX 0.A daily-ramp math + daemon log audit ──"

# A.1 — pure math (no daemon I/O): N × 14.2 floor for N=1..7.
ramp_for_day() {
  (
    set +e
    export SPARE_DAY_INDEX="$1"
    export USAGE_POLL_DISABLED=1   # safe: source-only, never hits keychain
    . "$USAGE_LIB"
    _usage_poll_spare_ramp_pct
  )
}
eq "$(ramp_for_day 1)" "14"  "day 1 ramp = 14% (= floor(1 × 14.2))"
eq "$(ramp_for_day 2)" "28"  "day 2 ramp = 28% (= floor(2 × 14.2))"
eq "$(ramp_for_day 3)" "42"  "day 3 ramp = 42% (= floor(3 × 14.2))"
eq "$(ramp_for_day 4)" "56"  "day 4 ramp = 56% (= floor(4 × 14.2))"
eq "$(ramp_for_day 5)" "71"  "day 5 ramp = 71% (= floor(5 × 14.2))"
eq "$(ramp_for_day 6)" "85"  "day 6 ramp = 85% (= floor(6 × 14.2))"
eq "$(ramp_for_day 7)" "99"  "day 7 ramp = 99% (= floor(7 × 14.2), clamped ≤100)"

# A.2 — daemon log contains the formula (day=N × R%), not just the result.
# Source usage-poll with USAGE_POLL_DISABLED=0 + a stubbed keychain+curl so
# the real path runs end-to-end and logs once.
PART_A="$WORK/partA"
mkdir -p "$PART_A/cache" "$PART_A/bin"
cat > "$PART_A/bin/security" <<'EOF'
#!/bin/bash
echo '{"claudeAiOauth":{"accessToken":"stub"}}'
exit 0
EOF
cat > "$PART_A/bin/curl" <<'EOF'
#!/bin/bash
echo '{"five_hour":{"utilization":10},"seven_day":{"utilization":20}}'
exit 0
EOF
chmod +x "$PART_A/bin/security" "$PART_A/bin/curl"

LOG_OUT="$PART_A/poll.log"
(
  set -u
  export PATH="$PART_A/bin:$PATH"
  export BEADS_DAEMON_CACHE_DIR="$PART_A/cache"
  export USAGE_THRESHOLD=70
  export USAGE_CACHE_SECONDS=300
  export SPARE_DAY_INDEX=3
  export USAGE_POLL_DISABLED=0
  . "$USAGE_LIB"
  USAGE_POLL_CACHE_DIR="$BEADS_DAEMON_CACHE_DIR"
  USAGE_POLL_CACHE_FILE="$USAGE_POLL_CACHE_DIR/capacity.json"
  USAGE_POLL_OUTBOX="$USAGE_POLL_CACHE_DIR/coordinator-outbox.jsonl"
  daemon_usage_poll_once
) 2> "$LOG_OUT"

grep -q "day=3 × 14.2%" "$LOG_OUT" \
  && ok "daemon log contains the daily-ramp formula 'day=3 × 14.2%' (UX 0.A verifiable from logs)" \
  || { bad "daemon log missing the daily-ramp formula"; sed -n '1,5p' "$LOG_OUT"; }

grep -q "ramp=42%" "$LOG_OUT" \
  && ok "daemon log shows ramp=42% on day 3 (matches floor(3 × 14.2))" \
  || bad "daemon log shows ramp=42% on day 3"

# A.3 — x7ve: day_index derives from seven_day.resets_at, not the calendar.
# Without SPARE_DAY_INDEX the ramp must move monotonically with the API-
# reported window end, so the soft line cannot jump backwards at UTC midnight.
ramp_for_resets() {
  # $1 = resets_at ISO 8601 (leave empty to test the missing-field path)
  (
    set +e
    unset SPARE_DAY_INDEX
    export USAGE_POLL_DISABLED=1   # safe: source-only, never hits keychain
    . "$USAGE_LIB"
    _usage_poll_spare_ramp_pct "$1"
  )
}
day_for_resets() {
  (
    set +e
    unset SPARE_DAY_INDEX
    export USAGE_POLL_DISABLED=1
    . "$USAGE_LIB"
    _usage_poll_spare_ramp_day "$1"
  )
}

NOW_EPOCH=$(date +%s)
iso_at() {  # $1 = seconds-from-now (may be negative)
  local target=$(( NOW_EPOCH + $1 ))
  date -u -r "$target" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$target" +%Y-%m-%dT%H:%M:%SZ
}

# resets ~1 day out ⇒ we are deep in the window ⇒ day=7.
eq "$(day_for_resets "$(iso_at 86400)")"     "7"  "resets_at = now+1d ⇒ day=7 (deep in rolling window)"
eq "$(ramp_for_resets "$(iso_at 86400)")"    "99" "resets_at = now+1d ⇒ ramp=99%"

# resets ~7 days out ⇒ window just reset ⇒ day=1.
eq "$(day_for_resets "$(iso_at $((7*86400)))")"   "1"  "resets_at = now+7d ⇒ day=1 (window just reset)"
eq "$(ramp_for_resets "$(iso_at $((7*86400)))")"  "14" "resets_at = now+7d ⇒ ramp=14%"

# resets ~3.5 days out ⇒ ceil((3.5d)/1d)=4 days remaining ⇒ day=8-4=4.
eq "$(day_for_resets "$(iso_at $(( (7*86400)/2 )))")"   "4"  "resets_at = now+3.5d ⇒ day=4 (ceil of remaining)"
eq "$(ramp_for_resets "$(iso_at $(( (7*86400)/2 )))")"  "56" "resets_at = now+3.5d ⇒ ramp=56%"

# resets in the past (clock skew / stale cache) ⇒ clamped to day=7.
eq "$(day_for_resets "$(iso_at -3600)")"  "7"  "resets_at in the past ⇒ day=7 (clamped)"

# Missing / malformed resets_at ⇒ conservative day=1, ramp=14%.
eq "$(day_for_resets "")"                "1"  "resets_at missing ⇒ day=1 (conservative)"
eq "$(ramp_for_resets "")"               "14" "resets_at missing ⇒ ramp=14% (conservative)"
eq "$(day_for_resets "not-a-timestamp")" "1"  "resets_at malformed ⇒ day=1 (conservative)"

# SPARE_DAY_INDEX override still wins, even when resets_at says otherwise —
# pinned tests must keep working.
SPARE_DAY_INDEX_OVERRIDE_RAMP=$(
  set +e
  export SPARE_DAY_INDEX=2
  export USAGE_POLL_DISABLED=1
  . "$USAGE_LIB"
  _usage_poll_spare_ramp_pct "$(iso_at 86400)"
)
eq "$SPARE_DAY_INDEX_OVERRIDE_RAMP" "28" "SPARE_DAY_INDEX=2 overrides resets_at-derived day"

# A.4 — pkp2: the REAL API format is "2026-05-25T07:00:00.585476+00:00"
# (microseconds + explicit +00:00 offset), not the strict-Z form. Verify
# the parser handles every shape Anthropic could plausibly return so we
# don't regress into silently-day=1.
day_for_resets_pkp2() {
  # $1 = a real or synthetic resets_at string
  (
    set +e
    unset SPARE_DAY_INDEX
    export USAGE_POLL_DISABLED=1
    . "$USAGE_LIB"
    _usage_poll_spare_ramp_day "$1"
  )
}

# Build a "+1 day out" timestamp in EACH shape we want to accept, all anchored
# on the SAME epoch second so the day-index answer is identical across them.
TOMORROW_EPOCH=$(( NOW_EPOCH + 86400 ))
ISO_Z=$(date -u -r "$TOMORROW_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -d "@$TOMORROW_EPOCH" +%Y-%m-%dT%H:%M:%SZ)
ISO_BASE="${ISO_Z%Z}"                           # ...07:00:00
ISO_FRAC_OFFSET="${ISO_BASE}.585476+00:00"      # ← the real API shape
ISO_FRAC_Z="${ISO_BASE}.585476Z"                # fractional + Z
ISO_OFFSET="${ISO_BASE}+00:00"                  # no fractional, explicit +00:00
ISO_OFFSET_NOCOLON="${ISO_BASE}+0000"           # no fractional, +0000

eq "$(day_for_resets_pkp2 "$ISO_FRAC_OFFSET")"   "7" "real API shape (microsec + +00:00) parses ⇒ day=7"
eq "$(day_for_resets_pkp2 "$ISO_Z")"             "7" "strict Z form still parses ⇒ day=7 (BC preserved)"
eq "$(day_for_resets_pkp2 "$ISO_FRAC_Z")"        "7" "fractional + Z parses ⇒ day=7"
eq "$(day_for_resets_pkp2 "$ISO_OFFSET")"        "7" "no fractional + +00:00 parses ⇒ day=7"
eq "$(day_for_resets_pkp2 "$ISO_OFFSET_NOCOLON")" "7" "no fractional + +0000 parses ⇒ day=7"

# Non-UTC offsets are deliberately NOT normalized — the API returns UTC, and a
# hypothetical non-UTC value falls through to day=1 (conservative soft line).
ISO_NON_UTC="${ISO_BASE}.585476-05:00"
eq "$(day_for_resets_pkp2 "$ISO_NON_UTC")" "1" "non-UTC offset falls to day=1 (conservative; API returns UTC)"

# ════════════════════════════════════════════════════════════════════════════
# PART B — spare-cycles + low_priority + usage UNDER ramp ⇒ allowed
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART B — spare-only + low_prio + usage UNDER ramp ⇒ allowed ──"

PART_B="$WORK/partB"
mkdir -p "$PART_B"
# Day 3 ramp = 42%. pct_7d=20 < 42 ⇒ daemon allows low_priority.
cat > "$PART_B/capacity.json" <<EOF
{"schema_version":1,"pct_5h":5,"pct_7d":20,"spare_ramp_today":42,"allowed_cost_classes":["standard","low_priority"],"observed_at":"2026-01-01T00:00:00Z","expires_at":"2026-01-01T00:05:00Z"}
EOF
touch "$PART_B/capacity.json"

R="$(run_capacity "$PART_B" low_priority spare-cycles)"
eq "${R%%|*}" "0" "spare-only + low_priority + under ramp: rc=0 (allowed)"
eq "${R##*|}" "ok" "spare-only + low_priority + under ramp: reason='ok'"

# ════════════════════════════════════════════════════════════════════════════
# PART C — spare-cycles + low_priority + usage OVER ramp ⇒ denied
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART C — spare-only + low_prio + usage OVER ramp ⇒ denied ──"

PART_C="$WORK/partC"
mkdir -p "$PART_C"
# Day 3 ramp = 42%. pct_7d=50 ≥ 42 ⇒ daemon dropped low_priority from
# allowed_cost_classes (the M2 _usage_poll_compute_allowed contract).
cat > "$PART_C/capacity.json" <<EOF
{"schema_version":1,"pct_5h":5,"pct_7d":50,"spare_ramp_today":42,"allowed_cost_classes":["standard"],"observed_at":"2026-01-01T00:00:00Z","expires_at":"2026-01-01T00:05:00Z"}
EOF
touch "$PART_C/capacity.json"

R="$(run_capacity "$PART_C" low_priority spare-cycles)"
eq "${R%%|*}" "1" "spare-only + low_priority + over ramp: rc=1 (denied)"
eq "${R##*|}" "spare_cycles_today_exhausted" "spare-only + low_priority + over ramp: reason='spare_cycles_today_exhausted'"

# ════════════════════════════════════════════════════════════════════════════
# PART D — spare-cycles + standard (any usage) ⇒ denied
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART D — spare-only + standard ⇒ denied (UX 0.A: low-prio only) ──"

PART_D="$WORK/partD"
mkdir -p "$PART_D"
# Permissive global cache (standard is globally fine) — the spare-only gate
# should still refuse the standard pickup with the WHY (spare-only), not the
# downstream symptom.
cat > "$PART_D/capacity.json" <<EOF
{"schema_version":1,"pct_5h":5,"pct_7d":10,"spare_ramp_today":42,"allowed_cost_classes":["standard","low_priority"],"observed_at":"2026-01-01T00:00:00Z","expires_at":"2026-01-01T00:05:00Z"}
EOF
touch "$PART_D/capacity.json"

R="$(run_capacity "$PART_D" standard spare-cycles)"
eq "${R%%|*}" "1" "spare-only + standard: rc=1 (denied)"
eq "${R##*|}" "spare_only_standard_disallowed" "spare-only + standard: reason='spare_only_standard_disallowed'"

# ════════════════════════════════════════════════════════════════════════════
# PART E — backwards compat: no desired-state ⇒ no spare-only gate applied
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART E — pre-C2 callers unaffected (no desired-state ⇒ no gate) ──"

PART_E="$WORK/partE"
mkdir -p "$PART_E"
cat > "$PART_E/capacity.json" <<EOF
{"schema_version":1,"pct_5h":5,"pct_7d":10,"spare_ramp_today":100,"allowed_cost_classes":["standard","low_priority"],"observed_at":"2026-01-01T00:00:00Z","expires_at":"2026-01-01T00:05:00Z"}
EOF
touch "$PART_E/capacity.json"

R="$(run_capacity "$PART_E" standard "")"
eq "${R%%|*}" "0" "no desired-state + standard + permissive cache: rc=0 (BC preserved)"
eq "${R##*|}" "ok" "no desired-state + standard + permissive cache: reason='ok'"

R="$(run_capacity "$PART_E" standard running)"
eq "${R%%|*}" "0" "desired=running + standard + permissive cache: rc=0 (no spare-only gate)"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════════════════════════════"
printf "  C2 result: \033[32m%d passed\033[0m" "$PASS"
[[ "$FAIL" -gt 0 ]] && printf ", \033[31m%d failed\033[0m" "$FAIL"
printf "\n"
echo "════════════════════════════════════════════════════════════════════"
echo ""

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
