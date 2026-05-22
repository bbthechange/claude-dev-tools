# Runbooks index

Operational guides for recurring tasks. Read `../HANDOFF.md` first for the big picture.

## Daily operations

| Document | When |
|---|---|
| [`runner-status-check.md`](runner-status-check.md) | Is the runner alive? What's it working on? |
| [`cleanup-orphan-runners.md`](cleanup-orphan-runners.md) | Multiple `run-beads-tasks` processes accumulating |
| [`reset-stuck-bead.md`](reset-stuck-bead.md) | A bead is stuck in blocked-for-human and you want to retry |
| [`daemon-control.md`](daemon-control.md) | Install, start, stop, reload the per-machine daemon |

## Configuration changes

| Document | When |
|---|---|
| [`add-workspace.md`](add-workspace.md) | Onboarding a new project as a workspace |
| [`register-mcp-tool.md`](register-mcp-tool.md) | Adding a new MCP server (user-scope) |
| [`add-tool-to-runner-allowlist.md`](add-tool-to-runner-allowlist.md) | Permitting a new tool for the workspace runner |
| [`set-desired-state.md`](set-desired-state.md) | Telling the daemon to spawn/stop/pause a workspace |

## Deploys

| Document | When |
|---|---|
| [`deploy-pages.md`](deploy-pages.md) | Edited Board or Inbox source files |
| [`deploy-cloudflare-worker.md`](deploy-cloudflare-worker.md) | Edited the hosted engine source |

## Debugging / dogfooding

| Document | When |
|---|---|
| [`inspect-engine-records.md`](inspect-engine-records.md) | What's in the engine's D1? Dossiers, runner_state, etc. |
| [`manual-dossier-tools.md`](manual-dossier-tools.md) | Test the dossier-builder prompt in isolation; manually upload a dossier |

## Discipline

Most of the recurring bugs in this project are a single pattern: **the code is committed and tests pass, but the production wiring (Pages deploy, Worker deploy, MCP registration, allowlist entry) is missing.** A task that closes on a passing local test, but the user-facing behavior never changed, is the failure mode the rescue epic exists to prevent.

When closing a production-touching task:

1. Identify what live artifact the change is supposed to produce (a deployed file at a URL, a runner accepting a new tool, an engine accepting a new op).
2. Make a probe call against the live artifact. Curl the deployed URL. Trigger the new tool from a worker. Send the new op to the engine.
3. Assert the probe's output matches the expected new behavior.
4. Only then `bd close`.

If a task description is missing acceptance criteria that specify the live-verify step, add it before starting.
