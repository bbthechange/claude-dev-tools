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

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  echo "Failed tests: ${FAILED_NAMES[*]}"
  exit 1
fi
exit 0
