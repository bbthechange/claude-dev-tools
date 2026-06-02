#!/bin/bash
# Conformance harness — shared library (T1a, claude-tools-ooc).
#
# Provides: isolated black-box runs of run-beads-tasks.sh under stubbed
# claude/bd/security/curl, and a per-BC assertion protocol.
#
# RESULT PROTOCOL — every check prints exactly one line to stdout:
#   RESULT|<status>|<BC>|<INTERFACE-cite>|<description>
# status ∈ PASS | FAIL | GATE-PENDING | GATE-MET
#   PASS          regression: current script exhibits the SCAR (EXIT-crit 1)
#   FAIL          regression broken (harness bug OR script regressed)
#   GATE-PENDING  forward criterion not yet satisfiable on the CURRENT script
#                 (this is the literal close-criterion T2/T3 must flip GREEN —
#                 expected pre-rewrite; does NOT fail the current-script verdict)
#   GATE-MET      forward criterion already satisfied (informational)
# Human diagnostics go to stderr.

set -u

HARNESS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="$(cd "$HARNESS_LIB_DIR/.." && pwd)"
RUNNER="$(cd "$CONF_DIR/../" && pwd)/run-beads-tasks.sh"
FAKE_BIN="$HARNESS_LIB_DIR/fake-bin"

[[ -x "$RUNNER" ]] || { echo "RESULT|FAIL|BC-00|-|runner not found at $RUNNER" ; exit 1; }

# ── per-test isolated workspace ──────────────────────────────────────────────
H_init_test() {
  TEST_NAME="$1"
  WORKDIR="$(mktemp -d)"
  export BD_STORE="$WORKDIR/.bdstore"
  export BD_AUDIT="$WORKDIR/.bd-audit.log"
  export HARNESS_OUT="$WORKDIR/.out"
  export HARNESS_CLAUDE_PLAN="$WORKDIR/.claude-plan"
  export HARNESS_CLAUDE_COUNT="$WORKDIR/.claude-count"
  # claude-tools-d3w9: isolate the §6.2 capacity cache into the per-test WORKDIR.
  # check_usage delegates to la_capacity_check (lib/local-agent.sh), which FIRST
  # consults the daemon's machine-level verdict at la__daemon_capacity_file ⇒
  # ${BEADS_DAEMON_CACHE_DIR:-$HOME/.cache/claude-tools}/capacity.json, BEFORE
  # the BC-34 §6.2 keychain/API fallback that emits the asserted skip-notes. That
  # file is SHARED machine-wide — a live daemon, or any run within 2×
  # USAGE_CACHE_SECONDS, keeps it warm — and it lives outside WORKDIR so
  # H_cleanup never clears it. A warm verdict makes check_usage print "Usage (via
  # daemon)" and SKIP the keychain/API probe, so BC-34's fail-OPEN skip-notes
  # never emit (the rig passes alone only when the cache happens to be cold;
  # in-suite, or with the daemon up, it fails deterministically). Point the cache
  # dir at an empty per-test path so the daemon read always misses and the §6.2
  # fallback runs deterministically. XDG_CACHE_HOME isolated defensively too.
  export BEADS_DAEMON_CACHE_DIR="$WORKDIR/.daemon-cache"
  export XDG_CACHE_HOME="$WORKDIR/.cache"
  # claude-tools-69u8: isolate the dossier-author audit log per WORKDIR. The
  # runner's §7.3 stuck path + §G analysis path call dg__author, whose audit
  # default is $HOME/.cache/claude-tools/dossier-author-audit.jsonl — keyed on
  # $HOME, NOT XDG_CACHE_HOME, so the line above did NOT redirect it and every
  # conformance run polluted the REAL production telemetry (analysis-T1, stuck-
  # stuck-*, …). Pin it into WORKDIR so the B3 audit signal stays trustworthy.
  export DG_AUDIT_LOG="$WORKDIR/.dossier-author-audit.jsonl"
  mkdir -p "$BD_STORE" "$HARNESS_OUT" "$BEADS_DAEMON_CACHE_DIR" "$XDG_CACHE_HOME"
  : > "$BD_AUDIT"; : > "$HARNESS_CLAUDE_COUNT"
  mkdir -p "$WORKDIR/.beads"
  ( cd "$WORKDIR" && git init -q 2>/dev/null || true )
  # Sensible defaults — individual tests override via env before run_runner.
  export PATH="$FAKE_BIN:$PATH"
  export USAGE_THRESHOLD=0          # no keychain/curl unless a BC-34 test opts in
  export IDLE_TIMEOUT=99999         # watchdog silent unless a BC-22 test opts in
  export MAX_RETRIES=2
  export MAX_CONSECUTIVE_FAILURES=3
  # claude-tools-giu: opt INTO the legacy BC-05/BC-21 exit-on-drain SCAR for
  # the conformance harness so the historical exit-code table is still
  # exercised end-to-end. The production runner default (env unset) is the
  # UX §0.A idle-on-drain loop; the SCAR remains testable via this opt-in.
  export RUNNER_EXIT_ON_DRAIN=1
  # claude-tools-d3w9: opt OUT of the §apen post-close discipline audit. It is a
  # post-baseline feature (claude-tools-apen, added after the T1a conformance
  # GREEN at 4c0748e) that runs real `git log/status` + debrief checks on every
  # SUCCESS close. Under the faked worker (no real commit, commit-less workdir,
  # no debrief) it always finds spurious failures and fires side-effects (a
  # Runner: note, an incidents row, a regression bead) that the §8.2 "clean
  # SUCCESS" assertions (bc-09 et al.) do not model — AND its bare `git log`
  # aborts the runner under `set -e` on a commit-less repo. The audited
  # behaviour is out of this harness's INTERFACE §3/§7/§8 scope and has no BC of
  # its own, so the harness skips it via the runner's seam.
  export RUNNER_SKIP_POST_CLOSE_AUDIT=1
  unset HARNESS_BD_SHOW_STATUS_EMPTY HARNESS_KEYCHAIN HARNESS_USAGE HARNESS_HANG_SECONDS 2>/dev/null || true
}

# _reap_runner_pg — sweep the runner's ENTIRE process group.
#
# WHY (load-bearing, anti-self-saturation): the CURRENT run-beads-tasks.sh
# leaks one `tail -f`+parser subshell per task iteration even on its normal
# exit path — its `kill TAIL_PID; pkill -P TAIL_PID` reaping is racy (once the
# parser subshell dies, `tail -f` reparents to PID 1 before `pkill -P` runs).
# That is the characterized BC-40 scaffolding hazard (and BC-36 "no clean exit
# on parent death") — NOT the harness's to fix in the runner (T2 owns the
# rewrite; anti-drift forbids touching another task's surface). But across
# 20+ rigs each spawning the runner up to 8× the leak compounds into the
# orphaned-runner / leaked-`tail -f` pileup that saturated the machine in the
# first T1a attempt. So the harness MUST contain its own blast radius: every
# runner is launched as a process-group leader (`set -m` ⇒ PGID==PID) and the
# whole group is SIGKILLed after the runner exits, regardless of how it exited.
_reap_runner_pg() {
  [[ -n "${RUNNER_PID:-}" ]] || return 0
  kill -KILL -- -"$RUNNER_PID" 2>/dev/null || true
  RUNNER_PID=""
}

H_cleanup() {
  _reap_runner_pg
  [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}

# bd_seed <id> <title> <desc> [status=open] [labels] [deps(comma)] [issue_type=task]
# issue_type (claude-tools-dzc/v2c1): default "task"; pass "epic" to seed an epic
# container so the runner's epic-exclusion selection can be exercised.
bd_seed() {
  local id="$1" title="$2" desc="$3" status="${4:-open}" labels="${5:-}" deps="${6:-}" itype="${7:-task}"
  local d="$BD_STORE/$id"; mkdir -p "$d"
  printf '%s' "$title"  > "$d/title"
  printf '%s' "$desc"   > "$d/desc"
  printf '%s' "$status" > "$d/status"
  printf '%s' "$labels" > "$d/labels"
  printf '%s' "$itype"  > "$d/issue_type"
  printf '%s' "0"       > "$d/attempts"
  : > "$d/notes"
  if [[ -n "$deps" ]]; then printf '%s\n' "${deps//,/$'\n'}" > "$d/deps"; else : > "$d/deps"; fi
}

# bd_set_children <parent-id> <child1,child2,...> — declare FORMAL children so the
# fake `bd show --children` emits the real {<parent>:[self,...kids]} object shape
# (claude-tools-v2cut.1, BC-07/08). A child's status is read LIVE at query time, so
# a close during the run is reflected. A child that IS bd_seed'd reports its seeded
# status; a child WITHOUT its own seed reads status `open` (the `_get` default) —
# the "phantom open child" the some-children-open rigs use to keep the child out of
# `bd ready` while still counting it open in the parent's child list.
bd_set_children() { printf '%s' "$2" > "$BD_STORE/$1/children"; }

# claude_plan <behavior> [behavior...]   (one invocation per behavior; last repeats)
claude_plan() { printf '%s\n' "$@" > "$HARNESS_CLAUDE_PLAN"; }

# run_runner [extra runner args...] — runs with a hard wall-clock backstop.
# Captures combined output to $HARNESS_OUT/runner.out; sets RUN_EXIT.
# _spawn_runner — launch run-beads-tasks.sh as a PROCESS-GROUP LEADER.
# `set -m` (job control) makes the `&` job its own process group with
# PGID == RUNNER_PID, so _reap_runner_pg can SIGKILL the whole tree (runner +
# its leaked tail -f/parser/watchdog) via `kill -- -RUNNER_PID`. `exec` so
# RUNNER_PID is the runner itself (its own INT/TERM/HUP trap must fire — BC-35).
#
# claude-tools-54ei — RESET INT/HUP/QUIT to SIG_DFL before the runner starts.
# POSIX rule: a signal that is SIG_IGN on entry to a shell CANNOT be trapped or
# reset from within bash, so `trap cleanup INT` becomes a SILENT no-op and the
# runner ignores `kill -INT/-HUP` entirely (until the harness SIGKILLs it).
# When the gate runs inside a detached worker the runner inherits exactly those
# ignores: launch-detached.sh uses `nohup … &` (⇒ SIGHUP ignored) and an async
# list (⇒ SIGINT/SIGQUIT ignored per POSIX), and the disposition propagates down
# every exec to the runner-under-test. That made BC-35's INT (v1+v2) and HUP
# (v2) RED in the gate while green from a clean interactive shell — a launch
# artifact, NOT the scenario BC-35 models (an interactive Ctrl-C, where SIGINT
# is at its DEFAULT, trappable disposition). `set -m` does NOT rescue this — it
# only exempts bash's OWN async-list ignore-setting, never an *inherited* ignore
# (verified). bash cannot un-ignore the signals, but an external exec helper
# (perl/python3 — not bound by bash's rule) can sigaction(SIG_DFL) then execvp,
# giving the runner the trappable disposition a real foreground/interactive
# runner has. `exec`-ing the helper keeps RUNNER_PID == the runner. Degrades to
# a plain `exec bash` when no helper exists (correct whenever the signals are
# already at their default — e.g. a standalone gate run, which always was green).
_spawn_runner() {
  set -m
  (
    cd "$WORKDIR" || exit 127
    if command -v perl >/dev/null 2>&1; then
      exec perl -e 'foreach(qw(INT HUP QUIT)){$SIG{$_}="DEFAULT"} exec @ARGV or die "exec: $!"' \
        bash "$RUNNER" "$@"
    elif command -v python3 >/dev/null 2>&1; then
      exec python3 -c 'import signal,sys,os; [signal.signal(s,signal.SIG_DFL) for s in (signal.SIGINT,signal.SIGHUP,signal.SIGQUIT)]; os.execvp(sys.argv[1],sys.argv[1:])' \
        bash "$RUNNER" "$@"
    else
      exec bash "$RUNNER" "$@"
    fi
  ) > "$HARNESS_OUT/runner.out" 2>&1 &
  RUNNER_PID=$!
  set +m
}

# run_runner [extra runner args...] — runs with a hard wall-clock backstop.
# Captures combined output to $HARNESS_OUT/runner.out; sets RUN_EXIT. The
# runner's process group is swept on EVERY exit path (clean or backstop).
run_runner() {
  local max="${RUN_TIMEOUT:-45}"
  _spawn_runner "$@"
  local waited=0
  while kill -0 "$RUNNER_PID" 2>/dev/null; do
    sleep 1; waited=$((waited+1))
    if [[ $waited -ge $max ]]; then
      kill -TERM -- -"$RUNNER_PID" 2>/dev/null || true
      sleep 2
      wait "$RUNNER_PID" 2>/dev/null; RUN_EXIT=124
      _reap_runner_pg; return
    fi
  done
  wait "$RUNNER_PID" 2>/dev/null; RUN_EXIT=$?
  _reap_runner_pg
}

# run_runner_bg — start the runner WITHOUT waiting (BC-35 interrupt test).
# Still a process-group leader; the BC-35 rig signals only $RUNNER_PID (the
# runner main, positive PID) so the runner's OWN trap is what's exercised, then
# wait_runner_exit sweeps the leaked children after RUN_EXIT is captured.
run_runner_bg() { _spawn_runner "$@"; }

# wait_runner_exit — reap a backgrounded runner, set RUN_EXIT (with a backstop),
# then sweep the process group (leaked tail -f/parser) — AFTER RUN_EXIT so the
# runner's own exit code (BC-35 exit 1) is observed, not the sweep's.
wait_runner_exit() {
  local max="${1:-20}" w=0
  while kill -0 "$RUNNER_PID" 2>/dev/null; do
    sleep 1; w=$((w+1))
    [[ $w -ge $max ]] && { kill -KILL -- -"$RUNNER_PID" 2>/dev/null || true; }
  done
  wait "$RUNNER_PID" 2>/dev/null; RUN_EXIT=$?
  _reap_runner_pg
}

# wait_audit <regex> <timeout-s> — block until $BD_AUDIT matches, or time out.
wait_audit() {
  local re="$1" to="${2:-15}" w=0
  while [[ $w -lt $to ]]; do
    grep -qE "$re" "$BD_AUDIT" 2>/dev/null && return 0
    sleep 1; w=$((w+1))
  done
  return 1
}

# ── black-box observers ──────────────────────────────────────────────────────
bd_status()      { cat "$BD_STORE/$1/status" 2>/dev/null || echo "MISSING"; }
notes_of()       { cat "$BD_STORE/$1/notes"  2>/dev/null || true; }
out()            { cat "$HARNESS_OUT/runner.out" 2>/dev/null || true; }
audit()          { cat "$BD_AUDIT" 2>/dev/null || true; }
incidents_log()  { cat "$WORKDIR/.beads/runner-logs/incidents.log" 2>/dev/null || true; }
logdir_files()   { ls -1 "$WORKDIR/.beads/runner-logs" 2>/dev/null || true; }
analysis_ids()   { ls -1 "$BD_STORE" 2>/dev/null | grep '^htest-' || true; }
prompt_text()    { cat "$HARNESS_OUT/last-prompt.txt" 2>/dev/null || true; }
# notify_log — BC-26: the AppleScript strings of every desktop notification the
# run fired (one per line; recorded by the fake osascript). Empty ⇒ no notify
# was sent (the deliberate-silence classes). Used to assert the selective policy.
notify_log()     { cat "$HARNESS_OUT/notify.log" 2>/dev/null || true; }

# audit_seq <id> — the ordered status transitions for one issue, space-joined.
audit_seq() { awk -v id="$1" '$1==id{printf "%s ",$2}' "$BD_AUDIT" 2>/dev/null; }

# incidents.log rows are TSV: <ts>\t<task>\t<class>\t<log>
inc_has()   { awk -F'\t' -v t="$1" -v c="$2" '$2==t&&$3==c{n=1} END{exit n?0:1}' \
                "$WORKDIR/.beads/runner-logs/incidents.log" 2>/dev/null; }
inc_not()   { ! inc_has "$1" "$2"; }
inc_count() { awk -F'\t' -v t="$1" -v c="$2" '$2==t&&$3==c{n++} END{print n+0}' \
                "$WORKDIR/.beads/runner-logs/incidents.log" 2>/dev/null; }
analysis_count() { analysis_ids | grep -c . || true; }

# ── assertion protocol ───────────────────────────────────────────────────────
# ck    <BC> <cite> <desc> ; pass iff the LAST command in `_chk` returned 0
# Usage: _expect "<bc>" "<cite>" "<desc>" && { <commands...>; } ; _emit
_BC=""; _CITE=""; _DESC=""; _OK=1; _MODE="reg"
_expect()      { _BC="$1"; _CITE="$2"; _DESC="$3"; _OK=1; _MODE="reg";  }
_gate()        { _BC="$1"; _CITE="$2"; _DESC="$3"; _OK=1; _MODE="gate"; }
_need()        { # _need <human-msg> <cmd...>  — records first failure
  local msg="$1"; shift
  if "$@"; then return 0; fi
  echo "    ✗ $msg" >&2; _OK=0; return 1
}
_emit() {
  if [[ "$_MODE" == "gate" ]]; then
    if [[ $_OK -eq 1 ]]; then
      echo "RESULT|GATE-MET|$_BC|$_CITE|$_DESC"
    else
      echo "RESULT|GATE-PENDING|$_BC|$_CITE|$_DESC"
      echo "    ⓘ forward criterion — expected unmet on CURRENT script; T2/T3 must flip GREEN" >&2
    fi
  else
    if [[ $_OK -eq 1 ]]; then echo "RESULT|PASS|$_BC|$_CITE|$_DESC"
    else echo "RESULT|FAIL|$_BC|$_CITE|$_DESC"; fi
  fi
}

# ── T1b observers (claude-tools-crq) ─────────────────────────────────────────
# bd_human_log — tasks the runner flagged via `bd human` (the §7.3 backstop /
# STUCK observable; bd stub appends one id per line to $HARNESS_OUT/bd-human.log).
bd_human_log()   { cat "$HARNESS_OUT/bd-human.log" 2>/dev/null || true; }
# lease_seed_valid <task> — pre-plant a still-valid locally-held lease so the
# AD2.2 degraded-closed bounded-fallback path ("continue a task whose lease we
# already hold") is exercisable. Must be called AFTER H_init_test.
lease_seed_valid(){ mkdir -p "$HARNESS_OUT/lease-cache" 2>/dev/null || true; : > "$HARNESS_OUT/lease-cache/$1"; }
# line_before <fileA-regex> <fileB-regex> <file> — true iff the FIRST line
# matching A precedes the FIRST line matching B in <file> (single append-only
# stream ⇒ true wall order, no cross-file race). Used for §6.1 acquire-before-
# in_progress ordering.
line_before() {
  local a b
  a=$(grep -nE -- "$1" "$3" 2>/dev/null | head -1 | cut -d: -f1)
  b=$(grep -nE -- "$2" "$3" 2>/dev/null | head -1 | cut -d: -f1)
  [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]
}

# convenience predicates (return 0/1)
contains()    { grep -qF -- "$2" <<< "$1"; }
notcontains() { ! grep -qF -- "$2" <<< "$1"; }
matches()     { grep -qE -- "$2" <<< "$1"; }
file_glob()   { local g; for g in $1; do [[ -e "$g" ]] && return 0; done; return 1; }

# ── Mechanism A PID claim files (claude-tools-uxc1) ───────────────────────────
# dead_pid — a reliably-DEAD pid: spawn a trivial child, reap it, echo its (now
# unused) pid. The runner's `kill -0` on it returns "dead" ⇒ adopt-eligible.
dead_pid() { local p; ( exit 0 ) & p=$!; wait "$p" 2>/dev/null; printf '%s' "$p"; }

# plant_claim <id> <pid> [runner_id] [workspace] — write a claim file the way the
# runner does (write_task_claim), so a rig can model a crash-orphan's leftover
# claim. Dead <pid> ⇒ adoptable; a live <pid> (e.g. $$) ⇒ a live sibling (skip); a
# mismatched runner_id/workspace ⇒ foreign (skip). Defaults track what the runner
# computes: runner_id=$RUNNER_ID (else hostname), workspace=$PROJECT_REF (else the
# WORKDIR basename the runner derives via `basename "$(pwd)"`). Call AFTER
# H_init_test (needs $WORKDIR) and after exporting RUNNER_ID/PROJECT_REF.
plant_claim() {
  local id="$1" pid="$2"
  local rid="${3:-${RUNNER_ID:-$(hostname 2>/dev/null || echo localhost)}}"
  local ws="${4:-${PROJECT_REF:-$(basename "$WORKDIR")}}"
  local cdir="$WORKDIR/.beads/runner-logs/claims"
  mkdir -p "$cdir"
  printf '{"runner_id":"%s","pid":%s,"host":"%s","started_at":"%s","workspace":"%s"}\n' \
    "$rid" "$pid" "$(hostname 2>/dev/null || echo localhost)" "2026-01-01T00:00:00Z" "$ws" \
    > "$cdir/$id.json"
}
# claim_exists <id> — true iff the runner's claim file for <id> is present under
# the test WORKDIR (used to assert removal on close / non-adoption-overwrite).
claim_exists() { [[ -f "$WORKDIR/.beads/runner-logs/claims/$1.json" ]]; }
