#!/usr/bin/env bash
# beads-runner/lib/activity-classifier.sh
# Activity-state log→state classifier (I1 · claude-tools-uxvi1).
#
# Conforms to design/activity.md §1.2 (the precedence table) + UX-V2-ARCHITECTURE
# Contract D.2 (the CLOSED activity enum + the 90/180s liveness windows). This is
# the "sourceable classifier" the design calls for ("factor classifier into a
# sourceable lib, shared w/ I5") — a PURE function with NO LLM, NO side effects,
# and NO I/O: feed it the already-parsed event facts, get back one enum value +
# a blunt liveness dot. The runner-side tail-parse that extracts those facts from
# the claude `--output-format stream-json` stream, and the agent-activity-report
# publish, are claude-tools-uxvi1's remaining surface — this lib is the unit the
# table-driven conformance assertion (bc-uxvi1-activity-parser.sh) pins.
#
# Sourced with no side effects (safe under `set -euo pipefail`); defines
# functions + the two SPINE constants only.

# ── Contract D.2 SPINE constants — DO NOT TIGHTEN ────────────────────────────
# 90/180 are [spine] values, NOT tunables. Legitimate intra-task silence
# regularly hits 100–700s (the model thinking after a tool_result), so a 60s
# window false-fires ~56× (tmp/beads-log-visibility-findings.md). Tightening
# these re-introduces that flapping — must-protect #8 (TESTING-STRATEGY §3 R8).
# The DETECTOR sets below (test-runner / read-util patterns) are [free] and may
# grow; these two numbers may not shrink without re-measuring.
ACTIVITY_LIVENESS_AMBER_S=90      # [spine] <90s = green/live
ACTIVITY_LIVENESS_RED_S=180       # [spine] >180s = red/maybe-stuck
ACTIVITY_STATE_CONFIDENCE="derived"   # D.2 — every derived state is "derived", never asserted

# ── detector sets ([free] — add patterns freely; the enum stays closed) ──────
# A Bash command is a TEST RUN if it matches this (→ running-tests), else it is
# treated as exploration (→ exploring). Grows freely per ARCH §8.
_ACTIVITY_TEST_RE='(^|[[:space:]/])(npm[[:space:]]+(run[[:space:]]+)?test|yarn[[:space:]]+test|pnpm[[:space:]]+test|vitest|jest|mocha|pytest|py\.test|tox|go[[:space:]]+test|cargo[[:space:]]+test|rspec|bats|ctest|gradle[[:space:]]+test|mvn[[:space:]]+test|make[[:space:]]+(test|check)|run-tests\.sh|run-conformance\.sh|\.sh[[:space:]]+--tier)'

# activity_liveness_dot <delta_secs> → green | amber | red
# Computed from the heartbeat ALONE (D.2): never overridden by a state guess, so
# the dot stays honest even when the regex set misses a new tool.
activity_liveness_dot() {
  local d="${1:-0}"
  case "$d" in ''|*[!0-9]*) d=0 ;; esac
  if   [[ "$d" -gt "$ACTIVITY_LIVENESS_RED_S"   ]]; then printf 'red'
  elif [[ "$d" -ge "$ACTIVITY_LIVENESS_AMBER_S" ]]; then printf 'amber'
  else                                                   printf 'green'
  fi
}

# activity_state_confidence → always "derived" (D.2 — nothing semantic asserted)
activity_state_confidence() { printf '%s' "$ACTIVITY_STATE_CONFIDENCE"; }

# activity_classify_state <delta_secs> <last_tool> <askbrian_inflight 0|1> \
#                         <rate_limited 0|1> [bash_cmd]
# Returns one of the 7 CLOSED D.2 states on stdout. Derivation is the
# design/activity.md §1.2 precedence — silence-gated FIRST (a stale "writing-code"
# must never outlive the agent that stopped), with the two overrides (waiting /
# rate-limited) ABOVE the silence gate:
#   1 ask-brian MCP call in flight, no result   → waiting-on-you   (suppresses maybe-stuck)
#   2 a real 429 in flight                       → rate-limited
#   3 Δ > 180s                                   → maybe-stuck
#   4 Δ ∈ [90s,180s]                             → thinking
#   5 last tool ∈ Edit/Write/MultiEdit           → writing-code
#   6 last tool Bash matching a test runner       → running-tests
#   7 last tool ∈ Read/Grep/Glob | other Bash     → exploring
#   8 otherwise (recent non-tool assistant text)  → thinking (soft)
activity_classify_state() {
  local delta="${1:-0}" tool="${2:-}" askbrian="${3:-0}" ratelimited="${4:-0}" bashcmd="${5:-}"
  case "$delta" in ''|*[!0-9]*) delta=0 ;; esac

  # 1 + 2 — the two overrides that win over the silence gate.
  [[ "$askbrian" == "1" ]]    && { printf 'waiting-on-you'; return; }
  [[ "$ratelimited" == "1" ]] && { printf 'rate-limited';   return; }

  # 3 + 4 — silence gate (wins over event-keyed tool state).
  if [[ "$delta" -gt "$ACTIVITY_LIVENESS_RED_S" ]]; then printf 'maybe-stuck'; return; fi
  if [[ "$delta" -ge "$ACTIVITY_LIVENESS_AMBER_S" ]]; then printf 'thinking'; return; fi

  # 5/6/7 — event-keyed (only reached when live, Δ<90s).
  case "$tool" in
    Edit|Write|MultiEdit|NotebookEdit)
      printf 'writing-code'; return ;;
    Bash)
      if [[ -n "$bashcmd" ]] && printf '%s' "$bashcmd" | grep -qE "$_ACTIVITY_TEST_RE"; then
        printf 'running-tests'; return
      fi
      printf 'exploring'; return ;;     # non-test Bash = operational/exploratory
    Read|Grep|Glob|LS|WebFetch|WebSearch)
      printf 'exploring'; return ;;
  esac

  # 8 — recent non-tool assistant text (or an unrecognized tool): soft thinking.
  printf 'thinking'
}
