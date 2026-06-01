#!/bin/bash
# beads-runner/hooks/auto-label-live-session.sh
#
# PreToolUse(Bash) hook — Mechanism B of the cross-process ownership stack
# (inbox-lifecycle §8.3.4; siblings: Mechanism A = claude-tools-uxc1, Mechanism
# C = claude-tools-uxc3). Filed as claude-tools-n6ek.
#
# PURPOSE — when a NON-runner agent (a live interactive Claude session, or a
# human's manual `bd update` from a terminal) sets a bead `in_progress`,
# auto-attach the `human-live-session` label so the runner's existing
# RUNNER_NO_CLAIM_LABELS hard gate (runner.sh:76, :1578-1588) refuses to
# autonomously claim it — WITHOUT depending on the interactive agent remembering
# to label it. Mechanism A's claim-file walk already SKIPS a no-claim
# `in_progress` bead (it never *adopts* it); this hook is what then keeps the
# runner from re-claiming the bead off `bd ready` once it cycles back to `open`,
# and makes the human ownership visible on the Board/Inbox.
#
# This hook is a LABELLER, not a gate. It ALWAYS allows the bd command to
# proceed (exit 0, no stdout). Its only effect is the side-effect `bd label add`.
# It NEVER blocks (never emits permissionDecision=deny).
#
# ── Runner-identity detection — THE critical safety property (§8.3.6) ─────────
# If this hook fired inside a runner-spawned worker and labelled the runner's OWN
# in-flight bead, the runner would then refuse its own work via
# RUNNER_NO_CLAIM_LABELS → instant deadlock. §8.3.6 calls this "the most
# important test case." We detect "am I inside the runner?" from the env the v2
# runner stamps onto the `claude -p` worker at the spawn site:
#   • BEADS_RUNNER_SESSION=1   — the dedicated runner-session boolean, set as a
#                                command-prefix env on `claude -p` (runner.sh:2121).
#                                This is the SAME marker close-checklist.sh:101
#                                relies on, which PROVES it reaches PreToolUse
#                                hook subprocesses of the worker.
#   • CURRENT_TASK_ID=<id>     — `export`ed by the runner (runner.sh:2006);
#                                belt-and-suspenders second signal.
# EITHER present ⇒ runner ⇒ pass through with NO label. (The v1 design named a
# `RUNNER_PID` marker near :309; v2's BEADS_RUNNER_SESSION is the equivalent that
# is ALREADY present and propagating, so claude-tools-n6ek adds no new export.)
#
# Detection is env-ONLY. We deliberately do NOT fall back to the
# `.beads/runner-logs/current-task` file (as close-checklist.sh does for the
# task-id) for the runner verdict: that file persists in the workspace, so an
# interactive session running in a workspace where the runner ever ran would
# read it and wrongly suppress labelling for EVERY interactive bead.
#
# Bias: we err toward "I am the runner." A false-runner verdict only loses a
# label (Mechanism A still SKIPS the no-claim orphan, so no dup-work). A
# false-interactive verdict deadlocks the runner. Pass-through is the safe miss.
#
# ── Contract surface (DO NOT change without re-verifying against the docs) ────
#   Input stdin (PreToolUse): { hook_event_name="PreToolUse", tool_name,
#                               tool_input.command, session_id, cwd, ... }
#   Allow / pass-through      : exit 0, no stdout (on EVERY path).
#
# Env consumed:
#   BEADS_RUNNER_SESSION       "1" ⇒ runner ⇒ pass through (no label)
#   CURRENT_TASK_ID            non-empty ⇒ runner ⇒ pass through (no label)
#   CLAUDE_PROJECT_DIR         workspace root (for the log file path)
#   BEADS_LIVE_SESSION_LABEL   label to apply (default: human-live-session)
#   BEADS_HOOK_LOG             override log file path
#
# Tools assumed present: jq, bd. Missing jq ⇒ cannot parse the tool input ⇒
# pass through (the safe miss); missing bd ⇒ label add no-ops, pass through.

set -uo pipefail

# ── 0. Read stdin ────────────────────────────────────────────────────────────
INPUT_JSON="$(cat 2>/dev/null || echo '{}')"

jqr() {  # jqr <jq-expr> → echoes value or empty on any error
  printf '%s' "$INPUT_JSON" | jq -r "$1" 2>/dev/null || true
}

# No jq ⇒ we cannot reliably parse the command out of the JSON. Pass through
# (the safe miss — Mechanism A still skips no-claim orphans).
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

event_name="$(jqr '.hook_event_name // empty')"
tool_name="$(jqr '.tool_name // empty')"
tool_command="$(jqr '.tool_input.command // empty')"
cwd_stdin="$(jqr '.cwd // empty')"
session_id="$(jqr '.session_id // empty')"

project_dir="${CLAUDE_PROJECT_DIR:-${cwd_stdin:-$PWD}}"
LIVE_LABEL="${BEADS_LIVE_SESSION_LABEL:-human-live-session}"

# ── Logging helper (best-effort; never fails the hook) ───────────────────────
LOG_FILE="${BEADS_HOOK_LOG:-}"
if [[ -z "$LOG_FILE" && -d "$project_dir/.beads/runner-logs" ]]; then
  LOG_FILE="$project_dir/.beads/runner-logs/hook-events.jsonl"
fi
log_event() {  # log_event <decision> [ids_csv]
  [[ -z "$LOG_FILE" ]] && return 0
  local now decision ids
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '?')"
  decision="$1"; ids="${2:-}"
  jq -nc \
    --arg ts "$now" \
    --arg event "${event_name:-PreToolUse}" \
    --arg hook "auto-label-live-session" \
    --arg decision "$decision" \
    --arg label "$LIVE_LABEL" \
    --arg ids "$ids" \
    --arg session_id "$session_id" \
    '{ts:$ts, event:$event, hook:$hook, decision:$decision, label:$label, ids:$ids, session_id:$session_id}' \
    >> "$LOG_FILE" 2>/dev/null || true
}

# ── 1. Gate: PreToolUse on the Bash tool only ────────────────────────────────
# The matcher wires this to Bash, but be defensive — any other event/tool is a
# silent pass-through.
if [[ -n "$event_name" && "$event_name" != "PreToolUse" ]]; then
  exit 0
fi
if [[ -n "$tool_name" && "$tool_name" != "Bash" ]]; then
  exit 0
fi
[[ -z "$tool_command" ]] && exit 0

# ── 2. Gate: command must be a `bd update` that drives a bead in_progress ────
# Two shapes (§8.3.4 + verified against `bd update --help`):
#   • `bd update <id...> --status=in_progress`  (also `--status in_progress`,
#                                                 `-s in_progress`, quoted value)
#   • `bd update <id...> --claim`  (--claim "sets … status to in_progress")
# Fail-CLOSED matcher: if it doesn't clearly match, do nothing. (A missed match
# only loses a label; Mechanism A still skips the no-claim orphan.)
is_update_cmd=0
if printf '%s' "$tool_command" | grep -qE '\bbd[[:space:]]+update\b'; then
  if printf '%s' "$tool_command" \
       | grep -qE -- '(--status|(^|[[:space:]])-s)[[:space:]=]+["'\'']?in_progress\b'; then
    is_update_cmd=1
  elif printf '%s' "$tool_command" | grep -qE -- '(^|[[:space:]])--claim([[:space:]]|=|$)'; then
    is_update_cmd=1
  fi
fi
if [[ $is_update_cmd -eq 0 ]]; then
  # Not a matching command — silent pass-through, no log (avoid noise on every
  # unrelated Bash call in an interactive session).
  exit 0
fi

# ── 3. Runner-identity gate — env ONLY (see header). Presence ⇒ pass through ──
if [[ "${BEADS_RUNNER_SESSION:-}" == "1" || -n "${CURRENT_TASK_ID:-}" ]]; then
  log_event passthrough_runner ""
  exit 0
fi

# ── 4. Interactive session — extract the bead id(s) and apply the label ──────
# Tokenise the command after the `update` subcommand. Collect positional,
# bead-id-shaped tokens; skip flags and the values of value-taking flags so a
# label value (e.g. `runner-reliability` after `--add-labels`) or a `--set-labels`
# flag token is never mistaken for a bead id.
#
# Known, deliberate limitations (all in the SAFE over-label direction — they can
# only ADD a label in an interactive session; the §8.3.6 deadlock is impossible
# because the runner-identity gate above short-circuits before we reach here):
#   • Flat token stream — no `;`/`&&`/`||`/`|` segment boundaries. A second
#     `bd update <id> --claim` chained after a non-matching `bd update <id2>
#     --status=open` would label BOTH ids. Rare; harmless (extra human-live-session
#     label a human can lift).
#   • The §2 matcher greps the whole string, so a `--claim`/`in_progress`
#     substring inside a quoted flag VALUE (e.g. `--notes "… --claim …"`) can
#     trip it. Correctly distinguishing requires a real shell parser; not worth
#     it for a fail-open labeller.
ids=()
read -r -a _toks <<< "$tool_command"
seen_update=0
prev_value_flag=0
# Flags that consume the FOLLOWING token as their value (space-separated form).
# An id-shaped value after one of these (e.g. `--add-labels runner-reliability`)
# must NOT be treated as a bead id.
value_flag_re='^(-s|--status|-p|--priority|-a|--assignee|-t|--title|--type|--epic|--parent|--defer|--estimate|--actor|--session|--db|-C|--directory|--label|--add-labels|--remove-labels|--set-labels|--notes|--append-notes|--body-file|--design|--dolt-auto-commit)$'
id_re='^[a-z][a-z0-9]*(-[a-z0-9]+)+$'
for tok in "${_toks[@]}"; do
  if [[ $seen_update -eq 0 ]]; then
    [[ "$tok" == "update" ]] && seen_update=1
    continue
  fi
  if [[ "$tok" == -* ]]; then
    # A `--flag=value` token is self-contained; a bare value-flag consumes next.
    if [[ "$tok" == *=* ]]; then
      prev_value_flag=0
    elif [[ "$tok" =~ $value_flag_re ]]; then
      prev_value_flag=1
    else
      prev_value_flag=0   # boolean flag (e.g. --claim) — does NOT consume next
    fi
    continue
  fi
  if [[ $prev_value_flag -eq 1 ]]; then
    prev_value_flag=0     # this token is the preceding flag's value, not an id
    continue
  fi
  # Positional token. Strip ONE matched pair of surrounding quotes — `read -a`
  # word-splits but leaves quote chars in place, so a quoted id like
  # `"claude-tools-x"` would otherwise fail the id pattern and lose its label.
  case "$tok" in
    \"*\") tok="${tok#\"}"; tok="${tok%\"}" ;;
    \'*\') tok="${tok#\'}"; tok="${tok%\'}" ;;
  esac
  # Is it bead-id shaped?
  if [[ "$tok" =~ $id_re ]]; then
    ids+=("$tok")
  fi
done

if [[ ${#ids[@]} -eq 0 ]]; then
  log_event no_ids_extracted ""
  exit 0
fi

# Apply the label to each id. Best-effort and non-fatal: a failure here must
# NEVER block the user's bd command. Runs synchronously BEFORE we exit 0 so the
# label lands before the original `bd update` proceeds (and so it doesn't race
# the bd write). `bd label add` is a different command shape, so it cannot
# re-trigger this matcher (no recursion).
applied=()
for id in "${ids[@]}"; do
  if command -v bd >/dev/null 2>&1; then
    bd label add "$id" "$LIVE_LABEL" >/dev/null 2>&1 || true
  fi
  applied+=("$id")
done

IFS=','; log_event labelled "${applied[*]}"; unset IFS
exit 0
