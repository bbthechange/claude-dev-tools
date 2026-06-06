#!/bin/bash
# BC-49 + BC-50 — per-pickup capacity gate + desired-state resolver
#                 (v2 -tree coverage-hardening, claude-tools-v2cut.5).
#
# Binds BEHAVIORAL-CONTRACT.md BC-49 (per-pickup ask-capacity gate: deny ⇒
# release lease + backoff + continue; unreachable ⇒ local fallback ⇒ proceed)
# and BC-50 (workspace desired-state resolver: LOCAL-FIRST read, FAIL-CLOSED to
# hold, `stopped` ends the runner — claude-tools-y6j9). In v2 the moving parts are:
#   • job_ask_capacity (runner.sh:364) → la_capacity_check  — the per-pickup gate
#   • job_reconcile_desired (runner.sh:366) → co_deliver_desired_state — desired
# Under RUNNER_BACKEND=stub la_capacity_check ALWAYS returns `ok` (fail-open
# proceed) and co_deliver_desired_state ALWAYS echoes "running" (proceed). So
# the BEHAVIORAL half here is: a task is picked up and CLOSES (capacity ok +
# desired running ⇒ proceed). The non-`running` deny/stop paths cannot be
# stub-driven black-box (the stub never emits over/stopped), so those are
# asserted SOURCE-STRUCTURALLY against runner.sh — explicitly legitimate under
# the stub backend. A `.stop-beads` behavioral stop IS cleanly observable, so it
# is also driven end-to-end.
#
# SCAR (silent-when-wrong): a capacity DENY that strands the bead `in_progress`
# (no lease release) reintroduces the BC-04 double-claim race. For desired-state
# the scar INVERTED (claude-tools-dky8/y6j9): the OLD posture fail-OPENed to
# `running` on any failure, so one unreachable/garbled read BROKE THROUGH a pause
# and claimed work (the break-through-pause bug). The runner is now LOCAL-FIRST —
# co_deliver_desired_state reads `.co-store/runner_state.desired` first — and the
# resolver FAILS CLOSED to `paused` (hold + re-reconcile), never to `running`. A
# present local paused/stopped survives a Coordinator-unreachable window.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"   # repoint to v2
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# ── BC-49/50 A · behavioral: capacity ok + desired running ⇒ pickup + close ──
H_init_test bc4950tree-proceed
bd_seed T1 "normal task" "do a thing"
claude_plan success
run_runner
o="$(out)"
_expect "BC-49" "§6.3" "per-pickup capacity gate fail-open-proceeds (stub ⇒ ok) AND desired-state resolves running (stub ⇒ running) ⇒ task picked up and closed"
_need "task picked up and closed"                     test "$(bd_status T1)" = closed
_need "clean exit 0"                                  test "$RUN_EXIT" -eq 0
_need "NO capacity-deny hold line (stub verdict is ok)" notcontains "$o" "capacity verdict=over"
_need "NO desired=stopped line (stub desired is running)" notcontains "$o" "desired=stopped"
_emit
H_cleanup

# ── BC-50 B · behavioral: .stop-beads observed ⇒ runner ends cleanly ─────────
# The desired-state poll's sibling control is the STOP_FILE (.stop-beads), which
# st_reconcile checks at the top of every reconcile (runner.sh:1778). The runner
# clears it once at startup (clean-slate rm, runner.sh:1449 — stop is consumed,
# not sticky), so the file must appear AFTER startup to be observed. We unset
# RUNNER_EXIT_ON_DRAIN so an empty queue IDLE-loops (UX §0.A) instead of draining
# to exit, then a background planter writes .stop-beads after startup; the next
# reconcile OBSERVES it and ends the runner via STOPPING (BC-21 exit 0). This is
# the cleanly-observable behavioral stop — the local twin of desired=stopped.
H_init_test bc4950tree-stopfile-ends
unset RUNNER_EXIT_ON_DRAIN          # idle-loop so a post-startup stop is observed
( sleep 3; : > "$WORKDIR/.stop-beads" ) &   # plant AFTER the startup clean-slate rm
STOP_PLANTER=$!
RUN_TIMEOUT=30 run_runner
wait "$STOP_PLANTER" 2>/dev/null || true
export RUNNER_EXIT_ON_DRAIN=1        # restore harness default for any later block
o="$(out)"
_expect "BC-50" "§2.5" ".stop-beads planted post-startup is OBSERVED at the reconcile point and ends the runner cleanly (exit 0) — the local twin of desired=stopped"
_need "stop file observed line printed"               contains "$o" "stop file (.stop-beads) observed"
_need "graceful stop consumed (BC-21 exit 0)"         contains "$o" "graceful stop consumed (BC-21 exit 0)"
_need "clean exit 0"                                  test "$RUN_EXIT" -eq 0
_emit
H_cleanup

# ── BC-49/50 C · SOURCE: capacity-deny clean path + desired-state resolver ───
# The deny/stop branches are unreachable under the stub (always ok/running), so
# the load-bearing posture is asserted source-structurally against runner.sh.
H_init_test bc4950tree-source-posture
_expect "BC-49" "§6.3" "capacity DENY releases lease + sleeps + continues (bead stays open); desired=stopped is OBSERVED in the control loop and ends the runner; the resolver reads LOCAL-FIRST and fails CLOSED to hold (claude-tools-y6j9)"
# BC-49 — capacity deny path is clean (release + backoff + continue)
_need "deny path releases the held lease"             grep -qE 'job_release_lease "\$CANDIDATE_ID" "\$LEASE_GENERATION"' "$RUNNER"
_need "deny path backs off (sleep) before continuing" \
      bash -c 'grep -A8 "if ! job_ask_capacity standard; then" "$1" | grep -qE "^[[:space:]]*sleep "' _ "$RUNNER"
_need "deny path continues — bead NOT claimed (transition RECONCILE; return)" \
      bash -c 'grep -A8 "if ! job_ask_capacity standard; then" "$1" | grep -qE "transition RECONCILE; return"' _ "$RUNNER"
_need "deny line clears LEASE_GENERATION (no stale fencing token carried)" \
      bash -c 'grep -A8 "if ! job_ask_capacity standard; then" "$1" | grep -qE "LEASE_GENERATION=\"\""' _ "$RUNNER"
# BC-50 — desired=stopped honored in the DURING-task control loop (§2.5)
_need "control loop OBSERVES desired==stopped (or STOP_FILE) during a task" \
      grep -qE '\[\[ "\$d" == "stopped" \]\] \|\| \[\[ -f "\$STOP_FILE" \]\]' "$RUNNER"
_need "desired=stopped at reconcile ends the runner (transition STOPPING)" \
      bash -c 'grep -A2 "stopped)" "$1" | grep -qE "transition STOPPING; return"' _ "$RUNNER"
_need "stop is honored AFTER the current task (§2.5 no mid-task kill)" \
      grep -qF 'honoring AFTER current task' "$RUNNER"
# BC-50 — LOCAL-FIRST + resolver fail-CLOSED (claude-tools-y6j9). The runner reads
# its own .co-store desired first; the safe_capture fallback is `paused` (HOLD),
# never `running`, and the unrecognized-desired `*)` case HOLDS + re-reconciles
# instead of claiming. This is the break-through-pause fix — an unreachable/garbled
# read can no longer manufacture a `running` that breaks through a local pause.
_need "co_deliver_desired_state reads the LOCAL .co-store RunnerState first (real backend adapter)" \
      grep -qE 'co__store_get runner_state' "$(dirname "$RUNNER")/lib/runner-backend-real.sh"
_need "desired-state captured via safe_capture with FAIL-CLOSED 'paused' fallback" \
      grep -qE 'safe_capture COORD_UNREACHABLE paused -- job_reconcile_desired' "$RUNNER"
_need "unrecognized desired ⇒ FAIL-CLOSED to hold (the * case re-reconciles, does not claim)" \
      grep -qF 'fail-CLOSED to hold' "$RUNNER"
_need "the runner exports CO_STORE so the main-loop local read hits the per-workspace store" \
      grep -qE 'CO_STORE:=.*\.beads/runner-logs/\.co-store' "$RUNNER"
_emit
H_cleanup
