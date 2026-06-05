// L1 follow-up (claude-tools-uxl1b) §5.6 — DEFER / ESCALATE: the two remaining
// Inbox verbs, as DISTINCT engine ops (no verb defaults to another's payload —
// the L1 empty-payload bug class).
//
//   dossier-defer    → tier="digest"   ("push out without resolution")
//   dossier-escalate → tier="blocking" ("promote to higher-attention surface")
//
// They adjust the §4.1 attention tier AND disarm the §2.2 timer: no §5.2
// response, no §5.3 ConsequenceBlock, no per-Item state move — but a real move
// nulls timer_fire_at (both targets are non-auto-proceed tiers, claude-tools-
// fyci). Total + idempotent (re-running at the target tier is a no-op). They
// NEVER target `timed-fyi` (the auto-proceed lane) — escalate(timed-fyi)→
// blocking and defer(timed-fyi)→digest both move OUT of it AND disarm it.
//
// Exercises the REAL engine via SELF.fetch (Worker §9.1 chokepoint → singleton
// Coordinator DO → D1) under the SAME workerd+miniflare runtime as the CF.6
// differential. Self-contained harness so it never perturbs dossier.spec.js's
// shared counters. Bash twin: lib/dossier.sh do_dossier_defer/do_dossier_escalate
// (test-dossier.sh EXIT-DEFER).

import { env, SELF } from "cloudflare:test";
import { it, expect } from "vitest";

const GOOD = "bearer-runner-secret-xyz";

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
    try { body = JSON.parse(raw); } catch { body = null; }
  }
  return { status: res.status, raw, body };
}
function good(r) {
  if (r.status === 200 && r.body === null) return true; // text/plain ok
  return !!(r.body && r.body.ok === true);
}
async function GET(id) {
  const r = await call(GOOD, "dossier-get", [id]);
  if (r.status !== 200) return null;
  try { return JSON.parse(r.raw); } catch { return null; }
}
const tierOf = (rec) => (rec && typeof rec.tier === "string" ? rec.tier : undefined);
const istate = (rec, iid) => {
  const it = rec && rec.items && rec.items.find((x) => x.id === iid);
  return it ? it.state : undefined;
};
async function workPlaneRows() {
  const { results } = await env.DB.prepare("SELECT line FROM work_plane_ops").all();
  return (results || []).length;
}
async function waitingHas(bref) {
  const r = await call(GOOD, "work-snapshot", []);
  const w = r.body && Array.isArray(r.body.waiting_on_you) ? r.body.waiting_on_you : [];
  return w.some((x) => x.bead_ref === bref);
}

// a v2 dossier for <bref> at <tier> with explicit per-item {id,state,response}.
const mkFor = (id, bref, items, tier = "blocking", timer = null) => ({
  id, schema_version: 2, kind: "decide", trigger: "worker_stuck",
  bead_ref: bref, tier, created_at: "2026-05-30T00:00:00Z",
  timer_fire_at: timer,
  body: { dossier_schema_version: 2, tldr: "t", sections: [], diagrams: [], full_detail: "f" },
  items: items.map((x) => ({
    id: x.id, kind: x.kind ?? "approve-reject", framing: {},
    context_anchor: { where: "x", expansion: "y" },
    consequence_block: { cb_schema_version: 2, creates: [], unblocks: [], labels: [], status_changes: [] },
    reversible: "r",
    state: x.state, response: x.response ?? null, consequence_applied: false, applied_at: null,
  })),
});

it("L1 follow-up (claude-tools-uxl1b) §5.6 — defer / escalate adjust the attention tier, nothing else", async () => {
  let P = 0, F = 0;
  const fl = [];
  const ck = (name, cond) => {
    if (cond) { P++; console.log(`  ✓ ${name}`); }
    else { F++; fl.push(name); console.log(`  ✗ ${name}`); }
  };

  // ── defer a blocking decision → digest; items untouched; still on the Inbox ─
  const BREF = "thirsty-uxl1b-a";
  const D = mkFor("de-d1", BREF, [
    { id: "open1", state: "open" },
    { id: "ans1", state: "answered", response: { decision: "approve", responded_at: "2026-05-30T01:00:00Z" } },
  ], "blocking");
  ck("plant a v2 BLOCKING decision dossier (open + answered items)", good(await call(GOOD, "dossier-put", [D])));
  ck("BEFORE: the dossier shows on the Inbox (waiting_on_you)", await waitingHas(BREF));

  const r1 = await call(GOOD, "dossier-defer", ["de-d1"]);
  ck("dossier-defer accepted (ok)", good(r1));
  ck("dossier-defer reports the new tier=digest", r1.body && r1.body.tier === "digest");
  ck("dossier-defer reports it MOVED (not idempotent)", r1.body && r1.body.from === "blocking" && !r1.body.idempotent);
  const S1 = await GET("de-d1");
  ck("defer set tier→digest", tierOf(S1) === "digest");
  ck("defer left the OPEN item untouched (no resolution)", istate(S1, "open1") === "open");
  ck("defer left the ANSWERED item untouched (recommendation NOT consumed)", istate(S1, "ans1") === "answered");
  const ans = S1 && S1.items.find((x) => x.id === "ans1");
  ck("defer preserved the recorded .response verbatim", !!ans && ans.response && ans.response.decision === "approve");
  ck("defer left every consequence_applied latch false", S1.items.every((x) => x.consequence_applied === false));
  ck("defer left timer_fire_at untouched (null)", S1.timer_fire_at === null);
  ck("defer fired NO work-plane ConsequenceBlock op", (await workPlaneRows()) === 0);
  ck("AFTER defer: STILL on the Inbox — tier-agnostic, items still non-terminal (§5.6 'without resolution')", await waitingHas(BREF));

  // ── idempotent defer at the floor ─────────────────────────────────────────
  const r1b = await call(GOOD, "dossier-defer", ["de-d1"]);
  ck("second defer (already digest) ⇒ { ok:true, idempotent:true } (no write)",
    r1b.body && r1b.body.ok === true && r1b.body.idempotent === true && r1b.body.tier === "digest");

  // ── escalate digest → blocking (the reverse) ───────────────────────────────
  const r2 = await call(GOOD, "dossier-escalate", ["de-d1"]);
  ck("dossier-escalate accepted (ok)", good(r2));
  ck("escalate set tier→blocking", tierOf(await GET("de-d1")) === "blocking");
  ck("escalate reports from=digest → blocking (moved)", r2.body && r2.body.from === "digest" && r2.body.tier === "blocking");
  const r2b = await call(GOOD, "dossier-escalate", ["de-d1"]);
  ck("second escalate (already blocking) ⇒ idempotent no-op", r2b.body && r2b.body.idempotent === true && r2b.body.tier === "blocking");

  // ── timed-fyi is the auto-proceed lane: verbs move OUT of it AND disarm it ──
  // Plant the cards with an ARMED timer (timer_fire_at set) so the disarm is
  // observable: escalate/defer must move the tier OUT *and* null timer_fire_at
  // (claude-tools-fyci — kill the digest+armed-timer edge at the source).
  const D2 = mkFor("de-fyi", "thirsty-uxl1b-fyi", [{ id: "f1", state: "open", kind: "fyi-objectable" }], "timed-fyi", "2026-06-01T00:00:00Z");
  ck("plant a timed-fyi (Flow F) overview WITH an armed timer", good(await call(GOOD, "dossier-put", [D2])));
  ck("BEFORE escalate: the timed-fyi card carries an armed timer_fire_at", (await GET("de-fyi")).timer_fire_at === "2026-06-01T00:00:00Z");
  ck("escalate(timed-fyi) → blocking (OUT of the auto-proceed lane — auto-proceed OFF)",
    good(await call(GOOD, "dossier-escalate", ["de-fyi"])) && tierOf(await GET("de-fyi")) === "blocking");
  ck("escalate(timed-fyi) DISARMED the timer (timer_fire_at now null — fyci)", (await GET("de-fyi")).timer_fire_at === null);
  // put it back to timed-fyi and verify defer also exits the lane (to digest), never stays timed-fyi
  await call(GOOD, "dossier-put", [mkFor("de-fyi2", "thirsty-uxl1b-fyi2", [{ id: "f1", state: "open", kind: "fyi-objectable" }], "timed-fyi", "2026-06-01T00:00:00Z")]);
  ck("defer(timed-fyi) → digest (OUT of the auto-proceed lane, never into/stays timed-fyi)",
    good(await call(GOOD, "dossier-defer", ["de-fyi2"])) && tierOf(await GET("de-fyi2")) === "digest");
  ck("defer(timed-fyi) DISARMED the timer (timer_fire_at now null — fyci)", (await GET("de-fyi2")).timer_fire_at === null);
  ck("a defer/escalate NEVER lands a dossier in timed-fyi", tierOf(await GET("de-fyi")) !== "timed-fyi" && tierOf(await GET("de-fyi2")) !== "timed-fyi");

  // ── reversibility round-trip preserves the item set exactly ────────────────
  await call(GOOD, "dossier-defer", ["de-d1"]);     // blocking → digest
  await call(GOOD, "dossier-escalate", ["de-d1"]);  // digest → blocking
  const S3 = await GET("de-d1");
  ck("round-trip defer→escalate leaves the items byte-identical",
    istate(S3, "open1") === "open" && istate(S3, "ans1") === "answered" && S3.items.length === 2);

  // ── rejection / chokepoint arms ────────────────────────────────────────────
  ck("dossier-defer on a missing dossier ⇒ reject (not found)", !good(await call(GOOD, "dossier-defer", ["de-nope"])));
  ck("dossier-escalate on a missing dossier ⇒ reject (not found)", !good(await call(GOOD, "dossier-escalate", ["de-nope"])));
  ck("dossier-defer with no id ⇒ reject", !good(await call(GOOD, "dossier-defer", [""])));
  ck("§9.1 — no bearer ⇒ 401 before any write (defer)",
    (await call(null, "dossier-defer", ["de-d1"])).status === 401);
  ck("§9.1 — no bearer ⇒ 401 before any write (escalate)",
    (await call(null, "dossier-escalate", ["de-d1"])).status === 401);
  // the 401s changed nothing
  ck("after the 401s the tier is unchanged (blocking)", tierOf(await GET("de-d1")) === "blocking");

  console.log(`\n== L1 follow-up defer/escalate (claude-tools-uxl1b): PASS=${P} FAIL=${F} ==`);
  if (F > 0) console.log("FAILED:\n  - " + fl.join("\n  - "));
  expect(F, `uxl1b clauses failed: ${fl.join("; ")}`).toBe(0);
});
