#!/bin/bash
# beads-runner/hooks/test-build-settings.sh
#
# Unit tests for build-settings.sh — the ONE source of truth for the
# close-discipline hook's `claude --settings` JSON shape, shared by
# run-beads-tasks.sh (v1) and runner.sh (v2). (claude-tools-2fkp.)
#
# Run: bash beads-runner/hooks/test-build-settings.sh
# Exit 0 = all pass; non-zero = a test failed (failing test names printed).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/build-settings.sh"

[[ -f "$LIB" ]] || { echo "FAIL: builder not found at $LIB"; exit 1; }
# shellcheck source=build-settings.sh
source "$LIB"
command -v build_hook_settings >/dev/null 2>&1 \
  || { echo "FAIL: build_hook_settings not defined after sourcing $LIB"; exit 1; }

# ── Test harness ────────────────────────────────────────────────────────────
PASS=0
FAIL=0
FAILED_NAMES=()
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  FAIL %s\n' "$1" >&2; }
check(){ # check <name> <test-cmd...>  — pass iff cmd returns 0 (output suppressed)
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi
}
jqe()  { jq -e "$@"; }   # used via `check` (which suppresses output)

HOOK="/opt/some dir/hooks/close-checklist.sh"   # embeds a space — exercises quoting
OUT="$(mktemp -t build-settings.XXXX)"
EXP="$(mktemp -t build-settings-exp.XXXX)"
trap 'rm -f "$OUT" "$EXP"' EXIT

# ── 1. happy path: writes valid JSON, returns 0 ──────────────────────────────
check "returns 0 on success"                 build_hook_settings "$HOOK" "$OUT"
check "output is valid JSON"                  jqe . "$OUT"
check "PreToolUse matcher is Bash"            jqe '.hooks.PreToolUse[0].matcher == "Bash"' "$OUT"
check "PreToolUse fires the hook command"     jqe --arg c "$HOOK" '.hooks.PreToolUse[0].hooks[0].command == $c' "$OUT"
check "PreToolUse hook type is command"       jqe '.hooks.PreToolUse[0].hooks[0].type == "command"' "$OUT"
check "Stop matcher is empty (all stops)"     jqe '.hooks.Stop[0].matcher == ""' "$OUT"
check "Stop fires the hook command"           jqe --arg c "$HOOK" '.hooks.Stop[0].hooks[0].command == $c' "$OUT"
check "Stop hook type is command"             jqe '.hooks.Stop[0].hooks[0].type == "command"' "$OUT"
check "exactly two hook events wired"         jqe '(.hooks | keys | sort) == ["PreToolUse","Stop"]' "$OUT"

# ── 2. shape parity with the v1 inline jq (anti-drift guard) ─────────────────
# EXP is the literal JSON run-beads-tasks.sh emitted inline before the extract.
# If the shared shape ever diverges, this canonical compare fails LOUD.
jq -n --arg cmd "$HOOK" '{
  hooks: {
    PreToolUse: [{ matcher: "Bash",  hooks: [{ type: "command", command: $cmd }] }],
    Stop:       [{ matcher: "",      hooks: [{ type: "command", command: $cmd }] }]
  }
}' > "$EXP"
if diff <(jq -S . "$OUT") <(jq -S . "$EXP") >/dev/null 2>&1; then
  ok "matches the canonical v1 shape (anti-drift)"
else
  bad "matches the canonical v1 shape (anti-drift)"
fi

# ── 3. degrade: a missing jq returns non-zero (caller gates --settings on it) ─
# Shadow PATH with an empty dir so `command -v jq` fails inside the function.
NOJQ="$(mktemp -d -t build-settings-nojq.XXXX)"
if PATH="$NOJQ" build_hook_settings "$HOOK" "$OUT" 2>/dev/null; then
  bad "returns non-zero when jq is unavailable"
else
  ok "returns non-zero when jq is unavailable"
fi
rm -rf "$NOJQ"

# ── summary ──────────────────────────────────────────────────────────────────
echo ""
echo "build-settings: PASS=$PASS FAIL=$FAIL"
if [[ $FAIL -gt 0 ]]; then
  printf 'FAILED: %s\n' "${FAILED_NAMES[*]}" >&2
  exit 1
fi
exit 0
