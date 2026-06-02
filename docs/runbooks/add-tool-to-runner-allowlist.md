# Runbook: add a tool to the workspace runner's allowedTools

## When

A headless `claude -p` worker spawned by the runner tries to use a tool and gets:

> Claude requested permissions to use <tool>, but you haven't granted it yet.

This means the tool name isn't in the runner's `--allowedTools` allowlist, so the harness prompts for permission — which has no human to answer in headless mode.

## Where the allowlist lives

Each workspace has `.beads/runner.sh` which is sourced by `beads-runner/run-beads-tasks.sh` at startup. The relevant section is `PERMISSION_FLAGS`:

```bash
PERMISSION_FLAGS=(
  --permission-mode acceptEdits
  --allowedTools
    "Bash(git:*)" "Bash(bd:*)"
    "Bash(mkdir:*)" ...
    # ── non-Bash tools the task instructions explicitly require ──
    "Task"
    "WebFetch" "WebSearch"
    # ── MCP tools ──
    'mcp__askbrian__ask-brian'
)
```

## Adding an entry

Edit `<workspace>/.beads/runner.sh`, add the entry inside the `--allowedTools` array. Categories used:

- **Bash subcommands**: `"Bash(<command>:*)"` — wildcarded to allow any args. Example: `"Bash(curl:*)"`.
- **Native non-Bash tools**: `Task`, `WebFetch`, `WebSearch`, `Read`, `Glob`, `Grep`, `Edit`, etc.
- **MCP tools**: `'mcp__<server-name>__<tool-name>'` — note the single quotes (the name is taken literally, no shell expansion).

After editing, the runner has to be **restarted** to pick up the new `runner.sh` — it sources the file once at startup. See `cleanup-orphan-runners.md` for the kill+relaunch sequence.

## Verify

After restart, find the active claude -p subprocess and look at its command line:

```bash
ps -ax -o command 2>&1 | grep -F "claude -p" | grep -v grep | head -1 | tr ' ' '\n' | grep -E "mcp__|--allowedTools|<your tool name>"
```

If your tool name appears in the output, the runner is passing it to claude. The agent's next attempt to use the tool should succeed (no permission prompt).

## Failure modes

- **Tool quoting**: shell may interpret special characters. For MCP tool names with double underscores, use single quotes: `'mcp__server__tool'`.
- **Wrong tool name**: MCP tools are named `mcp__<server>__<tool>` (with double underscores, not single). The server name is from `claude mcp list`; the tool name is what the MCP server exposes.
- **Wrong place**: the entry must be inside the `--allowedTools` array, before the closing `)` of `PERMISSION_FLAGS`. If you put it elsewhere (like after the closing paren), it'll be silently ignored.
- **Stale runner**: even after editing, a runner that's been alive since before your edit is using the OLD allowlist. Kill+relaunch is mandatory.

## What you should NOT have to do

- The MCP server itself doesn't need to be in the allowlist — only its tools. (`claude mcp add` registration handles server discovery; the allowlist is per-tool.)
- You don't need to restart the daemon — only the workspace runner. The daemon doesn't run workers; it spawns them, and the spawned process reads the current `runner.sh` at its startup.

## Example: adding a new MCP tool

Say you've registered `claude mcp add my-server --scope user -- node /path/to/server.mjs` and that server exposes a `lookup` tool. The full tool name is `mcp__my-server__lookup`. Edit `<workspace>/.beads/runner.sh`:

```bash
# (inside the PERMISSION_FLAGS allowedTools array, before the closing paren)
'mcp__my-server__lookup'
```

Then restart the runner. The next worker that picks up a task will have access.

## Currently-allowlisted MCP tools (and where)

| Tool | Allowlisted in | Bead |
|---|---|---|
| `mcp__askbrian__ask-brian` | every workspace runner (`claude-tools`, `thirsty`, `thirsty-backend`, …) | claude-tools-qxz |
| `mcp__ask-workspace__ask-workspace` | `thirsty` (FE) + `thirsty-backend` (BE) runner.sh — the verified cross-WS pair | claude-tools-c3es |

`ask-workspace` is the worker→worker cross-WS bridge (DESIGN K). Its responder is
bounded by `RESPONDER_TIMEOUT_MS` (default 300s), comfortably under the
`IDLE_TIMEOUT=21600` already set in those runner.sh files for the blocking
`ask-brian` tool, so adding it needs **no watchdog change**.

### Cross-repo nuance (claude-tools-c3es scar)

`thirsty/.beads/runner.sh` and `thirsty-backend/.beads/runner.sh` live in the
**thirsty / thirsty-backend** git repos, not claude-tools. The runner sources the
file from its **local** working tree at startup, so the change is functionally
live the moment you edit + restart — independent of whether the sibling repo is
pushed. Note `--permission-mode` interaction (`run-beads-tasks.sh` ~L1617): an
**opus** worker is launched with `--permission-mode auto` (LLM-classified
approval) and never consults `--allowedTools`; only **non-opus (sonnet)** workers
read the allowlist. So the allowlist entry is the load-bearing fix for the sonnet
path — verify on that path (`--model sonnet`), where `permission_denials:[]` in
the final `result` event is the acceptance signal.
