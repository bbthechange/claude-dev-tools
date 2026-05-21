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
MAX_RETRIES=${MAX_RETRIES:-2}
MAX_CONSECUTIVE_FAILURES=${MAX_CONSECUTIVE_FAILURES:-3}
DEFAULT_MODEL=${DEFAULT_MODEL:-opus[1m]}  # [1m] = 1M context variant; auto-tracks latest Opus
USAGE_THRESHOLD=${USAGE_THRESHOLD:-70}       # pause new tasks above this % (0 = disabled)
USAGE_SLEEP_SECONDS=${USAGE_SLEEP_SECONDS:-1800} # sleep duration when over threshold (30 min)
USAGE_CACHE_SECONDS=${USAGE_CACHE_SECONDS:-300}  # cache usage API response (avoid hammering per-loop)
CAPACITY_DENY_BACKOFF=${CAPACITY_DENY_BACKOFF:-60} # C1: per-pickup daemon ask-capacity denied ⇒ release lease + sleep N before retry
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
LOG_RETENTION_DAYS=${LOG_RETENTION_DAYS:-14}     # rotation: delete runner-logs older than this
LOG_DIR=".beads/runner-logs"                     # post-mortem artifacts (stream-json, ps/lsof snapshots, incidents.log)

# Hook functions — override in .beads/runner.sh if needed
runner_setup()   { :; }  # called once at script start
runner_cleanup() { :; }  # called on exit/interrupt

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
# The controllable unit reported UP (§4.2 project_ref). Derived locally; the
# Coordinator owns desired-state, never the LA (§1.1).
PROJECT_REF="${PROJECT_REF:-$(basename "$(pwd)")}"

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
if [[ "${1:-}" == "--yolo" ]]; then
  PERMISSION_FLAGS=(--dangerously-skip-permissions)
  MODE_LABEL="all permissions bypassed"
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
  rm -f "$USAGE_CACHE_FILE" "${SIGNAL_FILE:-}"
  echo "Results: $COMPLETED completed, $FAILED failed"
  exit 1
}
trap cleanup INT TERM

# ── Usage check ──────────────────────────────────────────────────────────────

USAGE_CACHE_FILE=""
USAGE_CACHE_TIME=0

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
      echo "ok"   > "$USAGE_CACHE_FILE"; return 0
    else
      echo "over" > "$USAGE_CACHE_FILE"; return 1
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
  if [[ ${five_int:-0} -ge $USAGE_THRESHOLD ]] || [[ ${seven_int:-0} -ge $USAGE_THRESHOLD ]]; then
    echo "over" > "$USAGE_CACHE_FILE"
    echo "  Usage: 5h=${five_hour}% 7d=${seven_day}% (threshold: ${USAGE_THRESHOLD}%)"
    return 1
  fi
  echo "ok" > "$USAGE_CACHE_FILE"
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
# Resolves the workspace's current desired-state for the spare-only gate.
# Best-effort, fail-OPEN (empty echo ⇒ caller treats as `running` — same
# posture runner.sh's st_reconcile takes when the engine is unreachable).
# Cached for DESIRED_STATE_CACHE_SECONDS so a per-pickup gate does not hammer
# the coordinator the way the loop-top check_usage cache shields the usage
# API. Sources coordinator.sh + co-http-transport.sh only if available
# (standalone runs without a coordinator return empty ⇒ no spare-only gate
# applies, which is the correct posture).
DESIRED_STATE_CACHE_SECONDS=${DESIRED_STATE_CACHE_SECONDS:-30}
DESIRED_STATE_CACHE_VALUE=""
DESIRED_STATE_CACHE_TIME=0
workspace_desired_state() {
  local now age
  now=$(date +%s 2>/dev/null || echo 0)
  age=$(( now - DESIRED_STATE_CACHE_TIME ))
  if [[ -n "$DESIRED_STATE_CACHE_VALUE" ]] && [[ "$age" -lt "$DESIRED_STATE_CACHE_SECONDS" ]]; then
    printf '%s' "$DESIRED_STATE_CACHE_VALUE"
    return 0
  fi
  command -v co_request >/dev/null 2>&1 || { printf ''; return 0; }
  [[ -n "${PROJECT_REF:-}" ]] || { printf ''; return 0; }
  local bearer resp desired
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

# ── Task selection ───────────────────────────────────────────────────────────

# Snapshot in_progress tasks at startup — these are orphans from a previous crash.
# Tasks that become in_progress later are being worked on by other agents.
# Note: small race window between snapshot and first loop — another agent could claim
# an orphan in that window. The status recheck inside next_task() mitigates this.
read -ra ORPHANED_IDS <<< "$(bd list --status=in_progress --json 2>/dev/null | jq -r '.[].id // empty' 2>/dev/null || true)"
# Clear if the only element is empty string (no orphans)
[[ ${#ORPHANED_IDS[@]} -eq 1 && -z "${ORPHANED_IDS[0]}" ]] && ORPHANED_IDS=()

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
  bd ready --json 2>/dev/null || echo "[]"
}

# Check if a task is actually workable (deps resolved, not a parent container)
# Returns 0 if ok, 1 if should skip
validate_task() {
  local task_id="$1"

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

  return 0
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
  if [[ "$exit_code" == "${WORKER_STUCK_EXIT:-7}" ]]; then
    echo "worker_stuck"; return 0
  fi
  command -v bd >/dev/null 2>&1 || return 1
  # --long --json includes the `notes` key (the runner already relies on this
  # shape at create_analysis_task — same contract).
  row=$(bd show "$task_id" --long --json 2>/dev/null) || return 1
  [[ -n "$row" ]] || return 1
  status=$(printf '%s' "$row" | jq -r '.[0].status // ""' 2>/dev/null)
  has_human=$(printf '%s' "$row" | jq -r '
    if (any(.[].labels[]?; . == "human")) then "yes" else "no" end' 2>/dev/null)
  has_stuck_note=$(printf '%s' "$row" | jq -r '
    if ((.[0].notes // "") | test("STUCK_NEEDS_HUMAN")) then "yes" else "no" end' 2>/dev/null)
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
      append_runner_note "$task_id" "STUCK_AUTOFLIP relaxed-primary — agent set 'human' label + STUCK_NEEDS_HUMAN note but missed status=blocked; runner auto-flipped (claude-tools-2ir)" "-"
    fi
    echo "worker_stuck"
    return 0
  fi
  return 1
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

# §4.2 `starting`: the very first registration line — a freshly (re)launched
# runner appears in the hosted engine under its project_ref before it claims
# any work (the I2 "appears as a live runner via the deployed read path").
hb starting

while true; do
  # Check for graceful stop signal
  if [[ -f "$STOP_FILE" ]]; then
    echo ""
    echo "Stop file detected ($STOP_FILE) — stopping gracefully."
    rm -f "$STOP_FILE"
    break
  fi

  # Check usage quota before starting a new task
  while ! check_usage; do
    echo "  Above ${USAGE_THRESHOLD}% usage — sleeping $((USAGE_SLEEP_SECONDS / 60))min before rechecking..."
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
  if command -v sr_reconcile_blocked_for_human >/dev/null 2>&1; then
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

  TASK_JSON=$(next_task)
  TASK_ID=$(echo "$TASK_JSON" | jq -r '.[0].id // empty')

  if [[ -z "$TASK_ID" ]]; then
    # UX 0.A (claude-tools-giu): runner stays alive when the queue drains —
    # honestly idle to the engine, polling for new ready work, and picks up
    # any task added afterward WITHOUT requiring an external respawn. The
    # daemon's M3 desired-state poll is still authoritative: a desired=stopped
    # OR a .stop-beads here ends the runner cleanly within IDLE_POLL_INTERVAL.
    # RUNNER_EXIT_ON_DRAIN=1 opts into the legacy BC-05 SCAR (drain ⇒ exit 0)
    # so conformance tests can still verify the historical exit-code contract.
    if [[ -n "${RUNNER_EXIT_ON_DRAIN:-}" ]]; then
      echo ""
      echo "No more ready tasks."
      echo "  (RUNNER_EXIT_ON_DRAIN=1 — BC-05 legacy exit-on-drain contract)"
      hb idle
      break
    fi
    if [[ "${IDLE_NOTIFIED:-0}" != "1" ]]; then
      echo ""
      echo "No more ready tasks — idling (poll every ${IDLE_POLL_INTERVAL:-60}s for new work)."
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
      # IDLE_POLL_INTERVAL — same posture as runner.sh's idle reconcile.
      IDLE_DESIRED=$(workspace_desired_state)
      if [[ "$IDLE_DESIRED" == "stopped" ]]; then
        echo "Coordinator desired=stopped observed while idle — stopping gracefully."
        break 2
      fi
      sleep "${IDLE_POLL_INTERVAL:-60}"
      TASK_JSON=$(next_task)
      TASK_ID=$(echo "$TASK_JSON" | jq -r '.[0].id // empty')
      [[ -n "$TASK_ID" ]] && break
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

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  $TASK_TITLE ($TASK_ID) [$TASK_MODEL]"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Pre-flight: skip tasks that aren't actually workable (no failure counted)
  if ! validate_task "$TASK_ID"; then
    echo ""
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
  if [[ -z "${TASK_COST_CLASS:-}" ]]; then
    if [[ "${TASK_PRIORITY:-2}" -ge 3 ]]; then
      TASK_COST_CLASS="low_priority"
    else
      TASK_COST_CLASS="standard"
    fi
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
        echo "  Capacity DENIED by local fallback for $TASK_ID (cost=$TASK_COST_CLASS) — releasing lease, sleeping ${CAPACITY_DENY_BACKOFF}s."
        lease_release_seam "$TASK_ID"
        sleep "$CAPACITY_DENY_BACKOFF"
        continue
      fi
      ;;
  esac

  CURRENT_TASK_ID="$TASK_ID"
  bd update "$TASK_ID" --status=in_progress 2>/dev/null || true
  hb running "$TASK_ID"   # §4.2: actual=running + current_task_ref, re-registers liveness

  # ── Build prompt ─────────────────────────────────────────────────────────

  read -r -d '' PROMPT <<'PROMPT_DELIM' || true
You are working on beads issue BEADS_ID: "BEADS_TITLE"

Task description:
BEADS_DESC

IMPORTANT: You are running non-interactively. Do NOT use EnterPlanMode or ExitPlanMode -- there is no human to approve plans. Do NOT use AskUserQuestion -- there is no human to answer. Just execute the work directly.

If -- and ONLY if -- you hit a genuine fork you must NOT resolve yourself (an irreversible product / architecture / scope decision that is the human's call to make, or a spec ambiguity where guessing would risk real damage), do NOT ask and do NOT guess a default. This is NOT for ordinary hard work and NOT a substitute for thinking a problem through -- it is only for a decision a human owns. When you hit one, call the `mcp__askbrian__ask-brian` MCP tool with a SHORT trigger and wait for it to return Brian's answer. The tool blocks until he answers, then returns the answer as a string -- act on it and continue the task. Multi-question is allowed: if a second fork emerges after the first answer, call the tool again rather than burning a whole stuck cycle. Do NOT close the issue while waiting; just call the tool.

The trigger is intentionally brief (aim for under 200 words). A fresh dossier-builder agent in its own clean context will read the bead, related code, and design docs and write the polished multi-section dossier with Mermaid + per-option consequence_blocks. Your job is to drop a seed the builder can build on, not to dump your whole context. Tool inputs:
  - question: one sentence -- the precise decision needed
  - options: [{label, blast_radius?}, ...] -- name each viable option; blast_radius is OPTIONAL, the builder fills it in from the code
  - recommendation?: your pick if you have one (the builder may revise after reading)
  - reversible?: short note on what is / isn't reversible (the builder may revise)
  - context_dump: freeform note of WHAT IS IN YOUR HEAD that the builder cannot find by reading the bead, related code, and docs itself -- an alternative you considered, a subtle constraint you discovered mid-task, why you cannot resolve this yourself. Do NOT re-explain the bead description or code the builder can read for itself.

Fallback path (only if `mcp__askbrian__ask-brian` is not registered in this session -- the MCP server is rolling out alongside this prompt): write the structured ask into the bead so the runner can route it, then stop. The runner auto-flips status=blocked from the `human` label + STUCK_NEEDS_HUMAN note, so you only need:
  1. bd update BEADS_ID --append-notes="STUCK_NEEDS_HUMAN
     TL;DR: <one sentence>
     The ask: <the precise decision needed>
     Options: <each option and its blast radius>
     Recommendation: <your pick> -- <why>
     Reversible: <what is / isn't reversible>"
  2. bd label add BEADS_ID human
  3. Stop. Do NOT close the issue, do NOT pick an option yourself, do NOT keep working around it. For a real human-decision fork this IS the correct, expected outcome -- not a failure.

Follow the instructions in the task description above exactly. The description contains the full workflow for this task type.

Before closing the issue, add a brief debrief note summarizing how it went:
  bd update BEADS_ID --append-notes="<your debrief>"
Include: what you did, any difficulties or unexpected behavior, how long things took if notable, anything you were not sure about, and any follow-up suggestions. Be honest -- this is for the human reviewing your work later.

When you have completed all steps, close the issue: bd close BEADS_ID
PROMPT_DELIM
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
  if command -v sr_resume_answer >/dev/null 2>&1 \
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

  claude -p "$PROMPT" \
    --output-format stream-json \
    --verbose \
    --model "$TASK_MODEL" \
    "${GUARDRAIL_FLAGS[@]+"${GUARDRAIL_FLAGS[@]}"}" \
    "${EXTRA_CLAUDE_FLAGS[@]+"${EXTRA_CLAUDE_FLAGS[@]}"}" \
    "${PERMISSION_FLAGS[@]+"${PERMISSION_FLAGS[@]}"}" \
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

  (
    tail -f "$STREAM_FILE" 2>/dev/null | while IFS= read -r line; do
      TS=$(date +%H:%M:%S)
      date +%s > "$ACTIVITY_FILE"
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
        *)
          echo "  [$TS] [$TYPE] $(echo "$line" | jq -c '.' 2>/dev/null)"
          ;;
      esac
    done
  ) &
  TAIL_PID=$!

  # ── Watchdog ─────────────────────────────────────────────────────────────

  (
    while kill -0 "$CLAUDE_PID" 2>/dev/null; do
      sleep 15
      if [[ -f "$ACTIVITY_FILE" ]]; then
        LAST=$(cat "$ACTIVITY_FILE")
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

  # ── Wait for result and classify ─────────────────────────────────────────

  wait "$CLAUDE_PID" 2>/dev/null && CLAUDE_EXIT=0 || CLAUDE_EXIT=$?
  sleep 1
  kill "$TAIL_PID" "$WATCHDOG_PID" 2>/dev/null || true
  pkill -P "$TAIL_PID" 2>/dev/null || true  # kill tail -f child that outlives subshell
  wait "$TAIL_PID" "$WATCHDOG_PID" 2>/dev/null || true
  echo ""

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
  if [[ "$CLASSIFICATION" != "AUTH_FAILURE" && "$CLASSIFICATION" != "BILLING_ERROR" ]] \
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
      # §7.4: capture the dedup'd dossier id sr_route_stuck echoes (one fork ⇒
      # ONE id; idempotent on a re-trigger — PRIMARY+BACKSTOP on the same fork
      # collapse here). stderr stays suppressed.
      SR_DID="$(sr_route_stuck "${SR_BEARER:-bearer-runner-stuck}" "$TASK_ID" \
        "$SR_TRIGGER" "$(sr_worker_ask "$TASK_ID" 2>/dev/null || true)" \
        2>/dev/null || true)"
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
      ;;

    AUTH_FAILURE)
      echo "  FATAL: Authentication failed — stopping runner."
      FAILED=$((FAILED + 1))
      bd update "$TASK_ID" --status=open 2>/dev/null || true
      append_runner_note "$TASK_ID" "AUTH_FAILURE" "-"
      record_incident "$TASK_ID" "AUTH_FAILURE" "-"
      notify_user "beads-runner: auth failure" "$TASK_ID — runner stopped"
      runner_cleanup
      rm -f "$STREAM_FILE" "$ACTIVITY_FILE" "$TASK_INFLIGHT_FILE" "$SIGNAL_FILE" "$USAGE_CACHE_FILE"
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
      rm -f "$STREAM_FILE" "$ACTIVITY_FILE" "$TASK_INFLIGHT_FILE" "$SIGNAL_FILE" "$USAGE_CACHE_FILE"
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
    rm -f "$STREAM_FILE" "$ACTIVITY_FILE" "$TASK_INFLIGHT_FILE" "$SIGNAL_FILE" "$USAGE_CACHE_FILE"
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
  rm -f "$STREAM_FILE" "$ACTIVITY_FILE" "$TASK_INFLIGHT_FILE" "$SIGNAL_FILE"
  CLAUDE_PID=""
  CURRENT_TASK_ID=""
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
