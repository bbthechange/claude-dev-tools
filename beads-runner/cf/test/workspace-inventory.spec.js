// claude-tools-8dfb (epic claude-tools-vvgy) — §4.6 workspace_inventory v1
// CF-side WRITE conformance, exercised against the REAL engine (Worker → §9.1
// chokepoint → singleton Coordinator DO → D1) via SELF.fetch under the SAME
// workerd+miniflare runtime `wrangler dev` uses, NO Cloudflare account.
//
// What this proves:
//   • Valid payload accepted: WRITE returns 200/{ok:true}; the row read back
//     via `get workspace_inventory <project_ref>` matches what was sent.
//   • Schema validation rejects each contract violation listed in the bead:
//     missing/non-int counts, missing in_progress_beads[].title, absent
//     top_n_beads, unknown higher schema_version, malformed/pre-2024
//     observed_at, unsafe/missing project_ref.
//   • §9.1 — the resolved principal is STAMPED at the chokepoint; the wire's
//     `principal` literal is OVERWRITTEN by `_writeRecord`.
//   • Overwrite semantics: two writes for the same project_ref ⇒ the second
//     REPLACES the first (no append, no historical accumulation). This is the
//     one-row-per-workspace contract from the bead.
//   • Bounded top_n_beads: arrays of length 0 / 1 / 20 / 100 all accepted
//     (no hard cap at the write boundary — bounding is the producer's concern,
//     §4.6).
//   • Anti-drift: `workspace_inventory` IS in the §4 schema registry at v1.

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
async function put(line) {
  return call(GOOD, "workspace-inventory-put", [line]);
}
async function getRecord(type, id) {
  const r = await call(GOOD, "get", [type, id]);
  if (r.status !== 200) return null;
  try {
    return JSON.parse(r.raw);
  } catch {
    return null;
  }
}

function nowIso() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

// A minimal-valid workspace_inventory payload — every field the §4.6 wire
// shape requires, no extras. Tests mutate one field at a time and re-stringify.
function basePayload(overrides) {
  return {
    report: "workspace_inventory",
    schema_version: 1,
    // §9.1 — this literal MUST be overwritten by the resolved principal.
    principal: "literal-should-be-overwritten",
    runner_id: "runnerA",
    project_ref: "wi-test",
    observed_at: nowIso(),
    counts: { open: 5, ready: 3, in_progress: 1, blocked: 1 },
    in_progress_beads: [
      { bead_ref: "wi-test-001", title: "smoke test", stage: "impl" },
    ],
    top_n_beads: [
      { bead_ref: "wi-test-001", title: "smoke test", status: "in_progress", stage: "impl" },
    ],
    ...(overrides || {}),
  };
}
function line(overrides) {
  return JSON.stringify(basePayload(overrides));
}

function makeTopN(n, prefix) {
  const out = [];
  for (let i = 0; i < n; i++) {
    out.push({
      bead_ref: `${prefix}-${String(i).padStart(4, "0")}`,
      title: `bead ${i}`,
      status: "open",
      stage: "impl",
    });
  }
  return out;
}

it("CF workspace-inventory-put (claude-tools-8dfb) — schema validation + write semantics", async () => {
  // ── CASE 1: Valid payload accepted; read-back matches what was written ────
  const r1 = await put(line({ project_ref: "case1" }));
  ck("valid payload ⇒ 200/{ok:true}", r1.status === 200 && r1.body && r1.body.ok === true);
  const stored1 = await getRecord("workspace_inventory", "case1");
  ck("stored row present at id=project_ref", !!stored1);
  ck("stored row carries schema_version=1", stored1 && stored1.schema_version === 1);
  ck("stored row carries project_ref verbatim", stored1 && stored1.project_ref === "case1");
  ck(
    "stored row carries counts verbatim",
    stored1 && stored1.counts && stored1.counts.open === 5 && stored1.counts.ready === 3 &&
      stored1.counts.in_progress === 1 && stored1.counts.blocked === 1
  );
  ck(
    "stored row carries in_progress_beads verbatim",
    stored1 && Array.isArray(stored1.in_progress_beads) && stored1.in_progress_beads.length === 1 &&
      stored1.in_progress_beads[0].bead_ref === "wi-test-001"
  );
  ck(
    "stored row carries top_n_beads verbatim (with status field)",
    stored1 && Array.isArray(stored1.top_n_beads) && stored1.top_n_beads.length === 1 &&
      stored1.top_n_beads[0].status === "in_progress"
  );

  // ── CASE 2: Schema validation rejects ─────────────────────────────────────
  const rMissingCount = await put(line({ counts: { open: 5, ready: 3, blocked: 1 } }));
  ck("missing counts.in_progress ⇒ reject (422)", rMissingCount.status === 422);
  const rNonInt = await put(line({ counts: { open: 5, ready: 3, in_progress: 1.5, blocked: 1 } }));
  ck("non-int count (1.5) ⇒ reject (422)", rNonInt.status === 422);
  const rStrCount = await put(line({ counts: { open: "5", ready: 3, in_progress: 1, blocked: 1 } }));
  ck("string count \"5\" ⇒ reject (422, contract value not best-effort)", rStrCount.status === 422);
  const rIpNoTitle = await put(
    line({ in_progress_beads: [{ bead_ref: "wi-test-001", stage: "impl" }] })
  );
  ck("in_progress_beads[].title missing ⇒ reject (422)", rIpNoTitle.status === 422);
  const rIpNoRef = await put(
    line({ in_progress_beads: [{ title: "no ref", stage: "impl" }] })
  );
  ck("in_progress_beads[].bead_ref missing ⇒ reject (422)", rIpNoRef.status === 422);
  const rIpNoStage = await put(
    line({ in_progress_beads: [{ bead_ref: "x", title: "no stage" }] })
  );
  ck("in_progress_beads[].stage missing ⇒ reject (422)", rIpNoStage.status === 422);
  // top_n_beads is REQUIRED (may be empty, but must be present as an array).
  const noTop = basePayload({ project_ref: "case2-no-top" });
  delete noTop.top_n_beads;
  const rNoTop = await put(JSON.stringify(noTop));
  ck("missing top_n_beads ⇒ reject (422, required even if empty)", rNoTop.status === 422);
  const rTopNoTitle = await put(
    line({ top_n_beads: [{ bead_ref: "x", status: "open", stage: "impl" }] })
  );
  ck("top_n_beads[].title missing ⇒ reject (422)", rTopNoTitle.status === 422);
  const rTopNoStatus = await put(
    line({ top_n_beads: [{ bead_ref: "x", title: "no status", stage: "impl" }] })
  );
  ck("top_n_beads[].status missing ⇒ reject (422)", rTopNoStatus.status === 422);
  // ip array still required (even if empty)
  const noIp = basePayload({ project_ref: "case2-no-ip" });
  delete noIp.in_progress_beads;
  const rNoIp = await put(JSON.stringify(noIp));
  ck("missing in_progress_beads ⇒ reject (422)", rNoIp.status === 422);
  // counts itself missing / non-object
  const noCounts = basePayload({ project_ref: "case2-no-counts" });
  delete noCounts.counts;
  const rNoCounts = await put(JSON.stringify(noCounts));
  ck("missing counts ⇒ reject (422)", rNoCounts.status === 422);
  const rCountsArr = await put(line({ counts: [5, 3, 1, 1] }));
  ck("counts as array ⇒ reject (422, must be object)", rCountsArr.status === 422);
  // report discriminator
  const rWrongReport = await put(line({ report: "heartbeat" }));
  ck('report!="workspace_inventory" ⇒ reject (422)', rWrongReport.status === 422);
  // unsafe / missing project_ref
  const rBadProj = await put(line({ project_ref: "../../etc" }));
  ck("unsafe project_ref ('..') ⇒ reject (422, store-owner input hygiene)", rBadProj.status === 422);
  const rEmptyProj = await put(line({ project_ref: "" }));
  ck("empty project_ref ⇒ reject (422)", rEmptyProj.status === 422);

  // ── CASE 3: Unknown higher schema_version rejected (§0.3 discipline) ──────
  const rSv2 = await put(line({ schema_version: 2 }));
  ck("schema_version 2 ⇒ rejected (§0.3, never best-effort-parse)", rSv2.status === 422);
  const rSvStr = await put(line({ schema_version: "1" }));
  ck('string schema_version "1" ⇒ rejected (§0.3 int gate)', rSvStr.status === 422);
  const noSv = basePayload({ project_ref: "case3-no-sv" });
  delete noSv.schema_version;
  const rNoSv = await put(JSON.stringify(noSv));
  ck("missing schema_version ⇒ rejected (§0.3)", rNoSv.status === 422);

  // ── CASE 4: Principal stamping — wire literal OVERWRITTEN by §9.1 ─────────
  await put(line({ project_ref: "case4", principal: "malicious" }));
  const stored4 = await getRecord("workspace_inventory", "case4");
  ck("§9.1 — wire principal 'malicious' OVERWRITTEN by resolved principal", stored4 && stored4.principal === "brian");

  // ── CASE 5: Overwrite semantics — second write REPLACES the first ─────────
  await put(line({ project_ref: "case5", counts: { open: 10, ready: 5, in_progress: 2, blocked: 0 } }));
  const before5 = await getRecord("workspace_inventory", "case5");
  ck("first write stored counts.open=10", before5 && before5.counts.open === 10);
  await put(line({ project_ref: "case5", counts: { open: 1, ready: 1, in_progress: 1, blocked: 1 } }));
  const after5 = await getRecord("workspace_inventory", "case5");
  ck("second write REPLACES first (counts.open=1, no append)", after5 && after5.counts.open === 1);
  // Only one row should exist for case5 (the INSERT OR REPLACE primary key).
  const cnt5Row = await env.DB.prepare(
    "SELECT COUNT(*) AS n FROM records WHERE type = ? AND id = ?"
  )
    .bind("workspace_inventory", "case5")
    .first();
  ck("exactly ONE row per (type, project_ref) — no historical accumulation", cnt5Row && cnt5Row.n === 1);

  // ── CASE 6: Bounded top_n_beads — accept length 0, 1, 20, 100 ─────────────
  for (const n of [0, 1, 20, 100]) {
    const r = await put(
      line({
        project_ref: `case6-${n}`,
        top_n_beads: makeTopN(n, `c6n${n}`),
      })
    );
    ck(`top_n_beads length ${n} accepted (no hard cap at write boundary)`, r.status === 200);
    const stored = await getRecord("workspace_inventory", `case6-${n}`);
    ck(`top_n_beads length ${n} round-trips at the stored row`, stored && stored.top_n_beads.length === n);
  }
  // in_progress_beads of length 0 is also accepted.
  const rIp0 = await put(line({ project_ref: "case6-ip0", in_progress_beads: [] }));
  ck("in_progress_beads length 0 accepted (may be empty)", rIp0.status === 200);

  // ── CASE 7: observed_at validation ────────────────────────────────────────
  const rBadIso = await put(line({ project_ref: "case7-bad", observed_at: "not-a-timestamp" }));
  ck("malformed observed_at ⇒ reject (422, §0.4)", rBadIso.status === 422);
  const rNoZ = await put(line({ project_ref: "case7-noz", observed_at: "2026-05-24T20:00:00" }));
  ck("observed_at missing trailing Z ⇒ reject (§0.4 UTC discipline)", rNoZ.status === 422);
  const rPre2024 = await put(line({ project_ref: "case7-old", observed_at: "1999-01-01T00:00:00Z" }));
  ck("observed_at pre-2024 ⇒ reject (S-1 freshness guard, h7n-style)", rPre2024.status === 422);
  const noObs = basePayload({ project_ref: "case7-noobs" });
  delete noObs.observed_at;
  const rNoObs = await put(JSON.stringify(noObs));
  ck("missing observed_at ⇒ reject (required, §0.4)", rNoObs.status === 422);

  // ── CASE 8: `verified` optional additive field round-trips (claude-tools-7qf7)
  // The done·code-vs-done·verified source signal. Optional at v1 (no bump),
  // STRICT boolean: only literal true survives; absent/non-bool ⇒ false.
  const rVer = await put(
    line({
      project_ref: "case8-ver",
      in_progress_beads: [
        { bead_ref: "case8-001", title: "probed", stage: "done", verified: true },
        { bead_ref: "case8-002", title: "unprobed", stage: "done" }, // absent ⇒ false
      ],
      top_n_beads: [
        { bead_ref: "case8-003", title: "open probed", status: "open", stage: "done", verified: true },
        { bead_ref: "case8-004", title: "non-bool", status: "open", stage: "done", verified: "yes" }, // non-bool ⇒ false
      ],
    })
  );
  ck("verified-carrying payload ⇒ 200", rVer.status === 200);
  const storedVer = await getRecord("workspace_inventory", "case8-ver");
  ck(
    "in_progress_beads[].verified:true round-trips strict-true",
    storedVer && storedVer.in_progress_beads[0].verified === true
  );
  ck(
    "in_progress_beads[].verified absent ⇒ stored false (un-probed default)",
    storedVer && storedVer.in_progress_beads[1].verified === false
  );
  ck(
    "top_n_beads[].verified:true round-trips strict-true",
    storedVer && storedVer.top_n_beads[0].verified === true
  );
  ck(
    "top_n_beads[].verified non-bool ('yes') ⇒ stored false (strict)",
    storedVer && storedVer.top_n_beads[1].verified === false
  );

  // ── ANTI-DRIFT: schema registry carries workspace_inventory at v1 ─────────
  ck("workspace_inventory IS in the §4 schema registry at v1", schemaVersion("workspace_inventory") === 1);

  // ── ANTI-DRIFT: no rejected payload persisted ANY row (case2/3/7 ids) ─────
  for (const id of [
    "case2-no-top",
    "case2-no-ip",
    "case2-no-counts",
    "case3-no-sv",
    "case7-bad",
    "case7-noz",
    "case7-old",
    "case7-noobs",
  ]) {
    const row = await getRecord("workspace_inventory", id);
    ck(`no row persisted on rejection for id='${id}'`, row === null);
  }

  // ── ANTI-DRIFT: a `put workspace_inventory <id> <json>` ALSO works through
  //    the generic put path (since the type is now in the registry). This
  //    exercises the same §0.3/§9.1 gate via the substrate's `opPut` rather
  //    than the workspace-inventory-put handler — both must agree. (The
  //    handler is the producer's wire-shape gate; opPut is the substrate
  //    fallback the cf/src test suite expects to keep working for any
  //    registered §4 type.)
  const directPut = await call(GOOD, "put", [
    "workspace_inventory",
    "case-direct",
    JSON.stringify({
      schema_version: 1,
      project_ref: "case-direct",
      observed_at: nowIso(),
      counts: { open: 0, ready: 0, in_progress: 0, blocked: 0 },
      in_progress_beads: [],
      top_n_beads: [],
      runner_id: "rdirect",
    }),
  ]);
  ck("substrate `put workspace_inventory …` ⇒ 200 (type now registered)", directPut.status === 200);
  const directStored = await getRecord("workspace_inventory", "case-direct");
  ck("substrate `put` also stamps the §9.1 principal", directStored && directStored.principal === "brian");

  // eslint-disable-next-line no-console
  console.log(`\n  ${PASS} passed, ${FAIL} failed`);
  if (FAIL > 0) {
    // eslint-disable-next-line no-console
    console.log("  failures:\n   - " + fails.join("\n   - "));
  }
  expect(FAIL).toBe(0);
});
