# Runbook: set a workspace's desired-state on the hosted engine

## When

You want the daemon to spawn (`running`), pause (`paused`), constrain to spare cycles (`spare-cycles`), or stop (`stopped`) a workspace's runner. This is what the Board's per-workspace Run/Pause/Spare-only/Stop toggles do under the hood.

## State semantics

- **running**: daemon spawns a runner if none alive; leaves an existing runner alone.
- **spare-cycles**: same as running, but the runner gates pickups on the spare-cycles ramp (14.2%/day) — only picks up low-priority work outside business needs.
- **paused**: leaves the runner alive; the runner's own `job_reconcile_desired` holds it at idle (no new pickups). Does NOT spawn a paused workspace from cold.
- **stopped**: SIGTERMs the runner. Does not spawn a stopped workspace.

The daemon polls desired-state every 60 seconds (configurable via `DESIRED_STATE_POLL_INTERVAL` env). State transitions are picked up within one poll cycle.

## Setting via the Board UI

The "cleanest" path: open `https://claude-wrangler-board.pages.dev/` on a phone or laptop, find the workspace, tap a state button. This requires the Board's `set-desired` Pages function to be deployed (see `deploy-pages.md`) and the Cloudflare Worker's adapter to support the `set-desired` op (see `deploy-cloudflare-worker.md`).

## Setting via curl (when the UI is broken or you're scripting)

```bash
TOK=$(security find-generic-password -s "claude-beads-runner.coordinator-token" -w)
curl -sS -X POST https://coordinator-cf.bbthechange.workers.dev/ \
  -H "Authorization: Bearer $TOK" \
  -H "content-type: application/json" \
  -d '{"op":"set-desired","args":["<project_ref>","<state>","<actor>"]}'
```

Args:
- `<project_ref>`: the workspace's bd prefix (e.g., `claude-tools`, `thirsty`).
- `<state>`: one of `running`, `paused`, `spare-cycles`, `stopped`.
- `<actor>`: a string identifier — convention is `brian` for human-initiated, `daemon` for daemon-initiated, `runner` for self-initiated. Used for C4 audit (who set this state).

## Verifying

```bash
# Read the current desired-state for a workspace
curl -sS -X POST https://coordinator-cf.bbthechange.workers.dev/ \
  -H "Authorization: Bearer $TOK" \
  -H "content-type: application/json" \
  -d '{"op":"get","args":["runner_state","<project_ref>"]}' | jq '{desired, actual, last_heartbeat_at, current_task_ref}'
```

Then watch the daemon log for the M3 transition:

```bash
tail -F ~/.cache/claude-tools/daemon-logs/stdout.log | grep -E "M3 transition|M3 action"
# Expected within ~60s:
#   M3 transition: workspace=<dir> ... desired <prev> → <new>
#   M3 action: workspace=<dir> desired=<new> ⇒ <spawning|SIGTERM|no-op>
```

## Common gotchas

- **Setting `desired=running` doesn't immediately spawn a runner.** The daemon polls every 60s. Be patient or do `bash beads-runner/launch-detached.sh <workspace>` to skip the wait.
- **A `paused` workspace with no live runner stays dead.** Setting `paused` then `running` won't bring it back any faster than setting `running` from cold — the spawn happens on the desired=running path.
- **Setting `stopped` will kill an in-flight task.** The runner's reconcile path observes the desired-state change within 60 seconds and SIGTERMs the claude child. Any in-progress work is lost unless the task agent has saved state. If you want the runner to finish its current task first, write `.stop-beads` in the workspace instead (graceful drain).
- **The `set-desired` response shape**: the live engine returns the new runner_state record. Old versions of the adapter may return `{"desired": null}` or similar — that's not an error, just the acknowledgment shape. Use the get-runner_state probe above to confirm the state actually changed.

## Setting desired-state when the engine adapter doesn't support set-desired

If the adapter is broken (`claude-tools-2dk` pattern), you might see:

```
{"ok":false,"error":"co: adapter - unsupported POST proxy op 'set-desired'"}
```

In that case the Worker handler is fine but the adapter (which fronts the Worker for Pages) doesn't passthrough the op. See `deploy-cloudflare-worker.md` for the fix.
