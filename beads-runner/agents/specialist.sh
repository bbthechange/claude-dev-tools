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
#   xws-responder   : reads + Bash for `bd`, no file writes outside .beads
#                     (K1 surface, claude-tools-uxvk1; the read-only cross-WS
#                     responder — same NO_CODE_EDITS posture as reconciler/
#                     enricher PLUS a no-recursion guard that disallows the
#                     ask-workspace / ask-brian MCP tools so a responder can
#                     never trigger another responder — DESIGN K §2.2 item 3).
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
                                | xws-responder
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
  ux|design|impl|docs|tests|reconciler|enricher|dossier-builder|xws-responder) : ;;
  *) echo "specialist.sh: reject — --kind '$KIND' not in the closed enum (ux|design|impl|docs|tests|reconciler|enricher|dossier-builder|xws-responder)" >&2; exit 2 ;;
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
# No-recursion guard for the xws-responder hat (K1, claude-tools-uxvk1; DESIGN K
# §2.2 item 3 / r0m item 5). The cross-WS responder is spawned by the
# ask-workspace MCP server, which is registered at USER scope — so without an
# explicit disallow the responder's `claude -p` would inherit the very tool that
# spawned it and could relay onward, making cross-WS cycles possible. Disallow
# both human/peer ask tools by name so recursion is impossible at the harness
# layer, not merely discouraged by the prompt. (A no-op for every other hat.)
NO_XWS_RECURSION=(mcp__ask-workspace__ask-workspace mcp__askbrian__ask-brian)

# Common allowlist every hat needs (claude-tools-e5aq): without --allowedTools,
# `--permission-mode default` (and acceptEdits, for Bash) sends every tool call
# to the permission prompt, which in non-interactive `claude -p` is an instant
# denial. Observed on 2026-05-28 in rhythmGame: 16 enricher runs, 192 denials,
# zero beads created — `bd --version` was rejected, never mind `bd create`.
# The enricher/reconciler/dossier-builder prompts are explicit that the bd
# subprocess is the agent's only writer; without Bash(bd:*) the hat is
# structurally unable to do its job.
#
# This list mirrors the worker's `.beads/runner.sh` PERMISSION_FLAGS allowlist
# for the read-only bash family (bd, git, grep, find, ls, cat, head, tail, jq,
# etc.) plus the non-Bash read tools the hats use (Read/Grep/Glob/LS). The
# real-work hats below extend it with write tools and a broader Bash surface.
COMMON_ALLOWED=(
  Read Grep Glob LS
  "Bash(bd:*)"
  "Bash(git:*)"
  "Bash(grep:*)" "Bash(rg:*)" "Bash(find:*)"
  "Bash(ls:*)" "Bash(cat:*)" "Bash(head:*)" "Bash(tail:*)"
  "Bash(wc:*)" "Bash(diff:*)" "Bash(cmp:*)" "Bash(sort:*)" "Bash(uniq:*)"
  "Bash(jq:*)" "Bash(awk:*)" "Bash(sed:*)"
  "Bash(date:*)" "Bash(basename:*)" "Bash(dirname:*)" "Bash(realpath:*)"
  "Bash(which:*)" "Bash(command:*)" "Bash(echo:*)" "Bash(printf:*)"
  "Bash(tree:*)" "Bash(env:*)" "Bash(test:*)"
)

# Real-work hats also need the write tools and the broader bash surface (so
# they can edit files, run builds, invoke node/wrangler, etc.).
REAL_WORK_EXTRA=(
  Write Edit MultiEdit NotebookEdit Task WebFetch WebSearch
  "Bash(mkdir:*)" "Bash(cp:*)" "Bash(mv:*)" "Bash(rm:*)"
  "Bash(chmod:*)" "Bash(touch:*)" "Bash(ln:*)" "Bash(mktemp:*)"
  "Bash(bash:*)" "Bash(sh:*)" "Bash(make:*)"
  "Bash(node:*)" "Bash(npm:*)" "Bash(npx:*)" "Bash(pnpm:*)" "Bash(yarn:*)"
  "Bash(wrangler:*)" "Bash(miniflare:*)"
  "Bash(tsc:*)" "Bash(tsx:*)" "Bash(vitest:*)" "Bash(vite:*)" "Bash(esbuild:*)"
  "Bash(python:*)" "Bash(python3:*)" "Bash(curl:*)"
  "Bash(ps:*)" "Bash(lsof:*)" "Bash(kill:*)" "Bash(pkill:*)" "Bash(wait:*)"
  "Bash(sleep:*)" "Bash(timeout:*)" "Bash(tee:*)" "Bash(xargs:*)"
  "Bash(security:*)" "Bash(shellcheck:*)"
)

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
    ALLOWED=("${COMMON_ALLOWED[@]}")
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
    ALLOWED=("${COMMON_ALLOWED[@]}")
    DISALLOWED=("${GUARDRAIL[@]}" "${NO_CODE_EDITS[@]}")
    PERMISSION_MODE=(--permission-mode default)
    ;;
  xws-responder)
    # K1 (claude-tools-uxvk1; DESIGN K §2.1): the cross-WS read-only responder.
    # EXACTLY the reconciler/enricher read-only posture (COMMON_ALLOWED, the
    # full NO_CODE_EDITS set disallowed, --permission-mode default) — must-
    # protect #11 (aux read-only BY CONSTRUCTION): it can Read/Grep/Glob, run
    # read-only `bd`/`git`, and nothing else; it physically cannot edit B's
    # tree, run a build, or commit. PLUS the no-recursion guard: a responder
    # must never be able to call the ask-workspace (or ask-brian) MCP tool, or a
    # responder could trigger another responder and cycle (§2.2 item 3). The
    # answer/escalate split is the prompt's job; the lockdown is enforced here.
    ALLOWED=("${COMMON_ALLOWED[@]}")
    DISALLOWED=("${GUARDRAIL[@]}" "${NO_CODE_EDITS[@]}" "${NO_XWS_RECURSION[@]}")
    PERMISSION_MODE=(--permission-mode default)
    ;;
  ux|design|impl|docs|tests)
    # Real work: writes + bd allowed; same posture as a per-task worker.
    ALLOWED=("${COMMON_ALLOWED[@]}" "${REAL_WORK_EXTRA[@]}")
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

# ── Node v25 PATH prime (claude-tools-3kd; shared with run-beads-tasks.sh /
#    runner.sh via lib/node25-prime.sh, claude-tools-18c). The body lives in
#    the shared helper because the same bug bit three siblings; the SCOPED
#    skip env var (SPECIALIST_SKIP_NVM_PRIME) stays caller-local so each test
#    surface forces a skip under its own name. See node25-prime.sh for the
#    full bug-and-fix narrative; the one-liner: a daemon-launched PATH
#    resolves `claude` to system-node v25 which crashes the CLI at startup.
# shellcheck source=../lib/node25-prime.sh
source "$SCRIPT_DIR/../lib/node25-prime.sh"
node25_prime_path "${SPECIALIST_SKIP_NVM_PRIME:-0}"

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
# tool list does not gobble a following --flag; --allowedTools is sandwiched
# between --add-dir and --disallowedTools and explicitly terminated by the
# next named flag (--permission-mode) before --disallowedTools is appended.
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
    --allowedTools "${ALLOWED[@]}" \
    "${PERMISSION_MODE[@]}" \
    --disallowedTools "${DISALLOWED[@]}" \
    > "$STREAM_FILE" 2>&1
)
CLAUDE_EXIT=$?

log_event end "$CLAUDE_EXIT"

# ── wrong-Node crash detector (LOUD, never silent) — claude-tools-3kd ────────
# Backstop behind the path-prime above. The detection regex/scan body lives in
# node25_check_wrong_node_crash (lib/node25-prime.sh, shared with the runners);
# here we own the specialist-scoped surface: a wrong_node_crash event in
# specialist.log, a KIND-named stderr block, and a sticky line in
# wrong-node-crash.log. $CLAUDE_EXIT is NOT mutated — the caller's rc!=0 path
# still runs (any downstream fallback still fires), but the silent degradation
# we're killing is now impossible.
if [[ "$CLAUDE_EXIT" -ne 0 ]]; then
  if _node_seen="$(node25_check_wrong_node_crash "$STREAM_FILE")"; then
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
