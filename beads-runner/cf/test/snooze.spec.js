// L1 follow-up (claude-tools-653d) §5.6 — SNOOZE: the §5.6 verb family's third
// member (defer/escalate are the others). "Get this decision out of my face NOW,
// bring it BACK at a time I pick." inbox-lifecycle §5.6 listed snooze as "(future)
// — like timer expiry, set by user"; it was unbuilt because it needs a
// "surface-at-T not auto-proceed" fire-action (the SAME primitive N3 ready-to-pair
// built — DESIGN N §4.3), NOT the timed-fyi auto-proceed the only timer shipped.
//
//   dossier-snooze {dossier_id, snooze_until} → tier="digest" + timer_fire_at +
//       snoozed_until = snooze_until, and ARM the §2.2 re-surface timer.
//   snooze-surface (the fire-action @ snooze_until) → re-tier blocking, clear the
//       snooze fields, best-effort new_dossier ping; NEVER auto-proceed, NEVER a CB.
//
// A DISTINCT engine verb (no payload defaulting — the uxl1b contract). Exercises
// the REAL engine via SELF.fetch (Worker §9.1 chokepoint → singleton Coordinator
// DO → D1) under the SAME workerd+miniflare runtime as the CF differential — NO
// Cloudflare account. Self-contained harness so it never perturbs the shared
// dossier.spec.js counters. Bash twin: lib/timed-fyi.sh do_dossier_snooze /
// snooze_surface + their tf_poll routing (lib/test-snooze.sh).

import { env, SELF, runDurableObjectAlarm } from "cloudflare:test";
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
async function resetBd() {
  await env.DB.prepare("DELETE FROM work_plane_ops").run();
}
async function BDN(re) {
  const { results } = await env.DB.prepare("SELECT line FROM work_plane_ops").all();
  const rx = new RegExp(re);
  return (results || []).filter((r) => rx.test(r.line)).length;
}
async function waitingHas(bref) {
  const r = await call(GOOD, "work-snapshot", []);
  const w = r.body && Array.isArray(r.body.waiting_on_you) ? r.body.waiting_on_you : [];
  return w.some((x) => x.bead_ref === bref);
}
// the §4.3 notification for a dossier (notif-get-for-dossier: 200 on found).
async function NREC(id) {
  const r = await call(GOOD, "notif-get-for-dossier", [id]);
  if (r.status !== 200) return null;
  try { return JSON.parse(r.raw); } catch { return null; }
}
const NHAS = async (id) => (await NREC(id)) !== null;
async function DUE(id, now) {
  const r = await call(GOOD, "timer-due", now === undefined ? [] : [now]);
  return r.raw.split("\n").filter(Boolean).includes(id);
}

// Future-pinned epochs (the ready-to-pair.spec.js discipline): opTimerArm calls a
// REAL ctx.storage.setAlarm — a snooze_until in the FAR future never fires
// spontaneously, so the explicit timed-fyi-poll driver is deterministic. NEAR <
// SNZ < FAR. EXIT-ALARM uses a deep-PAST time (planted directly, bypassing the
// future-guard) to exercise the real setAlarm() callback.
const CA = "2026-05-30T00:00:00Z";
const NEAR = "2099-05-01T00:00:00Z"; // before the snooze fires
const SNZ = "2099-06-01T00:00:00Z"; // snooze_until (the re-surface time)
const FAR = "2099-07-01T00:00:00Z"; // well past snooze_until (poll fires it)

// a v2 BLOCKING decision dossier for <bref> with explicit per-item {id,state,response}.
const mkFor = (id, bref, items, tier = "blocking", timer = null) => ({
  id, schema_version: 2, kind: "decide", trigger: "worker_stuck",
  bead_ref: bref, tier, created_at: CA,
  timer_fire_at: timer,
  body: { dossier_schema_version: 2, tldr: "t", sections: [], diagrams: [], full_detail: "f" },
  items: items.map((x) => ({
    id: x.id, kind: x.kind ?? "approve-reject", framing: {},
    context_anchor: { where: "x", expansion: "y" },
    consequence_block: { cb_schema_version: 2, creates: [{ title: `new ${x.id}`, type: "task", priority: 2, labels: [], description: "d" }], unblocks: [], labels: [], status_changes: [] },
    reversible: "r",
    state: x.state, response: x.response ?? null, consequence_applied: false, applied_at: null,
  })),
});
// a v2 timed-fyi (Flow F) overview with a fyi-objectable item — the AUTO-PROCEED
// lane. created_at is FAR-FUTURE so timed-fyi-arm's computed fire_at
// (created_at + 86400 ≈ 2099-05-31) is also future — never a spontaneous
// setAlarm(past) that would preempt the explicit poll (the ready-to-pair gotcha).
const mkfyi = (id, bref, iid) => ({
  id, schema_version: 2, kind: "decide", trigger: "proactive_checkpoint",
  bead_ref: bref, tier: "timed-fyi", created_at: "2099-05-30T00:00:00Z", timer_fire_at: null,
  body: { dossier_schema_version: 2, tldr: "x", sections: [], diagrams: [], full_detail: "y" },
  items: [{
    id: iid, kind: "fyi-objectable", framing: {},
    context_anchor: { where: "x", expansion: "y" },
    consequence_block: { cb_schema_version: 2, creates: [{ title: `new ${iid}`, type: "task", priority: 2, labels: [], description: "d" }], unblocks: [], labels: [], status_changes: [] },
    reversible: "r", state: "open", response: null, consequence_applied: false, applied_at: null,
  }],
});

it("L1 follow-up (claude-tools-653d) §5.6 — snooze: defer now + RE-SURFACE (not auto-proceed) at T", async () => {
  let P = 0, F = 0;
  const fl = [];
  const ck = (name, cond) => {
    if (cond) { P++; console.log(`  ✓ ${name}`); }
    else { F++; fl.push(name); console.log(`  ✗ ${name}`); }
  };

  // ── EXIT-A: dossier-snooze ARM — defer (tier→digest) + arm the re-surface timer ─
  console.log("── EXIT-A: dossier-snooze defers + arms the §2.2 re-surface timer @ snooze_until ──");
  const BREF = "thirsty-653d-a";
  const D = mkFor("snz-d1", BREF, [
    { id: "open1", state: "open" },
    { id: "ans1", state: "answered", response: { decision: "approve", responded_at: "2026-05-30T01:00:00Z", principal: "brian" } },
  ], "blocking");
  ck("plant a v2 BLOCKING decision dossier (open + answered items)", good(await call(GOOD, "dossier-put", [D])));
  ck("BEFORE: the dossier shows on the Inbox (waiting_on_you)", await waitingHas(BREF));

  const r1 = await call(GOOD, "dossier-snooze", ["snz-d1", SNZ]);
  ck("dossier-snooze accepted (ok)", good(r1));
  ck("dossier-snooze reports tier=digest + the snooze_until", r1.body && r1.body.tier === "digest" && r1.body.snooze_until === SNZ);
  const S1 = await GET("snz-d1");
  ck("snooze set tier→digest (deferred out of the foreground)", tierOf(S1) === "digest");
  ck("snooze wrote timer_fire_at = snooze_until (the §4.1 field the timer fires on)", S1.timer_fire_at === SNZ);
  ck("snooze wrote snoozed_until = snooze_until (the fireDueTimers routing discriminator)", S1.snoozed_until === SNZ);
  ck("snooze left the OPEN item untouched (no resolution)", istate(S1, "open1") === "open");
  ck("snooze left the ANSWERED item untouched (recommendation NOT consumed)", istate(S1, "ans1") === "answered");
  const ans = S1 && S1.items.find((x) => x.id === "ans1");
  ck("snooze preserved the recorded .response verbatim", !!ans && ans.response && ans.response.decision === "approve");
  ck("snooze left every consequence_applied latch false", S1.items.every((x) => x.consequence_applied === false));
  ck("snooze fired NO work-plane ConsequenceBlock op", (await workPlaneRows()) === 0);
  ck("AFTER snooze: STILL on the Inbox (digest + ≥1 open item — out of foreground, not resolved)", await waitingHas(BREF));
  ck("§2.2 timer armed fire(dossier_id)=snz-d1, DUE after snooze_until", await DUE("snz-d1", FAR));
  ck("NOT due BEFORE snooze_until (snoozed, not yet re-surfaced)", !(await DUE("snz-d1", NEAR)));

  // re-snooze to a LATER time re-schedules (overwrites; not idempotent — always re-arms)
  const SNZ2 = "2099-06-15T00:00:00Z";
  const r1b = await call(GOOD, "dossier-snooze", ["snz-d1", SNZ2]);
  ck("re-snooze to a later time succeeds (re-schedule)", good(r1b));
  ck("re-snooze updated snoozed_until + timer_fire_at to the new time", (await GET("snz-d1")).snoozed_until === SNZ2 && (await GET("snz-d1")).timer_fire_at === SNZ2);

  // rejections — fail-closed (NO write, NO timer)
  ck("snooze on a missing dossier ⇒ reject", !good(await call(GOOD, "dossier-snooze", ["snz-nope", SNZ])));
  ck("snooze with no id ⇒ reject", !good(await call(GOOD, "dossier-snooze", ["", SNZ])));
  ck("snooze with no snooze_until ⇒ reject", !good(await call(GOOD, "dossier-snooze", ["snz-d1", ""])));
  ck("snooze with an unparseable snooze_until ⇒ reject", !good(await call(GOOD, "dossier-snooze", ["snz-d1", "not-a-date"])));
  ck("snooze with a PAST snooze_until ⇒ reject (a snooze re-surfaces LATER, not now)", !good(await call(GOOD, "dossier-snooze", ["snz-d1", "2000-01-01T00:00:00Z"])));
  ck("§9.1 — no bearer ⇒ 401 before any write", (await call(null, "dossier-snooze", ["snz-d1", SNZ])).status === 401);

  // ── EXIT-B: snooze-surface — SURFACE ≠ auto-proceed ──
  console.log("── EXIT-B: snooze-surface re-tiers to blocking + pings; NO auto-proceed, NO consequence ──");
  await resetBd();
  const surf = await call(GOOD, "snooze-surface", ["snz-d1"]);
  ck("snooze-surface succeeds", good(surf));
  const SB = await GET("snz-d1");
  ck("surface RE-tiered the card back to the foreground (digest→blocking)", tierOf(SB) === "blocking");
  ck("surface CLEARED timer_fire_at (the timer fired, no longer snoozed)", SB.timer_fire_at === null);
  ck("surface CLEARED snoozed_until (no longer snoozed)", SB.snoozed_until === null);
  ck("surface applied NO item — open1 stays OPEN (re-surface, not auto-proceed)", istate(SB, "open1") === "open");
  ck("surface left the answered item answered (recommendation NOT consumed)", istate(SB, "ans1") === "answered");
  ck("surface left every latch false (NO §7.4 auto-apply)", SB.items.every((x) => x.consequence_applied === false));
  ck("surface fired NO §5.3 consequence (no bd create — surface is not auto-proceed)", (await BDN("create --title new open1")) === 0);
  ck("surface fired the blocking new_dossier notification (re-ping)", await NHAS("snz-d1"));
  const nrec = await NREC("snz-d1");
  ck("the surfaced notification is tier 'blocking' (new_dossier binds blocking — §10.2 r1)", nrec && nrec.tier === "blocking");

  // a no-longer-snoozed card ⇒ informational no-op success
  const surf2 = await call(GOOD, "snooze-surface", ["snz-d1"]);
  ck("snooze-surface on a no-longer-snoozed card ⇒ no-op success (fired:false)", surf2.body && surf2.body.ok === true && surf2.body.fired === false);

  // ── EXIT-C: the shared timer-due poll ROUTES a snoozed card to SURFACE ──
  console.log("── EXIT-C: the shared poll ROUTES a snoozed card to re-surface (NOT auto-proceed) ──");
  const Csnz = mkFor("snz-C", "thirsty-653d-c", [{ id: "c1", state: "open" }], "blocking");
  await call(GOOD, "dossier-put", [Csnz]);
  await call(GOOD, "dossier-snooze", ["snz-C", SNZ]);
  await call(GOOD, "dossier-put", [mkfyi("fyi-C", "thirsty-653d-fyi", "y1")]);
  await call(GOOD, "timed-fyi-arm", ["fyi-C"]);
  await resetBd();
  const polled = await call(GOOD, "timed-fyi-poll", [FAR]);
  const fired = (polled.body && polled.body.fired) || [];
  ck("poll surfaced the snoozed snz-C (in the fired list)", fired.includes("snz-C"));
  ck("poll surfaced the timed-fyi fyi-C (in the fired list)", fired.includes("fyi-C"));
  ck("ROUTED: snoozed snz-C RE-SURFACED — re-tiered to blocking", tierOf(await GET("snz-C")) === "blocking");
  ck("ROUTED: snoozed snz-C item c1 left OPEN (NO auto-proceed)", istate(await GET("snz-C"), "c1") === "open");
  ck("ROUTED: snoozed snz-C applied NO §5.3 consequence (no bd create for c1)", (await BDN("create --title new c1")) === 0);
  ck("ROUTED: snoozed snz-C cleared snoozed_until on surface", (await GET("snz-C")).snoozed_until === null);
  ck("ROUTED: timed-fyi fyi-C AUTO-PROCEEDED — y1 applied (the OTHER fire-action still works)", istate(await GET("fyi-C"), "y1") === "applied");
  ck("ROUTED: timed-fyi fyi-C applied its §5.3 consequence (bd create for y1)", (await BDN("create --title new y1")) === 1);

  // ── EXIT-ALARM (CF superset): the REAL §2.2 setAlarm() callback routes snooze→surface ──
  console.log("── EXIT-ALARM: the real DO alarm() re-surfaces a due snoozed card (setAlarm path) ──");
  await resetBd();
  // Plant directly (snoozed_until + timer_fire_at PAST) + raw timer-arm to bypass
  // the dossierSnooze future-guard — exactly the ready-to-pair EXIT-ALARM setup.
  const PAST = "2000-01-01T00:00:00Z";
  const Dalm = { ...mkFor("snz-alm", "thirsty-653d-alm", [{ id: "a1", state: "open" }], "digest", PAST), snoozed_until: PAST };
  await call(GOOD, "dossier-put", [Dalm]);
  await call(GOOD, "timer-arm", ["snz-alm", PAST]); // setAlarm(past) ⇒ alarm() delivered
  await runDurableObjectAlarm(env.COORDINATOR.get(env.COORDINATOR.idFromName("coordinator")));
  ck("alarm-fire RE-SURFACED the snoozed card (re-tiered to blocking)", tierOf(await GET("snz-alm")) === "blocking");
  ck("alarm-fire fired the blocking new_dossier notification", await NHAS("snz-alm"));
  ck("alarm-fire applied NO §5.3 consequence (surface, not auto-proceed)", (await BDN("create --title new a1")) === 0);
  ck("alarm-fire left the item OPEN (no §7.4 auto-apply)", istate(await GET("snz-alm"), "a1") === "open");

  console.log(`\n== L1 follow-up snooze (claude-tools-653d): PASS=${P} FAIL=${F} ==`);
  if (F > 0) console.log("FAILED:\n  - " + fl.join("\n  - "));
  expect(F, `653d clauses failed: ${fl.join("; ")}`).toBe(0);
});
