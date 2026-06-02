#!/bin/bash
# beads-runner/cf/test/conformance-contract-v2.sh — TEST-INFRA (claude-tools-rznj.2)
#
# THE UX-v2 CONTRACT-CONFORMANCE HARNESS (Contracts A–D guardian).
# TESTING-STRATEGY.md §7.3. Modelled on cf/test/conformance-machine-state.sh:
# a single cross-cutting test that lives at the intersection of every layer so a
# future "tidy-up" of one layer cannot ship if it breaks a frozen seam. The
# whole point of UX-V2-ARCHITECTURE.md is to STOP drift; this test is what makes
# drift FAIL instead of shipping silently (the 4xe/2dk/bgw/56h/qxz bug family).
#
# ANTI-DRIFT: binds FROZEN UX-V2-ARCHITECTURE.md (the A–D contracts) and its
# §5.2 closed-enum spec. A contract gap ⇒ reopen + re-freeze the spine doc
# (explicit section + rationale + date, per its footer) — NEVER edit the doc, the
# enums, or this test silently to make it pass.
#
# Four parts (one per anti-drift risk in TESTING-STRATEGY.md §4):
#   PART 0  — files exist + parse.
#   PART A  — OP-WIRING (Contract A / A.1; prevents R3/2dk). For each op in the
#             fixture (test-fixtures/contract-a-ops-v2.json), grep EVERY layer it
#             must appear in (module *_OPS set, coordinator.js guard, Pages proxy,
#             adapter mapping, migration). A 'wired' op missing a declared layer
#             FAILS. 'planned' v2 ops are printed as guidance, not enforced —
#             each track flips its row to 'wired' when it lands.
#   PART B  — PROJECTION v2 (Contract B / A.3; prevents R2/56h). Drives the REAL
#             workSnapshot() and asserts the top-level B.1 shape it emits today
#             (dropping schema_version/read_only/machines/projects FAILS). The v2
#             per-project named sub-objects (activity/holds/queue_health/
#             blueprint_meta) are VERSION-GATED: pending while the projection is
#             at v1; the moment workSnapshot bumps schema_version past the bound,
#             every named sub-object must be present-or-honestly-degraded or this
#             FAILS ("silently dropped" = the 56h bug).
#   PART D  — ENUMS (Contract D / §5.2; prevents R4 / the gate collision). Asserts
#             web/shared/enums.js is byte-equivalent to (a) the FROZEN §5.2 closed
#             sets and (b) the matching engine constant where one exists today
#             (notification.js TIERS ≡ NOTIFICATION_TIER). Other engine mirrors
#             (activity / hold-type / liveness) are added by their tracks (I1/J2).
#   PART B.4— TOLERANCE (Contract B.4; prevents R5/4xe). Each view-model
#             (web/**/*-view.js, auto-enrolled by glob) has the single sanctioned
#             refusal — ONE integer schema gate — and NEVER re-adds a render
#             refusal (zero `throw`; degrade per-field).
#
# Run:  bash beads-runner/cf/test/conformance-contract-v2.sh
# Enrolled by run-tests.sh (claude-tools-rznj.1) via its cf/test/conformance-*.sh
# glob (TESTING-STRATEGY.md §7.1). Any FAIL ⇒ a contract drifted ⇒ block.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

FIXTURE_A="$REPO_ROOT/test-fixtures/contract-a-ops-v2.json"
COORDINATOR_JS="$REPO_ROOT/cf/src/coordinator.js"
ADAPTER_JS="$REPO_ROOT/cf/pages-dev/adapter.js"
RECONCILE_JS="$REPO_ROOT/cf/src/reconcile.js"
NOTIFICATION_JS="$REPO_ROOT/cf/src/notification.js"
ACTIVITY_JS="$REPO_ROOT/cf/src/activity.js"
ENUMS_JS="$REPO_ROOT/web/shared/enums.js"

# Contract B — the projection schema_version this tree is bound to today. The
# v2 target is 2 (UX-V2-ARCHITECTURE.md B.1). When a track (J2/I2/Q1/H) bumps
# workSnapshot to 2, bump this bound IN THE SAME COMMIT — and PART B then enforces
# the full B.1 per-project shape.
PROJECTION_SCHEMA_BOUND=1
PROJECTION_SCHEMA_TARGET=2
# The §6 "one genuinely shared mutable seam" — each track owns ONE named
# sub-object in projects[]; never a loose flat field. These are what PART B
# requires present-or-degraded once the projection is at v2.
B1_SUBOBJECTS=(activity holds queue_health blueprint_meta runner_health)

PASS=0; FAIL=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
eq()   { [[ "$1" == "$2" ]] && ok "$3" || bad "$3 (got '$1' want '$2')"; }
info() { printf '  \033[36m•\033[0m %s\n' "$1"; }
plan() { printf '  \033[33m◌\033[0m %s\n' "$1"; }

# quote-aware presence: the op appears as a quoted string literal in $2.
has_quoted() { grep -qE "[\"']$1[\"']" "$2"; }

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " UX-v2 contract-conformance — claude-tools-rznj.2"
echo " binds FROZEN UX-V2-ARCHITECTURE.md (Contracts A–D)"
echo "════════════════════════════════════════════════════════════════════"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ════════════════════════════════════════════════════════════════════════════
# PART 0 — files exist + parse
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART 0 — files exist + parse ──"
for f in "$FIXTURE_A" "$COORDINATOR_JS" "$ADAPTER_JS" "$RECONCILE_JS" \
         "$NOTIFICATION_JS" "$ENUMS_JS"; do
  [[ -f "$f" ]] && ok "present: ${f#$REPO_ROOT/}" || bad "missing: ${f#$REPO_ROOT/}"
done
jq -e . "$FIXTURE_A" >/dev/null 2>&1 \
  && ok "contract-a-ops-v2.json parses (jq)" || bad "contract-a-ops-v2.json is not valid JSON"
node --check "$ENUMS_JS" 2>/dev/null \
  && ok "enums.js parses (node --check)" || bad "enums.js syntax error"
node --check "$RECONCILE_JS" 2>/dev/null \
  && ok "reconcile.js parses (node --check)" || bad "reconcile.js syntax error"
node --check "$ADAPTER_JS" 2>/dev/null \
  && ok "adapter.js parses (node --check)" || bad "adapter.js syntax error"
# enums.js must be require()-able and freeze its sets (a stray push must throw).
node -e "const E=require('$ENUMS_JS'); if(!Object.isFrozen(E.ACTIVITY_STATE)) process.exit(3);" 2>/dev/null \
  && ok "enums.js loads + its sets are frozen (closed)" \
  || bad "enums.js does not load or its sets are not Object.frozen"

# ════════════════════════════════════════════════════════════════════════════
# PART A — op-wiring conformance (Contract A.1 — the 2dk/R3 fix)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART A — op-wiring: every wired op present in every layer it needs ──"

OPS_N=$(jq '.ops | length' "$FIXTURE_A")
for i in $(seq 0 $((OPS_N - 1))); do
  op=$(jq -r ".ops[$i].op" "$FIXTURE_A")
  status=$(jq -r ".ops[$i].status" "$FIXTURE_A")
  module=$(jq -r ".ops[$i].module // \"\"" "$FIXTURE_A")
  ops_set=$(jq -r ".ops[$i].ops_set // \"\"" "$FIXTURE_A")
  guard=$(jq -r ".ops[$i].guard // \"\"" "$FIXTURE_A")
  proxy=$(jq -r ".ops[$i].proxy // \"\"" "$FIXTURE_A")
  adapter=$(jq -r ".ops[$i].adapter" "$FIXTURE_A")
  migration=$(jq -r ".ops[$i].migration // \"\"" "$FIXTURE_A")
  track=$(jq -r ".ops[$i].track" "$FIXTURE_A")

  if [[ "$status" == "planned" ]]; then
    plan "PLANNED [$track] op '$op' — not yet enforced; flip to 'wired' when it lands."
    continue
  fi

  # ── module *_OPS set (skip for a substrate-switch op: module/ops_set null) ──
  if [[ -n "$ops_set" ]]; then
    if [[ -f "$REPO_ROOT/$module" ]] && has_quoted "$op" "$REPO_ROOT/$module"; then
      ok "[$op] module: listed in $ops_set ($module)"
    else
      bad "[$op] module: NOT listed in $ops_set ($module) — A.1 step 1"
    fi
  else
    info "[$op] module: substrate-switch op (no *_OPS set — guard covers it)"
  fi

  # ── guard in coordinator.js (always required) ──
  if [[ "$guard" == "substrate" ]]; then
    if grep -qE "case \"$op\"" "$COORDINATOR_JS"; then
      ok "[$op] guard: substrate switch case in coordinator.js"
    else
      bad "[$op] guard: MISSING 'case \"$op\"' in coordinator.js — A.1 step 2"
    fi
  else
    if grep -qF "${guard}.has" "$COORDINATOR_JS"; then
      ok "[$op] guard: $guard.has dispatch in coordinator.js"
    else
      bad "[$op] guard: MISSING '$guard.has' guard in coordinator.js — A.1 step 2"
    fi
  fi

  # ── Pages proxy (required iff declared) ──
  if [[ -n "$proxy" ]]; then
    if [[ -f "$REPO_ROOT/$proxy" ]] && has_quoted "$op" "$REPO_ROOT/$proxy"; then
      ok "[$op] proxy: hard-coded in $proxy"
    else
      bad "[$op] proxy: NOT hard-coded in $proxy — A.1 step 3"
    fi
  else
    info "[$op] proxy: none (daemon-emitted / internal op — no web surface)"
  fi

  # ── adapter mapping (required iff adapter:true) ──
  if [[ "$adapter" == "true" ]]; then
    if grep -qF "op === \"$op\"" "$ADAPTER_JS"; then
      ok "[$op] adapter: op === \"$op\" mapped in pages-dev/adapter.js"
    else
      bad "[$op] adapter: MISSING 'op === \"$op\"' in adapter.js — A.1 step 4 (the layer 2dk forgot)"
    fi
  else
    info "[$op] adapter: not adapter-mapped (correct for a daemon-emitted op)"
  fi

  # ── migration (required iff declared) ──
  if [[ -n "$migration" ]]; then
    if [[ -f "$REPO_ROOT/$migration" ]]; then
      ok "[$op] migration: $migration present"
    else
      bad "[$op] migration: MISSING $migration — A.1 step 5"
    fi
  else
    info "[$op] migration: none (added no table)"
  fi
done

# ════════════════════════════════════════════════════════════════════════════
# PART B — projection v2 conformance (Contract B / A.3 — the 56h/R2 fix)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART B — workSnapshot() emits the B.1 top-level shape (live drive) ──"

PART_B_SCRIPT="$WORK/partB.mjs"
PART_B_RESULT="$WORK/partB.json"
cat > "$PART_B_SCRIPT" <<NODE_EOF
import { handleReconcileOp } from "${RECONCILE_JS}";
import fs from "fs";

// Empty-DB stub — workSnapshot's §3.C empty-state path is designed-for: no
// runner_state rows ⇒ projects:[]; no dossiers ⇒ waiting_on_you:[]; the
// machine_state_reports SELECT degrades to machines:[]. Every co.db read this
// producer makes returns an empty result, so we exercise the REAL projection
// assembly without a Worker/miniflare harness (same trick as the sibling
// conformance-machine-state.sh PART B).
function stmt() {
  const r = {
    bind() { return r; },
    async all() { return { results: [] }; },
    async first() { return null; },
    async run() {},
  };
  return r;
}
const co = { env: {}, db: { prepare() { return stmt(); } } };

const steps = [];
const ck = (name, cond) => steps.push({ name, ok: !!cond });

const res = await handleReconcileOp(co, "work-snapshot", ["", ""], "conformance");
const obj = await res.json();

// ── B.1 top-level shape — the keys the UI reads; dropping one is the 56h bug ──
ck("schema_version is an integer (§0.3 — UI gates on integer-≤-bound)", Number.isInteger(obj.schema_version));
ck("read_only === true (§4.5 producer is a pure read)", obj.read_only === true);
ck("machines is an array (§3.A peer; never absent/null — §3.C)", Array.isArray(obj.machines));
ck("projects is an array (the per-workspace strip)", Array.isArray(obj.projects));
ck("lifecycle_columns is an object (the stage ladder)", obj.lifecycle_columns && typeof obj.lifecycle_columns === "object" && !Array.isArray(obj.lifecycle_columns));
ck("waiting_on_you is an array (the Inbox lane)", Array.isArray(obj.waiting_on_you));

fs.writeFileSync(process.argv[2], JSON.stringify({ schema_version: obj.schema_version, steps }));
NODE_EOF

if ( cd "$REPO_ROOT/cf" && node "$PART_B_SCRIPT" "$PART_B_RESULT" ); then
  ok "workSnapshot() drove cleanly (exit 0)"
else
  bad "workSnapshot() live drive FAILED (exit non-zero) — see node error above"
fi

LIVE_SV=""
if [[ -f "$PART_B_RESULT" ]]; then
  jq -r '.steps[] | (if .ok then "  [32m✓[0m " else "  [31m✗[0m " end) + .name' "$PART_B_RESULT"
  N_OK=$(jq '[.steps[] | select(.ok)] | length' "$PART_B_RESULT")
  N_TOT=$(jq '.steps | length' "$PART_B_RESULT")
  PASS=$((PASS + N_OK))
  FAIL=$((FAIL + N_TOT - N_OK))
  LIVE_SV=$(jq -r '.schema_version' "$PART_B_RESULT")
else
  bad "PART B produced no result file"
fi

# ── version gate: the v2 per-project named sub-objects ──
echo ""
echo "── PART B — v2 named sub-objects (version-gated on schema_version) ──"
if [[ -z "$LIVE_SV" || "$LIVE_SV" == "null" ]]; then
  bad "could not read live schema_version — cannot evaluate the v2 sub-object gate"
elif [[ "$LIVE_SV" -le "$PROJECTION_SCHEMA_BOUND" ]]; then
  ok "projection at schema_version=$LIVE_SV (bound=$PROJECTION_SCHEMA_BOUND) — v1 baseline intact"
  plan "PENDING (target schema_version=$PROJECTION_SCHEMA_TARGET): ${B1_SUBOBJECTS[*]} — enforced once a track bumps workSnapshot to v2 (bump PROJECTION_SCHEMA_BOUND in the same commit)."
else
  info "projection bumped to schema_version=$LIVE_SV (> bound $PROJECTION_SCHEMA_BOUND) — enforcing full B.1 per-project shape"
  for key in "${B1_SUBOBJECTS[@]}"; do
    # The producer must ASSEMBLE each named sub-object into projects[] (present
    # or honestly degraded). Absence = the silent-drop / 56h bug.
    if grep -qE "(^|[^_a-zA-Z])$key\s*:" "$RECONCILE_JS"; then
      ok "[projection v$LIVE_SV] sub-object '$key' assembled in workSnapshot/reconcile.js"
    else
      bad "[projection v$LIVE_SV] sub-object '$key' SILENTLY DROPPED (R2/56h) — every B.1 named sub-object must be present or honestly degraded"
    fi
  done
fi

# ════════════════════════════════════════════════════════════════════════════
# PART D — enum conformance (Contract D / §5.2 — the R4/gate-collision fix)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART D — enums.js ≡ FROZEN §5.2  AND  ≡ the engine constant ──"

PART_D_SCRIPT="$WORK/partD.cjs"
PART_D_RESULT="$WORK/partD.json"
cat > "$PART_D_SCRIPT" <<NODE_EOF
const fs = require("fs");
const E = require("${ENUMS_JS}");

const steps = [];
const ck = (name, cond) => steps.push({ name, ok: !!cond });
const setEq = (a, b) => Array.isArray(a) && Array.isArray(b)
  && a.length === b.length
  && [...a].sort().join("") === [...b].sort().join("");

// (a) enums.js ≡ FROZEN UX-V2-ARCHITECTURE.md §5.2 closed sets. Editing enums.js
// without re-freezing the spine doc (and this oracle) is exactly the drift this
// guards. NEVER widen the oracle to make a stray enum edit pass.
const ORACLE = {
  ACTIVITY_STATE: ["writing-code","running-tests","exploring","thinking","waiting-on-you","rate-limited","maybe-stuck"],
  LIVENESS_DOT: ["green","amber","red"],
  DONE_SUBSTATE: ["done·code","done·verified"],
  NOTIFICATION_TIER: ["blocking","timed-fyi","digest"],
  HOLD_TYPE: ["gate","dependency","scheduled"],
  GATE_SCOPE: ["task","cohort"],
  STATE_CONFIDENCE: ["derived"],
};
for (const k of Object.keys(ORACLE)) {
  ck("enums.js " + k + " ≡ frozen §5.2 set", setEq(E[k], ORACLE[k]));
}
ck("enums.js LIVENESS_WINDOWS ≡ §5.2 measured 90/180", E.LIVENESS_WINDOWS
  && E.LIVENESS_WINDOWS.AMBER_AFTER_S === 90 && E.LIVENESS_WINDOWS.RED_AFTER_S === 180);

// (b) byte-equivalence with the matching ENGINE constant where one exists today.
// notification.js: \`const TIERS = ["blocking","timed-fyi","digest"];\`
const notif = fs.readFileSync("${NOTIFICATION_JS}", "utf8");
const m = notif.match(/const\s+TIERS\s*=\s*\[([^\]]*)\]/);
let engineTiers = null;
if (m) engineTiers = [...m[1].matchAll(/["']([^"']+)["']/g)].map((x) => x[1]);
ck("engine notification.js TIERS extracted", Array.isArray(engineTiers) && engineTiers.length > 0);
ck("NOTIFICATION_TIER ≡ engine notification.js TIERS (byte-equivalent sets)", setEq(E.NOTIFICATION_TIER, engineTiers));

// (b cont.) I1 (claude-tools-uxvi1) LANDED the ACTIVITY_STATE engine mirror:
// cf/src/activity.js exports the closed D.2 enum it gates ingest on. Assert it
// is byte-equivalent to enums.js ACTIVITY_STATE (which PART (a) already pinned
// to the frozen §5.2 set) — so the bash classifier, the engine, and the web
// enum cannot drift apart. Same regex-extract technique as TIERS above.
const act = fs.readFileSync("${ACTIVITY_JS}", "utf8");
const am = act.match(/ACTIVITY_STATES\s*=\s*\[([^\]]*)\]/);
let engineStates = null;
if (am) engineStates = [...am[1].matchAll(/["']([^"']+)["']/g)].map((x) => x[1]);
ck("engine activity.js ACTIVITY_STATES extracted", Array.isArray(engineStates) && engineStates.length > 0);
ck("ACTIVITY_STATE ≡ engine activity.js ACTIVITY_STATES (byte-equivalent sets)", setEq(E.ACTIVITY_STATE, engineStates));

fs.writeFileSync(process.argv[2], JSON.stringify({ steps }));
NODE_EOF

if node "$PART_D_SCRIPT" "$PART_D_RESULT" 2>"$WORK/partD.err"; then
  :
else
  bad "PART D node script errored: $(tr '\n' ' ' < "$WORK/partD.err")"
fi
if [[ -f "$PART_D_RESULT" ]]; then
  jq -r '.steps[] | (if .ok then "  [32m✓[0m " else "  [31m✗[0m " end) + .name' "$PART_D_RESULT"
  N_OK=$(jq '[.steps[] | select(.ok)] | length' "$PART_D_RESULT")
  N_TOT=$(jq '.steps | length' "$PART_D_RESULT")
  PASS=$((PASS + N_OK))
  FAIL=$((FAIL + N_TOT - N_OK))
else
  bad "PART D produced no result file"
fi
info "engine mirror ENFORCED: ACTIVITY_STATE (I1, claude-tools-uxvi1 — activity.js)."
info "engine mirrors PENDING (added by their track, then promoted to enforced): HOLD_TYPE (J2), LIVENESS_WINDOWS (I2)."

# ════════════════════════════════════════════════════════════════════════════
# PART B.4 — tolerance conformance (Contract B.4 — the 4xe/R5 fix)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART B.4 — every view-model: ONE integer schema gate, never a render refusal ──"

VIEW_MODELS=$(find "$REPO_ROOT/web" -name '*-view.js' -type f 2>/dev/null | sort)
[[ -n "$VIEW_MODELS" ]] || bad "no *-view.js found under web/ — the B.4 glob matched nothing"
while IFS= read -r vm; do
  [[ -n "$vm" ]] || continue
  rel="${vm#$REPO_ROOT/}"
  node --check "$vm" 2>/dev/null && ok "$rel parses (node --check)" || bad "$rel syntax error"

  # Tolerance: the single sanctioned refusal is the integer schema gate. A
  # `throw` in a view-model is re-adding a render refusal (4xe) — forbidden;
  # missing/malformed fields degrade per-field, they never throw.
  THROWS=$(grep -cE '\bthrow\b' "$vm")
  eq "$THROWS" "0" "$rel: zero throw (degrade per-field, never refuse a record)"

  if grep -q 'schema_version' "$vm"; then
    # The ONE integer schema gate: a SUPPORTED_*_SCHEMA bound + an unknown-higher
    # refusal (the `> SUPPORTED_` idiom, or the inbox-view schemaGate/unknownHigher).
    if grep -qE 'SUPPORTED_[A-Z_]*SCHEMA' "$vm" \
       && grep -qE '>\s*SUPPORTED_[A-Z_]*SCHEMA|unknownHigher\(|schemaGate\(' "$vm"; then
      ok "$rel: has its single integer schema gate (unknown-higher refusal)"
    else
      bad "$rel: consumes schema_version but has NO integer schema gate (B.4 single refusal point)"
    fi
  else
    info "$rel: does not consume a versioned projection — schema gate N/A (no-throw still enforced)"
  fi
done <<< "$VIEW_MODELS"

# ════════════════════════════════════════════════════════════════════════════
# Summary
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════════════════════════════"
printf " PASS=%d  FAIL=%d\n" "$PASS" "$FAIL"
echo "════════════════════════════════════════════════════════════════════"

if [[ "$FAIL" -eq 0 ]]; then
  echo " ✓ UX-v2 contracts A–D GREEN — the seams hold."
  exit 0
else
  echo " ✗ UX-v2 contract drift detected. A frozen A–D seam moved. Per"
  echo "   UX-V2-ARCHITECTURE.md: wire the missing layer (A), emit the dropped"
  echo "   projection key (B), align the enum (D), or remove the render refusal"
  echo "   (B.4) — NEVER edit the frozen doc/enums/this test to force a pass."
  exit 1
fi
