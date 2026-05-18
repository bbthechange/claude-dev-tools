// CF.9 (claude-tools-7g0.9) — DIFFERENTIAL conformance test.
//
// Mirrors the CF.9-OWNED clauses of the bash focused test
// lib/test-notification.sh (T5.6 §4.3 persisted tiered record,
// one-per-Dossier, creation≠dispatch). Every assertion exercises the REAL
// engine via SELF.fetch (Worker → §9.1 chokepoint → singleton single-threaded
// Coordinator DO → D1) under the SAME workerd+miniflare runtime `wrangler
// dev` uses, NO Cloudflare account. The CF engine MUST exhibit the SAME
// INTERFACE.md v1 §4.3 (+ §4.1 tier source) / §0.3 behaviour as the bash
// oracle + that test:
//   EXIT-1  EXACTLY ONE Notification per Dossier (NOT one-per-Item); re-emit
//           idempotent (still one; created_at NOT reset).
//   EXIT-2  created_at + dispatched=false BEFORE any send (creation≠dispatch
//           — the C3 seam); dispatched/dispatched_at flip ONLY on send and
//           only false→true ONCE; fire-and-forget REJECTED.
//   EXIT-3  tier MIRRORS the §4.1 dossier tier; terse BY STRUCTURE — the
//           §4.3 set is closed (an injected body/content key REJECTED).
//   EXIT-4  schema_version=1 + principal stamped at the §9.1 chokepoint; an
//           unknown-higher version REJECTED on BOTH write and read paths.
//   EXIT-5  channel OPAQUE (round-trips verbatim — a later digest rollup
//           needs no schema change); NO §4 record type added; not advertised
//           as a §2 capability; the C3 creation hook (dossier-generate → ONE
//           Notification at creation).
//
// THE AD1 PAYOFF: one-per-Dossier + dispatched-once are TRUE BY CONSTRUCTION
// (the singleton DO is one actor; co._serialize makes each
// read→decide→write a single critical section on it), replacing the bash
// hand-rolled per-notification mkdir advisory lock.
//
// `env` (the D1 binding) is used ONLY to plant a §0.3-higher record and to
// count §4.3 rows — EXACTLY mirroring the bash test reading/writing the store
// directly (NREC / NCOUNT). No non-contract debug surface is added.

import { env, SELF } from "cloudflare:test";
import { it, expect } from "vitest";

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
// success = the bash `rc==0` analogue (op returned ok / a 2xx record body).
function good(r) {
  if (r.status === 200 && r.body === null) return true; // text/plain ok
  return !!(r.body && r.body.ok === true);
}
const nid = (did) => `notif.${did}`;
// NREC — the `co_request GOOD get notification <nid>` analogue (CF.1 opGet).
async function NREC(did) {
  const r = await call(GOOD, "get", ["notification", nid(did)]);
  if (r.status !== 200) return null;
  try {
    return JSON.parse(r.raw);
  } catch {
    return null;
  }
}
async function NF(did, key) {
  const rec = await NREC(did);
  return rec ? rec[key] : undefined;
}
// NCOUNT — the `ls records/notification.*.json | wc -l` analogue: count §4.3
// rows directly in the store (proves one-per-Dossier STRUCTURALLY).
async function NCOUNT() {
  const row = await env.DB.prepare(
    "SELECT COUNT(*) AS n FROM records WHERE type = 'notification'"
  ).first();
  return row ? row.n : 0;
}

// ── §4.1 envelope + §4.1.1 item builders (the bash mk()/item()) ─────────────
const mk = (id, tier, items) => ({
  id,
  schema_version: 2,
  kind: "decide",
  trigger: "proactive_checkpoint",
  bead_ref: "claude-tools-65z",
  tier,
  created_at: "2026-05-16T00:00:00Z",
  timer_fire_at: null,
  body: {
    dossier_schema_version: 2,
    tldr: "opaque",
    sections: [],
    diagrams: [],
    full_detail: "T5.2 owns this",
  },
  items,
});
const item = (i) => ({
  id: i,
  kind: "approve-reject",
  framing: {},
  context_anchor: { where: "x", expansion: "y" },
  consequence_block: { cb_schema_version: 2, creates: [], unblocks: [], labels: [], status_changes: [] },
  state: "open",
  response: null,
  consequence_applied: false,
  applied_at: null,
});
const items15 = () => Array.from({ length: 15 }, (_, k) => item(`i${k + 1}`));

it("CF.9 §4.3 Notification is behaviour-identical to lib/notification.sh + its test", async () => {
  // ════════════════════════════════════════════════════════════════════════
  // EXIT-1: EXACTLY ONE Notification per Dossier (NOT one-per-Item)
  // ════════════════════════════════════════════════════════════════════════
  ck("dossier-put seeds the 15-item dossier", good(await call(GOOD, "dossier-put", [mk("d15", "blocking", items15())])));
  const seeded = await call(GOOD, "get", ["dossier", "d15"]);
  ck(
    "the seeded dossier really has 15 Items",
    seeded.status === 200 && JSON.parse(seeded.raw).items.length === 15
  );
  const emit15 = await call(GOOD, "notif-emit", ["d15"]);
  ck("notif-emit succeeds on a 15-item dossier", good(emit15));
  ck("emit echoes the one-per-Dossier notification id", emit15.body && emit15.body.id === "notif.d15");
  ck("exactly ONE Notification row exists (NOT 15, NOT one-per-Item)", (await NCOUNT()) === 1);
  ck("the row announces the dossier (dossier_ref=d15)", (await NF("d15", "dossier_ref")) === "d15");
  ck("notification id derived one-per-Dossier", (await NF("d15", "id")) === "notif.d15");
  const CA1 = await NF("d15", "created_at");
  const emit15b = await call(GOOD, "notif-emit", ["d15"]);
  ck("re-emit returns the SAME notification id", emit15b.body && emit15b.body.id === "notif.d15");
  ck("re-emit did NOT create a second row (still one)", (await NCOUNT()) === 1);
  ck("re-emit did NOT reset created_at (one fork ⇒ one Notification)", (await NF("d15", "created_at")) === CA1);

  // ════════════════════════════════════════════════════════════════════════
  // EXIT-2: creation≠dispatch (C3) · false→true ONCE · no fire-&-forget
  // ════════════════════════════════════════════════════════════════════════
  await call(GOOD, "dossier-put", [mk("dC3", "timed-fyi", [item("a1")])]);
  await call(GOOD, "notif-emit", ["dC3"]);
  ck("created_at set at creation (a row exists before any send)", !!(await NF("dC3", "created_at")));
  ck("dispatched=false at creation (creation≠dispatch — C3)", (await NF("dC3", "dispatched")) === false);
  ck("dispatched_at=null at creation", (await NF("dC3", "dispatched_at")) === null);
  ck("channel=null at creation", (await NF("dC3", "channel")) === null);
  // fire-and-forget FORBIDDEN: dispatch with NO row is rejected.
  ck(
    "fire-and-forget REJECTED — dispatch a never-emitted Notification",
    !good(await call(GOOD, "notif-dispatch-for-dossier", ["dNeverEmitted"]))
  );
  ck("...and the never-emitted row was NOT created by the rejected dispatch", (await NREC("dNeverEmitted")) === null);
  // send: dispatched/dispatched_at flip ONLY here.
  ck("notif-dispatch succeeds (the send)", good(await call(GOOD, "notif-dispatch-for-dossier", ["dC3"])));
  ck("dispatched flipped true ONLY on send", (await NF("dC3", "dispatched")) === true);
  ck("dispatched_at stamped ONLY on send", !!(await NF("dC3", "dispatched_at")));
  ck("dispatched_at is no longer null", (await NF("dC3", "dispatched_at")) !== null);
  // false→true EXACTLY ONCE — a SECOND dispatch is rejected (single-writer-set).
  ck(
    "SECOND dispatch REJECTED (false→true ONCE — C3 latch)",
    !good(await call(GOOD, "notif-dispatch-for-dossier", ["dC3"]))
  );
  const DA1 = await NF("dC3", "dispatched_at");
  await call(GOOD, "notif-dispatch-for-dossier", ["dC3"]); // rejected
  ck("rejected re-dispatch did NOT re-stamp dispatched_at (NO write)", (await NF("dC3", "dispatched_at")) === DA1);

  // ════════════════════════════════════════════════════════════════════════
  // EXIT-3: tier mirrors §4.1 · terse by structure (principle 2)
  // ════════════════════════════════════════════════════════════════════════
  for (const T of ["blocking", "timed-fyi", "digest"]) {
    const D = `dT_${T.replace(/-/g, "_")}`;
    await call(GOOD, "dossier-put", [mk(D, T, [item("q1")])]);
    await call(GOOD, "notif-emit", [D]);
    ck(`tier mirrors the §4.1 dossier tier (${T})`, (await NF(D, "tier")) === T);
  }
  const GOODREC = await NREC("dT_blocking");
  ck("a well-formed §4.3 record validates", good(await call(GOOD, "notif-validate", [GOODREC])));
  ck(
    "a record with an injected 'body' key REJECTED (terse — principle 2)",
    !good(await call(GOOD, "notif-validate", [{ ...GOODREC, body: { tldr: "leak" } }]))
  );
  ck(
    "a record with a 'content' key REJECTED (no content — principle 2)",
    !good(await call(GOOD, "notif-validate", [{ ...GOODREC, content: "payload" }]))
  );
  ck(
    "the §4.3 record carries NO content/body/payload/items key (closed set)",
    Object.keys(GOODREC).filter((k) => ["body", "content", "payload", "items"].includes(k)).length === 0
  );

  // ════════════════════════════════════════════════════════════════════════
  // EXIT-4: schema_version=1 · principal stamped (§9.1) · §0.3
  // ════════════════════════════════════════════════════════════════════════
  ck("schema_version=1 persisted (§4.3)", (await NF("dT_blocking", "schema_version")) === 1);
  const bsv = await call(GOOD, "notif-bound-sv", []);
  ck("bound version READ from the §4 registry (= notification⇒1, not a local literal)", bsv.raw === "1");
  ck("CF.1 STAMPED principal=PRINCIPAL_V1 at the §9.1 chokepoint", (await NF("dT_blocking", "principal")) === "brian");
  // §0.3 — unknown HIGHER schema_version rejected on the WRITE path (validate
  // is the producer-side gate; CF.1 _writeRecord re-enforces it too).
  ck(
    "§0.3 — schema_version 2 REJECTED by notif-validate (unknown higher)",
    !good(await call(GOOD, "notif-validate", [{ ...GOODREC, schema_version: 2 }]))
  );
  ck(
    '§0.3 — string "1" schema_version REJECTED (type-check)',
    !good(await call(GOOD, "notif-validate", [{ ...GOODREC, schema_version: "1" }]))
  );
  // §0.3 also bound on the READ path: a v3 slipped directly into the store
  // (bypassing the front door) must be REJECTED by notif-get, not parsed.
  await env.DB.prepare("INSERT OR REPLACE INTO records (type,id,json) VALUES ('notification','notif.dRd',?)")
    .bind(JSON.stringify({ ...GOODREC, schema_version: 3, id: "notif.dRd", dossier_ref: "dRd" }))
    .run();
  ck(
    "§0.3 — notif-get REJECTS an unknown-higher stored record (read path)",
    !good(await call(GOOD, "notif-get", ["notif.dRd"]))
  );
  // §9.1 — no bearer ⇒ rejected at the ONE chokepoint (401, BEFORE the DO).
  ck("§9.1 — missing bearer ⇒ notif-emit REJECTED (401)", (await call(null, "notif-emit", ["dT_blocking"])).status === 401);
  ck(
    "§9.1 — emit on a MISSING dossier REJECTED (collapses 401/absent — C4)",
    !good(await call(GOOD, "notif-emit", ["noSuchDossier"]))
  );

  // ════════════════════════════════════════════════════════════════════════
  // EXIT-5: binds §4.3 · channel OPAQUE · anti-drift (structural)
  // ════════════════════════════════════════════════════════════════════════
  await call(GOOD, "dossier-put", [mk("dCh", "digest", [item("z1")])]);
  await call(GOOD, "notif-emit", ["dCh"]);
  const OPAQUE = "digest-rollup::weekly::xyz#42";
  ck(
    "notif-dispatch accepts an arbitrary OPAQUE channel tag",
    good(await call(GOOD, "notif-dispatch-for-dossier", ["dCh", OPAQUE]))
  );
  ck("the opaque channel tag round-trips VERBATIM (no schema change — C3)", (await NF("dCh", "channel")) === OPAQUE);
  // No §4 record type added; the registry is UNCHANGED (notification was
  // already registered — CF.9 adds none and never edits the registry).
  ck("§4 registry UNCHANGED — notification⇒1 (no schema bump)", (await call(GOOD, "notif-bound-sv", [])).raw === "1");
  ck(
    "NO §4 record type added — 'notify' is unknown_type",
    (await call(GOOD, "put", ["notify", "z", '{"schema_version":1}'])).body?.code === "unknown_type"
  );
  ck(
    "dossier registry entry dossier⇒2 (v2 §11 Mermaid amend; notification added no record type) — a v3 dossier is still §0.3-rejected",
    !good(await call(GOOD, "dossier-put", [{ ...mk("dRegChk", "blocking", []), schema_version: 3 }]))
  );
  const capsRes = await SELF.fetch(
    new Request("https://coordinator.local/", { method: "GET", headers: { authorization: `Bearer ${GOOD}` } })
  );
  const caps = await capsRes.text();
  ck("CF.1 capabilities still EXACTLY four §2 lines", (caps.match(/§2/g) || []).length === 4);
  ck(
    "no notification op is advertised as a §2 capability",
    !/no_emit|no_dispatch|notif-emit|notif-dispatch/.test(caps)
  );
  // The C3 creation hook: dossier-generate (CF.6) → ONE Notification at
  // creation, mirroring its tier, dispatched=false (creation≠dispatch).
  const GI = {
    id: "dGen",
    trigger: "proactive_checkpoint",
    bead_ref: "claude-tools-65z",
    tier: "timed-fyi",
    source: { tldr: "t", sections: [{ heading: "H", prose: "P" }], diagrams: [], full_detail: "FD" },
    items: [],
  };
  const fg = await call(GOOD, "notif-for-generation", [GI]);
  ck("notif-for-generation consumes the CF.6 hook + emits ONE Notification", fg.body && fg.body.id === "notif.dGen");
  ck("the generated dossier's Notification mirrors its tier (timed-fyi)", (await NF("dGen", "tier")) === "timed-fyi");
  ck("creation≠dispatch holds via the hook (dispatched=false at creation)", (await NF("dGen", "dispatched")) === false);

  // eslint-disable-next-line no-console
  console.log(`\n══ CF.9 differential (vs lib/notification.sh + test-notification.sh): PASS=${PASS} FAIL=${FAIL} ══`);
  if (FAIL > 0) {
    // eslint-disable-next-line no-console
    console.log("FAILED:\n  - " + fails.join("\n  - "));
  }
  expect(FAIL, `differential clauses failed: ${fails.join("; ")}`).toBe(0);
});
