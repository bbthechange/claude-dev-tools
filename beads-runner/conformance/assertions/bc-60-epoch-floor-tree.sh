#!/bin/bash
# BC-60 — epoch-floor + liveness/in-flight mechanics (v2 -tree
#         coverage-hardening, claude-tools-v2cut.5)
#
# Binds: BEHAVIORAL-CONTRACT.md §BC-60 ("In-flight tracking, per-line activity
#        stamp, and the malformed-timestamp guard"). BC-60 underpins
#        BC-22/BC-22-addendum/BC-59. Its three mechanics, AS NAMED IN THE
#        CONTRACT, describe the v1 2603-line run-beads-tasks.sh (source refs
#        1914/1926, 1913/1976-1989, 2109/2084/2200). v2 runner.sh REBUILT this
#        SCAR idiomatically (the conformance bar is "preserve the behavior,
#        rebuild the bash"), so this rig asserts the v2 form of each mechanic —
#        what is genuinely present/observable in $RUNNER — NOT the v1 file
#        names. The v1->v2 mapping (all three preserved, two re-implemented):
#
#   (a) per-line liveness action   v1: ACTIVITY_FILE overwritten with `date +%s`
#       ("any byte = alive")           as the first action for every stream line.
#                                  v2: _watchdog_loop reads live stream growth
#                                      (`wc -c`) + tree CPU (`_tree_cpu_secs`)
#                                      every WATCHDOG_POLL; ANY stream byte (or
#                                      tree-CPU advance) resets last_progress —
#                                      the same "any byte = alive" definition,
#                                      with no separate ACTIVITY_FILE seam (v2
#                                      has NO concurrent tail -f stream parser).
#   (b) in-flight set membership   v1: TASK_INFLIGHT_FILE, one line per in-flight
#                                      Task subagent; add via `grep -qxF || echo
#                                      >>`, remove via `grep -vxF` + `mv`.
#                                  v2: _inflight_tasks replays the SAME
#                                      task_notification/task_updated events from
#                                      the stream into an in-memory awk
#                                      associative array — add on
#                                      status=in_progress, delete on
#                                      completed|stopped|killed|failed|cancelled.
#                                      Same set semantics, single-writer, no file.
#   (c) epoch-floor guard          v1 & v2 BOTH: every reader of a timestamp file
#       (claude-tools-h7n)             rejects a value that is not all-digits or
#                                      `< 1704067200` (2024-01-01) and continues,
#                                      so a partial/empty read can't make
#                                      IDLE = now (~56yr) and fire a false kill.
#                                      v2 PRESERVES the literal floor + all-digits
#                                      check on its POST_TERMINAL_FILE reader
#                                      (runner.sh ~1357-1359).
#
# These are no-ops / un-timeable in the stub harness (the watchdog soft/kill
# tiers are 180/600s; the post-terminal grace is 60s — all far longer than any
# rig wall-clock), so the assertions are SOURCE-STRUCTURAL against $RUNNER, plus
# a light behavioral block proving _inflight_tasks reduces real stream events.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"   # repoint to v2
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# ── A · per-line liveness action ("any byte = alive") ────────────────────────
# v2 form: the watchdog's per-poll liveness read. ANY stream growth (wc -c) OR
# tree-CPU advance resets last_progress; idle is `now - last_progress`. This is
# the v2 re-implementation of v1's ACTIVITY_FILE `date +%s` per-line stamp.
H_init_test bc60tree-liveness-action
_expect "BC-60" "§BC-60" "liveness action: ANY stream byte (wc -c growth) or tree-CPU advance resets the idle clock (v2 form of v1's ACTIVITY_FILE stamp)"
_need "watchdog samples live stream byte-count (wc -c on the stream)" \
      grep -qE 'wc -c < "\$stream"' "$RUNNER"
_need "watchdog samples tree CPU as the second progress signal" \
      grep -qE '_tree_cpu_secs "\$pid"' "$RUNNER"
_need "ANY byte/CPU growth resets last_progress (the 'alive' action)" \
      grep -qE 'bytes.*-gt.*prev_bytes.*\|\|.*cpu.*-gt.*prev_cpu' "$RUNNER"
_need "the reset stamps now into last_progress (the v2 'date +%s' equivalent)" \
      grep -qE 'last_progress="\$now"' "$RUNNER"
_need "idle is computed as now - last_progress" \
      grep -qE 'idle=\$\(\( *now - last_progress *\)\)' "$RUNNER"
_need "the v2 departure from v1's per-line stamp is pinned (no concurrent parser)" \
      grep -qE 'v2 has no concurrent tail -f parser' "$RUNNER"
_emit
H_cleanup

# ── B · in-flight set-membership maintenance ─────────────────────────────────
# v2 form: _inflight_tasks adds a task_id to the in-memory set on
# status=in_progress and removes it on any terminal status. Same set semantics
# as v1's TASK_INFLIGHT_FILE grep-qxF(add)/grep-vxF(remove), single-writer.
H_init_test bc60tree-inflight-membership
_expect "BC-60" "§BC-60" "in-flight set-membership: add on in_progress, remove on completed|stopped|killed|failed|cancelled (v2 awk-set form of v1's TASK_INFLIGHT_FILE)"
_need "_inflight_tasks replays task_notification/task_updated events" \
      grep -qE '"\(task_notification\|task_updated\)"' "$RUNNER"
_need "ADD: status in_progress puts the task_id in the set" \
      grep -qE 'st == "in_progress".*inflight\[tid\] = 1' "$RUNNER"
_need "REMOVE: each terminal status deletes the task_id from the set" \
      bash -c 'grep -qE "completed.*stopped.*killed" "'"$RUNNER"'" && grep -qE "failed.*cancelled.*delete inflight\[tid\]" "'"$RUNNER"'"'
_need "the set is reduced to a live count (set membership, not a running tally)" \
      grep -qE 'for \(t in inflight\) n\+\+' "$RUNNER"
_need "the watchdog consumes the count to STRETCH (not pause) the kill threshold" \
      grep -qE 'effective_timeout=\$\(\( *IDLE_TIMEOUT \* IDLE_TIMEOUT_INFLIGHT_MULT *\)\)' "$RUNNER"
_emit
H_cleanup

# ── C · epoch-floor / malformed-timestamp guard (claude-tools-h7n) ───────────
# v2 PRESERVES the literal floor: the post-terminal timestamp reader rejects a
# value that is not all-digits OR `< 1704067200` (2024-01-01) before using it,
# so a partial/empty read can't make the age huge and fire a false SIGKILL.
H_init_test bc60tree-epoch-floor
_expect "BC-60" "§BC-60" "epoch-floor guard: a timestamp-file value must be all-digits AND >= 1704067200 before it is trusted (claude-tools-h7n; v2 preserves the literal floor)"
_need "the literal 2024-01-01 floor 1704067200 is present in $RUNNER" \
      grep -qF '1704067200' "$RUNNER"
_need "the guard requires the value be all-digits (^[0-9]+$)" \
      grep -qE 'pt_at.*=~.*\^\[0-9\]\+\$' "$RUNNER"
_need "the guard ANDs all-digits with the >= 1704067200 floor on one reader" \
      grep -qE '=~ \^\[0-9\]\+\$.*&&.*pt_at >= 1704067200' "$RUNNER"
_need "only a passing value is used to compute the age (guarded reader)" \
      grep -qE 'pt_age=\$\(\( *now - pt_at *\)\)' "$RUNNER"
_need "the guarded reader feeds the post-terminal SIGKILL backstop (not a bare kill)" \
      grep -qE 'POST_TERMINAL_KILL=1' "$RUNNER"
_emit
H_cleanup

# ── D · behavioral: _inflight_tasks reduces real stream events to a live set ──
# Exercise the actual v2 reducer against a crafted stream: a single subagent
# rises to 1 on in_progress, then falls to 0 on a terminal task_updated —
# proving the set-membership semantics, not just the source text. $RUNNER has NO
# sourced-guard (its bottom-of-file `while true` state-machine runs the runner on
# `source`), so we EXTRACT just the pure `_inflight_tasks() {...}` definition
# into an isolated file and source THAT — zero side effects, the genuine v2 code.
H_init_test bc60tree-inflight-behavioral
sf="$WORKDIR/.stream.jsonl"
fnlib="$WORKDIR/.inflight-fn.sh"
awk '/^_inflight_tasks\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$RUNNER" > "$fnlib"
_count_inflight() { ( source "$fnlib"; _inflight_tasks "$1" ); }

# 1) one subagent in_progress => count rises to 1
printf '%s\n' '{"type":"system","subtype":"task_notification","task_id":"sub-A","status":"in_progress","summary":"long subagent"}' > "$sf"
n_open="$(_count_inflight "$sf")"

# 2) terminal task_updated => count falls back to 0
printf '%s\n' '{"type":"system","subtype":"task_updated","task_id":"sub-A","patch":{"status":"completed"}}' >> "$sf"
n_closed="$(_count_inflight "$sf")"

# 3) empty/absent stream => 0 (the malformed/empty-read safe default)
n_empty="$(_count_inflight "$WORKDIR/.nope")"

_expect "BC-60" "§BC-60" "behavioral: _inflight_tasks (extracted v2 reducer) maps task events to a live set — 1 on in_progress, 0 after the terminal event, 0 on empty"
_need "the _inflight_tasks definition was extractable from \$RUNNER" \
      test -s "$fnlib"
_need "in_progress subagent counted (set rises to 1)"   test "$n_open" = "1"
_need "terminal task_updated removes it (set falls to 0)" test "$n_closed" = "0"
_need "empty/absent stream is the safe 0 default"       test "$n_empty" = "0"
_emit
H_cleanup
