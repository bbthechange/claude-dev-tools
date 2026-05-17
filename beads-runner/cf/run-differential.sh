#!/bin/bash
# CF.1 (claude-tools-7g0.1) — differential conformance harness.
#
# Ties the Cloudflare substrate to its differential oracle: lib/coordinator.sh
# + lib/test-coordinator.sh. Two parts, mirroring how test-coordinator.sh
# itself mixes behavioral assertions with one source-discipline grep:
#
#   1. BEHAVIORAL — `npm test` runs test/coordinator.spec.js under
#      @cloudflare/vitest-pool-workers: the REAL Worker + Coordinator DO + D1
#      on the SAME workerd+miniflare runtime `wrangler dev` uses, NO Cloudflare
#      account. It re-implements every EXIT-1..5 + §2.4 clause of
#      test-coordinator.sh and asserts behaviour-identity.
#
#   2. SOURCE DISCIPLINE — the §0.C "no actor-discriminating branch" assertion.
#      test-coordinator.sh asserts this with a literal grep over the bash lib
#      (`! grep -Eiq "if .*\$?actor|case .*\$actor" "$LIB"`). We run the SAME
#      assertion, same tool, pointed at the CF source (comments stripped so it
#      matches the *code*, not the prose that documents the discipline) — the
#      most defensible "behaviour-identical on §0.C" claim.
#
# Exit 0 iff BOTH parts pass. This is the CF.1 observable EXIT proof.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE" || exit 2
rc=0

echo "── CF.1 differential part 1/2: behavioral conformance (vitest-pool-workers) ──"
if [[ ! -d node_modules ]]; then
  echo "(installing devDependencies — first run only)"
  npm install --no-audit --no-fund || { echo "FATAL: npm install failed"; exit 2; }
fi
npm test --silent || rc=1

echo ""
echo "── CF.1 differential part 2/2: §0.C source discipline (no actor branch) ──"
# Strip JS comments (NOT strings), then apply the SAME grep
# test-coordinator.sh applies to the bash lib. A real actor-discriminating
# branch (if/switch/case/ternary keyed on the `actor` parameter) MUST NOT
# exist — the §0.C downgrade/promote asymmetry is §0.C-DEFERRED, captured not
# enforced (C4). Comments are stripped so the documentation OF the discipline
# does not itself trip the grep (the bash lib's prose likewise does not). The
# stripper (test/strip-comments.mjs) is a char-state scanner that tracks
# string/template/comment state, so a `//` INSIDE a string never truncates
# real code (fail-closed: a stripper error or empty output is treated as a
# §0.C VIOLATION, never a silent green — a discipline gate must never fail
# open). It lives in its own file to keep this harness free of brittle
# nested-quoting.
viol=0
for f in src/coordinator.js src/index.js src/schema.js src/notification.js src/forensic.js; do
  stripped="$(node test/strip-comments.mjs "$f")" || { echo "  ✗ $f — comment-stripper failed (fail-closed §0.C VIOLATION)"; viol=1; continue; }
  [[ -n "$stripped" ]] || { echo "  ✗ $f — empty after strip (fail-closed §0.C VIOLATION)"; viol=1; continue; }
  if printf '%s' "$stripped" | grep -Eiq 'if[^a-z].*\bactor\b|case[^a-z].*\bactor\b|switch[[:space:]]*\([^)]*actor|\bactor\b[[:space:]]*(===|==|!==|!=|\?|&&|\|\|)'; then
    echo "  ✗ $f contains an actor-discriminating branch (§0.C MUST NOT be enforced)"
    viol=1
  else
    echo "  ✓ $f — no actor-discriminating branch (§0.C captured-not-enforced)"
  fi
done
[[ "$viol" -eq 0 ]] || rc=1

echo ""
if [[ "$rc" -eq 0 ]]; then
  echo "══ CF.1 DIFFERENTIAL GREEN — behaviour-identical to coordinator.sh + test-coordinator.sh ══"
else
  echo "══ CF.1 DIFFERENTIAL RED — see failures above ══"
fi
exit "$rc"
