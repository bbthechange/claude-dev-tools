#!/bin/bash
# dg-author-bridge.sh — DG_AUTHOR_CMD shim for the Flow B BACKSTOP path.
#
# Wires the runner-side relaxed-primary autoflip (sr_route_stuck →
# dg_from_worker_ask → dg__author) to the real dossier-builder agent, so a
# slipped STUCK_NEEDS_HUMAN no longer falls back to the deterministic jq
# shape-coercer. Mirrors the hardened flag set the MCP-askbrian server
# learned (claude-tools-cvj and its followups: --system-prompt REPLACE,
# --output-format json, explicit Bash allowlist, AskUserQuestion / *PlanMode
# disallowed, --max-turns cap).
#
# Contract (per lib/dossier-gen.sh dg__author):
#   stdin   — generation_input JSON (gi). At minimum carries .id, .bead_ref,
#             .source.{tldr,ask,options,recommendation,reversible}; the
#             runner-side gi for a worker_stuck fire comes from sr_worker_ask
#             which is intentionally THIN (the rich material lives in the
#             bead's notes — we pull those ourselves below).
#   stdout  — a single JSON object {body:{…}, items:[…]} on success.
#   rc=0    — success.
#   rc!=0   — failure (dg__author treats it as agent_unavailable / _invalid_
#             output and falls back to the jq path). stderr is for diagnostics.
#
# The bead notes are the missing context_dump: a relaxed-primary fire means
# the agent wrote a rich STUCK_NEEDS_HUMAN note instead of calling ask-brian,
# so the diagnostic material is sitting on the bead. We splice it in so the
# builder sees the same caliber of input the MCP path would have given it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
BUILDER_PROMPT="${DOSSIER_BUILDER_PROMPT_PATH:-$SCRIPT_DIR/../agents/dossier-builder.system.md}"
BUILDER_MODEL="${DOSSIER_BUILDER_MODEL:-claude-opus-4-7}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
WORKSPACE_DIR="${DG_AUTHOR_BRIDGE_WORKSPACE:-$PWD}"

# The bridge log lives next to the specialist logs — same self-gitignored
# .beads/runner-logs/ surface (BC-27). Captures the full JSON envelope from
# claude -p plus the parse outcome so we can post-mortem a thin or invalid
# fire without re-running it.
LOG_DIR="$WORKSPACE_DIR/.beads/runner-logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
[[ -f "$LOG_DIR/.gitignore" ]] || printf '*\n!.gitignore\n' > "$LOG_DIR/.gitignore" 2>/dev/null || true
TS="$(date -u +%Y%m%dT%H%M%SZ)"

die() {
  echo "dg-author-bridge: $1" >&2
  exit "${2:-1}"
}

command -v jq >/dev/null 2>&1 || die "jq required" 2
command -v "$CLAUDE_BIN" >/dev/null 2>&1 || die "claude CLI not on PATH (CLAUDE_BIN=$CLAUDE_BIN)" 2
[[ -f "$BUILDER_PROMPT" ]] || die "builder prompt not found: $BUILDER_PROMPT" 2
[[ -d "$WORKSPACE_DIR" ]] || die "workspace not a directory: $WORKSPACE_DIR" 2

if [[ -t 0 ]]; then
  die "stdin is a tty; pipe generation_input JSON in" 2
fi
GI="$(cat)"
[[ -n "$GI" ]] || die "empty stdin (expected generation_input JSON)" 2
printf '%s' "$GI" | jq -e 'type=="object"' >/dev/null 2>&1 \
  || die "stdin not a JSON object" 2

DOSSIER_ID="$(printf '%s' "$GI" | jq -r '.id // ""')"
BEAD_REF="$(printf '%s' "$GI"   | jq -r '.bead_ref // ""')"
[[ -n "$DOSSIER_ID" ]] || die "gi.id missing" 2
[[ -n "$BEAD_REF"   ]] || die "gi.bead_ref missing" 2

STREAM_FILE="$LOG_DIR/dg-author-bridge-$BEAD_REF-$TS.json"

# Pull the rich material the runner-side raw ask doesn't carry. `bd show` is
# the load-bearing source — its DESCRIPTION + NOTES sections are where the
# slipped agent wrote the diagnostic that should have gone into a context_
# dump. Failure is non-fatal: the builder can still work from gi.source.* +
# its own Read/Grep in-workspace exploration; we just lose the agent's prior
# narrative. The builder's system prompt explicitly tells it to run `bd
# show <bead_ref>` itself anyway, so this is belt-and-suspenders.
BEAD_DUMP=""
if command -v bd >/dev/null 2>&1; then
  # Short timeout — bd has been observed to hang in this repo's history; the
  # bridge must not inherit that. If timeout/gtimeout is unavailable, fall
  # through to a bare call (the outer dg__author timeout still bounds us).
  if command -v timeout >/dev/null 2>&1; then
    BEAD_DUMP="$(timeout 10s env BEADS_SKIP_IDENTITY_CHECK=1 bd show "$BEAD_REF" 2>/dev/null || true)"
  elif command -v gtimeout >/dev/null 2>&1; then
    BEAD_DUMP="$(gtimeout 10s env BEADS_SKIP_IDENTITY_CHECK=1 bd show "$BEAD_REF" 2>/dev/null || true)"
  else
    BEAD_DUMP="$(BEADS_SKIP_IDENTITY_CHECK=1 bd show "$BEAD_REF" 2>/dev/null || true)"
  fi
fi

# Compose the builder input shape declared in
# beads-runner/agents/dossier-builder.system.md (input shape on stdin).
# Mirror buildBuilderInput() in mcp-askbrian/server.mjs.
BUILDER_INPUT="$(jq -cn \
  --arg did   "$DOSSIER_ID" \
  --arg bref  "$BEAD_REF" \
  --arg ws    "$WORKSPACE_DIR" \
  --arg dump  "$BEAD_DUMP" \
  --argjson gi "$GI" '
  {
    dossier_id:    $did,
    bead_ref:      $bref,
    workspace_dir: $ws,
    question:      ($gi.source.ask  // $gi.source.tldr // "Decision required."),
    options:       ($gi.source.options // []),
    recommendation:($gi.source.recommendation // null),
    reversible:    ($gi.source.reversible // ""),
    # context_dump is the load-bearing input per the builder prompt. For
    # the runner-side BACKSTOP, the rich material is the bead itself
    # (description + STUCK_NEEDS_HUMAN note the slipped agent wrote);
    # splice it in so the builder has more than the thin sr_worker_ask
    # stub to chew on.
    context_dump: (
      "RUNNER-BACKSTOP CONTEXT (the worker hit a stuck condition and"
      + " did not call ask-brian; the rich material is in the bead notes"
      + " below; gather more via Read/Grep/Bash bd as the system prompt"
      + " directs).\n\n"
      + "=== bd show " + $bref + " ===\n"
      + (if ($dump|length) > 0 then $dump else "(bd show returned empty)" end)
    )
  }')"

# Time budget: builder typically takes 78-180s per cvj observations; allow up
# to 5 min like the MCP path. dg__author wraps us in its own `timeout`
# (DG_AUTHOR_TIMEOUT_SEC, default 90); the caller must bump that to match.
# When called inside dg__author with DG_AUTHOR_TIMEOUT_SEC>=300, the inner
# timeout is the effective cap; otherwise the outer one cuts us off first.
ENV_TIMEOUT="${DG_AUTHOR_BRIDGE_TIMEOUT_SEC:-300}"

# Pick a timeout binary if available — macOS lacks GNU `timeout` by default
# but ships it as `gtimeout` under coreutils. Fall back to bare invocation
# (the outer dg__author already wraps us in its own `timeout`/`gtimeout`,
# so we are not unprotected — this inner timeout is defense-in-depth).
TIMEOUT_PREFIX=()
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_PREFIX=(timeout "${ENV_TIMEOUT}s")
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_PREFIX=(gtimeout "${ENV_TIMEOUT}s")
fi

# Invoke claude -p with the hardened flag set from runBuilder
# (mcp-askbrian/server.mjs). Stream-json is NOT used here — we want the
# single .result envelope so we can parse it as JSON.
ENVELOPE=""
RC=0
ENVELOPE="$(
  cd "$WORKSPACE_DIR" || exit 70
  printf '%s' "$BUILDER_INPUT" | "${TIMEOUT_PREFIX[@]+${TIMEOUT_PREFIX[@]}}" "$CLAUDE_BIN" -p \
    --system-prompt "@$BUILDER_PROMPT" \
    --add-dir "$WORKSPACE_DIR" \
    --output-format json \
    --permission-mode acceptEdits \
    --allowedTools Read Grep Glob Bash \
    --disallowedTools AskUserQuestion EnterPlanMode ExitPlanMode \
    --max-turns 30 \
    --model "$BUILDER_MODEL" \
    --no-chrome \
    2>>"$STREAM_FILE.stderr"
)" || RC=$?

# Capture the envelope for post-mortem regardless of outcome.
printf '%s' "$ENVELOPE" > "$STREAM_FILE" 2>/dev/null || true

# 124/137 = timeout SIGTERM/SIGKILL escalation (matches dg__author classification).
if [[ "$RC" -eq 124 || "$RC" -eq 137 ]]; then
  die "builder timed out after ${ENV_TIMEOUT}s (envelope: $STREAM_FILE; stderr: $STREAM_FILE.stderr)" 124
fi
if [[ "$RC" -ne 0 ]]; then
  die "claude -p exited $RC (envelope: $STREAM_FILE; stderr: $STREAM_FILE.stderr)" "$RC"
fi
[[ -n "$ENVELOPE" ]] || die "claude produced empty envelope (stderr: $STREAM_FILE.stderr)" 1

# claude -p --output-format json emits one envelope: {result, ...}. The
# model's text output is `.result`. Strip a leading ```json fence if the
# model added one (defensive — the builder prompt forbids fences but the
# MCP path observed this enough times to defend against it).
RESULT="$(printf '%s' "$ENVELOPE" | jq -r '.result // .text // ""' 2>/dev/null)"
[[ -n "$RESULT" ]] || die "envelope has no .result (envelope: $STREAM_FILE)" 1

# Strip ```json fences if present anywhere (anchored 1s/$s left blank lines
# the strict shape-check tolerated but the looser fence styles the model
# emits in practice — leading whitespace, trailing newline — would slip).
# Delete any line that is solely a fence open/close marker.
CLEANED="$(printf '%s' "$RESULT" \
  | sed -E '/^[[:space:]]*```(json)?[[:space:]]*$/d')"

# Honor the structured refusal shape: when the builder returns
# {refuse:true,...}, that is an honest "context too thin" signal — fail rc=1
# so dg__author falls through to the labeled-degraded jq path (which is the
# correct UX per the builder prompt's own guidance: "Honest thin is better
# than dishonest thick").
if printf '%s' "$CLEANED" | jq -e '.refuse == true' >/dev/null 2>&1; then
  REASON="$(printf '%s' "$CLEANED" | jq -r '.reason // "unspecified"')"
  die "builder refused: $REASON (envelope: $STREAM_FILE)" 1
fi

# Validate shape — dg__author requires .body{} + .items[].
if ! printf '%s' "$CLEANED" | jq -e 'type=="object" and (.body|type)=="object" and (.items|type)=="array"' >/dev/null 2>&1; then
  die "builder output not {body,items} (envelope: $STREAM_FILE)" 1
fi

# Mirror the MCP server's quality gate (mcp-askbrian/server.mjs:373-): a
# worker-stuck dossier MUST carry ≥3 sections, ≥1 item, ≥500 chars of
# full_detail. Anything thinner is the model punting; treat as a builder
# failure so the labeled-degraded jq fallback runs and the badge matches.
QUALITY="$(printf '%s' "$CLEANED" | jq -r '
  def sections: (.body.sections // []) | if type=="array" then length else 0 end;
  def items_n: (.items // [])         | if type=="array" then length else 0 end;
  def full_len:(.body.full_detail // "") | tostring | length;
  "sections=" + (sections|tostring) +
  ";items="   + (items_n|tostring) +
  ";full="    + (full_len|tostring) +
  ";thin="    + (if (sections < 3 or items_n < 1 or full_len < 500) then "1" else "0" end)
')"
case "$QUALITY" in
  *";thin=1"*) die "builder thin output ($QUALITY; envelope: $STREAM_FILE)" 1 ;;
esac

# Success. Emit the body+items JSON dg__author expects.
printf '%s' "$CLEANED"
