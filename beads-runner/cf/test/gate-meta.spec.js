// J1 (claude-tools-uxvj1) — DESIGN J §2 gate_metadata DIFFERENTIAL conformance.
//
// Exercises the REAL engine (Worker → §9.1 chokepoint → singleton single-
// threaded Coordinator DO → D1) via SELF.fetch under the SAME workerd+
// miniflare runtime `wrangler dev` uses, NO Cloudflare account.
//
// What this proves:
//   • set → get round-trips: an upserted gate comes back as the D.2 Gate object
//     { id, why, unblock_condition, owner, scope, set_at, updated_at } VERBATIM.
//   • Write gate (conformance at write — the one refusal point): a bad id, a
//     MISSING why (B8 — a Gate always carries a why), and a scope outside the
//     closed D.2 enum {task,cohort} each 422 and write NOTHING.
//   • set_at is PRESERVED across edits (only updated_at advances) — "set 4d ago"
//     stays honest; scope defaults to "task" when absent.
//   • get one (gate_id given) ⇒ {gate:…|null}; get all (omitted) ⇒ {gates:[…]}
//     sorted; a missing row ⇒ {gate:null}, never a throw.
//   • owner is an INPUT, not the principal (§2.3): "you" / "agent:<hat>" stored
//     verbatim — the engine never overwrites it with PRINCIPAL_V1.
//   • §9.1: no/invalid token ⇒ 401 at the chokepoint; NOTHING written.
//   • Anti-drift: `gate_metadata` is NOT a §4 record type (absent from
//     schemaVersion); the four §2 capability lines stay exactly four;
//     `put gate_metadata ...` is unknown_type; the records table never sees one.

import { env, SELF } from "cloudflare:test";
import { it, expect } from "vitest";
import { schemaVersion } from "../src/schema.js";

const GOOD = "bearer-runner-secret-xyz";

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

async function set(bearer, meta) {
  return call(bearer, "gate-meta-set", [JSON.stringify(meta)]);
}
async function getOne(bearer, gateId) {
  return call(bearer, "gate-meta-get", [gateId]);
}
async function getAll(bearer) {
  return call(bearer, "gate-meta-get", []);
}
async function rowCount() {
  try {
    const r = await env.DB.prepare("SELECT COUNT(*) AS n FROM gate_metadata").first();
    return r ? r.n : 0;
  } catch {
    return 0; // table not lazily created yet ⇒ empty
  }
}
async function freshStore() {
  try {
    await env.DB.prepare("DELETE FROM gate_metadata").run();
  } catch {
    /* table not lazily created yet = already empty */
  }
}

// The canonical gate metadata — a cohort-scoped hold an agent placed.
function meta(overrides) {
  return {
    id: "audio-redesign",
    why: "Waiting on the new audio engine before re-enabling these tasks.",
    unblock_condition: "rhythmGame-77a closes",
    owner: "agent:enricher",
    scope: "cohort",
    ...overrides,
  };
}

const GATE_KEYS = ["id", "why", "unblock_condition", "owner", "scope", "set_at", "updated_at"];

// ════════════════════════════════════════════════════════════════════════════
it("J1 gate_metadata is contract-faithful to DESIGN J §2 + UX-V2-ARCHITECTURE A.2/D.2", async () => {
  // ── SET → GET ROUND-TRIP (the D.2 Gate object) ─────────────────────────────
  await freshStore();
  const m = meta();
  const s = await set(GOOD, m);
  ck("gate-meta-set upserts with rc 0 (200, empty body)", s.status === 200 && s.raw === "");
  ck("set stored exactly one row in the gate_metadata namespace", (await rowCount()) === 1);

  const g = await getOne(GOOD, "audio-redesign");
  ck("gate-meta-get [id] returns 200 + JSON {gate:{...}}", g.status === 200 && g.body && g.body.gate && typeof g.body.gate === "object");
  const gate = g.body && g.body.gate;
  ck("D.2: id = the bare gate id", gate && gate.id === "audio-redesign");
  ck("D.2: why preserved", gate && gate.why === m.why);
  ck("D.2: unblock_condition preserved", gate && gate.unblock_condition === m.unblock_condition);
  ck("§2.3: owner preserved verbatim (an INPUT, not PRINCIPAL_V1)", gate && gate.owner === "agent:enricher");
  ck("D.2: scope preserved (cohort)", gate && gate.scope === "cohort");
  ck("set_at is an RFC-3339 UTC …Z stamp", gate && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(gate.set_at));
  ck("updated_at is an RFC-3339 UTC …Z stamp", gate && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(gate.updated_at));
  ck("Gate object has EXACTLY the 7 D.2+set_at keys", gate && JSON.stringify(Object.keys(gate).sort()) === JSON.stringify([...GATE_KEYS].sort()));

  // ── scope DEFAULTS to "task" when absent ───────────────────────────────────
  await freshStore();
  await set(GOOD, meta({ id: "defaultscope", scope: undefined }));
  const ds = await getOne(GOOD, "defaultscope");
  ck("scope defaults to 'task' when absent (closed D.2 enum, no null member)", ds.body && ds.body.gate && ds.body.gate.scope === "task");

  // ── set_at PRESERVED across edits; updated_at advances ─────────────────────
  await freshStore();
  await set(GOOD, meta({ id: "edited", why: "first reason" }));
  const first = await getOne(GOOD, "edited");
  const firstSetAt = first.body.gate.set_at;
  // edit the why; set_at must NOT move
  const edit = await set(GOOD, meta({ id: "edited", why: "revised reason after more info" }));
  ck("editing an existing gate returns rc 0", edit.status === 200);
  ck("edit did NOT create a second row (upsert on the same id)", (await rowCount()) === 1);
  const second = await getOne(GOOD, "edited");
  ck("edit applied the new why", second.body.gate.why === "revised reason after more info");
  ck("set_at PRESERVED across the edit ('set 4d ago' stays honest, §2.2)", second.body.gate.set_at === firstSetAt);

  // ── GET ALL (no id) ⇒ {gates:[…]} sorted; GET missing ⇒ {gate:null} ────────
  await freshStore();
  await set(GOOD, meta({ id: "zzz-last", why: "z" }));
  await set(GOOD, meta({ id: "aaa-first", why: "a" }));
  const all = await getAll(GOOD);
  ck("gate-meta-get [] returns {gates:[...]}", all.body && Array.isArray(all.body.gates));
  ck("get-all surfaces both gates", all.body && all.body.gates.length === 2);
  ck("get-all is sorted by gate_id ASC", all.body && all.body.gates[0].id === "aaa-first" && all.body.gates[1].id === "zzz-last");
  const missing = await getOne(GOOD, "no-such-gate");
  ck("missing row ⇒ {gate:null} (never a throw, §2.2)", missing.status === 200 && missing.body && missing.body.gate === null);

  // ── WRITE GATE: id shape + REQUIRED why + closed scope enum (writes NOTHING)─
  await freshStore();
  const rejects = async (m2) => {
    const before = await rowCount();
    const res = await set(GOOD, m2);
    const after = await rowCount();
    return res.status === 422 && res.raw === "" && before === after;
  };
  ck("why MISSING ⇒ 422; nothing written (B8 — a Gate always has a why)", await rejects(meta({ why: undefined })));
  ck("why empty string ⇒ 422", await rejects(meta({ why: "" })));
  ck("why whitespace-only ⇒ 422 (a whitespace why is not a why — D.3)", await rejects(meta({ why: "   " })));
  ck("id missing ⇒ 422 (the bare gate id)", await rejects(meta({ id: undefined })));
  ck("id with uppercase ⇒ 422 (gate-defer.sh ^[a-z0-9][a-z0-9-]*$ shape)", await rejects(meta({ id: "Audio-Redesign" })));
  ck("id with a colon ⇒ 422 (the `gate:` prefix is the namespace, not the key)", await rejects(meta({ id: "gate:audio" })));
  ck("id with a leading hyphen ⇒ 422 (must start alnum)", await rejects(meta({ id: "-leading" })));
  ck("id with a space ⇒ 422", await rejects(meta({ id: "audio redesign" })));
  ck("scope outside {task,cohort} ⇒ 422 (closed D.2 enum)", await rejects(meta({ scope: "epic" })));

  // invalid JSON / non-object args also reject with NOTHING written
  const rawReject = async (arg) => {
    const before = await rowCount();
    const res = await call(GOOD, "gate-meta-set", [arg]);
    const after = await rowCount();
    return res.status === 422 && before === after;
  };
  ck("invalid JSON arg ⇒ 422; nothing written", await rawReject("{not-json"));
  ck("array (not an object) ⇒ 422", await rawReject(JSON.stringify([1, 2, 3])));
  ck("missing arg ⇒ 422", await rawReject(undefined));

  // `gate_id` alias is accepted for `id` (the column name)
  await freshStore();
  await call(GOOD, "gate-meta-set", [JSON.stringify({ gate_id: "alias-gate", why: "via the gate_id alias" })]);
  const al = await getOne(GOOD, "alias-gate");
  ck("`gate_id` is accepted as an alias for id", al.body && al.body.gate && al.body.gate.id === "alias-gate");

  // ── §9.1 — no/invalid token ⇒ rejected at the chokepoint; NOTHING written ──
  await freshStore();
  const noTok = await set(null, meta());
  ck("no-token gate-meta-set ⇒ 401 at the Worker (one chokepoint)", noTok.status === 401);
  ck("no-token gate-meta-set wrote NOTHING", (await rowCount()) === 0);
  env.CO_EXPECTED_TOKEN = "expected";
  const badTok = await set("wrong", meta());
  ck("invalid-token gate-meta-set ⇒ 401", badTok.status === 401);
  delete env.CO_EXPECTED_TOKEN;
  ck("invalid-token gate-meta-set wrote NOTHING", (await rowCount()) === 0);

  // ── ANTI-DRIFT: structural absence from the §4 registry / store / caps ─────
  ck("'gate_metadata' is NOT a §4 record type (absent from schemaVersion)", schemaVersion("gate_metadata") === null);
  const gget = await call(GOOD, "get", ["gate_metadata", "audio-redesign"]);
  ck("§4 get gate_metadata ⇒ NOT reachable as a §4 record", gget.status !== 200);
  const gput = await call(GOOD, "put", ["gate_metadata", "x", '{"schema_version":1}']);
  ck("§4 put gate_metadata ⇒ unknown_type", gput.status === 422 && gput.body && gput.body.code === "unknown_type");
  const caps = await call(GOOD, "capabilities", []);
  const n4 = (caps.raw.match(/§2/g) || []).length;
  ck("co_capabilities still EXACTLY four §2 lines (CF.1 substrate untouched)", n4 === 4);
  ck("co_capabilities does NOT advertise gate-meta as a §2 capability", !caps.raw.includes("gate-meta") && !caps.raw.includes("gate_metadata"));
  // the records table never sees a gate metadata row (separate namespace)
  await set(GOOD, meta({ id: "canary-gate", why: "gateCanaryWhy" }));
  const recs = await env.DB.prepare("SELECT json FROM records").all();
  const recBlob = JSON.stringify((recs && recs.results) || []);
  ck("the §4 records table holds NO gate metadata (separate namespace)", !recBlob.includes("gateCanaryWhy") && !recBlob.includes("canary-gate"));

  expect(FAIL, `J1 gate-meta conformance failed: ${fails.join("; ")}`).toBe(0);
});
