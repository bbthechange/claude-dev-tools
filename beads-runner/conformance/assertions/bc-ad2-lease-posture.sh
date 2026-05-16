#!/bin/bash
# AD2.1 / AD2.2 — lease ↔ beads-status binding & unreachable posture.
# Binds: INTERFACE.md v1 §6.1 (acquire lease BEFORE bd --status=in_progress;
#        release/expiry ⇒ status=open) and §6.2 (split posture: capacity
#        fail-OPEN; lease degraded-CLOSED with a bounded local fallback).
# GATES: T4 (hosted Coordinator: lease arbitration / unreachable posture).
#
# The current single-process script has NO lease/Coordinator concept — it never
# invokes the `lease` control-plane seam — so every assertion below is
# correctly GATE-PENDING pre-rewrite. These are the literal close-criteria T4
# must flip to GATE-MET. Ordering is checked on the SINGLE append-only $BD_AUDIT
# stream (the `lease` shim writes LEASE rows there) so "acquire precedes
# in_progress" is a true wall-order check, not a racy cross-file compare.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

# ── AD2.1: lease acquired BEFORE bd update --status=in_progress ───────────────
H_init_test ad21-lease-before-inprogress
bd_seed T1 "lease ordering" "x"
claude_plan success
run_runner
_gate "AD2.1" "§6.1" "lease acquired BEFORE --status=in_progress; release pairs it (gates T4)"
_need "post-T4: a lease acquire is observable"           contains "$(audit)" "LEASE acquire T1"
_need "post-T4: acquire PRECEDES T1 in_progress (§6.1 order)" line_before "LEASE acquire T1" "^T1 in_progress" "$BD_AUDIT"
_need "post-T4: lease release paired (binds release⇒open)" contains "$(audit)" "LEASE release T1"
_emit
H_cleanup

# ── AD2.2: Coordinator-unreachable + NO held lease ⇒ MUST NOT claim a NEW task
# This is the highest-blast-radius invariant (no new unsynchronized claim ⇒ no
# BC-04 regression). Current script ignores all of it and runs T1 anyway.
H_init_test ad22-unreachable-no-lease-no-claim
bd_seed T1 "must not be claimed" "x"
claude_plan success
export HARNESS_COORDINATOR=unreachable        # Coordinator down; no cached lease
run_runner
_gate "AD2.2" "§6.2" "lease plane degraded-CLOSED: no fresh lease ⇒ no NEW claim (gates T4)"
_need "post-T4: T1 NEVER driven to in_progress" bash -c '! grep -q "^T1 in_progress" "'"$BD_AUDIT"'" 2>/dev/null'
_need "post-T4: the unclaimed task did NOT run/close" bash -c '[[ "$(cat "'"$BD_STORE"'/T1/status" 2>/dev/null)" != closed ]]'
_need "post-T4: a NEW lease was denied while unreachable" contains "$(audit)" "LEASE acquire T1 denied-unreachable"
_emit
H_cleanup

# ── AD2.2: Coordinator-unreachable + HOLDS a still-valid lease ⇒ MAY continue
# that one task (bounded local fallback). Current script has no lease seam, so
# the mechanism (honoring the cached lease) is absent ⇒ correctly PENDING.
H_init_test ad22-unreachable-held-lease-continues
bd_seed T1 "held lease continues" "x"
lease_seed_valid T1                           # we already hold a valid lease
claude_plan success
export HARNESS_COORDINATOR=unreachable
run_runner
_gate "AD2.2" "§6.2" "bounded local fallback: continue ONLY a task whose valid lease we hold (gates T4)"
_need "post-T4: cached lease honored (continued via seam)" contains "$(audit)" "LEASE acquire T1 ok-cached"
_need "post-T4: the held task was allowed to complete"     test "$(bd_status T1)" = closed
_emit
H_cleanup
