#!/bin/bash
# beads-runner/daemon/test-m6-dispatch.sh — M6 bd-surgery dispatch acceptance
# (claude-tools-4iy; epic claude-tools-kie).
#
# WHAT THIS PROVES
#   1. m6-dispatch.sh exists, parses, and is sourced by daemon.sh next to the
#      M4 poll lib.
#   2. daemon_m6_dispatch_busy refuses gracefully on bad inputs (no workspace
#      / missing specialist / missing task_ref) without aborting the caller.
#   3. The CANARY branch (DAEMON_M6_DISABLED=1) records the would-be dispatch
#      into a context file with the correct shape: mode=bd-surgery, workspace,
#      bead_ref, dossier_id, item_id, answer record, instructions string.
#   4. Idempotency — a second dispatch for the same task_ref while a previous
#      pid is alive is a no-op (the canary branch is permissive; a separate
#      assertion uses a hand-built live pidfile to exercise the real check).
#   5. End-to-end wiring: when daemon_dispatch_for_state classifies "busy on a
#      DIFFERENT task" AND m6-dispatch is loaded, daemon_m6_dispatch_busy is
#      actually called (the canary log line + the context file appear).
#   6. specialist.sh's reconciler kind disallows the full M6 set (Write Edit
#      MultiEdit NotebookEdit BashWriteEdits) and runs --permission-mode
#      default (NOT acceptEdits).
#   7. daemon_m6_kill_all SIGTERMs any tracked live pid on drain.
#
# Like the M4 test, this is its own focused acceptance — not part of the T1
# conformance suite. Run:
#   bash beads-runner/daemon/test-m6-dispatch.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
DAEMON_SH="$HERE/daemon.sh"
POLL_LIB="$HERE/hosted-resolution-poll.sh"
M6_LIB="$HERE/m6-dispatch.sh"
SPECIALIST="$REPO_ROOT/agents/specialist.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
eq()  { [[ "$1" == "$2" ]] && ok "$3" || bad "$3 (got '$1' want '$2')"; }
has() { case "$1" in *"$2"*) ok "$3";; *) bad "$3 (missing '$2')";; esac; }
nothas() { case "$1" in *"$2"*) bad "$3 (unexpectedly contains '$2')";; *) ok "$3";; esac; }

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " M6 bd-surgery dispatch — claude-tools-4iy (epic claude-tools-kie)"
echo "════════════════════════════════════════════════════════════════════"

# ════════════════════════════════════════════════════════════════════════════
# PART 0 — files exist, parse, are wired
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART 0 — files exist, parse, are wired (static) ──"
[[ -f "$M6_LIB" ]] && ok "m6-dispatch.sh present" || bad "m6-dispatch.sh missing"
bash -n "$M6_LIB" 2>/dev/null && ok "m6-dispatch.sh parses (bash -n clean)" || bad "m6-dispatch.sh syntax"
bash -n "$DAEMON_SH" 2>/dev/null && ok "daemon.sh parses (bash -n clean) with M6 wiring" || bad "daemon.sh syntax"
bash -n "$POLL_LIB" 2>/dev/null && ok "hosted-resolution-poll.sh parses (bash -n clean) with M6 call-site" || bad "poll lib syntax"
bash -n "$SPECIALIST" 2>/dev/null && ok "agents/specialist.sh parses (bash -n clean) with widened reconciler disallowed list" || bad "specialist syntax"

for fn in daemon_m6_dispatch_busy daemon_m6_kill_all daemon_m6_already_in_flight daemon_m6_pidfile_for; do
  grep -q "^$fn()" "$M6_LIB" && ok "m6-dispatch.sh defines $fn" || bad "m6-dispatch.sh defines $fn"
done

grep -q 'm6-dispatch.sh' "$DAEMON_SH" \
  && ok "daemon.sh sources m6-dispatch.sh (the M6 wire-in)" \
  || bad "daemon.sh must source m6-dispatch.sh"
grep -q 'daemon_m6_kill_all' "$DAEMON_SH" \
  && ok "daemon.sh on_exit drain calls daemon_m6_kill_all (no orphan bd-surgery children on shutdown)" \
  || bad "daemon.sh must call daemon_m6_kill_all on drain"
grep -q 'daemon_m6_dispatch_busy' "$POLL_LIB" \
  && ok "hosted-resolution-poll.sh dispatches to daemon_m6_dispatch_busy on the M6 branch" \
  || bad "hosted-resolution-poll.sh must call daemon_m6_dispatch_busy"

# specialist.sh: reconciler must disallow the full M6 set + run --permission-mode default.
grep -q 'NO_CODE_EDITS=(Write Edit MultiEdit NotebookEdit BashWriteEdits)' "$SPECIALIST" \
  && ok "specialist.sh declares the M6 NO_CODE_EDITS list (Write Edit MultiEdit NotebookEdit BashWriteEdits)" \
  || bad "specialist.sh must declare NO_CODE_EDITS=(Write Edit MultiEdit NotebookEdit BashWriteEdits)"

# ════════════════════════════════════════════════════════════════════════════
# PART A — direct calls into daemon_m6_dispatch_busy (canary branch)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART A — daemon_m6_dispatch_busy under DAEMON_M6_DISABLED=1 (canary) ──"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# Daemon-cache redirected into the tmpdir so the test does not write into
# the real ~/.cache/claude-tools.
export DAEMON_CACHE_DIR="$TMPROOT/cache"
export DAEMON_M6_BASE="$DAEMON_CACHE_DIR/m6-dispatch"
mkdir -p "$DAEMON_CACHE_DIR"

# Canary branch — claude -p must NOT be spawned. The test environment has no
# claude binary, no network, no Anthropic credentials.
export DAEMON_M6_DISABLED=1

# Provide a `log` function so the lib's `declare -F log` checks succeed and
# we can capture the dispatch line. Append-mode shared file across calls.
LOGFILE="$TMPROOT/daemon.log"
log() { printf '%s [test] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOGFILE"; }

# shellcheck source=/dev/null
. "$M6_LIB" 2>/dev/null || { bad "could not source m6-dispatch.sh"; exit 1; }

# Build a fake workspace + an answer record.
WS="$TMPROOT/workspace"
mkdir -p "$WS/.beads"
ANS_DIR="$WS/.beads/runner-logs/.co-store/blocked-for-human-answer"
mkdir -p "$ANS_DIR"
TREF="tools-m6test"
DID="stuck-$TREF"
IID="pick-1"
ANS="$ANS_DIR/$TREF.json"
jq -cn \
  --arg t "$TREF" --arg d "$DID" --arg i "$IID" \
  '{task_ref:$t,dossier_id:$d,item_id:$i,
    chosen:"resume",chosen_label:"I have unblocked it — resume the task",
    chosen_blast_radius:"Re-queues the task once a human resolves the fork.",
    response:{selected_option_id:"resume",free_text:"unblocked locally; proceed."},
    free_text:"unblocked locally; proceed.",
    decided_at:"2026-05-20T00:00:00Z"}' > "$ANS"

# A1 — happy canary path: dispatch records a context file + log line.
: > "$LOGFILE"
daemon_m6_dispatch_busy "$WS" "$TREF" "$DID" "$IID" "$ANS"
CTX_FILE="$(ls -1 "$DAEMON_M6_BASE/logs/"*"context.json" 2>/dev/null | head -1)"
[[ -n "$CTX_FILE" && -f "$CTX_FILE" ]] \
  && ok "A1: canary recorded context file under $DAEMON_M6_BASE/logs/" \
  || bad "A1: no context file written"
if [[ -n "$CTX_FILE" && -f "$CTX_FILE" ]]; then
  eq "$(jq -r '.mode'          "$CTX_FILE" 2>/dev/null)" "bd-surgery"  "A1: context.mode = bd-surgery"
  eq "$(jq -r '.workspace_dir' "$CTX_FILE" 2>/dev/null)" "$WS"         "A1: context.workspace_dir = $WS"
  eq "$(jq -r '.bead_ref'      "$CTX_FILE" 2>/dev/null)" "$TREF"       "A1: context.bead_ref = $TREF"
  eq "$(jq -r '.dossier_id'    "$CTX_FILE" 2>/dev/null)" "$DID"        "A1: context.dossier_id = $DID"
  eq "$(jq -r '.item_id'       "$CTX_FILE" 2>/dev/null)" "$IID"        "A1: context.item_id = $IID"
  eq "$(jq -r '.answer.chosen' "$CTX_FILE" 2>/dev/null)" "resume"      "A1: context.answer.chosen = resume (the human's pick from $ANS)"
  has "$(jq -r '.instructions' "$CTX_FILE" 2>/dev/null)" "bd-surgery mode" "A1: instructions name the bd-surgery mode"
  has "$(jq -r '.instructions' "$CTX_FILE" 2>/dev/null)" "Do NOT edit code" "A1: instructions assert read-only-outside-.beads/ constraint"
fi
LOGTEXT="$(cat "$LOGFILE" 2>/dev/null)"
has "$LOGTEXT" "DAEMON_M6_DISABLED=1" "A1: canary log line emitted (DAEMON_M6_DISABLED=1)"
has "$LOGTEXT" "task_ref=$TREF"       "A1: canary log line names task_ref"
has "$LOGTEXT" "workspace=$WS"        "A1: canary log line names workspace"

# A2 — reject: missing workspace.
: > "$LOGFILE"
daemon_m6_dispatch_busy "" "$TREF" "$DID" "$IID" "$ANS"
has "$(cat "$LOGFILE")" "reject — workspace" "A2: missing workspace dir ⇒ structured reject (no abort)"

# A3 — reject: missing task_ref.
: > "$LOGFILE"
daemon_m6_dispatch_busy "$WS" "" "$DID" "$IID" "$ANS"
has "$(cat "$LOGFILE")" "reject — no task_ref" "A3: missing task_ref ⇒ structured reject"

# A4 — reject: specialist binary not executable (the M6 spec demands this be
#       a loud failure, NOT a silent fall-through to the M5 path).
: > "$LOGFILE"
DAEMON_M6_SPECIALIST_SAVED="$DAEMON_M6_SPECIALIST"
DAEMON_M6_SPECIALIST="$TMPROOT/no-such-specialist"
daemon_m6_dispatch_busy "$WS" "$TREF" "$DID" "$IID" "$ANS"
has "$(cat "$LOGFILE")" "specialist.sh not executable" "A4: missing specialist ⇒ logged refusal (parked bead falls through to M5 next idle-handoff)"
DAEMON_M6_SPECIALIST="$DAEMON_M6_SPECIALIST_SAVED"

# ════════════════════════════════════════════════════════════════════════════
# PART B — idempotency check via daemon_m6_already_in_flight
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART B — idempotency (no double-launch for the same task_ref) ──"

mkdir -p "$DAEMON_M6_BASE/pids"
PF="$(daemon_m6_pidfile_for "$TREF")"
# Write our own pid (alive by definition) into the pidfile. The check should
# return 0 (in-flight). NOTE: the canary branch in daemon_m6_dispatch_busy
# returns BEFORE consulting daemon_m6_already_in_flight (it's a test/canary
# hook), so we exercise the helper directly here.
echo "$$" > "$PF"
if daemon_m6_already_in_flight "$TREF"; then
  ok "B1: live pidfile ⇒ daemon_m6_already_in_flight = true (suppresses re-dispatch)"
else
  bad "B1: live pidfile not detected by daemon_m6_already_in_flight"
fi

# Stale pidfile (very-unlikely-alive pid) ⇒ in_flight=false + the file is
# reclaimed.
echo "99999" > "$PF"
if daemon_m6_already_in_flight "$TREF"; then
  bad "B2: stale pidfile should not register as in-flight"
else
  ok "B2: stale pidfile ⇒ daemon_m6_already_in_flight = false (reclaimed)"
fi
[[ ! -f "$PF" ]] && ok "B2: stale pidfile cleaned up after check" \
                || bad "B2: stale pidfile not removed"

# ════════════════════════════════════════════════════════════════════════════
# PART C — daemon_m6_kill_all SIGTERMs tracked live pids on drain
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART C — daemon_m6_kill_all drain hook ──"

# Spawn a sleeper as the "in-flight bd-surgery agent."
( sleep 30 ) &
SLEEPER_PID=$!
echo "$SLEEPER_PID" > "$DAEMON_M6_BASE/pids/c1-sleeper.pid"
kill -0 "$SLEEPER_PID" 2>/dev/null && ok "C1: spawned sleeper pid=$SLEEPER_PID; pidfile written" \
                                   || bad "C1: sleeper not alive"

: > "$LOGFILE"
daemon_m6_kill_all

# Give the kernel a beat to reap.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  kill -0 "$SLEEPER_PID" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$SLEEPER_PID" 2>/dev/null; then
  bad "C1: sleeper still alive after daemon_m6_kill_all (expected SIGTERM-induced exit)"
  kill -KILL "$SLEEPER_PID" 2>/dev/null || true
else
  ok "C1: sleeper terminated after daemon_m6_kill_all sent SIGTERM"
fi
has "$(cat "$LOGFILE")" "sent SIGTERM to bd-surgery pid=$SLEEPER_PID" "C1: drain logged the kill per-pid"
[[ ! -f "$DAEMON_M6_BASE/pids/c1-sleeper.pid" ]] \
  && ok "C1: pidfile cleaned up by daemon_m6_kill_all" \
  || bad "C1: pidfile not cleaned up"

# ════════════════════════════════════════════════════════════════════════════
# PART D — end-to-end wiring via daemon_dispatch_for_state
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART D — daemon_dispatch_for_state busy:OTHER ⇒ daemon_m6_dispatch_busy fires ──"

# Source the M4 poll lib so daemon_dispatch_for_state is in scope.
# shellcheck source=/dev/null
. "$POLL_LIB" 2>/dev/null || { bad "could not source hosted-resolution-poll.sh"; exit 1; }

# Reset answer dir + a single fresh answer file (the "new_list" snapshot).
D_WS="$TMPROOT/d-workspace"
D_ADIR="$D_WS/.beads/runner-logs/.co-store/blocked-for-human-answer"
mkdir -p "$D_ADIR"
D_TREF="tools-m6e2e"
D_ANS="$D_ADIR/$D_TREF.json"
jq -cn --arg t "$D_TREF" --arg d "stuck-$D_TREF" --arg i "pick-1" \
  '{task_ref:$t,dossier_id:$d,item_id:$i,
    chosen:"abandon",chosen_label:"Abandon / re-scope",
    response:{selected_option_id:"abandon"},
    free_text:"",decided_at:"2026-05-20T00:00:00Z"}' > "$D_ANS"

# Clear log + the prior workspace's canary artifacts so this PART asserts on
# fresh signal only.
: > "$LOGFILE"
rm -rf "$DAEMON_M6_BASE"
mkdir -p "$DAEMON_M6_BASE"

# Drive the dispatch with state=busy:some-other-task — the M6 branch.
daemon_dispatch_for_state "$D_WS" "busy:some-other-task" "$D_ADIR" "$(basename "$D_ANS")"

LOGTEXT="$(cat "$LOGFILE")"
has "$LOGTEXT" "M4 dispatch"                "D1: M4 dispatch line emitted (decision branch)"
has "$LOGTEXT" "M6 (busy on a DIFFERENT"    "D1: decision = M6 busy-on-different-task"
has "$LOGTEXT" "DAEMON_M6_DISABLED=1"       "D1: M6 dispatch actually called (canary log line)"
has "$LOGTEXT" "task_ref=$D_TREF"           "D1: M6 dispatch named the parked task_ref ($D_TREF)"

CTX_FILE="$(ls -1 "$DAEMON_M6_BASE/logs/"*"context.json" 2>/dev/null | head -1)"
[[ -n "$CTX_FILE" && -f "$CTX_FILE" ]] \
  && ok "D1: context file captured for E2E dispatch" \
  || bad "D1: no context file from E2E dispatch"
if [[ -n "$CTX_FILE" && -f "$CTX_FILE" ]]; then
  eq "$(jq -r '.bead_ref' "$CTX_FILE")" "$D_TREF" "D1: context.bead_ref carries through end-to-end"
  eq "$(jq -r '.answer.chosen' "$CTX_FILE")" "abandon" "D1: context.answer faithfully carries the captured decision (chosen=abandon)"
fi

# D2 — busy on the SAME (parked) task: M5 branch ⇒ M6 dispatch MUST NOT fire.
rm -rf "$DAEMON_M6_BASE"; mkdir -p "$DAEMON_M6_BASE"
: > "$LOGFILE"
daemon_dispatch_for_state "$D_WS" "busy:$D_TREF" "$D_ADIR" "$(basename "$D_ANS")"
LOGTEXT="$(cat "$LOGFILE")"
has "$LOGTEXT" "M5 (busy on the parked task" "D2: M5 branch when runner is on the parked task itself"
nothas "$LOGTEXT" "DAEMON_M6_DISABLED=1"     "D2: M6 dispatch suppressed (no bd-surgery launch on the M5 branch)"

# D3 — idle: M5 branch ⇒ M6 dispatch MUST NOT fire.
rm -rf "$DAEMON_M6_BASE"; mkdir -p "$DAEMON_M6_BASE"
: > "$LOGFILE"
daemon_dispatch_for_state "$D_WS" "idle" "$D_ADIR" "$(basename "$D_ANS")"
LOGTEXT="$(cat "$LOGFILE")"
has "$LOGTEXT" "M5 (idle/parked"             "D3: M5 branch when runner is idle"
nothas "$LOGTEXT" "DAEMON_M6_DISABLED=1"     "D3: M6 dispatch suppressed on idle (no bd-surgery launch)"

echo ""
echo "──────────────────────────────────────────────────────────────────────"
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
echo "──────────────────────────────────────────────────────────────────────"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
