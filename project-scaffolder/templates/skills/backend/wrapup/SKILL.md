---
name: wrapup
description: Wrap up a development task — review, risk-check, and commit. Use this skill when the user says "wrap up", "wrapup", "finish this up", "ready to commit", "ship it", or "/wrapup". Runs the code-reviewer, integrates valid feedback, performs a backend-specific production risk analysis (migrations / API contracts / rollback), and commits the change. Does not push.
---

# Wrap Up a Development Task (Backend)

End-of-task checklist: code review, test verification, production risk analysis, commit. Run every step in order — do not skip.

## Step 1: Code Review

Run the `code-reviewer` skill (which spawns the `code-reviewer` agent). Provide a one-sentence summary of what was implemented.

When the reviewer returns feedback:

1. **Evaluate each item critically** — not all feedback is valid. Consider whether it actually applies to the change, matches project conventions, or would introduce unnecessary scope.
2. **Fix items that are valid** — edit the code directly.
3. **Briefly note items you rejected and why** so the user can redirect if the judgment is off.

If the reviewer reports "No issues found", continue.

## Step 1b: Security Review (conditional)

Decide whether this change has meaningful **security surface**: authentication or authorization, sessions/tokens, crypto, parsing or deserialization of untrusted input, file or network I/O, secrets handling, SQL/command construction, deep links / IPC, or anything reachable by an untrusted caller.

- **If it does:** spawn the `security-reviewer` agent with a one-sentence summary of the change. Do **not** run the built-in `/security-review` skill — it injects the full diff into *this* conversation, which both bloats the working context and makes the review non-independent. The `security-reviewer` agent reviews in an isolated context (like `code-reviewer`) and is the correct tool here.
- **If it doesn't** (docs, tests, pure refactor, config with no secret/permission impact): state "no security surface — skipped" and continue.

Evaluate returned findings exactly as in Step 1: fix valid ones (re-run Step 2 after), briefly note rejected ones with a reason. Treat a HIGH finding as a commit blocker — do not commit until it is resolved or explicitly accepted by the user.

## Step 2: Test Verification

Detect the stack and run the right test command. Check the project's config (`package.json`, `pyproject.toml`, `Makefile`, etc.) before guessing:

| Stack | Command | Detection hint |
|-------|---------|----------------|
| Node | `npm test` / `pnpm test` / `yarn test` | `package.json` — **check `scripts.test` exists** first; some projects use `npm run <custom>` |
| Python (plain / venv) | `pytest` or `python -m pytest` | `pytest.ini` / `pyproject.toml [tool.pytest]` / `tests/` |
| Python (Poetry) | `poetry run pytest` | `pyproject.toml` has `[tool.poetry]` |
| Python (uv) | `uv run pytest` | `uv.lock` present |
| Python (Pipenv) | `pipenv run pytest` | `Pipfile` present |
| Go | `go test ./...` | `go.mod` |
| Rust | `cargo test` | `Cargo.toml` |
| Make-based | `make test` | `Makefile` has a `test` target |

Also run the linter / type-checker if one is configured: `tsc --noEmit`, `mypy`, `ruff check`, `eslint`, `cargo clippy`, `golangci-lint run`.

If the project has **no test runner configured at all**, note this to the user and continue — do not fabricate a test suite. If there is a runner but the change is in an untested area, say so in the wrapup summary so the user knows coverage risk before committing.

If anything fails, fix it before proceeding. Do not commit a broken build or regression.

## Step 3: Production Risk Analysis

**This step surfaces real issues that code review misses.** Take it seriously — work through every category below and state "no risk" for ones that don't apply, rather than skipping.

### Database / Migration Risks
- Any schema change? Is the migration **forward-compatible with the currently-deployed code** (so old code can still run against the new schema during rollout)?
- Any non-reversible migration (dropping a column, narrowing a type, non-null add without default)?
- Any migration that locks a large table (ALTER on a big table, adding a non-concurrent index, adding a non-null column without default)? Can it run without downtime? (Postgres: use `CREATE INDEX CONCURRENTLY`. MySQL: verify `ALGORITHM=INPLACE, LOCK=NONE` is supported for the operation.)
- Any backfill required? Is it idempotent and restartable? How long will it take on production data volume?
- Does the new code path tolerate both old and new schema during rollout?

### API Contract Risks
- Any breaking change to a public / cross-service API? (Removed field, changed type, tightened validation, renamed endpoint.)
- Any caller — mobile client, frontend, partner service — that will fail against the new contract? Do they need to ship first?
- Any change to response shape that a client might parse strictly?
- Any change to auth behavior, rate limiting, or error response format?

### Config / Environment Risks
- New environment variables or secrets required? Are they documented and set in every target environment (staging, production, preview)?
- Any change to defaults that silently alters behavior in environments where the var isn't set?
- New external dependency (service, queue, bucket, third-party API)? Is its availability / cost / rate limit acceptable?

### Background Jobs / Queue / Scheduled Work
- Any change to a job's schema or serialization? Old enqueued jobs may still be in the queue after deploy — can the new code handle them, or do they need to be drained first?
- Any change to a cron / scheduled job frequency or identity?
- Any new job that could fan out and overload a downstream service?

### Performance / Cost Risks
- Any new database query on a hot path? Does it use an index that exists on production?
- Any N+1 pattern introduced?
- Any new external API call on a hot path? Budgeted rate limit and cost?
- Any change that meaningfully increases memory / CPU per request?

### Rollout / Rollback Risks
- Is this safe to deploy mid-day, or does it need an off-hours window?
- If this breaks in production, **how do we roll back?** Is the previous version still compatible with the new database / queue state? (If not, this isn't a rollback-safe change and needs a feature flag.)
- Should this be behind a feature flag or gradual rollout?

### Security / Data Risks
- Any new endpoint exposing data — is authorization correct? (Not just authentication — does the caller have the right to read/write this specific record?)
- Any new logging of request bodies, headers, or identifiers that could log PII / secrets?
- Any new SQL built from user input — parameterized?
- Any new file upload / deserialization path — validated and size-bounded?

Summarize the findings to the user in 3-6 bullets. **If you find a blocker (non-rollback-safe migration paired with incompatible code, missing env var, breaking change for an unready client, unauthorized data exposure), stop and flag it — do not commit.**

## Step 4: Commit

Stage and commit only the files relevant to this change.

First, see what's changed:

```bash
git status
```

Stage only the paths relevant to this change — use the real paths from `git status`, not `git add -A` (which can sweep in stray files):

```bash
git add path/to/file1 path/to/file2
```

Create the commit with a heredoc so the multi-line message is preserved verbatim:

```bash
git commit -m "$(cat <<'EOF'
<subject line — imperative mood, ≤ 72 chars>

<body: why this change exists; the diff shows the what>
EOF
)"
```

Commit message guidelines:
- Subject line ≤ 72 chars, imperative mood ("Add login flow", not "Added login flow").
- Body explains the **why**, not the what (the diff shows the what).
- Reference any linked issue / ticket if the project uses one.

Verify:

```bash
git status     # should be clean
git log -1     # confirm the commit landed
```

Report to the user: one sentence on what was committed, the risk findings from Step 3, and anything that needs follow-up.

## Do NOT

- Push to remote unless the user explicitly asks.
- Use `--no-verify` to skip hooks — fix the hook failure instead.
- Amend a previous commit unless explicitly asked.
- Proceed past Step 2 if tests / lint fail, or past Step 3 if a risk blocker is found.
