#!/bin/bash
# beads-runner/hooks/test-auto-label-live-session.sh
#
# Unit tests for auto-label-live-session.sh (Mechanism B, claude-tools-n6ek;
# inbox-lifecycle §8.3.4). PATH-prepends a `bd` shim that records `bd label add`
# invocations so the tests are deterministic and touch no real state.
#
# Run: bash beads-runner/hooks/test-auto-label-live-session.sh
# Exit 0 = all pass; non-zero = a test failed (failing test names printed).
#
# The headline case (§8.3.6 "most important test case"): inside a runner-spawned
# worker the hook MUST pass through WITHOUT labelling — else the runner labels
# its own in-flight bead and refuses its own work (RUNNER_NO_CLAIM_LABELS) →
# instant deadlock. Covered by T_runner_session_status / T_runner_session_claim
# / T_runner_session_taskid.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/auto-label-live-session.sh"
LABEL="human-live-session"

[[ -x "$HOOK" ]] || { echo "FAIL: hook not executable at $HOOK"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not present (hook degrades to pass-through)"; exit 0; }

PASS=0
FAIL=0
FAILED_NAMES=()

# ── Shim dir: a fake `bd` that records `label add <id> <label>` lines ─────────
SHIM_DIR="$(mktemp -d -t albls-shim.XXXX)"
cat > "$SHIM_DIR/bd" <<'EOF'
#!/bin/bash
# fake bd — only `label add <id> <label>` is recorded; everything else no-ops 0.
if [[ "${1:-}" == "label" && "${2:-}" == "add" ]]; then
  shift 2
  printf '%s\n' "$*" >> "$BD_SHIM_RECORD"
fi
exit 0
EOF
chmod +x "$SHIM_DIR/bd"

WS="$(mktemp -d -t albls-ws.XXXX)"
mkdir -p "$WS/.beads/runner-logs"

cleanup() { rm -rf "$SHIM_DIR" "$WS" 2>/dev/null || true; }
trap cleanup EXIT

# ── Input builder ────────────────────────────────────────────────────────────
mk_input() {  # mk_input <command> [tool_name] → PreToolUse JSON on stdout
  jq -nc \
    --arg cmd "$1" \
    --arg tn "${2:-Bash}" \
    --arg cwd "$WS" \
    '{hook_event_name:"PreToolUse", tool_name:$tn, tool_input:{command:$cmd}, session_id:"test-sess", cwd:$cwd}'
}

# ── Hook runner ──────────────────────────────────────────────────────────────
# Scrub the runner's session/bead env BEFORE applying the per-test prefix (this
# suite itself runs INSIDE a runner-spawned worker, which exports
# BEADS_RUNNER_SESSION=1 + CURRENT_TASK_ID — leaking those would make every
# "interactive" case wrongly pass through). Each test sets its OWN env via $envs.
# A fresh record file per call isolates assertions. PATH-prepends the bd shim.
run_hook() {  # run_hook <input_json> <env-prefix> → echoes record-file path; sets RC
  local input="$1" envs="$2"
  REC="$(mktemp -t albls-rec.XXXX)"
  STDOUT="$(BD_SHIM_RECORD="$REC" \
    bash -c "unset BEADS_RUNNER_SESSION CURRENT_TASK_ID; \
             export PATH='$SHIM_DIR:'\$PATH; \
             export BD_SHIM_RECORD='$REC'; \
             export BEADS_HOOK_LOG='$WS/.beads/runner-logs/hook-events.jsonl'; \
             $envs '$HOOK'" <<<"$input")"
  RC=$?
}

# ── Assertions ───────────────────────────────────────────────────────────────
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); echo "  FAIL: $1 — $2"; }

# Every path is an "allow": exit 0 and empty stdout (the hook never blocks).
assert_allow() {  # assert_allow <name>
  [[ "$RC" -eq 0 ]] || { bad "$1" "expected exit 0, got $RC"; return; }
  [[ -z "$STDOUT" ]] || { bad "$1" "expected empty stdout (allow), got: $STDOUT"; return; }
  return 0
}

assert_labelled() {  # assert_labelled <name> <id>
  assert_allow "$1" || return
  if grep -qE "(^| )$2 $LABEL\$" "$REC" 2>/dev/null; then
    ok "$1"
  else
    bad "$1" "expected '$2 $LABEL' recorded; record=[$(tr '\n' ';' < "$REC")]"
  fi
}

assert_not_labelled() {  # assert_not_labelled <name> [forbidden-substr]
  assert_allow "$1" || return
  if [[ -s "$REC" ]] && { [[ -z "${2:-}" ]] || grep -q "${2:-}" "$REC" 2>/dev/null; }; then
    bad "$1" "expected NO label recorded${2:+ for '$2'}; record=[$(tr '\n' ';' < "$REC")]"
  else
    ok "$1"
  fi
}

echo "== auto-label-live-session.sh =="

# ── Interactive session (no runner env) ⇒ label applied ──────────────────────
run_hook "$(mk_input 'bd update claude-tools-aaa --status=in_progress')" ""
assert_labelled "interactive_status_eq" "claude-tools-aaa"

run_hook "$(mk_input 'bd update claude-tools-bbb --status in_progress')" ""
assert_labelled "interactive_status_space" "claude-tools-bbb"

run_hook "$(mk_input 'bd update claude-tools-ccc -s in_progress')" ""
assert_labelled "interactive_s_space" "claude-tools-ccc"

run_hook "$(mk_input "bd update claude-tools-ddd --status='in_progress'")" ""
assert_labelled "interactive_quoted" "claude-tools-ddd"

run_hook "$(mk_input 'bd update claude-tools-eee --claim')" ""
assert_labelled "interactive_claim" "claude-tools-eee"

run_hook "$(mk_input 'bd update --claim claude-tools-fff')" ""
assert_labelled "interactive_claim_flag_first" "claude-tools-fff"

# A quoted bead id must still be labelled (read -a leaves the quote chars in
# place, so the tokenizer strips one matched surrounding pair).
run_hook "$(mk_input 'bd update "claude-tools-qqq" --claim')" ""
assert_labelled "interactive_quoted_id" "claude-tools-qqq"

run_hook "$(mk_input "bd update 'claude-tools-rrr' --status=in_progress")" ""
assert_labelled "interactive_quoted_id_single" "claude-tools-rrr"

# Multi-id ⇒ both labelled.
run_hook "$(mk_input 'bd update claude-tools-m1 claude-tools-m2 --status=in_progress')" ""
assert_labelled "interactive_multi_id_1" "claude-tools-m1"
assert_labelled "interactive_multi_id_2" "claude-tools-m2"   # re-runs hook; same input, fresh record

# A value-taking flag's id-shaped VALUE must NOT be mistaken for a bead id.
run_hook "$(mk_input 'bd update claude-tools-ggg --status=in_progress --add-labels runner-reliability')" ""
assert_labelled "interactive_flagvalue_id_ok" "claude-tools-ggg"
run_hook "$(mk_input 'bd update claude-tools-ggg --status=in_progress --add-labels runner-reliability')" ""
assert_not_labelled "interactive_flagvalue_not_id" "runner-reliability"

# ── CRITICAL: inside the runner ⇒ pass through, NO label (deadlock guard) ─────
run_hook "$(mk_input 'bd update claude-tools-own --status=in_progress')" "BEADS_RUNNER_SESSION=1"
assert_not_labelled "runner_session_status"

run_hook "$(mk_input 'bd update claude-tools-own --claim')" "BEADS_RUNNER_SESSION=1"
assert_not_labelled "runner_session_claim"

# Belt-and-suspenders: CURRENT_TASK_ID alone (no BEADS_RUNNER_SESSION) ⇒ runner.
run_hook "$(mk_input 'bd update claude-tools-own --status=in_progress')" "CURRENT_TASK_ID=claude-tools-own"
assert_not_labelled "runner_session_taskid"

# ── Non-matching commands ⇒ pass through, NO label ───────────────────────────
run_hook "$(mk_input 'bd update claude-tools-hhh --status=open')" ""
assert_not_labelled "neg_status_open"

run_hook "$(mk_input 'bd show claude-tools-iii')" ""
assert_not_labelled "neg_show"

run_hook "$(mk_input 'bd update claude-tools-jjj --status=in_progress_foo')" ""
assert_not_labelled "neg_in_progress_suffix"

run_hook "$(mk_input 'bd update claude-tools-kkk --priority=p1')" ""
assert_not_labelled "neg_priority_only"

# Non-Bash tool ⇒ pass through.
run_hook "$(mk_input 'bd update claude-tools-lll --status=in_progress' 'Edit')" ""
assert_not_labelled "neg_non_bash_tool"

# Matching shape but no bead id present ⇒ nothing to label.
run_hook "$(mk_input 'bd update --status=in_progress')" ""
assert_not_labelled "neg_no_id"

# ── Tally ────────────────────────────────────────────────────────────────────
echo "── auto-label-live-session: PASS=$PASS FAIL=$FAIL"
if [[ $FAIL -gt 0 ]]; then
  printf '   failed: %s\n' "${FAILED_NAMES[*]}"
  exit 1
fi
exit 0
