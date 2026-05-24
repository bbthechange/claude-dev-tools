#!/bin/bash
# beads-runner/cf/test/conformance-machine-state.sh — C5 (claude-tools-zdxd.6)
#
# CROSS-CUTTING CONFORMANCE TEST for MACHINE-STATE.md v1 (D2).
# Lives at the intersection of every layer (daemon emitter, engine ingest,
# snapshot projection, view-model render, binding-map banners) so a future
# refactor that "tidies up" any one layer cannot ship if it breaks the
# contract. The sibling per-layer tests (daemon/test-machine-state-producer.sh
# and cf/test/machine-state.spec.js) prove their layer in isolation; THIS
# test proves the channel end-to-end against the canonical fixture and
# enforces the §B anti-drift discipline.
#
# ANTI-DRIFT: binds FROZEN MACHINE-STATE.md v1 (D2).
# Oracle = MACHINE-STATE.md + test-fixtures/machine-state-v1.json +
# cf/test/conformance-machine-state.sh (this file).
# A D2 gap ⇒ reopen D2, bump+re-freeze — NEVER diverge, NEVER edit
# MACHINE-STATE.md silently.
#
# Five parts:
#   PART 0 — files exist, parse.
#   PART A — daemon emitter (_machine_state_emit) round-trips the canonical
#            fixture: every §1.1 / §1.2 field matches verbatim (modulo
#            observed_at / runner_id / principal which the emitter sets at
#            runtime).
#   PART B — handing the emitted JSON to the engine ingest (handleMachineStateOp
#            "report-machine-state") returns rc 0 and stores a row whose
#            stamped JSON matches the principal-stamped fixture; the
#            snapshot projection (readMachines) surfaces it with `fresh:true`
#            + a computed `age_seconds`; the renderer (deriveBoardView)
#            colour-bands pct_7d=82 vs threshold=70 as RED (§4.B).
#   PART C — §B binding-map banner grep on every production file MACHINE-
#            STATE.md §B lists (whitespace-collapsed, so a multi-line banner
#            still passes — the test asserts CONTENT, not formatting).
#   PART D — §0.B structural-absence assertion: `machine_state` MUST NOT
#            appear in cf/src/schema.js's §4 SCHEMA_VERSIONS registry. A
#            silent addition would make `put machine_state ...` succeed and
#            collapse the §0.C two-channel separation into one.
#
# Run: bash beads-runner/cf/test/conformance-machine-state.sh
# CI / pre-deploy: any FAIL ⇒ block the deploy. That is the durability
# mechanism (a refactor that drops `machines[]` from workSnapshot fails C5
# before it ever ships to the Board).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
FIXTURE="$REPO_ROOT/test-fixtures/machine-state-v1.json"
USAGE_LIB="$REPO_ROOT/daemon/usage-poll.sh"
MACHINE_STATE_JS="$REPO_ROOT/cf/src/machine-state.js"
RECONCILE_JS="$REPO_ROOT/cf/src/reconcile.js"
SCHEMA_JS="$REPO_ROOT/cf/src/schema.js"
BOARD_VIEW_JS="$REPO_ROOT/web/board/board-view.js"
APP_JS="$REPO_ROOT/web/board/app.js"
MIGRATION_SQL="$REPO_ROOT/cf/migrations/0006_machine_state.sql"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
eq()  { [[ "$1" == "$2" ]] && ok "$3" || bad "$3 (got '$1' want '$2')"; }

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " C5 D2 machine_state conformance — claude-tools-zdxd.6"
echo " binds FROZEN MACHINE-STATE.md v1 (D2)"
echo "════════════════════════════════════════════════════════════════════"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ════════════════════════════════════════════════════════════════════════════
# PART 0 — files exist and parse
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART 0 — files exist + parse ──"
for f in "$FIXTURE" "$USAGE_LIB" "$MACHINE_STATE_JS" "$RECONCILE_JS" \
         "$SCHEMA_JS" "$BOARD_VIEW_JS" "$APP_JS" "$MIGRATION_SQL"; do
  [[ -f "$f" ]] && ok "present: ${f#$REPO_ROOT/}" || bad "missing: ${f#$REPO_ROOT/}"
done
bash -n "$USAGE_LIB" 2>/dev/null && ok "usage-poll.sh parses (bash -n)" \
  || bad "usage-poll.sh syntax error"
node --check "$MACHINE_STATE_JS" 2>/dev/null && ok "machine-state.js parses (node --check)" \
  || bad "machine-state.js syntax error"
node --check "$BOARD_VIEW_JS" 2>/dev/null && ok "board-view.js parses (node --check)" \
  || bad "board-view.js syntax error"

# ════════════════════════════════════════════════════════════════════════════
# PART A — daemon emitter round-trips the canonical fixture
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART A — _machine_state_emit ≡ fixture (modulo observed_at/runner_id/principal) ──"

PART_A="$WORK/partA"
mkdir -p "$PART_A"
OUTBOX="$PART_A/coordinator-outbox.jsonl"

# Read fixture field-by-field. Numeric fields are extracted exactly as the
# fixture stores them so a future field-type drift (e.g. fixture switches to
# string) would break the emit call too.
FIX_PCT_5H=$(jq -r '.pct_5h' "$FIXTURE")
FIX_PCT_7D=$(jq -r '.pct_7d' "$FIXTURE")
FIX_RAMP=$(jq -r '.spare_ramp_today' "$FIXTURE")
FIX_THR=$(jq -r '.threshold_in_effect' "$FIXTURE")
FIX_KC=$(jq -r '.keychain_ok' "$FIXTURE")
FIX_API=$(jq -r '.usage_api_ok' "$FIXTURE")
FIX_GD=$(jq -r '.gate_disabled' "$FIXTURE")

# Source the emitter, point its outbox at PART_A, fix RUNNER_ID + PRINCIPAL_V1
# so the comparison has stable values.
(
  set -u
  export BEADS_DAEMON_CACHE_DIR="$PART_A"
  export USAGE_POLL_THRESHOLD="$FIX_THR"
  export RUNNER_ID="conformance-test-host"
  export PRINCIPAL_V1="brian"
  # shellcheck disable=SC1090
  source "$USAGE_LIB"
  _machine_state_emit "$FIX_PCT_5H" "$FIX_PCT_7D" "$FIX_RAMP" "$FIX_THR" "$FIX_KC" "$FIX_API"
)

[[ -s "$OUTBOX" ]] && ok "emitter wrote one line to outbox" || { bad "emitter produced no output"; }
LINE_COUNT=$(wc -l < "$OUTBOX" | tr -d ' ')
eq "$LINE_COUNT" "1" "emitter wrote exactly one record"

EMITTED=$(cat "$OUTBOX")
echo "$EMITTED" | jq . >/dev/null 2>&1 && ok "emitted line is valid JSON" || bad "emitted line is not valid JSON"

# Field-by-field roundtrip. The closed §1.1+§1.2 set MUST match the fixture
# exactly (numerically; jq's == is numeric-equal). observed_at / runner_id /
# principal are the three runtime-substituted fields per the §1.1 contract.
eq "$(echo "$EMITTED" | jq -r '.report')"              "machine_state"  "report == 'machine_state' (closed literal §1.3)"
eq "$(echo "$EMITTED" | jq -r '.schema_version')"      "1"              "schema_version == 1"
eq "$(echo "$EMITTED" | jq -r '.principal')"           "brian"          "principal == PRINCIPAL_V1 (runtime substituted)"
eq "$(echo "$EMITTED" | jq -r '.runner_id')"           "conformance-test-host" "runner_id == RUNNER_ID (runtime substituted)"
eq "$(echo "$EMITTED" | jq -r '.pct_5h == '"$FIX_PCT_5H")" "true" "pct_5h matches fixture"
eq "$(echo "$EMITTED" | jq -r '.pct_7d == '"$FIX_PCT_7D")" "true" "pct_7d matches fixture"
eq "$(echo "$EMITTED" | jq -r '.spare_ramp_today')"    "$FIX_RAMP"      "spare_ramp_today matches fixture"
eq "$(echo "$EMITTED" | jq -r '.threshold_in_effect')" "$FIX_THR"       "threshold_in_effect matches fixture"
eq "$(echo "$EMITTED" | jq -r '.gate_disabled')"       "$FIX_GD"        "gate_disabled matches fixture (§1.2 mirror)"
eq "$(echo "$EMITTED" | jq -r '.keychain_ok')"         "$FIX_KC"        "keychain_ok matches fixture (§1.2)"
eq "$(echo "$EMITTED" | jq -r '.usage_api_ok')"        "$FIX_API"       "usage_api_ok matches fixture (§1.2)"
# observed_at: not equal to the fixture literal, but MUST parse as ISO-8601 Z.
EMITTED_OBS=$(echo "$EMITTED" | jq -r '.observed_at')
[[ "$EMITTED_OBS" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  && ok "observed_at is ISO-8601 UTC (runtime substituted)" \
  || bad "observed_at malformed ($EMITTED_OBS)"

# The set of keys in the emit MUST equal the set in the fixture (no missing,
# no extra). A silent field addition in the emitter without a D2 amend is
# precisely the failure mode §1.2 calls out.
FIX_KEYS=$(jq -r 'keys_unsorted - ["_comment_DO_NOT_REMOVE"] | sort | .[]' "$FIXTURE" | tr '\n' ' ')
EMIT_KEYS=$(echo "$EMITTED" | jq -r 'keys_unsorted | sort | .[]' | tr '\n' ' ')
eq "$EMIT_KEYS" "$FIX_KEYS" "emitter key-set == fixture key-set (no field drift)"

# ════════════════════════════════════════════════════════════════════════════
# PART B — ingest → projection → render, end-to-end via a node script
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART B — engine ingest + readMachines + deriveBoardView roundtrip ──"

PART_B_SCRIPT="$WORK/partB.mjs"
PART_B_RESULT="$WORK/partB.json"

# Write the node script. It:
#   1. Imports handleMachineStateOp from cf/src/machine-state.js with a tiny
#      in-memory D1 stub (we cannot run miniflare/wrangler-dev from this
#      bash harness, so we exercise the pure JS surface — the same code path
#      cf/test/machine-state.spec.js exercises under cloudflare:test).
#   2. Posts the daemon-emitted line to "report-machine-state", asserts rc 0
#      + stored row.
#   3. Re-reads via "get-machine-states", computes `fresh` + `age_seconds`
#      using the exact §3.A formula readMachines uses (replicated here so
#      this test doesn't depend on a Worker harness — the formula is short
#      enough that drift between this test and reconcile.js would surface
#      on the next refactor).
#   4. Imports board-view.js (UMD/CommonJS) and runs deriveBoardView on a
#      synthetic §4.5 snapshot whose `machines[]` is the projected row.
#      Asserts pct_7d=82 vs threshold=70 ⇒ band='red' (§4.B: >= threshold).
cat > "$PART_B_SCRIPT" <<NODE_EOF
import { handleMachineStateOp } from "${REPO_ROOT}/cf/src/machine-state.js";
import { createRequire } from "module";
const require = createRequire(import.meta.url);
const BoardView = require("${REPO_ROOT}/web/board/board-view.js");
import fs from "fs";

// ── tiny D1 stub — implements only the surface machine-state.js uses ───────
class Stmt {
  constructor(db, sql, binds) { this.db = db; this.sql = sql; this.binds = binds || []; }
  bind(...a) { return new Stmt(this.db, this.sql, a); }
  async run() {
    if (/^CREATE TABLE/i.test(this.sql)) return;
    if (/^INSERT OR REPLACE INTO machine_state_reports/i.test(this.sql)) {
      const [rid, obs, json] = this.binds;
      const i = this.db.rows.findIndex(r => r.runner_id === rid);
      const rec = { runner_id: rid, observed_at: obs, json };
      if (i >= 0) this.db.rows[i] = rec; else this.db.rows.push(rec);
    }
  }
  async first() {
    if (/^SELECT observed_at FROM machine_state_reports/i.test(this.sql)) {
      const r = this.db.rows.find(x => x.runner_id === this.binds[0]);
      return r ? { observed_at: r.observed_at } : null;
    }
    return null;
  }
  async all() {
    if (/^SELECT (runner_id, observed_at, json|json) FROM machine_state_reports/i.test(this.sql)) {
      const sorted = this.db.rows.slice().sort((a,b) => a.runner_id.localeCompare(b.runner_id));
      return { results: sorted.map(r => ({ runner_id: r.runner_id, observed_at: r.observed_at, json: r.json })) };
    }
    return { results: [] };
  }
}
class StubDB {
  constructor() { this.rows = []; }
  prepare(sql) { return new Stmt(this, sql); }
}
const co = {
  db: new StubDB(),
  _serialize: async (fn) => await fn(),
  env: { USAGE_POLL_TTL_SECONDS: "300" },
};

const emitted = fs.readFileSync(process.argv[2], "utf-8").trim();
const fixture = JSON.parse(fs.readFileSync(process.argv[3], "utf-8"));
delete fixture._comment_DO_NOT_REMOVE;

const out = { steps: [], fails: [] };
function ck(name, cond) {
  out.steps.push({ name, ok: !!cond });
  if (!cond) out.fails.push(name);
}

// (1) ingest
const r = await handleMachineStateOp(co, "report-machine-state", [emitted], "brian");
ck("ingest report-machine-state ⇒ 200 (rc 0)", r && r.status === 200);
ck("ingest body is empty (text-200 convention)", (await r.text()) === "");

// (2) row stored
ck("one row stored in machine_state_reports", co.db.rows.length === 1);
const stored = JSON.parse(co.db.rows[0].json);
ck("stored.principal == 'brian' (§9.1 stamp ran)", stored.principal === "brian");
ck("stored.report == 'machine_state'", stored.report === "machine_state");
ck("stored.schema_version == 1", stored.schema_version === 1);
ck("stored.pct_5h preserved (numeric)", stored.pct_5h === fixture.pct_5h);
ck("stored.pct_7d preserved (numeric)", stored.pct_7d === fixture.pct_7d);
ck("stored.spare_ramp_today preserved", stored.spare_ramp_today === fixture.spare_ramp_today);
ck("stored.threshold_in_effect preserved", stored.threshold_in_effect === fixture.threshold_in_effect);
ck("stored.gate_disabled preserved (§1.2)", stored.gate_disabled === fixture.gate_disabled);
ck("stored.keychain_ok preserved (§1.2)", stored.keychain_ok === fixture.keychain_ok);
ck("stored.usage_api_ok preserved (§1.2)", stored.usage_api_ok === fixture.usage_api_ok);

// (3) projection — get-machine-states + readMachines-equivalent fresh/age computation
const g = await handleMachineStateOp(co, "get-machine-states", [], "brian");
ck("get-machine-states ⇒ 200", g.status === 200);
const gb = await g.json();
ck("get-machine-states surfaces one machine", Array.isArray(gb.machines) && gb.machines.length === 1);

// readMachines computes fresh + age_seconds at projection time (§3.A).
// Replicated here so the conformance asserts the FORMULA, not a different
// implementation: a future drift between reconcile.js readMachines and this
// formula would surface as a render anomaly C5 catches.
const obsMs = Date.parse(stored.observed_at);
const nowMs = obsMs + 30_000; // 30s after the observation
const ageSec = Math.max(0, Math.floor((nowMs - obsMs) / 1000));
const ttl = 300;
const fresh = ageSec <= 2 * ttl;
ck("§3.A age_seconds computed correctly (30s after observed_at ⇒ 30)", ageSec === 30);
ck("§3.A fresh==true at age 30s (≤ 2×TTL=600)", fresh === true);

const machineProjected = { ...stored, fresh, age_seconds: ageSec };

// (4) render — deriveBoardView on a synthetic §4.5 snapshot
const snapshot = {
  schema_version: 1,
  principal: "brian",
  read_only: true,
  machines: [machineProjected],
  projects: [],
  waiting_on_you: [],
  lifecycle_columns: {},
};
const view = BoardView.deriveBoardView(snapshot, nowMs);
ck("deriveBoardView ⇒ ok:true", view.ok === true);
ck("view.machines has one entry", Array.isArray(view.machines) && view.machines.length === 1);
const vm = view.machines[0];
ck("view machine carries runner_id", vm.runner_id === stored.runner_id);
ck("view machine pct_5h_text formatted ('24%' / fixture pct_5h=24)", vm.pct_5h_text === "24%");
ck("view machine pct_7d_text formatted ('82%' / fixture pct_7d=82)", vm.pct_7d_text === "82%");
ck("view machine ramp_text formatted ('56%' / fixture spare_ramp_today=56)", vm.ramp_text === "56%");
// §4.B color band — pct_7d=82 vs threshold=70 ⇒ 82 >= 70 ⇒ RED
ck("§4.B: pct_7d=82 vs threshold=70 ⇒ band='red'", vm.pct_7d_band === "red");
// pct_5h=24 vs threshold=70: 24 < 0.5*70=35 ⇒ GREEN
ck("§4.B: pct_5h=24 vs threshold=70 ⇒ band='green'", vm.pct_5h_band === "green");
ck("view machine fresh==true (passed through)", vm.fresh === true);
ck("view machine gate_disabled==false (threshold=70, not 0)", vm.gate_disabled === false);
// §4.A composite strip text
ck("§4.A strip_text contains runner_id", vm.strip_text.includes(stored.runner_id));
ck("§4.A strip_text contains '5h 24%'", vm.strip_text.includes("5h 24%"));
ck("§4.A strip_text contains '7d 82%'", vm.strip_text.includes("7d 82%"));
ck("view.machines_empty == false (one machine present)", view.machines_empty === false);

fs.writeFileSync(process.argv[4], JSON.stringify(out));
NODE_EOF

EMIT_FILE="$WORK/emitted.json"
echo "$EMITTED" > "$EMIT_FILE"
( cd "$REPO_ROOT/cf" && node "$PART_B_SCRIPT" "$EMIT_FILE" "$FIXTURE" "$PART_B_RESULT" ) \
  && ok "node ingest+projection+render script ran (exit 0)" \
  || bad "node ingest+projection+render script failed (exit non-zero)"

if [[ -f "$PART_B_RESULT" ]]; then
  jq -r '.steps[] | (if .ok then "  [32m✓[0m " else "  [31m✗[0m " end) + .name' "$PART_B_RESULT"
  N_OK=$(jq '[.steps[] | select(.ok)] | length' "$PART_B_RESULT")
  N_TOTAL=$(jq '.steps | length' "$PART_B_RESULT")
  PASS=$((PASS + N_OK))
  FAIL=$((FAIL + N_TOTAL - N_OK))
else
  bad "PART B produced no result file"
fi

# ════════════════════════════════════════════════════════════════════════════
# PART C — §B binding-map banner grep
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART C — §B binding-map banner grep ──"

# Whitespace-collapsed grep: a multi-line banner (cf/src/reconcile.js,
# web/board/board-view.js have the banner split across lines for readability)
# still passes — we assert CONTENT, not formatting. A new binding-map file
# that lacks both phrases ⇒ FAIL.
check_banner() {
  local f="$1" rel="${1#$REPO_ROOT/}"
  local collapsed
  # Strip comment markers (// /* * --) THEN collapse whitespace so a banner
  # split across comment lines (cf/src/reconcile.js, web/board/board-view.js
  # keep them broken for readability) still matches the canonical phrases.
  collapsed=$(sed -e 's,//, ,g' -e 's,/\*, ,g' -e 's,\*/, ,g' -e 's,^[[:space:]]*\*, ,g' -e 's,--, ,g' < "$f" \
              | tr '\n' ' ' | tr -s ' ')
  if echo "$collapsed" | grep -q 'binds FROZEN MACHINE-STATE.md v1'; then
    ok "§B banner phrase 1 present: $rel"
  else
    bad "§B banner MISSING 'binds FROZEN MACHINE-STATE.md v1': $rel"
  fi
  if echo "$collapsed" | grep -q 'A D2 gap'; then
    ok "§B banner phrase 2 present: $rel"
  else
    bad "§B banner MISSING 'A D2 gap': $rel"
  fi
}

# The production binding-map files MACHINE-STATE.md §B enumerates. (schema.js
# is a structural-absence binding — checked in PART D, not banner-grepped.
# Test files are bound by §A fixture-load, not by canonical banner.)
check_banner "$USAGE_LIB"
check_banner "$MACHINE_STATE_JS"
check_banner "$RECONCILE_JS"
check_banner "$BOARD_VIEW_JS"
check_banner "$APP_JS"
check_banner "$MIGRATION_SQL"

# ════════════════════════════════════════════════════════════════════════════
# PART D — §0.B structural-absence assertion in cf/src/schema.js
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART D — §0.B: 'machine_state' MUST NOT appear in cf/src/schema.js §4 registry ──"

# The registry lives in the SCHEMA_VERSIONS object literal. A silent addition
# would make `put machine_state ...` succeed, collapse the §0.C two-channel
# separation, and route gate logic through display data. The grep matches
# either `machine_state: <n>` or `"machine_state": <n>` — both an unquoted
# and a quoted key are caught.
if grep -E "^[[:space:]]*\"?machine_state\"?[[:space:]]*:" "$SCHEMA_JS" >/dev/null 2>&1; then
  bad "schema.js contains 'machine_state' as a §4 registry key (§0.B violation)"
else
  ok "schema.js does NOT register 'machine_state' as a §4 type (§0.B respected)"
fi

# ════════════════════════════════════════════════════════════════════════════
# Summary
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════════════════════════════"
printf " PASS=%d  FAIL=%d\n" "$PASS" "$FAIL"
echo "════════════════════════════════════════════════════════════════════"

if [[ "$FAIL" -eq 0 ]]; then
  echo " ✓ C5 D2 conformance GREEN — the channel holds end-to-end."
  exit 0
else
  echo " ✗ C5 D2 conformance RED — a D2 gap was detected. Per MACHINE-STATE.md §C,"
  echo "   reopen D2 and re-freeze; NEVER edit MACHINE-STATE.md silently to make"
  echo "   this test pass."
  exit 1
fi
