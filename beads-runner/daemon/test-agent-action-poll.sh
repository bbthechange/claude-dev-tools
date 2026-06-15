#!/bin/bash
# beads-runner/daemon/test-agent-action-poll.sh — I4 (claude-tools-uxvi4)
# acceptance for the daemon-side agent-action executor (design/agent-action.md §4).
#
# Proves:
#   • daemon_aa_dispatch_one drops the runner-honored CONTROL MARKER for the
#     process intents (nudge / kill-retry) and reports "done";
#   • kill-gate applies the gate FIRST (gate-defer apply) THEN drops the kill
#     marker; a gate-apply failure ⇒ "failed" + NO kill marker;
#   • gate-apply / gate-lift run gate-defer in $ws (no marker);
#   • AT-MOST-ONCE: a second dispatch of the same action_id does NOT re-do the
#     host effect (the local marker short-circuits it) and still reports "done";
#   • END-TO-END through the bash oracle: an enqueued action is polled, the
#     marker drops, and the action is ACKED out of pending.

set -u
# Hermetic: this offline tier must use the IN-PROCESS bash oracle, never an
# ambient hosted endpoint. co-http-transport.sh only overrides co_request when
# COORDINATOR_URL is set, so a dev machine with the daemon configured would
# otherwise leak its live URL into the e2e subshell (the lib/conformance suites
# are hermetic for the same reason — they never set COORDINATOR_URL). CO_STORE is
# unset for the same reason: the set-desired arm writes ${CO_STORE:-<ws default>},
# so a leaked ambient CO_STORE (the daemon exports one) would redirect the local
# write away from the per-ws path the assertions read (claude-tools-jzzw).
unset COORDINATOR_URL COORDINATOR_TOKEN CO_STORE 2>/dev/null || true
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# Source the executor. Point the local at-most-once marker dir + gate-defer at
# test-controlled locations so we never touch the real cache or a real `bd`.
TMP="$(mktemp -d)"
export DAEMON_AA_DONE_DIR="$TMP/handled"
# shellcheck source=/dev/null
. "$HERE/agent-action-poll.sh"

# Record gate-defer invocations instead of running the real script.
GATE_DEFER_LOG="$TMP/gate-defer.log"
GATE_DEFER_RC=0
daemon_aa_gate_defer() { local _ws="$1"; shift; echo "$*" >> "$GATE_DEFER_LOG"; return "$GATE_DEFER_RC"; }

mk_ws() { local d="$TMP/ws-$1"; mkdir -p "$d/.beads/runner-logs"; printf '%s' "$d"; }
marker_dir() { printf '%s/.beads/runner-logs/agent-action' "$1"; }
markers_in() { ls "$(marker_dir "$1")"/*.json 2>/dev/null | wc -l | tr -d ' '; }

# ── nudge: drops a control marker, reports done ──────────────────────────────
echo "── nudge ──"
WS="$(mk_ws nudge)"
st="$(daemon_aa_dispatch_one "$WS" '{"action_id":"a-nudge","intent":"nudge","target":{"bead_ref":"x-1"},"args":{"reason":"poke"}}')"
[[ "$st" == "done" ]] && ok "nudge ⇒ done" || bad "nudge should be done (got '$st')"
[[ "$(markers_in "$WS")" == "1" ]] && ok "nudge dropped a control marker" || bad "nudge marker not dropped"
grep -q '"intent":"nudge"' "$(marker_dir "$WS")"/a-nudge.json 2>/dev/null \
  && ok "marker carries intent=nudge" || bad "marker missing intent"
grep -q '"bead_ref":"x-1"' "$(marker_dir "$WS")"/a-nudge.json 2>/dev/null \
  && ok "marker carries bead_ref" || bad "marker missing bead_ref"

# ── kill-retry: drops a kill marker, reports done ────────────────────────────
echo "── kill-retry ──"
WS="$(mk_ws killretry)"
st="$(daemon_aa_dispatch_one "$WS" '{"action_id":"a-kr","intent":"kill-retry","target":{"bead_ref":"x-2"},"args":{}}')"
[[ "$st" == "done" ]] && ok "kill-retry ⇒ done" || bad "kill-retry should be done (got '$st')"
[[ "$(markers_in "$WS")" == "1" ]] && ok "kill-retry dropped a kill marker" || bad "kill marker not dropped"

# ── kill-gate: gate applied FIRST, then kill marker ──────────────────────────
echo "── kill-gate (apply-then-kill) ──"
WS="$(mk_ws killgate)"; : > "$GATE_DEFER_LOG"; GATE_DEFER_RC=0
st="$(daemon_aa_dispatch_one "$WS" '{"action_id":"a-kg","intent":"kill-gate","target":{"bead_ref":"x-3","gate_id":"g1"},"args":{"date":"2030-01-01"}}')"
[[ "$st" == "done" ]] && ok "kill-gate ⇒ done" || bad "kill-gate should be done (got '$st')"
grep -q '^apply g1 x-3 2030-01-01' "$GATE_DEFER_LOG" 2>/dev/null \
  && ok "kill-gate ran gate-defer apply g1 x-3 2030-01-01" || bad "gate-defer apply not invoked correctly ($(cat "$GATE_DEFER_LOG" 2>/dev/null))"
[[ "$(markers_in "$WS")" == "1" ]] && ok "kill-gate dropped the kill marker AFTER the gate" || bad "kill marker not dropped"

# ── kill-gate where the gate apply FAILS: no kill marker, reports failed ─────
echo "── kill-gate (apply fails ⇒ no kill) ──"
WS="$(mk_ws killgatefail)"; : > "$GATE_DEFER_LOG"; GATE_DEFER_RC=1
st="$(daemon_aa_dispatch_one "$WS" '{"action_id":"a-kgf","intent":"kill-gate","target":{"bead_ref":"x-4","gate_id":"g2"},"args":{"date":"2030-01-01"}}')"
GATE_DEFER_RC=0
[[ "$st" == "failed" ]] && ok "kill-gate with a failed gate apply ⇒ failed" || bad "should be failed (got '$st')"
[[ "$(markers_in "$WS")" == "0" ]] && ok "NO kill marker when the gate apply failed (don't kill ungated)" || bad "kill marker dropped despite failed gate"

# ── gate-apply over a cohort: gate-defer per bead, no marker ─────────────────
echo "── gate-apply (cohort) ──"
WS="$(mk_ws gateapply)"; : > "$GATE_DEFER_LOG"; GATE_DEFER_RC=0
st="$(daemon_aa_dispatch_one "$WS" '{"action_id":"a-ga","intent":"gate-apply","target":{"gate_id":"g3","bead_refs":["x-5","x-6"]},"args":{"date":"2030-01-01"}}')"
[[ "$st" == "done" ]] && ok "gate-apply ⇒ done" || bad "gate-apply should be done (got '$st')"
[[ "$(grep -c '^apply g3' "$GATE_DEFER_LOG" 2>/dev/null)" == "2" ]] \
  && ok "gate-apply ran gate-defer apply for each bead in the cohort" || bad "gate-apply cohort count wrong"
[[ "$(markers_in "$WS")" == "0" ]] && ok "gate-apply dropped NO control marker (label intent, no runner)" || bad "gate-apply dropped a marker"

# ── gate-lift: gate-defer lift --commit ──────────────────────────────────────
echo "── gate-lift ──"
WS="$(mk_ws gatelift)"; : > "$GATE_DEFER_LOG"; GATE_DEFER_RC=0
st="$(daemon_aa_dispatch_one "$WS" '{"action_id":"a-gl","intent":"gate-lift","target":{"gate_id":"g4"},"args":{}}')"
[[ "$st" == "done" ]] && ok "gate-lift ⇒ done" || bad "gate-lift should be done (got '$st')"
grep -q '^lift g4 --commit' "$GATE_DEFER_LOG" 2>/dev/null \
  && ok "gate-lift ran gate-defer lift g4 --commit" || bad "gate-defer lift not invoked ($(cat "$GATE_DEFER_LOG"))"

# ── AT-MOST-ONCE: a second dispatch does NOT re-drop the marker ──────────────
echo "── at-most-once ──"
WS="$(mk_ws amo)"
daemon_aa_dispatch_one "$WS" '{"action_id":"a-amo","intent":"kill-retry","target":{"bead_ref":"x-7"},"args":{}}' >/dev/null
rm -f "$(marker_dir "$WS")"/a-amo.json   # simulate the runner consuming the marker
st="$(daemon_aa_dispatch_one "$WS" '{"action_id":"a-amo","intent":"kill-retry","target":{"bead_ref":"x-7"},"args":{}}')"
[[ "$st" == "done" ]] && ok "re-dispatch of a handled action ⇒ done (ack re-attempt)" || bad "re-dispatch wrong status (got '$st')"
[[ "$(markers_in "$WS")" == "0" ]] && ok "re-dispatch did NOT re-drop the kill marker (local marker short-circuits)" || bad "marker re-dropped — NOT at-most-once"

# ── set-desired: applies the requested state to the LOCAL .co-store ──────────
# claude-tools-y6j9 local-first: the daemon is the SINGLE writer of local
# desired (a stopped/dead runner can't apply "running" to itself). Brian's tap
# rides the agent_actions queue as a set-desired intent; the daemon consumes it
# and writes the LOCAL runner_state record the runner/daemon read FIRST.
echo "── set-desired (local-first change-request) ──"
WS="$(mk_ws setdesired)"
st="$(daemon_aa_dispatch_one "$WS" '{"action_id":"a-sd","intent":"set-desired","workspace":"sdProj","target":{},"args":{"state":"paused"},"owner":"you"}')"
[[ "$st" == "done" ]] && ok "set-desired ⇒ done" || bad "set-desired should be done (got '$st')"
SD_REC="$WS/.beads/runner-logs/.co-store/records/runner_state.sdProj.json"
[[ -f "$SD_REC" ]] && ok "set-desired wrote the LOCAL runner_state record" || bad "local runner_state record not written ($SD_REC)"
[[ "$(jq -r '.desired // ""' "$SD_REC" 2>/dev/null)" == "paused" ]] \
  && ok "local runner_state.desired = paused (the runner/daemon read THIS first)" || bad "local desired not paused ($(cat "$SD_REC" 2>/dev/null))"
[[ "$(markers_in "$WS")" == "0" ]] && ok "set-desired dropped NO control marker (loop-level, not a worker kill)" || bad "set-desired dropped a marker"
# A later set-desired(running) overwrites it (FIFO transitions converge locally).
daemon_aa_dispatch_one "$WS" '{"action_id":"a-sd2","intent":"set-desired","workspace":"sdProj","target":{},"args":{"state":"running"}}' >/dev/null
[[ "$(jq -r '.desired // ""' "$SD_REC" 2>/dev/null)" == "running" ]] \
  && ok "a later set-desired(running) overwrites local desired" || bad "local desired not updated to running"
# A bad/missing state ⇒ failed, NO write.
WS2="$(mk_ws setdesiredbad)"
st="$(daemon_aa_dispatch_one "$WS2" '{"action_id":"a-sdb","intent":"set-desired","workspace":"sdProj","target":{},"args":{"state":"halt"}}')"
[[ "$st" == "failed" ]] && ok "set-desired bad state ⇒ failed" || bad "bad state should be failed (got '$st')"
[[ ! -f "$WS2/.beads/runner-logs/.co-store/records/runner_state.sdProj.json" ]] \
  && ok "bad state wrote NO local record" || bad "bad state wrote a record"

# ── END-TO-END through the bash oracle ───────────────────────────────────────
echo "── end-to-end (oracle → poll → ack) ──"
E2E_STORE="$TMP/e2e-store"; mkdir -p "$E2E_STORE"
WS="$(mk_ws e2e)"
export CO_STORE="$E2E_STORE"
( set +u; source "$REPO/lib/coordinator.sh"
  co_request bearer-x agent-action '{"intent":"kill-retry","workspace":"e2eProj","target":{"bead_ref":"e2eProj-1"},"args":{"reason":"stuck"}}' >/dev/null )
# Fake a one-workspace registry pointing at WS / project_ref e2eProj.
registry_count() { echo 1; }
REGISTRY_DIRS=("$WS"); REGISTRY_PROJECT_REFS=("e2eProj")
REGISTRY_COORDINATOR_URLS=(""); REGISTRY_TOKEN_KEYCHAIN_ITEMS=("")
daemon_agent_action_poll_once
[[ "$(markers_in "$WS")" == "1" ]] && ok "poll dropped the control marker for the enqueued action" || bad "poll did not drop a marker"
remaining="$( ( set +u; source "$REPO/lib/coordinator.sh"; co_request bearer-x agent-action-pending e2eProj | jq -r '.actions|length' ) )"
[[ "$remaining" == "0" ]] && ok "poll ACKED the action out of pending (oracle status flipped)" || bad "action still pending after poll (n=$remaining)"

rm -rf "$TMP"
echo ""
echo "════════════════════════════════════════════════════════════════════════"
printf '  RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "════════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
