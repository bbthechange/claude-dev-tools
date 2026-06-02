// I1 (claude-tools-uxvi1) — DESIGN I §1.4 agent_activity DIFFERENTIAL conformance.
//
// Exercises the REAL engine (Worker → §9.1 chokepoint → singleton single-
// threaded Coordinator DO → D1) via SELF.fetch under the SAME workerd+miniflare
// runtime `wrangler dev` uses, NO Cloudflare account. The fixture at
// test-fixtures/agent-activity-v1.json is the SINGLE source of truth — changing
// a gated field there breaks every test that does not change in lockstep, which
// is the §A drift-blocker.
//
// What this proves:
//   • Ingest test: the canonical fixture round-trips: POST agent-activity-report
//     ⇒ rc 0 ⇒ DB row present with the §9.1-stamped fixture in `json`.
//   • Rejection tests: each §1.4 rule fires and writes NOTHING (including the
//     D.2 closed-enum gates: bad state / non-derived confidence / bad dot /
//     bad lane).
//   • Latest-wins: older straggler dropped, newer kept (per-agent_key).
//   • Anti-drift: `agent_activity` is NOT in the §4 schema registry; the four
//     §2 capability lines stay exactly four; `put agent_activity ...` is
//     unknown_type; the records table never sees an agent_activity report.

import { env, SELF } from "cloudflare:test";
import { it, expect } from "vitest";
import { schemaVersion } from "../src/schema.js";
import { ACTIVITY_STATES } from "../src/activity.js";
import fixture from "../../test-fixtures/agent-activity-v1.json";

const GOOD = "bearer-runner-secret-xyz";

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
  return call(bearer, "agent-activity-report", [line]);
}
function ingested(r) {
  return r.status === 200;
}

async function storedRow(key) {
  return env.DB.prepare(
    "SELECT agent_key, observed_at, json FROM agent_activity WHERE agent_key = ?"
  )
    .bind(key)
    .first();
}
async function rowCount() {
  const r = await env.DB.prepare("SELECT COUNT(*) AS n FROM agent_activity").first();
  return r ? r.n : 0;
}
async function freshStore() {
  try {
    await env.DB.prepare("DELETE FROM agent_activity").run();
  } catch {
    /* table not lazily created yet = already empty */
  }
}

// Build a §1.4 line by overlaying changes on the canonical fixture. Keeps every
// test bound to the fixture as the single source of truth. `undefined` override
// deletes the key (JSON.stringify drops it) — the "field missing" rejection arm.
function line(overrides) {
  return JSON.stringify({ ...payload(), ...overrides });
}

// ════════════════════════════════════════════════════════════════════════════
it("I1 agent_activity ingest is contract-faithful to DESIGN I §1.4 + D.2", async () => {
  // ── INGEST TEST: the canonical fixture round-trips ─────────────────────────
  await freshStore();
  const fix = payload();
  const r = await report(GOOD, JSON.stringify(fix));
  ck("the canonical fixture ingests with rc 0 (200, empty body)", ingested(r) && r.raw === "");

  let st = await storedRow(fix.agent_key);
  ck("ingest stored the report in the agent_activity namespace", !!st);
  ck("stored observed_at matches the fixture (denorm column)", st && st.observed_at === fix.observed_at);

  const stored = st && JSON.parse(st.json);
  ck("§9.1 principal stamped over the fixture's 'PRINCIPAL_V1' literal", stored && stored.principal === "brian");
  ck("stored.report is the closed literal 'agent_activity'", stored && stored.report === "agent_activity");
  ck("stored.schema_version is 1", stored && stored.schema_version === 1);
  ck("stored.agent_key preserved verbatim", stored && stored.agent_key === fix.agent_key);
  ck("stored.lane preserved", stored && stored.lane === fix.lane);
  ck("stored.state preserved (closed D.2 enum value)", stored && stored.state === fix.state);
  ck("stored.state_confidence is 'derived'", stored && stored.state_confidence === "derived");
  ck("stored.liveness_dot preserved", stored && stored.liveness_dot === fix.liveness_dot);
  // The §1.4 superset (debug/projection-input telemetry) is tolerated verbatim.
  ck("stored.current_tool preserved (table-only telemetry)", stored && stored.current_tool === fix.current_tool);
  ck("stored.touching preserved (the [free] writer stretch)", stored && JSON.stringify(stored.touching) === JSON.stringify(fix.touching));

  // The "principal-stamped fixture" assertion in full: every field except
  // `principal` equals the fixture; `principal` equals the resolved
  // PRINCIPAL_V1 ("brian").
  const expected = { ...fix, principal: "brian" };
  ck("stored ≡ principal-stamped fixture (deep equal)", stored && JSON.stringify(stored) === JSON.stringify(expected));

  // get-agent-activity aggregates and returns the stamped record.
  const g = await call(GOOD, "get-agent-activity", []);
  ck("get-agent-activity returns 200 + JSON {agents:[...]}", g.status === 200 && g.body && Array.isArray(g.body.agents));
  ck("get-agent-activity surfaces the just-ingested record", g.body && g.body.agents.length === 1 && g.body.agents[0].agent_key === fix.agent_key);
  ck("get-agent-activity record carries the §9.1 stamped principal", g.body && g.body.agents[0].principal === "brian");

  // ── REJECTION TESTS: each §1.4 rule fires; writes NOTHING ─────────────────
  const rejects = async (l) => {
    const before = await rowCount();
    const res = await report(GOOD, l);
    const after = await rowCount();
    return res.status === 422 && before === after;
  };

  ck("(1) invalid JSON ⇒ rejected; nothing written", await rejects("{not-json"));
  ck("(1) array (not an object) ⇒ rejected", await rejects(JSON.stringify([1, 2, 3])));
  ck("(1) report!='agent_activity' ⇒ rejected", await rejects(line({ report: "machine_state" })));
  ck('(2) string schema_version "1" ⇒ rejected (must be int)', await rejects(line({ schema_version: "1" })));
  ck("(2) float schema_version 1.5 ⇒ rejected", await rejects(line({ schema_version: 1.5 })));
  ck("(3) sv=2 (unknown HIGHER) ⇒ rc 3 (§0.3 never best-effort)", await rejects(line({ schema_version: 2 })));
  ck("(4) sv=0 (unsupported) ⇒ rejected", await rejects(line({ schema_version: 0 })));
  ck("(5) agent_key missing ⇒ rejected", await rejects(line({ agent_key: undefined })));
  ck("(5) agent_key with '..' ⇒ rc 3 (unsafeKey)", await rejects(line({ agent_key: "../../etc" })));
  ck("(5) agent_key empty string ⇒ rejected", await rejects(line({ agent_key: "" })));
  ck("(5) agent_key non-string (number) ⇒ rejected", await rejects(line({ agent_key: 42 })));
  ck("(6) observed_at missing ⇒ rejected", await rejects(line({ observed_at: undefined })));
  ck("(6) observed_at non-string ⇒ rejected", await rejects(line({ observed_at: 12345 })));
  ck("(7) lane='supervisor' (not writer|auxiliary) ⇒ rejected", await rejects(line({ lane: "supervisor" })));
  ck("(7) lane missing ⇒ rejected", await rejects(line({ lane: undefined })));
  ck("(8) state='compiling' (not in closed D.2 enum) ⇒ rejected", await rejects(line({ state: "compiling" })));
  ck("(8) state missing ⇒ rejected", await rejects(line({ state: undefined })));
  ck("(9) state_confidence='asserted' (D.2 — only 'derived') ⇒ rejected", await rejects(line({ state_confidence: "asserted" })));
  ck("(9) state_confidence missing ⇒ rejected", await rejects(line({ state_confidence: undefined })));
  ck("(10) liveness_dot='yellow' (not green|amber|red) ⇒ rejected", await rejects(line({ liveness_dot: "yellow" })));
  ck("(10) liveness_dot missing ⇒ rejected", await rejects(line({ liveness_dot: undefined })));

  // Every closed-enum state value is ACCEPTED (the D.2 7-set is the mirror).
  await freshStore();
  for (const s of ACTIVITY_STATES) {
    const rr = await report(GOOD, line({ agent_key: `writer:enum-${s}`, state: s }));
    ck(`(8) closed-enum state '${s}' ⇒ accepted`, rr.status === 200);
  }
  ck("ACTIVITY_STATES has exactly 7 closed values (D.2)", ACTIVITY_STATES.length === 7);

  // ── LATEST-WINS: older straggler dropped, newer kept ──────────────────────
  await freshStore();
  const T_OLD = "2026-05-24T00:00:00Z";
  const T_NEW = "2026-05-24T12:00:00Z";
  const KEY = "writer:macbook-pro.local";
  await report(GOOD, line({ agent_key: KEY, observed_at: T_NEW, state: "writing-code" }));
  let lw = await storedRow(KEY);
  ck("seeded newer report stored", lw && lw.observed_at === T_NEW);
  const sr = await report(GOOD, line({ agent_key: KEY, observed_at: T_OLD, state: "exploring" }));
  ck("older straggler ⇒ rc 0 (kept-newer-stored skip; not a reject)", sr.status === 200);
  lw = await storedRow(KEY);
  ck("older straggler did NOT clobber the newer observed_at", lw && lw.observed_at === T_NEW);
  ck("older straggler did NOT clobber the newer state value", lw && JSON.parse(lw.json).state === "writing-code");
  const T_NEWEST = "2026-05-24T23:59:59Z";
  await report(GOOD, line({ agent_key: KEY, observed_at: T_NEWEST, state: "maybe-stuck" }));
  lw = await storedRow(KEY);
  ck("newer report supersedes the prior (latest-wins)", lw && lw.observed_at === T_NEWEST);
  ck("newer report's state is the stored value", lw && JSON.parse(lw.json).state === "maybe-stuck");

  // ── §9.1 — no/invalid token ⇒ rejected at the chokepoint; NOTHING written ─
  await freshStore();
  const noToken = await report(null, JSON.stringify(payload()));
  ck("no-token agent-activity-report ⇒ 401 at the Worker (one chokepoint)", noToken.status === 401);
  ck("no-token agent-activity-report wrote NOTHING", (await rowCount()) === 0);
  env.CO_EXPECTED_TOKEN = "expected";
  const badToken = await report("wrong", JSON.stringify(payload()));
  ck("invalid-token agent-activity-report ⇒ 401", badToken.status === 401);
  delete env.CO_EXPECTED_TOKEN;
  ck("invalid-token agent-activity-report wrote NOTHING", (await rowCount()) === 0);

  // ── ANTI-DRIFT: structural absence from the §4 registry / store / poll ────
  ck("'agent_activity' is NOT a §4 record type (absent from schemaVersion)", schemaVersion("agent_activity") === null);
  const gget = await call(GOOD, "get", ["agent_activity", "writer:macbook-pro.local"]);
  ck("§4 get agent_activity ⇒ NOT reachable as a §4 record", gget.status !== 200);
  const gput = await call(GOOD, "put", ["agent_activity", "x", '{"schema_version":1}']);
  ck("§4 put agent_activity ⇒ unknown_type", gput.status === 422 && gput.body && gput.body.code === "unknown_type");
  const caps = await call(GOOD, "capabilities", []);
  const n = (caps.raw.match(/§2/g) || []).length;
  ck("co_capabilities still EXACTLY four §2 lines (CF.1 substrate untouched)", n === 4);
  ck("co_capabilities does NOT advertise activity as a §2 capability", !caps.raw.includes("agent-activity") && !caps.raw.includes("agent_activity"));
  // the records table never sees an agent_activity report (separate namespace)
  await report(GOOD, line({ agent_key: "writer:aaCanary", observed_at: "2026-05-24T01:02:03Z" }));
  const recs = await env.DB.prepare("SELECT json FROM records").all();
  const recBlob = JSON.stringify((recs && recs.results) || []);
  ck("the §4 records table holds NO agent_activity report (separate namespace)", !recBlob.includes('"report":"agent_activity"') && !recBlob.includes("aaCanary"));

  expect(FAIL, `I1 conformance failed: ${fails.join("; ")}`).toBe(0);
});
