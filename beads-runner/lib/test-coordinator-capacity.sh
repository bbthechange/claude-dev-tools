#!/bin/bash
# beads-runner/lib/test-coordinator-capacity.sh — focused unit test for the
# §6.3 / §6.2 coordinator-side COARSE capacity aggregation (T4.4, d7x).
#
# T4.4's OWN test surface. Deliberately NOT a member of the T1 conformance
# suite (beads-runner/conformance/, owned by T1a/T1b) and it does NOT touch
# T4.1's test-coordinator.sh (claude-tools-ick) nor T4.5's
# test-coordinator-forensic.sh — anti-drift: each tier its own focused test.
# It exercises ONLY the §6.3/§6.2 surface on coordinator.sh.
#
# Asserts the EXIT CRITERIA T4.4 owns against INTERFACE.md v1 §6.3/§6.2:
#   1. ask-capacity(cost_class) returns ok|over from AGGREGATED Local-Agent
#      coarse reports: `standard` over iff aggregated 5h-OR-7d hard-ceiling
#      verdict is over; `low_priority` ADDITIONALLY over past the day-N
#      spare-cycles line — proved against reports seeded VERBATIM by T3's
#      la_report_capacity (behavioural anti-drift: the Coordinator consumes
#      T3's §1.1 upward shape with NO adaptation; a divergent shape would be
#      rejected at ingest and fail this test ⇒ the §11 BLOCKING escalation).
#   2. USAGE_THRESHOLD=0 disables the ceiling ⇒ capacity always ok.
#   3. Coordinator-unreachable ⇒ capacity FAILS OPEN (proceed) — the AD2.2
#      capacity half of the §6.2 split posture (mirror of the LEASE half's
#      la_lease_fallback_allows, the OPPOSITE — degraded-closed — posture).
#   4. Anti-drift: a capacity report is a §1.1 UP report, NOT a §4 record
#      type; it lives in a SEPARATE machine-scratch `capacity/` namespace,
#      never round-trips the §4 store, is structurally absent from the §4.5
#      projection (poll); the four §2 capabilities stay EXACTLY four
#      (co_capabilities untouched); §0.3 reject-unknown-higher + the §6.3
#      closed enums are enforced at ingest; §9.1 stamps the resolved
#      principal; this tier NEVER measures (no Keychain/usage API/numbers).
#
# BC-34 x4 GREEN (task EXIT crit 4) is the conformance suite's job, NOT this
# unit test's: this change touches ONLY coordinator.sh (+ this new file);
# local-agent.sh / run-beads-tasks.sh / every conformance assertion are
# UNTOUCHED, so bc-34 x4 cannot regress. The suite is run as the quality gate.
#
# Self-contained: its own CO_STORE under mktemp; its own env vocabulary,
# sharing NO state with the T1 conformance harness or the sibling T4 tests.
set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/coordinator.sh"
LA_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/local-agent.sh"
[[ -f "$LIB" ]]    || { echo "FATAL: coordinator.sh not found at $LIB"; exit 2; }
[[ -f "$LA_LIB" ]] || { echo "FATAL: local-agent.sh not found at $LA_LIB"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
ck()  { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }

# In-process predicates (no `bash -c` quoting hazards: captured values are
# compared in the current shell, where they expand normally).
has()       { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }   # $2 ⊇ $1
hasnt()     { case "$2" in *"$1"*) return 1;; *) return 0;; esac; }
eq()        { [[ "$1" == "$2" ]]; }
nz()        { [[ -n "$1" ]]; }
zz()        { [[ -z "$1" ]]; }
rejected()  { ! co_request "$@" >/dev/null 2>&1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CO_STORE="$WORK/store"          # hosted store realised in scratch (never the repo)
unset CO_EXPECTED_TOKEN PRINCIPAL_V1 USAGE_THRESHOLD 2>/dev/null || true

# shellcheck source=/dev/null
source "$LIB"

GOOD="bearer-runner-secret-xyz"        # a present, valid v1 bearer

# ── seed §1.1 capacity reports VERBATIM via the real T3 la_report_capacity ────
# The strongest anti-drift proof: the Coordinator ingests the EXACT bytes the
# Local Agent emits. t3_line sources local-agent.sh in a sub-shell with a
# scratch outbox, calls la_report_capacity <cc> <vd>, and echoes the last
# appended §1.1 line. (Same-shell `source` of both libs would collide on the
# shared §0.5 lookups / runner-id helpers — the sub-shell keeps them apart and
# is exactly how the real reconnect drain would relay the line up.)
LA_OUT="$WORK/la-logs"
t3_line() {  # <runner_id> <cost_class> <verdict>  → the verbatim §1.1 line
  local rid="$1" cc="$2" vd="$3"
  ( rm -rf "$LA_OUT"; mkdir -p "$LA_OUT"
    export LOG_DIR="$LA_OUT" RUNNER_ID="$rid" PRINCIPAL_V1="brian"
    # shellcheck source=/dev/null
    source "$LA_LIB"
    la_report_capacity "$cc" "$vd" )
  tail -n1 "$LA_OUT/coordinator-outbox.jsonl" 2>/dev/null
}
# pin only the wall-clock of an otherwise-verbatim T3 line (latest-wins tests)
at_pin() { jq -c --arg t "$2" '.observed_at=$t' <<<"$1" 2>/dev/null; }
fresh_store() { rm -rf "$CO_STORE/capacity" 2>/dev/null || true; }

echo "── EXIT-1: ask-capacity aggregates VERBATIM T3 §1.1 coarse reports ──"
# The verbatim-binding proof: a real T3 line ingests with NO adaptation, and
# is stored as the T3 shape with ONLY §9.1 principal (re)stamped.
L_A_over="$(t3_line runnerA standard over)"
ck "T3 la_report_capacity produced a §1.1 line"      nz "$L_A_over"
ck "the line IS the §1.1 capacity shape (report==capacity)" \
   eq "$(jq -r '.report' <<<"$L_A_over" 2>/dev/null)" "capacity"
co_request "$GOOD" report-capacity "$L_A_over" >/dev/null 2>&1
STORED="$CO_STORE/capacity/standard/runnerA.json"
ck "ingest stored the report in the capacity/ namespace"  test -f "$STORED"
ck "§9.1 principal stamped on the ingested report"   eq "$(jq -r '.principal' "$STORED" 2>/dev/null)" "brian"
ck "ingested report keeps T3's verbatim fields (runner_id)" \
   eq "$(jq -r '.runner_id' "$STORED" 2>/dev/null)" "runnerA"
ck "ingested report keeps T3's verbatim fields (verdict)" \
   eq "$(jq -r '.verdict' "$STORED" 2>/dev/null)" "over"
# Only `principal` differs between the raw T3 line and the stored record —
# every other field is byte-faithful (no shape adaptation == no drift).
DIFFK="$(jq -rn --argjson a "$(jq -c 'del(.principal)' <<<"$L_A_over")" \
                 --argjson b "$(jq -c 'del(.principal)' "$STORED")" \
        '($a==$b)' 2>/dev/null)"
ck "stored ≡ T3 line modulo the §9.1 principal stamp"  eq "$DIFFK" "true"

# standard: gated ONLY by the hard ceiling — any aggregated `over` ⇒ over.
v="$(co_request "$GOOD" ask-capacity standard 2>/dev/null)"; rc=$?
ck "1 runner standard=over ⇒ ask-capacity standard = over" eq "$v" "over"
ck "ask-capacity standard rc=1 on over (proceed/halt convention)" test "$rc" -eq 1

# recovered runner re-reports ok with a NEWER observed_at ⇒ latest-wins ⇒ ok.
co_request "$GOOD" report-capacity "$(at_pin "$(t3_line runnerA standard ok)" 2999-01-01T00:00:00Z)" >/dev/null 2>&1
v="$(co_request "$GOOD" ask-capacity standard 2>/dev/null)"; rc=$?
ck "recovered runner (newer ok) supersedes its earlier over" eq "$v" "ok"
ck "ask-capacity standard rc=0 on ok"                test "$rc" -eq 0
# an OLDER straggler `over` must NOT clobber the newer stored `ok`.
co_request "$GOOD" report-capacity "$(at_pin "$(t3_line runnerA standard over)" 2000-01-01T00:00:00Z)" >/dev/null 2>&1
ck "older straggler over does NOT overwrite newer ok"  eq "$(co_request "$GOOD" ask-capacity standard 2>/dev/null)" "ok"

# multi-runner aggregation: ANY runner over ⇒ over; all ok ⇒ ok.
fresh_store
co_request "$GOOD" report-capacity "$(t3_line hostA standard ok)"   >/dev/null 2>&1
co_request "$GOOD" report-capacity "$(t3_line hostB standard ok)"   >/dev/null 2>&1
ck "all runners standard=ok ⇒ aggregated ok"          eq "$(co_request "$GOOD" ask-capacity standard 2>/dev/null)" "ok"
co_request "$GOOD" report-capacity "$(t3_line hostB standard over)" >/dev/null 2>&1
ck "ANY runner standard=over ⇒ aggregated over"       eq "$(co_request "$GOOD" ask-capacity standard 2>/dev/null)" "over"

# no reports at all (gate enabled) ⇒ ok (the real guard is the LA hard ceiling,
# which WOULD have reported over — AD2.3 honest rationale).
fresh_store
ck "no reports + gate enabled ⇒ standard ok"          eq "$(co_request "$GOOD" ask-capacity standard 2>/dev/null)" "ok"
ck "no reports + gate enabled ⇒ low_priority ok"      eq "$(co_request "$GOOD" ask-capacity low_priority 2>/dev/null)" "ok"

echo "── EXIT-1: low_priority ADDITIONALLY gated by the spare-cycles line ──"
# The LA already encoded the day-N ≤ N×SPARE_RAMP_PER_DAY soft line into the
# coarse low_priority verdict; under the hard ceiling, `standard` ignores it.
fresh_store
co_request "$GOOD" report-capacity "$(t3_line spareR standard ok)"        >/dev/null 2>&1
co_request "$GOOD" report-capacity "$(t3_line spareR low_priority over)"  >/dev/null 2>&1
ck "low_priority over (spare line) ⇒ ask low_priority = over" eq "$(co_request "$GOOD" ask-capacity low_priority 2>/dev/null)" "over"
ck "standard IGNORES the spare ramp (still ok)"               eq "$(co_request "$GOOD" ask-capacity standard 2>/dev/null)" "ok"
# never starves the weekly cap: a hit hard ceiling on standard ⇒ low_priority
# is certainly over even with NO low_priority report (backfill-only).
fresh_store
co_request "$GOOD" report-capacity "$(t3_line capR standard over)" >/dev/null 2>&1
ck "standard hard-ceiling over ⇒ low_priority over (no LP report)" eq "$(co_request "$GOOD" ask-capacity low_priority 2>/dev/null)" "over"
# low_priority is ok ONLY when BOTH the hard ceiling is clear AND it is under
# the spare line (both coarse verdicts ok).
fresh_store
co_request "$GOOD" report-capacity "$(t3_line lpR standard ok)"       >/dev/null 2>&1
co_request "$GOOD" report-capacity "$(t3_line lpR low_priority ok)"   >/dev/null 2>&1
ck "ceiling clear + under spare line ⇒ low_priority ok"  eq "$(co_request "$GOOD" ask-capacity low_priority 2>/dev/null)" "ok"

echo "── EXIT-2: USAGE_THRESHOLD=0 disables the ceiling ⇒ always ok ──"
fresh_store
co_request "$GOOD" report-capacity "$(t3_line zR standard over)"      >/dev/null 2>&1
co_request "$GOOD" report-capacity "$(t3_line zR low_priority over)"  >/dev/null 2>&1
ck "threshold>0: seeded over ⇒ standard over (control)"  eq "$(co_request "$GOOD" ask-capacity standard 2>/dev/null)" "over"
v="$(USAGE_THRESHOLD=0 co_request "$GOOD" ask-capacity standard 2>/dev/null)"; rc=$?
ck "USAGE_THRESHOLD=0 ⇒ standard ok despite seeded over"  eq "$v" "ok"
ck "USAGE_THRESHOLD=0 ⇒ standard rc=0 (proceed)"          test "$rc" -eq 0
lp_disabled_ok() ( [[ "$(USAGE_THRESHOLD=0 co_request "$GOOD" ask-capacity low_priority 2>/dev/null)" == ok ]] )
ck "USAGE_THRESHOLD=0 ⇒ low_priority ok despite seeded over"  lp_disabled_ok

echo "── EXIT-3: §6.2/AD2.2 — Coordinator-unreachable ⇒ capacity FAILS OPEN ──"
fresh_store
co_request "$GOOD" report-capacity "$(t3_line uR standard over)" >/dev/null 2>&1
# reachable: the gate is consulted (seeded over ⇒ over, rc 1).
v="$(co_ask_capacity "$GOOD" standard reachable 2>/dev/null)"; rc=$?
ck "reachable ⇒ aggregation consulted (over)"        eq "$v" "over"
ck "reachable over ⇒ rc 1"                           test "$rc" -eq 1
# unreachable: FAIL OPEN — proceed regardless of the (un-consultable) verdict.
v="$(co_ask_capacity "$GOOD" standard unreachable 2>/dev/null)"; rc=$?
ck "unreachable ⇒ FAIL OPEN: verdict ok (proceed)"   eq "$v" "ok"
ck "unreachable ⇒ rc 0 (proceed)"                    test "$rc" -eq 0
# the posture IS 'proceed' — no Coordinator exists to auth against; even an
# empty bearer proceeds (a one-task overshoot is noise; BC-34 intent is held
# AT THE LOCAL AGENT, T3).
v="$(co_ask_capacity "" standard unreachable 2>/dev/null)"; rc=$?
ck "unreachable + no bearer ⇒ verdict ok (proceed)"  eq "$v" "ok"
ck "unreachable + no bearer ⇒ rc 0 (proceed)"        test "$rc" -eq 0
ck "unreachable low_priority ⇒ proceed too"          eq "$(co_ask_capacity "$GOOD" low_priority unreachable 2>/dev/null)" "ok"
# default reach arg is 'reachable' (a runner that does NOT pass the flag asks).
ck "default reach=reachable (gate consulted ⇒ over)" eq "$(co_ask_capacity "$GOOD" standard 2>/dev/null)" "over"

echo "── EXIT-4: anti-drift — §1.1 report is NOT §4; never in §4.5; §0.3 enforced ──"
cdir="$(co__capacity_dir)"
ck "capacity store dir resolves UNDER machine-scratch CO_STORE (not the repo)" \
   eq "$cdir" "$CO_STORE/capacity"
sv="$(co__schema_version capacity 2>/dev/null || true)"
ck "'capacity' is NOT a §4 record type (absent from co__schema_version)"  zz "$sv"
ck "a capacity report is NOT reachable via the §4 get path"   rejected "$GOOD" get capacity standard
ck "a capacity report cannot be put via the §4 store path"    rejected "$GOOD" put capacity x '{"schema_version":1}'
# §0.3 / §6.3 closed-enum enforcement at ingest (mirrors the §4 store
# discipline; binds the §1.1 report to schema_version 1 VERBATIM).
ck "schema_version 2 capacity report ⇒ rejected (§0.3, never best-effort)" \
   rejected "$GOOD" report-capacity '{"report":"capacity","schema_version":2,"runner_id":"r","cost_class":"standard","verdict":"over"}'
ck "string schema_version \"1\" ⇒ rejected (§1.1 int)" \
   rejected "$GOOD" report-capacity '{"report":"capacity","schema_version":"1","runner_id":"r","cost_class":"standard","verdict":"over"}'
ck "report!=\"capacity\" ⇒ rejected (not a §1.1 capacity report)" \
   rejected "$GOOD" report-capacity '{"report":"terminal-reason","schema_version":1,"runner_id":"r"}'
ck "unknown cost_class ⇒ rejected (§6.3 closed enum)" \
   rejected "$GOOD" report-capacity '{"report":"capacity","schema_version":1,"runner_id":"r","cost_class":"bulk","verdict":"ok"}'
ck "unknown verdict ⇒ rejected (§6.3 closed enum)" \
   rejected "$GOOD" report-capacity '{"report":"capacity","schema_version":1,"runner_id":"r","cost_class":"standard","verdict":"maybe"}'
ck "unsafe runner_id ('..') ⇒ rejected at the door" \
   rejected "$GOOD" report-capacity '{"report":"capacity","schema_version":1,"runner_id":"../../etc","cost_class":"standard","verdict":"ok"}'
ck "ask-capacity unknown cost_class ⇒ rejected (closed enum)"  rejected "$GOOD" ask-capacity bulk
# §9.1 — no/invalid token ⇒ rejected BEFORE any ingest write (one chokepoint).
fresh_store
ck "no-token report-capacity ⇒ rejected (authed channel only)" \
   rejected "" report-capacity "$(t3_line nR standard over)"
ck "no-token report-capacity wrote NOTHING"          zz "$(ls -A "$CO_STORE/capacity" 2>/dev/null)"
ck "no-token ask-capacity ⇒ rejected"                rejected "" ask-capacity standard
invalid_tok_rejected() ( export CO_EXPECTED_TOKEN=expected; ! co_request wrong report-capacity '{}' >/dev/null 2>&1 )
ck "invalid-token report-capacity ⇒ rejected"        invalid_tok_rejected
# §9.1 — a foreign principal literal in the report is OVERWRITTEN by the
# resolved principal (never trust the use-site literal — C7).
co_request "$GOOD" report-capacity \
  '{"report":"capacity","schema_version":1,"principal":"someone-else","runner_id":"pR","cost_class":"standard","verdict":"ok","observed_at":"2026-05-16T10:00:00Z"}' >/dev/null 2>&1
ck "ingest overwrites a foreign principal with PRINCIPAL_V1" \
   eq "$(jq -r '.principal' "$CO_STORE/capacity/standard/pR.json" 2>/dev/null)" "brian"

# the capacity report is structurally absent from the §2.4 projection/poll and
# the §4 records dir (a SEPARATE namespace, mirroring forensic/ — T4.3/T6a).
# A distinct canary runner_id (NOT the project_ref) so the check is specific.
fresh_store
co_request "$GOOD" report-capacity "$(t3_line rCapCanary standard over)" >/dev/null 2>&1
co_request "$GOOD" set-desired projP running "agent-1" >/dev/null 2>&1
poll="$(co_request "$GOOD" poll projP 2>/dev/null)"
ck "§2.4 poll output carries NO capacity report marker"       hasnt '"report":"capacity"' "$poll"
ck "§2.4 poll output carries NO capacity runner_id canary"    hasnt "rCapCanary" "$poll"
ck "§2.4 poll output carries no capacity 'verdict' field"     hasnt '"verdict"' "$poll"
ck "the §4 records/ dir holds NO capacity report (separate namespace)" \
   bash -c '! grep -rqF "$1" "$2" 2>/dev/null' _ '"report":"capacity"' "$CO_STORE/records"
# the four §2 capabilities are EXACTLY four and never mention capacity
# (capacity is a §6.3 surface through the §2.3 door, NOT a fifth capability).
caps="$(co_capabilities 2>/dev/null)"
ncaps="$(grep -c '§2' <<<"$caps" || true)"
ck "co_capabilities (T4.1) still EXACTLY four §2 lines (untouched)"  eq "$ncaps" "4"
ck "co_capabilities does NOT advertise capacity as a §2 capability"  hasnt "capacity" "$caps"
# never measures: this tier defines NO usage-cache / spare-ramp LOOKUP
# FUNCTION and touches NO Keychain/usage API (the MUST-NOT-TOUCH boundary).
# Grep the function-DEFINITION shape, not the bare token — a bare substring
# grep would be (correctly) defeated by this file's own anti-drift PROSE that
# names these constants to explain why they are deliberately NOT defined
# (exactly the lesson test-coordinator-forensic.sh calls out: prove the
# boundary by structure, not by a grep the correct comment defeats).
ck "coordinator.sh defines NO co__USAGE_CACHE_SECONDS lookup (never measures)" \
   bash -c '! grep -Eq "$1" "$2"' _ 'co__USAGE_CACHE_SECONDS *\(\)' "$LIB"
ck "coordinator.sh defines NO co__SPARE_RAMP_PER_DAY lookup (never measures)" \
   bash -c '! grep -Eq "$1" "$2"' _ 'co__SPARE_RAMP_PER_DAY *\(\)' "$LIB"
ck "coordinator.sh never reads a Keychain / usage API (§1.1)" \
   bash -c '! grep -Eq "$1" "$2"' _ 'find-generic-password|api\.anthropic\.com' "$LIB"

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " test-coordinator-capacity (T4.4, claude-tools-d7x):  PASS=$PASS  FAIL=$FAIL"
echo "══════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
