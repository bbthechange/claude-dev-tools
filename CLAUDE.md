# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->


## Build & Test

_Add your build and test commands here_

```bash
# Example:
# npm install
# npm test
```

## Architecture Overview

_Add a brief overview of your project architecture_

## Conventions & Patterns

_Add your project-specific conventions here_

## Web/Pages task-acceptance discipline (lesson from claude-tools-bgw)

Any bd task that touches `beads-runner/web/**` is **not done when the code is committed** — it is done when the deployed Cloudflare Pages site serves the new bytes. `bd close` without a deploy is the exact failure mode that bit F1/F2/F3/G1/L3 (closed-but-not-shipped) and that [claude-tools-bgw] exists to prevent.

Board, Inbox, and Intake are routes inside ONE unified Pages project, `claude-wrangler` (consolidation in claude-tools-b59; UX-DESIGN §2 "one responsive web app"). One deploy ships all three.

**Required steps before `bd close` on a web-track task:**

1. **Deploy** the unified Pages project:
   ```bash
   (cd beads-runner/web && npx wrangler pages deploy . --project-name claude-wrangler)
   ```
2. **Verify** the deploy landed — deployed bytes must match committed bytes:
   ```bash
   bash beads-runner/verify-pages-deploy.sh          # all three routes
   bash beads-runner/verify-pages-deploy.sh board    # or just one
   ```
   A passing run prints `mismatches=0`. Any `DRIFT` or `MISS` line means the deploy did not land; re-deploy and re-verify before closing.

This is "a child closes on what Brian experiences, never on a passing weak contract check" applied to the web tracks. Local tests passing + code committed is **not** acceptance — `mismatches=0` against the live host is.
