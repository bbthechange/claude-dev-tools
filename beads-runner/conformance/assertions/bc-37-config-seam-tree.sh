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
# V2-VS-V1 GAP (asserted as a FORWARD _gate so it never FAILs the suite):
#  v1 run-beads-tasks.sh parses a first-arg `--yolo` → PERMISSION_FLAGS becomes
#  `(--dangerously-skip-permissions)` + the run is relabelled "all permissions
#  bypassed" (v1 lines 292-294). v2 runner.sh's STATE dispatch loop (~2542)
#  calls the st_* functions with NO args and has NO `--yolo` / no
#  `--dangerously-skip-permissions` parsing anywhere — the BC-37 §"First arg
#  --yolo" surface is NOT yet ported. The _gate below documents that as the
#  close-criterion the v2c cutover must flip GREEN; it is NOT a regression.
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

# ── FORWARD GATE — the --yolo escape hatch (v2 has NOT ported it; see header) ──
H_init_test bc37tree-yolo-forward
bd_seed T1 "task one" "do a thing"
claude_plan success
run_runner --yolo                # v2 ignores the arg (dispatch loop passes none on)
av="$(argv_text)"
o="$(out)"
_gate "BC-37" "§452" "FORWARD: --yolo ⇒ --dangerously-skip-permissions + 'all permissions bypassed' (v1 ports; v2 not yet)"
# These two will be UNMET on v2 (GATE-PENDING, never FAIL) until --yolo is ported.
_need "claude argv carries --dangerously-skip-permissions under --yolo" \
                                                      contains "$av" "--dangerously-skip-permissions"
_need "run relabelled 'all permissions bypassed'"     matches "$o" "all permissions bypassed"
_emit
H_cleanup
