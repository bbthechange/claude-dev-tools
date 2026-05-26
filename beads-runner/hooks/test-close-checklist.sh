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

run_hook() {  # run_hook <input_json> <env-prefix-line> → stdout + stderr; exit propagated
  local input="$1" envs="$2"
  bash -c "$envs '$HOOK'" <<<"$input"
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

echo
echo "──────────────────────────────────────────────────────────"
echo "Tests: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  echo "Failed: ${FAILED_NAMES[*]}"
  exit 1
fi
exit 0
