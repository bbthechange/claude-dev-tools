# shellcheck shell=bash
# beads-runner/lib/sweep-fixtures.sh — self-heal orphaned LIVE-bd test fixtures
# (claude-tools-fxsweep).
#
# WHY THIS EXISTS
#   test-bd-ready-ordering.sh deliberately seeds fixtures into the LIVE bd
#   workspace — it pins the REAL bd binary's `bd ready` ordering contract, which
#   a fake would tautologically pass (see that file's head) — and cleans them via
#   an EXIT/INT/TERM trap. That trap does NOT fire on SIGKILL, and the runner
#   watchdog kills stuck workers with `kill -9`, so a run killed mid-flight (or a
#   crash) leaks its fixtures permanently (observed 2026-05-31: 8 orphaned
#   'ordering-fixture' beads sat live in `bd ready`). This helper is the
#   idempotent self-heal: it deletes any bead carrying a fixture label, called at
#   the START of the test AND at the START of the run-tests.sh gate. In a healthy
#   workspace it deletes nothing.
#
# SAFETY — this DELETES beads, so the join MUST be exact:
#   • It matches the ACTUAL .labels array via jq. bd's --label-pattern /
#     --label-regex are NO-OPS in the current bd binary (v1.0.4, verified
#     2026-05-31): they return the WHOLE DB regardless of the pattern, so a
#     CLI-glob `bd delete` would wipe everything. The exact `--label` filter
#     works, but takes only a full label, not the per-PID-suffixed fixture
#     labels. So a jq scan over the real labels array is the only safe join.
#   • The matched prefix is the SPECIFIC fixture label 'test-bd-ready-ordering-',
#     NEVER a broad 'test-*' (real beads carry 'test-infra' / 'gate' / 'human').
#     A near-miss like 'test-bd-readiness-' must NOT match.
#   • Every bd call is best-effort (`|| true`): a sweep failure (no workspace, bd
#     absent, jq absent) must NEVER fail its caller — a deterministic test, or
#     the deterministic offline gate.
#
# CONCURRENCY NOTE
#   The prefix sweep is intentionally broad across runs (every per-PID fixture
#   label). If a SECOND run is seeding concurrently, this could delete its
#   in-flight fixtures — but the run-tests.sh gate serializes via its singleton
#   lock, and a stray concurrent direct invocation would only see a test FAILURE
#   (the lesser evil), never a leak. Leak-prevention is the contract here.
#
# Sourced (not executed). bd + jq are resolved from PATH so a stateful fake bd on
# PATH (lib/test-sweep-fixtures.sh) exercises this with zero live-bd risk.

# Emit (stdout, one id per line) every bead carrying a fixture label. Read-only —
# this is the safety-critical join, kept as its own function so it is tested in
# isolation against a fake bd. Always returns 0; emits nothing if bd/jq are
# absent or the workspace is unreachable.
fixture_orphan_ids() {
  command -v bd >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  # type=="string" guards startswith() against a non-string label element — jq
  # would otherwise error mid-stream ("startswith() requires string inputs") and
  # stop enumerating, leaving beads AFTER the offender unswept (a silent partial
  # sweep — the very leak this is meant to close). Defensive; today every label
  # is a string, but the join must never abort short.
  bd list --all --json --limit 0 2>/dev/null \
    | jq -r '.[]
             | select(any(.labels[]?; type=="string" and startswith("test-bd-ready-ordering-")))
             | .id' 2>/dev/null \
    || true
}

# Delete every orphaned fixture. Prints ONE summary line naming the count and ids
# (so a leak is never silently absorbed — "no silent caps") only when there is
# something to sweep; prints nothing in the healthy case. Always returns 0.
sweep_fixtures() {
  local ids n
  ids="$(fixture_orphan_ids)"
  [[ -n "$ids" ]] || return 0
  # `grep -c .` exits 1 on a zero count; `|| true` keeps the count line
  # self-contained (rc never leaks) even if the `[[ -n "$ids" ]]` guard above
  # is ever weakened. The captured stdout (the count) is unaffected.
  n="$(printf '%s\n' "$ids" | grep -c . || true)"
  printf 'fixture-sweep: deleting %s orphaned test-bd-ready-ordering fixture(s): %s\n' \
    "$n" "$(printf '%s' "$ids" | tr '\n' ' ')"
  while IFS= read -r _id; do
    [[ -n "$_id" ]] || continue
    bd delete "$_id" --force >/dev/null 2>&1 || true
  done <<< "$ids"
  return 0
}
