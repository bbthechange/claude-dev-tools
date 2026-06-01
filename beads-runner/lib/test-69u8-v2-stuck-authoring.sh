#!/bin/bash
# beads-runner/lib/test-69u8-v2-stuck-authoring.sh — claude-tools-69u8
#
# Sub-problem 2: the v2 runner (runner.sh) `_drive_blocked_for_human` used to
# write a BODY-LESS stub dossier ({schema_version,trigger,bead_ref,task_ref,
# principal}) via co_store_put and NEVER call dg__author — so a v2 STUCK fork
# shipped neither an agent body NOR a jq-fallback body to Brian's Inbox. This
# test pins the fix: the function now AUTHORS a real §5 body+items dossier (via
# the same dg_from_worker_ask path v1 uses), keyed on the §7.4 dedup id.
#
# HERMETIC: DG_AUTHOR_AUTOWIRE=0 forces the deterministic jq author (no claude
# spawn) — proving the body is authored regardless of agent reachability. The
# agent path is covered by lib/test-dossier-gen.sh test (9). runner.sh is
# sourced (its source-guard skips the dispatch loop) so we exercise the REAL
# function, not a copy.
set -u

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_ABS="$(cd "$LIB_DIR/.." && pwd)/runner.sh"
[[ -f "$RUNNER_ABS" ]] || { echo "FATAL: runner.sh not found at $RUNNER_ABS"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
ck()  { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
ckn() { if "${@:2}" >/dev/null 2>&1; then bad "$1"; else ok "$1"; fi; }
eq()  { [[ "$1" == "$2" ]]; }
nz()  { [[ -n "$1" ]]; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A trivial fake bd on PATH so the §7.3 bead-drive (bd update/label/human) is a
# clean no-op — _drive_blocked_for_human treats bd as fail-open anyway.
mkdir -p "$WORK/bin"
printf '#!/bin/bash\nexit 0\n' > "$WORK/bin/bd"; chmod +x "$WORK/bin/bd"
export PATH="$WORK/bin:$PATH"

# Pure-local, hermetic store. No hosted transport, no real agent spawn.
export CO_STORE="$WORK/store"
unset COORDINATOR_URL COORDINATOR_TOKEN 2>/dev/null || true
export RUNNER_BACKEND=stub
export RUNNER_SKIP_NVM_PRIME=1
export DG_AUTHOR_AUTOWIRE=0   # kill-switch ⇒ deterministic jq author (hermetic)

TREF="claude-tools-69u8test"
DID="stuck-$TREF"
BEARER="bearer-runner-stuck"

echo "── claude-tools-69u8: v2 STUCK path AUTHORS a real dossier (not a body-less stub) ──"

# Source the REAL runner (guard skips the dispatch loop) from inside the
# workspace, capturing its noisy startup so it doesn't muddy the test output.
(
  cd "$WORK"
  # shellcheck source=/dev/null
  source "$RUNNER_ABS" >/dev/null 2>&1
  # Sourcing installs runner.sh's `trap runner_teardown EXIT` (+ _on_signal),
  # which kill-trees the process group when THIS subshell exits. Disarm it (the
  # same `trap -` idiom runner.sh uses for its own subshells) so we exit cleanly
  # AFTER the function under test has done its work.
  trap - EXIT INT TERM HUP

  declare -F _drive_blocked_for_human >/dev/null 2>&1 || { echo "NODRIVE"; exit 9; }

  # The fix under test.
  _drive_blocked_for_human "$TREF" >/dev/null 2>&1
  # Idempotent re-trigger (§7.4 one-fork-one-dossier): a second call must not
  # produce a second dossier nor crash.
  _drive_blocked_for_human "$TREF" >/dev/null 2>&1
  trap - EXIT INT TERM HUP
  exit 0
) || { bad "sourcing/driving runner.sh failed"; echo "TOTAL pass=$PASS fail=$((FAIL+1))"; exit 1; }

# Read the persisted dossier back through a CLEAN subshell that sources only the
# real dossier stack (the test shell above was polluted by the stub backend).
GET="$(
  cd "$LIB_DIR"
  export CO_STORE
  # shellcheck source=/dev/null
  source "$LIB_DIR/stuck-routing.sh" 2>/dev/null
  co_request "$BEARER" get dossier "$DID" 2>/dev/null
)"

ck  "a dossier was persisted at the §7.4 dedup id ($DID)"            nz "$GET"
ck  "persisted record is the §4.1 worker_stuck dossier"             eq "$(printf '%s' "$GET" | jq -r '.trigger // ""')" "worker_stuck"

# The CORE assertion: it is NOT the old body-less stub — it carries a real §5
# body with all four mandatory tiers + ≥1 item.
ck  "dossier has a body (NOT the body-less stub)"                   eq "$(printf '%s' "$GET" | jq -r 'has("body")')" "true"
ck  "body.tldr is non-empty"                                       nz "$(printf '%s' "$GET" | jq -r '.body.tldr // ""')"
ck  "body.full_detail is non-empty (the stand-alone deep prose)"   nz "$(printf '%s' "$GET" | jq -r '.body.full_detail // ""')"
ck  "body.sections[] has ≥1 entry (the skimmable deep body)"       test "$(printf '%s' "$GET" | jq -r '(.body.sections // []) | length')" -ge 1
ck  "items[] has ≥1 respondable Item (the pick-option fork)"       test "$(printf '%s' "$GET" | jq -r '(.items // []) | length')" -ge 1
ck  "body.authored_by is stamped (degraded-author badge present)"  nz "$(printf '%s' "$GET" | jq -r '.body.authored_by // ""')"
# With AUTOWIRE off it is the deterministic jq author — proving a body ships
# even when the real agent is unreachable (the sub-problem-2 guarantee).
ck  "AUTOWIRE off ⇒ authored_by='fallback' (jq author, body still present)"  \
    eq "$(printf '%s' "$GET" | jq -r '.body.authored_by // ""')" "fallback"

# The OLD body-less stub had NO body/items keys at all — assert that shape is
# gone (defends against a regression back to the co_store_put stub).
ckn "record is NOT the old body-less stub (it would lack .body)" \
    eq "$(printf '%s' "$GET" | jq -r 'has("body")')" "false"

echo "══════════════════════════════════════════════════════════════════════"
echo " test-69u8-v2-stuck-authoring:  PASS=$PASS  FAIL=$FAIL"
echo "══════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
