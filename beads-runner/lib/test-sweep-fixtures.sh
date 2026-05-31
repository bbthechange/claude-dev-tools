#!/usr/bin/env bash
# beads-runner/lib/test-sweep-fixtures.sh — regression coverage for the orphaned
# LIVE-bd fixture self-heal (lib/sweep-fixtures.sh, claude-tools-fxsweep).
#
# WHAT THIS PINS — the sweep DELETES beads, so the safety-critical property is the
# JOIN: it must delete ONLY beads carrying the exact 'test-bd-ready-ordering-'
# fixture-label prefix, and NEVER a real bead (test-infra / gate / human / a
# near-miss 'test-bd-readiness-' prefix). A jq-filter typo that emitted every id
# would wipe the live DB; this test is the guard against that regression.
#
# ISOLATION (TESTING-STRATEGY §8): a STATEFUL FAKE `bd` on PATH — same precedent
# as test-bd-stage.sh — so nothing touches the live workspace. The fake `bd list`
# DELIBERATELY ignores its filter flags and always returns the full set: that
# mirrors the real bd v1.0.4 bug where --label-pattern/--label-regex are no-ops
# (return the whole DB), so this test also fails loudly if the implementation ever
# regresses to leaning on a CLI-side label filter instead of the jq join.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/test-assert.sh
source "$HERE/test-assert.sh"

command -v jq >/dev/null 2>&1 || { echo "test-sweep-fixtures.sh: reject — jq not on PATH" >&2; exit 2; }

WORK="$(mktemp -d 2>/dev/null)" || { echo "mktemp failed"; exit 70; }
trap 'rm -rf "$WORK"' EXIT

# ── stateful fake bd on PATH ─────────────────────────────────────────────────
# `bd list ... --json`  → cats $FAKE_BD_JSON (ignores all filter flags, like the
#                         real broken --label-pattern).
# `bd delete ID... --force` → appends each non-flag id to $FAKE_BD_DELLOG.
FAKEBIN="$WORK/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/bd" <<'BDEOF'
#!/usr/bin/env bash
case "${1:-}" in
  list)
    cat "$FAKE_BD_JSON" 2>/dev/null || echo '[]'
    ;;
  delete)
    shift
    for a in "$@"; do
      case "$a" in --*) continue;; esac
      printf '%s\n' "$a" >> "$FAKE_BD_DELLOG"
    done
    ;;
  *) : ;;
esac
exit 0
BDEOF
chmod +x "$FAKEBIN/bd"
export PATH="$FAKEBIN:$PATH"

# ── fixtures ─────────────────────────────────────────────────────────────────
# Real beads (must survive) + two orphaned fixtures (must be swept). real4 is the
# near-miss: 'test-bd-readiness-' shares a prefix with 'test-bd-ready-' but is NOT
# 'test-bd-ready-ordering-', so it must NOT match. real6 carries a NON-STRING label
# element (42) and sits BEFORE the orphans: without the jq `type=="string"` guard
# startswith() would error there and stop enumerating, dropping orphanA/orphanB —
# so the "exactly two orphans" assertion below also pins that the scan never aborts
# short on a non-string label.
WITH_ORPHANS="$WORK/with-orphans.json"
cat > "$WITH_ORPHANS" <<'JSON'
[
  {"id":"claude-tools-real1","labels":["test-infra","gate"]},
  {"id":"claude-tools-real2","labels":["human"]},
  {"id":"claude-tools-real3","labels":[]},
  {"id":"claude-tools-real4","labels":["test-bd-readiness-12345"]},
  {"id":"claude-tools-real5"},
  {"id":"claude-tools-real6","labels":[42,"weird-non-string"]},
  {"id":"claude-tools-orphanA","labels":["test-bd-ready-ordering-12345","human-triage"]},
  {"id":"claude-tools-orphanB","labels":["test-bd-ready-ordering-67890","human-triage"]}
]
JSON

NO_ORPHANS="$WORK/no-orphans.json"
cat > "$NO_ORPHANS" <<'JSON'
[
  {"id":"claude-tools-real1","labels":["test-infra","gate"]},
  {"id":"claude-tools-real2","labels":["human"]}
]
JSON

# shellcheck source=lib/sweep-fixtures.sh
source "$HERE/sweep-fixtures.sh"

# ── T1: fixture_orphan_ids selects ONLY the orphans ──────────────────────────
export FAKE_BD_JSON="$WITH_ORPHANS"
export FAKE_BD_DELLOG="$WORK/del1.log"; : > "$FAKE_BD_DELLOG"
ids="$(fixture_orphan_ids | sort | tr '\n' ',')"
ck "T1: orphan ids = exactly the two fixture beads"   eq "$ids" "claude-tools-orphanA,claude-tools-orphanB,"
ck "T1: a real bead (test-infra) is NOT selected"     hasnt "real1" "$ids"
ck "T1: bead with empty labels is NOT selected"       hasnt "real3" "$ids"
ck "T1: bead with NO labels key is NOT selected"       hasnt "real5" "$ids"
ck "T1: near-miss 'test-bd-readiness-' is NOT selected" hasnt "real4" "$ids"
ck "T1: a non-string label element does NOT abort the scan" hasnt "real6" "$ids"

# ── T2: sweep_fixtures deletes ONLY the orphans, and announces the count ─────
out="$(sweep_fixtures)"
dels="$(sort "$FAKE_BD_DELLOG" | tr '\n' ',')"
ck "T2: delete log = exactly the two orphans"         eq "$dels" "claude-tools-orphanA,claude-tools-orphanB,"
ck "T2: no real bead was deleted"                      hasnt "real" "$dels"
ck "T2: summary line names the count (2)"             has "deleting 2 " "$out"
ck "T2: summary names an orphan id"                   has "orphanA" "$out"

# ── T3: healthy workspace — nothing to sweep, sweep is silent ────────────────
export FAKE_BD_JSON="$NO_ORPHANS"
export FAKE_BD_DELLOG="$WORK/del3.log"; : > "$FAKE_BD_DELLOG"
ids3="$(fixture_orphan_ids)"
ck "T3: no orphans selected when DB is clean"         eq "$ids3" ""
out3="$(sweep_fixtures)"
ck "T3: sweep prints nothing when DB is clean"        eq "$out3" ""
ck "T3: sweep deletes nothing when DB is clean"       eq "$(cat "$FAKE_BD_DELLOG")" ""

summary "test-sweep-fixtures"
