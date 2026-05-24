# Runbook: heal a beads workspace-identity mismatch

## When

Every `bd` write fails with:

```
Error: workspace identity mismatch detected

  metadata.json project_id: <UUID-A>
  database _project_id:     <UUID-B>
```

Reads (`bd show`, `bd ready`, `bd list`) succeed and return the right
content. Only writes (`update`, `close`, `label`, `note`, …) fail.

Originally filed as `claude-tools-z0ox` (claude-tools, 2026-05-23).

## What it actually means

`bd` stores the workspace's project identity in two places that must agree:

1. **`.beads/metadata.json`** — git-tracked, the canonical/shared identity.
   Set once by `bd init`, kept in repo so every clone agrees.
2. **The embedded Dolt DB** (`.beads/embeddeddolt/<db>/`) — local-only state
   that carries a `_project_id` column / setting bd reads on every write.

`bd` compares the two before *every* write and refuses if they diverge,
because a mismatch could mean the DB belongs to a different project
(silent cross-project writes would be the worst-case failure).

Diverging is rare but **legitimate**: it happens when the embedded DB gets
rebuilt (e.g., switching from server → embedded mode, restoring from a
backup, or a `bd init` that hit the DB but not the git-tracked metadata).
The DB content stays correct — only the bookkeeping ID gets re-minted.

## Diagnose

```bash
bd context --json
# project_id in this output == metadata.json's value (it reads the file)

# Confirm the conflict (this fails LOUDLY with both IDs printed)
bd update <any-id> --notes "probe"
```

Compare with git history to confirm which side drifted:

```bash
git log --oneline -- .beads/metadata.json
git show <oldest-commit>:.beads/metadata.json
```

If `metadata.json`'s `project_id` matches the original `bd init` value in
git, the **embedded DB** is the drifted side and is what needs healing.
That's the common case.

## Heal (the easy way — try this first)

Empirically (bd 1.0.2, embedded mode, 2026-05-23 investigation), running
**any successful write with the override** appears to implicitly stamp the
DB's `_project_id` from `metadata.json`, after which subsequent writes
succeed without the override:

```bash
# Run ONCE; any write op works (update, kv set, label, note).
BEADS_SKIP_IDENTITY_CHECK=1 bd update <some-bead> --notes "identity heal"

# Verify — this should now succeed WITHOUT the override:
bd update <some-bead> --notes "post-heal probe"
```

If the second write succeeds, you're done. The DB-side `_project_id`
has been re-aligned with `metadata.json`. This is the simplest recovery
and what was used to clear the mismatch documented on `claude-tools-z0ox`.

> **Warning — do not just paper over it with the env var.** Setting
> `BEADS_SKIP_IDENTITY_CHECK=1` permanently in `.beads/runner.sh` (or any
> shell rc) defeats the only check that catches a genuinely wrong DB. Use
> the override as a one-shot heal, then go back to unset.

## Heal (fallback — direct DB rewrite)

If the one-shot-write heal above does NOT clear the mismatch (e.g., the
write succeeds but the next un-overridden write still errors), fall back
to rewriting the DB's `_project_id` directly. `bd` exposes no first-class
command for this in embedded mode (`bd doctor` is server-mode only). The
helper script wraps the dolt SQL:

```bash
bash beads-runner/heal-beads-identity-mismatch.sh
```

What the script does:

1. Reads `metadata.json`'s `project_id` (the canonical, git-tracked side).
2. Stops any running bd-managed Dolt process for this workspace.
3. Runs `dolt sql -q "UPDATE … SET _project_id = '<canonical>' …"` against
   the embedded DB.
4. Re-runs `bd update <probe-id> --notes "identity-heal probe"` (without
   the override) to confirm the heal stuck.

The script will refuse to run if `bd context --json` shows
`is_redirected=true` (worktree redirect) or `dolt_mode != embedded` —
those need a different recipe.

## Recovery if the heal probe still fails

If the post-heal probe still errors with the same mismatch, the DB likely
has the `_project_id` stored in more than one place (bd versions ≥ 1.x
keep it both as a settings row and embedded in the Dolt config). Run the
script with `--verbose` to see every UPDATE it issued, and check the
script's discovery output for any settings table it missed.

In the worst case (heal genuinely impossible), the nuclear option is:

```bash
bd export --output=.beads/backup/identity-heal-bailout.jsonl
rm -rf .beads/embeddeddolt
bd bootstrap            # rebuilds the embedded DB from issues.jsonl/backup
bd import .beads/backup/identity-heal-bailout.jsonl
```

This re-mints both sides from scratch and rewrites `metadata.json` to
match. **Commit the new `metadata.json` immediately** so other clones
don't get the same mismatch on next `git pull`.

## Why bd should fix this upstream

The current behavior — hard refusal with no `bd doctor --fix` path in
embedded mode — pushes users to `BEADS_SKIP_IDENTITY_CHECK=1` as a
de-facto default, which silently disables the genuinely-wrong-DB check.

A safer design: if `metadata.json` and the embedded DB disagree but the
DB's issue prefix / federation peer-id match the metadata, offer
`bd doctor --fix-identity` to heal automatically and require an explicit
flag to override otherwise. Filed in the closing notes on `claude-tools-z0ox`
as an upstream recommendation.
