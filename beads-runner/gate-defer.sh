#!/usr/bin/env bash
# beads-runner/gate-defer.sh — gate↔defer ownership coupling
# (R3, claude-tools-vb7; epic claude-tools-ir7).
#
# WHAT THIS IS:
#   bd has no native concept of "this defer was set by gate X". Lifting a
#   release/readiness gate (e.g. impl-gate-2026-04-22) historically left
#   every Deferred: <date> stamp that gate applied in place — the cohort
#   stayed invisible to `bd ready` for weeks until an audit sweep noticed.
#   That stale defer outliving its gate is the ORIGIN of the R2 cascade-
#   starvation (claude-tools-fyx).
#
#   This script realizes Brian's decision (vb7 ask-brian fork, opt-a):
#   couple a defer to its owning gate via the bd label `gate:<gate-id>`.
#   `apply` stamps the defer AND the label in one step; `lift` finds every
#   bead carrying the label and clears its defer (and the label). Lifting
#   reverses what apply did, mechanically.
#
#   Naming: this is the COHORT/RELEASE gate concept (e.g.
#   impl-gate-2026-04-22), NOT the pickup-time gate-policy.sh (which is
#   keyed on preset:* labels and decides "may the runner auto-claim this
#   one bead"). The two are deliberately separate seams — confusing them
#   was a hazard called out in the vb7 dossier.
#
# USAGE:
#   gate-defer.sh apply <gate-id> <bead-id> <date>
#     Stamp `Deferred: <date>` on <bead-id> AND add label gate:<gate-id>.
#     <date> is whatever `bd update --defer` accepts (e.g. 2026-07-01).
#
#   gate-defer.sh lift  <gate-id> [--commit]
#     Default DRY-RUN: list every bead carrying gate:<gate-id> with its
#     current Deferred date. No state change. Prints `mismatches=0` style
#     summary so a caller can decide to commit.
#     With --commit: for each bead, bd update --defer "" AND remove the
#     gate:<gate-id> label. Lift is en-masse and unconditional — there is
#     no "restore prior defer" path (opt-a forecloses that on purpose).
#
#   gate-defer.sh list  <gate-id>
#     Print every bead id carrying gate:<gate-id>, one per line. Useful
#     for piping into ad-hoc audits without running the full lift.
#
# EXIT CODES:
#   0  success
#   2  usage error (bad args)
#   3  partial failure during lift (some beads updated, others not — the
#      script prints which failed so the caller can retry)
#   4  bd subprocess failure on a pre-flight call (nothing changed)
#
# Safe under `set -uo pipefail`; every bd call is guarded.

set -uo pipefail

usage() {
  cat <<'EOF'
gate-defer.sh — gate↔defer ownership coupling (R3, claude-tools-vb7)

Usage:
  gate-defer.sh apply <gate-id> <bead-id> <date>
      Stamp Deferred:<date> on <bead-id> AND add label gate:<gate-id>.

  gate-defer.sh lift  <gate-id> [--commit]
      Default dry-run: list every bead carrying gate:<gate-id> + its defer.
      With --commit: clear the defer AND remove the label on each.

  gate-defer.sh list  <gate-id>
      Print bead ids carrying gate:<gate-id>, one per line.

The label convention `gate:<gate-id>` is the source of truth. Anything that
sets a defer on behalf of a gate MUST also stamp the label (use `apply`).
Lifting the gate later mechanically reverses both.
EOF
}

# Validate a gate id: lowercase letters, digits, hyphens. We don't want
# spaces/colons in a label value, and we want the same shape as the prior
# free-text gate names (e.g. impl-gate-2026-04-22). Forbid an empty id.
_is_valid_gate_id() {
  local g="$1"
  [[ -n "$g" ]] && [[ "$g" =~ ^[a-z0-9][a-z0-9-]*$ ]]
}

# List bead ids carrying gate:<id>. One per line. bd's JSON list is the
# stable shape; --flat is only used for human output. Empty output = no
# beads.
_beads_for_gate() {
  local gate="$1" out
  out=$(bd list --label "gate:$gate" --no-pager --all --json 2>/dev/null) || return 4
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$out" | jq -r '.[].id' 2>/dev/null
  else
    # Tolerant fallback: pull the first "id":"…" from each object.
    printf '%s' "$out" \
      | tr ',' '\n' \
      | grep -oE '"id":"[a-zA-Z0-9_-]+"' \
      | sed 's/^"id":"\(.*\)"$/\1/'
  fi
}

# Print the current Deferred date for <bead>, or empty if none.
# `bd show` is the human-readable surface; `Deferred:` appears as a field
# line. We grep for it tolerantly so the script survives minor formatting
# drift.
_defer_of() {
  local bead="$1" out
  out=$(bd show "$bead" 2>/dev/null) || return 4
  printf '%s' "$out" | grep -m1 -E '^Deferred:' | sed 's/^Deferred:[[:space:]]*//'
}

cmd_apply() {
  local gate="${1:-}" bead="${2:-}" date="${3:-}"
  [[ -n "$gate" ]] || { echo "gate-defer apply: reject — gate-id required" >&2; usage >&2; exit 2; }
  [[ -n "$bead" ]] || { echo "gate-defer apply: reject — bead-id required" >&2; usage >&2; exit 2; }
  [[ -n "$date" ]] || { echo "gate-defer apply: reject — date required" >&2; usage >&2; exit 2; }
  _is_valid_gate_id "$gate" || {
    echo "gate-defer apply: reject — gate-id '$gate' must be [a-z0-9][a-z0-9-]*" >&2
    exit 2
  }

  # Stamp the defer first; if bd rejects the date format we surface the
  # error from bd rather than swallowing it. Then the label — `--add-label`
  # is the documented way to add without replacing existing labels.
  if ! bd update "$bead" --defer "$date" --add-label "gate:$gate" >/dev/null 2>&1; then
    echo "gate-defer apply: reject — bd update '$bead' --defer '$date' --add-label 'gate:$gate' failed" >&2
    exit 4
  fi
  printf 'gate:%s applied to %s (Deferred: %s)\n' "$gate" "$bead" "$date"
}

cmd_lift() {
  local gate="${1:-}" commit_flag="${2:-}"
  [[ -n "$gate" ]] || { echo "gate-defer lift: reject — gate-id required" >&2; usage >&2; exit 2; }
  _is_valid_gate_id "$gate" || {
    echo "gate-defer lift: reject — gate-id '$gate' must be [a-z0-9][a-z0-9-]*" >&2
    exit 2
  }
  local commit=0
  case "$commit_flag" in
    "")        commit=0 ;;
    --commit)  commit=1 ;;
    *) echo "gate-defer lift: reject — unknown flag '$commit_flag' (expected --commit or nothing)" >&2; exit 2 ;;
  esac

  local beads
  beads=$(_beads_for_gate "$gate") || {
    echo "gate-defer lift: reject — bd list --label gate:$gate failed (nothing changed)" >&2
    exit 4
  }

  if [[ -z "$beads" ]]; then
    printf 'gate:%s no beads carry this label (nothing to lift)\n' "$gate"
    return 0
  fi

  local total=0 failed=0 bead defer
  if [[ $commit -eq 0 ]]; then
    printf 'gate:%s DRY-RUN — would clear defer and remove label from:\n' "$gate"
  else
    printf 'gate:%s LIFT — clearing defer and removing label from:\n' "$gate"
  fi

  while IFS= read -r bead; do
    [[ -n "$bead" ]] || continue
    total=$((total + 1))
    defer=$(_defer_of "$bead" 2>/dev/null || true)
    if [[ $commit -eq 0 ]]; then
      # Dry-run line: bead id + the defer date we WOULD clear (or "(none)")
      printf '  %s  Deferred: %s\n' "$bead" "${defer:-(none)}"
      continue
    fi
    # Commit path: clear defer AND remove the gate label in one bd call.
    # If this fails we keep going (count it) so a single bad bead does not
    # strand the rest of the cohort — same en-masse spirit as the bug being
    # fixed (the manual workaround left the WHOLE cohort stuck).
    if bd update "$bead" --defer "" --remove-label "gate:$gate" >/dev/null 2>&1; then
      printf '  %s  cleared (was: %s)\n' "$bead" "${defer:-(none)}"
    else
      printf '  %s  FAILED — bd update %s --defer "" --remove-label gate:%s failed\n' "$bead" "$bead" "$gate" >&2
      failed=$((failed + 1))
    fi
  done <<< "$beads"

  if [[ $commit -eq 0 ]]; then
    printf 'gate:%s dry-run total=%d (re-run with --commit to apply)\n' "$gate" "$total"
    return 0
  fi
  printf 'gate:%s lift total=%d failed=%d\n' "$gate" "$total" "$failed"
  [[ $failed -eq 0 ]] || exit 3
}

cmd_list() {
  local gate="${1:-}"
  [[ -n "$gate" ]] || { echo "gate-defer list: reject — gate-id required" >&2; usage >&2; exit 2; }
  _is_valid_gate_id "$gate" || {
    echo "gate-defer list: reject — gate-id '$gate' must be [a-z0-9][a-z0-9-]*" >&2
    exit 2
  }
  local beads
  beads=$(_beads_for_gate "$gate") || {
    echo "gate-defer list: reject — bd list --label gate:$gate failed" >&2
    exit 4
  }
  [[ -z "$beads" ]] && return 0
  printf '%s\n' "$beads"
}

# ── dispatch ─────────────────────────────────────────────────────────────────
CMD="${1:-}"
[[ -n "$CMD" ]] || { usage >&2; exit 2; }
shift || true

case "$CMD" in
  apply)      cmd_apply "$@" ;;
  lift)       cmd_lift  "$@" ;;
  list)       cmd_list  "$@" ;;
  -h|--help)  usage; exit 0 ;;
  *) echo "gate-defer: reject — unknown subcommand '$CMD'" >&2; usage >&2; exit 2 ;;
esac
