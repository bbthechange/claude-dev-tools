#!/bin/bash
# beads-runner/lib/test-309l-v2-classify.sh — claude-tools-309l v2 acceptance.
#
# The v2 (runner.sh) conformance tree rig (bc-13-14-retry-asymmetry-tree.sh) is
# pre-existing RED on a stock macOS/bash-3.2 box (the v2 runner idles instead of
# claiming the harness-seeded tasks — a harness/env limitation, NOT this change;
# verified: the rig is equally red with a pristine runner.sh). This unit test
# pins the 309l v2 LOGIC directly — extract the recogniser + classify_failure
# from runner.sh, mock `bd`, and assert the exit-0 classification, mirroring
# lib/test-stuck-primary-relaxed.sh / lib/test-belt-aged-human.sh.
#
# Contract pinned (the v2 mirror of the v1 belt — recency-INDEPENDENT, over-
# trigger-SAFE):
#   • exit 0 + status=closed                       ⇒ SUCCESS
#   • exit 0 + status=blocked + human label        ⇒ STUCK_NEEDS_HUMAN (1vnx)
#   • exit 0 + open|in_progress + human + worker note (bare/aged) ⇒ STUCK_NEEDS_HUMAN (309l)
#   • exit 0 + in_progress + human + ONLY a runner audit line     ⇒ TASK_NOT_CLOSED
#       (the `(?<!Runner: )` lookbehind drops the runner's own residue — keeps Fix-B closed)
#   • exit 0 + in_progress + human + NO note        ⇒ TASK_NOT_CLOSED (bare label ≠ fork)
#   • exit 0 + in_progress + note + NO human label  ⇒ TASK_NOT_CLOSED (label required)

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$HERE/../runner.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

extract_fn() {
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\) \\{" { in_fn=1 }
    in_fn { print }
    in_fn && /^\}/ { exit }
  ' "$RUNNER"
}

SAFE_SRC="$(extract_fn safe_capture)"
HUMAN_SRC="$(extract_fn _bead_has_human_label)"
NOTE_SRC="$(extract_fn _bead_has_stuck_ask_note)"
CLS_SRC="$(extract_fn classify_failure)"
for v in SAFE_SRC HUMAN_SRC NOTE_SRC CLS_SRC; do
  if [[ -z "${!v}" ]]; then bad "could not extract $v from $RUNNER"; echo "RESULT: 0 passed, 1 failed"; exit 1; fi
done

# Run one classify case. $1 desc, $2 expected-class, $3 labels-json, $4 status, $5 notes.
run_case() {
  local desc="$1" want="$2" labels_json="$3" status="$4" notes="$5" got
  got="$(
    eval "$SAFE_SRC"; eval "$HUMAN_SRC"; eval "$NOTE_SRC"; eval "$CLS_SRC"
    degrade() { :; }
    WORKER_STUCK_EXIT=7
    export _CASE_LABELS="$labels_json" _CASE_STATUS="$status" _CASE_NOTES="$notes"
    bd() {
      if [[ "$1" == "label" && "${2:-}" == "list" ]]; then
        printf '%s' "$_CASE_LABELS"; return 0
      fi
      if [[ "$1" == "show" ]]; then
        local long=0 a; for a in "$@"; do [[ "$a" == "--long" ]] && long=1; done
        if [[ "$long" -eq 1 ]]; then
          jq -cn --arg s "$_CASE_STATUS" --arg n "$_CASE_NOTES" '[{id:"x",status:$s,notes:$n}]'
        else
          jq -cn --arg s "$_CASE_STATUS" '[{id:"x",status:$s}]'
        fi
        return 0
      fi
      return 0
    }
    # classify_failure <sig> <id> <exit> ; empty sig file ⇒ no stream marker
    classify_failure /dev/null "x" 0
  )"
  if [[ "$got" == "$want" ]]; then ok "$desc ⇒ $got"; else bad "$desc expected $want, got '$got'"; fi
}

NOW="$(date +%s)"; AGED=$(( NOW - 99999 ))

echo "── baseline / 1vnx (unchanged) ──"
run_case "closed bead"                       SUCCESS           '["human"]'      closed      ""
run_case "blocked + human (1vnx)"            STUCK_NEEDS_HUMAN '["human"]'      blocked     ""

echo ""
echo "── 309l (new): aged-out human + NOT-blocked + worker note ──"
run_case "in_progress + human + AGED @epoch note" STUCK_NEEDS_HUMAN '["human"]' in_progress "STUCK_NEEDS_HUMAN@${AGED}
The ask: A or B"
run_case "open + human + bare worker note"   STUCK_NEEDS_HUMAN '["human"]'      open        "x
STUCK_NEEDS_HUMAN
The ask: foo"

echo ""
echo "── over-trigger SAFETY + negatives ──"
run_case "in_progress + human + ONLY runner audit line" TASK_NOT_CLOSED '["human"]' in_progress "Runner: STUCK_NEEDS_HUMAN at 10:00:00Z — no stream preserved"
run_case "in_progress + human + NO note"     TASK_NOT_CLOSED   '["human"]'      in_progress ""
run_case "in_progress + note + NO human"     TASK_NOT_CLOSED   '["model:opus"]' in_progress "STUCK_NEEDS_HUMAN@${AGED}"

echo ""
echo "════════════════════════════════════════════════════════════════════════"
printf '  RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "════════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
