# Runbook: register a new workspace with the daemon

## When

You're onboarding a new project as a workspace the daemon should supervise. Once registered, the daemon will:

- Poll its desired-state on the Cloudflare engine every 60 seconds
- Spawn a workspace runner when desired-state=running and no live pidfile
- Kill the runner when desired-state=stopped
- Continuously poll for answered dossiers belonging to this workspace
- Dispatch resume agents in the workspace when the runner is busy mid-task

## Prerequisites

The workspace must already have:

1. `.beads/` initialized (`bd init` run inside the workspace).
2. A unique `project_ref` (the bd prefix used in bead IDs — e.g., `claude-tools-` → `claude-tools`). This is also the key used to identify this workspace in the hosted engine.
3. The coordinator token stored in the macOS Keychain at the right service name (default: `claude-beads-runner.coordinator-token`).
4. The `askbrian` MCP server registered at user scope (one-time per machine) — see `register-mcp-tool.md`. The server is shared across all workspaces; whether a given workspace's agents can actually CALL it is gated separately, per-workspace, in step 2 below.
5. `.beads/runner.sh` configured with the workspace's per-project config — see the next section.

## Step 1 — configure `.beads/runner.sh`

The runner script (`beads-runner/run-beads-tasks.sh`) sources `<workspace>/.beads/runner.sh` at startup and uses the per-workspace overrides found there. Without a correctly-shaped `runner.sh`, the runner will use bare defaults that almost certainly don't fit your project, OR it'll silently degrade in ways that are hard to debug (heartbeats never reach the hosted engine; agents hit permission denials in headless mode; etc.).

Reference templates: `beads-runner/examples/ios.sh`, `beads-runner/examples/android.sh`. Gold reference (most complete, fully wired): `claude-tools/.beads/runner.sh`. Thirsty / thirsty-backend are minimal real-world examples.

### Required sections

**A. `PERMISSION_FLAGS` — the headless allowlist**

The default in `run-beads-tasks.sh` is intentionally bare (just `git`, `bd`, basic file/text utilities, `curl`). Every workspace adds the language toolchain and any MCP tool names its agents need to call. Without a tool in this list, a headless `claude -p` worker hits "Claude requested permissions to use X, but you haven't granted it yet" — there's no human to answer the prompt, so it silently fails.

Required entries you should consider per workspace:

- Bash subcommands the project uses (`pnpm`, `node`, `xcodebuild`, `python`, `wrangler`, etc.).
- Native tools the prompt encourages (`Task`, `WebFetch`, `WebSearch`).
- **`'mcp__askbrian__ask-brian'`** — required for the per-workspace agent to actually invoke the ask-brian MCP tool. The MCP server being registered at user scope only makes the tool VISIBLE to claude sessions; this allowlist entry is what makes it CALLABLE in headless mode. If you omit this line, the agent's fork-routing falls through to the bd-notes/human-label fallback (the bead gets parked with status=blocked + label=human and the worker exits — no dossier on your phone). This is the exact bug `claude-tools-qxz` was filed for; mirror it in every new workspace.

See `add-tool-to-runner-allowlist.md` for the full allowlist semantics + tool-name conventions.

**B. `PROJECT_REF` — pinned, exported**

```bash
PROJECT_REF="thirsty"
```

If unset, the runner defaults to `basename "$(pwd)"`, which breaks for worktrees and detached launches. Always pin it explicitly to the bd prefix.

**C. `COORDINATOR_URL` + `COORDINATOR_TOKEN` — both EXPORTED**

```bash
export COORDINATOR_URL="https://coordinator-cf.bbthechange.workers.dev"
export COORDINATOR_TOKEN="$(security find-generic-password -s 'claude-beads-runner.coordinator-token' -w 2>/dev/null)"
```

The `export` is load-bearing (see `claude-tools-cxj`). Without it, `beads-runner/lib/co-http-transport.sh` stays dormant in subshells — every fallback dossier gets written to the local in-process bash store at `.beads/runner-logs/.co-store/` and never reaches the hosted engine, heartbeats accumulate but never drain, the Board shows the workspace as stale, and the §7.3 stuck-backstop dossier path silently no-ops.

**D. `RUNNER_NO_CLAIM_LABELS` — append, don't replace**

The script's default (`human-live-session,human-triage,human-action`) is the universal label gate for "humans only — runner must not auto-claim". To add workspace-specific labels (e.g., a frontend workspace refusing `backend` beads), APPEND don't REPLACE:

```bash
RUNNER_NO_CLAIM_LABELS="${RUNNER_NO_CLAIM_LABELS:+$RUNNER_NO_CLAIM_LABELS,}backend"
```

A bare assignment overwrites the universal gate and lets a runner auto-claim `human-action` beads — that's the bug `claude-tools-tkf` fixed; don't reintroduce it.

**E. `IDLE_TIMEOUT` — bump for ask-brian-enabled workspaces**

A worker that calls `mcp__askbrian__ask-brian` enters a tool_use state where its stdout goes silent for as long as Brian takes to answer on his phone. The default watchdog (600s) kills these workers mid-wait. Set:

```bash
IDLE_TIMEOUT=21600   # 6h, matches mcp-askbrian/server.mjs POLL_MAX_MS
```

Skip this if the workspace's `runner.sh` doesn't allowlist `mcp__askbrian__ask-brian` (no MCP calls → no long silent waits → default 600s is fine).

**F. `PROMPT_EXTRA` — project-specific guidance**

Free-form string appended to every task prompt. Use it for things every agent in this workspace should know: project-specific watchdog guidance, MCP-tool usage notes, test-running quirks, etc. See `claude-tools/.beads/runner.sh` for an example.

**G. `EXTRA_CLAUDE_FLAGS` — additional `claude -p` invocation flags**

Defaults to `(--no-chrome)`. Override if your workspace needs `--add-dir <other-path>` (cross-workspace work), or extra flags. Note: overriding REPLACES the default; re-include `--no-chrome` unless you want browser automation.

### Minimal template

```bash
# .beads/runner.sh — per-project config for run-beads-tasks.sh
# See docs/runbooks/add-workspace.md in the claude-tools repo for full schema.

PERMISSION_FLAGS=(
  --permission-mode acceptEdits
  --allowedTools
    # ── core (always include these) ──
    "Bash(git:*)" "Bash(bd:*)"
    "Bash(mkdir:*)" "Bash(cp:*)" "Bash(mv:*)" "Bash(rm:*)"
    "Bash(chmod:*)" "Bash(touch:*)" "Bash(ln:*)" "Bash(mktemp:*)"
    "Bash(ls:*)" "Bash(cat:*)" "Bash(head:*)" "Bash(tail:*)"
    "Bash(find:*)" "Bash(wc:*)" "Bash(diff:*)"
    "Bash(jq:*)" "Bash(sort:*)" "Bash(uniq:*)" "Bash(echo:*)" "Bash(printf:*)"
    "Bash(which:*)" "Bash(command:*)" "Bash(date:*)"
    "Bash(basename:*)" "Bash(dirname:*)" "Bash(realpath:*)"
    "Bash(curl:*)" "Bash(grep:*)" "Bash(rg:*)" "Bash(sed:*)" "Bash(awk:*)"
    "Bash(bash:*)" "Bash(sh:*)" "Bash(ps:*)" "Bash(sleep:*)" "Bash(timeout:*)"
    # ── project toolchain (customize for your project) ──
    # "Bash(node:*)" "Bash(npm:*)" "Bash(pnpm:*)"
    # "Bash(python:*)" "Bash(python3:*)"
    # "Bash(xcodebuild:*)" "Bash(swift:*)"
    # ── non-Bash tools the prompt encourages ──
    "Task" "WebFetch" "WebSearch"
    # ── ask-brian MCP (required for the dossier-to-phone flow) ──
    # Omit this line for old-style behavior (agent falls back to bd-notes
    # + human label + bead parks blocked when stuck).
    'mcp__askbrian__ask-brian'
)

EXTRA_CLAUDE_FLAGS=(--no-chrome)

PROJECT_REF="<your-bd-prefix>"

export COORDINATOR_URL="https://coordinator-cf.bbthechange.workers.dev"
export COORDINATOR_TOKEN="$(security find-generic-password -s 'claude-beads-runner.coordinator-token' -w 2>/dev/null)"

# Append (don't replace) the universal human-* gate.
# RUNNER_NO_CLAIM_LABELS="${RUNNER_NO_CLAIM_LABELS:+$RUNNER_NO_CLAIM_LABELS,}<your-extra-label>"

# Required if you allowlisted mcp__askbrian__ask-brian above; otherwise omit.
IDLE_TIMEOUT=21600

PROMPT_EXTRA='Project-specific guidance: ...'
```

### Smoke-test the runner.sh before registering

From inside the workspace:

```bash
# Source it in a subshell and verify the load-bearing exports are set.
( source .beads/runner.sh && \
  echo "PROJECT_REF=$PROJECT_REF" && \
  echo "COORDINATOR_URL=$COORDINATOR_URL" && \
  echo "token_len=${#COORDINATOR_TOKEN}" && \
  printf 'allowlist contains askbrian: '; \
  printf '%s\n' "${PERMISSION_FLAGS[@]}" | grep -q askbrian && echo yes || echo no )
```

Expected: non-empty `PROJECT_REF` and `COORDINATOR_URL`, `token_len` ≥ 32, `askbrian: yes` (if you intend the dossier flow) or `no` (if you don't).

## Step 2 — add the workspace to the daemon registry

The daemon's registry lives at `~/.config/claude-tools/workspaces.json`. Schema:

```json
{
  "workspaces": [
    {
      "project_ref": "<bd-prefix, e.g., 'thirsty'>",
      "dir": "<absolute path to workspace root>",
      "coordinator_url": "https://coordinator-cf.bbthechange.workers.dev",
      "coordinator_token_keychain": "claude-beads-runner.coordinator-token"
    }
  ]
}
```

The `coordinator_url` and `coordinator_token_keychain` fields are optional; if absent, the daemon falls back to env vars or the workspace's `.beads/runner.sh` config.

To add a workspace:

```bash
mkdir -p ~/.config/claude-tools
$EDITOR ~/.config/claude-tools/workspaces.json
```

After editing, signal the daemon to reload (the daemon only reads the registry at startup and on SIGHUP):

```bash
DAEMON_PID=$(cat ~/.cache/claude-tools/daemon.pid 2>/dev/null)
kill -HUP "$DAEMON_PID"

# Verify the reload took effect
tail /Users/brianbutler/.cache/claude-tools/daemon-logs/stdout.log
# Look for: "SIGHUP received; reloading workspace registry" and
#           "workspace registry reload ok (N workspaces)"
```

If you don't have a workspaces.json yet, the daemon log warns about it at startup with a clear message:

```
WARN: no workspace registry yet at /Users/brianbutler/.config/claude-tools/workspaces.json (continuing — M1/M4 have nothing to poll until a registry exists)
```

That's fine; the daemon will just heartbeat. Once you create the file and SIGHUP, it'll start polling.

## Step 3 — start the workspace runner

Adding the workspace to the registry alone does NOT start a runner. The daemon needs `desired=running` for that workspace on the engine. Set it via the Board UI (tap "Run" on the workspace) or via curl:

```bash
TOK=$(security find-generic-password -s "claude-beads-runner.coordinator-token" -w)
curl -sS -X POST https://coordinator-cf.bbthechange.workers.dev/ \
  -H "Authorization: Bearer $TOK" \
  -H "content-type: application/json" \
  -d '{"op":"set-desired","args":["<project_ref>","running","brian"]}'
```

Within 60 seconds the daemon's M3 desired-state poll will fire, see no live runner pidfile, and spawn one via `launch-detached.sh`.

## Verifying end-to-end

```bash
# Workspaces the daemon knows about
jq '.workspaces[] | {project_ref, dir}' ~/.config/claude-tools/workspaces.json

# Daemon reloaded successfully
grep "workspace registry reload ok" ~/.cache/claude-tools/daemon-logs/stdout.log | tail -1

# Runner spawned (after setting desired=running and waiting ~60s)
pgrep -fl run-beads-tasks
ls -lt <workspace>/.beads/runner-logs/detached-*.log | head -3

# The spawned claude -p has the askbrian MCP in its allowlist
ps -ax -o command 2>&1 | grep -F "claude -p" | grep -F "<workspace>" \
  | head -1 | tr ' ' '\n' | grep -E "askbrian|allowedTools"

# Hosted engine sees this workspace's heartbeats (the Board will reflect it)
curl -sS -X POST https://coordinator-cf.bbthechange.workers.dev/ \
  -H "Authorization: Bearer $TOK" \
  -H "content-type: application/json" \
  -d '{"op":"work-snapshot","args":[]}' | jq '.runners[] | select(.project_ref=="<project_ref>")'
```

If the Board shows the workspace but `last_heartbeat_at` stays null, the most common cause is missing `export` on `COORDINATOR_URL`/`COORDINATOR_TOKEN` in `runner.sh` (see step 1.C).

## Removing a workspace

```bash
# Set desired=stopped first so the daemon stops respawning
curl -sS -X POST https://coordinator-cf.bbthechange.workers.dev/ \
  -H "Authorization: Bearer $TOK" \
  -H "content-type: application/json" \
  -d '{"op":"set-desired","args":["<project_ref>","stopped","brian"]}'

# Wait ~60s for the daemon to SIGTERM the runner, then verify it's dead
sleep 70
pgrep -fl run-beads-tasks  # should not include this workspace's runner

# Edit the registry to remove the workspace entry
$EDITOR ~/.config/claude-tools/workspaces.json

# SIGHUP the daemon
kill -HUP $(cat ~/.cache/claude-tools/daemon.pid)
```

## Common pitfalls

- **Missing `mcp__askbrian__ask-brian` in the allowlist** → agents see the tool exists (user-scope MCP makes it visible everywhere) and try to call it, hit permission denial, fall through to the bd-notes/human-label path. The runner's relaxed-primary autoflip (`claude-tools-2ir`) catches the slip, flips the bead to `status=blocked`, and produces a §7.3 backstop dossier on your phone — agent-authored when the `dg-author-bridge` succeeds (`claude-tools-5me`), labeled-degraded `FALLBACK AUTHOR` otherwise. Still worth allowlisting `mcp__askbrian__ask-brian`: the PRIMARY path (worker explicitly calls ask-brian via MCP) produces a richer dossier than the backstop because the worker's live in-context understanding feeds straight into `context_dump`, vs. the backstop reconstructing it from notes after the worker has already exited.
- **Missing `export` on `COORDINATOR_URL`/`COORDINATOR_TOKEN`** → outbox-only mode. The runner writes everything locally to `.beads/runner-logs/.co-store/`, nothing reaches the hosted engine, the Board shows the workspace as stale forever.
- **Unset or wrong `PROJECT_REF`** → workspace registers under `basename(pwd)` instead of the bd prefix. From a worktree at `/tmp/foo` this would be `foo`, breaking matching between bd beads and hosted RunnerState rows.
- **`RUNNER_NO_CLAIM_LABELS=` (bare assignment instead of append)** → loses the universal `human-live-session,human-triage,human-action` gate, and the runner can auto-claim beads explicitly labelled for humans only. This was `claude-tools-tkf`.
- **`IDLE_TIMEOUT` left at default (600s) with ask-brian enabled** → workers waiting on Brian's phone answer get killed mid-wait at the 10-minute mark; a new worker spawns, hits the same fork, files a duplicate dossier. Set 21600s when MCP is allowlisted.

## Related

- `runbooks/register-mcp-tool.md` — one-time machine-wide MCP server registration.
- `runbooks/add-tool-to-runner-allowlist.md` — semantics of the allowlist itself.
- `runbooks/daemon-control.md` — install/start/stop the daemon itself.
- `runbooks/set-desired-state.md` — the curl pattern for set-desired ops.
- `runbooks/runner-status-check.md` — verifying the runner is alive and healthy.
