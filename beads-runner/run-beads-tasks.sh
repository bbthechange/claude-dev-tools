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
)
EXTRA_CLAUDE_FLAGS=(--no-chrome)
PROMPT_EXTRA=""
MAX_RETRIES=${MAX_RETRIES:-2}
MAX_CONSECUTIVE_FAILURES=${MAX_CONSECUTIVE_FAILURES:-3}
DEFAULT_MODEL=${DEFAULT_MODEL:-opus}
USAGE_THRESHOLD=${USAGE_THRESHOLD:-70}       # pause new tasks above this % (0 = disabled)
USAGE_SLEEP_SECONDS=${USAGE_SLEEP_SECONDS:-1800} # sleep duration when over threshold (30 min)
USAGE_CACHE_SECONDS=${USAGE_CACHE_SECONDS:-300}  # cache usage API response (avoid hammering per-loop)

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
  fi
  runner_cleanup
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

  # Extract OAuth token from macOS Keychain
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

  # Call usage API
  usage_json=$(curl -s -f -X GET "https://api.anthropic.com/api/oauth/usage" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    2>/dev/null) || {
    echo "  (Usage API call failed — skipping check)" >&2
    return 0
  }

  # Parse utilization from both windows
  local five_hour seven_day
  five_hour=$(echo "$usage_json" | jq -r '.five_hour.utilization // 0' 2>/dev/null)
  seven_day=$(echo "$usage_json" | jq -r '.seven_day.utilization // 0' 2>/dev/null)

  # Cache the result
  if [[ -z "$USAGE_CACHE_FILE" ]]; then
    USAGE_CACHE_FILE=$(mktemp) || return 0
  fi
  USAGE_CACHE_TIME=$now

  # Check if either window exceeds threshold (compare as integers)
  local five_int seven_int
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
      status=$(echo "$task_json" | jq -r '.status // empty' 2>/dev/null || true)
      if [[ "$status" == "in_progress" ]]; then
        # Resume this orphan. Keep unprocessed orphans (after current position) for later.
        remaining+=("${ORPHANED_IDS[@]:$pos}")
        ORPHANED_IDS=("${remaining[@]+"${remaining[@]}"}")
        echo "(Resuming orphaned task from previous run)" >&2
        echo "$task_json" | jq '[.]'
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
    task_status=$(bd show "$task_id" --json 2>/dev/null | jq -r '.status // empty' 2>/dev/null || true)
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
      bd update "$TASK_ID" --append-notes="Skipped by runner after $MAX_RETRIES failures" 2>/dev/null || true
      create_analysis_task "$TASK_ID" "$TASK_TITLE" "exceeded_max_retries"
      LAST_FAILED_ID=""
      FAIL_COUNT=0
      continue
    fi
  else
    LAST_FAILED_ID=""
    FAIL_COUNT=0
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

  STREAM_FILE=$(mktemp)

  claude -p "$PROMPT" \
    --output-format stream-json \
    --verbose \
    --model "$TASK_MODEL" \
    "${EXTRA_CLAUDE_FLAGS[@]}" \
    "${PERMISSION_FLAGS[@]}" \
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
        if [[ $IDLE -ge 600 ]]; then
          echo "  Killing after ${IDLE}s idle — likely stuck"
          echo "WATCHDOG_KILL=1" >> "$SIGNAL_FILE"
          kill "$CLAUDE_PID" 2>/dev/null || true
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
      bd update "$TASK_ID" --append-notes="Runner stopped: auth failure" 2>/dev/null || true
      runner_cleanup
      rm -f "$STREAM_FILE" "$ACTIVITY_FILE" "$SIGNAL_FILE" "$USAGE_CACHE_FILE"
      echo "Results: $COMPLETED completed, $FAILED failed"
      exit 3
      ;;

    BILLING_ERROR)
      echo "  FATAL: Billing error — stopping runner."
      FAILED=$((FAILED + 1))
      bd update "$TASK_ID" --status=open 2>/dev/null || true
      bd update "$TASK_ID" --append-notes="Runner stopped: billing error" 2>/dev/null || true
      runner_cleanup
      rm -f "$STREAM_FILE" "$ACTIVITY_FILE" "$SIGNAL_FILE" "$USAGE_CACHE_FILE"
      echo "Results: $COMPLETED completed, $FAILED failed"
      exit 4
      ;;

    RATE_LIMIT)
      echo "  Rate limited — will retry after usage check."
      FAILED=$((FAILED + 1))
      bd update "$TASK_ID" --status=open 2>/dev/null || true
      # Don't set LAST_FAILED_ID — rate limit retries are invisible to per-task retry counter
      USAGE_CACHE_TIME=0  # force fresh usage check on next loop iteration
      ;;

    MAX_OUTPUT_TOKENS)
      echo "  FAILED: $TASK_TITLE — ran out of context window"
      FAILED=$((FAILED + 1))
      bd update "$TASK_ID" --status=open 2>/dev/null || true
      create_analysis_task "$TASK_ID" "$TASK_TITLE" "max_output_tokens"
      LAST_FAILED_ID=""
      FAIL_COUNT=0
      ;;

    TASK_NOT_CLOSED)
      echo "  PARTIAL: $TASK_TITLE — exited 0 but task still open"
      FAILED=$((FAILED + 1))
      bd update "$TASK_ID" --status=open 2>/dev/null || true
      # First time: retry (Claude might just close it). Second time: create analysis task.
      # Note: FAIL_COUNT at the top of the loop also increments, but this check fires
      # before FAIL_COUNT reaches MAX_RETRIES, so this is the effective gate.
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
      # Count toward consecutive failures only if different task
      if [[ "$TASK_ID" != "$LAST_FAILED_ID" ]]; then
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
      fi
      LAST_FAILED_ID="$TASK_ID"
      ;;
  esac

  # Consecutive failure circuit breaker
  if [[ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]]; then
    echo ""
    echo "  $MAX_CONSECUTIVE_FAILURES consecutive failures — likely systemic error."
    echo "  Stopping to avoid closing healthy tasks as skipped."
    runner_cleanup
    rm -f "$STREAM_FILE" "$ACTIVITY_FILE" "$SIGNAL_FILE" "$USAGE_CACHE_FILE"
    echo "Results: $COMPLETED completed, $FAILED failed"
    exit 2
  fi

  rm -f "$STREAM_FILE" "$ACTIVITY_FILE" "$SIGNAL_FILE"
  CLAUDE_PID=""
  CURRENT_TASK_ID=""
  echo ""
done

rm -f "$USAGE_CACHE_FILE"
echo "Results: $COMPLETED completed, $FAILED failed"
echo "Run 'bd stats' or 'git log --oneline' to review."
