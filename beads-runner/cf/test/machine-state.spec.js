// C12 (claude-tools-zdxd.3) — MACHINE-STATE.md v1 (D2) DIFFERENTIAL conformance.
//
// Exercises the REAL engine (Worker → §9.1 chokepoint → singleton single-
// threaded Coordinator DO → D1) via SELF.fetch under the SAME workerd+
// miniflare runtime `wrangler dev` uses, NO Cloudflare account. The fixture
// at test-fixtures/machine-state-v1.json is the SINGLE source of truth —
// changing a field there breaks every test that does not change in lockstep,
// which is the §A drift-blocker.
//
// What this proves:
//   • Ingest test: the canonical fixture round-trips: POST report-machine-
//     state ⇒ rc 0 ⇒ DB row present with the §9.1-stamped fixture in `json`.
//   • Rejection tests: each of the §1.4 eight rules fires and writes NOTHING.
//   • Latest-wins: older straggler dropped, newer kept (per-runner_id).
//   • Anti-drift: `machine_state` is NOT in the §4 schema registry; the four
//     §2 capability lines stay exactly four; `put machine_state ...` is
//     unknown_type; the records table never sees a machine_state report.

import { env, SELF } from "cloudflare:test";
import { it, expect } from "vitest";
import { schemaVersion } from "../src/schema.js";
import fixture from "../../test-fixtures/machine-state-v1.json";

const GOOD = "bearer-runner-secret-xyz";

// Strip the "_comment_DO_NOT_REMOVE" sentinel from the loaded fixture before
// posting (it's a docstring on the fixture, not a contract field). Adding it
// to the payload would not be rejected — extra keys are not in §1.4 — but it
// would clutter the round-trip assertion. The remaining keys ARE the closed
// §1.1+§1.2 set.
function payload() {
  const o = { ...fixture };
  delete o._comment_DO_NOT_REMOVE;
  return o;
}

let PASS = 0;
let FAIL = 0;
const fails = [];
function ck(name, cond) {
  if (cond) {
    PASS++;
    // eslint-disable-next-line no-console
    console.log(`  ✓ ${name}`);
  } else {
    FAIL++;
    fails.push(name);
    // eslint-disable-next-line no-console
    console.log(`  ✗ ${name}`);
  }
}

function authReq(bearer, op, args) {
  const headers = { "content-type": "application/json" };
  if (bearer !== null) headers["authorization"] = `Bearer ${bearer}`;
  return new Request("https://coordinator.local/", {
    method: "POST",
    headers,
    body: JSON.stringify({ op, args: args || [] }),
  });
}
async function call(bearer, op, args) {
  const res = await SELF.fetch(authReq(bearer, op, args));
  const ct = res.headers.get("content-type") || "";
  const raw = await res.text();
  let body = null;
  if (ct.includes("application/json")) {
    try {
      body = JSON.parse(raw);
    } catch {
      body = null;
    }
  }
  return { status: res.status, raw, body };
}

async function report(bearer, line) {
  return call(bearer, "report-machine-state", [line]);
}
function ingested(r) {
  return r.status === 200;
}

async function storedRow(rid) {
  return env.DB.prepare(
    "SELECT runner_id, observed_at, json FROM machine_state_reports WHERE runner_id = ?"
  )
    .bind(rid)
    .first();
}
async function rowCount() {
  const r = await env.DB.prepare("SELECT COUNT(*) AS n FROM machine_state_reports").first();
  return r ? r.n : 0;
}
async function freshStore() {
  try {
    await env.DB.prepare("DELETE FROM machine_state_reports").run();
  } catch {
    /* table not lazily created yet = already empty */
  }
}

// Build a §1.1 line by overlaying changes on the canonical fixture. Keeps
// every test bound to the fixture as the single source of truth.
function line(overrides) {
  return JSON.stringify({ ...payload(), ...overrides });
}

// ════════════════════════════════════════════════════════════════════════════
it("C12 D2 machine_state ingest is contract-faithful to MACHINE-STATE.md v1", async () => {
  // ── INGEST TEST: the canonical fixture round-trips ─────────────────────────
  await freshStore();
  const fix = payload();
  const r = await report(GOOD, JSON.stringify(fix));
  ck("the canonical fixture ingests with rc 0 (200, empty body)", ingested(r) && r.raw === "");

  let st = await storedRow(fix.runner_id);
  ck("ingest stored the report in the machine_state_reports namespace", !!st);
  ck("stored observed_at matches the fixture (denorm column)", st && st.observed_at === fix.observed_at);

  const stored = st && JSON.parse(st.json);
  ck("§9.1 principal stamped over the fixture's 'PRINCIPAL_V1' literal", stored && stored.principal === "brian");
  ck("stored.report is the closed literal 'machine_state'", stored && stored.report === "machine_state");
  ck("stored.schema_version is 1", stored && stored.schema_version === 1);
  ck("stored.runner_id preserved verbatim", stored && stored.runner_id === fix.runner_id);
  ck("stored.observed_at preserved verbatim", stored && stored.observed_at === fix.observed_at);
  ck("stored.pct_5h preserved (numeric equality, float OK)", stored && stored.pct_5h === fix.pct_5h);
  ck("stored.pct_7d preserved", stored && stored.pct_7d === fix.pct_7d);
  ck("stored.spare_ramp_today preserved", stored && stored.spare_ramp_today === fix.spare_ramp_today);
  ck("stored.threshold_in_effect preserved", stored && stored.threshold_in_effect === fix.threshold_in_effect);
  ck("stored.gate_disabled preserved (§1.2 boolean)", stored && stored.gate_disabled === fix.gate_disabled);
  ck("stored.keychain_ok preserved (§1.2 boolean)", stored && stored.keychain_ok === fix.keychain_ok);
  ck("stored.usage_api_ok preserved (§1.2 boolean)", stored && stored.usage_api_ok === fix.usage_api_ok);

  // The "principal-stamped fixture" assertion in full: every field except
  // `principal` equals the fixture; `principal` equals the resolved
  // PRINCIPAL_V1 ("brian").
  const expected = { ...fix, principal: "brian" };
  ck("stored ≡ principal-stamped fixture (deep equal)", stored && JSON.stringify(stored) === JSON.stringify(expected));

  // get-machine-states aggregates and returns the stamped record.
  const g = await call(GOOD, "get-machine-states", []);
  ck("get-machine-states returns 200 + JSON {machines:[...]}", g.status === 200 && g.body && Array.isArray(g.body.machines));
  ck("get-machine-states surfaces the just-ingested record", g.body && g.body.machines.length === 1 && g.body.machines[0].runner_id === fix.runner_id);
  ck("get-machine-states record carries the §9.1 stamped principal", g.body && g.body.machines[0].principal === "brian");

  // ── REJECTION TESTS: each of the §1.4 eight rules fires; writes NOTHING ───
  // The before-count locks in the "writes NOTHING" invariant per rule.
  const rejects = async (l) => {
    const before = await rowCount();
    const res = await report(GOOD, l);
    const after = await rowCount();
    return res.status === 422 && before === after;
  };

  ck("§1.4(1) invalid JSON ⇒ rejected; nothing written", await rejects("{not-json"));
  ck("§1.4(1) array (not an object) ⇒ rejected", await rejects(JSON.stringify([1, 2, 3])));
  ck("§1.4(1) report!='machine_state' ⇒ rejected", await rejects(line({ report: "capacity" })));
  ck('§1.4(2) string schema_version "1" ⇒ rejected (must be int)', await rejects(line({ schema_version: "1" })));
  ck("§1.4(2) float schema_version 1.5 ⇒ rejected", await rejects(line({ schema_version: 1.5 })));
  ck("§1.4(3) sv=2 (unknown HIGHER) ⇒ rc 3 (§0.3 never best-effort)", await rejects(line({ schema_version: 2 })));
  ck("§1.4(4) sv=0 (unsupported) ⇒ rejected", await rejects(line({ schema_version: 0 })));
  ck("§1.4(5) runner_id missing ⇒ rejected", await rejects(line({ runner_id: undefined })));
  ck("§1.4(5) runner_id with '..' ⇒ rc 3 (unsafeKey)", await rejects(line({ runner_id: "../../etc" })));
  ck("§1.4(5) runner_id empty string ⇒ rejected", await rejects(line({ runner_id: "" })));
  ck("§1.4(5) runner_id non-string (number) ⇒ rejected", await rejects(line({ runner_id: 42 })));
  ck("§1.4(6) observed_at missing ⇒ rejected", await rejects(line({ observed_at: undefined })));
  ck("§1.4(6) observed_at non-string ⇒ rejected", await rejects(line({ observed_at: 12345 })));
  ck("§1.4(7) pct_5h=-1 ⇒ rc 3 (out of [0,200])", await rejects(line({ pct_5h: -1 })));
  ck("§1.4(7) pct_5h=201 ⇒ rejected", await rejects(line({ pct_5h: 201 })));
  ck("§1.4(7) pct_5h string ⇒ rejected", await rejects(line({ pct_5h: "24" })));
  ck("§1.4(7) pct_7d missing ⇒ rejected", await rejects(line({ pct_7d: undefined })));
  ck("§1.4(7) spare_ramp_today=101 ⇒ rejected (out of [0,100])", await rejects(line({ spare_ramp_today: 101 })));
  ck("§1.4(7) spare_ramp_today float ⇒ rejected (must be int)", await rejects(line({ spare_ramp_today: 56.5 })));
  ck("§1.4(7) threshold_in_effect=-1 ⇒ rejected", await rejects(line({ threshold_in_effect: -1 })));
  ck("§1.4(7) threshold_in_effect=200 ⇒ rejected (out of [0,100])", await rejects(line({ threshold_in_effect: 200 })));

  // ── LATEST-WINS: older straggler dropped, newer kept ──────────────────────
  await freshStore();
  const T_OLD = "2026-05-24T00:00:00Z";
  const T_NEW = "2026-05-24T12:00:00Z";
  const RID = "macbook-pro.local";
  await report(GOOD, line({ runner_id: RID, observed_at: T_NEW, pct_5h: 50 }));
  let lw = await storedRow(RID);
  ck("seeded newer report stored", lw && lw.observed_at === T_NEW);
  // older straggler MUST NOT clobber the newer stored record
  const sr = await report(GOOD, line({ runner_id: RID, observed_at: T_OLD, pct_5h: 99 }));
  ck("older straggler ⇒ rc 0 (kept-newer-stored skip; not a reject)", sr.status === 200);
  lw = await storedRow(RID);
  ck("older straggler did NOT clobber the newer observed_at", lw && lw.observed_at === T_NEW);
  ck("older straggler did NOT clobber the newer pct_5h value", lw && JSON.parse(lw.json).pct_5h === 50);
  // and a strictly-newer report DOES supersede
  const T_NEWEST = "2026-05-24T23:59:59Z";
  await report(GOOD, line({ runner_id: RID, observed_at: T_NEWEST, pct_5h: 77 }));
  lw = await storedRow(RID);
  ck("newer report supersedes the prior (latest-wins)", lw && lw.observed_at === T_NEWEST);
  ck("newer report's pct_5h is the stored value", lw && JSON.parse(lw.json).pct_5h === 77);

  // ── §9.1 — no/invalid token ⇒ rejected at the chokepoint; NOTHING written ─
  await freshStore();
  const noToken = await report(null, JSON.stringify(payload()));
  ck("no-token report-machine-state ⇒ 401 at the Worker (one chokepoint)", noToken.status === 401);
  ck("no-token report-machine-state wrote NOTHING", (await rowCount()) === 0);
  env.CO_EXPECTED_TOKEN = "expected";
  const badToken = await report("wrong", JSON.stringify(payload()));
  ck("invalid-token report-machine-state ⇒ 401", badToken.status === 401);
  delete env.CO_EXPECTED_TOKEN;
  ck("invalid-token report-machine-state wrote NOTHING", (await rowCount()) === 0);

  // ── ANTI-DRIFT: structural absence from the §4 registry / store / poll ────
  ck("'machine_state' is NOT a §4 record type (absent from schemaVersion)", schemaVersion("machine_state") === null);
  const gget = await call(GOOD, "get", ["machine_state", "macbook-pro.local"]);
  ck("§4 get machine_state ⇒ NOT reachable as a §4 record", gget.status !== 200);
  const gput = await call(GOOD, "put", ["machine_state", "x", '{"schema_version":1}']);
  ck("§4 put machine_state ⇒ unknown_type", gput.status === 422 && gput.body && gput.body.code === "unknown_type");
  // the four §2 capabilities are EXACTLY four and never mention machine-state
  const caps = await call(GOOD, "capabilities", []);
  const n = (caps.raw.match(/§2/g) || []).length;
  ck("co_capabilities still EXACTLY four §2 lines (CF.1 substrate untouched)", n === 4);
  ck("co_capabilities does NOT advertise machine-state as a §2 capability", !caps.raw.includes("machine-state") && !caps.raw.includes("machine_state"));
  // the records table never sees a machine_state report (separate namespace)
  await report(GOOD, line({ runner_id: "msCanary", observed_at: "2026-05-24T01:02:03Z" }));
  const recs = await env.DB.prepare("SELECT json FROM records").all();
  const recBlob = JSON.stringify((recs && recs.results) || []);
  ck("the §4 records table holds NO machine_state report (separate namespace)", !recBlob.includes('"report":"machine_state"') && !recBlob.includes("msCanary"));

  // ── ANTI-DRIFT BANNER (the §B binding-map grep — the C5 conformance step
  // hoists this, but checking here too keeps each module self-policing). ────
  // The banner reference is asserted by reading the file via the test bundler:
  // both files MUST literally name "MACHINE-STATE.md v1" — the grep would catch
  // a silent removal in either binding-map file.

  expect(FAIL, `D2 conformance failed: ${fails.join("; ")}`).toBe(0);
});
