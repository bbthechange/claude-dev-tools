#!/bin/bash
# beads-runner/hooks/test-close-checklist.sh
#
# Unit tests for close-checklist.sh. Uses a PATH-prepended shim dir for `bd` /
# `git` / `pgrep` so checks are deterministic without touching real state.
#
# Run: bash beads-runner/hooks/test-close-checklist.sh
# Exit 0 = all pass; non-zero = a test failed (last failing test name printed).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/close-checklist.sh"

[[ -x "$HOOK" ]] || { echo "FAIL: hook not executable at $HOOK"; exit 1; }

# ── Test harness ────────────────────────────────────────────────────────────
PASS=0
FAIL=0
FAILED_NAMES=()

mkshim_dir() {  # mkshim_dir → echoes a tmpdir with stub bd/git/pgrep
  local d
  d="$(mktemp -d -t hook-test.XXXX)"
  echo "$d"
}

write_shim() {  # write_shim <dir> <name> <script-body>
  local dir="$1" name="$2" body="$3"
  cat > "$dir/$name" <<EOF
#!/bin/bash
$body
EOF
  chmod +x "$dir/$name"
}

# Render a minimal session workspace under tmpdir, with .beads and .claude
# committed so a fresh `git status` is clean (mirrors a real wired workspace).
mkworkspace() {  # mkworkspace → echoes a tmpdir set up as a fake workspace
  local d
  d="$(mktemp -d -t hook-ws.XXXX)"
  mkdir -p "$d/.beads/runner-logs" "$d/.claude/skills/wrapup"
  echo "stub" > "$d/.claude/skills/wrapup/SKILL.md"
  echo "placeholder" > "$d/.beads/.gitkeep"
  git -C "$d" init -q 2>/dev/null
  git -C "$d" -c user.email=t@t -c user.name=t add . 2>/dev/null
  git -C "$d" -c user.email=t@t -c user.name=t commit -q -m init 2>/dev/null
  echo "$d"
}

# Write a session transcript JSONL inside the workspace (under runner-logs, so
# it's excluded from the dirty-tree check) and echo its path. Each arg is one
# already-formed JSONL line. Shape mirrors a real Claude Code transcript:
#   {"type":"assistant", ..., "message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"wrapup"}}]}}
write_transcript() {  # write_transcript <ws> <jsonl-line> [<jsonl-line> ...]
  local ws="$1"; shift
  local tp="$ws/.beads/runner-logs/transcript.jsonl"
  : > "$tp"
  local line
  for line in "$@"; do printf '%s\n' "$line" >> "$tp"; done
  echo "$tp"
}

# A canonical "the agent invoked /wrapup" transcript line. $1 = skill name.
skill_line() { printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_x","name":"Skill","input":{"skill":"%s"}}]}}' "$1"; }

run_hook() {  # run_hook <input_json> <env-prefix-line> → stdout + stderr; exit propagated
  local input="$1" envs="$2"
  # Scrub the runner's session/bead env BEFORE applying the per-test prefix so
  # each test controls BEADS_RUNNER_SESSION / CURRENT_TASK_ID explicitly. Without
  # this, running the gate from inside a real runner session leaks
  # BEADS_RUNNER_SESSION=1 + CURRENT_TASK_ID=<live bead> into the hook, so the
  # "not-a-runner-session" / "no-task-id" gates (T1/T2) resolve the live in-flight
  # bead and block — a false RED that depends on ambient session state, not code.
  # Also scrub BEADS_DIRTY_BASELINE so an ambient runner-session value can't leak
  # into the dirty-tree scoping (claude-tools-f4ub); tests set it explicitly.
  bash -c "unset BEADS_RUNNER_SESSION CURRENT_TASK_ID BEADS_DIRTY_BASELINE; $envs '$HOOK'" <<<"$input"
}

assert_allow() {  # assert_allow <name> <stdout>
  local name="$1" out="$2"
  if [[ -z "$out" ]]; then
    PASS=$((PASS+1)); echo "  PASS: $name"
  else
    FAIL=$((FAIL+1)); FAILED_NAMES+=("$name")
    echo "  FAIL: $name → expected empty stdout (allow), got:"; echo "$out" | head -5 | sed 's/^/    /'
  fi
}

assert_block_stop() {  # assert_block_stop <name> <stdout> <substr-in-reason>
  local name="$1" out="$2" needle="$3"
  if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1 \
     && printf '%s' "$out" | jq -r '.reason' | grep -qF "$needle"; then
    PASS=$((PASS+1)); echo "  PASS: $name"
  else
    FAIL=$((FAIL+1)); FAILED_NAMES+=("$name")
    echo "  FAIL: $name → expected Stop block containing '$needle', got:"; echo "$out" | head -5 | sed 's/^/    /'
  fi
}

assert_block_pretool() {  # assert_block_pretool <name> <stdout> <substr>
  local name="$1" out="$2" needle="$3"
  if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
     && printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -qF "$needle"; then
    PASS=$((PASS+1)); echo "  PASS: $name"
  else
    FAIL=$((FAIL+1)); FAILED_NAMES+=("$name")
    echo "  FAIL: $name → expected PreToolUse deny containing '$needle', got:"; echo "$out" | head -5 | sed 's/^/    /'
  fi
}

# ── Tests ───────────────────────────────────────────────────────────────────

echo "[Gates]"

# T1: Not a runner session → allow
ws=$(mkworkspace); shim=$(mkshim_dir)
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'"}' "PATH=$shim:\$PATH CLAUDE_PROJECT_DIR=$ws")
assert_allow "T1 not-runner-session" "$out"
rm -rf "$ws" "$shim"

# T2: No task id → allow
ws=$(mkworkspace); shim=$(mkshim_dir)
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'"}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CLAUDE_PROJECT_DIR=$ws")
assert_allow "T2 no-task-id" "$out"
rm -rf "$ws" "$shim"

# T3: stop_hook_active=true → allow
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd 'exit 0'
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'","stop_hook_active":true}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo-123 CLAUDE_PROJECT_DIR=$ws")
assert_allow "T3 stop_hook_active" "$out"
rm -rf "$ws" "$shim"

# T4: PreToolUse on non-Bash tool → allow
ws=$(mkworkspace); shim=$(mkshim_dir)
out=$(run_hook '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"'"$ws"'","tool_name":"Read","tool_input":{}}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo-123 CLAUDE_PROJECT_DIR=$ws")
assert_allow "T4 pretooluse-non-bash" "$out"
rm -rf "$ws" "$shim"

# T5: PreToolUse on non-close Bash → allow
ws=$(mkworkspace); shim=$(mkshim_dir)
out=$(run_hook '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"'"$ws"'","tool_name":"Bash","tool_input":{"command":"ls /tmp"}}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo-123 CLAUDE_PROJECT_DIR=$ws")
assert_allow "T5 pretooluse-non-close" "$out"
rm -rf "$ws" "$shim"

echo "[Close-command matcher]"

# T6: PreToolUse matches `bd close` and fails on missing wrapup
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show foo-123 --long --json') printf '%s' '[{\"status\":\"open\",\"notes\":\"a debrief that is sufficiently long to pass the 40 char threshold easily\"}]'; ;; 'show foo-123 --json') printf '%s' '[{\"status\":\"open\"}]' ;; esac; exit 0"
out=$(run_hook '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"'"$ws"'","tool_name":"Bash","tool_input":{"command":"bd close foo-123"}}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo-123 CLAUDE_PROJECT_DIR=$ws")
assert_block_pretool "T6 bd-close matched + wrapup-missing" "$out" "wrapup-reviewed"
rm -rf "$ws" "$shim"

# T7: PreToolUse matches `bd done` alias
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show foo --long --json') printf '%s' '[{\"status\":\"open\",\"notes\":\"\"}]'; ;; 'show foo --json') printf '%s' '[{\"status\":\"open\"}]' ;; esac"
out=$(run_hook '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"'"$ws"'","tool_name":"Bash","tool_input":{"command":"bd done foo"}}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_block_pretool "T7 bd-done alias matched" "$out" "BLOCKED"
rm -rf "$ws" "$shim"

# T8: PreToolUse matches `--status=closed` form
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show foo --long --json') printf '%s' '[{\"status\":\"open\",\"notes\":\"\"}]'; ;; 'show foo --json') printf '%s' '[{\"status\":\"open\"}]' ;; esac"
out=$(run_hook '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"'"$ws"'","tool_name":"Bash","tool_input":{"command":"bd update foo --status=closed"}}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_block_pretool "T8 --status=closed matched" "$out" "BLOCKED"
rm -rf "$ws" "$shim"

# T8a: PreToolUse matches `--status='closed'` (shell-quoted single)
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show foo --long --json') printf '%s' '[{\"status\":\"open\",\"notes\":\"\"}]'; ;; 'show foo --json') printf '%s' '[{\"status\":\"open\"}]' ;; esac"
out=$(run_hook "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"s1\",\"cwd\":\"$ws\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bd update foo --status='closed'\"}}" "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_block_pretool "T8a --status='closed' (quoted) matched" "$out" "BLOCKED"
rm -rf "$ws" "$shim"

# T8b: PreToolUse matches `--status \"closed\"` (double-quoted, space-separated)
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show foo --long --json') printf '%s' '[{\"status\":\"open\",\"notes\":\"\"}]'; ;; 'show foo --json') printf '%s' '[{\"status\":\"open\"}]' ;; esac"
out=$(run_hook "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"s1\",\"cwd\":\"$ws\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bd update foo --status \\\"closed\\\"\"}}" "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_block_pretool "T8b --status \"closed\" (quoted, space-separated) matched" "$out" "BLOCKED"
rm -rf "$ws" "$shim"

# T8c: PreToolUse matches `-s closed` short form
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show foo --long --json') printf '%s' '[{\"status\":\"open\",\"notes\":\"\"}]'; ;; 'show foo --json') printf '%s' '[{\"status\":\"open\"}]' ;; esac"
out=$(run_hook '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"'"$ws"'","tool_name":"Bash","tool_input":{"command":"bd update foo -s closed"}}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_block_pretool "T8c -s closed (short form) matched" "$out" "BLOCKED"
rm -rf "$ws" "$shim"

# T8d: Multi-id close blocked outright with multi_id_close failure
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show foo --long --json') printf '%s' '[{\"status\":\"open\",\"notes\":\"a long enough debrief here; wrapup-reviewed: 2026-01-01 sha=abc clean=0\"}]'; ;; 'show foo --json') printf '%s' '[{\"status\":\"open\"}]' ;; esac"
out=$(run_hook '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"'"$ws"'","tool_name":"Bash","tool_input":{"command":"bd close foo bar baz"}}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_block_pretool "T8d multi-id close denied" "$out" "Multi-bead close"
rm -rf "$ws" "$shim"

# T8e: Single id with redirect tail not counted as multi-id
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show foo --long --json') printf '%s' '[{\"status\":\"open\",\"notes\":\"a long enough debrief here; wrapup-reviewed: 2026-01-01 sha=abc clean=0\"}]'; ;; 'show foo --json') printf '%s' '[{\"status\":\"open\"}]' ;; esac"
out=$(run_hook '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"'"$ws"'","tool_name":"Bash","tool_input":{"command":"bd close foo | tail -3"}}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_allow "T8e single-id with pipe tail allowed" "$out"
rm -rf "$ws" "$shim"

# T8e2: Single id with `2>&1 | tail` redirect-tail not counted as multi-id
# (regression for thirsty-backend-gi9z: the old sequential `${var%%X*}` strips
# ran `| ; & >` in that order, so `foo 2>&1 | tail` was reduced to `foo 2` →
# two tokens → false-positive multi_id_close even on a single-id invocation.)
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show foo --long --json') printf '%s' '[{\"status\":\"open\",\"notes\":\"a long enough debrief here; wrapup-reviewed: 2026-01-01 sha=abc clean=0\"}]'; ;; 'show foo --json') printf '%s' '[{\"status\":\"open\"}]' ;; esac"
out=$(run_hook '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"'"$ws"'","tool_name":"Bash","tool_input":{"command":"bd close foo 2>&1 | tail -3"}}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_allow "T8e2 single-id with 2>&1 | tail allowed" "$out"
rm -rf "$ws" "$shim"

# T8f: Non-close `bd update --notes "we closed the loop"` does NOT trigger
ws=$(mkworkspace); shim=$(mkshim_dir)
out=$(run_hook '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"'"$ws"'","tool_name":"Bash","tool_input":{"command":"bd update foo --notes \"we closed the loop\""}}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_allow "T8f bd update --notes (contains 'closed') not a close" "$out"
rm -rf "$ws" "$shim"

echo "[Checks]"

# T9: Dirty tree (Stop) blocks
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show foo --long --json') printf '%s' '[{\"status\":\"open\",\"notes\":\"a debrief that is plenty long for the threshold check; wrapup-reviewed: 2026-01-01\"}]'; ;; 'show foo --json') printf '%s' '[{\"status\":\"open\"}]' ;; esac"
echo "uncommitted" > "$ws/some-file.txt"
git -C "$ws" add some-file.txt 2>/dev/null
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'"}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_block_stop "T9 dirty-tree blocks Stop" "$out" "Uncommitted changes"
rm -rf "$ws" "$shim"

# T10: Dirty tree but only debrief file → allow
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show foo --long --json') printf '%s' '[{\"status\":\"open\",\"notes\":\"a debrief that is plenty long; wrapup-reviewed: 2026-01-01\"}]'; ;; 'show foo --json') printf '%s' '[{\"status\":\"open\"}]' ;; esac"
echo "debrief content" > "$ws/.beads/foo-debrief.txt"
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'"}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_allow "T10 debrief-file ignored" "$out"
rm -rf "$ws" "$shim"

# T11: Closed bead + no commit referencing → block
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show foo --long --json') printf '%s' '[{\"status\":\"closed\",\"notes\":\"a debrief that is plenty long for the threshold; wrapup-reviewed: 2026-01-01\"}]'; ;; 'show foo --json') printf '%s' '[{\"status\":\"closed\"}]' ;; esac"
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'"}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_block_stop "T11 closed-without-commit" "$out" "closed but no commit"
rm -rf "$ws" "$shim"

# T11a: Closed bead + commit DOES reference it → allow (regression guard for
# claude-tools-m3mx: previously check 3 used `wc -l` on `--pretty=format:%h`
# which always returned 0, so this branch was indistinguishable from T11).
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show foo --long --json') printf '%s' '[{\"status\":\"closed\",\"notes\":\"a debrief that is plenty long for the threshold; wrapup-reviewed: 2026-01-01\"}]'; ;; 'show foo --json') printf '%s' '[{\"status\":\"closed\"}]' ;; esac"
echo "ref" > "$ws/ref.txt"
git -C "$ws" add ref.txt 2>/dev/null
git -C "$ws" -c user.email=t@t -c user.name=t commit -q -m "work referencing foo bead" 2>/dev/null
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'"}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_allow "T11a closed-with-commit allowed" "$out"
rm -rf "$ws" "$shim"

# T11b: Closed bead whose only commit carries the SHORT conventional-commit
# scope, not the full bead id → block. Locks the limitation that motivates
# the full-id commit mandate (claude-tools-02ec): `git log --grep` for the full
# id `claude-tools-foo` cannot match a `docs(foo): ...` subject. If anyone ever
# loosens the grep to also match the short id (option a), this test must be
# consciously updated — it is the guard for the chosen behavior.
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show claude-tools-foo --long --json') printf '%s' '[{\"status\":\"closed\",\"notes\":\"a debrief that is plenty long for the threshold; wrapup-reviewed: 2026-01-01\"}]'; ;; 'show claude-tools-foo --json') printf '%s' '[{\"status\":\"closed\"}]' ;; esac"
echo "ref" > "$ws/ref.txt"
git -C "$ws" add ref.txt 2>/dev/null
git -C "$ws" -c user.email=t@t -c user.name=t commit -q -m "docs(foo): short scope only, no full id" 2>/dev/null
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'"}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=claude-tools-foo CLAUDE_PROJECT_DIR=$ws")
assert_block_stop "T11b short-scope-only blocks (full id absent)" "$out" "closed but no commit"
rm -rf "$ws" "$shim"

# T11c: Closed bead, commit subject uses the SHORT scope but the BODY carries
# the FULL bead id → allow. Validates the recommended wrapup pattern (claude-
# tools-02ec option b): a `docs(foo): ...` subject + a `Refs: claude-tools-foo`
# body line satisfies the full-id grep, so the conventional short scope can
# stay AND close-discipline passes with no separate carry-id commit.
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show claude-tools-foo --long --json') printf '%s' '[{\"status\":\"closed\",\"notes\":\"a debrief that is plenty long for the threshold; wrapup-reviewed: 2026-01-01\"}]'; ;; 'show claude-tools-foo --json') printf '%s' '[{\"status\":\"closed\"}]' ;; esac"
echo "ref" > "$ws/ref.txt"
git -C "$ws" add ref.txt 2>/dev/null
git -C "$ws" -c user.email=t@t -c user.name=t commit -q -m "docs(foo): short scope subject" -m "Refs: claude-tools-foo" 2>/dev/null
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'"}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=claude-tools-foo CLAUDE_PROJECT_DIR=$ws")
assert_allow "T11c full id in body allowed (short scope subject)" "$out"
rm -rf "$ws" "$shim"

# T12: Missing debrief → block
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show foo --long --json') printf '%s' '[{\"status\":\"open\",\"notes\":\"wrapup-reviewed: 2026-01-01\"}]'; ;; 'show foo --json') printf '%s' '[{\"status\":\"open\"}]' ;; esac"
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'"}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_block_stop "T12 missing-debrief" "$out" "No debrief notes"
rm -rf "$ws" "$shim"

# T13: All clean → allow
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show foo --long --json') printf '%s' '[{\"status\":\"open\",\"notes\":\"a sufficiently long debrief here; wrapup-reviewed: 2026-01-01 sha=abc clean=0\"}]'; ;; 'show foo --json') printf '%s' '[{\"status\":\"open\"}]' ;; esac"
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'"}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_allow "T13 all-clean" "$out"
rm -rf "$ws" "$shim"

# T14: Workspace without wrapup skill → wrapup check skipped (allow if other checks pass)
ws=$(mkworkspace); shim=$(mkshim_dir)
# git-rm so the absent skill doesn't show up as a tracked-but-deleted dirty entry
git -C "$ws" rm -q -f .claude/skills/wrapup/SKILL.md 2>/dev/null
git -C "$ws" -c user.email=t@t -c user.name=t commit -q -m "rm wrapup" 2>/dev/null
write_shim "$shim" bd "case \"\$*\" in 'show foo --long --json') printf '%s' '[{\"status\":\"open\",\"notes\":\"a long enough debrief without a wrapup marker — should still pass\"}]'; ;; 'show foo --json') printf '%s' '[{\"status\":\"open\"}]' ;; esac"
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'"}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_allow "T14 no-wrapup-skill skips wrapup check" "$out"
rm -rf "$ws" "$shim"

# T15: CURRENT_TASK_ID read from file when env unset
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show foo --long --json') printf '%s' '[{\"status\":\"open\",\"notes\":\"\"}]'; ;; 'show foo --json') printf '%s' '[{\"status\":\"open\"}]' ;; esac"
echo "foo" > "$ws/.beads/runner-logs/current-task"
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'"}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CLAUDE_PROJECT_DIR=$ws")
# Should trip the missing-debrief check (notes empty), proving the file fallback worked
assert_block_stop "T15 task-id from file fallback" "$out" "No debrief"
rm -rf "$ws" "$shim"

echo "[Wrapup hybrid: transcript Skill(wrapup) OR marker — claude-tools-fh87]"

# Long debrief WITHOUT a wrapup-reviewed marker (so the wrapup check is the only
# variable; the debrief check is satisfied and won't add noise to the block).
NO_MARKER_NOTES="a sufficiently long debrief here describing what was done, well over the forty char threshold"

# T16: transcript present + Skill(wrapup) in transcript + NO marker → allow
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show foo --long --json') printf '%s' '[{\"status\":\"open\",\"notes\":\"$NO_MARKER_NOTES\"}]'; ;; 'show foo --json') printf '%s' '[{\"status\":\"open\"}]' ;; esac"
tp=$(write_transcript "$ws" "$(skill_line wrapup)")
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'","transcript_path":"'"$tp"'"}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_allow "T16 transcript Skill(wrapup), no marker → allow" "$out"
rm -rf "$ws" "$shim"

# T17: transcript present + NO Skill(wrapup) + marker present → allow (marker path)
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show foo --long --json') printf '%s' '[{\"status\":\"open\",\"notes\":\"$NO_MARKER_NOTES; wrapup-reviewed: 2026-01-01 sha=abc clean=0\"}]'; ;; 'show foo --json') printf '%s' '[{\"status\":\"open\"}]' ;; esac"
tp=$(write_transcript "$ws" '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"working"}]}}')
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'","transcript_path":"'"$tp"'"}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_allow "T17 transcript w/o Skill but marker present → allow" "$out"
rm -rf "$ws" "$shim"

# T18: transcript present + NO Skill(wrapup) + NO marker → block (wrapup_not_invoked)
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show foo --long --json') printf '%s' '[{\"status\":\"open\",\"notes\":\"$NO_MARKER_NOTES\"}]'; ;; 'show foo --json') printf '%s' '[{\"status\":\"open\"}]' ;; esac"
tp=$(write_transcript "$ws" '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"working"}]}}')
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'","transcript_path":"'"$tp"'"}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_block_stop "T18 transcript w/o Skill + no marker → block" "$out" "has not been invoked"
rm -rf "$ws" "$shim"

# T19: transcript MISSING + marker present → allow (graceful degrade to marker)
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show foo --long --json') printf '%s' '[{\"status\":\"open\",\"notes\":\"$NO_MARKER_NOTES; wrapup-reviewed: 2026-01-01 sha=abc clean=0\"}]'; ;; 'show foo --json') printf '%s' '[{\"status\":\"open\"}]' ;; esac"
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'"}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_allow "T19 no transcript_path + marker → allow (marker fallback)" "$out"
rm -rf "$ws" "$shim"

# T20: transcript MISSING + NO marker → block (marker-only fallback still enforces)
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show foo --long --json') printf '%s' '[{\"status\":\"open\",\"notes\":\"$NO_MARKER_NOTES\"}]'; ;; 'show foo --json') printf '%s' '[{\"status\":\"open\"}]' ;; esac"
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'"}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_block_stop "T20 no transcript_path + no marker → block" "$out" "has not been invoked"
rm -rf "$ws" "$shim"

# T21: custom BEADS_WRAPUP_SKILL_PATTERN + Skill(wrapup-frontend) in transcript → allow.
# The workspace skill dir must also match the pattern, so create wrapup-frontend/.
ws=$(mkworkspace); shim=$(mkshim_dir)
mkdir -p "$ws/.claude/skills/wrapup-frontend"; echo stub > "$ws/.claude/skills/wrapup-frontend/SKILL.md"
git -C "$ws" rm -q -f .claude/skills/wrapup/SKILL.md 2>/dev/null
git -C "$ws" -c user.email=t@t -c user.name=t add . 2>/dev/null
git -C "$ws" -c user.email=t@t -c user.name=t commit -q -m "swap to wrapup-frontend" 2>/dev/null
write_shim "$shim" bd "case \"\$*\" in 'show foo --long --json') printf '%s' '[{\"status\":\"open\",\"notes\":\"$NO_MARKER_NOTES\"}]'; ;; 'show foo --json') printf '%s' '[{\"status\":\"open\"}]' ;; esac"
tp=$(write_transcript "$ws" "$(skill_line wrapup-frontend)")
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'","transcript_path":"'"$tp"'"}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws BEADS_WRAPUP_SKILL_PATTERN=wrapup*")
assert_allow "T21 custom pattern + Skill(wrapup-frontend) → allow" "$out"
rm -rf "$ws" "$shim"

# T22: transcript has a NON-wrapup Skill (code-reviewer) + no marker → block.
# Guards against false-positive on ANY Skill call.
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show foo --long --json') printf '%s' '[{\"status\":\"open\",\"notes\":\"$NO_MARKER_NOTES\"}]'; ;; 'show foo --json') printf '%s' '[{\"status\":\"open\"}]' ;; esac"
tp=$(write_transcript "$ws" "$(skill_line code-reviewer)")
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'","transcript_path":"'"$tp"'"}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_block_stop "T22 non-wrapup Skill only + no marker → block" "$out" "has not been invoked"
rm -rf "$ws" "$shim"

# T23: live transcript with a partial/malformed final line + a valid Skill(wrapup)
# line → still allow (per-line scan tolerates the mid-write tail; jq -s would not).
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show foo --long --json') printf '%s' '[{\"status\":\"open\",\"notes\":\"$NO_MARKER_NOTES\"}]'; ;; 'show foo --json') printf '%s' '[{\"status\":\"open\"}]' ;; esac"
tp=$(write_transcript "$ws" "$(skill_line wrapup)" '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Sk')
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'","transcript_path":"'"$tp"'"}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_allow "T23 partial final line + valid Skill(wrapup) → allow" "$out"
rm -rf "$ws" "$shim"

# T24: plugin-namespaced Skill("myplugin:wrapup") + default pattern + no marker →
# allow. The namespace prefix must not defeat the default "wrapup*" match.
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show foo --long --json') printf '%s' '[{\"status\":\"open\",\"notes\":\"$NO_MARKER_NOTES\"}]'; ;; 'show foo --json') printf '%s' '[{\"status\":\"open\"}]' ;; esac"
tp=$(write_transcript "$ws" "$(skill_line myplugin:wrapup)")
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'","transcript_path":"'"$tp"'"}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_allow "T24 namespaced Skill(myplugin:wrapup) + default pattern → allow" "$out"
rm -rf "$ws" "$shim"

echo "[Foreign-dirt scoping — claude-tools-f4ub]"

# GOOD_NOTES: long debrief + wrapup marker so checks 4 & 5 pass — isolating the
# dirty-tree check as the only variable. status=open so close_without_commit
# (Stop+closed only) stays out of the picture.
GOOD_NOTES="a sufficiently long debrief here describing what was done; wrapup-reviewed: 2026-01-01 sha=abc clean=0"

# T25: a FOREIGN uncommitted file (present at spawn ⇒ listed in the baseline,
# outside this bead's commit set) is NOT this worker's — the hook must ALLOW the
# close, never block. BEADS_DIRTY_BASELINE points at the runner's snapshot.
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show foo --long --json') printf '%s' '[{\"status\":\"open\",\"notes\":\"$GOOD_NOTES\"}]'; ;; 'show foo --json') printf '%s' '[{\"status\":\"open\"}]' ;; esac"
echo "a sibling/aux session owns this" > "$ws/foreign.txt"
printf '%s\n' '?? foreign.txt' > "$ws/.beads/runner-logs/dirty-baseline.txt"
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'"}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws BEADS_DIRTY_BASELINE=$ws/.beads/runner-logs/dirty-baseline.txt")
assert_allow "T25 foreign-only dirt (in baseline) → allow" "$out"
rm -rf "$ws" "$shim"

# T26: same, but BEADS_DIRTY_BASELINE empty ⇒ the hook falls back to the default
# $project_dir/.beads/runner-logs/dirty-baseline.txt path. Locks the fallback.
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show foo --long --json') printf '%s' '[{\"status\":\"open\",\"notes\":\"$GOOD_NOTES\"}]'; ;; 'show foo --json') printf '%s' '[{\"status\":\"open\"}]' ;; esac"
echo "a sibling/aux session owns this" > "$ws/foreign.txt"
printf '%s\n' '?? foreign.txt' > "$ws/.beads/runner-logs/dirty-baseline.txt"
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'"}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws BEADS_DIRTY_BASELINE=")
assert_allow "T26 foreign-only dirt via default baseline path → allow" "$out"
rm -rf "$ws" "$shim"

# T27: MIXED — an OWN new file (appeared during the session ⇒ absent from the
# baseline) AND a FOREIGN file (in the baseline). The hook must BLOCK on the OWN
# file only, and the foreign path must be left for its owner — NEVER given
# commit-under-bead / git-restore advice (claude-tools-f4ub acceptance #3).
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show foo --long --json') printf '%s' '[{\"status\":\"open\",\"notes\":\"$GOOD_NOTES\"}]'; ;; 'show foo --json') printf '%s' '[{\"status\":\"open\"}]' ;; esac"
echo "a sibling owns this"   > "$ws/foreign.txt"
echo "package main"          > "$ws/own.go"
printf '%s\n' '?? foreign.txt' > "$ws/.beads/runner-logs/dirty-baseline.txt"
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'"}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws BEADS_DIRTY_BASELINE=$ws/.beads/runner-logs/dirty-baseline.txt")
assert_block_stop "T27 mixed → blocks on own.go" "$out" "own.go"
# acceptance #3: foreign.txt must sit under the "leave them" note, never advised
# to be committed-under-bead or git-restore'd.
if printf '%s' "$out" | jq -r '.reason' 2>/dev/null | grep -qF "do NOT 'git restore' them" \
   && printf '%s' "$out" | jq -r '.reason' 2>/dev/null | grep -qF "foreign.txt"; then
  PASS=$((PASS+1)); echo "  PASS: T27b foreign path left for owner (no restore/commit advice)"
else
  FAIL=$((FAIL+1)); FAILED_NAMES+=("T27b")
  echo "  FAIL: T27b expected foreign 'leave them' note for foreign.txt, got:"; echo "$out" | head -8 | sed 's/^/    /'
fi
rm -rf "$ws" "$shim"

# T28: commit-set rescue — a file that WAS dirty at spawn (in baseline) but is in
# this bead's OWN commit set is OWN, not foreign, so it still blocks. Guards the
# "or are in the bead's commit" clause: a worker that committed a file under its
# bead then left it dirty is genuine smuggling, baseline notwithstanding.
ws=$(mkworkspace); shim=$(mkshim_dir)
write_shim "$shim" bd "case \"\$*\" in 'show foo --long --json') printf '%s' '[{\"status\":\"open\",\"notes\":\"$GOOD_NOTES\"}]'; ;; 'show foo --json') printf '%s' '[{\"status\":\"open\"}]' ;; esac"
echo "orig" > "$ws/tracked.txt"
git -C "$ws" add tracked.txt 2>/dev/null
git -C "$ws" -c user.email=t@t -c user.name=t commit -q -m "work on foo bead" tracked.txt 2>/dev/null
echo "changed by this worker" >> "$ws/tracked.txt"   # now dirty (modified)
printf '%s\n' ' M tracked.txt' > "$ws/.beads/runner-logs/dirty-baseline.txt"
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'"}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws BEADS_DIRTY_BASELINE=$ws/.beads/runner-logs/dirty-baseline.txt")
assert_block_stop "T28 baseline-but-in-commit-set → still blocks (own)" "$out" "tracked.txt"
rm -rf "$ws" "$shim"

echo "[Close-detector over-match — anchor on invoked subcommand (claude-tools-9efz)]"

# OM1: read-only `bd list --status closed` query → NOT a close → allow.
# (Invoked subcommand is `list`, a read-only verb; the old whole-string grep of
# Pattern B matched the `--status closed` and falsely gated this.)
ws=$(mkworkspace); shim=$(mkshim_dir)
out=$(run_hook '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"'"$ws"'","tool_name":"Bash","tool_input":{"command":"bd list --status closed"}}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_allow "OM1 bd list --status closed (read-only query) → allow" "$out"
rm -rf "$ws" "$shim"

# OM2: read-only `bd list -s closed` short form → allow (verb=list, Pattern C gated).
ws=$(mkworkspace); shim=$(mkshim_dir)
out=$(run_hook '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"'"$ws"'","tool_name":"Bash","tool_input":{"command":"bd list -s closed"}}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_allow "OM2 bd list -s closed (read-only query) → allow" "$out"
rm -rf "$ws" "$shim"

# OM3: `bd create -d '...bd close foo bar...'` — a close MENTIONED in a quoted
# argument. Invoked subcommand is `create`, so Pattern A must NOT fire and (the
# old bug) multi_id_close must NOT trip on the `foo bar baz` inside the text.
ws=$(mkworkspace); shim=$(mkshim_dir)
out=$(run_hook "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"s1\",\"cwd\":\"$ws\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bd create -d 'fix the thing, then bd close foo bar baz'\"}}" "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_allow "OM3 bd create -d '...bd close foo bar...' (quoted mention) → allow" "$out"
rm -rf "$ws" "$shim"

echo "[Wrapup marker PRODUCER — transcript proof persists the marker (claude-tools-9efz)]"

# A long debrief with NO marker, so the producer/marker behavior is the only
# variable (debrief check stays satisfied).
PROD_NOTES="a sufficiently long debrief here describing what was done, well over the forty char threshold"
# Shim that RECORDS every `bd update` to $rec and serves marker-absent notes.
# $rec is baked into the shim body by the caller before write_shim.
prod_shim() {  # prod_shim <shimdir> <rec> <notes>
  write_shim "$1" bd "
case \"\$1\" in
  update) printf '%s\n' \"\$*\" >> '$2' ;;
  show) case \"\$*\" in *'--long'*) printf '%s' '[{\"status\":\"open\",\"notes\":\"$3\"}]';; *) printf '%s' '[{\"status\":\"open\"}]';; esac ;;
esac"
}
assert_recorded() {  # assert_recorded <name> <rec> <needle>
  if grep -qF "$3" "$2" 2>/dev/null; then
    PASS=$((PASS+1)); echo "  PASS: $1"
  else
    FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); echo "  FAIL: $1 → expected '$3' in $2, got:"; sed 's/^/    /' "$2" 2>/dev/null
  fi
}
assert_not_recorded() {  # assert_not_recorded <name> <rec>
  if [[ ! -s "$2" ]]; then
    PASS=$((PASS+1)); echo "  PASS: $1"
  else
    FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); echo "  FAIL: $1 → expected NO bd update, got:"; sed 's/^/    /' "$2" 2>/dev/null
  fi
}

# P1: Stop + transcript proves wrapup + NO marker → allow AND the hook persists
# the wrapup-reviewed marker (the producer the post-close audit needs).
ws=$(mkworkspace); shim=$(mkshim_dir); rec="$ws/.beads/runner-logs/bd-update.log"; : > "$rec"
prod_shim "$shim" "$rec" "$PROD_NOTES"
tp=$(write_transcript "$ws" "$(skill_line wrapup)")
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'","transcript_path":"'"$tp"'"}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_allow "P1 Stop transcript-proven + no marker → allow" "$out"
assert_recorded "P1b producer persisted wrapup-reviewed marker" "$rec" "update foo --append-notes=wrapup-reviewed:"
rm -rf "$ws" "$shim"

# P2: Stop + transcript proves wrapup + marker ALREADY present → allow, NO
# double-write (idempotent).
ws=$(mkworkspace); shim=$(mkshim_dir); rec="$ws/.beads/runner-logs/bd-update.log"; : > "$rec"
prod_shim "$shim" "$rec" "$PROD_NOTES; wrapup-reviewed: 2026-01-01 sha=abc clean=0"
tp=$(write_transcript "$ws" "$(skill_line wrapup)")
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'","transcript_path":"'"$tp"'"}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_allow "P2 Stop transcript-proven + marker present → allow" "$out"
assert_not_recorded "P2b no double-write when marker already present" "$rec"
rm -rf "$ws" "$shim"

# P3: PreToolUse `bd close` + transcript proves wrapup + NO marker → allow AND
# persist the marker BEFORE the close (so the post-close audit later finds it).
ws=$(mkworkspace); shim=$(mkshim_dir); rec="$ws/.beads/runner-logs/bd-update.log"; : > "$rec"
prod_shim "$shim" "$rec" "$PROD_NOTES"
tp=$(write_transcript "$ws" "$(skill_line wrapup)")
out=$(run_hook '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"'"$ws"'","tool_name":"Bash","tool_input":{"command":"bd close foo"},"transcript_path":"'"$tp"'"}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_allow "P3 PreToolUse close + transcript-proven + no marker → allow" "$out"
assert_recorded "P3b producer persisted marker on the close path" "$rec" "update foo --append-notes=wrapup-reviewed:"
rm -rf "$ws" "$shim"

# P4: NO transcript + marker present → allow via the (b) marker fallback, and
# the producer must NOT fire (proof was the marker, not the transcript).
ws=$(mkworkspace); shim=$(mkshim_dir); rec="$ws/.beads/runner-logs/bd-update.log"; : > "$rec"
prod_shim "$shim" "$rec" "$PROD_NOTES; wrapup-reviewed: 2026-01-01 sha=abc clean=0"
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'"}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_allow "P4 no transcript + marker → allow (marker fallback)" "$out"
assert_not_recorded "P4b producer does not fire on the marker-only path" "$rec"
rm -rf "$ws" "$shim"

# P5: NO transcript + NO marker → block (wrapup_not_invoked) AND the producer
# must NEVER fabricate a marker for an unproven wrapup.
ws=$(mkworkspace); shim=$(mkshim_dir); rec="$ws/.beads/runner-logs/bd-update.log"; : > "$rec"
prod_shim "$shim" "$rec" "$PROD_NOTES"
out=$(run_hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"'"$ws"'"}' "PATH=$shim:\$PATH BEADS_RUNNER_SESSION=1 CURRENT_TASK_ID=foo CLAUDE_PROJECT_DIR=$ws")
assert_block_stop "P5 no transcript + no marker → block" "$out" "has not been invoked"
assert_not_recorded "P5b producer never fabricates a marker for unproven wrapup" "$rec"
rm -rf "$ws" "$shim"

echo
echo "──────────────────────────────────────────────────────────"
echo "Tests: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  echo "Failed: ${FAILED_NAMES[*]}"
  exit 1
fi
exit 0
