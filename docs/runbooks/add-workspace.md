# Runbook: register a new workspace with the daemon

## When

You're onboarding a new project as a workspace the daemon should supervise. Once registered, the daemon will:

- Poll its desired-state on the Cloudflare engine every 60 seconds
- Spawn a workspace runner when desired-state=running and no live pidfile
- Kill the runner when desired-state=stopped
- Continuously poll for answered dossiers belonging to this workspace
- Dispatch resume agents in the workspace when the runner is busy mid-task

## Prerequisites

The workspace must already have:

1. `.beads/` initialized (`bd init` run inside the workspace).
2. `.beads/runner.sh` configured with the workspace's per-project config (allowed tools, env vars, coordinator URL+token resolution).
3. A unique `project_ref` (the bd prefix used in bead IDs — e.g., `claude-tools-` → `claude-tools`).
4. The coordinator token stored in the macOS Keychain at the right service name (default: `claude-beads-runner.coordinator-token`; can be overridden per workspace).

## Adding the workspace

The daemon's registry lives at `~/.config/claude-tools/workspaces.json`. Schema:

```json
{
  "workspaces": [
    {
      "project_ref": "<bd-prefix, e.g., 'thirsty'>",
      "dir": "<absolute path to workspace root>",
      "coordinator_url": "https://coordinator-cf.bbthechange.workers.dev",
      "coordinator_token_keychain": "claude-beads-runner.coordinator-token"
    }
  ]
}
```

The `coordinator_url` and `coordinator_token_keychain` fields are optional; if absent, the daemon falls back to env vars or the workspace's `.beads/runner.sh` config.

To add a workspace:

```bash
# Edit the registry (or write it with jq merge if multiple workspaces)
mkdir -p ~/.config/claude-tools
$EDITOR ~/.config/claude-tools/workspaces.json
```

After editing, signal the daemon to reload (the daemon only reads the registry at startup and on SIGHUP):

```bash
# Find the daemon's pid and SIGHUP it
DAEMON_PID=$(cat ~/.cache/claude-tools/daemon.pid 2>/dev/null)
kill -HUP "$DAEMON_PID"

# Verify the reload took effect
tail /Users/brianbutler/.cache/claude-tools/daemon-logs/stdout.log
# Look for: "SIGHUP received; reloading workspace registry" and "workspace registry reload ok (N workspaces)"
```

If you don't have a workspaces.json yet, the daemon log warns about it at startup with a clear message:

```
WARN: no workspace registry yet at /Users/brianbutler/.config/claude-tools/workspaces.json (continuing — M1/M4 have nothing to poll until a registry exists)
```

That's fine; the daemon will just heartbeat. Once you create the file and SIGHUP, it'll start polling.

## Starting the workspace runner

Adding the workspace to the registry alone does NOT start a runner. The daemon needs `desired=running` for that workspace on the engine. Set it via the Board UI (tap "Run" on the workspace) or via curl:

```bash
TOK=$(security find-generic-password -s "claude-beads-runner.coordinator-token" -w)
curl -sS -X POST https://coordinator-cf.bbthechange.workers.dev/ \
  -H "Authorization: Bearer $TOK" \
  -H "content-type: application/json" \
  -d '{"op":"set-desired","args":["<project_ref>","running","brian"]}'
```

Within 60 seconds the daemon's M3 desired-state poll will fire, see no live runner pidfile, and spawn one via `launch-detached.sh`.

## Verifying

```bash
# Workspaces the daemon knows about
jq '.workspaces[] | {project_ref, dir}' ~/.config/claude-tools/workspaces.json

# Daemon reloaded successfully
grep "workspace registry reload ok" ~/.cache/claude-tools/daemon-logs/stdout.log | tail -1

# Runner spawned (after setting desired=running and waiting ~60s)
pgrep -fl run-beads-tasks
ls -lt <workspace>/.beads/runner-logs/detached-*.log | head -3
```

## Removing a workspace

```bash
# Set desired=stopped first so the daemon stops respawning
curl -sS -X POST https://coordinator-cf.bbthechange.workers.dev/ \
  -H "Authorization: Bearer $TOK" \
  -H "content-type: application/json" \
  -d '{"op":"set-desired","args":["<project_ref>","stopped","brian"]}'

# Wait ~60s for the daemon to SIGTERM the runner, then verify it's dead
sleep 70
pgrep -fl run-beads-tasks  # should not include this workspace's runner

# Edit the registry to remove the workspace entry
$EDITOR ~/.config/claude-tools/workspaces.json

# SIGHUP the daemon
kill -HUP $(cat ~/.cache/claude-tools/daemon.pid)
```

## Related

- `runbooks/daemon-control.md` — install/start/stop the daemon itself.
- `runbooks/set-desired-state.md` — the curl pattern for set-desired ops.
- `runbooks/runner-status-check.md` — verifying the runner is alive and healthy.
