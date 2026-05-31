#!/bin/bash
# beads-runner/daemon/test-notif-delivery.sh — N2 (claude-tools-uxg1)
# notification DELIVERY clock conformance (DESIGN N §2.3).
#
# WHAT THIS PROVES (offline — no real engine, no network):
#   PART 0 — file parses + defines the public API + carries the DESIGN N banner.
#   PART A — _notif_deliver_call rings co_request with the EXACT op + mode:
#            `co_request <bearer> notif-deliver blocking|digest` (via a fake
#            co-http-transport.sh injected on DAEMON_REPO_LIB_DIR).
#   PART B — the two entry points map to the two modes (blocking / digest).
#   PART C — DAEMON_NOTIF_DELIVERY_DISABLED=1 is a hard kill switch (no call).
#   PART D — no workspace registered ⇒ graceful skip (returns 0, no call).
#
# The real Web-Push crypto + the deliver-once ledger are the ENGINE's
# (cf/test/push.spec.js pins them against the RFC 8291/8292 vectors). This test
# only proves the daemon CLOCK rings the right op on the right cadence.
#
# Run: bash beads-runner/daemon/test-notif-delivery.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/notif-delivery-poll.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " N2 notification delivery clock — claude-tools-uxg1"
echo "════════════════════════════════════════════════════════════════════"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A fake co-http-transport.sh that records every co_request invocation instead
# of hitting the network — injected via DAEMON_REPO_LIB_DIR.
FAKELIB="$WORK/lib"
mkdir -p "$FAKELIB"
cat > "$FAKELIB/co-http-transport.sh" <<'EOF'
co_request() { printf 'CALL %s\n' "$*" >> "$CAPTURE"; printf '{"ok":true}'; }
EOF

# ── PART 0 ──────────────────────────────────────────────────────────────────
echo ""
echo "── PART 0 — file parses + defines the API ──"
[[ -f "$LIB" ]] && ok "notif-delivery-poll.sh present" || bad "lib missing"
bash -n "$LIB" 2>/dev/null && ok "lib parses (bash -n clean)" || bad "lib syntax error"
( . "$LIB" 2>/dev/null
  declare -F daemon_notif_delivery_poll_once >/dev/null 2>&1 ) \
  && ok "defines daemon_notif_delivery_poll_once" || bad "missing daemon_notif_delivery_poll_once"
( . "$LIB" 2>/dev/null
  declare -F daemon_notif_digest_sweep_once >/dev/null 2>&1 ) \
  && ok "defines daemon_notif_digest_sweep_once" || bad "missing daemon_notif_digest_sweep_once"
grep -q "DESIGN N" "$LIB" && ok "carries the DESIGN N provenance banner" || bad "DESIGN N banner missing"

# helper: run a poll function with a registry + the fake transport, capturing
# the co_request calls. $1 = function to call. Echoes the capture file content.
run_with_fake() {
  local fn="$1"
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
    "$fn" >/dev/null 2>&1
  )
  [[ -f "$cap" ]] && cat "$cap" || true
}

# ── PART A + B — the entry points ring co_request with the right op + mode ───
echo ""
echo "── PART A/B — rings co_request notif-deliver <mode> ──"
OUT_BLOCK="$(run_with_fake daemon_notif_delivery_poll_once)"
printf '%s' "$OUT_BLOCK" | grep -q "CALL testbearer notif-deliver blocking" \
  && ok "delivery poll ⇒ co_request testbearer notif-deliver blocking" \
  || bad "delivery poll did not ring 'notif-deliver blocking' (got: $OUT_BLOCK)"

OUT_DIGEST="$(run_with_fake daemon_notif_digest_sweep_once)"
printf '%s' "$OUT_DIGEST" | grep -q "CALL testbearer notif-deliver digest" \
  && ok "digest sweep ⇒ co_request testbearer notif-deliver digest" \
  || bad "digest sweep did not ring 'notif-deliver digest' (got: $OUT_DIGEST)"

# ── PART C — the kill switch ─────────────────────────────────────────────────
echo ""
echo "── PART C — DAEMON_NOTIF_DELIVERY_DISABLED kill switch ──"
OUT_OFF="$(
  cap="$WORK/cap.off"
  (
    set +u
    export DAEMON_REPO_LIB_DIR="$FAKELIB" COORDINATOR_TOKEN="testbearer" CAPTURE="$cap"
    export DAEMON_NOTIF_DELIVERY_DISABLED=1
    REGISTRY_PROJECT_REFS=("thirsty")
    REGISTRY_COORDINATOR_URLS=("https://fake.example")
    REGISTRY_TOKEN_KEYCHAIN_ITEMS=("")
    # shellcheck source=/dev/null
    . "$LIB"
    daemon_notif_delivery_poll_once >/dev/null 2>&1
    daemon_notif_digest_sweep_once >/dev/null 2>&1
  )
  [[ -f "$cap" ]] && cat "$cap" || true
)"
[[ -z "$OUT_OFF" ]] && ok "DISABLED=1 ⇒ no co_request call (hard kill switch)" \
  || bad "DISABLED=1 still called the engine (got: $OUT_OFF)"

# ── PART D — no workspace registered ⇒ graceful skip ─────────────────────────
echo ""
echo "── PART D — no workspace ⇒ graceful skip ──"
RC_NOWS="$(
  (
    set +u
    export DAEMON_REPO_LIB_DIR="$FAKELIB" CAPTURE="$WORK/cap.nows"
    # no REGISTRY_* arrays defined at all
    # shellcheck source=/dev/null
    . "$LIB"
    daemon_notif_delivery_poll_once; echo "rc=$?"
  )
)"
printf '%s' "$RC_NOWS" | grep -q "rc=0" && ok "no registry ⇒ returns 0 (never aborts the daemon loop)" \
  || bad "no registry did not return 0 (got: $RC_NOWS)"
[[ ! -f "$WORK/cap.nows" ]] && ok "no registry ⇒ no co_request call (skipped)" \
  || bad "no registry still called the engine"

# ── summary ──────────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────────────────────────────"
printf ' N2 delivery clock: \033[32m%d passed\033[0m, %s%d failed\033[0m\n' \
  "$PASS" "$([[ $FAIL -gt 0 ]] && printf '\033[31m' || printf '\033[32m')" "$FAIL"
echo "────────────────────────────────────────────────────────────────────"
[[ $FAIL -eq 0 ]]
