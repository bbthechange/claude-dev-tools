# shellcheck shell=bash
# beads-runner/lib/test-assert.sh — OPTIONAL shared assertion VOCABULARY for the
# bash test-*.sh suites (TESTING-STRATEGY.md §7.2(b), claude-tools-rznj.4).
#
# WHAT THIS IS
#   The ~50 bash test-*.sh each re-define the same seven assertion verbs —
#   ok / bad / ck / has / hasnt / eq / nz. This file extracts JUST that
#   vocabulary so a NEW test can `source` it instead of copy-pasting the block:
#
#       HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#       source "$HERE/test-assert.sh"      # adjust the relative path per dir
#       WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT   # <-- still YOUR job
#       ck "thing works" eq "$got" "$want"
#       ...
#       summary "test-my-thing"            # prints the tally, sets exit code
#
# WHAT THIS IS **NOT** — and must never become (TESTING-STRATEGY.md §7.2 + §8):
#   VOCABULARY ONLY. Never a shared store, fixture, mock, fake `bd`, or any
#   data shared across tests. The per-test `mktemp -d` store + own fake `bd` on
#   PATH + `trap rm` cleanup is deliberate anti-flake isolation and stays with
#   each test — shared mutable state across tests is the classic flake source.
#   The ONLY state this file touches is the per-PROCESS PASS/FAIL tally that the
#   ok/bad verbs inherently need; it lives in the sourcing test's own shell
#   (each test runs in its own subprocess with its own mktemp store), resets
#   every time the file is sourced, and is shared with nothing. That is not the
#   "shared mutable state" §8 forbids — it is the tally the named vocabulary is.
#
#   Because it is vocabulary only, this file does NOT mass-rewrite the existing
#   ~50 tests (churn + regression risk, §7.2). They keep their inline copies and
#   migrate to `source`ing this only when otherwise edited; new ux-v2 tests use
#   it from the start.
#
# DUAL-PURPOSE / WHY IT KEEPS THE `test-` PREFIX
#   In lib/, the `test-` prefix means "a runnable test" (run-tests.sh enrolls
#   every lib/test-*.sh by glob, §7.1). To keep that prefix honest, this file is
#   *also* its own self-test: run directly (`bash lib/test-assert.sh`, which the
#   gate does) it exercises every verb and exits non-zero on any failure. When
#   `source`d, that self-test block is skipped — only the verbs are defined.

# ── per-PROCESS tally (see header) ─────────────────────────────────────────
# Idempotent: a test that already declared PASS/FAIL keeps its values; one that
# did not gets sane defaults. Safe under `set -u`.
: "${PASS:=0}"
: "${FAIL:=0}"

# ── the seven verbs (the §7.2(b) vocabulary) ───────────────────────────────
# ok/bad   — record a pass/fail with a message, bumping the per-process tally.
ok()    { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
# ck "msg" cmd args... — run the predicate; ok on success, bad on failure.
# Guards the missing-predicate footgun: bare `ck "msg"` would otherwise run the
# empty command (exit 0) and record a vacuous pass. A dropped predicate is a
# test bug, so report it loudly rather than silently green (this file is the
# template new tests copy — hardening it here beats inheriting the footgun).
# The message is default-expanded (`${1:-…}`) so even the zero-arg call `ck`
# records a loud FAIL instead of dying on an unbound `$1` under `set -u` — the
# regime this vocabulary is built for; the guard must survive the most-missing case.
ck()    { (($# >= 2)) || { bad "${1:-<no message>} (ck: missing predicate)"; return 1; }; if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
# pure predicates (status only — compose under ck or if; never self-report):
has()   { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }   # $2 contains $1
hasnt() { case "$2" in *"$1"*) return 1;; *) return 0;; esac; }   # $2 lacks $1
eq()    { [[ "$1" == "$2" ]]; }                                   # $1 == $2
# nz — non-empty AND not the JSON literal "null" (consumers assert on `jq -r`
# output, where an absent field prints "null"; treating that as empty is the
# useful semantics for projection/view-model tests — see test-inbox.sh).
nz()    { [[ -n "$1" && "$1" != "null" ]]; }

# ── optional reporting convenience (pure; no shared state) ──────────────────
# summary "test-name" — print the standard tally footer and RETURN non-zero iff
# anything failed, so a test can end with `summary "..."` and let the exit code
# propagate. Optional: tests are free to print their own banner instead.
summary() {
  local name="${1:-test}"
  echo ""
  echo "══════════════════════════════════════════════════════════════════════"
  printf ' %s:  PASS=%d  FAIL=%d\n' "$name" "$PASS" "$FAIL"
  echo "══════════════════════════════════════════════════════════════════════"
  [[ "$FAIL" -eq 0 ]]
}

# ── self-test (runs ONLY when executed directly, never when sourced) ────────
# Keeps the `test-` prefix honest and gives the shared vocabulary its own
# regression coverage in the offline gate. Asserts each verb against the
# vocabulary itself, using a throwaway tally so the real PASS/FAIL above stay
# the report of THIS block when run standalone.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -u
  echo "test-assert self-test (lib/test-assert.sh):"

  # Positive cases route through ck. Negative cases use shell-level `!` (a
  # keyword, so it cannot be passed as an argument to ck) — this also shows
  # template-readers the idiomatic way to assert a negative with this
  # positives-only vocabulary (or just prefer the inverse verb, hasnt).
  ck "eq: equal strings pass"            eq "abc" "abc"
  if ! eq "abc" "xyz"; then ok "eq: unequal strings return non-zero"; else bad "eq: unequal strings return non-zero"; fi
  ck "has: needle present in haystack"   has "lo" "hello world"
  if ! has "zz" "hello world"; then ok "has: absent needle returns non-zero"; else bad "has: absent needle returns non-zero"; fi
  ck "hasnt: needle absent passes"       hasnt "zz" "hello world"
  if ! hasnt "lo" "hello world"; then ok "hasnt: present needle returns non-zero"; else bad "hasnt: present needle returns non-zero"; fi
  ck "nz: non-empty value passes"        nz "value"
  if ! nz "";     then ok "nz: empty value returns non-zero"; else bad "nz: empty value returns non-zero"; fi
  if ! nz "null"; then ok "nz: JSON literal null returns non-zero"; else bad "nz: JSON literal null returns non-zero"; fi

  # ok/bad must move the per-process tally. Probe in a subshell so the live
  # report is not polluted by the probe's deliberate bad().
  probe="$(PASS=0 FAIL=0; ok x >/dev/null; ok y >/dev/null; bad z >/dev/null; \
           printf '%d/%d' "$PASS" "$FAIL")"
  ck "ok/bad bump the per-process PASS/FAIL tally" eq "$probe" "2/1"

  # ck routes a passing predicate to ok and a failing one to bad.
  ck_probe="$(PASS=0 FAIL=0; ck a true >/dev/null; ck b false >/dev/null; \
              printf '%d/%d' "$PASS" "$FAIL")"
  ck "ck records pass-on-true, fail-on-false" eq "$ck_probe" "1/1"

  # ck guards a dropped predicate (loud fail, never a vacuous pass) — for BOTH
  # the one-arg call (message, no predicate) and the zero-arg call (the
  # most-missing case, which must not die on an unbound $1 under set -u).
  guard_probe="$(PASS=0 FAIL=0; ck "msg only" >/dev/null 2>&1; \
                 printf '%d/%d' "$PASS" "$FAIL")"
  ck "ck flags a missing predicate instead of passing vacuously" eq "$guard_probe" "0/1"
  guard0_probe="$(PASS=0 FAIL=0; ck >/dev/null 2>&1; \
                  printf '%d/%d' "$PASS" "$FAIL")"
  ck "ck survives a zero-arg call under set -u (loud fail, no crash)" eq "$guard0_probe" "0/1"

  summary "test-assert (self-test)"
fi
