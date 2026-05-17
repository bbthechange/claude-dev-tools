#!/bin/bash
# BC-15 (FORWARD) — every NON-success, non-exempt terminal handling releases
#   the task to `open` (never left stranded `in_progress`). (T2.2,
#   claude-tools-8nn.)
# Binds: INTERFACE.md v1 §6.1 (lease release/expiry maps the bead back to
#        --status=open; binds the strong plane onto the BC-15/09/35 SCAR).
#
# TARGET — the per-class dispatch that performs the reset-to-open is THIS
# child's owned surface in runner.sh; the untouched bc-15-release-to-open.sh
# keeps v1 regression-green. Same re-point precedent as bc-01-fresh-process.sh.
#
# SCAR (silent-when-wrong): a just-failed task left `in_progress` is
# indistinguishable from work-in-flight / a future crash orphan and silently
# vanishes from `bd ready`.
#
# NOTE — STUCK_NEEDS_HUMAN is DELIBERATELY NOT exercised here: §7.5 makes it the
# documented exemption (it ends blocked-for-human, NOT open). That surface is
# bc-13-14-retry-asymmetry-tree (§7.5) + bc-stuck-cross-tier (the cross-tier
# outcome) — not BC-15.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# For every non-success class, the failing iteration must record a `T1 open`
# transition AFTER an `in_progress`, and T1 must never END stranded in_progress.
check_release() {
  local label="$1" cite="$2"; shift 2
  H_init_test "bc15tree-$label"
  bd_seed T1 "release $label" "x"
  claude_plan "$@"
  run_runner
  local seq last
  seq="$(audit_seq T1)"
  last="$(awk -v id=T1 '$1==id{v=$2} END{print v}' "$BD_AUDIT")"
  _expect "BC-15" "$cite" "non-success ($label) ⇒ bead reset to open, not stranded in_progress (runner.sh)"
  _need "audit shows in_progress→open release"  matches "$seq" "in_progress open"
  _need "final state not stranded in_progress"  test "$last" != in_progress
  _emit
  H_cleanup
}

check_release server   "§6.1" server  success     # generic SERVER_ERROR branch
check_release unknown  "§6.1" unknown success     # generic UNKNOWN_FAILURE branch
check_release rate     "§6.1" ratelimit success   # RATE_LIMIT branch
check_release maxtok   "§6.1" maxtok_result success
check_release overflow "§6.1" overflow success
check_release tnc      "§6.1" noclose success     # TASK_NOT_CLOSED branch
