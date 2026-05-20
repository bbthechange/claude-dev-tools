#!/usr/bin/env bash
# beads-runner/agents/test-specialist.sh — S1 shim regression test
# (claude-tools-bk6). Drives the kind-selected `claude -p` shim against a
# fake `claude` binary on PATH so the test runs offline / token-free.
#
# What this asserts (S1 acceptance):
#   • The closed kind enum {ux,design,impl,docs,tests,reconciler,enricher,
#     dossier-builder} all dispatch.
#   • System-prompt resolution: missing <kind>.system.md is a hard reject.
#   • Permission discipline by kind:
#       dossier-builder ⇒ Write/Edit/NotebookEdit AND Bash disallowed
#                          (B2 read-only surface), --permission-mode default
#       reconciler|enricher ⇒ Write/Edit/NotebookEdit disallowed, Bash kept
#                              (M6/I3 — bd subprocess writes to .beads)
#       ux|design|impl|docs|tests ⇒ --permission-mode acceptEdits, writes kept
#     All hats: the §7.6 guardrail (AskUserQuestion EnterPlanMode
#     ExitPlanMode) is on the disallow list.
#   • Workspace plumbing: claude runs with cwd == workspace AND --add-dir
#     pointing at the workspace.
#   • Logging: BC-27 self-gitignored runner-logs dir; one stream-json file
#     per call (specialist-<kind>-<ts>.jsonl); structured one-line JSON
#     events {start,end} in specialist.log; end events carry exit_code.
#   • Output extraction: the last `result.result` line surfaces on stdout.
#
# NOTE on the fake claude: specialist.sh redirects the worker with
# `> $STREAM_FILE 2>&1`, so the fake's stderr (FAKE_CLAUDE_ARGS/_CWD) ends
# up INSIDE the stream file alongside its stdout JSON. We assert against
# the stream file, not the shim's stderr.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
SHIM="$SCRIPT_DIR/specialist.sh"

FAILED=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; FAILED=1; }

WORK="$(mktemp -d 2>/dev/null)" || { echo "mktemp failed"; exit 70; }
trap 'rm -rf "$WORK"' EXIT

FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/claude" <<'CLAUDE_EOF'
#!/usr/bin/env bash
# Fake claude — emits a single stream-json result line on stdout, and echoes
# its invocation context to stderr so the test can assert the flag wiring.
echo "FAKE_CLAUDE_ARGS: $*" >&2
echo "FAKE_CLAUDE_CWD: $(pwd)" >&2
printf '{"type":"result","result":"ok-from-fake-claude","is_error":false,"stop_reason":"end_turn"}\n'
exit 0
CLAUDE_EOF
chmod +x "$FAKE_BIN/claude"
export PATH="$FAKE_BIN:$PATH"

WS="$WORK/ws"
mkdir -p "$WS/.beads"

# Backup whatever prompts already exist; install placeholder prompts for the
# test so a missing-prompt environment (e.g. before S2 lands) still passes.
PROMPT_BACKUP="$WORK/prompts-backup"
mkdir -p "$PROMPT_BACKUP"
for k in ux design impl docs tests reconciler enricher dossier-builder; do
  pf="$SCRIPT_DIR/$k.system.md"
  if [[ -f "$pf" ]]; then
    cp "$pf" "$PROMPT_BACKUP/$k.system.md"
  fi
  printf 'SHIM PLACEHOLDER for %s — test fixture (claude-tools-bk6)\n' "$k" > "$pf"
done
restore_prompts() {
  for k in ux design impl docs tests reconciler enricher dossier-builder; do
    pf="$SCRIPT_DIR/$k.system.md"
    bf="$PROMPT_BACKUP/$k.system.md"
    if [[ -f "$bf" ]]; then mv "$bf" "$pf"; else rm -f "$pf"; fi
  done
}
trap 'restore_prompts; rm -rf "$WORK"' EXIT

# ── reject paths (no claude needed) ──────────────────────────────────────────
echo '── reject paths ──'
out=$(bash "$SHIM" 2>&1); rc=$?
[[ $rc -eq 2 ]] && grep -q "kind required" <<<"$out" \
  && pass "no args ⇒ exit 2, --kind required" || fail "no args: rc=$rc / out=$out"

out=$(bash "$SHIM" --kind=bogus --workspace="$WS" 2>&1); rc=$?
[[ $rc -eq 2 ]] && grep -q "not in the closed enum" <<<"$out" \
  && pass "bad --kind ⇒ exit 2, closed-enum reject" || fail "bad kind: rc=$rc / out=$out"

out=$(bash "$SHIM" --kind=ux --workspace=/path/does-not-exist-xyz 2>&1); rc=$?
[[ $rc -eq 2 ]] && grep -q "not a directory" <<<"$out" \
  && pass "missing workspace ⇒ exit 2, not-a-directory reject" || fail "bad ws: rc=$rc / out=$out"

# Hide one prompt to assert the missing-prompt reject.
mv "$SCRIPT_DIR/ux.system.md" "$WORK/ux.system.md.hidden"
out=$(echo '{}' | bash "$SHIM" --kind=ux --workspace="$WS" 2>&1); rc=$?
[[ $rc -eq 2 ]] && grep -q "system prompt missing" <<<"$out" \
  && pass "missing <kind>.system.md ⇒ exit 2, hard reject" || fail "missing prompt: rc=$rc / out=$out"
mv "$WORK/ux.system.md.hidden" "$SCRIPT_DIR/ux.system.md"

: > "$WORK/empty.json"
out=$(bash "$SHIM" --kind=ux --workspace="$WS" --context-file="$WORK/empty.json" 2>&1); rc=$?
[[ $rc -eq 2 ]] && grep -q "context is empty" <<<"$out" \
  && pass "empty context ⇒ exit 2" || fail "empty ctx: rc=$rc / out=$out"

# ── happy paths per kind ─────────────────────────────────────────────────────
echo '── happy paths (kind dispatch + flag wiring + output extraction) ──'
run() {
  local kind="$1" stdout sf
  stdout=$(echo '{"ask":"smoke"}' | bash "$SHIM" --kind="$kind" --workspace="$WS")
  local rc=$?
  [[ $rc -eq 0 ]] || { fail "$kind: shim exit $rc"; return; }
  [[ "$stdout" == "ok-from-fake-claude" ]] \
    || fail "$kind: stdout did not surface the result.result text (got: $stdout)"
  sf=$(ls -t "$WS/.beads/runner-logs/specialist-$kind-"*.jsonl 2>/dev/null | head -1)
  [[ -n "$sf" && -f "$sf" ]] || { fail "$kind: stream file missing"; return; }
  grep -q "FAKE_CLAUDE_CWD: $WS" "$sf" \
    || fail "$kind: claude did not cd into workspace ($WS)"
  grep -q -- "--append-system-prompt" "$sf" \
    || fail "$kind: --append-system-prompt missing"
  grep -q -- "--add-dir $WS" "$sf" \
    || fail "$kind: --add-dir $WS missing"
  grep -q -- "--disallowedTools AskUserQuestion EnterPlanMode ExitPlanMode" "$sf" \
    || fail "$kind: §7.6 guardrail not at start of --disallowedTools"
  pass "$kind: dispatched, flags wired, output extracted"
}
for k in ux design impl docs tests reconciler enricher dossier-builder; do
  run "$k"
done

# ── per-kind permission discipline ───────────────────────────────────────────
echo '── per-kind permission discipline ──'
stream_for() {
  local kind="$1"
  echo '{}' | bash "$SHIM" --kind="$kind" --workspace="$WS" >/dev/null
  local sf
  sf=$(ls -t "$WS/.beads/runner-logs/specialist-$kind-"*.jsonl 2>/dev/null | head -1)
  [[ -n "$sf" && -f "$sf" ]] && cat "$sf" || echo ""
}

DB=$(stream_for dossier-builder)
# M6 (claude-tools-4iy) broadens the no-code-edits set from
# `Write Edit NotebookEdit` to `Write Edit MultiEdit NotebookEdit BashWriteEdits`.
# dossier-builder additionally forbids Bash entirely (B2 pure reader).
if grep -q -- "--disallowedTools .* Write Edit MultiEdit NotebookEdit BashWriteEdits Bash" <<<"$DB"; then
  pass "dossier-builder: full M6 no-code-edits set + Bash disallowed (B2 read-only)"
else
  fail "dossier-builder: expected …Write Edit MultiEdit NotebookEdit BashWriteEdits Bash on --disallowedTools"
fi
grep -q -- "--permission-mode default" <<<"$DB" \
  && pass "dossier-builder: --permission-mode default" \
  || fail "dossier-builder: expected --permission-mode default"

REC=$(stream_for reconciler)
# After M6: full no-code-edits set, but Bash itself is KEPT (the `bd` subprocess
# is invoked through Bash). BashWriteEdits ≠ Bash; check the bare-token Bash is
# absent by requiring whitespace boundaries on both sides.
if grep -q -- "--disallowedTools .* Write Edit MultiEdit NotebookEdit BashWriteEdits" <<<"$REC" \
   && ! grep -qE -- "--disallowedTools .* Bash([[:space:]]|$)" <<<"$REC"; then
  pass "reconciler: full M6 no-code-edits set forbidden, bare Bash kept (M6 bd subprocess + read-only git)"
else
  fail "reconciler: expected Write/Edit/MultiEdit/NotebookEdit/BashWriteEdits forbidden AND bare Bash kept"
fi

ENR=$(stream_for enricher)
if grep -q -- "--disallowedTools .* Write Edit MultiEdit NotebookEdit BashWriteEdits" <<<"$ENR" \
   && ! grep -qE -- "--disallowedTools .* Bash([[:space:]]|$)" <<<"$ENR"; then
  pass "enricher: full M6 no-code-edits set forbidden, bare Bash kept (I3 bd subprocess)"
else
  fail "enricher: expected Write/Edit/MultiEdit/NotebookEdit/BashWriteEdits forbidden AND bare Bash kept"
fi

IMPL=$(stream_for impl)
grep -q -- "--permission-mode acceptEdits" <<<"$IMPL" \
  && pass "impl: --permission-mode acceptEdits (real-work hat)" \
  || fail "impl: expected --permission-mode acceptEdits"
if grep -q -- "--disallowedTools .* Write" <<<"$IMPL"; then
  fail "impl: writes should NOT be on --disallowedTools (real-work hat)"
else
  pass "impl: writes kept (real-work hat)"
fi

# ── arg-form parity + workspace with spaces ──────────────────────────────────
echo '── arg forms + spaces ──'
# Mixed "--flag value" form (the happy path above used "--flag=value" only).
stdout=$(echo '{"ask":"mix"}' | bash "$SHIM" --kind ux --workspace "$WS")
rc=$?
[[ $rc -eq 0 && "$stdout" == "ok-from-fake-claude" ]] \
  && pass "mixed --kind ux --workspace \$WS form parses + dispatches" \
  || fail "space-separated arg form broke: rc=$rc / out=$stdout"

# Workspace path containing spaces.
WS2="$WORK/ws with space"
mkdir -p "$WS2/.beads"
stdout=$(echo '{}' | bash "$SHIM" --kind=ux --workspace="$WS2")
rc=$?
[[ $rc -eq 0 && "$stdout" == "ok-from-fake-claude" ]] \
  && pass "workspace path with spaces handled" \
  || fail "spaces-in-workspace broke: rc=$rc / out=$stdout"
[[ -d "$WS2/.beads/runner-logs" ]] \
  && pass "log dir created under spaced workspace" \
  || fail "log dir not created under spaced workspace"

# ── non-zero claude exit must pass through and be logged ─────────────────────
echo '── exit-code passthrough ──'
# Swap in a fake-claude that exits 1 with a result line marked is_error.
cat > "$FAKE_BIN/claude" <<'CLAUDE_FAIL_EOF'
#!/usr/bin/env bash
echo "FAKE_FAIL_ARGS: $*" >&2
printf '{"type":"result","result":"fake-failure","is_error":true,"stop_reason":"end_turn"}\n'
exit 1
CLAUDE_FAIL_EOF
chmod +x "$FAKE_BIN/claude"

stdout=$(echo '{"ask":"fail"}' | bash "$SHIM" --kind=ux --workspace="$WS")
rc=$?
[[ $rc -eq 1 ]] && pass "shim passes through claude's non-zero exit (got 1)" \
  || fail "exit-code passthrough broke: rc=$rc (expected 1)"
[[ "$stdout" == "fake-failure" ]] \
  && pass "shim still surfaces the result.result text on non-zero exit" \
  || fail "result extraction skipped on non-zero exit: out=$stdout"
grep -q '"exit_code":1' "$WS/.beads/runner-logs/specialist.log" \
  && pass "summary log records the non-zero exit_code" \
  || fail "summary log missing exit_code:1 entry"

# Restore the success fake for any later assertions.
cat > "$FAKE_BIN/claude" <<'CLAUDE_OK_EOF'
#!/usr/bin/env bash
echo "FAKE_CLAUDE_ARGS: $*" >&2
echo "FAKE_CLAUDE_CWD: $(pwd)" >&2
printf '{"type":"result","result":"ok-from-fake-claude","is_error":false,"stop_reason":"end_turn"}\n'
exit 0
CLAUDE_OK_EOF
chmod +x "$FAKE_BIN/claude"

# ── logging discipline ───────────────────────────────────────────────────────
echo '── logging discipline ──'
LOG_DIR="$WS/.beads/runner-logs"
[[ -d "$LOG_DIR" ]] && pass "log dir created at <workspace>/.beads/runner-logs" \
  || fail "log dir missing"
[[ -f "$LOG_DIR/.gitignore" ]] && pass "BC-27 .gitignore present" \
  || fail "BC-27 .gitignore missing"
grep -q '^\*$' "$LOG_DIR/.gitignore" && pass ".gitignore self-excludes" \
  || fail ".gitignore content wrong (expected '*' on a line)"
ls "$LOG_DIR"/specialist-*-*.jsonl >/dev/null 2>&1 \
  && pass "per-call stream files preserved (specialist-<kind>-<ts>.jsonl)" \
  || fail "no per-call stream files"
[[ -f "$LOG_DIR/specialist.log" ]] && pass "structured summary log present" \
  || fail "specialist.log missing"
bad_line=""
while IFS= read -r l; do
  [[ -n "$l" ]] || continue
  printf '%s' "$l" | jq -e . >/dev/null 2>&1 || { bad_line="$l"; break; }
done < "$LOG_DIR/specialist.log"
[[ -z "$bad_line" ]] && pass "summary log: every non-empty line is valid JSON" \
  || fail "summary log: a line failed to parse — $bad_line"
grep -q '"event":"start"' "$LOG_DIR/specialist.log" \
  && pass "summary log has start events" \
  || fail "summary log missing start events"
grep -q '"event":"end"' "$LOG_DIR/specialist.log" \
  && pass "summary log has end events" \
  || fail "summary log missing end events"
grep -q '"exit_code":0' "$LOG_DIR/specialist.log" \
  && pass "summary log records exit_code" \
  || fail "summary log missing exit_code field"

echo
if [[ $FAILED -eq 0 ]]; then
  echo "ALL_PASS (S1 shim acceptance — claude-tools-bk6)"
  exit 0
else
  echo "SOME_FAIL"
  exit 1
fi
