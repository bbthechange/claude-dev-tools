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
    "Bash(wrangler:*)"      # Cloudflare Workers/DO/D1/Pages CLI
    "Bash(tsc:*)" "Bash(vitest:*)" "Bash(vite:*)" "Bash(esbuild:*)" "Bash(make:*)"
    # ── non-Bash tools the task instructions explicitly require ──────────────
    "Task"                  # T0 review subagent; T2/T4/T5 self-decomposition validation
    "WebFetch" "WebSearch"  # Cloudflare Workers/DO docs (T4/T5); O-1 probe research pattern
)

EXTRA_CLAUDE_FLAGS=(--no-chrome)
