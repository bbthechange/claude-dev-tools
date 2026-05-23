# Runbook: clean up orphan runner processes

## When

You see multiple `bash run-beads-tasks.sh` processes in `pgrep -fl run-beads-tasks` output. They've been accumulating from previous sessions, manual relaunches, or daemon-respawn-on-stale-pidfile.

## Why it happens

The runner detaches via `launch-detached.sh` (nohup + reparent to PID 1). It stays alive after the launching shell exits. If you launch it multiple times without first killing the previous one, you stack runners. The daemon, if configured to spawn workspace runners (desired-state=running and no live pidfile), can also create new instances when it can't see the existing pidfile.

## Clean shutdown sequence

The naive `pkill -f run-beads-tasks` may not work cleanly because:

1. The daemon (if desired-state=running) will respawn a new runner within ~60 seconds.
2. Watchdog subshells from completed tasks may survive their parent.
3. Multiple workspaces may have runners; you may want to keep some alive.

Proper sequence:

```bash
# 1. Tell the daemon to stop respawning by setting desired-state=stopped for the workspaces you're cleaning.
TOK=$(security find-generic-password -s "claude-beads-runner.coordinator-token" -w)
curl -sS -X POST https://coordinator-cf.bbthechange.workers.dev/ \
  -H "Authorization: Bearer $TOK" \
  -H "content-type: application/json" \
  -d '{"op":"set-desired","args":["claude-tools","stopped","brian"]}'

# 2. SIGTERM all runner processes for that workspace
pkill -f run-beads-tasks
sleep 3

# 3. Force-kill any stragglers (watchdog subshells, hung children)
pkill -9 -f run-beads-tasks

# 4. Verify
pgrep -fl run-beads-tasks
# Expected: empty output

# 5. Clear the stale pidfile so the daemon doesn't think a dead pid is alive
rm -f <workspace>/.beads/runner-logs/detached-runner.pid

# 6. If you want a fresh runner to take its place, either:
#    (a) Set desired=running so the daemon spawns within 60s
curl -sS -X POST https://coordinator-cf.bbthechange.workers.dev/ \
  -H "Authorization: Bearer $TOK" \
  -H "content-type: application/json" \
  -d '{"op":"set-desired","args":["claude-tools","running","brian"]}'
#    OR
#    (b) Launch manually (more predictable, no 60s wait)
bash beads-runner/launch-detached.sh /Users/brianbutler/code/claude-tools
```

## When to skip the desired-state step

If you don't care whether the daemon respawns immediately (e.g., you're killing for a quick code-pickup restart), you can just do steps 2-3 and then launch manually. The daemon's respawn would land within 60 seconds and adopt your manually-spawned runner's pidfile (or get there first — either way you end up with one runner).

## Why orphan accumulation is a concern

Each orphan runner:
- Polls bd, contending for the workspace lease (only one can claim a task at a time; others get lease-denied)
- Holds open log files and the keychain (the `security` call) periodically
- Spawns its own watchdog subshells per task
- Could trigger silent failures if it tries to spawn a `claude -p` that deadlocks on the lease

When you see 10+ runner processes for one workspace, something is wrong with the launch discipline. Investigate before just killing — note what's spawning them.

## Distinguishing real orphan parents from leaked subshells (claude-tools-yva)

`pgrep -fl run-beads-tasks` will match both real runner parents AND leaked
TAIL/WATCHDOG subshells, because subshells inherit `$0` so their command
line is identical to the parent's. Before assuming a "respawn storm,"
distinguish:

```bash
# 1. PPID: real parents have PPID=1 (detached). Subshell leaks ALSO have
#    PPID=1 once their parent exits. PPID alone is not enough.
ps -A -o pid,ppid,pgid,stat,etime,command | grep run-beads-tasks

# 2. Process group: a real parent runner is its own PG leader (pid == pgid).
#    A leaked subshell (with claude-tools-yva fix) is in its own PG too, but
#    its PG members are sleep/jq/tail-f (not full runner state). A pre-yva
#    leak shared the parent's PG.

# 3. The discriminator: lsof. Leaked subshells share the parent's log fd.
#    Real parents have their OWN detached-<ts>.log. If you see 10 procs
#    pointing to the SAME log file, 9 of them are leaked subshells, not
#    runners.
for pid in $(pgrep -f run-beads-tasks); do
  echo "PID=$pid log=$(lsof -p "$pid" 2>/dev/null | awk '$4=="1u"{print $NF; exit}')"
done | sort -k2

# 4. State: real parents are typically in 'R' / 'S+' tied to a `claude -p`
#    child or polling bd. Leaked subshells are all 'S' (sleeping in sleep 15
#    or tail -f) with 0% CPU and identical etime grouped around their
#    spawn time.
```

If you have N processes with identical log fds, they're a leak swarm — one
SIGTERM round on all of them clears it without killing the actual parent
(which has its own log fd). Post-yva, this swarm should not recur; if it
does, gather a snapshot before killing and reopen claude-tools-yva.

## Related bugs

- `claude-tools-t7i` (closed) — watchdog subshells outliving their parent. Fixed in commit `f8b0162`.
- `claude-tools-yva` — ~50% subshell leak rate at task-reap boundary; `sleep` grandchildren reparented to PID 1 before pid-based `pkill -P` finds them. Fixed by switching to per-task process-group isolation (`set -m`) + PG-targeted reap (`kill -- -$PID`). The leak swarm in this section's discriminator is what yva fixes; if it returns, the fix has regressed.
- Recurring observation: even with t7i fixed, multiple `run-beads-tasks.sh` parents have shown up in the same session. The daemon's respawn-on-stale-pidfile combined with manual launches and stop-beads-triggered exits seems to be the most common source. If you find a reproducible new pattern, file a bug.
