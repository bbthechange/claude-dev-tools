#!/usr/bin/env bash
# beads-runner/test-gate-defer.sh — gate-defer.sh regression test
# (R3, claude-tools-vb7; epic claude-tools-ir7).
#
# Drives gate-defer.sh against a STATEFUL FAKE `bd` on PATH (same precedent
# as test-bd-stage.sh — bd init is too slow for unit work; the fake gives
# a hermetic, offline-friendly oracle for the label↔defer invariants this
# script enforces).
#
# What this asserts (R3 acceptance):
#   • apply stamps Deferred AND gate:<id> label in one step
#   • apply rejects an invalid gate-id shape (exit 2)
#   • lift default is DRY-RUN — nothing changes
#   • lift --commit clears Deferred AND removes the gate:<id> label on every
#     bead carrying it, and leaves other labels alone
#   • lift --commit on a gate with no beads is a clean 0-exit no-op
#   • list prints exactly the bead ids carrying gate:<id>
#   • a single bd-update failure during lift is reported (exit 3) without
#     stranding the rest of the cohort

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
HELPER="$SCRIPT_DIR/gate-defer.sh"
[[ -f "$HELPER" ]] || { echo "test-gate-defer.sh: reject — $HELPER not found" >&2; exit 2; }

FAILED=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; FAILED=1; }

WORK="$(mktemp -d 2>/dev/null)" || { echo "mktemp failed"; exit 70; }
trap 'rm -rf "$WORK"' EXIT

# ── stateful fake bd ─────────────────────────────────────────────────────────
# State per bead in $BDST:
#   $BDST/<bead>.labels — newline-separated labels
#   $BDST/<bead>.defer  — single line, the Deferred date (or absent/empty)
# Commands implemented (just what gate-defer.sh calls):
#   bd list --label <val> --no-pager --all --json
#   bd update <bead> --defer <date> --add-label <label>
#   bd update <bead> --defer "" --remove-label <label>
#   bd show <bead>            (emits "Deferred: <date>" if set)
#   bd update <bead> --fail   (test-only knob: makes the NEXT update on this
#                              bead exit non-zero — used for the partial-
#                              failure case)
FAKEBIN="$WORK/bin"
export BDST="$WORK/bdst"
mkdir -p "$FAKEBIN" "$BDST"

cat > "$FAKEBIN/bd" <<'BDEOF'
#!/usr/bin/env bash
set -uo pipefail

cmd="${1:-}"; shift || true

# Helper: rewrite labels file without <label> (in-place).
_remove_label() {
  local f="$1" lab="$2"
  [[ -f "$f" ]] || return 0
  local tmp="$f.tmp.$$"
  grep -Fxv "$lab" "$f" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$f"
}

case "$cmd" in
  list)
    # gate-defer only invokes: bd list --label <val> --no-pager --all --json
    want=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --label) want="${2:-}"; shift 2;;
        --label=*) want="${1#--label=}"; shift;;
        *) shift;;
      esac
    done
    [[ -z "$want" ]] && { printf '[]\n'; exit 0; }
    ids=()
    for f in "$BDST"/*.labels; do
      [[ -f "$f" ]] || continue
      if grep -Fxq "$want" "$f" 2>/dev/null; then
        b="$(basename "$f" .labels)"
        ids+=("$b")
      fi
    done
    # Stable sort so the test can compare deterministically.
    if [[ ${#ids[@]} -gt 0 ]]; then
      IFS=$'\n' sorted=($(printf '%s\n' "${ids[@]}" | sort))
    else
      sorted=()
    fi
    # Emit a JSON array of {"id":"…"} objects (gate-defer's jq parse keys on
    # ".[].id"). Minimal shape — we don't model other bd fields.
    printf '['
    first=1
    for id in "${sorted[@]:-}"; do
      [[ -z "$id" ]] && continue
      if [[ "$first" == 1 ]]; then first=0; else printf ','; fi
      printf '{"id":"%s"}' "$id"
    done
    printf ']\n'
    ;;

  show)
    bead="${1:-}"; shift || true
    [[ -n "$bead" ]] || exit 2
    f="$BDST/$bead.defer"
    if [[ -s "$f" ]]; then
      printf 'Deferred: %s\n' "$(cat "$f")"
    fi
    ;;

  update)
    bead="${1:-}"; shift || true
    [[ -n "$bead" ]] || exit 2
    # Test-only knob: `bd update <bead> --fail` arms a one-shot failure for
    # the NEXT non-fail update on this bead.
    if [[ "${1:-}" == "--fail" ]]; then
      touch "$BDST/$bead.failnext"
      exit 0
    fi
    # If a one-shot failure was armed, consume it and exit non-zero.
    if [[ -f "$BDST/$bead.failnext" ]]; then
      rm -f "$BDST/$bead.failnext"
      exit 1
    fi
    # Parse the flags gate-defer.sh actually uses.
    defer=""
    set_defer=0
    add_labels=()
    rm_labels=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --defer)         defer="${2:-}"; set_defer=1; shift 2;;
        --add-label)     add_labels+=("${2:-}"); shift 2;;
        --remove-label)  rm_labels+=("${2:-}"); shift 2;;
        *) shift;;
      esac
    done
    f_labels="$BDST/$bead.labels"
    f_defer="$BDST/$bead.defer"
    touch "$f_labels"
    if [[ $set_defer -eq 1 ]]; then
      if [[ -z "$defer" ]]; then
        rm -f "$f_defer"
      else
        printf '%s\n' "$defer" > "$f_defer"
      fi
    fi
    for l in "${add_labels[@]:-}"; do
      [[ -z "$l" ]] && continue
      grep -Fxq "$l" "$f_labels" 2>/dev/null || printf '%s\n' "$l" >> "$f_labels"
    done
    for l in "${rm_labels[@]:-}"; do
      [[ -z "$l" ]] && continue
      _remove_label "$f_labels" "$l"
    done
    ;;

  *) : ;;
esac
exit 0
BDEOF
chmod +x "$FAKEBIN/bd"
export PATH="$FAKEBIN:$PATH"

# Helpers used by cases.
labels_of() {
  local f="$BDST/$1.labels"
  [[ -f "$f" ]] || return 0
  cat "$f" 2>/dev/null
}
defer_of() {
  local f="$BDST/$1.defer"
  [[ -f "$f" ]] || return 0
  cat "$f" 2>/dev/null
}

# ── case 1: apply stamps Deferred AND gate:<id> in one step ─────────────────
B1="bead-1"
if bash "$HELPER" apply impl-gate-2026-04-22 "$B1" 2026-07-01 >/dev/null 2>&1; then
  if [[ "$(defer_of "$B1")" == "2026-07-01" ]] \
     && labels_of "$B1" | grep -Fxq "gate:impl-gate-2026-04-22"; then
    pass "apply stamps Deferred AND gate:<id> label"
  else
    fail "apply: defer='$(defer_of "$B1")' labels='$(labels_of "$B1")'"
  fi
else
  fail "apply exited non-zero on a valid input"
fi

# ── case 2: apply rejects an invalid gate-id shape ──────────────────────────
err=$(bash "$HELPER" apply BAD_GATE "$B1" 2026-07-01 2>&1)
rc=$?
if [[ "$rc" == "2" ]] && printf '%s' "$err" | grep -q "must be"; then
  pass "apply rejects an invalid gate-id shape (exit 2)"
else
  fail "apply BAD_GATE: rc=$rc err='$err' (expected rc=2)"
fi

# ── case 3: lift default is DRY-RUN — nothing changes ──────────────────────
B2="bead-2"; B3="bead-3"
bash "$HELPER" apply impl-gate-2026-04-22 "$B2" 2026-07-01 >/dev/null 2>&1
bash "$HELPER" apply impl-gate-2026-04-22 "$B3" 2026-07-01 >/dev/null 2>&1
# Also stamp a foreign label on B2 to confirm lift won't touch it later.
bd update "$B2" --add-label "runner-reliability" >/dev/null 2>&1

out=$(bash "$HELPER" lift impl-gate-2026-04-22 2>&1)
rc=$?
if [[ "$rc" == "0" ]] \
   && printf '%s' "$out" | grep -q "DRY-RUN" \
   && [[ "$(defer_of "$B1")" == "2026-07-01" ]] \
   && [[ "$(defer_of "$B2")" == "2026-07-01" ]] \
   && labels_of "$B1" | grep -Fxq "gate:impl-gate-2026-04-22"; then
  pass "lift default is DRY-RUN (no state change)"
else
  fail "lift dry-run: rc=$rc out='$out' B1.defer='$(defer_of "$B1")'"
fi

# ── case 4: lift --commit clears Deferred AND removes the gate label ────────
out=$(bash "$HELPER" lift impl-gate-2026-04-22 --commit 2>&1)
rc=$?
ok=1
for b in "$B1" "$B2" "$B3"; do
  [[ -z "$(defer_of "$b")" ]] || { ok=0; break; }
  ! labels_of "$b" | grep -Fxq "gate:impl-gate-2026-04-22" || { ok=0; break; }
done
# Foreign label on B2 must survive (lift is targeted, not a label wipe).
labels_of "$B2" | grep -Fxq "runner-reliability" || ok=0
if [[ "$rc" == "0" && "$ok" == "1" ]]; then
  pass "lift --commit clears defer + label, leaves other labels alone"
else
  fail "lift commit: rc=$rc out='$out' (B1 d='$(defer_of "$B1")' l='$(labels_of "$B1")')"
fi

# ── case 5: lift --commit on a gate with no beads is a clean no-op ──────────
out=$(bash "$HELPER" lift impl-gate-2099-01-01 --commit 2>&1)
rc=$?
if [[ "$rc" == "0" ]] && printf '%s' "$out" | grep -q "no beads"; then
  pass "lift --commit on empty cohort is a clean no-op (exit 0)"
else
  fail "lift empty cohort: rc=$rc out='$out'"
fi

# ── case 6: list prints exactly the beads carrying gate:<id> ────────────────
B4="bead-4"; B5="bead-5"
bash "$HELPER" apply impl-gate-2026-09-01 "$B4" 2026-12-31 >/dev/null 2>&1
bash "$HELPER" apply impl-gate-2026-09-01 "$B5" 2026-12-31 >/dev/null 2>&1
out=$(bash "$HELPER" list impl-gate-2026-09-01 2>/dev/null)
ids=$(printf '%s\n' "$out" | sort | tr '\n' ' ')
if [[ "$ids" == "$B4 $B5 " ]]; then
  pass "list prints exactly the beads carrying gate:<id>"
else
  fail "list: got '$ids' (expected '$B4 $B5 ')"
fi

# ── case 7: a single update failure during lift is reported (exit 3) ────────
# Arm a one-shot failure on B5, then lift. B4 should still be cleared,
# and the script should report exit 3 with the failure surfaced on stderr.
bd update "$B5" --fail >/dev/null 2>&1
out=$(bash "$HELPER" lift impl-gate-2026-09-01 --commit 2>&1)
rc=$?
ok=1
[[ -z "$(defer_of "$B4")" ]] || ok=0
! labels_of "$B4" | grep -Fxq "gate:impl-gate-2026-09-01" || ok=0
# B5 should still carry its defer + label because the update failed.
[[ "$(defer_of "$B5")" == "2026-12-31" ]] || ok=0
labels_of "$B5" | grep -Fxq "gate:impl-gate-2026-09-01" || ok=0
if [[ "$rc" == "3" && "$ok" == "1" ]] && printf '%s' "$out" | grep -q "failed=1"; then
  pass "single update failure during lift → exit 3, others still cleared"
else
  fail "partial fail: rc=$rc out='$out' B4.d='$(defer_of "$B4")' B5.d='$(defer_of "$B5")'"
fi

# ── case 8: bare invocation prints usage and exits 2 ────────────────────────
bash "$HELPER" >/dev/null 2>&1
rc=$?
if [[ "$rc" == "2" ]]; then
  pass "bare invocation exits 2 (usage)"
else
  fail "bare invocation: rc=$rc (expected 2)"
fi

if [[ "$FAILED" == "0" ]]; then
  echo "OK — all gate-defer.sh assertions pass"
  exit 0
else
  echo "FAIL — gate-defer.sh test assertions failed" >&2
  exit 1
fi
