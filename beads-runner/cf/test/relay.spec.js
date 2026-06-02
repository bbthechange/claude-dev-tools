// K2 (claude-tools-uxvk2) — DESIGN K §3 relay_log DIFFERENTIAL conformance.
//
// Exercises the REAL engine (Worker → §9.1 chokepoint → singleton single-
// threaded Coordinator DO → D1) via SELF.fetch under the SAME workerd+
// miniflare runtime `wrangler dev` uses, NO Cloudflare account.
//
// What this proves:
//   • Append → tail round-trips: a posted exchange comes back in the B.3
//     {exchanges:[{id,from_ws,to_ws,at,question,answer,outcome,dossier_ref}]}
//     shape VERBATIM (Contract B.3).
//   • Closed `outcome` enum gate ({resolved,escalated}) + safeKey exchange_id /
//     routing-key gate fire at append and write NOTHING (conformance at write).
//   • Append-only recency order (newest-first); project_ref scope filter; the
//     global (unfiltered) log; the `n` row cap; dossier_ref null vs linked.
//   • §9.1: no/invalid token ⇒ 401 at the chokepoint; NOTHING written.
//   • Anti-drift: `relay_log` is NOT a §4 record type (absent from
//     schemaVersion); the four §2 capability lines stay exactly four;
//     `put relay_log ...` is unknown_type; the records table never sees a row.

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

async function append(bearer, exchange) {
  return call(bearer, "relay-log-append", [JSON.stringify(exchange)]);
}
async function tail(bearer, projectRef, n) {
  return call(bearer, "relay-log-tail", [projectRef == null ? "" : projectRef, n == null ? "" : n]);
}
async function rowCount() {
  try {
    const r = await env.DB.prepare("SELECT COUNT(*) AS n FROM relay_log").first();
    return r ? r.n : 0;
  } catch {
    return 0; // table not lazily created yet ⇒ empty
  }
}
async function freshStore() {
  try {
    await env.DB.prepare("DELETE FROM relay_log").run();
  } catch {
    /* table not lazily created yet = already empty */
  }
}

// The canonical exchange — a "resolved" answer the responder returned.
function exchange(overrides) {
  return {
    exchange_id: "fe-be-93o-1",
    project_ref: "thirsty-fe",
    from_ws: "thirsty-fe",
    to_ws: "thirsty-be",
    at: "2026-05-30T12:00:00Z",
    question: "Is the cancel endpoint deployed? What's its response shape?",
    answer: "Deployed since a1b2c3. Shape: { ok, refunded_cents }. 204 on already-cancelled.",
    outcome: "resolved",
    dossier_ref: null,
    ...overrides,
  };
}

const B3_KEYS = ["id", "from_ws", "to_ws", "at", "question", "answer", "outcome", "dossier_ref"];

// ════════════════════════════════════════════════════════════════════════════
it("K2 relay_log is contract-faithful to DESIGN K §3 + UX-V2-ARCHITECTURE A.2/B.3", async () => {
  // ── APPEND → TAIL ROUND-TRIP (the B.3 shape) ───────────────────────────────
  await freshStore();
  const ex = exchange();
  const ap = await append(GOOD, ex);
  ck("relay-log-append ingests with rc 0 (200, empty body)", ap.status === 200 && ap.raw === "");
  ck("append stored exactly one row in the relay_log namespace", (await rowCount()) === 1);

  const t = await tail(GOOD);
  ck("relay-log-tail returns 200 + JSON {exchanges:[...]}", t.status === 200 && t.body && Array.isArray(t.body.exchanges));
  ck("tail surfaces the just-appended exchange", t.body && t.body.exchanges.length === 1);

  const e0 = t.body && t.body.exchanges[0];
  ck("B.3: id = the stable exchange_id", e0 && e0.id === ex.exchange_id);
  ck("B.3: from_ws preserved", e0 && e0.from_ws === ex.from_ws);
  ck("B.3: to_ws preserved", e0 && e0.to_ws === ex.to_ws);
  ck("B.3: at preserved", e0 && e0.at === ex.at);
  ck("B.3: question preserved", e0 && e0.question === ex.question);
  ck("B.3: answer preserved", e0 && e0.answer === ex.answer);
  ck("B.3: outcome preserved (resolved)", e0 && e0.outcome === "resolved");
  ck("B.3: dossier_ref is null for a resolved exchange", e0 && e0.dossier_ref === null);
  // The B.3 projection shape is EXACTLY its closed key set (no extra leak, e.g.
  // no project_ref / no rowid).
  ck("B.3: exchange has EXACTLY the 8 B.3 keys", e0 && JSON.stringify(Object.keys(e0).sort()) === JSON.stringify([...B3_KEYS].sort()));

  // ── ESCALATED row carries the dossier_ref; resolved does not ───────────────
  await freshStore();
  await append(GOOD, exchange({ exchange_id: "esc-1", outcome: "escalated", dossier_ref: "dossier-abc" }));
  const te = await tail(GOOD);
  ck("escalated exchange round-trips with its dossier_ref", te.body && te.body.exchanges[0].outcome === "escalated" && te.body.exchanges[0].dossier_ref === "dossier-abc");

  // empty-string dossier_ref normalises to null (B.3 "…|null")
  await freshStore();
  await append(GOOD, exchange({ exchange_id: "norm-1", dossier_ref: "" }));
  const tn = await tail(GOOD);
  ck("empty dossier_ref is normalised to null in the projection", tn.body && tn.body.exchanges[0].dossier_ref === null);

  // ── APPEND-ONLY RECENCY ORDER (newest-first) + project_ref scope filter ────
  await freshStore();
  await append(GOOD, exchange({ exchange_id: "a-1", project_ref: "thirsty-fe", from_ws: "thirsty-fe" }));
  await append(GOOD, exchange({ exchange_id: "b-1", project_ref: "thirsty-be", from_ws: "thirsty-be" }));
  await append(GOOD, exchange({ exchange_id: "a-2", project_ref: "thirsty-fe", from_ws: "thirsty-fe" }));
  const all = await tail(GOOD);
  ck("global tail returns all 3 exchanges (no project_ref filter)", all.body && all.body.exchanges.length === 3);
  ck("tail order is newest-first (append-only id DESC)", all.body && all.body.exchanges[0].id === "a-2" && all.body.exchanges[2].id === "a-1");
  const feOnly = await tail(GOOD, "thirsty-fe");
  ck("project_ref filter scopes to one workspace's outbound asks", feOnly.body && feOnly.body.exchanges.length === 2 && feOnly.body.exchanges.every((e) => e.id === "a-1" || e.id === "a-2"));
  const beOnly = await tail(GOOD, "thirsty-be");
  ck("project_ref filter (be) returns only the be exchange", beOnly.body && beOnly.body.exchanges.length === 1 && beOnly.body.exchanges[0].id === "b-1");
  const none = await tail(GOOD, "no-such-ws");
  ck("unknown project_ref ⇒ empty exchanges (honest, no fabrication)", none.body && none.body.exchanges.length === 0);

  // ── `n` row cap ────────────────────────────────────────────────────────────
  const capped = await tail(GOOD, "", "2");
  ck("n=2 caps the global tail to the 2 newest rows", capped.body && capped.body.exchanges.length === 2 && capped.body.exchanges[0].id === "a-2");

  // ── project_ref defaults to from_ws when absent ───────────────────────────
  await freshStore();
  await append(GOOD, exchange({ exchange_id: "def-1", project_ref: undefined, from_ws: "thirsty-fe" }));
  const def = await tail(GOOD, "thirsty-fe");
  ck("project_ref defaults to from_ws when absent (filterable)", def.body && def.body.exchanges.length === 1 && def.body.exchanges[0].id === "def-1");

  // ── `at` is stamped server-side when absent (RFC-3339 UTC …Z) ──────────────
  await freshStore();
  await append(GOOD, exchange({ exchange_id: "noat-1", at: undefined }));
  const noat = await tail(GOOD);
  ck("at is stamped server-side when absent (…Z)", noat.body && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(noat.body.exchanges[0].at));

  // ── WRITE GATE: closed outcome enum + identity/routing keys (writes NOTHING)─
  await freshStore();
  const rejects = async (ex2) => {
    const before = await rowCount();
    const res = await append(GOOD, ex2);
    const after = await rowCount();
    return res.status === 422 && before === after;
  };
  ck("outcome not in {resolved,escalated} ⇒ 422; nothing written", await rejects(exchange({ outcome: "answered" })));
  ck("outcome missing ⇒ 422", await rejects(exchange({ outcome: undefined })));
  ck("exchange_id missing ⇒ 422 (the stable B.3 id)", await rejects(exchange({ exchange_id: undefined, id: undefined })));
  ck("exchange_id empty string ⇒ 422", await rejects(exchange({ exchange_id: "" })));
  ck("exchange_id with '..' ⇒ 422 (unsafeKey)", await rejects(exchange({ exchange_id: "../../etc" })));
  ck("project_ref present-and-unsafe ⇒ 422", await rejects(exchange({ project_ref: "../evil" })));
  ck("to_ws present-and-unsafe ⇒ 422", await rejects(exchange({ to_ws: "../evil" })));

  // invalid JSON / non-object args also reject with NOTHING written
  const rawReject = async (arg) => {
    const before = await rowCount();
    const res = await call(GOOD, "relay-log-append", [arg]);
    const after = await rowCount();
    return res.status === 422 && before === after;
  };
  ck("invalid JSON arg ⇒ 422; nothing written", await rawReject("{not-json"));
  ck("array (not an object) ⇒ 422", await rawReject(JSON.stringify([1, 2, 3])));
  ck("missing arg ⇒ 422", await rawReject(undefined));

  // `id` alias is accepted for exchange_id (the B.3 field name)
  await freshStore();
  await call(GOOD, "relay-log-append", [JSON.stringify({ id: "alias-1", from_ws: "x", to_ws: "y", outcome: "resolved" })]);
  const al = await tail(GOOD);
  ck("`id` is accepted as an alias for exchange_id", al.body && al.body.exchanges.length === 1 && al.body.exchanges[0].id === "alias-1");

  // ── §9.1 — no/invalid token ⇒ rejected at the chokepoint; NOTHING written ──
  await freshStore();
  const noTok = await append(null, exchange());
  ck("no-token relay-log-append ⇒ 401 at the Worker (one chokepoint)", noTok.status === 401);
  ck("no-token relay-log-append wrote NOTHING", (await rowCount()) === 0);
  env.CO_EXPECTED_TOKEN = "expected";
  const badTok = await append("wrong", exchange());
  ck("invalid-token relay-log-append ⇒ 401", badTok.status === 401);
  delete env.CO_EXPECTED_TOKEN;
  ck("invalid-token relay-log-append wrote NOTHING", (await rowCount()) === 0);

  // ── ANTI-DRIFT: structural absence from the §4 registry / store / caps ─────
  ck("'relay_log' is NOT a §4 record type (absent from schemaVersion)", schemaVersion("relay_log") === null);
  const gget = await call(GOOD, "get", ["relay_log", "fe-be-93o-1"]);
  ck("§4 get relay_log ⇒ NOT reachable as a §4 record", gget.status !== 200);
  const gput = await call(GOOD, "put", ["relay_log", "x", '{"schema_version":1}']);
  ck("§4 put relay_log ⇒ unknown_type", gput.status === 422 && gput.body && gput.body.code === "unknown_type");
  const caps = await call(GOOD, "capabilities", []);
  const n4 = (caps.raw.match(/§2/g) || []).length;
  ck("co_capabilities still EXACTLY four §2 lines (CF.1 substrate untouched)", n4 === 4);
  ck("co_capabilities does NOT advertise relay-log as a §2 capability", !caps.raw.includes("relay-log") && !caps.raw.includes("relay_log"));
  // the records table never sees a relay exchange (separate namespace)
  await append(GOOD, exchange({ exchange_id: "canary-1", question: "relayCanaryQ" }));
  const recs = await env.DB.prepare("SELECT json FROM records").all();
  const recBlob = JSON.stringify((recs && recs.results) || []);
  ck("the §4 records table holds NO relay exchange (separate namespace)", !recBlob.includes("relayCanaryQ") && !recBlob.includes("canary-1"));

  expect(FAIL, `K2 relay conformance failed: ${fails.join("; ")}`).toBe(0);
});
