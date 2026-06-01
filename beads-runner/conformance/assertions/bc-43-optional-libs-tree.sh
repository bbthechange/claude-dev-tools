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
run_runner
_expect "BC-43" "§15" "absent coordination tier (default stub path) ⇒ a seeded task still processes to closed unchanged; runner drains exit 0"
_need "T1 closed (core behaviour unchanged on the standalone path)" test "$(bd_status T1)" = closed
_need "runner drained exit 0"                        test "${RUN_EXIT:-1}" -eq 0
_need "no backend-unknown degrade emitted (stub default chosen cleanly)" \
      notcontains "$(out)" "BACKEND_UNKNOWN"
_emit
H_cleanup
