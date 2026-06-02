# Runbook: register an MCP server at user scope so all Claude Code sessions see it

## When

You've built a new MCP server (or are using an existing one like `mcp-askbrian/`) and you want every Claude Code session — interactive and headless `claude -p` workers — to have access to its tools without per-session setup.

## Registration

User-scope MCP registrations persist across Claude Code restarts and are visible from any working directory. The registration writes to `~/.claude.json`.

```bash
claude mcp add <NAME> --scope user \
  -e <ENV_KEY>=<value> \
  -e <ENV_KEY2>=<value2> \
  -- <command> [args...]
```

**Arg order matters.** Put `<NAME>` BEFORE any `-e` flags, otherwise the `-e` parser greedily consumes the name as another env var. Format:

```
claude mcp add <NAME> [flags] -- <command> [args...]
```

## Example: production `askbrian` MCP server

```bash
TOK=$(security find-generic-password -s "claude-beads-runner.coordinator-token" -w)
claude mcp add askbrian --scope user \
  -e COORDINATOR_URL=https://coordinator-cf.bbthechange.workers.dev \
  -e COORDINATOR_TOKEN="$TOK" \
  -- node /Users/brianbutler/code/claude-tools/mcp-askbrian/server.mjs
```

## Example: `ask-workspace` MCP server (cross-WS sibling)

The cross-workspace relay (DESIGN K / `claude-tools-uxvk1`) is a sibling fork of
`askbrian`. Register it the same way — same `COORDINATOR_URL` + keychain token
(it shares the engine for the relay-append and escalation legs), pointed at
`mcp-ask-workspace/server.mjs`:

```bash
TOK=$(security find-generic-password -s "claude-beads-runner.coordinator-token" -w)
claude mcp add ask-workspace --scope user \
  -e COORDINATOR_URL=https://coordinator-cf.bbthechange.workers.dev \
  -e COORDINATOR_TOKEN="$TOK" \
  -- node /Users/brianbutler/code/claude-tools/mcp-ask-workspace/server.mjs
```

The tool name as seen by claude is `mcp__ask-workspace__ask-workspace`. The
token-in-config wart (below) applies identically.

**Routing prerequisite (not optional for this server).** Unlike `askbrian`,
`ask-workspace` routes `to_ws` → the target workspace's local dir via the daemon
workspace registry (`~/.config/claude-tools/workspaces.json`). The registry must
contain a row whose `project_ref` equals the `to_ws` the caller passes, and that
row's `dir` must exist on this machine — otherwise the tool returns a terse
route-miss error (never a fabricated answer). For the FE↔BE setup the rows are
`thirsty` (FE) and `thirsty-backend` (BE).

## Verify registration

```bash
# List registered servers
claude mcp list
# Look for: <NAME>: <command> - ✓ Connected
```

If you see `✗ Failed` or `⚠ Disconnected`, the server is registered but couldn't start. Check the server's stderr by running its command manually:

```bash
node /Users/brianbutler/code/claude-tools/mcp-askbrian/server.mjs
# It should wait on stdin (MCP protocol over stdio). Ctrl-C to exit.
```

## Verify the tool is invocable from a worker

Registration alone is not sufficient for **headless** `claude -p` workers to use the tool. The tool name must also be in the worker's `--allowedTools` allowlist. See `add-tool-to-runner-allowlist.md`.

The tool name as seen by claude is `mcp__<server-name>__<tool-name>`. For example, `askbrian` server's `ask-brian` tool is `mcp__askbrian__ask-brian`.

## Removal

```bash
claude mcp remove <NAME> --scope user
```

## Security warts to know about

The `-e COORDINATOR_TOKEN=...` form stores the token IN PLAINTEXT in `~/.claude.json`. This is a known wart. The MCP server (`mcp-askbrian/server.mjs`) reads from `process.env.COORDINATOR_TOKEN`. A cleaner pattern would be to have the server resolve the token from macOS Keychain at startup (matching the runner's BC-34 credential path), eliminating the need for the env var in the config. Not implemented yet; worth a follow-up.

## Multiple environments

If you have prod + probe versions of the same MCP server, register them with distinct names:

```bash
claude mcp add askbrian-probe --scope user -e PROBE_DIR=/tmp/mcp-probe-H -- node /tmp/mcp-probe-H/ask-brian-server.mjs
claude mcp add askbrian --scope user -e COORDINATOR_URL=... -e COORDINATOR_TOKEN=... -- node /Users/brianbutler/code/claude-tools/mcp-askbrian/server.mjs
```

Both will be in every session's tool list as `mcp__askbrian-probe__ask-brian` and `mcp__askbrian__ask-brian`. Workers should call the production one.

## When the registration "doesn't work"

Always check three things:

1. `claude mcp list` shows the server as `✓ Connected`. If not, the server can't start (run it manually to see why).
2. The expected tool name appears in a fresh `claude -p` session's `init` event's `tools` array. Spawn a one-off and inspect:
   ```bash
   echo "hi" | claude -p --output-format stream-json --verbose 2>&1 | head -5 | jq '.[0].tools | map(select(startswith("mcp__")))'
   ```
3. The tool name is in the worker's `--allowedTools` allowlist. Without this, headless workers will get permission-denied when they try to call it. See `add-tool-to-runner-allowlist.md`.

## What "the tool isn't permissioned" looks like

In a worker's stream-json log:

```
{"type":"tool_use","name":"mcp__askbrian__ask-brian", ...}
{"type":"tool_result", "is_error":true, "content":"Claude requested permissions to use mcp__askbrian__ask-brian, but you haven't granted it yet."}
```

This is NOT a registration problem — it's an allowlist problem. The tool is visible (you can see the tool_use happened) but the harness rejected the call because the tool isn't in `--allowedTools`. See `add-tool-to-runner-allowlist.md`.
