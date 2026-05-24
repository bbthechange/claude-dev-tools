#!/bin/bash
# beads-runner/daemon/test-machine-state-producer.sh — C12
# (claude-tools-zdxd.3) — MACHINE-STATE.md v1 (D2) PRODUCER conformance.
#
# WHAT THIS PROVES
#   PART 0 — files exist, parse, and carry the §B anti-drift banner.
#   PART A — daemon_usage_poll_once with a synthetic Anthropic response
#            emits one machine_state record to the daemon outbox whose
#            fields MATCH test-fixtures/machine-state-v1.json field-for-
#            field (allowing observed_at / runner_id / principal
#            substitution — these are environment-derived at emit time).
#   PART B — fail-OPEN arms (BC-34: keychain unreadable, API failed) still
#            emit a record with keychain_ok/usage_api_ok=false and
#            pct_5h/pct_7d=0 (the §1.1 fail-open contract — the Board
#            renders the §4.C breadcrumb).
#   PART C — anti-drift banner grep: BOTH binding-map files
#            (daemon/usage-poll.sh, cf/src/machine-state.js) carry the §B
#            banner referencing MACHINE-STATE.md v1.
#
# Run: bash beads-runner/daemon/test-machine-state-producer.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
USAGE_LIB="$HERE/usage-poll.sh"
FIXTURE="$REPO_ROOT/test-fixtures/machine-state-v1.json"
CF_MACHINE_STATE="$REPO_ROOT/cf/src/machine-state.js"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
eq()  { [[ "$1" == "$2" ]] && ok "$3" || bad "$3 (got '$1' want '$2')"; }

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " C12 D2 machine_state producer — claude-tools-zdxd.3"
echo "════════════════════════════════════════════════════════════════════"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ════════════════════════════════════════════════════════════════════════════
# PART 0 — files exist, parse, define the helper
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART 0 — files exist, parse, define the helper ──"
[[ -f "$USAGE_LIB" ]]          && ok "usage-poll.sh present"        || bad "usage-poll.sh missing"
[[ -f "$FIXTURE" ]]            && ok "fixture present"              || bad "fixture missing"
[[ -f "$CF_MACHINE_STATE" ]]   && ok "cf/src/machine-state.js present" || bad "cf/src/machine-state.js missing"
bash -n "$USAGE_LIB" 2>/dev/null && ok "usage-poll.sh parses (bash -n clean)" || bad "usage-poll.sh syntax"
grep -q '^_machine_state_emit()' "$USAGE_LIB" \
  && ok "usage-poll.sh defines _machine_state_emit" \
  || bad "usage-poll.sh defines _machine_state_emit"

# ════════════════════════════════════════════════════════════════════════════
# PART A — success-path emit matches the canonical fixture
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART A — daemon_usage_poll_once emits D2 record matching fixture ──"

PART_A="$WORK/partA"
mkdir -p "$PART_A/bin" "$PART_A/cache"

# Synthetic Anthropic response: pct_5h=24, pct_7d=82 (matches fixture).
cat > "$PART_A/bin/security" <<'EOF'
#!/bin/bash
echo '{"claudeAiOauth":{"accessToken":"d2-stub-token"}}'
exit 0
EOF
cat > "$PART_A/bin/curl" <<'EOF'
#!/bin/bash
echo '{"five_hour":{"utilization":24},"seven_day":{"utilization":82}}'
exit 0
EOF
chmod +x "$PART_A/bin/security" "$PART_A/bin/curl"

(
  set -u
  export PATH="$PART_A/bin:$PATH"
  export BEADS_DAEMON_CACHE_DIR="$PART_A/cache"
  export USAGE_THRESHOLD=70
  export USAGE_CACHE_SECONDS=300
  # Day 4 × 14.2 = 56.8 ⇒ printf %d ⇒ 56 (matches fixture spare_ramp_today).
  export SPARE_DAY_INDEX=4
  export USAGE_POLL_DISABLED=0
  export RUNNER_ID="macbook-pro.local"
  # shellcheck source=/dev/null
  . "$USAGE_LIB"
  USAGE_POLL_CACHE_DIR="$BEADS_DAEMON_CACHE_DIR"
  USAGE_POLL_CACHE_FILE="$USAGE_POLL_CACHE_DIR/capacity.json"
  USAGE_POLL_OUTBOX="$USAGE_POLL_CACHE_DIR/coordinator-outbox.jsonl"
  daemon_usage_poll_once
)

OUTBOX="$PART_A/cache/coordinator-outbox.jsonl"
[[ -f "$OUTBOX" ]] && ok "outbox written" || bad "outbox missing"

# Exactly one machine_state record per cycle (§1.1 cadence).
ms_count=$(grep -c '"report":"machine_state"' "$OUTBOX" 2>/dev/null || echo 0)
eq "$ms_count" "1" "exactly ONE machine_state record per cycle (D2 cadence)"

MS_LINE=$(grep '"report":"machine_state"' "$OUTBOX" | head -n1)
[[ -n "$MS_LINE" ]] && ok "machine_state line present" || bad "machine_state line present"

# Field-for-field assertions against the canonical fixture, allowing
# observed_at / runner_id / principal substitution (env-derived).
eq "$(printf '%s' "$MS_LINE" | jq -r '.report')"               "machine_state" "field: report"
eq "$(printf '%s' "$MS_LINE" | jq -r '.schema_version')"       "1"             "field: schema_version (1, int)"
# principal is the env literal at emit time (not the resolved one — the
# engine §9.1 stamp overwrites this on ingest; the test allows substitution).
[[ "$(printf '%s' "$MS_LINE" | jq -r '.principal')" =~ ^(brian|PRINCIPAL_V1)$ ]] \
  && ok "field: principal is the env literal (engine §9.1 stamps on ingest)" \
  || bad "field: principal allowed values {brian, PRINCIPAL_V1}"
eq "$(printf '%s' "$MS_LINE" | jq -r '.runner_id')"            "macbook-pro.local" "field: runner_id (env-substituted)"
# pct_5h / pct_7d are numeric (float OK); use numeric equality not string.
eq "$(printf '%s' "$MS_LINE" | jq -e '.pct_5h == 24' >/dev/null 2>&1 && echo y || echo n)" "y" "field: pct_5h == 24 (fixture value, float OK)"
eq "$(printf '%s' "$MS_LINE" | jq -e '.pct_7d == 82' >/dev/null 2>&1 && echo y || echo n)" "y" "field: pct_7d == 82"
eq "$(printf '%s' "$MS_LINE" | jq -r '.spare_ramp_today')"     "56"  "field: spare_ramp_today=56 (day4 × 14.2)"
eq "$(printf '%s' "$MS_LINE" | jq -r '.threshold_in_effect')"  "70"  "field: threshold_in_effect=70 (fixture)"
eq "$(printf '%s' "$MS_LINE" | jq -r '.gate_disabled')"        "false" "field: gate_disabled=false (threshold>0)"
eq "$(printf '%s' "$MS_LINE" | jq -r '.keychain_ok')"          "true"  "field: keychain_ok=true (security mock succeeded)"
eq "$(printf '%s' "$MS_LINE" | jq -r '.usage_api_ok')"         "true"  "field: usage_api_ok=true (curl mock succeeded)"
# observed_at is an env-substituted ISO-8601 timestamp; assert shape only.
obs="$(printf '%s' "$MS_LINE" | jq -r '.observed_at')"
[[ "$obs" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  && ok "field: observed_at is RFC-3339 UTC (env-substituted)" \
  || bad "field: observed_at shape (got '$obs')"

# Closed-field set: the line MUST carry exactly the fixture's keys (minus the
# _comment_DO_NOT_REMOVE docstring on the fixture). Adding a field without a
# D2 amend is the drift incident this assertion catches.
fix_keys=$(jq -r 'del(._comment_DO_NOT_REMOVE) | keys_unsorted | sort | join(",")' "$FIXTURE")
emit_keys=$(printf '%s' "$MS_LINE" | jq -r 'keys_unsorted | sort | join(",")')
eq "$emit_keys" "$fix_keys" "emit carries EXACTLY the fixture's key set (no drift)"

# ════════════════════════════════════════════════════════════════════════════
# PART B — fail-OPEN arms still emit (keychain_ok / usage_api_ok = false)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART B — fail-OPEN arms still emit (BC-34, §1.1 fail-open) ──"

PART_B="$WORK/partB"
mkdir -p "$PART_B/bin" "$PART_B/cache-kc-fail" "$PART_B/cache-api-fail"

# Keychain-fail arm: security returns nonzero.
cat > "$PART_B/bin/security" <<'EOF'
#!/bin/bash
exit 1
EOF
cat > "$PART_B/bin/curl" <<'EOF'
#!/bin/bash
echo '{"five_hour":{"utilization":0},"seven_day":{"utilization":0}}'
EOF
chmod +x "$PART_B/bin/security" "$PART_B/bin/curl"

(
  set -u
  export PATH="$PART_B/bin:$PATH"
  export BEADS_DAEMON_CACHE_DIR="$PART_B/cache-kc-fail"
  export USAGE_THRESHOLD=70
  export USAGE_CACHE_SECONDS=300
  export RUNNER_ID="kc-fail-host"
  # shellcheck source=/dev/null
  . "$USAGE_LIB"
  USAGE_POLL_CACHE_DIR="$BEADS_DAEMON_CACHE_DIR"
  USAGE_POLL_CACHE_FILE="$USAGE_POLL_CACHE_DIR/capacity.json"
  USAGE_POLL_OUTBOX="$USAGE_POLL_CACHE_DIR/coordinator-outbox.jsonl"
  daemon_usage_poll_once
)

KC_OUT="$PART_B/cache-kc-fail/coordinator-outbox.jsonl"
[[ -f "$KC_OUT" ]] && ok "keychain-fail arm still wrote outbox" || bad "keychain-fail arm wrote outbox"
KC_LINE=$(grep '"report":"machine_state"' "$KC_OUT" 2>/dev/null | head -n1)
[[ -n "$KC_LINE" ]] && ok "keychain-fail arm emitted a machine_state record" || bad "keychain-fail arm emitted record"
eq "$(printf '%s' "$KC_LINE" | jq -r '.keychain_ok')"  "false" "kc-fail: keychain_ok=false"
eq "$(printf '%s' "$KC_LINE" | jq -r '.usage_api_ok')" "false" "kc-fail: usage_api_ok=false (no API call made)"
eq "$(printf '%s' "$KC_LINE" | jq -e '.pct_5h == 0' >/dev/null 2>&1 && echo y || echo n)" "y" "kc-fail: pct_5h=0 (fail-open zero)"
eq "$(printf '%s' "$KC_LINE" | jq -e '.pct_7d == 0' >/dev/null 2>&1 && echo y || echo n)" "y" "kc-fail: pct_7d=0"

# API-fail arm: security succeeds, curl returns nonzero.
cat > "$PART_B/bin/security" <<'EOF'
#!/bin/bash
echo '{"claudeAiOauth":{"accessToken":"stub"}}'
EOF
cat > "$PART_B/bin/curl" <<'EOF'
#!/bin/bash
exit 22
EOF
chmod +x "$PART_B/bin/security" "$PART_B/bin/curl"

(
  set -u
  export PATH="$PART_B/bin:$PATH"
  export BEADS_DAEMON_CACHE_DIR="$PART_B/cache-api-fail"
  export USAGE_THRESHOLD=70
  export USAGE_CACHE_SECONDS=300
  export RUNNER_ID="api-fail-host"
  # shellcheck source=/dev/null
  . "$USAGE_LIB"
  USAGE_POLL_CACHE_DIR="$BEADS_DAEMON_CACHE_DIR"
  USAGE_POLL_CACHE_FILE="$USAGE_POLL_CACHE_DIR/capacity.json"
  USAGE_POLL_OUTBOX="$USAGE_POLL_CACHE_DIR/coordinator-outbox.jsonl"
  daemon_usage_poll_once
)

API_OUT="$PART_B/cache-api-fail/coordinator-outbox.jsonl"
API_LINE=$(grep '"report":"machine_state"' "$API_OUT" 2>/dev/null | head -n1)
[[ -n "$API_LINE" ]] && ok "api-fail arm emitted a machine_state record" || bad "api-fail arm emitted record"
eq "$(printf '%s' "$API_LINE" | jq -r '.keychain_ok')"  "true"  "api-fail: keychain_ok=true (security succeeded)"
eq "$(printf '%s' "$API_LINE" | jq -r '.usage_api_ok')" "false" "api-fail: usage_api_ok=false"
eq "$(printf '%s' "$API_LINE" | jq -e '.pct_5h == 0' >/dev/null 2>&1 && echo y || echo n)" "y" "api-fail: pct_5h=0"

# ════════════════════════════════════════════════════════════════════════════
# PART C — §B anti-drift banner grep (both binding-map files)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART C — anti-drift banner grep (§B) ──"

grep -q "ANTI-DRIFT: binds FROZEN MACHINE-STATE.md v1" "$USAGE_LIB" \
  && ok "daemon/usage-poll.sh carries §B anti-drift banner (MACHINE-STATE.md v1)" \
  || bad "daemon/usage-poll.sh §B banner"
grep -q "ANTI-DRIFT: binds FROZEN MACHINE-STATE.md v1" "$CF_MACHINE_STATE" \
  && ok "cf/src/machine-state.js carries §B anti-drift banner (MACHINE-STATE.md v1)" \
  || bad "cf/src/machine-state.js §B banner"

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " C12 D2 producer: PASS=$PASS FAIL=$FAIL"
echo "════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "✓ C12 (claude-tools-zdxd.3) — D2 producer emits the §1.1 telemetry shape"
