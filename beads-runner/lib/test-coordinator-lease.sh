#!/bin/bash
# beads-runner/lib/test-coordinator-lease.sh — focused unit test for the
# §6.1/§6.2/§4.4 global exclusive TTL'd LEASE arbitration (T4.2, claude-tools-am8).
#
# T4.2's OWN test surface. Deliberately NOT a member of the T1 conformance
# suite (beads-runner/conformance/, owned by T1a/T1b) and it does NOT touch
# T4.1's test-coordinator.sh, T4.3's test-coordinator-reconcile.sh, T4.4's
# test-coordinator-capacity.sh, nor T4.5's test-coordinator-forensic.sh —
# anti-drift: each tier its own focused test. It exercises ONLY the
# §6.1/§6.2/§4.4 lease-arbitration surface on coordinator.sh.
#
# Asserts the EXIT CRITERIA T4.2 owns against INTERFACE.md v1 §6.1/§6.2/§4.4:
#   1. BC-04 RACE: N runners concurrently claiming one task_ref ⇒ EXACTLY ONE
#      acquires the lease, every other is DENIED; a renew/release carrying a
#      STALE `generation` is REJECTED (the §4.4 fencing token — the BC-04
#      two-runners-one-orphan RESIDUAL close, BEHAVIORAL-CONTRACT §18).
#   2. §6.1 binding & precedence: acquire yields a §4.4 record (task_ref,
#      owner, monotonic generation, ttl_seconds=LEASE_TTL, expires_at,
#      schema_version=1, §9.1 principal STAMPED); the lease is consulted on
#      EVERY pickup (a 2nd different owner is denied while held); release
#      relinquishes exclusivity (record gone ⇒ free) — binds release⇒open.
#   3. ORPHAN RECOVERY = an EXPIRED lease: a crashed owner's expired lease is
#      re-acquirable by a new owner; the zombie's stale-generation renew/
#      release is then REJECTED (replaces the bash startup-snapshot;
#      SCAFFOLDING mechanism gone, BC-04-close intent kept).
#   4. §6.2 AD2.2 LEASE half: co_lease_acquire unreachable ⇒ DEGRADED-CLOSED
#      (deny, NO write) — the exact MIRROR of co_ask_capacity's shape but the
#      OPPOSITE posture (capacity fails OPEN). Both halves frozen.
#   5. (Full T1 conformance stays PASS/zero-FAIL — the conformance SUITE's
#      job, run as the quality gate; this change touches coordinator.sh +
#      this new file + the runner §6.1 wiring only.)
#
# Anti-drift proven by STRUCTURE (a source grep is defeated by this file's own
# correct anti-drift prose — the lesson the sibling T4 tests call out):
#   • T4.1's co__poll stays the pure liveness-free TRANSPORT that merely
#     SURFACES a stored lease — it arbitrates/fences NOTHING (asserted: a
#     poll over an EXPIRED stored lease still returns it verbatim; only
#     acquire does orphan recovery); co_capabilities stays EXACTLY four §2
#     lines (lease-* is NOT a fifth §2 capability);
#   • §9.1 — no/invalid token ⇒ lease-acquire rejected BEFORE any write
#     (reuses the ONE chokepoint; no second auth path);
#   • the §6.2 BOUNDED LOCAL FALLBACK is the Local Agent's (T3) — NOT here:
#     co_lease_acquire unreachable simply DENIES, it never consults a cache.
#
# Self-contained: its own CO_STORE under mktemp; its own env vocabulary,
# sharing NO state with the T1 conformance harness or the sibling T4 tests.
set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/coordinator.sh"
[[ -f "$LIB" ]] || { echo "FATAL: coordinator.sh not found at $LIB"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
ck()  { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
eq()  { [[ "$1" == "$2" ]]; }
ne()  { [[ "$1" != "$2" ]]; }
has() { grep -qF -- "$2" <<<"$1"; }
hasnt(){ ! grep -qF -- "$2" <<<"$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CO_STORE="$WORK/store"
unset CO_EXPECTED_TOKEN PRINCIPAL_V1 2>/dev/null || true
unset LEASE_TTL 2>/dev/null || true

# shellcheck source=/dev/null
source "$LIB"

GOOD="bearer-runner-secret-xyz"
LREC() { co_request "$GOOD" get lease "$1" 2>/dev/null; }   # raw stored §4.4 record
q()    { "$@" >/dev/null 2>&1; }                            # run quietly (discard the echoed record)

echo "── EXIT-1: BC-04 RACE — N concurrent claims ⇒ EXACTLY ONE winner ──"
RD="$WORK/race"; mkdir -p "$RD"
for o in ownerA ownerB ownerC ownerD ownerE; do
  ( rec="$(co_request "$GOOD" lease-acquire raceT "$o" 2>/dev/null)"; rc=$?
    printf '%s|%s|%s\n' "$rc" "$o" "$(printf '%s' "$rec" | jq -r '.owner // "-"' 2>/dev/null)" \
      > "$RD/$o" ) &
done
wait
granted=0; denied=0; winner=""
for f in "$RD"/*; do
  IFS='|' read -r rc o ow < "$f"
  if [[ "$rc" == "0" ]]; then granted=$((granted+1)); winner="$ow"; else denied=$((denied+1)); fi
done
ck "exactly ONE concurrent claimant acquired the lease (BC-04)"  eq "$granted" "1"
ck "every other concurrent claimant was DENIED (4 of 5)"         eq "$denied"  "4"
ck "the stored lease owner is the sole winner"                   eq "$(LREC raceT | jq -r .owner)" "$winner"
ck "winner's record carries generation 1 (first grant)"          eq "$(LREC raceT | jq -r .generation)" "1"

echo "── EXIT-1: §4.4 GENERATION fencing — stale generation REJECTED ──"
co_request "$GOOD" lease-acquire fenceT runnerA >/dev/null 2>&1
g1="$(LREC fenceT | jq -r .generation)"
ck "first acquire ⇒ generation 1"                       eq "$g1" "1"
# SAME owner re-acquires its still-valid lease ⇒ generation STRICTLY bumps
# (isolates the fencing TOKEN from the owner string).
co_request "$GOOD" lease-acquire fenceT runnerA >/dev/null 2>&1
g2="$(LREC fenceT | jq -r .generation)"
ck "same-owner re-acquire ⇒ generation strictly monotonic (1→2)"  eq "$g2" "2"
# A renew/release carrying the STALE gen1 is REJECTED even though the owner
# matches — proving `generation`, not just owner, is the fence (§4.4).
co_request "$GOOD" lease-renew fenceT runnerA 1 >/dev/null 2>&1
ck "renew with STALE generation 1 ⇒ REJECTED (owner matches)"  bash -c '! co_request "'"$GOOD"'" lease-renew fenceT runnerA 1 >/dev/null 2>&1'
ck "release with STALE generation 1 ⇒ REJECTED"                bash -c '! co_request "'"$GOOD"'" lease-release fenceT runnerA 1 >/dev/null 2>&1'
ck "lease still HELD after the stale renew/release (not destroyed)" test -n "$(LREC fenceT)"
ck "renew with CURRENT generation 2 ⇒ accepted"                q co_request "$GOOD" lease-renew fenceT runnerA 2
ck "release with CURRENT generation 2 ⇒ accepted"              q co_request "$GOOD" lease-release fenceT runnerA 2
ck "release ⇒ exclusivity relinquished (record gone — binds ⇒open)" test -z "$(LREC fenceT)"

echo "── EXIT-2: §6.1 binding, the §4.4 record shape & precedence ──"
arec="$(co_request "$GOOD" lease-acquire bindT runner7 2>/dev/null)"
ck "acquire returns the §4.4 record"                eq "$(jq -r .task_ref <<<"$arec")" "bindT"
ck "owner captured"                                 eq "$(jq -r .owner    <<<"$arec")" "runner7"
ck "schema_version is integer 1 (§4.4)"             eq "$(jq -r '.schema_version' <<<"$arec")" "1"
ck "ttl_seconds == LEASE_TTL default (900, §0.5)"   eq "$(jq -r .ttl_seconds <<<"$arec")" "900"
ck "expires_at present (RFC-3339 …Z, §0.4)"         bash -c 'grep -qE "Z$" <<<"$(jq -r .expires_at <<<'"'"$arec"'"')"'
ck "§9.1 principal STAMPED (brian), not a literal"  eq "$(jq -r .principal <<<"$arec")" "brian"
# The lease is consulted on EVERY pickup: a 2nd DIFFERENT owner is denied
# while it is held (lease authoritative for EXCLUSIVITY — precedence).
ck "2nd different owner DENIED while held (every-pickup consult)" bash -c '! co_request "'"$GOOD"'" lease-acquire bindT runner9 >/dev/null 2>&1'
ck "the holder is unchanged after the denied claim"  eq "$(LREC bindT | jq -r .owner)" "runner7"
# Idempotent + correctness edges.
ck "release of an ABSENT lease ⇒ idempotent success"  q co_request "$GOOD" lease-release neverT runnerX 1
ck "renew with NO lease ⇒ REJECTED"                   bash -c '! co_request "'"$GOOD"'" lease-renew neverT runnerX 1 >/dev/null 2>&1'
ck "release by a NON-owner ⇒ REJECTED"                bash -c '! co_request "'"$GOOD"'" lease-release bindT intruder 1 >/dev/null 2>&1'

echo "── EXIT-3: ORPHAN RECOVERY = an EXPIRED lease (no bash snapshot) ──"
( export LEASE_TTL=1
  source "$LIB"
  co_request "$GOOD" lease-acquire orphanT crashedRunner >/dev/null 2>&1 )
go="$(LREC orphanT | jq -r .generation)"
ck "crashed owner holds the lease (gen $go)"          eq "$go" "1"
sleep 2     # the lease (TTL=1s) is now EXPIRED — orphan recovery is due
# A NEW owner may take an EXPIRED lease (orphan recovery); generation is
# STRICTLY monotonic across the takeover (the record persisted, gen bumps).
nrec="$(co_request "$GOOD" lease-acquire orphanT freshRunner 2>/dev/null)"
ck "expired lease re-acquired by a NEW owner (orphan recovery)" eq "$(jq -r .owner <<<"$nrec")" "freshRunner"
ck "generation strictly monotonic across takeover (1→2)"        eq "$(jq -r .generation <<<"$nrec")" "2"
# THE residual close: the zombie crashedRunner (still thinks it holds gen1)
# can renew/release NOTHING — the new owner's lease is fenced.
ck "zombie's stale-generation renew ⇒ REJECTED (BC-04 residual close)"  bash -c '! co_request "'"$GOOD"'" lease-renew orphanT crashedRunner 1 >/dev/null 2>&1'
ck "zombie's stale-generation release ⇒ REJECTED"                      bash -c '! co_request "'"$GOOD"'" lease-release orphanT crashedRunner 1 >/dev/null 2>&1'
ck "the new owner's lease survives the zombie (still freshRunner)"      eq "$(LREC orphanT | jq -r .owner)" "freshRunner"

echo "── EXIT-4: §6.2 AD2.2 LEASE half — DEGRADED-CLOSED (mirror of capacity) ──"
out_un="$(co_lease_acquire "$GOOD" unreachT runnerU unreachable 2>&1)"; rc_un=$?
ck "co_lease_acquire unreachable ⇒ nonzero (DEGRADED-CLOSED)"  ne "$rc_un" "0"
ck "unreachable denial is observable (denied-unreachable)"    has "$out_un" "denied-unreachable"
ck "unreachable ⇒ NO lease record was written (no new claim)" test -z "$(LREC unreachT)"
ck "reachable ⇒ arbitrated through the front door (granted)"  q co_lease_acquire "$GOOD" reachT runnerR reachable
ck "reachable grant persisted"                                eq "$(LREC reachT | jq -r .owner)" "runnerR"
# Same SHAPE, OPPOSITE posture: the CAPACITY half fails OPEN where the LEASE
# half fails CLOSED — §6.2 freezes BOTH so neither is left to implementation.
cap_un="$(co_ask_capacity "$GOOD" standard unreachable 2>/dev/null)"; cap_rc=$?
ck "co_ask_capacity unreachable ⇒ ok (capacity fails OPEN — contrast)" eq "$cap_un" "ok"
ck "capacity-half rc 0 vs lease-half rc≠0 (deliberately opposite)"      bash -c "[[ $cap_rc -eq 0 && $rc_un -ne 0 ]]"

echo "── §9.1 chokepoint + store-owner input hygiene + anti-drift ──"
co_request "" lease-acquire authT runnerZ >/dev/null 2>&1 || true
ck "no-token lease-acquire ⇒ REJECTED (§9.1)"           bash -c '! co_request "" lease-acquire authT runnerZ >/dev/null 2>&1'
ck "no-token lease-acquire ⇒ ZERO lease written (before-any-write)" test -z "$(LREC authT)"
CO_EXPECTED_TOKEN=expected co_request bad lease-acquire authT2 runnerZ >/dev/null 2>&1 || true
ck "invalid-token lease-acquire ⇒ still ZERO lease written" test -z "$(LREC authT2)"
ck "unsafe task_ref ('../evil') ⇒ rejected at the door"  bash -c '! co_request "'"$GOOD"'" lease-acquire "../evil" o >/dev/null 2>&1'
ck "unsafe task_ref ('..') ⇒ rejected at the door"       bash -c '! co_request "'"$GOOD"'" lease-acquire ".." o >/dev/null 2>&1'
ck "no stray lease file escaped the records dir"         bash -c '! test -e "'"$CO_STORE"'/records/evil"'
# T4.1 co_capabilities UNTOUCHED — lease-* is NOT a fifth §2 capability.
caps="$(co_capabilities 2>/dev/null)"
ncaps="$(grep -c '§2' <<<"$caps" || true)"
ck "co_capabilities (T4.1) still EXACTLY four §2 lines"   eq "$ncaps" "4"
ck "lease-* is NOT advertised as a §2 capability"         hasnt "$caps" "lease-acquire"
# 'lease' IS a §4 record type (T4.1 registry) — arbitration did not redefine it.
ck "'lease' is a §4 record type, schema_version 1 (registry intact)" \
   eq "$(co__schema_version lease)" "1"
# Anti-drift: co__poll stays pure liveness-free TRANSPORT — it SURFACES a
# stored lease verbatim and arbitrates/fences NOTHING (even an EXPIRED one).
( export LEASE_TTL=1; source "$LIB"
  co_request "$GOOD" lease-acquire pollT pollOwner >/dev/null 2>&1 )
sleep 2   # pollT's lease is now EXPIRED — transport must NOT expire/fence it
pj="$(co_request "$GOOD" poll pollT pollT 2>/dev/null)"
ck "co__poll SURFACES the stored lease verbatim (transport)"  eq "$(jq -r .lease.owner <<<"$pj")" "pollOwner"
ck "co__poll did NOT expire/orphan-recover it (no arbitration)" eq "$(jq -r '.lease.generation' <<<"$pj")" "1"
ck "co__poll output carries NO 'liveness' (T4.3 boundary intact)" \
   bash -c "[[ \"\$(jq -r 'has(\"liveness\")' <<<'$pj')\" == false ]]"

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " test-coordinator-lease (T4.2, claude-tools-am8):  PASS=$PASS  FAIL=$FAIL"
echo "══════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
