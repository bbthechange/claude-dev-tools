# Context: The ask-brian MCP server (worker → human-decision bridge)

> One-liner: the bridge a worker calls when it hits a fork it must NOT decide
> alone. It spawns a fresh dossier-builder, writes a polished decision dossier
> to the hosted engine, notifies Brian's phone, and **BLOCKS** — returning his
> tapped answer to the SAME worker session as the tool_result, so the worker's
> ~600k-token context is never thrown away.

**Read this doc when** your task touches: anything under `mcp-askbrian/` — the
`ask-brian` MCP tool, the builder-dispatch / engine-write / poll-for-answer
flow, the engine-bridge sub-commands, the MCP registration, or the
token-in-config security wart.

**Owns / scope (the files this doc covers):**
- `mcp-askbrian/server.mjs` — the stdio MCP server (the ONE tool `ask-brian`;
  the five-step flow; builder subprocess; poll loop; the tool_result envelope).
- `mcp-askbrian/helpers/engine-bridge.sh` — the Node→engine bash bridge
  (`id_for` / `write_polished` / `write_fallback` / `poll_once`).
- `mcp-askbrian/package.json` — the stdio server package (one dep: the MCP SDK).
- `mcp-askbrian/test-engine-bridge.sh`, `test-mcp-protocol.sh` — the offline smokes.

**Sibling fork — `mcp-ask-workspace/`** (K1, claude-tools-uxvk1; DESIGN K). This
server's whole shape is forked sideways into `mcp-ask-workspace/server.mjs` +
`helpers/engine-bridge.sh` for **cross-workspace** asks (`ask-workspace`): an
agent in workspace A asks a sibling workspace B. It KEEPS the `claude -p`-child /
blocking-poll / `isError`-unset machinery verbatim; it CHANGES what gets spawned
(a **read-only responder** via `specialist.sh --kind=xws-responder` at `cwd=B`,
not the builder), the answer's two outcomes (**answer** → return + relay-log vs
**escalate** → the inherited dossier-publish-and-block path), and adds the
`relay_log_append` / `relay_log_tail` bridge sub-commands (K2's CF-only ops). If
you change the builder spawn, the poll loop, or the `isError` contract HERE,
check whether the fork needs the same change. Design of record:
`beads-runner/design/cross-ws.md`. **Live status (claude-tools-qaid):** the
server is REGISTERED at user scope (`claude mcp add ask-workspace …`, mirrors
askbrian; see `docs/runbooks/register-mcp-tool.md`) and the §8 live round-trip is
verified — a real `claude -p` worker in `thirsty` (FE) asks `thirsty-backend`
(BE), a real read-only responder answers, the answer returns as `tool_result`
(`isError` absent), and the answer-path `relay-log-append` lands LIVE on the
engine (K2 is deployed, so it is no longer the tolerated-warn no-op the bead was
filed against). To let runner-spawned workers (not just hand-driven ones) call
it, the tool must also be in each workspace's `.beads/runner.sh` `--allowedTools`
(per `docs/runbooks/add-tool-to-runner-allowlist.md`) — not yet wired.

**Not here (go to the right doc):**
- The dossier-builder PROMPT this server dispatches (`agents/dossier-builder.system.md`)
  and the specialist-hat dispatch policy → `docs/context/worker-agents.md`. This
  server only *spawns* the builder with `claude -p`; the persona lives there.
  (The `xws-responder` hat the sibling fork spawns also lives there.)
- The engine the dossier is written to + the §4.1 dossier record / §4.3
  notification shapes → `docs/context/engine-cloudflare.md`.
- The Inbox that renders the dossier on the phone and where Brian taps the
  answer this server polls for → `docs/context/web-inbox.md`.
- The push DELIVERY pipeline triggered by the notify step → `docs/context/notifications.md`.
- The shared libs the bridge sources (`stuck-routing.sh`, `dossier-gen.sh`,
  `notification.sh`, `co-http-transport.sh`) → `docs/context/lib-shared.md`.

---

## Mental model

A worker is a single `claude -p` process pinned to one bd task, carrying a huge,
expensive context window. When it hits an irreversible product/architecture/scope
fork it must not resolve, the old design ended the worker and re-asked Brian out
of band — throwing away that context. This server keeps the worker **alive and
blocked** through one MCP tool call.

**The five steps** (`server.mjs` `CallToolRequestSchema` handler; the order is
the `architecture-refinement-brian-2026-05-20` bd memory — build the dossier
BEFORE publishing):

1. **Derive a deterministic dossier id.** `bridge id_for <bead_ref>` →
   `stuck-<bead_ref>` (matches `sr_dossier_id_for`). This is *why* `bead_ref` is
   a required tool input: an MCP-side and a runner-side trigger on the same fork
   collapse to ONE dossier (one-fork-one-dossier, §7.4).
2. **Authoring dispatch.** Spawn a FRESH `claude -p` running the dossier-builder
   (`runBuilder`), feeding it the worker's structured ask + `context_dump` on
   stdin. Time-budgeted (`BUILDER_TIMEOUT_MS`, default 300s). It Reads/Greps the
   workspace and emits ONE JSON dossier `{body, items[]}` on stdout.
3. **Write to the hosted engine FIRST.** `bridge write_polished` (builder output)
   or, on any builder failure/timeout/thin-output, `bridge write_fallback` (the
   B3 jq-deterministic path). The dossier is durable cloud-side BEFORE the poll
   loop starts, so a crash can never lose the ask.
4. **Notify the phone.** `emit_and_dispatch` inside the bridge creates the §4.3
   Notification row (channel `mcp-askbrian`) at write time.
5. **Poll, then return.** `bridge poll_once <did>` every `POLL_INTERVAL_MS`
   (1s) until EVERY item is out of `open`; format the answer(s) and return
   `{content:[{type:"text", text}]}` with `isError` UNSET. That text becomes the
   worker's tool_result; the worker resumes with Brian's decision in hand.

Registered once at **user scope** (`claude mcp add askbrian --scope user`), so
every interactive and headless `claude -p` session sees the tool. The bridge runs
against the live engine via `COORDINATOR_URL`/`COORDINATOR_TOKEN`; with no
`COORDINATOR_URL` it falls back to the in-process bash store (the standalone /
oracle / conformance path the offline tests use).

## Key files

| File | Role |
|---|---|
| `server.mjs` | The stdio MCP server. Lists the one `ask-brian` tool; runs the five-step flow; spawns the builder; runs the poll loop; assembles the tool_result. Tunables are all env-overridable (`BUILDER_TIMEOUT_MS`, `POLL_INTERVAL_MS`, `POLL_MAX_MS`, `DOSSIER_BUILDER_MODEL`, `CLAUDE_BIN`). |
| `helpers/engine-bridge.sh` | The Node→engine bash bridge. Sources the runner libs in the same order `run-beads-tasks.sh` does so the in-process `co_request` is wired before `co-http-transport.sh` overrides it. Four sub-commands: `id_for`, `write_polished`, `write_fallback`, `poll_once`. All schema/§5-gate/notification logic stays in the shared libs — the bridge is a thin adapter. |
| `package.json` | One dependency: `@modelcontextprotocol/sdk`. `"type":"module"`; `bin.mcp-askbrian` → `server.mjs`. Run `npm install` in this dir once before the protocol smoke. |
| `test-engine-bridge.sh` | Offline smoke for the four bridge sub-commands against the in-process store: id derivation, fallback write, pre/post-answer poll, polished write, the §5 gate, and the N=3 multi-item regression (claude-tools-88e). |
| `test-mcp-protocol.sh` | End-to-end JSON-RPC smoke: drives `server.mjs` over stdio, a sidecar coroutine hand-flips the item state, asserts the answer text returns AND `result.isError` is absent (the R1 §Q1 contract). |

## Contracts & invariants (don't break these)

- **`isError` stays UNSET on success.** Per R1 §Q1, the tool_result must have
  `is_error == null`, not `false`. The runner's `scan_stream_for_tool_errors`
  treats null as success; a literal `false` would still read as an error. Never
  set `isError: false` on the happy path (`server.mjs` returns
  `{content:[...]}` with no `isError` key).
- **Engine write happens BEFORE the poll loop.** The dossier must be durable
  cloud-side before this server blocks. A worker killed mid-poll loses only the
  answer-return; the daemon-resume backstop re-dispatches it with the answer.
- **`bead_ref` is required and load-bearing.** It is the dossier id seed; without
  it the one-fork-one-dossier dedup (§7.4) breaks and Brian gets duplicate cards.
- **Multi-item dossiers block until ALL items resolve.** `poll_once` returns
  nothing until every item is out of `open`; returning the first answer alone
  leaks the rest (claude-tools-88e: N=3 answered, worker saw item 1 only,
  re-asked 2–3, Brian's Inbox got a duplicate 6h later). One tool call covers the
  whole dossier — there is no per-fork `bfh` record here as on the runner path.
- **Tolerance at render, conformance at write.** The bridge writes through the
  shared `dg_generate` / `dg_from_worker_ask` §5 gate; do not loosen validation
  in the bridge to make a thin builder output pass. A thin/vacuous builder
  result is forced down the honest fallback path instead (see Gotchas).
- **The builder is dispatched with a REPLACED system prompt.** `--system-prompt
  @<builder.md>` (not `--append-system-prompt`) so Claude Code's default
  helpful-assistant persona can't win and emit markdown commentary instead of a
  JSON dossier. Tool surface is restored explicitly via `--allowedTools`.

## Common changes (recipes)

**Change/add a bridge sub-command:** edit `helpers/engine-bridge.sh` (add a
`cmd_*` fn + a `main()` case), call it from `server.mjs` via `runBridge(subcmd,
args)`. Keep all engine/schema/notification logic in the sourced libs — the
bridge is an adapter, not a second source of truth. Then run the offline gate:

```bash
bash mcp-askbrian/test-engine-bridge.sh     # bridge sub-commands (in-process store)
(cd mcp-askbrian && npm install)            # once, before the protocol smoke
bash mcp-askbrian/test-mcp-protocol.sh       # full JSON-RPC + isError-absent contract
bash beads-runner/run-tests.sh               # the offline regression gate (run before any bd close)
```

**Change the tool's input schema** (`server.mjs` `ListToolsRequestSchema`):
remember the input is deliberately LENIENT — a worker under pressure can't be
asked to author the §5 CB schema by hand. `buildWorkerAsk` /
`normalizeOptions` / `normalizeRecommendation` shape it so both the builder path
and the jq fallback see a `worker_ask` that passes `dg_from_worker_ask`. Keep
the normalizers in sync if you add a field.

**(Re)register the server** — user scope, token from Keychain:

```bash
TOK=$(security find-generic-password -s "claude-beads-runner.coordinator-token" -w)
claude mcp add askbrian --scope user \
  -e COORDINATOR_URL=https://coordinator-cf.bbthechange.workers.dev \
  -e COORDINATOR_TOKEN="$TOK" \
  -- node /Users/brianbutler/code/claude-tools/mcp-askbrian/server.mjs
claude mcp list   # expect: askbrian: … - ✓ Connected
```
Arg order matters: `<NAME>` BEFORE any `-e` flags (the parser is greedy). Full
procedure + live-verify in `docs/runbooks/register-mcp-tool.md`.

## Gotchas / scars

- **Token lands in plaintext in `~/.claude.json`.** `claude mcp add -e
  COORDINATOR_TOKEN=…` stores the bearer in the config file in cleartext. The
  same secret already lives in macOS Keychain (`claude-beads-runner.coordinator-token`).
  Known wart — the clean fix is to have `server.mjs` resolve the token from
  Keychain at startup (matching the runner's BC-34 credential path) and drop the
  `-e` flag entirely. Not done yet; worth a follow-up bead.
- **Builder model matters.** Default `claude-opus-4-7` (`DOSSIER_BUILDER_MODEL`).
  Faster default models (Sonnet/Haiku) followed the long builder system prompt
  unreliably and emitted markdown prose (`"The three…"`) instead of JSON
  (claude-tools-cvj). Don't switch the default to a cheaper model without
  re-proving the JSON-dossier path holds.
- **Builder timeout is 300s on purpose.** A real builder run (Opus 1M + full
  prompt + Read/Grep) takes ~182s; the old 90s SIGTERM'd it mid-thought every
  time, masking the agent-authored path and always falling back (claude-tools-cxj).
- **Thin/vacuous output is treated as a builder FAILURE, not a success.** A
  worker-stuck dossier must carry ≥3 sections, ≥1 item, ≥500 chars of
  `full_detail`; anything thinner is the model punting and is routed down the
  honest jq fallback so the badge matches the shape (claude-tools-cvj). A bad
  shape badged "agent" is worse than an honest fallback.
- **Builder dossiers are badged `authored_by="agent"`.** `assembleGenerationInput`
  stamps `source.authored_by="agent"` so the Inbox doesn't mislabel an
  MCP-polished dossier as "fallback author" (the bridge env has no
  `DG_AUTHOR_CMD`, so `dg__author`'s jq path is just a shape-coercer here, not a
  degraded fallback — claude-tools-xdo).
- **The bridge must source libs in the runner's order.** `stuck-routing.sh`
  first (it pulls in dossier-gen → dossier → coordinator), THEN
  `co-http-transport.sh`, so the HTTP transport overrides `co_request` last. Out
  of order, the in-process store wins even with `COORDINATOR_URL` set.
- **SIGTERM drains, it does not abort in-flight calls.** A signal makes new
  `tools/call`s decline immediately, but in-flight polls keep going until they
  observe an answer or hit `SHUTDOWN_DRAIN_MS` (25s) — the engine write is
  durable, so only the answer-return is at risk and daemon-resume catches that.

## Go deeper

- `docs/runbooks/register-mcp-tool.md` — the full user-scope registration +
  verify-from-a-worker procedure, and the token-in-config wart write-up.
- `beads-runner/research/mcp-interactive-tool.md` — the R1 implementation
  contract this server binds (the five steps, the `is_error == null` rule, the
  "must not rot" poll posture).
- `beads-runner/agents/dossier-builder.system.md` — the builder persona's
  declared stdin schema and four-tier body output (see `worker-agents.md`).
- `beads-runner/lib/{stuck-routing,dossier-gen,notification,co-http-transport}.sh`
  — the actual engine/schema/§5-gate logic the bridge delegates to (`lib-shared.md`).
- bd memories: `architecture-refinement-brian-2026-05-20` (build-before-publish),
  and the claude-tools-{88e,cvj,cxj,xdo} scars referenced above.

## Keeping this doc current

When you finish a task in this area, append anything a future agent will need and
didn't find here: a new bridge sub-command, a changed step order, a new tunable
or its default, a fresh scar, or (when it lands) the Keychain-at-startup token
fix. Keep it concise — this doc earns its keep only if agents read all of it.
Delete lines that have gone stale; don't let it grow into a re-spec of the R1
contract or INTERFACE.md. Last substantive update: 2026-05-31.
