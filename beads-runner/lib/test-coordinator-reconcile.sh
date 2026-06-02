#!/bin/bash
# beads-runner/lib/test-coordinator-reconcile.sh — focused unit test for the
# §4.2 RunnerState reconcile + S-1 liveness + the §4.5 read-only work-snapshot
# projection store (T4.3, claude-tools-l9o).
#
# T4.3's OWN test surface. Deliberately NOT a member of the T1 conformance
# suite (beads-runner/conformance/, owned by T1a/T1b) and it does NOT touch
# T4.1's test-coordinator.sh, T4.4's test-coordinator-capacity.sh, nor T4.5's
# test-coordinator-forensic.sh — anti-drift: each tier its own focused test.
# It exercises ONLY the §4.2/§2.4-semantics/§4.5 surface on coordinator.sh.
#
# Asserts the EXIT CRITERIA T4.3 owns against INTERFACE.md v1 §4.2/§2.4/§4.5:
#   1. reconcile returns the correct RunnerState.desired across a SIMULATED
#      SLEEP/RECONNECT: desired set while the runner is 'asleep'; its next
#      reconnect/reconcile returns the CURRENT desired + that runner's lease
#      state (reconciliation, NOT a durable command queue).
#   2. liveness is DERIVED correctly: last_heartbeat_at older than STALE_AFTER
#      ⇒ 'stale', within ⇒ 'live'; desired≠actual is surfaced HONESTLY, not
#      masked; the datum is derived at READ time and is NEVER stored (C6/S-1).
#   3. the work-snapshot projection reflects desired+actual+liveness AND
#      enforces the NO-reader-write-path invariant (read-only).
#   4. (Full T1 conformance stays PASS/zero-FAIL — that is the conformance
#      SUITE's job, run as the quality gate; this change touches ONLY
#      coordinator.sh + this new file, so the suite cannot regress.)
#
# Anti-drift proven by STRUCTURE (a source grep is defeated by this file's own
# correct anti-drift prose, exactly the lesson the sibling T4 tests call out):
#   • consumes T3's §1.1 UPWARD heartbeat contract VERBATIM (the same outbox
#     envelope convention la_report_capacity / la_report_terminal_reason emit);
#     §0.3 reject-unknown-higher + §9.1 principal-stamp + the §4.2 closed
#     `actual` enum enforced at ingest, exactly as the §4 store does;
#   • the COORDINATOR-OWNED desired/last_desired_actor are PRESERVED by a
#     heartbeat (§1.1: the runner never originates desired);
#   • T4.1's co__poll stays the pure liveness-free TRANSPORT (its own T4.1
#     test asserts this) — reconcile is a SEPARATE semantics layer;
#     co_capabilities stays EXACTLY four §2 lines (T4.1 untouched);
#   • the capacity strip is SURFACED from T4.4's aggregated verdict (not
#     measured here); the §10 forensic stream is NEVER in the projection;
#   • the WAITING-ON-YOU lane reads Dossier item-state COUNTS only (T5 owns
#     content); §9.1 — no/invalid token ⇒ rejected BEFORE any write.
#
# Self-contained: its own CO_STORE under mktemp; its own env vocabulary,
# sharing NO state with the T1 conformance harness or the sibling T4 tests.
set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/coordinator.sh"
[[ -f "$LIB" ]] || { echo "FATAL: coordinator.sh not found at $LIB"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
ck()  { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }

# In-process predicates (no `bash -c` quoting hazards: captured values are
# compared in the current shell, where they expand normally).
has()      { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }   # $2 ⊇ $1
hasnt()    { case "$2" in *"$1"*) return 1;; *) return 0;; esac; }
eq()       { [[ "$1" == "$2" ]]; }
nz()       { [[ -n "$1" ]]; }
zz()       { [[ -z "$1" ]]; }
ge1()      { [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]]; }
rejected() { ! co_request "$@" >/dev/null 2>&1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CO_STORE="$WORK/store"          # hosted store realised in scratch (never the repo)
unset CO_EXPECTED_TOKEN PRINCIPAL_V1 STALE_AFTER USAGE_THRESHOLD 2>/dev/null || true

# shellcheck source=/dev/null
source "$LIB"

GOOD="bearer-runner-secret-xyz"        # a present, valid v1 bearer

# An RFC-3339 UTC timestamp <n> seconds in the past (the S-1 datum is wire
# time; §0.4 — all timestamps are RFC-3339 UTC `…Z`).
ago() {
  local n="$1" e; e=$(( $(date -u +%s) - n ))
  date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}
# A §1.1 heartbeat line in T3's VERBATIM coordinator-outbox envelope
# convention (the SAME {report,schema_version,principal,runner_id,…,
# observed_at} shape la_report_capacity / la_report_terminal_reason emit; T3's
# debrief documents the outbox as the §1.1 realisation seam T4 drains on
# reconnect). observed_at IS the last_heartbeat_at S-1 datum.
hb_line() {  # <runner_id> <project_ref> <actual> <current_task_ref> <observed_at>
  jq -cn --argjson sv 1 --arg pr "literal-should-be-overwritten" \
         --arg rid "$1" --arg prj "$2" --arg act "$3" \
         --arg cur "$4" --arg at "$5" \
     '{report:"heartbeat",schema_version:$sv,principal:$pr,runner_id:$rid,
       project_ref:$prj,actual:$act,current_task_ref:$cur,observed_at:$at}'
}

echo "── EXIT-1: reconcile across a SIMULATED SLEEP/RECONNECT (§2.4 semantics) ──"
# The runner is 'asleep' (no poll). The Coordinator owns desired-state and
# sets desired=paused while it sleeps; T4.2's arbitration has written a Lease
# (here just the stored record — this tier only SURFACES it, no arbitration).
co_request "$GOOD" set-desired projA paused "ui:brian-laptop" >/dev/null 2>&1
co_request "$GOOD" put lease projA \
  '{"schema_version":1,"task_ref":"projA","owner":"hostA","generation":4}' >/dev/null 2>&1
# It WAKES and reconnects: §2.4 returns the CURRENT desired + its lease state.
rc1="$(co_request "$GOOD" reconcile projA projA 2>/dev/null)"
ck "reconnect ⇒ desired delivered (paused, set while asleep)" eq "$(jq -r '.desired' <<<"$rc1")" "paused"
ck "reconnect ⇒ that runner's lease state surfaced"           eq "$(jq -r '.lease.owner' <<<"$rc1")" "hostA"
ck "reconcile stamps the §9.1 resolved principal"             eq "$(jq -r '.principal' <<<"$rc1")" "brian"
ck "reconcile carries the project_ref"                        eq "$(jq -r '.project_ref' <<<"$rc1")" "projA"
# Reconciliation, NOT a durable command queue: a SECOND desired change while
# still asleep is not queued — the next reconnect reflects the LATEST desired,
# never a replayed sequence of commands.
co_request "$GOOD" set-desired projA stopped "ui:brian-laptop" >/dev/null 2>&1
rc2="$(co_request "$GOOD" reconcile projA projA 2>/dev/null)"
ck "next reconnect ⇒ the CURRENT desired (stopped), not a queue" eq "$(jq -r '.desired' <<<"$rc2")" "stopped"
# A reconcile with no lease arg still returns desired (lease simply null).
rc3="$(co_request "$GOOD" reconcile projA 2>/dev/null)"
ck "reconcile w/o lease arg ⇒ desired still delivered"        eq "$(jq -r '.desired' <<<"$rc3")" "stopped"
ck "reconcile w/o lease arg ⇒ lease is null (none surfaced)"  eq "$(jq -r '.lease' <<<"$rc3")" "null"

echo "── EXIT-2: §4.2 liveness DERIVED at read time (S-1/C6); desired≠actual honest ──"
# §1.1 heartbeat ingest in T3's VERBATIM outbox convention. observed_at WITHIN
# STALE_AFTER ⇒ liveness derives 'live'.
co_request "$GOOD" heartbeat "$(hb_line hostA projA running ct-1 "$(ago 30)")" >/dev/null 2>&1
rL="$(co_request "$GOOD" reconcile projA projA 2>/dev/null)"
ck "heartbeat within STALE_AFTER ⇒ liveness = live"           eq "$(jq -r '.liveness' <<<"$rL")" "live"
ck "actual surfaced from the heartbeat (running)"             eq "$(jq -r '.actual' <<<"$rL")" "running"
# desired=stopped (Coordinator-owned, unchanged by the heartbeat) ≠
# actual=running ⇒ the mismatch is surfaced HONESTLY, never masked.
ck "desired≠actual surfaced honestly (mismatch flag true)"    eq "$(jq -r '.desired_actual_mismatch' <<<"$rL")" "true"
ck "actual NOT masked to desired (still 'running')"           eq "$(jq -r '.actual' <<<"$rL")" "running"
ck "desired NOT masked to actual (still 'stopped')"           eq "$(jq -r '.desired' <<<"$rL")" "stopped"
# A heartbeat OLDER than STALE_AFTER ⇒ derives 'stale' — honestly distinct
# from actual:running (the Board renders 'stale (last seen…)', T6a).
co_request "$GOOD" heartbeat "$(hb_line hostA projA running ct-1 "$(ago 99999)")" >/dev/null 2>&1
rS="$(co_request "$GOOD" reconcile projA projA 2>/dev/null)"
ck "heartbeat older than STALE_AFTER ⇒ liveness = stale"      eq "$(jq -r '.liveness' <<<"$rS")" "stale"
ck "stale liveness does NOT mask actual (still 'running')"    eq "$(jq -r '.actual' <<<"$rS")" "running"
# The STALE_AFTER boundary is the §0.5 constant (env-overridable; literal
# default == frozen 180 s). With STALE_AFTER=10, a 30-s-old beat is stale.
vfar() ( STALE_AFTER=10 co_request "$GOOD" reconcile projA projA 2>/dev/null | jq -r '.liveness' )
co_request "$GOOD" heartbeat "$(hb_line hostA projA idle ct-1 "$(ago 30)")" >/dev/null 2>&1
ck "STALE_AFTER override moves the boundary (30s>10 ⇒ stale)" eq "$(vfar)" "stale"
ck "same beat with default 180s boundary ⇒ live"              eq "$(co_request "$GOOD" reconcile projA projA 2>/dev/null | jq -r '.liveness')" "live"
# DERIVED, never STORED (C6: a stored 'live' lies the instant the beat stops).
storedRS="$(co_request "$GOOD" get runner_state projA 2>/dev/null)"
ck "stored RunnerState carries last_heartbeat_at (the S-1 datum)" nz "$(jq -r '.last_heartbeat_at' <<<"$storedRS")"
ck "stored RunnerState has NO 'liveness' key (derived at READ)"   eq "$(jq -r 'has("liveness")' <<<"$storedRS")" "false"
# A never-heard-from runner is honestly STALE, not masked as live.
co_request "$GOOD" set-desired projNoHB running "ui:x" >/dev/null 2>&1
ck "no heartbeat ever ⇒ liveness honestly 'stale'"            eq "$(co_request "$GOOD" reconcile projNoHB 2>/dev/null | jq -r '.liveness')" "stale"
# HONEST degradation (S-1/C6): an UNREADABLE local clock ⇒ 'stale', NOT a
# falsely-derived 'live'. Shadow `date` so the clock read fails; a real recent
# heartbeat must STILL derive 'stale' (recency is unestablishable — never lie).
recent_ts="$(ago 5)"
# Shadow ONLY the bare clock read (`date -u +%s`); RFC-3339 PARSE calls still
# work — so this exercises the now-unreadable path, not the unparseable-hb one.
clock_dead_is_stale() (
  date() { case "$*" in "-u +%s") return 1;; *) command date "$@";; esac; }
  [[ "$(co__derive_liveness "$recent_ts")" == "stale" ]]
)
ck "unreadable clock ⇒ liveness honestly 'stale' (no false live)" clock_dead_is_stale
ck "explicit now_epoch arg still honored when clock is dead"      bash -c 'source "$1"; out=$(co__derive_liveness "1970-01-01T00:00:30Z" 100); [[ "$out" == live ]]' _ "$LIB"

echo "── EXIT-3: §4.5 read-only projection reflects desired+actual+liveness ──"
# GAP G2 (claude-tools-uxg2) — the two trailing `done` beads exercise the
# done·verified vs done·code split: d1's probe passed (verified:true); d2 has
# no probe fact (absent → done·code, the strict default — un-probed is NOT
# verified). Twin of cf/test/reconcile.spec.js's BEADS fixture.
BEADS='[{"bead_ref":"claude-tools-99","title":"Impl X","stage":"impl","priority":1,"age":"2h","waiting_on":"review","failure":{"class":"UNKNOWN_FAILURE","retry_state":"1/3","runner_notes":["Runner: retrying"]}},{"bead_ref":"claude-tools-12","title":"Idea Y","stage":"idea","priority":2,"age":"1d"},{"bead_ref":"claude-tools-77","title":"Loose","stage":"weird","priority":3,"age":"5m"},{"bead_ref":"claude-tools-d1","title":"Shipped","stage":"done","priority":1,"age":"3h","verified":true},{"bead_ref":"claude-tools-d2","title":"Landed","stage":"done","priority":2,"age":"4h"}]'
# claude-tools-4xe — type=dossier writes now run the §5.1-core WRITE GATE
# (co__store_put): a minimal conformant body (bound dossier_schema_version +
# []-diagrams) is required; the §4.5 projection still reads only items[] (body
# stays T6b's), so a minimal body keeps these waiting_on_you assertions intact.
co_request "$GOOD" put dossier dOpen \
  '{"schema_version":2,"id":"dOpen","bead_ref":"claude-tools-99","tier":"blocking","body":{"dossier_schema_version":2,"diagrams":[]},"items":[{"id":"i1","state":"open"},{"id":"i2","state":"applied"}]}' >/dev/null 2>&1
co_request "$GOOD" put dossier dResolved \
  '{"schema_version":2,"id":"dResolved","bead_ref":"claude-tools-12","tier":"digest","body":{"dossier_schema_version":2,"diagrams":[]},"items":[{"id":"j1","state":"applied"},{"id":"j2","state":"expired"}]}' >/dev/null 2>&1
SNAP="$(co_request "$GOOD" work-snapshot projA "$BEADS" 2>/dev/null)"
ck "projection declares itself read_only:true"                eq "$(jq -r '.read_only' <<<"$SNAP")" "true"
ck "projection schema_version is 1 (§4.5)"                    eq "$(jq -r '.schema_version' <<<"$SNAP")" "1"
P0="$(jq -c '.projects[0].runner_state' <<<"$SNAP")"
ck "projection RunnerState reflects desired"                  eq "$(jq -r '.desired' <<<"$P0")" "stopped"
ck "projection RunnerState reflects actual"                   eq "$(jq -r '.actual' <<<"$P0")" "idle"
ck "projection RunnerState reflects liveness DERIVED"         eq "$(jq -r '.liveness' <<<"$P0")" "live"
ck "projection surfaces desired≠actual honestly"              eq "$(jq -r '.desired_actual_mismatch' <<<"$P0")" "true"
ck "projection lifecycle column keyed by stage: (impl)"       eq "$(jq -r '.lifecycle_columns.impl[0].bead_ref' <<<"$SNAP")" "claude-tools-99"
ck "projection lifecycle column keyed by stage: (idea)"       eq "$(jq -r '.lifecycle_columns.idea[0].bead_ref' <<<"$SNAP")" "claude-tools-12"
ck "an unknown stage buckets under \"\" (honest, not silently impl)" \
   eq "$(jq -r '.lifecycle_columns[""][0].bead_ref' <<<"$SNAP")" "claude-tools-77"
ck "per-bead failure metadata carried (Flow G tiers 1–2)"     eq "$(jq -r '.lifecycle_columns.impl[0].failure.class' <<<"$SNAP")" "UNKNOWN_FAILURE"
ck "card carries the one thing it waits on (§4.5)"            eq "$(jq -r '.lifecycle_columns.impl[0].waiting_on' <<<"$SNAP")" "review"
# GAP G2 (claude-tools-uxg2) — the per-card `verified` flag (§3 / principle 11),
# byte-parallel with the cf/src/reconcile.js twin. Strict boolean: only literal
# true ⇒ done·verified; absent/false ⇒ done·code.
ck "G2 — done card whose probe passed carries verified:true"  eq "$(jq -r '.lifecycle_columns.done[0].verified' <<<"$SNAP")" "true"
ck "G2 — done card with no probe fact carries verified:false" eq "$(jq -r '.lifecycle_columns.done[1].verified' <<<"$SNAP")" "false"
ck "G2 — verified is a per-card boolean on EVERY card (impl=false)" eq "$(jq -r '.lifecycle_columns.impl[0].verified' <<<"$SNAP")" "false"
# WAITING-ON-YOU = Dossiers (this principal) with ≥1 still-open item — COUNTS
# only; a fully-resolved (all applied/expired) dossier drops off (T5 content).
woyN="$(jq -r '[.waiting_on_you[].dossier_ref]|length' <<<"$SNAP")"
ck "WAITING-ON-YOU lists the dossier with an open item"       eq "$(jq -r '.waiting_on_you[0].dossier_ref' <<<"$SNAP")" "dOpen"
ck "WAITING-ON-YOU open_item_count is the COUNT (1, applied excluded)" eq "$(jq -r '.waiting_on_you[0].open_item_count' <<<"$SNAP")" "1"
ck "fully-resolved dossier is NOT in WAITING-ON-YOU"          eq "$woyN" "1"
# capacity strip SURFACED from T4.4's aggregated coarse verdict (NOT measured).
ck "capacity strip surfaced (verdict from §6.3 aggregation)"  nz "$(jq -r '.projects[0].capacity_strip.verdict' <<<"$SNAP")"
ck "capacity strip names its source as T4.4 §6.3 (surfaced)"  has "T4.4" "$(jq -r '.projects[0].capacity_strip.source' <<<"$SNAP")"

echo "── EXIT-3b: 4g5o — current_task_title field present in projection (graceful) ──"
# claude-tools-4g5o — the projection's runner_state MUST carry a
# current_task_title field for the Board renderer to read. The bash
# coordinator has no workspace_inventory store (that lives in CF), so the
# title is ALWAYS null here — exactly the Case C "no record ⇒ null" the CF
# join also exhibits when the producer hasn't published yet. This proves
# the shape parity without requiring the bash to mirror the CF join.
ck "projection runner_state HAS current_task_title field"     eq "$(jq -r '.projects[0].runner_state|has("current_task_title")' <<<"$SNAP")" "true"
ck "bash projection — current_task_title is null (no store)"  eq "$(jq -r '.projects[0].runner_state.current_task_title' <<<"$SNAP")" "null"

echo "── EXIT-3c: uxvi2 — runner_health{} TWIN + activity{} default (DESIGN I §2/§3) ──"
# runner_health is a TRUE differential twin of cf/src/reconcile.js
# deriveRunnerHealth — derived from the SAME §4.2 RunnerState co__reconcile
# produces (liveness+actual), so both engines compute byte-identical
# {process,heartbeat,last_pickup_at,state}. activity has NO bash store
# (agent_activity is a CF-only transient — the machines[]/queue_health
# precedent), so the bash oracle emits the honest-empty default for SHAPE
# PARITY. projA here is actual=idle + liveness=live (the §4.2 idle the lv9c
# line at the top left), so it reads runner_health.state=idle.
P0RH="$(jq -c '.projects[0].runner_health' <<<"$SNAP")"
ck "runner_health is a named sub-object on projects[] (not a flat key)" \
   eq "$(jq -r '.projects[0]|has("runner_health")' <<<"$SNAP")" "true"
ck "runner_health field-set is EXACTLY {process,heartbeat,last_pickup_at,state} (B.1)" \
   eq "$(jq -r 'keys|join(",")' <<<"$P0RH")" "heartbeat,last_pickup_at,process,state"
ck "runner_health.process alive (actual=idle, not stopped/crashed)" eq "$(jq -r '.process' <<<"$P0RH")" "alive"
ck "runner_health.heartbeat fresh (liveness=live)"                  eq "$(jq -r '.heartbeat' <<<"$P0RH")" "fresh"
ck "runner_health.state idle (fresh, actual!=running) — starved/cooldown read idle, never stuck" \
   eq "$(jq -r '.state' <<<"$P0RH")" "idle"
ck "runner_health.last_pickup_at null (no producer yet — honest)"   eq "$(jq -r '.last_pickup_at' <<<"$P0RH")" "null"
# activity — the honest-empty default (SHAPE PARITY; CF fills the real lanes).
ck "activity is a named sub-object on projects[]"             eq "$(jq -r '.projects[0]|has("activity")' <<<"$SNAP")" "true"
ck "activity.writer is null (bash has no agent_activity store)" eq "$(jq -r '.projects[0].activity.writer' <<<"$SNAP")" "null"
ck "activity.auxiliary is [] (uniform, never absent)"         eq "$(jq -rc '.projects[0].activity.auxiliary' <<<"$SNAP")" "[]"
# The other three runner_health states (true twin): seed new project_refs into
# this store and re-snapshot all-projects. running+fresh⇒working;
# running+stale⇒wedged (process still alive, §3); crashed⇒process dead,
# state idle (never "stuck" — process:dead carries the truth).
co_request "$GOOD" heartbeat "$(hb_line hW projRhWork running tW "$(ago 5)")"      >/dev/null 2>&1
co_request "$GOOD" heartbeat "$(hb_line hG projRhWedge running tG "$(ago 99999)")" >/dev/null 2>&1
co_request "$GOOD" heartbeat "$(hb_line hD projRhDead crashed tD "$(ago 5)")"      >/dev/null 2>&1
SNAPrh="$(co_request "$GOOD" work-snapshot "" "$BEADS" 2>/dev/null)"
rh_state() { jq -r --arg p "$1" '.projects[]|select(.project_ref==$p)|.runner_health.state' <<<"$SNAPrh"; }
rh_proc()  { jq -r --arg p "$1" '.projects[]|select(.project_ref==$p)|.runner_health.process' <<<"$SNAPrh"; }
ck "twin: running + fresh heartbeat ⇒ working"                eq "$(rh_state projRhWork)" "working"
ck "twin: running + STALE heartbeat ⇒ wedged (the krxv/td0y wedge)" eq "$(rh_state projRhWedge)" "wedged"
ck "twin: wedged keeps process 'alive' (§3 wedged is process-alive-but-stale)" eq "$(rh_proc projRhWedge)" "alive"
ck "twin: crashed ⇒ process 'dead'"                           eq "$(rh_proc projRhDead)" "dead"
ck "twin: crashed ⇒ state 'idle', NOT wedged (process:dead carries the truth)" eq "$(rh_state projRhDead)" "idle"

echo "── EXIT-3: NO write path from any reader (read-only invariant) ──"
sig() { ( cd "$CO_STORE/records" 2>/dev/null && ls -1 2>/dev/null | sort | shasum ); }
before="$(sig)"
# Repeated reads, all-projects mode, and adversarial (non-array) work-truth —
# none of these may mutate the store.
co_request "$GOOD" work-snapshot projA "$BEADS"        >/dev/null 2>&1
co_request "$GOOD" work-snapshot ""     "$BEADS"       >/dev/null 2>&1
co_request "$GOOD" work-snapshot projA '{"evil":1}'    >/dev/null 2>&1
co_request "$GOOD" work-snapshot projA 'not even json' >/dev/null 2>&1
co_request "$GOOD" reconcile    projA                  >/dev/null 2>&1
after="$(sig)"
ck "work-snapshot/reconcile reads mutate ZERO records"        eq "$before" "$after"
ck "no work_snapshot record self-created by the reader"       bash -c '! test -e "$1"' _ "$CO_STORE/records/work_snapshot.projA.json"
# Structural: the projection producer invokes NO write primitive (the
# invariant holds BY CONSTRUCTION, §4.5). Extract the function body and prove
# it calls none of co__store_put / co__store_write / co__*_write /
# co__set_desired / co__heartbeat.
body="$(sed -n '/^co__work_snapshot() {/,/^}/p' "$LIB")"
ck "co__work_snapshot body found"                             nz "$body"
ck "co__work_snapshot calls NO co__store_put (read-only)"     hasnt "co__store_put" "$body"
ck "co__work_snapshot calls NO co__store_write (read-only)"   hasnt "co__store_write" "$body"
ck "co__work_snapshot calls NO co__set_desired (read-only)"   hasnt "co__set_desired" "$body"
ck "co__work_snapshot calls NO co__heartbeat (read-only)"     hasnt "co__heartbeat" "$body"
ck "co__work_snapshot calls NO *_write primitive (read-only)" bash -c '! grep -Eq "co__[a-z_]*_write" <<<"$1"' _ "$body"

echo "── anti-drift: §1.1 heartbeat consumed VERBATIM; §0.3/§9.1/§4.2 enforced ──"
fresh="$WORK/store2"; ( export CO_STORE="$fresh"
  L="$(hb_line hostZ projZ running ctZ "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
  co_request "$GOOD" heartbeat "$L" >/dev/null 2>&1 )
storedZ="$(CO_STORE="$fresh" co_request "$GOOD" get runner_state projZ 2>/dev/null)"
ck "verbatim §1.1 line ingests with NO shape adaptation"      eq "$(jq -r '.actual' <<<"$storedZ")" "running"
ck "observed_at consumed VERBATIM as last_heartbeat_at"       nz "$(jq -r '.last_heartbeat_at' <<<"$storedZ")"
ck "current_task_ref consumed verbatim from the §1.1 line"    eq "$(jq -r '.current_task_ref' <<<"$storedZ")" "ctZ"
ck "§9.1 — the report's principal literal is OVERWRITTEN"     eq "$(jq -r '.principal' <<<"$storedZ")" "brian"
# §1.1: the runner never originates desired — a heartbeat MUST NOT clobber the
# COORDINATOR-OWNED desired/last_desired_actor.
co_request "$GOOD" set-desired projKeep paused "ui:owner" >/dev/null 2>&1
co_request "$GOOD" heartbeat "$(hb_line hostK projKeep crashed ctK "$(ago 5)")" >/dev/null 2>&1
keep="$(co_request "$GOOD" get runner_state projKeep 2>/dev/null)"
ck "heartbeat PRESERVES Coordinator-owned desired (paused)"   eq "$(jq -r '.desired' <<<"$keep")" "paused"
ck "heartbeat PRESERVES last_desired_actor (ui:owner)"        eq "$(jq -r '.last_desired_actor' <<<"$keep")" "ui:owner"
ck "heartbeat still records the runner-reported actual"       eq "$(jq -r '.actual' <<<"$keep")" "crashed"
# §0.3 reject-unknown-higher / §4.2 closed enum / store-owner input hygiene.
ck "heartbeat schema_version 2 ⇒ rejected (§0.3, never best-effort)" \
   rejected "$GOOD" heartbeat '{"report":"heartbeat","schema_version":2,"project_ref":"p","actual":"running"}'
ck "heartbeat string schema_version \"1\" ⇒ rejected (§1.1 int)" \
   rejected "$GOOD" heartbeat '{"report":"heartbeat","schema_version":"1","project_ref":"p","actual":"running"}'
ck "report!=\"heartbeat\" ⇒ rejected (not a §1.1 heartbeat)" \
   rejected "$GOOD" heartbeat '{"report":"capacity","schema_version":1,"project_ref":"p","actual":"running"}'
ck "out-of-enum actual ⇒ rejected (§4.2 closed enum)" \
   rejected "$GOOD" heartbeat '{"report":"heartbeat","schema_version":1,"project_ref":"p","actual":"zooming"}'
ck "unsafe project_ref ('..') ⇒ rejected at the door" \
   rejected "$GOOD" heartbeat '{"report":"heartbeat","schema_version":1,"project_ref":"../../etc","actual":"idle"}'
# §9.1 — no/invalid token ⇒ rejected at the ONE chokepoint BEFORE any write.
ck "no-token heartbeat ⇒ rejected (authed channel only)" \
   rejected "" heartbeat "$(hb_line hostN projN running ctN "$(ago 5)")"
ck "no-token reconcile ⇒ rejected"                            rejected "" reconcile projA
ck "no-token work-snapshot ⇒ rejected"                        rejected "" work-snapshot projA "$BEADS"
invalid_tok() ( export CO_EXPECTED_TOKEN=expected; ! co_request wrong heartbeat "$(hb_line h p running c "$(ago 5)")" >/dev/null 2>&1 )
ck "invalid-token heartbeat ⇒ rejected"                       invalid_tok

echo "── claude-tools-lv9c: current_task_ref is AUTHORITATIVE per heartbeat ──"
# Producer (la_report_heartbeat) OMITS current_task_ref on `hb idle`. Coordinator
# must treat any missing/empty current_task_ref as a CLEAR signal — never
# preserve the prior value from `...prev`. Otherwise the Board shows a stale
# "currently running" pointer to a long-closed task.

# Case A — set then clear via hb idle (field OMITTED, the producer's wire shape)
co_request "$GOOD" heartbeat "$(hb_line hostLv9 projLv9A running claude-tools-xyz "$(ago 5)")" >/dev/null 2>&1
lv9A1="$(co_request "$GOOD" get runner_state projLv9A 2>/dev/null)"
ck "lv9c A1 — running heartbeat sets current_task_ref"        eq "$(jq -r '.current_task_ref' <<<"$lv9A1")" "claude-tools-xyz"
# An idle heartbeat that OMITS the field entirely (the producer's la_report_heartbeat
# shape on `hb idle`) must CLEAR the prior value.
idle_no_cur="$(jq -cn --argjson sv 1 --arg pr "literal" --arg rid hostLv9 \
                      --arg prj projLv9A --arg at "$(ago 1)" \
   '{report:"heartbeat",schema_version:$sv,principal:$pr,runner_id:$rid,
     project_ref:$prj,actual:"idle",observed_at:$at}')"
co_request "$GOOD" heartbeat "$idle_no_cur" >/dev/null 2>&1
lv9A2="$(co_request "$GOOD" get runner_state projLv9A 2>/dev/null)"
ck "lv9c A2 — idle heartbeat (field absent) CLEARS current_task_ref" \
   zz "$(jq -r '.current_task_ref // ""' <<<"$lv9A2")"
ck "lv9c A2 — actual flips to idle"                           eq "$(jq -r '.actual' <<<"$lv9A2")" "idle"

# Case B — running TASK_A then running TASK_B overwrites (not stale)
co_request "$GOOD" heartbeat "$(hb_line hostLv9 projLv9B running TASK_A "$(ago 10)")" >/dev/null 2>&1
ck "lv9c B1 — current_task_ref = TASK_A" \
   eq "$(co_request "$GOOD" get runner_state projLv9B 2>/dev/null | jq -r '.current_task_ref')" "TASK_A"
co_request "$GOOD" heartbeat "$(hb_line hostLv9 projLv9B running TASK_B "$(ago 5)")" >/dev/null 2>&1
ck "lv9c B2 — current_task_ref overwrites to TASK_B"          \
   eq "$(co_request "$GOOD" get runner_state projLv9B 2>/dev/null | jq -r '.current_task_ref')" "TASK_B"

# Case C — preserve actual + last_heartbeat_at while clearing current_task_ref
co_request "$GOOD" heartbeat "$(hb_line hostLv9 projLv9C running TASK_A "$(ago 60)")" >/dev/null 2>&1
obs2="$(ago 5)"
idle_C="$(jq -cn --argjson sv 1 --arg pr "literal" --arg rid hostLv9 \
                 --arg prj projLv9C --arg at "$obs2" \
   '{report:"heartbeat",schema_version:$sv,principal:$pr,runner_id:$rid,
     project_ref:$prj,actual:"idle",observed_at:$at}')"
co_request "$GOOD" heartbeat "$idle_C" >/dev/null 2>&1
lv9C="$(co_request "$GOOD" get runner_state projLv9C 2>/dev/null)"
ck "lv9c C — actual reflects new idle"                        eq "$(jq -r '.actual' <<<"$lv9C")" "idle"
ck "lv9c C — last_heartbeat_at reflects new observed_at"      eq "$(jq -r '.last_heartbeat_at' <<<"$lv9C")" "$obs2"
ck "lv9c C — current_task_ref cleared on idle"                zz "$(jq -r '.current_task_ref // ""' <<<"$lv9C")"

# Case D — empty string from the wire (literal "") ALSO clears, identical to
# omission (the producer's jqStr-style normalization on the receive side).
co_request "$GOOD" heartbeat "$(hb_line hostLv9 projLv9D running TASK_A "$(ago 10)")" >/dev/null 2>&1
ck "lv9c D1 — current_task_ref = TASK_A"                      \
   eq "$(co_request "$GOOD" get runner_state projLv9D 2>/dev/null | jq -r '.current_task_ref')" "TASK_A"
co_request "$GOOD" heartbeat "$(hb_line hostLv9 projLv9D idle "" "$(ago 5)")" >/dev/null 2>&1
ck "lv9c D2 — literal empty current_task_ref also clears"     \
   zz "$(co_request "$GOOD" get runner_state projLv9D 2>/dev/null | jq -r '.current_task_ref // ""')"

echo "── anti-drift: T4.1 boundary intact (co__poll liveness-free; caps == 4) ──"
# co__poll stays the pure TRANSPORT its own T4.1 test asserts — reconcile is a
# SEPARATE semantics layer (this is exactly the T4.1 boundary T4.3 must hold).
pollOut="$(co_request "$GOOD" poll projA projA 2>/dev/null)"
ck "co__poll (T4.1) still carries NO 'liveness' (boundary intact)" eq "$(jq -r 'has("liveness")' <<<"$pollOut")" "false"
ck "co__poll (T4.1) carries NO desired_actual_mismatch (boundary)" eq "$(jq -r 'has("desired_actual_mismatch")' <<<"$pollOut")" "false"
ck "reconcile (T4.3) DOES derive liveness (the semantics layer)"   eq "$(jq -r 'has("liveness")' <<<"$rL")" "true"
caps="$(co_capabilities 2>/dev/null)"
ncaps="$(grep -c '§2' <<<"$caps" || true)"
ck "co_capabilities (T4.1) still EXACTLY four §2 lines (untouched)" eq "$ncaps" "4"
ck "co_capabilities does NOT advertise reconcile/work-snapshot as §2" hasnt "work-snapshot" "$caps"
# 'work_snapshot' IS a §4 type (T4.1 registry, for the publisher's stored
# envelope) — the READ-side producer is a different path that never persists.
ck "'work_snapshot' is a §4 record type (T4.1 registry — publisher envelope)" \
   eq "$(co__schema_version work_snapshot)" "1"
# forensic stream is NEVER in the projection (separate namespace; §10).
MARK="FORENSIC-CANARY-7c1f"
co_request "$GOOD" forensic-put fc1 claude-tools-99 \
  "{\"last_assistant\":\"$MARK\"}" >/dev/null 2>&1
SNAP2="$(co_request "$GOOD" work-snapshot projA "$BEADS" 2>/dev/null)"
ck "the §10 forensic stream is NEVER in the §4.5 projection"  hasnt "$MARK" "$SNAP2"
# capacity strip TRACKS T4.4's aggregated verdict (surfaced, not measured):
# seed a real-shaped §1.1 'over' report and the strip flips to 'over'.
co_request "$GOOD" report-capacity \
  '{"report":"capacity","schema_version":1,"runner_id":"capR","cost_class":"standard","verdict":"over","observed_at":"2026-05-16T10:00:00Z"}' >/dev/null 2>&1
ck "capacity strip SURFACES T4.4's aggregated 'over' verdict" \
   eq "$(co_request "$GOOD" work-snapshot projA "$BEADS" 2>/dev/null | jq -r '.projects[0].capacity_strip.verdict')" "over"

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " test-coordinator-reconcile (T4.3, claude-tools-l9o):  PASS=$PASS  FAIL=$FAIL"
echo "══════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
