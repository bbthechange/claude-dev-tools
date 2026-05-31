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
# names the failing tier(s)). 2 == bad usage / nothing to run. 75 == another gate
# is already running (busy — retry later; a single mkdir-based lock serializes all
# gate forms so concurrent runs can't pile up and contend).
set -u

BR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── gate-invocation log (claude-tools-d315) ──────────────────────────────────
# Append ONE record per gate ENTRY — before arg-parsing and the singleton lock —
# so EVERY invocation self-identifies its caller: a full run, a --tier/--changed
# run, a lock-refused run (exit 75), and a SELFTEST all land a row. This exists
# to explain the unexplained 2026-05-30 nested full gate (a second full run whose
# parent PID was the first gate) when no code in the repo invokes run-tests.sh:
# the next nested/concurrent gate now names its parent command, so we learn
# whether it's a worker relaunch, a sandboxed runner, or a real recursion — and
# fix the right thing instead of guessing on dead PIDs.
#
# The path is derived from BR_DIR (the REAL beads-runner dir, never CWD), so it
# always points at the real repo's .beads/runner-logs/ even when the gate runs
# inside a conformance mktemp sandbox — outside every test's asserted surface
# ($WORKDIR/.beads), and double-gitignored (root .gitignore + the dir's own
# `*`/`!.gitignore`). The whole block is `|| true`-guarded: a logging failure can
# NEVER fail or perturb the gate, which stays deterministic.
{
  _d315_logdir="$BR_DIR/../.beads/runner-logs"
  mkdir -p "$_d315_logdir" 2>/dev/null
  # Sanitize the free-text fields (args, and esp. caller — a parent command line
  # can carry embedded newlines/TABs; BSD ps escapes them but procps may not) so
  # each entry stays ONE physical TAB-delimited row for a downstream parser.
  printf '%s\tpid=%s\tppid=%s\targs=%s\tcaller=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$PPID" \
    "$(printf '%s' "$*" | tr '\n\t' '  ')" \
    "$(ps -o command= -p "$PPID" 2>/dev/null | tr '\n\t' '  ')" \
    >>"$_d315_logdir/gate-invocations.log"
} 2>/dev/null || true

# ── colors (used unconditionally, matching the existing test convention) ──
C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_C=$'\033[36m'; C_0=$'\033[0m'

# ── canonical tier order (full run executes in this order) ──
ALL_TIERS=(lib daemon hooks agents top conformance contract cf)

usage() {
  sed -n '2,43p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
# singleton gate lock (claude-tools-fm4r) — portable, refuse-and-report
# ════════════════════════════════════════════════════════════════════════════
# This IS the offline regression gate; nothing else serialized it, so a worker
# that relaunches it could stack N full gates that then contend for CPU, the
# Dolt sql-server, and the bd lock (observed 2026-05-30: a 4-way pile-up turned
# a ~few-minute gate into ~16 min). Guard with a portable atomic lock.
#
# Portability: macOS (darwin) has NO flock(1) (`which flock` → not found), so we
# use `mkdir` — atomic create-or-fail on every POSIX filesystem — as the lock
# token. Posture is REFUSE-AND-REPORT: if a LIVE gate holds the lock we print its
# pid/start and exit 75 (EX_TEMPFAIL — "busy, retry later", never confused with
# 1=tests-failed or 2=bad-usage) and touch nothing. We do NOT kill the in-flight
# gate: the conformance tier spawns sandboxed run-beads-tasks.sh children
# (conformance/lib/harness.sh H_cleanup) that an abrupt kill would orphan.
#
# Scope: ONE lock for ALL gate forms (full / --tier / --changed) — they share the
# workSnapshot() seam and the single Dolt server, so they must serialize. Keyed
# by BR_DIR (this checkout) so a different checkout runs independently. A lock
# whose recorded pid is dead is reclaimed, so a crashed gate never wedges the
# next one. Acquired HERE (before the token shim / header / any tier) so a refused
# run does no work and creates no temp dirs.
#
# Test hooks (env, mirrors the offline-token knobs above): RUN_TESTS_GATE_LOCK_BASE
# relocates the lock dir off /tmp for hermetic tests; RUN_TESTS_GATE_SELFTEST, when
# set, acquires the lock then exits 0 (printing `LOCK-ACQUIRED pid=N`) WITHOUT
# running any tier — `hold:<secs>` holds the lock that long first. See test-gate-lock.sh.
GATE_LOCK_BUSY=75
GATE_LOCK_BASE="${RUN_TESTS_GATE_LOCK_BASE:-/tmp}"
GATE_LOCK_KEY="$(printf '%s' "$BR_DIR" | cksum | tr ' ' '_')"
LOCKDIR="$GATE_LOCK_BASE/run-tests-gate-$GATE_LOCK_KEY.lock"
GATE_LOCK_HELD=0
GATE_SHIM_DIR=""
GATE_START_HUMAN="$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo unknown)"
mkdir -p "$GATE_LOCK_BASE" 2>/dev/null || true

# ONE EXIT trap for the whole gate: drop the offline `security` shim AND, only if
# we actually hold it, release the lock. The HELD guard is load-bearing — the
# refuse path exits WITHOUT setting it, so a refused run never deletes the live
# holder's lockdir (it "mutates nothing").
cleanup_gate() {
  [[ -n "$GATE_SHIM_DIR" && -d "$GATE_SHIM_DIR" ]] && rm -rf "$GATE_SHIM_DIR"
  [[ "$GATE_LOCK_HELD" == "1" && -d "$LOCKDIR" ]] && rm -rf "$LOCKDIR"
  return 0
}
trap cleanup_gate EXIT

acquire_gate_lock() {
  local owner_pid owner_start r tries=0
  while :; do
    if mkdir "$LOCKDIR" 2>/dev/null; then
      GATE_LOCK_HELD=1
      printf 'pid=%s\nstart=%s\n' "$$" "$GATE_START_HUMAN" > "$LOCKDIR/owner" 2>/dev/null || true
      return 0
    fi
    # Lock dir exists. Read the recorded owner, riding out the sub-millisecond
    # window between a winner's mkdir and its owner-file write (re-read briefly).
    owner_pid=""; owner_start=""
    for r in 1 2 3; do
      if [[ -s "$LOCKDIR/owner" ]]; then
        owner_pid="$(sed -n 's/^pid=//p'    "$LOCKDIR/owner" 2>/dev/null | head -1)"
        owner_start="$(sed -n 's/^start=//p' "$LOCKDIR/owner" 2>/dev/null | head -1)"
        break
      fi
      sleep 1
    done
    # NB: kill -0 is the universal PID-based-lock liveness test — it carries the
    # usual PID-reuse caveat (if the holder died and the OS recycled its exact pid
    # to an unrelated live process, we'd refuse until that process exits). Self-
    # healing (it clears once that pid dies) and acceptable for a test gate; not
    # worth a start-time/ps cross-check here.
    if [[ -n "$owner_pid" ]] && kill -0 "$owner_pid" 2>/dev/null; then
      # A LIVE gate holds it → refuse, report, touch nothing.
      printf '%sgate already running%s (pid %s, started %s) — skipping\n' \
        "$C_Y" "$C_0" "$owner_pid" "${owner_start:-unknown}" >&2
      printf '   lock: %s\n' "$LOCKDIR" >&2
      exit "$GATE_LOCK_BUSY"
    fi
    # Holder is dead (kill -0 failed) or its owner file never materialized → the
    # lock is stale. Reclaim atomically: only the process whose `mv` wins removes
    # it, so losers re-loop and re-inspect (and correctly refuse if a live winner
    # has meanwhile re-claimed). Bounded so a pathological recreate-loop can't spin.
    tries=$((tries+1))
    if [[ $tries -gt 5 ]]; then
      printf '%serror:%s could not acquire gate lock after %d reclaim attempts (%s)\n' \
        "$C_R" "$C_0" "$tries" "$LOCKDIR" >&2
      exit "$GATE_LOCK_BUSY"
    fi
    if mv "$LOCKDIR" "$LOCKDIR.stale.$$.$tries" 2>/dev/null; then
      rm -rf "$LOCKDIR.stale.$$.$tries" 2>/dev/null || true
    fi
  done
}

acquire_gate_lock

# Test-only fast exit: acquire (above) exercised the real lock; now report and
# leave WITHOUT running any tier. `hold:<secs>` keeps the lock held that long so a
# sibling invocation can observe contention. (See the Test hooks note above.)
if [[ -n "${RUN_TESTS_GATE_SELFTEST:-}" ]]; then
  printf 'LOCK-ACQUIRED pid=%s\n' "$$"
  case "$RUN_TESTS_GATE_SELFTEST" in
    hold:*) sleep "${RUN_TESTS_GATE_SELFTEST#hold:}" ;;
  esac
  exit 0
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
# (GATE_SHIM_DIR is initialized, and cleanup_gate + its EXIT trap installed, in
#  the singleton gate-lock section above — that one trap covers shim AND lock.)
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
