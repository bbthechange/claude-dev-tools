#!/bin/bash
# beads-runner/lib/test-git-pin-main.sh — focused unit test for git-pin-main.sh
# (claude-tools-trunkpin, the shared self-heal that pins the runner's working
# tree back to main at the loop top so a worker that wandered onto a feature
# branch does not make every later bead's auto-commit pile up there).
#
# The lib has ONE surface: pin_head_to_main [skip_flag] [trunk_branch]. We cover
# its contract directly in throwaway git repos so a refactor of the lib body is
# caught by a focused failure rather than an indirect runner-harness symptom:
#   - skip flag honored (no-op even when off-main)
#   - off-main + CLEAN tree            → switches to trunk (the self-heal)
#   - off-main + DIRTY tree            → does NOT switch, warns LOUDLY
#   - already on trunk                 → SILENT no-op, rc 0
#   - trunk ref absent (fresh/CI repo) → no-op (nothing to pin to)
#   - detached HEAD + clean            → switches to trunk
#   - custom trunk via $2 / env        → honored
#   - not a git work tree              → rc 0, silent (never aborts the caller)

set -u

PASS=0; FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git-pin-main.sh"
[[ -f "$LIB" ]] || { echo "test-git-pin-main: lib not found at $LIB" >&2; exit 70; }

# shellcheck source=git-pin-main.sh
source "$LIB"

declare -F pin_head_to_main >/dev/null \
  && pass "pin_head_to_main is defined after source" \
  || fail "pin_head_to_main NOT defined after source"

TMP_REPOS=()
_cleanup() { local d; for d in "${TMP_REPOS[@]:-}"; do [[ -n "$d" ]] && rm -rf "$d"; done; }
trap _cleanup EXIT

# mkrepo [trunk_name] — fresh repo with one tracked-file commit, current branch
# renamed to $1 (default `main`). Echoes the repo path. Always leaves a clean
# tree on the named trunk branch.
mkrepo() {
  local trunk="${1:-main}" r
  r="$(mktemp -d)"
  TMP_REPOS+=("$r")
  git -C "$r" init -q
  git -C "$r" config user.email "t@example.com"
  git -C "$r" config user.name "Test"
  git -C "$r" config commit.gpgsign false
  printf 'hello\n' > "$r/file.txt"
  git -C "$r" add file.txt
  git -C "$r" commit -q -m "init"
  git -C "$r" branch -M "$trunk"   # force-rename default branch → trunk
  echo "$r"
}
cur_branch() { git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "DETACHED"; }

echo "── skip flag: pin_head_to_main 1 is a no-op even when off-main ──"
R="$(mkrepo)"; git -C "$R" checkout -q -b feature
( cd "$R" && pin_head_to_main 1 ) 2>/dev/null
[[ "$(cur_branch "$R")" == "feature" ]] \
  && pass "skip=1 left HEAD on feature (no switch)" \
  || fail "skip=1 switched HEAD (got '$(cur_branch "$R")', want feature)"

echo "── off-main + CLEAN tree → self-heals back to main ──"
R="$(mkrepo)"; git -C "$R" checkout -q -b feature
_rc=0; ( cd "$R" && pin_head_to_main 0 ) 2>/dev/null || _rc=$?
[[ "$(cur_branch "$R")" == "main" ]] \
  && pass "clean off-main tree switched to main" \
  || fail "clean off-main tree did NOT switch (got '$(cur_branch "$R")', want main)"
[[ "$_rc" == "0" ]] && pass "self-heal returned rc 0" || fail "self-heal returned rc=$_rc (want 0)"

echo "── off-main + DIRTY tree → does NOT switch, warns loudly ──"
R="$(mkrepo)"; git -C "$R" checkout -q -b feature
printf 'uncommitted change\n' > "$R/file.txt"      # tracked-file modification
_out="$( ( cd "$R" && pin_head_to_main 0 ) 2>&1 )"
[[ "$(cur_branch "$R")" == "feature" ]] \
  && pass "dirty off-main tree stayed on feature (no unsafe switch)" \
  || fail "dirty off-main tree switched anyway (got '$(cur_branch "$R")', want feature)"
echo "$_out" | grep -qi "DIRTY" \
  && pass "dirty case emitted a LOUD warning" \
  || fail "dirty case did NOT warn (out='$_out')"

echo "── already on main → SILENT no-op, rc 0 ──"
R="$(mkrepo)"   # left on main
_out="$( ( cd "$R" && pin_head_to_main 0 ) 2>&1 )"; _rc=$?
[[ "$(cur_branch "$R")" == "main" && -z "$_out" && "$_rc" == "0" ]] \
  && pass "already-on-main: silent, rc 0, no switch" \
  || fail "already-on-main: out='$_out' rc=$_rc branch='$(cur_branch "$R")' (want silent/rc0/main)"

echo "── trunk ref absent (no 'main' branch) → no-op, nothing to pin to ──"
R="$(mkrepo trunk)"; git -C "$R" checkout -q -b feature   # trunk is named 'trunk', no 'main'
( cd "$R" && pin_head_to_main 0 ) 2>/dev/null              # default target main — absent
[[ "$(cur_branch "$R")" == "feature" ]] \
  && pass "absent main ref left HEAD on feature (no-op)" \
  || fail "absent main ref still switched (got '$(cur_branch "$R")', want feature)"

echo "── custom trunk via \$2 → honored ──"
# Reuse the 'trunk'-named repo above (still on feature, clean again).
git -C "$R" checkout -q feature 2>/dev/null; git -C "$R" checkout -q -- . 2>/dev/null
( cd "$R" && pin_head_to_main 0 trunk ) 2>/dev/null
[[ "$(cur_branch "$R")" == "trunk" ]] \
  && pass "\$2=trunk switched to the 'trunk' branch" \
  || fail "\$2=trunk did NOT switch (got '$(cur_branch "$R")', want trunk)"

echo "── custom trunk via RUNNER_MAIN_BRANCH env → honored ──"
R="$(mkrepo trunk)"; git -C "$R" checkout -q -b feature
( cd "$R" && RUNNER_MAIN_BRANCH=trunk pin_head_to_main 0 ) 2>/dev/null
[[ "$(cur_branch "$R")" == "trunk" ]] \
  && pass "RUNNER_MAIN_BRANCH=trunk switched to the 'trunk' branch" \
  || fail "RUNNER_MAIN_BRANCH env ignored (got '$(cur_branch "$R")', want trunk)"

echo "── detached HEAD + clean → self-heals to main ──"
R="$(mkrepo)"; SHA="$(git -C "$R" rev-parse HEAD)"; git -C "$R" checkout -q "$SHA"  # detach
[[ "$(cur_branch "$R")" == "DETACHED" ]] || fail "setup: expected detached HEAD"
( cd "$R" && pin_head_to_main 0 ) 2>/dev/null
[[ "$(cur_branch "$R")" == "main" ]] \
  && pass "detached clean HEAD switched to main" \
  || fail "detached clean HEAD did NOT switch (got '$(cur_branch "$R")', want main)"

echo "── not a git work tree → rc 0, silent (never aborts caller) ──"
D="$(mktemp -d)"; TMP_REPOS+=("$D")
_out="$( ( cd "$D" && pin_head_to_main 0 ) 2>&1 )"; _rc=$?
[[ "$_rc" == "0" && -z "$_out" ]] \
  && pass "non-git dir: rc 0, silent" \
  || fail "non-git dir: rc=$_rc out='$_out' (want rc0/silent)"

echo ""
echo "Result: $PASS passed, $FAIL failed"
[[ "$FAIL" == "0" ]] || exit 1
echo "ALL_PASS (git-pin-main lib unit — claude-tools-trunkpin)"
