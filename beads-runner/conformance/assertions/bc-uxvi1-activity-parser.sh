#!/bin/bash
# uxvi1 (FORWARD / v2) — activity-state log→state classifier, table-driven.
#
# Binds: design/activity.md §1.2 (precedence table) + UX-V2-ARCHITECTURE
# Contract D.2 (closed activity enum + 90/180s liveness). Authored HERE as part
# of the claude-tools-v2c3 green bar (TESTING-STRATEGY §6 I1: "table-driven
# parser test — feed synthetic tool-streams → exact D.2 state mapping; liveness
# 90/180 pinned with the 'do not tighten / 60s=~56 false-fires' guard;
# state_confidence always 'derived'").
#
# UNIT under test = lib/activity-classifier.sh (a PURE function). The rig sources
# it directly — no runner spawn — and pins the §1.2 mapping, the 90/180 SPINE
# windows, and the derived-confidence invariant. The runner-side wiring + the
# agent-activity-report publish are claude-tools-uxvi1's remaining surface.
#
# SCAR (silent-when-wrong): a stale "writing-code" outliving the agent that
# stopped (silence gate must win); a 60s window that flaps ~56× (must not
# tighten); a maybe-stuck rendered red while the agent legitimately waits on an
# ask-brian decision (waiting-on-you must suppress maybe-stuck).
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/activity-classifier.sh"

# _state <delta> <tool> <askbrian> <rl> <bash> <expected> <desc>
_state() {
  local got; got="$(activity_classify_state "$1" "$2" "$3" "$4" "$5")"
  _expect "uxvi1" "activity.md§1.2" "$7"
  _need "Δ=$1 tool='$2' ab=$3 rl=$4 bash='$5' ⇒ '$6' (got '$got')" test "$got" = "$6"
  _need "state '$got' is in the closed D.2 enum" \
    bash -c 'case "'"$got"'" in writing-code|running-tests|exploring|thinking|waiting-on-you|rate-limited|maybe-stuck) exit 0;; *) exit 1;; esac'
  _emit
}
# _dot <delta> <expected> <desc>
_dot() {
  local got; got="$(activity_liveness_dot "$1")"
  _expect "uxvi1" "D.2-liveness" "$3"
  _need "dot(Δ=$1) ⇒ '$2' (got '$got')" test "$got" = "$2"
  _emit
}

# ── event-keyed states (live, Δ<90s) ─────────────────────────────────────────
_state 10  Edit      0 0 ""               writing-code  "Edit ⇒ writing-code"
_state 10  Write     0 0 ""               writing-code  "Write ⇒ writing-code"
_state 10  MultiEdit 0 0 ""               writing-code  "MultiEdit ⇒ writing-code"
_state 10  Bash      0 0 "npm test"       running-tests "Bash 'npm test' ⇒ running-tests"
_state 10  Bash      0 0 "pytest -q"      running-tests "Bash 'pytest' ⇒ running-tests"
_state 10  Bash      0 0 "go test ./..."  running-tests "Bash 'go test' ⇒ running-tests"
_state 5   Bash      0 0 "bash beads-runner/run-tests.sh --tier lib" running-tests "Bash run-tests.sh ⇒ running-tests"
_state 10  Bash      0 0 "ls -la /tmp"    exploring     "non-test Bash ⇒ exploring"
_state 10  Read      0 0 ""               exploring     "Read ⇒ exploring"
_state 10  Grep      0 0 ""               exploring     "Grep ⇒ exploring"
_state 10  Glob      0 0 ""               exploring     "Glob ⇒ exploring"
_state 10  ""        0 0 ""               thinking      "no tool / assistant text ⇒ thinking (soft)"
_state 10  WeirdTool 0 0 ""               thinking      "unrecognized tool ⇒ thinking (soft, enum stays closed)"

# ── silence gate WINS over the event-keyed tool state ────────────────────────
_state 95  Edit      0 0 ""               thinking      "Δ=95 (amber) ⇒ thinking even with Edit (silence gate wins)"
_state 180 Edit      0 0 ""               thinking      "Δ=180 boundary ⇒ thinking (180 ∈ [90,180])"
_state 181 Edit      0 0 ""               maybe-stuck   "Δ=181 ⇒ maybe-stuck (silence gate >180 beats Edit)"
_state 500 Bash      0 0 "npm test"       maybe-stuck   "Δ=500 ⇒ maybe-stuck (silence beats running-tests)"
_state 90  Read      0 0 ""               thinking      "Δ=90 boundary ⇒ thinking (amber floor)"
_state 89  Read      0 0 ""               exploring     "Δ=89 ⇒ exploring (still live)"

# ── overrides: waiting-on-you + rate-limited beat the silence gate ───────────
_state 5000 ""       1 0 ""               waiting-on-you "ask-brian in-flight ⇒ waiting-on-you (suppresses maybe-stuck)"
_state 10   Edit     1 0 ""               waiting-on-you "ask-brian in-flight beats writing-code"
_state 10   ""       0 1 ""               rate-limited   "real 429 in-flight ⇒ rate-limited"
_state 300  Bash     0 1 "npm test"       rate-limited   "429 beats the silence gate"
_state 300  ""       1 1 ""               waiting-on-you "ask-brian precedence ABOVE rate-limited"

# ── liveness dot (heartbeat-only; never overridden by a state guess) ─────────
_dot 0     green "dot(0) ⇒ green"
_dot 89    green "dot(89) ⇒ green (just under amber)"
_dot 90    amber "dot(90) ⇒ amber (floor)"
_dot 179   amber "dot(179) ⇒ amber"
_dot 180   amber "dot(180) ⇒ amber (red is strictly >180)"
_dot 181   red   "dot(181) ⇒ red"
_dot 99999 red   "dot(99999) ⇒ red"

# ── 90/180 are SPINE constants — the pin guard (TESTING-STRATEGY §3 R8) ───────
# If a future edit tightens these, THIS fails loudly — re-introducing the 60s
# ~56-false-fire flap. Do not change without re-measuring.
_expect "uxvi1" "R8-guard" "liveness amber window is PINNED at 90s (do not tighten — 60s=~56 false-fires)"
_need "ACTIVITY_LIVENESS_AMBER_S must equal 90" test "$ACTIVITY_LIVENESS_AMBER_S" = "90"
_emit
_expect "uxvi1" "R8-guard" "liveness red window is PINNED at 180s (do not tighten)"
_need "ACTIVITY_LIVENESS_RED_S must equal 180" test "$ACTIVITY_LIVENESS_RED_S" = "180"
_emit

# ── state_confidence is ALWAYS "derived" (D.2 — nothing semantic asserted) ────
_expect "uxvi1" "D.2-confidence" "every activity state carries state_confidence='derived'"
_need "activity_state_confidence ⇒ derived" test "$(activity_state_confidence)" = "derived"
_need "ACTIVITY_STATE_CONFIDENCE constant is 'derived'" test "$ACTIVITY_STATE_CONFIDENCE" = "derived"
_emit
