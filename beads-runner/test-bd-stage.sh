#!/usr/bin/env bash
# beads-runner/test-bd-stage.sh — bd-stage.sh regression test
# (L1, claude-tools-u6s; epic claude-tools-kie).
#
# Drives bd-stage.sh against a STATEFUL FAKE `bd` on PATH — the established
# T5.5 / I4 test precedent (see lib/test-i4-feedback-return.sh:267). The real
# `bd init` pulls a Dolt schema from a remote and is far too slow for a unit
# test; a fake `bd` that maintains the label/issue tables in flat files in
# $BDST gives us a hermetic, offline-friendly oracle for the contract this
# script enforces (the "exactly one stage:* label per bead" invariant and the
# closed enum).
#
# What this asserts (L1 acceptance):
#   • set on a fresh bead writes exactly one stage:* label
#   • set on a staged bead removes the prior stage:* and adds the new one
#   • set is idempotent on the same value (no churn)
#   • set HEALS a manually-broken invariant (2 stage:* labels → exactly 1)
#   • get prints the bare stage value (no 'stage:' prefix) on a staged bead
#   • get on an unstaged (legacy) bead prints nothing and exits 0
#   • get exits 3 on a still-broken invariant (callers cannot trust a value
#     they did not see — `set` is the only sanctioned heal path)
#   • list returns only beads at the named stage
#   • the closed enum rejects ad-hoc strings on both set and list (exit 2)
#   • bare invocation exits 2 with usage

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
HELPER="$SCRIPT_DIR/bd-stage.sh"
[[ -x "$HELPER" ]] || { echo "test-bd-stage.sh: reject — $HELPER not executable" >&2; exit 2; }

FAILED=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; FAILED=1; }

WORK="$(mktemp -d 2>/dev/null)" || { echo "mktemp failed"; exit 70; }
trap 'rm -rf "$WORK"' EXIT

# ── stateful fake bd ─────────────────────────────────────────────────────────
# State: $BDST/<bead>.labels = newline-separated label list per bead.
# Commands implemented (just enough to drive bd-stage.sh end-to-end):
#   bd label list <bead> [--json]
#   bd label add <bead> <label>
#   bd label remove <bead> <label>
#   bd list --label <label> --flat --no-pager --all
# Anything else exits 0 silently — the helper script never invokes anything
# else and the test should not depend on side effects of unexposed paths.
FAKEBIN="$WORK/bin"
export BDST="$WORK/bdst"
mkdir -p "$FAKEBIN" "$BDST"
cat > "$FAKEBIN/bd" <<'BDEOF'
#!/usr/bin/env bash
# Stateful fake bd — labels only. See test-bd-stage.sh for contract.
set -uo pipefail

cmd="${1:-}"; shift || true
sub="${1:-}"
case "$cmd" in
  label)
    shift || true
    case "$sub" in
      list)
        bead="${1:-}"; shift || true
        json=0
        for a in "$@"; do [[ "$a" == "--json" ]] && json=1; done
        f="$BDST/$bead.labels"
        labels=()
        if [[ -s "$f" ]]; then
          while IFS= read -r l; do
            [[ -n "$l" ]] && labels+=("$l")
          done < "$f"
        fi
        if [[ "$json" == 1 ]]; then
          # Compose a JSON array of strings. Newline-tolerant; no jq dependency
          # in the fake (it must run even when jq is missing on the host).
          printf '['
          first=1
          for l in "${labels[@]:-}"; do
            [[ -z "$l" ]] && continue
            if [[ "$first" == 1 ]]; then first=0; else printf ','; fi
            # Escape backslash + double-quote (sufficient for our label set;
            # the closed stage enum cannot contain either).
            esc="${l//\\/\\\\}"; esc="${esc//\"/\\\"}"
            printf '"%s"' "$esc"
          done
          printf ']\n'
        else
          for l in "${labels[@]:-}"; do
            [[ -n "$l" ]] && printf '  - %s\n' "$l"
          done
        fi
        ;;
      add)
        bead="${1:-}"; label="${2:-}"
        [[ -n "$bead" && -n "$label" ]] || exit 2
        f="$BDST/$bead.labels"
        touch "$f"
        # Idempotent — bd's real behavior is "no-op if present".
        grep -Fxq "$label" "$f" 2>/dev/null || printf '%s\n' "$label" >> "$f"
        ;;
      remove)
        bead="${1:-}"; label="${2:-}"
        [[ -n "$bead" && -n "$label" ]] || exit 2
        f="$BDST/$bead.labels"
        [[ -f "$f" ]] || exit 0
        tmp="$f.tmp.$$"
        grep -Fxv "$label" "$f" > "$tmp" 2>/dev/null || true
        mv "$tmp" "$f"
        ;;
      *) : ;;
    esac
    ;;
  list)
    # Parse --label <val>; ignore other flags (the test only needs label filter).
    # NOTE: do NOT shift here — $sub at this point IS the first flag, e.g.
    # `--label`, which the loop below consumes. Top-level shift already moved
    # past `list` itself.
    want=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --label) want="${2:-}"; shift 2;;
        --label=*) want="${1#--label=}"; shift;;
        *) shift;;
      esac
    done
    [[ -z "$want" ]] && exit 0
    for f in "$BDST"/*.labels; do
      [[ -f "$f" ]] || continue
      if grep -Fxq "$want" "$f" 2>/dev/null; then
        b="$(basename "$f" .labels)"
        # A simple bd-list-like line that bd-stage list passes through; the
        # test asserts only that the bead id appears in the output.
        printf '%s\n' "$b"
      fi
    done
    ;;
  create)
    # Used by mk_bead helper below — emits a fake id.
    id="t-$$-$RANDOM"
    json=0
    for a in "$@"; do [[ "$a" == "--json" ]] && json=1; done
    if [[ "$json" == 1 ]]; then
      printf '{"id":"%s"}\n' "$id"
    else
      printf '%s\n' "$id"
    fi
    ;;
  *) : ;;
esac
exit 0
BDEOF
chmod +x "$FAKEBIN/bd"

export PATH="$FAKEBIN:$PATH"

# Helper: invent a bead id (fake bd's `create` returns one).
mk_bead() {
  local id
  id=$(bd create --title="t" --description="d" --type=task --json 2>/dev/null)
  # Strip JSON wrapper.
  printf '%s' "$id" | sed -E 's/.*"id":"([^"]+)".*/\1/'
}

# Helper: print all stage:* labels currently on a bead, one per line.
stage_labels() {
  local f="$BDST/$1.labels"
  [[ -f "$f" ]] || return 0
  grep -E '^stage:' "$f" 2>/dev/null || true
}

# ── case 1: set on fresh bead writes exactly one stage:* label ──────────────
B1=$(mk_bead)
[[ -n "$B1" ]] || { echo "could not invent bead id"; exit 70; }

if bash "$HELPER" set "$B1" idea >/dev/null 2>&1; then
  labels=$(stage_labels "$B1")
  count=$(printf '%s\n' "$labels" | grep -c .)
  if [[ "$count" == "1" && "$labels" == "stage:idea" ]]; then
    pass "set on fresh bead writes exactly one stage:idea label"
  else
    fail "set on fresh bead: expected stage:idea once; got count=$count labels='$labels'"
  fi
else
  fail "set on fresh bead exited non-zero"
fi

# ── case 2: set on a staged bead transitions (removes prior, adds new) ──────
if bash "$HELPER" set "$B1" design >/dev/null 2>&1; then
  labels=$(stage_labels "$B1")
  count=$(printf '%s\n' "$labels" | grep -c .)
  if [[ "$count" == "1" && "$labels" == "stage:design" ]]; then
    pass "set transitions idea → design; exactly one stage:* remains"
  else
    fail "transition idea → design: expected stage:design once; got count=$count labels='$labels'"
  fi
else
  fail "transition set exited non-zero"
fi

# ── case 3: set is idempotent for the same value ────────────────────────────
if bash "$HELPER" set "$B1" design >/dev/null 2>&1; then
  labels=$(stage_labels "$B1")
  count=$(printf '%s\n' "$labels" | grep -c .)
  if [[ "$count" == "1" && "$labels" == "stage:design" ]]; then
    pass "set is idempotent on the same value"
  else
    fail "idempotent set: expected stage:design once; got count=$count labels='$labels'"
  fi
else
  fail "idempotent set exited non-zero"
fi

# ── case 4: set heals a manually-broken invariant ───────────────────────────
B2=$(mk_bead)
bd label add "$B2" stage:idea
bd label add "$B2" stage:ux
pre=$(stage_labels "$B2" | grep -c .)
[[ "$pre" == "2" ]] || fail "case-4 precondition: expected 2 stage:* labels before heal; got $pre"

if bash "$HELPER" set "$B2" impl >/dev/null 2>&1; then
  labels=$(stage_labels "$B2")
  count=$(printf '%s\n' "$labels" | grep -c .)
  if [[ "$count" == "1" && "$labels" == "stage:impl" ]]; then
    pass "set heals a broken invariant (2 labels → exactly 1)"
  else
    fail "heal: expected stage:impl once; got count=$count labels='$labels'"
  fi
else
  fail "heal set exited non-zero"
fi

# ── case 5: get prints bare value, exits 0 ──────────────────────────────────
out=$(bash "$HELPER" get "$B1" 2>/dev/null)
rc=$?
if [[ "$rc" == "0" && "$out" == "design" ]]; then
  pass "get prints bare stage value (no 'stage:' prefix)"
else
  fail "get bead at design: rc=$rc out='$out' (expected rc=0 out='design')"
fi

# ── case 6: get on unstaged bead is empty + exit 0 ──────────────────────────
B3=$(mk_bead)
out=$(bash "$HELPER" get "$B3" 2>/dev/null)
rc=$?
if [[ "$rc" == "0" && -z "$out" ]]; then
  pass "get on unstaged bead is empty + exit 0"
else
  fail "get unstaged: rc=$rc out='$out' (expected rc=0 empty)"
fi

# ── case 7: get exits 3 on a still-broken invariant ─────────────────────────
B4=$(mk_bead)
bd label add "$B4" stage:ux
bd label add "$B4" stage:tests
bash "$HELPER" get "$B4" >/dev/null 2>&1
rc=$?
if [[ "$rc" == "3" ]]; then
  pass "get exits 3 on invariant violation (two stage:* labels)"
else
  fail "get on broken bead: rc=$rc (expected 3)"
fi

# ── case 8: list returns the right beads only ───────────────────────────────
B5=$(mk_bead); B6=$(mk_bead)
bash "$HELPER" set "$B5" idea >/dev/null 2>&1
bash "$HELPER" set "$B6" docs >/dev/null 2>&1
out=$(bash "$HELPER" list idea 2>/dev/null)
if printf '%s' "$out" | grep -q "$B5" && ! printf '%s' "$out" | grep -q "$B6"; then
  pass "list idea includes the idea-bead and excludes the docs-bead"
else
  fail "list idea: did not isolate stage:idea (out: $out)"
fi

# ── case 9: closed enum rejects ad-hoc strings ──────────────────────────────
B7=$(mk_bead)
err=$(bash "$HELPER" set "$B7" frobnicate 2>&1)
rc=$?
if [[ "$rc" == "2" ]] && printf '%s' "$err" | grep -q "closed stage enum"; then
  pass "set rejects an out-of-enum stage (exit 2)"
else
  fail "set frobnicate: rc=$rc (expected 2 with 'closed stage enum') err='$err'"
fi

err=$(bash "$HELPER" list zzz 2>&1)
rc=$?
if [[ "$rc" == "2" ]] && printf '%s' "$err" | grep -q "closed stage enum"; then
  pass "list rejects an out-of-enum stage (exit 2)"
else
  fail "list zzz: rc=$rc (expected 2) err='$err'"
fi

# ── case 10: bare invocation prints usage and exits 2 ───────────────────────
bash "$HELPER" >/dev/null 2>&1
rc=$?
if [[ "$rc" == "2" ]]; then
  pass "bare invocation exits 2 (usage)"
else
  fail "bare invocation: rc=$rc (expected 2)"
fi

if [[ "$FAILED" == "0" ]]; then
  echo "OK — all bd-stage.sh assertions pass"
  exit 0
else
  echo "FAIL — bd-stage.sh test assertions failed" >&2
  exit 1
fi
