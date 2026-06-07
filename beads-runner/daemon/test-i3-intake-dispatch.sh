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
          daemon_intake_parse_error_reason \
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

# Seed 5 intake-request records: 2 pending, 1 processed, 1 with bogus flag, 1
# terminal gave_up (processed=false but excluded — claude-tools-t956).
jq -cn '{schema_version:1,id:"intake-2026-05-20T07-00-00Z-aaa",idea_text:"first idea",project_ref:"alpha",preset:"autonomous-until-stuck",processed:false,submitted_at:"2026-05-20T07:00:00Z"}' > "$STORE_A/records/intake-request.intake-2026-05-20T07-00-00Z-aaa.json"
jq -cn '{schema_version:1,id:"intake-2026-05-20T07-01-00Z-bbb",idea_text:"second idea",project_ref:"beta",preset:"collaborative-stage",processed:false,submitted_at:"2026-05-20T07:01:00Z"}' > "$STORE_A/records/intake-request.intake-2026-05-20T07-01-00Z-bbb.json"
jq -cn '{schema_version:1,id:"intake-2026-05-20T07-02-00Z-ccc",idea_text:"already done",project_ref:"alpha",preset:"autonomous-until-stuck",processed:true,submitted_at:"2026-05-20T07:02:00Z",enricher_bd_id:"alpha-001"}' > "$STORE_A/records/intake-request.intake-2026-05-20T07-02-00Z-ccc.json"
# Bogus flag (string "false") ⇒ treated as ALREADY processed (conservative).
jq -cn '{schema_version:1,id:"intake-2026-05-20T07-03-00Z-ddd",idea_text:"bogus",project_ref:"alpha",preset:"autonomous-until-stuck",processed:"false",submitted_at:"2026-05-20T07:03:00Z"}' > "$STORE_A/records/intake-request.intake-2026-05-20T07-03-00Z-ddd.json"
# L3 follow-up (claude-tools-t956): terminal gave_up:true record. It stays
# processed=false forever, so the OLD filter kept re-returning it every cadence
# (monotonic queue growth). It MUST be excluded from the pending queue now.
jq -cn '{schema_version:1,id:"intake-2026-05-20T07-04-00Z-eee",idea_text:"gave up",project_ref:"alpha",preset:"autonomous-until-stuck",processed:false,gave_up:true,gave_up_at:"2026-05-20T07:30:00Z",dispatch_attempts:3,dispatch_state:"gave_up",submitted_at:"2026-05-20T07:04:00Z"}' > "$STORE_A/records/intake-request.intake-2026-05-20T07-04-00Z-eee.json"

# shellcheck source=/dev/null
. "$COORD_LIB" 2>/dev/null || { bad "could not source coordinator.sh"; exit 1; }

out_a="$(co__intake_pending)"
count_a="$(printf '%s' "$out_a" | jq 'length' 2>/dev/null)"
eq "$count_a" "2" "A1: exactly 2 pending records (skipped processed=true, bogus processed=\"false\", AND gave_up:true)"

ids_a="$(printf '%s' "$out_a" | jq -r '.[].id' | tr '\n' ',' | sed 's/,$//')"
eq "$ids_a" "intake-2026-05-20T07-00-00Z-aaa,intake-2026-05-20T07-01-00Z-bbb" "A2: pending records returned in lexicographic id order (FIFO across taps)"

# A2b — the terminal gave_up record is dropped from the queue (claude-tools-t956).
case "$out_a" in
  *"intake-2026-05-20T07-04-00Z-eee"*) bad "A2b: gave_up:true record still returned by co__intake_pending" ;;
  *) ok "A2b: gave_up:true record excluded from co__intake_pending (no monotonic queue growth)" ;;
esac

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
# claude-tools-t956 / §9.5 #2 — the clean self-reported terminal error line.
s_error="enricher: error → permissions denied: bd create blocked by tool guardrail"
s_error_ascii="enricher: error -> mktemp failed in workspace"

eq "$(daemon_intake_parse_bd_id "$s_create")"   "alpha-042"  "C1: created  ⇒ bd id alpha-042"
eq "$(daemon_intake_parse_bd_id "$s_dedup")"    "alpha-007"  "C2: augmented ⇒ bd id alpha-007"
eq "$(daemon_intake_parse_bd_id "$s_refuse")"   "alpha-099"  "C3: refused   ⇒ Inbox question bd id alpha-099"
eq "$(daemon_intake_parse_bd_id "$s_garbage")"  ""           "C4: garbage   ⇒ empty bd id (caller will not mark processed)"

eq "$(daemon_intake_outcome "$s_create")"   "created"   "C5: outcome=created"
eq "$(daemon_intake_outcome "$s_dedup")"    "augmented" "C6: outcome=augmented"
eq "$(daemon_intake_outcome "$s_refuse")"   "refused"   "C7: outcome=refused"
eq "$(daemon_intake_outcome "$s_garbage")"  "unknown"   "C8: outcome=unknown for unmatched summary"

# §9.5 #2 — `enricher: error → <reason>` recognized as a CLEAN terminal error
# (distinct from unknown), no bd id, and the reason parsed honestly (both arrows).
eq "$(daemon_intake_outcome "$s_error")"            "error"  "C9: outcome=error for an enricher: error line"
eq "$(daemon_intake_parse_bd_id "$s_error")"        ""       "C10: error line ⇒ no bd id (still a failed dispatch)"
eq "$(daemon_intake_parse_error_reason "$s_error")"      "permissions denied: bd create blocked by tool guardrail" "C11: error reason parsed (unicode → arrow)"
eq "$(daemon_intake_parse_error_reason "$s_error_ascii")" "mktemp failed in workspace"                             "C12: error reason parsed (ascii -> arrow)"
eq "$(daemon_intake_parse_error_reason "$s_create")"     ""                                                        "C13: non-error line ⇒ empty reason"

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

# e5 — clean `enricher: error → <reason>` ⇒ not marked processed; the STATED
# reason is recorded as last_error (not the generic "unparseable") — §9.5 #2 /
# claude-tools-t956. Still a failed dispatch (no bd id) ⇒ dispatch_state=failing.
WE5="$(mktemp -d)"
WS_ALPHA_E5="$WE5/alpha-ws"
mkdir -p "$WS_ALPHA_E5/.beads/runner-logs/.co-store/records"
jq -cn '{schema_version:1,id:"intake-enr-error",idea_text:"erroring idea",project_ref:"alpha",preset:"autonomous-until-stuck",processed:false,submitted_at:"2026-05-20T08:04:00Z"}' \
  > "$WS_ALPHA_E5/.beads/runner-logs/.co-store/records/intake-request.intake-enr-error.json"

STUB_ERROR="$WE5/stub-error.sh"
cat > "$STUB_ERROR" <<'EOF'
#!/bin/bash
echo "enricher: error → permissions denied: bd create blocked by tool guardrail"
exit 0
EOF
chmod +x "$STUB_ERROR"

REGISTRY_DIRS=("$WS_ALPHA_E5")
export DAEMON_INTAKE_SPECIALIST_OVERRIDE="$STUB_ERROR"
: > "$I3_LOGS"
daemon_intake_poll_once
logs="$(cat "$I3_LOGS")"
has "$logs" "enricher self-reported error" "E5a: clean enricher error logged distinctly (not 'could not parse bd id')"
rec_e5="$(cat "$WS_ALPHA_E5/.beads/runner-logs/.co-store/records/intake-request.intake-enr-error.json")"
eq "$(printf '%s' "$rec_e5" | jq -r '.processed')"      "false"   "E5b: enricher-error record stays processed=false (failed dispatch)"
eq "$(printf '%s' "$rec_e5" | jq -r '.dispatch_state')" "failing" "E5c: enricher-error ⇒ dispatch_state=failing (under the cap)"
has "$(printf '%s' "$rec_e5" | jq -r '.last_error')" "permissions denied" "E5d: last_error carries the enricher's STATED reason (not 'unparseable')"
unset DAEMON_INTAKE_SPECIALIST_OVERRIDE

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
# PART H — L3 (claude-tools-uxvl3): the intake state thread the phone surfaces
#   received → enriching → created  /  failing(n) → gave-up
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART H — L3 intake state thread (failing(n) / gave-up / created / enriching) ──"

# Force the hermetic LOCAL store: if this box's env has COORDINATOR_URL/_TOKEN
# set (e.g. a live beads-runner workspace), co_request would route the puts to
# the REMOTE engine instead of the test's file-backed .co-store, and every
# assertion below would read a stale local record. Unset them so the per-
# workspace `.co-store` symlink is authoritative (this is why PARTs D/E/F can be
# red on a configured box — they don't unset and inherit the live binding).
unset COORDINATOR_URL COORDINATOR_TOKEN CO_STORE

WH="$(mktemp -d)"
WS_ALPHA_H="$WH/alpha-ws"
H_STORE="$WH/shared-store"
mkdir -p "$WS_ALPHA_H/.beads/runner-logs" "$H_STORE/records"
ln -snf "$H_STORE" "$WS_ALPHA_H/.beads/runner-logs/.co-store"

REGISTRY_PROJECT_REFS=("alpha")
REGISTRY_DIRS=("$WS_ALPHA_H")
REGISTRY_COORDINATOR_URLS=("")
REGISTRY_TOKEN_KEYCHAIN_ITEMS=("")
REGISTRY_LOADED=1

# NB: this PART drives `daemon_intake_dispatch_one` DIRECTLY with a literal
# record rather than through `daemon_intake_poll_once`. The discovery step
# (`daemon_intake_fetch_pending` → `co_request intake-pending`) is a known
# hermetic-transport artifact on some dev boxes (PARTs D/E/F exercise it and can
# be red there independent of this change — see the test-i3 token-artifact
# memory). dispatch_one's WRITE path (`co_request put`) works locally, so
# calling it directly + re-reading the record between cadences is the robust way
# to pin the L3 state machine. "Next cadence" = re-cat the record off disk and
# feed it back in (exactly what poll_once would hand it).
H_REC="$H_STORE/records/intake-request.intake-l3-fail.json"
jq -cn '{schema_version:1,id:"intake-l3-fail",idea_text:"a flaky idea",project_ref:"alpha",preset:"autonomous-until-stuck",processed:false,submitted_at:"2026-05-31T08:00:00Z"}' > "$H_REC"

# A stub that ALWAYS fails (specialist non-zero exit) — drives failing→gave-up.
STUB_H_FAIL="$WH/stub-h-fail.sh"
cat > "$STUB_H_FAIL" <<'EOF'
#!/bin/bash
echo "enricher: created should-not-count (intake x)"
exit 9
EOF
chmod +x "$STUB_H_FAIL"
export DAEMON_INTAKE_SPECIALIST_OVERRIDE="$STUB_H_FAIL"
# Cap at 2 so two failed dispatches reach gave-up (keeps the test fast).
export INTAKE_MAX_ATTEMPTS=2

# Attempt 1 — should land in failing(1), NOT gave-up.
: > "$I3_LOGS"; daemon_intake_dispatch_one "$(cat "$H_REC")"
rec_h="$(cat "$H_REC")"
eq "$(printf '%s' "$rec_h" | jq -r '.dispatch_attempts')" "1"        "H1: first failed dispatch ⇒ dispatch_attempts=1"
eq "$(printf '%s' "$rec_h" | jq -r '.dispatch_state')"    "failing"  "H2: first failed dispatch ⇒ dispatch_state=failing"
eq "$(printf '%s' "$rec_h" | jq -r '.processed')"         "false"    "H3: failing record stays processed=false (still retried)"
eq "$(printf '%s' "$rec_h" | jq -r '.gave_up // false')"  "false"    "H4: not gave_up before the cap"
has "$(printf '%s' "$rec_h" | jq -r '.last_error')" "specialist exit=9" "H5: last_error captures the failure reason"

# Attempt 2 — reaches the cap (2) ⇒ gave-up (terminal).
: > "$I3_LOGS"; daemon_intake_dispatch_one "$(cat "$H_REC")"
rec_h="$(cat "$H_REC")"
eq "$(printf '%s' "$rec_h" | jq -r '.dispatch_attempts')" "2"        "H6: second failed dispatch ⇒ dispatch_attempts=2"
eq "$(printf '%s' "$rec_h" | jq -r '.dispatch_state')"    "gave_up"  "H7: reaching INTAKE_MAX_ATTEMPTS ⇒ dispatch_state=gave_up"
eq "$(printf '%s' "$rec_h" | jq -r '.gave_up')"           "true"     "H8: gave_up flag set at the cap"
[[ "$(printf '%s' "$rec_h" | jq -r '.gave_up_at')" != "null" && -n "$(printf '%s' "$rec_h" | jq -r '.gave_up_at')" ]] \
  && ok "H9: gave_up_at timestamp present" || bad "H9: gave_up_at timestamp missing"

# Attempt 3 — gave-up records are SKIPPED: no new attempt, counter frozen, no work logged.
: > "$I3_LOGS"; daemon_intake_dispatch_one "$(cat "$H_REC")"
rec_h="$(cat "$H_REC")"
eq "$(printf '%s' "$rec_h" | jq -r '.dispatch_attempts')" "2"        "H10: gave-up record is skipped (dispatch_attempts frozen at 2)"
eq "$(printf '%s' "$rec_h" | jq -r '.dispatch_state')"    "gave_up"  "H11: gave-up record stays terminal across cadences"
nothas "$(cat "$I3_LOGS")" "I3 dispatch: workspace=" "H12: gave-up record produces no fresh dispatch log line"

unset DAEMON_INTAKE_SPECIALIST_OVERRIDE INTAKE_MAX_ATTEMPTS

# H13/H14/H15 — the success path carries the terminal `created` state + the
# in-flight `enriching` marker is visible to the running enricher (proving the
# received→enriching→created thread, not just the failure half).
H_REC2="$H_STORE/records/intake-request.intake-l3-ok.json"
jq -cn '{schema_version:1,id:"intake-l3-ok",idea_text:"a good idea",project_ref:"alpha",preset:"autonomous-until-stuck",processed:false,submitted_at:"2026-05-31T08:10:00Z"}' > "$H_REC2"
STUB_H_OK="$WH/stub-h-ok.sh"
# The stub reads the live record WHILE running — at that moment the daemon has
# already written the `enriching` marker, so the stub records what the phone
# would show mid-flight.
cat > "$STUB_H_OK" <<EOF
#!/bin/bash
seen="\$(jq -r '.dispatch_state // "none"' "$H_REC2" 2>/dev/null)"
echo "MIDFLIGHT_STATE=\$seen" >> "$WH/midflight.log"
echo "enricher: created alpha-l3ok (intake intake-l3-ok, preset=autonomous-until-stuck, stage=stage:impl, prio=P2)"
EOF
chmod +x "$STUB_H_OK"
export DAEMON_INTAKE_SPECIALIST_OVERRIDE="$STUB_H_OK"
: > "$I3_LOGS"; daemon_intake_dispatch_one "$(cat "$H_REC2")"
rec_h2="$(cat "$H_REC2")"
eq "$(printf '%s' "$rec_h2" | jq -r '.dispatch_state')"  "created" "H13: successful dispatch ⇒ dispatch_state=created"
eq "$(printf '%s' "$rec_h2" | jq -r '.processed')"       "true"    "H14: created record is processed=true"
has "$(cat "$WH/midflight.log" 2>/dev/null)" "MIDFLIGHT_STATE=enriching" "H15: enricher saw the in-flight 'enriching' marker (received→enriching→created)"
unset DAEMON_INTAKE_SPECIALIST_OVERRIDE
rm -rf "$WH" 2>/dev/null || true

# ════════════════════════════════════════════════════════════════════════════
# PART I — L4 (claude-tools-uxvl4): the `overview-request` preset → NO bd task,
#   routes to a dossier-builder → proactive_checkpoint timed-fyi (Blueprint
#   refresh / FYI). The s6/s4 testing invariant: assert NO bead is created.
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART I — overview-request preset: dossier-builder FYI, NO bd task ──"

# Hermetic local store (same posture as PART H): unset any live engine binding so
# the per-workspace .co-store symlink is authoritative.
unset COORDINATOR_URL COORDINATOR_TOKEN CO_STORE

WI="$(mktemp -d)"
WS_ALPHA_I="$WI/alpha-ws"
I_STORE="$WI/shared-store"
mkdir -p "$WS_ALPHA_I/.beads/runner-logs" "$I_STORE/records"
ln -snf "$I_STORE" "$WS_ALPHA_I/.beads/runner-logs/.co-store"

REGISTRY_PROJECT_REFS=("alpha")
REGISTRY_DIRS=("$WS_ALPHA_I")
REGISTRY_COORDINATOR_URLS=("")
REGISTRY_TOKEN_KEYCHAIN_ITEMS=("")
REGISTRY_LOADED=1

# Builder stub: emits a valid {body, items[]} dossier (the dossier-builder I/O
# contract) and logs its invocation args so we can assert --kind=dossier-builder.
I_STUB_LOG="$WI/builder.log"
STUB_BUILDER="$WI/stub-builder.sh"
cat > "$STUB_BUILDER" <<EOF
#!/bin/bash
echo "ARGS: \$*" >> "$I_STUB_LOG"
cat <<'JSON'
{"body":{"dossier_schema_version":2,"tldr":"Where things stand.","sections":[{"heading":"State","prose":"All green."}],"diagrams":[],"full_detail":"A stand-alone paragraph of overview prose for the phone."},"items":[]}
JSON
EOF
chmod +x "$STUB_BUILDER"

# Engine override: capture the generation_input ($2 = gi.json temp file) and echo
# a deterministic dossier id (rc 0 ⇒ "written"). Lets us assert the §4.1 envelope
# WITHOUT sourcing the coordinator/dossier stack.
I_GI_CAPTURE="$WI/gi.json"
STUB_ENGINE="$WI/stub-engine.sh"
cat > "$STUB_ENGINE" <<EOF
#!/bin/bash
# \$1=ws \$2=gi.json
cat "\$2" > "$I_GI_CAPTURE" 2>/dev/null
echo "fyi-overview-test-001"
exit 0
EOF
chmod +x "$STUB_ENGINE"

I_REC="$I_STORE/records/intake-request.intake-l4-overview.json"
jq -cn '{schema_version:1,id:"intake-l4-overview",idea_text:"how is the runner rewrite going?",project_ref:"alpha",preset:"overview-request",processed:false,submitted_at:"2026-06-06T08:00:00Z"}' > "$I_REC"

export DAEMON_INTAKE_SPECIALIST_OVERRIDE="$STUB_BUILDER"
export DAEMON_INTAKE_OVERVIEW_ENGINE_OVERRIDE="$STUB_ENGINE"
: > "$I3_LOGS"
daemon_intake_dispatch_one "$(cat "$I_REC")"
logs="$(cat "$I3_LOGS")"
rec_i="$(cat "$I_REC")"

has "$logs" "I3 overview-dispatch:"                "I1: overview branch taken (distinct log channel)"
has "$(cat "$I_STUB_LOG" 2>/dev/null)" "--kind=dossier-builder" "I2: spawned the dossier-builder hat (NOT the enricher)"
nothas "$(cat "$I_STUB_LOG" 2>/dev/null)" "--kind=enricher"     "I3: enricher was NOT spawned for overview-request"
eq "$(printf '%s' "$rec_i" | jq -r '.processed')"            "true"     "I4: overview record marked processed (queue drains)"
eq "$(printf '%s' "$rec_i" | jq -r '.dispatch_state')"       "overview" "I5: dispatch_state=overview (terminal, not 'created')"
eq "$(printf '%s' "$rec_i" | jq -r '.overview_outcome')"     "written"  "I6: overview_outcome=written"
eq "$(printf '%s' "$rec_i" | jq -r '.overview_dossier_id')"  "fyi-overview-test-001" "I7: overview_dossier_id captured from the engine write"
# THE invariant (bead testing note): NO bd task is ever created for overview-request.
eq "$(printf '%s' "$rec_i" | jq -r '.enricher_bd_id // "ABSENT"')" "ABSENT" "I8: NO enricher_bd_id — no bead was created (s6/s4 invariant)"
nothas "$logs" "bd_id="                                       "I9: overview path logs no bd_id (it makes no bead)"

# The §4.1 generation envelope is the FYI shape: kind=overview, trigger=
# proactive_checkpoint, tier=timed-fyi, bead_ref=intake_id (synthetic anchor).
gi="$(cat "$I_GI_CAPTURE" 2>/dev/null)"
eq "$(printf '%s' "$gi" | jq -r '.kind')"      "overview"             "I10: generation_input kind=overview"
eq "$(printf '%s' "$gi" | jq -r '.trigger')"   "proactive_checkpoint" "I11: generation_input trigger=proactive_checkpoint"
eq "$(printf '%s' "$gi" | jq -r '.tier')"      "timed-fyi"            "I12: generation_input tier=timed-fyi"
eq "$(printf '%s' "$gi" | jq -r '.bead_ref')"  "intake-l4-overview"   "I13: bead_ref anchored on the synthetic intake_id (no real bead)"
eq "$(printf '%s' "$gi" | jq -r '.source.authored_by')" "agent"       "I14: source authored_by=agent (no degraded-fallback badge)"

unset DAEMON_INTAKE_OVERVIEW_ENGINE_OVERRIDE

# I15/I16 — builder failure rides the I3 retry machine (failing, not processed).
I_REC2="$I_STORE/records/intake-request.intake-l4-fail.json"
jq -cn '{schema_version:1,id:"intake-l4-fail",idea_text:"brief me",project_ref:"alpha",preset:"overview-request",processed:false,submitted_at:"2026-06-06T08:05:00Z"}' > "$I_REC2"
STUB_BUILDER_FAIL="$WI/stub-builder-fail.sh"
cat > "$STUB_BUILDER_FAIL" <<'EOF'
#!/bin/bash
echo '{"body":{},"items":[]}'
exit 5
EOF
chmod +x "$STUB_BUILDER_FAIL"
export DAEMON_INTAKE_SPECIALIST_OVERRIDE="$STUB_BUILDER_FAIL"
: > "$I3_LOGS"
daemon_intake_dispatch_one "$(cat "$I_REC2")"
rec_i2="$(cat "$I_REC2")"
eq "$(printf '%s' "$rec_i2" | jq -r '.processed')"      "false"   "I15: failed overview build stays processed=false (retries)"
eq "$(printf '%s' "$rec_i2" | jq -r '.dispatch_state')" "failing" "I16: failed overview build ⇒ dispatch_state=failing"
unset DAEMON_INTAKE_SPECIALIST_OVERRIDE

# I17 — clean builder refusal is TERMINAL (processed, no retry, still no bead).
I_REC3="$I_STORE/records/intake-request.intake-l4-refuse.json"
jq -cn '{schema_version:1,id:"intake-l4-refuse",idea_text:"x",project_ref:"alpha",preset:"overview-request",processed:false,submitted_at:"2026-06-06T08:06:00Z"}' > "$I_REC3"
STUB_BUILDER_REFUSE="$WI/stub-builder-refuse.sh"
cat > "$STUB_BUILDER_REFUSE" <<'EOF'
#!/bin/bash
echo '{"refuse":true,"reason":"workspace too thin to anchor a real overview"}'
EOF
chmod +x "$STUB_BUILDER_REFUSE"
export DAEMON_INTAKE_SPECIALIST_OVERRIDE="$STUB_BUILDER_REFUSE"
: > "$I3_LOGS"
daemon_intake_dispatch_one "$(cat "$I_REC3")"
rec_i3="$(cat "$I_REC3")"
eq "$(printf '%s' "$rec_i3" | jq -r '.processed')"                 "true"     "I17: clean refusal marks processed (no money-burning retry)"
eq "$(printf '%s' "$rec_i3" | jq -r '.overview_outcome')"          "refused"  "I18: refusal recorded as overview_outcome=refused"
eq "$(printf '%s' "$rec_i3" | jq -r '.enricher_bd_id // "ABSENT"')" "ABSENT"  "I19: refusal still creates NO bead"
unset DAEMON_INTAKE_SPECIALIST_OVERRIDE

# I20 — DAEMON_INTAKE_DISABLED=1 canary exercises mark-processed without tokens.
I_REC4="$I_STORE/records/intake-request.intake-l4-canary.json"
jq -cn '{schema_version:1,id:"intake-l4-canary",idea_text:"canary overview",project_ref:"alpha",preset:"overview-request",processed:false,submitted_at:"2026-06-06T08:07:00Z"}' > "$I_REC4"
export DAEMON_INTAKE_DISABLED=1
: > "$I3_LOGS"
daemon_intake_dispatch_one "$(cat "$I_REC4")"
logs="$(cat "$I3_LOGS")"
rec_i4="$(cat "$I_REC4")"
has "$logs" "DAEMON_INTAKE_DISABLED=1"                              "I20: overview canary branch fires"
eq "$(printf '%s' "$rec_i4" | jq -r '.processed')"                 "true"    "I21: overview canary marks record processed"
eq "$(printf '%s' "$rec_i4" | jq -r '.overview_outcome')"          "canary"  "I22: overview canary outcome tag"
eq "$(printf '%s' "$rec_i4" | jq -r '.enricher_bd_id // "ABSENT"')" "ABSENT" "I23: overview canary creates NO bead"
unset DAEMON_INTAKE_DISABLED
rm -rf "$WI" 2>/dev/null || true

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
