#!/usr/bin/env bash
# beads-runner/test-gate-policy.sh — gate-policy.sh regression test
# (L2, claude-tools-1tu; epic claude-tools-kie).
#
# Drives gate-policy.sh against a STATEFUL FAKE `bd` on PATH — same shape as
# test-bd-stage.sh (the L1 sibling), so the two scripts share a test
# precedent: a hermetic, offline-friendly fake `bd` whose `label list --json`
# output is driven from flat files in $BDST.
#
# What this asserts (L2 acceptance):
#   • a bead with no preset label gets `auto-advance` (the autonomous-until-
#     stuck default — the workhorse case)
#   • a bead at any stage with no preset gets `auto-advance` (the v1 table is
#     uniform across stages)
#   • a bead with `preset:collaborative-stage` gets `gate-human:collaborative-stage`
#     (the only enforced pickup gate)
#   • an UNSTAGED bead (no stage:* label) with no preset still gets
#     `auto-advance` (legacy beads are not stranded; agents/gate-policy.md)
#   • a bead with an UNKNOWN `preset:*` label fails CLOSED →
#     `gate-human:unknown-preset` (an enricher typo must not quietly skip Brian)
#   • a bd subprocess failure fails CLOSED → `gate-human:bd-unavailable`
#     (exit 4; the runner branches on this explicitly)
#   • explain prints stage/preset/verdict on one line
#   • bare invocation exits 2 with usage; unknown subcommand exits 2
#   • the STAGE_ENUM in gate-policy.sh agrees with the one in bd-stage.sh
#     (anti-drift between L1 and L2 — adding a stage must touch both)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
HELPER="$SCRIPT_DIR/gate-policy.sh"
BD_STAGE="$SCRIPT_DIR/bd-stage.sh"
[[ -x "$HELPER" ]]   || { echo "test-gate-policy.sh: reject — $HELPER not executable" >&2; exit 2; }
[[ -x "$BD_STAGE" ]] || { echo "test-gate-policy.sh: reject — $BD_STAGE not executable (needed for the anti-drift enum check)" >&2; exit 2; }

FAILED=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; FAILED=1; }

WORK="$(mktemp -d 2>/dev/null)" || { echo "mktemp failed"; exit 70; }
trap 'rm -rf "$WORK"' EXIT

# ── stateful fake bd ─────────────────────────────────────────────────────────
# State: $BDST/<bead>.labels = newline-separated label list per bead. The
# special bead id `__bd_broken__` triggers a bd subprocess failure (exit 1
# from `bd label list`) so we can exercise the gate-policy.sh fail-CLOSED
# path without touching the underlying state files.
FAKEBIN="$WORK/bin"
export BDST="$WORK/bdst"
mkdir -p "$FAKEBIN" "$BDST"
cat > "$FAKEBIN/bd" <<'BDEOF'
#!/usr/bin/env bash
# Stateful fake bd — labels only. See test-gate-policy.sh for contract.
set -uo pipefail
cmd="${1:-}"; shift || true
sub="${1:-}"
case "$cmd" in
  label)
    shift || true
    case "$sub" in
      list)
        bead="${1:-}"
        [[ "$bead" == "__bd_broken__" ]] && exit 1
        f="$BDST/$bead.labels"
        if [[ -f "$f" ]]; then
          # Build a JSON array of the labels.
          awk 'BEGIN{printf "["} NR>1{printf ","} {printf "\"%s\"", $0} END{printf "]\n"}' "$f"
        else
          echo '[]'
        fi
        ;;
      add)
        bead="${1:-}"; lbl="${2:-}"
        f="$BDST/$bead.labels"
        touch "$f"
        grep -qxF "$lbl" "$f" || printf '%s\n' "$lbl" >> "$f"
        ;;
      remove)
        bead="${1:-}"; lbl="${2:-}"
        f="$BDST/$bead.labels"
        [[ -f "$f" ]] && grep -vxF "$lbl" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
        ;;
      *) : ;;
    esac
    ;;
  *) : ;;
esac
BDEOF
chmod +x "$FAKEBIN/bd"
export PATH="$FAKEBIN:$PATH"

# ── helper: write labels for a bead in one shot ──────────────────────────────
seed_labels() {
  local bead="$1"; shift
  local f="$BDST/$bead.labels"
  : > "$f"
  for lbl in "$@"; do printf '%s\n' "$lbl" >> "$f"; done
}

# ── decide: autonomous-until-stuck default (no preset label) ─────────────────
echo "── decide: autonomous-until-stuck default (no preset)"
for stage in idea ux design impl docs tests; do
  bead="auto-$stage"
  seed_labels "$bead" "stage:$stage"
  got="$("$HELPER" decide "$bead" 2>/dev/null)"
  if [[ "$got" == "auto-advance" ]]; then
    pass "stage:$stage with no preset → auto-advance"
  else
    fail "stage:$stage with no preset: expected auto-advance, got '$got'"
  fi
done

# ── decide: explicit preset:autonomous-until-stuck (also auto-advance) ───────
echo "── decide: explicit preset:autonomous-until-stuck"
seed_labels explicit-auto "stage:impl" "preset:autonomous-until-stuck"
got="$("$HELPER" decide explicit-auto 2>/dev/null)"
[[ "$got" == "auto-advance" ]] \
  && pass "explicit preset:autonomous-until-stuck → auto-advance" \
  || fail "explicit autonomous: expected auto-advance, got '$got'"

# ── decide: collaborative-stage preset → gate-human ──────────────────────────
echo "── decide: collaborative-stage preset"
for stage in idea ux design impl docs tests; do
  bead="collab-$stage"
  seed_labels "$bead" "stage:$stage" "preset:collaborative-stage"
  got="$("$HELPER" decide "$bead" 2>/dev/null)"
  if [[ "$got" == "gate-human:collaborative-stage" ]]; then
    pass "stage:$stage + preset:collaborative-stage → gate-human:collaborative-stage"
  else
    fail "stage:$stage collab: expected gate-human:collaborative-stage, got '$got'"
  fi
done

# ── decide: unstaged (legacy) bead with no preset → still auto-advance ───────
echo "── decide: unstaged (legacy) bead"
seed_labels legacy-bead   # no labels at all
got="$("$HELPER" decide legacy-bead 2>/dev/null)"
[[ "$got" == "auto-advance" ]] \
  && pass "unstaged + no preset → auto-advance (legacy not stranded)" \
  || fail "unstaged: expected auto-advance, got '$got'"

# Unstaged + collaborative-stage still gates (preset is the gate, not stage)
seed_labels legacy-collab "preset:collaborative-stage"
got="$("$HELPER" decide legacy-collab 2>/dev/null)"
[[ "$got" == "gate-human:collaborative-stage" ]] \
  && pass "unstaged + preset:collaborative-stage → gate-human:collaborative-stage" \
  || fail "unstaged collab: expected gate-human:collaborative-stage, got '$got'"

# ── decide: unknown preset → fail-CLOSED ─────────────────────────────────────
echo "── decide: unknown preset (fail-CLOSED)"
seed_labels typo-bead "stage:impl" "preset:weird-future-thing"
got="$("$HELPER" decide typo-bead 2>/dev/null)"
[[ "$got" == "gate-human:unknown-preset" ]] \
  && pass "unknown preset → gate-human:unknown-preset" \
  || fail "unknown preset: expected gate-human:unknown-preset, got '$got'"

# ── decide: bd subprocess failure → fail-CLOSED + exit 4 ─────────────────────
echo "── decide: bd subprocess failure (fail-CLOSED, exit 4)"
got="$("$HELPER" decide __bd_broken__ 2>/dev/null)"; rc=$?
[[ "$got" == "gate-human:bd-unavailable" ]] \
  && pass "bd-broken → gate-human:bd-unavailable" \
  || fail "bd-broken verdict: expected gate-human:bd-unavailable, got '$got'"
[[ "$rc" == "4" ]] \
  && pass "bd-broken exit code = 4 (caller must branch fail-CLOSED)" \
  || fail "bd-broken exit code: expected 4, got $rc"

# ── explain: prints stage/preset/verdict on one line ─────────────────────────
echo "── explain"
seed_labels expl-1 "stage:design" "preset:collaborative-stage"
out="$("$HELPER" explain expl-1 2>/dev/null)"
if [[ "$out" == *"stage=design"* && "$out" == *"preset=collaborative-stage"* && "$out" == *"gate-human:collaborative-stage"* ]]; then
  pass "explain prints stage + preset + verdict"
else
  fail "explain: missing fields in '$out'"
fi
# Default-on-absence rendering
seed_labels expl-2 "stage:idea"
out="$("$HELPER" explain expl-2 2>/dev/null)"
if [[ "$out" == *"preset=autonomous-until-stuck (default)"* && "$out" == *"auto-advance"* ]]; then
  pass "explain renders preset default-on-absence as '(default)'"
else
  fail "explain default-on-absence: got '$out'"
fi
# Unstaged rendering
seed_labels expl-3
out="$("$HELPER" explain expl-3 2>/dev/null)"
if [[ "$out" == *"stage=unstaged"* ]]; then
  pass "explain renders missing stage as 'unstaged'"
else
  fail "explain unstaged: got '$out'"
fi

# ── usage / dispatch ─────────────────────────────────────────────────────────
echo "── usage / dispatch"
"$HELPER" >/dev/null 2>&1; rc=$?
[[ "$rc" == "2" ]] && pass "bare invocation exits 2" || fail "bare invocation: expected 2, got $rc"
"$HELPER" weirdo >/dev/null 2>&1; rc=$?
[[ "$rc" == "2" ]] && pass "unknown subcommand exits 2" || fail "unknown subcommand: expected 2, got $rc"
"$HELPER" decide >/dev/null 2>&1; rc=$?
[[ "$rc" == "2" ]] && pass "decide with no bead exits 2" || fail "decide no-bead: expected 2, got $rc"
"$HELPER" explain >/dev/null 2>&1; rc=$?
[[ "$rc" == "2" ]] && pass "explain with no bead exits 2" || fail "explain no-bead: expected 2, got $rc"
out="$("$HELPER" --help 2>&1)"; rc=$?
[[ "$rc" == "0" && "$out" == *"gate-policy.sh"* ]] \
  && pass "--help exits 0 and prints usage" \
  || fail "--help: rc=$rc out='$out'"

# ── anti-drift: STAGE_ENUM in gate-policy.sh == STAGE_ENUM in bd-stage.sh ────
# This is the L1↔L2 contract: adding a stage means touching BOTH scripts;
# silent drift between the two would let a bd-stage `set` succeed for a
# stage that gate-policy doesn't know about (or vice versa).
echo "── anti-drift: STAGE_ENUM (L1) vs STAGE_ENUM (L2)"
l1_enum="$(grep -E '^STAGE_ENUM=' "$BD_STAGE" | head -1 | sed 's/.*=(//;s/).*//')"
l2_enum="$(grep -E '^STAGE_ENUM=' "$HELPER" | head -1 | sed 's/.*=(//;s/).*//')"
if [[ -n "$l1_enum" && "$l1_enum" == "$l2_enum" ]]; then
  pass "STAGE_ENUM agrees between bd-stage.sh and gate-policy.sh ($l1_enum)"
else
  fail "STAGE_ENUM drift — bd-stage.sh='$l1_enum' gate-policy.sh='$l2_enum'"
fi

# ── done ─────────────────────────────────────────────────────────────────────
if [[ $FAILED -eq 0 ]]; then
  echo ""
  echo "test-gate-policy.sh: ALL PASS"
  exit 0
else
  echo ""
  echo "test-gate-policy.sh: FAILURES (see FAIL lines above)" >&2
  exit 1
fi
