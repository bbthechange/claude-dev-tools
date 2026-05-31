# Runbook: install, start, stop, and inspect the per-machine daemon

## What the daemon does

`com.beads-runner.daemon` is a launchd LaunchAgent that runs continuously on Brian's Mac. Source: `beads-runner/daemon/daemon.sh`. It does:

- Anthropic usage poll (one per machine, every 300s) — replaces N per-workspace polls.
- Workspace registry load + reload on SIGHUP.
- Desired-state poll per workspace (every 60s) — spawn/kill workspace runners based on engine state.
- Hosted-resolution poll per workspace (every 30s) — observe answered dossiers continuously and dispatch resume.
- Intake poll (every 30s) — observe new intake-requests and dispatch the enricher hat.
- Flow F overview triggers (every 60s) — fire proactive overview dossiers on stage transitions.
- Heartbeat (every 10s) — log liveness.

## Install

```bash
bash beads-runner/daemon/install.sh
```

The script writes `~/Library/LaunchAgents/com.beads-runner.daemon.plist`, then `launchctl bootstrap`s it into the user's GUI domain. Idempotent — re-running overwrites and reloads.

After install:

- Plist: `~/Library/LaunchAgents/com.beads-runner.daemon.plist`
- Daemon pid: `~/.cache/claude-tools/daemon.pid`
- Logs: `~/.cache/claude-tools/daemon-logs/stdout.log` and `stderr.log`
- Registry: `~/.config/claude-tools/workspaces.json` (you create this — see `add-workspace.md`)

## Verify it's running

```bash
# launchctl says state
launchctl print "gui/$(id -u)/com.beads-runner.daemon" | grep -E "state|pid|exit"
# Expected: state = running, pid = <number>, no exit code

# Pid is alive
DAEMON_PID=$(cat ~/.cache/claude-tools/daemon.pid)
kill -0 "$DAEMON_PID" && echo "alive" || echo "DEAD"

# Recent heartbeat in log (should be within last 10s if alive)
tail -3 ~/.cache/claude-tools/daemon-logs/stdout.log
```

## Stop

```bash
# Graceful (drain in-flight work)
launchctl bootout "gui/$(id -u)/com.beads-runner.daemon"

# Force (if graceful hangs)
DAEMON_PID=$(cat ~/.cache/claude-tools/daemon.pid)
kill -9 "$DAEMON_PID"
launchctl bootout "gui/$(id -u)/com.beads-runner.daemon"
```

After stopping, the daemon will NOT auto-restart unless you bootstrap it again or reboot (launchd loads its agents at user login).

## Reload registry (no restart)

The daemon only reads `~/.config/claude-tools/workspaces.json` at startup and on SIGHUP. To pick up registry changes without restarting:

```bash
kill -HUP $(cat ~/.cache/claude-tools/daemon.pid)

# Verify
sleep 2
grep "SIGHUP received\|workspace registry reload" ~/.cache/claude-tools/daemon-logs/stdout.log | tail -2
# Expected: "SIGHUP received; reloading workspace registry" + "workspace registry reload ok (N workspaces)"
```

## Restart with new code

If you've edited `beads-runner/daemon/daemon.sh` or any of its dependencies, the running daemon is using the OLD code. To pick up changes:

```bash
bash beads-runner/daemon/install.sh
```

`install.sh` boots out an already-loaded agent before re-bootstrapping, so re-running it is an unambiguous reload — you don't need a separate `bootout` first. (The explicit `launchctl bootout … && bash install.sh` still works and is fine if you prefer it.)

### ⚠️ This applies to `launchd-plist.template` env edits too

Editing `beads-runner/daemon/launchd-plist.template` — e.g. bumping `USAGE_THRESHOLD` — and cycling with `touch .stop-beads` is a **silent no-op for the daemon**. `.stop-beads` cycles the *workspace runner loop*, not the LaunchAgent. launchd loads `EnvironmentVariables` from the **rendered** plist at `~/Library/LaunchAgents/com.beads-runner.daemon.plist` at *bootstrap* time only; until you re-run `install.sh`, launchd has no idea the template moved. This bit us once (template said 95, the live daemon kept enforcing 85 for hours, parking every workspace runner). See `claude-tools-6s6x`.

**Editing the template is not "done" until you re-run `install.sh`** (which re-renders the plist *and* re-bootstraps the daemon with the new env). Then verify the change actually loaded — see the next section.

## Verify the daemon's env matches the template

After any template edit + `install.sh`, confirm the live daemon actually loaded the new value (the "Done means verified" step for daemon config):

```bash
# Drift check: compares the committed template against BOTH the installed plist
# and the env launchd actually loaded. Prints `mismatches=0` when in sync;
# names each drifted key (and the fix) and exits non-zero otherwise.
bash beads-runner/daemon/check-plist-drift.sh

# Or confirm one key directly:
launchctl print "gui/$(id -u)/com.beads-runner.daemon" | grep USAGE_THRESHOLD
# Expected: the value matches launchd-plist.template
```

A `mismatches=0` from `check-plist-drift.sh` is the daemon-config equivalent of `verify-pages-deploy.sh`'s `mismatches=0` — committed config provably matches what's running. A `DRIFT` line means the template moved but `install.sh` wasn't (successfully) re-run; the line tells you the fix.

## Uninstall

```bash
bash beads-runner/daemon/uninstall.sh
```

Removes the plist from `~/Library/LaunchAgents/`, bootouts, cleans up the pidfile.

## What you'll see in the daemon log

```
2026-05-21T... [daemon pid=N] daemon starting; HEARTBEAT_INTERVAL=10s ...
2026-05-21T... [daemon pid=N] WARN: no workspace registry yet ...
2026-05-21T... [daemon pid=N] heartbeat                          # every 10s when idle
2026-05-21T... [daemon pid=N] M2 usage-poll: 5h=X% 7d=Y% ramp=Z% allowed=[...]   # every 300s
2026-05-21T... [daemon pid=N] M3 transition: workspace=<dir> desired <prev> → <new>   # on state change
2026-05-21T... [daemon pid=N] M3 action: workspace=<dir> desired=running ⇒ spawning   # on spawn
2026-05-21T... [daemon pid=N] M3 action: workspace=<dir> desired=stopped ⇒ SIGTERM runner pid=N   # on stop
2026-05-21T... [daemon pid=N] Flow F: dispatched overview for <bead-ref>            # on stage transition
2026-05-21T... [daemon pid=N] intake-dispatch: <intake-id> → enricher in <workspace>   # on new intake
```

Heartbeat-only logs (just `heartbeat` every 10s with no transitions or actions) means everything's healthy and idle.

## If you've forgotten whether you've installed it

```bash
ls -la ~/Library/LaunchAgents/com.beads-runner.daemon.plist
```

Exists ⇒ installed. Not exists ⇒ run `install.sh`.

## If launchctl says `exit = N` for some nonzero N

The daemon crashed. Check stderr:

```bash
tail -50 ~/.cache/claude-tools/daemon-logs/stderr.log
```

Common causes: missing `jq`, missing `bd`, missing files in `beads-runner/lib/`. Reinstall after fixing.
