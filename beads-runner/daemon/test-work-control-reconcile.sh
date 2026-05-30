#!/bin/bash
# beads-runner/daemon/test-work-control-reconcile.sh — L2 (claude-tools-uxvl2)
# WORK→CONTROL auto-close reconciler conformance (inbox-lifecycle §7 Option 2).
#
# WHAT THIS PROVES
#   PART 0 — file exists, parses, defines the public API.
#   PART A — resolved-outside-flow truth table (closed / self-unblocked / still
#            blocked+human).
#   PART B — workspace resolution by longest project_ref prefix.
#   PART C — reconcile_once emits a well-formed bead_status_changed line onto the
#            daemon outbox for a closed bead, and the line's `report` maps to the
#            engine `bead-status-changed` op via la_outbox_drain.
#   PART D — a still-blocked+human bead is NOT published (no dead-card churn).
#   PART E — idempotency: a second pass for the same (bead_ref, status) emits NO
#            duplicate line (the §7.6.4 tuple contract).
#   PART F — DAEMON_WC_DISABLED canary writes a marker but no outbox line.
#
# Run: bash beads-runner/daemon/test-work-control-reconcile.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
LIB="$HERE/work-control-reconcile-poll.sh"
TRANSPORT="$REPO_ROOT/lib/co-http-transport.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
eq()  { [[ "$1" == "$2" ]] && ok "$3" || bad "$3 (got '$1' want '$2')"; }

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " L2 work→control auto-close reconciler — claude-tools-uxvl2"
echo "════════════════════════════════════════════════════════════════════"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ════════════════════════════════════════════════════════════════════════════
# PART 0 — file exists, parses, defines the public API
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART 0 — file exists, parses, defines the API ──"
[[ -f "$LIB" ]] && ok "work-control-reconcile-poll.sh present" || bad "lib missing"
bash -n "$LIB" 2>/dev/null && ok "lib parses (bash -n clean)" || bad "lib syntax"
( . "$LIB" 2>/dev/null
  declare -F daemon_wc_reconcile_once >/dev/null 2>&1 ) \
  && ok "defines daemon_wc_reconcile_once" || bad "defines daemon_wc_reconcile_once"
grep -q "inbox-lifecycle §7" "$LIB" && ok "carries the inbox-lifecycle §7 provenance banner" || bad "§7 banner"

# ════════════════════════════════════════════════════════════════════════════
# PART A — resolved-outside-flow truth table
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART A — resolved-outside-flow truth table ──"
(
  set -u
  export DAEMON_CACHE_DIR="$WORK/cacheA"
  # shellcheck source=/dev/null
  . "$LIB"
  daemon_wc__resolved_outside_flow "closed" "human"      && echo CLOSED_YES   || echo CLOSED_NO
  daemon_wc__resolved_outside_flow "open" ""             && echo UNBLK_YES    || echo UNBLK_NO
  daemon_wc__resolved_outside_flow "in_progress" "x,y"   && echo INPROG_YES   || echo INPROG_NO
  daemon_wc__resolved_outside_flow "blocked" "human"     && echo BLKHUMAN_YES || echo BLKHUMAN_NO
  daemon_wc__resolved_outside_flow "open" "human"        && echo OPENHUMAN_YES|| echo OPENHUMAN_NO
) > "$WORK/partA.out" 2>/dev/null
grep -qx "CLOSED_YES"    "$WORK/partA.out" && ok "closed ⇒ resolved-outside-flow"                       || bad "closed should resolve"
grep -qx "UNBLK_YES"     "$WORK/partA.out" && ok "open + no human ⇒ resolved-outside-flow"               || bad "open/no-human should resolve"
grep -qx "INPROG_YES"    "$WORK/partA.out" && ok "in_progress + no human ⇒ resolved-outside-flow"        || bad "in_progress/no-human should resolve"
grep -qx "BLKHUMAN_NO"   "$WORK/partA.out" && ok "blocked + human ⇒ still waiting (NOT resolved)"         || bad "blocked+human must NOT resolve"
grep -qx "OPENHUMAN_NO"  "$WORK/partA.out" && ok "open + human label ⇒ still waiting (NOT resolved)"      || bad "open+human must NOT resolve"

# ════════════════════════════════════════════════════════════════════════════
# PART B — workspace resolution by longest project_ref prefix
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART B — workspace resolution by longest prefix ──"
mkdir -p "$WORK/ws-thirsty" "$WORK/ws-thirsty-backend" "$WORK/ws-ct"
(
  set -u
  export DAEMON_CACHE_DIR="$WORK/cacheB"
  # shellcheck source=/dev/null
  . "$LIB"
  REGISTRY_PROJECT_REFS=("thirsty" "thirsty-backend" "claude-tools")
  REGISTRY_DIRS=("$WORK/ws-thirsty" "$WORK/ws-thirsty-backend" "$WORK/ws-ct")
  echo "A=$(daemon_wc__workspace_for thirsty-9wgz)"
  echo "B=$(daemon_wc__workspace_for thirsty-backend-abc)"
  echo "C=$(daemon_wc__workspace_for claude-tools-uxvl2)"
  echo "D=$(daemon_wc__workspace_for hangoutsBackend-c0b)"
) > "$WORK/partB.out" 2>/dev/null
grep -qx "A=$WORK/ws-thirsty"          "$WORK/partB.out" && ok "thirsty-9wgz ⇒ ws-thirsty"                  || bad "thirsty prefix"
grep -qx "B=$WORK/ws-thirsty-backend"  "$WORK/partB.out" && ok "thirsty-backend-abc ⇒ ws-thirsty-backend (longest prefix wins)" || bad "longest-prefix"
grep -qx "C=$WORK/ws-ct"               "$WORK/partB.out" && ok "claude-tools-uxvl2 ⇒ ws-ct"                 || bad "claude-tools prefix"
grep -qx "D="                          "$WORK/partB.out" && ok "unregistered bead (hangoutsBackend-…) ⇒ empty (not on this machine)" || bad "unregistered ⇒ empty"

# ── shared override scripts for PART C/D/E/F ────────────────────────────────
SNAP="$WORK/snap.sh"
cat > "$SNAP" <<'EOF'
#!/bin/bash
echo "thirsty-closedbead"
echo "thirsty-stillblocked"
EOF
chmod +x "$SNAP"

BDOVR="$WORK/bd.sh"
cat > "$BDOVR" <<'EOF'
#!/bin/bash
case "$1" in
  thirsty-closedbead)    printf 'closed\t\n' ;;
  thirsty-stillblocked)  printf 'blocked\thuman\n' ;;
  *)                     : ;;
esac
EOF
chmod +x "$BDOVR"

# ════════════════════════════════════════════════════════════════════════════
# PART C — reconcile_once emits a well-formed bead_status_changed line
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART C — closed bead ⇒ well-formed outbox event ──"
PART_C="$WORK/cacheC"
mkdir -p "$PART_C"
(
  set -u
  export DAEMON_CACHE_DIR="$PART_C"
  export USAGE_POLL_OUTBOX="$PART_C/coordinator-outbox.jsonl"
  export DAEMON_WC_PUBLISHED_DIR="$PART_C/published"
  export DAEMON_WC_SNAPSHOT_OVERRIDE="$SNAP"
  export DAEMON_WC_BD_OVERRIDE="$BDOVR"
  export PRINCIPAL_V1="brian"
  # shellcheck source=/dev/null
  . "$LIB"
  daemon_wc_reconcile_once
)
OUTBOX="$PART_C/coordinator-outbox.jsonl"
[[ -f "$OUTBOX" ]] && ok "outbox written" || bad "outbox missing"
bsc_count=$(grep -c '"report":"bead_status_changed"' "$OUTBOX" 2>/dev/null || true)
eq "$bsc_count" "1" "exactly ONE bead_status_changed line (closed bead only; blocked+human suppressed)"
LINE=$(grep '"report":"bead_status_changed"' "$OUTBOX" | head -n1)
eq "$(printf '%s' "$LINE" | jq -r '.report')"         "bead_status_changed" "field: report"
eq "$(printf '%s' "$LINE" | jq -r '.schema_version')" "1"                   "field: schema_version (1, int)"
eq "$(printf '%s' "$LINE" | jq -r '.bead_ref')"       "thirsty-closedbead"  "field: bead_ref (the closed bead)"
eq "$(printf '%s' "$LINE" | jq -r '.status')"         "closed"              "field: status"
eq "$(printf '%s' "$LINE" | jq -r '.principal')"      "brian"               "field: principal (wire literal; engine §9.1 stamps on ingest)"
obs="$(printf '%s' "$LINE" | jq -r '.observed_at')"
[[ "$obs" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  && ok "field: observed_at is RFC-3339 UTC" || bad "field: observed_at shape (got '$obs')"
# the marker landed for the published tuple
[[ -f "$PART_C/published/thirsty-closedbead.closed.json" ]] \
  && ok "(bead_ref,status) marker written for the published event" || bad "marker missing"

# the report→op mapping exists in the transport drainer (wire reachability)
grep -q 'bead_status_changed) *op="bead-status-changed"' "$TRANSPORT" \
  && ok "la_outbox_drain maps report=bead_status_changed → op=bead-status-changed" \
  || bad "transport report→op mapping missing"

# ════════════════════════════════════════════════════════════════════════════
# PART D — blocked+human bead is NOT published
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART D — blocked+human bead is NOT published ──"
blk_count=$(grep -c '"bead_ref":"thirsty-stillblocked"' "$OUTBOX" 2>/dev/null || true)
eq "$blk_count" "0" "still-blocked+human bead produced NO event (no dead-card churn)"

# ════════════════════════════════════════════════════════════════════════════
# PART E — idempotency: a second pass emits no duplicate
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART E — idempotency (§7.6.4 (bead_ref,status) tuple) ──"
(
  set -u
  export DAEMON_CACHE_DIR="$PART_C"
  export USAGE_POLL_OUTBOX="$PART_C/coordinator-outbox.jsonl"
  export DAEMON_WC_PUBLISHED_DIR="$PART_C/published"
  export DAEMON_WC_SNAPSHOT_OVERRIDE="$SNAP"
  export DAEMON_WC_BD_OVERRIDE="$BDOVR"
  export PRINCIPAL_V1="brian"
  # shellcheck source=/dev/null
  . "$LIB"
  daemon_wc_reconcile_once   # second pass — marker already present
)
bsc_count2=$(grep -c '"report":"bead_status_changed"' "$OUTBOX" 2>/dev/null || true)
eq "$bsc_count2" "1" "second pass emitted NO duplicate (still exactly 1 line total)"

# ════════════════════════════════════════════════════════════════════════════
# PART F — DAEMON_WC_DISABLED canary: marker, no outbox line
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART F — DAEMON_WC_DISABLED canary ──"
PART_F="$WORK/cacheF"
mkdir -p "$PART_F"
(
  set -u
  export DAEMON_CACHE_DIR="$PART_F"
  export USAGE_POLL_OUTBOX="$PART_F/coordinator-outbox.jsonl"
  export DAEMON_WC_PUBLISHED_DIR="$PART_F/published"
  export DAEMON_WC_SNAPSHOT_OVERRIDE="$SNAP"
  export DAEMON_WC_BD_OVERRIDE="$BDOVR"
  export DAEMON_WC_DISABLED=1
  # shellcheck source=/dev/null
  . "$LIB"
  daemon_wc_reconcile_once
)
f_outbox="$PART_F/coordinator-outbox.jsonl"
f_lines=0; [[ -f "$f_outbox" ]] && f_lines=$(grep -c '"report":"bead_status_changed"' "$f_outbox" 2>/dev/null || true)
eq "$f_lines" "0" "canary: NO outbox line emitted (DAEMON_WC_DISABLED=1)"
[[ -f "$PART_F/published/thirsty-closedbead.closed.json" ]] \
  && ok "canary: marker still written (so we don't retry)" || bad "canary marker missing"

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " L2 work→control reconciler: PASS=$PASS FAIL=$FAIL"
echo "════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "✓ L2 (claude-tools-uxvl2) — work→control reconciler publishes the §7 auto-close event"
