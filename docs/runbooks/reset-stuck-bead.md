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

There are TWO independent re-blockers that can undo a `bd`-side reset:

1. **The S-2 control→work reconcile** (`beads-runner/cf/src/stuck.js` `reconcileBlockedForHuman`, mirrored in `beads-runner/lib/stuck-routing.sh` `sr_reconcile_blocked_for_human`). DRIVEN BY the `stuck_bfh` record's `resolved:false` flag — NOT by anything on the bd side. While that record exists with `resolved:false`, every reconcile cycle re-asserts `status=blocked` + `human` label on the bead. **Clearing bd notes / status / label is purely cosmetic at the work plane until this record is gone.** See the "Clear the `stuck_bfh` control-plane record" section below — this is the step the qxz/f0e reset recipe missed.

2. **Fix B autoflip** (`claude-tools-2ir`): re-blocks beads with `status=open` + `human` label + `STUCK_NEEDS_HUMAN` text in notes. After a manual reset, the notes still contain the old `STUCK_NEEDS_HUMAN` text; once the runner picks the bead back up and the worker writes the `human` label, Fix B fires.

To break the loop, you have to either:

- **Make the next attempt succeed.** If the original failure was a missing MCP tool registration, fix the registration first (see `register-mcp-tool.md`), make sure `.beads/runner.sh` allowlists the tool (see `add-tool-to-runner-allowlist.md`), and ensure the runner picks up the updated config (kill + relaunch — see `cleanup-orphan-runners.md`). Then reset the bead (and clear the `stuck_bfh` record — see below). The worker should now call the MCP tool successfully and never write `human` label, so Fix B won't fire.

- **Defer the bead.** If you don't have time to fix the underlying issue and just want the runner to stop re-picking it: `bd defer <bead-id> --until=2030-01-01`. Un-defer later with `bd defer <bead-id> --until=now`.

## Clear the `stuck_bfh` control-plane record (REQUIRED for re-run from scratch)

The reset recipe prescribed by `claude-tools-qxz`'s debrief —

```bash
bd update <bead-id> --status=open
bd label remove <bead-id> human
# (optionally) wipe STUCK_NEEDS_HUMAN notes
```

— is **insufficient on its own** when an engine `stuck_bfh` record exists for the bead. The S-2 reconcile loop will re-block within ~3 minutes. This gap was filed as `claude-tools-bcj` (see also `claude-tools-f0e`, where live-verify of qxz was prevented by exactly this).

If you want to **re-run the agent from scratch on the fork** (not record a decision), wipe the `stuck_bfh` record BEFORE the `bd update --status=open` step:

### 1. Check if a record exists

CF engine (the authoritative one for runners that talk to the hosted coordinator):

```bash
TOK=$(security find-generic-password -s "claude-beads-runner.coordinator-token" -w)
curl -sS -X POST https://coordinator-cf.bbthechange.workers.dev/ \
  -H "Authorization: Bearer $TOK" \
  -H "content-type: application/json" \
  -d '{"op":"stuck-bfh-get","args":["<bead-id>"]}'
```

A 200 with `{"task_ref":...,"resolved":false,...}` means the record exists and is unresolved — the reconcile will re-block.  A 404 `{"ok":false,"found":false}` means no record; you're safe.

Local bash coordinator (the `sr_*` family in `lib/stuck-routing.sh`, used by some setups):

```bash
ls "$CO_STORE/blocked-for-human/<bead-id>.json" 2>/dev/null
```

### 2. Wipe the record

The cleanest path on the CF engine is to call `stuck-resolve` with **only the task_ref** (no dossier item, no decision payload). `humanResolve` in `beads-runner/cf/src/stuck.js` skips `item-set-state` when `did`/`iid` are absent and just flips `resolved:false→true`. The next reconcile then LIFTS the work-plane block and DELETEs the record (S-2 control→work). This is the closest thing to a "no-decision restart" the current API offers:

```bash
curl -sS -X POST https://coordinator-cf.bbthechange.workers.dev/ \
  -H "Authorization: Bearer $TOK" \
  -H "content-type: application/json" \
  -d '{"op":"stuck-resolve","args":["<bead-id>"]}'

# Force the reconcile immediately (otherwise wait for the next cron cycle)
curl -sS -X POST https://coordinator-cf.bbthechange.workers.dev/ \
  -H "Authorization: Bearer $TOK" \
  -H "content-type: application/json" \
  -d '{"op":"stuck-reconcile","args":["<bead-id>"]}'
```

For the local bash coordinator's record:

```bash
rm "$CO_STORE/blocked-for-human/<bead-id>.json"
```

### 3. Verify the record is gone

```bash
# CF engine — should now return 404
curl -sS -X POST https://coordinator-cf.bbthechange.workers.dev/ \
  -H "Authorization: Bearer $TOK" \
  -H "content-type: application/json" \
  -d '{"op":"stuck-bfh-get","args":["<bead-id>"]}'
```

Only THEN run `bd update --status=open` + `bd label remove human` — those will now stick.

### Caveat

`stuck-resolve` is semantically the "human gave a decision" path. Using it without a decision payload effectively records a no-op decision on the dossier (the dossier items remain in their prior state since `did`/`iid` were omitted). For a true "wipe and re-run" op (delete the bfh + reset associated dossier items), see follow-up `claude-tools-0wu` (a dedicated `stuck-restart` op). Until that exists, the no-arg `stuck-resolve` is the documented workaround.

## When the bead has an associated engine record (with a decision payload)

The section above ("Clear the `stuck_bfh` control-plane record") is the canonical path when you want to **re-run from scratch**. The path below is for the different scenario where you actually want to **record a decision** against the dossier (e.g., dismiss the fork with an explanation, or apply a specific option) — `item-apply` writes the decision against a dossier item, which triggers the S-2 reconcile to lift the bd block.

To check the engine record:

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

# WIPE the stuck_bfh control-plane record FIRST — otherwise S-2 reconcile
# re-blocks 240 within minutes (this is the gap that bit claude-tools-f0e;
# filed as claude-tools-bcj).
TOK=$(security find-generic-password -s "claude-beads-runner.coordinator-token" -w)
curl -sS -X POST https://coordinator-cf.bbthechange.workers.dev/ \
  -H "Authorization: Bearer $TOK" -H "content-type: application/json" \
  -d '{"op":"stuck-resolve","args":["claude-tools-240"]}'
curl -sS -X POST https://coordinator-cf.bbthechange.workers.dev/ \
  -H "Authorization: Bearer $TOK" -H "content-type: application/json" \
  -d '{"op":"stuck-reconcile","args":["claude-tools-240"]}'

# Verify the bfh record is GONE (expect 404)
curl -sS -X POST https://coordinator-cf.bbthechange.workers.dev/ \
  -H "Authorization: Bearer $TOK" -H "content-type: application/json" \
  -d '{"op":"stuck-bfh-get","args":["claude-tools-240"]}'

# Now reset the bead — these will stick
bd update claude-tools-240 --status=open
bd label remove claude-tools-240 human

# Relaunch the runner (it sources the updated .beads/runner.sh)
bash beads-runner/launch-detached.sh /Users/brianbutler/code/claude-tools

# Watch
tail -F .beads/runner-logs/detached-*.log | grep -E "claude-tools-240|mcp__askbrian|━━━"
```

Verify: a successful ask-brian invocation will show as `"name":"mcp__askbrian__ask-brian"` in a `tool_use` line in the log. If you see that, the dossier-builder is being dispatched. If you only see Fix B's STUCK_AUTOFLIP and no ask-brian tool_use, the agent took the fallback path; investigate the runner's permissions (see `add-tool-to-runner-allowlist.md`).
