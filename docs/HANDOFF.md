# Handoff — claude-tools rescue epic state and operational map

Last updated: 2026-05-29

## What this is

The claude-tools workspace hosts the "attention router" — a system that lets Brian leave Claude agents to work autonomously across multiple workspaces and only get pinged on his phone when a real human decision is needed. This document is the operational handoff: where we are, what's done, what isn't, what's open, and where to look for everything else.

Read this first. Then the runbooks under `docs/runbooks/` are step-by-step instructions for every operation that recurs.

## The big picture

Three tiers:

- **The hosted engine** — a Cloudflare Worker (`coordinator-cf.bbthechange.workers.dev`) backed by a Durable Object + D1 database. Stores dossiers, runner state, notifications. The phone-facing Board and Inbox are Cloudflare Pages projects that proxy reads/writes through this Worker.
- **The per-machine daemon** — a launchd LaunchAgent (`com.beads-runner.daemon.plist`) that runs continuously on Brian's Mac. Owns the Anthropic usage poll, the workspace registry, desired-state polling per workspace, the continuous hosted-resolution poll for answered dossiers, and the resume-dispatch logic.
- **The per-workspace runner** — a bash loop (`beads-runner/run-beads-tasks.sh`) per workspace that picks up bd tasks and spawns a fresh `claude -p` worker agent for each. When a worker hits a fork it can't resolve, it calls the `mcp__askbrian__ask-brian` MCP tool, which spawns the dossier-builder agent, writes a polished dossier to the Cloudflare engine, and blocks until Brian responds.

The rescue epic `claude-tools-kie` ("The actual tool") replaced what was a stubbed proof-of-concept with the actual product. The spine is built and the wiring is live. The epic itself is **DEFERRED until 2030-01-01** along with its sole remaining child `claude-tools-bzc` (the live end-to-end session with Brian) — per the 8bm/38y churn-stop precedent, the closing gate is a HUMAN GATE that only un-defers when Brian is ready to drive the session on his phone. From an autonomous-work perspective, kie is complete; the un-defer protocol is `bd undefer claude-tools-bzc claude-tools-kie`, reclaim, and drive it live.

The companion epic `claude-tools-ir7` ("beads-runner reliability") that tracked runner self-modification / queue-starvation bugs is now **closed** (2026-05-24, all six children resolved; two residual P3 slivers split out as `claude-tools-507` + `claude-tools-7my` and themselves closed). It was kept human-triaged throughout so the live runner did not auto-rewrite the script it was executing.

## Status snapshot

### Done

- **Per-machine daemon**: installed, running, polling. See `runbooks/daemon-control.md` to stop/start/check.
- **Workspace runner**: spawned by the daemon when desired-state is `running` for a workspace. Has idle-poll behavior (`giu`, stays alive between tasks). Has the MCP allowlist fix (`qxz`). Has the watchdog cleanup fix. Has Node v25 PATH-prime protection (`4tj`) + heartbeat-null fix (`3w8`). Has Fix B auto-flip on agent slip. Has watchdog guard against empty/non-numeric `LAST` (`h7n`). Has watchdog+tail subshell-leak fixes (`8mb`, `yva`). Has `TASK_COST_CLASS` per-iteration reset (`hkwg`). Has `next_task()` epic exclusion + hot-loop backoff (`dzc`, `g20`, `8ux`). Has stuck-backstop bead-drive to `blocked` + human label (`2y1`) plus dedicated stuck-restart op (`daw`, `5os`).
- **Production MCP + dossier-builder reliability**: builder timeout raised past real Opus 4.7 authoring time and `§7.3` backstop dossiers now reach the hosted engine (`cxj`); builder emits JSON dossiers instead of answering the question, workers stop over-escalating trivial asks (`cvj`); `specialist.sh` grants Bash to the builder so it can actually gather context (`lhc`); `qxz` live-verified end-to-end against `claude-tools-240` (`f0e`).
- **Close discipline**: Stop + PreToolUse hooks + post-terminal watchdog enforce that bd state matches the work actually done (`td0y`); `.beads/issues.jsonl` excluded from the dirty_tree audit so JSONL churn no longer false-flags closes (`u4ms`).
- **Specialist hats**: enricher (and the rest of the hat set) granted `Bash(bd:*)` so they can actually use `bd` (`e5aq`).
- **Hosted Cloudflare engine**: deployed, includes all op handlers (put/get/poll/set-desired/timer-*/work-snapshot/item-apply). Token in macOS Keychain at service `claude-beads-runner.coordinator-token`.
- **Board**: deployed with per-workspace start/stop toggles, capacity strip, failure badges, lifecycle columns. See `https://claude-wrangler.pages.dev/board` (route inside the unified `claude-wrangler` Pages project per claude-tools-b59).
- **Inbox**: deployed with Mermaid rendering, tolerant degradation for non-conformant dossiers, redacted forensic blob view. See `https://claude-wrangler.pages.dev/inbox`.
- **Production `ask-brian` MCP server**: built at `mcp-askbrian/server.mjs`, registered at user scope, takes worker dump + spawns dossier-builder + writes to engine + polls for answer. Bridge: `mcp-askbrian/helpers/engine-bridge.sh`.
- **Dossier-builder agent**: prompt at `beads-runner/agents/dossier-builder.system.md`. Dispatched by the MCP server, runs inside the workspace with full tool access.
- **Specialist hat agents**: 7 prompts under `beads-runner/agents/` (ux, design, impl, docs, tests, reconciler, enricher, dossier-builder). Launched via `beads-runner/agents/specialist.sh --kind=<hat>`.
- **Flow A intake**: phone UI at `https://claude-wrangler.pages.dev/intake`, backed by enricher hat dispatch from the daemon.
- **Lifecycle stages**: `stage:<value>` label discipline (idea/ux/design/impl/docs/tests/done) applied to all 49 kie children. See `beads-runner/agents/lifecycle.md` and `beads-runner/agents/gate-policy.md`.
- **Capacity gating**: workspace runner consults daemon's `ask-capacity` on every pickup. Spare-cycles 14.2%/day ramp implemented.

### Not done (autonomous-reachable)

Nothing. `bd ready` returns zero open issues and `bd list --status=in_progress` is empty as of 2026-05-29. All P1 bugs flagged in the prior handoff (`h7n`, and the `ir7` epic with its last child `1yt`) closed 2026-05-23 / 2026-05-24.

The only remaining work is the human-gated deferral below.

### Human-gated / deferred

- **`claude-tools-bzc`** — the live closing-gate session. DEFERRED until 2030-01-01 per the 8bm churn-stop precedent. Un-defer only when Brian is ready to drive the full session on his phone. This is the final gate for the kie epic.
- **`claude-tools-kie`** — the epic itself, deferred along with bzc.

### Active situation (where we are right now)

- **Runner-instance accumulation appears resolved.** `pgrep -fl run-beads-tasks` shows 4 live processes as of 2026-05-29, down from 20+ on 2026-05-23. The subshell-leak fixes (`8mb`, `yva`) plus the watchdog-guard fix (`h7n`) likely account for it. The loose-thread item below should be considered cured pending the next extended autonomous run.
- **Queue is empty.** `bd ready` returns no open issues; `bd list --status=in_progress` is empty. All `ir7` reliability work landed.
- **`claude-tools-240` (the terminology-doc fixture) is CLOSED + deferred** along with `bzc`. The closing-gate test has not yet been driven live end-to-end; it's been intentionally parked under the same un-defer protocol as the epic.

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

Practical symptom: `claude-tools-240` kept getting re-blocked even after manual reset, until the agent actually succeeded in calling ask-brian (which doesn't add the human label, so the auto-flip doesn't fire). 240 is now CLOSED + deferred alongside `bzc`, so the live symptom is gone, but the underlying predicate-tightness is unchanged: a future bead that legitimately gets a stuck attempt and is then resolved will still trip the same auto-flip on re-pickup. Worth tightening the Fix B predicate to "recent" (e.g., last N seconds) rather than "any presence anywhere in notes" before the next bead hits the same shape. The `daw`/`5os`/`2y1` stuck-restart op + bead-drive fixes are adjacent but do not address the predicate-window itself.

### Multiple runner accumulation

Across the 2026-05-17–2026-05-23 sessions, runner instances accumulated repeatedly. Causes identified:
- Daemon respawning when desired-state stays `running` and pidfile points at a dead pid (correct behavior).
- Watchdog subshells outliving their parent claude (`t7i`, closed; `8mb` + `yva` closed the SIGTERM-path and ~50%-rate leaks).
- Manual launches not tracked by the daemon's adopt logic.

`runbooks/cleanup-orphan-runners.md` documents the cleanup. **As of 2026-05-29 this appears cured** — `pgrep -fl run-beads-tasks` shows 4 live instances after a multi-day autonomous run. Leave the runbook in place as a safety net, but the daemon adopt logic likely no longer needs a hardening pass; re-check after the next extended autonomous session.

### Token-in-MCP-config security wart

The production `mcp__askbrian__ask-brian` MCP registration requires `COORDINATOR_TOKEN` to be passed via `claude mcp add -e COORDINATOR_TOKEN=...`, which lands the token in `~/.claude.json`. The token is the same one in macOS Keychain at service `claude-beads-runner.coordinator-token`. Worth migrating the MCP server to read from Keychain at startup instead of taking the env var, so the secret doesn't sit in a config file. Not blocking, but a real cleanup.

### Dossier-cleanup hygiene (shipped, still worth a sweep)

`claude-tools-23r` shipped a "Dismiss as stale" affordance in the Inbox (POSTs `/api/expire` to flip every open item to state=expired, gated behind a `window.confirm`). `claude-tools-vxs` had earlier cleaned up duplicate sources. Existing stale dossiers from prior testing can now be dismissed from the UI rather than wedging the lane.

### The closing-gate test itself

`claude-tools-bzc` requires Brian to experience the full dossier loop end-to-end on his phone. Per the 8bm/38y churn-stop precedent it is DEFERRED until 2030-01-01 rather than left open to be re-triaged each session. The un-defer is a deliberate, human-initiated action: `bd undefer claude-tools-bzc claude-tools-kie`, reclaim, drive the live session. If/when it passes (all 9 acceptance criteria — workspace registration, phone toggle, real dossier with real Mermaid, phone answer, mid-task daemon surgery, resume, stop/restart from phone, no ssh) the kie epic closes.

### Things deferred to the future

- **`claude-tools-r0m`** — cross-workspace agent-to-agent communication (frontend agent asks backend agent a question via MCP). Deferred until 2030; revisit post-Z if the manual-relay pain persists.
- **`claude-tools-bcm`** — Claude Agent SDK + `canUseTool` research. Deferred until post-June-15-2026 when the SDK pricing may change (per the support doc citation in the bead). If the SDK becomes subscription-covered then, evaluate migrating from the MCP-blocking pattern.
- **The terminology-doc decision** — was set up as the closing-gate fixture (`claude-tools-240`); now closed + deferred alongside bzc. The actual architectural choice (where the per-workspace glossary lives, what format, how agents reference it) hasn't been made — it surfaces again when bzc un-defers and the live session asks Brian to pick.

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
