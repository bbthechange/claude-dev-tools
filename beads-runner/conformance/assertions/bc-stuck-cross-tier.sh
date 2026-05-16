#!/bin/bash
# STUCK_NEEDS_HUMAN — cross-tier END-TO-END (worker-path AND backstop).
# Binds: INTERFACE.md v1 §7.2 (two independent triggers) + §7.3 (a fired
#        backstop MUST itself drive the bead to blocked-for-human).
# GATES: T5 (Dossier DO / per-Item routing) and T2 (classifier + backstop).
#
# ANTI-OVERLAP (binding): T1a owns the classification-STRING surface — bc-10-11
# (§7.1 STUCK slot in the precedence chain) and bc-13-14 (§7.5 breaker/retry
# exemption). This rig deliberately asserts a DIFFERENT surface: the cross-tier
# OUTCOME — the bead must END blocked-for-human (NOT reset to open), `bd human`
# must be honored, for BOTH the instructed worker path (§7.2 primary) and the
# zero-model-trust runner backstop (§7.2 permission_denials / "Entered plan
# mode." + §7.3 backstop-drives-bead). It does NOT re-assert §7.1/§7.5.
#
# All are forward GATEs: the current single-process script has no STUCK class
# and no backstop scan, so each is correctly GATE-PENDING pre-rewrite — the
# literal close-criterion T2/T5 must flip to GATE-MET.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

# ── §7.2 PRIMARY (worker-driven, instructed) ─────────────────────────────────
# Worker does the prescribed sequence: bd status=blocked → bd human → exit
# WORKER_STUCK_EXIT. Today: exit 7 → UNKNOWN_FAILURE → bead RESET to open
# (the human flag rots), counts toward breaker. Post-T2/T5: STUCK_NEEDS_HUMAN,
# bead STAYS blocked-for-human, runner continues.
H_init_test stuck-worker-path
bd_seed T1 "needs a human decision" "x"
claude_plan stuck_primary success
run_runner
_gate "STUCK-e2e" "§7.2" "worker-path STUCK ⇒ bead STAYS blocked-for-human (gates T5)"
_need "post-T5: bead ends 'blocked', NOT reset to open" test "$(bd_status T1)" = blocked
_need "post-T5: classified STUCK_NEEDS_HUMAN, not UNKNOWN" inc_has T1 STUCK_NEEDS_HUMAN
_need "bd human flag preserved (not clobbered by re-open)" contains "$(bd_human_log)" "T1"
_emit
H_cleanup

# ── §7.2 BACKSTOP A — permission_denials[] (zero model trust) ─────────────────
# Worker SLIPPED: false exit-0/is_error:false, bead NOT closed, but final
# result carries permission_denials[AskUserQuestion]. Today: exit 0 + bead
# open → TASK_NOT_CLOSED (the deceit succeeds). Post-T2: the backstop OVERRIDES
# the false success ⇒ STUCK_NEEDS_HUMAN, and (§7.3) itself drives the bead.
H_init_test stuck-backstop-permission-denials
bd_seed T1 "slipped via AskUserQuestion" "x"
claude_plan stuck_backstop_pd success
run_runner
_gate "STUCK-e2e" "§7.2" "permission_denials backstop OVERRIDES false exit-0 ⇒ STUCK (gates T2)"
_need "post-T2: classified STUCK_NEEDS_HUMAN (not TASK_NOT_CLOSED)" inc_has T1 STUCK_NEEDS_HUMAN
_need "post-T2: §7.3 backstop drove bead to blocked"               test "$(bd_status T1)" = blocked
_need "post-T2: §7.3 backstop raised bd human"                     contains "$(bd_human_log)" "T1"
_emit
H_cleanup

# ── §7.2 BACKSTOP B — "Entered plan mode." silent-no-op residual gap ──────────
# The EnterPlanMode no-op the research flags: a "Entered plan mode." tool_result
# in the stream, false exit-0, bead not closed. Same required outcome.
H_init_test stuck-backstop-entered-plan-mode
bd_seed T1 "slipped via EnterPlanMode" "x"
claude_plan stuck_backstop_plan success
run_runner
_gate "STUCK-e2e" "§7.2" "'Entered plan mode.' stream backstop ⇒ STUCK + bead driven (gates T2)"
_need "post-T2: classified STUCK_NEEDS_HUMAN"        inc_has T1 STUCK_NEEDS_HUMAN
_need "post-T2: §7.3 backstop drove bead to blocked" test "$(bd_status T1)" = blocked
_need "post-T2: §7.3 backstop raised bd human"       contains "$(bd_human_log)" "T1"
_emit
H_cleanup
