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

# ════════════════════════════════════════════════════════════════════════════
# Hosted coordinator wiring — claude-tools-3w8 / I2 per-workspace registration
# (epic claude-tools-8bm). Mirrors the thirsty workspace block.
# ════════════════════════════════════════════════════════════════════════════
# This is WORKSPACE 1. Without these two vars, beads-runner/lib/co-http-
# transport.sh STAYS DORMANT (its top-level `if [[ -n "$COORDINATOR_URL" ]]`
# gate evaluates false), la_outbox_drain is never declared, and the runner's
# §1.1 coordinator-outbox.jsonl only EVER grows locally — heartbeats accumulate
# but never reach reconcile.js, so RunnerState.last_heartbeat_at stays null in
# the hosted engine and the deployed Board shows "stale (last seen unknown
# ago)" forever (3w8: 110 silent heartbeats found in the outbox, none drained).
# Adding these two vars wires the §4.2 actual-state heartbeat + §1.1 outbox
# drain so this runner REGISTERS + stays live (last_heartbeat_at within §0.5
# STALE_AFTER) in the HOSTED engine under project_ref "claude-tools".

# project_ref pinned explicitly so a launch from any cwd (e.g. a worktree, the
# detached launcher) still registers under the right stable §1.1-safe key —
# co__safe_key requires [A-Za-z0-9._-], no "..". Without this, basename of
# pwd is used; a worktree at /tmp/foo would register as "foo" instead.
PROJECT_REF="claude-tools"

# ── claude-tools-tkf — FE-rooted workspace, refuse 'backend' tasks ──────────
# claude-tools' worker sandbox is rooted at /Users/brianbutler/code/claude-
# tools (with --add-dir extending into thirsty/ above). Any bead labelled
# `backend` — by convention, work whose code lives in ~/code/thirsty-backend/
# — is unreachable from this sandbox; six prior auto-claims of thirsty-hs88.2
# from this workspace all bailed with zero code written. Append (don't
# replace) the workspace gate so the universal human-* labels from the
# run-beads-tasks.sh default still apply.
RUNNER_NO_CLAIM_LABELS="${RUNNER_NO_CLAIM_LABELS:+$RUNNER_NO_CLAIM_LABELS,}backend"

# Deployed Worker "coordinator-cf" (cf-production-deploy-topology); co-http-
# transport.sh speaks the native POST-slash {op,args:[…]} dialect against the
# raw Worker (the full CF.11-proven op surface — heartbeat / reconcile /
# work-snapshot included). The §9.2 bearer is resolved server-side from the
# macOS Keychain (service "claude-beads-runner.coordinator-token") by
# la_coordinator_token — NEVER hard-coded here, NEVER in any agent context.
#
# EXPORTED (claude-tools-cxj): without `export` these stay shell-local to the
# script that sources runner.sh and are invisible to subprocesses — including
# the §7.3 backstop dossier path (sr_route_stuck → dg_from_worker_ask →
# do_dossier_put) which runs in subshells / through co_request. With the gate
# at co-http-transport.sh:79 evaluating false in those subshells, every
# fallback dossier was written to the in-process bash store at CO_STORE
# (.beads/runner-logs/.co-store/) and never reached coordinator-cf. The token
# pull from Keychain mirrors la_coordinator_token's lookup; an empty result is
# tolerated by co_http__token (env > Keychain > stub fallback).
export COORDINATOR_URL="https://coordinator-cf.bbthechange.workers.dev"
export COORDINATOR_TOKEN="$(security find-generic-password -s 'claude-beads-runner.coordinator-token' -w 2>/dev/null)"

# ── Cloudflare deploy auth (claude-tools-goym) ───────────────────────────────
# The headless runner spawns `claude -p` workers (run-beads-tasks.sh:1767) that
# inherit THIS process's env. Web/Worker beads only close on a real deploy
# (wrangler deploy / pages deploy + verify-pages-deploy.sh mismatches=0), but
# wrangler's OAuth login is INTERACTIVE (browser) and its refresh token expires
# — so a headless worker can NEVER OAuth, and every web/Worker bead stalled at
# its deploy gate (goym: the dead-refresh-400, no-token state). wrangler reads
# CLOUDFLARE_API_TOKEN from the env and PREFERS it over OAuth, skipping the
# browser entirely. We pull a SCOPED token (Workers Scripts:Edit + Cloudflare
# Pages:Edit + Account Settings:Read) from the Keychain — same posture as
# COORDINATOR_TOKEN above: NEVER hard-coded, NEVER in any agent context, NEVER
# in the launchd plist (that would put it plaintext on disk + in logs). The
# `Bash(npx:*)` / `Bash(wrangler:*)` allowlist entries above are the companion
# half — permission to RUN wrangler; this is the credential it runs WITH.
# An empty result is tolerated (a non-web bead doesn't need it, and the empty
# assignment is safe under `set -e`, exactly as COORDINATOR_TOKEN proves); a
# web bead whose token is missing fails loudly at the deploy gate, as it should.
# See docs/runbooks/deploy-cloudflare-worker.md / deploy-pages.md.
export CLOUDFLARE_API_TOKEN="$(security find-generic-password -s 'cloudflare-api-token' -w 2>/dev/null)"

# ── Watchdog grace (BC-22) ───────────────────────────────────────────────────
# Overhaul tasks legitimately run quiet for a while (harness spawning claude -p,
# npm ci, wrangler, blocking review subagents). Default 600s (10m) killed a
# healthy harness agent. 1200s (20m) was the v1 stopgap — but a worker that
# correctly invokes `mcp__askbrian__ask-brian` enters a tool_use state where
# its own stdout is silent for as long as Brian takes to answer on his phone,
# and the watchdog killed those workers at 20 min sharp (observed on the
# claude-tools-240 closing-gate test 2026-05-22 08:02/08:24, where each
# kill spawned a fresh analysis-claude-tools-240 fallback dossier and the
# runner entered a respawn loop). 21600s (6h) matches mcp-askbrian/server.mjs
# POLL_MAX_MS so a worker waiting on a human decision survives the natural
# poll horizon. Still NOT the real fix — the rewritten watchdog must key
# "stuck" on agent+child-process-tree liveness (the MCP server child is
# emitting poll_still_waiting every ~37s; that IS liveness) — but bumping
# this saves the closing-gate test from churning while T2's deeper rewrite
# lands. Trade-off: a genuinely hung worker (model crash, infinite loop)
# now wastes one 6h slot before retry. Acceptable for now.
IDLE_TIMEOUT=21600

# ── Project-wide worker guidance (appended to every task prompt; BC-37) ───────
PROMPT_EXTRA='Watchdog / long operations: a watchdog stops you if your visible activity is silent past the idle timeout. Delegating to subagents (the Task tool) is ENCOURAGED for context isolation and for objective review with a clean context, and is watchdog-safe while the subagent is actively working — do NOT inline context-heavy work into your own thread just to avoid delegating (that causes context overflow, which is worse). The ONLY pattern that trips the watchdog is detaching a long shell command (run_in_background, or a long blocking Bash) and then sitting idle: if you must background a long Bash op, poll it and print a one-line progress note every few minutes so activity stays visible. Prefer foreground for short commands, a subagent for anything heavy or needing objectivity, and background-shell only when necessary with periodic visible progress.'
