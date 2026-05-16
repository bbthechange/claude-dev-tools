#!/bin/bash
# O-1 headless version probe — T1c (claude-tools-0vt).
#
# WHY: AD3's whole stuck-signal defense rests on UNDOCUMENTED, version-pinned
# `claude` behavior (research/headless-stuck-signal.md, characterized against
# claude 2.1.142). A `claude` upgrade can silently regress the
# AskUserQuestion / EnterPlanMode / ExitPlanMode backstops with no other
# warning. This script is the owned canary: it re-asserts, on the INSTALLED
# `claude`, every empirical fact §7.2/§7.6 + AD3.x depend on, and exits
# non-zero on ANY drift. A red probe blocks trusting the AD3 backstops.
#
# Binds: INTERFACE.md v1 §7.2 (two-trigger detection — the backstop scans
#        result.permission_denials[] + the "Entered plan mode." tool_result),
#        §7.6 (--disallowedTools guardrail), DESIGN AD3.1/AD3.3/AD3.5.
#        Source of truth for expected shapes: research/headless-stuck-signal.md.
#
# MUST RE-RUN ON EVERY `claude` UPGRADE. It is intentionally NOT in
# conformance/assertions/bc-*.sh (run-conformance.sh's offline regression glob)
# because it invokes the live, networked `claude` binary; it is a separate
# upgrade-gated canary the conformance gate REFERENCES (see conformance/README).
#
# RESULT protocol (same as lib/harness.sh, so output can be aggregated):
#   RESULT|PASS|O-1|<cite>|<desc>     installed claude matches the AD3 contract
#   RESULT|FAIL|O-1|<cite>|<desc>     DRIFT — AD3 assumption no longer holds
#
# Exit codes:
#   0  every assertion PASS — AD3 backstops safe to trust on this claude
#   1  >=1 assertion FAIL — DRIFT; AD3 backstops must NOT be trusted as-is
#   2  probe could not run (missing claude/jq, auth/network) — NOT drift,
#      but still non-zero: an un-runnable canary cannot certify AD3 either.
#
# Usage:  bash beads-runner/conformance/probes/o1-headless-version-probe.sh
set -u

MODEL="claude-sonnet-4-6"          # tool-availability is model-independent
                                   # (research Q3); pinned for cost/determinism.
PROBE_PASS=0
PROBE_FAIL=0

emit() { # status desc
  printf 'RESULT|%s|O-1|§7.2/§7.6|%s\n' "$1" "$2"
}
pass() { PROBE_PASS=$((PROBE_PASS+1)); emit PASS "$1"; }
fail() { PROBE_FAIL=$((PROBE_FAIL+1)); emit FAIL "$1"; echo "    DRIFT: $1 — $2" >&2; }

# ── Environment preflight (env failure ≠ drift; exit 2) ──────────────────────
command -v claude >/dev/null 2>&1 || { echo "✗ probe cannot run: 'claude' not on PATH" >&2; exit 2; }
command -v jq     >/dev/null 2>&1 || { echo "✗ probe cannot run: 'jq' not on PATH" >&2; exit 2; }

CLAUDE_VERSION="$(claude --version 2>/dev/null | tr -d '\n')"
echo "═══════════════════════════════════════════════════════════════════════"
echo " O-1 headless version probe — T1c (claude-tools-0vt)"
echo " claude under test : ${CLAUDE_VERSION:-<unknown>}"
echo " research baseline : claude 2.1.142 (research/headless-stuck-signal.md)"
echo " binds             : INTERFACE.md v1 §7.2/§7.6 · DESIGN AD3.1/3.3/3.5"
echo "═══════════════════════════════════════════════════════════════════════"
[[ "$CLAUDE_VERSION" == *"2.1.142"* ]] || \
  echo " NOTE: installed claude ($CLAUDE_VERSION) ≠ research baseline 2.1.142 —" \
       "this run is exactly the upgrade-revalidation this probe exists for." >&2

# Isolated throwaway workspace — this repo is never touched (research §Environment).
WORK="$(mktemp -d 2>/dev/null)" || { echo "✗ probe cannot run: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
( cd "$WORK" && git init -q . 2>/dev/null ) || true

# Portable bounded run of `claude -p`. Captures stream-json to $1; echoes the
# process exit code on stdout. Uses (g)timeout when available.
TIMEOUT_BIN=""
command -v timeout  >/dev/null 2>&1 && TIMEOUT_BIN="timeout"
command -v gtimeout >/dev/null 2>&1 && TIMEOUT_BIN="gtimeout"
run_claude() { # outfile prompt extra-args...
  local out="$1" prompt="$2"; shift 2
  local rc
  if [[ -n "$TIMEOUT_BIN" ]]; then
    ( cd "$WORK" && $TIMEOUT_BIN 150 claude -p "$prompt" \
        --output-format stream-json --verbose --model "$MODEL" "$@" ) \
        >"$out" 2>>"$out"; rc=$?
  else
    ( cd "$WORK" && claude -p "$prompt" \
        --output-format stream-json --verbose --model "$MODEL" "$@" ) \
        >"$out" 2>>"$out"; rc=$?
  fi
  echo "$rc"
}

# jq helpers over a stream-json file (one JSON object per line; tolerate noise).
# NOTE: do NOT use `// empty` here — jq's `//` treats the boolean `false` as
# empty, so `is_error:false` would wrongly read as "" and falsely trip DRIFT.
result_field() { jq -rs --arg f "$2" 'map(select(.type=="result")) | last | (.[$f]) | if .==null then "" else tostring end' "$1" 2>/dev/null; }
denials_tools() { jq -rs 'map(select(.type=="result")) | last | (.permission_denials // []) | .[] | (.tool_name // .) ' "$1" 2>/dev/null; }
stream_has_tool_result_substr() { # file substr
  jq -rs --arg s "$2" '[.. | objects | select(.type? == "tool_result") | (.content|tostring) | select(contains($s))] | length' "$1" 2>/dev/null
}
init_tools() { jq -rs 'map(select(.type=="system" and (.subtype=="init"))) | last | (.tools // []) | .[]' "$1" 2>/dev/null; }

S="$WORK/stream.jsonl"

# ── A1 · AskUserQuestion → soft-fail (exit 0 / success) + denial record ──────
#    The §7.2 primary backstop hook. research Q1.
ec=$(run_claude "$S" 'Call the AskUserQuestion tool RIGHT NOW. Ask "Pick a color: red or blue?" with options red and blue. Do nothing else.' --max-turns 6)
if [[ "$ec" != "0" ]]; then
  fail "A1 AskUserQuestion is no longer exit-0 soft-fail" "exit=$ec (research: exit 0, subtype success)"
elif [[ "$(result_field "$S" subtype)" == "success" && "$(result_field "$S" is_error)" == "false" ]] \
   && denials_tools "$S" | grep -qx 'AskUserQuestion'; then
  pass "A1 AskUserQuestion → exit0/success/is_error:false WITH permission_denials[AskUserQuestion] (backstop hook intact)"
else
  fail "A1 AskUserQuestion soft-fail/denial shape drifted" \
       "subtype=$(result_field "$S" subtype) is_error=$(result_field "$S" is_error) denials=[$(denials_tools "$S" | tr '\n' ',')]"
fi

# ── A2 · EnterPlanMode → SILENT no-op (no denial) + "Entered plan mode." ─────
#    The residual gap §7.2 closes ONLY via the stream string. research Q2.
ec=$(run_claude "$S" 'Call the EnterPlanMode tool RIGHT NOW as your very first action. Do nothing else afterward.' --max-turns 6)
denials="$(denials_tools "$S" | tr '\n' ',' )"
hits="$(stream_has_tool_result_substr "$S" 'Entered plan mode.')"
if [[ "$ec" != "0" ]]; then
  fail "A2 EnterPlanMode is no longer exit-0" "exit=$ec"
elif [[ "$(result_field "$S" subtype)" == "success" && -z "${denials//,/}" && "${hits:-0}" -ge 1 ]]; then
  pass "A2 EnterPlanMode → silent exit0/success, NO permission_denials, stream carries 'Entered plan mode.' (the only backstop for this gap holds)"
else
  fail "A2 EnterPlanMode residual-gap signal drifted" \
       "subtype=$(result_field "$S" subtype) denials=[$denials] 'Entered plan mode.'-hits=${hits:-0} (expected: success, no denials, >=1 hit)"
fi

# ── A3 · ExitPlanMode (out of plan mode) → soft-fail, exit 0, not a crash ────
#    research Q2 (deterministic shape; the in-plan permission_denials[ExitPlanMode]
#    is a stronger signal but needs a model-authored plan first — not auto-probed).
ec=$(run_claude "$S" 'Call the ExitPlanMode tool RIGHT NOW as your very first action. Do nothing else.' --max-turns 6)
notinplan="$(stream_has_tool_result_substr "$S" 'not in plan mode')"
if [[ "$ec" != "0" ]]; then
  fail "A3 ExitPlanMode is no longer exit-0 soft-fail" "exit=$ec"
elif [[ "$(result_field "$S" subtype)" == "success" && "${notinplan:-0}" -ge 1 ]]; then
  pass "A3 ExitPlanMode (out of plan) → exit0/success soft-fail with 'not in plan mode' tool_result (shape stable)"
else
  fail "A3 ExitPlanMode soft-fail shape drifted" \
       "subtype=$(result_field "$S" subtype) 'not in plan mode'-hits=${notinplan:-0}"
fi

# ── A4 · --disallowedTools guardrail (§7.6) — tools not even advertised ──────
ec=$(run_claude "$S" 'Call the AskUserQuestion tool RIGHT NOW. Do nothing else.' --max-turns 4 --disallowedTools AskUserQuestion EnterPlanMode ExitPlanMode)
adv="$(init_tools "$S" | grep -E '^(AskUserQuestion|EnterPlanMode|ExitPlanMode)$' || true)"
if [[ "$ec" != "0" ]]; then
  fail "A4 guardrail run no longer exit-0" "exit=$ec"
elif [[ -z "$adv" ]]; then
  pass "A4 --disallowedTools removes AskUserQuestion/EnterPlanMode/ExitPlanMode from the advertised init tool list (§7.6 guardrail holds)"
else
  fail "A4 --disallowedTools no longer suppresses the interactive tools" \
       "still advertised: [$(echo "$adv" | tr '\n' ',')]"
fi

# ── Verdict ─────────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════════════════"
echo " O-1 verdict on ${CLAUDE_VERSION:-<unknown>}:  PASS=$PROBE_PASS  FAIL=$PROBE_FAIL"
if [[ "$PROBE_FAIL" -eq 0 ]]; then
  echo " ✓ AD3 backstop assumptions hold on this claude — §7.2/§7.6 safe to trust."
  echo "═══════════════════════════════════════════════════════════════════════"
  exit 0
else
  echo " ✗ DRIFT — an AD3 assumption changed on this claude. Per ANTI-DRIFT a"
  echo "   changed EXPECTED behavior is a BLOCKING escalation: reopen"
  echo "   claude-tools-65z (re-characterize research/headless-stuck-signal.md,"
  echo "   re-freeze §7.2/§7.6) — do NOT weaken this probe to make it green."
  echo "═══════════════════════════════════════════════════════════════════════"
  exit 1
fi
