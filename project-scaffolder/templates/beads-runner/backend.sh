# .beads/runner.sh — Backend project config for run-beads-tasks
#
# Permissions: git, bd, common build/test tools
# Flags: --no-chrome (no browser automation)

PERMISSION_FLAGS=(
  --permission-mode acceptEdits
  --allowedTools
    "Bash(git:*)" "Bash(bd:*)"
    "Bash(npm:*)" "Bash(npx:*)" "Bash(yarn:*)" "Bash(pnpm:*)"
    "Bash(python:*)" "Bash(pip:*)" "Bash(pytest:*)"
    "Bash(cargo:*)" "Bash(go:*)" "Bash(make:*)"
    "Bash(docker:*)" "Bash(docker-compose:*)"
    "Bash(curl:*)" "Bash(jq:*)"
)

EXTRA_CLAUDE_FLAGS=(--no-chrome)
