#!/bin/bash
# beads-runner/lib/test-coordinator-blueprint.sh — focused oracle clauses for
# the H1 blueprint §4 record + sectioned ops on coordinator.sh
# (claude-tools-uxvh1).
#
# This is the BASH ORACLE side of the differential pair whose CF twin is
# cf/test/blueprint.spec.js (cf/src/blueprint.js). It exercises ONLY the
# blueprint-* surface on coordinator.sh; coordinator.sh is the FROZEN oracle the
# CF engine is asserted equal to (lib-shared.md). These clauses MIRROR the
# spec.js assertions clause-for-clause so a behaviour divergence shows up as a
# RED here OR a RED there.
#
# What this proves (1:1 with blueprint.spec.js):
#   • put(section) → get round-trips: an upserted layer comes back VERBATIM in
#     the B.2 body {schema_version, project_ref, derived, customization,
#     narrative, conflicts[], updated_at, updated_by}.
#   • THE LOAD-BEARING SEAM — sectioned read-merge-write never clobbers: a
#     `derived` write then a `customization` write (and the reverse) leaves BOTH
#     layers intact (§2.3, principle 9, must-protect #3).
#   • A first section-only write seeds the freshEmptyBlueprint skeleton.
#   • conflicts-append PUSHES (does not replace) — two appends ⇒ two entries.
#   • Write gate (conformance at WRITE): missing arg, bad JSON, missing/unsafe
#     project_ref, unknown section, non-object body each reject (rc 2/3) and
#     write NOTHING.
#   • blueprint-get on a missing/empty project_ref ⇒ the JSON literal `null`.
#   • updated_by is an INPUT, not the principal (§2.3): stored verbatim, distinct
#     from the §9.1 principal stamp (= the resolved principal "brian").
#   • §9.1: no/invalid token ⇒ rejected at the chokepoint; NOTHING written.
#   • Anti-drift: `blueprint` IS a §4 record (in co__schema_version; reachable
#     via the generic §4 get; the §0.3 gate rejects a higher schema_version).
set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/coordinator.sh"
[[ -f "$LIB" ]] || { echo "FATAL: coordinator.sh not found at $LIB"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
ck()  { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
eq()  { [[ "$1" == "$2" ]]; }
grep_z() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CO_STORE="$WORK/store"          # hosted store realised in scratch (never the repo)
unset CO_EXPECTED_TOKEN PRINCIPAL_V1 2>/dev/null || true

# shellcheck source=/dev/null
source "$LIB"

GOOD="bearer-runner-secret-xyz"        # a present, valid v1 bearer
PR="rhythmGame"

# Count blueprint rows (the bash analogue of the spec's SELECT COUNT(*) WHERE
# type='blueprint' — a listing of records/blueprint.*.json in the §4 store).
rowcount() {
  local d c=0 f
  d="$(co__ensure_store)/records"
  [[ -d "$d" ]] || { echo 0; return 0; }
  for f in "$d"/blueprint.*.json; do [[ -e "$f" ]] && c=$((c+1)); done
  echo "$c"
}
freshstore() { rm -rf "$(co__ensure_store)/records" 2>/dev/null || true; }

# The canonical layers (the §3 derived map + the §5 customization).
DERIVED='{"nodes":[{"id":"domain:posts-feed","label":"Posts & Feed","kind":"domain","parent":null,"source_refs":["src/feed/**"],"auto_opened":false},{"id":"store:postgres","label":"Postgres","kind":"store","parent":null,"source_refs":[],"auto_opened":false}],"edges":[{"from":"domain:posts-feed","to":"store:postgres","kind":"call","bundle_key":"posts-feed→postgres"}],"apis":[{"id":"api:POST-/posts","domain":"domain:posts-feed","route":"POST /posts","calls":["capability:create-post"]}]}'
CUSTOM='{"renames":{"capability:create-post":"Publish"},"regroups":{},"pins":["domain:posts-feed"],"hidden":["vendor:datadog"],"splits":[],"merges":[]}'

put() { co_request "$GOOD" blueprint-put "$1" >/dev/null 2>&1; }
getbp() { co_request "$GOOD" blueprint-get "${1:-$PR}" 2>/dev/null; }

echo "── PUT(derived) → GET ROUND-TRIP (the B.2 body) ──"
freshstore
ENV_DERIVED="$(jq -cn --argjson d "$DERIVED" --arg pr "$PR" '{project_ref:$pr,section:"derived",body:$d,updated_by:"agent:blueprint-update"}')"
co_request "$GOOD" blueprint-put "$ENV_DERIVED" >/dev/null 2>&1; ck "blueprint-put(derived) ⇒ rc 0" eq "$?" "0"
ck "put stored exactly one blueprint row in the §4 store" eq "$(rowcount)" "1"
B="$(getbp)"
bp() { printf '%s' "$B" | jq -r "$1" 2>/dev/null; }
ck "body.schema_version === 1 (§0.3 integer)"            eq "$(bp '.schema_version')" "1"
ck "body.project_ref echoes the id"                     eq "$(bp '.project_ref')" "$PR"
ck "body.derived round-trips VERBATIM"                  eq "$(printf '%s' "$B" | jq -cS '.derived' 2>/dev/null)" "$(printf '%s' "$DERIVED" | jq -cS '.' 2>/dev/null)"
ck "body.updated_by is the INPUT (agent:blueprint-update), not the principal" eq "$(bp '.updated_by')" "agent:blueprint-update"
ck "body.updated_at is an RFC-3339 UTC …Z stamp"        grep_z "$(bp '.updated_at')"
ck "freshEmptyBlueprint seeded the customization sub-shape (pins[] present)" eq "$(bp '.customization.pins|type')" "array"
ck "freshEmptyBlueprint seeded narrative + conflicts[]" eq "$(bp '.conflicts|type')" "array"

echo "── THE LOAD-BEARING SEAM: sectioned never-clobber (§2.3) ──"
ENV_CUSTOM="$(jq -cn --argjson c "$CUSTOM" --arg pr "$PR" '{project_ref:$pr,section:"customization",body:$c,updated_by:"you"}')"
co_request "$GOOD" blueprint-put "$ENV_CUSTOM" >/dev/null 2>&1; ck "blueprint-put(customization) ⇒ rc 0" eq "$?" "0"
ck "still exactly one row (merged on (type,id), not a second record)" eq "$(rowcount)" "1"
B="$(getbp)"
ck "after customization write, derived is STILL intact (no clobber)" eq "$(printf '%s' "$B" | jq -cS '.derived' 2>/dev/null)" "$(printf '%s' "$DERIVED" | jq -cS '.' 2>/dev/null)"
ck "after customization write, customization is the new value"        eq "$(printf '%s' "$B" | jq -cS '.customization' 2>/dev/null)" "$(printf '%s' "$CUSTOM" | jq -cS '.' 2>/dev/null)"
ck "updated_by switched to the customization writer (you)"            eq "$(printf '%s' "$B" | jq -r '.updated_by' 2>/dev/null)" "you"

echo "── reverse order: customization first seeds skeleton, derived does not clobber ──"
freshstore
put "$ENV_CUSTOM"
B="$(getbp)"
ck "a first customization-only write yields a full record (derived = empty skeleton)" eq "$(printf '%s' "$B" | jq -r '.derived.nodes|length' 2>/dev/null)" "0"
ck "the first customization-only write stored the customization" eq "$(printf '%s' "$B" | jq -cS '.customization' 2>/dev/null)" "$(printf '%s' "$CUSTOM" | jq -cS '.' 2>/dev/null)"
put "$ENV_DERIVED"
B="$(getbp)"
ck "derived write after customization does NOT clobber customization (reverse)" eq "$(printf '%s' "$B" | jq -cS '.customization' 2>/dev/null)" "$(printf '%s' "$CUSTOM" | jq -cS '.' 2>/dev/null)"
ck "derived write after customization landed derived" eq "$(printf '%s' "$B" | jq -cS '.derived' 2>/dev/null)" "$(printf '%s' "$DERIVED" | jq -cS '.' 2>/dev/null)"

echo "── conflicts-append PUSHES, does not replace (§2.3) ──"
freshstore
put "$ENV_DERIVED"
CF1='{"project_ref":"rhythmGame","section":"conflicts-append","body":{"kind":"rename-orphan","node_id":"capability:create-post","custom":"Publish","note":"no longer maps to code"},"updated_by":"agent:blueprint-update"}'
CF2='{"project_ref":"rhythmGame","section":"conflicts-append","body":{"kind":"hide-orphan","node_id":"vendor:datadog","custom":"(hidden)","note":"vendor removed"},"updated_by":"agent:blueprint-update"}'
put "$CF1"; put "$CF2"
B="$(getbp)"
ck "conflicts-append pushed two entries (not replaced)" eq "$(printf '%s' "$B" | jq -r '.conflicts|length' 2>/dev/null)" "2"
ck "conflicts are in append order"                      eq "$(printf '%s' "$B" | jq -r '.conflicts[0].node_id' 2>/dev/null)" "capability:create-post"
ck "second conflict appended after the first"           eq "$(printf '%s' "$B" | jq -r '.conflicts[1].node_id' 2>/dev/null)" "vendor:datadog"
ck "a derived replace did not wipe conflicts[]"         eq "$(printf '%s' "$B" | jq -cS '.derived' 2>/dev/null)" "$(printf '%s' "$DERIVED" | jq -cS '.' 2>/dev/null)"

echo "── WRITE GATE — conformance at write; each rejects (rc != 0), NOTHING written ──"
freshstore
put "$ENV_DERIVED"     # a baseline row
BASE="$(rowcount)"
rejects() {  # $1 = envelope json; passes iff rc != 0 AND rowcount unchanged
  local before after rc
  before="$(rowcount)"
  co_request "$GOOD" blueprint-put "$1" >/dev/null 2>&1; rc=$?
  after="$(rowcount)"
  [[ "$rc" -ne 0 && "$before" == "$after" ]]
}
ck "unknown section ⇒ reject; nothing written"          rejects '{"project_ref":"rhythmGame","section":"bogus","body":{}}'
ck "missing project_ref ⇒ reject"                       rejects '{"section":"derived","body":{}}'
ck "unsafe project_ref (\"..\") ⇒ reject"               rejects '{"project_ref":"../etc","section":"derived","body":{}}'
ck "unsafe project_ref (\"/\") ⇒ reject"                rejects '{"project_ref":"a/b","section":"derived","body":{}}'
ck "body not an object (array) ⇒ reject"                rejects '{"project_ref":"rhythmGame","section":"derived","body":[1,2]}'
ck "body not an object (scalar) ⇒ reject"               rejects '{"project_ref":"rhythmGame","section":"customization","body":"nope"}'
ck "body null ⇒ reject"                                 rejects '{"project_ref":"rhythmGame","section":"narrative","body":null}'
ck "invalid JSON arg ⇒ reject"                          rejects '{not-json'
ck "array (not an object) envelope ⇒ reject"            rejects '[1,2,3]'
# missing arg ⇒ rc 2, nothing written
co_request "$GOOD" blueprint-put >/dev/null 2>&1; ck "missing arg ⇒ rc 2" eq "$?" "2"
ck "baseline row survived every rejected write (nothing clobbered)" eq "$(rowcount)" "$BASE"

echo "── blueprint-get on a missing / empty project_ref ⇒ null (honest empty) ──"
ck "blueprint-get(missing) ⇒ the JSON literal null"     eq "$(getbp does-not-exist-ws)" "null"
ck "blueprint-get('') ⇒ null (never an error)"          eq "$(co_request "$GOOD" blueprint-get '' 2>/dev/null)" "null"

echo "── §2.3 updated_by is an input, distinct from the §9.1 principal stamp ──"
freshstore
ENV_YOU="$(jq -cn --argjson d "$DERIVED" --arg pr "$PR" '{project_ref:$pr,section:"derived",body:$d,updated_by:"you"}')"
put "$ENV_YOU"
B="$(getbp)"
ck "updated_by stays the input 'you' (never overwritten by the principal)" eq "$(printf '%s' "$B" | jq -r '.updated_by' 2>/dev/null)" "you"
ck "the §9.1 principal IS stamped on the record (distinct from updated_by)" eq "$(printf '%s' "$B" | jq -r '.principal' 2>/dev/null)" "brian"

echo "── §9.1 — no/invalid token ⇒ rejected at the chokepoint; NOTHING written ──"
freshstore
co_request "" blueprint-put "$ENV_DERIVED" >/dev/null 2>&1; ck "no-token blueprint-put ⇒ rejected (rc != 0)" test "$?" -ne 0
ck "no-token blueprint-put wrote NOTHING" eq "$(rowcount)" "0"
export CO_EXPECTED_TOKEN="expected"
co_request "wrong" blueprint-put "$ENV_DERIVED" >/dev/null 2>&1; ck "invalid-token blueprint-put ⇒ rejected" test "$?" -ne 0
co_request "wrong" blueprint-get "$PR" >/dev/null 2>&1; ck "invalid-token blueprint-get ⇒ rejected (read is behind the chokepoint too)" test "$?" -ne 0
unset CO_EXPECTED_TOKEN
ck "invalid-token blueprint-put wrote NOTHING" eq "$(rowcount)" "0"

echo "── ANTI-DRIFT — blueprint IS a §4 record (the INVERSE of the transients) ──"
ck "'blueprint' IS a §4 record type (co__schema_version === 1)" eq "$(co__schema_version blueprint)" "1"
freshstore
put "$ENV_DERIVED"
G4="$(co_request "$GOOD" get blueprint "$PR" 2>/dev/null)"
ck "the generic §4 get reaches a blueprint record (addressable by (type,id))" eq "$(printf '%s' "$G4" | jq -r '.project_ref' 2>/dev/null)" "$PR"
# the §0.3 integer-≤-bound gate applies to blueprint via the generic §4 put.
co_request "$GOOD" put blueprint ws2 '{"schema_version":2,"project_ref":"ws2"}' >/dev/null 2>&1; ck "§4 put blueprint with a HIGHER schema_version ⇒ reject (§0.3)" test "$?" -ne 0
co_request "$GOOD" put blueprint ws2 '{"schema_version":1,"project_ref":"ws2"}' >/dev/null 2>&1; ck "§4 put blueprint at the bound v1 ⇒ accepted (a known §4 type)" eq "$?" "0"

echo ""
echo "test-coordinator-blueprint: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
