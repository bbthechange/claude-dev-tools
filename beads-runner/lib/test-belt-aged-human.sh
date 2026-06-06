#!/bin/bash
# beads-runner/lib/test-belt-aged-human.sh — claude-tools-309l acceptance.
#
# _bead_blocked_for_human is the v1 last-resort BELT (claude-tools-1vnx) that pins
# a human-decision fork the worker left in place, INDEPENDENT of the §7.3 preempt.
# 1vnx fired it on `human` + (blocked | unreadable). 309l EXTENDS it to ALSO catch
# the aged-out residual: a `human`-labelled bead the worker left NOT blocked
# (slipped the status flip — the m3xi vector) whose STUCK_NEEDS_HUMAN note has aged
# past detect_worker_stuck_primary's recency window (uxvi4), so neither the §7.3
# Case-3 preempt nor 1vnx's belt could see it → TASK_NOT_CLOSED → reset/thrash.
#
# The contract this pins (the recency-INDEPENDENT, over-trigger-SAFE recogniser):
#   • human + blocked                      ⇒ FIRE  (1vnx, unchanged)
#   • human + UNREADABLE status            ⇒ FIRE  (1vnx fail-SAFE, unchanged)
#   • human + open|in_progress + worker note (bare OR aged @epoch) ⇒ FIRE  (309l)
#   • human + in_progress + ONLY a runner audit line               ⇒ NO fire
#       (the `(?<!Runner: )` lookbehind drops the runner's own residue — the
#        dominant uxvi4 over-trigger vector; this is what keeps Fix-B closed)
#   • human + in_progress + NO note        ⇒ NO fire  (bare label ≠ fork — the
#                                            test-stuck-primary-relaxed posture)
#   • NO human + in_progress + note        ⇒ NO fire  (the label is required)
#   • human + CLOSED + note                ⇒ NO fire  (a SUCCESS must never be
#                                            pinned back to blocked)
#
# Extracted from run-beads-tasks.sh and evaluated in-process with a mocked `bd`,
# mirroring test-stuck-primary-relaxed.sh.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$HERE/../run-beads-tasks.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

FN_SRC="$(awk '
  /^_bead_blocked_for_human\(\) \{/ { in_fn=1 }
  in_fn { print }
  in_fn && /^\}/ { exit }
' "$RUNNER")"
if [[ -z "$FN_SRC" ]]; then
  bad "could not extract _bead_blocked_for_human from $RUNNER"
  echo "RESULT: 0 passed, 1 failed"; exit 1
fi

# Run one case: $1=desc, $2=expect(fire|no), $3=labels-json, $4=status, $5=notes.
# A status of "__UNREADABLE__" makes `bd show` echo nothing (the fail-SAFE probe).
run_case() {
  local desc="$1" expect="$2" labels_json="$3" status="$4" notes="$5" rc
  (
    eval "$FN_SRC"
    export _CASE_LABELS="$labels_json" _CASE_STATUS="$status" _CASE_NOTES="$notes"
    bd() {
      case "$1 ${2:-}" in
        "label list")
          # bd label list <id> --json → JSON array of label strings
          printf '%s' "$_CASE_LABELS"; return 0 ;;
      esac
      if [[ "$1" == "show" ]]; then
        local long=0 a
        for a in "$@"; do [[ "$a" == "--long" ]] && long=1; done
        [[ "$_CASE_STATUS" == "__UNREADABLE__" ]] && return 0   # empty ⇒ unreadable
        if [[ "$long" -eq 1 ]]; then
          jq -cn --arg s "$_CASE_STATUS" --arg n "$_CASE_NOTES" \
            '[{id:"x",status:$s,notes:$n}]'
        else
          jq -cn --arg s "$_CASE_STATUS" '[{id:"x",status:$s}]'
        fi
        return 0
      fi
      return 0
    }
    _bead_blocked_for_human "x"
  )
  rc=$?
  if [[ "$expect" == "fire" ]]; then
    [[ $rc -eq 0 ]] && ok "$desc ⇒ FIRE" || bad "$desc should FIRE (rc=$rc)"
  else
    [[ $rc -ne 0 ]] && ok "$desc ⇒ no fire" || bad "$desc must NOT fire (rc=$rc)"
  fi
}

NOW="$(date +%s)"; AGED=$(( NOW - 99999 ))

echo "── 1vnx (unchanged): canonical + fail-safe ──"
run_case "human + blocked"                      fire '["human"]'        blocked     ""
run_case "human + UNREADABLE status"            fire '["human"]'        __UNREADABLE__ ""

echo ""
echo "── 309l (new): aged-out human + NOT-blocked + worker note ──"
run_case "human + in_progress + AGED @epoch note" fire '["human"]'      in_progress "STUCK_NEEDS_HUMAN@${AGED}
The ask: pick A or B"
run_case "human + open + bare worker note"      fire '["human"]'        open        "prior text
STUCK_NEEDS_HUMAN
The ask: foo"

echo ""
echo "── over-trigger SAFETY (Fix-B must stay closed) ──"
run_case "human + in_progress + ONLY runner audit line" no '["human"]'  in_progress "Runner: STUCK_NEEDS_HUMAN at 10:00:00Z — no stream preserved"
run_case "human + in_progress + NO note"        no   '["human"]'        in_progress ""
run_case "NO human label + in_progress + note"  no   '["model:opus"]'   in_progress "STUCK_NEEDS_HUMAN@${AGED}"
run_case "human + CLOSED + note (a SUCCESS)"    no   '["human"]'        closed      "STUCK_NEEDS_HUMAN@${AGED}"

echo ""
echo "════════════════════════════════════════════════════════════════════════"
printf '  RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "════════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
