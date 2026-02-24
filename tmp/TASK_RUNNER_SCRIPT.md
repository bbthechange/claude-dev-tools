# Task Runner Script

`run-beads-tasks.sh` — processes beads issues sequentially, each in a fresh Claude Code session with clean 200k context. Located at `beads-runner/run-beads-tasks.sh`, installed via symlink to `/usr/local/bin/run-beads-tasks`.

## Architecture Overview

```
run-beads-tasks.sh
├── Load config        # Sources .beads/runner.sh from project root (if exists)
├── runner_setup()     # Hook: project-specific setup (e.g. Xcode auto-clicker)
├── cleanup()          # Trap handler: kills children, resets active task, calls runner_cleanup()
├── check_usage()      # Calls usage API, caches result, compares to threshold
├── next_task()        # Returns first in_progress task, or first ready task
└── main loop
    ├── graceful stop     # Checks for .stop-beads sentinel file
    ├── usage check       # Stops if above USAGE_THRESHOLD %
    ├── model selection   # Reads model:X label from beads, defaults to DEFAULT_MODEL
    ├── retry tracking    # Per-task retries + systemic failure detection
    ├── claude -p &       # Background child, output to temp file
    ├── tail -f parser &  # Background: parses stream-json, shows timestamped progress
    └── watchdog &        # Background: warns at 3min idle, kills at 10min idle
```

### Child Processes Per Task
Each task iteration spawns 3 background processes that must ALL be cleaned up:
- `CLAUDE_PID` — the actual claude -p session
- `TAIL_PID` — stream parser (tail -f | while read)
- `WATCHDOG_PID` — idle detector

Plus any persistent background processes started by `runner_setup()` in the project config (e.g. `AUTO_ALLOW_PID` for Xcode dialog auto-clicker on iOS).

## Per-Project Configuration

The script is project-agnostic. All project-specific behavior lives in `.beads/runner.sh` at the project root. If this file exists, it is `source`d before the main loop.

### Configurable Variables

| Variable | Default | Purpose |
|---|---|---|
| `PERMISSION_FLAGS` | `--permission-mode acceptEdits --allowedTools "Bash(git:*)" "Bash(bd:*)"` | Claude permission mode and pre-approved tools |
| `EXTRA_CLAUDE_FLAGS` | `(--no-chrome)` | Additional flags passed to `claude -p` |
| `PROMPT_EXTRA` | `""` | Text appended to the prompt for every task |
| `MAX_RETRIES` | `2` | Consecutive failures before skipping a task |
| `MAX_CONSECUTIVE_FAILURES` | `3` | Different-task failures before aborting entirely |
| `DEFAULT_MODEL` | `opus` | Model when no `model:` label is set |
| `USAGE_THRESHOLD` | `70` | Pause new tasks above this % utilization (0 = disabled) |
| `USAGE_SLEEP_SECONDS` | `1800` | How long to sleep when over threshold (30 min) |
| `USAGE_CACHE_SECONDS` | `300` | How long to cache the usage API response |

### Hook Functions

| Hook | Called When | Purpose |
|---|---|---|
| `runner_setup()` | Once at script start | Start persistent background processes |
| `runner_cleanup()` | On exit/interrupt | Kill persistent background processes |

### Example Configs

See `beads-runner/examples/` for ready-to-use configs:

- **`ios.sh`** — Xcode MCP tools, xcodebuild/swift permissions, Xcode dialog auto-clicker
- **`android.sh`** — Gradle, ADB, emulator permissions, browser automation enabled

Copy the appropriate example to `.beads/runner.sh` in your project root.

## Critical Invariants — Do Not Break These

### 1. Claude must run as a direct backgrounded child, NOT in a pipe
```bash
# CORRECT — Ctrl+C reaches the trap handler
claude -p "$PROMPT" > "$STREAM_FILE" 2>&1 &
CLAUDE_PID=$!
wait "$CLAUDE_PID"

# WRONG — pipe swallows SIGINT, script becomes unkillable
claude -p "$PROMPT" | while read line; do ...
```

### 2. stream-json requires --verbose with --print
Without `--verbose`, `claude -p --output-format stream-json` exits immediately with code 1 and no error message. This was a silent failure that caused hours of debugging.

### 3. set -euo pipefail is active
Every command must handle potential failures. Specifically:
- `declare -f <function>` returns exit code 1 if the function doesn't exist — this will crash the script
- Use `|| true` or `|| echo "[]"` for commands that may fail
- Background processes (`&`) are immune to `set -e` in the parent

### 4. Cleanup must reset active task to open
If the script exits (Ctrl+C, crash, kill) while a task is `in_progress`, that task becomes orphaned. The cleanup handler resets `CURRENT_TASK_ID` to open. The `next_task()` function also checks for `in_progress` tasks first as a safety net.

### 5. Two-level failure protection
- **Per-task retries** (`FAIL_COUNT`/`MAX_RETRIES`): Same task failing consecutively — skip after N failures, close with reason
- **Systemic failure abort** (`CONSECUTIVE_FAILURES`/`MAX_CONSECUTIVE_FAILURES`): Different tasks failing consecutively — abort script entirely. Prevents quota exhaustion from churning through every task and closing them all as "skipped"

A single success resets `CONSECUTIVE_FAILURES` to 0.

### 6. PERMISSION_FLAGS is a bash array, not a string
The flags array is expanded directly into the `claude` invocation. The original version used `eval` with a quoted string — the array approach avoids quoting hell entirely. Do not convert back to a string.

## Prompt Template

The prompt uses heredoc with single-quoted delimiter (`<<'PROMPT_DELIM'`) to avoid variable expansion issues with special characters in task descriptions. Placeholder substitution (`BEADS_ID`, `BEADS_TITLE`, `BEADS_DESC`) is done via bash string replacement after the heredoc is read.

The base prompt is intentionally generic:
- Tells Claude which beads issue it's working on
- Instructs it to follow the task description (which contains the actual workflow)
- Disables interactive tools (EnterPlanMode, AskUserQuestion) since there's no human
- Requests a debrief note before closing

Project-specific instructions are appended via `PROMPT_EXTRA` in `.beads/runner.sh`.

## Model Selection

Beads has no native model field. Convention uses labels:
```bash
bd label add <task-id> model:sonnet
bd label add <task-id> model:opus
```

The script reads via `bd label list <id> --json` and extracts the `model:` prefix. Default is the configured `DEFAULT_MODEL` (opus) if no label is set. Labels are NOT included in `bd ready --json` output — requires a separate `bd label list` call per task.

## Permission Handling

### Default mode (no flag)
`--permission-mode acceptEdits` + `--allowedTools` for patterns defined in `PERMISSION_FLAGS`. The defaults only pre-approve git and beads commands. Project configs add environment-specific patterns.

`--allowedTools` ADDS pre-approvals on top of the permission mode — it does NOT restrict available tools. All tools (Read, Write, Edit, Glob, Grep, MCP, Skills, Task) remain available.

Any Bash command NOT matching pre-approved patterns will prompt. In `-p` mode, prompts hang forever (no terminal). The watchdog kill at 10 minutes is the safety net.

### --yolo flag
`--dangerously-skip-permissions` — bypasses everything. Use for fully unattended operation when you trust the task descriptions.

## Usage Quota Check

Before starting each new task, the script checks your Claude account utilization via the undocumented API at `https://api.anthropic.com/api/oauth/usage`. If either the 5-hour or 7-day utilization exceeds `USAGE_THRESHOLD` (default 70%), the script sleeps for `USAGE_SLEEP_SECONDS` (default 30 minutes) and rechecks — looping until usage drops below the threshold. This preserves remaining quota for manual interactive use while automatically resuming when capacity frees up. You can still `touch .stop-beads` to exit during a sleep period.

### How it works
1. Reads the OAuth token from macOS Keychain (`security find-generic-password -s "Claude Code-credentials"`)
2. Calls the usage API with the `anthropic-beta: oauth-2025-04-20` header
3. Parses `five_hour.utilization` and `seven_day.utilization` (both 0-100 percentages)
4. Caches the result for `USAGE_CACHE_SECONDS` (default 300s) to avoid hammering the API

### Response format
```json
{
  "five_hour":       { "utilization": 15.0, "resets_at": "2026-02-23T12:00:00+00:00" },
  "seven_day":       { "utilization": 42.0, "resets_at": "2026-02-27T03:00:00+00:00" },
  "seven_day_sonnet": { "utilization": 3.0,  "resets_at": "..." },
  "seven_day_opus":   null
}
```

### Failure modes
If the credentials can't be read, the token is missing, or the API call fails, the check is skipped (fail-open) and the script continues processing tasks. This prevents the usage check itself from blocking work due to transient issues.

### Disabling
Set `USAGE_THRESHOLD=0` in your `.beads/runner.sh` to disable the check entirely.

### macOS-only
The `security find-generic-password` command is macOS-specific. On Linux, the credentials storage location differs — you'll need to adapt the token extraction or set `USAGE_THRESHOLD=0`.

## Graceful Stop

Create the sentinel file `.stop-beads` in the project root:
```bash
touch .stop-beads
```

The script checks for this file at the top of each loop iteration. When found, it finishes the current task (doesn't interrupt it), removes the file, and exits cleanly with results. This avoids orphaning a task mid-execution.

## Watchdog Behavior

The watchdog checks the `ACTIVITY_FILE` (temp file containing a Unix timestamp) every 15 seconds:
- **>=180s idle**: Prints warning `No activity for Xs — possibly stuck`
- **>=600s idle**: Prints `Killing after Xs idle — likely stuck` and kills `CLAUDE_PID`

The activity timestamp is updated by the stream parser on every line of output. Long-running operations (builds, test suites, MCP calls) that take 2-3 minutes are normal and won't trigger the kill. The 10-minute kill catches genuinely stuck states like:
- MCP server crashed
- Permission prompt hanging (no terminal in `-p` mode)
- Network timeout with no response

## Known Issues and Gotchas

### Temp file cleanup
`STREAM_FILE` and `ACTIVITY_FILE` are created with `mktemp` and deleted after each task. If the script is killed hard (SIGKILL), these leak in `/tmp`. Not a significant issue but worth knowing.

### bd ready vs bd list ordering
`bd ready --json` returns tasks ordered by priority (P0 first). The script always takes `.[0]` (first/highest priority). Tasks with dependencies are excluded automatically by `bd ready`.

### The prompt delegates to task descriptions
The base prompt is generic — it tells Claude to follow the task description. This means the quality of task execution depends entirely on how well the task description is written. Include explicit step-by-step instructions in task descriptions for best results.

### runner.sh is sourced, not executed
Because `.beads/runner.sh` is `source`d, it runs in the same shell context. Variables it sets override the defaults. Functions it defines override the stub hooks. Be careful with side effects — anything that modifies the shell environment affects the main script.

## Installation

Symlink the script to your PATH:
```bash
ln -s ~/code/claude-tools/beads-runner/run-beads-tasks.sh /usr/local/bin/run-beads-tasks
```

Then from any project directory with beads initialized:
```bash
run-beads-tasks            # scoped permissions
run-beads-tasks --yolo     # skip all permission prompts
```

## Task Design Patterns

### Simple task
Write a clear description with step-by-step instructions. The runner will execute it in a single session.

### Design then Implement
For complex work, split into two beads tasks with a dependency:

1. **Design task** (opus): Investigate, design fix, write design into implementation task's `--design` field via `bd update <id> --design="..."`
2. **Implementation task** (blocked by design): Reads design, implements, tests, commits

Create with: `bd dep add <impl-id> <design-id>` — implementation stays blocked until design is closed. Each gets a fresh 200k context. User can review the design between phases.

### Model-per-task
Use labels to assign different models to different tasks:
```bash
bd label add <simple-task-id> model:sonnet    # cheaper for straightforward work
bd label add <complex-task-id> model:opus     # more capable for design/architecture
```

## Adding a New Project Type

1. Create `beads-runner/examples/<type>.sh` with appropriate `PERMISSION_FLAGS` and `PROMPT_EXTRA`
2. Include any necessary `runner_setup()`/`runner_cleanup()` hooks
3. Document any environment prerequisites (e.g. accessibility permissions for auto-clickers)
4. Users copy the example to `.beads/runner.sh` in their project root
