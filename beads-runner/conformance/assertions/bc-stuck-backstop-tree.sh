#!/bin/bash
# STUCK §7.2(b)/§7.3 — RUNNER-SIDE backstop production (FORWARD). (T2.5,
#   claude-tools-kqn.)
# Binds: INTERFACE.md v1 §7.2 (two independent triggers — here the runner-side
#        zero-model-trust backstop) + §7.3 (a fired backstop MUST itself drive
#        the bead to blocked-for-human) + §7.2(a) primary (the worker sentinel
#        path must END blocked, never reset to open).
#
# TARGET — the §7.2(b) scan + §7.3 drive live in the forward rewrite target
# runner.sh. Same re-point precedent as the other -tree rigs.
#
# ANTI-OVERLAP (binding): this rig asserts the T2.5-owned PRODUCTION surface —
# (1) the backstop SCAN turns the version-pinned signals into the STUCK marker
# and (2) §7.3 the runner itself drives the bead. It does NOT re-assert the
# §7.1 precedence STRING or the §7.5 breaker/retry-exemption MECHANICS (those
# are bc-10-11-…-tree / bc-13-14-…-tree, T2.2-owned), and it does NOT duplicate
# the bc-stuck-cross-tier e2e (that GATE also binds T5's Dossier DO — T1b's).
# The single OUTCOME asserted here: a slipped/forked worker MUST end
# blocked-for-human with `bd human` raised, classified STUCK_NEEDS_HUMAN and
# never the false TASK_NOT_CLOSED — for the backstop AND the primary path.
#
# SCAR (silent-when-wrong): the worker slips the §7.6 guardrail, exits
# 0/is_error:false with the bead open — trusting that swallows a real human
# decision as "agent forgot to close" and the fork rots silently.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# ── §7.2(b) BACKSTOP A — result.permission_denials[AskUserQuestion] ───────────
# False exit-0/is_error:false, bead NOT closed, permission_denials on the final
# result. The runner backstop MUST override the false success ⇒ STUCK, and
# (§7.3) itself drive the bead to blocked + bd human.
H_init_test stuckbk-tree-permission-denials
bd_seed T1 "slipped via AskUserQuestion" "x"
claude_plan stuck_backstop_pd success
run_runner
_expect "STUCK-bk" "§7.2" "permission_denials backstop OVERRIDES false exit-0 ⇒ STUCK (runner.sh)"
_need "classified STUCK_NEEDS_HUMAN"                  inc_has T1 STUCK_NEEDS_HUMAN
_need "NOT the false TASK_NOT_CLOSED"                 inc_not T1 TASK_NOT_CLOSED
_need "§7.3 runner drove bead to blocked"             test "$(bd_status T1)" = blocked
_need "§7.3 runner raised bd human"                   contains "$(bd_human_log)" "T1"
_need "Runner: STUCK_NEEDS_HUMAN note appended"       matches "$(notes_of T1)" "Runner: STUCK_NEEDS_HUMAN at"
_need "STUCK did not stop the fleet (exit 0 drain)"   test "$RUN_EXIT" -eq 0
_emit
H_cleanup

# ── §7.2(b) BACKSTOP B — "Entered plan mode." silent-no-op residual ──────────
H_init_test stuckbk-tree-entered-plan-mode
bd_seed T1 "slipped via EnterPlanMode" "x"
claude_plan stuck_backstop_plan success
run_runner
_expect "STUCK-bk" "§7.2" "'Entered plan mode.' stream backstop ⇒ STUCK + §7.3 drive (runner.sh)"
_need "classified STUCK_NEEDS_HUMAN"                  inc_has T1 STUCK_NEEDS_HUMAN
_need "NOT the false TASK_NOT_CLOSED"                 inc_not T1 TASK_NOT_CLOSED
_need "§7.3 runner drove bead to blocked"             test "$(bd_status T1)" = blocked
_need "§7.3 runner raised bd human"                   contains "$(bd_human_log)" "T1"
_emit
H_cleanup

# ── §7.2(a) PRIMARY — worker sentinel path ENDS blocked, never reset open ────
# The instructed worker did status=blocked + bd human and exited
# WORKER_STUCK_EXIT(7). The runner MUST classify STUCK_NEEDS_HUMAN and the
# bead MUST stay blocked-for-human — NOT reset to `open` (the v1 SCAR where
# exit 7 → UNKNOWN → generic reopen clobbered the human flag).
H_init_test stuckbk-tree-primary
bd_seed T1 "needs a human decision" "x"
claude_plan stuck_primary success
run_runner
_expect "STUCK-bk" "§7.2" "worker-sentinel primary ⇒ STUCK, bead STAYS blocked (runner.sh)"
_need "classified STUCK_NEEDS_HUMAN"                  inc_has T1 STUCK_NEEDS_HUMAN
_need "bead ends blocked, not reset to open"          test "$(bd_status T1)" = blocked
_need "bead never reopened after blocked"             notcontains "$(audit_seq T1)" "blocked open"
_need "bd human flag preserved (not clobbered)"       contains "$(bd_human_log)" "T1"
_emit
H_cleanup
