#!/bin/bash
# beads-runner/daemon/test-timer-due-poll.sh — N10-11 (claude-tools-buoz)
# §2.2 timer DAEMON CLOCK conformance (DESIGN N §2.2/§4.3, INTERFACE S-6).
#
# WHAT THIS PROVES (offline — no real engine, no network):
#   PART 0 — file parses + defines the public API + carries the DESIGN N banner.
#   PART A — daemon_timer_due_poll_once rings co_request with the EXACT op:
#            `co_request <bearer> timed-fyi-poll` — the COMPOSITE driver that
#            FIRES due timers (timed-fyi auto-proceed + ready-to-pair surface),
#            NOT the bare `timer-due` op (which only LISTS ids), and with NO
#            `now` arg (the engine owns the comparison clock). Via a fake
#            co-http-transport.sh injected on DAEMON_REPO_LIB_DIR.
#   PART B — DAEMON_TIMER_DUE_DISABLED=1 is a hard kill switch (no call).
#   PART C — no workspace registered ⇒ graceful skip (returns 0, no call).
#   PART D — the poll is actually WIRED into daemon.sh's main loop (sourced +
#            cadence-gated + boot-fire arm) — i.e. the audit gap wzejgmopj
#            ("engine live but nothing rings it") is really closed.
#
# The actual fire logic (timer-due query, kind-routing, §7.4 latch auto-proceed,
# pair-surface) is the ENGINE's (cf/test/timer.spec.js / cf/src/timer.js pins
# fireDueTimers; lib/test-timed-fyi.sh is the bash differential ORACLE). This
# test only proves the daemon CLOCK rings the right driver op on the right beat.
#
# Run: bash beads-runner/daemon/test-timer-due-poll.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/timer-due-poll.sh"
DAEMON_SH="$HERE/daemon.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " N10-11 §2.2 timer daemon clock — claude-tools-buoz"
echo "════════════════════════════════════════════════════════════════════"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A fake co-http-transport.sh that records every co_request invocation instead
# of hitting the network — injected via DAEMON_REPO_LIB_DIR.
FAKELIB="$WORK/lib"
mkdir -p "$FAKELIB"
cat > "$FAKELIB/co-http-transport.sh" <<'EOF'
co_request() { printf 'CALL %s\n' "$*" >> "$CAPTURE"; printf '{"ok":true,"fired":[],"warned":false}'; }
EOF

# ── PART 0 ──────────────────────────────────────────────────────────────────
echo ""
echo "── PART 0 — file parses + defines the API ──"
[[ -f "$LIB" ]] && ok "timer-due-poll.sh present" || bad "lib missing"
bash -n "$LIB" 2>/dev/null && ok "lib parses (bash -n clean)" || bad "lib syntax error"
( . "$LIB" 2>/dev/null
  declare -F daemon_timer_due_poll_once >/dev/null 2>&1 ) \
  && ok "defines daemon_timer_due_poll_once" || bad "missing daemon_timer_due_poll_once"
grep -q "DESIGN N" "$LIB" && ok "carries the DESIGN N provenance banner" || bad "DESIGN N banner missing"

# helper: run the poll with a registry + the fake transport, capturing the
# co_request calls. Echoes the capture file content.
run_with_fake() {
  local cap="$WORK/cap.$$.$RANDOM"
  (
    set +u
    export DAEMON_REPO_LIB_DIR="$FAKELIB"
    export COORDINATOR_TOKEN="testbearer"
    export CAPTURE="$cap"
    REGISTRY_PROJECT_REFS=("thirsty")
    REGISTRY_COORDINATOR_URLS=("https://fake.example")
    REGISTRY_TOKEN_KEYCHAIN_ITEMS=("")
    # shellcheck source=/dev/null
    . "$LIB"
    daemon_timer_due_poll_once >/dev/null 2>&1
  )
  [[ -f "$cap" ]] && cat "$cap" || true
}

# ── PART A — rings the COMPOSITE firing op (timed-fyi-poll), no `now` arg ─────
echo ""
echo "── PART A — rings co_request timed-fyi-poll (the firing driver) ──"
OUT="$(run_with_fake)"
printf '%s' "$OUT" | grep -q "CALL testbearer timed-fyi-poll" \
  && ok "poll ⇒ co_request testbearer timed-fyi-poll" \
  || bad "poll did not ring 'timed-fyi-poll' (got: $OUT)"
# It must be the COMPOSITE op that FIRES, never the bare `timer-due` that only
# LISTS due ids (the design's one critical correctness distinction).
printf '%s' "$OUT" | grep -q "CALL testbearer timer-due\b" \
  && bad "poll rang the bare 'timer-due' (only LISTS; does not fire) — must ring 'timed-fyi-poll'" \
  || ok "does NOT ring the bare 'timer-due' (that op only lists, never fires)"
# No `now` arg — the engine owns the comparison clock (opTimerDue defaults it).
printf '%s' "$OUT" | grep -qx "CALL testbearer timed-fyi-poll" \
  && ok "passes NO 'now' arg (engine owns the clock — no Mac↔engine skew)" \
  || bad "passed an unexpected extra arg to timed-fyi-poll (got: $OUT)"

# ── PART B — the kill switch ─────────────────────────────────────────────────
echo ""
echo "── PART B — DAEMON_TIMER_DUE_DISABLED kill switch ──"
OUT_OFF="$(
  cap="$WORK/cap.off"
  (
    set +u
    export DAEMON_REPO_LIB_DIR="$FAKELIB" COORDINATOR_TOKEN="testbearer" CAPTURE="$cap"
    export DAEMON_TIMER_DUE_DISABLED=1
    REGISTRY_PROJECT_REFS=("thirsty")
    REGISTRY_COORDINATOR_URLS=("https://fake.example")
    REGISTRY_TOKEN_KEYCHAIN_ITEMS=("")
    # shellcheck source=/dev/null
    . "$LIB"
    daemon_timer_due_poll_once >/dev/null 2>&1
  )
  [[ -f "$cap" ]] && cat "$cap" || true
)"
[[ -z "$OUT_OFF" ]] && ok "DISABLED=1 ⇒ no co_request call (hard kill switch)" \
  || bad "DISABLED=1 still called the engine (got: $OUT_OFF)"

# ── PART C — no workspace registered ⇒ graceful skip ─────────────────────────
echo ""
echo "── PART C — no workspace ⇒ graceful skip ──"
RC_NOWS="$(
  (
    set +u
    export DAEMON_REPO_LIB_DIR="$FAKELIB" CAPTURE="$WORK/cap.nows"
    # no REGISTRY_* arrays defined at all
    # shellcheck source=/dev/null
    . "$LIB"
    daemon_timer_due_poll_once; echo "rc=$?"
  )
)"
printf '%s' "$RC_NOWS" | grep -q "rc=0" && ok "no registry ⇒ returns 0 (never aborts the daemon loop)" \
  || bad "no registry did not return 0 (got: $RC_NOWS)"
[[ ! -f "$WORK/cap.nows" ]] && ok "no registry ⇒ no co_request call (skipped)" \
  || bad "no registry still called the engine"

# ── PART D — wired into daemon.sh's main loop (the gap is really closed) ──────
echo ""
echo "── PART D — wired into daemon.sh (sourced + cadence-gated) ──"
if [[ -f "$DAEMON_SH" ]]; then
  grep -q '\. "\$DAEMON_DIR/timer-due-poll.sh"' "$DAEMON_SH" \
    && ok "daemon.sh sources timer-due-poll.sh" \
    || bad "daemon.sh does not source timer-due-poll.sh"
  grep -q 'daemon_timer_due_poll_once' "$DAEMON_SH" \
    && ok "daemon.sh main loop calls daemon_timer_due_poll_once" \
    || bad "daemon.sh never calls daemon_timer_due_poll_once (poll is dead code)"
  grep -q 'TIMER_DUE_POLL_INTERVAL' "$DAEMON_SH" \
    && ok "daemon.sh defines + gates on TIMER_DUE_POLL_INTERVAL" \
    || bad "daemon.sh has no TIMER_DUE_POLL_INTERVAL cadence gate"
  grep -q '_last_timer_due_poll" -eq 0' "$DAEMON_SH" \
    && ok "boot-fire arm present (a missed fire window reconciles at boot)" \
    || bad "no boot-fire arm for the timer-due poll"
else
  bad "daemon.sh not found at $DAEMON_SH"
fi

# ── summary ──────────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────────────────────────────"
printf ' N10-11 timer daemon clock: \033[32m%d passed\033[0m, %s%d failed\033[0m\n' \
  "$PASS" "$([[ $FAIL -gt 0 ]] && printf '\033[31m' || printf '\033[32m')" "$FAIL"
echo "────────────────────────────────────────────────────────────────────"
[[ $FAIL -eq 0 ]]
