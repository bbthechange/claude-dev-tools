#!/bin/bash
# beads-runner/daemon/test-m2-usage-poll.sh — M2 daemon-owned Anthropic
# usage poll (claude-tools-8mz; epic claude-tools-kie).
#
# WHAT THIS PROVES
#   PART 0 — files exist, parse, are wired into daemon.sh + local-agent.sh.
#   PART A — daemon_usage_poll_once reads the Keychain ONCE per call, hits
#            the Anthropic API ONCE per call, writes capacity.json with the
#            full {pct_5h, pct_7d, spare_ramp_today, allowed_cost_classes,
#            observed_at, expires_at} contract, and emits the §1.1 capacity
#            report to its own outbox.
#   PART B — daemon_usage_poll_once degrades fail-OPEN on Keychain or API
#            failure: cache lands with permissive allowed_cost_classes; the
#            workspace doesn't gate (BC-34 preserved at the producer too).
#   PART C — the ACCEPTANCE: with the daemon's capacity.json fresh, a
#            workspace runner's la_capacity_check makes ZERO direct
#            Keychain reads and ZERO direct Anthropic API calls. The cached
#            verdict alone gates the workspace. (Verified by counting calls
#            to fake `security` + `curl` bins on the workspace's PATH.)
#   PART D — fail-OPEN fallback: with the daemon's capacity.json ABSENT,
#            la_capacity_check transparently falls back to its direct
#            Keychain+API path (BC-34 §6.2 fail-OPEN preserved).
#   PART E — staleness: a capacity.json older than 2 × USAGE_CACHE_SECONDS
#            is treated as dead by the workspace and the fallback path is
#            taken (no stale verdict gets stuck after a daemon crash).
#   PART F — daemon.sh wires usage-poll.sh into the main loop (sourced,
#            USAGE_POLL_INTERVAL declared, driver call site present) —
#            the static checks that catch a refactor silently unwiring M2.
#
# Mirrors the structure of test-m3-desired-state.sh / test-m4-hosted-
# resolution-poll.sh. Run: bash beads-runner/daemon/test-m2-usage-poll.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
LIB_DIR="$REPO_ROOT/lib"
DAEMON_SH="$HERE/daemon.sh"
USAGE_LIB="$HERE/usage-poll.sh"
LOCAL_AGENT_LIB="$LIB_DIR/local-agent.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
eq()  { [[ "$1" == "$2" ]] && ok "$3" || bad "$3 (got '$1' want '$2')"; }
has() { case "$1" in *"$2"*) ok "$3";; *) bad "$3 (missing '$2')";; esac; }
nothas() { case "$1" in *"$2"*) bad "$3 (unexpectedly contains '$2')";; *) ok "$3";; esac; }

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " M2 daemon-owned Anthropic usage poll — claude-tools-8mz"
echo "════════════════════════════════════════════════════════════════════"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ════════════════════════════════════════════════════════════════════════════
# PART 0 — files exist, parse, are wired (static)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART 0 — files exist, parse, are wired (static) ──"
[[ -f "$USAGE_LIB" ]]      && ok "usage-poll.sh present"      || bad "usage-poll.sh missing"
bash -n "$USAGE_LIB" 2>/dev/null  && ok "usage-poll.sh parses (bash -n clean)" || bad "usage-poll.sh syntax"
bash -n "$DAEMON_SH" 2>/dev/null  && ok "daemon.sh parses (bash -n clean) with M2 wiring" || bad "daemon.sh syntax"
bash -n "$LOCAL_AGENT_LIB" 2>/dev/null && ok "local-agent.sh parses (bash -n clean) with M2 wiring" || bad "local-agent.sh syntax"

for fn in daemon_usage_poll_once daemon_usage_drain \
          _usage_poll_read_token _usage_poll_call_api \
          _usage_poll_compute_allowed _usage_poll_write_cache \
          _usage_poll_emit_capacity_report; do
  grep -q "^$fn()" "$USAGE_LIB" && ok "usage-poll.sh defines $fn" || bad "usage-poll.sh defines $fn"
done

grep -q "la__capacity_via_daemon" "$LOCAL_AGENT_LIB" \
  && ok "local-agent.sh defines la__capacity_via_daemon" \
  || bad "local-agent.sh defines la__capacity_via_daemon"
grep -q "la__daemon_capacity_file" "$LOCAL_AGENT_LIB" \
  && ok "local-agent.sh defines la__daemon_capacity_file" \
  || bad "local-agent.sh defines la__daemon_capacity_file"

# ════════════════════════════════════════════════════════════════════════════
# PART A — daemon_usage_poll_once produces the contract cache + outbox
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART A — daemon_usage_poll_once produces capacity.json + outbox ──"

PART_A="$WORK/partA"
mkdir -p "$PART_A/bin" "$PART_A/cache"

# Fake `security` (returns a parseable creds blob) and `curl` (returns
# under-threshold usage). Both record their invocation count.
cat > "$PART_A/bin/security" <<'EOF'
#!/bin/bash
echo "security $*" >> "${M2T_SEC_CALLS:-/dev/null}"
echo '{"claudeAiOauth":{"accessToken":"daemon-stub-token"}}'
exit 0
EOF
cat > "$PART_A/bin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "${M2T_CURL_CALLS:-/dev/null}"
echo '{"five_hour":{"utilization":10},"seven_day":{"utilization":20}}'
exit 0
EOF
chmod +x "$PART_A/bin/security" "$PART_A/bin/curl"

export M2T_SEC_CALLS="$PART_A/sec.calls"
export M2T_CURL_CALLS="$PART_A/curl.calls"
: > "$M2T_SEC_CALLS"; : > "$M2T_CURL_CALLS"

(
  set -u
  export PATH="$PART_A/bin:$PATH"
  export BEADS_DAEMON_CACHE_DIR="$PART_A/cache"
  export USAGE_THRESHOLD=70
  export USAGE_CACHE_SECONDS=300
  export SPARE_DAY_INDEX=1
  export USAGE_POLL_DISABLED=0
  # shellcheck source=/dev/null
  . "$USAGE_LIB"
  # The poll lib captures BEADS_DAEMON_CACHE_DIR at source-time into
  # USAGE_POLL_CACHE_DIR; the daemon sources it BEFORE main() so it sees the
  # final env. Re-export those derived paths to match the daemon's runtime.
  USAGE_POLL_CACHE_DIR="$BEADS_DAEMON_CACHE_DIR"
  USAGE_POLL_CACHE_FILE="$USAGE_POLL_CACHE_DIR/capacity.json"
  USAGE_POLL_OUTBOX="$USAGE_POLL_CACHE_DIR/coordinator-outbox.jsonl"
  daemon_usage_poll_once
)

CACHE="$PART_A/cache/capacity.json"
OUTBOX="$PART_A/cache/coordinator-outbox.jsonl"

[[ -f "$CACHE" ]] && ok "capacity.json written" || bad "capacity.json missing"
jq -e . "$CACHE" >/dev/null 2>&1 && ok "capacity.json is valid JSON" || bad "capacity.json not valid JSON"

eq "$(jq -r '.schema_version' "$CACHE")" "1"                          "schema_version=1"
eq "$(jq -r '.pct_5h'         "$CACHE")" "10"                         "pct_5h=10"
eq "$(jq -r '.pct_7d'         "$CACHE")" "20"                         "pct_7d=20"
eq "$(jq -r '.spare_ramp_today' "$CACHE")" "14"                       "spare_ramp_today=14 (day1 × 14.2)"
jq -e '.allowed_cost_classes | type == "array"' "$CACHE" >/dev/null \
  && ok "allowed_cost_classes is an array" || bad "allowed_cost_classes is an array"
# Day1: ramp=14, pct_7d=20 ≥ ramp ⇒ low_priority gated, standard ok.
eq "$(jq -r '.allowed_cost_classes | length' "$CACHE")" "1"           "allowed_cost_classes length=1 (standard only — pct_7d ≥ ramp)"
eq "$(jq -r '.allowed_cost_classes[0]' "$CACHE")" "standard"          "allowed_cost_classes[0]=standard"

# Exactly one Keychain read + one usage-API curl per poll cycle.
eq "$(wc -l < "$M2T_SEC_CALLS"  | tr -d ' ')" "1" "security invoked exactly ONCE per poll"
eq "$(wc -l < "$M2T_CURL_CALLS" | tr -d ' ')" "1" "curl invoked exactly ONCE per poll"
grep -q "Claude Code-credentials" "$M2T_SEC_CALLS" && ok "Keychain item probed is 'Claude Code-credentials'" || bad "Keychain item probed is 'Claude Code-credentials'"
grep -q "api.anthropic.com/api/oauth/usage" "$M2T_CURL_CALLS" && ok "curl hit the Anthropic usage endpoint" || bad "curl hit the Anthropic usage endpoint"

# §1.1 outbox — one capacity record per cost class.
[[ -f "$OUTBOX" ]] && ok "daemon outbox written" || bad "daemon outbox missing"
eq "$(grep -c '"report":"capacity"' "$OUTBOX" 2>/dev/null || echo 0)" "2" "daemon emits 2 §1.1 capacity reports (standard + low_priority)"
grep -q '"cost_class":"standard"'     "$OUTBOX" && ok "standard verdict reported"     || bad "standard verdict reported"
grep -q '"cost_class":"low_priority"' "$OUTBOX" && ok "low_priority verdict reported" || bad "low_priority verdict reported"
# Day1 ramp: pct_7d=20 ≥ ramp=14 ⇒ low_priority OVER, standard OK.
grep -q '"cost_class":"low_priority","verdict":"over"' "$OUTBOX" && ok "low_priority verdict=over (pct_7d ≥ ramp)" || bad "low_priority verdict=over (pct_7d ≥ ramp)"
grep -q '"cost_class":"standard","verdict":"ok"' "$OUTBOX" && ok "standard verdict=ok (pct_5h<70 & pct_7d<70)" || bad "standard verdict=ok"

# ════════════════════════════════════════════════════════════════════════════
# PART B — daemon poll fails OPEN on Keychain / API errors
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART B — daemon poll fails OPEN on Keychain / API errors (BC-34) ──"

PART_B="$WORK/partB"
mkdir -p "$PART_B/bin" "$PART_B/cache-keychain-fail" "$PART_B/cache-api-fail"

# security returns nonzero → keychain unreadable.
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
  export BEADS_DAEMON_CACHE_DIR="$PART_B/cache-keychain-fail"
  export USAGE_THRESHOLD=70
  export USAGE_CACHE_SECONDS=300
  # shellcheck source=/dev/null
  . "$USAGE_LIB"
  USAGE_POLL_CACHE_DIR="$BEADS_DAEMON_CACHE_DIR"
  USAGE_POLL_CACHE_FILE="$USAGE_POLL_CACHE_DIR/capacity.json"
  USAGE_POLL_OUTBOX="$USAGE_POLL_CACHE_DIR/coordinator-outbox.jsonl"
  daemon_usage_poll_once
)

KC_FAIL_CACHE="$PART_B/cache-keychain-fail/capacity.json"
[[ -f "$KC_FAIL_CACHE" ]] && ok "Keychain-fail still writes a permissive cache (fail-OPEN)" || bad "Keychain-fail writes a cache"
eq "$(jq -r '.allowed_cost_classes | length' "$KC_FAIL_CACHE")" "2" "Keychain-fail cache allows BOTH cost classes (permissive)"

# API-fail path: curl returns nonzero.
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
  # shellcheck source=/dev/null
  . "$USAGE_LIB"
  USAGE_POLL_CACHE_DIR="$BEADS_DAEMON_CACHE_DIR"
  USAGE_POLL_CACHE_FILE="$USAGE_POLL_CACHE_DIR/capacity.json"
  USAGE_POLL_OUTBOX="$USAGE_POLL_CACHE_DIR/coordinator-outbox.jsonl"
  daemon_usage_poll_once
)

API_FAIL_CACHE="$PART_B/cache-api-fail/capacity.json"
[[ -f "$API_FAIL_CACHE" ]] && ok "API-fail still writes a permissive cache (fail-OPEN)" || bad "API-fail writes a cache"
eq "$(jq -r '.allowed_cost_classes | length' "$API_FAIL_CACHE")" "2" "API-fail cache allows BOTH cost classes (permissive)"

# ════════════════════════════════════════════════════════════════════════════
# PART C — workspace makes ZERO direct API calls when daemon cache is fresh
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART C — ACCEPTANCE: workspace makes ZERO direct API calls via daemon ──"

PART_C="$WORK/partC"
mkdir -p "$PART_C/bin" "$PART_C/cache" "$PART_C/runner-logs"

# Workspace-side fakes: if these are EVER invoked, the workspace cheated
# past the daemon cache. The test asserts both files stay empty.
cat > "$PART_C/bin/security" <<'EOF'
#!/bin/bash
echo "WORKSPACE_HIT_KEYCHAIN $*" >> "${M2T_C_SEC_CALLS:-/dev/null}"
exit 1
EOF
cat > "$PART_C/bin/curl" <<'EOF'
#!/bin/bash
echo "WORKSPACE_HIT_API $*" >> "${M2T_C_CURL_CALLS:-/dev/null}"
exit 1
EOF
chmod +x "$PART_C/bin/security" "$PART_C/bin/curl"

# Plant a FRESH, PERMISSIVE daemon capacity.json directly (we already
# tested the producer in PART A; here we test the consumer in isolation).
cat > "$PART_C/cache/capacity.json" <<EOF
{"schema_version":1,"pct_5h":5,"pct_7d":10,"spare_ramp_today":100,"allowed_cost_classes":["standard","low_priority"],"observed_at":"2026-01-01T00:00:00Z","expires_at":"2026-01-01T00:05:00Z"}
EOF

export M2T_C_SEC_CALLS="$PART_C/sec.calls"
export M2T_C_CURL_CALLS="$PART_C/curl.calls"
: > "$M2T_C_SEC_CALLS"; : > "$M2T_C_CURL_CALLS"

RESULT_STD="$(
  set -u
  export PATH="$PART_C/bin:$PATH"
  export BEADS_DAEMON_CACHE_DIR="$PART_C/cache"
  export LOG_DIR="$PART_C/runner-logs"
  export RUNNER_ID="m2-acceptance-runner"
  export USAGE_THRESHOLD=70
  export USAGE_CACHE_SECONDS=300
  # shellcheck source=/dev/null
  . "$LOCAL_AGENT_LIB"
  if la_capacity_check standard >/dev/null 2>&1; then echo OK; else echo OVER; fi
)"
eq "$RESULT_STD" "OK" "la_capacity_check standard ⇒ ok (permissive daemon cache)"

RESULT_LP="$(
  set -u
  export PATH="$PART_C/bin:$PATH"
  export BEADS_DAEMON_CACHE_DIR="$PART_C/cache"
  export LOG_DIR="$PART_C/runner-logs"
  export RUNNER_ID="m2-acceptance-runner"
  export USAGE_THRESHOLD=70
  export USAGE_CACHE_SECONDS=300
  # shellcheck source=/dev/null
  . "$LOCAL_AGENT_LIB"
  if la_capacity_check low_priority >/dev/null 2>&1; then echo OK; else echo OVER; fi
)"
eq "$RESULT_LP" "OK" "la_capacity_check low_priority ⇒ ok (permissive daemon cache)"

# THE CORE ACCEPTANCE — zero workspace-side credential / API hits.
[[ ! -s "$M2T_C_SEC_CALLS"  ]] && ok "workspace NEVER touched Keychain (acceptance)" \
                              || bad "workspace touched Keychain (acceptance broken): $(cat "$M2T_C_SEC_CALLS")"
[[ ! -s "$M2T_C_CURL_CALLS" ]] && ok "workspace NEVER touched Anthropic API (acceptance)" \
                              || bad "workspace touched Anthropic API (acceptance broken): $(cat "$M2T_C_CURL_CALLS")"

# §1.1 capacity report: workspace MUST NOT emit one (the daemon owns it).
WORKSPACE_OUTBOX="$PART_C/runner-logs/coordinator-outbox.jsonl"
if [[ -f "$WORKSPACE_OUTBOX" ]]; then
  eq "$(grep -c '"report":"capacity"' "$WORKSPACE_OUTBOX" 2>/dev/null || echo 0)" "0" "workspace outbox has 0 capacity reports (daemon owns them)"
else
  ok "workspace outbox absent (no per-workspace capacity report — correct)"
fi

# Verify a GATED cache produces the OVER verdict on the workspace side.
cat > "$PART_C/cache/capacity.json" <<EOF
{"schema_version":1,"pct_5h":95,"pct_7d":40,"spare_ramp_today":100,"allowed_cost_classes":[],"observed_at":"2026-01-01T00:00:00Z","expires_at":"2026-01-01T00:05:00Z"}
EOF
: > "$M2T_C_SEC_CALLS"; : > "$M2T_C_CURL_CALLS"

RESULT_OVER="$(
  set -u
  export PATH="$PART_C/bin:$PATH"
  export BEADS_DAEMON_CACHE_DIR="$PART_C/cache"
  export LOG_DIR="$PART_C/runner-logs"
  export RUNNER_ID="m2-acceptance-runner"
  export USAGE_THRESHOLD=70
  export USAGE_CACHE_SECONDS=300
  # shellcheck source=/dev/null
  . "$LOCAL_AGENT_LIB"
  if la_capacity_check standard >/dev/null 2>&1; then echo OK; else echo OVER; fi
)"
eq "$RESULT_OVER" "OVER" "la_capacity_check standard ⇒ over (daemon cache gates both classes)"
[[ ! -s "$M2T_C_SEC_CALLS"  ]] && ok "workspace still didn't touch Keychain on OVER verdict" || bad "workspace touched Keychain on OVER verdict"
[[ ! -s "$M2T_C_CURL_CALLS" ]] && ok "workspace still didn't touch API on OVER verdict"      || bad "workspace touched API on OVER verdict"

# ════════════════════════════════════════════════════════════════════════════
# PART D — daemon ABSENT ⇒ workspace falls back to direct path (BC-34)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART D — daemon absent ⇒ workspace falls back to direct API path ──"

PART_D="$WORK/partD"
mkdir -p "$PART_D/bin" "$PART_D/empty-cache" "$PART_D/runner-logs"

cat > "$PART_D/bin/security" <<'EOF'
#!/bin/bash
echo "security $*" >> "${M2T_D_SEC_CALLS:-/dev/null}"
echo '{"claudeAiOauth":{"accessToken":"fallback-stub"}}'
exit 0
EOF
cat > "$PART_D/bin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "${M2T_D_CURL_CALLS:-/dev/null}"
echo '{"five_hour":{"utilization":15},"seven_day":{"utilization":25}}'
exit 0
EOF
chmod +x "$PART_D/bin/security" "$PART_D/bin/curl"

export M2T_D_SEC_CALLS="$PART_D/sec.calls"
export M2T_D_CURL_CALLS="$PART_D/curl.calls"
: > "$M2T_D_SEC_CALLS"; : > "$M2T_D_CURL_CALLS"

RESULT_FB="$(
  set -u
  export PATH="$PART_D/bin:$PATH"
  export BEADS_DAEMON_CACHE_DIR="$PART_D/empty-cache"  # contains NO capacity.json
  export LOG_DIR="$PART_D/runner-logs"
  export RUNNER_ID="m2-fallback-runner"
  export USAGE_THRESHOLD=70
  export USAGE_CACHE_SECONDS=300
  # shellcheck source=/dev/null
  . "$LOCAL_AGENT_LIB"
  if la_capacity_check standard >/dev/null 2>&1; then echo OK; else echo OVER; fi
)"
eq "$RESULT_FB" "OK" "la_capacity_check standard ⇒ ok (fallback to direct API, 5h=15/7d=25 < 70)"
[[ -s "$M2T_D_SEC_CALLS"  ]] && ok "workspace DID touch Keychain on daemon-absent fallback" || bad "workspace did not touch Keychain on fallback"
[[ -s "$M2T_D_CURL_CALLS" ]] && ok "workspace DID touch Anthropic API on daemon-absent fallback" || bad "workspace did not touch API on fallback"

# Genuine fail-OPEN posture preserved: a fallback path whose Keychain also
# fails MUST still return 0 (BC-34).
cat > "$PART_D/bin/security" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$PART_D/bin/security"
RESULT_OPEN="$(
  set -u
  export PATH="$PART_D/bin:$PATH"
  export BEADS_DAEMON_CACHE_DIR="$PART_D/empty-cache"
  export LOG_DIR="$PART_D/runner-logs"
  export RUNNER_ID="m2-fallback-runner"
  export USAGE_THRESHOLD=70
  # shellcheck source=/dev/null
  . "$LOCAL_AGENT_LIB"
  if la_capacity_check standard 2>/dev/null; then echo OK; else echo OVER; fi
)"
eq "$RESULT_OPEN" "OK" "fallback Keychain-fail ⇒ fail-OPEN (BC-34 preserved end-to-end)"

# ════════════════════════════════════════════════════════════════════════════
# PART E — stale daemon cache (> 2× TTL) is treated as dead
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART E — stale daemon cache ⇒ fallback (no stuck-stale verdict) ──"

PART_E="$WORK/partE"
mkdir -p "$PART_E/bin" "$PART_E/cache" "$PART_E/runner-logs"

cat > "$PART_E/bin/security" <<'EOF'
#!/bin/bash
echo "security $*" >> "${M2T_E_SEC_CALLS:-/dev/null}"
echo '{"claudeAiOauth":{"accessToken":"stale-fallback-stub"}}'
exit 0
EOF
cat > "$PART_E/bin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "${M2T_E_CURL_CALLS:-/dev/null}"
echo '{"five_hour":{"utilization":5},"seven_day":{"utilization":5}}'
exit 0
EOF
chmod +x "$PART_E/bin/security" "$PART_E/bin/curl"

# Write a cache file then age its mtime past 2 × USAGE_CACHE_SECONDS.
cat > "$PART_E/cache/capacity.json" <<EOF
{"schema_version":1,"pct_5h":99,"pct_7d":99,"spare_ramp_today":100,"allowed_cost_classes":[],"observed_at":"1970-01-01T00:00:00Z","expires_at":"1970-01-01T00:05:00Z"}
EOF
# 2 hours ago — well past 2 × 300s.
touch -t 197001010000 "$PART_E/cache/capacity.json" 2>/dev/null || \
  touch -d "2 hours ago" "$PART_E/cache/capacity.json" 2>/dev/null || true

export M2T_E_SEC_CALLS="$PART_E/sec.calls"
export M2T_E_CURL_CALLS="$PART_E/curl.calls"
: > "$M2T_E_SEC_CALLS"; : > "$M2T_E_CURL_CALLS"

RESULT_STALE="$(
  set -u
  export PATH="$PART_E/bin:$PATH"
  export BEADS_DAEMON_CACHE_DIR="$PART_E/cache"
  export LOG_DIR="$PART_E/runner-logs"
  export RUNNER_ID="m2-stale-runner"
  export USAGE_THRESHOLD=70
  export USAGE_CACHE_SECONDS=300
  # shellcheck source=/dev/null
  . "$LOCAL_AGENT_LIB"
  if la_capacity_check standard >/dev/null 2>&1; then echo OK; else echo OVER; fi
)"
# Stale cache had allowed=[] (would gate). The workspace should IGNORE it
# and fall through to direct API (which returns 5%/5% ⇒ ok).
eq "$RESULT_STALE" "OK" "stale daemon cache ⇒ ignored; fallback API returns ok"
[[ -s "$M2T_E_CURL_CALLS" ]] && ok "stale cache ⇒ workspace called direct API (correct)" || bad "stale cache ⇒ workspace should have called direct API"

# ════════════════════════════════════════════════════════════════════════════
# PART F — daemon.sh wires usage-poll.sh into the main loop (static)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART F — daemon.sh wires usage-poll.sh into the main loop ──"

grep -q '\. "\$DAEMON_DIR/usage-poll.sh"' "$DAEMON_SH" \
  && ok "daemon.sh sources usage-poll.sh" \
  || bad "daemon.sh sources usage-poll.sh"
grep -q 'USAGE_POLL_INTERVAL=' "$DAEMON_SH" \
  && ok "daemon.sh declares USAGE_POLL_INTERVAL" \
  || bad "daemon.sh declares USAGE_POLL_INTERVAL"
grep -q 'daemon_usage_poll_once' "$DAEMON_SH" \
  && ok "daemon.sh calls daemon_usage_poll_once in the main loop" \
  || bad "daemon.sh calls daemon_usage_poll_once"
grep -q 'daemon_usage_drain'    "$DAEMON_SH" \
  && ok "daemon.sh calls daemon_usage_drain on EXIT" \
  || bad "daemon.sh calls daemon_usage_drain"

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " M2 acceptance: PASS=$PASS FAIL=$FAIL"
echo "════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "✓ M2 (claude-tools-8mz) — daemon owns the Anthropic usage poll; workspaces consult it"
