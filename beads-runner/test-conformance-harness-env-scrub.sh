#!/bin/bash
# test-conformance-harness-env-scrub.sh — top-tier regression lock for
# claude-tools-b1ya.
#
# WHAT IT PINS: the conformance harness (conformance/lib/harness.sh:H_init_test)
# must SCRUB the runner's session-identity env — BEADS_RUNNER_SESSION and
# CURRENT_TASK_ID — at the per-test boundary, so a rig's view of those vars is
# never contaminated by the ambient session the gate happens to run inside.
#
# It ALSO pins the claude-tools-hr7b coordinator-wiring scrub: H_init_test must
# unset COORDINATOR_URL + COORDINATOR_TOKEN and pin RUNNER_BACKEND=stub, so a
# '-tree' rig stays hermetic on a live-fleet box (where the daemon shell exports
# COORDINATOR_URL/TOKEN + RUNNER_BACKEND=real). Without it the runner sources the
# REAL backend, routes the §6.1 lease to the HOSTED coordinator, fails to lease
# the rig's fake bead, and every assertion goes falsely RED. The full gate scrubs
# only the COORDINATOR_* pair (run-tests.sh:380, NOT RUNNER_BACKEND) and a direct
# subset run inherits the box env wholesale — so the boundary scrub is the one
# hermetic chokepoint that covers both entry points.
#
# WHY IT EXISTS (the false-RED-from-within-a-session scar): a runner spawns each
# worker with BEADS_RUNNER_SESSION=1 + CURRENT_TASK_ID=<live in-flight bead>
# exported (runner.sh:2458/2590). When run-tests.sh runs from INSIDE such a
# worker, that env LEAKS into every harness. The originating bug (w3re) was a
# close-checklist hook test that inherited the live bead and false-RED'd its
# not-runner-session / no-task-id cases; it was fixed by unsetting both in its
# run_hook. The b1ya audit then swept every offline harness family and found the
# conformance family immune ONLY because each rig drives the runner-under-test,
# which OVERWRITES both vars before spawning its worker — a non-obvious downstream
# property. H_init_test now scrubs both at the boundary as defense-in-depth so a
# FUTURE rig that invokes a consumer (close-checklist.sh / auto-label-live-session.sh)
# DIRECTLY, without going through the runner, is protected by default. This test
# pins that scrub: a refactor that drops it turns RED here deterministically.
#
# The complementary half — that the runner still RE-SETS BEADS_RUNNER_SESSION=1
# in its spawned worker env — is pinned by conformance rig bc-2fkp; together they
# prove the scrub is safe (it cannot weaken the runner's own session signalling).
#
# Counts as ONE top-tier unit (pass == exit 0). Auto-enrolled by glob (testing.md).

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0; FAIL=0
ck() { local m="$1"; shift; if "$@"; then echo "  ok  : $m"; PASS=$((PASS+1)); else echo "  FAIL: $m"; FAIL=$((FAIL+1)); fi; }

# Reproduce the leaked-session context: export the two identity vars with a
# bogus live bead BEFORE H_init_test, exactly as a runner worker would. ALSO
# reproduce the live-fleet-box coordinator wiring (claude-tools-hr7b): the daemon
# shell exports COORDINATOR_URL/TOKEN + RUNNER_BACKEND=real, which leak into any
# rig launched from that shell.
export BEADS_RUNNER_SESSION=1
export CURRENT_TASK_ID="claude-tools-FAKE-live-bead"
export COORDINATOR_URL="https://coordinator-cf.example.invalid"
export COORDINATOR_TOKEN="fake-fleet-box-bearer-token"
export RUNNER_BACKEND=real

# Sanity: prove the contamination is really present before the boundary runs,
# else the assertions below would be vacuous.
ck "precondition: BEADS_RUNNER_SESSION leaked into env" test "${BEADS_RUNNER_SESSION:-}" = "1"
ck "precondition: CURRENT_TASK_ID leaked into env"       test "${CURRENT_TASK_ID:-}" = "claude-tools-FAKE-live-bead"
ck "precondition: COORDINATOR_URL leaked into env (fleet box)"   test -n "${COORDINATOR_URL:-}"
ck "precondition: COORDINATOR_TOKEN leaked into env (fleet box)" test -n "${COORDINATOR_TOKEN:-}"
ck "precondition: RUNNER_BACKEND=real leaked into env (fleet box)" test "${RUNNER_BACKEND:-}" = "real"

# shellcheck source=/dev/null
source "$DIR/conformance/lib/harness.sh"

H_init_test "harness-env-scrub-b1ya"

# The boundary must have removed both. With `set -u`, ${VAR:-} yields empty for
# both an unset var and one set to "".
ck "H_init_test scrubbed BEADS_RUNNER_SESSION (no ambient runner-session leak)" \
   test -z "${BEADS_RUNNER_SESSION:-}"
ck "H_init_test scrubbed CURRENT_TASK_ID (no leaked live bead)" \
   test -z "${CURRENT_TASK_ID:-}"

# claude-tools-hr7b: the boundary must also have cleared the coordinator wiring
# and pinned the in-process stub backend, so a '-tree' rig leases against the
# stub (always grants) instead of the hosted coordinator (refuses the fake bead).
ck "H_init_test scrubbed COORDINATOR_URL (no hosted-coordinator leak)" \
   test -z "${COORDINATOR_URL:-}"
ck "H_init_test scrubbed COORDINATOR_TOKEN (no hosted-bearer leak)" \
   test -z "${COORDINATOR_TOKEN:-}"
ck "H_init_test pinned RUNNER_BACKEND=stub (hermetic in-process backend)" \
   test "${RUNNER_BACKEND:-}" = "stub"

H_cleanup

echo "── test-conformance-harness-env-scrub: pass=$PASS fail=$FAIL"
[[ "$FAIL" -eq 0 ]]
