#!/usr/bin/env bash
# beads-runner/test-sweep-stranded-live-sessions.sh — Mechanism C sweep
# regression test (claude-tools-uxc3; inbox-lifecycle §8.3.5 / §8.3.7).
#
# Drives sweep-stranded-live-sessions.sh against a STATEFUL FAKE `bd` on PATH
# (same precedent as test-defer-cascade-audit.sh / test-gate-defer.sh — `bd
# init` is too slow for unit work; the fake is a hermetic offline oracle for
# the stranded-detection + idempotent-triage invariants this script enforces).
#
# What this asserts (§8.3.7 Mechanism C + C-3 acceptance):
#   • stranded (no claim, updated_at 6h ago) ⇒ sweep files ONE triage bead,
#     exit 1, and the ORIGINAL bead is untouched (no status flip, no label
#     change — the hard C-3 invariant)
#   • recent (updated_at 5 min ago) ⇒ NO triage, exit 0
#   • a LIVE local claim (alive pid) ⇒ NOT stranded even when stale (the
#     claim-liveness gate), exit 0
#   • a STALE claim (dead pid) ⇒ still stranded; triage filed; audit records
#     the dead-pid claim
#   • idempotency: a second sweep over the same strand files NOTHING
#     (already-triaged), still exit 1
#   • scan (dry-run) detects + reports but FILES NOTHING, exit 1
#   • list emits only the stranded bead-id(s)
#   • a non-human-live-session in_progress bead is NOT a candidate, exit 0
#   • bare / unknown subcommand ⇒ exit 2

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
HELPER="$SCRIPT_DIR/sweep-stranded-live-sessions.sh"
[[ -f "$HELPER" ]] || { echo "test-sweep-stranded-live-sessions.sh: reject — $HELPER not found" >&2; exit 2; }

FAILED=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; FAILED=1; }

WORK="$(mktemp -d 2>/dev/null)" || { echo "mktemp failed"; exit 70; }
trap 'rm -rf "$WORK"' EXIT

# ── stateful fake bd ─────────────────────────────────────────────────────────
# State per bead in $BDST/<id>.json — minimal shape: id/title/description/
# status/updated_at/labels. Commands implemented (just what the sweep calls):
#   bd list --status=in_progress --json
#   bd list --all --json --limit 0
#   bd create --title T -d DESC --type task -p N --labels a,b --deps ...
FAKEBIN="$WORK/bin"
export BDST="$WORK/bdst"
export BDSEQ="$WORK/seq"
mkdir -p "$FAKEBIN" "$BDST"
echo 0 > "$BDSEQ"

cat > "$FAKEBIN/bd" <<'BDEOF'
#!/usr/bin/env bash
set -uo pipefail
cmd="${1:-}"; shift || true

_all_records() {
  local first=1
  printf '['
  for f in "$BDST"/*.json; do
    [[ -f "$f" ]] || continue
    if [[ "$first" == 1 ]]; then first=0; else printf ','; fi
    cat "$f"
  done
  printf ']\n'
}

case "$cmd" in
  list)
    want_status=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --status)    want_status="${2:-}"; shift 2;;
        --status=*)  want_status="${1#--status=}"; shift;;
        --all)       want_status=""; shift;;
        --limit)     shift 2;;
        --limit=*)   shift;;
        --json)      shift;;
        *)           shift;;
      esac
    done
    _all_records | jq --arg s "$want_status" 'map(select($s == "" or .status == $s))'
    ;;

  create)
    title=""; desc=""; labels=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --title)     title="${2:-}"; shift 2;;
        --title=*)   title="${1#--title=}"; shift;;
        -d)          desc="${2:-}"; shift 2;;
        --description) desc="${2:-}"; shift 2;;
        -d=*)        desc="${1#-d=}"; shift;;
        --labels)    labels="${2:-}"; shift 2;;
        --labels=*)  labels="${1#--labels=}"; shift;;
        -l)          labels="${2:-}"; shift 2;;
        --type|-p|--deps|--type=*|-p=*|--deps=*) # ignored by the fake
          case "$1" in *=*) shift;; *) shift 2;; esac;;
        *)           shift;;
      esac
    done
    n=$(cat "$BDSEQ"); n=$((n+1)); echo "$n" > "$BDSEQ"
    id="fake-triage-$n"
    # labels CSV -> JSON array
    labels_json=$(printf '%s' "$labels" | jq -R 'split(",") | map(select(length>0))')
    jq -n --arg id "$id" --arg t "$title" --arg d "$desc" \
          --argjson l "$labels_json" \
          '{id:$id, title:$t, description:$d, status:"open",
            updated_at:"2099-01-01T00:00:00Z", labels:$l}' > "$BDST/$id.json"
    printf '✓ Created issue: %s — %s\n' "$id" "$title"
    ;;

  *) : ;;
esac
exit 0
BDEOF
chmod +x "$FAKEBIN/bd"
export PATH="$FAKEBIN:$PATH"

# Claims dir + a self-contained log dir, both inside the sandbox.
export LOG_DIR="$WORK/runner-logs"
export CLAIMS_DIR="$WORK/claims"
mkdir -p "$LOG_DIR" "$CLAIMS_DIR"

# ── helpers ──────────────────────────────────────────────────────────────────
# Portable (now - N hours/minutes) ISO-8601 Z. GNU then BSD.
_ago_h() { date -u -d "$1 hours ago"   +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-"$1"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; }
_ago_m() { date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-"$1"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; }

# _seed <id> <status> <updated_at> <labels-csv> [<title>]
_seed() {
  local id="$1" status="$2" updated="$3" labels="$4" title="${5:-untitled}"
  local lj; lj=$(printf '%s' "$labels" | jq -R 'split(",") | map(select(length>0))')
  jq -n --arg id "$id" --arg s "$status" --arg u "$updated" --arg t "$title" --argjson l "$lj" \
    '{id:$id, title:$t, description:"orig", status:$s, updated_at:$u, labels:$l}' > "$BDST/$id.json"
}

# _seed_claim <id> <pid> [<host>] — write a Mechanism-A claim file.
_seed_claim() {
  local id="$1" pid="$2" host="${3:-$(hostname 2>/dev/null || echo unknown)}"
  jq -n --arg rid "runner-x" --argjson pid "$pid" --arg host "$host" \
        --arg started "2026-01-01T00:00:00Z" --arg ws "ws-x" \
    '{runner_id:$rid, pid:$pid, host:$host, started_at:$started, workspace:$ws}' \
    > "$CLAIMS_DIR/$id.json"
}

_reset() { rm -f "$BDST"/*.json "$CLAIMS_DIR"/*.json 2>/dev/null || true; echo 0 > "$BDSEQ"; }

# Count triage beads currently on the fake board (label stranded-live-session-triage).
_triage_count() {
  bd list --all --json --limit 0 2>/dev/null \
    | jq '[.[] | select(any(.labels[]?; . == "stranded-live-session-triage"))] | length' 2>/dev/null
}
# Snapshot one bead's status+labels (to prove the sweep never mutates the original).
_orig_state() { jq -c '{status, labels}' "$BDST/$1.json" 2>/dev/null; }

DEAD_PID=2147483647   # INT_MAX — never a live pid on macOS/Linux

# ── case 1: stranded (no claim, 6h old) ⇒ files ONE triage, exit 1, original untouched ──
_reset
_seed strand-1 in_progress "$(_ago_h 6)" "human-live-session,runner-reliability" "Crashed live task"
before="$(_orig_state strand-1)"
out=$(bash "$HELPER" sweep 2>/dev/null); rc=$?
err=$(bash "$HELPER" scan 2>&1 >/dev/null)   # summary line (scan won't re-file)
after="$(_orig_state strand-1)"
tc="$(_triage_count)"
if [[ "$rc" == "1" && "$tc" == "1" ]] \
   && printf '%s' "$out" | grep -q 'strand-1  STRANDED' \
   && printf '%s' "$out" | grep -q 'triaged -> fake-triage-1' \
   && [[ "$before" == "$after" ]]; then
  pass "stranded (no claim, 6h) ⇒ one triage filed, exit 1, original untouched"
else
  fail "case1: rc=$rc triage_count=$tc out='$out' before='$before' after='$after'"
fi

# Verify the filed triage carries the dedup marker + NO human-triage label.
tdesc=$(jq -r '.description' "$BDST/fake-triage-1.json" 2>/dev/null)
tlabels=$(jq -c '.labels' "$BDST/fake-triage-1.json" 2>/dev/null)
if printf '%s\n' "$tdesc" | grep -qxF 'STRANDED_TASK=strand-1' \
   && printf '%s' "$tlabels" | grep -q 'stranded-live-session-triage' \
   && ! printf '%s' "$tlabels" | grep -q 'human-triage'; then
  pass "triage bead carries STRANDED_TASK marker + label, no human-triage"
else
  fail "case1b: tdesc-marker/labels wrong: labels='$tlabels'"
fi

# ── case 2: recent (5 min old) ⇒ NO triage, exit 0 ──────────────────────────
_reset
_seed strand-2 in_progress "$(_ago_m 5)" "human-live-session" "Still live"
out=$(bash "$HELPER" sweep 2>/dev/null); rc=$?
tc="$(_triage_count)"
if [[ "$rc" == "0" && "$tc" == "0" && -z "$out" ]]; then
  pass "recent (5 min) ⇒ no triage, exit 0"
else
  fail "case2: rc=$rc triage_count=$tc out='$out'"
fi

# ── case 3: LIVE local claim ⇒ not stranded even when stale, exit 0 ─────────
_reset
_seed strand-3 in_progress "$(_ago_h 9)" "human-live-session" "Stale but actively claimed"
_seed_claim strand-3 "$$"     # this test process — alive
out=$(bash "$HELPER" sweep 2>/dev/null); rc=$?
tc="$(_triage_count)"
if [[ "$rc" == "0" && "$tc" == "0" && -z "$out" ]]; then
  pass "live local claim ⇒ not stranded even when stale, exit 0"
else
  fail "case3: rc=$rc triage_count=$tc out='$out'"
fi

# ── case 4: STALE (dead-pid) claim ⇒ still stranded; audit records dead claim ─
_reset
_seed strand-4 in_progress "$(_ago_h 9)" "human-live-session" "Crashed runner-claimed task"
_seed_claim strand-4 "$DEAD_PID"
out=$(bash "$HELPER" sweep 2>/dev/null); rc=$?
tc="$(_triage_count)"
tdesc=$(jq -r '.description' "$BDST/fake-triage-1.json" 2>/dev/null)
if [[ "$rc" == "1" && "$tc" == "1" ]] \
   && printf '%s' "$out" | grep -q 'strand-4  STRANDED' \
   && printf '%s\n' "$tdesc" | grep -q 'DEAD'; then
  pass "stale dead-pid claim ⇒ still stranded; audit records the dead claim"
else
  fail "case4: rc=$rc triage_count=$tc out='$out'"
fi

# ── case 4b: claim with a LIVE pid but no/foreign host ⇒ NOT a live owner ───
# (Only an explicit local-host claim earns the LIVE skip; a claim that doesn't
# assert this host can't be liveness-checked locally, so the strand surfaces.)
_reset
_seed strand-4b in_progress "$(_ago_h 9)" "human-live-session" "Alive pid, no host field"
jq -n --arg rid "runner-x" --argjson pid "$$" --arg started "2026-01-01T00:00:00Z" --arg ws "ws-x" \
  '{runner_id:$rid, pid:$pid, started_at:$started, workspace:$ws}' > "$CLAIMS_DIR/strand-4b.json"
out=$(bash "$HELPER" sweep 2>/dev/null); rc=$?
tc="$(_triage_count)"
if [[ "$rc" == "1" && "$tc" == "1" ]] \
   && printf '%s' "$out" | grep -q 'strand-4b  STRANDED'; then
  pass "claim with live pid but no host ⇒ not a live owner; strand surfaces"
else
  fail "case4b: rc=$rc triage_count=$tc out='$out'"
fi

# ── case 5: idempotency — second sweep files nothing, still exit 1 ──────────
_reset
_seed strand-5 in_progress "$(_ago_h 6)" "human-live-session" "Crashed live task"
bash "$HELPER" sweep >/dev/null 2>&1; rc1=$?
tc1="$(_triage_count)"
out2=$(bash "$HELPER" sweep 2>/dev/null); rc2=$?
tc2="$(_triage_count)"
if [[ "$rc1" == "1" && "$rc2" == "1" && "$tc1" == "1" && "$tc2" == "1" ]] \
   && printf '%s' "$out2" | grep -q 'already-triaged'; then
  pass "idempotent: second sweep files nothing (already-triaged), still exit 1"
else
  fail "case5: rc1=$rc1 tc1=$tc1 rc2=$rc2 tc2=$tc2 out2='$out2'"
fi

# ── case 6: scan (dry-run) detects but files NOTHING, exit 1 ────────────────
_reset
_seed strand-6 in_progress "$(_ago_h 6)" "human-live-session" "Crashed live task"
out=$(bash "$HELPER" scan 2>/dev/null); rc=$?
tc="$(_triage_count)"
if [[ "$rc" == "1" && "$tc" == "0" ]] \
   && printf '%s' "$out" | grep -q 'would-file (dry-run)'; then
  pass "scan: detects + reports would-file, files nothing, exit 1"
else
  fail "case6: rc=$rc triage_count=$tc out='$out'"
fi

# ── case 7: list emits only the stranded bead-id ────────────────────────────
_reset
_seed strand-7a in_progress "$(_ago_h 6)" "human-live-session" "Stranded A"
_seed strand-7b in_progress "$(_ago_m 5)" "human-live-session" "Recent (excluded)"
_seed strand-7c in_progress "$(_ago_h 6)" "runner-reliability"  "No live label (excluded)"
out=$(bash "$HELPER" list 2>/dev/null); rc=$?
ids=$(printf '%s\n' "$out" | sort | tr '\n' ' ')
if [[ "$rc" == "1" && "$ids" == "strand-7a " ]]; then
  pass "list emits only the stranded bead-id"
else
  fail "case7: rc=$rc ids='$ids'"
fi

# ── case 8: non-human-live-session in_progress bead is not a candidate ──────
_reset
_seed strand-8 in_progress "$(_ago_h 9)" "runner-reliability" "Runner-owned, no live label"
out=$(bash "$HELPER" sweep 2>/dev/null); rc=$?
tc="$(_triage_count)"
if [[ "$rc" == "0" && "$tc" == "0" && -z "$out" ]]; then
  pass "non-human-live-session in_progress bead is not a candidate"
else
  fail "case8: rc=$rc triage_count=$tc out='$out'"
fi

# ── case 9: bare / unknown subcommand ⇒ exit 2 ──────────────────────────────
bash "$HELPER" >/dev/null 2>&1; rc_bare=$?
bash "$HELPER" frobnicate >/dev/null 2>&1; rc_unknown=$?
if [[ "$rc_bare" == "2" && "$rc_unknown" == "2" ]]; then
  pass "bare + unknown subcommand exit 2 (usage)"
else
  fail "case9: rc_bare=$rc_bare rc_unknown=$rc_unknown (expected 2/2)"
fi

if [[ "$FAILED" == "0" ]]; then
  echo "OK — all sweep-stranded-live-sessions.sh assertions pass"
  exit 0
else
  echo "FAIL — sweep-stranded-live-sessions.sh test assertions failed" >&2
  exit 1
fi
