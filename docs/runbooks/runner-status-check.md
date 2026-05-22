# Runbook: check the workspace runner's status

## When

Any time you want to know if a workspace runner is alive, what it's working on, or what the recent activity has been.

## What

The runner is a long-lived bash process (`run-beads-tasks.sh`) spawned by `launch-detached.sh` or by the daemon. It reparents to PID 1 and writes its stdout+stderr to a log file under `<workspace>/.beads/runner-logs/detached-<TIMESTAMP>.log`.

## Commands

```bash
# Are there any runners alive?
pgrep -fl run-beads-tasks

# Find the active claude -p child (if any). This is what the runner spawned for the current task.
pgrep -fl 'claude -p' | head -5

# Find the latest log file for a workspace
LATEST=$(ls -t <workspace>/.beads/runner-logs/detached-*.log | head -1)
echo "log: $LATEST"
tail -F "$LATEST"

# What's the active claude -p process working on? Extract the bead ID from its command line.
ps -p <claude-pid> -o command | grep -oE 'claude-tools-[a-z0-9]+' | head -1

# Recent task pickups in the log (visual separators between tasks)
grep -n '━━━━━' "$LATEST" | tail -10
```

## What you'll see

A healthy runner has:

- One `bash run-beads-tasks.sh` parent process, PPID=1 (orphaned to launchd).
- Zero or one `claude -p` child while working a task; the parent runs `wait $CLAUDE_PID` in between.
- Stream events flowing to its log: `system:init`, `assistant`, `tool_use`, `tool_result`, `result` events.
- Between tasks: `Capacity (via daemon): standard allowed` / `No more ready tasks — idling (poll every 60s for new work)` messages.

If you see multiple `bash run-beads-tasks.sh` processes, you've accumulated orphans. See `cleanup-orphan-runners.md`.

If the runner is silent for more than `IDLE_TIMEOUT` seconds (default 1200s) while in a task, the watchdog will SIGKILL the claude child and the runner will move on.

## Common signals

| Log line | Means |
|---|---|
| `━━━━━` followed by a task title | Just started a new task |
| `No activity for Ns — possibly stuck` | Watchdog warning, claude child hasn't produced output for N seconds |
| `Killing after Ns idle — likely stuck` | Watchdog has issued SIGINT/SIGKILL |
| `STUCK_NEEDS_HUMAN: <title>` | Worker hit a fork that needed a human decision; dossier should have been written |
| `STUCK_AUTOFLIP relaxed-primary` | Fix B kicked in (agent slipped step 1 of stuck protocol) |
| `FEEDBACK RETURN (...) reconciled N blocked-for-human bead(s)` | Daemon observed an answered dossier; bead lifted to open |
| `No more ready tasks — idling` | Queue empty, runner is idle-polling for new work |
| `Done: <title>` | Task closed by the agent |
| `Stop file detected (.stop-beads)` | Graceful shutdown triggered |

## Verifying the runner has the latest config

The runner sources `.beads/runner.sh` once at startup. If you've edited that file (allowed tools, env vars, etc.), the running runner is using the OLD version. To pick up changes, kill and relaunch — see `cleanup-orphan-runners.md` and then `bash beads-runner/launch-detached.sh <workspace>`.

To check whether a live runner has a specific tool in its allowlist:

```bash
ps -p <claude-pid> -o command | tr ' ' '\n' | grep -E 'allowedTools|disallowedTools|mcp__|Task$|WebFetch' | head -20
```

The command line of the claude -p subprocess shows the exact flags. If a tool is missing from `--allowedTools`, the runner needs to be restarted with the updated `.beads/runner.sh`.
