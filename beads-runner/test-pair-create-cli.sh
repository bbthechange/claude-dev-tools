#!/bin/bash
# beads-runner/test-pair-create-cli.sh — offline smoke for the N10-10
# (claude-tools-l6vx) kind:"pair" producer CLI, pair-create.sh.
#
# Exercises ONLY the --dry-run path (which runs the REAL pair_create producer
# against a throwaway in-process store — NO engine, NO Keychain, NO network)
# plus the arg-validation / usage surface. The producer's full behavior +
# differential equivalence is proven in lib/test-ready-to-pair.sh (EXIT-PROD)
# and cf/test/ready-to-pair.spec.js (EXIT-PROD); this guards the CLI wiring
# (arg parser, lib sourcing, dry-run isolation) only.
set -u

CLI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pair-create.sh"
[[ -x "$CLI" ]] || { echo "FATAL: pair-create.sh not found/executable at $CLI"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2' want '$3')"; fi; }

echo "── pair-create.sh --dry-run: the producer builds the canonical kind:'pair' envelope ──"
OUT="$("$CLI" --bead-ref=claude-tools-l6vx --scheduled-at=2099-06-02T15:00:00Z --tldr="pair on the CLI" --dry-run 2>/dev/null)"
eq "dry-run emits a kind:'pair' envelope"            "$(jq -r '.kind'         <<<"$OUT" 2>/dev/null)" "pair"
eq "dry-run tier is 'blocking' (§10.2 r10)"          "$(jq -r '.tier'         <<<"$OUT" 2>/dev/null)" "blocking"
eq "dry-run trigger is 'proactive_checkpoint'"       "$(jq -r '.trigger'      <<<"$OUT" 2>/dev/null)" "proactive_checkpoint"
eq "dry-run carries the scheduled_at appointment"    "$(jq -r '.scheduled_at' <<<"$OUT" 2>/dev/null)" "2099-06-02T15:00:00Z"
eq "dry-run id is the deterministic pair-<bead_ref>" "$(jq -r '.id'           <<<"$OUT" 2>/dev/null)" "pair-claude-tools-l6vx"
eq "dry-run is a 0-item SESSION CARD (§4.2)"         "$(jq -r '.items|length' <<<"$OUT" 2>/dev/null)" "0"
eq "dry-run tldr is the session topic"               "$(jq -r '.body.tldr'    <<<"$OUT" 2>/dev/null)" "pair on the CLI"
eq "dry-run wrote NO timer_fire_at"                  "$(jq -r '.timer_fire_at' <<<"$OUT" 2>/dev/null)" "null"

echo ""
echo "── pair-create.sh: default tldr + explicit --dossier-id ──"
OUT2="$("$CLI" --bead-ref=abc --scheduled-at=2099-01-01T00:00:00Z --dossier-id=my-pair-1 --dry-run 2>/dev/null)"
eq "default tldr is 'pair on <bead_ref>'"            "$(jq -r '.body.tldr' <<<"$OUT2" 2>/dev/null)" "pair on abc"
eq "explicit --dossier-id is honored"                "$(jq -r '.id'        <<<"$OUT2" 2>/dev/null)" "my-pair-1"

echo ""
echo "── pair-create.sh: fail-closed rejects ──"
"$CLI" --bead-ref=x --scheduled-at=not-a-date --dry-run >/dev/null 2>&1
eq "unparseable --scheduled-at ⇒ rc 1 (fail-closed, NO dossier)" "$?" "1"
"$CLI" --bead-ref=x --scheduled-at=2099-01-01T00:00:00Z --dossier-id=../evil --dry-run >/dev/null 2>&1
eq "unsafe --dossier-id ⇒ rc 1"                                  "$?" "1"
"$CLI" --bead-ref=x >/dev/null 2>&1
eq "missing --scheduled-at ⇒ rc 2 (usage error)"                 "$?" "2"
"$CLI" --scheduled-at=2099-01-01T00:00:00Z >/dev/null 2>&1
eq "missing --bead-ref ⇒ rc 2 (usage error)"                     "$?" "2"
"$CLI" --bogus-flag >/dev/null 2>&1
eq "unknown argument ⇒ rc 2"                                     "$?" "2"

echo ""
echo "── pair-create.sh --help: prints usage, never spills shell code ──"
HELP="$("$CLI" --help 2>&1)"; HRC=$?
eq "--help ⇒ rc 0"                                   "$HRC" "0"
if grep -q -- 'set -euo pipefail' <<<"$HELP"; then bad "--help must NOT print 'set -euo pipefail' (sed range spilled into code)"; else ok "--help stops at the header (no shell-code spill)"; fi
if grep -q -- '--scheduled-at' <<<"$HELP"; then ok "--help documents --scheduled-at"; else bad "--help is missing the usage body"; fi

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " test-pair-create-cli (N10-10, claude-tools-l6vx):  PASS=$PASS  FAIL=$FAIL"
echo "══════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
