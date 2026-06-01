#!/bin/bash
# BC-44 — process-tree isolation + EXIT-trap reap of the worker/watchdog subtrees
#         on every exit path (v2 -tree coverage-hardening, claude-tools-v2cut.5)
#
# Binds: BEHAVIORAL-CONTRACT.md §14 BC-44. The CONTRACT's mechanism prose is
# v1-flavoured (`set -m` so PGID==PID, negative-PID `kill -- -$PID`, a
# `_final_subshell_reap` EXIT trap). The contract itself classifies that bash
# job-control machinery as SCAFFOLDING ("must be rebuilt, not transcribed").
# v2 MATCHES/EXCEEDS the SCAR (the load-bearing goal: reap the worker+watchdog
# SUBTREES — incl. reparented `sleep`/`ps`/`claude` grandchildren — on EVERY exit
# path, closing the ~211-accumulated-tails leak AT THE SOURCE) via a DIFFERENT,
# stronger mechanism:
#   * `_tree_pids <root>` — a portable `ps -A`+ppid-fixpoint subtree walk that
#     enumerates the whole subtree INCLUDING grandchildren (so a reparented child
#     is reached by ENUMERATION, not by a negative-PID group kill that a
#     self-issued kill deliberately avoids — see runner.sh ~1133-1137);
#   * `_kill_tree`/`_reap_tree` — staged, BOUNDED first_sig→grace→SIGKILL of that
#     enumerated subtree, ALWAYS skipping `$$` (BC-21: never signal the runner);
#   * ONE `trap runner_teardown EXIT` funnel that reaps the worker (INT first) +
#     watchdog subtrees + `_sweep_self` catch-all on every exit path.
# So this rig asserts v2's ACTUAL constructs (NOT `set -m`/negative-PID, which v2
# consciously does not self-issue) SOURCE-STRUCTURALLY, plus a behavioral block
# that a normal run exits cleanly with no hang.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"   # repoint to v2
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# ── A · subtree ENUMERATION reaches reparented grandchildren ───────────────────
H_init_test bc44tree-subtree-enumeration
_expect "BC-44" "§14" "_tree_pids walks the FULL subtree (incl. grandchildren) via ps+ppid fixpoint — reparented children reached by enumeration (runner.sh)"
_need "_tree_pids defined"                            grep -qE '^_tree_pids\(\) *\{' "$RUNNER"
_need "_tree_pids snapshots ps -A pid/ppid"           grep -qE 'ps -A -o pid=,ppid=' "$RUNNER"
_need "_tree_pids closes the ppid set to a fixpoint (grandchildren included)" \
      grep -qE 'while\(changed\)' "$RUNNER"
_need "_kill_tree signals every pid in the subtree"   grep -qE '_kill_tree\(\) *\{' "$RUNNER"
_need "_kill_tree drives off _tree_pids"              grep -qE 'done < <\(_tree_pids "\$root"' "$RUNNER"
# BC-21: the runner itself must NEVER be signalled (its frozen exit code is preserved).
_need "_kill_tree ALWAYS skips \$\$ (never signal the runner)" \
      grep -qE '\[\[ -n "\$p" && "\$p" != "\$\$" \]\] \|\| continue' "$RUNNER"
_emit
H_cleanup

# ── B · staged, BOUNDED escalation of the subtree (first_sig → grace → SIGKILL) ─
H_init_test bc44tree-bounded-staged-reap
_expect "BC-44" "§14" "_reap_tree does a BOUNDED staged first_sig→grace-poll→SIGKILL of a child subtree (no unbounded wait on a SIGTERM-ignoring worker) (runner.sh)"
_need "_reap_tree defined"                            grep -qE '^_reap_tree\(\) *\{' "$RUNNER"
_need "_reap_tree sends the first signal to the subtree" grep -qE '_kill_tree "\$root" "\$first"' "$RUNNER"
_need "_reap_tree polls a bounded grace window"       grep -qE 'for \(\(i=0; i<grace; i\+\+\)\)' "$RUNNER"
_need "_reap_tree escalates survivors to SIGKILL"     grep -qE '_kill_tree "\$root" KILL' "$RUNNER"
_need "_reap_tree reaps the direct-child zombie"      grep -qE 'wait "\$root" 2>/dev/null \|\| true' "$RUNNER"
# v2 consciously does NOT self-issue a negative-PID process-group kill (that is the
# launcher's, not the dying process's — it would SIGKILL the runner mid-EXIT-trap
# and corrupt the frozen BC-21 code to 137). Assert the conscious absence.
_need "v2 does NOT self-issue a negative-PID 'kill -- -PID' group kill" \
      bash -c '! grep -qE "kill +-(TERM|KILL|[0-9]+) +-- +-\\\$" "'"$RUNNER"'"'
_emit
H_cleanup

# ── C · ONE EXIT-trap funnel reaps both subtrees on every exit path ────────────
H_init_test bc44tree-exit-trap-funnel
_expect "BC-44" "§14" "a single 'trap runner_teardown EXIT' funnel reaps worker(INT-first)+watchdog subtrees + sweeps strays on EVERY exit path (runner.sh)"
_need "trap runner_teardown EXIT installed"           grep -qE '^trap runner_teardown EXIT' "$RUNNER"
_need "teardown reaps the worker subtree (SIGINT first)" \
      grep -qE '_reap_tree "\$CLAUDE_PID" INT' "$RUNNER"
_need "teardown reaps the watchdog subtree"           grep -qE '_reap_tree "\$WATCHDOG_PID" TERM' "$RUNNER"
_need "teardown runs the attached-stray catch-all sweep" \
      grep -qE '^  _sweep_self' "$RUNNER"
_need "_sweep_self TERM-then-KILLs the still-attached \$\$ subtree" \
      bash -c 'awk "/^_sweep_self\\(\\) \\{/,/^\\}/" "'"$RUNNER"'" | grep -qE "_kill_tree \"\\\$\\\$\" (TERM|KILL)"'
_need "teardown is idempotent (single-fire latch)"    grep -qE '_TEARDOWN_DONE' "$RUNNER"
# Signal path shares the SAME teardown (BC-36 symmetry): _on_signal exit ⇒ EXIT trap.
_need "INT/TERM/HUP routed through _on_signal (shares the EXIT funnel)" \
      grep -qE '^trap _on_signal INT TERM HUP' "$RUNNER"
_emit
H_cleanup

# ── D · behavioral sanity: a normal run exits cleanly, no hang ─────────────────
H_init_test bc44tree-clean-exit-no-hang
bd_seed T1 "task one" "do a thing"
claude_plan success
run_runner
_expect "BC-44" "§14" "after a normal run the runner exited cleanly via the teardown funnel (no hang; subtree reaped) — RUN_EXIT not the 124 backstop"
_need "T1 closed"                                     test "$(bd_status T1)" = closed
_need "runner exited (not the harness 124 wall-clock backstop)" test "${RUN_EXIT:-124}" -ne 124
_need "teardown Results line printed (funnel ran)"    matches "$(out)" "runner: Results: [0-9]+ completed / [0-9]+ processed"
_emit
H_cleanup
