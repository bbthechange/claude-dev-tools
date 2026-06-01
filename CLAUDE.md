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


## Context docs — read the ONE for your task FIRST (mandatory)

Before you touch code, **read the context doc for the area you're working in** (one
per area, under `docs/context/`). Each is a short, current orientation: what the
segment is, its key files, its invariants, the common recipes, and the scars. They
exist so a fresh agent gets the right mental model fast and the parallel swarm
doesn't drift. **This is not optional and not "skim the first paragraph" — read the
whole doc; they are kept short on purpose so you can.**

If you're unsure which one, read `docs/context/overview.md` first — it has a router
table. One doc per line below; match your task to the area and read that doc:

| Doc | Covers (area of the code) |
|---|---|
| `docs/context/overview.md` | **START HERE.** System map, the three tiers, naming traps, the two epics, anti-drift method, and a router to every doc below. |
| `docs/context/engine-cloudflare.md` | The hosted Cloudflare engine: the Worker auth chokepoint, the singleton Coordinator DO + D1, the `work-snapshot` projection, adding an op, §4 records vs transient tables. Code: `beads-runner/cf/`. |
| `docs/context/lib-shared.md` | The bash library layer the runner & tests source: the `coordinator.sh` oracle (differential twin of the CF engine), dossier/notification/stuck/consequence/local-agent libs, the HTTP transport to the live engine. Code: `beads-runner/lib/`. |
| `docs/context/runner.md` | The per-workspace runner loop that spawns one fresh `claude -p` worker per bd task: v1 `run-beads-tasks.sh` (LIVE) vs v2 `runner.sh` (rewrite), the worker lifecycle, the v2 cutover, the behavioral contract. Code: `beads-runner/run-beads-tasks.sh`, `runner.sh`. |
| `docs/context/daemon.md` | The per-machine launchd daemon that supervises runners: spawns/kills them, polls Cloudflare for desired-state + answered dossiers, dispatches aux agents, owns the workspace registry. Code: `beads-runner/daemon/`. |
| `docs/context/worker-agents.md` | The worker persona prompts & dispatch policy: the specialist hats (ux/design/impl/docs/tests/reconciler/enricher), the dossier-builder, `specialist.sh`, lifecycle/gate policy. Code: `beads-runner/agents/`. |
| `docs/context/mcp-askbrian.md` | The ask-brian MCP server: the worker→human-decision bridge that spawns the dossier-builder, writes the dossier to the engine, and blocks for Brian's phone answer. Code: `mcp-askbrian/`. |
| `docs/context/notifications.md` | The phone notification/push DELIVERY pipeline end-to-end: engine triggers → web-push transport → daemon poll → phone service worker. Spans engine/daemon/lib/web. |
| `docs/context/web-shell.md` | Frontend app-shell & shipping: the shared shell (`web/shared/`), the Pages Function proxy layer (`web/functions/`), the unified `claude-wrangler` Pages project, deploy-then-verify discipline. **READ FOR ANY WEB TASK.** |
| `docs/context/web-board.md` | The Board page (Flow E): the one-screen "is anything waiting on me, and is the machine healthy?" view. Code: `beads-runner/web/board/`. |
| `docs/context/web-inbox.md` | The Inbox page (Flow B): the WAITING-ON-YOU dossier lane, tolerant Mermaid/dossier rendering, the PWA service worker + push subscription, the inbox verbs. Code: `beads-runner/web/inbox/`. |
| `docs/context/web-intake.md` | The Intake page (Flow A): file new work from the phone, backed by enricher-hat dispatch. Code: `beads-runner/web/intake/`. |
| `docs/context/web-facets.md` | The UX-v2 facet routes: the per-workspace hub, the workspaces list, the capacity view, the cross-workspace view. Code: `beads-runner/web/{workspace,workspaces,capacity,cross-ws}/`. |
| `docs/context/testing.md` | How to test & the quality gates: `run-tests.sh` (the offline regression gate + tiers), the conformance harness, the live-verify step, the enforcement hooks. Run before every `bd close`. |
| `docs/context/contracts-and-design.md` | The frozen contracts & design canon: the A/B/C/D anti-drift contracts, the big design-doc index (INTERFACE/DESIGN/UX-DESIGN-V2/MACHINE-STATE/BEHAVIORAL-CONTRACT), the vocabulary/closed enums, the amend protocol. Read when filing beads or reviewing for conformance. |

**When you finish your task, UPDATE the doc you read** if your run surfaced anything
a future agent will need and didn't find there: a new invariant, a moved/renamed
file, a fresh gotcha, a changed recipe. Keep edits concise and delete stale lines —
the docs only work if they stay short and true. (Adding/retiring a doc ⇒ update this
table **and** `docs/context/overview.md` in lockstep.)

## Build & Test

### Offline regression gate — `beads-runner/run-tests.sh`

`beads-runner/run-tests.sh` is **the one offline regression gate** (TESTING-STRATEGY.md
§7.1). It runs every offline, deterministic test tier (T1–T7) with a unified
per-tier tally and a single exit code. Run it before every `bd close` on
beads-runner work — a green run is the §5 acceptance bar's "the full offline
suite is green" step (the only defence against a sibling break in the shared
`workSnapshot()` seam).

```bash
bash beads-runner/run-tests.sh            # full gate (all offline tiers)
bash beads-runner/run-tests.sh --changed  # only tiers touched by the git diff (fast, pre-close)
bash beads-runner/run-tests.sh --tier lib # one tier (repeatable / comma-list: --tier lib,cf)
bash beads-runner/run-tests.sh --list     # list tier names
```

Tiers (discovered by **glob**, never a hardcoded list — new `test-*.sh` and
`cf/test/conformance-*.sh` auto-enroll): `cf` (vitest engine differential),
`lib` `daemon` `hooks` `agents` `top` (the bash `test-*.sh` suites),
`conformance` (runner BC harness), `contract` (machine-state + UX-v2 A–D
guardian). It prints `TIER <name> pass=N fail=M` per tier and a final
`TOTAL pass=N fail=M`, exiting non-zero (and naming the failing tier) on any fail.

**It deliberately EXCLUDES the one networked tier (T8)** — `verify-pages-deploy.sh`,
`cf/pages-dev/verify.sh`, and any live-Worker probe stay **manual at close** (the
bgw/2dk acceptance step below). `run-tests.sh` green is the regression gate;
T8 live-verify is the separate, required acceptance gate.

## Architecture Overview

This repo is the **attention router**: it lets Brian leave Claude agents working
autonomously across many workspaces and only pings his phone when a real human
decision is needed. Three tiers + a hosted brain + a phone web app:

- **Per-machine daemon** (`beads-runner/daemon/`) supervises one **per-workspace
  runner** (`run-beads-tasks.sh` v1 / `runner.sh` v2) each; each runner loops over
  `bd` tasks and spawns one fresh `claude -p` **worker** per task.
- A worker that hits a human fork calls the **ask-brian MCP** (`mcp-askbrian/`),
  which spawns a **dossier-builder** (`beads-runner/agents/`), writes a decision
  card to the **Cloudflare engine** (`beads-runner/cf/`), and pings Brian's phone.
- Brian answers from the **web app** (`beads-runner/web/`, Pages project
  `claude-wrangler`); the answer flows back to the waiting worker.

Full map + naming traps: `docs/context/overview.md`. Per-area detail: the context
docs table above. Operational handoffs: `docs/HANDOFF.md`, `docs/HANDOFF-UX-V2.md`.

## Conventions & Patterns

- **bd is the task tracker** — never TodoWrite / TaskCreate / markdown todo lists.
- **Production-touching tasks live-verify before `bd close`** — local tests + commit
  is not acceptance; the live host serving the new behavior is (the `bgw`/`2dk`
  scar). Web: `verify-pages-deploy.sh` ⇒ `mismatches=0`.
- **The A/B/C/D contracts are law** — `beads-runner/UX-V2-ARCHITECTURE.md`; don't
  silently edit a frozen design doc, amend explicitly. See `docs/context/contracts-and-design.md`.
- **Component vocabulary** (use consistently): workspace runner, per-machine daemon,
  hosted engine / Cloudflare worker, dossier-builder agent, ask-brian MCP tool,
  Brian's phone, Inbox, Board. Avoid the section-symbol in human-facing prose.

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
