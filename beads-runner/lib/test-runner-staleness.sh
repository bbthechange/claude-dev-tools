#!/bin/bash
# beads-runner/lib/test-runner-staleness.sh — claude-tools-5772 acceptance for the
# RUNNER self-staleness re-exec (the sibling of the daemon's claude-tools-jzzw
# detector). A long-lived runner sources its libs ONCE at spawn and runs STALE code
# after a lib/runner update until it is respawned; the daemon's own self re-exec
# does NOT reap the runners, so this is the runner-side fix. The chosen design is
# the low-risk option: re-exec BETWEEN TASKS (loop top / idle re-poll in v1,
# st_reconcile in v2) where no `claude -p` worker is live, so no in-flight work is
# lost. Proves:
#   • sourcing the lib does NOT exec / launch anything (pure helpers);
#   • _runner_file_mtime returns an epoch for a real file, 0 for a missing one;
#   • runner_newest_source_mtime takes the newest of {self, lib/*.sh,
#     hooks/build-settings.sh} and IGNORES test-*.sh (the glob auto-enroll caveat);
#   • runner_source_is_stale fires only on a STRICTLY-newer, not-in-the-future
#     mtime (the future-mtime guard that prevents a re-exec loop);
#   • runner_reexec_if_stale honors the RUNNER_SELF_REEXEC=0 off-switch AND the
#     not-stale path — both return WITHOUT exec'ing (so this test can never exec);
#   • STRUCTURAL: both v1 (run-beads-tasks.sh) and v2 (runner.sh) source the lib,
#     capture the RUNNER_SELF_* globals, and CALL runner_reexec_if_stale at their
#     between-tasks points (a refactor can't silently drop the wiring).

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"          # beads-runner/lib
ROOT="$(cd "$HERE/.." && pwd)"                                # beads-runner

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# Disable the real re-exec defensively (belt-and-braces; the not-stale/off-switch
# returns are what actually keep this test from exec'ing). If a guard were broken,
# `exec` would replace this test process — a loud failure (the tier would lose the
# remaining assertions), so we also drive only NON-exec'ing paths below.
export RUNNER_SELF_REEXEC=0
# shellcheck source=lib/runner-staleness.sh
. "$HERE/runner-staleness.sh"

echo "── sourcing the lib does not exec / launch ──"
ok "sourcing runner-staleness.sh returned control (pure function defs only)"

echo "── _runner_file_mtime ──"
TMP="$(mktemp -d)"
touch "$TMP/f"
m="$(_runner_file_mtime "$TMP/f")"
{ [[ "$m" =~ ^[0-9]+$ ]] && [[ "$m" -gt 0 ]]; } \
  && ok "_runner_file_mtime returns an epoch for a real file" \
  || bad "_runner_file_mtime should be a positive epoch (got '$m')"
[[ "$(_runner_file_mtime "$TMP/nope")" == "0" ]] \
  && ok "_runner_file_mtime → 0 for a missing file" || bad "missing file should be 0"

echo "── runner_newest_source_mtime (glob set + test-* exclusion) ──"
WS="$TMP/ws"; mkdir -p "$WS/lib" "$WS/hooks"
: > "$WS/runner.sh"
: > "$WS/lib/coordinator.sh"; : > "$WS/lib/local-agent.sh"
: > "$WS/hooks/build-settings.sh"
touch -t 202001010000 "$WS/runner.sh" "$WS/lib/coordinator.sh" "$WS/lib/local-agent.sh" "$WS/hooks/build-settings.sh"
touch -t 203001010000 "$WS/lib/local-agent.sh"   # a lib/*.sh is the newest SOURCED file
: > "$WS/lib/test-coordinator.sh"; touch -t 204001010000 "$WS/lib/test-coordinator.sh"  # newer, but a test (MUST be ignored)
newest="$(runner_newest_source_mtime "$WS/runner.sh" "$WS")"
la_m="$(_runner_file_mtime "$WS/lib/local-agent.sh")"
[[ "$newest" == "$la_m" ]] \
  && ok "newest = the lib/*.sh mtime (ignores lib/test-*.sh)" \
  || bad "expected newest=$la_m (local-agent.sh), got '$newest' — test-* exclusion broke?"
# The self script can itself be the newest (the runner.sh / run-beads-tasks.sh edit case)
touch -t 205001010000 "$WS/runner.sh"
newest2="$(runner_newest_source_mtime "$WS/runner.sh" "$WS")"
self_m="$(_runner_file_mtime "$WS/runner.sh")"
[[ "$newest2" == "$self_m" ]] \
  && ok "newest tracks the self runner script when it is the newest edit" \
  || bad "expected newest=$self_m (self), got '$newest2'"
# hooks/build-settings.sh is in the watched set
touch -t 206001010000 "$WS/hooks/build-settings.sh"
newest3="$(runner_newest_source_mtime "$WS/runner.sh" "$WS")"
bs_m="$(_runner_file_mtime "$WS/hooks/build-settings.sh")"
[[ "$newest3" == "$bs_m" ]] \
  && ok "newest tracks hooks/build-settings.sh (it IS sourced into the runner)" \
  || bad "expected newest=$bs_m (build-settings), got '$newest3'"

echo "── runner_source_is_stale decision matrix ──"
runner_newest_source_mtime() { echo 1000; }    # override the scan to a fixed value
runner_source_is_stale 999 5000 - - \
  && ok "STALE when newest(1000) > boot(999) and ≤ now" || bad "should be stale"
runner_source_is_stale 1000 5000 - - \
  && bad "should NOT be stale when newest == boot" || ok "not stale when newest == boot (strict-greater)"
runner_source_is_stale 1001 5000 - - \
  && bad "should NOT be stale when boot newer than file" || ok "not stale when boot > newest"
runner_source_is_stale 999 999 - - \
  && bad "should NOT be stale when newest > now (clock-skew)" \
  || ok "not stale when newest(1000) > now(999) — future-mtime guard prevents a re-exec loop"

echo "── runner_reexec_if_stale: never execs on the off-switch / not-stale paths ──"
runner_newest_source_mtime() { echo 9999999999; }   # definitely newer than boot
RUNNER_SELF_START_EPOCH=1
RUNNER_SELF_PATH="$WS/runner.sh"; RUNNER_SELF_DIR="$WS"
RUNNER_SELF_REEXEC=0
runner_reexec_if_stale \
  && bad "reexec_if_stale should be a no-op (rc!=0) when disabled" \
  || ok "reexec_if_stale is a no-op when RUNNER_SELF_REEXEC=0 (never execs in test)"
# Enabled but NOT stale (boot in the far future ⇒ newest < boot) ⇒ rc 1, no exec.
RUNNER_SELF_REEXEC=1
runner_newest_source_mtime() { echo 1000; }
RUNNER_SELF_START_EPOCH=9999999999
runner_reexec_if_stale \
  && bad "reexec_if_stale should be a no-op when source is NOT stale" \
  || ok "reexec_if_stale is a no-op (rc 1) on the fresh-source path — still alive, no exec"

rm -rf "$TMP" 2>/dev/null || true

echo "── STRUCTURAL: both runners are wired (source + globals + call) ──"
V1="$ROOT/run-beads-tasks.sh"; V2="$ROOT/runner.sh"
chk() { # <file> <label> <grep-args...>
  local f="$1" label="$2"; shift 2
  if grep -q "$@" "$f" 2>/dev/null; then ok "$label"; else bad "$label — pattern absent in ${f##*/}"; fi
}
# v1
chk "$V1" "v1 sources lib/runner-staleness.sh"            -F "lib/runner-staleness.sh"
chk "$V1" "v1 captures RUNNER_SELF_START_EPOCH"           -F "RUNNER_SELF_START_EPOCH="
chk "$V1" "v1 captures RUNNER_SELF_ARGV"                  -F 'RUNNER_SELF_ARGV=("$@")'
chk "$V1" "v1 defines the no-op fallback (BC-43 degrade)" -F "runner_reexec_if_stale() { return 1; }"
# Two call sites: outer loop-top + idle inner loop.
[[ "$(grep -c 'runner_reexec_if_stale || true' "$V1")" -ge 2 ]] \
  && ok "v1 calls runner_reexec_if_stale at ≥2 between-tasks points (loop-top + idle)" \
  || bad "v1 should call runner_reexec_if_stale at the loop-top AND the idle re-poll"
# v2
chk "$V2" "v2 sources lib/runner-staleness.sh"            -F "lib/runner-staleness.sh"
chk "$V2" "v2 captures RUNNER_SELF_START_EPOCH"           -F "RUNNER_SELF_START_EPOCH="
chk "$V2" "v2 captures RUNNER_SELF_ARGV"                  -F 'RUNNER_SELF_ARGV=("$@")'
chk "$V2" "v2 defines the no-op fallback (BC-43 degrade)" -F "runner_reexec_if_stale() { return 1; }"
chk "$V2" "v2 calls runner_reexec_if_stale (st_reconcile)" -F "runner_reexec_if_stale || true"

echo "── test-runner-staleness: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
