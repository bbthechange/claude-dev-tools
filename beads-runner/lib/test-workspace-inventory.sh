#!/bin/bash
# beads-runner/lib/test-workspace-inventory.sh — claude-tools-8dfb (epic
# claude-tools-vvgy) §4.6 workspace_inventory v1.
#
# This op is CF-ONLY (no bash co__workspace_inventory_put exists; the wire
# producer is the workspace runner, the consumer is the projection join +
# renderer — both separate children of vvgy). So unlike sibling
# test-coordinator-*.sh tests that source coordinator.sh and drive an
# in-process bash co_request, this test exercises the REAL DEPLOYED engine
# (Worker → §9.1 chokepoint → singleton Coordinator DO → D1) over the same
# co-http-transport.sh the runner producer will use, modelled on
# test-i2-registration.sh's three-part discipline:
#
#   PART A — STATIC: schema registry + RECONCILE_OPS membership + INTERFACE.md
#            §4.6 cross-check. Token-independent; always runs.
#   PART B — LIVE: against https://coordinator-cf.bbthechange.workers.dev
#            using the §9.2 per-workspace token from the Keychain
#            (service "claude-beads-runner.coordinator-token"). Exercises
#            every contract case in the bead (valid accept; schema rejects;
#            unknown higher version; principal stamping; overwrite semantics;
#            bounded top_n_beads; observed_at validation). SKIPs cleanly if no
#            token resolves (the by-design D0 withholding posture).
#
# The exhaustive differential is the sibling JS spec
# beads-runner/cf/test/workspace-inventory.spec.js (vitest + miniflare, 53
# assertions, NO Cloudflare account); this bash test is the LIVE-engine smoke
# the deploy gates land against and the I2-style hosted-equivalent oracle.
#
# Run:  bash beads-runner/lib/test-workspace-inventory.sh

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIVE_URL="https://coordinator-cf.bbthechange.workers.dev"
PLACEHOLDER="bearer-runner-secret-xyz"     # the bearer the libs/tests carry (I0 D0)

PASS=0; FAIL=0; SKIP=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33m∙\033[0m %s\n' "$1"; SKIP=$((SKIP+1)); }
eq()   { [[ "$1" == "$2" ]] && ok "$3" || bad "$3 (got '$1' want '$2')"; }

# ════════════════════════════════════════════════════════════════════════════
# PART A — STATIC: schema registry + RECONCILE_OPS membership + INTERFACE.md
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART A — STATIC: registry, op set, INTERFACE.md cross-check ──"

SCHEMA_JS="$ROOT/cf/src/schema.js"
RECONCILE_JS="$ROOT/cf/src/reconcile.js"
INTERFACE_MD="$ROOT/INTERFACE.md"
SPEC_JS="$ROOT/cf/test/workspace-inventory.spec.js"

if [[ -f "$SCHEMA_JS" ]] && grep -Eq '^[[:space:]]*workspace_inventory:[[:space:]]*1' "$SCHEMA_JS"; then
  ok "schema.js carries 'workspace_inventory: 1' in the §4 registry"
else
  bad "schema.js missing 'workspace_inventory: 1' (the §4 registry binds the new type)"
fi

if [[ -f "$RECONCILE_JS" ]] && grep -q '"workspace-inventory-put"' "$RECONCILE_JS"; then
  ok "reconcile.js carries 'workspace-inventory-put' in RECONCILE_OPS / dispatch"
else
  bad "reconcile.js missing 'workspace-inventory-put' (handler dispatch)"
fi

if [[ -f "$RECONCILE_JS" ]] && grep -q 'workspaceInventoryPut' "$RECONCILE_JS"; then
  ok "reconcile.js defines workspaceInventoryPut handler"
else
  bad "reconcile.js missing workspaceInventoryPut handler definition"
fi

if [[ -f "$SPEC_JS" ]]; then
  ok "sibling vitest spec exists (cf/test/workspace-inventory.spec.js)"
else
  bad "sibling vitest spec missing — the JS differential is the rigorous case-by-case oracle"
fi

if [[ -f "$INTERFACE_MD" ]] && grep -q 'workspace_inventory' "$INTERFACE_MD"; then
  ok "INTERFACE.md mentions workspace_inventory (§4.6)"
else
  bad "INTERFACE.md missing workspace_inventory (§4.6)"
fi

# ════════════════════════════════════════════════════════════════════════════
# PART B — LIVE: hosted engine, with §9.2 keychain token if available
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART B — LIVE: $LIVE_URL · §4.6 workspace_inventory v1 end-to-end ──"

# Token-aware (mirrors test-i2-registration PART A). With no token, the live
# 401 chokepoint fires BEFORE any validation runs — so the schema-rejection
# arms cannot be observed without a real token. SKIP loudly rather than
# pretending pass.
B_TOKEN=""
if [[ -n "${COORDINATOR_TOKEN:-}" ]]; then
  B_TOKEN="env"
elif security find-generic-password -s "claude-beads-runner.coordinator-token" \
       -a "$(hostname)" -w >/dev/null 2>&1; then
  B_TOKEN="keychain"
fi

if [[ -z "$B_TOKEN" ]]; then
  skip "no §9.2 token resolved (env COORDINATOR_TOKEN or Keychain) — live arms SKIPPED"
  skip "  Brian's authed runs hit the live path; CI/agent runs verify via cf/test/workspace-inventory.spec.js"
else
  echo "   token source: $B_TOKEN"

  # The HTTP transport sources cleanly under set -uo pipefail; we override
  # co_request via COORDINATOR_URL. No local-agent.sh needed (we hand-build
  # the workspace_inventory line — there is no la_report_workspace_inventory
  # yet; that's the producer child issue, not this one).
  (
    set +u
    export COORDINATOR_URL="$LIVE_URL"
    # local-agent.sh provides la_coordinator_token (the Keychain getter the
    # transport prefers). With it sourced, an unset COORDINATOR_TOKEN still
    # resolves a real bearer from the Keychain — the I2 success-posture path.
    source "$ROOT/lib/local-agent.sh"        2>/dev/null
    source "$ROOT/lib/co-http-transport.sh"  # OVERRIDE: co_request now HTTP → LIVE

    # Helpers (the bash test's `now_iso`/`make_line`, kept local — these never
    # leak into the FROZEN libs).
    now_iso()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
    # workspace_inventory wire line. Every field §4.6 v1 requires, no extras.
    # The principal literal is OVERWRITTEN by the §9.1 stamp — proven below.
    wi_line()   {  # <project_ref> [extra-jq-mutation]
      local pr="$1" mut="${2:-.}"
      jq -cn \
         --arg pr "$pr" \
         --arg at "$(now_iso)" \
         --arg rid "test-wi-runner" \
         '{report:"workspace_inventory",
           schema_version:1,
           principal:"literal-should-be-overwritten",
           runner_id:$rid,
           project_ref:$pr,
           observed_at:$at,
           counts:{open:5,ready:3,in_progress:1,blocked:1},
           in_progress_beads:[{bead_ref:($pr+"-001"),title:"smoke",stage:"impl"}],
           top_n_beads:[{bead_ref:($pr+"-001"),title:"smoke",status:"in_progress",stage:"impl"}]}' \
        | jq -c "$mut"
    }
    rejected() { ! co_request "$PLACEHOLDER" workspace-inventory-put "$1" >/dev/null 2>&1; }
    accepted() {   co_request "$PLACEHOLDER" workspace-inventory-put "$1" >/dev/null 2>&1; }

    # The deploy probe — a fresh GET to /capabilities (the §2 four-line surface)
    # confirms the worker is up + the live token authenticates BEFORE we send
    # any writes. If this fails, every later arm would falsely-fail with "live
    # arms unreachable" — exit early with a clear note.
    if ! co_request "$PLACEHOLDER" capabilities >/dev/null 2>&1; then
      bad "LIVE precondition: capabilities query failed (worker down or token invalid)"
      exit 1
    fi
    ok "LIVE precondition: capabilities query OK (worker up + token valid)"

    # Unique project_ref prefix per run so successive runs don't collide on
    # the overwrite-semantics arm (every workspace_inventory write is one row
    # per project_ref — the contract — so a fixed id would let prior runs
    # carry residual state into this one).
    RUN="wi-test-$(date +%s)"

    # ── CASE 1: Valid payload accepted; read-back matches ──────────────────
    L1="$(wi_line "${RUN}-c1")"
    if accepted "$L1"; then ok "CASE 1: valid payload accepted (200/ok)"
    else bad "CASE 1: valid payload rejected"; fi
    R1="$(co_request "$PLACEHOLDER" get workspace_inventory "${RUN}-c1" 2>/dev/null)"
    if [[ -n "$R1" ]] && [[ "$(jq -r '.schema_version' <<<"$R1")" == "1" ]]; then
      ok "CASE 1: stored row read back via get (schema_version=1)"
    else bad "CASE 1: stored row not readable (got: $(printf '%s' "$R1" | head -c 80))"; fi
    eq "$(jq -r '.project_ref' <<<"$R1")" "${RUN}-c1" "CASE 1: stored project_ref verbatim"
    eq "$(jq -r '.counts.open'        <<<"$R1")" "5" "CASE 1: counts.open verbatim"
    eq "$(jq -r '.counts.ready'       <<<"$R1")" "3" "CASE 1: counts.ready verbatim"
    eq "$(jq -r '.counts.in_progress' <<<"$R1")" "1" "CASE 1: counts.in_progress verbatim"
    eq "$(jq -r '.counts.blocked'     <<<"$R1")" "1" "CASE 1: counts.blocked verbatim"
    eq "$(jq -r '.in_progress_beads|length' <<<"$R1")" "1" "CASE 1: in_progress_beads length=1"
    eq "$(jq -r '.top_n_beads|length'       <<<"$R1")" "1" "CASE 1: top_n_beads length=1"

    # ── CASE 2: Schema validation rejects ──────────────────────────────────
    if rejected "$(wi_line "${RUN}-c2a" 'del(.counts.in_progress)')"; then
      ok "CASE 2: missing counts.in_progress ⇒ reject (422)"
    else bad "CASE 2: missing counts.in_progress NOT rejected"; fi
    if rejected "$(wi_line "${RUN}-c2b" '.counts.open = 1.5')"; then
      ok "CASE 2: non-int count (1.5) ⇒ reject"
    else bad "CASE 2: non-int count NOT rejected"; fi
    if rejected "$(wi_line "${RUN}-c2c" '.counts.open = "5"')"; then
      ok "CASE 2: string count ⇒ reject (contract value, not best-effort)"
    else bad "CASE 2: string count NOT rejected"; fi
    if rejected "$(wi_line "${RUN}-c2d" '.in_progress_beads = [{"bead_ref":"x","stage":"impl"}]')"; then
      ok "CASE 2: in_progress_beads[].title missing ⇒ reject"
    else bad "CASE 2: in_progress_beads[].title NOT rejected"; fi
    if rejected "$(wi_line "${RUN}-c2e" 'del(.top_n_beads)')"; then
      ok "CASE 2: missing top_n_beads ⇒ reject (required, may be empty)"
    else bad "CASE 2: missing top_n_beads NOT rejected"; fi

    # ── CASE 3: Unknown higher schema_version ──────────────────────────────
    if rejected "$(wi_line "${RUN}-c3" '.schema_version = 2')"; then
      ok "CASE 3: schema_version=2 ⇒ reject (§0.3, never best-effort)"
    else bad "CASE 3: higher schema_version NOT rejected"; fi

    # ── CASE 4: Principal stamping (§9.1) ───────────────────────────────────
    L4="$(wi_line "${RUN}-c4" '.principal = "malicious"')"
    if accepted "$L4"; then ok "CASE 4: payload with wire principal='malicious' accepted"
    else bad "CASE 4: payload not accepted (cannot prove stamping)"; fi
    R4="$(co_request "$PLACEHOLDER" get workspace_inventory "${RUN}-c4" 2>/dev/null)"
    eq "$(jq -r '.principal' <<<"$R4")" "brian" "CASE 4: wire principal OVERWRITTEN by §9.1 ('brian')"

    # ── CASE 5: Overwrite semantics ────────────────────────────────────────
    L5a="$(wi_line "${RUN}-c5" '.counts = {open:10,ready:5,in_progress:2,blocked:0}')"
    L5b="$(wi_line "${RUN}-c5" '.counts = {open:1,ready:1,in_progress:1,blocked:1}')"
    accepted "$L5a" || bad "CASE 5: first write failed"
    R5a="$(co_request "$PLACEHOLDER" get workspace_inventory "${RUN}-c5" 2>/dev/null)"
    eq "$(jq -r '.counts.open' <<<"$R5a")" "10" "CASE 5: first write stored (counts.open=10)"
    accepted "$L5b" || bad "CASE 5: second write failed"
    R5b="$(co_request "$PLACEHOLDER" get workspace_inventory "${RUN}-c5" 2>/dev/null)"
    eq "$(jq -r '.counts.open' <<<"$R5b")" "1" "CASE 5: second write REPLACES first (no append)"

    # ── CASE 6: Bounded top_n_beads (0/1/20/100) ────────────────────────────
    make_topn() {  # <n>
      jq -cn --argjson n "$1" \
        '[range(0;$n) | {bead_ref:("c6-"+(tostring)),title:("b"+(tostring)),status:"open",stage:"impl"}]'
    }
    for n in 0 1 20 100; do
      Ln="$(wi_line "${RUN}-c6n${n}" '.top_n_beads = '"$(make_topn "$n")")"
      if accepted "$Ln"; then ok "CASE 6: top_n_beads length $n accepted"
      else bad "CASE 6: top_n_beads length $n rejected"; fi
      Rn="$(co_request "$PLACEHOLDER" get workspace_inventory "${RUN}-c6n${n}" 2>/dev/null)"
      eq "$(jq -r '.top_n_beads|length' <<<"$Rn")" "$n" "CASE 6: top_n_beads length $n round-trips"
    done

    # ── CASE 7: observed_at validation ──────────────────────────────────────
    if rejected "$(wi_line "${RUN}-c7a" '.observed_at = "not-a-timestamp"')"; then
      ok "CASE 7: malformed observed_at ⇒ reject"
    else bad "CASE 7: malformed observed_at NOT rejected"; fi
    if rejected "$(wi_line "${RUN}-c7b" '.observed_at = "1999-01-01T00:00:00Z"')"; then
      ok "CASE 7: pre-2024 observed_at ⇒ reject (h7n-style guard)"
    else bad "CASE 7: pre-2024 observed_at NOT rejected"; fi
    if rejected "$(wi_line "${RUN}-c7c" 'del(.observed_at)')"; then
      ok "CASE 7: missing observed_at ⇒ reject (required)"
    else bad "CASE 7: missing observed_at NOT rejected"; fi

    # ── ANTI-DRIFT: no row persisted for any rejected payload ───────────────
    for id in "${RUN}-c2a" "${RUN}-c2b" "${RUN}-c2c" "${RUN}-c2d" "${RUN}-c2e" \
              "${RUN}-c3" "${RUN}-c7a" "${RUN}-c7b" "${RUN}-c7c"; do
      if ! co_request "$PLACEHOLDER" get workspace_inventory "$id" >/dev/null 2>&1; then
        ok "no row persisted on rejection for id='$id'"
      else
        bad "row persisted DESPITE rejection for id='$id'"
      fi
    done

    # ── CLEANUP: delete the test records via the substrate `del`? ──────────
    # There is no public `del` op in the §2 surface; workspace_inventory rows
    # are ONE-PER-WORKSPACE, overwritten on each write — so test runs naturally
    # collide ONLY on the fixed RUN prefix (we use $(date +%s) per run to keep
    # them distinct). The records expire naturally as a future deploy runs the
    # same RUN prefix again, or stay as bounded test residue. The bead's
    # acceptance text suggests "Clean up the test record before close (or let
    # it expire naturally)" — naturally is the chosen path here, since the
    # rows are tiny (≤ few KB) and there's no leak risk.

    echo ""
    echo "── PART B summary: $PASS passed, $FAIL failed (this subshell) ──"
    [[ "$FAIL" -eq 0 ]] || exit 1
  )
  # Propagate the subshell rc into the outer counter so the overall PASS/FAIL
  # totals reflect what happened in PART B (the subshell rc is 0 iff its arms
  # all passed; FAIL accounting is per-subshell, so we collapse to "did the
  # whole live block pass").
  if [[ "$?" -ne 0 ]]; then FAIL=$((FAIL+1)); bad "PART B had at least one failure (see above)"; fi
fi

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  test-workspace-inventory.sh: $PASS passed, $FAIL failed, $SKIP skipped"
echo "════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
