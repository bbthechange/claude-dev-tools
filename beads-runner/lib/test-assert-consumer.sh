#!/bin/bash
# beads-runner/lib/test-assert-consumer.sh — the acceptance artifact for
# claude-tools-rznj.4 (TESTING-STRATEGY.md §7.2(b)): proves a NEW test that
# `source`s the shared vocabulary (lib/test-assert.sh) passes, and doubles as
# the copy-paste TEMPLATE the ux-v2 tests follow.
#
# Note what this test still owns FOR ITSELF (the helper supplies none of it —
# vocabulary only, never a shared store/fixture): its own `mktemp -d` store and
# its own `trap rm` cleanup. That per-test isolation is the deliberate anti-flake
# design §8 protects; sourcing the vocabulary does not erode it.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/test-assert.sh"

# OWN, isolated store — shared with nothing (the point of §8). Trivial here, but
# present so the template carries the isolation a real consumer needs.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── exercise the sourced vocabulary the way a real test would ──────────────
echo "test-assert-consumer (sources lib/test-assert.sh):"

# direct verbs — positives via ck; negatives via shell `!` (ck cannot carry the
# `!` keyword as an argument) or the inverse verb (hasnt).
ok  "ok() is available after source"
ck  "ck routes a true predicate to ok"        true
ck  "eq compares equal strings"               eq "alpha" "alpha"
if ! eq "alpha" "beta"; then ok "eq returns non-zero on unequal strings"; else bad "eq returns non-zero on unequal strings"; fi
ck  "has finds a substring"                   has "needle" "a needle in hay"
ck  "hasnt confirms absence (inverse verb)"   hasnt "missing" "a needle in hay"
ck  "nz accepts a real value"                 nz "present"
if ! nz "";     then ok "nz rejects empty"; else bad "nz rejects empty"; fi
if ! nz "null"; then ok "nz rejects JSON literal null"; else bad "nz rejects JSON literal null"; fi

# the store the helper did NOT give us — prove it is ours and isolated
echo "isolated" > "$WORK/own-fixture"
ck  "the per-test mktemp store is the test's own, not the helper's" \
    eq "$(cat "$WORK/own-fixture")" "isolated"

# the helper carries no shared mutable state: re-sourcing must not reset or
# corrupt the live tally (idempotent : "${PASS:=0}" leaves existing values).
_pass_before="$PASS"
# shellcheck source=/dev/null
source "$HERE/test-assert.sh"
ck  "re-sourcing the helper preserves the live tally (idempotent counters)" \
    eq "$PASS" "$_pass_before"

summary "test-assert-consumer"
