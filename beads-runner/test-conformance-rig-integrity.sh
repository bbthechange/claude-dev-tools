#!/bin/bash
# test-conformance-rig-integrity.sh — top-tier regression lock for claude-tools-rqpv.
#
# WHAT IT PINS: conformance/run-conformance.sh must NEVER score a rig that failed
# to run as GREEN. Three abort modes, each of which silently skips assertions, must
# turn the tier RED with a NAMED FAIL:
#   1. PARSE ABORT — `bash -n` rejects the rig (e.g. a heredoc-inside-$(...) with an
#      odd quote, which parses on bash 5.x but ABORTS under the harness's /bin/bash 3.2),
#      emitting ZERO RESULT lines.
#   2. NO-RESULT — the rig parsed but emitted no RESULT line at all (crashed/killed).
#   3. NON-ZERO EXIT — the rig emitted RESULT line(s) then aborted mid-way (a `set -u`
#      unbound var, a runtime error), silently skipping every later assertion.
#
# WHY IT EXISTS (the silent-when-wrong scar): the gate tallies only stdout `RESULT|`
# lines. A rig that contributes 0 pass / 0 fail let the per-BC rollup read GREEN while
# every assertion in it was skipped — the exact failure the conformance gate exists to
# prevent, reproduced inside the gate (claude-tools-rqpv, surfaced during the uxvi1
# review). The fix is the bash -n parse pre-check + the exit-status guard + the
# pre-existing >=1-RESULT guard. A clean run of healthy rigs must STILL be green (the
# guards must not false-RED), so we assert that too.
#
# Hermetic: drives run-conformance.sh against a TEMP dir of fixture rigs via the
# CONF_ASSERT_DIR override — never touches the real assertions/ set.
#
# Counts as ONE top-tier unit (pass == exit 0). Auto-enrolled by glob (testing.md).

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNCONF="$DIR/conformance/run-conformance.sh"

PASS=0; FAIL=0
ck() { local m="$1"; shift; if "$@"; then echo "  ok  : $m"; PASS=$((PASS+1)); else echo "  FAIL: $m"; FAIL=$((FAIL+1)); fi; }

[[ -x "$RUNCONF" || -f "$RUNCONF" ]] || { echo "FAIL: run-conformance.sh not found at $RUNCONF"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── fixtures ──────────────────────────────────────────────────────────────────
# 1. a clean rig: emits a PASS and exits 0.
cat > "$TMP/bc-good.sh" <<'EOF'
#!/bin/bash
echo "RESULT|PASS|bc-good|-|a clean rig that emits a PASS and exits 0"
EOF

# 2. a PARSE-ABORT rig: odd quote inside a heredoc-inside-$(...). Under /bin/bash 3.2
#    this aborts at parse time and emits ZERO RESULT lines.
cat > "$TMP/bc-parsebroken.sh" <<'EOF'
#!/bin/bash
val="$(cat <<'INNER'
this line has an odd " quote count
INNER
)"
echo "RESULT|PASS|bc-parsebroken|-|should NEVER print — the rig parse-aborts first"
EOF

# 3. a NO-RESULT rig: parses fine, exits 0, but emits no RESULT line (crash before any).
cat > "$TMP/bc-noresult.sh" <<'EOF'
#!/bin/bash
# A rig that does setup and dies before emitting any RESULT (modeled: emit nothing).
:
EOF

# 4. a NON-ZERO-EXIT rig: emits one PASS then aborts — later assertions silently skipped.
cat > "$TMP/bc-nonzero.sh" <<'EOF'
#!/bin/bash
echo "RESULT|PASS|bc-nonzero|-|first assertion ran"
exit 3
echo "RESULT|PASS|bc-nonzero|-|this assertion is SKIPPED by the abort above"
EOF

# Sanity: the parse-broken fixture really does fail bash -n in THIS environment
# (else the test is vacuous — e.g. a future bash where the construct parses).
if bash -n "$TMP/bc-parsebroken.sh" 2>/dev/null; then
  echo "SKIP: the parse-broken fixture parses under this bash — parse-abort scenario not reproducible here (test vacuous)"
  exit 0
fi

# ── drive the gate against the fixtures ─────────────────────────────────────────
OUT="$TMP/run.out"
CONF_ASSERT_DIR="$TMP" bash "$RUNCONF" > "$OUT" 2>&1
RC=$?

echo "── run-conformance.sh over fixtures: exit=$RC ──"

# Assert against the per-BC ROLLUP (the surface the bug corrupted: it read GREEN on an
# empty tally) and the NAMED reason strings — robust to the icon/column formatting.
ck "gate exited NON-zero (RED) on a mixed-health fixture set"      test "$RC" -ne 0
ck "the clean rig rolls up GREEN"                                  grep -qE 'bc-good +GREEN' "$OUT"
ck "PARSE-ABORT rig rolls up RED (not a silent GREEN skip)"        grep -qE 'bc-parsebroken +RED' "$OUT"
ck "PARSE-ABORT names the syntax error (bash -n)"                  grep -qF 'syntax error — bash -n rejected the rig' "$OUT"
ck "PARSE-ABORT rig did NOT smuggle in its post-abort PASS"        grep -qE 'bc-parsebroken +RED +\(pass=0 ' "$OUT"
ck "NO-RESULT rig rolls up RED"                                    grep -qE 'bc-noresult +RED' "$OUT"
ck "NO-RESULT names crashed-or-killed"                             grep -qF 'rig produced no RESULT line' "$OUT"
ck "NON-ZERO-EXIT rig rolls up RED"                                grep -qE 'bc-nonzero +RED' "$OUT"
ck "NON-ZERO-EXIT names the exit code"                             grep -qF 'rig exited non-zero (3)' "$OUT"

# ── a clean-only run must STILL be GREEN (guards must not false-RED) ─────────────
CLEAN="$(mktemp -d)"
cat > "$CLEAN/bc-good1.sh" <<'EOF'
#!/bin/bash
echo "RESULT|PASS|bc-good1|-|clean rig 1"
EOF
cat > "$CLEAN/bc-good2.sh" <<'EOF'
#!/bin/bash
echo "RESULT|PASS|bc-good2|-|clean rig 2"
EOF
COUT="$TMP/clean.out"
CONF_ASSERT_DIR="$CLEAN" bash "$RUNCONF" > "$COUT" 2>&1
CRC=$?
rm -rf "$CLEAN"
ck "a clean-only fixture set is GREEN (exit 0) — no false RED"     test "$CRC" -eq 0
ck "clean run reports HARNESS GREEN"                               grep -q 'HARNESS GREEN' "$COUT"

echo "── test-conformance-rig-integrity: pass=$PASS fail=$FAIL"
[[ "$FAIL" -eq 0 ]]
