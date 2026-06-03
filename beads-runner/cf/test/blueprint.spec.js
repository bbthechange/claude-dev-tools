// H1 (claude-tools-uxvh1) — DESIGN H §2 blueprint §4 record DIFFERENTIAL
// conformance (the vitest twin of the bash-oracle test).
//
// Exercises the REAL engine (Worker → §9.1 chokepoint → singleton single-
// threaded Coordinator DO → D1) via SELF.fetch under the SAME workerd+miniflare
// runtime `wrangler dev` uses, NO Cloudflare account.
//
// What this proves (blueprint.md §2 + UX-V2-ARCHITECTURE A.2/B.2/B.4):
//   • put(section) → get round-trips: an upserted layer comes back VERBATIM in
//     the B.2 body {schema_version, project_ref, derived, customization,
//     narrative, conflicts[], updated_at, updated_by}.
//   • THE LOAD-BEARING SEAM — sectioned read-merge-write never clobbers: a
//     `derived` write then a `customization` write (and the reverse) leaves BOTH
//     layers intact; neither erases the other (§2.3, principle 9, must-protect #3).
//   • A first section-only write seeds the freshEmptyBlueprint skeleton (the
//     other layers exist, empty) — never a half-formed record.
//   • conflicts-append PUSHES (does not replace) — two appends ⇒ two entries, in
//     order; a `derived` replace does not touch conflicts[].
//   • Write gate (conformance at write — the one refusal point, B.4): missing
//     arg, bad JSON, non-object, missing/unsafe project_ref, unknown section, and
//     a non-object body each 422 and write NOTHING.
//   • blueprint-get on a missing/empty project_ref ⇒ 200 `null` (the honest
//     empty state), never a throw.
//   • updated_by is an INPUT, not the principal (§2.3): "you" / "agent:<hat>"
//     stored verbatim, distinct from the §9.1 principal stamp.
//   • §9.1: no/invalid token ⇒ 401 at the chokepoint; NOTHING written.
//   • Anti-drift — blueprint IS a §4 record (the INVERSE of the transient
//     siblings): schemaVersion('blueprint')===1; it is reachable via the generic
//     §4 get; the §0.3 integer-≤-bound gate rejects a higher schema_version; the
//     four §2 capability lines stay exactly four.

import { env, SELF } from "cloudflare:test";
import { it, expect } from "vitest";
import { schemaVersion } from "../src/schema.js";

const GOOD = "bearer-runner-secret-xyz";
const PR = "rhythmGame";

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

async function put(bearer, envelope) {
  return call(bearer, "blueprint-put", [JSON.stringify(envelope)]);
}
async function putRaw(bearer, arg) {
  return call(bearer, "blueprint-put", arg === undefined ? [] : [arg]);
}
async function get(bearer, projectRef) {
  return call(bearer, "blueprint-get", projectRef === undefined ? [] : [projectRef]);
}
async function bpRowCount() {
  try {
    const r = await env.DB.prepare("SELECT COUNT(*) AS n FROM records WHERE type = 'blueprint'").first();
    return r ? r.n : 0;
  } catch {
    return 0;
  }
}
async function freshStore() {
  try {
    await env.DB.prepare("DELETE FROM records WHERE type = 'blueprint'").run();
  } catch {
    /* table not lazily created yet = already empty */
  }
}

// A representative derived map (the §3 schema, leaf names A.4-free at H2).
function derived() {
  return {
    nodes: [
      { id: "domain:posts-feed", label: "Posts & Feed", kind: "domain", parent: null, source_refs: ["src/feed/**"], auto_opened: false },
      { id: "store:postgres", label: "Postgres", kind: "store", parent: null, source_refs: [], auto_opened: false },
    ],
    edges: [{ from: "domain:posts-feed", to: "store:postgres", kind: "call", bundle_key: "posts-feed→postgres" }],
    apis: [{ id: "api:POST-/posts", domain: "domain:posts-feed", route: "POST /posts", calls: ["capability:create-post"] }],
  };
}
function customization() {
  return {
    renames: { "capability:create-post": "Publish" },
    regroups: {},
    pins: ["domain:posts-feed"],
    hidden: ["vendor:datadog"],
    splits: [],
    merges: [],
  };
}

// ════════════════════════════════════════════════════════════════════════════
it("H1 blueprint §4 record is contract-faithful to DESIGN H §2 + UX-V2-ARCHITECTURE A.2/B.2/B.4", async () => {
  // ── PUT(derived) → GET ROUND-TRIP (the B.2 body) ───────────────────────────
  await freshStore();
  const d = derived();
  const p1 = await put(GOOD, { project_ref: PR, section: "derived", body: d, updated_by: "agent:blueprint-update" });
  ck("blueprint-put(derived) ⇒ 200 {ok:true, project_ref}", p1.status === 200 && p1.body && p1.body.ok === true && p1.body.project_ref === PR);
  ck("put stored exactly one blueprint row in the §4 records table", (await bpRowCount()) === 1);

  const g1 = await get(GOOD, PR);
  ck("blueprint-get ⇒ 200 with the B.2 record body", g1.status === 200 && g1.body && typeof g1.body === "object");
  const b1 = g1.body || {};
  ck("body.schema_version === 1 (§0.3 integer)", b1.schema_version === 1);
  ck("body.project_ref echoes the id", b1.project_ref === PR);
  ck("body.derived round-trips VERBATIM", JSON.stringify(b1.derived) === JSON.stringify(d));
  ck("body.updated_by is the INPUT (agent:blueprint-update), not the principal", b1.updated_by === "agent:blueprint-update");
  ck("body.updated_at is a stamped string", typeof b1.updated_at === "string" && b1.updated_at.length > 0);
  ck("freshEmptyBlueprint seeded the other layers (customization sub-shape present)", b1.customization && typeof b1.customization === "object" && Array.isArray(b1.customization.pins));
  ck("freshEmptyBlueprint seeded narrative + conflicts[]", b1.narrative && typeof b1.narrative === "object" && Array.isArray(b1.conflicts));

  // ── THE LOAD-BEARING SEAM: sectioned never-clobber (§2.3) ───────────────────
  // A customization write AFTER a derived write must NOT erase derived.
  const c = customization();
  const p2 = await put(GOOD, { project_ref: PR, section: "customization", body: c, updated_by: "you" });
  ck("blueprint-put(customization) ⇒ 200", p2.status === 200 && p2.body && p2.body.ok === true);
  ck("still exactly one row (same (type,id) merged, not a second record)", (await bpRowCount()) === 1);
  const g2 = await get(GOOD, PR);
  const b2 = g2.body || {};
  ck("after customization write, derived is STILL intact (no clobber)", JSON.stringify(b2.derived) === JSON.stringify(d));
  ck("after customization write, customization is the new value", JSON.stringify(b2.customization) === JSON.stringify(c));
  ck("updated_by switched to the customization writer (you)", b2.updated_by === "you");

  // And the reverse order on a FRESH store: customization first, then derived —
  // a section-only first write seeds the skeleton; the later derived write does
  // not erase the customization.
  await freshStore();
  await put(GOOD, { project_ref: PR, section: "customization", body: c, updated_by: "you" });
  const gMid = await get(GOOD, PR);
  const bMid = gMid.body || {};
  ck("a first customization-only write yields a full record (derived = empty skeleton)", bMid.derived && Array.isArray(bMid.derived.nodes) && bMid.derived.nodes.length === 0);
  ck("the first customization-only write stored the customization", JSON.stringify(bMid.customization) === JSON.stringify(c));
  await put(GOOD, { project_ref: PR, section: "derived", body: d, updated_by: "agent:blueprint-update" });
  const gRev = await get(GOOD, PR);
  const bRev = gRev.body || {};
  ck("derived write after customization does NOT clobber customization (reverse order)", JSON.stringify(bRev.customization) === JSON.stringify(c));
  ck("derived write after customization landed derived", JSON.stringify(bRev.derived) === JSON.stringify(d));

  // ── conflicts-append PUSHES, does not replace (§2.3) ───────────────────────
  await freshStore();
  await put(GOOD, { project_ref: PR, section: "derived", body: d, updated_by: "agent:blueprint-update" });
  const cf1 = { kind: "rename-orphan", node_id: "capability:create-post", custom: "Publish", note: "no longer maps to code" };
  const cf2 = { kind: "hide-orphan", node_id: "vendor:datadog", custom: "(hidden)", note: "vendor removed" };
  await put(GOOD, { project_ref: PR, section: "conflicts-append", body: cf1, updated_by: "agent:blueprint-update" });
  await put(GOOD, { project_ref: PR, section: "conflicts-append", body: cf2, updated_by: "agent:blueprint-update" });
  const gc = await get(GOOD, PR);
  const bc = gc.body || {};
  ck("conflicts-append pushed two entries (not replaced)", Array.isArray(bc.conflicts) && bc.conflicts.length === 2);
  ck("conflicts are in append order", bc.conflicts[0] && bc.conflicts[0].node_id === "capability:create-post" && bc.conflicts[1] && bc.conflicts[1].node_id === "vendor:datadog");
  ck("a derived replace did not wipe conflicts[]", JSON.stringify(bc.derived) === JSON.stringify(d));

  // ── WRITE GATE — conformance at write; each rejects with NOTHING written ────
  await freshStore();
  await put(GOOD, { project_ref: PR, section: "derived", body: d, updated_by: "agent:blueprint-update" }); // a baseline row
  const baseN = await bpRowCount();
  const rejects = async (envelope) => {
    const before = await bpRowCount();
    const res = await put(GOOD, envelope);
    const after = await bpRowCount();
    return res.status === 422 && before === after;
  };
  ck("unknown section ⇒ 422; nothing written", await rejects({ project_ref: PR, section: "bogus", body: {} }));
  ck("missing project_ref ⇒ 422", await rejects({ section: "derived", body: {} }));
  ck("unsafe project_ref ('..') ⇒ 422", await rejects({ project_ref: "../etc", section: "derived", body: {} }));
  ck("unsafe project_ref ('/') ⇒ 422", await rejects({ project_ref: "a/b", section: "derived", body: {} }));
  ck("body not an object (array) ⇒ 422", await rejects({ project_ref: PR, section: "derived", body: [1, 2] }));
  ck("body not an object (scalar) ⇒ 422", await rejects({ project_ref: PR, section: "customization", body: "nope" }));
  ck("body null ⇒ 422", await rejects({ project_ref: PR, section: "narrative", body: null }));
  ck("baseline row survived every rejected write (nothing clobbered)", (await bpRowCount()) === baseN);

  const rawReject = async (arg) => {
    const before = await bpRowCount();
    const res = await putRaw(GOOD, arg);
    const after = await bpRowCount();
    return res.status === 422 && before === after;
  };
  ck("invalid JSON arg ⇒ 422; nothing written", await rawReject("{not-json"));
  ck("array (not an object) envelope ⇒ 422", await rawReject(JSON.stringify([1, 2, 3])));
  ck("missing arg ⇒ 422", await rawReject(undefined));

  // ── blueprint-get on a missing / empty project_ref ⇒ null (honest empty) ───
  const gMiss = await get(GOOD, "does-not-exist-ws");
  ck("blueprint-get(missing) ⇒ 200 body null (the honest empty state, B.4)", gMiss.status === 200 && gMiss.body === null);
  const gEmpty = await get(GOOD, "");
  ck("blueprint-get('') ⇒ 200 null (never a throw)", gEmpty.status === 200 && gEmpty.body === null);

  // ── §2.3 updated_by is an input, distinct from the §9.1 principal stamp ─────
  await freshStore();
  await put(GOOD, { project_ref: PR, section: "derived", body: d, updated_by: "you" });
  const gpr = await get(GOOD, PR);
  ck("updated_by stays the input 'you' (never overwritten by the principal)", gpr.body && gpr.body.updated_by === "you");
  ck("the §9.1 principal IS stamped on the record (distinct from updated_by)", gpr.body && gpr.body.principal === "brian");

  // ── §9.1 — no/invalid token ⇒ rejected at the chokepoint; NOTHING written ──
  await freshStore();
  const noTok = await put(null, { project_ref: PR, section: "derived", body: d });
  ck("no-token blueprint-put ⇒ 401 at the Worker (one chokepoint)", noTok.status === 401);
  ck("no-token blueprint-put wrote NOTHING", (await bpRowCount()) === 0);
  env.CO_EXPECTED_TOKEN = "expected";
  const badTok = await put("wrong", { project_ref: PR, section: "derived", body: d });
  ck("invalid-token blueprint-put ⇒ 401", badTok.status === 401);
  const badGet = await get("wrong", PR);
  ck("invalid-token blueprint-get ⇒ 401 (read is behind the chokepoint too)", badGet.status === 401);
  delete env.CO_EXPECTED_TOKEN;
  ck("invalid-token blueprint-put wrote NOTHING", (await bpRowCount()) === 0);

  // ── ANTI-DRIFT — blueprint IS a §4 record (the INVERSE of the transients) ──
  ck("'blueprint' IS a §4 record type (schemaVersion === 1, not null)", schemaVersion("blueprint") === 1);
  await freshStore();
  await put(GOOD, { project_ref: PR, section: "derived", body: d, updated_by: "agent:blueprint-update" });
  const g4 = await call(GOOD, "get", ["blueprint", PR]);
  ck("the generic §4 get reaches a blueprint record (it is addressable by (type,id))", g4.status === 200 && g4.raw.includes("domain:posts-feed"));
  // the §0.3 integer-≤-bound gate applies to blueprint via the generic §4 put.
  const hi = await call(GOOD, "put", ["blueprint", "ws2", JSON.stringify({ schema_version: 2, project_ref: "ws2" })]);
  ck("§4 put blueprint with a HIGHER schema_version ⇒ 422 (the §0.3 reject)", hi.status === 422 && hi.body && hi.body.code === "higher_version");
  const v1 = await call(GOOD, "put", ["blueprint", "ws2", JSON.stringify({ schema_version: 1, project_ref: "ws2" })]);
  ck("§4 put blueprint at the bound v1 ⇒ accepted (it is a known §4 type)", v1.status === 200);
  const caps = await call(GOOD, "capabilities", []);
  const n4 = (caps.raw.match(/§2/g) || []).length;
  ck("co_capabilities still EXACTLY four §2 lines (CF.1 substrate untouched)", n4 === 4);
  ck("co_capabilities does NOT advertise blueprint as a §2 capability", !caps.raw.includes("blueprint"));

  expect(FAIL, `H1 blueprint conformance failed: ${fails.join("; ")}`).toBe(0);
});
