#!/bin/bash
# beads-runner/hooks/close-checklist.sh
#
# Stop + PreToolUse hook for beads-runner workers. Enforces five close-time
# preconditions before allowing `bd close` (PreToolUse) or end-of-turn (Stop):
#   1. no orphan background processes still alive under this session
#   2. clean git tree (excluding debrief / runner-log scratch files)
#   3. closed bead has a commit referencing it (Stop only — PreToolUse fires
#      BEFORE close so the inconsistency can't yet exist)
#   4. /wrapup was invoked — proven by EITHER signal (claude-tools-fh87):
#        (a) a Skill(<wrapup-pattern>) tool_use in this session's transcript, OR
#        (b) a wrapup-reviewed marker in bd notes (durable audit trail)
#   5. a debrief was appended to bd notes
#
# Emits ONE comprehensive block per round so the agent can fix all failures in
# a single retry — Stop hooks are capped at 8 consecutive blocks (overridable
# via CLAUDE_CODE_STOP_HOOK_BLOCK_CAP) and one block per check would exhaust
# the budget on a multi-failure session. The runner's post-terminal watchdog
# (run-beads-tasks.sh) is the backstop for cases where the cap exhausts.
#
# Gating (silently allows the stop / tool call):
#   - BEADS_RUNNER_SESSION != "1"  (not a runner-spawned session)
#   - no CURRENT_TASK_ID            (idle session, no bead in flight)
#   - stop_hook_active=true         (Stop hook continuation loop — yield)
#   - PreToolUse on non-Bash tool   (only acts on Bash close commands)
#   - PreToolUse Bash that isn't a close command
#
# Parent bead: claude-tools-td0y. Plan: ~/.claude/plans/yeah-look-into-everything-toasty-papert.md
#
# Contract surface (DO NOT change without re-verifying against Claude Code docs):
#   Input stdin (Stop)        : { session_id, transcript_path, cwd, hook_event_name="Stop", stop_hook_active }
#   Input stdin (PreToolUse)  : { session_id, transcript_path, cwd, hook_event_name="PreToolUse",
#                                 tool_name, tool_input.command, tool_use_id }
#   Output (Stop block)       : { "decision": "block", "reason": "..." }      (exit 0 + stdout JSON)
#   Output (PreToolUse block) : { "hookSpecificOutput": { "hookEventName": "PreToolUse",
#                                 "permissionDecision": "deny",
#                                 "permissionDecisionReason": "..." } }       (exit 0 + stdout JSON)
#   Allow                     : exit 0 with no stdout
#
# Env vars consumed:
#   BEADS_RUNNER_SESSION   "1" → enforce; anything else → noop
#   CURRENT_TASK_ID        bead id (falls back to .beads/runner-logs/current-task)
#   CLAUDE_PROJECT_DIR     workspace root
#   CLAUDE_SESSION_ID      session id (falls back to stdin .session_id)
#   BEADS_HOOK_LOG         override log file path
#   POST_TERMINAL_GRACE    (referenced only in remediation text; runner reads it)
#   BEADS_WRAPUP_SKILL_PATTERN  glob for wrapup skill names (default "wrapup*").
#                          Used for BOTH the workspace-skill existence gate and
#                          the transcript Skill-name match, so a workspace can
#                          tailor its skill (e.g. "wrapup-frontend") and stay in
#                          contract. The marker fallback ("wrapup-reviewed:") is
#                          pattern-independent.
#
# Tools assumed present: jq, git, bd, pgrep, ps. Missing tools → check is skipped,
# not a hard fail (graceful degrade for minimal environments).

set -uo pipefail

# ── 0. Read stdin ───────────────────────────────────────────────────────────
INPUT_JSON="$(cat 2>/dev/null || echo '{}')"

jqr() {  # jqr <jq-expr> → echoes value or empty on any error
  printf '%s' "$INPUT_JSON" | jq -r "$1" 2>/dev/null || true
}

event_name="$(jqr '.hook_event_name // empty')"
session_id_stdin="$(jqr '.session_id // empty')"
cwd_stdin="$(jqr '.cwd // empty')"
stop_hook_active="$(jqr '.stop_hook_active // false')"
tool_name="$(jqr '.tool_name // empty')"
tool_command="$(jqr '.tool_input.command // empty')"

session_id="${CLAUDE_SESSION_ID:-$session_id_stdin}"
project_dir="${CLAUDE_PROJECT_DIR:-${cwd_stdin:-$PWD}}"

# ── Logging helper ──────────────────────────────────────────────────────────
LOG_FILE="${BEADS_HOOK_LOG:-}"
if [[ -z "$LOG_FILE" && -d "$project_dir/.beads/runner-logs" ]]; then
  LOG_FILE="$project_dir/.beads/runner-logs/hook-events.jsonl"
fi

log_event() {  # log_event <decision> <failed_csv> [extra_json]
  [[ -z "$LOG_FILE" ]] && return 0
  local now decision failed extra
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '?')"
  decision="$1"; failed="${2:-}"; extra="${3:-{\}}"
  jq -nc \
    --arg ts "$now" \
    --arg event "$event_name" \
    --arg decision "$decision" \
    --arg task_id "${task_id:-}" \
    --arg session_id "$session_id" \
    --arg failed "$failed" \
    --argjson extra "$extra" \
    '{ts:$ts, event:$event, decision:$decision, task_id:$task_id, session_id:$session_id, failed:$failed, extra:$extra}' \
    >> "$LOG_FILE" 2>/dev/null || true
}

# ── 1. Gate: runner-spawned sessions only ───────────────────────────────────
task_id=""  # declare early so log_event references work
if [[ "${BEADS_RUNNER_SESSION:-}" != "1" ]]; then
  log_event allow "" '{"reason":"not_runner_session"}'
  exit 0
fi

# ── 2. Gate: must have a task id ────────────────────────────────────────────
task_id="${CURRENT_TASK_ID:-}"
if [[ -z "$task_id" && -f "$project_dir/.beads/runner-logs/current-task" ]]; then
  task_id="$(tr -d '[:space:]' < "$project_dir/.beads/runner-logs/current-task" 2>/dev/null || echo '')"
fi
if [[ -z "$task_id" ]]; then
  log_event allow "" '{"reason":"no_task_id"}'
  exit 0
fi

# ── 3. Gate: PreToolUse only on close-shaped commands ───────────────────────
# Fail-open matcher: if the command looks anything like closing a bead, fire
# the hook. False positive cost = one extra log entry; false negative cost =
# the discipline gate is bypassed. Catches:
#   bd close <ids>         bd done <ids>          (and aliases)
#   bd update <id> --status=closed
#   bd update <id> --status closed
#   bd update <id> --status='closed' / "closed"   (shell-quoted value)
#   bd update <id> -s closed / -s 'closed' / -s "closed"
is_close_cmd=0
multi_id_close=0
if [[ "$event_name" == "PreToolUse" ]]; then
  if [[ "$tool_name" != "Bash" ]]; then
    log_event allow "" '{"reason":"not_bash_tool"}'
    exit 0
  fi
  # Pattern A: `bd close|done <args>` direct form
  if printf '%s' "$tool_command" | grep -qE '\bbd[[:space:]]+(close|done)([[:space:]]|$)'; then
    is_close_cmd=1
    # Extract args after `bd close|done` and count non-flag tokens (the ids).
    # If >1 id, deny — checks below only validate CURRENT_TASK_ID; closing
    # sibling beads in the same call would bypass discipline for the others.
    # BSD sed (macOS) does not support `\b`; use an explicit boundary class.
    # `(^|[^[:alnum:]_])bd ` ensures `mybd close` doesn't match but `bd close`,
    # `/usr/bin/bd close`, `;bd close`, etc. do.
    args="$(printf '%s' "$tool_command" | sed -nE 's/.*(^|[^[:alnum:]_])bd[[:space:]]+(close|done)[[:space:]]+(.*)/\3/p')"
    # Strip trailing pipe/redirect tail so `bd close foo | tail` doesn't count `tail` as an id.
    # Single regex (not sequential `${var%%X*}` strips): the old four-step form ran the strips
    # in the order `| ; & >`, so for `bd close foo 2>&1 | tail` the `|` strip yielded `foo 2>&1 `,
    # the `&` strip yielded `foo 2>`, and the `>` strip left `foo 2` — two tokens, false-positive
    # multi_id_close. Cut at the first shell-special metachar AND eat any preceding ` <digits>` FD
    # prefix so the `2` from `N>&M` doesn't survive as a phantom id.
    args="$(printf '%s' "$args" | sed -E 's/[[:space:]]*[0-9]*[|;&<>].*$//')"
    id_count=0
    for tok in $args; do
      [[ "$tok" == -* ]] && continue
      id_count=$((id_count + 1))
    done
    if (( id_count > 1 )); then
      multi_id_close=1
    fi
  fi
  # Pattern B: `--status … closed` (any whitespace/quote/=  between flag and value)
  if printf '%s' "$tool_command" | grep -qE -- '--status[=[:space:]]+["'"'"']?closed(["'"'"'[:space:]]|$)'; then
    is_close_cmd=1
  fi
  # Pattern C: `-s … closed` (short form)
  if printf '%s' "$tool_command" | grep -qE -- '(^|[[:space:]])-s[=[:space:]]+["'"'"']?closed(["'"'"'[:space:]]|$)'; then
    is_close_cmd=1
  fi
  if (( is_close_cmd == 0 )); then
    log_event allow "" '{"reason":"not_close_cmd"}'
    exit 0
  fi
fi

# ── 4. Gate: Stop hook respects stop_hook_active ────────────────────────────
if [[ "$event_name" == "Stop" && "$stop_hook_active" == "true" ]]; then
  log_event allow "" '{"reason":"stop_hook_active"}'
  exit 0
fi

# ── 5. Five (six) checks ────────────────────────────────────────────────────
failures=()
remediation=()

claude_pid="$PPID"  # verified: Claude Code spawns the hook directly, so PPID==claude pid (probed against `claude -p` empirically — see claude-tools-td0y debrief)

# Check 0: multi-id close — deny outright (the checks below only validate
# CURRENT_TASK_ID; closing sibling beads in the same call would silently
# bypass discipline for every id except CURRENT_TASK_ID).
if (( multi_id_close == 1 )); then
  failures+=("multi_id_close")
  remediation+=("Multi-bead close detected. The close-discipline checks only validate CURRENT_TASK_ID ($task_id). Run one bead per close call so each can be properly verified (commit references, debrief, wrapup marker). Example: instead of 'bd close foo bar baz', run 'bd close foo' then 'bd close bar' then 'bd close baz'.")
fi

# Build MCP exclusion regex from ~/.claude.json (canonical source of registered MCPs).
# Each line: command + space-joined args. We escape regex metachars and OR them.
mcp_excludes=()
if command -v jq >/dev/null 2>&1 && [[ -f "$HOME/.claude.json" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    mcp_excludes+=("$line")
  done < <(jq -r '.mcpServers // {} | to_entries[] | .value.command + " " + ((.value.args // []) | join(" "))' "$HOME/.claude.json" 2>/dev/null)
fi
# Generic fallback pattern for node-mcp-* layouts not yet registered
generic_mcp_re='node[^[:space:]]*[[:space:]][^[:space:]]*/mcp-[^/[:space:]]+/(server|index)\.(mjs|js|cjs)'

is_mcp() {
  local cmd="$1" ex
  # Guarded array expansion — `${arr[@]}` errors under `set -u` on bash 3.2
  # (macOS default /bin/bash) when arr is empty. The `${arr[@]+...}` pattern
  # makes empty-array iteration a no-op. Matches the runner's existing style.
  for ex in "${mcp_excludes[@]+"${mcp_excludes[@]}"}"; do
    # Substring match (cheap, no regex escape needed)
    if [[ "$cmd" == *"$ex"* ]]; then
      return 0
    fi
  done
  if printf '%s' "$cmd" | grep -qE "$generic_mcp_re"; then
    return 0
  fi
  return 1
}

# Check 1: orphan bg processes ────────────────────────────────────────────
orphan_descs=()
if command -v pgrep >/dev/null 2>&1; then
  for pid in $(pgrep -P "$claude_pid" 2>/dev/null); do
    cmd="$(ps -o command= -p "$pid" 2>/dev/null)"
    [[ -z "$cmd" ]] && continue
    if is_mcp "$cmd"; then
      continue
    fi
    orphan_descs+=("pid=$pid cmd=$(printf '%s' "$cmd" | cut -c1-120)")
  done
fi

if (( ${#orphan_descs[@]} > 0 )); then
  # Try to also enumerate /tmp/claude-$UID/.../tasks/*.output filenames so the
  # agent can map orphans to the task ids it spawned. Best-effort; the orphan
  # list above is the authoritative signal.
  active_tasks=""
  if [[ -n "$session_id" ]]; then
    slug="$(printf '%s' "$project_dir" | sed 's|/|-|g')"
    task_dir="/tmp/claude-$(id -u)/${slug}/${session_id}/tasks"
    if [[ -d "$task_dir" ]]; then
      active_tasks="$(find "$task_dir" -maxdepth 1 -name '*.output' -type f 2>/dev/null \
        | xargs -n1 basename 2>/dev/null | sed 's/\.output$//' | paste -sd ',' - 2>/dev/null || echo '')"
    fi
  fi

  failures+=("orphan_bg_tasks")
  msg="${#orphan_descs[@]} background process(es) are still alive under this session:"$'\n'
  for d in "${orphan_descs[@]}"; do
    msg+="  - $d"$'\n'
  done
  if [[ -n "$active_tasks" ]]; then
    msg+=$'\n'"Background task ids in your session: $active_tasks"$'\n'
  fi
  msg+=$'\n'"Use the tool you used to spawn each background task to read its pending output. Stop any that are no longer needed. Do NOT end the turn while orphan children exist — Node will not exit, and the runner's post-terminal watchdog will SIGKILL the process after ${POST_TERMINAL_GRACE:-60}s."
  remediation+=("$msg")
fi

# Check 2: dirty tree ─────────────────────────────────────────────────────
if command -v git >/dev/null 2>&1 && [[ -d "$project_dir/.git" ]]; then
  # Exclude .beads/issues.jsonl (bd close itself writes to it as a side-effect;
  # authoritative state is in Dolt — claude-tools-u4ms), beads/* debrief files,
  # runner-logs, the .stop-beads signal file.
  # Use grep -vE on the porcelain output (2-char status code + space + path).
  # --untracked-files=all expands directory entries so an untracked
  # .beads/foo-debrief.txt appears as a file we can filter, not as `?? .beads/`.
  # (Note: `-u all` is wrong — git parses "all" as a pathspec; must use `=` or `-uall`.)
  dirty="$(git -C "$project_dir" status --porcelain --untracked-files=all 2>/dev/null \
    | grep -vE '^.{3}(\.beads/issues\.jsonl$|\.beads/[^/]*-debrief\.txt$|\.beads/runner-logs/|\.stop-beads$)' \
    || true)"
  if [[ -n "$dirty" ]]; then
    failures+=("dirty_tree")
    msg="Uncommitted changes in the working tree (issues.jsonl / debrief / runner-log scratch files excluded):"$'\n'"$dirty"$'\n\n'
    msg+="Commit them — referencing the bead id ($task_id) in the message so 'git log --grep' can find them — or 'git restore <path>' / 'git clean' if they were exploratory. Do NOT close a bead with uncommitted work; the next runner iteration would smuggle this diff into an unrelated bead's commit."
    remediation+=("$msg")
  fi
fi

# Check 3: close-without-commit consistency (Stop only) ───────────────────
if [[ "$event_name" == "Stop" ]] && command -v bd >/dev/null 2>&1; then
  status="$(bd show "$task_id" --json 2>/dev/null | jq -r '.[0].status // empty' 2>/dev/null)"
  if [[ "$status" == "closed" ]]; then
    if command -v git >/dev/null 2>&1 && [[ -d "$project_dir/.git" ]]; then
      # NB: --format=%h (and --pretty=format:%h) emit NO trailing newline, so
      # `wc -l` on a single matching hash returns 0 — indistinguishable from
      # no-match. Test emptiness directly instead. (claude-tools-m3mx)
      grep_out="$(git -C "$project_dir" log --grep="$task_id" -1 --since='1 hour ago' --format=%h 2>/dev/null)"
      if [[ -z "$grep_out" ]]; then
        failures+=("close_without_commit")
        remediation+=("Bead $task_id is closed but no commit in the last hour references its id. Either (a) commit referencing $task_id in the message, or (b) 'bd reopen $task_id' and finish the work properly. A closed bead with no commit is the exact failure mode this hook exists to prevent (incident: thirsty-backend-krxv).")
      fi
    fi
  fi
fi

# Check 4: /wrapup invoked — accept EITHER signal (claude-tools-fh87 hybrid) ─
#   (a) transcript signal (primary, content-decoupled): a Skill tool_use whose
#       input skill name glob-matches $BEADS_WRAPUP_SKILL_PATTERN, recorded in
#       THIS session's transcript_path.
#   (b) marker signal (secondary, durable audit trail): a 'wrapup-reviewed:'
#       line in the bead notes (written by the wrapup skill's final step).
# Only enforced when a wrapup-pattern skill actually exists in the workspace
# (nothing to enforce otherwise — preserves the "no wrapup skill → skip" path).
#
# Why a hybrid: check #4 used to trust ONLY the marker, an agent-authored line
# gated on each workspace's wrapup skill telling it to write it. N workspaces ×
# M skill edits = a silent drift surface — drop the marker step in any workspace
# and that workspace's workers burn the 8-block cap on every close. The
# transcript path proves wrapup ran from the tool-call record itself, so the
# skill content can stay tailored per-workspace without coordination.
#
# Transcript JSONL shape (verified claude-tools-fh87 against live transcripts):
#   {"type":"assistant", ..., "message":{"content":[
#       {"type":"tool_use","name":"Skill","input":{"skill":"wrapup"}, ...}]}}
# We scan line-by-line (NOT `jq -s` over the whole file): the transcript is
# appended live, so its final line may be a partial write — slurping would abort
# the entire parse on that one malformed line. Per-line jq tolerates it. The
# grep -F prefilter keeps the scan cheap on long transcripts; if the writer's
# formatting ever drifts past it we just miss the transcript signal and fall
# back to the marker (graceful), never a false block.
wrapup_pattern="${BEADS_WRAPUP_SKILL_PATTERN:-wrapup*}"
shopt -s nullglob
_wrapup_skills=("$project_dir"/.claude/skills/$wrapup_pattern/SKILL.md)
shopt -u nullglob
if (( ${#_wrapup_skills[@]} > 0 )); then
  wrapup_ok=0
  wrapup_checkable=0  # did we have ANY way to verify? if not, skip (don't block)

  # (a) transcript signal
  transcript_path="$(jqr '.transcript_path // empty')"
  if [[ -n "$transcript_path" && -f "$transcript_path" ]] && command -v jq >/dev/null 2>&1; then
    wrapup_checkable=1
    while IFS= read -r _skill; do
      [[ -z "$_skill" ]] && continue
      # Plugin skills serialize namespaced ("beads:close", "<plugin>:wrapup");
      # bare workspace skills serialize as just "wrapup". Match the pattern
      # against BOTH the full name and the trailing segment (after the last ':')
      # so the default "wrapup*" catches a plugin-installed wrapup too, while a
      # deliberately namespaced BEADS_WRAPUP_SKILL_PATTERN still matches the full.
      # shellcheck disable=SC2053  — RHS glob match against the configured pattern is intentional
      if [[ "$_skill" == $wrapup_pattern || "${_skill##*:}" == $wrapup_pattern ]]; then wrapup_ok=1; break; fi
    done < <(grep -F '"name":"Skill"' "$transcript_path" 2>/dev/null \
               | while IFS= read -r _line; do
                   printf '%s' "$_line" \
                     | jq -r '.message.content[]? | select(.type=="tool_use" and .name=="Skill") | .input.skill // empty' 2>/dev/null
                 done)
  fi

  # (b) marker signal (only consulted if the transcript didn't already prove it)
  if (( wrapup_ok == 0 )) && command -v bd >/dev/null 2>&1; then
    wrapup_checkable=1
    notes="$(bd show "$task_id" --long --json 2>/dev/null | jq -r '.[0].notes // ""' 2>/dev/null)"
    if printf '%s' "$notes" | grep -q 'wrapup-reviewed:'; then
      wrapup_ok=1
    fi
  fi

  if (( wrapup_checkable == 1 && wrapup_ok == 0 )); then
    failures+=("wrapup_not_invoked")
    remediation+=("The /wrapup skill has not been invoked for $task_id (no Skill(wrapup) tool-call in this session's transcript, and no 'wrapup-reviewed:' marker in bead notes). Run /wrapup before closing — it enforces code review, quality gates, production-risk analysis, and (recommended) writes the marker as its final step. The skill is at .claude/skills/wrapup/SKILL.md (or your workspace's wrapup-pattern skill).")
  fi
fi

# Check 5: debrief presence ───────────────────────────────────────────────
if command -v bd >/dev/null 2>&1; then
  notes="$(bd show "$task_id" --long --json 2>/dev/null | jq -r '.[0].notes // ""' 2>/dev/null)"
  if [[ -z "$notes" || ${#notes} -lt 40 ]]; then
    failures+=("missing_debrief")
    remediation+=("No debrief notes on $task_id. Append a debrief before closing: bd update $task_id --append-notes \"<what you did, difficulties or unexpected behavior, anything you weren't sure about, follow-up suggestions>\"")
  fi
fi

# ── 6. Emit decision ────────────────────────────────────────────────────────
if (( ${#failures[@]} == 0 )); then
  log_event allow ""
  exit 0
fi

failed_csv="$(printf '%s,' "${failures[@]}" | sed 's/,$//')"

reason="BLOCKED ($event_name on bead $task_id): $failed_csv"$'\n\n'
for r in "${remediation[@]}"; do
  reason+="$r"$'\n\n'
done
reason+="Fix all of the above, then retry. This hook intentionally returns every failure at once so you can address them in a single pass — Stop hooks are capped at 8 consecutive blocks before being overridden."

log_event block "$failed_csv"

if [[ "$event_name" == "PreToolUse" ]]; then
  jq -n --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
else
  jq -n --arg reason "$reason" '{
    decision: "block",
    reason: $reason
  }'
fi

exit 0
