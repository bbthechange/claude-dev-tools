#!/usr/bin/env bash
# beads-runner/test-gate-offline-author.sh — the offline gate must NEVER spawn a
# real `claude` (claude-tools-bmfj).
#
# THE BUG: run-tests.sh runs inside a `claude -p` worker, and both runners export
# DG_AUTHOR_AUTOWIRE=1 at startup (run-beads-tasks.sh, runner.sh). That 1 is
# inherited by the gate. dossier-gen.sh's dg__author has a chokepoint autowire:
# when DG_AUTHOR_AUTOWIRE=1 AND real `claude` is on PATH AND the executable
# lib/dg-author-bridge.sh is present, it resolves the REAL bridge as DG_AUTHOR_CMD
# and fires claude-in-claude (a 300s-timeout opus call, relaunched once per
# dg_generate). An orphaned such run wedged the gate for ~1h and held the single
# global gate lock for the whole swarm.
#
# THE FIX (asserted here): run-tests.sh forces DG_AUTHOR_AUTOWIRE=0 for the WHOLE
# gate — before the singleton lock and the SELFTEST exit — so every tier inherits
# the deterministic jq author and no real claude is ever spawned, no matter what
# the worker session inherited.
#
# Mechanics: the lock SELFTEST hook (RUN_TESTS_GATE_SELFTEST=try, with
# RUN_TESTS_GATE_LOCK_BASE relocated so this never touches the real /tmp lock)
# acquires the lock then exits, printing the neutralized autowire value. We launch
# it with DG_AUTHOR_AUTOWIRE=1 in the environment (simulating a worker session)
# and assert the gate reports it forced OFF.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
RUNNER="$SCRIPT_DIR/run-tests.sh"
DGTEST="$SCRIPT_DIR/lib/test-dossier-gen.sh"
[[ -f "$RUNNER" ]] || { echo "test-gate-offline-author.sh: reject — $RUNNER not found" >&2; exit 2; }

FAILED=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; FAILED=1; }

WORK="$(mktemp -d 2>/dev/null)" || { echo "mktemp failed"; exit 70; }
trap 'rm -rf "$WORK"' EXIT

# ── (1) BEHAVIORAL: a gate launched with DG_AUTHOR_AUTOWIRE=1 inherited (exactly
#        what a worker session passes) reports it forced OFF for the whole run.
echo "── behavioral: inherited DG_AUTHOR_AUTOWIRE=1 is forced OFF by the gate"
DG_AUTHOR_AUTOWIRE=1 RUN_TESTS_GATE_LOCK_BASE="$WORK" RUN_TESTS_GATE_SELFTEST=try \
  bash "$RUNNER" >"$WORK/out" 2>&1
rc=$?
[[ $rc -eq 0 ]] && pass "gate SELFTEST exits 0 under inherited autowire=1" \
  || fail "gate SELFTEST exit $rc (out: $(cat "$WORK/out"))"
if grep -q '^OFFLINE-DG-AUTHOR-AUTOWIRE=0$' "$WORK/out"; then
  pass "gate forced DG_AUTHOR_AUTOWIRE=0 despite inheriting =1 (no claude-in-claude)"
else
  fail "gate did NOT force autowire off — out: [$(grep OFFLINE-DG-AUTHOR-AUTOWIRE "$WORK/out" || echo none)]"
fi

# ── (2) ANTI-DRIFT (static guardian, mirrors test-dg-author-bridge.sh): the gate
#        source carries the explicit kill-switch export. If someone deletes it,
#        this goes red — the intended tripwire.
echo "── anti-drift: run-tests.sh exports the kill-switch"
grep -qE '^[[:space:]]*export DG_AUTHOR_AUTOWIRE=0' "$RUNNER" \
  && pass "run-tests.sh exports DG_AUTHOR_AUTOWIRE=0" \
  || fail "run-tests.sh no longer forces DG_AUTHOR_AUTOWIRE=0 (root-cause guard removed)"

# ── (3) ANTI-DRIFT: EVERY lib test that drives the dg__author chokepoint
#        (sr_route_stuck/dg_from_worker_ask/dg_generate) must drop the inherited
#        autowire seam at startup, so a STANDALONE `bash lib/test-…sh` inside a
#        worker session cannot spawn claude-in-claude — the same wedge from a
#        sibling file (claude-tools-bmfj review finding). The seam-unset may use a
#        `\`-continuation, so join continued lines before matching (a single-line
#        grep silently misses the continuation form).
echo "── anti-drift: every chokepoint-reaching lib test drops the inherited autowire seam"
seam_unset_present() {  # $1=file → 0 iff an `unset … DG_AUTHOR_AUTOWIRE …` exists (continuation-aware)
  # awk, not sed: BSD/macOS sed lacks the GNU `:a;N;ba` line-join idiom. Join
  # `\`-continued logical lines (comments stripped) and look for a real `unset`
  # statement naming DG_AUTHOR_AUTOWIRE — so the continuation form is not missed
  # and a mere comment mentioning the var does not false-pass.
  awk '
    {
      cur = $0; sub(/#.*/, "", cur); buf = buf cur
      # Detect the continuation on the COMMENT-STRIPPED line: a trailing `\`
      # inside a comment is a statement terminator in bash, not a line-join.
      if (cur ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, "", buf); next }
      if (buf ~ /(^|[;&|[:space:]])unset([[:space:]]|$)/ && buf ~ /DG_AUTHOR_AUTOWIRE/) found = 1
      buf = ""
    }
    END { exit(found ? 0 : 1) }
  ' "$1"
}
for t in test-dossier-gen.sh test-stuck-routing.sh test-i3-stuck-dossier.sh; do
  f="$SCRIPT_DIR/lib/$t"
  if [[ ! -f "$f" ]]; then
    fail "$t not found at $f"
  elif seam_unset_present "$f"; then
    pass "$t unsets DG_AUTHOR_AUTOWIRE at startup (no standalone claude-in-claude)"
  else
    fail "$t no longer unsets DG_AUTHOR_AUTOWIRE (standalone leak risk — chokepoint reachable)"
  fi
done

# ── done ──────────────────────────────────────────────────────────────────────
if [[ $FAILED -eq 0 ]]; then
  echo ""
  echo "test-gate-offline-author.sh: ALL PASS"
  exit 0
else
  echo ""
  echo "test-gate-offline-author.sh: FAILURES (see FAIL lines above)" >&2
  exit 1
fi
