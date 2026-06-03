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
#       dossier-builder ⇒ Write/Edit/NotebookEdit disallowed, Bash KEPT
#                          (B2 surface; B6 claude-tools-lhc — the B1 prompt
#                          requires `bd show`/`bd notes`/`git log` for Step 1
#                          breadth-first context-gathering), --permission-mode default
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
for k in ux design impl docs tests reconciler enricher dossier-builder xws-responder blueprint-update; do
  pf="$SCRIPT_DIR/$k.system.md"
  if [[ -f "$pf" ]]; then
    cp "$pf" "$PROMPT_BACKUP/$k.system.md"
  fi
  printf 'SHIM PLACEHOLDER for %s — test fixture (claude-tools-bk6)\n' "$k" > "$pf"
done
restore_prompts() {
  for k in ux design impl docs tests reconciler enricher dossier-builder xws-responder blueprint-update; do
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
for k in ux design impl docs tests reconciler enricher dossier-builder xws-responder blueprint-update; do
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
# B6 (claude-tools-lhc) fix: dossier-builder KEEPS bare Bash — the B1 prompt
# (dossier-builder.system.md) instructs the agent to run `bd show`/`bd notes`/
# `git log`/`git diff --stat` in Step 1 for breadth-first context-gathering.
# Same posture as reconciler/enricher: no file writes outside .beads, but the
# bd CLI + read-only git are reachable via Bash.
if grep -q -- "--disallowedTools .* Write Edit MultiEdit NotebookEdit BashWriteEdits" <<<"$DB" \
   && ! grep -qE -- "--disallowedTools .* Bash([[:space:]]|$)" <<<"$DB"; then
  pass "dossier-builder: full M6 no-code-edits set forbidden, bare Bash kept (B6 — bd + read-only git for prompt Step 1)"
else
  fail "dossier-builder: expected Write/Edit/MultiEdit/NotebookEdit/BashWriteEdits forbidden AND bare Bash kept"
fi
grep -q -- "--permission-mode default" <<<"$DB" \
  && pass "dossier-builder: --permission-mode default" \
  || fail "dossier-builder: expected --permission-mode default"
# claude-tools-e5aq: --allowedTools must include Bash(bd:*) (and the
# read-only-bash family) so the bd subprocess + git/grep/etc actually run in
# non-interactive `claude -p`. Without this every Bash invocation is sent to
# the permission prompt and instantly denied — observed on 2026-05-28 in
# rhythmGame: 16 enricher runs, 192 denials, zero beads created.
grep -q -- "--allowedTools .* Bash(bd:\\*)" <<<"$DB" \
  && pass "dossier-builder: --allowedTools includes Bash(bd:*) (claude-tools-e5aq)" \
  || fail "dossier-builder: --allowedTools missing Bash(bd:*) — enricher-style 192-denial regression"

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
grep -q -- "--allowedTools .* Bash(bd:\\*)" <<<"$REC" \
  && pass "reconciler: --allowedTools includes Bash(bd:*) (claude-tools-e5aq)" \
  || fail "reconciler: --allowedTools missing Bash(bd:*)"

ENR=$(stream_for enricher)
if grep -q -- "--disallowedTools .* Write Edit MultiEdit NotebookEdit BashWriteEdits" <<<"$ENR" \
   && ! grep -qE -- "--disallowedTools .* Bash([[:space:]]|$)" <<<"$ENR"; then
  pass "enricher: full M6 no-code-edits set forbidden, bare Bash kept (I3 bd subprocess)"
else
  fail "enricher: expected Write/Edit/MultiEdit/NotebookEdit/BashWriteEdits forbidden AND bare Bash kept"
fi
grep -q -- "--allowedTools .* Bash(bd:\\*)" <<<"$ENR" \
  && pass "enricher: --allowedTools includes Bash(bd:*) (claude-tools-e5aq)" \
  || fail "enricher: --allowedTools missing Bash(bd:*) — the exact bug e5aq fixes"
grep -q -- "--allowedTools .* Bash(git:\\*)" <<<"$ENR" \
  && pass "enricher: --allowedTools includes Bash(git:*) (read-only git for dedup pass)" \
  || fail "enricher: --allowedTools missing Bash(git:*)"

# ── H5 (claude-tools-uxvh5) — the read-only Blueprint updater hat ─────────────
# The bead's testing invariant (s6/s4): the dispatched aux carries the
# read-only hat (no Write/Edit/mutating-Bash) — "assert the capability SET, not
# intent." blueprint-update is must-protect #11 (aux read-only BY
# CONSTRUCTION): it reads the tree + read-only bd/git and emits its regenerated
# Blueprint on stdout; the daemon is the engine writer (so no curl/token in the
# hat, and physically no tree mutation). EXACTLY the reconciler/enricher
# posture: full NO_CODE_EDITS set disallowed, bare Bash kept (read-only bd/git),
# --permission-mode default, Bash(bd:*) on the allowlist.
BPU=$(stream_for blueprint-update)
if grep -q -- "--disallowedTools .* Write Edit MultiEdit NotebookEdit BashWriteEdits" <<<"$BPU" \
   && ! grep -qE -- "--disallowedTools .* Bash([[:space:]]|$)" <<<"$BPU"; then
  pass "blueprint-update: Write/Edit/MultiEdit/NotebookEdit/BashWriteEdits REFUSED, bare Bash kept (read-only by construction — must-protect #11)"
else
  fail "blueprint-update: expected Write/Edit/MultiEdit/NotebookEdit/BashWriteEdits forbidden AND bare Bash kept"
fi
grep -q -- "--permission-mode default" <<<"$BPU" \
  && pass "blueprint-update: --permission-mode default (no auto-accept of edits)" \
  || fail "blueprint-update: expected --permission-mode default"
grep -q -- "--allowedTools .* Bash(bd:\\*)" <<<"$BPU" \
  && pass "blueprint-update: --allowedTools includes Bash(bd:*) (read-only bd for Step 1)" \
  || fail "blueprint-update: --allowedTools missing Bash(bd:*)"
# "Not merely unused": Write is actively DISALLOWED (asserted above) AND it is
# not quietly in the allowlist either. Isolate the allow segment so the greedy
# match can't reach the Write token that lives in the --disallowedTools segment.
BPU_ALLOW_SEG=$(grep -oE -- "--allowedTools .*--permission-mode" <<<"$BPU" | head -1)
if grep -qE -- "(^| )Write( |$)" <<<"$BPU_ALLOW_SEG"; then
  fail "blueprint-update: Write must NOT be on --allowedTools (read-only hat)"
else
  pass "blueprint-update: Write absent from --allowedTools (read-only hat — refused, not merely unused)"
fi

# ── K1 (claude-tools-uxvk1) — the cross-WS read-only responder lockdown ──────
# The bead's testing invariant (s6/s4): "responder capability lockdown:
# Read/Grep/Glob/bd-read ONLY. Assert a Write/Edit/mutating-Bash attempt is
# REFUSED (not merely unused)." We assert the harness-level refusal directly:
# the full NO_CODE_EDITS set (Write Edit MultiEdit NotebookEdit BashWriteEdits)
# is on --disallowedTools, bare Bash is kept (for read-only bd/git), the mode is
# `default` (no auto-accept of edits), and the no-recursion guard disallows BOTH
# cross-WS/human ask MCP tools so a responder cannot trigger another responder.
XWS=$(stream_for xws-responder)
if grep -q -- "--disallowedTools .* Write Edit MultiEdit NotebookEdit BashWriteEdits" <<<"$XWS" \
   && ! grep -qE -- "--disallowedTools .* Bash([[:space:]]|$)" <<<"$XWS"; then
  pass "xws-responder: Write/Edit/MultiEdit/NotebookEdit/BashWriteEdits REFUSED, bare Bash kept (read-only by construction — must-protect #11)"
else
  fail "xws-responder: expected Write/Edit/MultiEdit/NotebookEdit/BashWriteEdits forbidden AND bare Bash kept"
fi
grep -q -- "--permission-mode default" <<<"$XWS" \
  && pass "xws-responder: --permission-mode default (no auto-accept of edits)" \
  || fail "xws-responder: expected --permission-mode default"
grep -q -- "--allowedTools .* Bash(bd:\\*)" <<<"$XWS" \
  && pass "xws-responder: --allowedTools includes Bash(bd:*) (read-only bd for answering)" \
  || fail "xws-responder: --allowedTools missing Bash(bd:*)"
# "Not merely unused": Write is actively DISALLOWED (asserted above) AND it is
# not quietly in the allowlist either. Isolate the allow segment (between
# --allowedTools and --permission-mode) so the greedy match can't reach the
# Write token that legitimately lives in the --disallowedTools segment.
XWS_ALLOW_SEG=$(grep -oE -- "--allowedTools .*--permission-mode" <<<"$XWS" | head -1)
if grep -qE -- "(^| )Write( |$)" <<<"$XWS_ALLOW_SEG"; then
  fail "xws-responder: Write must NOT be on --allowedTools (read-only hat)"
else
  pass "xws-responder: Write absent from --allowedTools (read-only hat — refused, not merely unused)"
fi
# The no-recursion guard (DESIGN K §2.2 item 3 / r0m item 5): both ask MCP tools
# are disallowed so a responder can never relay onward and cycle.
grep -q -- "--disallowedTools .* mcp__ask-workspace__ask-workspace" <<<"$XWS" \
  && pass "xws-responder: ask-workspace MCP tool disallowed (no recursion — DESIGN K §2.2)" \
  || fail "xws-responder: ask-workspace MCP tool NOT disallowed — a responder could cycle"
grep -q -- "--disallowedTools .* mcp__askbrian__ask-brian" <<<"$XWS" \
  && pass "xws-responder: ask-brian MCP tool disallowed (the responder escalates via verdict, never directly)" \
  || fail "xws-responder: ask-brian MCP tool NOT disallowed"

IMPL=$(stream_for impl)
grep -q -- "--permission-mode acceptEdits" <<<"$IMPL" \
  && pass "impl: --permission-mode acceptEdits (real-work hat)" \
  || fail "impl: expected --permission-mode acceptEdits"
if grep -q -- "--disallowedTools .* Write" <<<"$IMPL"; then
  fail "impl: writes should NOT be on --disallowedTools (real-work hat)"
else
  pass "impl: writes kept (real-work hat)"
fi
# claude-tools-e5aq: real-work hats also need Bash(bd:*) in the allowlist;
# acceptEdits auto-accepts file edits but Bash is still permission-gated.
grep -q -- "--allowedTools .* Bash(bd:\\*)" <<<"$IMPL" \
  && pass "impl: --allowedTools includes Bash(bd:*) (claude-tools-e5aq)" \
  || fail "impl: --allowedTools missing Bash(bd:*)"
grep -q -- "--allowedTools .* Write " <<<"$IMPL" \
  && pass "impl: --allowedTools includes Write (real-work hat needs file writes)" \
  || fail "impl: --allowedTools missing Write — real-work hat cannot edit files"

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

# ── wrong-Node crash detector (claude-tools-3kd) ─────────────────────────────
# When the spawned claude crashes under Node v25+ at startup, the shim MUST
# surface it loudly (specialist.log event + stderr message + sticky marker)
# rather than letting the caller silently degrade to its jq fallback. The
# detector is a backstop behind the path-prime — even after we prepend nvm's
# bin, an unforeseen launch environment could still resolve a system claude;
# we want the noise to fire instantly when that happens.
echo '── wrong-Node crash detector (claude-tools-3kd) ──'
# Use a dedicated workspace so this test's stream file is unambiguous.
WS3="$WORK/ws-wrong-node"
mkdir -p "$WS3/.beads"

# Swap in a fake-claude that mimics the Node v25 × claude-CLI prototype crash:
# a TypeError stack from cli.js followed by the Node version banner, exit 1.
cat > "$FAKE_BIN/claude" <<'CLAUDE_NODE25_EOF'
#!/usr/bin/env bash
cat <<'CRASH'
file:///usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js:489
some.minified(token).boundary

TypeError: Cannot read properties of undefined (reading 'prototype')
    at file:///usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js:489:25504
    at file:///usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js:7:402

Node.js v25.2.1
CRASH
exit 1
CLAUDE_NODE25_EOF
chmod +x "$FAKE_BIN/claude"

# Force-skip the path-prime so the test's fake claude (not the user's real
# nvm-managed claude) is what runs. Without this the shim would prepend
# $NVM_DIR/versions/node/v<X>/bin and resolve the REAL claude, defeating the
# test fixture.
SPECIALIST_SKIP_NVM_PRIME=1 \
  bash "$SHIM" --kind=dossier-builder --workspace="$WS3" <<<'{"ask":"node25-repro"}' \
  >"$WORK/wn.stdout" 2>"$WORK/wn.stderr"
WN_RC=$?

[[ "$WN_RC" -ne 0 ]] \
  && pass "wrong-Node: shim exits nonzero (caller's fallback can still run)" \
  || fail "wrong-Node: expected nonzero exit, got $WN_RC"

grep -q "WRONG-NODE CRASH" "$WORK/wn.stderr" \
  && pass "wrong-Node: stderr carries the loud WRONG-NODE CRASH message" \
  || fail "wrong-Node: stderr missing WRONG-NODE CRASH (got: $(head -c 200 "$WORK/wn.stderr"))"

grep -q "Node\.js v25" "$WORK/wn.stderr" \
  && pass "wrong-Node: stderr names the detected node version" \
  || fail "wrong-Node: stderr missing node version detail"

grep -q '"event":"wrong_node_crash"' "$WS3/.beads/runner-logs/specialist.log" \
  && pass "wrong-Node: summary log carries a wrong_node_crash event" \
  || fail "wrong-Node: specialist.log missing wrong_node_crash event"

[[ -f "$WS3/.beads/runner-logs/wrong-node-crash.log" ]] \
  && grep -q "wrong_node_crash" "$WS3/.beads/runner-logs/wrong-node-crash.log" \
  && pass "wrong-Node: sticky marker file (wrong-node-crash.log) written" \
  || fail "wrong-Node: sticky marker file missing/empty"

# Negative case: a generic claude failure (no TypeError + no Node v25 banner)
# must NOT trip the wrong-Node detector. Otherwise we'd over-classify every
# genuine refusal as a wrong-Node crash and the loud signal would lose meaning.
WS4="$WORK/ws-generic-fail"
mkdir -p "$WS4/.beads"
cat > "$FAKE_BIN/claude" <<'CLAUDE_GENERIC_FAIL_EOF'
#!/usr/bin/env bash
printf '{"type":"result","result":"refusal text","is_error":true,"stop_reason":"end_turn"}\n'
exit 1
CLAUDE_GENERIC_FAIL_EOF
chmod +x "$FAKE_BIN/claude"

SPECIALIST_SKIP_NVM_PRIME=1 \
  bash "$SHIM" --kind=dossier-builder --workspace="$WS4" <<<'{"ask":"generic-fail"}' \
  >/dev/null 2>"$WORK/gf.stderr"

! grep -q "WRONG-NODE CRASH" "$WORK/gf.stderr" \
  && pass "wrong-Node: generic claude failure does NOT trip the detector" \
  || fail "wrong-Node: detector falsely fired on a generic non-Node failure"

! grep -q '"event":"wrong_node_crash"' "$WS4/.beads/runner-logs/specialist.log" \
  && pass "wrong-Node: generic failure does NOT emit a wrong_node_crash event" \
  || fail "wrong-Node: false-positive wrong_node_crash event on generic failure"

# Restore the success fake so nothing downstream is surprised.
cat > "$FAKE_BIN/claude" <<'CLAUDE_OK2_EOF'
#!/usr/bin/env bash
printf '{"type":"result","result":"ok-from-fake-claude","is_error":false,"stop_reason":"end_turn"}\n'
exit 0
CLAUDE_OK2_EOF
chmod +x "$FAKE_BIN/claude"

echo
if [[ $FAILED -eq 0 ]]; then
  echo "ALL_PASS (S1 shim acceptance — claude-tools-bk6)"
  exit 0
else
  echo "SOME_FAIL"
  exit 1
fi
