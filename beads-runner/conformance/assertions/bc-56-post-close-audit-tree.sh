#!/bin/bash
# BC-56 — `post_close_audit` PORTED to the v2 runner.sh: a SUCCESS that closed
# the bead WITHOUT shipping a commit (close-checklist Stop hook bypassed via the
# 8-block cap) is surfaced as a P1 `discipline-bypass` regression bead + incident
# + marker note — never a silent disappear. (v1: run-beads-tasks.sh post_close_audit;
# v2 port: claude-tools-v2cut.3. The cutover blocker the v2c3 COVERAGE-AUDIT filed.)
#
# Binds: INTERFACE.md v1 §8.2 (forensic side-channel) + BEHAVIORAL-CONTRACT BC-56
# (claude-tools-apen audit, claude-tools-td0y hook, claude-tools-02ec full-id grep).
#
# UNIT under test = post_close_audit() inside runner.sh. Like v1's top-level
# test-post-close-audit.sh, this rig EXTRACTS the function (+ its one helper,
# record_incident) and drives it with purpose-built bd/git shims in a real temp
# git repo — NOT via run_runner. WHY NOT end-to-end: under the faked worker the
# audit is SELF-PERPETUATING (every commit-less close files a bead that is itself
# closed commit-less → another bead → an infinite drain), which is exactly why
# the harness globally exports RUNNER_SKIP_POST_CLOSE_AUDIT=1. So this rig must
# opt the audit BACK IN (env unset) for every fire-case, and one case PINS that
# the opt-out seam the harness relies on still no-ops.
#
# SCAR (silent-when-wrong): a closed-but-not-shipped bead vanishing into the
# board with no trace (the claude-tools-apen/td0y close-discipline scar; the same
# scar CLAUDE.md's web-acceptance discipline guards). NEVER reopens the original
# bead — that triage call is the human's (reopening could loop the broken worker).
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/runner.sh"
[[ -f "$RUNNER" ]] || { echo "RESULT|FAIL|BC-56|-|runner.sh not found at $RUNNER"; exit 1; }

# This rig manages its own fixtures (real git repos), not the harness WORKDIR.
_TMPS=()
_bc56_cleanup() { local d; for d in "${_TMPS[@]:-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf "$d"; done; return 0; }
trap _bc56_cleanup EXIT

# Extract a `name() {` … `}` function block from the runner (same brittle-on-
# purpose awk as v1's test: a refactor that breaks the one-line `name() {` /
# column-0 `}` shape fails loudly here, signalling the rig needs re-aligning).
extract_function() {  # <name> <src>
  awk -v fn="$1" '
    $0 ~ "^" fn "\\(\\) \\{" { inside=1 }
    inside { print }
    inside && /^\}$/ { exit }
  ' "$2"
}

mkfixture() { local d; d="$(mktemp -d -t bc56-ws.XXXX)"; mkdir -p "$d/.beads/runner-logs"; _TMPS+=("$d"); echo "$d"; }
mkshim()    { local d; d="$(mktemp -d -t bc56-shim.XXXX)"; _TMPS+=("$d"); echo "$d"; }

# write_bd_shim <shimdir> <ws> <id> <status> <notesfile>
# Stateful enough for the four checks: `show --json` → status; `show --long
# --json` → status+notes (read from <notesfile> so newlines/quotes survive);
# `create` → the scrapeable "✓ Created issue:" line + a call log; `update` → a
# call log (so the rig can prove the note was appended AND the bead was never
# reopened). Any other id → `[]` (audit no-ops on a status it can't read).
write_bd_shim() {
  local dir="$1" ws="$2" id="$3" status="$4" notesfile="$5"
  {
    echo '#!/bin/bash'
    echo "BD_ID='$id'"
    echo "BD_STATUS='$status'"
    echo "BD_NOTES_FILE='$notesfile'"
    echo "BD_CREATE_LOG='$ws/.beads/runner-logs/bd-create-calls.log'"
    echo "BD_UPDATE_LOG='$ws/.beads/runner-logs/bd-update-calls.log'"
    cat <<'LOGIC'
cmd="$1"; shift || true
case "$cmd" in
  show)
    id="$1"; shift || true
    long=0; for a in "$@"; do [[ "$a" == "--long" ]] && long=1; done
    if [[ "$id" == "$BD_ID" ]]; then
      if [[ $long -eq 1 ]]; then
        jq -cn --arg s "$BD_STATUS" --rawfile n "$BD_NOTES_FILE" '[{status:$s,notes:$n}]'
      else
        jq -cn --arg s "$BD_STATUS" '[{status:$s}]'
      fi
    else
      echo '[]'
    fi ;;
  create)  echo "$*" >> "$BD_CREATE_LOG"; echo "✓ Created issue: claude-tools-fake — discipline-bypass" ;;
  update)  echo "$*" >> "$BD_UPDATE_LOG" ;;
  *) : ;;
esac
exit 0
LOGIC
  } > "$dir/bd"
  chmod +x "$dir/bd"
}

# run_audit <ws> <task_id> <shimdir> <skip 0|1>
# Renders record_incident + post_close_audit into a sourceable subshell and
# invokes the audit. skip=1 sets the opt-out seam; default (0) opts the audit IN.
run_audit() {
  local ws="$1" task_id="$2" shim="$3" skip="${4:-0}"
  local log_dir="$ws/.beads/runner-logs"
  local rec_fn audit_fn
  rec_fn="$(extract_function record_incident "$RUNNER")"
  audit_fn="$(extract_function post_close_audit "$RUNNER")"
  [[ -n "$rec_fn" && -n "$audit_fn" ]] || { echo "EXTRACT-FAILED" >&2; return 99; }
  local skipline=""
  [[ "$skip" == "1" ]] && skipline="export RUNNER_SKIP_POST_CLOSE_AUDIT=1"
  PATH="$shim:$PATH" bash -c "
    set -uo pipefail
    cd '$ws'
    unset RUNNER_SKIP_POST_CLOSE_AUDIT 2>/dev/null || true
    unset BEADS_DIRTY_BASELINE 2>/dev/null || true  # claude-tools-f4ub: force \$LOG_DIR fallback
    $skipline
    INCIDENTS=()
    INCIDENTS_LOG='$log_dir/incidents.log'
    LOG_DIR='$log_dir'
    $rec_fn
    $audit_fn
    post_close_audit '$task_id' 'test-session-anchor'
  " 2>/dev/null
}

# convenience: read a capture file (empty string if absent)
rd() { cat "$1" 2>/dev/null || true; }

# ── C1: bead NOT closed → audit no-ops ───────────────────────────────────────
ws=$(mkfixture); shim=$(mkshim)
: > "$ws/.beads/runner-logs/notes.txt"
write_bd_shim "$shim" "$ws" "foo-1" "open" "$ws/.beads/runner-logs/notes.txt"
( cd "$ws" && git init -q && git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init )
run_audit "$ws" "foo-1" "$shim" 0
inc="$ws/.beads/runner-logs/incidents.log"; crl="$ws/.beads/runner-logs/bd-create-calls.log"
_expect "BC-56" "apen" "bead NOT closed ⇒ audit no-ops (status re-verify gate; no incident, no regression bead)"
_need "no incident row written"   bash -c '[[ ! -s "'"$inc"'" ]]'
_need "no regression bead filed"   bash -c '[[ ! -s "'"$crl"'" ]]'
_emit

# ── C2: closed, no commit, no debrief → fires + files bead + never reopens ───
ws=$(mkfixture); shim=$(mkshim)
: > "$ws/.beads/runner-logs/notes.txt"   # empty notes ⇒ missing_debrief
write_bd_shim "$shim" "$ws" "foo-2" "closed" "$ws/.beads/runner-logs/notes.txt"
# A repo with one commit that does NOT reference foo-2 ⇒ close_without_commit.
# No wrapup skill ⇒ check 3 skipped. Clean tree (logs live under the excluded
# .beads/runner-logs/) ⇒ dirty_tree does NOT fire. So exactly two checks fire.
( cd "$ws" && git init -q && git -c user.email=t@t -c user.name=t commit --allow-empty -q -m 'unrelated init' )
run_audit "$ws" "foo-2" "$shim" 0
inc="$ws/.beads/runner-logs/incidents.log"; crl="$ws/.beads/runner-logs/bd-create-calls.log"; upd="$ws/.beads/runner-logs/bd-update-calls.log"
_expect "BC-56" "apen/§8.2" "closed without commit/debrief ⇒ DISCIPLINE_BYPASS incident naming the failed checks"
_need "DISCIPLINE_BYPASS incident row"        contains "$(rd "$inc")" "DISCIPLINE_BYPASS:"
_need "close_without_commit named"            contains "$(rd "$inc")" "close_without_commit"
_need "missing_debrief named"                 contains "$(rd "$inc")" "missing_debrief"
_emit
_expect "BC-56" "apen" "files P1 discipline-bypass regression bead FIRST, cross-refs its id, appends marker note, NEVER reopens"
_need "regression bead created with discipline-bypass label" matches "$(rd "$crl")" "discipline-bypass"
_need "incident cross-references the regression id"          contains "$(rd "$inc")" "regression=claude-tools-fake"
_need "Runner: DISCIPLINE_BYPASS marker note on original bead" matches "$(rd "$upd")" "Runner: DISCIPLINE_BYPASS"
_need "original bead NEVER reopened (no --status=open)"      notcontains "$(rd "$upd")" "--status=open"
_need "original bead never 'reopen'ed"                        bash -c '! grep -qw reopen "'"$upd"'" 2>/dev/null'
_emit

# ── C3: the opt-out seam — RUNNER_SKIP_POST_CLOSE_AUDIT=1 ⇒ no-op ─────────────
# Same fixture as C2 (would fire), but with the seam the conformance harness
# globally sets. PINS that the harness's opt-out still works AND that fire-cases
# above genuinely opt back IN (else they'd be vacuously green under the harness).
ws=$(mkfixture); shim=$(mkshim)
: > "$ws/.beads/runner-logs/notes.txt"
write_bd_shim "$shim" "$ws" "foo-3" "closed" "$ws/.beads/runner-logs/notes.txt"
( cd "$ws" && git init -q && git -c user.email=t@t -c user.name=t commit --allow-empty -q -m 'unrelated init' )
run_audit "$ws" "foo-3" "$shim" 1
inc="$ws/.beads/runner-logs/incidents.log"; crl="$ws/.beads/runner-logs/bd-create-calls.log"
_expect "BC-56" "d3w9-seam" "RUNNER_SKIP_POST_CLOSE_AUDIT=1 ⇒ audit no-ops even when checks would fire (harness opt-out seam)"
_need "no incident with audit skipped"     bash -c '[[ ! -s "'"$inc"'" ]]'
_need "no regression bead with audit skipped" bash -c '[[ ! -s "'"$crl"'" ]]'
_emit

# ── C4: clean close (commit refs id + debrief + wrapup + clean tree) → no fire ─
ws=$(mkfixture); shim=$(mkshim)
printf '%s\n' "This is a properly long debrief explaining what happened in detail." \
              "wrapup-reviewed: 2026-05-31T10:00:00Z sha=abc clean=0" \
  > "$ws/.beads/runner-logs/notes.txt"
write_bd_shim "$shim" "$ws" "clean-1" "closed" "$ws/.beads/runner-logs/notes.txt"
mkdir -p "$ws/.claude/skills/wrapup"; echo stub > "$ws/.claude/skills/wrapup/SKILL.md"
( cd "$ws" && git init -q \
  && git -c user.email=t@t -c user.name=t add . \
  && git -c user.email=t@t -c user.name=t commit -q -m 'work on clean-1 — closing it out' )
run_audit "$ws" "clean-1" "$shim" 0
inc="$ws/.beads/runner-logs/incidents.log"; crl="$ws/.beads/runner-logs/bd-create-calls.log"
_expect "BC-56" "apen" "clean close (commit references id, debrief present, wrapup marker, clean tree) ⇒ no audit fire"
_need "no incident"        bash -c '[[ ! -s "'"$inc"'" ]]'
_need "no regression bead" bash -c '[[ ! -s "'"$crl"'" ]]'
_emit

# ── C5: short conventional scope only (no full id) → close_without_commit fires
# Mirrors close-checklist T11b / claude-tools-02ec: the runner audit and the
# Stop hook AGREE a short scope alone does NOT satisfy the full-id grep.
ws=$(mkfixture); shim=$(mkshim)
printf '%s\n' "This is a properly long debrief explaining what happened in detail." \
              "wrapup-reviewed: 2026-05-31T10:00:00Z sha=abc clean=0" \
  > "$ws/.beads/runner-logs/notes.txt"
write_bd_shim "$shim" "$ws" "claude-tools-foo" "closed" "$ws/.beads/runner-logs/notes.txt"
mkdir -p "$ws/.claude/skills/wrapup"; echo stub > "$ws/.claude/skills/wrapup/SKILL.md"
( cd "$ws" && git init -q \
  && git -c user.email=t@t -c user.name=t add . \
  && git -c user.email=t@t -c user.name=t commit -q -m 'docs(foo): short scope only, no full id' )
run_audit "$ws" "claude-tools-foo" "$shim" 0
inc="$ws/.beads/runner-logs/incidents.log"
_expect "BC-56" "02ec" "short conventional-commit scope only (no full id) ⇒ close_without_commit fires (agrees with the Stop hook)"
_need "close_without_commit incident" contains "$(rd "$inc")" "close_without_commit"
_emit

# ── C6: full bead id in the commit BODY (Refs:) → clean close, no fire ────────
# Mirrors close-checklist T11c: the recommended wrapup pattern (short scope
# subject + `Refs: <id>` body) satisfies the full-id grep at BOTH sites.
ws=$(mkfixture); shim=$(mkshim)
printf '%s\n' "This is a properly long debrief explaining what happened in detail." \
              "wrapup-reviewed: 2026-05-31T10:00:00Z sha=abc clean=0" \
  > "$ws/.beads/runner-logs/notes.txt"
write_bd_shim "$shim" "$ws" "claude-tools-foo" "closed" "$ws/.beads/runner-logs/notes.txt"
mkdir -p "$ws/.claude/skills/wrapup"; echo stub > "$ws/.claude/skills/wrapup/SKILL.md"
( cd "$ws" && git init -q \
  && git -c user.email=t@t -c user.name=t add . \
  && git -c user.email=t@t -c user.name=t commit -q -m 'docs(foo): short scope subject' -m 'Refs: claude-tools-foo' )
run_audit "$ws" "claude-tools-foo" "$shim" 0
inc="$ws/.beads/runner-logs/incidents.log"; crl="$ws/.beads/runner-logs/bd-create-calls.log"
_expect "BC-56" "02ec" "full bead id in commit BODY (Refs:) ⇒ clean close, no fire (agrees with the Stop hook)"
_need "no incident"        bash -c '[[ ! -s "'"$inc"'" ]]'
_need "no regression bead" bash -c '[[ ! -s "'"$crl"'" ]]'
_emit

# ── C7: foreign-only dirt → downgraded incident, NOT a P1 bead (claude-tools-f4ub)
# The bead closed clean of its OWN work; a concurrent sibling / aux session / a
# stray human edit left a FOREIGN uncommitted file (present in the spawn-time
# baseline, outside the bead's commit set). The v2 audit must NOT file a
# discipline-bypass bead — only a forensic FOREIGN_DIRT_AT_CLOSE incident
# (option C). This is the claude-tools-uxgpre false positive, regression-locked.
ws=$(mkfixture); shim=$(mkshim)
printf '%s\n' "This is a properly long debrief explaining what happened in detail." \
              "wrapup-reviewed: 2026-05-31T10:00:00Z sha=abc clean=0" \
  > "$ws/.beads/runner-logs/notes.txt"
write_bd_shim "$shim" "$ws" "foreign-1" "closed" "$ws/.beads/runner-logs/notes.txt"
mkdir -p "$ws/.claude/skills/wrapup"; echo stub > "$ws/.claude/skills/wrapup/SKILL.md"
( cd "$ws" && git init -q \
  && git -c user.email=t@t -c user.name=t add . \
  && git -c user.email=t@t -c user.name=t commit -q -m 'work on foreign-1 — closing it out' )
# foreign file in the shared tree + the spawn-time baseline that records it as
# pre-existing (outside foreign-1's commit set). run_audit unsets
# BEADS_DIRTY_BASELINE so the audit reads $LOG_DIR/dirty-baseline.txt here.
echo 'a concurrent sibling owns this' > "$ws/foreign.txt"
printf '%s\n' '?? foreign.txt' > "$ws/.beads/runner-logs/dirty-baseline.txt"
run_audit "$ws" "foreign-1" "$shim" 0
inc="$ws/.beads/runner-logs/incidents.log"; crl="$ws/.beads/runner-logs/bd-create-calls.log"
_expect "BC-56" "f4ub" "foreign-only dirt (outside change set, in spawn baseline) ⇒ downgraded FOREIGN_DIRT incident, never a P1 discipline-bypass bead"
_need "FOREIGN_DIRT_AT_CLOSE incident row"   contains "$(rd "$inc")" "FOREIGN_DIRT_AT_CLOSE"
_need "no DISCIPLINE_BYPASS classification"  notcontains "$(rd "$inc")" "DISCIPLINE_BYPASS"
_need "no dirty_tree finding"                notcontains "$(rd "$inc")" "dirty_tree"
_need "no regression bead filed"             bash -c '[[ ! -s "'"$crl"'" ]]'
_emit

_bc56_cleanup
exit 0
