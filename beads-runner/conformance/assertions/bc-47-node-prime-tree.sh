#!/bin/bash
# BC-47 — Node v25 PATH prime is sourced UNCONDITIONALLY (a missing lib must fail
#         loudly, never silent-degrade) (v2 -tree coverage-hardening, claude-tools-v2cut.5)
#
# Binds: BEHAVIORAL-CONTRACT.md §15 BC-47. The unconditional source IS the
# contract: a daemon-launched PATH resolves `claude` to system Node v25, which
# crashes the CLI at startup, so `lib/node25-prime.sh` is the FIX — a missing lib
# is a real regression that must fail LOUDLY, not silently degrade to a
# stripped-PATH `claude`. So v2 sources it WITHOUT a `[[ -f ]]` guard (in
# deliberate contrast to the BC-43 optional libs git-pin-main.sh /
# build-settings.sh, which ARE `[[ -f ]]`-guarded) and calls `node25_prime_path`
# at startup. The scoped skip env var RUNNER_SKIP_NVM_PRIME stays caller-local.
# This is a SOURCE-STRUCTURAL posture proof against $RUNNER.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"   # repoint to v2

# ── A · node25-prime is sourced UNCONDITIONALLY and primed at startup ──────────
H_init_test bc47tree-unconditional-source
_expect "BC-47" "§15" "lib/node25-prime.sh is sourced WITHOUT a [[ -f ]] guard and node25_prime_path is called at startup (runner.sh)"
_need "node25-prime.sh is sourced"                    grep -qE 'source "\$RUNNER_DIR/lib/node25-prime.sh"' "$RUNNER"
# The source line is NOT preceded (same line) by an [[ -f ]] test — it is bare,
# unlike the optional libs. (The optional-lib pattern is `[[ -f ... ]] && source`
# or an `if [[ -f ... ]]; then source` block.)
_need "the node25-prime source line is BARE (no inline [[ -f ]] guard on it)" \
      bash -c '! grep -E "source \"\\\$RUNNER_DIR/lib/node25-prime.sh\"" "'"$RUNNER"'" | grep -qE "\[\[ -f"'
_need "node25_prime_path is invoked at startup"       grep -qE '^node25_prime_path ' "$RUNNER"
_need "the prime honours the caller-local skip env var RUNNER_SKIP_NVM_PRIME" \
      grep -qE 'node25_prime_path "\$\{RUNNER_SKIP_NVM_PRIME:-0\}"' "$RUNNER"
_emit
H_cleanup

# ── B · CONTRAST: the optional libs ARE [[ -f ]]-guarded; node25-prime is not ──
H_init_test bc47tree-contrast-optional-guard
_expect "BC-47" "§15" "the mandatory node25-prime source is UNGUARDED where the optional libs (git-pin-main, build-settings) ARE [[ -f ]]-guarded — the load-bearing distinction (runner.sh)"
# Confirm the optional libs really are guarded (so the contrast is meaningful).
_need "git-pin-main.sh IS [[ -f ]]-guarded (optional)" \
      grep -qE '\[\[ -f "\$RUNNER_DIR/lib/git-pin-main.sh" \]\]' "$RUNNER"
_need "build-settings.sh IS [[ -f ]]-guarded (optional)" \
      grep -qE '\[\[ -f "\$RUNNER_DIR/hooks/build-settings.sh" \]\]' "$RUNNER"
# And confirm node25-prime is NOT among the [[ -f ]]-guarded names anywhere.
_need "node25-prime is NEVER named inside an [[ -f ]] test" \
      bash -c '! grep -E "\[\[ -f" "'"$RUNNER"'" | grep -q "node25-prime"'
# The fix exists (a wrong-node crash backstop, BC-62) but the prime itself is mandatory.
_need "a post-run wrong-node-crash backstop exists (BC-62) behind the prime" \
      grep -qE 'node25_check_wrong_node_crash' "$RUNNER"
_emit
H_cleanup
