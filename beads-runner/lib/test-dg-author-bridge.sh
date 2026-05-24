#!/usr/bin/env bash
# beads-runner/lib/test-dg-author-bridge.sh — claude-tools-5me acceptance.
#
# Proves the DG_AUTHOR_CMD bridge behaves per the dg__author contract:
#   1. Happy path — fake claude returns a passing dossier ⇒ rc=0, stdout is
#      {body,items} with sections>=3, items>=1, full_detail>=500.
#   2. Builder refusal ({"refuse":true}) ⇒ rc!=0 (dg__author falls through).
#   3. Thin output (sections<3 OR items<1 OR full_detail<500) ⇒ rc!=0.
#   4. Envelope with no .result ⇒ rc!=0.
#   5. Invalid stdin (empty / not JSON) ⇒ rc=2.
#   6. Missing claude binary ⇒ rc=2.
#   7. End-to-end through dg__author: success path stamps body.authored_by=
#      "agent" (not "fallback"), failure path falls through to the jq path
#      with body.authored_by="fallback" + the right reason.
#
# Also grep-asserts the runner's call site exports DG_AUTHOR_CMD in the
# sr_route_stuck subshell so drift between the bridge and the wiring is
# caught loudly.
#
# Run:  bash beads-runner/lib/test-dg-author-bridge.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="$HERE/dg-author-bridge.sh"
RUNNER="$HERE/../run-beads-tasks.sh"
DG_LIB="$HERE/dossier-gen.sh"
BUILDER_PROMPT="$HERE/../agents/dossier-builder.system.md"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# ─── temp workspace ─────────────────────────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.beads/runner-logs"

GI='{"id":"stuck-claude-tools-test","kind":"decide","trigger":"worker_stuck","bead_ref":"claude-tools-test","tier":"blocking","source":{"tldr":"raw","ask":"how should we proceed?","options":[],"recommendation":null,"reversible":""},"items":[]}'

# Build a fake claude that yields a passing envelope. The body in .result
# carries 3 sections, 1 item, 600 chars of full_detail — just over the
# bridge's quality gate.
cat > "$TMP/fake-claude-ok.sh" <<'EOF'
#!/bin/bash
cat >/dev/null
FULL="$(printf 'x%.0s' {1..600})"
RESULT="$(jq -cn --arg full "$FULL" '{body:{tldr:"polished tldr",sections:[{heading:"A",prose:"a"},{heading:"B",prose:"b"},{heading:"C",prose:"c"}],diagrams:[],full_detail:$full},items:[{kind:"pick-option",options:[]}]}')"
jq -cn --arg r "$RESULT" '{result:$r, model:"fake", subtype:"success"}'
EOF
chmod +x "$TMP/fake-claude-ok.sh"

# Refusal envelope.
cat > "$TMP/fake-claude-refuse.sh" <<'EOF'
#!/bin/bash
cat >/dev/null
jq -cn '{result:"{\"refuse\":true,\"reason\":\"context too thin\"}", model:"fake"}'
EOF
chmod +x "$TMP/fake-claude-refuse.sh"

# Thin output — passes JSON+shape, fails quality gate.
cat > "$TMP/fake-claude-thin.sh" <<'EOF'
#!/bin/bash
cat >/dev/null
jq -cn '{result:"{\"body\":{\"tldr\":\"t\",\"sections\":[],\"diagrams\":[],\"full_detail\":\"x\"},\"items\":[]}", model:"fake"}'
EOF
chmod +x "$TMP/fake-claude-thin.sh"

# Envelope without .result key.
cat > "$TMP/fake-claude-noresult.sh" <<'EOF'
#!/bin/bash
cat >/dev/null
jq -cn '{model:"fake", subtype:"error"}'
EOF
chmod +x "$TMP/fake-claude-noresult.sh"

invoke() {
  local cb="$1" gi_in="${2:-$GI}"
  CLAUDE_BIN="$cb" \
    DG_AUTHOR_BRIDGE_WORKSPACE="$TMP" \
    DOSSIER_BUILDER_PROMPT_PATH="$BUILDER_PROMPT" \
    bash "$BRIDGE" <<<"$gi_in"
}

echo ""
echo "── PART A — bridge in isolation ─────────────────────────────────────"

# T1 happy path
OUT="$(invoke "$TMP/fake-claude-ok.sh" 2>/dev/null)"; RC=$?
[[ "$RC" -eq 0 ]] && ok "happy path rc=0" || bad "happy path rc=$RC (want 0)"
if [[ "$RC" -eq 0 ]]; then
  printf '%s' "$OUT" | jq -e '(.body.sections|length) >= 3' >/dev/null \
    && ok "happy path: >=3 sections" || bad "happy path: <3 sections"
  printf '%s' "$OUT" | jq -e '(.items|length) >= 1' >/dev/null \
    && ok "happy path: >=1 item" || bad "happy path: <1 item"
  printf '%s' "$OUT" | jq -e '((.body.full_detail // "")|length) >= 500' >/dev/null \
    && ok "happy path: full_detail >=500" || bad "happy path: full_detail short"
fi

# T2 refusal
invoke "$TMP/fake-claude-refuse.sh" >/dev/null 2>&1; RC=$?
[[ "$RC" -ne 0 ]] && ok "refusal rc!=0" || bad "refusal rc=$RC (want non-zero)"

# T3 thin
invoke "$TMP/fake-claude-thin.sh" >/dev/null 2>&1; RC=$?
[[ "$RC" -ne 0 ]] && ok "thin rc!=0" || bad "thin rc=$RC (want non-zero)"

# T4 envelope with no .result
invoke "$TMP/fake-claude-noresult.sh" >/dev/null 2>&1; RC=$?
[[ "$RC" -ne 0 ]] && ok "no .result rc!=0" || bad "no .result rc=$RC (want non-zero)"

# T5 invalid stdin
CLAUDE_BIN="$TMP/fake-claude-ok.sh" \
  DG_AUTHOR_BRIDGE_WORKSPACE="$TMP" \
  DOSSIER_BUILDER_PROMPT_PATH="$BUILDER_PROMPT" \
  bash "$BRIDGE" <<<"" >/dev/null 2>&1
RC=$?
[[ "$RC" -eq 2 ]] && ok "empty stdin rc=2" || bad "empty stdin rc=$RC (want 2)"

CLAUDE_BIN="$TMP/fake-claude-ok.sh" \
  DG_AUTHOR_BRIDGE_WORKSPACE="$TMP" \
  DOSSIER_BUILDER_PROMPT_PATH="$BUILDER_PROMPT" \
  bash "$BRIDGE" <<<"not json" >/dev/null 2>&1
RC=$?
[[ "$RC" -eq 2 ]] && ok "non-json stdin rc=2" || bad "non-json stdin rc=$RC (want 2)"

# T6 missing claude binary
CLAUDE_BIN="/nonexistent-claude-bin" \
  DG_AUTHOR_BRIDGE_WORKSPACE="$TMP" \
  DOSSIER_BUILDER_PROMPT_PATH="$BUILDER_PROMPT" \
  bash "$BRIDGE" <<<"$GI" >/dev/null 2>&1
RC=$?
[[ "$RC" -eq 2 ]] && ok "missing claude rc=2" || bad "missing claude rc=$RC (want 2)"

echo ""
echo "── PART B — end-to-end via dg__author ────────────────────────────────"

# Source dg__author. The lib uses set -euo pipefail; source it in a guarded
# context so a top-level fail does not nuke the test.
( source "$DG_LIB" 2>/dev/null
  export DG_AUTHOR_CMD="$BRIDGE"
  export DG_AUTHOR_TIMEOUT_SEC=60
  export DG_AUTHOR_BRIDGE_WORKSPACE="$TMP"
  export CLAUDE_BIN="$TMP/fake-claude-ok.sh"
  export DOSSIER_BUILDER_PROMPT_PATH="$BUILDER_PROMPT"
  OUT="$(dg__author "$GI" 2>/dev/null)"; RC=$?
  if [[ "$RC" -eq 0 ]] \
     && [[ "$(printf '%s' "$OUT" | jq -r '.body.authored_by')" == "agent" ]] \
     && [[ "$(printf '%s' "$OUT" | jq -r '.body.authored_by_reason')" == "agent_ok" ]]; then
    exit 0
  fi
  echo "OUT=$OUT" >&2
  exit 1
) && ok "dg__author + bridge stamps authored_by=agent / reason=agent_ok" \
  || bad "dg__author + bridge did NOT stamp authored_by=agent"

# Failure-path: refusal should fall through to the jq fallback with
# authored_by="fallback" (per dg__author's classification logic).
( source "$DG_LIB" 2>/dev/null
  export DG_AUTHOR_CMD="$BRIDGE"
  export DG_AUTHOR_TIMEOUT_SEC=60
  export DG_AUTHOR_BRIDGE_WORKSPACE="$TMP"
  export CLAUDE_BIN="$TMP/fake-claude-refuse.sh"
  export DOSSIER_BUILDER_PROMPT_PATH="$BUILDER_PROMPT"
  OUT="$(dg__author "$GI" 2>/dev/null)"; RC=$?
  if [[ "$RC" -eq 0 ]] \
     && [[ "$(printf '%s' "$OUT" | jq -r '.body.authored_by')" == "fallback" ]]; then
    exit 0
  fi
  echo "OUT=$OUT" >&2
  exit 1
) && ok "dg__author + bridge refusal falls through to jq with authored_by=fallback" \
  || bad "dg__author + bridge refusal did NOT fall through correctly"

echo ""
echo "── PART C — runner wiring (drift catch) ──────────────────────────────"

# The runner must export DG_AUTHOR_CMD inside the sr_route_stuck command
# substitution subshell. Grep the load-bearing markers.
grep -q 'dg-author-bridge.sh' "$RUNNER" \
  && ok "runner resolves the bridge path" \
  || bad "runner does NOT reference dg-author-bridge.sh"

# Loosened — semantic is "DG_AUTHOR_CMD is exported", not "via a specific
# helper-var name". The structural scoping check below carries the
# load-bearing assertion.
grep -qE '^[[:space:]]*export DG_AUTHOR_CMD=' "$RUNNER" \
  && ok "runner exports DG_AUTHOR_CMD" \
  || bad "runner does NOT export DG_AUTHOR_CMD"

grep -q 'export DG_AUTHOR_TIMEOUT_SEC' "$RUNNER" \
  && ok "runner bumps DG_AUTHOR_TIMEOUT_SEC (90s default is below builder's typical runtime)" \
  || bad "runner does NOT bump DG_AUTHOR_TIMEOUT_SEC"

grep -q 'export DG_AUTHOR_BRIDGE_WORKSPACE' "$RUNNER" \
  && ok "runner exports DG_AUTHOR_BRIDGE_WORKSPACE" \
  || bad "runner does NOT export DG_AUTHOR_BRIDGE_WORKSPACE"

# The exports must be inside the sr_route_stuck command substitution subshell
# (so they don't leak). Approximate: the exports appear between SR_DID="$( and
# the matching sr_route_stuck call.
awk '
  /SR_DID="\$\(/ { in_block=1 }
  in_block && /sr_route_stuck/ { in_block=0; found_call=1 }
  in_block && /export DG_AUTHOR_CMD=/ { found_export=1 }
  END { exit !(found_export && found_call) }
' "$RUNNER" \
  && ok "DG_AUTHOR_CMD export is inside the sr_route_stuck subshell (scoped, not leaked)" \
  || bad "DG_AUTHOR_CMD export is NOT correctly scoped to sr_route_stuck subshell"

echo ""
echo "════════════════════════════════════════════════════════════════════════"
printf "  RESULT: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "════════════════════════════════════════════════════════════════════════"
exit "$FAIL"
