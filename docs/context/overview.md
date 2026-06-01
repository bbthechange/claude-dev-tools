# Context: Overview & doc-router (START HERE)

> One-liner: this repo is the **attention router** — it lets Brian leave Claude
> agents working autonomously across many workspaces and only pings his phone
> when a real human decision is needed. This doc is the map; the table below
> routes you to the ONE context doc your task needs.

**Read this doc when** you're new to the repo, picking up a task cold, or unsure
which context doc covers your area. Then read the one doc the router points to —
and only that one (plus its siblings if your task genuinely spans them).

---

## The one-paragraph picture

A per-machine **daemon** supervises a **runner** per workspace; each runner loops
over `bd` tasks and spawns one fresh `claude -p` **worker** per task. When a worker
hits a fork only a human can resolve, it calls the **ask-brian MCP** tool, which
spawns a **dossier-builder** to author a polished decision card, writes it to the
hosted **Cloudflare engine**, and pings Brian's **phone**. Brian answers from a
**web app** (Board / Inbox / Intake + workspace facets); the answer flows back to
the waiting worker. Everything else — picking work, doing it, committing — happens
without him.

## System topology — the mental model you MUST have

Three tiers (three separate programs — do not conflate them; the naming bites):

```
PER-MACHINE DAEMON   beads-runner/daemon/daemon.sh   (one per computer, launchd)
   │  supervises: desired=running + no live runner ⇒ respawn; polls engine; dispatches aux
   ▼
PER-WORKSPACE RUNNER beads-runner/run-beads-tasks.sh (v1 LIVE) / runner.sh (v2 rewrite)
   │  loop: bd ready → pick → spawn ONE fresh worker → auto-commit → repeat
   ▼
PER-TASK WORKER      ephemeral `claude -p`  — does the bead; calls ask-brian MCP on a human fork
```

Plus the **hosted engine** (Cloudflare Worker `coordinator-cf.bbthechange.workers.dev`
= singleton Durable Object + D1) and the **phone web app** (Cloudflare Pages
project `claude-wrangler`).

**Naming traps (internalize these):**
- **"the runner"** = the *per-workspace* loop (`run-beads-tasks.sh`). The *central*
  per-computer thing is **the daemon**, never "the runner."
- **v1 vs v2** is a split *inside* the runner only: v1 (`run-beads-tasks.sh`) is
  LIVE; v2 (`runner.sh`) is the not-yet-deployed rewrite. The daemon has no v1/v2.
- **`runner.sh`** (the v2 script) ≠ **`<workspace>/.beads/runner.sh`** (the
  per-workspace *config* file v1 reads) — same name, different role.
- **"restart the runner" is automatic** — the daemon respawns it whenever
  `desired=running` and no runner is alive. You control the *branch* it returns on.

## The doc-router — find your task, read that doc

| If your task touches… | Read |
|---|---|
| The big picture / you're lost | **this doc** |
| `beads-runner/cf/` — engine, work-snapshot, an op, a §4 record, a migration | `engine-cloudflare.md` |
| `beads-runner/lib/*.sh` — the bash oracle, dossier/notification/stuck/local-agent libs, HTTP transport | `lib-shared.md` |
| `run-beads-tasks.sh` / `runner.sh` — the runner loop, worker lifecycle, v2 cutover | `runner.md` |
| `beads-runner/daemon/` — the supervisor, polls, runner spawn, registry | `daemon.md` |
| `beads-runner/agents/` — hat prompts, the dossier-builder, dispatch policy | `worker-agents.md` |
| `mcp-askbrian/` — the ask-brian MCP server / human-fork bridge | `mcp-askbrian.md` |
| Getting a notification to land on the phone (engine→daemon→web push) | `notifications.md` |
| ANY web/UI task — shell, Pages proxy, deploy+verify | `web-shell.md` (first) |
| The Board page (situational awareness) | `web-board.md` |
| The Inbox page (dossiers, Mermaid, PWA push) | `web-inbox.md` |
| The Intake page (file new work from phone) | `web-intake.md` |
| The workspace hub / workspaces list / capacity / cross-ws views | `web-facets.md` |
| Running tests, the regression gate, conformance, close hooks | `testing.md` |
| Filing/reviewing beads, the frozen A/B/C/D contracts, the design canon | `contracts-and-design.md` |

(All paths are under `docs/context/`. The same list, with one-line descriptions, is
in `CLAUDE.md` — that's the copy agents see at session start.)

## The anti-drift method (why these docs and contracts exist)

The failure mode this whole apparatus fights is **drift**: N parallel fresh-context
agents each build half a seam and the halves don't meet. The documented scar is the
"wired-but-not-actually-live" family (`4xe 2dk bgw 56h qxz`). The defenses:

1. **The contracts are law** — `beads-runner/UX-V2-ARCHITECTURE.md` Contracts A/B/C/D.
   A bead that violates them is *wrong*, not creative. See `contracts-and-design.md`.
2. **Beads dependencies are the drift guard** — DESIGN beads block their impl beads;
   reconciliation work blocks the specific dependents it touches. Trust the edges.
3. **Live-verify before `bd close`** — a production-touching task is done when the
   live host serves the new behavior, never when local tests pass + code is committed.
   Web tasks: `verify-pages-deploy.sh` prints `mismatches=0`. (See `testing.md`.)

## The two epics

- **`claude-tools-mhcp`** (label `ux-v2`) — the UX v2 overhaul. The WHAT is
  `beads-runner/UX-DESIGN-V2.md` (Flows A–L); the anti-drift contracts are
  `UX-V2-ARCHITECTURE.md`.
- **`claude-tools-v2cut`** (label `v2-cutover`) — finish + cut over the v2 runner.
  Build runner-touching features on the clean v2 state machine while it's offline,
  then one controlled cutover (don't patch live v1). See `runner.md`.

Re-derive current state (never trust frozen numbers in any doc):
`bd ready`, `bd list --label ux-v2`, `bd prime`, `bd memories`.

## Go deeper

- `docs/HANDOFF-UX-V2.md` — the UX-v2 anti-drift method + operational gotchas (§4).
- `docs/HANDOFF.md` — the older daemon/runner/engine operational map + "where to
  find everything" table.
- `docs/runbooks/` — step-by-step for every recurring operation.
- `bd prime` / `bd memories` — persistent workflow context + prior-session insights.

## Keeping this doc current

If you add or retire a context doc, update **both** the router table above **and**
the index in `CLAUDE.md` — they must stay in lockstep, one line per doc. If the
topology or a naming trap changes, fix the mental-model section. Keep it short; this
is the most-read doc and must stay scannable. Last substantive update: 2026-05-31.
