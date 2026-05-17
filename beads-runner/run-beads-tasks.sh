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
PROMPT_EXTRA=""
MAX_RETRIES=${MAX_RETRIES:-2}
MAX_CONSECUTIVE_FAILURES=${MAX_CONSECUTIVE_FAILURES:-3}
DEFAULT_MODEL=${DEFAULT_MODEL:-opus[1m]}  # [1m] = 1M context variant; auto-tracks latest Opus
USAGE_THRESHOLD=${USAGE_THRESHOLD:-70}       # pause new tasks above this % (0 = disabled)
USAGE_SLEEP_SECONDS=${USAGE_SLEEP_SECONDS:-1800} # sleep duration when over threshold (30 min)
USAGE_CACHE_SECONDS=${USAGE_CACHE_SECONDS:-300}  # cache usage API response (avoid hammering per-loop)
IDLE_TIMEOUT=${IDLE_TIMEOUT:-600}                # seconds of stream silence before watchdog kills (env-overridable)
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

  # Check if this is a parent/container task with children
  # Note: bd show --children includes the task itself in the result, so filter it out
  local children
  children=$(bd show "$task_id" --children --json 2>/dev/null || echo "[]")
  children=$(echo "$children" | jq --arg id "$task_id" '[.[] | select(.id != $id)]')
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

  TASK_JSON=$(next_task)
  TASK_ID=$(echo "$TASK_JSON" | jq -r '.[0].id // empty')

  if [[ -z "$TASK_ID" ]]; then
    echo ""
    echo "No more ready tasks."
    break
  fi

  TASK_TITLE=$(echo "$TASK_JSON" | jq -r '.[0].title')
  TASK_DESC=$(echo "$TASK_JSON" | jq -r '.[0].description')

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

  CURRENT_TASK_ID="$TASK_ID"
  bd update "$TASK_ID" --status=in_progress 2>/dev/null || true

  # ── Build prompt ─────────────────────────────────────────────────────────

  read -r -d '' PROMPT <<'PROMPT_DELIM' || true
You are working on beads issue BEADS_ID: "BEADS_TITLE"

Task description:
BEADS_DESC

IMPORTANT: You are running non-interactively. Do NOT use EnterPlanMode or ExitPlanMode -- there is no human to approve plans. Do NOT use AskUserQuestion -- there is no human to answer. Just execute the work directly.

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
    "${EXTRA_CLAUDE_FLAGS[@]+"${EXTRA_CLAUDE_FLAGS[@]}"}" \
    "${PERMISSION_FLAGS[@]+"${PERMISSION_FLAGS[@]}"}" \
    > "$STREAM_FILE" 2>&1 &
  CLAUDE_PID=$!

  # ── Stream parser ────────────────────────────────────────────────────────

  ACTIVITY_FILE=$(mktemp)
  SIGNAL_FILE=$(mktemp)
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
        if [[ $IDLE -ge $IDLE_TIMEOUT ]]; then
          echo "  Killing after ${IDLE}s idle — likely stuck"
          echo "WATCHDOG_KILL=1" >> "$SIGNAL_FILE"

          # Snapshot the stuck process before signalling: ps for state/CPU/mem,
          # lsof for open sockets/pipes (tells us network-blocked vs CPU-bound
          # vs child-pipe-blocked). Must run BEFORE SIGINT — lsof on a dying
          # process returns nothing useful.
          {
            echo "=== ps (idle ${IDLE}s, IDLE_TIMEOUT=${IDLE_TIMEOUT}) ==="
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

  # ── §7.3 STUCK_NEEDS_HUMAN — a fired backstop drives the bead (T5.5) ──────
  # The worker slipped past the §7.6 guardrail (result.permission_denials[
  # AskUserQuestion|ExitPlanMode] OR a "Entered plan mode." tool_result). §7.3:
  # the backstop MUST ITSELF drive the bead to blocked-for-human and route the
  # fork into ONE Dossier (§7.4 dossier-level dedup keyed task_ref; S-2 the
  # Coordinator owns blocked-for-human). This is the cross-tier OUTCOME ONLY —
  # classify_failure (§7.1) is byte-untouched and NO §7.5 breaker/retry counter
  # is advanced (STUCK is not a failure: the runner blocks the bead and moves
  # on — §7.5, like a blocking analysis child). The worker-driven primary
  # (WORKER_STUCK_EXIT) is the §7.1 classification slot = T2's, deliberately
  # NOT handled here. Guarded-optional like the §8.2 la_* calls.
  SR_STUCK_HANDLED=""
  if command -v sr_route_stuck >/dev/null 2>&1 && command -v sr_scan_backstop >/dev/null 2>&1; then
    SR_BACKSTOP="$(sr_scan_backstop "$STREAM_FILE" 2>/dev/null || true)"
    if [[ -n "$SR_BACKSTOP" ]]; then
      : "${CO_STORE:=$LOG_DIR/.co-store}"; export CO_STORE
      sr_route_stuck "${SR_BEARER:-bearer-runner-stuck}" "$TASK_ID" \
        "backstop:$SR_BACKSTOP" "$(sr_worker_ask "$TASK_ID" 2>/dev/null || true)" \
        >/dev/null 2>&1 || true
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

  # §7.3/§7.5: a backstop-driven STUCK_NEEDS_HUMAN bypasses the normal
  # classification dispatch — the bead is ALREADY blocked-for-human and the
  # runner just moves on (it must NOT be reset to --status=open and is
  # breaker/retry-exempt). classify_failure (§7.1) is untouched; this is the
  # §7.3 OUTCOME guard, not a new classification arm.
  if [[ -n "$SR_STUCK_HANDLED" ]]; then
    echo "  STUCK_NEEDS_HUMAN: $TASK_TITLE — backstop fired ($SR_BACKSTOP); bead driven to blocked-for-human (§7.3), fork ⇒ one Dossier (§7.4). Runner continues (§7.5)."
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
      rm -f "$STREAM_FILE" "$ACTIVITY_FILE" "$SIGNAL_FILE" "$USAGE_CACHE_FILE"
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
      rm -f "$STREAM_FILE" "$ACTIVITY_FILE" "$SIGNAL_FILE" "$USAGE_CACHE_FILE"
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
    rm -f "$STREAM_FILE" "$ACTIVITY_FILE" "$SIGNAL_FILE" "$USAGE_CACHE_FILE"
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
  rm -f "$STREAM_FILE" "$ACTIVITY_FILE" "$SIGNAL_FILE"
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
# I1 (claude-tools-txj): §2.4 drain-on-reconnect, realised at clean shutdown —
# push the machine-local §1.1 UP queue (capacity reports, …) to the DEPLOYED
# coordinator over the authed HTTP transport before the process exits. Guarded:
# defined ONLY when COORDINATOR_URL is set (else the queue persists locally for
# a future hosted-wired run, exactly as before — never lost, at-least-once).
if declare -F la_outbox_drain >/dev/null 2>&1; then
  la_outbox_drain "${COORDINATOR_TOKEN:-}" || true
fi
echo "Run 'bd stats' or 'git log --oneline' to review."
