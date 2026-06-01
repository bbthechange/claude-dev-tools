#!/bin/bash
# BC-43 — optional-lib standalone degradation: absent coordination tier ⇒ core
#         behaviour unchanged (v2 -tree coverage-hardening, claude-tools-v2cut.5)
#
# Binds: BEHAVIORAL-CONTRACT.md §15 BC-43. v2 realises the "standalone-degradation
# posture" through the RUNNER_BACKEND swap: it DEFAULTS to `stub` (so a bare
# workspace / the conformance harness runs the in-process stubs, never reaching
# for a coordination tier), and the stub path sources coordinator-stub +
# local-agent-stub. The remaining genuinely-optional libs (git-pin-main.sh,
# hooks/build-settings.sh) are `[[ -f ]]`-guarded so an absent lib degrades to a
# no-op stub instead of crashing. The harness run IS the stub/standalone path, so
# the behavioral block directly proves "absent coordination tier ⇒ a seeded task
# still processes to closed, unchanged"; the guarded seams are proven
# SOURCE-STRUCTURALLY against $RUNNER.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"   # repoint to v2
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# ── A · RUNNER_BACKEND defaults to stub; stub path sources the in-process stubs ─
H_init_test bc43tree-backend-default-stub
_expect "BC-43" "§15" "RUNNER_BACKEND defaults to 'stub' and the stub path sources coordinator-stub + local-agent-stub (the standalone path) (runner.sh)"
_need "RUNNER_BACKEND defaults to stub"              grep -qE 'RUNNER_BACKEND="\$\{RUNNER_BACKEND:-stub\}"' "$RUNNER"
_need "a stub) case arm exists"                       grep -qE '^  stub\)' "$RUNNER"
_need "stub path sources coordinator-stub.sh"        grep -qE 'source "\$RUNNER_DIR/lib/coordinator-stub.sh"' "$RUNNER"
_need "stub path sources local-agent-stub.sh"        grep -qE 'source "\$RUNNER_DIR/lib/local-agent-stub.sh"' "$RUNNER"
# An unknown backend degrades (typed `degrade:` line) and still falls back to the stubs.
_need "unknown backend degrades, never crashes"      grep -qE 'degrade: BACKEND_UNKNOWN' "$RUNNER"
_emit
H_cleanup

# ── B · the remaining optional libs are [[ -f ]]-guarded (absent ⇒ no-op stub) ──
H_init_test bc43tree-optional-guarded-seams
_expect "BC-43" "§15" "optional libs git-pin-main.sh + build-settings.sh are [[ -f ]]-guarded; PROJECT_REF defaults to basename pwd (runner.sh)"
_need "git-pin-main.sh sourced inside an [[ -f ]] guard" \
      grep -qE '\[\[ -f "\$RUNNER_DIR/lib/git-pin-main.sh" \]\]' "$RUNNER"
_need "pin_head_to_main has a default no-op stub (absent lib ⇒ no-op)" \
      grep -qE 'pin_head_to_main\(\) *\{ *:; *\}' "$RUNNER"
_need "hooks/build-settings.sh sourced inside an [[ -f ]] guard" \
      grep -qE '\[\[ -f "\$RUNNER_DIR/hooks/build-settings.sh" \]\]' "$RUNNER"
_need "build_hook_settings consumer is command-v-guarded (absent ⇒ no --settings)" \
      grep -qE 'command -v build_hook_settings >/dev/null 2>&1' "$RUNNER"
_need "PROJECT_REF defaults to basename \$(pwd) (standalone default)" \
      grep -qE 'PROJECT_REF="\$\{PROJECT_REF:-\$\(basename "\$\(pwd\)"\)\}"' "$RUNNER"
_emit
H_cleanup

# ── C · behavioral: the bare stub/standalone path processes a task UNCHANGED ────
H_init_test bc43tree-standalone-unchanged
bd_seed T1 "task one" "do a thing"
claude_plan success
# No COORDINATOR_URL, default RUNNER_BACKEND ⇒ the in-process stub/standalone path.
# ENFORCE the standalone precondition this section asserts: run-tests.sh scrubs
# COORDINATOR_URL before the tier, but a DIRECT subset run (run-conformance.sh
# bc-43, per README) on the operator/daemon host inherits the ambient
# COORDINATOR_URL and would trip the §D cutover-safety warning below — a false
# RED of the "stays silent standalone" check on exactly the production machine.
# Clear it here so "standalone" is real regardless of how the rig is invoked
# (claude-tools-v2c4).
unset COORDINATOR_URL COORDINATOR_TOKEN 2>/dev/null || true
run_runner
_expect "BC-43" "§15" "absent coordination tier (default stub path) ⇒ a seeded task still processes to closed unchanged; runner drains exit 0"
_need "T1 closed (core behaviour unchanged on the standalone path)" test "$(bd_status T1)" = closed
_need "runner drained exit 0"                        test "${RUN_EXIT:-1}" -eq 0
_need "no backend-unknown degrade emitted (stub default chosen cleanly)" \
      notcontains "$(out)" "BACKEND_UNKNOWN"
# The bare standalone path (no COORDINATOR_URL) must stay SILENT about the stub
# backend — the cutover-safety warning is for the hosted context only, and a
# false positive on every conformance/standalone run would train the operator
# to ignore it (claude-tools-v2c4).
_need "standalone stub path does NOT emit the hosted-stub warning (no false positive)" \
      notcontains "$(out)" "BACKEND_STUB_ON_HOSTED"
_emit
H_cleanup

# ── D · cutover safety: stub backend + hosted context ⇒ a LOUD warning ──────────
# claude-tools-v2c4. RUNNER_BACKEND=stub makes la_capacity_check a no-op (no 5h/7d
# ceiling). That is fine standalone (§C above proves it stays silent), but a
# runner WIRED to the hosted engine (COORDINATOR_URL set — the daemon/production
# path) on the stub backend is an accidental unguarded launch that can burn
# quota. Never-silent-degradation (claude-tools-18c): it must be HEARD. The
# daemon M3 spawn pins RUNNER_BACKEND=real, so this only fires on misconfig.
H_init_test bc43tree-stub-on-hosted-warning
_expect "BC-43" "§15" "RUNNER_BACKEND=stub + COORDINATOR_URL set ⇒ a loud BACKEND_STUB_ON_HOSTED degrade notice (cutover safety; the hosted/production path pins RUNNER_BACKEND=real) (runner.sh)"
_need "warning guarded on stub backend AND a set COORDINATOR_URL" \
      grep -qE '\[\[ "\$RUNNER_BACKEND" == "stub" && -n "\$\{COORDINATOR_URL:-\}" \]\]' "$RUNNER"
_need "warning carries the greppable BACKEND_STUB_ON_HOSTED degrade token" \
      grep -qE 'degrade: BACKEND_STUB_ON_HOSTED' "$RUNNER"
_need "warning names the missing usage ceiling + the RUNNER_BACKEND=real fix" \
      grep -qE 'Set RUNNER_BACKEND=real' "$RUNNER"
_emit
H_cleanup
