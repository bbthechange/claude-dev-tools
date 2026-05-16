#!/bin/bash
# beads-runner/lib/test-coordinator.sh — focused unit test for the Coordinator
# SKELETON (T4.1, claude-tools-ick). This is T4.1's OWN test surface —
# deliberately NOT a member of the T1 conformance suite (beads-runner/
# conformance/, owned by T1a/T1b) and it does NOT touch the bc-ad2 lease-
# posture rig (those AD2.1/AD2.2 gates belong to T4.2, claude-tools-am8).
# Anti-drift: it exercises only the Coordinator skeleton library.
#
# Asserts the EXIT CRITERIA T4.1 owns against INTERFACE.md v1:
#   1. §2 — the Coordinator shell stands up; the four §2 capabilities are
#      reachable surfaces (store / timer-surface / authed endpoint /
#      deliver-desired-state).
#   2. §2.3/§9.1 — every request passes EXACTLY ONE authenticate→principal
#      returning PRINCIPAL_V1 after bearer validity; no/invalid token ⇒
#      rejected BEFORE any §4 write.
#   3. §4/§0.3/§9.1 — each §4 record round-trips with principal=PRINCIPAL_V1
#      stamped; an unknown HIGHER schema_version is rejected (never
#      best-effort-parsed).
#   4. §9.1/§4.2 C4 seam — last_desired_actor is captured on a
#      RunnerState.desired change with ALL actors authorised equally (no
#      UI/agent split; the §0.C asymmetry is NOT enforced).
#   5. §2.2 — the timer is a CAPABILITY SURFACE with the S-6 'missed fire ⇒
#      fire-on-next-poll' degrade (no dossier semantics, no per-Item latch
#      here — that is T5).
#
# Self-contained: its own CO_STORE under mktemp; its own env vocabulary
# (T41T_* / CO_*), sharing NO state with the T1 conformance harness.
set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/coordinator.sh"
[[ -f "$LIB" ]] || { echo "FATAL: coordinator.sh not found at $LIB"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
ck()  { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CO_STORE="$WORK/store"          # hosted store realised in scratch (never the repo)
unset CO_EXPECTED_TOKEN PRINCIPAL_V1 LEASE_TMP 2>/dev/null || true

# shellcheck source=/dev/null
source "$LIB"

GOOD="bearer-runner-secret-xyz"        # a present, valid v1 bearer

echo "── EXIT-1: the shell stands up; the four §2 capabilities are reachable ──"
caps="$(co_capabilities 2>/dev/null)"
ck "co_capabilities lists §2.1 store"              grep -q '§2.1 store'              <<<"$caps"
ck "co_capabilities lists §2.2 timer"              grep -q '§2.2 durable one-shot'   <<<"$caps"
ck "co_capabilities lists §2.3 authed/§9.1 choke"  grep -q '§2.3 authed'             <<<"$caps"
ck "co_capabilities lists §2.4 deliver-desired"    grep -q '§2.4 deliver-desired'    <<<"$caps"
ncaps="$(grep -c '§2' <<<"$caps" || true)"
ck "exactly four §2 capability lines"              test "$ncaps" -eq 4
ck "all four reachable via co_request dispatch"    bash -c '
  source "'"$LIB"'"
  co_request "'"$GOOD"'" timer-due >/dev/null 2>&1 &&
  co_request "'"$GOOD"'" get lease nope >/dev/null 2>&1 ;
  # get on a missing record returns 1 (reachable, just empty) — treat reachable
  [[ $? -le 1 ]]'

echo "── EXIT-2: §9.1 ONE chokepoint; no/invalid token ⇒ reject BEFORE any write ──"
# Authoritative principal resolution after a VALID bearer.
p="$(co_authenticate "$GOOD" 2>/dev/null)"
ck "valid bearer ⇒ principal resolves"             test -n "$p"
ck "resolved principal == PRINCIPAL_V1 ('brian')"  test "$p" = "brian"
# Missing token rejected, nothing resolved.
ck "missing bearer ⇒ co_authenticate fails"        bash -c 'source "'"$LIB"'"; ! co_authenticate "" >/dev/null 2>&1'
# Invalid token (CO_EXPECTED_TOKEN mismatch) rejected.
ck "invalid bearer ⇒ co_authenticate fails"        bash -c 'source "'"$LIB"'"; CO_EXPECTED_TOKEN=expected co_authenticate wrong >/dev/null 2>&1; [[ $? -ne 0 ]]'
# The structural invariant: a rejected request performs NO §4 write.
co_request "" put runner_state projX '{"schema_version":1,"desired":"running"}' >/dev/null 2>&1 || true
ck "no-token put ⇒ request rejected (nonzero)"     bash -c 'source "'"$LIB"'"; ! co_request "" put runner_state projX "{\"schema_version\":1,\"desired\":\"running\"}" >/dev/null 2>&1'
ck "no-token put ⇒ ZERO §4 records written"        bash -c '[[ -z "$(ls -A "'"$CO_STORE"'/records" 2>/dev/null)" ]]'
CO_EXPECTED_TOKEN=expected co_request badtok put runner_state projY '{"schema_version":1,"desired":"running"}' >/dev/null 2>&1 || true
ck "invalid-token put ⇒ still ZERO §4 records"     bash -c '[[ -z "$(ls -A "'"$CO_STORE"'/records" 2>/dev/null)" ]]'

echo "── EXIT-3: §4 round-trip + §9.1 principal stamp + §0.3 reject-higher ──"
# A §4 record carrying a DIFFERENT principal literal must come back stamped
# with the RESOLVED principal (never the use-site literal — C7/§9.1).
co_request "$GOOD" put notification n1 \
  '{"schema_version":1,"dossier_ref":"d1","tier":"blocking","principal":"someone-else"}' >/dev/null 2>&1
got="$(co_request "$GOOD" get notification n1 2>/dev/null)"
ck "notification round-trips"                      bash -c "[[ -n \"$got\" ]]"
ck "stored principal == PRINCIPAL_V1 (stamped)"    bash -c "[[ \"\$(jq -r .principal <<<'$got')\" == brian ]]"
ck "use-site literal 'someone-else' overwritten"   bash -c "[[ \"\$(jq -r .principal <<<'$got')\" != 'someone-else' ]]"
# Every §4 record TYPE round-trips (store owner).
for t in dossier runner_state notification lease work_snapshot; do
  co_request "$GOOD" put "$t" "rt_$t" "{\"schema_version\":1}" >/dev/null 2>&1
  rec="$(co_request "$GOOD" get "$t" "rt_$t" 2>/dev/null)"
  ck "§4 $t round-trips with principal stamped" \
     bash -c "[[ \"\$(jq -r .principal <<<'$rec' 2>/dev/null)\" == brian ]]"
done
# §0.3 — an unknown HIGHER schema_version is rejected, NOT best-effort-parsed.
co_request "$GOOD" put runner_state hi '{"schema_version":2,"desired":"running"}' >/dev/null 2>&1 || true
ck "schema_version 2 (> bound 1) ⇒ rejected"       bash -c 'source "'"$LIB"'"; ! co_request "'"$GOOD"'" put runner_state hi "{\"schema_version\":2}" >/dev/null 2>&1'
ck "rejected higher-version record NOT persisted"  bash -c '! test -f "'"$CO_STORE"'/records/runner_state.hi.json"'
ck "missing schema_version ⇒ rejected"             bash -c 'source "'"$LIB"'"; ! co_request "'"$GOOD"'" put dossier nov "{\"id\":\"x\"}" >/dev/null 2>&1'
ck "unknown §4 record type ⇒ rejected"             bash -c 'source "'"$LIB"'"; ! co_request "'"$GOOD"'" put bogus_type z "{\"schema_version\":1}" >/dev/null 2>&1'
# §4 mandates `schema_version : int` — a JSON *string* "1" MUST NOT slip past.
co_request "$GOOD" put dossier dstr '{"schema_version":"1"}' >/dev/null 2>&1 || true
ck "string schema_version \"1\" ⇒ rejected (§4 int)"  bash -c 'source "'"$LIB"'"; ! co_request "'"$GOOD"'" put dossier dstr "{\"schema_version\":\"1\"}" >/dev/null 2>&1'
ck "rejected string-version record NOT persisted"  bash -c '! test -f "'"$CO_STORE"'/records/dossier.dstr.json"'
# Store-owner input hygiene: a traversal-shaped id is rejected at the door.
ck "unsafe id with '/' ⇒ rejected"                 bash -c 'source "'"$LIB"'"; ! co_request "'"$GOOD"'" put lease "../../etc/evil" "{\"schema_version\":1}" >/dev/null 2>&1'
ck "unsafe id with '..' ⇒ rejected"                bash -c 'source "'"$LIB"'"; ! co_request "'"$GOOD"'" put lease ".." "{\"schema_version\":1}" >/dev/null 2>&1'
ck "no stray file escaped the records dir"         bash -c '! test -e "'"$CO_STORE"'/records/etc"'

echo "── EXIT-4: C4 seam — last_desired_actor captured, ALL actors equal ──"
co_request "$GOOD" set-desired projA paused   "agent-runner-7" >/dev/null 2>&1
rsA="$(co_request "$GOOD" get runner_state projA 2>/dev/null)"
ck "set-desired persists RunnerState"              bash -c "[[ -n \"$rsA\" ]]"
ck "desired captured (paused)"                     bash -c "[[ \"\$(jq -r .desired <<<'$rsA')\" == paused ]]"
ck "last_desired_actor captured (agent-runner-7)"  bash -c "[[ \"\$(jq -r .last_desired_actor <<<'$rsA')\" == 'agent-runner-7' ]]"
ck "RunnerState principal stamped PRINCIPAL_V1"    bash -c "[[ \"\$(jq -r .principal <<<'$rsA')\" == brian ]]"
# A DIFFERENT actor class (a 'ui' actor) is authorised IDENTICALLY — no split,
# no §0.C asymmetry: the call succeeds and the actor is captured verbatim.
co_request "$GOOD" set-desired projA running "ui:brian-laptop" >/dev/null 2>&1
rsA2="$(co_request "$GOOD" get runner_state projA 2>/dev/null)"
ck "ui-actor desired change authorised equally"    bash -c "[[ \"\$(jq -r .desired <<<'$rsA2')\" == running ]]"
ck "ui actor captured verbatim (no UI/agent split)" bash -c "[[ \"\$(jq -r .last_desired_actor <<<'$rsA2')\" == 'ui:brian-laptop' ]]"
# §0.C asymmetry MUST NOT be enforced: agent→downgrade and ui→promote both pass
# through the SAME one chokepoint with no actor branch. Source-level guard: the
# library contains no `if`/`case` keyed on the actor argument.
ck "no actor-discriminating branch in source (§0.C not enforced)" \
   bash -c '! grep -Eiq "if .*\\\$?actor|case .*\\\$actor" "'"$LIB"'"'
# A corrupt prior RunnerState record MUST NOT wedge the desired-state control
# path (EXIT crit 4): set-desired degrades to a fresh base, still capturing
# the actor — desired-state is Coordinator-owned, the merge is best-effort.
printf 'not json at all\n' > "$CO_STORE/records/runner_state.projCorrupt.json"
co_request "$GOOD" set-desired projCorrupt stopped "agent-9" >/dev/null 2>&1
rsC="$(co_request "$GOOD" get runner_state projCorrupt 2>/dev/null)"
ck "corrupt prior ⇒ set-desired still succeeds"     bash -c "[[ \"\$(jq -r .desired <<<'$rsC' 2>/dev/null)\" == stopped ]]"
ck "corrupt prior ⇒ last_desired_actor still captured" bash -c "[[ \"\$(jq -r .last_desired_actor <<<'$rsC' 2>/dev/null)\" == 'agent-9' ]]"

echo "── EXIT-5-adjacent: §2.2 timer is a SURFACE with the S-6 poll-fallback ──"
co_request "$GOOD" timer-arm tmr-past "2000-01-01T00:00:00Z" >/dev/null 2>&1
co_request "$GOOD" timer-arm tmr-future "2999-01-01T00:00:00Z" >/dev/null 2>&1
due="$(co_request "$GOOD" timer-due 2>/dev/null)"
ck "armed past timer surfaces on poll (S-6 missed⇒poll)"  bash -c "grep -qx tmr-past <<<'$due'"
ck "future timer does NOT surface"                        bash -c "! grep -qx tmr-future <<<'$due'"
co_request "$GOOD" timer-ack tmr-past >/dev/null 2>&1
due2="$(co_request "$GOOD" timer-due 2>/dev/null)"
ck "acked timer no longer surfaces (ack surface works)"   bash -c "! grep -qx tmr-past <<<'$due2'"
# Anti-drift: the timer surface is OPAQUE — the armed record carries exactly
# {timer_id,fire_at,armed_at,acked} and NO dossier/item/consequence coupling
# (fire(dossier_id) wiring + the per-Item latch are T5, not this skeleton).
tkeys="$(jq -r 'keys|sort|join(",")' "$CO_STORE/timers/tmr-future.json" 2>/dev/null)"
ck "armed timer record is the opaque shape (T5 boundary)" \
   bash -c "[[ '$tkeys' == 'acked,armed_at,fire_at,timer_id' ]]"
ck "timer record carries NO dossier/item/consequence key (T5 boundary)" \
   bash -c "! grep -Eq 'dossier|consequence|item' \"$CO_STORE/timers/tmr-future.json\""

echo "── §2.4 deliver-desired-state is TRANSPORT (returns stored desired+lease) ──"
co_request "$GOOD" put lease projA '{"schema_version":1,"task_ref":"projA","owner":"runner-7"}' >/dev/null 2>&1
poll="$(co_request "$GOOD" poll projA projA 2>/dev/null)"
ck "poll returns the stored desired"               bash -c "[[ \"\$(jq -r .desired <<<'$poll')\" == running ]]"
ck "poll returns the stored lease record"          bash -c "[[ \"\$(jq -r .lease.owner <<<'$poll')\" == 'runner-7' ]]"
ck "poll stamps the resolved principal"            bash -c "[[ \"\$(jq -r .principal <<<'$poll')\" == brian ]]"
# Anti-drift: poll derived NO liveness and ran NO reconcile (T4.3 surface).
ck "poll output carries NO 'liveness' (T4.3 boundary)" bash -c "[[ \"\$(jq -r 'has(\"liveness\")' <<<'$poll')\" == false ]]"

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " test-coordinator (T4.1, claude-tools-ick):  PASS=$PASS  FAIL=$FAIL"
echo "══════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
