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
)
EXTRA_CLAUDE_FLAGS=(--no-chrome)
PROMPT_EXTRA=""
MAX_RETRIES=2
MAX_CONSECUTIVE_FAILURES=3
DEFAULT_MODEL=opus

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
  echo "Results: $COMPLETED completed, $FAILED failed"
  exit 1
}
trap cleanup INT TERM

# ── Task selection ───────────────────────────────────────────────────────────

# Pick up any orphaned in_progress tasks first, then fall through to ready tasks
next_task() {
  local json
  json=$(bd list --status=in_progress --json 2>/dev/null || echo "[]")
  local id
  id=$(echo "$json" | jq -r '.[0].id // empty')
  if [[ -n "$id" ]]; then
    echo "(Resuming interrupted task)" >&2
    echo "$json"
    return
  fi
  bd ready --json 2>/dev/null || echo "[]"
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

  # Track retries — skip task after MAX_RETRIES consecutive failures
  if [[ "$TASK_ID" == "$LAST_FAILED_ID" ]]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    if [[ $FAIL_COUNT -ge $MAX_RETRIES ]]; then
      echo "  Skipping after $MAX_RETRIES failures"
      bd update "$TASK_ID" --status=open 2>/dev/null || true
      bd update "$TASK_ID" --notes="Skipped by script after $MAX_RETRIES failures" 2>/dev/null || true
      bd close "$TASK_ID" --reason="Skipped: failed $MAX_RETRIES times" 2>/dev/null || true
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
        result)
          RESULT=$(echo "$line" | jq -r '.result // empty' 2>/dev/null)
          [[ -n "$RESULT" ]] && echo "  [$TS] $RESULT"
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
          kill "$CLAUDE_PID" 2>/dev/null || true
          break
        elif [[ $IDLE -ge 180 ]]; then
          echo "  No activity for ${IDLE}s — possibly stuck"
        fi
      fi
    done
  ) &
  WATCHDOG_PID=$!

  # ── Wait for result ──────────────────────────────────────────────────────

  if wait "$CLAUDE_PID" 2>/dev/null; then
    sleep 1
    kill "$TAIL_PID" "$WATCHDOG_PID" 2>/dev/null || true
    wait "$TAIL_PID" "$WATCHDOG_PID" 2>/dev/null || true
    echo ""
    echo "  Done: $TASK_TITLE"
    COMPLETED=$((COMPLETED + 1))
    CONSECUTIVE_FAILURES=0
  else
    EXIT_CODE=$?
    kill "$TAIL_PID" "$WATCHDOG_PID" 2>/dev/null || true
    wait "$TAIL_PID" "$WATCHDOG_PID" 2>/dev/null || true
    echo ""
    echo "  FAILED: $TASK_TITLE (exit code $EXIT_CODE)"
    FAILED=$((FAILED + 1))
    LAST_FAILED_ID="$TASK_ID"
    CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
    bd update "$TASK_ID" --status=open 2>/dev/null || true

    if [[ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]]; then
      echo ""
      echo "  $MAX_CONSECUTIVE_FAILURES consecutive failures — likely usage quota exhausted or systemic error."
      echo "  Stopping to avoid closing healthy tasks as skipped."
      echo "Results: $COMPLETED completed, $FAILED failed"
      exit 2
    fi
  fi

  rm -f "$STREAM_FILE" "$ACTIVITY_FILE"
  CLAUDE_PID=""
  CURRENT_TASK_ID=""
  echo ""
done

echo "Results: $COMPLETED completed, $FAILED failed"
echo "Run 'bd stats' or 'git log --oneline' to review."
