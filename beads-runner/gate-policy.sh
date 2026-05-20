#!/usr/bin/env bash
# beads-runner/gate-policy.sh — pickup-time gate-policy lookup
# (L2, claude-tools-1tu; epic claude-tools-kie).
#
# WHAT THIS IS (DESIGN.md §5 C1 S-3, agents/gate-policy.md table):
#   The runner's one chokepoint for the question "may I auto-pick this bead
#   up, or does it need to surface to Brian first?" L2's MINIMUM HONEST
#   REALIZATION of autonomous-until-stuck: transitions auto-advance by
#   default; the only pickup-time gate is the explicit `collaborative-stage`
#   preset. (The other two GATE points — worker STUCK_NEEDS_HUMAN and the
#   proactive design-checkpoint FYI — are runtime / observer paths, not
#   pickup gates. See agents/gate-policy.md for the full bounding.)
#
#   Keyed by (stage, preset) read from the bead's `bd label list`. Stage is
#   the L1 `stage:<value>` convention (bd-stage.sh); preset is the
#   `preset:<value>` convention this script introduces (the enricher S3,
#   claude-tools-bnq, sets it on intake). Absence of any `preset:*` label
#   is treated as `autonomous-until-stuck` so the common case stays quiet.
#
# USAGE:
#   gate-policy.sh decide <bead-id>
#     Prints exactly one of:
#       auto-advance
#       gate-human:collaborative-stage
#     Exit 0 on a clean verdict; exit 4 on a bd-subprocess failure (the
#     runner treats this as "do not pick up" — fail-CLOSED on the gate, the
#     opposite of capacity which fails OPEN).
#
#   gate-policy.sh explain <bead-id>
#     Same lookup, but prints a human-readable one-liner for logs / notes.
#
# EXIT CODES:
#   0  clean verdict printed
#   2  usage error (bad args)
#   4  bd subprocess failure (caller must treat as gate-human, fail-CLOSED)
#
# Safe under `set -uo pipefail`; every bd call is guarded.

set -uo pipefail

# ── known preset enum ────────────────────────────────────────────────────────
# Closed for v1, same as STAGE_ENUM in bd-stage.sh — adding a preset = adding
# a row in agents/gate-policy.md and a branch in _decide_from_stage_preset.
PRESET_ENUM=(autonomous-until-stuck collaborative-stage)

# Same canonical stage enum as bd-stage.sh; duplicated here intentionally so
# the gate script is consultable WITHOUT sourcing bd-stage (kept as two small
# scripts, not one monolith — bd-stage.sh is L1, gate-policy.sh is L2; the
# enums must agree, the test-gate-policy.sh harness asserts that).
STAGE_ENUM=(idea ux design impl docs tests done)

usage() {
  cat <<'EOF'
gate-policy.sh — pickup-time gate-policy lookup (L2, claude-tools-1tu)

Usage:
  gate-policy.sh decide  <bead-id>   print one of: auto-advance | gate-human:<reason>
  gate-policy.sh explain <bead-id>   print a human-readable one-liner for logs

Verdicts:
  auto-advance                       runner picks the bead up and runs it
  gate-human:collaborative-stage     bead has preset:collaborative-stage —
                                     surface as "ready to pair on <title>"
                                     in the Inbox, do not run

Exit codes:
  0  clean verdict printed
  2  usage error
  4  bd subprocess failure (caller MUST treat as gate-human; fail-CLOSED)
EOF
}

# Print every label currently on <bead>, one per line. Empty = no labels.
# Returns 4 on bd subprocess failure (the caller is the only one who knows
# what to do — typically fail-CLOSED).
_labels_of() {
  local bead="$1" out
  out=$(bd label list "$bead" --json 2>/dev/null) || return 4
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$out" | jq -r '.[]' 2>/dev/null
  else
    # Tolerant fallback: pull each quoted string from the flat array.
    printf '%s' "$out" \
      | tr ',' '\n' \
      | grep -oE '"[a-zA-Z0-9_:-]+"' \
      | tr -d '"'
  fi
}

# Extract the stage and preset values from a newline-separated label list.
# Stage: the bare value after `stage:` (empty if unstaged).
# Preset: the bare value after `preset:` (empty if no preset label, which is
# treated as the default `autonomous-until-stuck` downstream).
# If multiple stage:* labels are present (an L1 invariant violation), this
# script does NOT try to heal — it prints the FIRST one (stable for the
# fail-CLOSED verdict below) and lets bd-stage.sh own the heal path.
_extract_stage()  { grep -m1 '^stage:'  <<< "$1" | sed 's/^stage://';  }
_extract_preset() { grep -m1 '^preset:' <<< "$1" | sed 's/^preset://'; }

# The decision table — agents/gate-policy.md is the source of truth; this is
# the executable mirror. Inputs: stage (may be empty for legacy/unstaged),
# preset (may be empty — treated as the default autonomous-until-stuck).
# Output: prints the verdict on stdout, returns 0.
_decide_from_stage_preset() {
  local stage="$1" preset="$2"

  # Default-on-absence: no preset label ⇒ autonomous-until-stuck (the common
  # case kept quiet by the enricher — see agents/gate-policy.md).
  [[ -z "$preset" ]] && preset="autonomous-until-stuck"

  # An unknown preset is a future-proofing fork the v1 script will NOT
  # resolve silently. Fail-CLOSED with a typed verdict the runner can log
  # and surface; treat as gate-human so a typo in the enricher cannot
  # quietly skip Brian. (PRESET_ENUM is the closed v1 set.)
  local known=0 p
  for p in "${PRESET_ENUM[@]}"; do
    [[ "$p" == "$preset" ]] && { known=1; break; }
  done
  if [[ $known -eq 0 ]]; then
    printf 'gate-human:unknown-preset\n'
    return 0
  fi

  # The v1 table (agents/gate-policy.md):
  #   autonomous-until-stuck → auto-advance at every stage, including
  #     legacy/unstaged beads (so the runner does not strand them).
  #   collaborative-stage    → gate-human at every stage (the human asked to
  #     be IN the stage, not just approve its output).
  #
  # `done` is terminal; a bead at `stage:done` should not be in `bd ready`
  # (it is closed). If one does land here (corrupt state), we still answer
  # honestly: auto-advance for autonomous, gate for collaborative — the
  # runner will pick it up and the worker is supposed to recognize "already
  # done" without further harm. Not a v1 gate's job to second-guess.
  case "$preset" in
    autonomous-until-stuck) printf 'auto-advance\n' ;;
    collaborative-stage)    printf 'gate-human:collaborative-stage\n' ;;
  esac

  # `stage` is read but not yet used to BRANCH the verdict — the v1 table is
  # uniform across all stages. Kept in the signature (and asserted by the
  # test harness) so a future row that varies by stage has the seam ready
  # without a callsite refactor.
  : "${stage:-}"
}

cmd_decide() {
  local bead="${1:-}"
  [[ -n "$bead" ]] || { echo "gate-policy decide: reject — bead id required" >&2; usage >&2; exit 2; }

  local labels stage preset
  labels=$(_labels_of "$bead") || {
    # bd failed — fail-CLOSED on the gate (the opposite of capacity, which
    # fails OPEN per §6.2). A gate we cannot evaluate is treated as needing
    # human attention; the runner logs and continues to the next candidate.
    echo "gate-policy decide: reject — bd label list failed for '$bead'" >&2
    printf 'gate-human:bd-unavailable\n'
    exit 4
  }
  stage=$(_extract_stage  "$labels")
  preset=$(_extract_preset "$labels")
  _decide_from_stage_preset "$stage" "$preset"
}

cmd_explain() {
  local bead="${1:-}"
  [[ -n "$bead" ]] || { echo "gate-policy explain: reject — bead id required" >&2; usage >&2; exit 2; }

  local labels stage preset verdict
  labels=$(_labels_of "$bead") || {
    echo "gate-policy explain: reject — bd label list failed for '$bead'" >&2
    printf '%s: bd-unavailable — fail-CLOSED (treat as gate-human)\n' "$bead"
    exit 4
  }
  stage=$(_extract_stage  "$labels")
  preset=$(_extract_preset "$labels")
  verdict=$(_decide_from_stage_preset "$stage" "$preset")

  local stage_show="${stage:-unstaged}" preset_show="${preset:-autonomous-until-stuck (default)}"
  printf '%s: stage=%s preset=%s -> %s\n' "$bead" "$stage_show" "$preset_show" "$verdict"
}

# ── dispatch ─────────────────────────────────────────────────────────────────
CMD="${1:-}"
[[ -n "$CMD" ]] || { usage >&2; exit 2; }
shift || true

case "$CMD" in
  decide)     cmd_decide  "$@" ;;
  explain)    cmd_explain "$@" ;;
  -h|--help)  usage; exit 0 ;;
  *) echo "gate-policy: reject — unknown subcommand '$CMD'" >&2; usage >&2; exit 2 ;;
esac
