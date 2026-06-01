---
name: wrapup
description: Wrap up a development task in this tools repo — review, sanity-check, commit, push. Use when the user says "wrap up", "wrapup", "finish this up", "ready to commit", "ship it", or "/wrapup".
---

# Wrap Up a Development Task

End-of-task checklist for this Claude tools / plugins repo. Run every step in order — do not skip.

## Step 1: Code Review

Run the `code-reviewer` skill (which spawns the `code-reviewer` agent). Provide a one-sentence summary of what was implemented.

The reviewer reads the diff; **you** run the gate (Step 2). Keep the summary about *what changed* — do not ask the reviewer to run `run-tests.sh`, the conformance suite, or to check "whether this breaks sibling tests." Those are your Step-2 job; asking the reviewer to do them just makes it re-run the full suite and blocks you for 5–15 min.

When the reviewer returns feedback:

1. **Evaluate each item critically** — not all feedback is valid.
2. **Fix items that are valid** — edit the code directly.
3. **Briefly note items you rejected and why.**

If the reviewer reports "No issues found", continue.

## Step 2: Sanity Checks

This repo is a collection of Claude Code tools, plugins, skills, agents, and shell scripts — there is usually no test suite. Do whatever applies:

- **`beads-runner/**` changed**: this *does* have a gate — run `bash beads-runner/run-tests.sh --changed` (or the full gate). This is the worker's job, run here once, not the reviewer's. Run it in the foreground in this same turn (never background it and end the turn).
- **Shell scripts changed**: run `bash -n <file>` (syntax check) and `shellcheck <file>` if available.
- **Plugin / skill / agent frontmatter changed**: verify YAML parses, required fields (`name`, `description`) are present, and the file is loadable. If `plugin-dev:plugin-validator` is appropriate, use it.
- **JSON files changed** (`marketplace.json`, `settings.json`, `plugin.json`): validate with `python -m json.tool <file>` or `jq . <file>`.
- **Hook scripts changed**: confirm they're executable (`ls -l`) and that paths inside them are correct.
- **Templates changed** (e.g. `project-scaffolder/templates/...`): if the template is consumed by a skill in this repo, smoke-test the consuming skill if practical.

If something fails, fix it before committing.

## Step 3: Commit

Stage only the paths relevant to this change — not `git add -A`:

```bash
git status
git add path/to/file1 path/to/file2
```

Commit with a heredoc so the multi-line message is preserved:

```bash
git commit -m "$(cat <<'EOF'
<subject — imperative mood, ≤ 72 chars>

<body: why this change exists; the diff shows the what>

Refs: <full bead id, e.g. claude-tools-xxxx>
EOF
)"
```

**Carry the full bead id.** If this work tracks a bd issue, the commit message MUST contain the full `claude-tools-<id>` — in the subject or the body (a `Refs:` footer is fine). The beads-runner close-discipline check greps `git log` for the full id; a short conventional-commit scope like `feat(xxx):` alone does NOT match it and trips a false `close_without_commit`. Folding the id into the real work commit removes any need for a separate empty "carry full bead id" commit.

Verify:

```bash
git status     # should be clean
git log -1     # confirm the commit landed
```

## Step 4: Push

Per this repo's session-close protocol (see `AGENTS.md`), work is not done until pushed:

```bash
git pull --rebase
git push
git status     # MUST show "up to date with origin"
```

If beads issues were updated this session, also run `bd dolt push`.

## Step 5: Record Wrapup Completion (if a bd issue is associated)

If this work tracks against a bd issue (`bd ready` claimed one, or you ran `bd update <id> --claim` during the session), append the `wrapup-reviewed` marker to its notes. The beads-runner's close-discipline hook checks for this marker and refuses `bd close` if absent.

```bash
bd update <id> --append-notes "wrapup-reviewed: $(date -u +%Y-%m-%dT%H:%M:%SZ) sha=$(git rev-parse HEAD) clean=$(git status --porcelain | wc -l | tr -d ' ')"
```

Write the marker AFTER push so it reflects the pushed state. If push fails, the marker is not written — that is correct (do not claim wrapup-reviewed when the diff is still local).

Report to the user: one sentence on what was committed and pushed, plus anything that needs follow-up.

## Do NOT

- Use `--no-verify` to skip hooks — fix the hook failure instead.
- Amend a previous commit unless explicitly asked.
- Force-push.
