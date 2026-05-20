#!/usr/bin/env bash
# beads-runner/bd-stage.sh — lifecycle-stage label discipline for bd
# (L1, claude-tools-u6s; epic claude-tools-kie).
#
# WHAT THIS IS (DESIGN.md §5 C1 seam):
#   `stage` is the first-class enumerated field on every bead, realized on top
#   of `bd label` as the convention `stage:<value>` with the invariant that a
#   bead carries EXACTLY ONE stage label at any time (or none, for legacy
#   beads predating this convention). This script is the one chokepoint for
#   stage transitions — `bd-stage set` removes any existing stage:* label
#   before adding the new one, so the "exactly one" invariant cannot drift
#   even if a caller forgets to clear the old label.
#
#   The stage enum is closed: idea | ux | design | impl | docs | tests | done.
#   Adding a stage = updating STAGE_ENUM here and the gate-policy table (L2,
#   claude-tools-1tu) — never a freeform string.
#
#   See agents/lifecycle.md for the spine + the gate policy (which transitions
#   auto-advance vs. need Brian).
#
# USAGE:
#   bd-stage.sh set  <bead-id> <stage>   # transition: remove any prior stage:*, add stage:<new>
#   bd-stage.sh get  <bead-id>           # print current stage value (empty if unstaged)
#   bd-stage.sh list <stage>             # list bead ids carrying stage:<stage>
#
# EXIT CODES:
#   0  success
#   2  usage error (bad args, unknown stage)
#   3  invariant violation observed (e.g. a bead already carries >1 stage:* label —
#      `set` resolves this by removing them all before adding the new one, but
#      `get` reports it and exits 3 so a caller cannot quietly mistrust the value)
#   4  bd subprocess failure
#
# Safe under `set -uo pipefail` — every external call is guarded.

set -uo pipefail

# ── closed stage enum ────────────────────────────────────────────────────────
# Order is canonical (idea → ux → design → impl → docs → tests → done) and used
# by downstream consumers (L3 board columns, L2 gate-policy keying). Do not
# reorder without updating those.
STAGE_ENUM=(idea ux design impl docs tests done)

usage() {
  cat <<'EOF'
bd-stage.sh — stage label discipline for bd (L1, claude-tools-u6s)

Usage:
  bd-stage.sh set  <bead-id> <stage>   transition a bead to <stage>
  bd-stage.sh get  <bead-id>           print current stage (empty if unstaged)
  bd-stage.sh list <stage>             list bead ids at <stage>

Stages (closed enum):
  idea ux design impl docs tests done

Convention: every stage is realized as a bd label `stage:<value>`. A bead has
at most one stage:* label at any time; `set` enforces this by removing any
prior stage:* before adding the new one.
EOF
}

_is_valid_stage() {
  local s="$1" x
  for x in "${STAGE_ENUM[@]}"; do
    [[ "$x" == "$s" ]] && return 0
  done
  return 1
}

# Print every stage:* label currently on <bead>, one per line.
# Empty output = unstaged. Multiple lines = invariant violation (caller decides).
_current_stage_labels() {
  local bead="$1" out
  out=$(bd label list "$bead" --json 2>/dev/null) || return 4
  # The JSON is a flat array of strings. Extract stage:* entries; if jq is
  # absent, fall back to a grep-shaped parse of the same shape.
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$out" | jq -r '.[] | select(startswith("stage:"))' 2>/dev/null
  else
    # Each element appears as a quoted string in the JSON array; pull the
    # stage:<word> tokens out. Tolerant of whitespace/newlines.
    printf '%s' "$out" \
      | tr ',' '\n' \
      | grep -oE '"stage:[a-zA-Z0-9_-]+"' \
      | tr -d '"'
  fi
}

cmd_set() {
  local bead="${1:-}" new="${2:-}"
  [[ -n "$bead" ]] || { echo "bd-stage set: reject — bead id required" >&2; usage >&2; exit 2; }
  [[ -n "$new" ]]  || { echo "bd-stage set: reject — stage required" >&2; usage >&2; exit 2; }
  if ! _is_valid_stage "$new"; then
    echo "bd-stage set: reject — '$new' not in the closed stage enum (${STAGE_ENUM[*]})" >&2
    exit 2
  fi

  local current
  current=$(_current_stage_labels "$bead") || {
    echo "bd-stage set: reject — bd label list failed for '$bead'" >&2
    exit 4
  }

  # Remove EVERY prior stage:* label — robust against an already-broken
  # invariant (a legacy bead with two stage labels gets healed here, not
  # silently masked). Idempotent if there are none.
  local label
  while IFS= read -r label; do
    [[ -n "$label" ]] || continue
    [[ "$label" == "stage:$new" ]] && continue   # already correct; skip churn
    bd label remove "$bead" "$label" >/dev/null 2>&1 || {
      echo "bd-stage set: reject — bd label remove '$bead' '$label' failed" >&2
      exit 4
    }
  done <<< "$current"

  # Add the new one (idempotent — bd label add of an existing label is a no-op
  # in current bd versions; tolerate either behavior).
  bd label add "$bead" "stage:$new" >/dev/null 2>&1 || {
    echo "bd-stage set: reject — bd label add '$bead' 'stage:$new' failed" >&2
    exit 4
  }
  printf 'stage:%s set on %s\n' "$new" "$bead"
}

cmd_get() {
  local bead="${1:-}"
  [[ -n "$bead" ]] || { echo "bd-stage get: reject — bead id required" >&2; usage >&2; exit 2; }

  local current count
  current=$(_current_stage_labels "$bead") || {
    echo "bd-stage get: reject — bd label list failed for '$bead'" >&2
    exit 4
  }
  if [[ -z "$current" ]]; then
    # Unstaged (legacy) — print nothing, exit 0. The contract is "empty output =
    # unstaged"; exiting 0 lets callers do `[[ -z "$(bd-stage get X)" ]]`.
    return 0
  fi
  count=$(printf '%s\n' "$current" | grep -c .)
  if [[ "$count" -gt 1 ]]; then
    echo "bd-stage get: reject — invariant violation, $bead carries $count stage labels:" >&2
    printf '%s\n' "$current" >&2
    echo "  (run 'bd-stage set $bead <stage>' to heal — it removes all prior stage:* before adding.)" >&2
    exit 3
  fi
  # Strip the "stage:" prefix so callers get the bare value.
  printf '%s\n' "${current#stage:}"
}

cmd_list() {
  local stage="${1:-}"
  [[ -n "$stage" ]] || { echo "bd-stage list: reject — stage required" >&2; usage >&2; exit 2; }
  if ! _is_valid_stage "$stage"; then
    echo "bd-stage list: reject — '$stage' not in the closed stage enum (${STAGE_ENUM[*]})" >&2
    exit 2
  fi
  # --label is AND-filter; --flat for grep-friendly output; --no-pager so it
  # doesn't open less in a non-tty harness. Show all (--all) so closed beads
  # with stage:done aren't hidden.
  if ! bd list --label "stage:$stage" --flat --no-pager --all 2>/dev/null; then
    echo "bd-stage list: reject — bd list failed for stage:$stage" >&2
    exit 4
  fi
}

# ── dispatch ─────────────────────────────────────────────────────────────────
CMD="${1:-}"
[[ -n "$CMD" ]] || { usage >&2; exit 2; }
shift || true

case "$CMD" in
  set)        cmd_set "$@" ;;
  get)        cmd_get "$@" ;;
  list)       cmd_list "$@" ;;
  -h|--help)  usage; exit 0 ;;
  *) echo "bd-stage: reject — unknown subcommand '$CMD'" >&2; usage >&2; exit 2 ;;
esac
