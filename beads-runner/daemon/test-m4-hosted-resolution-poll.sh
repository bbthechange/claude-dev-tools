#!/bin/bash
# beads-runner/daemon/test-m4-hosted-resolution-poll.sh — M4 acceptance
# (claude-tools-8jb; epic claude-tools-kie).
#
# WHAT THIS PROVES
#   1. The M4 hosted-resolution poll lives in the DAEMON, not the runner.
#      The runner's old loop-top `sr_poll_hosted_resolution` call now runs
#      ONLY as a fallback gated on `daemon absent` (the daemon pidfile is not
#      alive). With the daemon up, the runner only reconciles — the daemon
#      owns observation.
#   2. The daemon-side per-workspace poll captures the resume-answer file
#      into the workspace's local store and flips the S-2 bfh record to
#      resolved:true — the same observable the runner-side path produced
#      pre-M4. The shape is unchanged (sr__answer_dir / bfh-resolved); the
#      OWNER moves to the daemon.
#   3. The dispatch decision (M5 idle/parked → splice picks up vs. M6 busy
#      on a DIFFERENT task → bd-surgery) is observable from the
#      workspace's pidfile + outbox heartbeats. M5/M6 implement the actual
#      dispatch; M4 just classifies and logs.
#
# Not in the T1 conformance suite — its own focused acceptance, mirroring the
# lib/test-i*.sh and test-stuck-routing.sh precedent. Run:
#   bash beads-runner/daemon/test-m4-hosted-resolution-poll.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
LIB_DIR="$REPO_ROOT/lib"
RUNNER="$REPO_ROOT/run-beads-tasks.sh"
DAEMON_SH="$HERE/daemon.sh"
POLL_LIB="$HERE/hosted-resolution-poll.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
note(){ printf '  · %s\n' "$1"; }
eq()  { [[ "$1" == "$2" ]] && ok "$3" || bad "$3 (got '$1' want '$2')"; }
has() { case "$1" in *"$2"*) ok "$3";; *) bad "$3 (missing '$2')";; esac; }

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " M4 hosted-resolution poll — claude-tools-8jb (epic claude-tools-kie)"
echo "════════════════════════════════════════════════════════════════════"

# ════════════════════════════════════════════════════════════════════════════
# PART 0 — files exist, parse, are wired into the daemon + runner
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART 0 — files exist, parse, are wired (static) ──"
[[ -f "$POLL_LIB" ]] && ok "hosted-resolution-poll.sh present" || bad "hosted-resolution-poll.sh missing"
[[ -f "$DAEMON_SH" ]] && ok "daemon.sh present" || bad "daemon.sh missing"
[[ -f "$RUNNER" ]]   && ok "run-beads-tasks.sh present" || bad "run-beads-tasks.sh missing"
bash -n "$POLL_LIB" 2>/dev/null && ok "hosted-resolution-poll.sh parses (bash -n clean)" || bad "hosted-resolution-poll.sh syntax"
bash -n "$DAEMON_SH" 2>/dev/null && ok "daemon.sh parses (bash -n clean)" || bad "daemon.sh syntax"
bash -n "$RUNNER" 2>/dev/null && ok "run-beads-tasks.sh parses (bash -n clean) with M4 fallback wiring" || bad "runner syntax with M4 fallback"

for fn in daemon_poll_workspace_hosted_resolution daemon_workspace_runner_state daemon_dispatch_for_state; do
  grep -q "^$fn()" "$POLL_LIB" && ok "hosted-resolution-poll.sh defines $fn" || bad "hosted-resolution-poll.sh defines $fn"
done

grep -q 'hosted-resolution-poll.sh' "$DAEMON_SH" \
  && ok "daemon.sh sources hosted-resolution-poll.sh (the M4 wire-in)" \
  || bad "daemon.sh must source hosted-resolution-poll.sh"
grep -q 'HOSTED_RESOLUTION_POLL_INTERVAL' "$DAEMON_SH" \
  && ok "daemon.sh has the M4 polling cadence variable (HOSTED_RESOLUTION_POLL_INTERVAL, ~30s default per AD8 latency)" \
  || bad "daemon.sh must declare HOSTED_RESOLUTION_POLL_INTERVAL"
grep -q 'run_hosted_resolution_poll' "$DAEMON_SH" \
  && ok "daemon.sh main loop calls run_hosted_resolution_poll on cadence" \
  || bad "daemon.sh must call run_hosted_resolution_poll in main loop"

# Runner: the literal sr_poll_hosted_resolution still must appear (the fallback
# path), but it must be GATED on the daemon being absent — not unconditional as
# pre-M4 was. Also: the I4 'FEEDBACK RETURN (§7.3/S-2/I4)' observable must
# still appear (the existing I4 acceptance test, lib/test-i4-feedback-return.sh
# PART 0, depends on it).
grep -q 'sr_poll_hosted_resolution' "$RUNNER" \
  && ok "runner still references sr_poll_hosted_resolution (the fallback for daemon-absent / standalone runner)" \
  || bad "runner must keep sr_poll_hosted_resolution as a fallback"
grep -q 'DAEMON_PIDFILE_PATH\|BEADS_DAEMON_PIDFILE' "$RUNNER" \
  && ok "runner detects the daemon via its pidfile path (DAEMON_PIDFILE_PATH / BEADS_DAEMON_PIDFILE)" \
  || bad "runner must detect daemon via pidfile"
grep -q 'DAEMON_ALIVE' "$RUNNER" \
  && ok "runner gates the inline poll on DAEMON_ALIVE (daemon owns the poll when alive; runner is the fallback)" \
  || bad "runner must gate the inline poll on daemon liveness"
grep -q 'FEEDBACK RETURN (§7.3/S-2/I4)' "$RUNNER" \
  && ok "I4 regression: 'FEEDBACK RETURN (§7.3/S-2/I4)' observable preserved (the I4 acceptance test depends on it)" \
  || bad "I4 'FEEDBACK RETURN (§7.3/S-2/I4)' observable must remain"

# ════════════════════════════════════════════════════════════════════════════
# PART A — workspace runner-state classifier (pidfile + heartbeat outbox)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART A — daemon_workspace_runner_state classifies pidfile+heartbeat ──"

# Source the libs the function needs.
# shellcheck source=/dev/null
. "$POLL_LIB" 2>/dev/null || { bad "could not source hosted-resolution-poll.sh"; exit 1; }

WA="$(mktemp -d)"
trap 'rm -rf "$WA"' EXIT
mkdir -p "$WA/.beads/runner-logs"

# A1 — no pidfile ⇒ absent
eq "$(daemon_workspace_runner_state "$WA")" "absent" "A1: no pidfile ⇒ runner_state=absent"

# A2 — stale pidfile (dead pid) ⇒ absent
echo "99999" > "$WA/.beads/runner-logs/detached-runner.pid"  # very unlikely-alive pid
state="$(daemon_workspace_runner_state "$WA")"
# accept absent (the kill -0 99999 fails for almost every system)
case "$state" in
  absent) ok "A2: stale pidfile (dead pid) ⇒ runner_state=absent" ;;
  *)      bad "A2: stale pidfile should be absent, got '$state'" ;;
esac

# A3 — live pidfile (this shell's own pid) but no heartbeat outbox ⇒ idle
echo "$$" > "$WA/.beads/runner-logs/detached-runner.pid"
eq "$(daemon_workspace_runner_state "$WA")" "idle" "A3: live pidfile + no outbox ⇒ runner_state=idle"

# A4 — live pidfile + last heartbeat actual=idle ⇒ idle
printf '%s\n' '{"report":"heartbeat","actual":"idle","observed_at":"2026-05-20T00:00:00Z"}' \
  > "$WA/.beads/runner-logs/coordinator-outbox.jsonl"
eq "$(daemon_workspace_runner_state "$WA")" "idle" "A4: live pidfile + heartbeat actual=idle ⇒ runner_state=idle"

# A5 — live pidfile + last heartbeat actual=running with current_task_ref=tools-xyz ⇒ busy:tools-xyz
printf '%s\n%s\n' \
  '{"report":"heartbeat","actual":"idle","observed_at":"2026-05-20T00:00:00Z"}' \
  '{"report":"heartbeat","actual":"running","current_task_ref":"tools-xyz","observed_at":"2026-05-20T00:01:00Z"}' \
  > "$WA/.beads/runner-logs/coordinator-outbox.jsonl"
eq "$(daemon_workspace_runner_state "$WA")" "busy:tools-xyz" "A5: live pidfile + heartbeat actual=running with current_task_ref ⇒ runner_state=busy:tools-xyz"

# ════════════════════════════════════════════════════════════════════════════
# PART B — full per-workspace poll: observe answered dossier, capture answer,
#          flip the S-2 bfh record. Uses the in-process bash store (no
#          COORDINATOR_URL ⇒ no HTTP override) so the test is hermetic.
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART B — per-workspace poll captures answer + flips bfh resolved:true ──"

WB="$(mktemp -d)"
WS="$WB/workspace"
mkdir -p "$WS/.beads/runner-logs"
WS_STORE="$WS/.beads/runner-logs/.co-store"
mkdir -p "$WS_STORE/records" "$WS_STORE/blocked-for-human" "$WS_STORE/blocked-for-human-answer"

# Shadow `bd` on PATH so the reconcile (which the daemon also runs after the
# poll) is a no-op. Without this, `sr_reconcile_blocked_for_human` would
# `rm -f` any just-flipped bfh record — true to its contract but it would
# erase the observable we want to check (resolved:true). With bd shadowed,
# the reconcile returns early and the bfh file stays for our assertion.
FAKEBIN="$WB/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/bd" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$FAKEBIN/bd"
export PATH="$FAKEBIN:$PATH"

FIXTURE="tools-m4test"

# B-pre: seed a bfh record (resolved:false) directly. Bypassing sr__raise_bfh
# (which requires a co_authenticate-resolvable bearer) — the file shape is the
# §7.3 SOURCE OF TRUTH the poll keys on (stuck-routing.sh:139).
NOW="2026-05-20T00:00:00Z"
jq -cn --arg tr "$FIXTURE" --arg d "stuck-$FIXTURE" --arg at "$NOW" \
  '{task_ref:$tr,dossier_id:$d,principal:"brian",trigger:"backstop:permission_denials",
    raised_at:$at,resolved:false,resolved_at:null}' \
  > "$WS_STORE/blocked-for-human/$FIXTURE.json"
[[ -f "$WS_STORE/blocked-for-human/$FIXTURE.json" ]] && ok "B-pre: seeded LOCAL S-2 bfh record (resolved:false)" || bad "could not seed bfh"

# B-pre: seed a dossier record where one item is `answered` — what
# sr_poll_hosted_resolution observes via do_dossier_get (in-process: reads
# CO_STORE/records/dossier.stuck-<fixture>.json).
DOSSIER_ID="stuck-$FIXTURE"
ITEM_ID="pick-1"
# schema_version = 2 (the dossier bound — co__schema_version dossier ⇒ 2).
# Keep the body minimal: do_dossier_get's only checks are integer
# schema_version ≤ bound; rollup is re-derived. The poll's decision filter is
# .items[].state ∈ {answered,applied}.
jq -cn \
  --arg id "$DOSSIER_ID" \
  --arg iid "$ITEM_ID" \
  --argjson sv 2 \
  '{schema_version:$sv,id:$id,kind:"worker_stuck",principal:"brian",
    body:{},
    items:[
      {id:$iid,kind:"pick-option",state:"answered",
       framing:{ask:"Resume or abandon the parked fork?"},
       options:[
         {option_id:"resume",label:"I have unblocked it — resume the task",
          blast_radius:"Re-queues the task once a human resolves the fork.",
          consequence_block:{creates:[],unblocks:[],labels:[],status_changes:[]}},
         {option_id:"abandon",label:"Abandon / re-scope this task",
          blast_radius:"Leaves the bead blocked-for-human.",
          consequence_block:{creates:[],unblocks:[],labels:[],status_changes:[]}}
       ],
       response:{selected_option_id:"resume",free_text:"unblocked locally; proceed."}}
    ]}' > "$WS_STORE/records/dossier.$DOSSIER_ID.json"

[[ -f "$WS_STORE/records/dossier.$DOSSIER_ID.json" ]] && ok "B-pre: seeded ANSWERED dossier (one item state=answered) into the workspace's CO_STORE" || bad "could not seed dossier"

# Build a workspaces.json registry with one entry pointing at $WS.
REG="$WB/workspaces.json"
jq -cn --arg dir "$WS" --arg pref "claude-tools-m4test" '
  {workspaces:[{project_ref:$pref,dir:$dir,coordinator_url:"",coordinator_token_keychain:""}]}' \
  > "$REG"

# Load the registry into the per-shell REGISTRY_<arrays>. The same loader the
# daemon uses (workspace-registry.sh).
# shellcheck source=/dev/null
. "$HERE/workspace-registry.sh"
registry_load "$REG" || { bad "registry_load failed for $REG"; exit 1; }
[[ "$(registry_count)" == "1" ]] && ok "registry_count=1 (the test workspace)" || bad "registry_count != 1"
[[ "${REGISTRY_DIRS[0]}" == "$WS" ]] && ok "REGISTRY_DIRS[0] = $WS" || bad "REGISTRY_DIRS[0] mismatch (got '${REGISTRY_DIRS[0]:-}' want '$WS')"

# CALL the per-workspace poll. In-process bash co_request (no COORDINATOR_URL)
# reads from $CO_STORE/records/, so the poll's do_dossier_get will see the
# answered dossier and capture the decision.
N="$(daemon_poll_workspace_hosted_resolution 0 2>&1 | tail -1)"
case "$N" in
  ''|*[!0-9]*) bad "poll echoed a non-integer count: '$N'" ;;
  *) ok "poll returned integer count: $N" ;;
esac

# Observable 1: the resume-answer file landed in the workspace's local store.
ANS="$WS_STORE/blocked-for-human-answer/$FIXTURE.json"
[[ -f "$ANS" ]] && ok "answer file captured at $ANS (the workspace's expected location — sr__answer_dir convention)" || bad "answer file missing at $ANS"

if [[ -f "$ANS" ]]; then
  has "$(jq -r '.task_ref' "$ANS" 2>/dev/null)" "$FIXTURE" "answer.task_ref = $FIXTURE"
  has "$(jq -r '.chosen' "$ANS" 2>/dev/null)" "resume" "answer.chosen = resume (the human's pick)"
  # chosen_label resolved from the item's options[] — the resume-prompt-ready
  # capture: no second hosted fetch needed at resume time.
  has "$(jq -r '.chosen_label' "$ANS" 2>/dev/null)" "resume" "answer.chosen_label resolved from the item's options[]"
fi

# Observable 2: the LOCAL S-2 bfh record flipped resolved:false → true. The
# daemon's own reconcile (which also runs as part of the poll) may then have
# already DELETED the now-resolved record (sr_reconcile_blocked_for_human's
# normal control→work cleanup — that is its contract for resolved:true). So
# the post-poll state is either {resolved:true} OR the file is gone — both
# indicate the flip happened; what would FAIL is {resolved:false} (unflipped)
# OR {resolved:true} that the reconcile then somehow couldn't clean up.
BFH_FILE="$WS_STORE/blocked-for-human/$FIXTURE.json"
if [[ ! -f "$BFH_FILE" ]]; then
  ok "S-2 bfh record absent post-poll (the daemon's own reconcile cleaned it up after the flip — control→work bead-lift)"
else
  RESOLVED_AFTER="$(jq -r '.resolved' "$BFH_FILE" 2>/dev/null)"
  eq "$RESOLVED_AFTER" "true" "S-2 bfh record flipped resolved:true (the next reconcile lifts the bead → open)"
fi

# Observable 3: idempotent — a second poll captures nothing new + does not re-flip.
N2="$(daemon_poll_workspace_hosted_resolution 0 2>&1 | tail -1)"
case "$N2" in
  ''|*[!0-9]*) bad "second poll echoed a non-integer count: '$N2'" ;;
  0)           ok "second poll is idempotent (count=0; no double-capture)" ;;
  *)           bad "second poll should be 0, got $N2" ;;
esac

# ════════════════════════════════════════════════════════════════════════════
# PART C — dispatch decision routes per runner state (M5 idle/parked vs M6
#          busy-on-different-task). M4 logs the decision; M5/M6 do the action.
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART C — dispatch decision logged per runner state (M5 vs M6) ──"

# Reset the answer dir (so we observe a NEW capture, not the leftover).
rm -f "$WS_STORE/blocked-for-human-answer/$FIXTURE.json"
# Reset the bfh to false so the poll will re-capture.
jq -cn --arg tr "$FIXTURE" --arg d "$DOSSIER_ID" --arg at "$NOW" \
  '{task_ref:$tr,dossier_id:$d,principal:"brian",trigger:"backstop:permission_denials",
    raised_at:$at,resolved:false,resolved_at:null}' \
  > "$WS_STORE/blocked-for-human/$FIXTURE.json"

# C1 — runner busy on a DIFFERENT task ⇒ M6 dispatch log line.
echo "$$" > "$WS/.beads/runner-logs/detached-runner.pid"
printf '%s\n' '{"report":"heartbeat","actual":"running","current_task_ref":"some-other-task","observed_at":"2026-05-20T00:02:00Z"}' \
  > "$WS/.beads/runner-logs/coordinator-outbox.jsonl"
OUT_C1="$(daemon_poll_workspace_hosted_resolution 0 2>&1)"
has "$OUT_C1" "M4 dispatch" "C1: M4 dispatch line emitted"
has "$OUT_C1" "runner_state=busy:some-other-task" "C1: runner_state reflects the busy-on-other-task heartbeat"
has "$OUT_C1" "M6" "C1: dispatch decision = M6 (busy on a different task — bd-surgery needed)"

# Reset for C2
rm -f "$WS_STORE/blocked-for-human-answer/$FIXTURE.json"
jq -cn --arg tr "$FIXTURE" --arg d "$DOSSIER_ID" --arg at "$NOW" \
  '{task_ref:$tr,dossier_id:$d,principal:"brian",trigger:"backstop:permission_denials",
    raised_at:$at,resolved:false,resolved_at:null}' \
  > "$WS_STORE/blocked-for-human/$FIXTURE.json"

# C2 — runner busy on the SAME (parked) task ⇒ M5 splice picks it up.
printf '%s\n' "{\"report\":\"heartbeat\",\"actual\":\"running\",\"current_task_ref\":\"$FIXTURE\",\"observed_at\":\"2026-05-20T00:03:00Z\"}" \
  > "$WS/.beads/runner-logs/coordinator-outbox.jsonl"
OUT_C2="$(daemon_poll_workspace_hosted_resolution 0 2>&1)"
has "$OUT_C2" "M5" "C2: dispatch decision = M5 (runner on the parked task — splice picks up)"

# Reset for C3
rm -f "$WS_STORE/blocked-for-human-answer/$FIXTURE.json"
jq -cn --arg tr "$FIXTURE" --arg d "$DOSSIER_ID" --arg at "$NOW" \
  '{task_ref:$tr,dossier_id:$d,principal:"brian",trigger:"backstop:permission_denials",
    raised_at:$at,resolved:false,resolved_at:null}' \
  > "$WS_STORE/blocked-for-human/$FIXTURE.json"

# C3 — runner idle ⇒ M5 splice picks it up.
printf '%s\n' '{"report":"heartbeat","actual":"idle","observed_at":"2026-05-20T00:04:00Z"}' \
  > "$WS/.beads/runner-logs/coordinator-outbox.jsonl"
OUT_C3="$(daemon_poll_workspace_hosted_resolution 0 2>&1)"
has "$OUT_C3" "M5" "C3: dispatch decision = M5 (runner idle — splice picks up on next loop top)"
has "$OUT_C3" "runner_state=idle" "C3: runner_state=idle"

echo ""
echo "──────────────────────────────────────────────────────────────────────"
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
echo "──────────────────────────────────────────────────────────────────────"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
