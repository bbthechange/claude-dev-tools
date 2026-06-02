#!/bin/bash
# beads-runner/lib/test-coordinator-gate-meta.sh — focused oracle clauses for
# the J1 gate_metadata transient store on coordinator.sh (claude-tools-pkgt).
#
# This is the BASH ORACLE side of the differential pair whose CF twin is
# cf/test/gate-meta.spec.js (gate-meta.js). It exercises ONLY the gate-meta-*
# surface on coordinator.sh and shares NO state with the T1 conformance harness
# or the sibling T4 tests. coordinator.sh is the FROZEN oracle the CF engine is
# asserted equal to (lib-shared.md); these clauses are written to MIRROR the
# spec.js assertions clause-for-clause so a behaviour divergence shows up as a
# RED here OR a RED there.
#
# What this proves (1:1 with gate-meta.spec.js):
#   • set → get round-trips: an upserted gate comes back as the D.2 Gate object
#     {id,why,unblock_condition,owner,scope,set_at,updated_at} VERBATIM.
#   • Write gate (conformance at WRITE — the one refusal point): a bad id, a
#     MISSING/empty/whitespace why (B8 — a Gate always has a why), and a scope
#     outside {task,cohort} each reject (rc 3) and write NOTHING.
#   • set_at is PRESERVED across edits (only updated_at advances); scope
#     defaults to "task" when absent.
#   • get one (id given) ⇒ {gate:…|null}; get all (omitted) ⇒ {gates:[…]} sorted;
#     a missing row ⇒ {gate:null}, never an error.
#   • owner is an INPUT, not the principal (§2.3): stored verbatim.
#   • §9.1: no/invalid token ⇒ rejected at the chokepoint; NOTHING written.
#   • Anti-drift: `gate_metadata` is NOT a §4 record type (put ⇒ rc 2 unknown
#     type); it lives in its OWN namespace, never the §4 records/ dir.
set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/coordinator.sh"
[[ -f "$LIB" ]] || { echo "FATAL: coordinator.sh not found at $LIB"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
ck()  { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
eq()  { [[ "$1" == "$2" ]]; }
# An RFC-3339 UTC …Z stamp predicate (§0.4 — all timestamps are RFC-3339 UTC).
grep_z() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CO_STORE="$WORK/store"          # hosted store realised in scratch (never the repo)
unset CO_EXPECTED_TOKEN PRINCIPAL_V1 2>/dev/null || true

# shellcheck source=/dev/null
source "$LIB"

GOOD="bearer-runner-secret-xyz"        # a present, valid v1 bearer

# Count rows in the gate_metadata namespace (the bash analogue of the spec's
# SELECT COUNT(*) — a directory listing of the SEPARATE namespace).
rowcount() {
  local d c=0 f
  d="$(co__gate_meta_dir)"
  [[ -d "$d" ]] || { echo 0; return 0; }
  for f in "$d"/*.json; do [[ -e "$f" ]] && c=$((c+1)); done
  echo "$c"
}
freshstore() { rm -rf "$(co__gate_meta_dir)" 2>/dev/null || true; }
# co_request gate-meta-set with a JSON object built from key=value pairs is
# fiddly; build the json explicitly per case instead.

echo "── SET → GET ROUND-TRIP (the D.2 Gate object) ──"
freshstore
M='{"id":"audio-redesign","why":"Waiting on the new audio engine before re-enabling these tasks.","unblock_condition":"rhythmGame-77a closes","owner":"agent:enricher","scope":"cohort"}'
co_request "$GOOD" gate-meta-set "$M" >/dev/null 2>&1; ck "gate-meta-set upserts (rc 0)" eq "$?" "0"
ck "set stored exactly one row in the gate_metadata namespace" eq "$(rowcount)" "1"

G="$(co_request "$GOOD" gate-meta-get audio-redesign 2>/dev/null)"
gate() { printf '%s' "$G" | jq -r "$1" 2>/dev/null; }
ck "gate-meta-get [id] returns {gate:{...}}"  eq "$(printf '%s' "$G" | jq -r '.gate|type' 2>/dev/null)" "object"
ck "D.2: id = the bare gate id"               eq "$(gate '.gate.id')" "audio-redesign"
ck "D.2: why preserved verbatim"              eq "$(gate '.gate.why')" "Waiting on the new audio engine before re-enabling these tasks."
ck "D.2: unblock_condition preserved"         eq "$(gate '.gate.unblock_condition')" "rhythmGame-77a closes"
ck "§2.3: owner preserved verbatim (INPUT, not PRINCIPAL_V1)" eq "$(gate '.gate.owner')" "agent:enricher"
ck "D.2: scope preserved (cohort)"            eq "$(gate '.gate.scope')" "cohort"
sa="$(gate '.gate.set_at')"; ua="$(gate '.gate.updated_at')"
ck "set_at is an RFC-3339 UTC …Z stamp"       grep_z "$sa"
ck "updated_at is an RFC-3339 UTC …Z stamp"   grep_z "$ua"
keys="$(printf '%s' "$G" | jq -cS '.gate|keys' 2>/dev/null)"
ck "Gate object has EXACTLY the 7 D.2+set_at keys" eq "$keys" '["id","owner","scope","set_at","unblock_condition","updated_at","why"]'

echo "── scope DEFAULTS to task when absent ──"
freshstore
co_request "$GOOD" gate-meta-set '{"id":"defaultscope","why":"x"}' >/dev/null 2>&1
DS="$(co_request "$GOOD" gate-meta-get defaultscope 2>/dev/null)"
ck "scope defaults to 'task' (closed D.2 enum, no null member)" eq "$(printf '%s' "$DS" | jq -r '.gate.scope' 2>/dev/null)" "task"
ck "absent unblock_condition surfaces null (B.4 honest absence)" eq "$(printf '%s' "$DS" | jq -r '.gate.unblock_condition' 2>/dev/null)" "null"
ck "absent owner surfaces null"                                  eq "$(printf '%s' "$DS" | jq -r '.gate.owner' 2>/dev/null)" "null"

echo "── set_at PRESERVED across edits; updated_at advances ──"
freshstore
co_request "$GOOD" gate-meta-set '{"id":"edited","why":"first reason"}' >/dev/null 2>&1
FIRST="$(co_request "$GOOD" gate-meta-get edited 2>/dev/null)"
firstSetAt="$(printf '%s' "$FIRST" | jq -r '.gate.set_at' 2>/dev/null)"
# A second-resolution clock means a same-second edit cannot prove updated_at
# MOVES, but it CAN prove set_at does NOT — that is the honesty invariant.
co_request "$GOOD" gate-meta-set '{"id":"edited","why":"revised reason after more info"}' >/dev/null 2>&1; ck "editing an existing gate returns rc 0" eq "$?" "0"
ck "edit did NOT create a second row (upsert on the same id)" eq "$(rowcount)" "1"
SECOND="$(co_request "$GOOD" gate-meta-get edited 2>/dev/null)"
ck "edit applied the new why"  eq "$(printf '%s' "$SECOND" | jq -r '.gate.why' 2>/dev/null)" "revised reason after more info"
ck "set_at PRESERVED across the edit ('set 4d ago' stays honest)" eq "$(printf '%s' "$SECOND" | jq -r '.gate.set_at' 2>/dev/null)" "$firstSetAt"

echo "── GET ALL (no id) ⇒ {gates:[…]} sorted; GET missing ⇒ {gate:null} ──"
freshstore
co_request "$GOOD" gate-meta-set '{"id":"zzz-last","why":"z"}'  >/dev/null 2>&1
co_request "$GOOD" gate-meta-set '{"id":"aaa-first","why":"a"}' >/dev/null 2>&1
ALL="$(co_request "$GOOD" gate-meta-get 2>/dev/null)"
ck "gate-meta-get [] returns {gates:[...]}" eq "$(printf '%s' "$ALL" | jq -r '.gates|type' 2>/dev/null)" "array"
ck "get-all surfaces both gates"            eq "$(printf '%s' "$ALL" | jq -r '.gates|length' 2>/dev/null)" "2"
ck "get-all is sorted by gate_id ASC"       eq "$(printf '%s' "$ALL" | jq -r '[.gates[].id]|join(",")' 2>/dev/null)" "aaa-first,zzz-last"
# corruption tolerance (per-row read): a torn/tampered row file degrades ONLY
# itself — it must NEVER zero out the whole projection (the J2 holds[] bulk path
# + the CF independent-rows convention). A single jq -cs slurp would collapse.
printf '%s' '{not valid json' > "$(co__gate_meta_dir)/torn-row.json"
ALL2="$(co_request "$GOOD" gate-meta-get 2>/dev/null)"
ck "a torn row file degrades only itself, not the whole projection" eq "$(printf '%s' "$ALL2" | jq -r '[.gates[].id]|join(",")' 2>/dev/null)" "aaa-first,zzz-last"
rm -f "$(co__gate_meta_dir)/torn-row.json"
MISS="$(co_request "$GOOD" gate-meta-get no-such-gate 2>/dev/null)"
ck "missing row ⇒ {gate:null} (never an error)" eq "$(printf '%s' "$MISS" | jq -r '.gate' 2>/dev/null)" "null"

echo "── WRITE GATE: id shape + REQUIRED why + closed scope enum (writes NOTHING) ──"
freshstore
# rejects <meta_json>: 0 iff set rejects (rc nonzero) AND the row count is unchanged.
rejects() {
  local before after
  before="$(rowcount)"
  co_request "$GOOD" gate-meta-set "$1" >/dev/null 2>&1 && return 1   # success ⇒ NOT a reject
  after="$(rowcount)"
  [[ "$before" == "$after" ]]
}
ck "why MISSING ⇒ reject; nothing written (B8)"          rejects '{"id":"audio-redesign","scope":"cohort"}'
ck "why empty string ⇒ reject"                           rejects '{"id":"audio-redesign","why":""}'
ck "why whitespace-only ⇒ reject (a whitespace why is not a why — D.3)" rejects '{"id":"audio-redesign","why":"   "}'
ck "id missing ⇒ reject (the bare gate id)"              rejects '{"why":"valid why"}'
ck "id with uppercase ⇒ reject (^[a-z0-9][a-z0-9-]*$)"   rejects '{"id":"Audio-Redesign","why":"valid why"}'
ck "id with a colon ⇒ reject (gate: is the namespace, not the key)" rejects '{"id":"gate:audio","why":"valid why"}'
ck "id with a leading hyphen ⇒ reject (must start alnum)" rejects '{"id":"-leading","why":"valid why"}'
ck "id with a space ⇒ reject"                            rejects '{"id":"audio redesign","why":"valid why"}'
ck "scope outside {task,cohort} ⇒ reject (closed D.2 enum)" rejects '{"id":"audio-redesign","why":"valid why","scope":"epic"}'
ck "invalid JSON arg ⇒ reject; nothing written"          rejects '{not-json'
ck "array (not an object) ⇒ reject"                      rejects '[1,2,3]'
# missing arg ⇒ rc 2 (the shell-level arity refusal), distinct from rc 3
co_request "$GOOD" gate-meta-set "" >/dev/null 2>&1; ck "missing arg ⇒ rc 2" eq "$?" "2"

echo "── gate_id alias accepted for id ──"
freshstore
co_request "$GOOD" gate-meta-set '{"gate_id":"alias-gate","why":"via the gate_id alias"}' >/dev/null 2>&1
AL="$(co_request "$GOOD" gate-meta-get alias-gate 2>/dev/null)"
ck "\`gate_id\` is accepted as an alias for id" eq "$(printf '%s' "$AL" | jq -r '.gate.id' 2>/dev/null)" "alias-gate"

echo "── §9.1 — no/invalid token ⇒ rejected at the chokepoint; NOTHING written ──"
freshstore
co_request "" gate-meta-set "$M" >/dev/null 2>&1; ck "no-token gate-meta-set ⇒ rc 1 (chokepoint)" eq "$?" "1"
ck "no-token gate-meta-set wrote NOTHING" eq "$(rowcount)" "0"
export CO_EXPECTED_TOKEN="expected"
co_request "wrong" gate-meta-set "$M" >/dev/null 2>&1; ck "invalid-token gate-meta-set ⇒ rc 1" eq "$?" "1"
unset CO_EXPECTED_TOKEN
ck "invalid-token gate-meta-set wrote NOTHING" eq "$(rowcount)" "0"

echo "── ANTI-DRIFT: gate_metadata is NOT a §4 record type ──"
ck "co__schema_version gate_metadata is empty (absent from the §4 registry)" eq "$(co__schema_version gate_metadata)" ""
co_request "$GOOD" put gate_metadata audio-redesign '{"schema_version":1,"why":"x"}' >/dev/null 2>&1
ck "§4 put gate_metadata ⇒ rc 2 (unknown §4 record type)" eq "$?" "2"
co_request "$GOOD" gate-meta-set '{"id":"canary-gate","why":"gateCanaryWhy"}' >/dev/null 2>&1
# the §4 records/ dir never holds a gate metadata row (separate namespace)
recblob=""
[[ -d "$CO_STORE/records" ]] && recblob="$(cat "$CO_STORE"/records/*.json 2>/dev/null)"
case "$recblob" in
  *gateCanaryWhy*|*canary-gate*) bad "the §4 records dir holds a gate metadata row (namespace leak)";;
  *) ok "the §4 records dir holds NO gate metadata (separate namespace)";;
esac
ck "the gate row lives in the gate_metadata/ namespace" test -f "$(co__gate_meta_dir)/canary-gate.json"

echo ""
echo "gate-meta oracle: pass=$PASS fail=$FAIL"
[[ "$FAIL" -eq 0 ]] || { echo "FAIL — gate-meta oracle clauses failed" >&2; exit 1; }
echo "OK — all gate-meta oracle clauses pass"
exit 0
