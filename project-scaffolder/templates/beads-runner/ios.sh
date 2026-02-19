# .beads/runner.sh — iOS project config for run-beads-tasks
#
# Permissions: git, bd, xcodegen, swift, xcodebuild, Xcode MCP
# Flags: --no-chrome (no browser automation)
# Hook: auto-clicks Xcode MCP trust dialog for unattended runs

PERMISSION_FLAGS=(
  --permission-mode acceptEdits
  --allowedTools
    "Bash(git:*)" "Bash(bd:*)"
    "Bash(xcodegen:*)" "Bash(swift:*)" "Bash(xcodebuild:*)"
    "mcp__xcode__*"
)

EXTRA_CLAUDE_FLAGS=(--no-chrome)

PROMPT_EXTRA='Additional instructions:
- Use Xcode MCP tools (BuildProject, RunSomeTests) instead of xcodebuild CLI — they use incremental builds and are much faster.
- NEVER use RunAllTests — only run the specific tests you wrote using RunSomeTests. Other test files may have mocks that crash the runner.'

# ── Xcode MCP auto-clicker ──────────────────────────────────────────────────
# Xcode prompts "Allow claude-code to access Xcode?" for every new claude PID.
# This auto-clicks "Allow" so unattended runs don't hang.
# Requires: Terminal/iTerm in System Settings > Privacy & Security > Accessibility

AUTO_ALLOW_PID=""

auto_allow_xcode() {
  while true; do
    osascript -e '
      tell application "System Events"
        tell process "Xcode"
          repeat with win in every window
            try
              set allText to value of every static text of win as text
              if allText contains "claude-code" and allText contains "access Xcode" then
                click button "Allow" of win
              end if
            end try
          end repeat
        end tell
      end tell
    ' 2>/dev/null
    sleep 2
  done
}

runner_setup() {
  auto_allow_xcode &
  AUTO_ALLOW_PID=$!
}

runner_cleanup() {
  if [[ -n "$AUTO_ALLOW_PID" ]]; then
    kill "$AUTO_ALLOW_PID" 2>/dev/null || true
  fi
}
