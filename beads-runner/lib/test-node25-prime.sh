#!/bin/bash
# beads-runner/lib/test-node25-prime.sh — focused unit test for node25-prime.sh
# (claude-tools-18c, the shared helper that DRYs the three sibling fixes:
# specialist.sh = claude-tools-3kd, run-beads-tasks.sh = claude-tools-4tj,
# runner.sh = claude-tools-18c).
#
# The lib has two surfaces:
#   1. node25_prime_path [skip_flag]      — PATH prime; non-invasive when node
#      is already < v25; honors skip flag from caller-scoped env var.
#   2. node25_check_wrong_node_crash <f>  — detect the Node v25 × claude-CLI
#      prototype TypeError signature; echo Node version + rc 0 on match.
#
# The deeper "current node IS v25, with a fake nvm tree, picks v23" path is
# already covered end-to-end by the specialist.sh test (which exercises the
# detector path via a fake-claude shim) and live-verified for the runner. Here
# we cover the API contract directly so a refactor of the lib body is caught
# by a focused failure, not by a confused-looking specialist-shim test.

set -u

PASS=0; FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/node25-prime.sh"
[[ -f "$LIB" ]] || { echo "test-node25-prime: lib not found at $LIB" >&2; exit 70; }

# shellcheck source=node25-prime.sh
source "$LIB"

declare -F node25_prime_path >/dev/null \
  && pass "node25_prime_path is defined after source" \
  || fail "node25_prime_path NOT defined after source"
declare -F node25_check_wrong_node_crash >/dev/null \
  && pass "node25_check_wrong_node_crash is defined after source" \
  || fail "node25_check_wrong_node_crash NOT defined after source"

echo "── node25_prime_path: skip-flag honored ──"
# With skip=1, PATH must be unchanged regardless of what `node` reports. We
# don't try to mock node (it's on PATH in the test env); we assert the no-op
# contract: PATH before == PATH after when skip flag is "1".
_PRE_PATH="$PATH"
node25_prime_path 1
[[ "$PATH" == "$_PRE_PATH" ]] \
  && pass "skip=1 leaves PATH untouched" \
  || fail "skip=1 mutated PATH (got '$PATH', want '$_PRE_PATH')"

echo "── node25_prime_path: low-version is a no-op ──"
# Fabricate a `node` shim on a temp dir at front of PATH that reports v23, so
# the prime sees v23 and must return without touching PATH (after we save the
# state at the moment of the call).
TMPDIR_LOW="$(mktemp -d)"
cat > "$TMPDIR_LOW/node" <<'EOF'
#!/bin/bash
echo "v23.11.1"
EOF
chmod +x "$TMPDIR_LOW/node"
_LOW_PATH="$TMPDIR_LOW:$PATH"
PATH="$_LOW_PATH" node25_prime_path 0
# We can't directly observe inside-the-call PATH state, but the function must
# have returned without erroring; the export is the only way PATH would leak
# out of the subshell-less call. So we assert: a low-version call returned 0
# (function reports success) AND did not error.
_rc=0
PATH="$_LOW_PATH" node25_prime_path 0 || _rc=$?
[[ "$_rc" == "0" ]] \
  && pass "low-version node leaves prime as a no-op (rc=0, no error)" \
  || fail "low-version node prime returned rc=$_rc (want 0)"
rm -rf "$TMPDIR_LOW"

echo "── node25_check_wrong_node_crash: positive signature ──"
# Build a fake stream that mimics what a Node v25-under-claude-CLI crash
# produces: TypeError early, "Node.js v25.x.y" banner near the end.
TMP_STREAM_POS="$(mktemp)"
{
  echo "node:internal/modules/cjs/loader:1234"
  echo "TypeError: Cannot read properties of undefined (reading 'prototype')"
  echo "    at Object.<anonymous> (/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js:489:1)"
  echo "    at Module._compile (node:internal/modules/cjs/loader:1356:14)"
  echo ""
  echo "Node.js v25.2.1"
} > "$TMP_STREAM_POS"

if _detected="$(node25_check_wrong_node_crash "$TMP_STREAM_POS")"; then
  pass "positive stream: detector returns 0"
  [[ "$_detected" == "Node.js v25.2.1" ]] \
    && pass "positive stream: detected version is 'Node.js v25.2.1' (got '$_detected')" \
    || fail "positive stream: detected version wrong (got '$_detected', want 'Node.js v25.2.1')"
else
  fail "positive stream: detector returned nonzero (should detect)"
fi
rm -f "$TMP_STREAM_POS"

echo "── node25_check_wrong_node_crash: v26+ also detected (range is 25+) ──"
TMP_STREAM_V26="$(mktemp)"
{
  echo "TypeError: Cannot read properties of undefined (reading 'prototype')"
  echo "Node.js v26.0.0"
} > "$TMP_STREAM_V26"
if _detected="$(node25_check_wrong_node_crash "$TMP_STREAM_V26")"; then
  [[ "$_detected" == "Node.js v26.0.0" ]] \
    && pass "v26 stream: detected as wrong-node (rc 0, version='$_detected')" \
    || fail "v26 stream: detected wrong version (got '$_detected')"
else
  fail "v26 stream: detector did NOT trip (should — range is 25+)"
fi
rm -f "$TMP_STREAM_V26"

echo "── node25_check_wrong_node_crash: negative cases ──"
# (a) Empty/missing stream file → rc 1, no output.
TMP_EMPTY="$(mktemp)"
_out="$(node25_check_wrong_node_crash "$TMP_EMPTY")"; _rc=$?
[[ "$_rc" == "1" && -z "$_out" ]] \
  && pass "empty stream: rc=1, no output" \
  || fail "empty stream: rc=$_rc, out='$_out' (want rc=1, empty)"
rm -f "$TMP_EMPTY"

_out="$(node25_check_wrong_node_crash "/nonexistent/path/$$")"; _rc=$?
[[ "$_rc" == "1" && -z "$_out" ]] \
  && pass "missing stream: rc=1, no output" \
  || fail "missing stream: rc=$_rc, out='$_out' (want rc=1, empty)"

# (b) TypeError without the v25 banner → rc 1 (a generic claude prototype
#     error in a future Node X.Y.Z must NOT false-positive).
TMP_GENERIC="$(mktemp)"
{
  echo "TypeError: Cannot read properties of undefined (reading 'prototype')"
  echo "Node.js v23.11.1"
} > "$TMP_GENERIC"
_out="$(node25_check_wrong_node_crash "$TMP_GENERIC")"; _rc=$?
[[ "$_rc" == "1" && -z "$_out" ]] \
  && pass "v23 + TypeError stream: rc=1 (no false positive on low-version node)" \
  || fail "v23 + TypeError stream: rc=$_rc, out='$_out' (want rc=1, empty)"
rm -f "$TMP_GENERIC"

# (c) v25 banner without the TypeError → rc 1 (a benign v25 process whose
#     unrelated output mentions Node.js v25 must NOT false-positive).
TMP_BANNER_ONLY="$(mktemp)"
{
  echo "some unrelated output"
  echo "Node.js v25.2.1"
} > "$TMP_BANNER_ONLY"
_out="$(node25_check_wrong_node_crash "$TMP_BANNER_ONLY")"; _rc=$?
[[ "$_rc" == "1" && -z "$_out" ]] \
  && pass "v25 banner alone: rc=1 (no false positive without prototype TypeError)" \
  || fail "v25 banner alone: rc=$_rc, out='$_out' (want rc=1, empty)"
rm -f "$TMP_BANNER_ONLY"

echo ""
echo "Result: $PASS passed, $FAIL failed"
[[ "$FAIL" == "0" ]] || exit 1
echo "ALL_PASS (node25-prime lib unit — claude-tools-18c)"
