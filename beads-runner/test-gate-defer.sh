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
#
# Plus the gate-PLACEMENT metadata write seam (claude-tools-escz, DESIGN J §6):
#   • apply --why/--unblock/--owner/--scope records the Gate's metadata via the
#     J1 gate-meta-set op, retrievable verbatim via gate-meta-get (the bead's
#     acceptance)
#   • a metadata flag WITHOUT --why is rejected (exit 2) and places NO label
#   • bare apply (no flags) writes NO metadata row — backward-compatible, the
#     label↔defer coupling stays the source of truth
#   • a gate-meta-set failure after the label lands → exit 5, label still placed

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

# ── fake co_request — the engine for the gate-meta-set/-get round-trip ───────
# (claude-tools-escz) cmd_apply's metadata seam calls `co_request <bearer>
# gate-meta-set <json>` (the J1 op). gate-defer.sh's _ensure_co_request finds
# this EXPORTED function FIRST (command -v co_request) and uses it, so the test
# never sources the real transport and never sets COORDINATOR_URL. The fake is
# a faithful stand-in for cf/src/gate-meta.js: it enforces the same write gate
# (id shape, why-required, scope ∈ {task,cohort}, scope defaults to task), keys
# one row per gate id under $GMSTORE, and answers gate-meta-get with the engine's
# `{gate:<obj>|null}` shape. The sentinel id `force-fail` returns non-zero to
# exercise the exit-5 (label-placed-but-metadata-failed) path.
export GMSTORE="$WORK/gmstore"
mkdir -p "$GMSTORE"
co_request() {
  local op="${2:-}"
  case "$op" in
    gate-meta-set)
      local json="${3:-}" id why scope
      id="$(printf '%s' "$json" | jq -r '.id // .gate_id // empty' 2>/dev/null)"
      [[ "$id" == "force-fail" ]] && return 1        # sentinel: simulate engine reject
      [[ "$id" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
      why="$(printf '%s' "$json" | jq -r '.why // empty' 2>/dev/null)"
      [[ -n "${why// /}" ]] || return 1
      scope="$(printf '%s' "$json" | jq -r '.scope // "task"' 2>/dev/null)"
      [[ "$scope" == "task" || "$scope" == "cohort" ]] || return 1
      printf '%s' "$json" \
        | jq -c --arg scope "$scope" \
            '{id:(.id // .gate_id), why:.why, unblock_condition:(.unblock_condition // null), owner:(.owner // null), scope:$scope}' \
            > "$GMSTORE/$id.json" 2>/dev/null
      return 0 ;;
    gate-meta-get)
      local id="${3:-}"
      if [[ -n "$id" ]]; then
        if [[ -f "$GMSTORE/$id.json" ]]; then
          jq -c '{gate: .}' "$GMSTORE/$id.json" 2>/dev/null
        else
          printf '{"gate":null}\n'
        fi
      else
        printf '{"gates":[]}\n'
      fi
      return 0 ;;
    *) return 2 ;;
  esac
}
export -f co_request

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

# ── case 9: apply --why/... records metadata, retrievable via gate-meta-get ──
# The bead's acceptance: "placing a gate records its metadata (why/unblock/owner)
# retrievable via gate-meta-get." Round-trip through the fake engine.
B6="bead-6"
out=$(bash "$HELPER" apply audio-redesign "$B6" 2026-08-01 \
        --why "blocked on the audio redesign decision" \
        --unblock "design J ratified" \
        --owner "agent:impl" \
        --scope cohort 2>&1)
rc=$?
got=$(co_request bearer-test gate-meta-get audio-redesign 2>/dev/null)
ok=1
[[ "$rc" == "0" ]] || ok=0
# label + defer still placed (existing behavior preserved)
[[ "$(defer_of "$B6")" == "2026-08-01" ]] || ok=0
labels_of "$B6" | grep -Fxq "gate:audio-redesign" || ok=0
# metadata round-trips verbatim
[[ "$(printf '%s' "$got" | jq -r '.gate.why')"               == "blocked on the audio redesign decision" ]] || ok=0
[[ "$(printf '%s' "$got" | jq -r '.gate.unblock_condition')" == "design J ratified" ]] || ok=0
[[ "$(printf '%s' "$got" | jq -r '.gate.owner')"             == "agent:impl" ]] || ok=0
[[ "$(printf '%s' "$got" | jq -r '.gate.scope')"             == "cohort" ]] || ok=0
[[ "$(printf '%s' "$got" | jq -r '.gate.id')"                == "audio-redesign" ]] || ok=0
if [[ "$ok" == "1" ]]; then
  pass "apply --why/--unblock/--owner/--scope records metadata (gate-meta-get round-trip)"
else
  fail "apply+meta: rc=$rc out='$out' get='$got' defer='$(defer_of "$B6")'"
fi

# ── case 9b: scope defaults to task when --scope omitted ────────────────────
B7="bead-7"
bash "$HELPER" apply single-task-gate "$B7" 2026-08-15 --why "waiting on Brian" >/dev/null 2>&1
got=$(co_request bearer-test gate-meta-get single-task-gate 2>/dev/null)
if [[ "$(printf '%s' "$got" | jq -r '.gate.scope')" == "task" ]] \
   && [[ "$(printf '%s' "$got" | jq -r '.gate.unblock_condition')" == "null" ]]; then
  pass "scope defaults to task; absent unblock surfaces null (B.4 honest absence)"
else
  fail "scope default: get='$got'"
fi

# ── case 10: a metadata flag WITHOUT --why is rejected (exit 2), no label ────
B8="bead-8"
err=$(bash "$HELPER" apply nowhy-gate "$B8" 2026-08-01 --owner "agent:impl" 2>&1)
rc=$?
ok=1
[[ "$rc" == "2" ]] || ok=0
printf '%s' "$err" | grep -q "requires --why" || ok=0
# label must NOT be placed — the local reject fires BEFORE bd is touched
labels_of "$B8" | grep -Fxq "gate:nowhy-gate" && ok=0
[[ -z "$(defer_of "$B8")" ]] || ok=0
if [[ "$ok" == "1" ]]; then
  pass "metadata flag without --why → exit 2, no label half-placed"
else
  fail "nowhy: rc=$rc err='$err' labels='$(labels_of "$B8")' defer='$(defer_of "$B8")'"
fi

# ── case 11: bare apply (no flags) writes NO metadata row (backward compat) ──
B9="bead-9"
bash "$HELPER" apply plain-gate "$B9" 2026-09-01 >/dev/null 2>&1
rc=$?
ok=1
[[ "$rc" == "0" ]] || ok=0
labels_of "$B9" | grep -Fxq "gate:plain-gate" || ok=0
# no metadata row should exist for a flagless apply
[[ ! -f "$GMSTORE/plain-gate.json" ]] || ok=0
if [[ "$ok" == "1" ]]; then
  pass "bare apply writes no metadata row (label↔defer stays the source of truth)"
else
  fail "plain apply: rc=$rc label='$(labels_of "$B9")' metafile-exists=$([[ -f "$GMSTORE/plain-gate.json" ]] && echo yes || echo no)"
fi

# ── case 12: gate-meta-set failure after the label lands → exit 5 ────────────
# Sentinel gate id `force-fail` makes the fake engine reject the write; the
# label (source of truth) must still be placed, and apply exits 5.
B10="bead-10"
out=$(bash "$HELPER" apply force-fail "$B10" 2026-09-01 --why "real why" 2>&1)
rc=$?
ok=1
[[ "$rc" == "5" ]] || ok=0
[[ "$(defer_of "$B10")" == "2026-09-01" ]] || ok=0
labels_of "$B10" | grep -Fxq "gate:force-fail" || ok=0
[[ ! -f "$GMSTORE/force-fail.json" ]] || ok=0
printf '%s' "$out" | grep -q "WARN" || ok=0
if [[ "$ok" == "1" ]]; then
  pass "gate-meta-set failure → exit 5, label still placed (degraded, B.4)"
else
  fail "force-fail: rc=$rc out='$out' defer='$(defer_of "$B10")' label='$(labels_of "$B10")'"
fi

# ── case 13: a value-flag with NO value exits 2 (no infinite-loop hang) ─────
# Regression for the claude-tools-escz review finding: a trailing `--why` with
# no value used to spin forever (shift 2 atomic-fail). Must be a clean exit 2.
# Wrap in `timeout` so a regression FAILS the test instead of hanging the suite.
B11="bead-11"
# Use timeout when available so a hang regression FAILS (rc 124) instead of
# wedging the suite. Avoid an empty-array expansion (`"${RUN_T[@]}"` trips
# `set -u` on bash 3.2 = stock macOS /bin/bash, which run-tests.sh uses).
if command -v timeout >/dev/null 2>&1; then
  err=$(timeout 10 bash "$HELPER" apply trailing-flag-gate "$B11" 2026-09-01 --why 2>&1)
else
  err=$(bash "$HELPER" apply trailing-flag-gate "$B11" 2026-09-01 --why 2>&1)
fi
rc=$?
if [[ "$rc" == "2" ]] && printf '%s' "$err" | grep -q "needs a value"; then
  pass "trailing --why with no value → exit 2 (no hang)"
else
  fail "trailing --why: rc=$rc err='$err' (expected rc=2; rc=124 = timed-out hang regression)"
fi

if [[ "$FAILED" == "0" ]]; then
  echo "OK — all gate-defer.sh assertions pass"
  exit 0
else
  echo "FAIL — gate-defer.sh test assertions failed" >&2
  exit 1
fi
