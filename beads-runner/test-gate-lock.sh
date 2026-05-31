#!/usr/bin/env bash
# beads-runner/test-gate-lock.sh — singleton gate-lock regression test
# (claude-tools-fm4r).
#
# run-tests.sh is THE offline regression gate; before this lock nothing stopped
# N copies running at once, so a worker that relaunched it could stack full
# gates that then contend for CPU, the Dolt sql-server, and the bd lock
# (observed 2026-05-30: a 4-way pile-up turned a ~few-minute gate into ~16 min).
# This pins the portable mkdir-based singleton lock the bead added.
#
# What this asserts (fm4r acceptance):
#   • happy path: a clean acquire exits 0, prints LOCK-ACQUIRED, and RELEASES
#     the lock on exit (the EXIT trap removes the lockdir).
#   • genuine concurrency: launch N copies at once → EXACTLY ONE runs; the rest
#     detect the holder and exit with the DISTINCT busy code (75, != 1=tests-
#     failed, != 2=bad-usage).
#   • a LIVE holder is reported by pid + start-time, and the refused run mutates
#     NOTHING (the holder's lockdir + owner file are untouched).
#   • a lock whose recorded pid is DEAD is reclaimed — no permanent wedge.
#   • owner file records pid= and start=.
#
# Mechanics: the lock logic is exercised through run-tests.sh itself via two
# documented test hooks (env, no production CLI surface): RUN_TESTS_GATE_LOCK_BASE
# relocates the lock dir into a per-test temp dir (hermetic — never touches the
# parent gate's real /tmp lock), and RUN_TESTS_GATE_SELFTEST makes the script
# acquire the lock then exit WITHOUT running any tier (so this test is fast and
# decoupled from every other tier's health). `hold:<secs>` keeps the lock held.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
RUNNER="$SCRIPT_DIR/run-tests.sh"
[[ -f "$RUNNER" ]] || { echo "test-gate-lock.sh: reject — $RUNNER not found" >&2; exit 2; }

FAILED=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; FAILED=1; }

WORK="$(mktemp -d 2>/dev/null)" || { echo "mktemp failed"; exit 70; }
# Reap any stray SELFTEST holders we spawned, then drop the temp tree.
cleanup() {
  [[ -n "${HOLDER_PID:-}" ]] && kill "$HOLDER_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# run-tests.sh keys its lock by a cksum of its own dir (BR_DIR == SCRIPT_DIR), so
# we can predict the exact lockdir path under any chosen base — same recipe the
# script uses, kept in lock-step here on purpose (if the script's recipe changes,
# this test goes red, which is the intended anti-drift signal).
lockdir_for() { printf '%s/run-tests-gate-%s.lock' "$1" "$(printf '%s' "$SCRIPT_DIR" | cksum | tr ' ' '_')"; }

# spawn a SELFTEST run; echoes its rc. $1=base $2=selftest-value $3=outfile
run_selftest() {
  RUN_TESTS_GATE_LOCK_BASE="$1" RUN_TESTS_GATE_SELFTEST="$2" bash "$RUNNER" >"$3" 2>&1
}

# ── (1) happy path: clean acquire → exit 0, LOCK-ACQUIRED, releases ──────────
echo "── happy path: clean acquire"
B1="$WORK/b1"; mkdir -p "$B1"; LD1="$(lockdir_for "$B1")"
run_selftest "$B1" try "$B1/out"; rc=$?
[[ $rc -eq 0 ]] && pass "clean acquire exits 0" || fail "clean acquire: expected 0, got $rc"
grep -q 'LOCK-ACQUIRED' "$B1/out" && pass "prints LOCK-ACQUIRED" || fail "no LOCK-ACQUIRED: $(cat "$B1/out")"
[[ -d "$LD1" ]] && fail "lock NOT released after exit (wedge risk)" || pass "lock released on exit"

# ── (2) owner file records pid + start ───────────────────────────────────────
echo "── owner file format"
B2="$WORK/b2"; mkdir -p "$B2"; LD2="$(lockdir_for "$B2")"
RUN_TESTS_GATE_LOCK_BASE="$B2" RUN_TESTS_GATE_SELFTEST=hold:6 bash "$RUNNER" >"$B2/holder.out" 2>&1 &
HOLDER_PID=$!
for _i in $(seq 1 40); do [[ -s "$LD2/owner" ]] && grep -q LOCK-ACQUIRED "$B2/holder.out" 2>/dev/null && break; sleep 0.2; done
if [[ -s "$LD2/owner" ]]; then
  owner="$(cat "$LD2/owner")"
  case "$owner" in *pid=*) pass "owner file has pid=" ;; *) fail "owner missing pid=: [$owner]" ;; esac
  case "$owner" in *start=*) pass "owner file has start=" ;; *) fail "owner missing start=: [$owner]" ;; esac
  opid="$(sed -n 's/^pid=//p' "$LD2/owner" | head -1)"
  [[ "$opid" == "$HOLDER_PID" ]] && pass "owner pid == holder pid ($HOLDER_PID)" || fail "owner pid '$opid' != holder '$HOLDER_PID'"
else
  fail "holder never wrote owner file"
fi

# ── (3) LIVE holder → refuse with 75, report pid/start, mutate NOTHING ───────
echo "── live holder: refuse-and-report, mutates nothing"
before_owner="$(cat "$LD2/owner" 2>/dev/null)"
before_entries="$(ls -1 "$B2" | sort)"
# NB: capture the refused run's output OUTSIDE the lock base, so the
# "mutated nothing" check below sees only what the script itself touched.
run_selftest "$B2" try "$WORK/second.out"; rc=$?
msg="$(cat "$WORK/second.out")"
[[ $rc -eq 75 ]] && pass "second invocation exits 75 (distinct busy code)" || fail "expected 75, got $rc"
[[ $rc -ne 1 && $rc -ne 2 ]] && pass "busy code is distinct from 1 (fail) and 2 (usage)" || fail "busy code collides with $rc"
case "$msg" in *"gate already running"*) pass "reports 'gate already running'" ;; *) fail "no holder report: [$msg]" ;; esac
case "$msg" in *"pid $HOLDER_PID"*) pass "names the holder pid ($HOLDER_PID)" ;; *) fail "missing holder pid: [$msg]" ;; esac
case "$msg" in *"started "*) pass "names the holder start-time" ;; *) fail "missing start-time: [$msg]" ;; esac
case "$msg" in *LOCK-ACQUIRED*) fail "refused run wrongly acquired the lock" ;; *) pass "refused run did NOT acquire" ;; esac
after_owner="$(cat "$LD2/owner" 2>/dev/null)"
after_entries="$(ls -1 "$B2" | sort)"
[[ "$before_owner" == "$after_owner" ]] && pass "holder owner file untouched (mutated nothing)" || fail "owner changed under refusal"
[[ "$before_entries" == "$after_entries" ]] && pass "no stray files created on refusal" || fail "refusal created files: [$after_entries]"
kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null; HOLDER_PID=""

# ── (4) genuine concurrency: N at once → exactly one runs, rest get 75 ───────
echo "── concurrency: N simultaneous gates, exactly one wins"
B4="$WORK/b4"; mkdir -p "$B4"
N=4
for n in $(seq 1 $N); do
  ( RUN_TESTS_GATE_LOCK_BASE="$B4" RUN_TESTS_GATE_SELFTEST=hold:3 bash "$RUNNER" >"$B4/out.$n" 2>&1; echo $? >"$B4/rc.$n" ) &
done
wait
zeros=0; busy=0; other=0
for n in $(seq 1 $N); do
  c="$(cat "$B4/rc.$n" 2>/dev/null)"
  case "$c" in 0) zeros=$((zeros+1)) ;; 75) busy=$((busy+1)) ;; *) other=$((other+1)) ;; esac
done
[[ $zeros -eq 1 ]] && pass "exactly one of $N invocations acquired (won)" || fail "expected 1 winner, got $zeros (busy=$busy other=$other)"
[[ $busy -eq $((N-1)) ]] && pass "the other $((N-1)) exited 75 (busy)" || fail "expected $((N-1)) busy, got $busy (winners=$zeros other=$other)"
[[ $other -eq 0 ]] && pass "no invocation hit an unexpected exit code" || fail "$other invocation(s) had an unexpected code"

# ── (5) dead-pid lock → reclaimed (no permanent wedge) ───────────────────────
echo "── stale lock: dead pid is reclaimed"
B5="$WORK/b5"; mkdir -p "$B5"; LD5="$(lockdir_for "$B5")"
( : ) & DEADPID=$!; wait "$DEADPID" 2>/dev/null     # spawn-and-reap → DEADPID is gone
# guard against the (vanishingly unlikely) instant PID reuse
if kill -0 "$DEADPID" 2>/dev/null; then
  fail "could not obtain a dead pid for the reclaim test (pid $DEADPID still live)"
else
  mkdir -p "$LD5"; printf 'pid=%s\nstart=%s\n' "$DEADPID" "the before times" >"$LD5/owner"
  run_selftest "$B5" try "$B5/out"; rc=$?
  [[ $rc -eq 0 ]] && pass "stale (dead-pid) lock reclaimed → acquire succeeds (exit 0)" || fail "dead-pid lock not reclaimed: rc=$rc out=[$(cat "$B5/out")]"
  grep -q LOCK-ACQUIRED "$B5/out" && pass "reclaim path prints LOCK-ACQUIRED" || fail "reclaim: no LOCK-ACQUIRED"
  [[ -d "$LD5" ]] && fail "reclaimed lock left behind after run" || pass "reclaimed lock released on exit (no wedge)"
fi

# ── done ─────────────────────────────────────────────────────────────────────
if [[ $FAILED -eq 0 ]]; then
  echo ""
  echo "test-gate-lock.sh: ALL PASS"
  exit 0
else
  echo ""
  echo "test-gate-lock.sh: FAILURES (see FAIL lines above)" >&2
  exit 1
fi
