// CF.6 (claude-tools-7g0.6) — DIFFERENTIAL conformance test.
//
// Mirrors the CF.6-OWNED clauses of the bash T5 trio's focused tests:
//   lib/test-dossier.sh      (T5.1 §4.1/§4.1.1 + state machine + PRIMITIVE 1
//                              latch + rollup/AD7) — PRIMITIVE 2 (the
//                              dossier-level task_ref dedup) is CF.8's DISTINCT
//                              dossier-level key, deliberately NOT here.
//   lib/test-dossier-gen.sh  (T5.2 §5 body⊃items[] generation, profiles)
//   lib/test-consequence.sh  (T5.3 §5.3 apply + §7.4 per-Item + §5.2.2 route)
//
// Every assertion exercises the REAL engine via SELF.fetch (Worker → §9.1
// chokepoint → singleton single-threaded Coordinator DO → D1) under the SAME
// workerd+miniflare runtime `wrangler dev` uses, NO Cloudflare account. The CF
// engine MUST exhibit the SAME INTERFACE.md v1 §-clause behaviour as the bash
// oracle + those tests — incl. the 8-way concurrent race ⇒ §5.3 applied
// EXACTLY ONCE. THE AD1 PAYOFF: per-Item idempotency + partial application are
// TRUE BY CONSTRUCTION (the singleton DO is one actor; co._serialize makes the
// read→route→apply→latch→state→persist a single critical section on it),
// replacing the bash hand-rolled per-dossier mkdir advisory lock.
//
// `env` (the D1 binding) is used ONLY to plant a §0.3-higher record and to
// read the work-plane sink — EXACTLY mirroring the bash tests reading/writing
// the store + $BD_LOG directly. No non-contract debug surface is added.

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
  if (r.status === 200 && r.body === null) return true; // text/plain ok (rollup, dossier-get)
  return !!(r.body && r.body.ok === true);
}
// Raw stored §4 record via the CF.1 `get` op — the `co_request GOOD get
// dossier <id>` analogue the bash GET() helper uses.
async function GET(id) {
  const r = await call(GOOD, "get", ["dossier", id]);
  if (r.status !== 200) return null;
  try {
    return JSON.parse(r.raw);
  } catch {
    return null;
  }
}
// do_dossier_get (the CF.6 read path: §0.3 read-bind + rollup re-derive).
async function dget(id) {
  const r = await call(GOOD, "dossier-get", [id]);
  if (r.status === 200) {
    try {
      return JSON.parse(r.raw);
    } catch {
      return null;
    }
  }
  return null;
}
const istate = (rec, iid) => {
  const it = rec && rec.items && rec.items.find((x) => x.id === iid);
  return it ? it.state : undefined;
};
const ica = (rec, iid) => {
  const it = rec && rec.items && rec.items.find((x) => x.id === iid);
  return it ? it.consequence_applied : undefined;
};
const iat = (rec, iid) => {
  const it = rec && rec.items && rec.items.find((x) => x.id === iid);
  return it ? it.applied_at : undefined;
};
async function resetBd() {
  await env.DB.prepare("DELETE FROM work_plane_ops").run();
}
// BDN <re> — grep -c analogue over the work-plane sink (one row = one
// `bd <args>` line; count LINES matching, like `grep -c`).
async function BDN(re) {
  const { results } = await env.DB.prepare("SELECT line FROM work_plane_ops").all();
  const rx = new RegExp(re);
  return (results || []).filter((r) => rx.test(r.line)).length;
}

// ── §4.1 envelope + §4.1.1 item builders (the bash mk()/item()/cb()) ────────
const mk = (id, sv, items) => ({
  id,
  schema_version: sv,
  kind: "decide",
  trigger: "worker_stuck",
  bead_ref: "claude-tools-65z",
  tier: "blocking",
  created_at: "2026-05-16T00:00:00Z",
  timer_fire_at: null,
  body: {
    dossier_schema_version: 2,
    tldr: "opaque to substrate",
    sections: [],
    diagrams: [],
    full_detail: "T5.2 owns this",
  },
  items,
});
const item = (id, state) => ({
  id,
  kind: "approve-reject",
  framing: {},
  context_anchor: { where: "x", expansion: "y" },
  consequence_block: { cb_schema_version: 2, creates: [], unblocks: [], labels: [], status_changes: [] },
  state,
  response: null,
  consequence_applied: false,
  applied_at: null,
});
const cb = (tag, v) => ({
  cb_schema_version: v,
  creates: [{ title: `new ${tag}`, type: "task", priority: 2, labels: ["auto"], description: "d", deps: ["claude-tools-dep"] }],
  unblocks: [`unb-${tag}`],
  labels: [{ bead_ref: `lbl-${tag}`, add: ["go"], remove: ["wait"] }],
  status_changes: [{ bead_ref: `st-${tag}`, to_status: "in_progress" }],
});
const recFields = (state) => ({ state, response: null, consequence_applied: false, applied_at: null });
const item_ar = (id, state) => ({
  id, kind: "approve-reject", framing: {}, context_anchor: { where: "x", expansion: "y" },
  consequence_block: cb(id, 2), reversible: "r", ...recFields(state),
});
const item_po = (id, state) => ({
  id, kind: "pick-option", framing: {}, context_anchor: { where: "x", expansion: "y" },
  options: [
    { option_id: "opt-a", label: "A", blast_radius: "x", consequence_block: cb(`${id}A`, 2) },
    { option_id: "opt-b", label: "B", blast_radius: "y", consequence_block: cb(`${id}B`, 2) },
  ],
  recommendation: { value: "opt-a", why: "because" },
  consequence_block: cb(`${id}A`, 2), reversible: "r", ...recFields(state),
});
const item_ff = (id, state) => ({
  id, kind: "freeform-edit", framing: {}, context_anchor: { where: "x", expansion: "y" },
  consequence_block: cb(id, 2), reversible: "r", ...recFields(state),
});
const item_rec = (id, state) => ({
  id, kind: "approve-recommendation", framing: {}, context_anchor: { where: "x", expansion: "y" },
  recommendation: { value: "v", why: "w" }, consequence_block: cb(id, 2), reversible: "r", ...recFields(state),
});
const item_obj = (id, state) => ({
  id, kind: "fyi-objectable", framing: {}, context_anchor: { where: "x", expansion: "y" },
  consequence_block: cb(id, 2), reversible: "r", ...recFields(state),
});
const cb_bare = (tag) => ({ cb_schema_version: 2, creates: [{ title: `bare ${tag}`, labels: ["x"] }], unblocks: [], labels: [], status_changes: [] });
const item_bare = (id, state) => ({
  id, kind: "approve-reject", framing: {}, context_anchor: { where: "x", expansion: "y" },
  consequence_block: cb_bare(id), reversible: "r", ...recFields(state),
});
const RESP_APPROVE = { decision: "approve", responded_at: "2026-05-16T01:00:00Z", principal: "brian" };
const RESP_PICK_A = { decision: "pick", selected_option_id: "opt-a", responded_at: "2026-05-16T01:00:00Z", principal: "brian" };
const RESP_FREEFORM = { decision: "freeform", freeform_text: "do it another way", responded_at: "2026-05-16T01:00:00Z", principal: "brian" };
const RESP_EDITED = { decision: "approve", edited_value: "changed by human", responded_at: "2026-05-16T01:00:00Z", principal: "brian" };
const RESP_OBJECT = { decision: "object", freeform_text: "I object to this auto-proceed", responded_at: "2026-05-16T01:00:00Z", principal: "brian" };

// ── §5 generation-input builders (the bash test-dossier-gen.sh fixtures) ────
const CBG = { cb_schema_version: 2, creates: [{ title: "follow-up", type: "task" }], unblocks: [], labels: [], status_changes: [] };
const gItemAr = (id) => ({
  id, kind: "approve-reject",
  framing: { ask: "Approve the schema rename?", why: "It unblocks T6b." },
  context_anchor: { where: "impl stage of claude-tools-xyz, the §5 renderer seam", expansion: "The field was renamed in T5.1; T6b binds the new name." },
  reversible: "Reversible — a rename revert is one commit.", consequence_block: CBG,
});
const gItemPo = (id) => ({
  id, kind: "pick-option",
  framing: { ask: "Which auth boundary?", why: "It forecloses the token model." },
  context_anchor: { where: "design stage — reached the auth boundary on the coordinator", expansion: "v1 is a constant principal (§9.1); the pick sets the C7 seam shape." },
  reversible: "Hard to reverse — the token model is load-bearing.",
  recommendation: { value: "opt-bearer", why: "Matches the BC-34 keychain family." },
  options: [
    { option_id: "opt-bearer", label: "Static bearer", blast_radius: "unblocks T3; forecloses per-call mint", consequence_block: CBG },
    { option_id: "opt-mint", label: "Mint per call", blast_radius: "unblocks rotation; forecloses the no-migration C7", consequence_block: CBG },
  ],
});
const gItemRec = (id) => ({
  id, kind: "approve-recommendation",
  framing: { ask: "Adopt the recommended retry posture?", why: "Closes claude-tools-ntn." },
  context_anchor: { where: "impl stage — runner classify_failure precedence", expansion: "A 500 outage misclassifies as UNKNOWN; the rec adds backoff." },
  reversible: "Reversible — the posture is a config constant.",
  recommendation: { value: "backoff+reclassify", why: "A >30s outage must not burn the retry budget." }, consequence_block: CBG,
});
const gItemFf = (id) => ({
  id, kind: "freeform-edit",
  framing: { ask: "Edit the §5.2 framing wording.", why: "Tone pass." },
  context_anchor: { where: "docs stage — the INTERFACE §5.2 prose", expansion: "Reviewers want the self-contained-context line sharpened." },
  reversible: "Fully reversible — prose only.", consequence_block: CBG,
});
const gItemFyi = (id) => ({
  id, kind: "fyi-objectable",
  framing: { ask: "Proceeding to ramp the spare-cycles line unless you object.", why: "Flow F overview." },
  context_anchor: { where: "proactive checkpoint — the §6.3 spare-cycles ramp", expansion: "Day N allows N×14.2% of the 7d budget; this is the auto-proceed." },
  reversible: "Reversible within the window — object to halt.", consequence_block: CBG,
});
const SRC_STRUCT = {
  tldr: "Pick the auth boundary for the coordinator.",
  ask: "Which token model does v1 adopt?",
  sections: [{ heading: "Context", prose: "The runner reached the §9.1 chokepoint." }, { heading: "Trade-offs", prose: "Static bearer vs per-call mint." }],
  diagrams: [{ caption: "Auth flow", content: "flowchart LR\n  runner --> authenticate --> principal" }],
  full_detail: "Standalone: v1 uses a constant principal; the pick fixes the C7 seam so later is one if at the chokepoint, no migration.",
  structural: true,
};
const SRC_NONSTRUCT = {
  tldr: "Approve the doc tone pass.",
  ask: "Approve the §5.2 wording edits?",
  sections: [{ heading: "Scope", prose: "Prose only; no schema or behavior change." }],
  full_detail: "Standalone: the edits sharpen the self-contained-context line; nothing structural changes, so no diagram is warranted.",
  structural: false,
};
const gi = (id, trigger, tier, source, items) => ({
  id, kind: "decide", trigger, bead_ref: "claude-tools-65z", tier, timer_fire_at: null, source, items,
});

it("CF.6 Dossier/Item DO is behaviour-identical to the bash T5 trio + their tests", async () => {
  // ════════════════════════════════════════════════════════════════════════
  // test-dossier.sh — EXIT-1: §4.1/§4.1.1 round-trip · principal+sv · §0.3
  // ════════════════════════════════════════════════════════════════════════
  const D1 = mk("dossA", 2, [item("it1", "open"), item("it2", "open")]);
  const put1 = await call(GOOD, "dossier-put", [D1]);
  ck("do_dossier_put accepts a well-formed v2 envelope", good(put1));
  ck("returns the dossier id", put1.body && put1.body.id === "dossA");
  const S = await GET("dossA");
  ck("envelope round-tripped through the §4 store", !!S && S.id === "dossA");
  ck("§9.1 STAMPED principal=PRINCIPAL_V1", !!S && S.principal === "brian");
  ck("schema_version=2 persisted (§4.1; v2 §11 amend)", !!S && S.schema_version === 2);
  ck("items[] round-tripped (2 Items)", !!S && S.items.length === 2);
  ck("OPAQUE body round-tripped UNTOUCHED (no §5 synthesis)", !!S && S.body.full_detail === "T5.2 owns this");
  ck("per-Item §4.1.1 record shape persisted", !!S && S.items[0].consequence_applied === false);
  const dgA = await dget("dossA");
  ck("do_dossier_get returns the record", !!dgA && dgA.id === "dossA");
  // §0.3 — unknown HIGHER schema_version rejected on WRITE, NO write.
  const bad2 = await call(GOOD, "dossier-put", [mk("dossHi", 3, [item("it1", "open")])]);
  ck("§0.3 — schema_version 3 REJECTED on write (unknown higher; bound=2 v2)", !good(bad2));
  ck("§0.3 — the rejected higher-version dossier was NOT written", (await GET("dossHi")) === null);
  // §0.3 also bound on the READ path: a v3 slipped straight into the store
  // (bypassing put) must be rejected by do_dossier_get, not best-parsed.
  await env.DB.prepare("INSERT OR REPLACE INTO records (type,id,json) VALUES ('dossier','dossRd',?)")
    .bind(JSON.stringify({ ...mk("dossRd", 3, [item("it1", "open")]), principal: "brian" }))
    .run();
  const dgRd = await call(GOOD, "dossier-get", ["dossRd"]);
  ck("§0.3 — do_dossier_get REJECTS an unknown-higher stored record", !good(dgRd));
  // Non-integer schema_version rejected (§4.1 'int' / §0.3 jq type-check).
  const strSv = await call(GOOD, "dossier-put", [{ ...D1, schema_version: "1" }]);
  ck('§0.3 — string "1" schema_version REJECTED', !good(strSv));
  // §9.1 — no bearer ⇒ rejected BEFORE any write (reuse the ONE chokepoint).
  const noTok = await call(null, "dossier-put", [mk("dossNoTok", 2, [item("it1", "open")])]);
  ck("§9.1 — missing bearer ⇒ do_dossier_put REJECTED (401)", noTok.status === 401);
  ck("§9.1 — nothing written on the auth-failed path", (await GET("dossNoTok")) === null);

  // ════════════════════════════════════════════════════════════════════════
  // test-dossier.sh — EXIT-2: per-Item STATE MACHINE — only legal transitions
  // ════════════════════════════════════════════════════════════════════════
  const sc = async (f, t) => good(await call(GOOD, "item-state-check", [f, t]));
  ck("open→answered LEGAL", await sc("open", "answered"));
  ck("answered→applied LEGAL", await sc("answered", "applied"));
  ck("open→expired LEGAL", await sc("open", "expired"));
  ck("open→applied ILLEGAL (skip)", !(await sc("open", "applied")));
  ck("answered→expired ILLEGAL", !(await sc("answered", "expired")));
  ck("open→open ILLEGAL (no-op not legal)", !(await sc("open", "open")));
  ck("applied→answered ILLEGAL (terminal)", !(await sc("applied", "answered")));
  ck("expired→open ILLEGAL (terminal)", !(await sc("expired", "open")));
  ck("answered→open ILLEGAL (no rewind)", !(await sc("answered", "open")));
  ck("unknown→answered ILLEGAL", !(await sc("bogus", "answered")));
  await call(GOOD, "dossier-put", [mk("dossSM", 2, [item("s1", "open"), item("s2", "open")])]);
  ck("set-state s1 open→answered ⇒ persisted",
    good(await call(GOOD, "item-set-state", ["dossSM", "s1", "answered"])) && istate(await GET("dossSM"), "s1") === "answered");
  ck("set-state s1 answered→applied ⇒ persisted",
    good(await call(GOOD, "item-set-state", ["dossSM", "s1", "applied"])) && istate(await GET("dossSM"), "s1") === "applied");
  ck("set-state s2 open→applied REJECTED (illegal skip)", !good(await call(GOOD, "item-set-state", ["dossSM", "s2", "applied"])));
  ck("the REJECTED illegal transition wrote NOTHING (s2 open)", istate(await GET("dossSM"), "s2") === "open");
  ck("set-state s1 applied→answered REJECTED (terminal escape)", !good(await call(GOOD, "item-set-state", ["dossSM", "s1", "answered"])));
  ck("set-state on a MISSING Item id REJECTED (§0.4)", !good(await call(GOOD, "item-set-state", ["dossSM", "nope", "answered"])));

  // ════════════════════════════════════════════════════════════════════════
  // test-dossier.sh — EXIT-3: PRIMITIVE 1 latch (PRIMITIVE 2 task_ref dedup
  // is CF.8's DISTINCT dossier-level key — deliberately NOT here)
  // ════════════════════════════════════════════════════════════════════════
  await call(GOOD, "dossier-put", [mk("dossL", 2, [item("L1", "open"), item("L2", "open")])]);
  ck("do_item_latch flips consequence_applied false→true once", good(await call(GOOD, "item-latch", ["dossL", "L1"])));
  ck("L1.consequence_applied is now true", ica(await GET("dossL"), "L1") === true);
  ck("L1.applied_at stamped (§4.1.1)", iat(await GET("dossL"), "L1") !== null);
  ck("SECOND latch on L1 REJECTED (single-writer-set; once)", !good(await call(GOOD, "item-latch", ["dossL", "L1"])));
  ck("the rejected 2nd latch wrote NOTHING (still true, once)", ica(await GET("dossL"), "L1") === true);
  ck("latch did NOT move .state (state↔latch orthogonal)", istate(await GET("dossL"), "L1") === "open");
  ck("latch applied NO ConsequenceBlock (creates[] untouched)",
    (await GET("dossL")).items.find((x) => x.id === "L1").consequence_block.creates.length === 0);
  const l2 = good(await call(GOOD, "item-latch", ["dossL", "L2"])) && ica(await GET("dossL"), "L2") === true;
  ck("L2 latch independent (per-Item key = Item id; §0.4)", l2);

  // ════════════════════════════════════════════════════════════════════════
  // test-dossier.sh — EXIT-4: DERIVED rollup — informational, NEVER a gate
  // ════════════════════════════════════════════════════════════════════════
  const rollup = async (env_) => (await call(GOOD, "dossier-rollup", [env_])).raw;
  ck("rollup = open while ≥1 item non-terminal",
    (await rollup(mk("x", 2, [item("a", "applied"), item("b", "open")]))) === "open");
  ck("rollup = open while an item is merely answered (non-terminal)",
    (await rollup(mk("x", 2, [item("a", "answered")]))) === "open");
  ck("rollup = resolved when ALL items terminal (applied|expired)",
    (await rollup(mk("x", 2, [item("a", "applied"), item("b", "expired")]))) === "resolved");
  await call(GOOD, "dossier-put", [mk("dossR", 2, [item("r1", "open")])]);
  ck("rollup persisted onto the stored envelope (projection datum)", (await GET("dossR")).state === "open");
  // THE AD7 invariant: the rollup gates NOTHING — resolve exactly 6 of 15.
  await call(GOOD, "dossier-put", [mk("doss15", 2, Array.from({ length: 15 }, (_, i) => item(`q${i + 1}`, "open")))]);
  for (let n = 1; n <= 6; n++) {
    await call(GOOD, "item-set-state", ["doss15", `q${n}`, "answered"]);
    await call(GOOD, "item-latch", ["doss15", `q${n}`]);
    await call(GOOD, "item-set-state", ["doss15", `q${n}`, "applied"]);
  }
  let s15 = await GET("doss15");
  ck("resolving 6 of 15 ⇒ exactly 6 consequence_applied latched",
    s15.items.filter((x) => x.consequence_applied === true).length === 6);
  ck("the other 9 items stay open (partial resolution — AD7)",
    s15.items.filter((x) => x.state === "open").length === 9);
  ck("rollup is still 'open' (≥1 non-terminal) — informational", s15.state === "open");
  ck("a 7th item still transitions — rollup NEVER blocked a sibling op",
    good(await call(GOOD, "item-set-state", ["doss15", "q7", "answered"])) && istate(await GET("doss15"), "q7") === "answered");
  for (let n = 1; n <= 15; n++) {
    const st = istate(await GET("doss15"), `q${n}`);
    if (st === "open") await call(GOOD, "item-set-state", ["doss15", `q${n}`, "expired"]);
    if (st === "answered") await call(GOOD, "item-set-state", ["doss15", `q${n}`, "applied"]);
  }
  s15 = await GET("doss15");
  ck("rollup now 'resolved' (all 15 terminal)", s15.state === "resolved");
  ck("do_dossier_get STILL serves a 'resolved' dossier (not a gate)", (await dget("doss15")).items.length === 15);

  // ════════════════════════════════════════════════════════════════════════
  // test-dossier.sh — EXIT-3/4 CONCURRENCY: single-WRITER, not single-value
  // (S-6 timer-fire vs poll-fallback; AD7 under load) — the AD1 payoff
  // ════════════════════════════════════════════════════════════════════════
  await call(GOOD, "dossier-put", [mk("dossC", 2, [item("C1", "open")])]);
  const latchRace = await Promise.all(
    "abcdefgh".split("").map(() => call(GOOD, "item-latch", ["dossC", "C1"]))
  );
  const won = latchRace.filter((r) => good(r)).length;
  ck("EXACTLY ONE of 8 concurrent latch flips won (single-WRITER; §7.4/S-6)", won === 1);
  ck("the 7 racing losers were REJECTED (false→true ONCE under concurrency)", 8 - won === 7);
  ck("C1.consequence_applied is true exactly once", ica(await GET("dossC"), "C1") === true);
  ck("C1.applied_at stamped once (no torn/duplicate apply)", iat(await GET("dossC"), "C1") !== null);
  // AD7 partial resolution UNDER CONCURRENCY: parallel set-state on DIFFERENT
  // sibling Items must NOT clobber each other (no lost update).
  await call(GOOD, "dossier-put", [mk("dossP", 2, Array.from({ length: 12 }, (_, i) => item(`p${i + 1}`, "open")))]);
  await Promise.all(Array.from({ length: 12 }, (_, i) => call(GOOD, "item-set-state", ["dossP", `p${i + 1}`, "answered"])));
  ck("12 concurrent sibling-Item moves ALL persisted (no lost update — AD7)",
    (await GET("dossP")).items.filter((x) => x.state === "answered").length === 12);

  // ════════════════════════════════════════════════════════════════════════
  // test-consequence.sh — EXIT-1: idempotency — double-tap AND alarm+poll
  // ════════════════════════════════════════════════════════════════════════
  await call(GOOD, "dossier-put", [mk("dA", 2, [item_ar("i1", "open")])]);
  await resetBd();
  ck("do_item_apply (approve) succeeds", good(await call(GOOD, "item-apply", ["dA", "i1", RESP_APPROVE])));
  ck("i1 consequence_applied flipped false→true", ica(await GET("dA"), "i1") === true);
  ck("i1 state answered→applied", istate(await GET("dA"), "i1") === "applied");
  ck("i1 applied_at stamped (§4.1.1)", iat(await GET("dA"), "i1") !== null);
  ck("§5.3 create ran ONCE for this item", (await BDN("create --title new i1")) === 1);
  const AT1 = iat(await GET("dA"), "i1");
  const CR1 = await BDN("create --title new i1");
  ck("2nd identical apply (double-tap) returns success", good(await call(GOOD, "item-apply", ["dA", "i1", RESP_APPROVE])));
  ck("consequence_applied STILL true (flipped ONCE)", ica(await GET("dA"), "i1") === true);
  ck("applied_at UNCHANGED (no re-apply)", iat(await GET("dA"), "i1") === AT1);
  ck("NO additional §5.3 create on double-tap", (await BDN("create --title new i1")) === CR1);
  // ALARM + POLL (S-6): the entrypoint T5.4/CF.7 calls from BOTH alarm-fire
  // and poll-fallback — concurrently. Exactly one applier; consequence ONCE.
  await call(GOOD, "dossier-put", [mk("dC", 2, [item_ar("c1", "open")])]);
  await resetBd();
  const applyRace = await Promise.all(
    "abcdefgh".split("").map(() => call(GOOD, "item-apply", ["dC", "c1", RESP_APPROVE]))
  );
  ck("C1 consequence_applied true exactly once", ica(await GET("dC"), "c1") === true);
  ck("§5.3 create ran EXACTLY ONCE under 8-way race (S-6)", (await BDN("create --title new c1")) === 1);
  ck("every concurrent caller returned success (idempotent)", applyRace.every((r) => good(r)));

  // ── test-consequence.sh — EXIT-4: §5.3 hits ALL FOUR work-plane kinds ──
  ck("creates[]        ⇒ bd create", (await BDN("create --title new c1")) >= 1);
  ck("creates[].deps[] ⇒ bd dep add <new> <dep>", (await BDN("dep add bd-fake-.* claude-tools-dep")) >= 1);
  ck("unblocks[]       ⇒ bd update <ref> --status=open", (await BDN("update unb-c1 --status=open")) >= 1);
  ck("labels[]         ⇒ bd update --add-label/--remove-label", (await BDN("update lbl-c1 --add-label go --remove-label wait")) >= 1);
  ck("status_changes[] ⇒ bd update <ref> --status=<to>", (await BDN("update st-c1 --status=in_progress")) >= 1);

  // ── test-consequence.sh — EXIT-3: §5.2.2 PER-ITEM routing ──
  // (a) pick-option: the CHOSEN option's block, not the other's.
  await call(GOOD, "dossier-put", [mk("dP", 2, [item_po("p1", "open")])]);
  await resetBd();
  ck("pick opt-a ⇒ deterministic apply succeeds", good(await call(GOOD, "item-apply", ["dP", "p1", RESP_PICK_A])));
  ck("chosen option-A block applied", (await BDN("create --title new p1A")) === 1);
  ck("the NON-chosen option-B block NOT applied", (await BDN("create --title new p1B")) === 0);
  ck("p1 applied + latched", istate(await GET("dP"), "p1") === "applied");
  ck("no follow-up dossier on the deterministic path", (await dget("dP-fu-p1")) === null);
  // (b) RECONCILER: freeform ⇒ NO block applied, follow-up scoped to item.
  await call(GOOD, "dossier-put", [mk("dR", 2, [item_ar("sib1", "open"), item_ff("ff1", "open"), item_ar("sib2", "open")])]);
  await call(GOOD, "item-apply", ["dR", "sib1", RESP_APPROVE]);
  const SIB1_AT = iat(await GET("dR"), "sib1");
  await resetBd();
  ck("freeform-edit ⇒ reconciler path succeeds", good(await call(GOOD, "item-apply", ["dR", "ff1", RESP_FREEFORM])));
  ck("reconciler applied NO §5.3 block (no bd create)", (await BDN("create --title new ff1")) === 0);
  ck("ff1 marked applied+latched (consequence=dispatch, once)", istate(await GET("dR"), "ff1") === "applied");
  ck("ff1 latch true", ica(await GET("dR"), "ff1") === true);
  const FU = await dget("dR-fu-ff1");
  ck("a follow-up Dossier was emitted (dR-fu-ff1)", !!FU);
  ck("follow-up is SCOPED to the one item (exactly 1)", !!FU && FU.items.length === 1);
  ck("follow-up carries a fresh re-decide item id", !!FU && FU.items[0].id === "ff1-r1");
  ck("follow-up item reset to open for re-decision", !!FU && FU.items[0].state === "open");
  ck("follow-up body is an OPAQUE reconcile pointer (NOT §5 content)", !!FU && FU.body.reconcile_of === "dR");
  ck("RESOLVED sibling sib1 UNTOUCHED (state)", istate(await GET("dR"), "sib1") === "applied");
  ck("RESOLVED sibling sib1 UNTOUCHED (applied_at)", iat(await GET("dR"), "sib1") === SIB1_AT);
  ck("OPEN sibling sib2 still open (never reopened/closed)", istate(await GET("dR"), "sib2") === "open");
  ck("OPEN sibling sib2 latch still false", ica(await GET("dR"), "sib2") === false);
  // (c) EDITED approve-recommendation ⇒ reconciler (edited, not pure).
  await call(GOOD, "dossier-put", [mk("dE", 2, [item_rec("e1", "open")])]);
  await resetBd();
  ck("approve-recommendation w/ edited_value ⇒ succeeds", good(await call(GOOD, "item-apply", ["dE", "e1", RESP_EDITED])));
  ck("edited ⇒ RECONCILER (no deterministic block applied)", (await BDN("create --title new e1")) === 0);
  ck("edited ⇒ a follow-up dossier emitted", !!(await dget("dE-fu-e1")));
  // (d) un-edited approve-recommendation ⇒ DETERMINISTIC.
  await call(GOOD, "dossier-put", [mk("dD", 2, [item_rec("d1", "open")])]);
  await resetBd();
  ck("un-edited approve-recommendation ⇒ deterministic", good(await call(GOOD, "item-apply", ["dD", "d1", RESP_APPROVE])));
  ck("deterministic block applied (bd create ran)", (await BDN("create --title new d1")) === 1);
  ck("no follow-up on the deterministic recommendation", (await dget("dD-fu-d1")) === null);
  // (e) decision:"object" on a fyi-objectable item ⇒ RECONCILER.
  await call(GOOD, "dossier-put", [mk("dO", 2, [item_obj("o1", "open")])]);
  await resetBd();
  ck("fyi-objectable + decision:object ⇒ reconciler succeeds", good(await call(GOOD, "item-apply", ["dO", "o1", RESP_OBJECT])));
  ck("objected ⇒ NO §5.3 block applied (no bd create)", (await BDN("create --title new o1")) === 0);
  ck("objected ⇒ a follow-up dossier emitted (objection interpreted)", !!(await dget("dO-fu-o1")));
  ck("objected o1 marked applied+latched (exactly once)", istate(await GET("dO"), "o1") === "applied");

  // ── test-consequence.sh — EXIT-2: partial application — 6 of 15 ──
  await call(GOOD, "dossier-put", [mk("d15", 2, Array.from({ length: 15 }, (_, i) => item_ar(`q${i + 1}`, "open")))]);
  await resetBd();
  for (let n = 1; n <= 6; n++) await call(GOOD, "item-apply", ["d15", `q${n}`, RESP_APPROVE]);
  const d15s = await GET("d15");
  ck("exactly 6 items consequence_applied", d15s.items.filter((x) => x.consequence_applied === true).length === 6);
  ck("exactly 6 items state=applied", d15s.items.filter((x) => x.state === "applied").length === 6);
  ck("the other 9 items STILL open (AD7 partial)", d15s.items.filter((x) => x.state === "open").length === 9);
  ck("the other 9 latches STILL false", d15s.items.filter((x) => x.consequence_applied === false).length === 9);
  let six = 0;
  for (let n = 1; n <= 6; n++) if ((await BDN(`new q${n} --type`)) === 1) six++;
  ck("each of the 6 blocks applied EXACTLY once", six === 6);
  ck("no block applied for the 9 unresolved (q7)", (await BDN("new q7 --type")) === 0);
  ck("a 7th item still applies (no sibling gate — AD7)", good(await call(GOOD, "item-apply", ["d15", "q7", RESP_APPROVE])));
  ck("q7 now applied", istate(await GET("d15"), "q7") === "applied");

  // ── test-consequence.sh — EXIT-5: FROZEN §5.3 binding · key=Item id ──
  const dV = mk("dV", 2, [item_ar("v1", "open")]);
  dV.items[0].consequence_block.cb_schema_version = 3;
  await call(GOOD, "dossier-put", [dV]);
  await resetBd();
  ck("cb_schema_version 3 ⇒ apply REJECTED (§0.3 unknown higher; bound=2 v2)", !good(await call(GOOD, "item-apply", ["dV", "v1", RESP_APPROVE])));
  ck("the §0.3-rejected block ran NO work-plane op", (await BDN("create")) === 0);
  ck("the §0.3-rejected item latch NOT flipped", ica(await GET("dV"), "v1") === false);
  ck("the §0.3-rejected item NOT moved to applied", istate(await GET("dV"), "v1") !== "applied");
  await call(GOOD, "dossier-put", [mk("dB", 2, [item_bare("b1", "open")])]);
  await resetBd();
  ck("bare create (no type/priority/desc) ⇒ apply succeeds", good(await call(GOOD, "item-apply", ["dB", "b1", RESP_APPROVE])));
  ck("absent §5.3 type NOT synthesised (no --type)", (await BDN("create --title bare b1 --type")) === 0);
  ck("absent §5.3 prio NOT synthesised (no -p)", (await BDN("create --title bare b1 .* -p ")) === 0);
  ck("absent §5.3 desc NOT synthesised (no -d)", (await BDN("create --title bare b1 .* -d ")) === 0);
  ck("the bare create DID run (title + present labels only)", (await BDN("create --title bare b1 --labels x")) === 1);
  await call(GOOD, "dossier-put", [mk("dK", 2, [item_ar("k1", "open"), item_ar("k2", "open")])]);
  await call(GOOD, "item-apply", ["dK", "k1", RESP_APPROVE]);
  ck("applying k1 latched k1", ica(await GET("dK"), "k1") === true);
  ck("applying k1 did NOT latch sibling k2 (key=Item id; §0.4)", ica(await GET("dK"), "k2") === false);
  ck("sibling k2 still open", istate(await GET("dK"), "k2") === "open");
  await call(GOOD, "dossier-put", [mk("dN", 2, [item_ar("n1", "open")])]);
  await call(GOOD, "item-set-state", ["dN", "n1", "answered", RESP_APPROVE]);
  await resetBd();
  ck("answered Item applies from its RECORDED .response (no arg)", good(await call(GOOD, "item-apply", ["dN", "n1"])));
  ck("answered-path applied the block", (await BDN("create --title new n1")) === 1);
  ck("answered-path n1 now applied", istate(await GET("dN"), "n1") === "applied");
  await call(GOOD, "dossier-put", [mk("dX", 2, [item_ar("x1", "open")])]);
  await call(GOOD, "item-set-state", ["dX", "x1", "expired"]);
  ck("expired Item ⇒ apply REJECTED", !good(await call(GOOD, "item-apply", ["dX", "x1", RESP_APPROVE])));
  ck("apply on a MISSING Item id REJECTED (§0.4)", !good(await call(GOOD, "item-apply", ["dN", "nope", RESP_APPROVE])));
  ck("apply on a MISSING dossier REJECTED", !good(await call(GOOD, "item-apply", ["nodoss", "x", RESP_APPROVE])));

  // ════════════════════════════════════════════════════════════════════════
  // test-dossier-gen.sh — EXIT-1: §5.1 body — ALL FOUR tiers mandatory (AD7)
  // ════════════════════════════════════════════════════════════════════════
  const G1 = gi("genA", "worker_stuck", "blocking", SRC_STRUCT, [gItemPo("d1")]);
  const genA = await call(GOOD, "dossier-generate", [G1]);
  ck("ONE dg_generate call accepts a well-formed §5 dossier", good(genA));
  ck("returns the dossier id", genA.body && genA.body.id === "genA");
  const gA = await GET("genA");
  ck("envelope round-tripped THROUGH the §4.1 store", !!gA && gA.id === "genA");
  ck("§9.1 STAMPED principal (no second auth path here)", !!gA && gA.principal === "brian");
  ck("§5.1 tldr present + non-empty", !!gA && !!gA.body.tldr);
  ck("§5.1 sections[] present + ≥1", !!gA && gA.body.sections.length >= 1);
  ck("§5.1 sections[0] heading+prose non-empty", !!gA && !!gA.body.sections[0].prose);
  ck("§5.1 diagrams[] NON-empty for a STRUCTURAL source", !!gA && gA.body.diagrams.length >= 1);
  ck("§5.1 full_detail present + non-empty", !!gA && !!gA.body.full_detail);
  ck("§5.1 dossier_schema_version stamped (=bound 2)", !!gA && gA.body.dossier_schema_version === 2);
  const G1b = gi("genB", "proactive_checkpoint", "digest", SRC_NONSTRUCT, [gItemAr("d1")]);
  ck("non-structural source ⇒ dg_generate still succeeds", good(await call(GOOD, "dossier-generate", [G1b])));
  const gB = await GET("genB");
  ck("§5.1 diagrams[]==[] ONLY when genuinely non-structural", !!gB && gB.body.diagrams.length === 0);
  ck("the other 3 tiers still present (non-structural)", !!gB && !!gB.body.full_detail);
  const vb = async (b) => good(await call(GOOD, "validate-body", [b]));
  ck("§5.1 empty sections[] REJECTED (decision-singular AD7 regression)",
    !(await vb({ dossier_schema_version: 2, tldr: "x", sections: [], diagrams: [], full_detail: "y" })));
  ck("§5.1 missing full_detail REJECTED (not optional — AD7)",
    !(await vb({ dossier_schema_version: 2, tldr: "x", sections: [{ heading: "h", prose: "p" }], diagrams: [] })));
  ck("§0.3 — body dossier_schema_version=3 REJECTED (unknown higher; bound=2 v2)",
    !(await vb({ dossier_schema_version: 3, tldr: "x", sections: [{ heading: "h", prose: "p" }], diagrams: [], full_detail: "f" })));

  // ── test-dossier-gen.sh — EXIT-2: MANDATORY context_anchor — reject ──
  const vi = async (i) => good(await call(GOOD, "validate-item", [i]));
  const noctx = (() => { const x = gItemAr("d1"); delete x.context_anchor; return x; })();
  ck("Item with NO context_anchor ⇒ dg__validate_item REJECTS", !(await vi(noctx)));
  ck("dg_generate REJECTS a dossier whose Item lacks context_anchor",
    !good(await call(GOOD, "dossier-generate", [gi("genNoCtx", "human_flag", "blocking", SRC_STRUCT, [noctx])])));
  ck("the REJECTED contextless dossier was NOT written", (await GET("genNoCtx")) === null);
  ck("empty context_anchor.where REJECTED",
    !(await vi({ ...gItemAr("d1"), context_anchor: { where: "", expansion: "y" } })));
  ck("whitespace-only context_anchor.expansion REJECTED",
    !(await vi({ ...gItemAr("d1"), context_anchor: { where: "w", expansion: "   " } })));
  ck("a valid Item's context_anchor round-trips {where,expansion}", !!gA && !!gA.items[0].context_anchor.expansion);
  ck("context_anchor.where round-tripped non-empty", !!gA && !!gA.items[0].context_anchor.where);

  // ── test-dossier-gen.sh — EXIT-3: §5.2 kind enum + §5.3 cb ──
  ck("kind=approve-reject + applyable cb ⇒ valid", await vi(gItemAr("a1")));
  ck("kind=pick-option + per-option applyable cb ⇒ valid", await vi(gItemPo("a2")));
  ck("kind=approve-recommendation ⇒ valid", await vi(gItemRec("a3")));
  ck("kind=freeform-edit ⇒ valid", await vi(gItemFf("a4")));
  ck("kind=fyi-objectable ⇒ valid", await vi(gItemFyi("a5")));
  ck("kind NOT in the CLOSED §5.2 enum ⇒ REJECTED", !(await vi({ ...gItemAr("a6"), kind: "decide" })));
  ck("pick-option each option carries a pre-declared consequence_block",
    !!gA && gA.items[0].options.map((o) => o.consequence_block).length === 2);
  ck("pick-option option cb_schema_version stamped (=bound, §0.3)",
    !!gA && gA.items[0].options[0].consequence_block.cb_schema_version === 2);
  ck("pick-option missing recommendation ⇒ REJECTED (§5.2)",
    !(await vi((() => { const x = gItemPo("a7"); delete x.recommendation; return x; })())));
  ck("pick-option with NO options ⇒ REJECTED (§5.2)", !(await vi({ ...gItemPo("a8"), options: [] })));
  ck("pick-option duplicate option_id ⇒ REJECTED (ambiguous chosen block)",
    !(await vi((() => { const x = gItemPo("a9"); x.options[1].option_id = x.options[0].option_id; return x; })())));
  const vc = async (c) => good(await call(GOOD, "cb-applyable", [c]));
  ck("dg__cb_applyable accepts a v2 four-array block",
    await vc({ cb_schema_version: 2, creates: [], unblocks: [], labels: [], status_changes: [] }));
  ck("§0.3 — cb_schema_version=3 REJECTED (unknown higher; bound=2 v2)", !(await vc({ cb_schema_version: 3, creates: [] })));
  ck("§5.3 — creates not an array ⇒ REJECTED", !(await vc({ cb_schema_version: 2, creates: "nope" })));
  ck("an Item whose cb is NOT machine-applyable ⇒ Item REJECTED",
    !(await vi({ ...gItemAr("a10"), consequence_block: { cb_schema_version: 99 } })));

  // ── test-dossier-gen.sh — EXIT-4: §5.2.1 profiles — SAME shape, NO branch ──
  ck("Flow F overview: deep body + ZERO items ⇒ valid (§5.2.1)",
    good(await call(GOOD, "dossier-generate", [gi("fF0", "proactive_checkpoint", "timed-fyi", SRC_STRUCT, [])])));
  ck("zero-item overview persisted with items[]==[] (same shape)", (await GET("fF0")).items.length === 0);
  ck("the zero-item overview STILL has a full deep §5.1 body", !!(await GET("fF0")).body.full_detail);
  ck("Flow F overview: deep body + ALL-fyi-objectable ⇒ valid (§5.2.1)",
    good(await call(GOOD, "dossier-generate", [gi("fFa", "proactive_checkpoint", "timed-fyi", SRC_STRUCT, [gItemFyi("f1"), gItemFyi("f2"), gItemFyi("f3")])])));
  ck("all-fyi overview: 3 items, all kind=fyi-objectable",
    (await GET("fFa")).items.filter((x) => x.kind === "fyi-objectable").length === 3);
  ck("mixed multi-item review (5 kinds) ⇒ valid (§5.2.1)",
    good(await call(GOOD, "dossier-generate", [gi("mix", "stage_gate", "blocking", SRC_STRUCT, [gItemAr("m1"), gItemPo("m2"), gItemRec("m3"), gItemFf("m4"), gItemFyi("m5")])])));
  ck("mixed review persisted all 5 independently-respondable items", (await GET("mix")).items.length === 5);
  ck("mixed review carries the SAME deep §5.1 body shape", !!(await GET("mix")).body.full_detail);
  const WASK = {
    tldr: "Worker hit the auth boundary on the fork.",
    ask: "Pick the token model so the fork can resolve.",
    options: [
      { option_id: "o-bearer", label: "Static bearer", blast_radius: "unblocks T3", consequence_block: CBG },
      { option_id: "o-mint", label: "Mint per call", blast_radius: "forecloses no-migration C7", consequence_block: CBG },
    ],
    recommendation: { value: "o-bearer", why: "BC-34 keychain family; no migration." },
    reversible: "Hard — token model is load-bearing.",
  };
  const wask = await call(GOOD, "dossier-from-worker-ask", ["wstuck", "claude-tools-65z", WASK]);
  ck("dg_from_worker_ask consumes the §7.2 ask ⇒ a dossier", good(wask));
  const wst = await GET("wstuck");
  ck("worker_stuck profile: trigger=worker_stuck", !!wst && wst.trigger === "worker_stuck");
  ck("worker_stuck profile: deep §5.1 body present", !!wst && !!wst.body.full_detail);
  ck("worker_stuck profile: exactly ONE pick-option item",
    !!wst && wst.items.filter((x) => x.kind === "pick-option").length === 1);
  ck("worker_stuck item carries the MANDATORY context_anchor", !!wst && !!wst.items[0].context_anchor.where);
  ck("ALL four profiles validated by the SAME dg__validate_dossier (no branch)",
    good(await call(GOOD, "validate-dossier", [await GET("mix")])));
  ck("the zero-item overview ALSO passes that very same validator",
    good(await call(GOOD, "validate-dossier", [await GET("fF0")])));

  // ── test-dossier-gen.sh — EXIT-5: binds the SCHEMA, never the pass count ──
  // The bash DG_AUTHOR_CMD shell-cmd swap is realized as the DG_AUTHOR_FIXTURE
  // env knob (a Worker cannot exec a cmd) — the SAME env-knob pattern CF.1
  // uses for CO_EXPECTED_TOKEN. A swapped author still flows the SAME §5 gate.
  env.DG_AUTHOR_FIXTURE = JSON.stringify({
    body: { dossier_schema_version: 2, tldr: "swapped-author tldr", sections: [{ heading: "S", prose: "swapped prose" }], diagrams: [{ caption: "c", content: "flowchart TD\n  A --> B" }], full_detail: "swapped full detail, stands alone." },
    items: [{ id: "sw1", kind: "approve-reject", framing: { ask: "swapped ask", why: "swapped why" }, context_anchor: { where: "swapped where", expansion: "swapped expansion" }, reversible: "swapped reversible", consequence_block: { cb_schema_version: 2, creates: [], unblocks: [], labels: [], status_changes: [] } }],
  });
  await call(GOOD, "dossier-generate", [gi("swap", "human_flag", "blocking", SRC_STRUCT, [gItemAr("ignored")])]);
  ck("a SWAPPED author still produces a schema-valid dossier (pass-count not bound)",
    (await GET("swap")) && (await GET("swap")).body.tldr === "swapped-author tldr");
  ck("the swapped dossier still passes the SAME frozen §5 gate",
    good(await call(GOOD, "validate-dossier", [await GET("swap")])));
  env.DG_AUTHOR_FIXTURE = JSON.stringify({
    body: { dossier_schema_version: 2, tldr: "t", sections: [{ heading: "h", prose: "p" }], diagrams: [], full_detail: "f" },
    items: [{ id: "bad1", kind: "approve-reject", framing: { ask: "a", why: "w" }, reversible: "r", consequence_block: { cb_schema_version: 2, creates: [], unblocks: [], labels: [], status_changes: [] } }],
  });
  ck("swapped author emitting an Item w/o context_anchor ⇒ STILL REJECTED",
    !good(await call(GOOD, "dossier-generate", [gi("swapbad", "human_flag", "blocking", SRC_STRUCT, [])])));
  ck("the schema-violating swapped dossier was NOT written", (await GET("swapbad")) === null);
  delete env.DG_AUTHOR_FIXTURE;
  ck("§9.1 — dg_generate with NO bearer ⇒ REJECTED (401)",
    (await call(null, "dossier-generate", [gi("noTok", "human_flag", "blocking", SRC_STRUCT, [gItemAr("d1")])])).status === 401);
  ck("§9.1 — nothing written on the auth-failed generate", (await GET("noTok")) === null);

  // ════════════════════════════════════════════════════════════════════════
  // ANTI-DRIFT (structural — sibling surfaces untouched)
  // ════════════════════════════════════════════════════════════════════════
  // CF.1 §4 registry dossier⇒2 (v2 §11 Mermaid amend; CF.6 added no record
  // type) — sv2 ok above; sv3 rejected above.
  // CF.6 added NO §4 record type: a put of a CF.6-shaped type is an unknown
  // §4 type (the `co__schema_version dossier_dedup/dossier_fu/dossier_gen ==
  // ""` analogue — the dossier-level dedup is CF.8's distinct key, NOT here).
  for (const t of ["dossier_dedup", "dossier_fu", "dossier_gen"]) {
    const r = await call(GOOD, "put", [t, "z", '{"schema_version":1}']);
    ck(`CF.6 added NO §4 record type '${t}' (unknown_type reject)`, r.body && r.body.code === "unknown_type");
  }
  const FU2 = await dget("dR-fu-ff1");
  ck("follow-up carries the ORIGINAL item kind verbatim (no §5 synthesis)",
    !!FU2 && FU2.items[0].kind === "freeform-edit");
  ck("follow-up body has NONE of the §5 tiers (generation is a sibling)",
    !!FU2 && !(("tldr" in FU2.body) || ("sections" in FU2.body) || ("diagrams" in FU2.body) || ("full_detail" in FU2.body)));
  const capsRes = await SELF.fetch(new Request("https://coordinator.local/", { method: "GET", headers: { authorization: `Bearer ${GOOD}` } }));
  const caps = await capsRes.text();
  ck("CF.1 capabilities still EXACTLY four §2 lines", (caps.match(/§2/g) || []).length === 4);
  ck("no CF.6 op is advertised as a §2 capability",
    !/do_dossier|dg_generate|do_item_apply|dossier-generate|item-apply/.test(caps));

  // eslint-disable-next-line no-console
  console.log(`\n══ CF.6 differential (vs the bash T5 trio + tests): PASS=${PASS} FAIL=${FAIL} ══`);
  if (FAIL > 0) {
    // eslint-disable-next-line no-console
    console.log("FAILED:\n  - " + fails.join("\n  - "));
  }
  expect(FAIL, `differential clauses failed: ${fails.join("; ")}`).toBe(0);
});
