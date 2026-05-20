# beads-runner daemon (per-machine Local Agent)

This directory is the **per-machine daemon** referenced by DESIGN.md
§3.2 (AD1 §11 amend, 2026-05-20). It is **one long-lived supervisor
process per computer**, distinct from every workspace runner —
`pid_daemon ≠ pid_any_workspace_runner`.

On macOS it runs as a per-user **launchd LaunchAgent** (NOT a system-wide
`LaunchDaemon`): it runs in Brian's GUI login session, has Keychain
access, and is restarted on crash by launchd's `KeepAlive`.

## M1 scope (claude-tools-gim — what this commit ships)

This is the **skeleton** only. The daemon process exists, is
single-instance, logs, handles SIGTERM as graceful drain, and runs an
empty 10-second heartbeat loop. The five real jobs (DESIGN §3.2 / §7) —
Anthropic usage poll, desired-state poll, heartbeat-actual-state,
hosted-resolution / resume dispatch, work-snapshot publish — land in
**M2–M6** (claude-tools-8mz, -cgh, -8jb, …). M1 deliberately ships
**no behavior**, just the lifecycle.

## Files

| File | Purpose |
|---|---|
| `daemon.sh` | the supervisor process: pidfile, signal handlers, heartbeat loop |
| `workspace-registry.sh` | library: load & parse `~/.config/claude-tools/workspaces.json` |
| `launchd-plist.template` | the LaunchAgent definition (token-substituted by `install.sh`) |
| `install.sh` | writes the plist into `~/Library/LaunchAgents/` and `launchctl bootstrap`s it |
| `uninstall.sh` | `launchctl bootout` and remove the plist |

## On-disk layout

```
~/.config/claude-tools/workspaces.json    # workspace registry (this machine's index)
~/.cache/claude-tools/daemon.pid          # single-instance pidfile
~/.cache/claude-tools/daemon-logs/
  ├── stdout.log                          # launchd-captured stdout
  ├── stderr.log                          # launchd-captured stderr
  └── .rotation-marker                    # appended on every daemon start
~/Library/LaunchAgents/com.beads-runner.daemon.plist
```

## Workspace registry schema (`workspaces.json`)

```json
{
  "workspaces": [
    {
      "project_ref": "claude-tools",
      "dir": "/Users/brianbutler/code/claude-tools",
      "coordinator_url": "https://coordinator.example.workers.dev",
      "coordinator_token_keychain": "beads-runner/coordinator-token/claude-tools"
    }
  ]
}
```

**Secrets policy.** `coordinator_token_keychain` is the **name** of a
macOS Keychain item, never the token itself. Tokens live in the
Keychain; M2/M3 read them via
`security find-generic-password -s <item> -w`. Same posture as the
BC-34 / §9.2 credential path already used by `lib/local-agent.sh`.

**Relationship to `.beads/runner.sh`.** The per-workspace runner config
(env vars, project-local overrides) stays in
`<workspace>/.beads/runner.sh` — that's where the workspace runner
reads its config. The registry here is the **daemon's index of which
workspaces this machine is responsible for**, not a replacement for
`runner.sh`. Two files; no overlap.

## Operator runbook

### Install
```bash
beads-runner/daemon/install.sh
```
This writes the plist into `~/Library/LaunchAgents/`, bootstraps it
into the user's `gui/$UID` launchd domain, and kickstarts the first run.

### Verify it's running
```bash
launchctl print "gui/$(id -u)/com.beads-runner.daemon" | grep -E 'state|pid'
tail -F ~/.cache/claude-tools/daemon-logs/stdout.log
```
You should see a `heartbeat` line every 10 seconds.

### Stop / restart
```bash
launchctl kickstart -k "gui/$(id -u)/com.beads-runner.daemon"   # restart
launchctl bootout   "gui/$(id -u)/com.beads-runner.daemon"      # stop
```
The daemon's SIGTERM handler runs the graceful-drain hook (currently a
no-op in M1) and releases the pidfile via its `EXIT` trap.

### Uninstall
```bash
beads-runner/daemon/uninstall.sh
```
Removes the plist and unloads the agent. Logs and the workspace
registry are preserved (operator data, not install artifacts).

### Reload the workspace registry without restarting
Send SIGHUP:
```bash
kill -HUP "$(cat ~/.cache/claude-tools/daemon.pid)"
```

## What this is NOT — yet

- **No usage poll.** Workspaces still call the Anthropic usage API
  themselves until M2 lands the one-per-machine poll here.
- **No spawning of workspace runners.** M3 wires the desired-state
  reconciler to spawn/kill workspace runners. Until then this daemon
  just heartbeats.
- **No hosted-resolution poll / `bd-surgery` dispatch.** That's M4
  (claude-tools-8jb / the AD8 build pointer).
- **No log rotation policy.** Currently we append a start marker on
  every boot but never truncate. Rotation lands with M5.
