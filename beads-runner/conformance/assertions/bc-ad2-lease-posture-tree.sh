#!/bin/bash
# BC-48 / AD2.1 / AD2.2 — §6.1 lease ↔ beads-status binding is PRESENT in v2
# (v2 -tree coverage-hardening, claude-tools-v2cut.5).
#
# Proves: v2 runner.sh HAS the lease seam the plain bc-ad2-lease-posture.sh
# (v1) can only GATE-PENDING. v1 has NO lease/Coordinator concept, so every
# assertion there is correctly forward. v2 binds the six jobs to a swappable
# backend: job_claim_lease→co_lease_acquire (coordinator-stub GRANTS, echoes a
# §4.4 generation), paired by job_release_lease→co_lease_release at task end /
# interrupt / failure-reset. Under RUNNER_BACKEND=stub the grant is
# unconditional, so the BEHAVIORAL half is: a seeded task claims, runs, and
# closes BECAUSE the stub-granted lease let it proceed past st_claim's
# "no lease ⇒ no run" gate (runner.sh:1971-1975). The ORDERING + RELEASE-PAIRING
# halves are SOURCE-STRUCTURAL (the stub lease ops are no-op-observable, so the
# acquire-before-in_progress order and the three release sites are asserted
# against runner.sh's text — explicitly legitimate here, see assignment notes).
# AD2.2's degraded-CLOSED bounded-fallback (la_lease_fallback_allows) is NOT
# wired into runner.sh yet (the stub always grants ⇒ the deny branch is never
# exercised black-box), so that check stays a _gate: GATE-MET for what the stub
# proves, GATE-PENDING for the runner-side consultation that is still forward.
#
# Binds: BEHAVIORAL-CONTRACT.md BC-48 (§6.1 acquire-before-in_progress;
# release⇒open); the AD2.1 ordering + AD2.2 split-posture invariants.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"   # repoint to v2
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STUB="$REPO/lib/local-agent-stub.sh"
COORD="$REPO/lib/coordinator-stub.sh"

# st_claim_body — st_claim's text, from `st_claim() {` to its first top-level
# `}` (the function close). Lets the §6.1 ordering be checked WITHIN the claim
# function alone, so an in_progress write elsewhere can never satisfy it.
st_claim_body() {
  awk '/^st_claim\(\) \{/{f=1} f{print} /^\}/{if(f) exit}' "$RUNNER"
}
# line_no <regex> <text...> — 1-based line number of the FIRST match in stdin.
first_line_no() { grep -nE -- "$1" | head -1 | cut -d: -f1; }

# ── AD2.1 (behavioral) — stub-granted lease lets a seeded task claim/run/close ─
# The lease is real in v2: if job_claim_lease returned nonzero/empty the runner
# prints "lease unavailable … not claiming" and RECONCILEs without ever driving
# the bead to in_progress. The stub GRANTS (echoes gen "1", rc 0), so the task
# must reach the worker and close. A close here is end-to-end proof the lease
# seam is present AND grants (v1 had no seam to grant at all).
H_init_test ad21tree-lease-grant-lets-task-run
bd_seed T1 "lease grants ⇒ task runs" "stub co_lease_acquire grants the lease"
claude_plan success
run_runner
_expect "BC-48" "§6.1" "v2 lease seam present: stub-granted lease lets a seeded task claim, run, and close"
_need "T1 closed (the granted lease let it proceed past the no-lease gate)" \
      test "$(bd_status T1)" = closed
_need "runner did NOT print the lease-unavailable deny for T1" \
      notcontains "$(out)" "lease unavailable for T1"
_need "T1 was actually driven to in_progress before closing (audit)" \
      contains "$(audit)" "T1 in_progress"
_emit
H_cleanup

# ── AD2.1 (source-structural) — ACQUIRE precedes the in_progress WRITE in st_claim
# v1's plain rig can only _gate this ("post-T4: acquire PRECEDES in_progress").
# v2 satisfies it in the source: within st_claim, the job_claim_lease call site
# is strictly above the `bd update --status=in_progress` write. We match the
# CALL site (gen="$(job_claim_lease …) — not the comment two lines above it) and
# the real write site (safe_capture … --status=in_progress), inside st_claim's
# body only.
H_init_test ad21tree-acquire-before-inprogress-order
body="$(st_claim_body)"
acq=$(printf '%s\n' "$body" | first_line_no 'gen="\$\(job_claim_lease ')
ipw=$(printf '%s\n' "$body" | first_line_no 'bd update "\$CANDIDATE_ID" --status=in_progress')
_expect "AD2.1" "§6.1" "st_claim acquires the lease (job_claim_lease) BEFORE the bd --status=in_progress write (source order)"
_need "the job_claim_lease CALL site exists in st_claim"  test -n "$acq"
_need "the --status=in_progress write exists in st_claim"  test -n "$ipw"
_need "acquire line precedes the in_progress write line"   bash -c '[[ -n "'"$acq"'" && -n "'"$ipw"'" && "'"$acq"'" -lt "'"$ipw"'" ]]'
_need "st_claim wires job_claim_lease → co_lease_acquire (§3 j1)" \
      grep -qE 'job_claim_lease\(\)[[:space:]]*\{[[:space:]]*co_lease_acquire' "$RUNNER"
_need "the no-lease gate refuses to claim when acquire fails" \
      grep -qE 'lease unavailable for .* — not claiming \(no lease ⇒ no run\)' "$RUNNER"
_emit
H_cleanup

# ── AD2.1 (source-structural) — RELEASE pairs the acquire at the three sites ───
# §6.1 "release pairs every acquire": v2 calls job_release_lease at the interrupt
# teardown net, the per-task end, and the fatal failure-reset. v1's plain rig
# gates "lease release paired"; v2 meets it structurally (the stub release is a
# no-op so it is not black-box observable — assert the call sites exist).
H_init_test ad21tree-release-pairs-acquire
rel_n=$(grep -cE 'job_release_lease ' "$RUNNER")
_expect "BC-48" "§6.1" "release (job_release_lease) pairs the acquire at task-end, interrupt, and failure-reset (source sites)"
_need "job_release_lease wired → co_lease_release (§3 j1 pairing)" \
      grep -qE 'job_release_lease\(\)[[:space:]]*\{[[:space:]]*co_lease_release' "$RUNNER"
_need "release present on the interrupt/teardown net (BC-35)" \
      grep -qE 'Interrupted — resetting .* to open' "$RUNNER"
_need "release present on the fatal failure-reset (_terminal_fatal, BC-15)" \
      bash -c 'awk "/^_terminal_fatal\(\) \{/{f=1} f{print} /^\}/{if(f) exit}" "'"$RUNNER"'" | grep -qE "job_release_lease "'
_need "release present on the per-task end (st_post_task)" \
      bash -c 'awk "/^st_post_task\(\) \{/{f=1} f{print} /^\}/{if(f) exit}" "'"$RUNNER"'" | grep -qE "job_release_lease "'
_need "at least three job_release_lease call sites (interrupt+fatal+task-end)" \
      bash -c '[[ "'"$rel_n"'" -ge 3 ]]'
_need "every release carries the §4.4 fencing generation (\$LEASE_GENERATION)" \
      bash -c 'c=$(grep -cE "job_release_lease .*LEASE_GENERATION" "'"$RUNNER"'"); [[ "$c" -ge 3 ]]'
_emit
H_cleanup

# ── AD2.2 (source-structural / stub) — degraded-CLOSED posture is DEFINED ──────
# The split posture (§6.2): capacity fails-OPEN, lease degrades-CLOSED with a
# bounded LOCAL fallback. The Local Agent stub encodes exactly that:
# la_lease_fallback_allows returns 1 (must-not-claim) when unreachable with NO
# cached lease, and 0 (may) when reachable. We assert that contract directly
# against the stub (it IS callable here) — v1 has no such function at all.
H_init_test ad22tree-degraded-closed-stub-contract
source "$STUB"
fb_unreach=0 fb_reach=0
la_lease_fallback_allows T1 unreachable >/dev/null 2>&1 || fb_unreach=$?
la_lease_fallback_allows T1 reachable   >/dev/null 2>&1 || fb_reach=$?
_expect "AD2.2" "§6.2" "Local-Agent degraded-CLOSED posture is DEFINED: unreachable+no-cache ⇒ must-not-claim; reachable ⇒ may"
_need "la_lease_fallback_allows is defined in the LA stub" \
      grep -qE '^la_lease_fallback_allows\(\)' "$STUB"
_need "unreachable + no cached lease ⇒ must-not-claim (returns 1)" \
      bash -c '[[ "'"$fb_unreach"'" -eq 1 ]]'
_need "reachable ⇒ Coordinator arbitrates, LA does not block (returns 0)" \
      bash -c '[[ "'"$fb_reach"'" -eq 0 ]]'
_need "the bounded local fallback also exposes note-held / release-local seams" \
      bash -c 'grep -qE "^la_lease_note_held\(\)" "'"$STUB"'" && grep -qE "^la_lease_release_local\(\)" "'"$STUB"'"'
_emit
H_cleanup

# ── AD2.2 (gate) — the RUNNER consulting the LA fallback on unreachable is FORWARD
# The stub coordinator ALWAYS grants (co_lease_acquire never denies), so the
# runner's "no lease ⇒ no run" branch and any la_lease_fallback_allows
# consultation are not exercisable black-box here. runner.sh does NOT yet call
# la_lease_fallback_allows (the runner-side wiring of the bounded local fallback
# is forward). Keep this as a _gate: GATE-MET for the deny-posture that DOES
# exist (the no-lease gate + LEASE_DENY_BACKOFF), GATE-PENDING for the
# unreachable-consults-LA-fallback wiring that is still forward.
H_init_test ad22tree-runner-consults-fallback-gate
_gate "AD2.2" "§6.2" "runner consults la_lease_fallback_allows on Coordinator-unreachable (degraded-CLOSED bounded fallback)"
_need "runner has a no-lease deny gate (acquire fail ⇒ no claim + backoff)" \
      grep -qE 'lease unavailable for .* — not claiming' "$RUNNER"
_need "the deny path backs off LEASE_DENY_BACKOFF before re-reconciling" \
      grep -qE 'sleep "\$\{LEASE_DENY_BACKOFF:-3\}"' "$RUNNER"
_need "FORWARD: runner.sh consults la_lease_fallback_allows when unreachable" \
      grep -qE 'la_lease_fallback_allows' "$RUNNER"
_emit
H_cleanup
