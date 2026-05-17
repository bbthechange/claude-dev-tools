// CF.4 (claude-tools-7g0.4) — DIFFERENTIAL conformance test.
//
// Mirrors the CF.4-OWNED clauses of the bash focused test
// lib/test-coordinator-capacity.sh (T4.4 §6.3/§6.2 Coordinator-side COARSE
// capacity aggregation + the AD2.2 capacity-half fail-OPEN posture) +
// conformance/assertions/bc-34-usage-fail-open.sh's §6.2 fail-OPEN binding.
// Every assertion exercises the REAL engine via SELF.fetch (Worker → §9.1
// chokepoint → singleton single-threaded Coordinator DO → D1) under the SAME
// workerd+miniflare runtime `wrangler dev` uses, NO Cloudflare account. The CF
// engine MUST exhibit the SAME INTERFACE.md v1 §6.3/§6.2 (+ §0.5
// USAGE_THRESHOLD) behaviour as the bash oracle + those tests:
//   EXIT-1  ask-capacity aggregates VERBATIM T3 §1.1 coarse reports —
//           `standard` over iff aggregated hard-ceiling verdict is over;
//           `low_priority` ADDITIONALLY over past the day-N spare line;
//           latest-wins per (runner_id,cost_class); no-report ⇒ ok.
//   EXIT-2  USAGE_THRESHOLD=0 disables the ceiling ⇒ capacity always ok.
//   EXIT-3  §6.2/AD2.2 — Coordinator-unreachable ⇒ capacity FAILS OPEN
//           (proceed), even with no bearer; reachable ⇒ the gate is
//           consulted. The OPPOSITE posture to CF.2's degraded-CLOSED lease.
//   EXIT-4  anti-drift: a §1.1 capacity report is NOT a §4 record — a
//           SEPARATE namespace, never round-trips the §4 store, structurally
//           absent from the §4.5 projection (poll); the four §2 capabilities
//           stay EXACTLY four; §0.3 reject-unknown-higher + the §6.3 closed
//           enums enforced at ingest; §9.1 stamps the resolved principal.
//
// THE §6.3 rc↔token bijection (kept VERBATIM from src/capacity.js): the bash
// co__ask_capacity emits the bare token "ok"|"over" to stdout AND returns rc
// 0|1 (a caller can branch on either). The CF dispatch returns that token as
// the text/plain body 200 (the bash stdout VERBATIM, the CF.5 stdout⇄body
// precedent); the bijection (ok⟺0, over⟺1) makes the bash rc recoverable —
// asserted here on BOTH the token and the derived rc. A bad-enum reject ⟺ the
// bash rc-2 stderr path ⟺ a non-2xx (422) — exactly the CF.5 rc-2→422 map.
//
// THE §6.2 fail-OPEN wrapper is exercised through the REAL exported
// `askCapacityFailOpen` (the bash co_ask_capacity analogue — runner-side
// decision logic, NOT a DO op, just as bash co_ask_capacity is NOT routed
// through co_request). The reachable arm calls the real engine via
// SELF.fetch; the unreachable arm MUST short-circuit WITHOUT contacting the
// engine (proved by a spy `ask` that records if it was invoked).
//
// `schemaVersion` is imported (the stuck.spec precedent) to assert `capacity`
// is NOT a §4 record type — the CF analogue of the bash `co__schema_version
// capacity` being empty. `env` (the D1 binding) reads the module's OWN
// `capacity_reports` namespace directly and DELETEs it between groups —
// EXACTLY mirroring the bash test reading $CO_STORE/capacity/ directly and
// `fresh_store`'s `rm -rf`. No non-contract debug surface is added.

import { env, SELF } from "cloudflare:test";
import { it, expect } from "vitest";
import { askCapacityFailOpen } from "../src/capacity.js";
import { schemaVersion } from "../src/schema.js";

const GOOD = "bearer-runner-secret-xyz"; // a present, valid v1 bearer

// The verbatim T3 §1.1 line (la_report_capacity shape, lib/local-agent.sh
// l.213-226): {report:"capacity",schema_version:1,principal,runner_id,
// cost_class,verdict,observed_at}. Built directly = the documented T3
// contract; the Coordinator ingests it with NO adaptation (a divergent shape
// would be rejected at ingest and fail this test ⇒ the §11 escalation).
function capLine(rid, cc, vd, at, principal = "t3-local-principal") {
  return JSON.stringify({
    report: "capacity",
    schema_version: 1,
    principal,
    runner_id: rid,
    cost_class: cc,
    verdict: vd,
    observed_at: at,
  });
}
const NOW = "2026-05-17T00:00:00Z"; // a fixed "current" wall-clock (non-ordering cases)

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

// report-capacity success = the bash `rc==0` analogue: a 2xx EMPTY body (the
// bash co__capacity_report has rc 0 + NO stdout, incl. the kept-newer-stored
// idempotent skip). A reject = non-2xx (NOTHING written).
async function report(bearer, line) {
  return call(bearer, "report-capacity", [line]);
}
function ingested(r) {
  return r.status === 200;
}

// ask-capacity ⇒ the §6.3 rc↔token bijection. A 200 "ok"/"over" body ⇒
// {verdict, rc} (ok⟺0, over⟺1); anything else ⇒ a reject (the bash rc-2).
function verdictRc(r) {
  if (r.status === 200 && (r.raw === "ok" || r.raw === "over")) {
    return { verdict: r.raw, rc: r.raw === "over" ? 1 : 0 };
  }
  return { verdict: null, rc: 2, rejected: true };
}
async function askEngine(bearer, cc) {
  return verdictRc(await call(bearer, "ask-capacity", [cc]));
}
// The §6.2 posture, through the REAL exported wrapper. `reach` undefined or
// "reachable" ⇒ consult the engine (bash co_ask_capacity default); only
// "unreachable" short-circuits — and MUST NOT call `ask` (no front door).
async function coAskCapacity(bearer, cc, reach) {
  return askCapacityFailOpen(reach, () => askEngine(bearer, cc));
}

async function storedRow(cc, rid) {
  return env.DB.prepare(
    "SELECT cost_class, runner_id, verdict, observed_at, json FROM capacity_reports WHERE cost_class = ? AND runner_id = ?"
  )
    .bind(cc, rid)
    .first();
}
// `fresh_store` analogue: wipe the module's OWN namespace (the bash
// `rm -rf "$CO_STORE/capacity"`). A not-yet-DDL'd table = empty (same as
// rm -rf of an absent dir) — tolerate it.
async function freshStore() {
  try {
    await env.DB.prepare("DELETE FROM capacity_reports").run();
  } catch {
    /* table not lazily created yet = already empty (bash absent-dir parity) */
  }
}
// jq `$a==$b`-on-objects analogue, modulo the §9.1 principal stamp:
// order-independent deep compare of every field EXCEPT principal.
function eqModuloPrincipal(aStr, bStr) {
  try {
    const norm = (s) => {
      const o = JSON.parse(s);
      delete o.principal;
      return JSON.stringify(
        Object.keys(o)
          .sort()
          .reduce((acc, k) => ((acc[k] = o[k]), acc), {})
      );
    };
    return norm(aStr) === norm(bStr);
  } catch {
    return false;
  }
}

// ════════════════════════════════════════════════════════════════════════════
it("CF.4 §6.3/§6.2 capacity is behaviour-identical to lib/coordinator.sh co__capacity_* / co__ask_capacity / co_ask_capacity + test-coordinator-capacity.sh + bc-34-usage-fail-open.sh", async () => {
  // ── EXIT-1: ask-capacity aggregates VERBATIM T3 §1.1 coarse reports ───────
  const L_A_over = capLine("runnerA", "standard", "over", NOW);
  ck("the line IS the §1.1 capacity shape (report==capacity)", JSON.parse(L_A_over).report === "capacity");
  ck("T3 la_report_capacity-shaped line ingests with NO adaptation", ingested(await report(GOOD, L_A_over)));
  let st = await storedRow("standard", "runnerA");
  ck("ingest stored the report in the capacity_reports namespace", !!st);
  ck("§9.1 principal stamped on the ingested report (resolved PRINCIPAL_V1)", st && JSON.parse(st.json).principal === "brian");
  ck("ingested report keeps T3's verbatim runner_id", st && JSON.parse(st.json).runner_id === "runnerA");
  ck("ingested report keeps T3's verbatim verdict", st && JSON.parse(st.json).verdict === "over");
  ck("stored ≡ T3 line modulo the §9.1 principal stamp (no shape adaptation == no drift)", st && eqModuloPrincipal(st.json, L_A_over));

  // standard: gated ONLY by the hard ceiling — any aggregated `over` ⇒ over.
  let v = await askEngine(GOOD, "standard");
  ck("1 runner standard=over ⇒ ask-capacity standard = over", v.verdict === "over");
  ck("ask-capacity standard rc=1 on over (proceed/halt convention)", v.rc === 1);

  // recovered runner re-reports ok with a NEWER observed_at ⇒ latest-wins ⇒ ok
  await report(GOOD, capLine("runnerA", "standard", "ok", "2999-01-01T00:00:00Z"));
  v = await askEngine(GOOD, "standard");
  ck("recovered runner (newer ok) supersedes its earlier over", v.verdict === "ok");
  ck("ask-capacity standard rc=0 on ok", v.rc === 0);
  // an OLDER straggler `over` must NOT clobber the newer stored `ok`.
  await report(GOOD, capLine("runnerA", "standard", "over", "2000-01-01T00:00:00Z"));
  ck("older straggler over does NOT overwrite newer ok", (await askEngine(GOOD, "standard")).verdict === "ok");
  st = await storedRow("standard", "runnerA");
  ck("the stored row is still the newer ok (straggler wrote NOTHING)", st && st.verdict === "ok");

  // multi-runner aggregation: ANY runner over ⇒ over; all ok ⇒ ok.
  await freshStore();
  await report(GOOD, capLine("hostA", "standard", "ok", NOW));
  await report(GOOD, capLine("hostB", "standard", "ok", NOW));
  ck("all runners standard=ok ⇒ aggregated ok", (await askEngine(GOOD, "standard")).verdict === "ok");
  await report(GOOD, capLine("hostB", "standard", "over", NOW));
  ck("ANY runner standard=over ⇒ aggregated over", (await askEngine(GOOD, "standard")).verdict === "over");

  // no reports at all (gate enabled) ⇒ ok (the real guard is the LA hard
  // ceiling, which WOULD have reported over — AD2.3 honest rationale).
  await freshStore();
  ck("no reports + gate enabled ⇒ standard ok", (await askEngine(GOOD, "standard")).verdict === "ok");
  ck("no reports + gate enabled ⇒ low_priority ok", (await askEngine(GOOD, "low_priority")).verdict === "ok");

  // ── EXIT-1: low_priority ADDITIONALLY gated by the spare-cycles line ──────
  await freshStore();
  await report(GOOD, capLine("spareR", "standard", "ok", NOW));
  await report(GOOD, capLine("spareR", "low_priority", "over", NOW));
  ck("low_priority over (spare line) ⇒ ask low_priority = over", (await askEngine(GOOD, "low_priority")).verdict === "over");
  ck("standard IGNORES the spare ramp (still ok)", (await askEngine(GOOD, "standard")).verdict === "ok");
  // never starves the weekly cap: a hit hard ceiling on standard ⇒
  // low_priority is certainly over even with NO low_priority report.
  await freshStore();
  await report(GOOD, capLine("capR", "standard", "over", NOW));
  ck("standard hard-ceiling over ⇒ low_priority over (no LP report)", (await askEngine(GOOD, "low_priority")).verdict === "over");
  // low_priority ok ONLY when BOTH the ceiling is clear AND under the spare
  // line (both coarse verdicts ok).
  await freshStore();
  await report(GOOD, capLine("lpR", "standard", "ok", NOW));
  await report(GOOD, capLine("lpR", "low_priority", "ok", NOW));
  ck("ceiling clear + under spare line ⇒ low_priority ok", (await askEngine(GOOD, "low_priority")).verdict === "ok");

  // ── EXIT-2: USAGE_THRESHOLD=0 disables the ceiling ⇒ always ok ────────────
  await freshStore();
  await report(GOOD, capLine("zR", "standard", "over", NOW));
  await report(GOOD, capLine("zR", "low_priority", "over", NOW));
  ck("threshold default (>0): seeded over ⇒ standard over (control)", (await askEngine(GOOD, "standard")).verdict === "over");
  env.USAGE_THRESHOLD = "0";
  v = await askEngine(GOOD, "standard");
  ck("USAGE_THRESHOLD=0 ⇒ standard ok despite seeded over", v.verdict === "ok");
  ck("USAGE_THRESHOLD=0 ⇒ standard rc=0 (proceed)", v.rc === 0);
  ck("USAGE_THRESHOLD=0 ⇒ low_priority ok despite seeded over", (await askEngine(GOOD, "low_priority")).verdict === "ok");
  delete env.USAGE_THRESHOLD; // restore: default 70 (gate enabled) again
  ck("USAGE_THRESHOLD restored ⇒ seeded over ⇒ standard over again", (await askEngine(GOOD, "standard")).verdict === "over");

  // ── EXIT-3: §6.2/AD2.2 — Coordinator-unreachable ⇒ capacity FAILS OPEN ────
  await freshStore();
  await report(GOOD, capLine("uR", "standard", "over", NOW));
  // reachable: the gate IS consulted (seeded over ⇒ over, rc 1).
  v = await coAskCapacity(GOOD, "standard", "reachable");
  ck("reachable ⇒ aggregation consulted (over)", v.verdict === "over");
  ck("reachable over ⇒ rc 1", v.rc === 1);
  // unreachable: FAIL OPEN — proceed, and MUST NOT contact the engine (no
  // front door exists when unreachable). A spy proves `ask` is never invoked.
  let asked = false;
  const spyAsk = async () => {
    asked = true;
    return { verdict: "over", rc: 1 };
  };
  v = await askCapacityFailOpen("unreachable", spyAsk);
  ck("unreachable ⇒ FAIL OPEN: verdict ok (proceed)", v.verdict === "ok");
  ck("unreachable ⇒ rc 0 (proceed)", v.rc === 0);
  ck("unreachable ⇒ the engine is NEVER consulted (the posture IS proceed)", asked === false);
  // the posture IS 'proceed' — even an empty bearer proceeds (a one-task
  // overshoot is noise; BC-34 intent is held AT THE LOCAL AGENT, T3).
  v = await coAskCapacity("", "standard", "unreachable");
  ck("unreachable + no bearer ⇒ verdict ok (proceed)", v.verdict === "ok");
  ck("unreachable + no bearer ⇒ rc 0 (proceed)", v.rc === 0);
  v = await coAskCapacity(null, "standard", "unreachable");
  ck("unreachable + null bearer ⇒ still proceed (no auth when unreachable)", v.verdict === "ok" && v.rc === 0);
  ck("unreachable low_priority ⇒ proceed too", (await coAskCapacity(GOOD, "low_priority", "unreachable")).verdict === "ok");
  // default reach ⇒ reachable (a runner that does NOT pass the flag asks).
  ck("default reach=reachable (gate consulted ⇒ over)", (await coAskCapacity(GOOD, "standard")).verdict === "over");

  // ── EXIT-4: anti-drift — §1.1 report is NOT §4; never in §4.5; §0.3/enums ─
  ck("'capacity' is NOT a §4 record type (absent from schemaVersion — co__schema_version parity)", schemaVersion("capacity") === null);
  let r = await call(GOOD, "get", ["capacity", "standard"]);
  ck("a capacity report is NOT reachable via the §4 get path", r.status !== 200);
  r = await call(GOOD, "put", ["capacity", "x", '{"schema_version":1}']);
  ck("a capacity report cannot be put via the §4 store path (unknown_type)", r.status === 422 && r.body && r.body.code === "unknown_type");
  // §0.3 / §6.3 closed-enum enforcement at ingest (binds the §1.1 report to
  // schema_version 1 VERBATIM; a reject writes NOTHING — non-2xx).
  const rejects = async (line) => (await report(GOOD, line)).status === 422;
  ck("schema_version 2 capacity report ⇒ rejected (§0.3, never best-effort)", await rejects('{"report":"capacity","schema_version":2,"runner_id":"r","cost_class":"standard","verdict":"over"}'));
  ck('string schema_version "1" ⇒ rejected (§1.1 int)', await rejects('{"report":"capacity","schema_version":"1","runner_id":"r","cost_class":"standard","verdict":"over"}'));
  ck('report!="capacity" ⇒ rejected (not a §1.1 capacity report)', await rejects('{"report":"terminal-reason","schema_version":1,"runner_id":"r"}'));
  ck("unknown cost_class ⇒ rejected (§6.3 closed enum)", await rejects('{"report":"capacity","schema_version":1,"runner_id":"r","cost_class":"bulk","verdict":"ok"}'));
  ck("unknown verdict ⇒ rejected (§6.3 closed enum)", await rejects('{"report":"capacity","schema_version":1,"runner_id":"r","cost_class":"standard","verdict":"maybe"}'));
  ck("unsafe runner_id ('..') ⇒ rejected at the door", await rejects('{"report":"capacity","schema_version":1,"runner_id":"../../etc","cost_class":"standard","verdict":"ok"}'));
  ck("invalid JSON ⇒ rejected (not a §1.1 capacity report)", await rejects("{not-json"));
  r = await call(GOOD, "ask-capacity", ["bulk"]);
  ck("ask-capacity unknown cost_class ⇒ rejected (closed enum, the bash rc-2 ⟺ 422)", r.status === 422);
  // co__ask_capacity `local cc="${1:-standard}"` parity: a MISSING/empty
  // cost_class defaults to `standard` (a real verdict), NOT a reject — this
  // is stricter than test-coordinator-capacity.sh (which never exercises the
  // no-arg arm) but binds the bash CONTRACT. Seed a standard over so the
  // defaulted answer is observably the standard aggregation.
  await freshStore();
  await report(GOOD, capLine("dfltR", "standard", "over", NOW));
  ck("ask-capacity no cost_class arg ⇒ defaults to standard (over, NOT reject)", verdictRc(await call(GOOD, "ask-capacity", [])).verdict === "over");
  ck("ask-capacity empty-string cost_class ⇒ defaults to standard (over, NOT reject)", verdictRc(await call(GOOD, "ask-capacity", [""])).verdict === "over");

  // §9.1 — no/invalid token ⇒ rejected BEFORE any ingest write (one
  // chokepoint; the Worker 401s before the DO is contacted).
  await freshStore();
  r = await report(null, capLine("nR", "standard", "over", NOW));
  ck("no-token report-capacity ⇒ rejected (authed channel only)", r.status === 401);
  const cnt = await env.DB.prepare("SELECT COUNT(*) AS n FROM capacity_reports").first();
  ck("no-token report-capacity wrote NOTHING", cnt && cnt.n === 0);
  r = await call(null, "ask-capacity", ["standard"]);
  ck("no-token ask-capacity ⇒ rejected", r.status === 401);
  env.CO_EXPECTED_TOKEN = "expected";
  r = await report("wrong", capLine("xR", "standard", "over", NOW));
  ck("invalid-token report-capacity ⇒ rejected", r.status === 401);
  delete env.CO_EXPECTED_TOKEN;

  // §9.1 — a foreign principal literal in the report is OVERWRITTEN by the
  // resolved principal (never trust the use-site literal — C7).
  await report(
    GOOD,
    '{"report":"capacity","schema_version":1,"principal":"someone-else","runner_id":"pR","cost_class":"standard","verdict":"ok","observed_at":"2026-05-16T10:00:00Z"}'
  );
  const pr = await storedRow("standard", "pR");
  ck("ingest overwrites a foreign principal with the resolved PRINCIPAL_V1", pr && JSON.parse(pr.json).principal === "brian");

  // structurally absent from the §2.4 projection/poll and the §4 records
  // table (a SEPARATE namespace, the forensic/ precedent). A distinct canary
  // runner_id (NOT the project_ref) so the check is specific.
  await freshStore();
  await report(GOOD, capLine("rCapCanary", "standard", "over", NOW));
  await call(GOOD, "set-desired", ["projP", "running", "agent-1"]);
  const poll = await call(GOOD, "poll", ["projP"]);
  ck("§2.4 poll output carries NO capacity report marker", !poll.raw.includes('"report":"capacity"'));
  ck("§2.4 poll output carries NO capacity runner_id canary", !poll.raw.includes("rCapCanary"));
  ck("§2.4 poll output carries no capacity 'verdict' field", !poll.raw.includes('"verdict"'));
  const recs = await env.DB.prepare("SELECT json FROM records").all();
  const recBlob = JSON.stringify((recs && recs.results) || []);
  ck("the §4 records table holds NO capacity report (separate namespace)", !recBlob.includes('"report":"capacity"') && !recBlob.includes("rCapCanary"));

  // the four §2 capabilities are EXACTLY four and never mention capacity
  // (capacity is a §6.3 surface through the §2.3 door, NOT a fifth capability).
  const caps = await call(GOOD, "capabilities", []);
  const nCaps = (caps.raw.match(/§2/g) || []).length;
  ck("co_capabilities still EXACTLY four §2 lines (CF.1 substrate untouched)", nCaps === 4);
  ck("co_capabilities does NOT advertise capacity as a §2 capability", !caps.raw.includes("capacity"));
  // never-measures (no usage-cache / spare-ramp LOOKUP, no Keychain / usage
  // API): the SOURCE-discipline clause — the CF analogue of the bash test
  // grepping $LIB — is enforced by run-differential.sh part 3 (the
  // comment-stripped, fail-closed gate), exactly as CF.1's §0.C source
  // discipline lives in run-differential.sh part 2, NOT a spec assertion
  // (workerd has no fs; the structural gate is the faithful realization).

  expect(FAIL, `differential clauses failed: ${fails.join("; ")}`).toBe(0);
});
