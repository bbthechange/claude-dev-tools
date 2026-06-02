#!/bin/bash
# beads-runner/lib/test-stuck-primary-relaxed.sh — claude-tools-2ir acceptance.
#
# FIX B (2ir): detect_worker_stuck_primary previously required BOTH status=
# blocked AND the `human` label. Post-mortem of n34 + the opa→n34, 4wt→4xe
# chains: agents reliably do 3 of the 4 stuck-protocol steps (label + note +
# stop) but slip step 1 (status flip). The runner fell through to
# TASK_NOT_CLOSED — the same misdiagnosis we've seen before. This test pins
# the relaxed contract:
#
#   • Case 2 (CANONICAL — unchanged): status=blocked + human  ⇒ worker_stuck.
#   • Case 3 (RELAXED — new): human label + STUCK_NEEDS_HUMAN note, status
#     NOT blocked ⇒ worker_stuck AND auto-flip to blocked AND incident log.
#   • Non-stuck (no human, no note, status=in_progress) ⇒ no fire.
#
# The function is extracted from run-beads-tasks.sh and evaluated in-process
# so we can mock `bd` and `record_incident`/`append_runner_note` without
# triggering the runner's main loop.

set -u

# claude-tools-43m gated detect_worker_stuck_primary behind ASK_BRIAN_ENABLED:
# in an opted-OUT workspace the worker prompt never mentions the stuck protocol,
# so any "stuck" signal would be spurious and the detector silently no-ops
# (returns 1, empty). This test pins the OPTED-IN relaxed contract, so it must
# opt in — exported so the per-case command-substitution subshells inherit it.
# (Added after the 2ir test was written; without it every positive case below
# returns empty and 7 assertions fail — see claude-tools-rznj.7 triage.)
export ASK_BRIAN_ENABLED=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$HERE/../run-beads-tasks.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# Extract detect_worker_stuck_primary from the runner without running it.
FN_SRC="$(awk '
  /^detect_worker_stuck_primary\(\) \{/ { in_fn=1 }
  in_fn { print }
  in_fn && /^\}/ { exit }
' "$RUNNER")"
if [[ -z "$FN_SRC" ]]; then
  bad "could not extract detect_worker_stuck_primary from $RUNNER"
  echo "RESULT: 0 passed, 1 failed"; exit 1
fi

# Run each case in its own subshell so mocks are isolated.

# ── Case 0: WORKER_STUCK_EXIT sentinel still wins (no bd call needed) ─────────
echo "── Case 0: exit==WORKER_STUCK_EXIT short-circuits to worker_stuck ──"
out="$(
  eval "$FN_SRC"
  export WORKER_STUCK_EXIT=7
  detect_worker_stuck_primary "x-1" 7 2>/dev/null
)"
[[ "$out" == "worker_stuck" ]] \
  && ok "exit=7 ⇒ worker_stuck (deterministic sentinel)" \
  || bad "exit=7 should echo worker_stuck (got '$out')"

# ── Case 2: canonical blocked+human ──────────────────────────────────────────
echo ""
echo "── Case 2 (CANONICAL — unchanged): status=blocked + human label ──"
out="$(
  eval "$FN_SRC"
  bd() {
    if [[ "$1" == "show" ]]; then
      echo '[{"id":"x-2","status":"blocked","labels":["human"],"notes":""}]'
      return 0
    fi
    return 0
  }
  export -f bd 2>/dev/null || true
  detect_worker_stuck_primary "x-2" 0 2>/dev/null
)"
[[ "$out" == "worker_stuck" ]] \
  && ok "status=blocked + human ⇒ worker_stuck (canonical path preserved)" \
  || bad "canonical blocked+human should fire (got '$out')"

# ── Case 3 (claude-tools-2ir RELAXED): human + STUCK_NEEDS_HUMAN note, no status=blocked ──
echo ""
echo "── Case 3 (RELAXED, claude-tools-2ir): human + note, status=in_progress ──"
TMP="$(mktemp -d)"
out="$(
  eval "$FN_SRC"
  AUTOFLIP_LOG="$TMP/autoflip.log"
  INCIDENT_LOG="$TMP/incident.log"
  NOTE_LOG="$TMP/note.log"
  bd() {
    if [[ "$1" == "show" ]]; then
      echo '[{"id":"x-3","status":"in_progress","labels":["human"],"notes":"Runner: foo\nSTUCK_NEEDS_HUMAN\nTL;DR: real fork\nThe ask: pick A or B"}]'
      return 0
    fi
    if [[ "$1" == "update" && "$3" == "--status=blocked" ]]; then
      echo "FLIPPED $2" >> "$AUTOFLIP_LOG"
      return 0
    fi
    return 0
  }
  record_incident() { echo "INCIDENT $*" >> "$INCIDENT_LOG"; }
  append_runner_note() { echo "NOTE $*" >> "$NOTE_LOG"; }
  export AUTOFLIP_LOG INCIDENT_LOG NOTE_LOG
  detect_worker_stuck_primary "x-3" 0 2>/dev/null
)"
[[ "$out" == "worker_stuck" ]] \
  && ok "human + STUCK_NEEDS_HUMAN note (no status=blocked) ⇒ worker_stuck (RELAXED contract)" \
  || bad "RELAXED case must fire (got '$out')"
grep -q "FLIPPED x-3" "$TMP/autoflip.log" 2>/dev/null \
  && ok "runner AUTO-FLIPPED bead to status=blocked (downstream §7.3 sees canonical state)" \
  || bad "auto-flip to status=blocked did not happen"
grep -q "STUCK_AUTOFLIP" "$TMP/incident.log" 2>/dev/null \
  && ok "incident logged on auto-flip (visibility into agent-slip frequency)" \
  || bad "incident not recorded for auto-flip"
grep -q "STUCK_AUTOFLIP" "$TMP/note.log" 2>/dev/null \
  && ok "Runner: note appended to bead for the auto-flip (audit trail on the bead)" \
  || bad "runner note not appended for auto-flip"
rm -rf "$TMP"

# ── Case 3a (RELAXED): human + note, status already 'open' (ready re-pickup) ──
echo ""
echo "── Case 3a (RELAXED edge): human + note, status=open ──"
out="$(
  eval "$FN_SRC"
  bd() {
    if [[ "$1" == "show" ]]; then
      echo '[{"id":"x-3a","status":"open","labels":["human","model:opus"],"notes":"some prior text\nSTUCK_NEEDS_HUMAN\nThe ask: foo"}]'
      return 0
    fi
    return 0
  }
  record_incident() { :; }
  append_runner_note() { :; }
  detect_worker_stuck_primary "x-3a" 0 2>/dev/null
)"
[[ "$out" == "worker_stuck" ]] \
  && ok "RELAXED also fires when status=open (any non-blocked status with the markers)" \
  || bad "RELAXED case should still fire for status=open (got '$out')"

# ── Negative: human label only, NO STUCK_NEEDS_HUMAN note ────────────────────
echo ""
echo "── Negative: human label only, no STUCK_NEEDS_HUMAN note ──"
out="$(
  eval "$FN_SRC"
  bd() {
    if [[ "$1" == "show" ]]; then
      echo '[{"id":"x-neg-1","status":"in_progress","labels":["human"],"notes":"Runner: SUCCESS at 12:00:00Z"}]'
      return 0
    fi
    return 0
  }
  record_incident() { :; }
  append_runner_note() { :; }
  detect_worker_stuck_primary "x-neg-1" 0 2>/dev/null
)"
[[ -z "$out" ]] \
  && ok "bare human label (no STUCK_NEEDS_HUMAN note) ⇒ NO fire (label alone is not the relaxed signal)" \
  || bad "bare human label must NOT fire (got '$out')"

# ── Negative: STUCK_NEEDS_HUMAN note but NO human label ──────────────────────
echo ""
echo "── Negative: note present, no human label ──"
out="$(
  eval "$FN_SRC"
  bd() {
    if [[ "$1" == "show" ]]; then
      echo '[{"id":"x-neg-2","status":"in_progress","labels":["model:opus"],"notes":"STUCK_NEEDS_HUMAN\nThe ask: ..."}]'
      return 0
    fi
    return 0
  }
  record_incident() { :; }
  append_runner_note() { :; }
  detect_worker_stuck_primary "x-neg-2" 0 2>/dev/null
)"
[[ -z "$out" ]] \
  && ok "STUCK_NEEDS_HUMAN note without 'human' label ⇒ NO fire (both required)" \
  || bad "note without label must NOT fire (got '$out')"

# ── Negative: clean in_progress, no markers ──────────────────────────────────
echo ""
echo "── Negative: clean in_progress task, no markers ──"
out="$(
  eval "$FN_SRC"
  bd() {
    if [[ "$1" == "show" ]]; then
      echo '[{"id":"x-neg-3","status":"in_progress","labels":["model:opus"],"notes":""}]'
      return 0
    fi
    return 0
  }
  detect_worker_stuck_primary "x-neg-3" 0 2>/dev/null
)"
[[ -z "$out" ]] \
  && ok "clean in_progress ⇒ NO fire" \
  || bad "clean in_progress must NOT fire (got '$out')"

# ── claude-tools-uxvi4 (must-protect #12 / HANDOFF Fix-B): RECENT-WINDOW gate ──
# The relaxed case-3 match is tightened: a STALE machine marker no longer re-trips
# the auto-flip, the runner's OWN "Runner: STUCK_NEEDS_HUMAN at <time>" audit line
# is excluded (the dominant over-trigger), and a RECENT @epoch marker fires.
NOW="$(date +%s)"; STALE=$((NOW-99999)); FRESH=$((NOW-30))

# Build a one-row bd-show JSON with a given notes blob (jq handles all escaping —
# avoids the '"$VAR"'-inside-double-quotes literal-quote trap).
stuck_row() { jq -cn --arg n "$1" '[{id:"x",status:"open",labels:["human"],notes:$n}]'; }

echo ""
echo "── Fix-B: STALE @epoch marker (no bare, no Runner: prefix) ⇒ NO fire ──"
ROW_STALE="$(stuck_row "pending work STUCK_NEEDS_HUMAN@${STALE} ok")"
out="$(
  eval "$FN_SRC"
  bd() { [[ "$1" == "show" ]] && { printf '%s' "$ROW_STALE"; return 0; }; return 0; }
  export ROW_STALE
  record_incident() { :; }; append_runner_note() { :; }
  detect_worker_stuck_primary "x-stale" 0 2>/dev/null
)"
[[ -z "$out" ]] \
  && ok "STALE STUCK_NEEDS_HUMAN@<old-epoch> ⇒ NO auto-loop (recency closes the over-trigger)" \
  || bad "stale @epoch must NOT fire (got '$out')"

echo ""
echo "── Fix-B: RECENT @epoch marker ⇒ fires ──"
ROW_FRESH="$(stuck_row "STUCK_NEEDS_HUMAN@${FRESH} fresh stuck")"
out="$(
  eval "$FN_SRC"
  bd() { [[ "$1" == "show" ]] && { printf '%s' "$ROW_FRESH"; return 0; }; return 0; }
  export ROW_FRESH
  record_incident() { :; }; append_runner_note() { :; }
  detect_worker_stuck_primary "x-fresh" 0 2>/dev/null
)"
[[ "$out" == "worker_stuck" ]] \
  && ok "RECENT STUCK_NEEDS_HUMAN@<fresh-epoch> ⇒ fires (a genuinely-recent stuck is still caught)" \
  || bad "recent @epoch must fire (got '$out')"

echo ""
echo "── Fix-B: runner AUDIT line only (Runner: STUCK_NEEDS_HUMAN at …) ⇒ NO fire ──"
ROW_AUDIT="$(stuck_row "Runner: STUCK_NEEDS_HUMAN at 10:00:00Z — no stream preserved")"
out="$(
  eval "$FN_SRC"
  bd() { [[ "$1" == "show" ]] && { printf '%s' "$ROW_AUDIT"; return 0; }; return 0; }
  export ROW_AUDIT
  record_incident() { :; }; append_runner_note() { :; }
  detect_worker_stuck_primary "x-audit" 0 2>/dev/null
)"
[[ -z "$out" ]] \
  && ok "the runner's own audit line is NOT a fresh stuck signal (lookbehind excludes it)" \
  || bad "runner audit-only must NOT fire (got '$out')"

echo ""
echo "── Fix-B: the recent-window is env-tunable (STUCK_NOTE_RECENT_WINDOW) ──"
ROW_WIN="$(stuck_row "STUCK_NEEDS_HUMAN@${FRESH}")"
out="$(
  eval "$FN_SRC"
  export STUCK_NOTE_RECENT_WINDOW=10   # the 30s-old marker is now OUTSIDE the window
  bd() { [[ "$1" == "show" ]] && { printf '%s' "$ROW_WIN"; return 0; }; return 0; }
  export ROW_WIN
  record_incident() { :; }; append_runner_note() { :; }
  detect_worker_stuck_primary "x-win" 0 2>/dev/null
)"
[[ -z "$out" ]] \
  && ok "a 30s-old marker with a 10s window ⇒ NO fire (window is honored)" \
  || bad "tunable window not honored (got '$out')"

echo ""
echo "════════════════════════════════════════════════════════════════════════"
printf '  RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "════════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
