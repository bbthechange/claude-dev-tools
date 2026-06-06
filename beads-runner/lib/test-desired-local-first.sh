#!/bin/bash
# beads-runner/lib/test-desired-local-first.sh — claude-tools-y6j9 regression-lock.
#
# Two locks for the local-first desired-state change (discovered-from dky8):
#   A. THE break-through-pause fix — runner-backend-real.sh co_deliver_desired_state
#      reads the LOCAL .co-store RunnerState.desired FIRST, so a present
#      paused/stopped SURVIVES a Coordinator-unreachable window (the bug: one
#      failed poll fail-OPENed to "running" and broke through a 17h pause). Also
#      pins the cold-start semantics (reachable network seeds; unreachable ⇒ the
#      EXPLICIT bootstrap default "running" — nothing to break through when there
#      is no local value).
#   B. the `set-desired` agent_actions INTENT in the bash ORACLE
#      (co__agent_action_enqueue) — accept a valid §4.2 wire state, reject a bad/
#      missing one. Keeps the oracle differential-equivalent to the cf engine
#      twin (cf/test/agent-action.spec.js).
#
# Offline + deterministic: no COORDINATOR_URL (co_request stays in-process and is
# stubbed where the network path is exercised), a temp CO_STORE, jq only.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
result() { echo "RESULT: $PASS passed, $FAIL failed"; [[ "$FAIL" -eq 0 ]]; }

command -v jq >/dev/null 2>&1 || { echo "  (skip) jq not available"; echo "RESULT: 0 passed, 0 failed"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
unset COORDINATOR_URL 2>/dev/null || true   # keep co_request in-process / stubbable
export CO_STORE="$TMP/.co-store"
mkdir -p "$CO_STORE/records"

# The REAL backend adapter sources coordinator.sh + local-agent.sh +
# co-http-transport.sh and defines co_deliver_desired_state (the fix under test).
# shellcheck source=/dev/null
source "$HERE/runner-backend-real.sh" 2>/dev/null \
  || { bad "could not source runner-backend-real.sh"; result; exit 1; }

PROJ="ct-localfirst"
REC="$CO_STORE/records/runner_state.$PROJ.json"
write_desired() { # <state>
  printf '{"schema_version":1,"project_ref":"%s","principal":"brian","desired":"%s","actual":"running","last_heartbeat_at":"2026-06-06T00:00:00Z"}\n' \
    "$PROJ" "$1" > "$REC"
}

echo "── A. break-through-pause: local desired wins, even when UNREACHABLE ──"
# Stub co_request to behave like the genuinely-unreachable transport (rc 4 +
# CO_HTTP_UNREACHABLE=1). With a LOCAL value present this path must NEVER be
# consulted — local wins outright — so the unreachable engine cannot break
# through the pause.
co_request() { CO_HTTP_UNREACHABLE=1; return 4; }

write_desired paused
out="$(co_deliver_desired_state "$PROJ")"
[[ "$out" == "paused" ]] && ok "local desired=paused SURVIVES an unreachable engine (the fix)" \
  || bad "BREAK-THROUGH-PAUSE REGRESSION: expected paused, got '$out'"

write_desired stopped
out="$(co_deliver_desired_state "$PROJ")"
[[ "$out" == "stopped" ]] && ok "local desired=stopped survives unreachable" \
  || bad "expected stopped, got '$out'"

write_desired spare-cycles
out="$(co_deliver_desired_state "$PROJ")"
[[ "$out" == "spare-cycles" ]] && ok "local desired=spare-cycles survives unreachable" \
  || bad "expected spare-cycles, got '$out'"

write_desired running
out="$(co_deliver_desired_state "$PROJ")"
[[ "$out" == "running" ]] && ok "local desired=running returned verbatim" \
  || bad "expected running, got '$out'"
unset -f co_request 2>/dev/null || true

echo "── A. cold-start (no local record): network seed, else bootstrap ──"
rm -f "$REC"
co_request() { printf '{"desired":"paused"}\n'; return 0; }  # reachable poll
out="$(co_deliver_desired_state "$PROJ")"
[[ "$out" == "paused" ]] && ok "cold-start: a reachable engine SEEDS desired=paused" \
  || bad "cold-start seed: expected paused, got '$out'"
unset -f co_request 2>/dev/null || true

co_request() { CO_HTTP_UNREACHABLE=1; return 4; }  # unreachable
out="$(co_deliver_desired_state "$PROJ")"
[[ "$out" == "running" ]] && ok "cold-start + unreachable: EXPLICIT bootstrap default running" \
  || bad "bootstrap: expected running, got '$out'"
unset -f co_request 2>/dev/null || true

# A corrupt local record must not crash; fall through to cold-start handling.
printf 'not json{' > "$REC"
co_request() { CO_HTTP_UNREACHABLE=1; return 4; }
out="$(co_deliver_desired_state "$PROJ")"
[[ "$out" == "running" ]] && ok "corrupt local record degrades to bootstrap (no crash)" \
  || bad "corrupt record: expected running, got '$out'"
unset -f co_request 2>/dev/null || true
rm -f "$REC"

echo "── B. set-desired agent_actions intent — bash oracle parity ──"
enq() { co__agent_action_enqueue brian "$1"; }

for st in running paused spare-cycles stopped; do
  env_="$(jq -cn --arg ws "$PROJ" --arg s "$st" '{intent:"set-desired",workspace:$ws,target:{},args:{state:$s}}')"
  r="$(enq "$env_")"; rc=$?
  if [[ $rc -eq 0 ]] && printf '%s' "$r" | jq -e '.ok==true and (.action_id|type=="string")' >/dev/null 2>&1; then
    ok "oracle: set-desired state='$st' enqueues (ok+action_id)"
  else
    bad "oracle: set-desired state='$st' should enqueue — got rc=$rc body=$r"
  fi
done

bad_env() { local r rc; r="$(enq "$1")"; rc=$?; [[ $rc -ne 0 ]] && printf '%s' "$r" | jq -e '.ok==false' >/dev/null 2>&1; }
bad_env "$(jq -cn --arg ws "$PROJ" '{intent:"set-desired",workspace:$ws,target:{},args:{state:"halt"}}')" \
  && ok "oracle: set-desired bad state rejected (rc≠0, ok:false)" || bad "oracle: bad state was NOT rejected"
bad_env "$(jq -cn --arg ws "$PROJ" '{intent:"set-desired",workspace:$ws,target:{},args:{}}')" \
  && ok "oracle: set-desired missing state rejected" || bad "oracle: missing state was NOT rejected"
bad_env "$(jq -cn '{intent:"set-desired",workspace:"../etc",target:{},args:{state:"paused"}}')" \
  && ok "oracle: set-desired unsafe workspace rejected" || bad "oracle: unsafe workspace was NOT rejected"
# UI 'spare-only' must be normalized by the proxy → engine rejects the raw UI name.
bad_env "$(jq -cn --arg ws "$PROJ" '{intent:"set-desired",workspace:$ws,target:{},args:{state:"spare-only"}}')" \
  && ok "oracle: raw UI 'spare-only' rejected (proxy must map to spare-cycles)" || bad "oracle: spare-only was NOT rejected"

result