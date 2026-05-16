#!/bin/bash
# BC-30 — Age-based rotation runs EXACTLY ONCE per invocation (at startup),
#         never per-iteration, so it cannot race artifacts an active run is
#         still producing.
# Binds: INTERFACE.md v1 §8.2 (log-dir lifecycle — startup-only prune).
# SCAR (silent-when-wrong): a per-iteration prune is a footgun a rewrite could
#        re-introduce; it would delete a concurrent/own in-flight artifact.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

H_init_test bc30-rotate-once
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

_expect "BC-30" "§8.2" "rotation is once-at-startup, NOT per-iteration"
_need "run completed normally (both beads closed)"   bash -c '[[ "$(cat "'"$BD_STORE"'/T1/status")" == closed && "$(cat "'"$BD_STORE"'/T2/status")" == closed ]]'
_need "startup prune DID run (ancient preexisting artifact deleted)" bash -c '! test -e "'"$ld"'/preexist-OLD.jsonl"'
_need "mid-run ancient artifact SURVIVED (no per-iteration prune)"    test -e "$ld/midrun-OLD.jsonl"
_need "ancient incidents.log name-exempt (survived)"  contains "$(incidents_log)" "PRESEED-MARKER"
_emit
H_cleanup
