#!/bin/bash
# BC-42 — typed fail-open posture: degrade()/safe_capture() primitives + guarded
#         seams replace v1's blanket `set -e`+`|| true` suppression
#         (v2 -tree coverage-hardening, claude-tools-v2cut.5)
#
# Binds: BEHAVIORAL-CONTRACT.md §21 BC-42. v2 declares the posture UP FRONT
# (`set -uo pipefail` — NO `-e`) and routes every fallible external call through
# `safe_capture`, which classifies a failure into a typed degradation KIND, emits
# ONE visible `degrade: <KIND> — <msg>` line (never silent), yields a
# caller-chosen fallback, and ALWAYS returns 0 so the loop cannot abort. The
# CALLER then branches on the fallback EXPLICITLY — that explicit branch, not the
# suppression, IS the posture. This contrasts v1's BC-42 SCAFFOLDING (blanket
# `2>/dev/null || true` where a real failure is indistinguishable from "no
# result"). The two stub no-ops (la_heartbeat etc.) make the runtime degradation
# events un-observable black-box, so the primitives' SHAPE is proven
# SOURCE-STRUCTURALLY against $RUNNER; a behavioral sanity block proves the
# posture does not crash a normal close.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
trap H_cleanup EXIT

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"   # repoint to v2
export RUNNER_TICK=1 CONTROL_POLL_INTERVAL=999 HEARTBEAT_INTERVAL=999 \
       RECLAIM_POLL_INTERVAL=1

# ── A · the typed degradation PRIMITIVES exist with the documented shape ───────
H_init_test bc42tree-primitives
_expect "BC-42" "§21" "degrade()/safe_capture() typed fail-open primitives defined with the documented shape (runner.sh)"
# NO `set -e` — the posture's root: a transient bd/IO hiccup must not abort the
# loop via -e; v2 uses `set -uo pipefail` instead and handles failures explicitly.
_need "v2 declares 'set -uo pipefail' (NO -e)"      grep -qE '^set -uo pipefail' "$RUNNER"
_need "v2 does NOT run 'set -euo pipefail'"          bash -c '! grep -qE "^set -euo pipefail" "'"$RUNNER"'"'
_need "degrade() defined"                            grep -qE '^degrade\(\) *\{' "$RUNNER"
# degrade emits exactly one visible typed line `degrade: <KIND> — <msg>` to stderr.
_need "degrade emits a typed 'degrade:' line to stderr" \
      grep -qE 'degrade\(\) *\{ *echo "degrade: \$1 — \$2" >&2; *\}' "$RUNNER"
_need "safe_capture() defined"                       grep -qE '^safe_capture\(\) *\{' "$RUNNER"
# safe_capture runs cmd; on nonzero rc it emits degrade + echoes the fallback + returns 0.
_need "safe_capture runs the cmd and captures rc"    grep -qE 'out="\$\("\$@" 2>/dev/null\)"; *rc=\$\?' "$RUNNER"
_need "safe_capture emits degrade on failure"        grep -qE 'degrade "\$kind"' "$RUNNER"
_need "safe_capture echoes the caller-chosen fallback on failure" \
      grep -qE "printf '%s' \"\\\$fallback\"" "$RUNNER"
_need "safe_capture ALWAYS returns 0 (loop must not abort)" \
      bash -c 'awk "/^safe_capture\\(\\) \\{/,/^\\}/" "'"$RUNNER"'" | grep -qE "^  return 0$"'
_emit
H_cleanup

# ── B · representative GUARDED seams exist (the posture applied at call sites) ──
H_init_test bc42tree-guarded-seams
_expect "BC-42" "§21" "representative guarded seams present: command-v guards, safe_capture call sites, unset-safe array expansion (runner.sh)"
# `command -v X || return 0` — a missing optional binary degrades to skip, not crash.
_need "command -v <tool> || return 0 guard present" \
      grep -qE 'command -v [A-Za-z_]+ >/dev/null 2>&1 *(\|\| *return 0|; *then|&&)' "$RUNNER"
_need "at least one bare 'command -v ... ; then' guarded seam" \
      grep -qE 'if (! )?command -v ' "$RUNNER"
# safe_capture is actually USED at the load-bearing bd/coordination seams, not just defined.
_need "safe_capture used to guard a bd update (reset-to-open seam)" \
      grep -qE 'safe_capture BD_UNAVAILABLE "" -- bd update' "$RUNNER"
_need "safe_capture used to guard the desired-state reconcile seam" \
      grep -qE 'safe_capture COORD_UNREACHABLE running -- job_reconcile_desired' "$RUNNER"
# `${arr[@]+"${arr[@]}"}` — the set -u-safe expansion of a possibly-empty array.
_need "unset-safe array expansion idiom present" \
      grep -qE '\$\{[A-Za-z_]+\[@\]\+"\$\{[A-Za-z_]+\[@\]\}"\}' "$RUNNER"
# `|| true` still appears as a representative IO guard (BC-42 lists it among the idioms).
_need "|| true representative IO guard present"      grep -qE '\|\| true' "$RUNNER"
_emit
H_cleanup

# ── C · behavioral sanity: the posture does NOT crash a normal close ───────────
H_init_test bc42tree-normal-close-survives
bd_seed T1 "task one" "do a thing"
claude_plan success
run_runner
_expect "BC-42" "§21" "the typed fail-open posture does not crash the loop: a normal task still closes and the runner drains exit 0"
_need "T1 closed (loop ran end-to-end)"              test "$(bd_status T1)" = closed
_need "runner drained exit 0 (no posture-induced abort)" test "${RUN_EXIT:-1}" -eq 0
_emit
H_cleanup
