# Handoff — claude-tools rescue epic state and operational map

Last updated: 2026-05-21 evening

## What this is

The claude-tools workspace hosts the "attention router" — a system that lets Brian leave Claude agents to work autonomously across multiple workspaces and only get pinged on his phone when a real human decision is needed. This document is the operational handoff: where we are, what's done, what isn't, what's open, and where to look for everything else.

Read this first. Then the runbooks under `docs/runbooks/` are step-by-step instructions for every operation that recurs.

## The big picture

Three tiers:

- **The hosted engine** — a Cloudflare Worker (`coordinator-cf.bbthechange.workers.dev`) backed by a Durable Object + D1 database. Stores dossiers, runner state, notifications. The phone-facing Board and Inbox are Cloudflare Pages projects that proxy reads/writes through this Worker.
- **The per-machine daemon** — a launchd LaunchAgent (`com.beads-runner.daemon.plist`) that runs continuously on Brian's Mac. Owns the Anthropic usage poll, the workspace registry, desired-state polling per workspace, the continuous hosted-resolution poll for answered dossiers, and the resume-dispatch logic.
- **The per-workspace runner** — a bash loop (`beads-runner/run-beads-tasks.sh`) per workspace that picks up bd tasks and spawns a fresh `claude -p` worker agent for each. When a worker hits a fork it can't resolve, it calls the `mcp__askbrian__ask-brian` MCP tool, which spawns the dossier-builder agent, writes a polished dossier to the Cloudflare engine, and blocks until Brian responds.

The rescue epic `claude-tools-kie` ("The actual tool") replaced what was a stubbed proof-of-concept with the actual product. 48 child tasks closed; the spine is built and most of the wiring is live. Only one task remains under the epic: `claude-tools-bzc`, the live end-to-end session with Brian, which is human-gated.

## Status snapshot

### Done

- **Per-machine daemon**: installed, running, polling. See `runbooks/daemon-control.md` to stop/start/check.
- **Workspace runner**: spawned by the daemon when desired-state is `running` for a workspace. Has idle-poll behavior (stays alive between tasks). Has the MCP allowlist fix. Has the watchdog cleanup fix. Has Node v25 PATH-prime protection. Has Fix B auto-flip on agent slip.
- **Hosted Cloudflare engine**: deployed, includes all op handlers (put/get/poll/set-desired/timer-*/work-snapshot/item-apply). Token in macOS Keychain at service `claude-beads-runner.coordinator-token`.
- **Board**: deployed with per-workspace start/stop toggles, capacity strip, failure badges, lifecycle columns. See `https://claude-wrangler-board.pages.dev/`.
- **Inbox**: deployed with Mermaid rendering, tolerant degradation for non-conformant dossiers, redacted forensic blob view. See `https://claude-wrangler-inbox.pages.dev/`.
- **Production `ask-brian` MCP server**: built at `mcp-askbrian/server.mjs`, registered at user scope, takes worker dump + spawns dossier-builder + writes to engine + polls for answer. Bridge: `mcp-askbrian/helpers/engine-bridge.sh`.
- **Dossier-builder agent**: prompt at `beads-runner/agents/dossier-builder.system.md`. Dispatched by the MCP server, runs inside the workspace with full tool access.
- **Specialist hat agents**: 7 prompts under `beads-runner/agents/` (ux, design, impl, docs, tests, reconciler, enricher, dossier-builder). Launched via `beads-runner/agents/specialist.sh --kind=<hat>`.
- **Flow A intake**: phone UI at `https://claude-wrangler-inbox.pages.dev/intake/` (or board's intake route), backed by enricher hat dispatch from the daemon.
- **Lifecycle stages**: `stage:<value>` label discipline (idea/ux/design/impl/docs/tests/done) applied to all 49 kie children. See `beads-runner/agents/lifecycle.md` and `beads-runner/agents/gate-policy.md`.
- **Capacity gating**: workspace runner consults daemon's `ask-capacity` on every pickup. Spare-cycles 14.2%/day ramp implemented.

### Not done

- **`claude-tools-bzc`** — the live closing-gate session with Brian (currently set up but the dossier loop hasn't produced a visible artifact end-to-end on Brian's phone yet; see "active situation" below).
- **`claude-tools-23r`** — Inbox lacks a dismiss/delete affordance for stale dossiers. P3. Important for UX hygiene because old test dossiers accumulate.
- **`claude-tools-240`** — the engineered fixture task ("terminology doc decision"). Created to drive the closing-gate; currently in a known-stuck state because the runner has been picking it up and falling through to the bd-notes fallback before the MCP fix was live. With the fix now live, the next attempt should produce a real dossier — see "active situation."

### Active situation (where we are right now)

- **The runner is alive** (pid 32894 was the last seen claude -p; check `pgrep -fl run-beads-tasks`).
- **`claude-tools-240` is OPEN at the top of the ready queue**, waiting for the runner to finish its current task and pick it up. The runner has the MCP tool allowlisted; next pickup of 240 should successfully call `mcp__askbrian__ask-brian` and produce a real dossier in Brian's Inbox.
- **The Inbox currently shows 13 testing dossiers** from earlier work (most are on `claude-tools-txj`, 9 duplicates). The new fixture dossier, when it arrives, should sort to the top by `created_at` (per `claude-tools-56h` fix, deployed). Look for an item titled with the actual TL;DR, not "1 thing needs you".

## Loose threads — things we flagged but haven't fully closed

These are real concerns surfaced during the rescue that should not be lost. None are blocking but each is worth picking up.

### The "wired but not actually live" failure-mode pattern

Five separate bugs in 24 hours were the same shape: a bd task closes when code lands + local tests pass, but the live production wiring/deploy/registration is missing. The user sees the feature on their phone behaving as if it never existed.

Instances:
- `claude-tools-4xe` (engine-vs-renderer conformance — earlier rescue)
- `claude-tools-2dk` (Cloudflare adapter passthrough for `set-desired`)
- `claude-tools-bgw` (Pages static-asset deploy gap)
- `claude-tools-56h` (work-snapshot projection drops user-facing fields)
- `claude-tools-qxz` (MCP tool registered but not in runner allowlist)

`claude-tools-bgw`'s fix includes a project-level discipline note that web-track tasks must `wrangler pages deploy` + curl-verify before closing. The pattern likely extends beyond web tasks — any production-touching task should probably have a probe-call acceptance gate before close. Worth a deliberate discipline conversation later.

### Fix B over-trigger on persistent notes

`claude-tools-2ir` ("Fix B") relaxed `detect_worker_stuck_primary` to auto-flip status=blocked when an agent set the `human` label and a STUCK_NEEDS_HUMAN note but missed step 1. The implementation tests for the literal string `STUCK_NEEDS_HUMAN` anywhere in the bd notes — including stale text from prior attempts. As a result, once a bead has had a stuck attempt, any subsequent re-pickup that re-applies the human label triggers the auto-flip even if the underlying problem is resolved.

Practical symptom: `claude-tools-240` keeps getting re-blocked even after manual reset, until the agent actually succeeds in calling ask-brian (which doesn't add the human label, so the auto-flip doesn't fire). Worth tightening the Fix B predicate to "recent" (e.g., last N seconds) rather than "any presence anywhere in notes."

### Multiple runner accumulation

Across this session, runner instances accumulated repeatedly. Causes identified:
- Daemon respawning when desired-state stays `running` and pidfile points at a dead pid (correct behavior).
- Watchdog subshells outliving their parent claude (`t7i`, closed).
- Manual launches not tracked by the daemon's adopt logic.

`runbooks/cleanup-orphan-runners.md` documents the cleanup. Worth monitoring whether this recurs after extended autonomous operation — if it does, the daemon's adopt logic may need hardening.

### Token-in-MCP-config security wart

The production `mcp__askbrian__ask-brian` MCP registration requires `COORDINATOR_TOKEN` to be passed via `claude mcp add -e COORDINATOR_TOKEN=...`, which lands the token in `~/.claude.json`. The token is the same one in macOS Keychain at service `claude-beads-runner.coordinator-token`. Worth migrating the MCP server to read from Keychain at startup instead of taking the env var, so the secret doesn't sit in a config file. Not blocking, but a real cleanup.

### Dossier-cleanup hygiene

The Inbox has 13 stale dossiers from testing (9 of which are duplicates on a single bead `claude-tools-txj`). There's no dismiss/delete UI today. `claude-tools-23r` (P3) is filed. `claude-tools-vxs` (P2, closed) cleaned up some duplicate sources but didn't remove existing dossiers. Worth a one-time cleanup pass against the engine plus a delete affordance.

### The closing-gate test itself

`claude-tools-bzc` requires Brian to experience the full dossier loop end-to-end on his phone. The fixture `claude-tools-240` was set up to drive this. As of this handoff the next pickup attempt with the MCP fix live should be the first honest test. If it succeeds — a real dossier renders on the phone, Brian taps responses, the worker resumes in-session — the rescue epic closes.

### Things deferred to the future

- **`claude-tools-r0m`** — cross-workspace agent-to-agent communication (frontend agent asks backend agent a question via MCP). Deferred until 2030; revisit post-Z if the manual-relay pain persists.
- **`claude-tools-bcm`** — Claude Agent SDK + `canUseTool` research. Deferred until post-June-15-2026 when the SDK pricing may change (per the support doc citation in the bead). If the SDK becomes subscription-covered then, evaluate migrating from the MCP-blocking pattern.
- **The terminology doc decision itself** — the `claude-tools-240` fixture is asking for a real architectural decision about a per-workspace terminology document. When that decision lands, it shapes how every future agent reads consistent vocabulary. Real product work.

## Where to find everything

| What | Where |
|---|---|
| Design docs (frozen) | `beads-runner/DESIGN.md`, `beads-runner/UX-DESIGN.md`, `beads-runner/INTERFACE.md`, `beads-runner/BEHAVIORAL-CONTRACT.md` |
| Headless-stuck-signal research | `beads-runner/research/headless-stuck-signal.md` |
| MCP-tool research | `beads-runner/research/mcp-interactive-tool.md` |
| Runner script (v1, active in production) | `beads-runner/run-beads-tasks.sh` |
| Runner script (v2 rewrite target, not yet deployed) | `beads-runner/runner.sh` |
| Per-workspace runner config | `<workspace>/.beads/runner.sh` |
| Daemon | `beads-runner/daemon/daemon.sh` + `beads-runner/daemon/*.sh` |
| Daemon install | `~/Library/LaunchAgents/com.beads-runner.daemon.plist` |
| Daemon logs | `~/.cache/claude-tools/daemon-logs/` |
| Daemon workspace registry | `~/.config/claude-tools/workspaces.json` |
| Runner logs (per-workspace) | `<workspace>/.beads/runner-logs/detached-*.log` |
| Specialist agent shim | `beads-runner/agents/specialist.sh` |
| Agent system prompts | `beads-runner/agents/*.system.md` |
| MCP server (production) | `mcp-askbrian/server.mjs` |
| MCP-to-engine bridge | `mcp-askbrian/helpers/engine-bridge.sh` |
| Cloudflare Worker source | `beads-runner/cf/src/*.js` |
| Cloudflare Worker config | `beads-runner/cf/wrangler.production.toml` |
| Pages: Board source | `beads-runner/web/board/` |
| Pages: Inbox source | `beads-runner/web/inbox/` |
| bd issue tracker | `bd` CLI; data in `.beads/` |
| Beads memory (persistent insights) | `bd memories` |
| This handoff | `docs/HANDOFF.md` |
| Operational runbooks | `docs/runbooks/*.md` |

## Quick orientation for a fresh agent

If you've just picked this project up cold:

1. Read this file end-to-end.
2. `bd prime` — get the beads workflow context.
3. `bd ready` and `bd list --status=in_progress` — see what work is pending.
4. `bd memories` — read persistent insights from prior sessions.
5. Look at `docs/runbooks/` for any operation you need to do.
6. The `beads-runner/DESIGN.md` and `beads-runner/UX-DESIGN.md` documents are the frozen architecture contracts. Don't silently edit; if you need to amend, do it explicitly as a section-11 amend with rationale (see `claude-tools-b7s` and `claude-tools-9zk` for examples).

## Conventions

- **Never use the section-symbol character in user-facing prose.** It's an internal-contract reference; reads as jargon to humans.
- **Component vocabulary** that should be used consistently in dossiers and docs: "workspace runner", "Cloudflare worker" (or "hosted engine"), "per-machine daemon", "dossier-builder agent", "ask-brian MCP tool", "Brian's phone", "Inbox", "Board".
- **bd is the task tracker.** Do not use TodoWrite / TaskCreate / markdown todo lists. Use `bd create` / `bd ready` / `bd close`. The project's CLAUDE.md enforces this.
- **bd memories are persistent across sessions.** Use `bd remember` for insights that future-you will need. Do not use `MEMORY.md` files.
- **Production-touching tasks should not close on a passing local test.** Always live-verify (curl the deployed URL, observe the actual phone-facing behavior) before close. This is the recurring failure mode the rescue epic explicitly fought.
