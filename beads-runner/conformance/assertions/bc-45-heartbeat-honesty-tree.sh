#!/bin/bash
# BC-45 — heartbeat-honesty: v2's DELIBERATE unconditional mid-task beat + the
#         watchdog soft-warn as the honest-stale signal (v2 -tree
#         coverage-hardening, claude-tools-v2cut.5)
#
# Binds: BEHAVIORAL-CONTRACT.md §BC-45 ("Heartbeat keeps the Board honest:
#        live-while-working, stale-while-stuck"). The contract's source refs
#        (255-261 hb / 2178-2211 mid-task HB subshell) are against the v1
#        2603-line run-beads-tasks.sh. v2 runner.sh re-implements the POSTURE
#        idiomatically and DEPARTS from v1's mechanism on purpose, so this rig
#        asserts the v2 INTENT, not v1's silence-on-stuck:
#
#   v1 (7v5): the mid-task `hb running` beat was STREAM-GATED — suppressed when
#             ACTIVITY_FILE was stale, so a wedged worker fell silent and the
#             Board read `stale`. Heartbeat there was PURE liveness (no lease).
#   v2 (port-forward, runner.sh ~2171-2191): the mid-task `job_heartbeat
#             running` beat is DELIBERATELY UNCONDITIONAL — it is NOT wrapped in
#             any ACTIVITY_FILE/stream-freshness conditional, because in v2
#             lease-renewal RIDES this same beat (§3 j3). Gating it would lapse
#             the lease on a CPU-busy-but-stream-quiet worker and let a sibling
#             double-claim. The honest-stale signal v1 got from gating is in v2
#             provided by the WATCHDOG instead: WATCHDOG_SOFT_WARN=180 + the
#             "possibly stuck (soft warning; still waiting)" line, escalating to
#             the BC-22 WATCHDOG_KILL incident.
#
# These mechanics are NO-OPS / un-timeable in the stub harness (job_heartbeat ->
# la_heartbeat is a stub no-op; the 180s soft-warn tier is far longer than any
# rig wall-clock), so the load-bearing assertions are SOURCE-STRUCTURAL against
# $RUNNER. A light behavioral block proves the unconditional beat does not break
# a normal run.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"   # repoint to v2
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# ── A · the mid-task `job_heartbeat running` beat is UNCONDITIONAL ────────────
# The beat lives inside the `since_hb >= HEARTBEAT_INTERVAL` branch of the
# during-task §2.5 loop. Prove it fires every interval with NO stream-freshness
# conditional wrapping it (the v1 ACTIVITY_FILE gate is GONE), and that the
# deliberate-departure rationale is pinned in the source so a future "fix" that
# re-adds the gate trips this assertion.
H_init_test bc45tree-unconditional-beat

# The during-task heartbeat branch: `job_heartbeat running ...` with the
# lease-renew comment. `beat_branch_body` extracts the lines from the
# `since_hb >= HEARTBEAT_INTERVAL` test through the `job_heartbeat running` beat,
# so we can prove the beat is reached unconditionally (the branch's only guard
# is the interval; the only statements before the beat are the `since_hb=0`
# reset + the documented comment block — there is NO `if`/`[[`/grep
# stream-freshness test wrapping the job_heartbeat call). Written to a file so
# the negation check is a plain grep, not a function call inside a subshell.
# Extract the branch body, then STRIP comment lines — the deliberate-departure
# rationale comment legitimately MENTIONS "ACTIVITY_FILE freshness" (it explains
# why v2 dropped that gate), so the no-gate assertion must look only at the
# EXECUTABLE statements, not the documentation.
beat_branch_body="$WORKDIR/.beat-branch.txt"
awk '/since_hb -ge .HEARTBEAT_INTERVAL/{f=1} f{print} /job_heartbeat running/{if(f) exit}' \
    "$RUNNER" | grep -vE '^[[:space:]]*#' > "$beat_branch_body"

_expect "BC-45" "§BC-45" "mid-task job_heartbeat running beat is UNCONDITIONAL (v2 drops v1's ACTIVITY_FILE stream-gate; lease-renew rides the beat)"
_need "the during-task heartbeat branch exists (since_hb >= HEARTBEAT_INTERVAL)" \
      grep -qE 'since_hb -ge .HEARTBEAT_INTERVAL' "$RUNNER"
_need "the mid-task running beat is present" \
      grep -qE 'job_heartbeat running' "$RUNNER"
_need "the beat renews the held lease (§3 j3 — lease-renewal rides the beat)" \
      grep -qE 'job_heartbeat running .*# renews held lease' "$RUNNER"
_need "the extracted heartbeat-branch body actually reaches the beat" \
      grep -qE 'job_heartbeat running' "$beat_branch_body"
_need "NO ACTIVITY_FILE/stream-freshness conditional wraps the beat (v1's gate is gone)" \
      bash -c '! grep -qiE "ACTIVITY_FILE|stream.fresh" "'"$beat_branch_body"'"'
_need "no ACTIVITY_FILE variable is even defined in v2 (the v1 seam is removed)" \
      bash -c '! grep -qE "ACTIVITY_FILE=" "'"$RUNNER"'"'
_need "the deliberate-departure rationale is pinned (DELIBERATELY UNCONDITIONAL)" \
      grep -qE 'DELIBERATELY UNCONDITIONAL' "$RUNNER"
_need "rationale names the v2 lease-rides-the-beat reason (regression guard)" \
      grep -qiE 'lease-renewal RIDES this same call|do NOT stream-gate it' "$RUNNER"
_emit
H_cleanup

# ── B · the watchdog provides the honest-stale signal (soft-warn tier) ────────
# In v2 the "stale-while-stuck" half of BC-45 is owned by the watchdog, not the
# heartbeat: a HARDCODED WATCHDOG_SOFT_WARN=180 tier emits an honest soft
# warning, escalating to the BC-22 WATCHDOG_KILL on a genuine wedge.
H_init_test bc45tree-soft-warn-honesty
_expect "BC-45" "§BC-45" "watchdog soft-warn is v2's honest-stale signal: WATCHDOG_SOFT_WARN=180 hardcoded + the soft-warning line"
_need "WATCHDOG_SOFT_WARN=180 is hardcoded (not env-tunable SCAR)" \
      grep -qE 'WATCHDOG_SOFT_WARN=180' "$RUNNER"
_need "the soft-warn tier is a literal constant, not a \${...:-} env default" \
      bash -c '! grep -qE "WATCHDOG_SOFT_WARN=\\\$\{" "'"$RUNNER"'"'
_need "the watchdog emits the honest soft-warning line" \
      grep -qE 'possibly stuck \(soft warning; still waiting\)' "$RUNNER"
_need "the soft-warn branch fires at WATCHDOG_SOFT_WARN once (warned-guard)" \
      grep -qE 'idle.* -ge .*WATCHDOG_SOFT_WARN.*warned.* -eq 0' "$RUNNER"
_need "soft-warn escalates to the BC-22 WATCHDOG_KILL incident on a real wedge" \
      grep -qE 'WATCHDOG_KILL=1' "$RUNNER"
_emit
H_cleanup

# ── C · behavioral sanity: the unconditional beat does not break a normal run ─
# A small HEARTBEAT_INTERVAL forces the during-task beat to fire several times;
# the normal task must still proceed and close (job_heartbeat is a stub no-op,
# so this proves the unconditional beat is harmless to a healthy run).
H_init_test bc45tree-normal-run-still-closes
bd_seed T1 "normal task" "does a thing then closes"
claude_plan success
export HEARTBEAT_INTERVAL=1          # force several mid-task beats
run_runner
_expect "BC-45" "§BC-45" "behavioral: a normal task with frequent mid-task beats still proceeds and closes (unconditional beat is harmless)"
_need "T1 closed (the unconditional beat did not wedge a healthy run)" \
      test "$(bd_status T1)" = closed
_need "runner drained exit 0" test "${RUN_EXIT:-1}" -eq 0
_emit
H_cleanup
