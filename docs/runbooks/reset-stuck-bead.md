# Runbook: reset a bead that's stuck in the blocked-for-human state

## When

A bd task shows `status: blocked` with the `human` label and a `STUCK_NEEDS_HUMAN` block in its notes, but you've already answered the dossier on your phone (or you want to retry the task fresh because the original stuck attempt was due to a transient issue like a missing MCP tool registration).

## Background

The runner has multiple mechanisms that can drive a bead to blocked-for-human:

1. The worker agent calls the `ask-brian` MCP tool and exits cleanly, with the engine bfh record marking it pending Brian's response.
2. The worker writes the legacy structured ask to bd notes + sets `human` label + status=blocked (the original v1 protocol).
3. Fix B's auto-flip: the worker set label+notes but missed status=blocked; the runner observes this on the next poll and applies status=blocked itself.

The engine-side resolution path (Brian taps the response → engine writes the answer → daemon observes via hosted-resolution poll → daemon unblocks the bead) is the normal mechanism. Manual reset is only for situations where the engine-side resolution didn't happen or you want to retry.

## Commands

```bash
# Reset status to open and remove the human label
bd update <bead-id> --status=open
bd label remove <bead-id> human

# Verify
bd show <bead-id> | head -5
# Should show status: OPEN, no human label
```

## When this isn't enough

Fix B (`claude-tools-2ir`) auto-flips a bead back to blocked when it observes:

- status=open + `human` label + `STUCK_NEEDS_HUMAN` text in notes

After a manual reset, the notes still contain the old `STUCK_NEEDS_HUMAN` text. Once the runner picks the bead up again and the worker writes the `human` label (its standard behavior on stuck), Fix B's auto-flip fires. The result is a loop where each reset is undone within minutes.

To break the loop, you have to either:

- **Make the next attempt succeed.** If the original failure was a missing MCP tool registration, fix the registration first (see `register-mcp-tool.md`), make sure `.beads/runner.sh` allowlists the tool (see `add-tool-to-runner-allowlist.md`), and ensure the runner picks up the updated config (kill + relaunch — see `cleanup-orphan-runners.md`). Then reset the bead. The worker should now call the MCP tool successfully and never write `human` label, so Fix B won't fire.

- **Defer the bead.** If you don't have time to fix the underlying issue and just want the runner to stop re-picking it: `bd defer <bead-id> --until=2030-01-01`. Un-defer later with `bd defer <bead-id> --until=now`.

## When the bead has an associated engine record

Some stuck beads have a `blocked-for-human` record on the Cloudflare engine (the dossier-loop's S-2 control record). Manually resetting bd state does NOT clear this engine record. To check:

```bash
TOK=$(security find-generic-password -s "claude-beads-runner.coordinator-token" -w)
curl -sS -X POST https://coordinator-cf.bbthechange.workers.dev/ \
  -H "Authorization: Bearer $TOK" \
  -H "content-type: application/json" \
  -d '{"op":"get","args":["blocked-for-human","<bead-id>"]}'
```

If the response is `{"ok":true,"value":{...}}` and the value has `resolved:false`, the engine considers this bead still pending. The daemon's hosted-resolution poll will keep re-applying the blocked-for-human state to your local bd until that record is resolved.

To resolve the engine record (mark the dossier item as applied, even synthetically):

```bash
# Find the dossier_id for the bead — usually derived from the bead ref
# Get the dossier
curl -sS -X POST https://coordinator-cf.bbthechange.workers.dev/ \
  -H "Authorization: Bearer $TOK" \
  -H "content-type: application/json" \
  -d '{"op":"get","args":["dossier","<dossier-id>"]}' | jq '.items[]'

# Apply a response to the first item (use op=item-apply)
curl -sS -X POST https://coordinator-cf.bbthechange.workers.dev/ \
  -H "Authorization: Bearer $TOK" \
  -H "content-type: application/json" \
  -d '{"op":"item-apply","args":["<dossier-id>","<item-id>",{"decision":"dismiss"}]}'
```

Once any item moves to `applied` state, the engine's S-2 reconciler will mark the bfh record resolved, and the daemon's next poll will unblock the local bd state.

## Practical example: forcing 240 to retry after the MCP fix

The fixture bead `claude-tools-240` was stuck because the runner didn't have the MCP tool in its allowlist. After landing the fix (`claude-tools-qxz`):

```bash
# Kill the old runner (which was using the pre-fix runner.sh)
pkill -f run-beads-tasks

# Reset the bead
bd update claude-tools-240 --status=open
bd label remove claude-tools-240 human

# Relaunch the runner (it sources the updated .beads/runner.sh)
bash beads-runner/launch-detached.sh /Users/brianbutler/code/claude-tools

# Watch
tail -F .beads/runner-logs/detached-*.log | grep -E "claude-tools-240|mcp__askbrian|━━━"
```

Verify: a successful ask-brian invocation will show as `"name":"mcp__askbrian__ask-brian"` in a `tool_use` line in the log. If you see that, the dossier-builder is being dispatched. If you only see Fix B's STUCK_AUTOFLIP and no ask-brian tool_use, the agent took the fallback path; investigate the runner's permissions (see `add-tool-to-runner-allowlist.md`).
