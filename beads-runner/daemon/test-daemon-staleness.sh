#!/bin/bash
# beads-runner/daemon/test-daemon-staleness.sh — jzzw (claude-tools-jzzw)
# acceptance for the daemon SELF-STALENESS detector (incident 2026-06-14: a
# long-lived daemon ran code older than its source for ~2 weeks and nothing
# noticed). Proves:
#   • sourcing daemon.sh does NOT launch the daemon (the BASH_SOURCE!=$0 guard) —
#     the pure helpers can be unit-tested in isolation;
#   • _daemon_file_mtime returns an epoch for a real file, 0 for a missing one;
#   • daemon_newest_source_mtime takes the newest of {daemon.sh, *-poll.sh, the
#     named non-poll helpers} and IGNORES test-*.sh + non-sourced operator scripts;
#   • daemon_source_is_stale fires only on a STRICTLY-newer, not-in-the-future
#     mtime (the future-mtime guard that prevents a re-exec loop);
#   • daemon_reexec_if_stale honors the DAEMON_SELF_REEXEC=0 off-switch (so this
#     test can never actually exec).

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# Disable the real re-exec defensively (belt-and-braces; the guard is what
# actually keeps `main` from launching when we source). If the guard were broken,
# `main` would block here forever and the tier would time out — a loud failure.
export DAEMON_SELF_REEXEC=0
# shellcheck source=/dev/null
. "$HERE/daemon.sh"

echo "── guard: sourcing does not launch the daemon ──"
ok "sourcing daemon.sh returned control (main is guarded, not launched)"

echo "── _daemon_file_mtime ──"
TMP="$(mktemp -d)"
touch "$TMP/f"
m="$(_daemon_file_mtime "$TMP/f")"
{ [[ "$m" =~ ^[0-9]+$ ]] && [[ "$m" -gt 0 ]]; } \
  && ok "_daemon_file_mtime returns an epoch for a real file" \
  || bad "_daemon_file_mtime should be a positive epoch (got '$m')"
[[ "$(_daemon_file_mtime "$TMP/nope")" == "0" ]] \
  && ok "_daemon_file_mtime → 0 for a missing file" || bad "missing file should be 0"

echo "── daemon_newest_source_mtime (glob set + exclusions) ──"
WSDIR="$TMP/dd"; mkdir -p "$WSDIR"
for f in daemon.sh a-poll.sh workspace-registry.sh m6-dispatch.sh aux-dispatch-gate.sh; do : > "$WSDIR/$f"; done
touch -t 202001010000 "$WSDIR"/*.sh            # old baseline for the sourced set
touch -t 203001010000 "$WSDIR/a-poll.sh"       # a *-poll.sh is the newest SOURCED file
: > "$WSDIR/test-x.sh";      touch -t 204001010000 "$WSDIR/test-x.sh"      # newer, but a test (ignored)
: > "$WSDIR/test-y-poll.sh"; touch -t 204001010000 "$WSDIR/test-y-poll.sh" # newer + matches *-poll.sh, but test-* (MUST be ignored)
: > "$WSDIR/install.sh";     touch -t 204001010000 "$WSDIR/install.sh"     # newer, but not sourced (ignored)
DAEMON_DIR="$WSDIR"   # daemon_newest_source_mtime reads $DAEMON_DIR at call time
newest="$(daemon_newest_source_mtime)"
poll_m="$(_daemon_file_mtime "$WSDIR/a-poll.sh")"
[[ "$newest" == "$poll_m" ]] \
  && ok "newest = the *-poll.sh mtime (ignores test-*.sh and install.sh)" \
  || bad "expected newest=$poll_m (a-poll.sh), got '$newest' — exclusion broke?"

echo "── daemon_source_is_stale decision matrix ──"
daemon_newest_source_mtime() { echo 1000; }    # override the scan to a fixed value
daemon_source_is_stale 999 5000 \
  && ok "STALE when newest(1000) > boot(999) and ≤ now" || bad "should be stale"
daemon_source_is_stale 1000 5000 \
  && bad "should NOT be stale when newest == boot" || ok "not stale when newest == boot (strict-greater)"
daemon_source_is_stale 1001 5000 \
  && bad "should NOT be stale when boot newer than file" || ok "not stale when boot > newest"
daemon_source_is_stale 999 999 \
  && bad "should NOT be stale when newest > now (clock-skew)" \
  || ok "not stale when newest(1000) > now(999) — future-mtime guard prevents a re-exec loop"

echo "── daemon_reexec_if_stale off-switch ──"
daemon_newest_source_mtime() { echo 9999999999; }   # definitely newer than boot
DAEMON_SELF_START_EPOCH=1
DAEMON_SELF_REEXEC=0
daemon_reexec_if_stale \
  && bad "reexec_if_stale should be a no-op (rc!=0) when disabled" \
  || ok "reexec_if_stale is a no-op when DAEMON_SELF_REEXEC=0 (never execs in test)"

rm -rf "$TMP" 2>/dev/null || true
echo "── test-daemon-staleness: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
