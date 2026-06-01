// N3 (claude-tools-uxg6) — READY-TO-PAIR DIFFERENTIAL conformance test.
//
// Mirrors lib/test-ready-to-pair.sh EXIT-A..E, one linear flow (the bash
// script is linear; per-file isolated storage gives this the bash test's
// fresh-mktemp store + fake-bin analogue). Every assertion exercises the REAL
// engine via SELF.fetch (Worker -> §9.1 chokepoint -> singleton Coordinator DO
// -> D1) under the SAME workerd+miniflare runtime, NO Cloudflare account. The
// CF pair fire-action MUST exhibit the SAME DESIGN N §4 / §2.2 / §10.2 behavior
// as timed-fyi.sh pair_arm/pair_surface + test-ready-to-pair.sh.
//
// CF SUPERSET (beyond the bash oracle): the bash test simulates "the alarm
// fires" by driving tf_poll (the §2.2 surface has no alarm daemon, by
// contract). Here EXIT-ALARM ALSO drives the REAL Durable Object `alarm()`
// callback via `runDurableObjectAlarm` to prove the alarm-fire path routes a
// due `kind:"pair"` timer to SURFACE (fire the blocking ready_to_pair notif),
// NOT to fireDossier auto-proceed.
//
// `env` (the D1 binding) is the work-plane sink grep analogue (the bash
// $BD_LOG fake-bin). No non-contract debug surface is added to the engine.

import { env, SELF, runDurableObjectAlarm } from "cloudflare:test";
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
function good(r) {
  if (r.status === 200 && r.body === null) return true; // text/plain ok
  return !!(r.body && r.body.ok === true);
}

// ── the bash test helpers (GET/ISTATE/ICA/NHAS/NREC/BDN/DUE) ────────────────
async function GET(id) {
  const r = await call(GOOD, "get", ["dossier", id]);
  if (r.status !== 200) return null;
  try {
    return JSON.parse(r.raw);
  } catch {
    return null;
  }
}
const _item = (rec, iid) =>
  rec && Array.isArray(rec.items) ? rec.items.find((x) => x && x.id === iid) : undefined;
const ISTATE = async (id, iid) => {
  const it = _item(await GET(id), iid);
  return it ? it.state : undefined;
};
const ICA = async (id, iid) => {
  const it = _item(await GET(id), iid);
  return it ? it.consequence_applied : undefined;
};
const TFA = async (id) => {
  const rec = await GET(id);
  return rec ? rec.timer_fire_at : undefined;
};
// NHAS/NREC — the §4.3 notification for a dossier (notif-get-for-dossier:
// 200 text on found, 404 on absent — the bash `co_request get notification`).
async function NREC(id) {
  const r = await call(GOOD, "notif-get-for-dossier", [id]);
  if (r.status !== 200) return null;
  try {
    return JSON.parse(r.raw);
  } catch {
    return null;
  }
}
const NHAS = async (id) => (await NREC(id)) !== null;
async function resetBd() {
  await env.DB.prepare("DELETE FROM work_plane_ops").run();
}
async function BDN(re) {
  const { results } = await env.DB.prepare("SELECT line FROM work_plane_ops").all();
  const rx = new RegExp(re);
  return (results || []).filter((r) => rx.test(r.line)).length;
}
async function DUE(id, now) {
  const r = await call(GOOD, "timer-due", now === undefined ? [] : [now]);
  return r.raw.split("\n").filter(Boolean).includes(id);
}

// Future-pinned epochs (the timer.spec.js discipline): opTimerArm calls a REAL
// ctx.storage.setAlarm — a PAST fire_at would fire alarm() spontaneously and
// preempt the explicit poll. The oracle-mirror blocks pin everything into the
// far FUTURE so the explicit driver is deterministic; EXIT-ALARM then uses a
// deep-PAST scheduled_at precisely to exercise the real setAlarm() callback.
const CA = "2099-05-16T00:00:00Z";
const SCHED = "2099-05-16T15:00:00Z"; // the appointment
const FAR = "2099-06-01T00:00:00Z"; // well past the appointment
const NEAR = "2099-05-16T12:00:00Z"; // before the appointment

const cb = (t) => ({
  cb_schema_version: 2,
  creates: [{ title: `new ${t}`, type: "task", priority: 2, labels: ["auto"], description: "d" }],
  unblocks: [`unb-${t}`],
  labels: [],
  status_changes: [],
});
const item_obj = (i) => ({
  id: i,
  kind: "fyi-objectable",
  framing: {},
  context_anchor: { where: "x", expansion: "y" },
  consequence_block: cb(i),
  reversible: "r",
  state: "open",
  response: null,
  consequence_applied: false,
  applied_at: null,
});
// §4.1 kind:"pair" SESSION CARD — tier blocking (§10.2 r10), a scheduled_at
// appointment, a conformant §5 body, NOT iterated as response Items (§4.2).
const mkpair = (id, scheduledAt, items = [], ca = CA) => {
  const env = {
    id,
    schema_version: 2,
    kind: "pair",
    trigger: "proactive_checkpoint",
    bead_ref: "claude-tools-uxg6",
    tier: "blocking",
    created_at: ca,
    timer_fire_at: null,
    body: {
      dossier_schema_version: 2,
      tldr: "pair on the activity blueprint",
      sections: [],
      diagrams: [],
      full_detail: "a scheduled working session",
    },
    items,
  };
  if (scheduledAt !== "") env.scheduled_at = scheduledAt;
  return env;
};
const mkdecide = (id) => ({
  id,
  schema_version: 2,
  kind: "decide",
  trigger: "proactive_checkpoint",
  bead_ref: "claude-tools-uxg6",
  tier: "blocking",
  created_at: CA,
  timer_fire_at: null,
  scheduled_at: SCHED,
  body: { dossier_schema_version: 2, tldr: "x", sections: [], diagrams: [], full_detail: "y" },
  items: [],
});
const mkfyi = (id, it) => ({
  id,
  schema_version: 2,
  kind: "decide",
  trigger: "proactive_checkpoint",
  bead_ref: "claude-tools-uxg6",
  tier: "timed-fyi",
  created_at: CA,
  timer_fire_at: null,
  body: { dossier_schema_version: 2, tldr: "x", sections: [], diagrams: [], full_detail: "y" },
  items: [it],
});
const PUT = (envObj) => call(GOOD, "dossier-put", [envObj]);
function coStub() {
  return env.COORDINATOR.get(env.COORDINATOR.idFromName("coordinator"));
}

it("N3 differential vs timed-fyi.sh pair_* + test-ready-to-pair.sh (DESIGN N §4 / §2.2 / §10.2)", async () => {
  // ── EXIT-A: pair-arm arms the §2.2 timer @ scheduled_at; bad input rejected ──
  console.log("── EXIT-A: pair-arm arms the §2.2 timer @ scheduled_at ──");
  await PUT(mkpair("dP1", SCHED, [item_obj("p1")]));
  const fa = await call(GOOD, "pair-arm", ["dP1"]);
  ck("pair-arm succeeds", good(fa));
  ck("pair-arm echoes the scheduled_at as fire_at", fa.body && fa.body.fire_at === SCHED);
  ck("§2.2 timer armed keyed fire(dossier_id)=dP1, due AFTER scheduled_at", await DUE("dP1", FAR));
  ck("NOT due BEFORE scheduled_at (upcoming, not ready)", !(await DUE("dP1", NEAR)));
  ck("pair-arm did NOT write timer_fire_at (scheduled_at is the pair's own field)", (await TFA("dP1")) === null);
  await PUT(mkdecide("dDec"));
  ck("pair-arm on a kind:'decide' dossier REJECTED", !good(await call(GOOD, "pair-arm", ["dDec"])));
  ck("rejected non-pair armed NO timer", !(await DUE("dDec", FAR)));
  await PUT(mkpair("dNo", "", []));
  ck("pair-arm on a pair with NO scheduled_at REJECTED", !good(await call(GOOD, "pair-arm", ["dNo"])));
  ck("missing-scheduled_at armed NO timer", !(await DUE("dNo", FAR)));
  await PUT(mkpair("dBad", "not-a-date", []));
  ck("pair-arm with unparseable scheduled_at REJECTED", !good(await call(GOOD, "pair-arm", ["dBad"])));
  ck("pair-arm on a MISSING dossier REJECTED", !good(await call(GOOD, "pair-arm", ["nodoss"])));
  ck("pair-arm with NO bearer REJECTED (§9.1)", !good(await call(null, "pair-arm", ["dP1"])));

  // ── EXIT-B: SURFACE ≠ auto-proceed ──
  console.log("── EXIT-B: SURFACE ≠ auto-proceed (upcoming→ready fires the blocking notif) ──");
  ck("BEFORE surface: NO §4.3 notification exists (cannot push early — upcoming)", !(await NHAS("dP1")));
  await resetBd();
  const surf = await call(GOOD, "pair-surface", ["dP1"]);
  ck("pair-surface succeeds", good(surf));
  ck("AFTER surface: a §4.3 notification now exists for the pair dossier", await NHAS("dP1"));
  const nrec = await NREC("dP1");
  ck("the surfaced notification is tier 'blocking' (§10.2 r10 — N2 pushes it)", nrec && nrec.tier === "blocking");
  ck("the blocking notification is left PENDING (dispatched=false; N2's latch)", nrec && nrec.dispatched === false);
  ck("SURFACE applied NO item — p1 stays OPEN (not iterated as §5 Items — §4.2)", (await ISTATE("dP1", "p1")) === "open");
  ck("p1 latch still false (NO §7.4 auto-apply on a pair surface)", (await ICA("dP1", "p1")) === false);
  ck("NO §5.3 consequence applied (no bd create — surface is not auto-proceed)", (await BDN("create --title new p1")) === 0);

  // ── EXIT-C: the shared timer-due poll ROUTES by kind ──
  console.log("── EXIT-C: the shared timer-due poll ROUTES by kind (pair vs timed-fyi) ──");
  await PUT(mkpair("dP2", SCHED, [item_obj("q1")]));
  await call(GOOD, "pair-arm", ["dP2"]);
  await PUT(mkfyi("dY1", item_obj("y1")));
  await call(GOOD, "timed-fyi-arm", ["dY1"]);
  await resetBd();
  const polled = await call(GOOD, "timed-fyi-poll", [FAR]);
  const fired = (polled.body && polled.body.fired) || [];
  ck("poll surfaced the pair dP2 (in the fired list)", fired.includes("dP2"));
  ck("poll surfaced the timed-fyi dY1 (in the fired list)", fired.includes("dY1"));
  ck("ROUTED: pair dP2 fired its blocking ready_to_pair notification", await NHAS("dP2"));
  ck("ROUTED: pair dP2 SURFACED — its item q1 left OPEN (no auto-proceed)", (await ISTATE("dP2", "q1")) === "open");
  ck("ROUTED: pair dP2 applied NO §5.3 consequence (no bd create for q1)", (await BDN("create --title new q1")) === 0);
  ck("ROUTED: timed-fyi dY1 AUTO-PROCEEDED — y1 applied", (await ISTATE("dY1", "y1")) === "applied");
  ck("ROUTED: timed-fyi dY1 applied its §5.3 consequence (bd create for y1)", (await BDN("create --title new y1")) === 1);

  // ── EXIT-D: idempotent re-surface (S-6 re-poll, no ack at fire) ──
  console.log("── EXIT-D: idempotent re-surface (S-6 re-poll, no ack at fire) ──");
  await resetBd();
  const re1 = await NREC("dP1");
  await call(GOOD, "pair-surface", ["dP1"]);
  const re2 = await NREC("dP1");
  ck("re-surface binds the SAME notification id (one-per-Dossier)", re1 && re2 && re1.id === re2.id);
  ck("re-surface kept the notification PENDING (dispatched still false)", re2 && re2.dispatched === false);
  await call(GOOD, "timed-fyi-poll", [FAR]);
  ck("re-poll still applied NO consequence (surface never auto-proceeds)", (await BDN("create --title new p1")) === 0);
  ck("p1 still OPEN after re-poll (idempotent surface)", (await ISTATE("dP1", "p1")) === "open");

  // ── EXIT-ALARM (CF superset): the REAL §2.2 setAlarm() callback routes pair→surface ──
  console.log("── EXIT-ALARM: the real DO alarm() surfaces a due pair (setAlarm path) ──");
  await resetBd();
  await PUT(mkpair("dAlmP", "2000-01-01T00:00:00Z", [item_obj("ap1")]));
  await call(GOOD, "pair-arm", ["dAlmP"]); // setAlarm(past) ⇒ alarm() delivered
  await runDurableObjectAlarm(coStub()); // force any pending alarm (idempotent)
  ck("alarm-fire SURFACED the pair (ready_to_pair notification fired)", await NHAS("dAlmP"));
  ck("alarm-fire applied NO §5.3 consequence (surface, not auto-proceed)", (await BDN("create --title new ap1")) === 0);
  ck("alarm-fire left the pair item OPEN (no §7.4 auto-apply)", (await ISTATE("dAlmP", "ap1")) === "open");

  // ── EXIT-PROJ: a kind:"pair" card surfaces in the §4.5 lane (0 items) + scheduled_at ──
  console.log("── EXIT-PROJ: a kind:'pair' card surfaces in the §4.5 lane (0 items) + scheduled_at ──");
  await PUT(mkpair("dPV", SCHED, [])); // a 0-item SESSION CARD (§4.2)
  await PUT(mkdecide("dNV0")); // kind:decide, items:[] (0 open)
  const snapR = await call(GOOD, "work-snapshot", ["projA", "[]"]);
  const SNAP = snapR.body || {};
  const woy = Array.isArray(SNAP.waiting_on_you) ? SNAP.waiting_on_you : [];
  const pv = woy.find((w) => w.dossier_id === "dPV");
  ck("a 0-item kind:'pair' card APPEARS in waiting_on_you (visibility by kind)", !!pv);
  ck("the pair lane entry carries kind:'pair'", pv && pv.kind === "pair");
  ck("the pair lane entry carries scheduled_at (the appointment — §4.4)", pv && pv.scheduled_at === SCHED);
  ck("the pair lane entry's open_item_count is 0 (a session card, not a form)", pv && pv.open_item_count === 0);
  ck("a 0-item kind:'decide' dossier is NOT in the lane (the open-item gate holds)", !woy.find((w) => w.dossier_id === "dNV0"));

  // ── EXIT-PROD (N10-10 claude-tools-l6vx): the PRODUCER creates + arms + surfaces ──
  console.log("── EXIT-PROD: the PRODUCER (pair-create) builds a kind:'pair' card + arms it, end-to-end ──");
  await resetBd();
  const pc = await call(GOOD, "pair-create", ["claude-tools-l6vx", SCHED, "pair on the producer"]);
  ck("pair-create succeeds", good(pc));
  ck("pair-create echoes the deterministic id 'pair-<bead_ref>'", pc.body && pc.body.id === "pair-claude-tools-l6vx");
  ck("pair-create echoes the armed fire_at = scheduled_at", pc.body && pc.body.fire_at === SCHED);
  const PD = "pair-claude-tools-l6vx";
  const pdRec = await GET(PD);
  ck("the produced dossier exists with kind:'pair'", pdRec && pdRec.kind === "pair");
  ck("produced tier is 'blocking' (§10.2 r10)", pdRec && pdRec.tier === "blocking");
  ck("produced trigger is 'proactive_checkpoint' (N3 fixture shape)", pdRec && pdRec.trigger === "proactive_checkpoint");
  ck("produced carries the scheduled_at appointment", pdRec && pdRec.scheduled_at === SCHED);
  ck("produced is a 0-item SESSION CARD (not a form — §4.2)", pdRec && Array.isArray(pdRec.items) && pdRec.items.length === 0);
  ck("produced body tldr is the session topic", pdRec && pdRec.body && pdRec.body.tldr === "pair on the producer");
  ck("produced wrote NO timer_fire_at (scheduled_at is the pair's field)", (await TFA(PD)) === null);
  ck("PRODUCER armed the §2.2 timer — DUE after scheduled_at", await DUE(PD, FAR));
  ck("NOT due BEFORE scheduled_at (upcoming, not ready)", !(await DUE(PD, NEAR)));
  ck("BEFORE its appointment: NO §4.3 notification (upcoming — N2 cannot push early)", !(await NHAS(PD)));
  // the produced card flows through the EXISTING uxg6/N3 surface path UNCHANGED:
  const surfP = await call(GOOD, "pair-surface", [PD]);
  ck("produced card SURFACES through the N3 path (pair-surface succeeds)", good(surfP));
  ck("produced card fired its blocking ready_to_pair notification", await NHAS(PD));
  const pnrec = await NREC(PD);
  ck("surfaced producer notif is tier 'blocking'", pnrec && pnrec.tier === "blocking");
  ck("produced card applied NO §5.3 consequence (a session card, not a decide)", (await BDN("create")) === 0);
  // visible in the §4.5 lane (visibility by kind)
  const snapP = await call(GOOD, "work-snapshot", ["projA", "[]"]);
  const woyP = snapP.body && Array.isArray(snapP.body.waiting_on_you) ? snapP.body.waiting_on_you : [];
  const pdv = woyP.find((w) => w.dossier_id === PD);
  ck("produced card APPEARS in waiting_on_you (visibility by kind)", !!pdv);
  ck("produced lane entry carries kind:'pair' + scheduled_at", pdv && pdv.kind === "pair" && pdv.scheduled_at === SCHED);
  // producer rejects, fail-closed (NO dossier): missing bead_ref / bad scheduled_at / unsafe id / no bearer
  ck("pair-create REJECTS a missing bead_ref", !good(await call(GOOD, "pair-create", ["", SCHED])));
  ck("pair-create REJECTS an unparseable scheduled_at", !good(await call(GOOD, "pair-create", ["claude-tools-l6vx", "not-a-date"])));
  ck("pair-create REJECTS an unsafe dossier id", !good(await call(GOOD, "pair-create", ["claude-tools-l6vx", SCHED, "t", "fd", "../evil"])));
  ck("pair-create with NO bearer REJECTED (§9.1)", !good(await call(null, "pair-create", ["claude-tools-l6vx", SCHED])));
  // idempotent re-create = re-schedule (deterministic id; overwrites the same card)
  const SCHED2 = "2099-05-16T18:00:00Z";
  const pc2 = await call(GOOD, "pair-create", ["claude-tools-l6vx", SCHED2]);
  ck("re-create returns the SAME deterministic id", pc2.body && pc2.body.id === PD);
  ck("re-create RE-SCHEDULED the appointment (scheduled_at updated)", (await GET(PD)).scheduled_at === SCHED2);

  // ── EXIT-E: binds §2.2/§10.2 · anti-drift (structural) ──
  console.log("── EXIT-E: binds §2.2/§10.2 · anti-drift (structural) ──");
  ck("§4 registry dossier⇒2 (pair added NO record type; rides the dossier type)", schemaVersion("dossier") === 2);
  ck("NO §4 record type added — 'pair' unregistered", schemaVersion("pair") === null);
  const tt = await call(GOOD, "notif-trigger-tiers", ["ready_to_pair"]);
  ck(
    "ready_to_pair is the §10.2 r10 trigger bound to 'blocking'",
    tt.body && tt.body.ok === true && Array.isArray(tt.body.tiers) && tt.body.tiers.length === 1 && tt.body.tiers[0] === "blocking"
  );

  // eslint-disable-next-line no-console
  console.log(`\n test-ready-to-pair (CF, N3 claude-tools-uxg6):  PASS=${PASS}  FAIL=${FAIL}`);
  if (FAIL > 0) console.log(` FAILURES: ${fails.join(" | ")}`);
  expect(FAIL, `pair differential failures: ${fails.join(" | ")}`).toBe(0);
});
