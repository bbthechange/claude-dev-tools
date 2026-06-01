#!/bin/bash
# BC-37 — per-project override seam: PROMPT_EXTRA append, project .beads/runner.sh
#         source, env-overridable knobs, and the --yolo escape hatch
#         (v2 -tree coverage-hardening, claude-tools-v2cut.5)
#
# PROVES (mix of black-box + source-structural):
#  (a) BEHAVIORAL — `export PROMPT_EXTRA=<marker>` makes the marker appear in the
#      worker prompt (runner.sh ~525-529: appended AFTER token substitution).
#  (b) SOURCE     — v2 sources a project `.beads/runner.sh` after defaults
#      (runner.sh ~200-203) so a project can override PERMISSION_FLAGS /
#      EXTRA_CLAUDE_FLAGS / PROMPT_EXTRA / DEFAULT_MODEL / the MAX_* knobs.
#  (c) BEHAVIORAL — a project `.beads/runner.sh` setting PROMPT_EXTRA actually
#      reaches the worker prompt (the source seam wired end-to-end).
#  (d) SOURCE     — env-overridable knobs use the `${VAR:-default}` idiom
#      (MAX_RETRIES, MAX_CONSECUTIVE_FAILURES, DEFAULT_MODEL).
#
# V1↔V2 PARITY (claude-tools-92l3 — the --yolo half is now PORTED + regression-locked):
#  v1 run-beads-tasks.sh parses a first-arg `--yolo` → PERMISSION_FLAGS becomes
#  `(--dangerously-skip-permissions)` + the run is relabelled "all permissions
#  bypassed" (v1 lines 292-294). v2 runner.sh now parses the same first-arg
#  `--yolo` at MODULE scope (the dispatch loop calls st_* with no args, so $1 is
#  the runner's own first positional), AFTER the project `.beads/runner.sh`
#  source so --yolo wins, and YOLO=1 suppresses the opus→`--permission-mode auto`
#  override so the bypass flows through. Asserted below as a real `_expect`
#  regression-lock (was a FORWARD `_gate` while unported — the bc-58 precedent:
#  a ported v2 fix earns a hard assertion, not a never-FAIL gate).
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"   # repoint to v2
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

argv_text() { cat "$HARNESS_OUT/last-argv.txt" 2>/dev/null || true; }

# ── (a) PROMPT_EXTRA via env reaches the worker prompt ───────────────────────
H_init_test bc37tree-promptextra-env
bd_seed T1 "task one" "do a thing"
claude_plan success
export PROMPT_EXTRA="ZZ_MARKER_123_envextra"
run_runner
_expect "BC-37" "§452" "env PROMPT_EXTRA is appended to the worker prompt (runner.sh ~526)"
_need "worker spawned (T1 closed)"                    test "$(bd_status T1)" = closed
_need "prompt contains the PROMPT_EXTRA marker"       contains "$(prompt_text)" "ZZ_MARKER_123_envextra"
_emit
unset PROMPT_EXTRA
H_cleanup

# ── (b)+(c) project .beads/runner.sh is sourced; its PROMPT_EXTRA wins ────────
H_init_test bc37tree-project-config-source
bd_seed T1 "task one" "do a thing"
claude_plan success
# Drop a project config the runner must source after defaults. It sets a marker
# PROMPT_EXTRA — observable in the worker prompt only if the source seam fires.
mkdir -p "$WORKDIR/.beads"
cat > "$WORKDIR/.beads/runner.sh" <<'CFG'
PROMPT_EXTRA="ZZ_PROJECT_CFG_MARKER_456"
MAX_RETRIES=5
CFG
run_runner
_expect "BC-37" "§452" "v2 sources project .beads/runner.sh after defaults; its PROMPT_EXTRA reaches the worker (runner.sh ~200,526)"
_need "worker spawned (T1 closed)"                    test "$(bd_status T1)" = closed
_need "prompt carries the PROJECT-CONFIG PROMPT_EXTRA marker (source seam fired)" \
                                                      contains "$(prompt_text)" "ZZ_PROJECT_CFG_MARKER_456"
# Source-structural — the config-source block exists and is `[[ -f ]]`-guarded.
_need "runner.sh sources .beads/runner.sh"            grep -qE 'source[[:space:]]+\.beads/runner\.sh' "$RUNNER"
_need "the source is guarded by an [[ -f .beads/runner.sh ]] test" \
      grep -qE '\[\[ -f \.beads/runner\.sh \]\]' "$RUNNER"
_emit
H_cleanup

# ── (d) env-overridable knobs use the ${VAR:-default} idiom (source-structural) ─
H_init_test bc37tree-env-knob-idiom
bd_seed T1 "task one" "do a thing"
claude_plan success
run_runner   # just to exercise a clean run; the asserts below are source-structural
_expect "BC-37" "§452" "env-overridable knobs use \${VAR:-default} so a project/env can override (runner.sh ~144,165,166)"
_need "MAX_RETRIES is \${MAX_RETRIES:-N}"             grep -qE 'MAX_RETRIES="\$\{MAX_RETRIES:-[0-9]+\}"' "$RUNNER"
_need "MAX_CONSECUTIVE_FAILURES is \${..:-N}"         grep -qE 'MAX_CONSECUTIVE_FAILURES="\$\{MAX_CONSECUTIVE_FAILURES:-[0-9]+\}"' "$RUNNER"
_need "DEFAULT_MODEL is \${DEFAULT_MODEL:-...}"       grep -qE 'DEFAULT_MODEL="\$\{DEFAULT_MODEL:-' "$RUNNER"
_emit
H_cleanup

# ── --yolo escape hatch — PORTED to v2 + regression-locked (claude-tools-92l3) ─
H_init_test bc37tree-yolo
bd_seed T1 "task one" "do a thing"
claude_plan success
run_runner --yolo                # v2 parses $1=="--yolo" at module scope
av="$(argv_text)"
o="$(out)"
_expect "BC-37" "§452" "--yolo ⇒ --dangerously-skip-permissions in the worker argv + run relabelled 'all permissions bypassed'"
_need "worker spawned (T1 closed)"                    test "$(bd_status T1)" = closed
_need "claude argv carries --dangerously-skip-permissions under --yolo" \
                                                      contains "$av" "--dangerously-skip-permissions"
_need "--yolo wins: opus did NOT downgrade the bypass to --permission-mode auto" \
                                                      notcontains "$av" "--permission-mode"
_need "run relabelled 'all permissions bypassed'"     matches "$o" "all permissions bypassed"
_emit
H_cleanup
