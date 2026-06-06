#!/bin/bash
# run-beads-tasks.sh — Processes beads tasks sequentially in fresh Claude Code sessions
# Each task gets a clean 200k context window (no autocompact drift)
#
# Usage:
#   run-beads-tasks.sh          # default: scoped permissions
#   run-beads-tasks.sh --yolo   # skip ALL permission prompts
#
# Requires: claude, bd (beads), jq
#
# Per-project config: place .beads/runner.sh in the project root.
# See examples/ for iOS and Android configs.
#
# Graceful stop: touch .stop-beads to stop after the current task finishes

set -euo pipefail

# ── Defaults (overridable in .beads/runner.sh) ───────────────────────────────

PERMISSION_FLAGS=(
  --permission-mode acceptEdits
  --allowedTools
    "Bash(git:*)" "Bash(bd:*)"
    # File operations (git-recoverable)
    "Bash(mkdir:*)" "Bash(cp:*)" "Bash(mv:*)"
    "Bash(chmod:*)" "Bash(touch:*)" "Bash(ln:*)" "Bash(mktemp:*)"
    # Read/inspect utilities
    "Bash(ls:*)" "Bash(cat:*)" "Bash(head:*)" "Bash(tail:*)"
    "Bash(find:*)" "Bash(tree:*)" "Bash(wc:*)" "Bash(diff:*)"
    # Text processing
    "Bash(jq:*)" "Bash(sort:*)" "Bash(uniq:*)" "Bash(echo:*)" "Bash(printf:*)"
    # Environment checks
    "Bash(which:*)" "Bash(command:*)" "Bash(date:*)"
    "Bash(basename:*)" "Bash(dirname:*)" "Bash(realpath:*)"
    # Network/scripting (needed by skills like /reddit)
    "Bash(curl:*)" "Bash(python:*)" "Bash(python3:*)"
)
EXTRA_CLAUDE_FLAGS=(--no-chrome)
# §7.6 guardrail (AD3.5; research Q3-bonus/Q5): workers run with the three
# interactive tools REMOVED from the advertised set — closes the EnterPlanMode
# silent-no-op temptation and the AskUserQuestion/ExitPlanMode soft-fail at the
# source. Kept SEPARATE from EXTRA_CLAUDE_FLAGS (which a project .beads/
# runner.sh overrides wholesale, e.g. to add --add-dir) so the frozen-contract
# guardrail survives project config. The instructed §7.2 PRIMARY path (prompt
# below) is STILL required — a bare prohibition is empirically insufficient
# (research Q5); the guardrail removes the tool, the prompt supplies the
# positive deliberate alternative. Keep --output-format stream-json (set on the
# claude invocation): `text` hides permission_denials[] the §7.2 BACKSTOP needs.
GUARDRAIL_FLAGS=(--disallowedTools AskUserQuestion EnterPlanMode ExitPlanMode)
PROMPT_EXTRA=""
# claude-tools-43m — per-workspace opt-in for the ask-brian / dossier escalation
# flow. Default OFF = old-script behavior: worker prompt never mentions
# mcp__askbrian__ask-brian, the §7.3 backstop never fires, beads are never
# auto-flipped to blocked-for-human, the I4 RESUME splice is a no-op. A
# workspace opts in by setting `ASK_BRIAN_ENABLED=1` in its `.beads/runner.sh`
# AND allowlisting `mcp__askbrian__ask-brian` in PERMISSION_FLAGS. Default OFF
# closes the doc-propagation gap that bit thirsty / thirsty-backend (dossiers
# appearing from the runner-side backstop without those workspaces ever wiring
# the MCP). claude-tools/.beads/runner.sh sets this to 1.
ASK_BRIAN_ENABLED=${ASK_BRIAN_ENABLED:-0}
MAX_RETRIES=${MAX_RETRIES:-2}
MAX_CONSECUTIVE_FAILURES=${MAX_CONSECUTIVE_FAILURES:-3}
DEFAULT_MODEL=${DEFAULT_MODEL:-opus[1m]}  # [1m] = 1M context variant; auto-tracks latest Opus
USAGE_THRESHOLD=${USAGE_THRESHOLD:-70}       # pause new tasks above this % (0 = disabled)
USAGE_SLEEP_SECONDS=${USAGE_SLEEP_SECONDS:-1800} # sleep duration when over threshold (30 min)
USAGE_CACHE_SECONDS=${USAGE_CACHE_SECONDS:-300}  # cache usage API response (avoid hammering per-loop)
CAPACITY_DENY_BACKOFF=${CAPACITY_DENY_BACKOFF:-60} # C1: per-pickup daemon ask-capacity denied ⇒ release lease + sleep N before retry
# claude-tools-noj / claude-tools-tkf — hard label gate. Tasks carrying ANY
# of these labels are refused by validate_task regardless of priority, defer
# state, or readiness.
#   - `human-live-session` — canonical "Brian is driving this on his phone
#     from the couch — do NOT auto-claim it" marker for engineered fixtures
#     (closing-gate beads, live end-to-end runs).
#   - `human-triage`      — older epic-level marker (ir7 children) kept for
#     back-compat.
#   - `human-action`      — universal "the next move belongs to a human, not
#     any runner". tkf documented the runner auto-claiming a P0 human-action
#     blocker filed specifically to stop a loop — the label must refuse in
#     EVERY workspace, so it lives in the global default rather than per-
#     workspace overrides.
# This is a HARD gate, not text in the description: tkf proved description
# text + priority + status flips are all ignored under load; only a labelled
# refusal sticks. Comma-separated env override is supported so a project can
# extend the gate (e.g. an FE-rooted workspace appending 'backend' so it
# never auto-claims a backend-impl bead) without editing the runner.
RUNNER_NO_CLAIM_LABELS=${RUNNER_NO_CLAIM_LABELS:-human-live-session,human-triage,human-action}
# claude-tools-uxg8 (GAP G8) — cross-workspace scope check. UX-DESIGN-V2 §8.5 /
# design/cross-ws.md §2.4: a task that references a *cross-repo id* (a bead id
# belonging to a SIBLING workspace) and isn't a tracking-only task is FLAGGED,
# not silently claimed by the wrong workspace's runner (the "why is there a
# backend task in the frontend tracking" frustration — a silent-misclaim hazard
# amplified by parallel FE/BE runners). RUNNER_SIBLING_PREFIXES is the
# comma-separated list of sibling bd id prefixes this workspace knows about
# (e.g. an FE workspace sets 'thirsty-be'); EMPTY by default, so a single-repo
# runner does nothing. This rides the same skip-not-fail suppression the
# no-claim-label gate uses rather than inventing a new mechanism (cross-ws.md
# §2.4); the canonical RUNNER_* env-var-→skip-with-reason shape is the one
# agents/claim-eligibility.md §"Why no new filter" prescribes for exactly this.
# List PEER-workspace prefixes only — do NOT list a prefix that is a
# parent-segment of your own local prefix (e.g. 'thirsty' when you are
# 'thirsty-be'), or your own local ids would match and self-flag.
RUNNER_SIBLING_PREFIXES=${RUNNER_SIBLING_PREFIXES:-}
# Labels that EXEMPT a bead from the cross-repo flag — a coordination / epic /
# tracking bead is *meant* to reference sibling-workspace ids (the "isn't a
# tracking-only task" carve-out in §8.5). Sticky + human-controlled like the
# no-claim labels; comma-separated, overridable per project.
RUNNER_TRACKING_ONLY_LABELS=${RUNNER_TRACKING_ONLY_LABELS:-tracking-only}
export WORKER_STUCK_EXIT=${WORKER_STUCK_EXIT:-7} # §7.2/§8.1 worker deliberate-stuck sentinel exit (≠ BC-21 0–4; INTERFACE.md v1 constants). Exported: a stuck-aware worker wrapper reads it; the §7.2 detection below keys on it.
IDLE_TIMEOUT=${IDLE_TIMEOUT:-600}                # seconds of stream silence before watchdog kills (env-overridable)
# claude-tools-idg — while a Task subagent is in-flight (task_notification
# in_progress without a terminal task_updated yet) the parent stream goes
# byte-silent: the subagent is an IN-API construct, not an OS child the
# parser can see. Stretch (don't pause) the threshold so legitimate 30-min
# subagents survive but a genuine deadlock (D5 hung bg-Bash that registered
# as in-flight) still eventually gets killed. Default 6× ⇒ 1h on a stock
# 600s IDLE_TIMEOUT.
IDLE_TIMEOUT_INFLIGHT_MULT=${IDLE_TIMEOUT_INFLIGHT_MULT:-6}  # multiplier while ≥1 Task subagent is in-flight
# claude-tools-td0y: post-terminal SIGKILL grace. Once the SDK emits its
# terminal record (`terminal_reason` or `type:"result"` in the stream-json),
# claude is contract-done. If the process is still alive after this many
# seconds it is wedged on an orphan child (the krxv incident: Node won't exit
# while a `run_in_background:true` Bash poller is still alive). Independent
# of IDLE_TIMEOUT — that's about stream silence inside an active task; this
# is about a known-completed task that won't release. 60s is comfortably
# longer than any legitimate Node teardown but ~360× faster than the 6h
# IDLE_TIMEOUT_INFLIGHT_MULT ceiling. Env-overridable per workspace.
POST_TERMINAL_GRACE=${POST_TERMINAL_GRACE:-60}   # seconds after SDK terminal record before SIGKILL backstop
LOG_RETENTION_DAYS=${LOG_RETENTION_DAYS:-14}     # rotation: delete runner-logs older than this
LOG_DIR=".beads/runner-logs"                     # post-mortem artifacts (stream-json, ps/lsof snapshots, incidents.log)

# Hook functions — override in .beads/runner.sh if needed
runner_setup()   { :; }  # called once at script start
runner_cleanup() { :; }  # called on exit/interrupt

# claude-tools-yva: belt-and-suspenders descendant reap. The per-task reap at
# the bottom of the task loop is the primary path, but failure-path early
# exits, signal races, and reparented grandchildren can still leave subshells
# alive. Wired to trap EXIT below so it ALWAYS runs before the runner exits,
# regardless of the user-overridable runner_cleanup hook.
#
# claude-tools-8mb: PG-kill TAIL/WATCHDOG first. The in-task reap at the
# bottom of the task loop covers normal task-end. SIGINT/SIGTERM (via
# cleanup()), the circuit-breaker exit 2, and any unguarded set -uo pipefail
# trip jump straight here without invoking it. `pkill -P $$` finds only
# DIRECT children — the TAIL/WATCHDOG subshell leaders — and misses their
# tail/while-read/sleep grandchildren, which then reparent to PID 1 with
# tail -f spinning on a deleted streamfile fd forever (the 'old
# hangoutsBackend Terminated: 15' leak — ~211 tails accumulated this way
# before this fix). PG-kill via `kill -- -$TAIL_PID` mirrors the in-task
# reap (TAIL_PID == PGID because of the per-task `set -m`; bash 3.2.57
# arm64 verified) and reaches every descendant in the group.
_final_subshell_reap() {
  if [[ -n "${WATCHDOG_PID:-}" ]]; then
    kill -TERM -- "-$WATCHDOG_PID" 2>/dev/null || kill -TERM "$WATCHDOG_PID" 2>/dev/null || true
  fi
  if [[ -n "${TAIL_PID:-}" ]]; then
    kill -TERM -- "-$TAIL_PID" 2>/dev/null || kill -TERM "$TAIL_PID" 2>/dev/null || true
  fi
  if [[ -n "${HB_PID:-}" ]]; then
    kill -TERM -- "-$HB_PID" 2>/dev/null || kill -TERM "$HB_PID" 2>/dev/null || true
  fi
  pkill -P $$ 2>/dev/null || true
  sleep 0.3 2>/dev/null || sleep 1
  if [[ -n "${WATCHDOG_PID:-}" ]]; then
    kill -KILL -- "-$WATCHDOG_PID" 2>/dev/null || true
  fi
  if [[ -n "${TAIL_PID:-}" ]]; then
    kill -KILL -- "-$TAIL_PID" 2>/dev/null || true
  fi
  if [[ -n "${HB_PID:-}" ]]; then
    kill -KILL -- "-$HB_PID" 2>/dev/null || true
  fi
  pkill -KILL -P $$ 2>/dev/null || true
}

# ── Load project config ──────────────────────────────────────────────────────

CONFIG_FILE=".beads/runner.sh"
if [[ -f "$CONFIG_FILE" ]]; then
  echo "Loading config: $CONFIG_FILE"
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

# ── Local Agent (T3, claude-tools-3al) ───────────────────────────────────────
# The per-computer measurement & supervision authority owns the BC-34
# credential/usage path (§6.2/§6.3) and writes the §8.2 terminal-reason record
# before this process exits. Sourced from the runner's own dir; OPTIONAL — the
# runner still works standalone if the lib is absent (each call is guarded).
LA_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib/local-agent.sh"
if [[ -f "$LA_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$LA_LIB"
fi

# ── STUCK_NEEDS_HUMAN DO routing (T5.5, claude-tools-j7f) ─────────────────────
# §7.3 backstop-drives-the-bead + §7.4 dossier-level task_ref dedup + S-2
# control→work reconcile. OPTIONAL & guarded exactly like the §8.2 la_* calls:
# absent lib ⇒ runner unchanged. It NEVER touches classify_failure (§7.1) or
# the §7.5 breaker/retry counters (T2/T1a own those); it asserts only the
# cross-tier OUTCOME (a fired backstop ⇒ bead blocked-for-human, ONE Dossier).
SR_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib/stuck-routing.sh"
if [[ -f "$SR_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$SR_LIB"
fi

# ── §4.3 Notification emit-at-creation (I3, claude-tools-3in; epic 8bm) ───────
# The disconnection I3 closes: the stuck path above persists the Dossier
# (sr_route_stuck → dg_from_worker_ask → dg_generate → do_dossier_put) but
# NEVER created the SINGLE §4.3 Notification — notification.sh's no_emit was
# oracle-tested yet wired NOWHERE into the runner, so a real stuck reached the
# hosted engine as a dossier with no notification. C3/§4.3 already mandate the
# Notification row EXIST at dossier creation (before any send) — this sources
# the existing lib so no_emit is callable; the actual emit is wired into the
# §7.3 stuck block (guarded-optional, idempotent one-per-Dossier, observable-
# not-silent — the same discipline as the la_*/sr_* calls). NON-§11: wiring an
# already-contracted lib, not a contract change. STRICT NO-OP when absent.
NO_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib/notification.sh"
if [[ -f "$NO_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$NO_LIB"
fi

# ── Hosted transport (I1, claude-tools-txj; epic claude-tools-8bm) ────────────
# Sourced AFTER the SR/LA libs so the in-process bash co_request (pulled in by
# the stuck-routing → dossier-gen → dossier → coordinator.sh guard chain) is
# already defined; co-http-transport.sh then OVERRIDES it with authed HTTPS to
# the deployed coordinator IFF a per-workspace COORDINATOR_URL is set. STRICT
# NO-OP when COORDINATOR_URL is unset (the standalone / oracle / conformance
# runs are byte-unaffected). This is the seam that makes a stuck/dossier flow
# produce a dossier in the HOSTED engine instead of the local bash store —
# the libs' co_request call sites do NOT change (the whole point of the
# frozen §0.2-nonnormative transport boundary).
CT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib/co-http-transport.sh"
if [[ -f "$CT_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$CT_LIB"
fi

# ── §9 row-4 audit-coverage marker refresh (claude-tools-mhcp.3) ──────────────
# Keep the per-workspace audit-coverage marker fresh immediately BEFORE each
# workspace_inventory publish. The READER is la_publish_workspace_inventory
# (sourced via LA_LIB above); the WRITER is the defer-cascade audit
# (claude-tools-mhcp.2) — a full `audit` run overwrite-or-removes
# .beads/runner-logs/audit-coverage.json so the §9 Queue-Health chip reflects
# THIS publish's queue (read/total over the open future-defer epics), never a
# stale ratio and never a phantom 0/0 (total==0 removes the marker ⇒ engine null
# ⇒ no chip). Co-locating the refresh with the publish — same process, same CWD
# (the workspace root) — is what guarantees writer and reader can never drift on
# the CWD-relative marker path (the silent-no-chip failure mode t5ud/mhcp.2
# guarded). Fully isolated & best-effort, exactly like the la_*/sr_* producer
# calls: run as a SUBPROCESS so the audit's own exit code (1 = cascade found,
# 3 = bd hiccup) NEVER touches the runner's loop; absent/disabled ⇒ strict no-op
# (the reader then falls to the existing marker, or null). Opt out at runtime
# with RUNNER_AUDIT_COVERAGE_DISABLED=1.
DCA_AUDIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/defer-cascade-audit.sh"
runner_refresh_audit_coverage() {
  [[ "${RUNNER_AUDIT_COVERAGE_DISABLED:-0}" == "1" ]] && return 0
  [[ -f "$DCA_AUDIT" ]] || return 0
  bash "$DCA_AUDIT" audit >/dev/null 2>&1 || true
  return 0
}

# ── claude-tools-69u8: wire the dossier-builder bridge ONCE for the whole
#    runner process, at the dg__author chokepoint — instead of per-call-site.
# Before this, only two sites (the §7.3 stuck backstop + the Flow G analysis
# dossier) exported DG_AUTHOR_CMD in their own subshell; EVERY other dg__author
# caller in this process fell to the jq path and fired no_DG_AUTHOR_CMD. The
# opt-in sentinel the offline unit tests never set keeps them on the pure jq
# path (test-dossier-gen.sh test (1)); the chokepoint additionally requires
# claude to be reachable, so a machine without the CLI degrades cleanly. The
# 300s timeout matches the MCP path (a full-context builder reliably exceeds
# the dg__author 90s default; cvj observed 78-180s). KILL-SWITCH: export
# DG_AUTHOR_AUTOWIRE=0 (in the daemon/launchd env or .beads/runner.sh) to force
# every dossier back to the deterministic jq author with one knob.
export DG_AUTHOR_AUTOWIRE="${DG_AUTHOR_AUTOWIRE:-1}"
export DG_AUTHOR_TIMEOUT_SEC="${DG_AUTHOR_TIMEOUT_SEC:-300}"
export DG_AUTHOR_BRIDGE_WORKSPACE="${DG_AUTHOR_BRIDGE_WORKSPACE:-$PWD}"

# The controllable unit reported UP (§4.2 project_ref). Derived locally; the
# Coordinator owns desired-state, never the LA (§1.1).
PROJECT_REF="${PROJECT_REF:-$(basename "$(pwd)")}"

# ── Local-first desired-state store path (claude-tools-efu3; sibling y6j9) ────
# Export CO_STORE ONCE at startup so workspace_desired_state()'s local-first read
# (co__store_get runner_state "$PROJECT_REF") hits the per-workspace store the
# DAEMON writes — .beads/runner-logs/.co-store/records/runner_state.<pref>.json
# (daemon/{desired-state,agent-action}-poll.sh use the same $ws/.beads/runner-
# logs/.co-store default; we run with CWD=the workspace root, so the relative
# $LOG_DIR/.co-store resolves to the identical file). Without this the store
# primitives default co_store_dir() to a /tmp scratch path and the main-loop
# read would miss the daemon's record entirely — the exact CO_STORE-export hole
# y6j9 closed for runner.sh. `:=` respects an env/config override; the later
# in-function `: "${CO_STORE:=...}"` sites (post_close_audit, the §7.3 stuck
# drive) then become no-ops, so the whole process shares one store path.
: "${CO_STORE:=$LOG_DIR/.co-store}"; export CO_STORE

# ── §4.2 actual-state heartbeat → per-workspace registration (I2; epic 8bm) ──
# The runner is the §1.1 caller of job-3 (heartbeat-actual-state). hb() emits
# one §4.2 actual line keyed by PROJECT_REF and, when a hosted COORDINATOR_URL
# is configured, immediately drains the durable §1.1 outbox so the runner
# REGISTERS + stays live (last_heartbeat_at within §0.5 STALE_AFTER) in the
# HOSTED engine under its OWN project_ref — N runners, one hosted authority.
# Identical OPTIONAL/guarded posture to every la_* call: absent lib ⇒ no-op;
# no COORDINATOR_URL ⇒ la_outbox_drain is undefined and the line only ever
# appends to the local durable queue (standalone/oracle/conformance runs
# byte-unaffected — drained on a later hosted reconnect, the §2.4 contract).
# NEVER aborts the loop (mirrors la_report_terminal_reason's last-write rule).
hb() {
  command -v la_report_heartbeat >/dev/null 2>&1 || return 0
  la_report_heartbeat "$1" "${2:-}" || true
  if declare -F la_outbox_drain >/dev/null 2>&1; then
    la_outbox_drain "${COORDINATOR_TOKEN:-}" >/dev/null 2>&1 || true
  fi
}

# ── §6.1 lease ↔ beads-status binding (T4.2, claude-tools-am8) ────────────────
# AD2.1: a GLOBAL EXCLUSIVE lease is acquired BEFORE `bd update
# --status=in_progress`; its release pairs that (lease release/expiry ⇒ the
# bead maps back to --status=open — binds the strong plane onto BC-15/BC-09/
# BC-35). This CLOSES the BC-04 multi-runner race the bash startup-snapshot
# left RESIDUAL (BEHAVIORAL-CONTRACT §18): no lease ⇒ do not run it. The
# `lease` seam is provided by the Local Agent tier (mirroring how `bd` /
# `security` / `curl` are external commands), which routes arbitration to the
# hosted Coordinator (lib/coordinator.sh §6.1/§4.4) and applies the §6.2/AD2.2
# posture: Coordinator-unreachable with NO held still-valid lease ⇒
# DEGRADED-CLOSED (a non-zero `lease acquire`); a held still-valid lease ⇒
# the bounded local fallback continues it. OPTIONAL — if no `lease` command
# is present the runner still works standalone (every call guarded, exactly
# like the §8.2 la_report_terminal_reason calls; anti-drift: this file owns
# only the §6.1 WORK-PLANE binding, not the arbitration/fallback mechanism).
lease_acquire_ok() {   # <task_ref> → 0 may run · 1 must NOT claim (no new claim)
  command -v lease >/dev/null 2>&1 || return 0   # no seam ⇒ standalone, proceed
  lease acquire "$1"
}
lease_release_seam() {  # <task_ref> — release pairs the acquire (⇒ bead open)
  [[ -n "${1:-}" ]] || return 0
  command -v lease >/dev/null 2>&1 || return 0
  lease release "$1" 2>/dev/null || true
}

# ── Handle --yolo flag ───────────────────────────────────────────────────────

MODE_LABEL="scoped permissions"
YOLO=0
if [[ "${1:-}" == "--yolo" ]]; then
  PERMISSION_FLAGS=(--dangerously-skip-permissions)
  MODE_LABEL="all permissions bypassed"
  YOLO=1
fi

# ── Node v25 PATH prime (claude-tools-4tj; shared with specialist.sh /
#    runner.sh via lib/node25-prime.sh, claude-tools-18c). The body lives in
#    the shared helper because the same bug bit three siblings; the SCOPED
#    skip env var (RUNNER_SKIP_NVM_PRIME) stays caller-local so each test
#    surface forces a skip under its own name. See node25-prime.sh for the
#    bug-and-fix narrative; the one-liner: a daemon-launched PATH resolves
#    `claude` to system-node v25 which crashes the CLI at startup.
#
# Sourced UNCONDITIONALLY (no `[[ -f $LIB ]]` guard, unlike the OPTIONAL
# LA/SR/NO libs above): the node25-prime lib IS the fix — a missing lib is a
# real regression and should fail loudly, not silently degrade to a stripped-
# PATH `claude` spawn. Matches the unconditional source in specialist.sh and
# runner.sh.
NP_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib/node25-prime.sh"
# shellcheck source=lib/node25-prime.sh
source "$NP_LIB"
node25_prime_path "${RUNNER_SKIP_NVM_PRIME:-0}"

# ── Trunk pin (claude-tools-trunkpin; shared with runner.sh via
#    lib/git-pin-main.sh). The runner does per-bead auto-commit on whatever
#    branch HEAD points at and NEVER creates branches; a worker that manually
#    `git checkout -b`s and never returns the tree to main makes EVERY later
#    bead pile onto that feature branch. pin_head_to_main (called at the loop
#    top below) self-heals a wandered-off tree back to main each iteration when
#    it is clean. Sourced OPTIONALLY: the self-heal is best-effort, so a missing
#    lib degrades to a no-op stub rather than aborting the runner.
pin_head_to_main() { :; }   # default no-op; overridden by the lib if present
PIN_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib/git-pin-main.sh"
if [[ -f "$PIN_LIB" ]]; then
  # shellcheck source=lib/git-pin-main.sh
  source "$PIN_LIB"
fi

# claude-tools-2fkp: the close-discipline `--settings` JSON shape is now shared
# with runner.sh (v2) via hooks/build-settings.sh so the PreToolUse(Bash)+Stop
# wiring can never drift between the two runners. OPTIONAL & guarded like the
# LA/SR/NO libs above: an absent builder DEGRADES to "spawn the worker without
# the hook" at the call site (the prompt-instructed discipline + the
# post-terminal watchdog backstop still apply), never crashes the loop.
BS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/hooks/build-settings.sh"
if [[ -f "$BS_LIB" ]]; then
  # shellcheck source=hooks/build-settings.sh
  source "$BS_LIB"
fi

STOP_FILE=".stop-beads"
rm -f "$STOP_FILE"

echo "Running: $MODE_LABEL"
if [[ "$USAGE_THRESHOLD" -gt 0 ]]; then
  echo "Usage limit: pause at ${USAGE_THRESHOLD}%, retry every $((USAGE_SLEEP_SECONDS / 60))min"
fi
echo "Graceful stop: touch $STOP_FILE"
echo ""

# ── State ────────────────────────────────────────────────────────────────────

COMPLETED=0
FAILED=0
CURRENT_TASK_ID=""
CLAUDE_PID=""
LAST_FAILED_ID=""
FAIL_COUNT=0
CONSECUTIVE_FAILURES=0
SIGNAL_FILE=""
INCIDENTS=()        # human-readable incident lines for end-of-run summary

# ── Log directory setup ──────────────────────────────────────────────────────

# Self-gitignoring directory: any artifact written here is ignored by git
# regardless of whether the parent .beads/ is tracked. Stream-json files contain
# raw model output, file contents, and tool results — must never be committed.
mkdir -p "$LOG_DIR"
if [[ ! -f "$LOG_DIR/.gitignore" ]]; then
  printf '*\n!.gitignore\n' > "$LOG_DIR/.gitignore"
fi

# Age-based rotation: prune artifacts older than LOG_RETENTION_DAYS at startup.
# Runs once per script invocation (not per-iteration) so it can't race active runs.
if [[ -d "$LOG_DIR" ]]; then
  find "$LOG_DIR" -type f ! -name '.gitignore' ! -name 'incidents.log' \
    -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
fi

# claude-tools-td0y: clear any stale current-task pointer left by a previous
# runner that died without clearing (SIGKILL, machine crash, etc.). The file
# is regenerated per-task at claim time. A stale id here would cause the
# close-discipline hook to enforce against the wrong bead on the FIRST tool
# call of the next task before the new id is written.
rm -f "$LOG_DIR/current-task" 2>/dev/null || true

INCIDENTS_LOG="$LOG_DIR/incidents.log"

# ── Pre-flight environment snapshot ──────────────────────────────────────────
# Project agents/skills are discovered relative to cwd. If the runner is invoked
# from the wrong directory (or .claude/agents is empty), agents that worked
# interactively will silently fail inside claude. Snapshot the environment once
# per run so missing project assets are obvious from the first line of output.
PREFLIGHT_LOG="$LOG_DIR/preflight.log"
{
  echo "=== preflight $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "pwd: $(pwd)"
  echo ""
  echo "=== .claude/agents ==="
  if [[ -d .claude/agents ]]; then ls -1 .claude/agents; else echo "(no .claude/agents directory)"; fi
  echo ""
  echo "=== .claude/skills ==="
  if [[ -d .claude/skills ]]; then ls -1 .claude/skills; else echo "(no .claude/skills directory)"; fi
  echo ""
  echo "=== claude version ==="
  claude --version 2>&1 || echo "(claude --version failed)"
  echo ""
  echo "=== bd version ==="
  bd version 2>&1 || echo "(bd version failed)"
} > "$PREFLIGHT_LOG" 2>&1 || true

PREFLIGHT_AGENTS=0
PREFLIGHT_SKILLS=0
[[ -d .claude/agents ]] && PREFLIGHT_AGENTS=$(find .claude/agents -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
[[ -d .claude/skills ]] && PREFLIGHT_SKILLS=$(find .claude/skills -maxdepth 1 -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
echo "Pre-flight: ${PREFLIGHT_AGENTS} project agent(s), ${PREFLIGHT_SKILLS} project skill(s) — $PREFLIGHT_LOG"

# ── Setup hook ───────────────────────────────────────────────────────────────

runner_setup

# ── Cleanup on exit ──────────────────────────────────────────────────────────

cleanup() {
  echo ""
  if [[ -n "$CLAUDE_PID" ]] && kill -0 "$CLAUDE_PID" 2>/dev/null; then
    kill "$CLAUDE_PID" 2>/dev/null
    wait "$CLAUDE_PID" 2>/dev/null || true
  fi
  if [[ -n "$CURRENT_TASK_ID" ]]; then
    echo "Interrupted — resetting $CURRENT_TASK_ID to open"
    bd update "$CURRENT_TASK_ID" --status=open 2>/dev/null || true
    lease_release_seam "$CURRENT_TASK_ID"   # §6.1 release⇒open (BC-35 interrupt)
  fi
  runner_cleanup
  # §4.2 `stopping`: honest final actual on the interrupt path too (last
  # durable line; drained on the next hosted reconnect — §2.4 — so a killed
  # runner reads back `stale`, never a stale `live` lie).
  if command -v la_report_heartbeat >/dev/null 2>&1; then
    la_report_heartbeat stopping "${CURRENT_TASK_ID:-}" || true
  fi
  # §8.2 terminal-reason re-home: last durable control-plane write BEFORE the
  # process exits — exit 1 = SIGINT/SIGTERM (BC-21 table / BC-35).
  if command -v la_report_terminal_reason >/dev/null 2>&1; then
    la_report_terminal_reason INTERRUPTED 1 "${CURRENT_TASK_ID:-}" "${PROJECT_REF:-}" || true
  fi
  rm -f "$USAGE_CACHE_FILE" "${SIGNAL_FILE:-}" "${POST_TERMINAL_FILE:-}" "${HOOK_SETTINGS_FILE:-}"
  # claude-tools-td0y: also clear the current-task pointer on interrupt so
  # a respawning runner doesn't see a stale id on its first hook firing.
  rm -f "$LOG_DIR/current-task" 2>/dev/null || true
  echo "Results: $COMPLETED completed, $FAILED failed"
  exit 1
}
# claude-tools-j0r0: HUP joins INT/TERM for v1↔v2 parity (v2 runner.sh traps
# `INT TERM HUP`). In PRODUCTION this is a provable no-op: a detached runner
# (launch-detached.sh `nohup … &`) inherits HUP at SIG_IGN, and POSIX forbids
# re-trapping an inherited SIG_IGN — so `trap cleanup … HUP` is silently inert
# there (the same rule as claude-tools-54ei). It only bites in a FOREGROUND/
# interactive run, where a controlling-process hangup now routes through the
# SAME teardown (reset-in-flight-to-open + exit 1) instead of an ungraceful
# death that strands the task `in_progress`. Regression-locked by the v1 HUP
# row in conformance/assertions/bc-35-interrupt-cleanup.sh.
trap cleanup INT TERM HUP
# claude-tools-yva: EXIT trap runs on every exit path — clean drain, exit 2
# (circuit breaker), or after cleanup()'s `exit 1` on INT/TERM. Idempotent: a
# second pkill on already-dead PIDs is a no-op. This is the last line of
# defense against leaked TAIL/WATCHDOG subshells whose `sleep` grandchildren
# were reparented to PID 1 mid-task.
trap _final_subshell_reap EXIT

# ── Usage check ──────────────────────────────────────────────────────────────

USAGE_CACHE_FILE=""
USAGE_CACHE_TIME=0
# zfxe: the reason + numbers behind the last `over` verdict, retained across the
# USAGE_CACHE_SECONDS window so the loop-top sleep message names WHICH gate held
# (the old "Above ${USAGE_THRESHOLD}% usage" line was a lie — see la_capacity_check).
# Written whenever a fresh check runs; a cached-hit serves the same TTL window's
# values (the cache file + these globals are written together in one process).
USAGE_REASON=ok
USAGE_PCT_5H=""
USAGE_PCT_7D=""

# Check Claude usage via API. Returns 0 (ok to proceed) or 1 (over threshold).
# Caches result to avoid hitting the API every loop iteration.
check_usage() {
  if [[ "$USAGE_THRESHOLD" -eq 0 ]]; then
    return 0  # disabled
  fi

  local now
  now=$(date +%s)
  local age=$((now - USAGE_CACHE_TIME))

  # Use cached result if fresh enough
  if [[ -n "$USAGE_CACHE_FILE" ]] && [[ -f "$USAGE_CACHE_FILE" ]] && [[ $age -lt $USAGE_CACHE_SECONDS ]]; then
    local cached
    cached=$(cat "$USAGE_CACHE_FILE")
    if [[ "$cached" == "over" ]]; then return 1; else return 0; fi
  fi

  if [[ -z "$USAGE_CACHE_FILE" ]]; then
    USAGE_CACHE_FILE=$(mktemp) || return 0
  fi
  USAGE_CACHE_TIME=$now

  # The Local Agent (T3) owns the BC-34 credential/usage path & §6.3 coarse
  # verdict (Keychain read, usage API, threshold + spare-cycles ramp, fail-OPEN
  # on every credential/API/keychain error). The runner only manages the
  # USAGE_CACHE_SECONDS TTL wrapper around the verdict. `standard` cost class —
  # the loop-level "may I start a task" gate is the hard 5h/7d ceiling.
  if command -v la_capacity_check >/dev/null 2>&1; then
    if la_capacity_check standard; then
      echo "ok"   > "$USAGE_CACHE_FILE"
      USAGE_REASON=ok; USAGE_PCT_5H="${LA_CAPACITY_PCT_5H:-}"; USAGE_PCT_7D="${LA_CAPACITY_PCT_7D:-}"
      return 0
    else
      echo "over" > "$USAGE_CACHE_FILE"
      # zfxe: stash the daemon's reason + numbers so the loop-top sleep line
      # names the gate that tripped instead of the old USAGE_THRESHOLD lie.
      USAGE_REASON="${LA_CAPACITY_REASON:-cost_class_not_allowed}"
      USAGE_PCT_5H="${LA_CAPACITY_PCT_5H:-}"; USAGE_PCT_7D="${LA_CAPACITY_PCT_7D:-}"
      return 1
    fi
  fi

  # ── Fallback (Local Agent lib absent): original inline path, preserved ─────
  local creds token usage_json
  creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || {
    echo "  (Could not read credentials for usage check — skipping)" >&2
    return 0
  }
  token=$(echo "$creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  if [[ -z "$token" ]]; then
    echo "  (No OAuth token found — skipping usage check)" >&2
    return 0
  fi
  usage_json=$(curl -s -f -X GET "https://api.anthropic.com/api/oauth/usage" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    2>/dev/null) || {
    echo "  (Usage API call failed — skipping check)" >&2
    return 0
  }
  local five_hour seven_day five_int seven_int
  five_hour=$(echo "$usage_json" | jq -r '.five_hour.utilization // 0' 2>/dev/null)
  seven_day=$(echo "$usage_json" | jq -r '.seven_day.utilization // 0' 2>/dev/null)
  five_int=${five_hour%.*}
  seven_int=${seven_day%.*}
  USAGE_PCT_5H="$five_hour"; USAGE_PCT_7D="$seven_day"   # zfxe: numbers the verdict used
  if [[ ${five_int:-0} -ge $USAGE_THRESHOLD ]] || [[ ${seven_int:-0} -ge $USAGE_THRESHOLD ]]; then
    echo "over" > "$USAGE_CACHE_FILE"
    # zfxe: name WHICH window tripped (the lib path does the same via la_capacity_check).
    if [[ ${five_int:-0} -ge $USAGE_THRESHOLD ]]; then USAGE_REASON=5h_hard_ceiling; else USAGE_REASON=7d_hard_ceiling; fi
    echo "  Usage: 5h=${five_hour}% 7d=${seven_day}% (threshold: ${USAGE_THRESHOLD}%)"
    return 1
  fi
  echo "ok" > "$USAGE_CACHE_FILE"
  USAGE_REASON=ok
  echo "  Usage: 5h=${five_hour}% 7d=${seven_day}%"
  return 0
}

# ── C1 (claude-tools-g98) — per-pickup daemon ask-capacity gate ──────────────
# Consult the daemon's machine-wide capacity verdict (UX 0.A "the runner in
# each environment checks with that central one before working") at the
# §3.3-item-2 ask-capacity moment: AFTER lease_acquire_ok, BEFORE the bead
# transitions to in_progress. The loop-top check_usage gate still fires once
# per loop; this is the finer-grained per-pickup check that gates the WRITE
# to in_progress (and lets us release the lease cleanly when the daemon
# says no, instead of claiming a task we cannot run).
#
# C2 (claude-tools-oil) — spare-only mode gate. The optional second arg is
# the workspace's desired-state (running|paused|spare-cycles|stopped). When
# it is `spare-cycles`, ONLY `low_priority` cost-class pickups are allowed
# (the machine-wide ramp gate then additionally bounds them by today's
# day-of-week × SPARE_RAMP_PER_DAY ceiling — that math lives in the daemon
# at usage-poll.sh:_usage_poll_spare_ramp_pct). When the arg is absent /
# any other value, behaviour is unchanged (BC: pre-C2 callers keep working).
#
# Return contract:
#   0 — allowed (proceed to claim)
#   1 — denied (caller releases lease, sleeps CAPACITY_DENY_BACKOFF, retries)
#   2 — daemon unreachable (caller falls back to la_capacity_check per BC-34)
#
# Stdout: a short single-token reason ("ok", "5h_hard_ceiling",
# "7d_hard_ceiling", "spare_cycles_today_exhausted", "cost_class_not_allowed",
# "spare_only_standard_disallowed", "daemon_unreachable") — the runner logs
# this verbatim so the failure mode is observable (the C1/C2 acceptance).
daemon_ask_capacity() {
  local cost_class="${1:-standard}" desired_state="${2:-}" cached pct_5h pct_7d ramp allowed
  command -v la__capacity_via_daemon >/dev/null 2>&1 || {
    printf 'daemon_unreachable'
    return 2
  }
  cached=$(la__capacity_via_daemon 2>/dev/null) || {
    printf 'daemon_unreachable'
    return 2
  }
  pct_5h=$(printf '%s' "$cached" | jq -r '.pct_5h // 0' 2>/dev/null) || pct_5h=0
  pct_7d=$(printf '%s' "$cached" | jq -r '.pct_7d // 0' 2>/dev/null) || pct_7d=0
  ramp=$(printf '%s'  "$cached" | jq -r '.spare_ramp_today // 100' 2>/dev/null) || ramp=100
  allowed=$(printf '%s' "$cached" | jq -r '.allowed_cost_classes[]?' 2>/dev/null)

  # C2: spare-only workspaces forbid any non-low_priority pickup, regardless
  # of how much slack the machine-wide gate has. Checked BEFORE the cache's
  # allowed-classes lookup so the reason is the WHY (spare-only), not the
  # downstream symptom (cost_class_not_allowed when standard is globally fine).
  if [[ "$desired_state" == "spare-cycles" ]] && [[ "$cost_class" != "low_priority" ]]; then
    printf 'spare_only_standard_disallowed'
    return 1
  fi

  if printf '%s\n' "$allowed" | grep -qx "$cost_class"; then
    printf 'ok'
    return 0
  fi
  # Denied — derive the §6.3 reason from the same numbers the daemon used.
  local threshold="${USAGE_THRESHOLD:-70}" five_i seven_i ramp_i
  five_i=${pct_5h%.*};   five_i=${five_i:-0}
  seven_i=${pct_7d%.*};  seven_i=${seven_i:-0}
  ramp_i=${ramp%.*};     ramp_i=${ramp_i:-100}
  if   [[ "$five_i"  -ge "$threshold" ]]; then printf '5h_hard_ceiling'
  elif [[ "$seven_i" -ge "$threshold" ]]; then printf '7d_hard_ceiling'
  elif [[ "$cost_class" == "low_priority" ]] && [[ "$seven_i" -ge "$ramp_i" ]]; then
    printf 'spare_cycles_today_exhausted'
  else
    printf 'cost_class_not_allowed'
  fi
  return 1
}

# ── C2 (claude-tools-oil) — workspace desired-state resolver ─────────────────
# Resolves the workspace's current desired-state (running|paused|spare-cycles|
# stopped) for the spare-only gate (BC-49) and the idle/skip stop checks (BC-05).
#
# LOCAL-FIRST (claude-tools-efu3 — ports the y6j9 fix to v1; BC-50). The runner
# is AUTHORITATIVE for `desired`. Read the LOCAL .co-store RunnerState.desired
# FIRST (co__store_get runner_state "$PROJECT_REF" — an offline file read; the
# co-http-transport.sh override replaces co_request, NOT the store primitives),
# so a present paused/stopped/spare-cycles SURVIVES a Coordinator-unreachable
# window. The OLD body did a live `co_request poll` every call and fail-OPENed to
# empty (⇒ caller treats as `running`) on ANY failure once the 30s cache aged out
# — the break-through-pause bug, milder in v1 only because the cache bounded it.
# Brian's Stop/Run/spare taps now ride the agent_actions `set-desired` change-
# request; the DAEMON consumes them and WRITES this same local record (the single
# local writer — desired-state-poll.sh / agent-action-poll.sh), so after cold-
# start the local value is authoritative and an unreachable/5xx engine can no
# longer flip it. The runner NEVER persists desired here (read-only).
#
# Network is consulted ONLY on cold-start (no local record yet — a truly fresh
# workspace) as a best-effort seed, cached for DESIRED_STATE_CACHE_SECONDS so a
# record-less workspace does not hammer the coordinator per pickup. On a cold-
# start network miss the echo stays EMPTY: v1's callers treat empty as `running`,
# which is the correct bootstrap posture in the ABSENT case — a runner was
# LAUNCHED, so its implicit desired is running and there is no local pause to
# break through (mirrors runner.sh co_deliver_desired_state's explicit `running`
# bootstrap). Standalone runs without the coordinator.sh store primitives skip
# straight to the legacy network/empty path (BC-43 guarded-optional).
#
# CONSUMER (claude-tools-yuwe, closes the efu3 follow-up): v1's pickup path now
# honors all three non-running desireds — `spare-cycles` (daemon_ask_capacity),
# `stopped` (idle/skip + the daemon SIGTERM), AND `paused` (the loop-top
# runner_should_hold_paused gate below, which holds at idle and never claims,
# mirroring runner.sh's st_reconcile). The local-first READ above was the
# prerequisite; the gate is its consumer.
DESIRED_STATE_CACHE_SECONDS=${DESIRED_STATE_CACHE_SECONDS:-30}
DESIRED_STATE_CACHE_VALUE=""
DESIRED_STATE_CACHE_TIME=0
workspace_desired_state() {
  local desired=""
  # LOCAL-FIRST: a present, valid local desired wins outright (offline read; the
  # network is never consulted while a local record exists ⇒ no break-through).
  if command -v co__store_get >/dev/null 2>&1 && [[ -n "${PROJECT_REF:-}" ]]; then
    local rec
    rec="$(co__store_get runner_state "$PROJECT_REF" 2>/dev/null)" || rec=""
    if [[ -n "$rec" ]]; then
      desired="$(printf '%s' "$rec" | jq -r 'if type=="object" then (.desired // "") else "" end' 2>/dev/null)" || desired=""
      case "$desired" in
        running|paused|spare-cycles|stopped) printf '%s' "$desired"; return 0 ;;
      esac
    fi
  fi
  # COLD-START ONLY (no usable local record): best-effort NETWORK seed, cached.
  local now age
  now=$(date +%s 2>/dev/null || echo 0)
  age=$(( now - DESIRED_STATE_CACHE_TIME ))
  if [[ -n "$DESIRED_STATE_CACHE_VALUE" ]] && [[ "$age" -lt "$DESIRED_STATE_CACHE_SECONDS" ]]; then
    printf '%s' "$DESIRED_STATE_CACHE_VALUE"
    return 0
  fi
  command -v co_request >/dev/null 2>&1 || { printf ''; return 0; }
  [[ -n "${PROJECT_REF:-}" ]] || { printf ''; return 0; }
  local bearer resp
  bearer="${COORDINATOR_TOKEN:-bearer-runner-c2}"
  resp="$(co_request "$bearer" poll "$PROJECT_REF" 2>/dev/null)" || resp=""
  [[ -n "$resp" ]] || { printf ''; return 0; }
  desired="$(printf '%s' "$resp" | jq -r 'if type=="object" then (.desired // "") else "" end' 2>/dev/null)" || desired=""
  case "$desired" in
    running|paused|spare-cycles|stopped) ;;
    *) desired="" ;;
  esac
  DESIRED_STATE_CACHE_VALUE="$desired"
  DESIRED_STATE_CACHE_TIME="$now"
  printf '%s' "$desired"
}

# ── BC-50 consumer (claude-tools-yuwe) — v1 paused-pickup gate predicate ──────
# Mirrors runner.sh st_reconcile's `paused) … hold` arm. v1 READS a local
# desired=paused reliably (workspace_desired_state, claude-tools-efu3) but its
# CONSUMER path used to ignore it: the pickup only blocked `spare-cycles`
# (daemon_ask_capacity) and the idle/skip loops only exit on `stopped` — so a v1
# runner with desired=paused AND a workable bead would CLAIM and spawn (the
# daemon delegates paused-honoring to the runner and no-ops on paused+alive, so
# nothing else covered it). This predicate is the missing consumer: the main loop
# calls it BEFORE select/lease and, when it returns 0, heartbeats idle, sleeps,
# and re-loops — it NEVER claims. PAUSED-ONLY by design: `stopped` stays the
# daemon SIGTERM + the idle/skip loops; `spare-cycles` stays daemon_ask_capacity's
# cost-class gate; only `paused` was uncovered. An empty/unrecognized desired
# (the bootstrap-to-running posture, BC-50) is NOT a hold — proceed to the gates.
#   0 — desired=paused: HOLD AT IDLE (caller: hb idle; sleep; continue)
#   1 — any other desired: proceed to the lease/capacity gates
runner_should_hold_paused() {
  [[ "$(workspace_desired_state)" == "paused" ]]
}

# ── Task selection ───────────────────────────────────────────────────────────

# Snapshot in_progress tasks at startup — these are orphans from a previous crash.
# Tasks that become in_progress later are being worked on by other agents.
# Note: small race window between snapshot and first loop — another agent could claim
# an orphan in that window. The status recheck inside next_task() mitigates this.
read -ra ORPHANED_IDS <<< "$(bd list --status=in_progress --json 2>/dev/null | jq -r '.[].id // empty' 2>/dev/null || true)"
# Clear if the only element is empty string (no orphans)
[[ ${#ORPHANED_IDS[@]} -eq 1 && -z "${ORPHANED_IDS[0]}" ]] && ORPHANED_IDS=()

# ── bd ready TTL cache (claude-tools-4a2e) ───────────────────────────────────
# next_task() is the ONE bd-ready poll, reached from BOTH the active loop top
# and the idle re-poll — and v1's active loop has NO inter-iteration sleep, so a
# lease-deny / capacity-deny / validate-skip spin re-queries `bd ready` (and
# re-takes the dolt lock) every few seconds while NOTHING has changed. Memoize
# the ready ARRAY for a short window so those rapid re-polls serve from cache.
#
# FILE-based, NOT an in-memory global — load-bearing: next_task() is ALWAYS called
# as `TASK_JSON=$(next_task)` (a command-substitution SUBSHELL), so any global it
# assigns is discarded with the subshell and never reaches the parent loop. A
# disk file persists across the subshell; ready_cache_bust (run in the PARENT)
# rm's it. The file lives under LOG_DIR (BC-27 self-gitignored, a per-runner OWN
# artifact — never a daemon rendezvous path), holding `<epoch>\n<json>`.
#
# SAFE: the lease acquire precedes the in_progress write (BC-48/AD2.1), so a stale
# cached bead another claimant already took simply FAILS the lease acquire — a
# wasted, fail-closed poll, never a double-claim. And the cache is BUSTED the
# instant THIS runner commits to running a worker (ready_cache_bust at the
# CURRENT_TASK_ID set, below), so the post-task poll is always fresh: a bead this
# runner just closed can never be re-presented from a stale cache (which would
# otherwise re-claim → reopen it — bd ready itself never returns a closed bead).
#
# DELIBERATELY NOT cached: the BC-06 `bd blocked` re-check in validate_task — a
# freshness guard for a dep added AFTER the ready snapshot that MUST stay live
# (conformance/assertions/bc-06-blocked-recheck-tree.sh). Only the ready ARRAY is
# memoized here; validate_task still hits dolt FRESH per candidate (label/blocked/
# show), so most per-loop lock traffic is unchanged — this collapses the spin.
#
# Sized SMALL (a stale window briefly hides freshly-filed high-priority work, ≤
# READY_CACHE_SECONDS): the idle re-poll already paces at IDLE_POLL_INTERVAL=60s
# (always > this window ⇒ idle polls stay fresh); the target is the sub-window
# spins (LEASE_DENY_BACKOFF=3s, SKIP_BACKOFF). Mirrors check_usage()'s USAGE_CACHE_*.
READY_CACHE_SECONDS=${READY_CACHE_SECONDS:-10}
# Path is computed lazily (LOG_DIR is read at call time, so this is robust to
# module-load ordering and to a LOG_DIR reparent).
_ready_cache_file() { printf '%s' "${LOG_DIR:-.beads/runner-logs}/.ready-cache.json"; }
# Force the next next_task() to re-query. Called in the PARENT shell when this
# runner commits to a task (CURRENT_TASK_ID set) so the post-worker poll never
# serves a just-closed bead from a still-warm cache.
ready_cache_bust() { rm -f "$(_ready_cache_file)" 2>/dev/null || true; }

# Pick up orphaned tasks first (one per loop), then fall through to ready tasks
next_task() {
  if [[ ${#ORPHANED_IDS[@]} -gt 0 ]]; then
    local remaining=() pos=0
    local orphan_id task_json status
    for orphan_id in "${ORPHANED_IDS[@]}"; do
      pos=$((pos + 1))
      task_json=$(bd show "$orphan_id" --json 2>/dev/null) || { remaining+=("$orphan_id"); continue; }
      status=$(echo "$task_json" | jq -r '.[0].status // empty' 2>/dev/null || true)
      if [[ "$status" == "in_progress" ]]; then
        # Resume this orphan. Keep unprocessed orphans (after current position) for later.
        remaining+=("${ORPHANED_IDS[@]:$pos}")
        ORPHANED_IDS=("${remaining[@]+"${remaining[@]}"}")
        echo "(Resuming orphaned task from previous run)" >&2
        echo "$task_json"
        return
      elif [[ -n "$status" ]]; then
        : # Status changed (another agent closed it, etc.) — drop from list
      else
        remaining+=("$orphan_id")  # bd show returned bad data — keep for retry
      fi
    done
    ORPHANED_IDS=("${remaining[@]+"${remaining[@]}"}")
  fi
  # claude-tools-dzc — exclude epics at the query layer so an epic-topped
  # ready queue doesn't starve the runner (158-skip-loop observed
  # 2026-05-24 in detached-20260524T003251Z.log). The in-process epic
  # skip in validate_task (below) stays as defense-in-depth.
  #
  # bd v1.0.2 accepts --exclude-type=epic but does NOT actually filter
  # (verified empirically against this DB on 2026-05-24 — flag is a
  # no-op). We pass it anyway so the intent is documented and a future
  # bd fix takes over, AND we jq-filter the JSON client-side so the
  # starvation is actually fixed today regardless of bd behavior.
  #
  # claude-tools-4a2e: served through the file-backed TTL cache (above). A recent
  # snapshot is re-emitted without re-taking the dolt lock; busted at
  # commit-to-run so the post-task poll is fresh. The cache file holds
  # `<epoch>\n<json>`; a non-empty `[]` (a real drain) is itself a cacheable
  # result. A `date` failure (now=0) forces a MISS both ways: the read guards on
  # `now>0`, and a write stamps ts=0 which the next read rejects (ts>0 guard).
  local _rc_file _rc_now _rc_ts _rc_age
  _rc_file="$(_ready_cache_file)"
  _rc_now=$(date +%s 2>/dev/null || echo 0)
  if [[ "$_rc_now" -gt 0 ]] && [[ -r "$_rc_file" ]]; then
    _rc_ts=$(head -1 "$_rc_file" 2>/dev/null || echo 0)
    [[ "$_rc_ts" =~ ^[0-9]+$ ]] || _rc_ts=0
    _rc_age=$(( _rc_now - _rc_ts ))
    if [[ "$_rc_ts" -gt 0 ]] && [[ "$_rc_age" -lt "$READY_CACHE_SECONDS" ]]; then
      tail -n +2 "$_rc_file" 2>/dev/null
      return
    fi
  fi
  local _rc_json
  _rc_json=$(bd ready --exclude-type=epic --json 2>/dev/null \
    | jq '[.[] | select((.issue_type // .type // "") != "epic")]' 2>/dev/null \
    || echo "[]")
  # Best-effort write-through (a failed write just re-queries next call).
  mkdir -p "${LOG_DIR:-.beads/runner-logs}" 2>/dev/null || true
  printf '%s\n%s\n' "$_rc_now" "$_rc_json" > "$_rc_file" 2>/dev/null || true
  printf '%s\n' "$_rc_json"
}

# Check if a task is actually workable (deps resolved, not a parent container)
# Returns 0 if ok, 1 if should skip
validate_task() {
  local task_id="$1"

  # claude-tools-noj — hard label gate. If the task carries any label in
  # RUNNER_NO_CLAIM_LABELS, refuse to claim it. Skip-not-fail (same posture
  # as the epic/parent skips below): no FAILED++, no retry tracking, no
  # incident — the bead stays open-and-ready for the human to claim from
  # their phone, but the autonomous runner walks past it on every loop.
  # Defer state is unreliable for this (claude-tools-240 cycle: a 2030 defer
  # gets mis-set or lifted, and the next loop re-claims; av7/tkf both
  # documented the same class). The label cannot be lifted by the runner
  # itself, so the gate is sticky across bd reloads.
  if [[ -n "${RUNNER_NO_CLAIM_LABELS:-}" ]]; then
    local task_labels gate_label hit=""
    task_labels=$(bd label list "$task_id" --json 2>/dev/null | jq -r '.[]?' 2>/dev/null || echo "")
    # IFS=',' split without subshell so an empty env value collapses cleanly
    local IFS=','
    for gate_label in $RUNNER_NO_CLAIM_LABELS; do
      gate_label="${gate_label## }"; gate_label="${gate_label%% }"
      [[ -z "$gate_label" ]] && continue
      if printf '%s\n' "$task_labels" | grep -qxF "$gate_label" 2>/dev/null; then
        hit="$gate_label"; break
      fi
    done
    if [[ -n "$hit" ]]; then
      echo "  Skipping: label '$hit' present (RUNNER_NO_CLAIM_LABELS — human-driven fixture, not for autonomous claim)"
      return 1
    fi
  fi

  # Check for unresolved dependencies (may have been added after bd ready ran)
  local blocked_ids
  blocked_ids=$(bd blocked --json 2>/dev/null | jq -r '.[].id // empty' 2>/dev/null || true)
  if echo "$blocked_ids" | grep -qxF "$task_id" 2>/dev/null; then
    echo "  Skipping: has unresolved dependencies (added after task was queued)"
    return 1
  fi

  # Epics are containers by definition — never workable. Skip them up front so
  # an epic with no formal parent-child links (text-only "Epic: ..." references
  # in child descriptions) doesn't sail past the child-count check and get
  # picked up as a regular task.
  # Note: `bd show --json` wraps the task object in a one-element array AND
  # names the type field `issue_type` (whereas `bd list --json` uses `type`
  # at the top level — bd is inconsistent here). Be defensive and accept both
  # shapes / both field names so a future bd update can't silently regress.
  local task_type
  task_type=$(bd show "$task_id" --json 2>/dev/null \
              | jq -r '(if type == "array" then .[0] else . end) | (.issue_type // .type // "")' 2>/dev/null \
              || echo "")
  if [[ "$task_type" == "epic" ]]; then
    echo "  Skipping: epic (containers are not workable; see children for actual work)"
    return 1
  fi

  # Check if this is a parent/container task with formal children.
  # bd v1.x returns {<parent-id>: [child_objects]} — an OBJECT keyed by parent
  # id, with the children array as its sole value. Flatten that to just the
  # children array; if the format is ever an array directly, handle that too.
  # Fail closed on any jq error (treat as zero children rather than fail open).
  local children
  children=$(bd show "$task_id" --children --json 2>/dev/null || echo "[]")
  children=$(echo "$children" | jq --arg id "$task_id" '
    ((if type == "object" then [.[] | .[]?] else . end) | map(select(.id? != $id)))
  ' 2>/dev/null || echo "[]")
  local child_count
  child_count=$(echo "$children" | jq 'length' 2>/dev/null || echo "0")
  if [[ "${child_count:-0}" -gt 0 ]]; then
    # Check if all children are closed — if so, auto-close the parent
    local open_children
    open_children=$(echo "$children" | jq '[.[] | select(.status != "closed")] | length' 2>/dev/null || echo "0")
    if [[ "${open_children:-0}" -eq 0 ]]; then
      echo "  Auto-closing parent task: all $child_count children completed"
      bd close "$task_id" --reason="All children completed" 2>/dev/null || true
    else
      echo "  Skipping parent task: $open_children of $child_count children still open"
    fi
    return 1
  fi

  # claude-tools-uxg8 (GAP G8) — cross-workspace scope check. UX-DESIGN-V2 §8.5 /
  # design/cross-ws.md §2.4. By here the bead is real, workable, non-epic,
  # non-parent, and carries no no-claim label — everything else says "claim it."
  # The last eligibility question is "does it belong to THIS workspace?" A bead
  # that references a SIBLING workspace's id (a cross-repo id) and is not a
  # tracking-only bead is a silent-misclaim hazard: the wrong runner claims a
  # task whose code lives in another repo, burns a worker, bails with nothing
  # written. We FLAG it (a loud skip-not-fail, same posture as the no-claim
  # gate) instead of silently claiming it. Opt-in: with RUNNER_SIBLING_PREFIXES
  # empty (the single-repo default) this whole block is skipped — no bd calls,
  # no work. Only a multi-workspace project that declares its siblings pays.
  if [[ -n "${RUNNER_SIBLING_PREFIXES:-}" ]]; then
    # The local prefix is the bead's own id minus its short suffix
    # (claude-tools-uxg8 → claude-tools; thirsty-fe-93o → thirsty-fe). The bead
    # lives in THIS workspace's DB, so its own prefix IS the local prefix — no
    # config needed to know "us."
    local local_prefix="${task_id%-*}"
    local show_json title desc haystack
    show_json=$(bd show "$task_id" --json 2>/dev/null || echo "[]")
    title=$(echo "$show_json" | jq -r '(if type == "array" then .[0] else . end) | (.title // "")' 2>/dev/null || echo "")
    desc=$(echo "$show_json" | jq -r '(if type == "array" then .[0] else . end) | (.description // "")' 2>/dev/null || echo "")
    haystack="$title"$'\n'"$desc"
    local sib hit=""
    local -a sib_arr=()
    IFS=',' read -ra sib_arr <<< "$RUNNER_SIBLING_PREFIXES"
    for sib in "${sib_arr[@]}"; do
      sib="${sib## }"; sib="${sib%% }"
      [[ -z "$sib" ]] && continue
      [[ "$sib" == "$local_prefix" ]] && continue   # never flag our own prefix
      # Match a <sibling-prefix>-<shortid> token. The boundary (start-of-line or
      # a non-id char before the prefix) keeps it from matching inside a longer
      # hyphenated word; the second grep extracts the clean id for the message.
      hit=$(printf '%s' "$haystack" \
            | grep -oE "(^|[^[:alnum:]-])${sib}-[a-z0-9]+" 2>/dev/null \
            | grep -oE "${sib}-[a-z0-9]+" 2>/dev/null | head -1 || true)
      [[ -n "$hit" ]] && break
    done
    if [[ -n "$hit" ]]; then
      # A tracking-only bead is allowed to reference sibling ids (that's its
      # job). Fetch labels only now — the common no-hit path paid nothing.
      local task_labels tlabel exempt=""
      local -a tlabel_arr=()
      task_labels=$(bd label list "$task_id" --json 2>/dev/null | jq -r '.[]?' 2>/dev/null || echo "")
      IFS=',' read -ra tlabel_arr <<< "$RUNNER_TRACKING_ONLY_LABELS"
      for tlabel in "${tlabel_arr[@]}"; do
        tlabel="${tlabel## }"; tlabel="${tlabel%% }"
        [[ -z "$tlabel" ]] && continue
        if printf '%s\n' "$task_labels" | grep -qxF "$tlabel" 2>/dev/null; then
          exempt="$tlabel"; break
        fi
      done
      if [[ -n "$exempt" ]]; then
        echo "  Note: references cross-repo id '$hit' but is labelled '$exempt' (tracking-only — cross-ref is intentional, claiming normally)"
      else
        echo "  Skipping: references cross-repo id '$hit' (workspace-scope check — this looks misfiled in '$local_prefix'; move it to its home repo, or add a '${RUNNER_TRACKING_ONLY_LABELS%%,*}' label if the cross-ref is intentional). Not claimed."
        return 1
      fi
    fi
  fi

  return 0
}

# Pick the FIRST workable bead from the ready snapshot (claude-tools-uxqj).
#
# next_task() returns the WHOLE `bd ready` array — priority-ascending and
# deterministic (test-bd-ready-ordering.sh) — but the old loop only ever read
# .[0] and, on an unworkable head, fell through to a skip-and-retry that
# re-selected the SAME head every loop. A single unworkable bead at ready[0]
# (a RUNNER_NO_CLAIM_LABELS task, a parent with open children, a late-blocked
# dep, or a stray epic that slipped the query filter) therefore STARVED every
# workable bead below it — 39 skip-loops / 0 builds, observed live 2026-05-30.
# That is the claude-tools-dzc starvation class, for labels not just epics: the
# fix is the same shape — iterate the candidates and skip-CONTINUE past the
# unworkable ones instead of abandoning the whole set on the first reject.
#
# This walks the snapshot in `bd ready` order and stops at the first candidate
# validate_task() accepts, then narrows TASK_JSON to that ONE element so every
# downstream `.[0]` read (title/desc/priority + the defensive re-validate
# below) is unchanged. validate_task()'s skip / auto-close lines still reach the
# runner's stdout because this runs in the loop body, NOT a command-sub.
#
# Sets TASK_JSON (narrowed to the chosen 1-elem array) + TASK_ID on success.
# Returns: 0 a workable bead was selected
#          1 the ready set is genuinely EMPTY (a real drain)
#          2 the ready set is NON-empty but every candidate is unworkable
select_workable_task() {
  TASK_JSON=$(next_task)
  local n i cand_id
  n=$(echo "$TASK_JSON" | jq 'length' 2>/dev/null || echo 0)
  [[ "${n:-0}" -gt 0 ]] || { TASK_ID=""; return 1; }
  for (( i=0; i<n; i++ )); do
    cand_id=$(echo "$TASK_JSON" | jq -r ".[$i].id // empty" 2>/dev/null || echo "")
    [[ -n "$cand_id" ]] || continue
    if validate_task "$cand_id"; then
      TASK_JSON=$(echo "$TASK_JSON" | jq -c ".[$i] | [.]" 2>/dev/null || echo "$TASK_JSON")
      TASK_ID="$cand_id"
      return 0
    fi
    # Unworkable candidate — keep actual-state warm while we scan past it so a
    # long all-unworkable head doesn't age out the GUI (the claude-tools-g20
    # hot-spin guard), the same `hb idle` the old single-candidate skip emitted.
    hb idle
  done
  TASK_ID=""
  return 2
}

# ── Failure classification ───────────────────────────────────────────────────

# Read signal file and classify the failure.
# Args: $1 = signal file, $2 = task ID, $3 = exit code
# Prints classification to stdout.
classify_failure() {
  local signal_file="$1" task_id="$2" exit_code="$3"

  # Exit 0: check if task was actually completed in beads
  if [[ "$exit_code" -eq 0 ]]; then
    local task_status
    task_status=$(bd show "$task_id" --json 2>/dev/null | jq -r '.[0].status // empty' 2>/dev/null || true)
    if [[ "$task_status" == "closed" || -z "$task_status" ]]; then
      # Closed = success. Empty = bd show failed, default to success (fail-open).
      [[ -z "$task_status" ]] && echo "  (Could not verify task status — assuming success)" >&2
      echo "SUCCESS"
    else
      echo "TASK_NOT_CLOSED"
    fi
    return
  fi

  # Non-zero exit: check signal file for specific error types.
  # Order matters: terminal conditions first, then transient ones.
  # A session may accumulate multiple signals (e.g., transient rate_limit then
  # terminal max_output_tokens), so check the more decisive signals first.
  if [[ -f "$signal_file" ]]; then
    grep -q '^AUTH_FAILURE=' "$signal_file" 2>/dev/null && { echo "AUTH_FAILURE"; return; }
    grep -q '^BILLING_ERROR=' "$signal_file" 2>/dev/null && { echo "BILLING_ERROR"; return; }
    # Context overflow is the most decisive terminal: the session physically
    # cannot continue, and retrying the same task on the same model re-overflows
    # deterministically. Check before max_output_tokens (same family).
    grep -q '^CONTEXT_OVERFLOW=' "$signal_file" 2>/dev/null && { echo "CONTEXT_OVERFLOW"; return; }
    # max_output_tokens can arrive as an api_retry error OR as a result stop_reason
    grep -q '^MAX_OUTPUT_TOKENS=' "$signal_file" 2>/dev/null && { echo "MAX_OUTPUT_TOKENS"; return; }
    grep -q '^RESULT_STOP_REASON=max_tokens' "$signal_file" 2>/dev/null && { echo "MAX_OUTPUT_TOKENS"; return; }
    grep -q '^RESULT_STOP_REASON=length' "$signal_file" 2>/dev/null && { echo "MAX_OUTPUT_TOKENS"; return; }
    grep -q '^SERVER_ERROR=' "$signal_file" 2>/dev/null && { echo "SERVER_ERROR"; return; }
    grep -q '^WATCHDOG_KILL=' "$signal_file" 2>/dev/null && { echo "WATCHDOG_KILL"; return; }
    grep -q '^RATE_LIMIT=' "$signal_file" 2>/dev/null && { echo "RATE_LIMIT"; return; }
  fi

  echo "UNKNOWN_FAILURE"
}

# §7.2 PRIMARY worker-driven stuck detection (the deliberate signal).
# Research Q4 + I3's genuine dogfood (claude-tools-3in), both confirmed: a
# capable headless worker does NOT slip the §7.6 guardrail — it OBEYS "just
# execute, don't ask" and, on a real human-decision fork, takes the INSTRUCTED
# deterministic path the prompt now mandates: `bd update --status=blocked` →
# structured ask → `bd human` → exit WORKER_STUCK_EXIT (§7.2). §7.1 mandates
# STUCK_NEEDS_HUMAN PREEMPT both the exit-0 "agent forgot to close" masking
# (research Q5 failure class) and UNKNOWN_FAILURE. Detection fires on ANY —
# zero model trust, same discipline as the §7.2 BACKSTOP stream scan:
#   1. exit == WORKER_STUCK_EXIT — the §7.2/§8.1 canonical worker sentinel
#      (what the conformance `stuck_primary` plan emits; what a stuck-aware
#      worker wrapper sets). The deterministic primary.
#   2. CANONICAL bead state: status=blocked AND the `human` label set — the
#      real-world corroborator (the runner sets in_progress before each run,
#      so blocked+human after is this run's deliberate act). claude -p exits
#      0 regardless (research Q4); the bd-CLI side effects are the signal.
#   3. RELAXED bead state (claude-tools-2ir): the `human` label set AND notes
#      contain a STUCK_NEEDS_HUMAN marker, even WITHOUT status=blocked. Post-
#      mortem of n34 + the opa→n34, 4wt→4xe chains: agents reliably do 3 of
#      the 4 stuck-protocol steps (label + structured note + stop) but slip
#      step 1 (status flip). The signal is honest; a 4-step ceremony where
#      missing step 1 invalidates the OTHER 3 is brittle. Brian's policy call
#      (2026-05-20): accept the signal, AUTO-FLIP status=blocked here so the
#      rest of the flow (sr_route_stuck, dossier, blocked-for-human routing)
#      sees the canonical state. Tradeoff Brian acknowledged: forgives slips
#      but trusts the label; the existing flow already trusts the label
#      heavily. Every auto-flip logs an incident so we see slip frequency.
# Echoes "worker_stuck" + returns 0 on a fire; nonzero + silent otherwise.
# Args: $1 = task_id, $2 = claude exit code.
detect_worker_stuck_primary() {
  local task_id="$1" exit_code="${2:-0}" row status has_human has_stuck_note
  # claude-tools-43m: stuck detection is part of the ask-brian / dossier
  # spine. In opted-out workspaces the worker prompt never mentions the
  # protocol, so any "stuck" signal would be spurious (stale notes, an
  # off-the-cuff `human` label) — silently no-op so the normal classify_failure
  # path handles whatever the worker actually did.
  if [[ "${ASK_BRIAN_ENABLED:-0}" != "1" ]]; then
    return 1
  fi
  if [[ "$exit_code" == "${WORKER_STUCK_EXIT:-7}" ]]; then
    echo "worker_stuck"; return 0
  fi
  command -v bd >/dev/null 2>&1 || return 1
  # --long --json includes the `notes` key (the runner already relies on this
  # shape at create_analysis_task — same contract).
  # claude-tools-1vnx: RETRY a transient empty/failed read. A ONE-SHOT read here
  # was a root of the m3xi thrash — a single `bd show` hiccup made a genuine
  # status=blocked + `human` fork read as not-stuck, so it fell through to
  # TASK_NOT_CLOSED (reset --status=open + analysis child + re-pick → re-block →
  # re-misclassify, burning an Opus analysis task per cycle). A bounded re-fetch
  # closes that transient window; the dispatch-site _bead_blocked_for_human guard
  # (claude-tools-1vnx) is the belt-and-suspenders behind this for a read that
  # STILL fails or a status that flipped away from blocked at check time.
  local _read_try
  row=""
  for _read_try in 1 2 3; do
    row=$(bd show "$task_id" --long --json 2>/dev/null || true)
    if [[ -n "$row" ]]; then break; fi
  done
  [[ -n "$row" ]] || return 1
  status=$(printf '%s' "$row" | jq -r '.[0].status // ""' 2>/dev/null)
  has_human=$(printf '%s' "$row" | jq -r '
    if (any(.[].labels[]?; . == "human")) then "yes" else "no" end' 2>/dev/null)
  # claude-tools-uxvi4 (must-protect #12 / HANDOFF "Fix-B over-trigger"): TIGHTEN
  # the relaxed case-3 note match to a RECENT WINDOW so a once-stuck-then-resolved
  # bead does not auto-loop forever on re-pickup (the 240 symptom). The old match
  # was `STUCK_NEEDS_HUMAN anywhere in notes` — including STALE residue from a
  # prior attempt. Now `has_stuck_note` is the OR of two recency-aware recognizers:
  #   • recent_ts — a machine marker STUCK_NEEDS_HUMAN@<epoch> within
  #     STUCK_NOTE_RECENT_WINDOW (default 1800s). A STALE @epoch (the runner's own
  #     stuck-observation residue, stamped below) is IGNORED — this is the window.
  #   • has_bare — a BARE STUCK_NEEDS_HUMAN that is NOT the runner's own
  #     "Runner: STUCK_NEEDS_HUMAN at <time>" AUDIT line (the (?<!Runner: )
  #     lookbehind drops that residue — the DOMINANT over-trigger vector this
  #     predicate itself produced) and NOT an @epoch marker. This preserves the
  #     claude-tools-2ir agent-slip safety net + the BC-53 back-compat the
  #     existing fixtures pin, while closing the audit-residue loop.
  local now_epoch stuck_win recent_ts has_bare
  now_epoch=$(date +%s 2>/dev/null || echo 0)
  stuck_win="${STUCK_NOTE_RECENT_WINDOW:-1800}"
  recent_ts=$(printf '%s' "$row" | jq -r --argjson now "$now_epoch" --argjson win "$stuck_win" '
    if (((.[0].notes // "")
          | [scan("STUCK_NEEDS_HUMAN@([0-9]+)")] | map(.[0] | tonumber)
          | map(select(($now - .) <= $win and ($now - .) >= -300)) | length) > 0)
    then "yes" else "no" end' 2>/dev/null) || recent_ts="no"
  has_bare=$(printf '%s' "$row" | jq -r '
    if ((.[0].notes // "") | test("(?<!Runner: )STUCK_NEEDS_HUMAN(?!@[0-9])"))
    then "yes" else "no" end' 2>/dev/null) || has_bare="no"
  if [[ "$recent_ts" == "yes" || "$has_bare" == "yes" ]]; then
    has_stuck_note="yes"
  else
    has_stuck_note="no"
  fi
  # Case 2: canonical blocked+human — fires as before, no auto-flip needed.
  if [[ "$status" == "blocked" && "$has_human" == "yes" ]]; then
    echo "worker_stuck"; return 0
  fi
  # Case 3 (claude-tools-2ir RELAXED): human label + STUCK_NEEDS_HUMAN note,
  # status NOT blocked ⇒ the agent slipped step 1. Auto-flip and log so the
  # downstream §7.3 spine sees the canonical state, and metrics show how often
  # the slip happens (informs prompt-vs-runner-tolerance investment).
  if [[ "$has_human" == "yes" && "$has_stuck_note" == "yes" ]]; then
    bd update "$task_id" --status=blocked >/dev/null 2>&1 || true
    if command -v record_incident >/dev/null 2>&1; then
      record_incident "$task_id" "STUCK_AUTOFLIP:relaxed-primary(human+note,no-blocked)" "-"
    fi
    if command -v append_runner_note >/dev/null 2>&1; then
      # NB: the descriptive note deliberately AVOIDS the literal STUCK_NEEDS_HUMAN
      # token — writing it here would create exactly the bare-match residue this
      # predicate's recency tightening (claude-tools-uxvi4) exists to kill.
      append_runner_note "$task_id" "STUCK_AUTOFLIP relaxed-primary — agent set 'human' label + a stuck-ask note but missed status=blocked; runner auto-flipped (claude-tools-2ir)" "-"
      # claude-tools-uxvi4: stamp a RECENCY-BOUNDED machine marker so (a) the
      # recent_ts recognizer above has a live producer and (b) on a future
      # re-pickup this observation reads as STALE (past STUCK_NOTE_RECENT_WINDOW)
      # and does NOT re-trip the auto-flip — the over-trigger fix, made concrete.
      append_runner_note "$task_id" "STUCK_NEEDS_HUMAN@${now_epoch}" "-"
    fi
    echo "worker_stuck"
    return 0
  fi
  return 1
}

# claude-tools-1vnx — un-thrashable human-decision fork detector (belt-and-
# suspenders behind the §7.3 STUCK preempt). True iff the bead is a human
# decision the worker DELIBERATELY left in place: the `human` label set AND a
# status the runner must not silently undo (blocked, or unreadable). The casualty
# (claude-tools-m3xi) was re-picked/re-surfaced 3× because the preempt's one-shot
# `bd show` read missed a genuine blocked+human at exit and the TASK_NOT_CLOSED
# arm then reset it --status=open and spawned an analysis child whose close
# re-armed the bead. This predicate is the OUTCOME guard the preempt asserts,
# made INDEPENDENT of the preempt's gating (ASK_BRIAN_ENABLED + the stuck-routing
# lib) and of its read fragility:
#   • The `human` LABEL is the load-bearing signal — sticky and durable where
#     status/defer are not (the same reasoning as RUNNER_NO_CLAIM_LABELS at :86),
#     and read via `bd label list` (the proven no-claim-gate read), retried.
#   • Status is corroboration: fire on `blocked` (the worker's deliberate fork
#     state), OR fail-SAFE when status is UNREADABLE after retries (never thrash a
#     CONFIRMED human fork on a transient bd hiccup). A reliably non-blocked status
#     (open/in_progress/closed) returns 1 → normal classification, matching the
#     detect_worker_stuck_primary negative posture that a non-blocked bare `human`
#     label alone is NOT the fork we pin (test-stuck-primary-relaxed.sh).
# Returns 0 = pin blocked-for-human; 1 = not our case (let classify_failure run).
_bead_blocked_for_human() {
  local task_id="$1" labels status row notes has_ask _try
  command -v bd >/dev/null 2>&1 || return 1
  labels=""
  for _try in 1 2; do
    labels=$(bd label list "$task_id" --json 2>/dev/null | jq -r '.[]?' 2>/dev/null || true)
    if [[ -n "$labels" ]]; then break; fi
  done
  printf '%s\n' "$labels" | grep -qxF "human" 2>/dev/null || return 1
  status=""
  for _try in 1 2; do
    status=$(bd show "$task_id" --json 2>/dev/null \
             | jq -r '(if type == "array" then .[0] else . end) | (.status // "")' 2>/dev/null || true)
    if [[ -n "$status" ]]; then break; fi
  done
  # Canonical fork state (blocked) or a fail-SAFE unreadable status ⇒ pin.
  [[ "$status" == "blocked" || -z "$status" ]] && return 0
  # claude-tools-309l — aged-out still-stuck residual. A human-labelled bead the
  # worker left NOT blocked (slipped the status flip — the m3xi vector) whose
  # STUCK_NEEDS_HUMAN note has aged past detect_worker_stuck_primary's recency
  # window (uxvi4) is no longer caught by the §7.3 Case-3 preempt and falls to
  # TASK_NOT_CLOSED → reset + analysis (thrash). Recognise it here, recency-
  # INDEPENDENTLY, because the `human` LABEL — not the clock — is the freshness
  # signal: a RESOLVED fork has its label REMOVED by the answer consequence
  # (sr_reconcile only lifts the work-plane block; the consequence removes the
  # label), so a bead that STILL carries it is still-stuck. Only the genuinely-
  # unfinished, not-blocked states qualify — a `closed` bead is a SUCCESS and
  # must NEVER be pinned back (classify_failure SUCCESS ⟺ closed).
  [[ "$status" == "open" || "$status" == "in_progress" ]] || return 1
  # A NON-audit human-fork note (the worker's own ask; the `(?<!Runner: )`
  # lookbehind drops the runner's OWN audit/auto-flip residue — the dominant
  # uxvi4 over-trigger vector) distinguishes a genuine fork from a spurious bare
  # `human` label (the test-stuck-primary-relaxed negative posture: a bare label
  # with NO ask note still falls through). This does NOT reopen Fix-B: the
  # over-trigger was the preempt RE-ROUTING a dossier on a resolved bead; this
  # belt fires only while the label persists and its action (pin + §7.4-deduped
  # author) is idempotent.
  # claude-tools-gqyp — match the protocol's ACTUAL ask shape, not just a machine
  # token. The escalation protocol writes a structured ask HEADED `HUMAN DECISION
  # NEEDED`; the v1 `--append-notes` fallback (:2050) writes STUCK_NEEDS_HUMAN@<ts>.
  # Recognise BOTH (under the same Runner-residue guard) so a compliant fork the
  # worker left NOT blocked is caught regardless of which producer path it took —
  # 309l's token-only grep was dead for the canonical `HUMAN DECISION NEEDED` form.
  row="__ERR__"
  for _try in 1 2; do
    row=$(bd show "$task_id" --long --json 2>/dev/null) || row="__ERR__"
    [[ "$row" != "__ERR__" && -n "$row" ]] && break
  done
  # A degraded/empty read ⇒ fail-CLOSED (never pin an unfinished bead on a read
  # glitch). Checked on the RAW row BEFORE jq, so the sentinel is load-bearing —
  # a future edit of the test() below can't turn a read failure into a false fire.
  [[ "$row" == "__ERR__" || -z "$row" ]] && return 1
  notes=$(printf '%s' "$row" | jq -r '.[0].notes // ""' 2>/dev/null) || return 1
  has_ask=$(printf '%s' "$notes" \
    | jq -Rrs 'test("(?<!Runner: )(STUCK_NEEDS_HUMAN|HUMAN DECISION NEEDED)")' 2>/dev/null) || has_ask="false"
  [[ "$has_ask" == "true" ]]
}

# Create an analysis task that blocks the failed task.
# A fresh agent investigates the failure and creates follow-up tasks.
# Args: $1 = task_id, $2 = task_title, $3 = failure_reason
create_analysis_task() {
  local task_id="$1" task_title="$2" reason="$3"

  # Guard: don't create analysis tasks for analysis tasks (prevents infinite chains)
  local labels
  labels=$(bd label list "$task_id" --json 2>/dev/null || echo "[]")
  if echo "$labels" | jq -e '.[] | select(. == "analysis")' >/dev/null 2>&1; then
    echo "  (Skipping analysis task creation — this is already an analysis task)"
    return 0
  fi

  local analysis_desc
  read -r -d '' analysis_desc <<EOF || true
Task $task_id ("$task_title") failed with reason: $reason.

Investigate what went wrong and determine next steps:
- Check the state of any code changes the previous agent made (git log, git diff)
- Determine if the task needs to be split into smaller sub-tasks
- Determine if a design task should be created first to plan the approach
- Determine if the agent just needs a fresh context window to retry
- Create any necessary follow-up beads tasks with appropriate dependencies

Before closing, ensure $task_id is blocked by any new tasks you create:
  bd dep add $task_id <new-task-id>
EOF

  local create_output analysis_id
  create_output=$(bd create \
    --title "Analyze failure: $task_title" \
    -d "$analysis_desc" \
    -p 1 \
    --labels "model:opus,analysis" 2>&1) || {
    echo "  WARNING: Failed to create analysis task"
    return 1
  }

  # Parse ID from output like: "✓ Created issue: prefix-abc — title"
  analysis_id=$(echo "$create_output" | sed -n 's/.*issue: \([^ ]*\).*/\1/p' | head -1)
  if [[ -z "$analysis_id" ]]; then
    echo "  WARNING: Could not parse analysis task ID from: $create_output"
    return 1
  fi

  bd dep add "$task_id" "$analysis_id" 2>/dev/null || {
    echo "  WARNING: Failed to add dependency $analysis_id -> $task_id"
  }

  echo "  Created analysis task: $analysis_id (blocks $task_id)"
  bd update "$task_id" --append-notes="Failed ($reason). Analysis task: $analysis_id" 2>/dev/null || true

  # ── G2 (claude-tools-vez): runner-killed bead ⇒ Inbox analysis dossier ─────
  # Best-effort, guarded-optional (same discipline as the §7.3 stuck-routing
  # block — absent libs ⇒ runner unchanged; failure here NEVER blocks the
  # analysis bead, which is the substrate). The dossier surfaces a
  # human-readable failure summary + the Runner: note timeline grouped by
  # attempt, plus one approve-recommendation Item for Brian to ack the
  # queued analysis. Deterministic id = "analysis-<task_id>" ⇒ one dossier
  # per failed bead, idempotent under same-input retries.
  if command -v dg_from_analysis_task >/dev/null 2>&1; then
    : "${CO_STORE:=$LOG_DIR/.co-store}"; export CO_STORE
    local notes_json classification did analysis_input
    local bearer="${SR_BEARER:-bearer-runner-stuck}"
    # Pull current notes from the bead (newline-separated text field; only the
    # `--long --json` form includes the `notes` key, verified against current
    # bd). Filter to Runner: lines only — the timeline is built from those
    # alone. A missing/changed shape falls back to "[]" so the dossier still
    # renders, just with the honest "no notes" placeholder.
    notes_json=$(bd show "$task_id" --long --json 2>/dev/null \
      | jq -c '
          [ ((.[0].notes // "") | split("\n") | .[]
             | select(test("^Runner: "))) ]' 2>/dev/null) || notes_json="[]"
    [[ -n "$notes_json" ]] || notes_json="[]"
    # Derive a normalized classification from the reason for the inbox-view.js
    # CLASS_PLAIN lookup (the renderer's class→plain-English map). Take the
    # leading token (up to first whitespace or ASCII dash), uppercase it.
    # Unknown tokens fall through to a generic "see analysis task for details"
    # line in dg_from_analysis_task — never invents details. Avoids regex
    # multi-byte traps by splitting on a plain ASCII class only.
    classification=$(printf '%s' "$reason" \
      | awk '{n=split($0, a, /[ \t-]/); print toupper(a[1])}' 2>/dev/null \
      | tr -cd 'A-Z0-9_:' )
    [[ -n "$classification" ]] || classification="UNKNOWN_FAILURE"
    analysis_input=$(jq -cn \
      --arg title "$task_title" \
      --arg reason "$reason" \
      --arg class "$classification" \
      --arg atid "$analysis_id" \
      --arg adesc "$analysis_desc" \
      --argjson notes "$notes_json" '
      { task_title:$title, reason:$reason, classification:$class,
        analysis_task_id:$atid, analysis_desc:$adesc,
        runner_notes:$notes }' 2>/dev/null) || analysis_input=""
    if [[ -n "$analysis_input" ]]; then
      # claude-tools-69u8: the dossier-builder bridge is now wired ONCE at the
      # dg__author chokepoint (DG_AUTHOR_AUTOWIRE, set at runner startup) instead
      # of per-call-site here — so this Flow G analysis dossier is authored by
      # the real agent (claude reachable) or the labeled-degraded jq path
      # (absent), with no local DG_AUTHOR_CMD export. (was claude-tools-ccnl/5me)
      did=$(dg_from_analysis_task "$bearer" \
        "analysis-$task_id" "$task_id" "$analysis_input" 2>/dev/null || true)
      if [[ -n "$did" ]]; then
        echo "  Inbox analysis dossier: $did (bead $task_id)"
        # §4.3/C3 — pair with the SINGLE Notification at creation if no_emit is
        # available (mirrors the §7.3 stuck path's I3 wiring); idempotent on a
        # re-trigger, never blocking. A failure is observable, not silent.
        if command -v no_emit >/dev/null 2>&1; then
          no_emit "$bearer" "$did" >/dev/null 2>&1 \
            || echo "  WARN: analysis dossier '$did' persisted but the §4.3 no_emit FAILED (idempotent — safe to re-emit later)"
        fi
      else
        echo "  WARN: analysis dossier write deferred for $task_id (best-effort; the analysis bead is the substrate and is already queued)"
      fi
    fi
  fi
}

# ── Post-mortem: visibility helpers ──────────────────────────────────────────

# Preserve the claude stream-json file for post-mortem analysis.
# Args: $1 = source stream file, $2 = destination basename (no extension)
# Echoes the relative destination path on success, empty string on skip/failure.
preserve_stream() {
  local src="$1" dest_base="$2"
  local dest="$LOG_DIR/${dest_base}.jsonl"
  [[ -f "$src" ]] || { echo ""; return; }
  cp "$src" "$dest" 2>/dev/null && echo "$dest" || echo ""
}

# Append a tab-separated incident record. Always called for every non-success
# classification, regardless of whether a stream was preserved.
# Args: $1 = task_id, $2 = classification, $3 = log_path (or "-" for none)
record_incident() {
  local task_id="$1" classification="$2" log_path="${3:--}"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s\t%s\t%s\t%s\n' "$ts" "$task_id" "$classification" "$log_path" >> "$INCIDENTS_LOG" 2>/dev/null || true
  INCIDENTS+=("$ts  $task_id  $classification  $log_path")
}

# Append a uniform "Runner: ..." note to a beads task. Greppable in `bd show`.
# Args: $1 = task_id, $2 = classification, $3 = log_path (or "-" for none)
append_runner_note() {
  local task_id="$1" classification="$2" log_path="${3:--}"
  local ts
  ts=$(date -u +%H:%M:%SZ)
  local msg="Runner: $classification at $ts"
  if [[ "$log_path" != "-" ]]; then
    msg="$msg — log: $log_path"
  else
    msg="$msg — no stream preserved"
  fi
  bd update "$task_id" --append-notes="$msg" 2>/dev/null || true
}

# Print the per-run incidents summary. Surfaces watchdog kills and other
# silently-retried failures so they don't go unnoticed when the next attempt
# succeeds.
print_incidents_summary() {
  if [[ ${#INCIDENTS[@]} -eq 0 ]]; then
    return
  fi
  echo ""
  echo "Incidents this run (${#INCIDENTS[@]}):"
  local line
  for line in "${INCIDENTS[@]}"; do
    echo "  $line"
  done
  echo "Full log: $INCIDENTS_LOG"
}

# Scan the stream for tool_result errors with high-signal patterns. Surfaces
# silent failures (e.g., subagent-not-found) that don't fail the run but mean
# the agent didn't actually do what we asked. Pattern-matched only — raw counts
# would be dominated by routine probes (Read on missing file, grep no-match, etc.).
# Side effects only: incidents log, beads note, optional notification. Never
# changes classification or exit code.
# Args: $1 = stream file, $2 = task_id
scan_tool_errors() {
  local stream="$1" task_id="$2"
  [[ -f "$stream" ]] || return 0

  # Cheap pre-filter: skip the jq pass entirely if no error markers exist.
  grep -qF '"is_error":true' "$stream" 2>/dev/null || return 0

  # Extract the textual body of every tool_result with is_error:true.
  # .content can be a string or an array of {type,text} parts — handle both.
  local all_errors
  all_errors=$(jq -r '
    .. | objects? | select(.type? == "tool_result" and .is_error? == true) |
    (.content | if type == "string" then .
                elif type == "array" then (map(select(.type? == "text") | .text) | join(" "))
                else "" end)
  ' "$stream" 2>/dev/null || true)
  [[ -z "$all_errors" ]] && return 0

  # Pattern strings come from claude-code/CLI; brittle by nature. Update if drift observed.
  local subagent_hits perm_hits mcp_hits
  subagent_hits=$(echo "$all_errors" | grep -cE "Agent type '[^']+' not found" 2>/dev/null || true)
  perm_hits=$(echo "$all_errors" | grep -cE "Permission denied|is not allowed" 2>/dev/null || true)
  mcp_hits=$(echo "$all_errors" | grep -cE "MCP server.*(unavailable|failed|not connected)" 2>/dev/null || true)

  if [[ "${subagent_hits:-0}" -gt 0 ]]; then
    local subagent_names
    subagent_names=$(echo "$all_errors" | grep -oE "Agent type '[^']+'" | sort -u | sed -E "s/Agent type '([^']+)'/\1/" | paste -sd, - 2>/dev/null || echo "?")
    local msg="subagent-unavailable: $subagent_names (×$subagent_hits)"
    bd update "$task_id" --append-notes="Runner: tool-error $msg" 2>/dev/null || true
    record_incident "$task_id" "TOOL_ERROR:$msg" "-"
    notify_user "beads-runner: subagent unavailable" "$task_id — $subagent_names"
  fi
  if [[ "${perm_hits:-0}" -gt 0 ]]; then
    bd update "$task_id" --append-notes="Runner: tool-error permission-denied (×$perm_hits)" 2>/dev/null || true
    record_incident "$task_id" "TOOL_ERROR:permission-denied (×$perm_hits)" "-"
  fi
  if [[ "${mcp_hits:-0}" -gt 0 ]]; then
    bd update "$task_id" --append-notes="Runner: tool-error mcp-unavailable (×$mcp_hits)" 2>/dev/null || true
    record_incident "$task_id" "TOOL_ERROR:mcp-unavailable (×$mcp_hits)" "-"
  fi
}

# claude-tools-apen: post-close discipline audit. Catches the AGENT-BYPASS-VIA-CAP
# class — a worker that burns the 8-block Stop-hook cap and closes the bead
# anyway. Mirrors the close-checklist.sh checks at the runner level after the
# session ends, so a bypass leaves a regression bead + incident, not a silent
# disappear. Only meaningful when the bead is actually closed (the SUCCESS
# path), so the runner calls it from there.
#
# Args: $1 = task_id, $2 = session anchor (LOG_BASE — forensic backtrack handle)
# Side effects only: records incident, files regression bead, appends note,
# notifies. Never reopens the original bead — that decision belongs to the
# human triaging the regression bead (reopening here could let the same broken
# worker loop on it again).
post_close_audit() {
  local task_id="$1" session_anchor="${2:-}"
  local project_dir="$PWD"

  # claude-tools-d3w9 test-isolation seam: the conformance harness fakes the
  # worker (claude/bd stubbed, commit-less throwaway workdir), so this
  # discipline audit can only ever fire spurious close_without_commit /
  # dirty_tree / missing_debrief findings and their side-effects (Runner: note,
  # incident row, regression bead) — none of which the harness's INTERFACE
  # §3/§7/§8 classification/lifecycle/exit assertions model. The audited
  # behaviour is out of that harness's scope and has no BC of its own, so the
  # harness opts out via this seam (mirrors the RUNNER_EXIT_ON_DRAIN seam).
  # Defaults OFF — production ALWAYS runs the audit.
  [[ -n "${RUNNER_SKIP_POST_CLOSE_AUDIT:-}" ]] && return 0

  # Re-verify bead is actually closed. SUCCESS classification is fail-open on
  # bd-show errors (line 743) — don't audit if we can't read the status, since
  # we can't tell whether the close even happened.
  if ! command -v bd >/dev/null 2>&1; then return 0; fi
  local status
  status="$(bd show "$task_id" --json 2>/dev/null | jq -r '.[0].status // empty' 2>/dev/null)"
  [[ "$status" == "closed" ]] || return 0

  local failures=()

  # Check 1: close-without-commit — the primary signal for the bypass case.
  # Mirrors close-checklist.sh check 3 (--since='1 hour ago'). NOTE: uses
  # `--format=%h` + emptiness check rather than `wc -l`, because git's `format:`
  # (and the default `format=`) emit no trailing newline — `wc -l` on a single
  # matching hash returns 0, indistinguishable from no-match. Emptiness is the
  # honest signal.
  if command -v git >/dev/null 2>&1 && [[ -d "$project_dir/.git" ]]; then
    local grep_out
    grep_out="$(git -C "$project_dir" log --grep="$task_id" -1 --since='1 hour ago' --format=%h 2>/dev/null || true)"
    if [[ -z "$grep_out" ]]; then
      failures+=("close_without_commit")
    fi
  fi

  # Check 2: dirty tree (excluding .beads/issues.jsonl, debrief, runner-log
  # scratch, .stop-beads). Mirrors close-checklist.sh check 2 — a closed bead
  # with a dirty tree means the worker's diff is about to be smuggled into the
  # next bead's commit. issues.jsonl is excluded because bd close itself writes
  # to it as a side-effect of flipping status; authoritative state is in Dolt
  # (claude-tools-u4ms).
  if command -v git >/dev/null 2>&1 && [[ -d "$project_dir/.git" ]]; then
    local dirty
    dirty="$(git -C "$project_dir" status --porcelain --untracked-files=all 2>/dev/null \
      | grep -vE '^.{3}(\.beads/issues\.jsonl$|\.beads/[^/]*-debrief\.txt$|\.beads/runner-logs/|\.stop-beads$)' \
      || true)"
    if [[ -n "$dirty" ]]; then
      failures+=("dirty_tree")
    fi
  fi

  # Check 3: wrapup marker (only if the workspace has a /wrapup skill).
  if [[ -f "$project_dir/.claude/skills/wrapup/SKILL.md" ]]; then
    local notes
    notes="$(bd show "$task_id" --long --json 2>/dev/null | jq -r '.[0].notes // ""' 2>/dev/null)"
    if ! printf '%s' "$notes" | grep -q 'wrapup-reviewed:'; then
      failures+=("wrapup_not_invoked")
    fi
  fi

  # Check 4: debrief presence. Mirrors close-checklist.sh check 5 (>=40 chars).
  local notes2
  notes2="$(bd show "$task_id" --long --json 2>/dev/null | jq -r '.[0].notes // ""' 2>/dev/null)"
  if [[ -z "$notes2" || ${#notes2} -lt 40 ]]; then
    failures+=("missing_debrief")
  fi

  if (( ${#failures[@]} == 0 )); then
    return 0
  fi

  local failed_csv
  failed_csv="$(printf '%s,' "${failures[@]}" | sed 's/,$//')"

  # 1. File the regression bead FIRST so the note we append below can carry
  #    its id — otherwise a `bd create` failure would leave the original bead
  #    claiming a regression was filed when it wasn't. P1 because a silently-
  #    closed bead is the exact failure mode this is designed to surface;
  #    sitting in the backlog defeats the purpose. Labeled discipline-bypass
  #    so it's filterable; NOT human-triage-labeled by default (per
  #    feedback_beads_human_triage_label).
  local desc
  desc="Auto-filed by run-beads-tasks.sh post-close audit (claude-tools-apen).

Bead $task_id was closed despite failing the close-discipline checks. This
typically means the close-checklist.sh Stop hook was bypassed — the 8-block
cap was burned by repeated retries, or the runner-session gating failed open.

Failed checks: $failed_csv
Session anchor: ${session_anchor:-unknown}
Runner log dir: $LOG_DIR

Human triage:
- Pull the stream-json and runner log for the session anchor (forensic).
- Inspect git log / git diff — was real work done, just not committed?
- If the close was premature, 'bd reopen $task_id' and finish properly.
- If the hook itself let it slip, investigate beads-runner/hooks/close-checklist.sh.

Cross-ref: claude-tools-apen (this audit), claude-tools-td0y (the hook)."
  local create_output regression_id=""
  create_output="$(bd create \
    --title "discipline-bypass: $task_id closed without $failed_csv" \
    -d "$desc" \
    --type=bug \
    -p 1 \
    --labels "discipline-bypass" 2>&1)" || true
  # `bd create` (text mode) emits "✓ Created issue: <prefix-id> — title".
  # Mirrors create_analysis_task's parse (same source format). Empty on parse
  # failure ⇒ the note below honestly says "regression bead may have failed".
  regression_id="$(printf '%s' "$create_output" | sed -n 's/.*issue: \([^ ]*\).*/\1/p' | head -1)"

  # 2. Incident log entry — forensic anchor (carries the session/log handle so
  #    the stream-json post-mortem is one ls away). The classification follows
  #    the existing INCIDENTS schema (TAB-separated, "CLASS:detail" tag form).
  local incident_tag="DISCIPLINE_BYPASS:$failed_csv"
  [[ -n "$regression_id" ]] && incident_tag="$incident_tag (regression=$regression_id)"
  record_incident "$task_id" "$incident_tag" "${session_anchor:--}"

  # 3. Append a marker note on the original bead so `bd show` reveals the
  #    bypass at a glance. Cross-reference the regression bead id if we got
  #    one back — otherwise be honest that the file step may have failed.
  local note="Runner: DISCIPLINE_BYPASS $failed_csv (session=${session_anchor:-unknown})"
  if [[ -n "$regression_id" ]]; then
    note="$note — regression bead $regression_id filed (claude-tools-apen)"
  else
    note="$note — regression-bead create FAILED, see incidents.log (claude-tools-apen)"
  fi
  bd update "$task_id" --append-notes="$note" 2>/dev/null || true

  local notify_body="$task_id closed without $failed_csv"
  [[ -n "$regression_id" ]] && notify_body="$notify_body — $regression_id filed"
  notify_user "beads-runner: discipline bypass" "$notify_body"
}

# macOS desktop notification + terminal bell. Best-effort, never fails the run.
# Args: $1 = title, $2 = body
notify_user() {
  local title="$1" body="$2"
  printf '\a' 2>/dev/null || true
  if command -v osascript >/dev/null 2>&1; then
    # Escape double-quotes for AppleScript string literal
    local safe_title="${title//\"/\\\"}"
    local safe_body="${body//\"/\\\"}"
    osascript -e "display notification \"$safe_body\" with title \"$safe_title\"" 2>/dev/null || true
  fi
}

# ── Main loop ────────────────────────────────────────────────────────────────

# gk17 source-mode guard: BEADS_RUNNER_TEST_MODE=1 lets a test (or a startup-
# sanity check) `source` this file to validate that all function definitions
# load cleanly without entering the persistent task loop. Returns from the
# sourced file at this point; functions defined above remain in the caller's
# shell, but no `hb starting` / `while true` side-effect runs.
if [[ "${BEADS_RUNNER_TEST_MODE:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

# §4.2 `starting`: the very first registration line — a freshly (re)launched
# runner appears in the hosted engine under its project_ref before it claims
# any work (the I2 "appears as a live runner via the deployed read path").
hb starting

# Preserve any startup-time TASK_COST_CLASS as a project-wide override (the
# §1257 escape hatch). Per-iteration cost-class is recomputed from TASK_PRIORITY
# below, so the empty-guard can't latch a stale value across iterations (hkwg).
TASK_COST_CLASS_OVERRIDE="${TASK_COST_CLASS:-}"

while true; do
  # Check for graceful stop signal
  if [[ -f "$STOP_FILE" ]]; then
    echo ""
    echo "Stop file detected ($STOP_FILE) — stopping gracefully."
    rm -f "$STOP_FILE"
    break
  fi

  # claude-tools-trunkpin: pin HEAD back to main at the loop top, BEFORE the
  # next bead is claimed. The runner auto-commits per bead onto whatever branch
  # HEAD points at; once a worker wanders the tree onto a feature branch, all
  # later beads pile there until a human notices. Enforce in the loop (the same
  # lesson as the gate/close hooks), not by worker discipline. Self-heals only
  # when the tree is clean; silent no-op on the common already-on-main path.
  pin_head_to_main "${RUNNER_SKIP_PIN_MAIN:-0}"

  # Check usage quota before starting a new task
  while ! check_usage; do
    # zfxe: name the gate that tripped + the numbers it tripped on. The old
    # "Above ${USAGE_THRESHOLD}% usage" wording was a lie — the daemon-side
    # cost-class gate can deny while neither 5h nor 7d is above USAGE_THRESHOLD
    # (e.g. a daemon/runner threshold split), so naming USAGE_THRESHOLD here
    # pointed at a gate that wasn't the one that held.
    echo "  Capacity verdict=over reason=${USAGE_REASON:-unknown} (5h=${USAGE_PCT_5H:-?}% 7d=${USAGE_PCT_7D:-?}%) — sleeping $((USAGE_SLEEP_SECONDS / 60))min before rechecking..."
    USAGE_CACHE_TIME=0  # force fresh API call after sleep
    # Sleep in 60s chunks so stop file is detected promptly
    slept=0
    while [[ $slept -lt $USAGE_SLEEP_SECONDS ]]; do
      if [[ -f "$STOP_FILE" ]]; then
        echo "Stop file detected ($STOP_FILE) — stopping."
        rm -f "$STOP_FILE"
        break 3  # break out of: chunk loop, usage loop, main loop
      fi
      sleep 60
      slept=$((slept + 60))
    done
  done

  # ── I4 FEEDBACK RETURN PATH — observe phone-answered dossiers + lift the
  #    fork back into the ready set (claude-tools-ryz; epic 8bm).
  #    M4 (claude-tools-8jb; epic kie) MOVED the AWAIT into the per-machine
  #    daemon (DESIGN §3.2 job 5 / AD8) so observation happens CONTINUOUSLY,
  #    not only between tasks: a long `claude -p` no longer stalls the
  #    daemon's poll. The block below is the FALLBACK for a standalone runner
  #    that is NOT being supervised by the daemon (no daemon pidfile alive) —
  #    so a `bash run-beads-tasks.sh` without `daemon/install.sh` still polls
  #    on its own loop top as it did pre-M4. ───────────────────────────────
  # When the daemon owns the poll, the runner only does the RECONCILE (the
  # control→work bead-lift): the daemon has already captured the resume-answer
  # file and flipped the S-2 bfh record to resolved:true, so the next reconcile
  # here lifts the bead → open and the prompt-build splice (below) hands the
  # captured decision to the resumed agent. Identical OPTIONAL/guarded/
  # observable-not-silent posture as the §7.3 stuck block + the §8.2 la_*
  # calls: absent libs ⇒ no-op; NEVER aborts the loop.
  DAEMON_PIDFILE_PATH="${BEADS_DAEMON_PIDFILE:-$HOME/.cache/claude-tools/daemon.pid}"
  DAEMON_ALIVE=0
  if [[ -f "$DAEMON_PIDFILE_PATH" ]]; then
    DAEMON_PID_VAL="$(cat "$DAEMON_PIDFILE_PATH" 2>/dev/null || echo "")"
    if [[ -n "$DAEMON_PID_VAL" ]] && kill -0 "$DAEMON_PID_VAL" 2>/dev/null; then
      DAEMON_ALIVE=1
    fi
  fi
  # claude-tools-43m: I4 feedback-return is dead code in opted-out workspaces
  # (no dossiers means no answered forks to reconcile). Skip the poll entirely.
  if [[ "${ASK_BRIAN_ENABLED:-0}" == "1" ]] && command -v sr_reconcile_blocked_for_human >/dev/null 2>&1; then
    : "${CO_STORE:=$LOG_DIR/.co-store}"; export CO_STORE
    SR_RESUMED=0
    # FALLBACK: the daemon is absent (no live pidfile). Run the poll inline as
    # the pre-M4 runner did so a standalone runner still works.
    if [[ "$DAEMON_ALIVE" -eq 0 ]] && command -v sr_poll_hosted_resolution >/dev/null 2>&1; then
      SR_RESUMED="$(sr_poll_hosted_resolution "${SR_BEARER:-bearer-runner-stuck}" 2>/dev/null || echo 0)"
    fi
    SR_LIFTED="$(sr_reconcile_blocked_for_human "${SR_BEARER:-bearer-runner-stuck}" 2>/dev/null || echo 0)"
    if [[ "${SR_RESUMED:-0}" != "0" || "${SR_LIFTED:-0}" != "0" ]]; then
      if [[ "$DAEMON_ALIVE" -eq 1 ]]; then
        echo "  FEEDBACK RETURN (§7.3/S-2/I4) [M4 daemon-owned]: reconciled ${SR_LIFTED:-0} blocked-for-human bead(s) — the daemon captured the answer continuously; this loop top just lifted the bead to open so the splice below resumes the agent with the decision."
      else
        echo "  FEEDBACK RETURN (§7.3/S-2/I4) [M4 fallback, daemon absent]: observed ${SR_RESUMED:-0} answered fork(s) inline; reconciled ${SR_LIFTED:-0} blocked-for-human bead(s) — a fork Brian answered on his phone is back in the ready set and will RESUME with the decision spliced in."
      fi
    fi
  fi

  # BC-50 consumer (claude-tools-yuwe): honor desired=paused at the PICKUP GATE.
  # Checked at the loop top — AFTER the feedback-return reconcile (an answered
  # fork still lifts to `open`, matching v2 where the daemon lifts continuously)
  # but BEFORE select_workable_task / lease_acquire — so a paused runner never
  # claims, never churns acquire/release, and never pops a crash-orphan off
  # ORPHANED_IDS only to drop it. Mirrors runner.sh st_reconcile (hb idle; sleep;
  # re-reconcile). PAUSED-ONLY: `stopped` is the daemon SIGTERM + the idle/skip
  # loops' job; this closes the has-workable-bead path that used to CLAIM through
  # a pause. A STOP_FILE present at the loop top (checked at :1654) still wins over
  # paused; a `.stop-beads` that arrives DURING the paused sleep is honored on the
  # next iteration's loop-top check (≤ IDLE_POLL_INTERVAL latency), matching v2's
  # st_reconcile paused arm (which likewise sleeps without a mid-sleep stop check).
  if runner_should_hold_paused; then
    if [[ "${PAUSED_NOTIFIED:-0}" != "1" ]]; then
      echo ""
      echo "Coordinator desired=paused observed — holding at idle (not claiming new work; re-check every ${IDLE_POLL_INTERVAL:-60}s)."
      PAUSED_NOTIFIED=1
    fi
    hb idle   # §4.2: actual=idle — the engine sees an idle, alive, paused runner
    sleep "${IDLE_POLL_INTERVAL:-60}"
    continue
  fi
  PAUSED_NOTIFIED=0

  # claude-tools-uxqj: select the first WORKABLE bead, skip-CONTINUE past
  # unworkable ones (no-claim label / parent w/ open children / late-blocked /
  # stray epic) — never abandon the ready set on an unworkable head and re-pick
  # it forever. SEL_RC distinguishes the two empty-selection states below.
  # (`f || rc=$?` is the set -e-safe rc capture: a bare non-zero call aborts.)
  SEL_RC=0; select_workable_task || SEL_RC=$?

  if [[ -z "$TASK_ID" ]]; then
    # UX 0.A (claude-tools-giu): runner stays alive when the queue drains —
    # honestly idle to the engine, polling for new ready work, and picks up
    # any task added afterward WITHOUT requiring an external respawn. The
    # daemon's M3 desired-state poll is still authoritative: a desired=stopped
    # OR a .stop-beads here ends the runner cleanly within the poll interval.
    # RUNNER_EXIT_ON_DRAIN=1 opts into the legacy BC-05 SCAR (drain ⇒ exit 0)
    # so conformance tests can still verify the historical exit-code contract.
    #
    # claude-tools-uxqj: exit-on-drain fires ONLY on a GENUINE drain (SEL_RC=1,
    # bd ready empty). SEL_RC=2 means the queue is NON-empty but every candidate
    # is unworkable — that is NOT a drain: exiting there would strand the
    # workable beads that arrive later, so we back off (SKIP_BACKOFF, the g20
    # hot-spin guard) and re-select. The per-candidate skip line already printed
    # during selection, so we do NOT mislabel this "No more ready tasks".
    if [[ "${SEL_RC:-1}" -eq 1 && -n "${RUNNER_EXIT_ON_DRAIN:-}" ]]; then
      echo ""
      echo "No more ready tasks."
      echo "  (RUNNER_EXIT_ON_DRAIN=1 — BC-05 legacy exit-on-drain contract)"
      hb idle
      break
    fi
    if [[ "${SEL_RC:-1}" -eq 2 ]]; then
      IDLE_POLL_SECS="${SKIP_BACKOFF:-30}"
      IDLE_MSG="Ready set is all-unworkable — idling (re-check every ${IDLE_POLL_SECS}s)."
    else
      IDLE_POLL_SECS="${IDLE_POLL_INTERVAL:-60}"
      IDLE_MSG="No more ready tasks — idling (poll every ${IDLE_POLL_SECS}s for new work)."
    fi
    if [[ "${IDLE_NOTIFIED:-0}" != "1" ]]; then
      echo ""
      echo "$IDLE_MSG"
      IDLE_NOTIFIED=1
    fi
    hb idle   # §4.2: actual=idle (the engine sees an idle, alive runner)
    while true; do
      if [[ -f "$STOP_FILE" ]]; then
        echo "Stop file detected ($STOP_FILE) — stopping gracefully."
        rm -f "$STOP_FILE"
        break 2
      fi
      # Honor desired=stopped from the Coordinator (e.g. phone toggle) within
      # the poll interval — same posture as runner.sh's idle reconcile.
      IDLE_DESIRED=$(workspace_desired_state)
      if [[ "$IDLE_DESIRED" == "stopped" ]]; then
        echo "Coordinator desired=stopped observed while idle — stopping gracefully."
        break 2
      fi
      sleep "$IDLE_POLL_SECS"
      # Re-select (NOT a raw .[0] pick) so a workable bead arriving below an
      # unworkable head is picked up, and so an all-unworkable→workable flip
      # (e.g. a child closing) is honored.
      SEL_RC=0; select_workable_task || SEL_RC=$?
      [[ -n "$TASK_ID" ]] && break
      # A GENUINE drain reached while idling (e.g. the lone unworkable head got
      # closed) must still honor the legacy exit-on-drain contract — break back
      # to the top-of-loop gate, which exits. Guarded by the env flag so the
      # production (unset) idle-on-drain path keeps polling forever as before.
      [[ "${SEL_RC:-1}" -eq 1 && -n "${RUNNER_EXIT_ON_DRAIN:-}" ]] && break
    done
    IDLE_NOTIFIED=0
    continue
  fi

  TASK_TITLE=$(echo "$TASK_JSON" | jq -r '.[0].title')
  TASK_DESC=$(echo "$TASK_JSON" | jq -r '.[0].description')
  TASK_PRIORITY=$(echo "$TASK_JSON" | jq -r '.[0].priority // 2' 2>/dev/null)
  TASK_PRIORITY=${TASK_PRIORITY:-2}

  # Read model from label (model:sonnet, model:opus), default to configured model
  TASK_MODEL=$(bd label list "$TASK_ID" --json 2>/dev/null | jq -r '.[] | select(startswith("model:")) | sub("model:"; "")' 2>/dev/null)
  TASK_MODEL=${TASK_MODEL:-$DEFAULT_MODEL}
  # Bare "opus" alias resolves to 200K — upgrade to the 1M variant.
  # (sonnet[1m] requires "extra usage" which this org has disabled, so leave sonnet alone.)
  [[ "$TASK_MODEL" == "opus" ]] && TASK_MODEL="opus[1m]"

  # claude-tools-qcoe: per-task permission mode. Opus supports `--permission-mode auto`
  # (LLM-classified auto-approval, still honors permissions.deny). Sonnet silently
  # downgrades auto→default in headless = block on first prompt = watchdog kill, so
  # non-Opus stays on the workspace PERMISSION_FLAGS (acceptEdits + allowlist).
  # FORWARD COMPAT: when Sonnet gains auto support, change `opus*)` to `opus*|sonnet*)`.
  # --yolo wins (--dangerously-skip-permissions in PERMISSION_FLAGS flows through).
  TASK_PERMISSION_FLAGS=("${PERMISSION_FLAGS[@]}")
  if [[ ${YOLO:-0} != 1 ]]; then
    case "$TASK_MODEL" in
      opus*) TASK_PERMISSION_FLAGS=(--permission-mode auto) ;;
    esac
  fi

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  $TASK_TITLE ($TASK_ID) [$TASK_MODEL]"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Defensive RE-validate (no failure counted). The PRIMARY workability gate is
  # now select_workable_task above (claude-tools-uxqj) — TASK_ID was already
  # accepted by validate_task during selection — but a task can go unworkable in
  # the window between selection and here (another agent claims it, a dep is
  # added). Re-checking catches that race; a skip falls through to the same
  # claude-tools-g20 heartbeat-idle + SKIP_BACKOFF the all-unworkable idle branch
  # uses (so a transient skip never hot-spins and still honors desired=stopped
  # for a phone toggle), then re-selects on the next loop.
  if ! validate_task "$TASK_ID"; then
    echo ""
    hb idle
    SKIP_DESIRED=$(workspace_desired_state)
    if [[ "$SKIP_DESIRED" == "stopped" ]]; then
      echo "Coordinator desired=stopped observed during validate_task skip — stopping gracefully."
      break
    fi
    sleep "${SKIP_BACKOFF:-30}"
    continue
  fi

  # Track retries — skip task after MAX_RETRIES consecutive failures
  if [[ "$TASK_ID" == "$LAST_FAILED_ID" ]]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    if [[ $FAIL_COUNT -ge $MAX_RETRIES ]]; then
      echo "  Skipping after $MAX_RETRIES failures"
      bd update "$TASK_ID" --status=open 2>/dev/null || true
      append_runner_note "$TASK_ID" "exceeded_max_retries" "-"
      record_incident "$TASK_ID" "exceeded_max_retries" "-"
      notify_user "beads-runner: max retries" "$TASK_ID — analysis task created"
      create_analysis_task "$TASK_ID" "$TASK_TITLE" "exceeded_max_retries"
      LAST_FAILED_ID=""
      FAIL_COUNT=0
      continue
    fi
  else
    LAST_FAILED_ID=""
    FAIL_COUNT=0
  fi

  # §6.1/AD2.1: acquire the GLOBAL EXCLUSIVE lease BEFORE driving the bead to
  # in_progress (the lease is consulted on EVERY pickup — this is what closes
  # BC-04). No lease ⇒ do NOT claim it: §6.2/AD2.2 DEGRADED-CLOSED — a
  # Coordinator-unreachable runner with no held still-valid lease, or the
  # BC-04 race loser, MUST NOT make a new unsynchronised claim (no
  # --status=in_progress, no run, no close). Placed AFTER validate_task /
  # the MAX_RETRIES gate so a skipped task never leaks an unreleased lease.
  if ! lease_acquire_ok "$TASK_ID"; then
    echo "  Lease unavailable for $TASK_ID — not claiming (no lease ⇒ no run)."
    sleep "${LEASE_DENY_BACKOFF:-3}"   # avoid hot-spin re-polling the same task
    continue
  fi

  # C1 (claude-tools-g98): consult the daemon's ask-capacity verdict NOW —
  # after the lease is held (so a winning runner has the bead) and before
  # the WRITE to in_progress (so a denied verdict releases the lease and
  # leaves the bead open for another env / another moment). Fail-OPEN per
  # BC-34: a daemon-unreachable verdict falls back to the local
  # la_capacity_check (which itself fails OPEN on every keychain/API error).
  #
  # C2 (claude-tools-oil): map task priority → cost-class so the spare-only
  # gate has something to bite on. UX 0.A: "Low-priority tasks run only when
  # there are spare cycles" — priority ≥ 3 (P3, P4) is low_priority; P0/P1/
  # P2 stays standard. A project that exports TASK_COST_CLASS overrides this
  # mapping wholesale (escape hatch for project-specific cost policies).
  WORKSPACE_DESIRED=$(workspace_desired_state)
  # Recompute every iteration — guarding on empty would latch the value from
  # a prior pickup (a P3 leaking low_priority onto the next P2). The startup
  # snapshot TASK_COST_CLASS_OVERRIDE preserves the project-wide escape hatch.
  if [[ -n "$TASK_COST_CLASS_OVERRIDE" ]]; then
    TASK_COST_CLASS="$TASK_COST_CLASS_OVERRIDE"
  elif [[ "${TASK_PRIORITY:-2}" -ge 3 ]]; then
    TASK_COST_CLASS="low_priority"
  else
    TASK_COST_CLASS="standard"
  fi
  # `set -e` exits on a failing command substitution inside an assignment in
  # bash 4.x+, so neutralise errexit and capture the code in one shot. CAP_RC
  # stays unset on success (defaults to 0); gets the function's return code on
  # any non-zero exit (1 = denied, 2 = daemon unreachable, anything else is a
  # bug the case-statement below will surface).
  CAP_RC=0
  CAP_REASON=$(daemon_ask_capacity "$TASK_COST_CLASS" "$WORKSPACE_DESIRED") || CAP_RC=$?
  case "$CAP_RC" in
    0) echo "  Capacity (via daemon): $TASK_COST_CLASS allowed (desired=${WORKSPACE_DESIRED:-running}, prio=${TASK_PRIORITY:-2})" ;;
    1)
      echo "  Capacity DENIED by daemon for $TASK_ID (cost=$TASK_COST_CLASS, desired=${WORKSPACE_DESIRED:-running}, prio=${TASK_PRIORITY:-2}, reason=$CAP_REASON) — releasing lease, sleeping ${CAPACITY_DENY_BACKOFF}s."
      lease_release_seam "$TASK_ID"
      sleep "$CAPACITY_DENY_BACKOFF"
      continue
      ;;
    2)
      # Daemon unreachable — fall back to the existing local heuristic.
      # la_capacity_check internally tries the daemon cache first, then the
      # direct Keychain+API path (BC-34 fail-OPEN on every error), so this
      # is the canonical "no daemon" path.
      echo "  Capacity (daemon unreachable) — falling back to local la_capacity_check for $TASK_COST_CLASS."
      if command -v la_capacity_check >/dev/null 2>&1 \
         && ! la_capacity_check "$TASK_COST_CLASS"; then
        # zfxe: la_capacity_check sets LA_CAPACITY_REASON/PCT alongside its exit
        # code — name the gate that held instead of just "DENIED".
        echo "  Capacity DENIED by local fallback for $TASK_ID (cost=$TASK_COST_CLASS, reason=${LA_CAPACITY_REASON:-unknown}, 5h=${LA_CAPACITY_PCT_5H:-?}% 7d=${LA_CAPACITY_PCT_7D:-?}%) — releasing lease, sleeping ${CAPACITY_DENY_BACKOFF}s."
        lease_release_seam "$TASK_ID"
        sleep "$CAPACITY_DENY_BACKOFF"
        continue
      fi
      ;;
  esac

  CURRENT_TASK_ID="$TASK_ID"
  # claude-tools-4a2e: we have now COMMITTED to running a worker for this bead
  # (lease held + capacity passed). Bust the bd-ready TTL cache so the NEXT loop's
  # poll (after the worker closes/fails this bead) re-queries fresh — a bead this
  # runner just closed must never be re-presented from a still-warm cache.
  ready_cache_bust
  # claude-tools-td0y: surface CURRENT_TASK_ID to hook scripts. Export so the
  # claude-p worker (and its hook subprocesses) inherit it; also write a file
  # as fallback for the case where a hook lands in a subshell that dropped
  # env. The hook reads env first, file second.
  export CURRENT_TASK_ID
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  printf '%s' "$TASK_ID" > "$LOG_DIR/current-task" 2>/dev/null || true
  bd update "$TASK_ID" --status=in_progress 2>/dev/null || true
  hb running "$TASK_ID"   # §4.2: actual=running + current_task_ref, re-registers liveness
  # gk17 / epic vvgy: emit a workspace_inventory snapshot at pickup so the
  # Board shows the freshly-claimed bead in this workspace's title rendering.
  # OPTIONAL/guarded (same posture as hb): a missing lib / failed shell-out
  # never blocks task start — the producer is best-effort.
  runner_refresh_audit_coverage   # claude-tools-mhcp.3: freshen the §9 marker the publish below reads
  command -v la_publish_workspace_inventory >/dev/null 2>&1 \
    && la_publish_workspace_inventory || true

  # ── Build prompt ─────────────────────────────────────────────────────────

  # claude-tools-43m: build the ask-brian / dossier escalation block only when
  # the workspace has opted in. Otherwise ASKBRIAN_BLOCK stays empty and the
  # heredoc collapses to the old-script prompt (task header + non-interactive
  # guardrails + homework discipline + debrief/close). The token substitution
  # mirrors the existing BEADS_ID/BEADS_TITLE/BEADS_DESC pattern below so the
  # heredoc itself stays literal-quoted.
  if [[ "${ASK_BRIAN_ENABLED:-0}" == "1" ]]; then
    read -r -d '' ASKBRIAN_BLOCK <<'ASKBRIAN_DELIM' || true
ASK-BRIAN IS A LAST RESORT, NOT A FIRST RESORT. Before you even consider calling `mcp__askbrian__ask-brian`, you MUST have done the research below. Brian is asleep and pays per-dossier; piling up his Inbox with questions you could have answered yourself by reading the codebase IS the failure mode -- not a safe default. The original design intent (Brian, 2026-05-22): "agents look through project documentation and then if it could not find an answer, pass it to the dossier agent." Internalize this.

RESEARCH CHECKLIST -- run through ALL of these before escalating:
  1. Read docs/HANDOFF.md and any docs/runbooks/*.md that names the area you are working on.
  2. Read the design docs that own the component: beads-runner/DESIGN.md, UX-DESIGN.md, INTERFACE.md, BEHAVIORAL-CONTRACT.md, and the relevant README/CLAUDE.md.
  3. `bd memories <keyword>` for prior insights; `bd show <related-bead>` for prior decisions; walk the dependency graph at depth 1.
  4. `git log --oneline -n 30 -- <relevant-paths>` for recent decisions on this area. Read the commits that look load-bearing in full.
  5. Read the code the question is actually about, end-to-end. If the question names a function/file, you must have read it.
  6. After all of the above: if a thoughtful engineer reading the same material would pick a defensible answer in 5-10 minutes -- you do the same. That is the job, not an escalation.

THINGS THAT ARE NOT FORKS (these have been over-escalated -- do not repeat):
  -- "Where should this file live?" -- look at existing convention in the workspace, pick one, file a separate bead if you want to revisit later. Not a fork.
  -- "How should this state machine handle case X?" -- read the existing state machine, find the precedent, follow it. Filing a "what should we do" question without having read the state machine first is NOT a fork; it is skipped homework.
  -- "Should we use approach A or B?" where both work and the tradeoff is small. Pick the one that matches the existing patterns in the codebase. Reversibility note in the debrief if it matters.
  -- A question already answered in CLAUDE.md, HANDOFF.md, a runbook, a design doc section, a recent commit message, or a bd memory. Always quote the source in your debrief if you used it.
  -- Anything where you have not yet run `bd show` on the related beads and `git log` on the relevant paths. Do the research first.

WHAT IS A REAL FORK (genuine ask-brian territory):
  -- An irreversible product/architecture/scope decision that genuinely has no precedent in this codebase (new component vocabulary, new external contract, breaking schema change).
  -- A spec ambiguity where guessing would risk real damage AND no design doc or prior decision covers it.
  -- A scope-or-priority call that is Brian's per the project's standing instructions (e.g., a §11 amendment, a roadmap reorder).

When you have a REAL fork after doing the research: call `mcp__askbrian__ask-brian` with a SHORT trigger and wait for the answer. The tool blocks until Brian answers, then returns the answer as a string -- act on it and continue. Multi-question is allowed: if a second fork emerges after the first answer, call again rather than burning a whole stuck cycle. Do NOT close the issue while waiting; just call the tool.

MULTI-ITEM DOSSIERS (when your `options` are actually multiple independent decisions / forks bundled into one ask): the tool returns ALL of Brian's answers in one tool_result -- a header line "Brian answered all N items in this dossier..." followed by per-item blocks "── Item k/N (item_id) ── / Ask: ... / Brian's answer: ...". Apply EVERY item's answer in this single response; do NOT re-ask any item just because you noticed only one of them in the result. Calling ask-brian a second time for an item Brian already answered piles a duplicate dossier into his Inbox and is the exact failure mode claude-tools-88e fixed.

CRUCIAL: Your `context_dump` to the dossier-builder must include the research you already did -- "I read X, Y, Z and they did not address W" is what makes the dossier rich. A thin context_dump is a strong signal you have not done the research, and the dossier-builder will refuse it. The builder is NOT a substitute for your homework; it is the polish layer on top of it.

The trigger is intentionally brief (aim for under 200 words). A fresh dossier-builder agent in its own clean context will read the bead, related code, and design docs and write the polished multi-section dossier with Mermaid + per-option consequence_blocks. Your job is to drop a seed the builder can build on, not to dump your whole context. Tool inputs:
  - question: one sentence -- the precise decision needed
  - options: [{label, blast_radius?}, ...] -- name each viable option; blast_radius is OPTIONAL, the builder fills it in from the code
  - recommendation?: your pick if you have one (the builder may revise after reading)
  - reversible?: short note on what is / isn't reversible (the builder may revise)
  - context_dump: freeform note of WHAT IS IN YOUR HEAD that the builder cannot find by reading the bead, related code, and docs itself -- an alternative you considered, a subtle constraint you discovered mid-task, why you cannot resolve this yourself. Do NOT re-explain the bead description or code the builder can read for itself.

Fallback path (only if `mcp__askbrian__ask-brian` is not registered in this session -- the MCP server is rolling out alongside this prompt): write the structured ask into the bead so the runner can route it, then stop. The runner auto-flips status=blocked from the `human` label + a recent STUCK_NEEDS_HUMAN@<epoch> note, so you only need:
  1. bd update BEADS_ID --append-notes="STUCK_NEEDS_HUMAN@$(date +%s)
     TL;DR: <one sentence>
     The ask: <the precise decision needed>
     Options: <each option and its blast radius>
     Recommendation: <your pick> -- <why>
     Reversible: <what is / isn't reversible>"
     (Run that command verbatim -- the `@$(date +%s)` is intentional: it stamps the marker with the current Unix time so the runner's stuck detector recency-bounds it and it ages out once resolved. Do NOT drop the suffix to a bare STUCK_NEEDS_HUMAN -- a bare marker re-trips the auto-flip on every re-pickup, forever.)
  2. bd label add BEADS_ID human
  3. Stop. Do NOT close the issue, do NOT pick an option yourself, do NOT keep working around it. For a real human-decision fork this IS the correct, expected outcome -- not a failure.
ASKBRIAN_DELIM
  else
    ASKBRIAN_BLOCK=""
  fi

  read -r -d '' PROMPT <<'PROMPT_DELIM' || true
You are working on beads issue BEADS_ID: "BEADS_TITLE"

Task description:
BEADS_DESC

IMPORTANT: You are running non-interactively. Do NOT use EnterPlanMode or ExitPlanMode -- there is no human to approve plans. Do NOT use AskUserQuestion -- there is no human to answer. Just execute the work directly.

ASKBRIAN_BLOCK
Follow the instructions in the task description above exactly. The description contains the full workflow for this task type.

When a step needs a long-running command -- the offline test gate (e.g. `bash beads-runner/run-tests.sh`), a build, or a deploy-verify -- follow this gate-wait discipline so you neither blind yourself to it nor stampede it:
  - Run it EXACTLY ONCE. For a pre-close gate prefer the fast `--changed` path and use the full gate only when required. NEVER relaunch a long-running command because it looks quiet -- a quiet gate is normal (some tiers run for minutes with sparse output), and silence is NOT evidence that it is wedged.
  - NEVER pipe a long-running command through a non-streaming `tail -N` (e.g. `cmd | tail -40`): `tail -N` without `-f` buffers ALL its input and emits nothing until the pipe closes, so you see zero output until the command exits and wrongly conclude it stalled. Instead watch the live stream: `cmd 2>&1 | tee /tmp/gate-BEADS_ID.log` prints output as it runs AND saves a log; or redirect it to a file (or run it with `run_in_background`) and `tail -f /tmp/gate-BEADS_ID.log` to follow that file.
  - To WAIT for it, use a non-blocking pattern the harness allows: run it with `run_in_background` (then poll for completion), or `until <done-condition>; do sleep N; done`. NEVER chain `sleep N; <cmd>` -- the harness blocks sleep-chaining and it only degrades into worse polling.

Commit-message discipline: the commit that carries your work MUST reference the FULL bead id (BEADS_ID) somewhere in its message -- the subject or the body. The close-discipline check greps `git log` for the full id; a short conventional-commit scope alone (e.g. `feat(xyz): ...`) does NOT match it and trips a false `close_without_commit` that files a spurious P1 regression bead. Put BEADS_ID in the subject (`feat(BEADS_ID): ...`) or add a footer line to the body (`Refs: BEADS_ID`). Do this in the real work commit -- do NOT lean on a separate empty "carry full bead id" commit afterward.

Before closing the issue, add a brief debrief note summarizing how it went:
  bd update BEADS_ID --append-notes="<your debrief>"
Include: what you did, any difficulties or unexpected behavior, how long things took if notable, anything you were not sure about, and any follow-up suggestions. Be honest -- this is for the human reviewing your work later.

When you have completed all steps, close the issue: bd close BEADS_ID
PROMPT_DELIM
  # ASKBRIAN_BLOCK substitution must happen BEFORE the BEADS_* substitutions
  # so that any BEADS_ID references inside the askbrian block (e.g. the bd
  # update / bd label add commands in the fallback path) also get rewritten.
  PROMPT="${PROMPT//ASKBRIAN_BLOCK/$ASKBRIAN_BLOCK}"
  PROMPT="${PROMPT//BEADS_ID/$TASK_ID}"
  PROMPT="${PROMPT//BEADS_TITLE/$TASK_TITLE}"
  PROMPT="${PROMPT//BEADS_DESC/$TASK_DESC}"

  # Append project-specific prompt instructions if configured
  if [[ -n "$PROMPT_EXTRA" ]]; then
    PROMPT="$PROMPT

$PROMPT_EXTRA"
  fi

  # ── I4 RESUME — a fork Brian answered re-enters here; splice the decision ──
  # This task was PARKED at a STUCK_NEEDS_HUMAN fork, Brian answered it on his
  # phone, the loop-top poll observed it in the hosted engine and the S-2
  # reconcile lifted the block — so it is back in `bd ready` and we are about
  # to re-dispatch it. PREPEND the captured human decision to the worker prompt
  # (highest salience — first thing the agent reads) so it ACTS on the answer
  # instead of re-hitting the same fork: this is precisely "Brian's phone
  # answer demonstrably changes what the parked agent does next" (the I4
  # acceptance). Also mirror the decision into the bead notes (beside the
  # agent's own structured ask) so the resume is durable + auditable outside
  # the prompt. One-shot: consumed after splicing so a later unrelated pickup
  # never re-injects a stale decision. Guarded-optional like every sr_* call.
  # claude-tools-43m: I4 splice is unreachable in opted-out workspaces (no
  # dossier was ever created, so no answer can ever be staged). Gate explicitly
  # to make the contract obvious to a reader.
  if [[ "${ASK_BRIAN_ENABLED:-0}" == "1" ]] \
     && command -v sr_resume_answer >/dev/null 2>&1 \
     && sr_resume_answer "$TASK_ID" >/dev/null 2>&1; then
    : "${CO_STORE:=$LOG_DIR/.co-store}"; export CO_STORE
    SR_DIRECTIVE="$(sr_format_resume_directive "$TASK_ID" 2>/dev/null || true)"
    if [[ -n "$SR_DIRECTIVE" ]]; then
      PROMPT="$SR_DIRECTIVE

$PROMPT"
      if command -v bd >/dev/null 2>&1; then
        bd update "$TASK_ID" --append-notes="HUMAN_DECISION (I4 resume — Brian answered the dossier on his phone): $(printf '%s' "$SR_DIRECTIVE" | tr '\n' ' ' | cut -c1-700)" >/dev/null 2>&1 || true
      fi
      echo "  RESUME (§7.3/S-2/I4): $TASK_TITLE — Brian's phone answer spliced into the worker prompt; the agent now acts on the human's decision, not the fork."
    fi
    sr_consume_resume_answer "$TASK_ID" 2>/dev/null || true
  fi

  # ── Run claude session ───────────────────────────────────────────────────

  # Per-iteration timestamp drives artifact filenames so retries don't collide.
  ITER_TS=$(date -u +%Y%m%dT%H%M%SZ)
  LOG_BASE="$TASK_ID-$ITER_TS"
  PROC_SNAPSHOT="$LOG_DIR/$LOG_BASE.proc.txt"

  STREAM_FILE=$(mktemp)

  # claude-tools-td0y: POST_TERMINAL_FILE records the epoch at which the SDK
  # emitted its terminal record. Set by the stream parser below; read by the
  # watchdog to SIGKILL claude POST_TERMINAL_GRACE seconds later if still
  # alive. Per-task file (under LOG_DIR with task id in name) so a leak from
  # a killed iteration is cleanable on the next loop top.
  POST_TERMINAL_FILE="$LOG_DIR/$LOG_BASE.post-terminal"
  rm -f "$POST_TERMINAL_FILE" 2>/dev/null || true

  # claude-tools-td0y: wire the close-discipline hook (Stop + PreToolUse on
  # `bd close|done|--status=closed`) via runner-injected --settings. The hook
  # itself lives in this repo under beads-runner/hooks/close-checklist.sh and
  # is versioned with the runner. Per-task file in LOG_DIR (cleanable). The
  # BEADS_RUNNER_SESSION=1 env var gates the hook so interactive claude
  # sessions in the same workspace are unaffected even if they happen to
  # load the same --settings file.
  HOOK_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/hooks/close-checklist.sh"
  HOOK_SETTINGS_FILE="$LOG_DIR/$LOG_BASE.hook-settings.json"
  HOOK_SETTINGS_FLAGS=()
  if [[ -x "$HOOK_SCRIPT" ]]; then
    # claude-tools-2fkp: the JSON shape now lives in the shared
    # hooks/build-settings.sh (sourced above) so v1 and v2 stay byte-identical.
    # Same degrade as before: no jq / write-failure / absent builder ⇒ NO
    # --settings (the worker still runs, just without the hook).
    if command -v build_hook_settings >/dev/null 2>&1; then
      build_hook_settings "$HOOK_SCRIPT" "$HOOK_SETTINGS_FILE" \
        && HOOK_SETTINGS_FLAGS=(--settings "$HOOK_SETTINGS_FILE")
    fi
  else
    echo "  WARN: close-discipline hook not executable at $HOOK_SCRIPT — running WITHOUT hook enforcement (claude-tools-td0y)." >&2
  fi

  BEADS_RUNNER_SESSION=1 \
  POST_TERMINAL_FILE="$POST_TERMINAL_FILE" \
  claude -p "$PROMPT" \
    --output-format stream-json \
    --verbose \
    --model "$TASK_MODEL" \
    "${GUARDRAIL_FLAGS[@]+"${GUARDRAIL_FLAGS[@]}"}" \
    "${EXTRA_CLAUDE_FLAGS[@]+"${EXTRA_CLAUDE_FLAGS[@]}"}" \
    "${TASK_PERMISSION_FLAGS[@]+"${TASK_PERMISSION_FLAGS[@]}"}" \
    "${HOOK_SETTINGS_FLAGS[@]+"${HOOK_SETTINGS_FLAGS[@]}"}" \
    > "$STREAM_FILE" 2>&1 &
  CLAUDE_PID=$!

  # ── Stream parser ────────────────────────────────────────────────────────

  ACTIVITY_FILE=$(mktemp)
  SIGNAL_FILE=$(mktemp)
  # claude-tools-idg: TASK_INFLIGHT_FILE holds one task_id per line for each
  # Task subagent currently in-flight. Maintained by the stream parser below;
  # read by the watchdog to stretch IDLE_TIMEOUT instead of false-positive kill.
  TASK_INFLIGHT_FILE=$(mktemp)
  date +%s > "$ACTIVITY_FILE"

  # claude-tools-yva: spawn TAIL parser in its own process group via job
  # control (`set -m`). PGID == TAIL_PID. On reap we send `kill -- -$TAIL_PID`
  # which reaches every descendant (tail -f, jq, ...) — including any that
  # have been reparented to PID 1 between subshell-loop iterations. Without
  # `set -m`, the subshell shares the runner's PGID, so a PG-wide kill would
  # nuke the runner itself; pid-only kill leaves reparented grandchildren.
  set -m
  (
    tail -f "$STREAM_FILE" 2>/dev/null | while IFS= read -r line; do
      TS=$(date +%H:%M:%S)
      date +%s > "$ACTIVITY_FILE"
      # claude-tools-td0y: detect SDK terminal record. The new SDK emits a
      # JSON line containing "terminal_reason" (observed in the krxv wedge);
      # the older format is `type":"result"` (already handled in the case
      # below). Either marker stamps POST_TERMINAL_FILE — the watchdog reads
      # it to SIGKILL claude POST_TERMINAL_GRACE seconds later if Node
      # refuses to exit (orphan child wedge). Idempotent: stamp once per
      # session; only write if file doesn't exist so a second result line
      # doesn't reset the grace clock. Cheap substring match (no jq per
      # line; the parser hot loop is already jq-heavy).
      if [[ -n "${POST_TERMINAL_FILE:-}" && ! -e "$POST_TERMINAL_FILE" ]]; then
        case "$line" in
          *'"terminal_reason"'*|*'"type":"result"'*)
            date +%s > "$POST_TERMINAL_FILE" 2>/dev/null || true
            echo "  [$TS] SDK terminal record detected — watchdog will SIGKILL claude in ${POST_TERMINAL_GRACE:-60}s if still alive (claude-tools-td0y)"
            ;;
        esac
      fi
      TYPE=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
      case "$TYPE" in
        assistant)
          MSG=$(echo "$line" | jq -r '.message // empty' 2>/dev/null)
          [[ -n "$MSG" ]] && echo "  [$TS] $MSG"
          ;;
        tool_use)
          TOOL=$(echo "$line" | jq -r '.tool // empty' 2>/dev/null)
          [[ -n "$TOOL" ]] && echo "  [$TS] -> $TOOL"
          ;;
        system)
          SUBTYPE=$(echo "$line" | jq -r '.subtype // empty' 2>/dev/null)
          if [[ "$SUBTYPE" == "api_retry" ]]; then
            ERROR=$(echo "$line" | jq -r '.error // empty' 2>/dev/null)
            ERROR_STATUS=$(echo "$line" | jq -r '.error_status // empty' 2>/dev/null)
            ATTEMPT=$(echo "$line" | jq -r '.attempt // empty' 2>/dev/null)
            MAX_R=$(echo "$line" | jq -r '.max_retries // empty' 2>/dev/null)
            echo "  [$TS] API retry ($ATTEMPT/$MAX_R): $ERROR (status: $ERROR_STATUS)"
            case "$ERROR" in
              rate_limit)           echo "RATE_LIMIT=${ERROR_STATUS:-429}" >> "$SIGNAL_FILE" ;;
              authentication_failed) echo "AUTH_FAILURE=${ERROR_STATUS:-401}" >> "$SIGNAL_FILE" ;;
              billing_error)        echo "BILLING_ERROR=1" >> "$SIGNAL_FILE" ;;
              server_error)         echo "SERVER_ERROR=${ERROR_STATUS:-500}" >> "$SIGNAL_FILE" ;;
              max_output_tokens)    echo "MAX_OUTPUT_TOKENS=1" >> "$SIGNAL_FILE" ;;
            esac
          elif [[ "$SUBTYPE" == "task_notification" || "$SUBTYPE" == "task_updated" ]]; then
            # claude-tools-idg: track Task subagent lifecycle to inform the
            # watchdog. status comes top-level (task_notification) or nested
            # under patch (task_updated); we read both.
            TASK_ID=$(echo "$line" | jq -r '.task_id // empty' 2>/dev/null)
            TASK_STATUS=$(echo "$line" | jq -r '.status // .patch.status // empty' 2>/dev/null)
            echo "  [$TS] [system:$SUBTYPE] task_id=$TASK_ID status=$TASK_STATUS"
            if [[ -n "$TASK_ID" ]]; then
              case "$TASK_STATUS" in
                in_progress)
                  grep -qxF "$TASK_ID" "$TASK_INFLIGHT_FILE" 2>/dev/null || \
                    echo "$TASK_ID" >> "$TASK_INFLIGHT_FILE"
                  ;;
                completed|stopped|killed|failed|cancelled)
                  if [[ -f "$TASK_INFLIGHT_FILE" ]]; then
                    grep -vxF "$TASK_ID" "$TASK_INFLIGHT_FILE" > "${TASK_INFLIGHT_FILE}.tmp" 2>/dev/null \
                      && mv "${TASK_INFLIGHT_FILE}.tmp" "$TASK_INFLIGHT_FILE"
                  fi
                  ;;
              esac
            fi
          else
            echo "  [$TS] [system:$SUBTYPE] $(echo "$line" | jq -c '.' 2>/dev/null)"
          fi
          ;;
        result)
          RESULT=$(echo "$line" | jq -r '.result // empty' 2>/dev/null)
          IS_ERROR=$(echo "$line" | jq -r '.is_error // false' 2>/dev/null)
          STOP_REASON=$(echo "$line" | jq -r '.stop_reason // empty' 2>/dev/null)
          [[ -n "$RESULT" ]] && echo "  [$TS] $RESULT"
          echo "RESULT_IS_ERROR=$IS_ERROR" >> "$SIGNAL_FILE"
          [[ -n "$STOP_REASON" ]] && echo "RESULT_STOP_REASON=$STOP_REASON" >> "$SIGNAL_FILE"
          # Context overflow ("Prompt is too long") arrives as an errored result
          # with stop_reason=stop_sequence — it does NOT match the max_tokens /
          # length stop reasons, so without this it falls through to
          # UNKNOWN_FAILURE and gets pointlessly retried (each retry re-overflows
          # at the same point). Pattern-matched on the result text; the API 400
          # surfaces as "Prompt is too long", context_length_exceeded is a
          # defensive secondary. is_error guard avoids matching a normal summary.
          if [[ "$IS_ERROR" == "true" ]] && \
             echo "$RESULT" | grep -qiE 'prompt is too long|context_length_exceeded' 2>/dev/null; then
            echo "CONTEXT_OVERFLOW=1" >> "$SIGNAL_FILE"
          fi
          ;;
        "")
          ;;
        rate_limit_event)
          # claude-tools-t5k: rate_limit_event is Claude-Code SUBSCRIPTION window
          # metadata (5h / 7d quota snapshots), NOT a 429 throttle. The real 429
          # path is system.api_retry.error=rate_limit above. Surface allowed_warning
          # loudly so seven_day quota approaches are visible; collapse 'allowed' to
          # one terse line; reserve RATE_LIMIT_QUOTA signal for rejected/exceeded
          # (never observed today — forward-compat).
          RL_STATUS=$(echo "$line" | jq -r '.rate_limit_info.status // empty' 2>/dev/null)
          RL_TYPE=$(echo "$line" | jq -r '.rate_limit_info.rateLimitType // empty' 2>/dev/null)
          RL_RESETS=$(echo "$line" | jq -r 'try (.rate_limit_info.resetsAt | todateiso8601) catch ""' 2>/dev/null)
          case "$RL_STATUS" in
            allowed_warning)
              RL_UTIL=$(echo "$line" | jq -r '.rate_limit_info.utilization // empty' 2>/dev/null)
              RL_THR=$(echo "$line" | jq -r '.rate_limit_info.surpassedThreshold // empty' 2>/dev/null)
              echo "  [$TS] [rate_limit:WARN] $RL_TYPE utilization=$RL_UTIL (>=$RL_THR) resetsAt=$RL_RESETS"
              ;;
            allowed)
              echo "  [$TS] [rate_limit] $RL_TYPE ok resetsAt=$RL_RESETS"
              ;;
            rejected|exceeded)
              echo "  [$TS] [rate_limit:QUOTA] $RL_TYPE status=$RL_STATUS resetsAt=$RL_RESETS"
              echo "RATE_LIMIT_QUOTA=$RL_TYPE" >> "$SIGNAL_FILE"
              ;;
            *)
              echo "  [$TS] [rate_limit_event] status=$RL_STATUS $RL_TYPE resetsAt=$RL_RESETS"
              ;;
          esac
          ;;
        *)
          echo "  [$TS] [$TYPE] $(echo "$line" | jq -c '.' 2>/dev/null)"
          ;;
      esac
    done
  ) &
  TAIL_PID=$!
  set +m

  # ── Watchdog ─────────────────────────────────────────────────────────────

  # claude-tools-yva: same PG-isolation trick for the watchdog. The watchdog
  # is the more common leak path because its `sleep 15` regularly outlives a
  # single iteration of the `while` loop — and a subshell `break` can happen
  # between the `sleep` spawn and the next iteration check, leaving an orphan
  # sleep that pid-only `pkill -P` cannot find.
  set -m
  (
    # claude-tools-t7i: defense in depth so the watchdog can't outlive its
    # claude child. Three guards: (a) re-check `kill -0 $CLAUDE_PID` immediately
    # after sleep (the `while` check alone only fires at the next iteration,
    # and a PID-recycle race after the parent reaps the zombie could otherwise
    # keep the loop ticking against a freshly-reassigned PID); (b) honor
    # `.stop-beads` from inside the loop so a graceful stop kills the watchdog
    # within one tick; (c) the parent's reap below escalates to SIGKILL +
    # pkill -P, so a watchdog mid-sleep cannot block the runner.
    while kill -0 "$CLAUDE_PID" 2>/dev/null; do
      sleep 15
      kill -0 "$CLAUDE_PID" 2>/dev/null || break
      [[ -f "$STOP_FILE" ]] && break
      # claude-tools-td0y: post-terminal SIGKILL backstop. If the stream parser
      # observed the SDK terminal record (POST_TERMINAL_FILE stamped) and
      # claude is STILL alive POST_TERMINAL_GRACE seconds later, Node is
      # wedged on an orphan child (the krxv pattern: a run_in_background:true
      # poller keeps the event loop alive long past terminal_reason). The
      # hook layer is supposed to prevent this, but if it fails for any
      # reason (8-block cap, agent bypass, hook crash, schema drift) this
      # is the reliable fallback. Independent of IDLE_TIMEOUT; cannot be
      # masked by IDLE_TIMEOUT_INFLIGHT_MULT.
      if [[ -n "${POST_TERMINAL_FILE:-}" && -f "$POST_TERMINAL_FILE" ]]; then
        PT_AT=$(cat "$POST_TERMINAL_FILE" 2>/dev/null | tr -d '[:space:]')
        if [[ "$PT_AT" =~ ^[0-9]+$ ]] && (( PT_AT >= 1704067200 )); then
          PT_AGE=$(( $(date +%s) - PT_AT ))
          if (( PT_AGE >= POST_TERMINAL_GRACE )); then
            echo "  POST-TERMINAL SIGKILL: SDK terminal record was ${PT_AGE}s ago (grace=${POST_TERMINAL_GRACE}s); claude pid=$CLAUDE_PID still alive — likely orphan child wedge (claude-tools-td0y)."
            echo "POST_TERMINAL_KILL=1" >> "$SIGNAL_FILE"
            { echo "=== post-terminal snapshot (age=${PT_AGE}s, grace=${POST_TERMINAL_GRACE}s) ==="
              ps -o pid,stat,etime,pcpu,pmem,command -p "$CLAUDE_PID" 2>&1 || true
              echo ""
              echo "=== children of claude ($CLAUDE_PID) ==="
              pgrep -P "$CLAUDE_PID" 2>/dev/null | xargs -I{} ps -o pid,etime,command -p {} 2>/dev/null || true
            } >> "$PROC_SNAPSHOT" 2>&1 || true
            kill -KILL "$CLAUDE_PID" 2>/dev/null || true
            break
          fi
        fi
      fi
      if [[ -f "$ACTIVITY_FILE" ]]; then
        LAST=$(cat "$ACTIVITY_FILE" 2>/dev/null | tr -d '[:space:]')
        # claude-tools-h7n: sanity-guard LAST before the IDLE arithmetic. An
        # empty or malformed read (parser hasn't written yet, or a partial
        # write raced our cat) would otherwise make bash treat LAST as 0 —
        # IDLE then becomes NOW (the current epoch, ~1.78e9s = 56yr), which
        # is always ≥ any sane EFFECTIVE_TIMEOUT and triggers an instant
        # false-positive kill. Floor 1704067200 = 2024-01-01; any real write
        # from this runner is well above it.
        if [[ ! "$LAST" =~ ^[0-9]+$ ]] || (( LAST < 1704067200 )); then
          continue
        fi
        NOW=$(date +%s)
        IDLE=$((NOW - LAST))
        # claude-tools-idg: stretch (don't pause) the kill threshold while a
        # Task subagent is in-flight. The parser maintains TASK_INFLIGHT_FILE
        # from task_notification/task_updated stream events; the kill backstop
        # is preserved (a genuinely-deadlocked bg-Bash that registered as
        # in-flight still dies eventually) just at IDLE_TIMEOUT × MULT.
        INFLIGHT=0
        if [[ -f "$TASK_INFLIGHT_FILE" ]]; then
          INFLIGHT=$(wc -l < "$TASK_INFLIGHT_FILE" 2>/dev/null | tr -d ' ')
          INFLIGHT=${INFLIGHT:-0}
        fi
        if [[ "$INFLIGHT" -gt 0 ]]; then
          EFFECTIVE_TIMEOUT=$(( IDLE_TIMEOUT * IDLE_TIMEOUT_INFLIGHT_MULT ))
        else
          EFFECTIVE_TIMEOUT=$IDLE_TIMEOUT
        fi
        if [[ $IDLE -ge $EFFECTIVE_TIMEOUT ]]; then
          echo "  Killing after ${IDLE}s idle — likely stuck (in-flight subagents=$INFLIGHT, threshold=${EFFECTIVE_TIMEOUT}s)"
          echo "WATCHDOG_KILL=1" >> "$SIGNAL_FILE"

          # Snapshot the stuck process before signalling: ps for state/CPU/mem,
          # lsof for open sockets/pipes (tells us network-blocked vs CPU-bound
          # vs child-pipe-blocked). Must run BEFORE SIGINT — lsof on a dying
          # process returns nothing useful.
          {
            echo "=== ps (idle ${IDLE}s, IDLE_TIMEOUT=${IDLE_TIMEOUT}, inflight_subagents=${INFLIGHT}, effective_threshold=${EFFECTIVE_TIMEOUT}s) ==="
            ps -o pid,stat,etime,pcpu,pmem,command -p "$CLAUDE_PID" 2>&1 || true
            echo ""
            echo "=== lsof (TCP/IPv/PIPE) ==="
            lsof -p "$CLAUDE_PID" 2>/dev/null | grep -E 'TCP|IPv|PIPE' || echo "(no matching fds)"
          } > "$PROC_SNAPSHOT" 2>&1 || true

          # Staged kill: SIGINT first to give the SDK a chance to flush in-flight
          # HTTP retry state to stderr (which is merged into STREAM_FILE), then
          # SIGKILL after 10s if still alive.
          kill -INT "$CLAUDE_PID" 2>/dev/null || true
          for _ in 1 2 3 4 5 6 7 8 9 10; do
            sleep 1
            kill -0 "$CLAUDE_PID" 2>/dev/null || break
          done
          kill -0 "$CLAUDE_PID" 2>/dev/null && kill -KILL "$CLAUDE_PID" 2>/dev/null || true
          break
        elif [[ $IDLE -ge 180 ]]; then
          echo "  No activity for ${IDLE}s — possibly stuck"
        fi
      fi
    done
  ) &
  WATCHDOG_PID=$!
  set +m

  # ── Mid-task heartbeat (claude-tools-7v5) ────────────────────────────────
  # The hb() function is otherwise only called at state transitions
  # (start/finish/idle), so a task longer than STALE_AFTER=180s makes the
  # Board render the workspace as liveness=stale even though the worker is
  # actively processing. This subshell emits hb running "$TASK_ID" every
  # HEARTBEAT_INTERVAL (60s) while the task is in flight, gated on stream
  # progress so a genuinely-stuck worker still goes stale honestly:
  #   Mode A (normal): emit only if ACTIVITY_FILE was updated within
  #     HEARTBEAT_GAP_TOL (90s). 90s comfortably exceeds measured p95 stream
  #     gaps (11–22s across three workspaces) but is well under STALE_AFTER.
  #   Mode B (subagent): if TASK_INFLIGHT_FILE has ≥1 line, emit
  #     unconditionally — mirrors the watchdog's idg trust in the same signal.
  # Same set -m / kill -- -$HB_PID PG-isolation pattern as TAIL/WATCHDOG
  # (claude-tools-yva) so sleep grandchildren can't outlive the parent.
  set -m
  (
    HB_INTERVAL=${HEARTBEAT_INTERVAL:-60}
    HB_GAP_TOL=${HEARTBEAT_GAP_TOL:-90}
    while kill -0 "$CLAUDE_PID" 2>/dev/null; do
      sleep "$HB_INTERVAL"
      kill -0 "$CLAUDE_PID" 2>/dev/null || break
      [[ -f "$STOP_FILE" ]] && break
      INFLIGHT=0
      if [[ -f "$TASK_INFLIGHT_FILE" ]]; then
        INFLIGHT=$(wc -l < "$TASK_INFLIGHT_FILE" 2>/dev/null | tr -d ' ')
        INFLIGHT=${INFLIGHT:-0}
      fi
      if [[ "$INFLIGHT" -gt 0 ]]; then
        hb running "$TASK_ID"
        continue
      fi
      if [[ -f "$ACTIVITY_FILE" ]]; then
        LAST=$(cat "$ACTIVITY_FILE" 2>/dev/null | tr -d '[:space:]')
        # Mirror watchdog h7n guard: reject empty/malformed/pre-2024 epochs
        # so a partial write or empty read can't produce a giant GAP that
        # silently suppresses the heartbeat forever.
        if [[ "$LAST" =~ ^[0-9]+$ ]] && (( LAST >= 1704067200 )); then
          NOW=$(date +%s)
          GAP=$((NOW - LAST))
          if (( GAP <= HB_GAP_TOL )); then
            hb running "$TASK_ID"
          fi
        fi
      fi
    done
  ) &
  HB_PID=$!
  set +m

  # ── Wait for result and classify ─────────────────────────────────────────

  wait "$CLAUDE_PID" 2>/dev/null && CLAUDE_EXIT=0 || CLAUDE_EXIT=$?
  sleep 1
  # claude-tools-yva: PG-targeted reap. The subshells were spawned with
  # `set -m` so each has its own process group (PGID == leader PID). Signalling
  # the negative PID (`kill -- -PID`) reaches the leader AND every descendant
  # in that PG — including `sleep` / `tail -f` grandchildren that the t7i
  # pid-based reap missed when the subshell's loop exited between iterations
  # and the grandchild got reparented to PID 1. PG membership survives both
  # reparenting and leader reap, so this remains correct mid-race.
  #
  # Layered: TERM the PG, 2s grace, KILL the PG if anything is left, then a
  # pid-only fallback in case PG isolation failed (set -m no-op'd for any
  # reason). `wait` only after kill confirmation so we never block.
  # claude-tools-7v5: reap the HB subshell BEFORE the watchdog so the order
  # mirrors spawn (parser, watchdog, HB → HB, watchdog, parser on the reap).
  kill -TERM -- "-$HB_PID" 2>/dev/null || kill -TERM "$HB_PID" 2>/dev/null || true
  for _ in 1 2; do
    kill -0 "$HB_PID" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$HB_PID" 2>/dev/null; then
    kill -KILL -- "-$HB_PID" 2>/dev/null || true
    kill -KILL "$HB_PID" 2>/dev/null || true
  fi
  wait "$HB_PID" 2>/dev/null || true
  kill -TERM -- "-$WATCHDOG_PID" 2>/dev/null || kill -TERM "$WATCHDOG_PID" 2>/dev/null || true
  for _ in 1 2; do
    kill -0 "$WATCHDOG_PID" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$WATCHDOG_PID" 2>/dev/null; then
    kill -KILL -- "-$WATCHDOG_PID" 2>/dev/null || true
    kill -KILL "$WATCHDOG_PID" 2>/dev/null || true
  fi
  kill -TERM -- "-$TAIL_PID" 2>/dev/null || kill -TERM "$TAIL_PID" 2>/dev/null || true
  # Brief grace, then KILL the PG to ensure tail -f / jq descendants exit even
  # if the subshell leader already died and the PG is grandchild-only.
  sleep 1
  kill -KILL -- "-$TAIL_PID" 2>/dev/null || true
  kill -KILL "$TAIL_PID" 2>/dev/null || true
  wait "$TAIL_PID" 2>/dev/null || true
  wait "$WATCHDOG_PID" 2>/dev/null || true
  echo ""

  # ── wrong-Node crash detector (LOUD, never silent) — claude-tools-4tj ────
  # Backstop behind the path-prime above. The detection regex/scan body lives
  # in node25_check_wrong_node_crash (lib/node25-prime.sh, shared with the
  # other two callers); here we own the runner-scoped surface: a TASK_ID-
  # attributed stderr block, an INCIDENTS entry that surfaces in the end-of-
  # run summary, and a sticky line in wrong-node-crash.log. $CLAUDE_EXIT is
  # NOT mutated — downstream classification still runs.
  if [[ "$CLAUDE_EXIT" -ne 0 ]] && declare -F node25_check_wrong_node_crash >/dev/null; then
    if _node_seen="$(node25_check_wrong_node_crash "$STREAM_FILE")"; then
      {
        printf '  WRONG-NODE CRASH — claude CLI crashed at startup.\n'
        printf '    detected: %s (the claude CLI is incompatible with Node v25+; see claude-tools-4tj / claude-tools-3kd)\n' "${_node_seen:-<unknown>}"
        printf '    stream:   %s\n' "$STREAM_FILE"
        printf '    fix:      ensure $NVM_DIR/versions/node/<lts>/bin is first in PATH for the launching process.\n'
        printf '              run-beads-tasks.sh already prepends nvm bin when node --version is v25+; the wrong-Node\n'
        printf '              detection firing means even that prepend did not resolve the right binary.\n'
      } >&2
      {
        printf '%s\t%s\twrong_node_crash\t%s\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")" \
          "$TASK_ID" "${_node_seen:-unknown}"
      } >> "$LOG_DIR/wrong-node-crash.log" 2>/dev/null || true
      INCIDENTS+=("$(date -u +%Y-%m-%dT%H:%M:%SZ)	$TASK_ID	WRONG_NODE_CRASH:${_node_seen:-unknown}	$STREAM_FILE")
    fi
  fi

  CLASSIFICATION=$(classify_failure "$SIGNAL_FILE" "$TASK_ID" "$CLAUDE_EXIT")

  # ── §7.1/§7.2/§7.3 STUCK_NEEDS_HUMAN — the deliberate PRIMARY *and* the
  #    zero-trust BACKSTOP both drive ONE bead+dossier+notification (T5.5) ─────
  # §7.2 defines TWO independent triggers for the SAME §7.3 outcome; the runner
  # must honor BOTH or a compliant agent's genuine stuck never reaches the
  # spine (claude-tools-wwl; the I5 prerequisite):
  #   • PRIMARY (worker-driven, instructed — AD3.1; research Q4): I3's genuine
  #     dogfood + research/headless-stuck-signal.md, confirmed — a capable
  #     headless worker does NOT slip the §7.6 guardrail; it OBEYS and, on a
  #     real human-decision fork, takes the INSTRUCTED deterministic bd path
  #     the prompt now mandates. It then ends its turn ⇒ `claude -p` exit 0 ⇒
  #     classify_failure = TASK_NOT_CLOSED; §7.1 mandates STUCK_NEEDS_HUMAN
  #     PREEMPT that exit-0 "agent forgot to close" masking. Detected from the
  #     bead state the worker deterministically produced (zero model trust).
  #   • BACKSTOP (runner-side, zero model trust — AD3.3): the by-design RARE
  #     slip (result.permission_denials[AskUserQuestion|ExitPlanMode] OR an
  #     "Entered plan mode." residual), overriding the false exit-0 success.
  # Either ⇒ the SAME §7.3 drive + §7.4 task_ref-keyed ONE Dossier + the §4.3
  # Notification spine (sr_route_stuck → dg → do_dossier_put → no_emit). §7.1
  # precedence: the two FLEET-FATAL classes (AUTH_FAILURE, BILLING_ERROR — "the
  # runner is dead, only you can fix") still outrank STUCK and fall through to
  # the dispatch; STUCK preempts every per-task class and TASK_NOT_CLOSED.
  # classify_failure (§7.1 marker chain) is byte-untouched — this is the §7.3
  # cross-tier OUTCOME guard, NOT a new classification arm; NO §7.5 breaker/
  # retry counter advances (STUCK is not a failure: block the bead, move on).
  # Guarded-optional like the §8.2 la_* calls (absent libs ⇒ runner unchanged).
  SR_STUCK_HANDLED=""
  SR_TRIGGER=""
  SR_REASON=""
  # claude-tools-43m: in opted-out workspaces the §7.3 backstop must NOT fire.
  # The backstop synthesizes its own dossier from worker permission_denials
  # (any disallowed-tool slip — AskUserQuestion / ExitPlanMode / EnterPlanMode)
  # via sr_route_stuck → dg_from_worker_ask → do_dossier_put, completely
  # bypassing whether the worker prompt even mentions ask-brian. Gating only
  # the prompt would leave dossiers leaking into the Inbox from any worker
  # permission denial. With this gate, a permission denial in an opted-out
  # workspace falls through to classify_failure (TASK_NOT_CLOSED / retry /
  # MAX_CONSECUTIVE_FAILURES) — exactly the old-script behavior.
  if [[ "${ASK_BRIAN_ENABLED:-0}" == "1" ]] \
     && [[ "$CLASSIFICATION" != "AUTH_FAILURE" && "$CLASSIFICATION" != "BILLING_ERROR" ]] \
     && command -v sr_route_stuck >/dev/null 2>&1 && command -v sr_scan_backstop >/dev/null 2>&1; then
    SR_BACKSTOP="$(sr_scan_backstop "$STREAM_FILE" 2>/dev/null || true)"
    SR_PRIMARY="$(detect_worker_stuck_primary "$TASK_ID" "$CLAUDE_EXIT" 2>/dev/null || true)"
    # Provenance: the deliberate PRIMARY is the §7.2 worker-driven signal
    # (dossier .trigger = "worker_stuck", the genuine §7.2 fork the deployed
    # Inbox reads); a bare slip is "backstop:<which>". If BOTH fire on the same
    # fork the deliberate path wins provenance; §7.4 task_ref dedup collapses
    # them to ONE dossier regardless of which trigger arrived first.
    if [[ -n "$SR_PRIMARY" ]]; then
      SR_TRIGGER="worker_stuck"
      SR_REASON="PRIMARY worker-driven (§7.2 deliberate bd-signal — compliant agent)"
    elif [[ -n "$SR_BACKSTOP" ]]; then
      SR_TRIGGER="backstop:$SR_BACKSTOP"
      SR_REASON="BACKSTOP fired ($SR_BACKSTOP) (§7.2 zero-trust slip)"
    fi
    if [[ -n "$SR_TRIGGER" ]]; then
      : "${CO_STORE:=$LOG_DIR/.co-store}"; export CO_STORE
      # claude-tools-69u8: the dossier-builder bridge is now wired ONCE at the
      # dg__author chokepoint (DG_AUTHOR_AUTOWIRE, set at runner startup) — this
      # §7.3 backstop no longer self-exports DG_AUTHOR_CMD. sr_route_stuck →
      # dg_from_worker_ask → dg__author authors via the real agent (claude
      # reachable) or the labeled-degraded jq path (absent). (was 5me's
      # per-call-site wiring.)
      # §7.4: capture the dedup'd dossier id sr_route_stuck echoes (one fork ⇒
      # ONE id; idempotent on a re-trigger — PRIMARY+BACKSTOP on the same fork
      # collapse here). stderr stays suppressed.
      SR_DID="$(
        sr_route_stuck "${SR_BEARER:-bearer-runner-stuck}" "$TASK_ID" \
          "$SR_TRIGGER" "$(sr_worker_ask "$TASK_ID" 2>/dev/null || true)" \
          2>/dev/null || true
      )"
      # §4.3/C3 — the SINGLE Notification for that dossier MUST exist at
      # creation, BEFORE any send. I3 wires the emit here (the disconnection:
      # the dossier reached the hosted engine with no notification). no_emit
      # is one-per-Dossier idempotent (safe on the §7.4 re-trigger), reads the
      # just-persisted §4.1 tier, and persists via co_request (→ the HOSTED
      # engine when COORDINATOR_URL is set — I1). Best-effort + LOUD-on-fail,
      # NEVER blocking the §7.3 bead drive (the fork must not rot on a notify
      # hiccup — the C3 RESIDUAL discipline; no_emit retry is safe).
      if command -v no_emit >/dev/null 2>&1 && [[ -n "$SR_DID" ]]; then
        if ! no_emit "${SR_BEARER:-bearer-runner-stuck}" "$SR_DID" >/dev/null 2>&1; then
          echo "  STUCK_NEEDS_HUMAN: WARN dossier '$SR_DID' persisted but the §4.3 no_emit FAILED — a dossier with NO Notification (C3 'row exists at creation' unmet). Observable, not silent; no_emit is idempotent so a later T5.5/operator re-emit is safe."
        fi
      fi
      append_runner_note "$TASK_ID" "STUCK_NEEDS_HUMAN" "-"
      record_incident   "$TASK_ID" "STUCK_NEEDS_HUMAN" "-"
      if command -v la_report_terminal_reason >/dev/null 2>&1; then
        la_report_terminal_reason STUCK_NEEDS_HUMAN "" "$TASK_ID" "${PROJECT_REF:-}" || true
      fi
      SR_STUCK_HANDLED=1
    fi
  fi

  # ── claude-tools-1vnx: un-thrashable human-decision fork (belt-and-suspenders) ─
  # The §7.3 preempt above is the PRIMARY honor-the-fork path (it also authors the
  # §7.4 dossier + §4.3 notification). But it is gated on ASK_BRIAN_ENABLED + the
  # stuck-routing lib AND leans on detect_worker_stuck_primary's bd read — the exact
  # fragility that let claude-tools-m3xi thrash: a flaky/late read missed a genuine
  # status=blocked + `human` at exit, so the bead fell to the TASK_NOT_CLOSED arm,
  # was reset --status=open, and on retry spawned an analysis child whose close
  # re-armed the bead (re-pick → re-block → re-misclassify), burning an Opus
  # analysis task every cycle. This OUTCOME guard closes that loop INDEPENDENTLY of
  # the preempt: a bead the worker DELIBERATELY left blocked + `human` is a decision
  # the runner must never silently undo. _bead_blocked_for_human reads the sticky
  # LABEL + status via separate, RETRIED bd calls (fail-SAFE on a transient hiccup),
  # so the bead is pinned blocked-for-human — STUCK_NEEDS_HUMAN recorded, breaker/
  # retry-exempt, NO reset-to-open, NO analysis child. Idempotent with the preempt
  # (if it already fired, SR_STUCK_HANDLED is set and this is skipped) and a strict
  # no-op for every non-human bead (the `human` label gate never matches them, so
  # the whole offline conformance suite is unaffected).
  # claude-tools-309l EXTENDS this belt to ALSO catch the aged-out still-stuck case
  # (human + open|in_progress + a non-audit STUCK_NEEDS_HUMAN note past the §7.3
  # Case-3 recency window — the residual hole 1vnx's belt left open). For THAT case
  # the bead is NOT yet blocked, so the belt now flips it (idempotent for the
  # already-blocked 1vnx case) and, when opted-IN, authors the dossier so the
  # pinned fork is visible in the Inbox — otherwise it sits blocked-but-invisible
  # and is never answered.
  if [[ -z "$SR_STUCK_HANDLED" ]] && _bead_blocked_for_human "$TASK_ID"; then
    # Pin OUT of the ready set (idempotent: an already-blocked 1vnx bead no-ops)
    # so an aged-note not-blocked fork stops being re-picked; re-assert the
    # `human` label the same way sr_reconcile does (restore a clobbered datum).
    bd update "$TASK_ID" --status=blocked >/dev/null 2>&1 || true
    bd label add "$TASK_ID" human >/dev/null 2>&1 || true
    # (c) claude-tools-309l: a belt-only fork was invisible in the Inbox (the §7.3
    # preempt authors the dossier; the belt did not). When opted-IN and the
    # stuck-routing lib is present, author the §7.4 task_ref-keyed dossier + §4.3
    # notification so the pinned fork actually surfaces for Brian. §7.4-deduped +
    # no_emit-idempotent ⇒ a re-fire on a re-pickup is a safe no-op; gated on
    # ASK_BRIAN_ENABLED so an opted-OUT workspace never leaks a dossier.
    if [[ "${ASK_BRIAN_ENABLED:-0}" == "1" ]] && command -v sr_route_stuck >/dev/null 2>&1; then
      : "${CO_STORE:=$LOG_DIR/.co-store}"; export CO_STORE
      SR_BELT_DID="$(
        sr_route_stuck "${SR_BEARER:-bearer-runner-stuck}" "$TASK_ID" \
          "worker_stuck" "$(sr_worker_ask "$TASK_ID" 2>/dev/null || true)" \
          2>/dev/null || true
      )"
      if command -v no_emit >/dev/null 2>&1 && [[ -n "$SR_BELT_DID" ]]; then
        no_emit "${SR_BEARER:-bearer-runner-stuck}" "$SR_BELT_DID" >/dev/null 2>&1 \
          || echo "  STUCK_NEEDS_HUMAN: WARN belt dossier '$SR_BELT_DID' persisted but no_emit FAILED — observable, idempotent; a later re-emit is safe."
      fi
    fi
    append_runner_note "$TASK_ID" "STUCK_NEEDS_HUMAN" "-"
    record_incident    "$TASK_ID" "STUCK_NEEDS_HUMAN" "-"
    if command -v la_report_terminal_reason >/dev/null 2>&1; then
      la_report_terminal_reason STUCK_NEEDS_HUMAN "" "$TASK_ID" "${PROJECT_REF:-}" || true
    fi
    SR_STUCK_HANDLED=1
    SR_REASON="blocked+human at exit (claude-tools-1vnx/309l un-thrash guard — the §7.3 preempt did not fire; bead pinned blocked-for-human, NOT reset, NO analysis child)"
  fi

  # Preserve the stream-json for serious failures so we can post-mortem what
  # state the agent was in when it failed. Skipped for routine/transient cases
  # (RATE_LIMIT, TASK_NOT_CLOSED) to avoid disk spam — those still get an
  # incidents.log entry and a beads note, just no stream snapshot.
  PRESERVED_LOG=""
  case "$CLASSIFICATION" in
    WATCHDOG_KILL|UNKNOWN_FAILURE|SERVER_ERROR|MAX_OUTPUT_TOKENS|CONTEXT_OVERFLOW)
      PRESERVED_LOG=$(preserve_stream "$STREAM_FILE" "$LOG_BASE-$CLASSIFICATION")
      [[ -n "$PRESERVED_LOG" ]] && echo "  Stream preserved: $PRESERVED_LOG"
      [[ "$CLASSIFICATION" == "WATCHDOG_KILL" && -f "$PROC_SNAPSHOT" ]] && \
        echo "  Process snapshot: $PROC_SNAPSHOT"
      ;;
  esac

  # §7.3/§7.5: a STUCK_NEEDS_HUMAN (PRIMARY or BACKSTOP) bypasses the normal
  # classification dispatch — the bead is ALREADY blocked-for-human and the
  # runner just moves on (it must NOT be reset to --status=open and is
  # breaker/retry-exempt). classify_failure (§7.1) is untouched; this is the
  # §7.3 OUTCOME guard, not a new classification arm.
  if [[ -n "$SR_STUCK_HANDLED" ]]; then
    echo "  STUCK_NEEDS_HUMAN: $TASK_TITLE — $SR_REASON; bead driven to blocked-for-human (§7.3), fork ⇒ one Dossier (§7.4) + §4.3 Notification. Runner continues (§7.5)."
  else
  case "$CLASSIFICATION" in
    SUCCESS)
      echo "  Done: $TASK_TITLE"
      COMPLETED=$((COMPLETED + 1))
      CONSECUTIVE_FAILURES=0
      LAST_FAILED_ID=""
      FAIL_COUNT=0
      # claude-tools-apen: post-close discipline audit. If the close-checklist
      # Stop hook was bypassed (8-block cap burned), this catches it — files a
      # regression bead + incident so the silent disappear doesn't happen.
      post_close_audit "$TASK_ID" "$LOG_BASE"
      ;;

    AUTH_FAILURE)
      echo "  FATAL: Authentication failed — stopping runner."
      FAILED=$((FAILED + 1))
      bd update "$TASK_ID" --status=open 2>/dev/null || true
      append_runner_note "$TASK_ID" "AUTH_FAILURE" "-"
      record_incident "$TASK_ID" "AUTH_FAILURE" "-"
      notify_user "beads-runner: auth failure" "$TASK_ID — runner stopped"
      runner_cleanup
      rm -f "$STREAM_FILE" "$ACTIVITY_FILE" "$TASK_INFLIGHT_FILE" "$SIGNAL_FILE" "$USAGE_CACHE_FILE" "${POST_TERMINAL_FILE:-}" "${HOOK_SETTINGS_FILE:-}"
      echo "Results: $COMPLETED completed, $FAILED failed"
      print_incidents_summary
      lease_release_seam "$TASK_ID"   # §6.1 release ⇒ bead open (fatal exit)
      if command -v la_report_terminal_reason >/dev/null 2>&1; then
        la_report_terminal_reason AUTH_FAILURE 3 "$TASK_ID" "${PROJECT_REF:-}" || true
      fi
      exit 3
      ;;

    BILLING_ERROR)
      echo "  FATAL: Billing error — stopping runner."
      FAILED=$((FAILED + 1))
      bd update "$TASK_ID" --status=open 2>/dev/null || true
      append_runner_note "$TASK_ID" "BILLING_ERROR" "-"
      record_incident "$TASK_ID" "BILLING_ERROR" "-"
      notify_user "beads-runner: billing error" "$TASK_ID — runner stopped"
      runner_cleanup
      rm -f "$STREAM_FILE" "$ACTIVITY_FILE" "$TASK_INFLIGHT_FILE" "$SIGNAL_FILE" "$USAGE_CACHE_FILE" "${POST_TERMINAL_FILE:-}" "${HOOK_SETTINGS_FILE:-}"
      echo "Results: $COMPLETED completed, $FAILED failed"
      print_incidents_summary
      lease_release_seam "$TASK_ID"   # §6.1 release ⇒ bead open (fatal exit)
      if command -v la_report_terminal_reason >/dev/null 2>&1; then
        la_report_terminal_reason BILLING_ERROR 4 "$TASK_ID" "${PROJECT_REF:-}" || true
      fi
      exit 4
      ;;

    RATE_LIMIT)
      echo "  Rate limited — will retry after usage check."
      FAILED=$((FAILED + 1))
      bd update "$TASK_ID" --status=open 2>/dev/null || true
      append_runner_note "$TASK_ID" "RATE_LIMIT" "-"
      record_incident "$TASK_ID" "RATE_LIMIT" "-"
      # Don't set LAST_FAILED_ID — rate limit retries are invisible to per-task retry counter
      # No notification — RATE_LIMIT is routine and would spam.
      USAGE_CACHE_TIME=0  # force fresh usage check on next loop iteration
      ;;

    MAX_OUTPUT_TOKENS)
      echo "  FAILED: $TASK_TITLE — ran out of context window"
      FAILED=$((FAILED + 1))
      bd update "$TASK_ID" --status=open 2>/dev/null || true
      append_runner_note "$TASK_ID" "MAX_OUTPUT_TOKENS" "${PRESERVED_LOG:--}"
      record_incident "$TASK_ID" "MAX_OUTPUT_TOKENS" "${PRESERVED_LOG:--}"
      notify_user "beads-runner: max output tokens" "$TASK_ID — context exhausted"
      create_analysis_task "$TASK_ID" "$TASK_TITLE" "max_output_tokens"
      LAST_FAILED_ID=""
      FAIL_COUNT=0
      ;;

    CONTEXT_OVERFLOW)
      echo "  FAILED: $TASK_TITLE — context window overflowed (Prompt is too long)"
      FAILED=$((FAILED + 1))
      bd update "$TASK_ID" --status=open 2>/dev/null || true
      append_runner_note "$TASK_ID" "CONTEXT_OVERFLOW" "${PRESERVED_LOG:--}"
      record_incident "$TASK_ID" "CONTEXT_OVERFLOW" "${PRESERVED_LOG:--}"
      notify_user "beads-runner: context overflow" "$TASK_ID — see $LOG_DIR"
      # Retrying as-is re-overflows at the same point, so go straight to an
      # analysis task (runs on opus). Reason carries salvage guidance: the
      # previous agent usually completed early phases before overflowing.
      create_analysis_task "$TASK_ID" "$TASK_TITLE" \
        "context_overflow — ran out of context mid-session. The previous agent likely completed early phases before overflowing: inspect git log / git diff for committed or staged work and re-scope this task to ONLY the remaining steps (do not redo completed work). If the task is inherently too large for one window, split it into smaller dependent tasks. Overflow-prone tasks are usually labeled model:sonnet (200K window); relabel the re-scoped task model:opus (the runner auto-selects the 1M-context Opus variant) before it is retried."
      LAST_FAILED_ID=""
      FAIL_COUNT=0
      ;;

    TASK_NOT_CLOSED)
      echo "  PARTIAL: $TASK_TITLE — exited 0 but task still open"
      FAILED=$((FAILED + 1))
      bd update "$TASK_ID" --status=open 2>/dev/null || true
      append_runner_note "$TASK_ID" "TASK_NOT_CLOSED" "-"
      record_incident "$TASK_ID" "TASK_NOT_CLOSED" "-"
      # First time: retry (Claude might just close it). Second time: create analysis task.
      # Note: FAIL_COUNT at the top of the loop also increments, but this check fires
      # before FAIL_COUNT reaches MAX_RETRIES, so this is the effective gate.
      # No notification — first occurrence is often "Claude forgot to call bd close".
      if [[ "$TASK_ID" == "$LAST_FAILED_ID" ]]; then
        create_analysis_task "$TASK_ID" "$TASK_TITLE" "task_not_closed"
        LAST_FAILED_ID=""
        FAIL_COUNT=0
      else
        LAST_FAILED_ID="$TASK_ID"
      fi
      ;;

    SERVER_ERROR|WATCHDOG_KILL|UNKNOWN_FAILURE|*)
      echo "  FAILED: $TASK_TITLE ($CLASSIFICATION, exit $CLAUDE_EXIT)"
      FAILED=$((FAILED + 1))
      bd update "$TASK_ID" --status=open 2>/dev/null || true
      append_runner_note "$TASK_ID" "$CLASSIFICATION" "${PRESERVED_LOG:--}"
      record_incident "$TASK_ID" "$CLASSIFICATION" "${PRESERVED_LOG:--}"
      notify_user "beads-runner: $CLASSIFICATION" "$TASK_ID — see $LOG_DIR"
      # Count toward consecutive failures only if different task
      if [[ "$TASK_ID" != "$LAST_FAILED_ID" ]]; then
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
      fi
      LAST_FAILED_ID="$TASK_ID"
      ;;
  esac
  fi

  # Scan the stream for high-signal tool-level errors regardless of classification.
  # Many silent failures (subagent missing, permission denied, MCP down) leave the
  # exit code clean because the agent recovers inline — but we still want to know.
  scan_tool_errors "$STREAM_FILE" "$TASK_ID"

  # Drop the proc snapshot if classification didn't end up using it.
  # (Only WATCHDOG_KILL writes to PROC_SNAPSHOT, and we keep it in that case.)
  if [[ "$CLASSIFICATION" != "WATCHDOG_KILL" && -f "$PROC_SNAPSHOT" ]]; then
    rm -f "$PROC_SNAPSHOT"
  fi

  # Consecutive failure circuit breaker
  if [[ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]]; then
    echo ""
    echo "  $MAX_CONSECUTIVE_FAILURES consecutive failures — likely systemic error."
    echo "  Stopping to avoid closing healthy tasks as skipped."
    notify_user "beads-runner: stopped" "$MAX_CONSECUTIVE_FAILURES consecutive failures"
    runner_cleanup
    rm -f "$STREAM_FILE" "$ACTIVITY_FILE" "$TASK_INFLIGHT_FILE" "$SIGNAL_FILE" "$USAGE_CACHE_FILE" "${POST_TERMINAL_FILE:-}" "${HOOK_SETTINGS_FILE:-}"
    echo "Results: $COMPLETED completed, $FAILED failed"
    print_incidents_summary
    lease_release_seam "${TASK_ID:-}"   # §6.1 release ⇒ bead open (fatal exit)
    if command -v la_report_terminal_reason >/dev/null 2>&1; then
      la_report_terminal_reason CIRCUIT_BREAKER 2 "${TASK_ID:-}" "${PROJECT_REF:-}" || true
    fi
    exit 2
  fi

  # §6.1: per-task end (SUCCESS or any non-fatal class that reset the bead to
  # --status=open above) — release pairs the acquire so the lease never
  # outlives the work (release/expiry ⇒ bead open; orphan recovery = expiry).
  lease_release_seam "$TASK_ID"
  rm -f "$STREAM_FILE" "$ACTIVITY_FILE" "$TASK_INFLIGHT_FILE" "$SIGNAL_FILE" "${POST_TERMINAL_FILE:-}" "${HOOK_SETTINGS_FILE:-}"
  # gk17 / epic vvgy: emit a workspace_inventory snapshot at completion so the
  # Board reflects the post-task queue (the just-closed bead leaves
  # in_progress, counts update, the next ready bead becomes visible).
  runner_refresh_audit_coverage   # claude-tools-mhcp.3: freshen the §9 marker the publish below reads
  command -v la_publish_workspace_inventory >/dev/null 2>&1 \
    && la_publish_workspace_inventory || true
  CLAUDE_PID=""
  CURRENT_TASK_ID=""
  # claude-tools-td0y: clear the current-task file so a between-tasks hook
  # invocation (e.g., an idle Stop) doesn't see a stale id.
  rm -f "$LOG_DIR/current-task" 2>/dev/null || true
  echo ""
done

rm -f "$USAGE_CACHE_FILE"
echo "Results: $COMPLETED completed, $FAILED failed"
print_incidents_summary
# §8.2 terminal-reason re-home: clean drain / graceful-stop = exit 0 (BC-21
# §8.1 row 0). Recorded so a heartbeat-absence channel can tell clean=0 from
# AUTH=3 (the whole point of the re-home, S-7).
if command -v la_report_terminal_reason >/dev/null 2>&1; then
  la_report_terminal_reason CLEAN 0 "" "${PROJECT_REF:-}" || true
fi
# §4.2 `stopping`: the honest final actual — last_heartbeat_at freezes here, so
# the hosted read path derives `stale` once §0.5 STALE_AFTER elapses (C6: a
# stored `live` would lie the instant the runner exits). Emitted into the same
# queue the drain below flushes; do NOT drain here (the I1 drain owns that).
if command -v la_report_heartbeat >/dev/null 2>&1; then
  la_report_heartbeat stopping "" || true
fi
# I1 (claude-tools-txj): §2.4 drain-on-reconnect, realised at clean shutdown —
# push the machine-local §1.1 UP queue (capacity reports, …) to the DEPLOYED
# coordinator over the authed HTTP transport before the process exits. Guarded:
# defined ONLY when COORDINATOR_URL is set (else the queue persists locally for
# a future hosted-wired run, exactly as before — never lost, at-least-once).
if declare -F la_outbox_drain >/dev/null 2>&1; then
  la_outbox_drain "${COORDINATOR_TOKEN:-}" || true
fi
echo "Run 'bd stats' or 'git log --oneline' to review."
