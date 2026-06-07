#!/bin/bash
# beads-runner/test-post-close-audit.sh
#
# Unit tests for post_close_audit() in run-beads-tasks.sh (claude-tools-apen).
# Catches the AGENT-BYPASS-VIA-CAP class — a worker that burns the 8-block
# Stop-hook cap and closes the bead anyway. Without this audit the bead
# silently disappears; with it we get an incidents.log entry + regression bead.
#
# Run: bash beads-runner/test-post-close-audit.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$HERE/run-beads-tasks.sh"

[[ -f "$RUNNER" ]] || { echo "FAIL: runner not found at $RUNNER"; exit 1; }

PASS=0
FAIL=0
FAILED_NAMES=()

# Extract post_close_audit + record_incident from the runner so we can source
# them in isolation without executing the whole script. Brittle to formatting:
# both functions are written as `name() {` on a single line and end with `}` at
# column 0; if that changes, this extraction will fail loudly (good — it means
# someone refactored and the test needs to be re-aligned).
extract_function() {  # extract_function <name> <source-file>
  local name="$1" src="$2"
  awk -v fn="$name" '
    $0 ~ "^" fn "\\(\\) \\{" { inside=1 }
    inside { print }
    inside && /^\}$/ { exit }
  ' "$src"
}

mkfixture() {  # mkfixture → echoes a tmpdir set up as a fake workspace
  local d
  d="$(mktemp -d -t apen-test.XXXX)"
  mkdir -p "$d/.beads/runner-logs" "$d/ws/.beads/runner-logs"
  echo "$d"
}

# Render the audit function + its single helper (record_incident) into a
# sourceable bash script, prepend a stub for notify_user (so the test does NOT
# fire osascript), expose required globals (INCIDENTS, INCIDENTS_LOG, LOG_DIR),
# then invoke post_close_audit with the supplied task id.
run_audit() {  # run_audit <ws-dir> <task_id> <shim-dir>
  local ws="$1" task_id="$2" shim="$3"
  local log_dir="$ws/.beads/runner-logs"
  local rec_fn audit_fn
  rec_fn="$(extract_function record_incident "$RUNNER")"
  audit_fn="$(extract_function post_close_audit "$RUNNER")"
  [[ -n "$rec_fn" && -n "$audit_fn" ]] || { echo "EXTRACT FAILED"; return 99; }

  PATH="$shim:$PATH" \
  bash -c "
    set -uo pipefail
    cd '$ws'
    unset BEADS_DIRTY_BASELINE 2>/dev/null || true  # claude-tools-f4ub: force \$LOG_DIR fallback
    INCIDENTS=()
    INCIDENTS_LOG='$log_dir/incidents.log'
    LOG_DIR='$log_dir'
    notify_user() { :; }  # silence desktop notifications
    $rec_fn
    $audit_fn
    post_close_audit '$task_id' 'test-session-anchor'
  "
}

mkshim() {  # mkshim → echoes a tmpdir for PATH-prepended stubs
  mktemp -d -t apen-shim.XXXX
}

write_shim() {  # write_shim <dir> <name> <body>
  local dir="$1" name="$2" body="$3"
  cat > "$dir/$name" <<EOF
#!/bin/bash
$body
EOF
  chmod +x "$dir/$name"
}

# ── Tests ───────────────────────────────────────────────────────────────────

echo "[post_close_audit]"

# T1: Bead is NOT closed → audit must no-op (no incident, no regression bead).
ws=$(mkfixture); shim=$(mkshim)
write_shim "$shim" bd 'case "$*" in "show foo-1 --json") printf "%s" "[{\"status\":\"open\"}]" ;; esac; exit 0'
run_audit "$ws" "foo-1" "$shim" >/dev/null 2>&1
if [[ ! -s "$ws/.beads/runner-logs/incidents.log" ]]; then
  PASS=$((PASS+1)); echo "  PASS: T1 bead-not-closed no-op"
else
  FAIL=$((FAIL+1)); FAILED_NAMES+=("T1"); echo "  FAIL: T1 bead-not-closed wrote incident (should not)"
  cat "$ws/.beads/runner-logs/incidents.log"
fi
rm -rf "$ws" "$shim"

# T2: Closed bead, NO commit references id, NO wrapup marker, NO debrief
#     → all four checks fire; expect incident logged + bd create called.
ws=$(mkfixture); shim=$(mkshim)
# bd shim: status=closed; notes empty so debrief + wrapup checks fail.
# Also captures `bd create` invocations to a sentinel file.
write_shim "$shim" bd "
SENTINEL='$ws/.beads/runner-logs/bd-create-calls.log'
case \"\$*\" in
  'show foo-2 --json')
    printf '%s' '[{\"status\":\"closed\"}]' ;;
  'show foo-2 --long --json')
    printf '%s' '[{\"status\":\"closed\",\"notes\":\"\"}]' ;;
  create*)
    echo \"\$*\" >> \"\$SENTINEL\"
    echo '✓ Created issue: claude-tools-fake — discipline-bypass' ;;
  update*) : ;;
esac
exit 0
"
# git shim: empty repo dir won't have .git, so git checks are skipped.
# We still need git binary present for the `command -v git` true-branch — but
# the [[ -d .git ]] guard inside the audit will fail, so checks 1 & 2 skip.
# That's fine: T2 verifies the bd-notes-driven checks fire.
( cd "$ws" && git init -q 2>/dev/null )
# Ensure no commit references foo-2 (HEAD is the init commit only).
( cd "$ws" && git -c user.email=t@t -c user.name=t commit --allow-empty -q -m 'init' )

run_audit "$ws" "foo-2" "$shim" >/dev/null 2>&1

inc_log="$ws/.beads/runner-logs/incidents.log"
create_log="$ws/.beads/runner-logs/bd-create-calls.log"

if [[ -s "$inc_log" ]] && grep -q "DISCIPLINE_BYPASS:" "$inc_log" \
   && grep -q "close_without_commit" "$inc_log" \
   && grep -q "missing_debrief" "$inc_log"; then
  PASS=$((PASS+1)); echo "  PASS: T2 closed+disciplinefail records incident"
else
  FAIL=$((FAIL+1)); FAILED_NAMES+=("T2-incident")
  echo "  FAIL: T2 closed+disciplinefail: expected DISCIPLINE_BYPASS incident with checks, got:"
  [[ -s "$inc_log" ]] && cat "$inc_log" | sed 's/^/    /' || echo "    (incidents.log empty/missing)"
fi

if [[ -s "$create_log" ]] && grep -q "discipline-bypass" "$create_log"; then
  PASS=$((PASS+1)); echo "  PASS: T2 regression bead filed"
else
  FAIL=$((FAIL+1)); FAILED_NAMES+=("T2-bd-create")
  echo "  FAIL: T2 expected bd create with discipline-bypass title, got:"
  [[ -s "$create_log" ]] && cat "$create_log" | sed 's/^/    /' || echo "    (no bd create call)"
fi

# T2b: incident line and the original bead's note should both reference the
#      regression bead id parsed from `bd create` output. Without this, the
#      "look at the regression bead" triage path requires a label search.
if [[ -s "$inc_log" ]] && grep -q "regression=claude-tools-fake" "$inc_log"; then
  PASS=$((PASS+1)); echo "  PASS: T2b incident cross-references regression id"
else
  FAIL=$((FAIL+1)); FAILED_NAMES+=("T2b")
  echo "  FAIL: T2b expected 'regression=claude-tools-fake' in incident, got:"
  [[ -s "$inc_log" ]] && cat "$inc_log" | sed 's/^/    /' || echo "    (no incident)"
fi
rm -rf "$ws" "$shim"

# T3: Closed bead WITH a referencing commit, wrapup marker, and a real debrief
#     → no audit fires (clean close).
ws=$(mkfixture); shim=$(mkshim)
write_shim "$shim" bd "
case \"\$*\" in
  'show foo-3 --json')
    printf '%s' '[{\"status\":\"closed\"}]' ;;
  'show foo-3 --long --json')
    printf '%s' '[{\"status\":\"closed\",\"notes\":\"This is a properly long debrief explaining what happened in detail.\nwrapup-reviewed: 2026-05-26T10:00:00Z sha=abc clean=0\"}]' ;;
  create*) echo \"\$*\" >> '$ws/.beads/runner-logs/bd-create-calls.log' ;;
esac
exit 0
"
# /wrapup skill must be COMMITTED so it doesn't show up as untracked and
# trip the dirty_tree check on an otherwise-clean close.
mkdir -p "$ws/.claude/skills/wrapup" && echo stub > "$ws/.claude/skills/wrapup/SKILL.md"
( cd "$ws" \
  && git init -q 2>/dev/null \
  && git -c user.email=t@t -c user.name=t add . \
  && git -c user.email=t@t -c user.name=t commit -q -m 'work on foo-3 — closing it out' )

run_audit "$ws" "foo-3" "$shim" >/dev/null 2>&1

if [[ ! -s "$ws/.beads/runner-logs/incidents.log" ]] \
   && [[ ! -s "$ws/.beads/runner-logs/bd-create-calls.log" ]]; then
  PASS=$((PASS+1)); echo "  PASS: T3 clean close → no audit fire"
else
  FAIL=$((FAIL+1)); FAILED_NAMES+=("T3")
  echo "  FAIL: T3 clean close fired audit (should not):"
  [[ -s "$ws/.beads/runner-logs/incidents.log" ]] && \
    echo "    incident:"; cat "$ws/.beads/runner-logs/incidents.log" | sed 's/^/      /' 2>/dev/null
  [[ -s "$ws/.beads/runner-logs/bd-create-calls.log" ]] && \
    echo "    bd create:"; cat "$ws/.beads/runner-logs/bd-create-calls.log" | sed 's/^/      /' 2>/dev/null
fi
rm -rf "$ws" "$shim"

# T4: Closed bead with commit + wrapup but NO debrief
#     → missing_debrief fires alone; regression bead labelled accordingly.
ws=$(mkfixture); shim=$(mkshim)
write_shim "$shim" bd "
case \"\$*\" in
  'show foo-4 --json')
    printf '%s' '[{\"status\":\"closed\"}]' ;;
  'show foo-4 --long --json')
    printf '%s' '[{\"status\":\"closed\",\"notes\":\"wrapup-reviewed: 2026-01-01\"}]' ;;
  create*) echo \"\$*\" >> '$ws/.beads/runner-logs/bd-create-calls.log' ;;
esac
exit 0
"
mkdir -p "$ws/.claude/skills/wrapup" && echo stub > "$ws/.claude/skills/wrapup/SKILL.md"
( cd "$ws" \
  && git init -q 2>/dev/null \
  && git -c user.email=t@t -c user.name=t add . \
  && git -c user.email=t@t -c user.name=t commit -q -m 'fix foo-4' )

run_audit "$ws" "foo-4" "$shim" >/dev/null 2>&1

inc_log="$ws/.beads/runner-logs/incidents.log"
if [[ -s "$inc_log" ]] && grep -q "missing_debrief" "$inc_log" \
   && ! grep -q "close_without_commit" "$inc_log" \
   && ! grep -q "wrapup_not_invoked" "$inc_log"; then
  PASS=$((PASS+1)); echo "  PASS: T4 missing-debrief-only fires that check alone"
else
  FAIL=$((FAIL+1)); FAILED_NAMES+=("T4")
  echo "  FAIL: T4 expected missing_debrief only, got:"
  [[ -s "$inc_log" ]] && cat "$inc_log" | sed 's/^/    /' || echo "    (no incident)"
fi
rm -rf "$ws" "$shim"

# T5: Closed bead, clean tree EXCEPT .beads/issues.jsonl (the bd-close
#     side-effect file). Audit must NOT fire — that was the rhythmGame
#     overnight false-positive cascade (claude-tools-u4ms).
ws=$(mkfixture); shim=$(mkshim)
write_shim "$shim" bd "
case \"\$*\" in
  'show foo-5 --json')
    printf '%s' '[{\"status\":\"closed\"}]' ;;
  'show foo-5 --long --json')
    printf '%s' '[{\"status\":\"closed\",\"notes\":\"Proper debrief content that is over forty characters long.\nwrapup-reviewed: 2026-05-28T00:00:00Z sha=abc clean=0\"}]' ;;
  create*) echo \"\$*\" >> '$ws/.beads/runner-logs/bd-create-calls.log' ;;
esac
exit 0
"
mkdir -p "$ws/.claude/skills/wrapup" && echo stub > "$ws/.claude/skills/wrapup/SKILL.md"
( cd "$ws" \
  && git init -q 2>/dev/null \
  && git -c user.email=t@t -c user.name=t add . \
  && git -c user.email=t@t -c user.name=t commit -q -m 'work on foo-5 — closing it out' )
# Simulate bd close's side-effect: an untracked .beads/issues.jsonl appears
# in the working tree after the close commit.
echo '{"id":"foo-5","status":"closed"}' > "$ws/.beads/issues.jsonl"

run_audit "$ws" "foo-5" "$shim" >/dev/null 2>&1

if [[ ! -s "$ws/.beads/runner-logs/incidents.log" ]] \
   && [[ ! -s "$ws/.beads/runner-logs/bd-create-calls.log" ]]; then
  PASS=$((PASS+1)); echo "  PASS: T5 issues.jsonl-only dirty tree does NOT fire audit"
else
  FAIL=$((FAIL+1)); FAILED_NAMES+=("T5")
  echo "  FAIL: T5 issues.jsonl-only dirty fired audit (should not):"
  [[ -s "$ws/.beads/runner-logs/incidents.log" ]] && \
    echo "    incident:"; cat "$ws/.beads/runner-logs/incidents.log" | sed 's/^/      /' 2>/dev/null
  [[ -s "$ws/.beads/runner-logs/bd-create-calls.log" ]] && \
    echo "    bd create:"; cat "$ws/.beads/runner-logs/bd-create-calls.log" | sed 's/^/      /' 2>/dev/null
fi
rm -rf "$ws" "$shim"

# T6: Closed bead, dirty tree contains both .beads/issues.jsonl AND a real
#     source file. Audit MUST still fire dirty_tree — the exclusion is
#     scoped to issues.jsonl, not a blanket suppression (claude-tools-u4ms).
ws=$(mkfixture); shim=$(mkshim)
write_shim "$shim" bd "
case \"\$*\" in
  'show foo-6 --json')
    printf '%s' '[{\"status\":\"closed\"}]' ;;
  'show foo-6 --long --json')
    printf '%s' '[{\"status\":\"closed\",\"notes\":\"Proper debrief content that is over forty characters long.\nwrapup-reviewed: 2026-05-28T00:00:00Z sha=abc clean=0\"}]' ;;
  create*) echo \"\$*\" >> '$ws/.beads/runner-logs/bd-create-calls.log' ;;
esac
exit 0
"
mkdir -p "$ws/.claude/skills/wrapup" && echo stub > "$ws/.claude/skills/wrapup/SKILL.md"
( cd "$ws" \
  && git init -q 2>/dev/null \
  && git -c user.email=t@t -c user.name=t add . \
  && git -c user.email=t@t -c user.name=t commit -q -m 'work on foo-6 — closing it out' )
echo '{"id":"foo-6","status":"closed"}' > "$ws/.beads/issues.jsonl"
echo 'package main' > "$ws/real.go"  # this is the genuine dirty file

run_audit "$ws" "foo-6" "$shim" >/dev/null 2>&1

inc_log="$ws/.beads/runner-logs/incidents.log"
if [[ -s "$inc_log" ]] && grep -q "dirty_tree" "$inc_log"; then
  PASS=$((PASS+1)); echo "  PASS: T6 genuine dirty file still fires audit"
else
  FAIL=$((FAIL+1)); FAILED_NAMES+=("T6")
  echo "  FAIL: T6 expected dirty_tree incident, got:"
  [[ -s "$inc_log" ]] && cat "$inc_log" | sed 's/^/    /' || echo "    (no incident)"
fi
rm -rf "$ws" "$shim"

# T7: Closed bead whose only commit carries the SHORT conventional-commit scope,
#     not the full bead id → close_without_commit fires. Mirrors close-checklist
#     T11b so the runner audit and the Stop hook AGREE that a short scope alone
#     (e.g. `docs(foo): ...`) does not satisfy the full-id grep (claude-tools-02ec
#     acceptance: both grep sites must agree). Marker + debrief are present so
#     close_without_commit is isolated.
ws=$(mkfixture); shim=$(mkshim)
write_shim "$shim" bd "
case \"\$*\" in
  'show claude-tools-foo --json')
    printf '%s' '[{\"status\":\"closed\"}]' ;;
  'show claude-tools-foo --long --json')
    printf '%s' '[{\"status\":\"closed\",\"notes\":\"This is a properly long debrief explaining what happened in detail.\nwrapup-reviewed: 2026-05-31T10:00:00Z sha=abc clean=0\"}]' ;;
  create*) echo \"\$*\" >> '$ws/.beads/runner-logs/bd-create-calls.log' ;;
esac
exit 0
"
mkdir -p "$ws/.claude/skills/wrapup" && echo stub > "$ws/.claude/skills/wrapup/SKILL.md"
( cd "$ws" \
  && git init -q 2>/dev/null \
  && git -c user.email=t@t -c user.name=t add . \
  && git -c user.email=t@t -c user.name=t commit -q -m 'docs(foo): short scope only, no full id' )

run_audit "$ws" "claude-tools-foo" "$shim" >/dev/null 2>&1

inc_log="$ws/.beads/runner-logs/incidents.log"
if [[ -s "$inc_log" ]] && grep -q "close_without_commit" "$inc_log"; then
  PASS=$((PASS+1)); echo "  PASS: T7 short-scope-only fires close_without_commit (agrees with hook)"
else
  FAIL=$((FAIL+1)); FAILED_NAMES+=("T7")
  echo "  FAIL: T7 expected close_without_commit incident, got:"
  [[ -s "$inc_log" ]] && cat "$inc_log" | sed 's/^/    /' || echo "    (no incident)"
fi
rm -rf "$ws" "$shim"

# T8: Closed bead, commit subject uses the SHORT scope but the BODY carries the
#     FULL bead id → no audit fires. Mirrors close-checklist T11c: the recommended
#     wrapup pattern (`docs(foo): ...` subject + `Refs: claude-tools-foo` body)
#     satisfies the full-id grep at BOTH sites, so a clean close stays clean.
ws=$(mkfixture); shim=$(mkshim)
write_shim "$shim" bd "
case \"\$*\" in
  'show claude-tools-foo --json')
    printf '%s' '[{\"status\":\"closed\"}]' ;;
  'show claude-tools-foo --long --json')
    printf '%s' '[{\"status\":\"closed\",\"notes\":\"This is a properly long debrief explaining what happened in detail.\nwrapup-reviewed: 2026-05-31T10:00:00Z sha=abc clean=0\"}]' ;;
  create*) echo \"\$*\" >> '$ws/.beads/runner-logs/bd-create-calls.log' ;;
esac
exit 0
"
mkdir -p "$ws/.claude/skills/wrapup" && echo stub > "$ws/.claude/skills/wrapup/SKILL.md"
( cd "$ws" \
  && git init -q 2>/dev/null \
  && git -c user.email=t@t -c user.name=t add . \
  && git -c user.email=t@t -c user.name=t commit -q -m 'docs(foo): short scope subject' -m 'Refs: claude-tools-foo' )

run_audit "$ws" "claude-tools-foo" "$shim" >/dev/null 2>&1

if [[ ! -s "$ws/.beads/runner-logs/incidents.log" ]] \
   && [[ ! -s "$ws/.beads/runner-logs/bd-create-calls.log" ]]; then
  PASS=$((PASS+1)); echo "  PASS: T8 full id in body → clean close (agrees with hook)"
else
  FAIL=$((FAIL+1)); FAILED_NAMES+=("T8")
  echo "  FAIL: T8 full-id-in-body fired audit (should not):"
  [[ -s "$ws/.beads/runner-logs/incidents.log" ]] && \
    echo "    incident:"; cat "$ws/.beads/runner-logs/incidents.log" | sed 's/^/      /' 2>/dev/null
  [[ -s "$ws/.beads/runner-logs/bd-create-calls.log" ]] && \
    echo "    bd create:"; cat "$ws/.beads/runner-logs/bd-create-calls.log" | sed 's/^/      /' 2>/dev/null
fi
rm -rf "$ws" "$shim"

# T9: Closed bead, clean of its OWN work, but a FOREIGN uncommitted file sits in
#     the shared tree (a concurrent sibling / aux session / stray human edit). It
#     is present in the spawn-time baseline and outside the bead's commit set, so
#     it must NOT file a P1 discipline-bypass bead — only a downgraded
#     FOREIGN_DIRT_AT_CLOSE forensic incident (claude-tools-f4ub option C). This
#     is the uxgpre false-positive, regression-locked.
ws=$(mkfixture); shim=$(mkshim)
write_shim "$shim" bd "
case \"\$*\" in
  'show foo-9 --json')
    printf '%s' '[{\"status\":\"closed\"}]' ;;
  'show foo-9 --long --json')
    printf '%s' '[{\"status\":\"closed\",\"notes\":\"Proper debrief content that is over forty characters long.\nwrapup-reviewed: 2026-05-28T00:00:00Z sha=abc clean=0\"}]' ;;
  create*) echo \"\$*\" >> '$ws/.beads/runner-logs/bd-create-calls.log' ;;
esac
exit 0
"
mkdir -p "$ws/.claude/skills/wrapup" && echo stub > "$ws/.claude/skills/wrapup/SKILL.md"
( cd "$ws" \
  && git init -q 2>/dev/null \
  && git -c user.email=t@t -c user.name=t add . \
  && git -c user.email=t@t -c user.name=t commit -q -m 'work on foo-9 — closing it out' )
# A FOREIGN uncommitted file + the spawn-time baseline that records it as
# pre-existing (outside foo-9's commit set). LOG_DIR (the audit's baseline dir) is
# $ws/.beads/runner-logs in run_audit.
echo 'sibling churn this worker never touched' > "$ws/foreign.txt"
printf '%s\n' '?? foreign.txt' > "$ws/.beads/runner-logs/dirty-baseline.txt"

run_audit "$ws" "foo-9" "$shim" >/dev/null 2>&1

inc_log="$ws/.beads/runner-logs/incidents.log"
create_log="$ws/.beads/runner-logs/bd-create-calls.log"
if [[ -s "$inc_log" ]] && grep -q "FOREIGN_DIRT_AT_CLOSE" "$inc_log" \
   && ! grep -q "DISCIPLINE_BYPASS" "$inc_log" \
   && ! grep -q "dirty_tree" "$inc_log" \
   && [[ ! -s "$create_log" ]]; then
  PASS=$((PASS+1)); echo "  PASS: T9 foreign-only dirt → downgraded incident, NO P1 regression bead"
else
  FAIL=$((FAIL+1)); FAILED_NAMES+=("T9")
  echo "  FAIL: T9 expected FOREIGN_DIRT_AT_CLOSE only + no bd create, got:"
  [[ -s "$inc_log" ]] && cat "$inc_log" | sed 's/^/    incident: /' || echo "    (no incident)"
  [[ -s "$create_log" ]] && cat "$create_log" | sed 's/^/    create: /'
fi
rm -rf "$ws" "$shim"

# T10: Closed bead with BOTH a foreign file (in baseline) AND a genuine OWN new
#      uncommitted file (absent from baseline, outside the commit set ⇒ this
#      worker's own smuggling-in-waiting). The own file MUST still fire dirty_tree
#      + a P1 regression bead — the foreign-dirt softening must not suppress
#      detection of real own dirt (claude-tools-f4ub acceptance / regression of T6).
ws=$(mkfixture); shim=$(mkshim)
write_shim "$shim" bd "
case \"\$*\" in
  'show foo-10 --json')
    printf '%s' '[{\"status\":\"closed\"}]' ;;
  'show foo-10 --long --json')
    printf '%s' '[{\"status\":\"closed\",\"notes\":\"Proper debrief content that is over forty characters long.\nwrapup-reviewed: 2026-05-28T00:00:00Z sha=abc clean=0\"}]' ;;
  create*) echo \"\$*\" >> '$ws/.beads/runner-logs/bd-create-calls.log' ;;
esac
exit 0
"
mkdir -p "$ws/.claude/skills/wrapup" && echo stub > "$ws/.claude/skills/wrapup/SKILL.md"
( cd "$ws" \
  && git init -q 2>/dev/null \
  && git -c user.email=t@t -c user.name=t add . \
  && git -c user.email=t@t -c user.name=t commit -q -m 'work on foo-10 — closing it out' )
echo 'sibling churn'        > "$ws/foreign.txt"
echo 'package main'         > "$ws/own.go"     # this worker's own uncommitted new file
printf '%s\n' '?? foreign.txt' > "$ws/.beads/runner-logs/dirty-baseline.txt"

run_audit "$ws" "foo-10" "$shim" >/dev/null 2>&1

inc_log="$ws/.beads/runner-logs/incidents.log"
create_log="$ws/.beads/runner-logs/bd-create-calls.log"
if [[ -s "$inc_log" ]] && grep -q "dirty_tree" "$inc_log" \
   && grep -q "DISCIPLINE_BYPASS" "$inc_log" \
   && [[ -s "$create_log" ]] && grep -q "discipline-bypass" "$create_log"; then
  PASS=$((PASS+1)); echo "  PASS: T10 own dirt alongside foreign still fires dirty_tree + P1 bead"
else
  FAIL=$((FAIL+1)); FAILED_NAMES+=("T10")
  echo "  FAIL: T10 expected dirty_tree DISCIPLINE_BYPASS + regression bead, got:"
  [[ -s "$inc_log" ]] && cat "$inc_log" | sed 's/^/    incident: /' || echo "    (no incident)"
  [[ -s "$create_log" ]] && cat "$create_log" | sed 's/^/    create: /' || echo "    (no bd create)"
fi
rm -rf "$ws" "$shim"

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  echo "Failed tests: ${FAILED_NAMES[*]}"
  exit 1
fi
exit 0
