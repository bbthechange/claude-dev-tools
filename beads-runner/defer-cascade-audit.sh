#!/usr/bin/env bash
# beads-runner/defer-cascade-audit.sh — surface hidden parent→child defer cascades
# (R2, claude-tools-fyx; epic claude-tools-ir7).
#
# WHAT THIS IS:
#   bd v1 silently cascades a parent epic's Deferred:<date> field to every
#   descendant: an OPEN child with zero blockers and no defer of its own
#   gets filtered out of `bd ready` solely because some ancestor carries a
#   future defer_until. `bd show <child>` does NOT surface that suppression
#   — you have to grep the parent for 'Deferred:'. The cascade is therefore
#   invisible: bd ready goes empty (or all-P3) while real demo-critical
#   work exists, and nothing tells you why.
#
#   This script realises the desired-behavior (1) from the fyx bug report:
#   "a child suppressed by an inherited/parent defer must be VISIBLE as
#   such". We can't modify `bd show` itself (bd is an external Go binary),
#   so we provide an out-of-band lens that walks the parent chain and
#   reports the silent cascade.
#
# USAGE:
#   defer-cascade-audit.sh audit
#     Scan all open epics; for each one whose defer_until is in the future,
#     enumerate every open descendant and print a one-line SUPPRESSED record
#     per child. Exit 0 if no cascade detected, 1 if any cascade detected
#     (so callers can use the exit code as a "queue starvation likely"
#     signal — e.g. a cron or a post-`bd ready` hook).
#
#   defer-cascade-audit.sh explain <bead-id>
#     For one specific bead, walk UP the parent chain and report whether any
#     ancestor's defer_until is suppressing it. Exit 0 if not suppressed,
#     1 if suppressed. Use this when `bd show <id>` says OPEN with no
#     blockers but `bd ready` still won't surface it.
#
#   defer-cascade-audit.sh list
#     Machine-readable: print only the suppressed child bead-ids, one per
#     line, no formatting. For piping into other tools.
#
# OUTPUT SHAPE (audit / explain):
#   <child-id>  SUPPRESSED by <ancestor-id> deferred until <date>  [<child-title-prefix>]
#
#   Trailing one-line summary on stderr:
#     defer-cascade-audit: epics_with_future_defer=N suppressed_open_children=M
#
# EXIT CODES:
#   0  no cascade detected (or `list` always — list signals via output)
#   1  at least one suppressed open child found
#   2  usage error
#   3  bd subprocess failure on a pre-flight call
#
# DESIGN NOTES:
#   • "Future" defer means defer_until > now (UTC). A past defer_until is
#     stale and bd ready would already surface the bead — not a cascade.
#   • Walks ONE level via `bd show --children --json` per epic. That is what
#     bd's own cascade does, and the runner's next_task already uses the
#     same shape (~run-beads-tasks.sh:628). If bd later supports multi-
#     level cascade we extend here; today the seam matches bd's seam.
#   • Only counts CHILDREN whose own defer_until is empty/past — a child
#     with its own future defer is suppressing itself, not being silently
#     suppressed by a parent. The bug is the *silent* case.
#   • Read-only. Never calls `bd update`, never mutates state. If you want
#     to clear a parent's defer, use `bd update <epic> --defer ""` or, if
#     the defer came from a release gate, `gate-defer.sh lift <gate-id>
#     --commit` (R3 / claude-tools-vb7).
#
# Safe under `set -uo pipefail`; every bd call is guarded.
#
# AUDIT-COVERAGE MARKER (claude-tools-mhcp.2, UX-DESIGN-V2 §9 row 4): `audit`
# emits the §9 audit-coverage marker the inventory producer surfaces on the
# Queue-Health strip — total = the open future-defer epics this run had to
# examine, read = how many it successfully walked. read<total only when a
# per-epic `bd show --children` failed: that is precisely "the audit did NOT
# read everything, so its suppressed-children count may under-report" — the
# distrust §9 row 4 exists to surface. The writer + path live in the same lib as
# the reader (la_publish_audit_coverage / la_audit_coverage_file in
# lib/local-agent.sh) so the two can never drift; this script just sources it and
# calls it. Best-effort: a missing/unsourceable lib ⇒ no marker (chip stays null,
# in-contract) and never affects the diagnosis. `explain`/`list` are query
# helpers and do NOT touch the marker; only a full `audit` run does.

set -uo pipefail

# Source the writer helper (best-effort — the marker is a side report, never a
# precondition for the diagnosis). lib/local-agent.sh is source-safe under
# `set -uo pipefail` (only function defs + one constant assignment at top level).
_DCA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [[ -r "$_DCA_DIR/lib/local-agent.sh" ]]; then
  # shellcheck source=lib/local-agent.sh
  source "$_DCA_DIR/lib/local-agent.sh" 2>/dev/null || true
fi

usage() {
  cat <<'EOF'
defer-cascade-audit.sh — surface hidden parent→child defer cascades
(R2, claude-tools-fyx)

Usage:
  defer-cascade-audit.sh audit
      Scan all open epics; report every open descendant suppressed by an
      ancestor's future defer_until. Exit 0 if clean, 1 if cascade found.

  defer-cascade-audit.sh explain <bead-id>
      Walk one bead's parent chain; report if any ancestor's defer_until
      is suppressing it. Exit 0 if clean, 1 if suppressed.

  defer-cascade-audit.sh list
      Print suppressed child bead-ids, one per line (machine-readable).
EOF
}

# UTC now as ISO-8601 (Z). Used to decide "future" defer_until.
_now_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Return 0 (true) iff $1 is a non-empty ISO-8601 date/timestamp in the future
# (strictly > now UTC). Empty/null/past → 1 (false). Tolerant of either a
# bare YYYY-MM-DD (bd accepts this on input) or a full RFC3339 timestamp.
_is_future() {
  local t="${1:-}"
  [[ -z "$t" || "$t" == "null" ]] && return 1
  # Normalise a bare date to end-of-day UTC so a same-day defer still
  # counts as "future" until the day ends.
  if [[ "$t" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    t="${t}T23:59:59Z"
  fi
  local now
  now=$(_now_utc) || return 1
  [[ "$t" > "$now" ]]
}

# Records emitted by the helpers below use ASCII Unit-Separator (\x1f) as the
# field delimiter, NOT TAB. bash `read` treats TAB as IFS whitespace and
# collapses consecutive tabs, which would shift an empty defer_until field
# into the next column. \x1f is non-whitespace and never appears in bead ids,
# ISO dates, or titles.
US=$'\x1f'

# Print every open epic with a future defer_until as
#   <epic-id><US><defer_until>
# Empty stdout = no such epics.
_open_epics_with_future_defer() {
  local out
  out=$(bd list -t epic --status=open --json 2>/dev/null) || return 3
  command -v jq >/dev/null 2>&1 || {
    echo "defer-cascade-audit: reject — jq required" >&2
    return 3
  }
  printf '%s' "$out" | jq -r --arg us "$US" '.[] | select(.defer_until != null and .defer_until != "") | "\(.id)\($us)\(.defer_until)"' 2>/dev/null
}

# Print open children of <parent-id>, one per line, as
#   <child-id><US><child-defer_until-or-empty><US><child-title>
# Uses `bd show --children --json` — same shape next_task() uses.
_open_children_of() {
  local parent="$1" out
  # bd failure → return 4 (NOT 0): the suppression scan still treats it as "no
  # children" (tolerant — never aborts the audit), but the distinct code lets the
  # coverage counter mark this epic UNREAD (read<total). Empty-but-successful and
  # has-children both return 0 (the trailing jq's status).
  out=$(bd show "$parent" --children --json 2>/dev/null) || return 4
  # bd v1.x returns {<parent-id>: [children]}; flatten defensively, drop
  # self, keep open only.
  printf '%s' "$out" | jq -r --arg id "$parent" --arg us "$US" '
    ((if type == "object" then [.[] | .[]?] else . end)
     | map(select(.id? != $id))
     | map(select(.status == "open"))
     | .[] | "\(.id)\($us)\(.defer_until // "")\($us)\((.title // "")[0:60])")
  ' 2>/dev/null
}

# Walk UP from <bead-id>. Print each ancestor as
#   <ancestor-id><US><defer_until-or-empty>
# Stops when there is no parent or after MAX_DEPTH hops (cycle guard).
_ancestors_of() {
  local bead="$1" depth=0 max=32 out parent defer
  while [[ -n "$bead" && $depth -lt $max ]]; do
    out=$(bd show "$bead" --json 2>/dev/null) || return 0
    parent=$(printf '%s' "$out" | jq -r '(if type == "array" then .[0] else . end) | .parent // ""' 2>/dev/null)
    [[ -z "$parent" || "$parent" == "null" ]] && return 0
    out=$(bd show "$parent" --json 2>/dev/null) || return 0
    defer=$(printf '%s' "$out" | jq -r '(if type == "array" then .[0] else . end) | .defer_until // ""' 2>/dev/null)
    printf '%s%s%s\n' "$parent" "$US" "$defer"
    bead="$parent"
    depth=$((depth + 1))
  done
}

# Implementation core for `audit` and `list`. Sets two globals consumed by
# the caller:
#   _SUPPRESSED — newline-separated lines, format depends on $1 (mode):
#                 audit → "<child>  SUPPRESSED by <epic> deferred until <date>  [<title>]"
#                 list  → "<child>"
#   _EPIC_COUNT — number of open epics with a future defer_until
_collect_suppression() {
  local mode="$1"
  _SUPPRESSED=""
  _EPIC_COUNT=0
  # _WALK_OK — future-defer epics this run successfully read children for (the
  # numerator of the §9 audit-coverage ratio; _EPIC_COUNT is the denominator).
  _WALK_OK=0
  local epics line epic_id epic_defer walk_rc
  epics=$(_open_epics_with_future_defer) || return 3
  [[ -z "$epics" ]] && return 0
  while IFS="$US" read -r epic_id epic_defer; do
    [[ -z "$epic_id" ]] && continue
    _is_future "$epic_defer" || continue
    _EPIC_COUNT=$((_EPIC_COUNT + 1))
    local children cline cid cdefer ctitle
    children=$(_open_children_of "$epic_id"); walk_rc=$?
    # Count a successful walk (rc 0) toward coverage; rc 4 = bd failed = UNREAD.
    [[ "$walk_rc" -eq 0 ]] && _WALK_OK=$((_WALK_OK + 1))
    [[ -z "$children" ]] && continue
    while IFS="$US" read -r cid cdefer ctitle; do
      [[ -z "$cid" ]] && continue
      # Skip children with their own future defer — those are NOT silently
      # suppressed; they're holding themselves.
      if _is_future "$cdefer"; then continue; fi
      case "$mode" in
        audit) line=$(printf '%s  SUPPRESSED by %s deferred until %s  [%s]' "$cid" "$epic_id" "$epic_defer" "$ctitle") ;;
        list)  line="$cid" ;;
        *)     line="$cid" ;;
      esac
      if [[ -z "$_SUPPRESSED" ]]; then
        _SUPPRESSED="$line"
      else
        _SUPPRESSED="$_SUPPRESSED"$'\n'"$line"
      fi
    done <<< "$children"
  done <<< "$epics"
}

cmd_audit() {
  local _SUPPRESSED _EPIC_COUNT _WALK_OK
  _collect_suppression audit || exit 3
  local n=0
  [[ -n "$_SUPPRESSED" ]] && n=$(printf '%s\n' "$_SUPPRESSED" | grep -c .)
  if [[ -n "$_SUPPRESSED" ]]; then
    printf '%s\n' "$_SUPPRESSED"
  fi
  printf 'defer-cascade-audit: epics_with_future_defer=%d suppressed_open_children=%d\n' \
    "$_EPIC_COUNT" "$n" >&2
  # §9 row-4 marker (claude-tools-mhcp.2): this audit examined _EPIC_COUNT
  # future-defer epics and read _WALK_OK of them. Overwrite-or-remove (the writer
  # removes the marker when _EPIC_COUNT==0 ⇒ "no audit reported" ⇒ no chip).
  # Best-effort: never let a marker hiccup change the audit's exit semantics.
  if declare -F la_publish_audit_coverage >/dev/null 2>&1; then
    la_publish_audit_coverage "$_WALK_OK" "$_EPIC_COUNT" || true
  fi
  [[ "$n" -eq 0 ]] || exit 1
}

cmd_list() {
  local _SUPPRESSED _EPIC_COUNT _WALK_OK   # _WALK_OK set by _collect_suppression; declared for hygiene
  _collect_suppression list || exit 3
  [[ -n "$_SUPPRESSED" ]] && printf '%s\n' "$_SUPPRESSED"
}

cmd_explain() {
  local bead="${1:-}"
  [[ -n "$bead" ]] || { echo "defer-cascade-audit explain: reject — bead-id required" >&2; usage >&2; exit 2; }
  local anc anc_id anc_defer hit=""
  anc=$(_ancestors_of "$bead") || true
  if [[ -z "$anc" ]]; then
    printf '%s  NO_SUPPRESSION  no ancestor with a future defer_until\n' "$bead"
    return 0
  fi
  while IFS="$US" read -r anc_id anc_defer; do
    [[ -z "$anc_id" ]] && continue
    if _is_future "$anc_defer"; then
      hit=$(printf '%s%s%s' "$anc_id" "$US" "$anc_defer")
      break
    fi
  done <<< "$anc"
  if [[ -n "$hit" ]]; then
    IFS="$US" read -r anc_id anc_defer <<< "$hit"
    printf '%s  SUPPRESSED by %s deferred until %s\n' "$bead" "$anc_id" "$anc_defer"
    exit 1
  fi
  printf '%s  NO_SUPPRESSION  no ancestor with a future defer_until\n' "$bead"
}

# ── dispatch ─────────────────────────────────────────────────────────────────
CMD="${1:-}"
[[ -n "$CMD" ]] || { usage >&2; exit 2; }
shift || true

case "$CMD" in
  audit)      cmd_audit "$@" ;;
  explain)    cmd_explain "$@" ;;
  list)       cmd_list "$@" ;;
  -h|--help)  usage; exit 0 ;;
  *) echo "defer-cascade-audit: reject — unknown subcommand '$CMD'" >&2; usage >&2; exit 2 ;;
esac
