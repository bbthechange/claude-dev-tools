#!/bin/bash
# beads-runner/lib/test-workspace-inventory-producer.sh — focused unit test for
# the workspace_inventory producer (claude-tools-ztb6 Phase A; epic
# claude-tools-vvgy). Exercises ONLY the producer surface in local-agent.sh +
# the drainer's workspace_inventory → workspace-inventory-put dispatch.
#
# Asserts:
#   1. la_publish_workspace_inventory with stubbed bd writes one valid jsonl
#      line to la__outbox.
#   2. The line's shape matches the wire contract (frozen in the epic).
#   3. counts are correctly aggregated from stubbed bd outputs.
#   4. in_progress_beads includes ALL in_progress beads (never capped by the
#      top_n bound — the Board needs the full set).
#   5. top_n_beads is bounded to <=20 entries even if bd returns more.
#   6. Missing jq → returns 0 silently.
#   7. Missing bd → returns 0 silently.
#   8. la_outbox_drain maps workspace_inventory lines to op=workspace-
#      inventory-put.
#
# Self-contained: writes its own bd/jq shims under a tmpdir on PATH; never
# touches the developer's real bd queue.
set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/local-agent.sh"
CT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/co-http-transport.sh"
[[ -f "$LIB" ]] || { echo "FATAL: local-agent.sh not found at $LIB"; exit 2; }
[[ -f "$CT_LIB" ]] || { echo "FATAL: co-http-transport.sh not found at $CT_LIB"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
ck()  { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAKEBIN="$WORK/bin"; mkdir -p "$FAKEBIN"

# ── bd shim ──────────────────────────────────────────────────────────────────
# Reads a directory of canned responses keyed by the request signature so each
# test case can plant its own dataset without touching the shim.
export WIP_BD_FIXTURE="$WORK/bd-fixture"
mkdir -p "$WIP_BD_FIXTURE"
cat > "$FAKEBIN/bd" <<'EOF'
#!/bin/bash
# Args: list --status=<S> --json    → cat $WIP_BD_FIXTURE/list-<S>.json
#       ready --json                → cat $WIP_BD_FIXTURE/ready.json
# Anything else → empty array.
sub="${1:-}"
case "$sub" in
  list)
    status=""
    for a in "$@"; do
      case "$a" in
        --status=*) status="${a#--status=}" ;;
      esac
    done
    f="$WIP_BD_FIXTURE/list-${status}.json"
    if [[ -f "$f" ]]; then cat "$f"; else echo "[]"; fi
    ;;
  ready)
    f="$WIP_BD_FIXTURE/ready.json"
    if [[ -f "$f" ]]; then cat "$f"; else echo "[]"; fi
    ;;
  *) echo "[]" ;;
esac
exit 0
EOF
chmod +x "$FAKEBIN/bd"
export PATH="$FAKEBIN:$PATH"

export LOG_DIR="$WORK/.beads/runner-logs"
export RUNNER_ID="wip-test-runner"
export PROJECT_REF="wip-test-project"
export BEADS_DAEMON_CACHE_DIR="$WORK/empty-daemon-cache"
mkdir -p "$LOG_DIR" "$BEADS_DAEMON_CACHE_DIR"
# shellcheck source=/dev/null
source "$LIB"

OUTBOX="$LOG_DIR/coordinator-outbox.jsonl"

# Helper: write a jq-style array of N synthetic open beads with monotonically
# increasing updated_at (so we can verify ordering / cap).
gen_open_beads() {
  local n="$1" i out="["
  for ((i=1; i<=n; i++)); do
    [[ "$i" -gt 1 ]] && out+=","
    out+="{\"id\":\"proj-${i}\",\"title\":\"Bead $i\",\"status\":\"open\",\"updated_at\":\"2026-05-$(printf '%02d' "$((i % 28 + 1))")T00:00:00Z\",\"labels\":[\"stage:impl\"]}"
  done
  out+="]"
  printf '%s' "$out"
}

# ── Case 1+2: writes a single valid jsonl line, shape matches wire contract ──
echo "── Case 1+2: producer writes one jsonl line with the wire-contract shape ──"
: > "$OUTBOX"
rm -f "$WIP_BD_FIXTURE"/*.json
printf '%s' "$(gen_open_beads 3)" > "$WIP_BD_FIXTURE/list-open.json"
printf '%s' "$(gen_open_beads 2)" > "$WIP_BD_FIXTURE/list-in_progress.json"
printf '%s' "$(gen_open_beads 1)" > "$WIP_BD_FIXTURE/list-blocked.json"
printf '%s' "$(gen_open_beads 2)" > "$WIP_BD_FIXTURE/ready.json"

la_publish_workspace_inventory
ck "exactly one line appended to la__outbox" test "$(wc -l < "$OUTBOX" | tr -d ' ')" = "1"

jq_field() { jq -r "$1" "$OUTBOX"; }      # reads the single-line outbox
is_valid_json() { jq -e . "$OUTBOX" >/dev/null 2>&1; }
obs_at_is_rfc3339() {
  local v; v="$(jq -r '.observed_at' "$OUTBOX")"
  [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}
ck "line is valid JSON"                       is_valid_json
ck "report == workspace_inventory"            test "$(jq_field '.report')" = "workspace_inventory"
ck "schema_version == 1"                      test "$(jq_field '.schema_version')" = "1"
ck "principal stamped (§9.1)"                 test "$(jq_field '.principal')" = "brian"
ck "runner_id stamped"                        test "$(jq_field '.runner_id')" = "wip-test-runner"
ck "project_ref stamped"                      test "$(jq_field '.project_ref')" = "wip-test-project"
ck "observed_at is RFC-3339 Z"                obs_at_is_rfc3339
ck "counts is an object"                      test "$(jq_field '.counts | type')" = "object"
ck "in_progress_beads is an array"            test "$(jq_field '.in_progress_beads | type')" = "array"
ck "top_n_beads is an array"                  test "$(jq_field '.top_n_beads | type')" = "array"

# ── Case 3: counts correctly aggregated from stubbed bd ──────────────────────
echo "── Case 3: counts are aggregated from bd's JSON ──"
ck "counts.open == 3"          test "$(jq_field '.counts.open')" = "3"
ck "counts.ready == 2"         test "$(jq_field '.counts.ready')" = "2"
ck "counts.in_progress == 2"   test "$(jq_field '.counts.in_progress')" = "2"
ck "counts.blocked == 1"       test "$(jq_field '.counts.blocked')" = "1"
ck "counts values are numbers" test "$(jq_field '[.counts[] | type] | unique | join(",")')" = "number"

# Shape of in_progress entries: each item is {bead_ref, title, stage}.
ck "in_progress_beads[0].bead_ref present" test "$(jq_field '.in_progress_beads[0].bead_ref')" != ""
ck "in_progress_beads[0].stage extracted from stage:* label" \
   test "$(jq_field '.in_progress_beads[0].stage')" = "impl"

# ── Case 4: in_progress_beads includes ALL in_progress beads ─────────────────
echo "── Case 4: in_progress_beads is NOT capped by top_n bound (25 > 20) ──"
: > "$OUTBOX"
printf '%s' "$(gen_open_beads 25)" > "$WIP_BD_FIXTURE/list-in_progress.json"
printf '%s' "$(gen_open_beads 3)"  > "$WIP_BD_FIXTURE/list-open.json"
la_publish_workspace_inventory
ck "in_progress_beads has all 25 entries" \
   test "$(jq_field '.in_progress_beads | length')" = "25"

# ── Case 5: top_n_beads bounded to <=20 ──────────────────────────────────────
echo "── Case 5: top_n_beads is bounded to 20 even when bd returns 30 ──"
: > "$OUTBOX"
printf '%s' "$(gen_open_beads 30)" > "$WIP_BD_FIXTURE/list-open.json"
printf '[]' > "$WIP_BD_FIXTURE/list-in_progress.json"
la_publish_workspace_inventory
ck "top_n_beads is bounded to 20" \
   test "$(jq_field '.top_n_beads | length')" = "20"
ck "top_n_beads entries have status field" \
   test "$(jq_field '.top_n_beads[0].status')" = "open"

# ── Case 6: missing jq → silent 0 ────────────────────────────────────────────
echo "── Case 6: missing jq returns 0 silently (no crash, no abort) ──"
: > "$OUTBOX"
# Hide jq by routing PATH past the real shell jq with a no-op shadow that
# fails the `command -v jq` check by being absent. Easier: put a different
# PATH that excludes jq.
(
  # Build a stripped PATH that has bd (our shim) but no jq anywhere.
  # macOS ships jq in /usr/bin or /opt — point PATH to ONLY FAKEBIN.
  export PATH="$FAKEBIN"
  set +e
  la_publish_workspace_inventory; rc=$?
  set -e
  exit "$rc"
)
RC=$?
ck "rc == 0 with jq absent" test "$RC" = "0"
ck "no line written when jq absent" test ! -s "$OUTBOX"

# ── Case 7: missing bd → silent 0 ────────────────────────────────────────────
# Build a clean tmpdir-PATH that has jq (symlinked from the real location) but
# NO bd anywhere. This works whether or not the developer's system PATH
# happens to include a real bd binary.
echo "── Case 7: missing bd returns 0 silently ──"
JQONLY="$WORK/jq-only"; mkdir -p "$JQONLY"
JQ_REAL="$(command -v jq 2>/dev/null || true)"
: > "$OUTBOX"
if [[ -n "$JQ_REAL" ]]; then
  ln -sf "$JQ_REAL" "$JQONLY/jq"
  (
    export PATH="$JQONLY"
    set +e
    la_publish_workspace_inventory; rc=$?
    set -e
    exit "$rc"
  )
  RC=$?
  ck "rc == 0 with bd absent" test "$RC" = "0"
  ck "no line written when bd absent" test ! -s "$OUTBOX"
else
  echo "  (skip: no jq available to build a bd-less PATH for this case)"
fi

# ── Case 8: drainer maps workspace_inventory → workspace-inventory-put ───────
echo "── Case 8: la_outbox_drain dispatches workspace_inventory → workspace-inventory-put ──"
# Source the HTTP transport with COORDINATOR_URL set so la_outbox_drain becomes
# defined; replace co_request with a recorder so we can assert the op.
export COORDINATOR_URL="https://example.invalid/coord"
export COORDINATOR_TOKEN="test-bearer"
# shellcheck source=/dev/null
source "$CT_LIB"

CALLS="$WORK/co.calls"
: > "$CALLS"
# Override co_request: record op + first arg, return 0.
co_request() {
  shift                       # drop bearer
  local op="$1"; shift
  printf '%s\t%s\n' "$op" "${1:-}" >> "$CALLS"
  return 0
}

# Plant a fresh outbox with one workspace_inventory line + one heartbeat line.
: > "$OUTBOX"
printf '%s\n' '{"report":"workspace_inventory","schema_version":1,"counts":{"open":1,"ready":0,"in_progress":0,"blocked":0}}' >> "$OUTBOX"
printf '%s\n' '{"report":"heartbeat","schema_version":1,"actual":"running"}' >> "$OUTBOX"

la_outbox_drain "test-bearer" >/dev/null 2>&1 || true

ck "drain called co_request for workspace-inventory-put" \
   grep -q '^workspace-inventory-put	' "$CALLS"
ck "drain still maps heartbeat verbatim (regression guard)" \
   grep -q '^heartbeat	' "$CALLS"
ck "outbox emptied after a successful drain" \
   test ! -s "$OUTBOX"

echo ""
echo "── Summary ──"
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
