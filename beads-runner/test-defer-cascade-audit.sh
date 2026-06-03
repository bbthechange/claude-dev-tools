#!/usr/bin/env bash
# beads-runner/test-defer-cascade-audit.sh — defer-cascade-audit.sh regression
# test (R2, claude-tools-fyx; epic claude-tools-ir7).
#
# Drives defer-cascade-audit.sh against a STATEFUL FAKE `bd` on PATH (same
# precedent as test-gate-defer.sh / test-bd-stage.sh — `bd init` is too slow
# for unit work; the fake is a hermetic, offline-friendly oracle for the
# parent-defer-cascade invariants this script enforces).
#
# What this asserts (R2 acceptance):
#   • audit reports nothing + exit 0 when no epic carries a future defer
#   • audit reports the open child + exit 1 when its parent epic carries a
#     future defer_until and the child has none of its own
#   • audit IGNORES a child that holds its own future defer (the bug is the
#     SILENT cascade — a self-deferred child isn't silently suppressed)
#   • audit IGNORES a closed child (only open children matter for ready)
#   • audit IGNORES a parent whose defer_until is in the past (stale defer
#     would already let bd ready surface the child — not a cascade)
#   • explain <bead> walks the parent chain; reports SUPPRESSED + exit 1 if
#     any ancestor has a future defer, NO_SUPPRESSION + exit 0 otherwise
#   • list emits only bead-ids (one per line), suitable for piping
#   • bare invocation prints usage and exits 2

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
HELPER="$SCRIPT_DIR/defer-cascade-audit.sh"
[[ -f "$HELPER" ]] || { echo "test-defer-cascade-audit.sh: reject — $HELPER not found" >&2; exit 2; }

FAILED=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; FAILED=1; }

WORK="$(mktemp -d 2>/dev/null)" || { echo "mktemp failed"; exit 70; }
trap 'rm -rf "$WORK"' EXIT

# claude-tools-mhcp.2 (§9 row 4) — pin the audit-coverage marker path to a tmp
# file so the `audit` command's marker writes/removes NEVER touch the real
# repo's .beads/runner-logs/audit-coverage.json. Cases 11-14 assert against it.
export LA_AUDIT_COVERAGE_FILE="$WORK/audit-coverage.json"

# ── stateful fake bd ─────────────────────────────────────────────────────────
# State per bead in $BDST:
#   $BDST/<bead>.json — a single-record JSON object with id/issue_type/status/
#                       defer_until/parent/title (minimal shape — only what
#                       defer-cascade-audit reads).
# Commands implemented (just what defer-cascade-audit invokes):
#   bd list -t epic --status=open --json
#   bd show <bead> --json
#   bd show <bead> --children --json
FAKEBIN="$WORK/bin"
export BDST="$WORK/bdst"
mkdir -p "$FAKEBIN" "$BDST"

cat > "$FAKEBIN/bd" <<'BDEOF'
#!/usr/bin/env bash
set -uo pipefail

cmd="${1:-}"; shift || true

# Read all bead .json records into one JSON array on stdout.
_all_records() {
  local first=1
  printf '['
  for f in "$BDST"/*.json; do
    [[ -f "$f" ]] || continue
    if [[ "$first" == 1 ]]; then first=0; else printf ','; fi
    cat "$f"
  done
  printf ']\n'
}

case "$cmd" in
  list)
    # defer-cascade-audit invokes: bd list -t epic --status=open --json
    want_type=""
    want_status=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -t)              want_type="${2:-}"; shift 2;;
        --status)        want_status="${2:-}"; shift 2;;
        --status=*)      want_status="${1#--status=}"; shift;;
        --json)          shift;;
        *)               shift;;
      esac
    done
    _all_records | jq --arg t "$want_type" --arg s "$want_status" '
      map(select(($t == "" or .issue_type == $t) and ($s == "" or .status == $s)))
    '
    ;;

  show)
    bead="${1:-}"; shift || true
    [[ -n "$bead" ]] || exit 2
    children_mode=0
    json_mode=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --children) children_mode=1; shift;;
        --json)     json_mode=1; shift;;
        *)          shift;;
      esac
    done
    # claude-tools-mhcp.2: simulate a bd subprocess failure on a specific epic's
    # children walk so the coverage counter can be exercised (read<total).
    if [[ $children_mode -eq 1 && -n "${BD_FAIL_CHILDREN_FOR:-}" && "$bead" == "$BD_FAIL_CHILDREN_FOR" ]]; then
      echo "bd: simulated children failure for $bead" >&2; exit 3
    fi
    f="$BDST/$bead.json"
    [[ -f "$f" ]] || { echo "[]"; exit 0; }
    if [[ $children_mode -eq 1 ]]; then
      # Emit the {<parent-id>: [children]} shape bd v1.x uses.
      local_children=$(_all_records | jq --arg p "$bead" '
        map(select(.parent == $p))
      ')
      jq -n --arg p "$bead" --argjson c "$local_children" '{($p): $c}'
      exit 0
    fi
    # bd show --json wraps the record in a one-element array.
    jq '[.]' < "$f"
    ;;

  *) : ;;
esac
exit 0
BDEOF
chmod +x "$FAKEBIN/bd"
export PATH="$FAKEBIN:$PATH"

# ── seeder ──────────────────────────────────────────────────────────────────
# Write a minimal bead record. Usage:
#   _seed <id> <issue_type> <status> <defer_until-or-empty> <parent-or-empty> [<title>]
_seed() {
  local id="$1" itype="$2" status="$3" defer="$4" parent="$5" title="${6:-untitled}"
  local f="$BDST/$id.json"
  jq -n \
    --arg id "$id" --arg t "$itype" --arg s "$status" \
    --arg d "$defer" --arg p "$parent" --arg ti "$title" \
    '{id:$id, issue_type:$t, status:$s,
      defer_until: (if $d == "" then null else $d end),
      parent: (if $p == "" then null else $p end),
      title: $ti}' > "$f"
}

# Clear all state between cases (each case sets up its own world).
_reset() { rm -f "$BDST"/*.json 2>/dev/null || true; }

# ── case 1: audit reports nothing when no epic has a future defer ───────────
_reset
_seed epic-1 epic open ""           ""        "Some epic, no defer"
_seed task-1 task open ""           epic-1    "A task under no-defer epic"
out=$(bash "$HELPER" audit 2>/dev/null)
rc=$?
err=$(bash "$HELPER" audit 2>&1 >/dev/null)
if [[ "$rc" == "0" && -z "$out" ]] \
   && printf '%s' "$err" | grep -q 'epics_with_future_defer=0 suppressed_open_children=0'; then
  pass "audit clean when no epic carries a future defer"
else
  fail "audit clean case: rc=$rc out='$out' err='$err'"
fi

# ── case 2: audit reports an open child suppressed by parent's future defer ─
_reset
_seed epic-2 epic open "2099-01-01"  ""        "Stale-deferred epic"
_seed task-2 task open ""            epic-2    "Hidden child"
out=$(bash "$HELPER" audit 2>/dev/null)
rc=$?
err=$(bash "$HELPER" audit 2>&1 >/dev/null)
if [[ "$rc" == "1" ]] \
   && printf '%s' "$out" | grep -q 'task-2  SUPPRESSED by epic-2 deferred until 2099-01-01' \
   && printf '%s' "$err" | grep -q 'epics_with_future_defer=1 suppressed_open_children=1'; then
  pass "audit surfaces the silent cascade (exit 1, child line, summary)"
else
  fail "audit cascade case: rc=$rc out='$out' err='$err'"
fi

# ── case 3: a child holding its OWN future defer is not silently suppressed ─
# (The bug is the *silent* cascade — a self-deferred child is intentional.)
_reset
_seed epic-3 epic open "2099-01-01"  ""        "Deferred epic"
_seed task-3 task open "2099-06-30"  epic-3    "Self-deferred child"
out=$(bash "$HELPER" audit 2>/dev/null)
rc=$?
err=$(bash "$HELPER" audit 2>&1 >/dev/null)
if [[ "$rc" == "0" && -z "$out" ]] \
   && printf '%s' "$err" | grep -q 'suppressed_open_children=0'; then
  pass "audit ignores a child holding its own future defer"
else
  fail "audit self-defer case: rc=$rc out='$out' err='$err'"
fi

# ── case 4: a closed child doesn't count (only open children matter) ────────
_reset
_seed epic-4 epic open "2099-01-01"  ""        "Deferred epic"
_seed task-4 task closed ""          epic-4    "Closed child"
out=$(bash "$HELPER" audit 2>/dev/null)
rc=$?
err=$(bash "$HELPER" audit 2>&1 >/dev/null)
if [[ "$rc" == "0" && -z "$out" ]] \
   && printf '%s' "$err" | grep -q 'suppressed_open_children=0'; then
  pass "audit ignores a closed child"
else
  fail "audit closed-child case: rc=$rc out='$out' err='$err'"
fi

# ── case 5: a parent whose defer_until is in the past doesn't count ─────────
# (Stale past defer would already let bd ready surface the child.)
_reset
_seed epic-5 epic open "2000-01-01"  ""        "Past-deferred epic"
_seed task-5 task open ""            epic-5    "Child of past-deferred epic"
out=$(bash "$HELPER" audit 2>/dev/null)
rc=$?
err=$(bash "$HELPER" audit 2>&1 >/dev/null)
if [[ "$rc" == "0" && -z "$out" ]] \
   && printf '%s' "$err" | grep -q 'epics_with_future_defer=0'; then
  pass "audit ignores an epic whose defer_until is in the past"
else
  fail "audit past-defer case: rc=$rc out='$out' err='$err'"
fi

# ── case 6: explain reports SUPPRESSED + exit 1 when an ancestor defers ─────
_reset
_seed epic-6 epic open "2099-01-01"  ""        "Deferred epic"
_seed task-6 task open ""            epic-6    "Hidden child"
out=$(bash "$HELPER" explain task-6 2>/dev/null)
rc=$?
if [[ "$rc" == "1" ]] \
   && printf '%s' "$out" | grep -q 'task-6  SUPPRESSED by epic-6 deferred until 2099-01-01'; then
  pass "explain SUPPRESSED (exit 1) when ancestor has future defer"
else
  fail "explain suppressed case: rc=$rc out='$out'"
fi

# ── case 7: explain reports NO_SUPPRESSION + exit 0 when nothing defers ─────
_reset
_seed epic-7 epic open ""            ""        "Clean epic"
_seed task-7 task open ""            epic-7    "Clean child"
out=$(bash "$HELPER" explain task-7 2>/dev/null)
rc=$?
if [[ "$rc" == "0" ]] \
   && printf '%s' "$out" | grep -q 'task-7  NO_SUPPRESSION'; then
  pass "explain NO_SUPPRESSION (exit 0) when no ancestor defers"
else
  fail "explain clean case: rc=$rc out='$out'"
fi

# ── case 8: list emits only suppressed bead-ids, one per line ───────────────
_reset
_seed epic-8 epic open "2099-01-01"  ""        "Deferred epic"
_seed task-8a task open ""           epic-8    "Hidden A"
_seed task-8b task open ""           epic-8    "Hidden B"
_seed task-8c task open "2099-06-30" epic-8    "Self-deferred (excluded)"
out=$(bash "$HELPER" list 2>/dev/null)
rc=$?
ids=$(printf '%s\n' "$out" | sort | tr '\n' ' ')
if [[ "$rc" == "0" && "$ids" == "task-8a task-8b " ]]; then
  pass "list emits only suppressed bead-ids (one per line)"
else
  fail "list case: rc=$rc ids='$ids'"
fi

# ── case 9: bare invocation prints usage and exits 2 ────────────────────────
bash "$HELPER" >/dev/null 2>&1
rc=$?
if [[ "$rc" == "2" ]]; then
  pass "bare invocation exits 2 (usage)"
else
  fail "bare invocation: rc=$rc (expected 2)"
fi

# ── case 10: explain rejects missing bead-id with exit 2 ────────────────────
bash "$HELPER" explain >/dev/null 2>&1
rc=$?
if [[ "$rc" == "2" ]]; then
  pass "explain without bead-id exits 2 (usage)"
else
  fail "explain no-arg: rc=$rc (expected 2)"
fi

# ── case 11: audit emits the §9 audit-coverage marker (read==total all-walked) ─
# (claude-tools-mhcp.2) One future-defer epic with a readable child ⇒ the audit
# examined 1 epic and read 1 ⇒ marker {"read":1,"total":1} (complete coverage).
_reset
rm -f "$LA_AUDIT_COVERAGE_FILE"
_seed epic-11 epic open "2099-01-01" "" "Deferred epic"
_seed task-11 task open ""           epic-11 "Hidden child"
bash "$HELPER" audit >/dev/null 2>&1
marker=$(cat "$LA_AUDIT_COVERAGE_FILE" 2>/dev/null)
if [[ -f "$LA_AUDIT_COVERAGE_FILE" ]] \
   && [[ "$(printf '%s' "$marker" | jq -r '.read')"  == "1" ]] \
   && [[ "$(printf '%s' "$marker" | jq -r '.total')" == "1" ]]; then
  pass "audit writes the §9 marker (read==total when every epic walked) [$marker]"
else
  fail "audit marker (complete) case: marker='$marker'"
fi

# ── case 12: a clean audit (no future-defer epic) REMOVES the marker ─────────
# Overwrite-or-remove: "nothing to report" must read as absent ⇒ engine null ⇒
# no chip — never a phantom 0/0, and a prior run's marker must not survive.
_reset
printf '{"read":3,"total":5}' > "$LA_AUDIT_COVERAGE_FILE"   # a STALE marker from a prior run
_seed epic-12 epic open ""  "" "No-defer epic"
_seed task-12 task open ""  epic-12 "Plain child"
bash "$HELPER" audit >/dev/null 2>&1
if [[ ! -f "$LA_AUDIT_COVERAGE_FILE" ]]; then
  pass "clean audit removes a stale marker (no future-defer epic ⇒ absent)"
else
  fail "clean audit removal case: marker still present = '$(cat "$LA_AUDIT_COVERAGE_FILE" 2>/dev/null)'"
fi

# ── case 13: marker total counts ALL future-defer epics (denominator) ────────
# Two future-defer epics, both readable ⇒ read==total==2.
_reset
rm -f "$LA_AUDIT_COVERAGE_FILE"
_seed epic-13a epic open "2099-01-01" "" "Deferred epic A"
_seed epic-13b epic open "2099-02-02" "" "Deferred epic B"
_seed task-13a task open ""           epic-13a "Hidden under A"
bash "$HELPER" audit >/dev/null 2>&1
marker=$(cat "$LA_AUDIT_COVERAGE_FILE" 2>/dev/null)
if [[ "$(printf '%s' "$marker" | jq -r '.read')"  == "2" ]] \
   && [[ "$(printf '%s' "$marker" | jq -r '.total')" == "2" ]]; then
  pass "marker total = every future-defer epic examined (2/2) [$marker]"
else
  fail "marker denominator case: marker='$marker'"
fi

# ── case 14: a bd-failed children walk ⇒ read<total (the §9 distrust signal) ──
# Two future-defer epics; bd fails on epic-14b's children walk ⇒ the audit read
# 1 of 2 ⇒ marker {"read":1,"total":2}, the "did NOT read everything" case the
# Board strip paints as a WARN chip. Tolerant: the audit still exits cleanly.
_reset
rm -f "$LA_AUDIT_COVERAGE_FILE"
_seed epic-14a epic open "2099-01-01" "" "Deferred epic A (readable)"
_seed epic-14b epic open "2099-02-02" "" "Deferred epic B (bd will fail)"
_seed task-14a task open ""           epic-14a "Hidden under A"
BD_FAIL_CHILDREN_FOR=epic-14b bash "$HELPER" audit >/dev/null 2>&1
marker=$(cat "$LA_AUDIT_COVERAGE_FILE" 2>/dev/null)
if [[ "$(printf '%s' "$marker" | jq -r '.read')"  == "1" ]] \
   && [[ "$(printf '%s' "$marker" | jq -r '.total')" == "2" ]]; then
  pass "bd-failed walk ⇒ read<total (1/2, the audit-didn't-read-everything signal) [$marker]"
else
  fail "marker partial-coverage case: marker='$marker'"
fi

if [[ "$FAILED" == "0" ]]; then
  echo "OK — all defer-cascade-audit.sh assertions pass"
  exit 0
else
  echo "FAIL — defer-cascade-audit.sh test assertions failed" >&2
  exit 1
fi
