#!/bin/bash
# uxvi1 (FORWARD / v2) — activity-state STREAM fact-extraction, table-driven.
#
# Binds: design/activity.md §1.1 (where it taps / what it sees) + §1.3 (the two
# detector refinements: real-429-not-subscription, waiting-suppresses-stuck).
# The PURE enum/precedence classifier is pinned separately by the sibling
# bc-uxvi1-activity-parser.sh (the lib/activity-classifier.sh unit). THIS rig
# pins the NEW surface uxvi1 adds on top of it: lib/activity-report.sh, which
# extracts the classifier's input FACTS from a real claude `--output-format
# stream-json` capture —
#   • the LAST tool_use name (read from assistant message CONTENT blocks, the
#     design's canonical path — NOT the unreliable top-level tool_use) + its
#     Bash command;
#   • ask-brian-MCP-in-flight (last tool_use is the ask-brian call with NO
#     tool_result after it → §1.2 row 1, suppresses maybe-stuck);
#   • a REAL 429 in flight (system api_retry error=rate_limit as the most-recent
#     event) — and NOT a benign subscription-window rate_limit_event (the §1.3/t5k
#     correction).
#
# SCAR (silent-when-wrong): reading tool names off the top-level tool_use the
# stream does NOT reliably emit (→ blank tool → everything reads thinking); a
# benign allowed_warning subscription event mis-read as a red rate-limited state;
# an ask-brian block (legitimately >180s silent) rendered maybe-stuck.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/activity-report.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# _mk <name> — write a synthetic stream capture from stdin; echo its path.
_mk() { local p="$WORK/$1.jsonl"; cat > "$p"; printf '%s' "$p"; }

# _facts <file> <exp_name> <exp_cmd> <exp_ab> <exp_rl> <desc>
_facts() {
  local f="$1" en="$2" ec="$3" eab="$4" erl="$5" desc="$6"
  local raw gn gc gab grl
  raw="$(activity_facts_from_stream "$f")"
  IFS=$'\x1f' read -r gn gc gab grl <<<"${raw//$'\t'/$'\x1f'}"
  : "${gn:=}"; : "${gc:=}"; : "${gab:=0}"; : "${grl:=0}"
  _expect "uxvi1" "activity.md§1.1" "$desc"
  _need "tool name '$gn' == '$en'"            test "$gn"  = "$en"
  _need "bash cmd '$gc' == '$ec'"             test "$gc"  = "$ec"
  _need "askbrian-inflight $gab == $eab"      test "$gab" = "$eab"
  _need "rate-limited $grl == $erl"           test "$grl" = "$erl"
  _emit
}

# _sstate <file> <delta> <exp_state> <desc> — end-to-end stream→state at a pinned Δ
_sstate() {
  local f="$1" d="$2" es="$3" desc="$4" got
  got="$(activity_state_from_stream "$f" "$d" | cut -f1)"
  _expect "uxvi1" "activity.md§1.2" "$desc"
  _need "Δ=$d ⇒ state '$got' == '$es'" test "$got" = "$es"
  _need "state '$got' is in the closed D.2 enum" \
    bash -c 'case "'"$got"'" in writing-code|running-tests|exploring|thinking|waiting-on-you|rate-limited|maybe-stuck) exit 0;; *) exit 1;; esac'
  _emit
}

# ── tool names come from assistant message CONTENT blocks (the design path) ───
F_EDIT="$(_mk edit <<'EOF'
{"type":"system","subtype":"init"}
{"type":"assistant","message":{"content":[{"type":"text","text":"now editing"},{"type":"tool_use","name":"Edit","input":{"file_path":"/x"}}]}}
EOF
)"
_facts  "$F_EDIT" "Edit" "" 0 0 "Edit tool_use read from assistant content (not top-level)"
_sstate "$F_EDIT" 10 writing-code "Edit ⇒ writing-code (live)"

F_TEST="$(_mk test <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"pytest -q tests/"}}]}}
EOF
)"
_facts  "$F_TEST" "Bash" "pytest -q tests/" 0 0 "Bash tool_use carries .input.command"
_sstate "$F_TEST" 10 running-tests "Bash 'pytest' ⇒ running-tests"

F_EXPLORE="$(_mk explore <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls -la /tmp"}}]}}
EOF
)"
_facts  "$F_EXPLORE" "Bash" "ls -la /tmp" 0 0 "non-test Bash command captured"
_sstate "$F_EXPLORE" 10 exploring "non-test Bash ⇒ exploring"

F_READ="$(_mk read <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Grep","input":{"pattern":"foo"}}]}}
EOF
)"
_sstate "$F_READ" 10 exploring "Grep ⇒ exploring"

# LAST tool_use wins across multiple assistant events (Read then Write).
F_LAST="$(_mk last <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/y"}}]}}
EOF
)"
_facts  "$F_LAST" "Write" "" 0 0 "the LAST tool_use wins (Read→Write ⇒ Write)"
_sstate "$F_LAST" 10 writing-code "last tool Write ⇒ writing-code"

# ── ask-brian MCP in flight: last tool_use is the ask-brian call, no result ──
F_ASK="$(_mk ask <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a1"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__askbrian__ask-brian","input":{"question":"which?"}}]}}
EOF
)"
_facts  "$F_ASK" "mcp__askbrian__ask-brian" "" 1 0 "ask-brian in flight (no result after the call)"
_sstate "$F_ASK" 10   waiting-on-you "ask-brian in flight ⇒ waiting-on-you"
_sstate "$F_ASK" 5000 waiting-on-you "ask-brian SUPPRESSES maybe-stuck even at Δ=5000 (§1.3)"

# ask-brian RESOLVED: a tool_result + further work AFTER the ask-brian call.
F_ASKDONE="$(_mk askdone <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__askbrian__ask-brian","input":{}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a9"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{}}]}}
EOF
)"
_facts  "$F_ASKDONE" "Edit" "" 0 0 "ask-brian answered ⇒ NOT in flight (work resumed)"
_sstate "$F_ASKDONE" 10 writing-code "ask-brian answered ⇒ back to writing-code"

# ── real 429 vs benign subscription telemetry (§1.3 / t5k) ───────────────────
F_RL="$(_mk rl <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{}}]}}
{"type":"system","subtype":"api_retry","error":"rate_limit","error_status":429,"attempt":1,"max_retries":5}
EOF
)"
_facts  "$F_RL" "Edit" "" 0 1 "real 429 (api_retry rate_limit) most-recent ⇒ rate-limited fact"
_sstate "$F_RL" 10  rate-limited "real 429 in flight ⇒ rate-limited"
_sstate "$F_RL" 300 rate-limited "real 429 beats the silence gate"

# A retry FOLLOWED by resumed work is NOT in flight.
F_RLDONE="$(_mk rldone <<'EOF'
{"type":"system","subtype":"api_retry","error":"rate_limit","error_status":429,"attempt":1,"max_retries":5}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{}}]}}
EOF
)"
_facts  "$F_RLDONE" "Edit" "" 0 0 "429 then resumed work ⇒ NOT rate-limited"
_sstate "$F_RLDONE" 10 writing-code "resumed after 429 ⇒ writing-code"

F_BENIGN="$(_mk benign <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}
{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","rateLimitType":"seven_day","utilization":85}}
EOF
)"
_facts  "$F_BENIGN" "Read" "" 0 0 "benign allowed_warning subscription event is NOT a 429 (§1.3/t5k)"
_sstate "$F_BENIGN" 10 exploring "benign subscription telemetry ⇒ stays exploring (not red)"

# ── robustness: non-JSON stderr noise, empty + missing captures ──────────────
F_NOISE="$(_mk noise <<'EOF'
  [12:00:00] a human-readable log line on stderr
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"MultiEdit","input":{}}]}}
warning: partial line {"type":"asst"}truncated-not-valid-json
EOF
)"
_facts  "$F_NOISE" "MultiEdit" "" 0 0 "non-JSON + truncated lines tolerated (fromjson? drops them)"
_sstate "$F_NOISE" 10 writing-code "MultiEdit amid noise ⇒ writing-code"

F_EMPTY="$(_mk empty </dev/null)"
_facts  "$F_EMPTY" "" "" 0 0 "empty capture ⇒ no facts (no tool, no flags)"
_sstate "$F_EMPTY" 10 thinking "empty capture, live ⇒ thinking (soft)"
_facts  "$WORK/does-not-exist.jsonl" "" "" 0 0 "missing capture ⇒ no facts (graceful)"

# ── silence gate still wins over an event-keyed tool state (end-to-end) ───────
_sstate "$F_EDIT" 181 maybe-stuck "Δ=181 with an Edit ⇒ maybe-stuck (silence gate wins)"
_sstate "$F_EDIT" 95  thinking    "Δ=95 (amber) with an Edit ⇒ thinking (silence gate wins)"
