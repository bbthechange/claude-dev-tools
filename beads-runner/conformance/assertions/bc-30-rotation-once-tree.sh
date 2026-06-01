#!/bin/bash
# BC-30 (FORWARD / v2) — age-based rotation runs EXACTLY ONCE at startup, never
#   per-iteration, so it cannot race the artifacts an active run is producing.
#   (claude-tools-v2cut.4 port — v2 had no rotation at all.)
#
# Binds: BEHAVIORAL-CONTRACT.md §11 BC-30. v2 prunes in st_starting (reached
# EXACTLY ONCE: STARTING→RECONCILE never returns), excluding .gitignore +
# incidents.log. SCAR (silent-when-wrong): a per-iteration prune is a footgun a
# rewrite could re-introduce; it would delete a concurrent/own in-flight artifact.
#
# TARGET — the forward rewrite runner.sh (same re-point pattern as bc-58/bc-22).
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

H_init_test bc30tree-rotate-once
ld="$WORKDIR/.beads/runner-logs"
mkdir -p "$ld"

# Positive control: a PRE-EXISTING ancient artifact must be pruned at startup
# (proves rotation actually ran this invocation).
: > "$ld/preexist-OLD.jsonl"
touch -t 200001010000 "$ld/preexist-OLD.jsonl"
# Exemption control: an ancient incidents.log is name-excluded ⇒ must survive.
printf '%s\n' "PRESEED-MARKER" > "$ld/incidents.log"
touch -t 200001010000 "$ld/incidents.log"

# Two tasks. Task #1 (success_touch_old) creates an ANCIENT-mtime artifact
# UNDER LOG_DIR *during iteration 1* — i.e. AFTER the single startup prune.
# A per-iteration prune (top of iteration 2) would delete it; once-per-
# invocation rotation must leave it ALIVE at run end. This is load-bearing.
bd_seed T1 "iter-1 toucher" "x"
bd_seed T2 "iter-2 plain"  "x"
claude_plan success_touch_old success
run_runner

_expect "BC-30" "§11" "rotation is once-at-startup, NOT per-iteration (runner.sh)"
_need "run completed normally (both beads closed)"   bash -c '[[ "$(cat "'"$BD_STORE"'/T1/status")" == closed && "$(cat "'"$BD_STORE"'/T2/status")" == closed ]]'
_need "startup prune DID run (ancient preexisting artifact deleted)" bash -c '! test -e "'"$ld"'/preexist-OLD.jsonl"'
_need "mid-run ancient artifact SURVIVED (no per-iteration prune)"    test -e "$ld/midrun-OLD.jsonl"
_need "ancient incidents.log name-exempt (survived)"  contains "$(incidents_log)" "PRESEED-MARKER"
_emit
H_cleanup
