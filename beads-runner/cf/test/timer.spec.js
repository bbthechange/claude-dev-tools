// CF.7 (claude-tools-7g0.7) — DIFFERENTIAL conformance test.
//
// Mirrors lib/test-timed-fyi.sh EXIT-1..5, one linear flow (the bash script is
// linear; per-file isolated storage gives this the bash test's fresh-mktemp
// store + fake-bin analogue). Every assertion exercises the REAL engine via
// SELF.fetch (Worker -> §9.1 chokepoint -> singleton Coordinator DO -> D1)
// under the SAME workerd+miniflare runtime `wrangler dev` uses, NO Cloudflare
// account. The CF timer MUST exhibit the SAME §2.2 / S-6 (§7.4) / §5.2.2
// behavior as timed-fyi.sh + test-timed-fyi.sh.
//
// CF SUPERSET (beyond the bash oracle, proving the §2.2 setAlarm() realization
// EXIT criteria #1/#2): the bash test simulates "the alarm fires" by directly
// calling tf_fire (the §2.2 surface has no alarm daemon, by contract). Here we
// ALSO drive the REAL Durable Object `alarm()` callback via
// `runDurableObjectAlarm` to prove the alarm-fire path AND that a MISSED alarm
// degrades to fire-on-next-poll, dedup'd EXACTLY-once via CF.6's §7.4 per-Item
// latch (NOT timer reliability, NOT the ack). Both go through the SAME shared
// handler -> the SAME idempotent `item-apply`.
//
// `env` (the D1 binding) is used ONLY as the work-plane sink grep analogue
// (the bash $BD_LOG fake-bin) and to reset it between scenarios — EXACTLY the
// dossier.spec.js pattern. `schemaVersion`/`timedFyiDefault` are imported for
// the EXIT-5 §0.5/§4-registry clauses, mirroring how the bash EXIT-5 calls
// `co__schema_version` / `tf__TIMED_FYI_DEFAULT` directly (stuck.spec.js /
// reconcile.spec.js establish importing a pure helper for a unit-level mirror).
// No non-contract debug surface is added to the engine.

import { env, SELF, runDurableObjectAlarm } from "cloudflare:test";
import { it, expect } from "vitest";
import { schemaVersion } from "../src/schema.js";
import { timedFyiDefault } from "../src/timer.js";

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
// success = the bash `rc==0` analogue.
function good(r) {
  if (r.status === 200 && r.body === null) return true; // text/plain ok
  return !!(r.body && r.body.ok === true);
}

// ── the bash test helpers (GET/ISTATE/ICA/IAT/TFA/BDN/DUE) ──────────────────
// GET() = `co_request GOOD get dossier <id>` (echoes the stored §4.1 record).
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
const IAT = async (id, iid) => {
  const it = _item(await GET(id), iid);
  return it ? it.applied_at : undefined;
};
const TFA = async (id) => {
  const rec = await GET(id);
  return rec ? rec.timer_fire_at : undefined;
};
// do_dossier_get (CF.6 read path) — null when absent (the `ckn do_dossier_get`
// "follow-up does NOT exist" analogue).
async function dget(id) {
  const r = await call(GOOD, "dossier-get", [id]);
  if (r.status !== 200) return null;
  try {
    return JSON.parse(r.raw);
  } catch {
    return null;
  }
}
async function resetBd() {
  await env.DB.prepare("DELETE FROM work_plane_ops").run();
}
// BDN <re> — `grep -c` analogue over the work-plane sink (one row = one
// `bd <args>` line), EXACTLY the dossier.spec.js BDN.
async function BDN(re) {
  const { results } = await env.DB.prepare("SELECT line FROM work_plane_ops").all();
  const rx = new RegExp(re);
  return (results || []).filter((r) => rx.test(r.line)).length;
}
// DUE <id> [now] — `co_request GOOD timer-due [now]` then `grep -Fxq`.
async function DUE(id, now) {
  const r = await call(GOOD, "timer-due", now === undefined ? [] : [now]);
  return r.raw.split("\n").filter(Boolean).includes(id);
}

// ── §4.1 envelope + item builders (the bash mk()/cb()/item_obj()/item_ar()) ──
// NOTE on the year: the bash oracle has NO alarm daemon — its timers sit armed
// until tf_poll/tf_fire is EXPLICITLY driven, so test-timed-fyi.sh asserts
// `DUE <id> <now>` against a fixed CA in the past. The CF realization's
// opTimerArm calls a REAL `ctx.storage.setAlarm(fire_at)`; under the workers
// runtime a fire_at in the PAST fires `alarm()` spontaneously (proven below in
// EXIT-1-ALARM). To mirror the bash "armed-but-not-yet-driven" surface
// DETERMINISTICALLY (and only then drive it via the explicit poll/fire with an
// explicit `now`, exactly as the bash `DUE`/`tf_poll` do), the oracle-mirror
// blocks pin CA/NEAR/FAR into the far FUTURE so setAlarm cannot preempt the
// explicit driver. Every CA+window↔NEAR↔FAR RELATIONSHIP is identical to the
// bash test (the only thing that changed is the absolute epoch). EXIT-1-ALARM
// then uses a deep-PAST CA precisely to exercise the real setAlarm() callback.
const CA = "2099-05-16T00:00:00Z"; // +86400 ⇒ 2099-05-17T00:00:00Z ; +3600 ⇒ …01:00:00Z
const mk = (id, tier, items, ca = CA) => ({
  id,
  schema_version: 1,
  kind: "decide",
  trigger: "proactive_checkpoint",
  bead_ref: "claude-tools-65z",
  tier,
  created_at: ca,
  timer_fire_at: null,
  body: {
    dossier_schema_version: 1,
    tldr: "opaque",
    sections: [],
    diagrams: [],
    full_detail: "T5.2 owns this",
  },
  items,
});
const cb = (t) => ({
  cb_schema_version: 1,
  creates: [{ title: `new ${t}`, type: "task", priority: 2, labels: ["auto"], description: "d" }],
  unblocks: [`unb-${t}`],
  labels: [],
  status_changes: [],
});
const item_obj = (i, s) => ({
  id: i,
  kind: "fyi-objectable",
  framing: {},
  context_anchor: { where: "x", expansion: "y" },
  consequence_block: cb(i),
  reversible: "r",
  state: s,
  response: null,
  consequence_applied: false,
  applied_at: null,
});
const item_ar = (i, s) => ({
  id: i,
  kind: "approve-reject",
  framing: {},
  context_anchor: { where: "x", expansion: "y" },
  consequence_block: cb(i),
  reversible: "r",
  state: s,
  response: null,
  consequence_applied: false,
  applied_at: null,
});
const RESP_OBJECT = {
  decision: "object",
  freeform_text: "I object to this auto-proceed",
  responded_at: "2026-05-16T01:00:00Z",
  principal: "brian",
};
const RESP_APPROVE = {
  decision: "approve",
  responded_at: "2026-05-16T01:00:00Z",
  principal: "brian",
};
const FAR = "2099-06-01T00:00:00Z"; // well past every fire_at below
const NEAR = "2099-05-16T12:00:00Z"; // before the default fire_at (next day)
const PUT = (envObj) => call(GOOD, "dossier-put", [envObj]);
// The singleton Coordinator DO stub (the SAME instance the Worker hits via
// idFromName("coordinator")) — for driving the REAL §2.2 setAlarm() callback.
function coStub() {
  return env.COORDINATOR.get(env.COORDINATOR.idFromName("coordinator"));
}

it("CF.7 differential vs timed-fyi.sh + test-timed-fyi.sh (§2.2 / S-6 / §5.2.2)", async () => {
  // ── EXIT-4: timer_fire_at = created_at + window · default/override/null ──
  await PUT(mk("dDef", "timed-fyi", [item_obj("f1", "open")]));
  const fa = await call(GOOD, "timed-fyi-arm", ["dDef"]);
  ck("tf_arm (default) succeeds", good(fa));
  ck(
    "default window ⇒ timer_fire_at = created_at + TIMED_FYI_DEFAULT(86400)",
    (await TFA("dDef")) === "2099-05-17T00:00:00Z"
  );
  ck("tf_arm echoes the computed fire_at", fa.body && fa.body.fire_at === "2099-05-17T00:00:00Z");
  ck("§2.2 timer armed keyed fire(dossier_id)=dDef, due AFTER fire_at", await DUE("dDef", FAR));
  ck("NOT due BEFORE fire_at (one-shot at T, not earlier)", !(await DUE("dDef", NEAR)));

  await PUT(mk("dOv", "timed-fyi", [item_obj("o1", "open")]));
  ck("tf_arm override=3600 succeeds", good(await call(GOOD, "timed-fyi-arm", ["dOv", "3600"])));
  ck("override ⇒ timer_fire_at = created_at + 3600", (await TFA("dOv")) === "2099-05-16T01:00:00Z");
  await PUT(mk("dBd", "timed-fyi", [item_obj("b1", "open")]));
  ck(
    "boundary override == TIMED_FYI_DEFAULT accepted ((0,DEFAULT] inclusive)",
    good(await call(GOOD, "timed-fyi-arm", ["dBd", "86400"]))
  );
  ck("boundary override ⇒ created_at + 86400", (await TFA("dBd")) === "2099-05-17T00:00:00Z");

  await PUT(mk("dXr", "timed-fyi", [item_obj("x1", "open")]));
  ck("override > TIMED_FYI_DEFAULT REJECTED", !good(await call(GOOD, "timed-fyi-arm", ["dXr", "86401"])));
  ck("override = 0 REJECTED (range is (0,DEFAULT])", !good(await call(GOOD, "timed-fyi-arm", ["dXr", "0"])));
  ck("override negative REJECTED", !good(await call(GOOD, "timed-fyi-arm", ["dXr", "-5"])));
  ck("override non-integer REJECTED (§0.4 integer s)", !good(await call(GOOD, "timed-fyi-arm", ["dXr", "abc"])));
  ck("a REJECTED arm left timer_fire_at null (no write)", (await TFA("dXr")) === null);
  ck("a REJECTED arm armed NO §2.2 timer", !(await DUE("dXr", FAR)));

  await PUT(mk("dNul", "timed-fyi", [item_obj("n1", "open")]));
  ck("tf_arm window=null succeeds (no-op success)", good(await call(GOOD, "timed-fyi-arm", ["dNul", "null"])));
  ck("null window ⇒ timer_fire_at stays null", (await TFA("dNul")) === null);
  ck("null window ⇒ NO §2.2 timer armed (never fires)", !(await DUE("dNul", FAR)));

  // SOFT-DISARM (review #1): real arm, then re-arm null ⇒ envelope cleared AND
  // the prior arm soft-disarmed (timer-ack) so the S-6 poll-fallback does NOT
  // fire it and the item does NOT auto-proceed.
  await PUT(mk("dDis", "timed-fyi", [item_obj("z1", "open")]));
  await call(GOOD, "timed-fyi-arm", ["dDis", "3600"]);
  ck("prior real arm ⇒ §2.2 timer armed (due at FAR)", await DUE("dDis", FAR));
  ck("re-arm window=null succeeds", good(await call(GOOD, "timed-fyi-arm", ["dDis", "null"])));
  ck("re-arm null ⇒ timer_fire_at cleared", (await TFA("dDis")) === null);
  ck("re-arm null SOFT-DISARMED the prior arm (not in timer-due)", !(await DUE("dDis", FAR)));
  await call(GOOD, "timed-fyi-poll", [FAR]);
  ck("soft-disarmed dossier does NOT auto-proceed on poll (z1 stays open)", (await ISTATE("dDis", "z1")) === "open");
  ck("soft-disarmed z1 latch still false (no consequence applied)", (await ICA("dDis", "z1")) === false);

  await PUT(mk("dBlk", "blocking", [item_obj("k1", "open")]));
  ck("tf_arm on a 'blocking' dossier ⇒ no-op success", good(await call(GOOD, "timed-fyi-arm", ["dBlk"])));
  ck("non-timed-fyi tier ⇒ timer_fire_at stays null", (await TFA("dBlk")) === null);
  ck("non-timed-fyi tier ⇒ NO §2.2 timer armed", !(await DUE("dBlk", FAR)));

  // ── EXIT-1: alarm fires ⇒ un-objected fyi-objectable auto-proceeds ONCE ──
  await PUT(mk("dF1", "timed-fyi", [item_obj("g1", "open")]));
  await call(GOOD, "timed-fyi-arm", ["dF1"]);
  await resetBd();
  ck("tf_fire (alarm) succeeds", good(await call(GOOD, "timed-fyi-fire", ["dF1"])));
  ck("g1 consequence_applied flipped false→true", (await ICA("dF1", "g1")) === true);
  ck("g1 state → applied (open→answered→applied via CF.6)", (await ISTATE("dF1", "g1")) === "applied");
  ck("g1 applied_at stamped (§4.1.1)", (await IAT("dF1", "g1")) !== null);
  ck("§5.3 consequence APPLIED once (bd create for g1)", (await BDN("create --title new g1")) === 1);
  ck("§5.3 unblocks applied (control→work, BC-15)", (await BDN("update unb-g1 --status=open")) >= 1);
  ck("un-objected proceed is DETERMINISTIC — NO reconciler follow-up", (await dget("dF1-fu-g1")) === null);
  const dF1rec = await GET("dF1");
  ck(
    "auto-proceed response is self-describing (auto_proceed:true recorded)",
    dF1rec && dF1rec.items[0].response && dF1rec.items[0].response.auto_proceed === true
  );

  // ── EXIT-1-ALARM (CF superset, proves task EXIT #1/#2): the REAL §2.2
  // ctx.storage.setAlarm() callback fires fire(dossier_id). created_at deep in
  // the PAST ⇒ fire_at ≤ real-now, so opTimerArm's setAlarm is a past time and
  // the workers runtime delivers `alarm()`; alarm()'s timer-due (real-now)
  // surfaces ONLY this dossier (every oracle-mirror timer is pinned to 2099).
  // We also force any pending alarm via runDurableObjectAlarm so the proof is
  // deterministic regardless of spontaneous-delivery timing — the EXIT
  // criterion is the EFFECT (consequence applied EXACTLY once), and nothing
  // else ever drives dAlm (it is never passed to timed-fyi-fire/poll), so the
  // effect proves the alarm() wiring is real (CF.1 left it a no-op marker).
  await resetBd();
  await PUT(mk("dAlm", "timed-fyi", [item_obj("alm1", "open")], "2000-01-01T00:00:00Z"));
  await call(GOOD, "timed-fyi-arm", ["dAlm"]); // setAlarm(past) ⇒ alarm() delivered
  await runDurableObjectAlarm(coStub()); // force any pending alarm (idempotent)
  ck("DO alarm() fire(dossier_id) ⇒ alm1 consequence applied (setAlarm wired)", (await ICA("dAlm", "alm1")) === true);
  ck("alarm() ⇒ alm1 state applied", (await ISTATE("dAlm", "alm1")) === "applied");
  ck("alarm-fire applied §5.3 EXACTLY once", (await BDN("create --title new alm1")) === 1);
  ck("un-driven-elsewhere ⇒ NO reconciler follow-up (alarm proceed deterministic)", (await dget("dAlm-fu-alm1")) === null);
  // S-6: alarm racing the poll-fallback applies EXACTLY once via CF.6's §7.4
  // per-Item latch — NOT the ack. Re-arm in the PAST (acked←0, "ack lost"),
  // force the alarm AGAIN and also poll: the latch dedups every path.
  await call(GOOD, "timer-arm", ["dAlm", "2000-01-02T00:00:00Z"]); // resets acked=0
  await runDurableObjectAlarm(coStub());
  await call(GOOD, "timed-fyi-poll", [FAR]);
  ck("alarm-then-poll (lost ack) ⇒ alm1 §5.3 STILL exactly once (latch dedup, S-6)", (await BDN("create --title new alm1")) === 1);
  ck("alm1 latch still true (idempotent no-op on re-fire)", (await ICA("dAlm", "alm1")) === true);

  // ── EXIT-2: suppressed alarm ⇒ fire-on-next-poll · S-6 exactly-once ──
  // (a) alarm SUPPRESSED entirely — never fire; the poll-fallback fires it.
  await PUT(mk("dS", "timed-fyi", [item_obj("s1", "open")]));
  await call(GOOD, "timed-fyi-arm", ["dS"]);
  await resetBd();
  await call(GOOD, "timed-fyi-poll", [NEAR]);
  ck("poll BEFORE fire_at does NOT fire dS (s1 still open)", (await ISTATE("dS", "s1")) === "open");
  const polled = await call(GOOD, "timed-fyi-poll", [FAR]);
  ck(
    "poll AFTER fire_at fires the suppressed alarm (dS surfaced)",
    polled.body && Array.isArray(polled.body.fired) && polled.body.fired.includes("dS")
  );
  ck("suppressed alarm ⇒ s1 STILL auto-proceeds on poll", (await ISTATE("dS", "s1")) === "applied");
  ck("fire-on-next-poll applied the consequence ONCE", (await BDN("create --title new s1")) === 1);
  // (b) S-6 dedup is the §7.4 per-Item LATCH, not the ack: re-arm (ack lost),
  //     poll again — must NOT double-apply.
  await call(GOOD, "timer-arm", ["dS", "2099-05-17T00:00:00Z"]); // resets acked=false
  ck("re-armed timer is due again (ack was 'lost')", await DUE("dS", FAR));
  await call(GOOD, "timed-fyi-poll", [FAR]);
  ck("alarm-then-poll (lost ack) ⇒ STILL applied exactly once (latch dedup)", (await BDN("create --title new s1")) === 1);
  ck("s1 still applied, latch still true (idempotent no-op 2nd time)", (await ICA("dS", "s1")) === true);
  // (c) double alarm-fire ⇒ exactly once
  await PUT(mk("dD2", "timed-fyi", [item_obj("d2", "open")]));
  await call(GOOD, "timed-fyi-arm", ["dD2"]);
  await resetBd();
  await call(GOOD, "timed-fyi-fire", ["dD2"]);
  await call(GOOD, "timed-fyi-fire", ["dD2"]);
  ck("double alarm-fire ⇒ §5.3 applied exactly once", (await BDN("create --title new d2")) === 1);
  // (d) 8-way concurrent fire race (alarm ⇄ poll) ⇒ exactly once (S-6)
  await PUT(mk("dRc", "timed-fyi", [item_obj("r1", "open")]));
  await call(GOOD, "timed-fyi-arm", ["dRc"]);
  await resetBd();
  const race = await Promise.all(
    "abcdefgh"
      .split("")
      .map((_, k) =>
        k % 2 === 0 ? call(GOOD, "timed-fyi-fire", ["dRc"]) : call(GOOD, "timed-fyi-poll", [FAR])
      )
  );
  ck("r1 consequence_applied true exactly once", (await ICA("dRc", "r1")) === true);
  ck("§5.3 applied EXACTLY ONCE under 8-way alarm⇄poll race (S-6 / §7.4 latch)", (await BDN("create --title new r1")) === 1);
  ck("every concurrent fire/poll returned success (idempotent)", race.every((r) => good(r)));

  // ── EXIT-3: objected ≠ auto-proceed · non-auto-proceeding left open ──
  await PUT(
    mk("dO", "timed-fyi", [item_obj("obj1", "open"), item_obj("keep1", "open"), item_ar("other1", "open")])
  );
  // Human objects to obj1 FIRST (CF.6 reconciler: applied + follow-up, NO block).
  await call(GOOD, "item-apply", ["dO", "obj1", RESP_OBJECT]);
  const OBJ1_AT = await IAT("dO", "obj1");
  ck("objected obj1 reconciled (state applied, follow-up emitted)", (await dget("dO-fu-obj1")) !== null);
  ck("objection applied NO §5.3 block (reconciler, not proceed)", (await BDN("create --title new obj1")) === 0);
  await call(GOOD, "timed-fyi-arm", ["dO"]);
  await resetBd();
  ck("tf_fire (alarm) succeeds with a mixed dossier", good(await call(GOOD, "timed-fyi-fire", ["dO"])));
  ck("OBJECTED obj1 did NOT auto-proceed (no proceed §5.3 block)", (await BDN("create --title new obj1")) === 0);
  ck("OBJECTED obj1 applied_at UNCHANGED (no second resolution)", (await IAT("dO", "obj1")) === OBJ1_AT);
  ck("un-objected keep1 DID auto-proceed (consequence applied)", (await BDN("create --title new keep1")) === 1);
  ck("keep1 state → applied", (await ISTATE("dO", "keep1")) === "applied");
  ck("non-fyi-objectable other1 LEFT OPEN (never auto-proceeds)", (await ISTATE("dO", "other1")) === "open");
  ck("other1 latch still false (untouched)", (await ICA("dO", "other1")) === false);
  ck("other1 NO §5.3 block applied", (await BDN("create --title new other1")) === 0);
  ck(
    "left-open other1 still answerable later (no sibling/pipeline gate — AD7)",
    good(await call(GOOD, "item-apply", ["dO", "other1", RESP_APPROVE]))
  );
  ck("other1 now applied (proves no gate from partial resolution)", (await ISTATE("dO", "other1")) === "applied");
  const dOrec = await GET("dO");
  const openFyi = (dOrec.items || []).filter(
    (x) => x.kind === "fyi-objectable" && x.state === "open"
  ).length;
  ck("a timed-fyi dossier never infinite-stalls (0 fyi-objectable left open)", openFyi === 0);

  // ── EXIT-5: binds §2.2/§7.4 · anti-drift (structural) ──
  ck("§4 registry UNCHANGED — dossier⇒1 (no schema bump)", schemaVersion("dossier") === 1);
  ck("NO §4 record type added — 'timed_fyi' unregistered", schemaVersion("timed_fyi") === null);
  ck("the timer is the §2.2 SURFACE, not a §4 record ('timer' unregistered)", schemaVersion("timer") === null);
  const caps = (await call(GOOD, "capabilities", [])).raw;
  ck("tf_arm is NOT advertised as a §2 capability", !caps.includes("timed-fyi-arm"));
  ck("tf_fire is NOT advertised as a §2 capability", !caps.includes("timed-fyi-fire"));
  ck("tf_poll is NOT advertised as a §2 capability", !caps.includes("timed-fyi-poll"));
  ck(
    "§2.2 stays the timer surface (timer-arm|timer-due|timer-ack)",
    caps.includes("timer-arm|timer-due|timer-ack")
  );
  ck("§2 surface is still exactly the four capability lines", caps.split("\n").filter((l) => l.startsWith("§2")).length === 4);
  // §0.5 frozen constant: ONE env-overridable definition, default 86400, NO
  // competing literal (the bash `tf__TIMED_FYI_DEFAULT` mirror).
  ck("timedFyiDefault default = 86400 (§0.5)", timedFyiDefault({}) === 86400);
  ck("timedFyiDefault is env-overridable (no hardcoded use-site literal)", timedFyiDefault({ TIMED_FYI_DEFAULT: "10" }) === 10);
  // the §2.2 fire(dossier_id) target IS the envelope timer_fire_at (one truth).
  await PUT(mk("dT", "timed-fyi", [item_obj("t1", "open")]));
  await call(GOOD, "timed-fyi-arm", ["dT", "7200"]);
  ck("armed §2.2 timer id == dossier id (fire(dossier_id))", await DUE("dT", FAR));
  ck("armed timer fire_at == envelope timer_fire_at (single target)", (await TFA("dT")) === "2099-05-16T02:00:00Z");
  // missing / unauthorized rejected (§9.1 collapses 401/absent — C4).
  ck("tf_arm on a MISSING dossier REJECTED", !good(await call(GOOD, "timed-fyi-arm", ["nodoss"])));
  ck("tf_fire on a MISSING dossier REJECTED", !good(await call(GOOD, "timed-fyi-fire", ["nodoss"])));
  ck("tf_arm with NO bearer REJECTED (§9.1, no second auth path)", !good(await call(null, "timed-fyi-arm", ["dT"])));

  // eslint-disable-next-line no-console
  console.log(`\n══ CF.7 differential (vs timed-fyi.sh): PASS=${PASS} FAIL=${FAIL} ══`);
  if (FAIL > 0) {
    // eslint-disable-next-line no-console
    console.log("FAILED:\n  - " + fails.join("\n  - "));
  }
  expect(FAIL, `differential clauses failed: ${fails.join("; ")}`).toBe(0);
});
