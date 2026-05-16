#!/bin/bash
# Conformance harness runner — T1a (claude-tools-ooc).
#
# Runs every assertion rig against the CURRENT beads-runner/run-beads-tasks.sh
# and prints a per-BC verdict. This is the shared regression gate the
# beads-runner overhaul (epic claude-tools-glk) binds to; T1b reuses this same
# framework for the coordinator/observability SCARs.
#
# RESULT protocol (see lib/harness.sh):
#   PASS          regression green — current script exhibits the SCAR
#   FAIL          regression broken (harness bug OR a real script regression)
#   GATE-PENDING  forward criterion not yet satisfiable on the CURRENT script —
#                 the LITERAL close-criterion T2/T3 must flip GREEN (expected
#                 here, pre-rewrite; does NOT fail the current-script verdict)
#   GATE-MET      forward criterion already satisfied (informational)
#
# EXIT-criterion-1 verdict (this runner's exit code):
#   0  iff  zero FAIL  AND  every GATE produced its documented pre-rewrite
#           state — i.e. the harness is proven correct against the frozen
#           current behavior and ready to gate the rewrite.
#   1  otherwise (a regression assertion failed → harness or script is wrong).
#
# Usage:
#   bash beads-runner/conformance/run-conformance.sh            # all
#   bash beads-runner/conformance/run-conformance.sh bc-21 bc-35 # subset (substr)
set -u

CONF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSERT_DIR="$CONF_DIR/assertions"
RESULTS="$(mktemp)"
trap 'rm -f "$RESULTS"' EXIT

filter=("$@")
match() {
  [[ ${#filter[@]} -eq 0 ]] && return 0
  local f; for f in "${filter[@]}"; do [[ "$1" == *"$f"* ]] && return 0; done
  return 1
}

echo "═══════════════════════════════════════════════════════════════════════"
echo " beads-runner conformance harness — T1a (claude-tools-ooc)"
echo " target: $(cd "$CONF_DIR/.." && pwd)/run-beads-tasks.sh"
echo " binds : INTERFACE.md v1 §3, §7.1, §7.5, §8.1/§8.2 (terminal-reason /"
echo "         classification precedence) — assertions are the literal"
echo "         close-criteria T2/T3 cite by BC id."
echo "═══════════════════════════════════════════════════════════════════════"

ran=0
for rig in "$ASSERT_DIR"/bc-*.sh; do
  base="$(basename "$rig" .sh)"
  match "$base" || continue
  ran=$((ran+1))
  echo ""
  echo "▶ $base"
  # Each rig prints RESULT|… lines on stdout, diagnostics on stderr.
  bash "$rig" 2> >(sed 's/^/    /' >&2) | tee -a "$RESULTS" \
    | while IFS='|' read -r tag status bc cite desc; do
        [[ "$tag" == RESULT ]] || continue
        case "$status" in
          PASS)         icon="✓ PASS       " ;;
          FAIL)         icon="✗ FAIL       " ;;
          GATE-PENDING) icon="◌ GATE(pend) " ;;
          GATE-MET)     icon="◑ GATE(met)  " ;;
          *)            icon="? $status " ;;
        esac
        printf '   %s %-9s %-7s %s\n' "$icon" "$bc" "$cite" "$desc"
      done
done

echo ""
echo "═══════════════════════════════════════════════════════════════════════"
if [[ $ran -eq 0 ]]; then
  echo " no rigs matched filter: ${filter[*]:-<none>}"
  exit 1
fi

pass=$(grep -c '^RESULT|PASS|'         "$RESULTS" || true)
fail=$(grep -c '^RESULT|FAIL|'         "$RESULTS" || true)
gpen=$(grep -c '^RESULT|GATE-PENDING|' "$RESULTS" || true)
gmet=$(grep -c '^RESULT|GATE-MET|'     "$RESULTS" || true)

echo " Summary:  PASS=$pass  FAIL=$fail  GATE-PENDING=$gpen  GATE-MET=$gmet"
echo ""

# Per-BC rollup (a BC is GREEN iff it has ≥1 PASS and 0 FAIL).
echo " Per-BC regression rollup:"
awk -F'|' '
  $1=="RESULT"{
    bc=$3;
    if(!(bc in seen)){ seen[bc]=1; order[++n]=bc }
    if($2=="PASS")       p[bc]++
    else if($2=="FAIL")  f[bc]++
    else if($2 ~ /^GATE/) g[bc]++
  }
  END{
    for(i=1;i<=n;i++){
      bc=order[i];
      st=(f[bc]>0?"RED   ":(p[bc]>0?"GREEN ":"gate  "));
      printf("   %-10s %s   (pass=%d fail=%d gate=%d)\n",bc,st,p[bc]+0,f[bc]+0,g[bc]+0)
    }
  }' "$RESULTS"

echo ""
if [[ "$fail" -eq 0 ]]; then
  echo " ✓ HARNESS GREEN — every regression assertion passes against the"
  echo "   current run-beads-tasks.sh; $gpen forward gate(s) correctly PENDING"
  echo "   (the literal close-criteria T2/T3 must flip to GREEN)."
  echo "═══════════════════════════════════════════════════════════════════════"
  exit 0
else
  echo " ✗ HARNESS RED — $fail regression assertion(s) failed. Either the"
  echo "   harness is wrong or run-beads-tasks.sh regressed a SCAR. Per"
  echo "   ANTI-DRIFT, a changed EXPECTED behavior escalates to"
  echo "   claude-tools-65z — never edit the assertion to make it pass."
  echo "═══════════════════════════════════════════════════════════════════════"
  exit 1
fi
