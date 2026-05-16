#!/bin/bash
# BC-15 — A failed task is released to `open` (never left `in_progress`).
# Binds: INTERFACE.md v1 §6.1 (lease release/expiry maps the bead back to
#        --status=open; binds the strong plane onto the BC-15/09/35 transitions).
# SCAR (silent-when-wrong): a just-failed task left `in_progress` is
#        indistinguishable from work-in-flight / a future crash orphan.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

# For every non-success class, the failing iteration must record a `T1 open`
# transition AFTER an `in_progress`, and T1 must never be the LAST transition
# while still `in_progress` (i.e. not stranded).
check_release() {
  local label="$1" cite="$2"; shift 2
  H_init_test "bc15-$label"
  bd_seed T1 "release $label" "x"
  claude_plan "$@"
  run_runner
  local seq last
  seq="$(audit_seq T1)"
  last="$(awk -v id=T1 '$1==id{v=$2} END{print v}' "$BD_AUDIT")"
  _expect "BC-15" "$cite" "non-success ($label) ⇒ bead reset to open, not stranded in_progress"
  _need "audit shows in_progress→open release"  matches "$seq" "in_progress open"
  _need "final state not stranded in_progress"  test "$last" != in_progress
  _emit
  H_cleanup
}

check_release server  "§6.1" server  success    # generic SERVER_ERROR branch
check_release unknown "§6.1" unknown success    # generic UNKNOWN_FAILURE branch
check_release rate    "§6.1" ratelimit success  # RATE_LIMIT branch
check_release maxtok  "§6.1" maxtok_result success
check_release overflow "§6.1" overflow success
check_release tnc     "§6.1" noclose success    # TASK_NOT_CLOSED branch
