# .beads/runner.sh — Android project config for run-beads-tasks.sh
#
# Copy this file to .beads/runner.sh in your project root.

PERMISSION_FLAGS=(
  --permission-mode acceptEdits
  --allowedTools
    "Bash(git:*)" "Bash(bd:*)"
    "Bash(./gradlew:*)" "Bash(gradle:*)"
    "Bash(adb:*)" "Bash(emulator:*)"
    "Bash(./scripts/*:*)"
    "Bash(java:*)" "Bash(kotlin:*)"
    "Bash(jq:*)" "Bash(curl:*)"
    "Bash(mktemp:*)" "Bash(open:*)" "Bash(chmod:*)" "Bash(kill:*)"
    "Bash(tail:*)" "Bash(date:*)" "Bash(ls:*)" "Bash(cat:*)" "Bash(mkdir:*)"
    "mcp__claude-in-chrome__*"
)

# No --no-chrome: this project uses browser automation
EXTRA_CLAUDE_FLAGS=()
