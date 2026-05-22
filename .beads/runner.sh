# .beads/runner.sh — per-project config for run-beads-tasks.sh (BC-37 seam)
#
# Sourced after the script defaults, before PERMISSION_FLAGS is used, so this
# REPLACES the default allowlist with the comprehensive one below.
#
# Purpose: the beads-runner overhaul tasks (epic claude-tools-glk: T0–T6) need
# a toolchain the script default does not cover — `claude` (the conformance
# harness spawns `claude -p`), the Cloudflare/Node toolchain (Coordinator,
# Decision DO, web app), shell/process tooling (runner rewrite + watchdog),
# macOS Keychain (Local Agent BC-34), and subagent/web tools the task
# instructions require. Without these, agents hit permission denials in the
# unattended `claude -p` sessions and silently stall.
#
# Scoped allowlist, not --yolo: each entry is justified. If a specific command
# still gets denied, add it here (or run the runner with --yolo for a one-off
# fully-autonomous pass — run-beads-tasks.sh --yolo).

PERMISSION_FLAGS=(
  --permission-mode acceptEdits
  --allowedTools
    # ── script defaults (preserved) ─────────────────────────────────────────
    "Bash(git:*)" "Bash(bd:*)"
    "Bash(mkdir:*)" "Bash(cp:*)" "Bash(mv:*)" "Bash(rm:*)"
    "Bash(chmod:*)" "Bash(touch:*)" "Bash(ln:*)" "Bash(mktemp:*)"
    "Bash(ls:*)" "Bash(cat:*)" "Bash(head:*)" "Bash(tail:*)"
    "Bash(find:*)" "Bash(tree:*)" "Bash(wc:*)" "Bash(diff:*)" "Bash(cmp:*)"
    "Bash(jq:*)" "Bash(sort:*)" "Bash(uniq:*)" "Bash(echo:*)" "Bash(printf:*)"
    "Bash(which:*)" "Bash(command:*)" "Bash(date:*)"
    "Bash(basename:*)" "Bash(dirname:*)" "Bash(realpath:*)"
    "Bash(curl:*)" "Bash(python:*)" "Bash(python3:*)"
    # ── conformance harness + runner rewrite + Local Agent (T1/T2/T3) ────────
    "Bash(claude:*)"        # T1a/T1c spawn `claude -p` — the gate cannot run without this
    "Bash(bash:*)" "Bash(sh:*)"
    "Bash(grep:*)" "Bash(rg:*)" "Bash(sed:*)" "Bash(awk:*)"
    "Bash(ps:*)" "Bash(lsof:*)" "Bash(kill:*)" "Bash(pkill:*)" "Bash(wait:*)"
    "Bash(sleep:*)" "Bash(timeout:*)" "Bash(tee:*)" "Bash(xargs:*)" "Bash(env:*)"
    "Bash(security:*)"      # macOS Keychain — T3 BC-34 path + the BC-34 conformance assertion
    "Bash(shellcheck:*)"    # wrapup sanity for the T2 shell rewrite
    # ── Cloudflare Coordinator / Decision DO / web app (T4/T5/T6) ────────────
    "Bash(node:*)" "Bash(npm:*)" "Bash(npx:*)" "Bash(pnpm:*)" "Bash(yarn:*)"
    "Bash(wrangler:*)" "Bash(miniflare:*)"  # Cloudflare Workers/DO/D1/Pages CLI + local emulator (direct invocation, not only via npx wrangler dev)
    "Bash(tsc:*)" "Bash(tsx:*)" "Bash(vitest:*)" "Bash(vite:*)" "Bash(esbuild:*)" "Bash(make:*)"  # tsx: run a .ts file directly (bare bin, not just `npx tsx`)
    # ── non-Bash tools the task instructions explicitly require ──────────────
    "Task"                  # T0 review subagent; T2/T4/T5 self-decomposition validation
    "WebFetch" "WebSearch"  # Cloudflare Workers/DO docs (T4/T5); O-1 probe research pattern
    # ── ask-brian MCP (claude-tools-qxz) ─────────────────────────────────────
    # The fork-routing tool MUST be in the allowlist for non-interactive
    # `claude -p` workers to actually invoke it. `claude mcp add --scope user`
    # only makes the tool VISIBLE; without this line every fork falls through
    # to the bd-notes/human-label fallback and no dossier is ever produced.
    'mcp__askbrian__ask-brian'
)

# --add-dir: epic 8bm I1/I2 wire & verify a runner in the SECOND workspace
# (/Users/brianbutler/code/thirsty). Without this the headless agent's file
# tools are trusted only within claude-tools and cannot configure thirsty —
# the I2 task would silently stall. Scoped to the one real workspace 2.
EXTRA_CLAUDE_FLAGS=(--no-chrome --add-dir /Users/brianbutler/code/thirsty)

# ── Watchdog grace (BC-22) ───────────────────────────────────────────────────
# Overhaul tasks legitimately run quiet for a while (harness spawning claude -p,
# npm ci, wrangler, blocking review subagents). Default 600s (10m) killed a
# healthy harness agent. 1200s (20m) gives long ops room WITHOUT meaningfully
# weakening true-hang detection (per-task MAX_RETRIES + the consecutive-failure
# breaker still bound a real hang; a genuine hang just wastes one 20m timeout,
# not the fleet). NOT the real fix — see the T2 note: the rewritten watchdog
# must key "stuck" on agent+child-process-tree liveness, not parent-stream
# silence alone (BC-22's own caveat). This is the v1 stopgap.
IDLE_TIMEOUT=1200

# ── Project-wide worker guidance (appended to every task prompt; BC-37) ───────
PROMPT_EXTRA='Watchdog / long operations: a watchdog stops you if your visible activity is silent past the idle timeout. Delegating to subagents (the Task tool) is ENCOURAGED for context isolation and for objective review with a clean context, and is watchdog-safe while the subagent is actively working — do NOT inline context-heavy work into your own thread just to avoid delegating (that causes context overflow, which is worse). The ONLY pattern that trips the watchdog is detaching a long shell command (run_in_background, or a long blocking Bash) and then sitting idle: if you must background a long Bash op, poll it and print a one-line progress note every few minutes so activity stays visible. Prefer foreground for short commands, a subagent for anything heavy or needing objectivity, and background-shell only when necessary with periodic visible progress.'
