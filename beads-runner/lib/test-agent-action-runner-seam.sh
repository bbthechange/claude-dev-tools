#!/bin/bash
# beads-runner/lib/test-agent-action-runner-seam.sh — I4 (claude-tools-uxvi4).
#
# The RUNNER SIDE of the agent-action seam (design/agent-action.md §4): the v2
# runner.sh watchdog honors a daemon-dropped CONTROL MARKER. The daemon drops
# <ws>/.beads/runner-logs/agent-action/<id>.json; the watchdog reads it each tick
# and:
#   • nudge      ⇒ extend the idle-grace one window (veto a pending kill), NO kill
#   • kill-retry ⇒ terminate the worker + emit WATCHDOG_KILL=1 (reset-to-open ⇒ re-dispatch)
#   • kill-gate  ⇒ terminate the worker (the daemon already applied gate:* ⇒ J4 refuses re-pickup)
#   • a marker for a DIFFERENT bead (stale/late) ⇒ consumed, NO effect
#
# _watchdog_scan_agent_action + _watchdog_signal_worker are extracted from
# runner.sh and exercised in-process (the test-stuck-primary-relaxed.sh idiom),
# so we never spawn the whole loop.

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
SIG_FN="$(extract_fn _watchdog_signal_worker)"
SCAN_FN="$(extract_fn _watchdog_scan_agent_action)"
if [[ -z "$SIG_FN" || -z "$SCAN_FN" ]]; then
  bad "could not extract the watchdog helpers from $RUNNER"
  echo "RESULT: 0 passed, 1 failed"; exit 1
fi
eval "$SIG_FN"
eval "$SCAN_FN"

TMP="$(mktemp -d)"
MDIR="$TMP/.beads/runner-logs/agent-action"; mkdir -p "$MDIR"
SIG="$TMP/sig"
BEAD="proj-42"

drop() { # <action_id> <intent> <bead_ref>
  jq -cn --arg a "$1" --arg i "$2" --arg b "$3" \
    '{action_id:$a, intent:$i, bead_ref:$b, reason:"t", dropped_at:"now"}' > "$MDIR/$1.json"
}
markers() { ls "$MDIR"/*.json 2>/dev/null | wc -l | tr -d ' '; }

# ── nudge: returns "nudge", consumes marker, no kill ─────────────────────────
echo "── nudge ──"
: > "$SIG"; drop n1 nudge "$BEAD"
out="$(_watchdog_scan_agent_action "$MDIR" "$BEAD" 999999 "$SIG" 2>/dev/null)"
[[ "$out" == "nudge" ]] && ok "nudge marker ⇒ echoes 'nudge'" || bad "nudge should echo nudge (got '$out')"
[[ "$(markers)" == "0" ]] && ok "nudge marker consumed" || bad "nudge marker not consumed"
! grep -q 'WATCHDOG_KILL' "$SIG" 2>/dev/null && ok "nudge writes NO WATCHDOG_KILL (no terminate)" || bad "nudge must not write a kill marker"

# ── kill-retry: returns "kill", consumes marker, signals the worker, sig markers ─
echo "── kill-retry ──"
: > "$SIG"; sleep 60 & WPID=$!
drop k1 kill-retry "$BEAD"
out="$(_watchdog_scan_agent_action "$MDIR" "$BEAD" "$WPID" "$SIG" 2>/dev/null)"
[[ "$out" == "kill" ]] && ok "kill-retry marker ⇒ echoes 'kill'" || bad "kill-retry should echo kill (got '$out')"
[[ "$(markers)" == "0" ]] && ok "kill-retry marker consumed" || bad "kill-retry marker not consumed"
grep -q '^WATCHDOG_KILL=1' "$SIG" 2>/dev/null && ok "emits WATCHDOG_KILL=1 (FROZEN §8.1 class ⇒ reset-to-open re-dispatch)" || bad "missing WATCHDOG_KILL=1"
grep -q '^AGENT_ACTION_KILL=kill-retry' "$SIG" 2>/dev/null && ok "emits AGENT_ACTION_KILL=kill-retry (observability)" || bad "missing AGENT_ACTION_KILL line"
sleep 0.3
kill -0 "$WPID" 2>/dev/null && { bad "worker pid still alive — not signaled"; kill -KILL "$WPID" 2>/dev/null; } || ok "the worker pid was terminated"

# ── kill-gate: same kill path, distinct observability line ───────────────────
echo "── kill-gate ──"
: > "$SIG"; sleep 60 & WPID=$!
drop k2 kill-gate "$BEAD"
out="$(_watchdog_scan_agent_action "$MDIR" "$BEAD" "$WPID" "$SIG" 2>/dev/null)"
[[ "$out" == "kill" ]] && ok "kill-gate marker ⇒ echoes 'kill'" || bad "kill-gate should echo kill (got '$out')"
grep -q '^AGENT_ACTION_KILL=kill-gate' "$SIG" 2>/dev/null && ok "emits AGENT_ACTION_KILL=kill-gate" || bad "missing kill-gate observability line"
sleep 0.3; kill -0 "$WPID" 2>/dev/null && { bad "worker not signaled"; kill -KILL "$WPID" 2>/dev/null; } || ok "worker terminated"

# ── stale/late marker (different bead): consumed, no effect ──────────────────
echo "── stale marker (different bead) ──"
: > "$SIG"; drop s1 kill-retry "some-OTHER-bead"
out="$(_watchdog_scan_agent_action "$MDIR" "$BEAD" 999999 "$SIG" 2>/dev/null)"
[[ -z "$out" ]] && ok "a marker for a different bead ⇒ no action" || bad "stale marker must not act (got '$out')"
[[ "$(markers)" == "0" ]] && ok "stale marker still consumed (no lingering)" || bad "stale marker not consumed"
! grep -q 'WATCHDOG_KILL' "$SIG" 2>/dev/null && ok "stale marker writes NO kill" || bad "stale marker must not kill"

# ── kill wins over nudge in the same tick ────────────────────────────────────
echo "── kill pre-empts nudge ──"
: > "$SIG"; sleep 60 & WPID=$!
drop a1 nudge "$BEAD"; drop a2 kill-retry "$BEAD"
out="$(_watchdog_scan_agent_action "$MDIR" "$BEAD" "$WPID" "$SIG" 2>/dev/null)"
[[ "$out" == "kill" ]] && ok "a kill marker present alongside a nudge ⇒ kill wins" || bad "kill should win over nudge (got '$out')"
sleep 0.3; kill -KILL "$WPID" 2>/dev/null || true

# ── empty / missing marker dir: no-op ────────────────────────────────────────
echo "── no marker dir ──"
out="$(_watchdog_scan_agent_action "$TMP/does-not-exist" "$BEAD" 999999 "$SIG" 2>/dev/null)"
[[ -z "$out" ]] && ok "missing marker dir ⇒ silent no-op" || bad "missing dir should be a no-op (got '$out')"

# ── claude-tools-wqx7: the watchdog scan dir is a daemon→runner RENDEZVOUS, so
#    st_run_task must PIN it to the FROZEN default .beads/runner-logs/agent-action,
#    NOT derive it from $log_dir/$LOG_DIR. The daemon (daemon_aa_control_marker_dir)
#    hardcodes the same fixed path and cannot know a workspace's LOG_DIR override;
#    a $log_dir derive here would silently break the seam under a non-default
#    LOG_DIR (daemon drops in the default dir, watchdog scans the override dir).
#    design/agent-action.md §4 freezes "the marker directory". Lock the symmetry. ──
echo "── marker dir pinned to the frozen rendezvous path (wqx7) ──"
aa_assign="$(grep -E '^[[:space:]]*local agent_action_dir=' "$RUNNER")"
if printf '%s' "$aa_assign" | grep -q '\.beads/runner-logs/agent-action' \
   && ! printf '%s' "$aa_assign" | grep -qE '\$\{?(log_dir|LOG_DIR)'; then
  ok "st_run_task pins agent_action_dir to the fixed .beads/runner-logs/agent-action (not \$LOG_DIR)"
else
  bad "agent_action_dir must be the frozen fixed path, not \$log_dir/\$LOG_DIR (got: '$aa_assign')"
fi

rm -rf "$TMP"
echo ""
echo "════════════════════════════════════════════════════════════════════════"
printf '  RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "════════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
