#!/usr/bin/env bash
# beads-runner/agents/specialist.sh — ONE shim, kind-selected hats
# (S1, claude-tools-bk6; epic claude-tools-kie).
#
# WHAT THIS IS (UX-DESIGN.md §2.1 "The hat model"):
#   The whole specialist-agent fleet — ux, design, impl, docs, tests,
#   reconciler, enricher, and the dossier-builder — is ONE binary that
#   launches a fresh `claude -p` against a workspace, with the system prompt
#   selected by --kind from `<dirname>/<kind>.system.md`. The hat is the
#   PROMPT, not the PROCESS — same shim, same lifecycle, same permission
#   discipline. Adding a hat = adding one .system.md file + one row to the
#   case statement; splitting a hat out into its own binary later is a
#   non-breaking refactor.
#
#   S1 (this child) stands up the shim only. S2 fills in the per-hat starter
#   prompts; S3 wires the enricher; B2 / M6 / I3 wire the daemon-side
#   triggers. The system-prompt files do NOT exist yet — this binary
#   requires them and errors loudly if absent, so a missing prompt is a
#   visible failure (not a quiet default).
#
# PERMISSION DISCIPLINE BY KIND (task spec):
#   dossier-builder : reads + Bash for `bd show`/`bd notes`/`git log`/`git
#                     diff --stat`/etc., no file writes outside .beads
#                     (B2 surface). Bash is REQUIRED — the B1 prompt's Step 1
#                     instructs the agent to walk the bd graph and recent
#                     commits as breadth-first context-gathering; without
#                     Bash it cannot follow its own prompt (B6,
#                     claude-tools-lhc). File writes still blocked via
#                     NO_CODE_EDITS — the dossier is emitted on stdout, the
#                     hosted engine is the writer.
#   reconciler      : reads + Bash for `bd`, no file writes outside .beads
#                     (M6 surface; the bd subprocess is the .beads writer).
#   enricher        : reads + Bash for `bd`, no file writes outside .beads
#                     (I3 surface).
#   ux/design/impl/docs/tests : reads + Bash + file writes — these are
#     doing real work during stage transitions or as worker bodies.
#
#   All hats: the runner's §7.6 GUARDRAIL (--disallowedTools
#   AskUserQuestion EnterPlanMode ExitPlanMode) applies — same discipline
#   as the per-task worker. Tool-level "no writes outside .beads" is not
#   enforceable inside claude, so the no-write hats forbid Write/Edit/
#   NotebookEdit entirely and rely on the bd subprocess for .beads writes.
#
# LOGGING (BC-27 self-gitignore scar applies):
#   Every invocation writes a structured JSON event line to
#   <workspace>/.beads/runner-logs/specialist.log AND preserves the full
#   claude stream-json under
#   <workspace>/.beads/runner-logs/specialist-<kind>-<ts>.jsonl. The
#   runner-logs dir self-gitignores so raw model output never enters git.
#
# Safe to run under `set -uo pipefail` — every fallible external call is
# guarded; exit code is the underlying `claude -p` exit code (the caller
# decides what it means, same posture as the runner: BC-09 — exit code is
# not a verdict on its own).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

usage() {
  cat <<'EOF'
specialist.sh — ONE shim, kind-selected system prompts (S1, claude-tools-bk6)

Usage:
  specialist.sh --kind=KIND --workspace=PATH [--context-file=PATH] [--model=NAME]
  cat ctx.json | specialist.sh --kind=KIND --workspace=PATH

Required:
  --kind KIND          one of: ux | design | impl | docs | tests
                                | reconciler | enricher | dossier-builder
  --workspace PATH     the workspace the hat runs inside (cwd + --add-dir)

Optional:
  --context-file PATH  JSON context; otherwise stdin is used
  --model NAME         claude model (default: $DEFAULT_MODEL or opus[1m])
EOF
}

# ── argument parsing ─────────────────────────────────────────────────────────
KIND=""
WORKSPACE=""
CONTEXT_FILE=""
MODEL="${DEFAULT_MODEL:-opus[1m]}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kind=*)         KIND="${1#*=}";          shift ;;
    --kind)           KIND="${2:-}";            shift 2 ;;
    --workspace=*)    WORKSPACE="${1#*=}";     shift ;;
    --workspace)      WORKSPACE="${2:-}";       shift 2 ;;
    --context-file=*) CONTEXT_FILE="${1#*=}";  shift ;;
    --context-file)   CONTEXT_FILE="${2:-}";    shift 2 ;;
    --model=*)        MODEL="${1#*=}";         shift ;;
    --model)          MODEL="${2:-}";           shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "specialist.sh: reject — unknown arg '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$KIND" ]]      || { echo "specialist.sh: reject — --kind required" >&2; usage >&2; exit 2; }
[[ -n "$WORKSPACE" ]] || { echo "specialist.sh: reject — --workspace required" >&2; usage >&2; exit 2; }
[[ -d "$WORKSPACE" ]] || { echo "specialist.sh: reject — --workspace '$WORKSPACE' is not a directory" >&2; exit 2; }

case "$KIND" in
  ux|design|impl|docs|tests|reconciler|enricher|dossier-builder) : ;;
  *) echo "specialist.sh: reject — --kind '$KIND' not in the closed enum (ux|design|impl|docs|tests|reconciler|enricher|dossier-builder)" >&2; exit 2 ;;
esac

SYS_PROMPT_FILE="$SCRIPT_DIR/$KIND.system.md"
if [[ ! -f "$SYS_PROMPT_FILE" ]]; then
  echo "specialist.sh: reject — system prompt missing: $SYS_PROMPT_FILE (S2 fills these in; this shim only resolves the file — a missing prompt is a visible failure, not a quiet default)" >&2
  exit 2
fi
SYS_PROMPT="$(cat "$SYS_PROMPT_FILE")"
[[ -n "$SYS_PROMPT" ]] || { echo "specialist.sh: reject — system prompt file '$SYS_PROMPT_FILE' is empty" >&2; exit 2; }

# Context: --context-file wins; otherwise stdin (which must not be a tty).
if [[ -n "$CONTEXT_FILE" ]]; then
  [[ -f "$CONTEXT_FILE" ]] || { echo "specialist.sh: reject — --context-file '$CONTEXT_FILE' not found" >&2; exit 2; }
  CONTEXT="$(cat "$CONTEXT_FILE")"
else
  if [[ -t 0 ]]; then
    echo "specialist.sh: reject — no --context-file and stdin is a tty (pipe context JSON in or pass --context-file)" >&2
    exit 2
  fi
  CONTEXT="$(cat)"
fi
[[ -n "$CONTEXT" ]] || { echo "specialist.sh: reject — context is empty" >&2; exit 2; }

# ── per-kind permission discipline ───────────────────────────────────────────
# Common §7.6 guardrail (defense-in-depth behind the §7.2(a) instructed prompt).
GUARDRAIL=(AskUserQuestion EnterPlanMode ExitPlanMode)
# No-code-edits set for read-only hats. M6 spec (claude-tools-4iy) is explicit:
# Write/Edit/MultiEdit/NotebookEdit/BashWriteEdits cover "anything that mutates
# files outside .beads". Real-work hats (ux/design/impl/docs/tests) do NOT
# disallow these; they need them.
NO_CODE_EDITS=(Write Edit MultiEdit NotebookEdit BashWriteEdits)

case "$KIND" in
  dossier-builder)
    # B2 surface, B6 (claude-tools-lhc) fix: Bash is REQUIRED. The B1 prompt
    # (dossier-builder.system.md) explicitly grants Read/Grep/Glob/Bash and
    # its Step 1 tells the agent to run `bd show`, `bd notes`, `git log`,
    # `git diff --stat`, etc. as breadth-first context-gathering. Same
    # posture as reconciler/enricher: bd + read-only git via Bash, no file
    # writes outside .beads (the dossier is emitted on stdout; the hosted
    # engine is the writer). NO_CODE_EDITS still covers Write/Edit/Multi/
    # NotebookEdit/BashWriteEdits so the agent physically cannot mutate
    # files outside .beads.
    DISALLOWED=("${GUARDRAIL[@]}" "${NO_CODE_EDITS[@]}")
    PERMISSION_MODE=(--permission-mode default)
    ;;
  reconciler|enricher)
    # M6/I3: bd subprocess via Bash + read-only git status/log/diff allowed;
    # NO file writes outside .beads (the bd CLI writes to .beads on its own).
    # Disallowed list explicitly covers Write/Edit/MultiEdit/NotebookEdit AND
    # BashWriteEdits — the M6 spec is precise about this so the bd-surgery
    # agent physically cannot edit code or commit (AD8 read-only-outside-
    # .beads/ contract).
    DISALLOWED=("${GUARDRAIL[@]}" "${NO_CODE_EDITS[@]}")
    PERMISSION_MODE=(--permission-mode default)
    ;;
  ux|design|impl|docs|tests)
    # Real work: writes + bd allowed; same posture as a per-task worker.
    DISALLOWED=("${GUARDRAIL[@]}")
    PERMISSION_MODE=(--permission-mode acceptEdits)
    ;;
esac

# ── log dir (BC-27 self-gitignore re-asserted on every write) ────────────────
# Hard-fail if the dir cannot be made/written: silent log loss is the exact
# scar the runner's BC-27 / BC-42 posture exists to prevent (raw model output
# reaching git, or a stream-json file we can never inspect because no one knew
# the write failed).
LOG_DIR="$WORKSPACE/.beads/runner-logs"
mkdir -p "$LOG_DIR" 2>/dev/null || { echo "specialist.sh: reject — could not create log dir '$LOG_DIR' (workspace .beads/ unwritable?)" >&2; exit 70; }
[[ -w "$LOG_DIR" ]] || { echo "specialist.sh: reject — log dir '$LOG_DIR' is not writable" >&2; exit 70; }
[[ -f "$LOG_DIR/.gitignore" ]] || printf '*\n!.gitignore\n' > "$LOG_DIR/.gitignore" 2>/dev/null || true

TS="$(date -u +%Y%m%dT%H%M%SZ)"
STREAM_FILE="$LOG_DIR/specialist-$KIND-$TS.jsonl"
SUMMARY_LOG="$LOG_DIR/specialist.log"
WRONG_NODE_LOG="$LOG_DIR/wrong-node-crash.log"

# ── claude-tools-3kd path-prime: spawn claude under nvm's node, not system v25
#
# The bug: a daemon-launched specialist.sh inherits a stripped PATH that
# resolves `claude` to a system install running under /usr/local/bin/node
# (currently v25.2.1). Node v25 is incompatible with the claude CLI — it
# crashes at startup with `TypeError: Cannot read properties of undefined
# (reading 'prototype')` from cli.js. The crash output (Node stack trace +
# version banner) lands in $STREAM_FILE as if it were the agent's reply, the
# shim's exit code is nonzero, and the caller's jq fallback silently kicks
# in — every dossier-builder spawn degrades to the deterministic baseline
# with nobody the wiser.
#
# The fix: if `node` on PATH is v25+, find the nvm default version and
# prepend its bin dir to PATH so the spawned claude binds to nvm's node
# (v23.11.1 today). The wrong-Node detector below is a backstop — even after
# this prepend, an unforeseen launch environment could re-introduce the
# crash, and we want it surfaced loudly rather than silently degrading.
#
# Non-invasive by design: if the current node is already < v25 (interactive
# session, test fixture, an OS without nvm) we change nothing. Tests can also
# set SPECIALIST_SKIP_NVM_PRIME=1 to force-skip.
if [[ "${SPECIALIST_SKIP_NVM_PRIME:-0}" != "1" ]]; then
  node_major="$(node --version 2>/dev/null | sed -n 's/^v\([0-9][0-9]*\).*/\1/p')"
  if [[ -n "$node_major" && "$node_major" -ge 25 ]]; then
    NVM_DIR_RESOLVED="${NVM_DIR:-$HOME/.nvm}"
    if [[ -d "$NVM_DIR_RESOLVED/versions/node" ]]; then
      _ver=""
      _alias_file="$NVM_DIR_RESOLVED/alias/default"
      if [[ -f "$_alias_file" ]]; then
        _ver="$(head -1 "$_alias_file" 2>/dev/null)"
        # Follow alias chain (e.g. default -> lts/iron -> 23.11.1) — bounded hops.
        for _ in 1 2 3 4 5; do
          [[ -n "$_ver" && -f "$NVM_DIR_RESOLVED/alias/$_ver" ]] || break
          _ver="$(head -1 "$NVM_DIR_RESOLVED/alias/$_ver" 2>/dev/null)"
        done
      fi
      _ver="${_ver#v}"
      # If alias resolution didn't yield an X.Y.Z literal, pick the highest
      # installed version that is NOT itself in the wrong-node range (v25+).
      if [[ ! "$_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        _ver="$(ls -1 "$NVM_DIR_RESOLVED/versions/node" 2>/dev/null \
                  | sed 's/^v//' \
                  | awk -F. '$1 < 25' \
                  | sort -V | tail -1)"
      fi
      if [[ -n "$_ver" && -d "$NVM_DIR_RESOLVED/versions/node/v$_ver/bin" ]]; then
        PATH="$NVM_DIR_RESOLVED/versions/node/v$_ver/bin:$PATH"
        export PATH
      fi
    fi
  fi
fi

log_event() {
  local event="$1" exit_code="${2:-}" rec
  rec=$(jq -cn \
        --arg ev   "$event" \
        --arg kind "$KIND" \
        --arg ws   "$WORKSPACE" \
        --arg ts   "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")" \
        --arg sf   "$STREAM_FILE" \
        --arg sp   "$SYS_PROMPT_FILE" \
        --arg ec   "$exit_code" \
        '{event:$ev,specialist_kind:$kind,workspace:$ws,observed_at:$ts,
          stream_file:$sf,system_prompt_file:$sp}
         + (if $ec=="" then {} else {exit_code:($ec|tonumber? // $ec)} end)' \
        2>/dev/null) || rec=""
  [[ -z "$rec" ]] && rec="{\"event\":\"$event\",\"specialist_kind\":\"$KIND\"}"
  printf '%s\n' "$rec" >> "$SUMMARY_LOG" 2>/dev/null || true
}

log_event start

# ── run claude -p inside the workspace ───────────────────────────────────────
# Subshell so the cd never leaks back to the caller; --add-dir also names the
# workspace explicitly (cwd + --add-dir + workspace CLAUDE.md, per UX-DESIGN
# §2.1). Stream-json captured (merged stdout+stderr, BC-39 idiom) to the
# self-gitignored stream file. --disallowedTools is LAST so the variadic
# tool list does not gobble a following --flag.
(
  # Exit 70 (sysexits EX_SOFTWARE) on cd failure — distinct enough from any
  # plausible claude exit that a caller inspecting CLAUDE_EXIT can disambiguate
  # "shim could not enter the workspace" from "claude exited X" via the
  # structured log line (which records the exit code the caller sees).
  cd "$WORKSPACE" || exit 70
  claude -p "$CONTEXT" \
    --output-format stream-json \
    --verbose \
    --model "$MODEL" \
    --no-chrome \
    --add-dir "$WORKSPACE" \
    --append-system-prompt "$SYS_PROMPT" \
    "${PERMISSION_MODE[@]}" \
    --disallowedTools "${DISALLOWED[@]}" \
    > "$STREAM_FILE" 2>&1
)
CLAUDE_EXIT=$?

log_event end "$CLAUDE_EXIT"

# ── claude-tools-3kd wrong-Node crash detector (LOUD, never silent) ──────────
# If claude exits nonzero AND the stream carries the Node v25+ × claude-CLI
# prototype TypeError, surface it explicitly: a structured event in the
# summary log, a clearly-marked stderr message, AND a sticky line in
# wrong-node-crash.log. We do NOT mutate $CLAUDE_EXIT — the caller's existing
# rc!=0 path still runs (so any downstream fallback still fires), but the
# silent-degradation we're killing is now impossible: the crash leaves visible
# fingerprints in three places. Even after the path-prime above, an unforeseen
# launch environment could reintroduce the wrong-Node case (system claude
# wrapper, NVM_DIR moved, custom $CLAUDE_BIN); this detector is the backstop
# that ensures we hear about it instantly instead of weeks later.
if [[ "$CLAUDE_EXIT" -ne 0 && -s "$STREAM_FILE" ]]; then
  # Bounded scan so a multi-MB stream doesn't stall the shim.
  _head_blob="$(head -c 16384 "$STREAM_FILE" 2>/dev/null)"
  _tail_blob="$(tail -c 4096  "$STREAM_FILE" 2>/dev/null)"
  if printf '%s%s' "$_head_blob" "$_tail_blob" \
       | grep -qE "TypeError: Cannot read properties of undefined \(reading 'prototype'\)" 2>/dev/null \
     && printf '%s' "$_tail_blob" \
       | grep -qE "Node\.js v(2[5-9]|[3-9][0-9])\." 2>/dev/null; then
    _node_seen="$(printf '%s' "$_tail_blob" | grep -oE "Node\.js v[0-9.]+" | tail -1)"
    log_event wrong_node_crash "$CLAUDE_EXIT"
    {
      printf '%s\n' "specialist.sh: WRONG-NODE CRASH — '$KIND' claude CLI crashed at startup."
      printf '  detected: %s (the claude CLI is incompatible with Node v25+; see claude-tools-3kd)\n' "${_node_seen:-<unknown>}"
      printf '  stream:   %s\n' "$STREAM_FILE"
      printf '  fix:      ensure $NVM_DIR/versions/node/<lts>/bin is first in PATH for the launching process,\n'
      printf '            or set $CLAUDE_BIN to an explicit nvm-managed claude path.\n'
      printf '            specialist.sh already prepends nvm bin when node --version is v25+; the wrong-Node\n'
      printf '            detection firing means even that prepend did not resolve the right binary.\n'
    } >&2
    {
      printf '%s\twrong_node_crash\t%s\t%s\t%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")" \
        "$KIND" "${_node_seen:-unknown}" "$STREAM_FILE"
    } >> "$WRONG_NODE_LOG" 2>/dev/null || true
  fi
fi

# Output extraction: the final assistant `result` text (callers that want the
# full stream read $STREAM_FILE). Line-by-line because the merged stderr can
# legitimately interleave non-JSON noise (SDK HTTP-retry chatter); a parse
# failure on one line must NOT mask the result on the next (BC-39 idiom).
# Silent if the stream has no result line.
if [[ -s "$STREAM_FILE" ]]; then
  LAST_RESULT=""
  while IFS= read -r _line; do
    [[ -n "$_line" ]] || continue
    _r=$(printf '%s' "$_line" | jq -r 'select(.type=="result") | .result // empty' 2>/dev/null) || _r=""
    [[ -n "$_r" ]] && LAST_RESULT="$_r"
  done < "$STREAM_FILE"
  [[ -n "$LAST_RESULT" ]] && printf '%s\n' "$LAST_RESULT"
fi

exit "$CLAUDE_EXIT"
