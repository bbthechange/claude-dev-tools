// L2 (claude-tools-uxvl2) — WORK→CONTROL auto-close (inbox-lifecycle §7 Opt 2).
//
// The `bead-status-changed` engine op: when a bead resolves OUTSIDE the dossier
// tap (bd close / blocked→open / `human` label dropped), the per-machine daemon
// publishes this over the zdxd D2 channel and the engine drops the now-stale
// card off the Inbox by moving every still-open item to a terminal state —
//   open     → expired   (no decision was made; the bead moved on)
//   answered → applied   (a decision IS recorded — PRESERVE it — but DO NOT
//                         fire the §5.3 ConsequenceBlock; that path stays
//                         reserved for an explicit Inbox tap — §7.6.3)
//   applied / expired    → untouched (idempotent no-op)
// via the item-set-state STATE MOVE, never item-apply (§7.9 gotcha). Idempotent
// (§7.6.4), v1-skip (§7.9 gotcha), principal+bead scoped (waiting_on_you parity).
//
// Exercises the REAL engine via SELF.fetch (Worker §9.1 chokepoint → singleton
// Coordinator DO → D1) under the SAME workerd+miniflare runtime as the CF.6
// differential — NO Cloudflare account. Self-contained harness so it never
// perturbs dossier.spec.js's shared counters.

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
const istate = (rec, iid) => {
  const it = rec && rec.items && rec.items.find((x) => x.id === iid);
  return it ? it.state : undefined;
};
const ica = (rec, iid) => {
  const it = rec && rec.items && rec.items.find((x) => x.id === iid);
  return it ? it.consequence_applied : undefined;
};
async function workPlaneRows() {
  const { results } = await env.DB.prepare("SELECT line FROM work_plane_ops").all();
  return (results || []).length;
}

// a v2 dossier for <bref> with explicit per-item {id,state,response}
// Defaults to the BLOCKING decision tier; pass tier="timed-fyi" for Flow F.
// timerFireAt: pass an RFC-3339 string to ARM the §2.2 auto-proceed timer
// (a genuine auto-proceeder); default null = no armed timer (claude-tools-o2mk).
const mkFor = (id, bref, items, tier = "blocking", timerFireAt = null) => ({
  id, schema_version: 2, kind: "decide", trigger: "worker_stuck",
  bead_ref: bref, tier, created_at: "2026-05-30T00:00:00Z",
  timer_fire_at: timerFireAt,
  body: { dossier_schema_version: 2, tldr: "t", sections: [], diagrams: [], full_detail: "f" },
  items: items.map((x) => ({
    id: x.id, kind: "approve-reject", framing: {},
    context_anchor: { where: "x", expansion: "y" },
    consequence_block: { cb_schema_version: 2, creates: [], unblocks: [], labels: [], status_changes: [] },
    reversible: "r",
    state: x.state, response: x.response ?? null, consequence_applied: false, applied_at: null,
  })),
});
const evt = (bref, status, at) => ({
  report: "bead_status_changed", schema_version: 1, principal: "brian",
  bead_ref: bref, status, blocked: false, human_label: false, observed_at: at,
});

it("L2 (claude-tools-uxvl2) — bead-status-changed auto-closes a bead's open dossier items", async () => {
  let P = 0, F = 0;
  const fl = [];
  const ck2 = (name, cond) => {
    if (cond) { P++; console.log(`  ✓ ${name}`); }
    else { F++; fl.push(name); console.log(`  ✗ ${name}`); }
  };
  const waitingHas = async (bref) => {
    const r = await call(GOOD, "work-snapshot", []);
    const w = r.body && Array.isArray(r.body.waiting_on_you) ? r.body.waiting_on_you : [];
    return w.some((x) => x.bead_ref === bref);
  };

  const BREF = "thirsty-L2alpha";
  const D = mkFor("bsc-d1", BREF, [
    { id: "open1", state: "open" },
    { id: "ans1", state: "answered", response: { decision: "approve", responded_at: "2026-05-30T01:00:00Z", principal: "brian" } },
    { id: "applied1", state: "applied" },
  ]);
  ck2("plant a v2 dossier with open + answered + applied items", good(await call(GOOD, "dossier-put", [D])));
  ck2("BEFORE: the bead's dossier shows on the Inbox (waiting_on_you)", await waitingHas(BREF));

  // ── the sweep ────────────────────────────────────────────────────────────
  const r1 = await call(GOOD, "bead-status-changed", [evt(BREF, "closed", "2026-05-30T02:00:00Z")]);
  ck2("bead-status-changed accepted (ok)", good(r1));
  ck2("first sweep is NOT idempotent (it acted)", r1.body && r1.body.idempotent === false);
  ck2("audit: 2 transitions recorded (open1, ans1)", r1.body && r1.body.transitions.length === 2);
  const S = await GET("bsc-d1");
  ck2("open item -> expired (no decision was made)", istate(S, "open1") === "expired");
  ck2("answered item -> applied", istate(S, "ans1") === "applied");
  const ans = S && S.items.find((x) => x.id === "ans1");
  ck2("answered->applied PRESERVES the recorded decision (.response carried verbatim)",
    !!ans && ans.response && ans.response.decision === "approve");
  ck2("answered->applied did NOT fire the CB (latch stays false — reserved for the Inbox tap)",
    ica(S, "ans1") === false);
  ck2("already-terminal applied item untouched", istate(S, "applied1") === "applied");
  ck2("AFTER: dossier drops off the Inbox — every item terminal (the §7.1 goal)", !(await waitingHas(BREF)));
  ck2("auto-close fired NO work-plane ConsequenceBlock op (no bd creates/unblocks/labels)", (await workPlaneRows()) === 0);

  // ── idempotency (§7.6.4) ───────────────────────────────────────────────────
  const r2 = await call(GOOD, "bead-status-changed", [evt(BREF, "closed", "2026-05-30T02:05:00Z")]);
  ck2("second identical event => { ok:true, idempotent:true } (monotonic no-op)",
    r2.body && r2.body.ok === true && r2.body.idempotent === true);

  // ── tier scoping: a co-existing ARMED timed-fyi (Flow F overview) for the SAME
  //    bead rides its own 24h timer and is NOT force-expired ──────────────────
  const BREF2 = "thirsty-L2beta";
  await call(GOOD, "dossier-put", [mkFor("stuck-bsc2", BREF2, [{ id: "d1", state: "open" }], "blocking")]);
  // ARMED timer (timer_fire_at set) ⇒ a genuine §2.2 auto-proceeder, exempt.
  await call(GOOD, "dossier-put", [mkFor("overview-bsc2", BREF2, [{ id: "f1", state: "open" }], "timed-fyi", "2026-05-31T00:00:00Z")]);
  const rt = await call(GOOD, "bead-status-changed", [evt(BREF2, "closed", "2026-05-30T02:08:00Z")]);
  ck2("tier scoping: blocking dossier's item -> expired", istate(await GET("stuck-bsc2"), "d1") === "expired");
  ck2("tier scoping: co-existing ARMED timed-fyi overview is PRESERVED (rides its timer)",
    istate(await GET("overview-bsc2"), "f1") === "open");
  ck2("tier scoping: matched_dossiers counts only the blocking dossier (armed timed-fyi exempt)", rt.body && rt.body.matched_dossiers === 1);

  // ── L2 gap (claude-tools-o2mk): a §5.6-DEFERRED decision card (tier lowered
  //    blocking→digest WITHOUT arming a timer) has NO timer to ride, so it IS
  //    auto-closed when its bead resolves outside the tap — it is NOT a genuine
  //    auto-proceeder. Plant blocking, then `defer` it (the real Inbox verb) so
  //    tier=digest & timer_fire_at stays null, then resolve the bead. ──────────
  const BREF3 = "thirsty-L2gamma";
  await call(GOOD, "dossier-put", [mkFor("defer-bsc3", BREF3, [{ id: "g1", state: "open" }], "blocking")]);
  const def = await call(GOOD, "dossier-defer", ["defer-bsc3"]);
  ck2("defer lowers the card to tier=digest (the §5.6 verb)", good(def));
  ck2("deferred card is tier=digest with NO armed timer (timer_fire_at null)", await (async () => {
    const s = await GET("defer-bsc3");
    return !!s && s.tier === "digest" && s.timer_fire_at === null;
  })());
  ck2("BEFORE: the deferred card still shows on the Inbox", await waitingHas(BREF3));
  const rd = await call(GOOD, "bead-status-changed", [evt(BREF3, "closed", "2026-05-30T02:09:00Z")]);
  ck2("deferred (no-timer) card IS auto-closed — its open item -> expired",
    istate(await GET("defer-bsc3"), "g1") === "expired");
  ck2("deferred card now counts as a matched_dossiers (acted on, not skipped)", rd.body && rd.body.matched_dossiers === 1);
  ck2("AFTER: the deferred card drops off the Inbox (the o2mk gap closed)", !(await waitingHas(BREF3)));

  // ── SNOOZE refinement (claude-tools-653d): a §5.6-SNOOZED card is tier=digest
  //    WITH an armed timer (timer_fire_at + snoozed_until = snooze_until) — a NEW
  //    shape, NOT a Flow-F auto-proceeder (its timer RE-SURFACES, never
  //    auto-applies). The exemption is narrowed from "armed timer ⇒ skip" to
  //    "GENUINELY timed-fyi ⇒ skip", so a snoozed card whose bead resolves OUTSIDE
  //    auto-closes (drops the dead card) instead of being mistaken for an armed
  //    timed-fyi overview. (The armed timed-fyi overview above is STILL exempt —
  //    the predicate change keeps that case green.) ───────────────────────────
  const BREF4 = "thirsty-L2snooze";
  const SNZ = "2099-06-01T00:00:00Z";
  const Dsnz = { ...mkFor("snooze-bsc4", BREF4, [{ id: "z1", state: "open" }], "digest", SNZ), snoozed_until: SNZ };
  await call(GOOD, "dossier-put", [Dsnz]);
  ck2("snoozed card is tier=digest WITH an armed timer AND snoozed_until set", await (async () => {
    const s = await GET("snooze-bsc4");
    return !!s && s.tier === "digest" && s.timer_fire_at === SNZ && s.snoozed_until === SNZ;
  })());
  ck2("BEFORE: the snoozed card still shows on the Inbox", await waitingHas(BREF4));
  const rs = await call(GOOD, "bead-status-changed", [evt(BREF4, "closed", "2026-05-30T02:09:30Z")]);
  ck2("snoozed card IS auto-closed despite its armed timer (not a Flow-F auto-proceeder) — z1 → expired",
    istate(await GET("snooze-bsc4"), "z1") === "expired");
  ck2("snoozed card counts as matched (acted on, NOT skipped like an armed timed-fyi)", rs.body && rs.body.matched_dossiers === 1);
  ck2("AFTER: the snoozed dead-bead card drops off the Inbox (the 653d refinement)", !(await waitingHas(BREF4)));

  // ── bead scoping: a different bead_ref's open item is untouched ─────────────
  await call(GOOD, "dossier-put", [mkFor("bsc-other", "thirsty-Other", [{ id: "o1", state: "open" }])]);
  await call(GOOD, "bead-status-changed", [evt(BREF, "closed", "2026-05-30T02:10:00Z")]);
  ck2("a DIFFERENT bead_ref's open item is NOT touched (bead scoping)",
    istate(await GET("bsc-other"), "o1") === "open");

  // ── §7.9 v1-skip: a sub-bound stored dossier is skipped, not crashed ───────
  const V1 = { ...mkFor("bsc-v1", "thirsty-V1", [{ id: "v1a", state: "open" }]), schema_version: 1, principal: "brian" };
  V1.body = { ...V1.body, dossier_schema_version: 1 };
  await env.DB.prepare("INSERT OR REPLACE INTO records (type,id,json) VALUES ('dossier','bsc-v1',?)")
    .bind(JSON.stringify(V1)).run();
  const rv = await call(GOOD, "bead-status-changed", [evt("thirsty-V1", "closed", "2026-05-30T02:15:00Z")]);
  ck2("v1 dossier SKIPPED, not crashed (ok)", good(rv));
  ck2("v1 dossier reported in skipped_v1 count", rv.body && rv.body.skipped_v1 >= 1);
  ck2("v1 dossier item left as-is (open) — write-back refused, not mangled",
    istate(await GET("bsc-v1"), "v1a") === "open");

  // ── wire robustness: the outbox line is a JSON STRING, accepted verbatim ────
  await call(GOOD, "dossier-put", [mkFor("bsc-str", "thirsty-Str", [{ id: "s1", state: "open" }])]);
  const rstr = await call(GOOD, "bead-status-changed", [JSON.stringify(evt("thirsty-Str", "closed", "2026-05-30T02:20:00Z"))]);
  ck2("accepts the wire JSON-STRING report shape (the outbox line)",
    good(rstr) && istate(await GET("bsc-str"), "s1") === "expired");

  // ── rejection arms ─────────────────────────────────────────────────────────
  ck2("reject — wrong report type", !good(await call(GOOD, "bead-status-changed", [{ report: "nope", schema_version: 1, bead_ref: "x" }])));
  ck2("reject — missing bead_ref", !good(await call(GOOD, "bead-status-changed", [{ report: "bead_status_changed", schema_version: 1 }])));
  ck2("reject — unknown higher schema_version (§0.3)", !good(await call(GOOD, "bead-status-changed", [{ report: "bead_status_changed", schema_version: 2, bead_ref: "x" }])));
  ck2("§9.1 — no bearer => 401 before any write",
    (await call(null, "bead-status-changed", [evt(BREF, "closed", "2026-05-30T02:25:00Z")])).status === 401);

  console.log(`\n== L2 bead-status-changed (claude-tools-uxvl2): PASS=${P} FAIL=${F} ==`);
  if (F > 0) console.log("FAILED:\n  - " + fl.join("\n  - "));
  expect(F, `L2 clauses failed: ${fl.join("; ")}`).toBe(0);
});
