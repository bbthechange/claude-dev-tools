#!/bin/bash
# beads-runner/lib/test-ready-cache.sh — claude-tools-4a2e regression-lock.
#
# P3 of the local-first state architecture: a short TTL cache over the per-loop
# `bd ready` poll so a spinning runner stops re-taking the dolt lock every pass.
# This file locks the two properties that make the cache SAFE and CORRECT:
#
#   PART A (v1 BEHAVIORAL, sourced run-beads-tasks.sh in test mode):
#     • a second next_task() within the window serves from cache (no new bd ready)
#     • ready_cache_bust forces a fresh query (the commit-to-run invalidation)
#     • an expired entry re-queries (the TTL boundary)
#     • next_task() NEVER calls `bd blocked` — the BC-06 re-check is uncached
#     • FILE-backed: the cache survives `TASK_JSON=$(next_task)`'s subshell (an
#       in-memory global would be discarded with the subshell and never persist —
#       the crux of why v1 uses a file while v2 uses a global).
#
#   PART B (STRUCTURAL, both runners): the bust fires at commit-to-run, and the
#     BC-06 `bd blocked` re-check is NOT wrapped by the ready cache.
#
# v2's end-to-end behavior (cache + bust + uncached BC-06 re-check, live with
# RECLAIM_POLL_INTERVAL=1) is exercised by conformance/assertions/
# bc-06-blocked-recheck-tree.sh; this file adds the v1 behavioral lock (no
# conformance assertion runs run-beads-tasks.sh end-to-end) and the cheap
# structural invariants for both.
#
# Offline + deterministic: BEADS_RUNNER_TEST_MODE=1 sources the runner to load
# its functions WITHOUT entering the task loop; a fake `bd` records invocations
# to files (so the counts survive the command-substitution subshell); jq only.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
result() { echo "RESULT: $PASS passed, $FAIL failed"; [[ "$FAIL" -eq 0 ]]; }

command -v jq >/dev/null 2>&1 || { echo "  (skip) jq not available"; echo "RESULT: 0 passed, 0 failed"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ── fake bd: records every invocation to a file so the count survives the
#    `$(next_task)` subshell (a variable counter would not). Only the verbs
#    next_task / the source-time module code touch are modeled. ──────────────
printf '%s\n' '[{"id":"rc-1","issue_type":"task","priority":1,"title":"ready one","description":"d"}]' > "$TMP/ready-fixture.json"
READY_CALLS="$TMP/ready-calls"; BLOCKED_CALLS="$TMP/blocked-calls"
bd() {
  case "${1:-}" in
    ready)   printf 'x\n' >> "$READY_CALLS";   cat "$TMP/ready-fixture.json" ;;
    blocked) printf 'x\n' >> "$BLOCKED_CALLS"; printf '[]\n' ;;
    *)       printf '[]\n' ;;
  esac
}
count() { [[ -r "$1" ]] && { wc -l < "$1" | tr -d ' '; } || echo 0; }

# ── source the v1 runner in test mode ────────────────────────────────────────
unset COORDINATOR_URL 2>/dev/null || true
export CO_STORE="$TMP/.co-store"; mkdir -p "$CO_STORE/records"
export PROJECT_REF="ct-ready-cache"
export ASK_BRIAN_ENABLED=0
export USAGE_POLL_DISABLED=1
export LOG_DIR="$TMP/logs"; mkdir -p "$LOG_DIR"
export READY_CACHE_SECONDS=30
export BEADS_RUNNER_TEST_MODE=1
# shellcheck source=/dev/null
source "$REPO/run-beads-tasks.sh" >/dev/null 2>&1 \
  || { bad "could not source run-beads-tasks.sh in test mode"; result; exit 1; }

for fn in next_task ready_cache_bust _ready_cache_file; do
  command -v "$fn" >/dev/null 2>&1 || { bad "$fn not defined after source"; result; exit 1; }
done

# Neutralize anything the source touched: empty the orphan list (so next_task
# falls straight through to the bd-ready cache) and zero the call counters.
ORPHANED_IDS=()
rm -f "$READY_CALLS" "$BLOCKED_CALLS" "$(_ready_cache_file)"

echo "── A. v1 file-backed cache: hit / bust / expiry, BC-06 left uncached ──"

out1="$(next_task)"
c1="$(count "$READY_CALLS")"
[[ "$c1" == "1" ]] && ok "cold call queries bd ready once (calls=$c1)" \
                    || bad "cold call should query once, got calls=$c1"
printf '%s' "$out1" | jq -e '.[0].id == "rc-1"' >/dev/null 2>&1 \
  && ok "cold call returns the ready array (rc-1)" \
  || bad "cold call did not return the seeded ready array: $out1"

out2="$(next_task)"
c2="$(count "$READY_CALLS")"
[[ "$c2" == "1" ]] && ok "second call within window serves from cache (no new bd ready; calls=$c2)" \
                    || bad "second call should hit cache (calls still 1), got calls=$c2"
[[ "$out2" == "$out1" ]] && ok "cached bytes are identical to the fresh query" \
                          || bad "cached output differs from fresh: '$out2' != '$out1'"

ready_cache_bust
out3="$(next_task)"
c3="$(count "$READY_CALLS")"
[[ "$c3" == "2" ]] && ok "ready_cache_bust forces a fresh query (calls=$c3)" \
                    || bad "after bust, expected a re-query (calls=2), got calls=$c3"
[[ -r "$(_ready_cache_file)" ]] && ok "fresh query re-populates the cache file" \
                                 || bad "cache file missing after re-query"

# Expire: rewrite the cache file's epoch far into the past → next call MISSes.
printf '%s\n%s\n' "$(( $(date +%s) - 9999 ))" "$(cat "$TMP/ready-fixture.json")" \
  > "$(_ready_cache_file)"
out4="$(next_task)"
c4="$(count "$READY_CALLS")"
[[ "$c4" == "3" ]] && ok "an expired entry (age > window) re-queries (calls=$c4)" \
                    || bad "expired entry should re-query (calls=3), got calls=$c4"

bc="$(count "$BLOCKED_CALLS")"
[[ "$bc" == "0" ]] && ok "next_task NEVER calls bd blocked (BC-06 re-check stays out of the cache)" \
                    || bad "next_task called bd blocked $bc time(s) — the BC-06 re-check must be uncached"

echo "── B. structural invariants (both runners) ──"

# Print a top-level function's body (header line to its column-0 closing brace).
func_body() { # <file> <funcname>
  awk -v fn="$2" '
    $0 ~ "^"fn"\\(\\) \\{" {inb=1}
    inb {print}
    inb && /^\}/ {exit}
  ' "$1"
}

V1="$REPO/run-beads-tasks.sh"; V2="$REPO/runner.sh"

# v1: the ready cache wraps `bd ready` but not `bd blocked`.
func_body "$V1" next_task | grep -q 'bd ready' \
  && ok "v1 next_task polls bd ready" \
  || bad "v1 next_task no longer polls bd ready"
func_body "$V1" next_task | grep -q 'bd blocked' \
  && bad "v1 next_task contains a bd blocked call — the BC-06 re-check must NOT be inside the cached poll" \
  || ok "v1 next_task contains no bd blocked (BC-06 re-check is in validate_task, uncached)"

# v1: the bust is invoked at commit-to-run (after the CURRENT_TASK_ID set).
v1_commit="$(grep -n 'CURRENT_TASK_ID="\$TASK_ID"' "$V1" | head -1 | cut -d: -f1)"
v1_bust="$(grep -nE '^[[:space:]]*ready_cache_bust[[:space:]]*$' "$V1" | head -1 | cut -d: -f1)"
if [[ -n "$v1_commit" && -n "$v1_bust" && "$v1_bust" -gt "$v1_commit" ]]; then
  ok "v1 ready_cache_bust ($v1_bust) fires AFTER commit-to-run ($v1_commit)"
else
  bad "v1 bust not found after commit-to-run (commit=$v1_commit bust=$v1_bust)"
fi

# v2: the ready cache wraps st_reconcile's bd ready; the BC-06 re-check in
# _validate_workable is NOT cache-gated; the bust fires in st_claim.
func_body "$V2" st_reconcile | grep -q 'READY_CACHE_JSON' \
  && ok "v2 st_reconcile wraps bd ready in the READY_CACHE TTL" \
  || bad "v2 st_reconcile no longer wraps bd ready in READY_CACHE"
func_body "$V2" _validate_workable | grep -q 'bd blocked' \
  && ok "v2 _validate_workable still runs the BC-06 bd blocked re-check" \
  || bad "v2 _validate_workable lost its bd blocked re-check"
func_body "$V2" _validate_workable | grep -q 'READY_CACHE' \
  && bad "v2 _validate_workable is cache-gated — the BC-06 re-check must stay live" \
  || ok "v2 BC-06 re-check is NOT gated by READY_CACHE (stays fresh per candidate)"
func_body "$V2" st_claim | grep -qE '^[[:space:]]*ready_cache_bust[[:space:]]*$' \
  && ok "v2 st_claim busts the ready cache at commit-to-run" \
  || bad "v2 st_claim no longer busts the ready cache at commit-to-run"

result
