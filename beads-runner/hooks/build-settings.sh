#!/usr/bin/env bash
# build-settings.sh — the ONE source of truth for the close-discipline hook's
# `claude --settings` JSON shape (claude-tools-2fkp).
#
# Both runners inject the same hook the same way: a PreToolUse matcher on `Bash`
# (so a `bd close|done|--status=closed` is gated before it runs) and a `Stop`
# matcher (so the 8-block discipline checklist fires at session end). v1
# (run-beads-tasks.sh, claude-tools-td0y) inlined this jq; v2 (runner.sh) is the
# port. Inlining it twice is the next drift waiting to happen — the matcher set,
# the field names, or the close-checklist contract could diverge between the two
# runners and no test would catch it. So the shape lives HERE and both runners
# call `build_hook_settings`.
#
# SOURCED, not executed — it defines a function. The hook SCRIPT path is the
# caller's to resolve (each runner already computes its own
# `<runner-dir>/hooks/close-checklist.sh`); this helper only owns the JSON.
#
# build_hook_settings <hook_script_path> <out_file>
#   Writes the claude --settings JSON to <out_file>. Returns 0 on success;
#   non-zero if jq is missing or the write fails — the caller gates `--settings`
#   injection on the return code (no jq ⇒ run WITHOUT the hook, never spawn a
#   worker pointed at a half-written settings file).
build_hook_settings() {
  local hook_script="$1" out_file="$2"
  command -v jq >/dev/null 2>&1 || return 1
  jq -n --arg cmd "$hook_script" '{
    hooks: {
      PreToolUse: [{ matcher: "Bash",  hooks: [{ type: "command", command: $cmd }] }],
      Stop:       [{ matcher: "",      hooks: [{ type: "command", command: $cmd }] }]
    }
  }' > "$out_file" 2>/dev/null
}
