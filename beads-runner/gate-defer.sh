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
#   gate-defer.sh apply <gate-id> <bead-id> <date> \
#       [--why <text>] [--unblock <text>] [--owner <who>] [--scope task|cohort]
#     Stamp `Deferred: <date>` on <bead-id> AND add label gate:<gate-id>.
#     <date> is whatever `bd update --defer` accepts (e.g. 2026-07-01).
#
#     When any metadata flag is given, ALSO record the Gate's why/unblock/owner
#     in the engine via the J1 `gate-meta-set` op (DESIGN J §6 / gates.md, bead
#     claude-tools-escz): "an agent that holds work places a Gate WITH A WHY."
#     `--why` is REQUIRED whenever metadata is supplied (a Gate always carries a
#     why — D.3 "nothing is held invisibly"); `--owner` is an INPUT, not the
#     principal (§2.3) — an agent passes `agent:<hat>`, the GUI passes `you`;
#     `--scope` is the closed D.2 enum {task,cohort}, default `task`. The bare
#     `apply <gate> <bead> <date>` (no flags) is unchanged — the label↔defer
#     coupling stays the source of truth; the metadata is annotation (§2.4).
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
#   5  apply placed the gate:<id> label + defer, but the gate-meta-set write
#      (the why/unblock/owner metadata) failed (engine unreachable or rejected).
#      The label — the source of truth — STANDS; the hold renders degraded
#      (why:null, a B.4 `degraded[]` note) until re-run with the engine reachable.
#
# Safe under `set -uo pipefail`; every bd call is guarded.

set -uo pipefail

# Directory of this script — used to lazily source the coordinator transport
# (lib/coordinator.sh + lib/co-http-transport.sh) ONLY when a Gate is placed
# WITH metadata, so the pure label↔defer apply/lift/list paths stay
# dependency-free (claude-tools-escz).
GD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
GD_LIB_DIR="$GD_DIR/lib"

usage() {
  cat <<'EOF'
gate-defer.sh — gate↔defer ownership coupling (R3, claude-tools-vb7)

Usage:
  gate-defer.sh apply <gate-id> <bead-id> <date> \
      [--why <text>] [--unblock <text>] [--owner <who>] [--scope task|cohort]
      Stamp Deferred:<date> on <bead-id> AND add label gate:<gate-id>.
      With --why (et al.): also record the Gate's why/unblock/owner/scope in
      the engine via gate-meta-set (a Gate placed by an agent carries a why).

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

# ── the gate-PLACEMENT metadata write seam (claude-tools-escz, DESIGN J §6) ──
# Make co_request available for the gate-meta-set write. Lazily sources the
# in-process oracle (lib/coordinator.sh) then the HTTP override
# (lib/co-http-transport.sh) — the SAME ordering the runner/daemon use
# (run-beads-tasks.sh:226-235, daemon/*-poll.sh) so production's authed HTTPS
# co_request wins when COORDINATOR_URL is set and the write lands in the hosted
# gate_metadata table (J1). If co_request is ALREADY defined (a caller that
# sourced the transport, or a test that injects a fake) we keep it untouched.
# Returns 0 iff co_request is callable afterwards.
_ensure_co_request() {
  command -v co_request >/dev/null 2>&1 && return 0
  [[ -f "$GD_LIB_DIR/coordinator.sh" ]] && . "$GD_LIB_DIR/coordinator.sh" 2>/dev/null
  [[ -n "${COORDINATOR_URL:-}" && -f "$GD_LIB_DIR/co-http-transport.sh" ]] \
    && . "$GD_LIB_DIR/co-http-transport.sh" 2>/dev/null
  command -v co_request >/dev/null 2>&1
}

# _gate_meta_set <gate> <why> <unblock> <owner> <scope>
#   Attach the Gate's metadata via the J1 `gate-meta-set` op (Contract A — the
#   EXISTING op, no new surface). The op takes ONE positional arg: a JSON object
#   {id, why, unblock_condition, owner, scope}. `why` is required and re-enforced
#   engine-side; empty unblock/owner/scope are omitted so the engine applies its
#   own defaults (scope ⇒ "task"). Returns 0 on success; non-zero (loud stderr)
#   on any unavailable-transport / engine-reject / unreachable failure — the
#   caller maps that to exit 5 (label placed, metadata not yet recorded).
_gate_meta_set() {
  local gate="$1" why="$2" unblock="$3" owner="$4" scope="$5"
  if ! _ensure_co_request; then
    echo "gate-defer apply: WARN — co_request unavailable (COORDINATOR_URL unset / transport not sourced); Gate metadata NOT recorded. The gate:$gate label is placed (source of truth); attach the why later from the Gates facet or re-run with the engine reachable." >&2
    return 1
  fi
  local meta_json
  meta_json="$(jq -cn \
      --arg id "$gate" --arg why "$why" --arg unblock "$unblock" \
      --arg owner "$owner" --arg scope "$scope" \
      '{id:$id, why:$why}
        + (if $unblock != "" then {unblock_condition:$unblock} else {} end)
        + (if $owner   != "" then {owner:$owner}            else {} end)
        + (if $scope   != "" then {scope:$scope}            else {} end)' 2>/dev/null)" \
    || { echo "gate-defer apply: WARN — could not build gate-meta JSON for gate:$gate" >&2; return 1; }
  # The HTTP transport ignores this passed bearer and uses the resolved
  # per-workspace token (COORDINATOR_TOKEN / Local Agent Keychain); the
  # in-process oracle authenticates it. Mirrors run-beads-tasks.sh:669.
  local bearer="${COORDINATOR_TOKEN:-bearer-gate-defer}"
  if co_request "$bearer" gate-meta-set "$meta_json" >/dev/null 2>&1; then
    return 0
  fi
  # Distinguish "no live engine configured" from "engine rejected/unreachable":
  # with COORDINATOR_URL unset, _ensure_co_request falls back to the in-process
  # oracle, which has NO gate-meta op (returns unknown-op) — so the failure is
  # configuration, not a reject. The clearer message points at the real fix.
  if [[ -z "${COORDINATOR_URL:-}" ]]; then
    echo "gate-defer apply: WARN — COORDINATOR_URL unset: no live engine to record Gate metadata (the in-process oracle has no gate-meta op). The gate:$gate label is placed (source of truth); set COORDINATOR_URL and re-run to attach the why." >&2
  else
    echo "gate-defer apply: WARN — gate-meta-set for gate:$gate failed (engine rejected or unreachable); the gate:$gate label is placed but its why/unblock are not recorded yet." >&2
  fi
  return 1
}

cmd_apply() {
  # Three positionals (gate bead date) + optional metadata flags. Flags may be
  # interspersed; everything after `--` is positional. (claude-tools-escz)
  local why="" unblock="" owner="" scope="" have_meta=0
  local -a pos=()
  # A value-taking flag MUST have a following value — `shift 2` is atomic-fail,
  # so a trailing `--why` with no value would never shift and spin forever
  # (claude-tools-escz review). Guard each with `$# -ge 2` ⇒ a clean exit 2,
  # mirroring the missing-positional rejects below.
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --why)       [[ $# -ge 2 ]] || { echo "gate-defer apply: reject — --why needs a value" >&2; exit 2; }
                   why="$2";          have_meta=1; shift 2 ;;
      --why=*)     why="${1#--why=}"; have_meta=1; shift ;;
      --unblock)   [[ $# -ge 2 ]] || { echo "gate-defer apply: reject — --unblock needs a value" >&2; exit 2; }
                   unblock="$2";      have_meta=1; shift 2 ;;
      --unblock=*) unblock="${1#--unblock=}"; have_meta=1; shift ;;
      --owner)     [[ $# -ge 2 ]] || { echo "gate-defer apply: reject — --owner needs a value" >&2; exit 2; }
                   owner="$2";        have_meta=1; shift 2 ;;
      --owner=*)   owner="${1#--owner=}"; have_meta=1; shift ;;
      --scope)     [[ $# -ge 2 ]] || { echo "gate-defer apply: reject — --scope needs a value" >&2; exit 2; }
                   scope="$2";        have_meta=1; shift 2 ;;
      --scope=*)   scope="${1#--scope=}"; have_meta=1; shift ;;
      --)          shift; while [[ $# -gt 0 ]]; do pos+=("$1"); shift; done ;;
      -*)          echo "gate-defer apply: reject — unknown flag '$1'" >&2; usage >&2; exit 2 ;;
      *)           pos+=("$1"); shift ;;
    esac
  done
  local gate="${pos[0]:-}" bead="${pos[1]:-}" date="${pos[2]:-}"
  [[ -n "$gate" ]] || { echo "gate-defer apply: reject — gate-id required" >&2; usage >&2; exit 2; }
  [[ -n "$bead" ]] || { echo "gate-defer apply: reject — bead-id required" >&2; usage >&2; exit 2; }
  [[ -n "$date" ]] || { echo "gate-defer apply: reject — date required" >&2; usage >&2; exit 2; }
  _is_valid_gate_id "$gate" || {
    echo "gate-defer apply: reject — gate-id '$gate' must be [a-z0-9][a-z0-9-]*" >&2
    exit 2
  }
  # A Gate placed WITH metadata ALWAYS carries a why (D.3 — nothing held
  # invisibly; the engine rejects a why-less metadata write anyway). Reject
  # locally with a clear message BEFORE touching bd, so a missing --why never
  # half-places a label.
  if [[ $have_meta -eq 1 ]] && [[ -z "${why// /}" ]]; then
    echo "gate-defer apply: reject — placing a Gate with metadata requires --why (a Gate always carries a why; gates.md §2.2/§6)" >&2
    exit 2
  fi
  # Validate scope locally too (closed D.2 enum) so an obvious typo fails fast
  # rather than as an opaque engine 422.
  if [[ -n "$scope" ]] && [[ "$scope" != "task" && "$scope" != "cohort" ]]; then
    echo "gate-defer apply: reject — --scope '$scope' must be task|cohort (D.2 enum)" >&2
    exit 2
  fi

  # Stamp the defer first; if bd rejects the date format we surface the
  # error from bd rather than swallowing it. Then the label — `--add-label`
  # is the documented way to add without replacing existing labels. The label
  # is the SOURCE OF TRUTH for cohort membership (§2.4), so it lands first;
  # the metadata is annotation written next.
  if ! bd update "$bead" --defer "$date" --add-label "gate:$gate" >/dev/null 2>&1; then
    echo "gate-defer apply: reject — bd update '$bead' --defer '$date' --add-label 'gate:$gate' failed" >&2
    exit 4
  fi
  printf 'gate:%s applied to %s (Deferred: %s)\n' "$gate" "$bead" "$date"

  # Metadata write — only when the caller supplied any metadata flag. A failure
  # here leaves the gate placed-but-degraded (B.4 tolerated), surfaced as exit 5
  # so the caller knows the why/unblock are not recorded yet.
  if [[ $have_meta -eq 1 ]]; then
    if _gate_meta_set "$gate" "$why" "$unblock" "$owner" "$scope"; then
      printf 'gate:%s metadata recorded (why/unblock/owner via gate-meta-set)\n' "$gate"
    else
      exit 5
    fi
  fi
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
