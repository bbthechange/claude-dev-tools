#!/bin/bash
# beads-runner/run-tests.sh — THE ONE OFFLINE REGRESSION GATE
# TEST-INFRA (claude-tools-rznj.1). TESTING-STRATEGY.md §7.1.
#
# Runs ALL offline, deterministic test tiers (T1–T7 in the strategy's §2 table)
# with a unified per-tier tally and a SINGLE exit code, superseding the partial
# tmp/run-all-tests.sh (which only looped lib/). This is the regression gate
# the §5 acceptance bar names: "the full offline suite is green" before bd close.
#
# WHAT IT RUNS (every tier is offline + deterministic — no network):
#   cf          (cd cf && npm test)              — T2 JS-engine differential (vitest/workerd)
#   lib         lib/test-*.sh                    — T1 bash-oracle + T3 web view-model
#   daemon      daemon/test-*.sh                 — T5 daemon
#   hooks       hooks/test-*.sh                  — close-checklist & friends
#   agents      agents/test-*.sh                 — specialist hat tests
#   top         beads-runner/test-*.sh           — top-level runner/gate/intake tests
#   conformance conformance/run-conformance.sh   — T6 runner BC conformance
#   contract    cf/test/conformance-*.sh         — machine-state (D2) + UX-v2 A–D guardian (T7)
#
# DISCOVERY IS BY GLOB, NEVER A HARDCODED LIST (§7.1): a new test-*.sh under any
# enrolled directory, or a new cf/test/conformance-*.sh, auto-joins the gate.
#
# WHAT IT DOES NOT RUN — T8 (the ONE networked tier), which stays manual at close:
#   verify-pages-deploy.sh, cf/pages-dev/verify.sh, and any live-Worker probe.
#   (lib/test-co-http-transport.sh is enrolled: its PART A/B are offline/local
#   emulation and its live PART C SKIPs by-design without a prod token — §8.)
#
# TALLY SEMANTICS: pass/fail counts are *runnable units* — one bash test file is
# one unit (pass == exit 0); the cf vitest run and the conformance runner are each
# one unit (they fan out internally; on failure their full output is printed).
#
# Usage:
#   bash beads-runner/run-tests.sh                 # full gate (all tiers)
#   bash beads-runner/run-tests.sh --tier lib      # one tier (repeatable, or comma-list)
#   bash beads-runner/run-tests.sh --tier lib,cf   #   comma-list; --tier=lib,cf also works
#   bash beads-runner/run-tests.sh --changed       # only tiers touched by the git diff (pre-close speed)
#   bash beads-runner/run-tests.sh --list          # list tier names and exit
#   bash beads-runner/run-tests.sh --help
#
# Exit: 0 iff every selected unit passed; non-zero otherwise (and the RED summary
# names the failing tier(s)). 2 == bad usage / nothing to run.
set -u

BR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── colors (used unconditionally, matching the existing test convention) ──
C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_C=$'\033[36m'; C_0=$'\033[0m'

# ── canonical tier order (full run executes in this order) ──
ALL_TIERS=(lib daemon hooks agents top conformance contract cf)

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

list_tiers() {
  echo "tiers (canonical run order):"
  local t
  for t in "${ALL_TIERS[@]}"; do echo "  $t"; done
}

# ════════════════════════════════════════════════════════════════════════════
# arg parsing
# ════════════════════════════════════════════════════════════════════════════
# SELECTED is a space-padded set of tier names (bash 3.2 has no associative
# arrays — macOS /bin/bash is 3.2, and the rest of the suite is 3.2-clean).
SELECTED=""
MODE="full"
TIER_FLAG=0
CHANGED_FLAG=0

is_selected() { case " $SELECTED " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
sel() { is_selected "$1" || SELECTED="$SELECTED $1"; }

add_selected() {  # validate + record a tier name
  local t="$1" known=0 k
  for k in "${ALL_TIERS[@]}"; do [[ "$t" == "$k" ]] && known=1 && break; done
  if [[ $known -eq 0 ]]; then
    echo "${C_R}error:${C_0} unknown tier '$t' (see --list)" >&2
    exit 2
  fi
  sel "$t"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tier)
      TIER_FLAG=1
      shift
      [[ $# -gt 0 ]] || { echo "${C_R}error:${C_0} --tier needs a name" >&2; exit 2; }
      IFS=',' read -r -a _names <<< "$1"
      for _n in "${_names[@]}"; do [[ -n "$_n" ]] && add_selected "$_n"; done
      ;;
    --tier=*)
      TIER_FLAG=1
      IFS=',' read -r -a _names <<< "${1#--tier=}"
      for _n in "${_names[@]}"; do [[ -n "$_n" ]] && add_selected "$_n"; done
      ;;
    --changed) CHANGED_FLAG=1 ;;
    --list) list_tiers; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "${C_R}error:${C_0} unknown argument '$1' (see --help)" >&2; exit 2 ;;
  esac
  shift
done

if [[ $TIER_FLAG -eq 1 && $CHANGED_FLAG -eq 1 ]]; then
  echo "${C_R}error:${C_0} --tier and --changed are mutually exclusive" >&2
  exit 2
fi

# ════════════════════════════════════════════════════════════════════════════
# --changed: map the git diff to the tiers it touches
# ════════════════════════════════════════════════════════════════════════════
UNMAPPED=()

# Map ONE repo-relative path to the tier(s) its change should re-run. Biases
# toward inclusion on the shared seams (cf/src, web, lib feed several tiers).
# Files that map to no tier (docs, *.md, CLAUDE.md, …) are reported and ignored:
# --changed is a fast PRE-FILTER; the no-arg full run is the authoritative gate.
map_path() {
  # NB: declare on separate lines — a single `local f=.. rel=${f#..}` expands
  # rel against the OUTER f (a bash quirk), which silently broke this mapping.
  local f="$1"
  local rel="${f#beads-runner/}"
  if [[ "$rel" == "$f" ]]; then UNMAPPED+=("$f"); return; fi   # not under beads-runner/
  case "$rel" in
    cf/test/conformance-*.sh)                                          sel contract ;;
    cf/test/*.spec.js)                                                 sel cf ;;
    cf/src/*|cf/pages-dev/*|cf/migrations/*|cf/vitest.config.js|cf/wrangler*|cf/package.json)
                                                                       sel cf; sel contract ;;
    cf/*)                                                              sel cf ;;
    web/*)                                                             sel lib; sel contract ;;
    test-fixtures/*)                                                   sel contract ;;
    # lib/ holds the bash-oracle engine (coordinator.sh, …); its JS twin is in
    # cf/, so a lib engine edit must re-run cf too or an oracle⇄twin divergence
    # (the §1 differential-conformance bug class) slips past --changed.
    lib/*)                                                             sel lib; sel cf; sel daemon; sel conformance; sel top ;;
    daemon/*)                                                          sel daemon; sel contract ;;
    hooks/*)                                                           sel hooks ;;
    agents/*)                                                          sel agents ;;
    conformance/*)                                                     sel conformance ;;
    run-beads-tasks.sh|runner.sh)                                      sel conformance; sel top ;;
    test-*.sh)                                                         sel top ;;
    *.sh)  case "$rel" in */*) UNMAPPED+=("$f") ;; *) sel top ;; esac ;;
    *)                                                                 UNMAPPED+=("$f") ;;
  esac
}

if [[ $CHANGED_FLAG -eq 1 ]]; then
  MODE="changed"
  REPO_ROOT="$(git -C "$BR_DIR" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "${C_R}error:${C_0} --changed needs a git repo" >&2; exit 2; }
  # tracked changes vs HEAD (staged + unstaged) + untracked-but-not-ignored.
  # Keep only beads-runner/ paths (nothing else can touch a beads-runner tier)
  # and drop node_modules noise (it may be untracked-not-ignored in this tree).
  _changed=()
  while IFS= read -r _line; do
    [[ -n "$_line" ]] || continue
    case "$_line" in
      beads-runner/*) ;;
      *) continue ;;
    esac
    case "$_line" in */node_modules/*) continue ;; esac
    _changed+=("$_line")
  done < <(
    { git -C "$REPO_ROOT" diff --name-only HEAD
      git -C "$REPO_ROOT" ls-files --others --exclude-standard
    } | sort -u
  )
  if [[ ${#_changed[@]} -eq 0 ]]; then
    echo "${C_Y}--changed:${C_0} no changes vs HEAD — nothing to run."
    echo "TOTAL pass=0 fail=0"
    exit 0
  fi
  for _f in "${_changed[@]}"; do map_path "$_f"; done
fi

# default (no --tier, no --changed): all tiers
if [[ $TIER_FLAG -eq 0 && $CHANGED_FLAG -eq 0 ]]; then
  for _t in "${ALL_TIERS[@]}"; do sel "$_t"; done
fi

# ════════════════════════════════════════════════════════════════════════════
# strictly offline: neutralize the coordinator token
# ════════════════════════════════════════════════════════════════════════════
# Several enrolled T1/T3 bash tests carry a TOKEN-GATED live-Worker probe (PART
# A/C against coordinator-cf.bbthechange.workers.dev). TESTING-STRATEGY.md §8 is
# explicit: "No network below T8" and those probes are "expected to be
# skipped/SKIP without a prod token — that SKIP is not a failure." So the offline
# gate runs with NO token resolvable, exactly as a clean CI checkout would: the
# live sections SKIP and only the offline assertions run. Without this, a machine
# that HAS a prod token (Brian's: COORDINATOR_TOKEN in env + a
# claude-beads-runner.coordinator-token keychain item) would make the gate reach
# the network — the very thing "EXCLUDE T8/network" forbids. On CI neither path
# resolves, so this is a no-op there.
unset COORDINATOR_TOKEN COORDINATOR_URL CO_EXPECTED_TOKEN 2>/dev/null || true
GATE_SHIM_DIR=""
cleanup_gate() { [[ -n "$GATE_SHIM_DIR" && -d "$GATE_SHIM_DIR" ]] && rm -rf "$GATE_SHIM_DIR"; }
trap cleanup_gate EXIT
# macOS only: a surgical `security` shim that denies ONLY the coordinator-token
# keychain lookup (so the probes can't resolve it) and delegates every other
# request to the real binary. (Linux CI has no `security`, so tests skip live
# naturally — no shim needed, and creating one could fool a `command -v security`
# branch, so guard on the real binary existing.)
if [[ -x /usr/bin/security ]]; then
  GATE_SHIM_DIR="$(mktemp -d 2>/dev/null || true)"
  if [[ -n "$GATE_SHIM_DIR" && -d "$GATE_SHIM_DIR" ]]; then
    cat > "$GATE_SHIM_DIR/security" <<'GATE_SECURITY_SHIM'
#!/bin/bash
# run-tests.sh offline shim — deny ONLY the coordinator token so token-gated
# live-Worker probes SKIP (TESTING-STRATEGY §8); delegate all else to the real one.
for a in "$@"; do
  case "$a" in claude-beads-runner.coordinator-token) exit 44 ;; esac
done
exec /usr/bin/security "$@"
GATE_SECURITY_SHIM
    chmod +x "$GATE_SHIM_DIR/security"
    PATH="$GATE_SHIM_DIR:$PATH"; export PATH
  fi
fi

# ════════════════════════════════════════════════════════════════════════════
# tier runners
# ════════════════════════════════════════════════════════════════════════════
TOTAL_PASS=0
TOTAL_FAIL=0
declare -a FAILED_TIERS=()

# run a single bash test file as one unit; echoes ✓/✗, dumps output on failure.
run_one() {
  local f="$1" out rc
  out="$(bash "$f" 2>&1)"; rc=$?
  if [[ $rc -eq 0 ]]; then
    printf '   %s✓%s %s\n' "$C_G" "$C_0" "${f#$BR_DIR/}"
  else
    printf '   %s✗%s %s   <<< FAIL (exit %d)\n' "$C_R" "$C_0" "${f#$BR_DIR/}" "$rc"
    printf '%s\n' "$out" | sed 's/^/        | /'
  fi
  return $rc
}

# a tier whose units are globbed bash files. $1=label, rest=glob patterns (abs).
run_bash_tier() {
  local label="$1"; shift
  local -a files=()
  local g f
  for g in "$@"; do
    for f in $g; do [[ -e "$f" ]] && files+=("$f"); done
  done
  local p=0 fl=0
  printf '%s▶ %s%s  (%d files)\n' "$C_C" "$label" "$C_0" "${#files[@]}"
  if [[ ${#files[@]} -eq 0 ]]; then
    printf '   %s(no test files matched — tier empty)%s\n' "$C_Y" "$C_0"
  fi
  for f in "${files[@]}"; do
    if run_one "$f"; then p=$((p+1)); else fl=$((fl+1)); fi
  done
  printf '%sTIER %-12s pass=%-3d fail=%-3d%s\n\n' \
    "$([[ $fl -eq 0 ]] && echo "$C_G" || echo "$C_R")" "$label" "$p" "$fl" "$C_0"
  TOTAL_PASS=$((TOTAL_PASS+p)); TOTAL_FAIL=$((TOTAL_FAIL+fl))
  [[ $fl -ne 0 ]] && FAILED_TIERS+=("$label")
  return 0
}

# a tier that is one sub-runner command (counts as a single unit).
# $1=label  $2=human note  $3..=command (run via "$@")
run_cmd_tier() {
  local label="$1" note="$2"; shift 2
  printf '%s▶ %s%s  (%s)\n' "$C_C" "$label" "$C_0" "$note"
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [[ $rc -eq 0 ]]; then
    printf '   %s✓%s %s passed\n' "$C_G" "$C_0" "$note"
    printf '%sTIER %-12s pass=1   fail=0  %s\n\n' "$C_G" "$label" "$C_0"
    TOTAL_PASS=$((TOTAL_PASS+1))
  else
    printf '   %s✗%s %s FAILED (exit %d) — output follows:\n' "$C_R" "$C_0" "$note" "$rc"
    printf '%s\n' "$out" | sed 's/^/        | /'
    printf '%sTIER %-12s pass=0   fail=1  %s\n\n' "$C_R" "$label" "$C_0"
    TOTAL_FAIL=$((TOTAL_FAIL+1))
    FAILED_TIERS+=("$label")
  fi
  return 0
}

# cf vitest is its own process group; wrap so cwd is cf/.
run_cf_tier() {
  local n; n=$(ls -1 "$BR_DIR"/cf/test/*.spec.js 2>/dev/null | wc -l | tr -d ' ')
  run_cmd_tier "cf" "vitest: $n spec files" \
    bash -c 'cd "$1" && npm test --silent' _ "$BR_DIR/cf"
}

# ════════════════════════════════════════════════════════════════════════════
# header
# ════════════════════════════════════════════════════════════════════════════
echo "════════════════════════════════════════════════════════════════════════"
echo " beads-runner offline regression gate — run-tests.sh (TESTING-STRATEGY §7.1)"
if [[ $TIER_FLAG -eq 1 ]]; then
  _sl=""; for t in "${ALL_TIERS[@]}"; do is_selected "$t" && _sl="$_sl,$t"; done
  echo " mode: --tier (${_sl#,})"
elif [[ $CHANGED_FLAG -eq 1 ]]; then
  echo " mode: --changed (tiers touched by the git diff vs HEAD)"
else
  echo " mode: full (all offline tiers; T8/network excluded — manual at close)"
fi
echo "════════════════════════════════════════════════════════════════════════"
echo ""

# ════════════════════════════════════════════════════════════════════════════
# dispatch (canonical order; only selected tiers run)
# ════════════════════════════════════════════════════════════════════════════
run_tier() {
  case "$1" in
    lib)         run_bash_tier "lib"         "$BR_DIR/lib/test-*.sh" ;;
    daemon)      run_bash_tier "daemon"      "$BR_DIR/daemon/test-*.sh" ;;
    hooks)       run_bash_tier "hooks"       "$BR_DIR/hooks/test-*.sh" ;;
    agents)      run_bash_tier "agents"      "$BR_DIR/agents/test-*.sh" ;;
    top)         run_bash_tier "top"         "$BR_DIR/test-*.sh" ;;
    contract)    run_bash_tier "contract"    "$BR_DIR/cf/test/conformance-*.sh" ;;
    conformance) run_cmd_tier  "conformance" "runner BC harness" bash "$BR_DIR/conformance/run-conformance.sh" ;;
    cf)          run_cf_tier ;;
  esac
}

RAN_ANY=0
for t in "${ALL_TIERS[@]}"; do
  is_selected "$t" || continue
  RAN_ANY=1
  run_tier "$t"
done

# changed-mode: report unmapped files so a missed coupling is never silent.
if [[ $CHANGED_FLAG -eq 1 && ${#UNMAPPED[@]} -gt 0 ]]; then
  echo "${C_Y}--changed: ${#UNMAPPED[@]} changed file(s) mapped to no tier (ignored):${C_0}"
  for u in "${UNMAPPED[@]}"; do echo "   · $u"; done
  echo ""
fi

# ════════════════════════════════════════════════════════════════════════════
# summary
# ════════════════════════════════════════════════════════════════════════════
echo "════════════════════════════════════════════════════════════════════════"
if [[ $RAN_ANY -eq 0 ]]; then
  if [[ $CHANGED_FLAG -eq 1 ]]; then
    echo " ${C_Y}--changed: the diff touched no test tier — nothing to run.${C_0}"
    echo "TOTAL pass=0 fail=0"
    echo "════════════════════════════════════════════════════════════════════════"
    exit 0
  fi
  echo " ${C_R}error: no tiers selected.${C_0}"
  exit 2
fi

echo "TOTAL pass=$TOTAL_PASS fail=$TOTAL_FAIL"
if [[ $TOTAL_FAIL -eq 0 ]]; then
  echo " ${C_G}✓ OFFLINE SUITE GREEN${C_0} — every selected unit passed."
  echo "════════════════════════════════════════════════════════════════════════"
  exit 0
else
  echo " ${C_R}✗ OFFLINE SUITE RED${C_0} — failing tier(s): ${FAILED_TIERS[*]}"
  echo "════════════════════════════════════════════════════════════════════════"
  exit 1
fi
