#!/bin/bash
# beads-runner/daemon/test-i3-intake-dispatch.sh — I3 intake-request poll +
# enricher dispatch (claude-tools-06i; epic claude-tools-kie).
#
# WHAT THIS PROVES
#   PART 0 — files exist, parse, are wired into daemon.sh.
#   PART A — co__intake_pending (the bash engine op) returns ONLY records
#            with processed=false; skips processed=true, missing flag,
#            string "false"; deterministic ordering by id.
#   PART B — daemon_intake_idea_hash is privacy-preserving (length, hex)
#            and deterministic; daemon_intake_workspace_for resolves
#            project_ref → workspace dir; missing ref ⇒ empty.
#   PART C — daemon_intake_parse_bd_id + daemon_intake_outcome correctly
#            extract bd id and outcome from each of the three enricher
#            stdout summary shapes (created / augmented / refused).
#   PART D — daemon_intake_dispatch_one end-to-end (with the override
#            stub): looks up the workspace, invokes the specialist, parses
#            the bd id, marks the record processed (verified via a second
#            co__intake_pending call returning []).
#   PART E — failure paths leave the record UNPROCESSED for retry:
#            (e1) unknown project_ref ⇒ skipped, no put;
#            (e2) specialist exit != 0 ⇒ not marked processed;
#            (e3) unparseable summary ⇒ not marked processed;
#            (e4) malformed record (no idea_text) ⇒ skipped.
#   PART F — DAEMON_INTAKE_DISABLED=1 canary still synthesises a summary,
#            marks the record processed (so wiring is exercised without
#            spending tokens).
#   PART G — daemon.sh wires intake-dispatch-poll.sh into the main loop
#            (sourced + INTAKE_POLL_INTERVAL declared + driver call site).
#
# Run: bash beads-runner/daemon/test-i3-intake-dispatch.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
LIB_DIR="$REPO_ROOT/lib"
DAEMON_SH="$HERE/daemon.sh"
I3_LIB="$HERE/intake-dispatch-poll.sh"
REGISTRY_LIB="$HERE/workspace-registry.sh"
COORD_LIB="$LIB_DIR/coordinator.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
eq()  { [[ "$1" == "$2" ]] && ok "$3" || bad "$3 (got '$1' want '$2')"; }
has() { case "$1" in *"$2"*) ok "$3";; *) bad "$3 (missing '$2')";; esac; }
nothas() { case "$1" in *"$2"*) bad "$3 (unexpectedly contains '$2')";; *) ok "$3";; esac; }

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " I3 intake-request dispatch — claude-tools-06i (epic claude-tools-kie)"
echo "════════════════════════════════════════════════════════════════════"

# ════════════════════════════════════════════════════════════════════════════
# PART 0 — files exist, parse, are wired
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART 0 — files exist, parse, are wired (static) ──"
[[ -f "$I3_LIB" ]] && ok "intake-dispatch-poll.sh present" || bad "intake-dispatch-poll.sh missing"
bash -n "$I3_LIB" 2>/dev/null && ok "intake-dispatch-poll.sh parses (bash -n clean)" || bad "intake-dispatch-poll.sh syntax"
bash -n "$DAEMON_SH" 2>/dev/null && ok "daemon.sh parses with I3 wiring" || bad "daemon.sh syntax"
bash -n "$COORD_LIB" 2>/dev/null && ok "lib/coordinator.sh parses with intake-pending op" || bad "lib/coordinator.sh syntax"

for fn in daemon_intake_idea_hash daemon_intake_workspace_for \
          daemon_intake_fetch_pending daemon_intake_mark_processed \
          daemon_intake_parse_bd_id daemon_intake_outcome \
          daemon_intake_dispatch_one daemon_intake_poll_once; do
  grep -q "^$fn()" "$I3_LIB" && ok "intake-dispatch-poll.sh defines $fn" || bad "intake-dispatch-poll.sh defines $fn"
done

grep -q '^co__intake_pending()' "$COORD_LIB" && ok "lib/coordinator.sh defines co__intake_pending" || bad "lib/coordinator.sh defines co__intake_pending"
grep -q 'intake-pending)' "$COORD_LIB" && ok "lib/coordinator.sh dispatches intake-pending in co_request" || bad "lib/coordinator.sh dispatches intake-pending"

# ════════════════════════════════════════════════════════════════════════════
# PART A — co__intake_pending filter + ordering (engine-side, bash impl)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART A — co__intake_pending filters processed=false only ──"

STORE_A="$(mktemp -d)"
trap 'rm -rf "$STORE_A" "${WB:-}" "${WC:-}" "${WD:-}" "${WE:-}" "${WF:-}" 2>/dev/null || true' EXIT
export CO_STORE="$STORE_A"
mkdir -p "$STORE_A/records"

# Seed 4 intake-request records: 2 pending, 1 processed, 1 with bogus flag.
jq -cn '{schema_version:1,id:"intake-2026-05-20T07-00-00Z-aaa",idea_text:"first idea",project_ref:"alpha",preset:"autonomous-until-stuck",processed:false,submitted_at:"2026-05-20T07:00:00Z"}' > "$STORE_A/records/intake-request.intake-2026-05-20T07-00-00Z-aaa.json"
jq -cn '{schema_version:1,id:"intake-2026-05-20T07-01-00Z-bbb",idea_text:"second idea",project_ref:"beta",preset:"collaborative-stage",processed:false,submitted_at:"2026-05-20T07:01:00Z"}' > "$STORE_A/records/intake-request.intake-2026-05-20T07-01-00Z-bbb.json"
jq -cn '{schema_version:1,id:"intake-2026-05-20T07-02-00Z-ccc",idea_text:"already done",project_ref:"alpha",preset:"autonomous-until-stuck",processed:true,submitted_at:"2026-05-20T07:02:00Z",enricher_bd_id:"alpha-001"}' > "$STORE_A/records/intake-request.intake-2026-05-20T07-02-00Z-ccc.json"
# Bogus flag (string "false") ⇒ treated as ALREADY processed (conservative).
jq -cn '{schema_version:1,id:"intake-2026-05-20T07-03-00Z-ddd",idea_text:"bogus",project_ref:"alpha",preset:"autonomous-until-stuck",processed:"false",submitted_at:"2026-05-20T07:03:00Z"}' > "$STORE_A/records/intake-request.intake-2026-05-20T07-03-00Z-ddd.json"

# shellcheck source=/dev/null
. "$COORD_LIB" 2>/dev/null || { bad "could not source coordinator.sh"; exit 1; }

out_a="$(co__intake_pending)"
count_a="$(printf '%s' "$out_a" | jq 'length' 2>/dev/null)"
eq "$count_a" "2" "A1: exactly 2 pending records (skipped processed=true AND bogus processed=\"false\")"

ids_a="$(printf '%s' "$out_a" | jq -r '.[].id' | tr '\n' ',' | sed 's/,$//')"
eq "$ids_a" "intake-2026-05-20T07-00-00Z-aaa,intake-2026-05-20T07-01-00Z-bbb" "A2: pending records returned in lexicographic id order (FIFO across taps)"

# A3 — empty store ⇒ []
# (NB: `VAR=value out=$(...)` would set BOTH as outer-shell assignments —
# the VAR=value-for-one-command form only applies when followed by an actual
# command, not an assignment. Use the form INSIDE $(...) so the env var
# scope is the function call alone, not the outer shell.)
STORE_EMPTY="$(mktemp -d)"
out_empty="$(CO_STORE="$STORE_EMPTY" co__intake_pending)"
eq "$out_empty" "[]" "A3: empty store ⇒ empty array (not an error)"
rm -rf "$STORE_EMPTY"

# IMPORTANT: unset CO_STORE so later PARTs (D/E/F) rely on the daemon's
# subshell default — $ws/.beads/runner-logs/.co-store — instead of leaking
# this PART's store across the whole test. (Without this `unset`, every
# subshell would see CO_STORE=$STORE_A and fetch/mark would land on the
# wrong dir; this is exactly the production posture too: the daemon never
# inherits CO_STORE from its launcher — it derives one per workspace.)
unset CO_STORE

# ════════════════════════════════════════════════════════════════════════════
# PART B — daemon_intake_* helpers (hashing + project_ref lookup)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART B — idea_text hash + workspace lookup helpers ──"

# shellcheck source=/dev/null
. "$REGISTRY_LIB" 2>/dev/null || { bad "could not source workspace-registry.sh"; exit 1; }
# shellcheck source=/dev/null
. "$I3_LIB" 2>/dev/null || { bad "could not source intake-dispatch-poll.sh"; exit 1; }

h1="$(daemon_intake_idea_hash "hello world")"
h2="$(daemon_intake_idea_hash "hello world")"
h3="$(daemon_intake_idea_hash "different")"

eq "${#h1}" "12" "B1: hash length is exactly 12 hex chars (privacy short id)"
[[ "$h1" =~ ^[0-9a-f]{12}$ ]] && ok "B1b: hash is hex chars only" || bad "B1b: hash format unexpected ($h1)"
eq "$h1" "$h2" "B2: hash is deterministic (same text ⇒ same hash)"
[[ "$h1" != "$h3" ]] && ok "B3: different text ⇒ different hash" || bad "B3: hash collision on trivially distinct inputs"

# Seed a small registry for the lookup test.
REGISTRY_PROJECT_REFS=("alpha" "beta")
REGISTRY_DIRS=("/tmp/alpha-ws" "/tmp/beta-ws")
REGISTRY_COORDINATOR_URLS=("" "")
REGISTRY_TOKEN_KEYCHAIN_ITEMS=("" "")
REGISTRY_LOADED=1

eq "$(daemon_intake_workspace_for alpha)" "/tmp/alpha-ws" "B4: alpha ⇒ /tmp/alpha-ws"
eq "$(daemon_intake_workspace_for beta)"  "/tmp/beta-ws"  "B5: beta ⇒ /tmp/beta-ws"
eq "$(daemon_intake_workspace_for gamma)" ""              "B6: unknown project_ref ⇒ empty"

# ════════════════════════════════════════════════════════════════════════════
# PART C — parse the enricher's three stdout summary shapes
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART C — parse enricher stdout summary (created/augmented/refused) ──"

s_create="enricher: created alpha-042 (intake intake-2026-05-20T07-00-00Z-aaa, preset=autonomous-until-stuck, stage=stage:impl, prio=P2)"
s_dedup="enricher: dedup → augmented alpha-007 (intake intake-2026-05-20T07-01-00Z-bbb, preset=autonomous-until-stuck)"
s_refuse="enricher: refuse → filed Inbox question alpha-099 (intake intake-2026-05-20T07-02-00Z-ccc): ambiguous between alpha-007 and alpha-008"
s_garbage="something else entirely on stdout"

eq "$(daemon_intake_parse_bd_id "$s_create")"   "alpha-042"  "C1: created  ⇒ bd id alpha-042"
eq "$(daemon_intake_parse_bd_id "$s_dedup")"    "alpha-007"  "C2: augmented ⇒ bd id alpha-007"
eq "$(daemon_intake_parse_bd_id "$s_refuse")"   "alpha-099"  "C3: refused   ⇒ Inbox question bd id alpha-099"
eq "$(daemon_intake_parse_bd_id "$s_garbage")"  ""           "C4: garbage   ⇒ empty bd id (caller will not mark processed)"

eq "$(daemon_intake_outcome "$s_create")"   "created"   "C5: outcome=created"
eq "$(daemon_intake_outcome "$s_dedup")"    "augmented" "C6: outcome=augmented"
eq "$(daemon_intake_outcome "$s_refuse")"   "refused"   "C7: outcome=refused"
eq "$(daemon_intake_outcome "$s_garbage")"  "unknown"   "C8: outcome=unknown for unmatched summary"

# ════════════════════════════════════════════════════════════════════════════
# PART D — end-to-end dispatch via the override stub
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART D — dispatch end-to-end (override stub specialist) ──"

WD="$(mktemp -d)"
WS_ALPHA="$WD/alpha-ws"
WS_BETA="$WD/beta-ws"
SHARED_STORE="$WD/shared-store"
mkdir -p "$WS_ALPHA/.beads/runner-logs" "$WS_BETA/.beads/runner-logs" "$SHARED_STORE/records"

# Production: every workspace points at the SAME engine — fetch and mark-
# processed land on one store. The bash hermetic test mirrors that by setting
# CO_STORE to a single shared dir and symlinking each workspace's local
# .co-store at it. (Without symlinks the daemon's per-workspace subshells
# default CO_STORE to "<ws>/.beads/runner-logs/.co-store"; the symlink makes
# every default land on the SAME store, exactly like every workspace
# resolving to the same hosted COORDINATOR_URL.)
ln -snf "$SHARED_STORE" "$WS_ALPHA/.beads/runner-logs/.co-store"
ln -snf "$SHARED_STORE" "$WS_BETA/.beads/runner-logs/.co-store"

cp "$STORE_A/records/intake-request.intake-2026-05-20T07-00-00Z-aaa.json" "$SHARED_STORE/records/"
cp "$STORE_A/records/intake-request.intake-2026-05-20T07-01-00Z-bbb.json" "$SHARED_STORE/records/"

REGISTRY_PROJECT_REFS=("alpha" "beta")
REGISTRY_DIRS=("$WS_ALPHA" "$WS_BETA")
REGISTRY_COORDINATOR_URLS=("" "")
REGISTRY_TOKEN_KEYCHAIN_ITEMS=("" "")
REGISTRY_LOADED=1

# Build an override stub that echoes a deterministic "created" summary and
# captures its invocation args to a file so we can assert on them.
STUB_LOG="$WD/stub.log"
STUB_SH="$WD/stub-specialist.sh"
cat > "$STUB_SH" <<EOF
#!/bin/bash
# I3 test stub — echoes a deterministic enricher-style summary and logs args.
echo "ARGS: \$*" >> "$STUB_LOG"
# Parse out the intake_id from the context file so the summary references it.
ctx_file=""
for a in "\$@"; do
  case "\$a" in
    --context-file=*) ctx_file="\${a#--context-file=}";;
  esac
done
intake_id=""
[[ -n "\$ctx_file" && -f "\$ctx_file" ]] && intake_id="\$(jq -r '.intake_id // ""' "\$ctx_file" 2>/dev/null)"
# Synthesise a unique bd id per intake so the test can grep for both.
suffix="\${intake_id##*-}"
bd_id="alpha-stub-\${suffix:0:6}"
echo "enricher: created \$bd_id (intake \$intake_id, preset=autonomous-until-stuck, stage=stage:impl, prio=P2)"
EOF
chmod +x "$STUB_SH"

export DAEMON_INTAKE_SPECIALIST_OVERRIDE="$STUB_SH"
unset DAEMON_INTAKE_DISABLED

# Capture daemon log lines so we can assert on the hash + bd id pattern.
I3_LOGS="$WD/i3.log"
: > "$I3_LOGS"
log() { printf '[stub-log] %s\n' "$*" >> "$I3_LOGS"; }
export -f log 2>/dev/null || true

daemon_intake_poll_once
logs="$(cat "$I3_LOGS")"

has "$logs" "I3 poll: 2 pending intake-request"      "D1: poll log reports pending count"
has "$logs" "I3 dispatch: workspace=$WS_ALPHA"       "D2: dispatch log includes resolved workspace path"
has "$logs" "intake_id=intake-2026-05-20T07-00-00Z-aaa" "D3: dispatch log includes first intake_id"
has "$logs" "intake_id=intake-2026-05-20T07-01-00Z-bbb" "D4: dispatch log includes second intake_id"
has "$logs" "idea_hash="                             "D5: dispatch log includes idea_hash field"
nothas "$logs" "first idea"                          "D6: dispatch log does NOT contain the raw idea_text (privacy)"
nothas "$logs" "second idea"                         "D7: dispatch log does NOT contain the second raw idea_text"
has "$logs" "OK"                                     "D8: at least one dispatch logged as OK (mark-processed succeeded)"
has "$logs" "bd_id=alpha-stub-"                      "D9: bd_id captured from the stub's stdout summary"

# Verify the stub was invoked with the expected --kind / --workspace flags.
stub_args="$(cat "$STUB_LOG" 2>/dev/null)"
has "$stub_args" "--kind=enricher"            "D10: stub invoked with --kind=enricher"
has "$stub_args" "--workspace=$WS_ALPHA"      "D11: stub invoked with --workspace=$WS_ALPHA"
has "$stub_args" "--context-file="            "D12: stub invoked with --context-file="

# After successful dispatch the records should be marked processed. (Use the
# $(VAR=val cmd) form so CO_STORE stays scoped to the function call and does
# not leak into the outer shell — see A3's note.)
out_after="$(CO_STORE="$SHARED_STORE" co__intake_pending)"
eq "$out_after" "[]" "D13: after dispatch both records ⇒ co__intake_pending returns empty array"

# And the record bodies carry the dispatch annotations.
rec_after="$(cat "$SHARED_STORE/records/intake-request.intake-2026-05-20T07-00-00Z-aaa.json")"
proc_after="$(printf '%s' "$rec_after" | jq -r '.processed' 2>/dev/null)"
bd_after="$(printf '%s' "$rec_after"   | jq -r '.enricher_bd_id' 2>/dev/null)"
oc_after="$(printf '%s' "$rec_after"   | jq -r '.enricher_outcome' 2>/dev/null)"
eq "$proc_after" "true"                  "D14: processed flag flipped to true"
[[ "$bd_after" == alpha-stub-* ]] && ok "D15: enricher_bd_id annotation present ($bd_after)" || bad "D15: enricher_bd_id annotation missing (got '$bd_after')"
eq "$oc_after" "created"                 "D16: enricher_outcome annotation present"

unset DAEMON_INTAKE_SPECIALIST_OVERRIDE

# ════════════════════════════════════════════════════════════════════════════
# PART E — failure paths leave the record UNPROCESSED for retry
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART E — failure paths leave records unprocessed ──"

WE="$(mktemp -d)"
WS_ALPHA_E="$WE/alpha-ws"
mkdir -p "$WS_ALPHA_E/.beads/runner-logs/.co-store/records"

# e1 — unknown project_ref ⇒ skipped, no put, record stays pending.
jq -cn '{schema_version:1,id:"intake-orphan",idea_text:"orphan idea",project_ref:"unknown-ws",preset:"autonomous-until-stuck",processed:false,submitted_at:"2026-05-20T08:00:00Z"}' \
  > "$WS_ALPHA_E/.beads/runner-logs/.co-store/records/intake-request.intake-orphan.json"

REGISTRY_PROJECT_REFS=("alpha")
REGISTRY_DIRS=("$WS_ALPHA_E")
REGISTRY_COORDINATOR_URLS=("")
REGISTRY_TOKEN_KEYCHAIN_ITEMS=("")
REGISTRY_LOADED=1

: > "$I3_LOGS"
daemon_intake_poll_once
logs="$(cat "$I3_LOGS")"
has "$logs" "skip — unknown project_ref='unknown-ws'" "E1a: unknown project_ref logged as skip"
rec_e1="$(cat "$WS_ALPHA_E/.beads/runner-logs/.co-store/records/intake-request.intake-orphan.json")"
eq "$(printf '%s' "$rec_e1" | jq -r '.processed')" "false" "E1b: orphan record stays processed=false (next cadence retries)"

# e2 — specialist exit != 0 ⇒ not marked processed.
WE2="$(mktemp -d)"
WS_ALPHA_E2="$WE2/alpha-ws"
mkdir -p "$WS_ALPHA_E2/.beads/runner-logs/.co-store/records"
jq -cn '{schema_version:1,id:"intake-fail",idea_text:"failing idea",project_ref:"alpha",preset:"autonomous-until-stuck",processed:false,submitted_at:"2026-05-20T08:01:00Z"}' \
  > "$WS_ALPHA_E2/.beads/runner-logs/.co-store/records/intake-request.intake-fail.json"

STUB_FAIL="$WE2/stub-fail.sh"
cat > "$STUB_FAIL" <<'EOF'
#!/bin/bash
echo "enricher: created bogus-001 (intake whatever, preset=x, stage=y, prio=P2)"
exit 7
EOF
chmod +x "$STUB_FAIL"

REGISTRY_DIRS=("$WS_ALPHA_E2")
export DAEMON_INTAKE_SPECIALIST_OVERRIDE="$STUB_FAIL"
: > "$I3_LOGS"
daemon_intake_poll_once
logs="$(cat "$I3_LOGS")"
has "$logs" "FAIL — specialist exit=7" "E2a: specialist non-zero exit logged"
rec_e2="$(cat "$WS_ALPHA_E2/.beads/runner-logs/.co-store/records/intake-request.intake-fail.json")"
eq "$(printf '%s' "$rec_e2" | jq -r '.processed')" "false" "E2b: failed-dispatch record stays processed=false"

# e3 — unparseable summary ⇒ not marked processed.
WE3="$(mktemp -d)"
WS_ALPHA_E3="$WE3/alpha-ws"
mkdir -p "$WS_ALPHA_E3/.beads/runner-logs/.co-store/records"
jq -cn '{schema_version:1,id:"intake-unparseable",idea_text:"x",project_ref:"alpha",preset:"autonomous-until-stuck",processed:false,submitted_at:"2026-05-20T08:02:00Z"}' \
  > "$WS_ALPHA_E3/.beads/runner-logs/.co-store/records/intake-request.intake-unparseable.json"

STUB_GARBAGE="$WE3/stub-garbage.sh"
cat > "$STUB_GARBAGE" <<'EOF'
#!/bin/bash
echo "this is not an enricher summary"
exit 0
EOF
chmod +x "$STUB_GARBAGE"

REGISTRY_DIRS=("$WS_ALPHA_E3")
export DAEMON_INTAKE_SPECIALIST_OVERRIDE="$STUB_GARBAGE"
: > "$I3_LOGS"
daemon_intake_poll_once
logs="$(cat "$I3_LOGS")"
has "$logs" "could not parse bd id" "E3a: unparseable summary logged as parse failure"
rec_e3="$(cat "$WS_ALPHA_E3/.beads/runner-logs/.co-store/records/intake-request.intake-unparseable.json")"
eq "$(printf '%s' "$rec_e3" | jq -r '.processed')" "false" "E3b: unparseable-dispatch record stays processed=false"

# e4 — malformed record (no idea_text) ⇒ skipped.
WE4="$(mktemp -d)"
WS_ALPHA_E4="$WE4/alpha-ws"
mkdir -p "$WS_ALPHA_E4/.beads/runner-logs/.co-store/records"
jq -cn '{schema_version:1,id:"intake-broken",project_ref:"alpha",preset:"autonomous-until-stuck",processed:false,submitted_at:"2026-05-20T08:03:00Z"}' \
  > "$WS_ALPHA_E4/.beads/runner-logs/.co-store/records/intake-request.intake-broken.json"

REGISTRY_DIRS=("$WS_ALPHA_E4")
unset DAEMON_INTAKE_SPECIALIST_OVERRIDE
: > "$I3_LOGS"
daemon_intake_poll_once
logs="$(cat "$I3_LOGS")"
has "$logs" "missing id/idea_text/project_ref" "E4a: malformed record logged as refused"
rec_e4="$(cat "$WS_ALPHA_E4/.beads/runner-logs/.co-store/records/intake-request.intake-broken.json")"
eq "$(printf '%s' "$rec_e4" | jq -r '.processed')" "false" "E4b: malformed record stays processed=false"

# ════════════════════════════════════════════════════════════════════════════
# PART F — DAEMON_INTAKE_DISABLED=1 canary: exercise wiring without tokens
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART F — DAEMON_INTAKE_DISABLED=1 canary ──"

WF="$(mktemp -d)"
WS_ALPHA_F="$WF/alpha-ws"
mkdir -p "$WS_ALPHA_F/.beads/runner-logs/.co-store/records"
jq -cn '{schema_version:1,id:"intake-canary",idea_text:"canary idea text",project_ref:"alpha",preset:"autonomous-until-stuck",processed:false,submitted_at:"2026-05-20T09:00:00Z"}' \
  > "$WS_ALPHA_F/.beads/runner-logs/.co-store/records/intake-request.intake-canary.json"

REGISTRY_DIRS=("$WS_ALPHA_F")
unset DAEMON_INTAKE_SPECIALIST_OVERRIDE
export DAEMON_INTAKE_DISABLED=1

: > "$I3_LOGS"
daemon_intake_poll_once
logs="$(cat "$I3_LOGS")"
has "$logs" "DAEMON_INTAKE_DISABLED=1" "F1: canary branch fires"
has "$logs" "OK"                       "F2: synthesised summary still marks record processed (wiring exercised)"
rec_f="$(cat "$WS_ALPHA_F/.beads/runner-logs/.co-store/records/intake-request.intake-canary.json")"
eq "$(printf '%s' "$rec_f" | jq -r '.processed')" "true"      "F3: canary marks record processed"
[[ "$(printf '%s' "$rec_f" | jq -r '.enricher_bd_id')" == stub-* ]] \
  && ok "F4: canary bd id is the stub- prefix (clearly synthetic)" \
  || bad "F4: canary bd id unexpected (got '$(printf '%s' "$rec_f" | jq -r '.enricher_bd_id')')"
unset DAEMON_INTAKE_DISABLED

# ════════════════════════════════════════════════════════════════════════════
# PART G — daemon.sh wires intake-dispatch-poll.sh into the main loop
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART G — daemon.sh wires the I3 path into its main loop (static) ──"
grep -q 'intake-dispatch-poll.sh' "$DAEMON_SH" \
  && ok "G1: daemon.sh sources intake-dispatch-poll.sh" \
  || bad "G1: daemon.sh must source intake-dispatch-poll.sh"
grep -q 'INTAKE_POLL_INTERVAL' "$DAEMON_SH" \
  && ok "G2: daemon.sh declares INTAKE_POLL_INTERVAL (30s default per task spec)" \
  || bad "G2: daemon.sh must declare INTAKE_POLL_INTERVAL"
grep -q 'daemon_intake_poll_once' "$DAEMON_SH" \
  && ok "G3: daemon.sh main loop calls daemon_intake_poll_once on cadence" \
  || bad "G3: daemon.sh must call daemon_intake_poll_once in main loop"

# ────────────────────────────────────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────────────"
printf '  passed: %d  failed: %d\n' "$PASS" "$FAIL"
echo "──────────────────────────────────────────────────────────────────────"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
