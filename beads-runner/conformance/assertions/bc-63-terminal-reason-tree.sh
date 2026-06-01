#!/bin/bash
# BC-63 — terminal-reason telemetry mirrors the BC-21 exit codes (the
#         heartbeat-absence "why did it stop" channel)
#         (v2 -tree coverage-hardening, claude-tools-v2cut.5)
#
# Binds: BEHAVIORAL-CONTRACT.md §9 BC-63. At every terminal path the runner fires
# a guarded `la_report_terminal_reason <REASON> <code> <task_id> <project_ref>`
# (the "last durable control-plane write before exit") whose REASON/code pair
# MIRRORS the BC-21 exit table: INTERRUPTED/1, CIRCUIT_BREAKER/2, AUTH_FAILURE/3,
# BILLING_ERROR/4, CLEAN/0 (drain/stop), and STUCK_NEEDS_HUMAN (no code — the
# loop continues). In the harness the backend is the STUB, whose
# la_report_terminal_reason is a NO-OP (return 0, no side effect) ⇒ the telemetry
# record is NOT observable black-box. So BC-63 is proven SOURCE-STRUCTURALLY:
# the two job_report_terminal call sites exist AND each TERMINAL_CLASS/EXIT_CODE
# pair that flows into them matches the frozen BC-21 row, so the telemetry
# REASON/code can only ever mirror the exit code.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"   # repoint to v2

# ── A · the terminal-reason JOB + its two call sites exist ─────────────────────
H_init_test bc63tree-call-sites
_expect "BC-63" "§9" "job_report_terminal wraps la_report_terminal_reason and fires at the interrupt path AND the single terminal funnel (runner.sh)"
_need "job_report_terminal wraps la_report_terminal_reason" \
      grep -qE 'job_report_terminal\(\) *\{ *la_report_terminal_reason ' "$RUNNER"
_need "passes <REASON> <code> <task_id> <project_ref> positionally" \
      grep -qE 'la_report_terminal_reason "\$1" "\$\{2:-\}" "\$\{3:-\}" "\$PROJECT_REF"' "$RUNNER"
# Interrupt path (INT/TERM/HUP) — fires INTERRUPTED 1 before exit (§8.2 row 1).
_need "interrupt path fires 'job_report_terminal INTERRUPTED 1'" \
      grep -qE 'job_report_terminal INTERRUPTED 1 ' "$RUNNER"
# The single terminal funnel (st_terminal) fires the decided class/code before exit.
_need "st_terminal fires job_report_terminal \"\$TERMINAL_CLASS\" \"\$EXIT_CODE\" (last durable write)" \
      grep -qE 'job_report_terminal "\$TERMINAL_CLASS" "\$EXIT_CODE" ""' "$RUNNER"
_emit
H_cleanup

# ── B · the REASON/exit pairs MIRROR the BC-21 exit table ──────────────────────
H_init_test bc63tree-reason-exit-mirror
_expect "BC-63" "§9" "each TERMINAL_CLASS/EXIT_CODE assignment flowing into the funnel mirrors a BC-21 row: INTERRUPTED/1, CIRCUIT_BREAKER/2, AUTH_FAILURE/3, BILLING_ERROR/4, CLEAN/0 (runner.sh)"
# Row 1 — INTERRUPTED / 1 (signal path, set before job_report_terminal INTERRUPTED 1).
_need "INTERRUPTED ⇒ EXIT_CODE=1"                     grep -qE 'EXIT_CODE=1; TERMINAL_CLASS="INTERRUPTED"' "$RUNNER"
# The three fatals route through _terminal_fatal <cls> <code>, which sets the pair.
_need "_terminal_fatal sets TERMINAL_CLASS=cls / EXIT_CODE=code (the mirror seam)" \
      grep -qE 'TERMINAL_CLASS="\$cls"; EXIT_CODE="\$code"' "$RUNNER"
# Row 2 — CIRCUIT_BREAKER / 2.
_need "CIRCUIT_BREAKER ⇒ code 2"                      grep -qE '_terminal_fatal CIRCUIT_BREAKER 2' "$RUNNER"
# Row 3 — AUTH_FAILURE / 3.
_need "AUTH_FAILURE ⇒ code 3"                         grep -qE '_terminal_fatal AUTH_FAILURE 3' "$RUNNER"
# Row 4 — BILLING_ERROR / 4.
_need "BILLING_ERROR ⇒ code 4"                        grep -qE '_terminal_fatal BILLING_ERROR 4' "$RUNNER"
# Row 0 — CLEAN / 0 (graceful drain + graceful stop both ⇒ class CLEAN, code 0).
_need "CLEAN ⇒ EXIT_CODE=0 (drain/stop)"              grep -qE 'TERMINAL_CLASS="CLEAN"; EXIT_CODE=0' "$RUNNER"
_emit
H_cleanup

# ── C · STUCK_NEEDS_HUMAN is the no-code reason (loop continues, no exit code) ──
H_init_test bc63tree-stuck-no-code
_expect "BC-63" "§9" "STUCK_NEEDS_HUMAN routes to blocked-for-human and continues the loop — it adds NO BC-21 exit code (the no-code terminal-reason) (runner.sh)"
# STUCK never goes through _terminal_fatal and never sets a fatal EXIT_CODE.
_need "STUCK_NEEDS_HUMAN drives blocked-for-human"    grep -qE '_drive_blocked_for_human ' "$RUNNER"
_need "STUCK_NEEDS_HUMAN never reaches _terminal_fatal (no exit code)" \
      bash -c '! grep -qE "_terminal_fatal STUCK" "'"$RUNNER"'"'
_need "STUCK is documented as adding no runner exit code (continues)" \
      grep -qE 'no retry, no breaker, no exit code' "$RUNNER"
_emit
H_cleanup

# ── D · stub la_report_terminal_reason is a NO-OP (so source-structural is correct) ─
H_init_test bc63tree-stub-noop-justifies-source
STUB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/local-agent-stub.sh"
_expect "BC-63" "§9" "the stub la_report_terminal_reason is a no-op (return 0, no side effect) — confirming the runtime telemetry is NOT observable black-box, so the mirror must be proven source-structurally (lib/local-agent-stub.sh)"
_need "stub defines la_report_terminal_reason"        grep -qE 'la_report_terminal_reason\(\)' "$STUB"
_need "stub la_report_terminal_reason returns 0 with no observable side effect" \
      bash -c 'b=$(awk "/la_report_terminal_reason\\(\\)/,/^\\}/" "'"$STUB"'"); grep -qE "^[[:space:]]*return 0$" <<<"$b" && ! grep -qE "(echo|printf|>>)" <<<"$b"'
_emit
H_cleanup
