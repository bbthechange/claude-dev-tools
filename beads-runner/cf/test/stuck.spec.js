// CF.8 (claude-tools-7g0.8) — DIFFERENTIAL conformance test.
//
// Mirrors lib/test-stuck-routing.sh (the T5.5 §7.4 dossier-level
// double-trigger dedup + §7.3 backstop-drives-the-bead + S-2/AD3.1
// control→work reconcile) clause-for-clause, AND demonstrates the cross-tier
// OUTCOME the STUCK-e2e forward GATE conformance/assertions/bc-stuck-cross-tier
// .sh asserts (§7.2 two independent triggers + §7.3 a fired backstop MUST
// itself drive the bead to blocked-for-human — bead ENDS blocked, never reset
// to open, `bd human` honored, for BOTH the worker path and the runner
// backstop). Every assertion exercises the REAL engine via SELF.fetch
// (Worker → §9.1 chokepoint → singleton Coordinator DO → D1) on the SAME
// workerd+miniflare runtime `wrangler dev` uses, NO Cloudflare account. The CF
// engine MUST exhibit the SAME INTERFACE.md v1 §7.2/§7.3/§7.4(dossier-level)
// behaviour as lib/stuck-routing.sh + those tests assert — not a re-spec.
//
// ANTI-OVERLAP (binding, 1:1 with bc-stuck-cross-tier.sh's own note): this
// asserts the CF.8-owned cross-tier OUTCOME — the bead must END
// blocked-for-human with `bd human`, ONE Dossier per fork, the S-2 reconcile
// driven by the control plane. It does NOT re-assert the §7.1 classification
// STRING or the §7.5 breaker/retry exemption (T2/T1a, frozen) — those are not
// exercised here.
//
// Linear single flow with per-file isolated storage (the bash test's
// fresh-mktemp-store analogue). `env` is used ONLY to read the opaque stored
// state (the §4 `records` set + the SEPARATE stuck_* sibling namespace) and to
// simulate the WORK-plane (Dolt) lag clobber — EXACTLY mirroring the bash
// test's direct `$BDST`/`$BD_HUMAN` store reads + its `printf 'open' > $BDST`
// clobber. No non-contract debug surface is added to the engine; the pure
// `stuckDossierIdFor` predicate drops to a direct import EXACTLY as the bash
// test drops to `sr_dossier_id_for`, and `schemaVersion` to the direct import
// EXACTLY as the bash test drops to `co__schema_version`.

import { env, SELF } from "cloudflare:test";
import { it, expect } from "vitest";
import { stuckDossierIdFor } from "../src/stuck.js";
import { schemaVersion } from "../src/schema.js";

const GOOD = "bearer-runner-secret-xyz"; // a present, valid v1 bearer

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
function eq(name, got, want) {
  ck(`${name} (${JSON.stringify(got)})`, got === want);
}
function ne(name, a, b) {
  ck(name, a !== b);
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
async function callJson(op, args) {
  const r = await call(GOOD, op, args);
  return r.body;
}

// ── direct store reads — the bash test's `$BDST`/`$BD_HUMAN`/`ls dossier.*`
//    reads + its `printf > $BDST` clobber. `env.DB` is the SAME D1 the DO uses
//    (the reconcile.spec `recordSig()` precedent). No engine debug op. ────────
// A missing table = the bash store dir/file simply not existing yet ⇒ empty
// (the faithful differential of bash's `[[ -f … ]] || default`; the DO lazily
// DDLs on its FIRST contact, never on a 401-rejected request that never
// reaches it). Robust to call-order, never a silent green elsewhere.
async function dbFirst(sql, ...bind) {
  try {
    return await env.DB.prepare(sql)
      .bind(...bind)
      .first();
  } catch {
    return null;
  }
}
async function dossierCount() {
  const r = await dbFirst("SELECT COUNT(*) AS n FROM records WHERE type = 'dossier'");
  return r ? r.n : 0;
}
// BDSTATUS: the work-plane status projection; absent ⇒ "open" (bash default).
async function beadStatus(tref) {
  const r = await dbFirst("SELECT status FROM stuck_bead_status WHERE bead_ref = ?", tref);
  return r ? r.status : "open";
}
// HUMAN_HITS: count of `bd human <tref>` lines in the work-plane log
// (the $BD_HUMAN analogue — §7.3 "bd human raised, fork ≠ rot").
async function humanHits(tref) {
  const r = await dbFirst(
    "SELECT COUNT(*) AS n FROM stuck_work_plane WHERE line = ?",
    `human ${tref}`
  );
  return r ? r.n : 0;
}
// The simulated WORK-plane (Dolt) lag: a later writer clobbers the bead status
// out from under us WITHOUT touching the control-plane stuck_bfh record. 1:1
// with the bash test's `printf 'open' > "$BDST/$H"` (NOT an engine op — a
// direct work-plane poke, exactly as bash pokes the fake's state file).
async function clobberBead(tref, status) {
  await env.DB.prepare(
    "INSERT INTO stuck_bead_status (bead_ref, status) VALUES (?, ?) ON CONFLICT(bead_ref) DO UPDATE SET status = excluded.status"
  )
    .bind(tref, status)
    .run();
}
// DJQ <id> <fn>: fetch the stored Dossier (the bash `co_request get dossier`)
// and project a field — the in-process projection the bash DJQ does via jq.
async function getDossier(id) {
  const r = await call(GOOD, "dossier-get", [id]);
  if (r.status !== 200) return null;
  try {
    return JSON.parse(r.raw);
  } catch {
    return null;
  }
}
// BFHJQ <tref> <field>: the control-plane blocked-for-human truth consult.
async function bfhField(tref, field) {
  const r = await call(GOOD, "stuck-bfh-get", [tref]);
  if (r.status !== 200) return undefined;
  try {
    return JSON.parse(r.raw)[field];
  } catch {
    return undefined;
  }
}
async function bfhExists(tref) {
  const r = await call(GOOD, "stuck-bfh-get", [tref]);
  return r.status === 200;
}
async function dedupGet(tref) {
  const r = await call(GOOD, "stuck-dedup-get", [tref]);
  return r.status === 200 ? r.raw : null;
}

// A contract-valid §7.2 worker structured ask (≥1 pick-option with a
// machine-applyable §5.3 block + recommendation{value,why}) so CF.6 authors a
// real worker_stuck dossier — the §7.2→§5 raw-material consumption. 1:1 with
// the bash test's ASK_JSON (cb_schema_version tracks the ONE bound source,
// §0.5 — equals the bash literal 2 after the §11 Mermaid amend bump,
// behaviour-identical).
const SV = schemaVersion("dossier");
const ASK = {
  tldr: "Worker hit a fork it must not resolve.",
  ask: "Adopt approach A or B?",
  options: [
    {
      option_id: "a",
      label: "Approach A",
      blast_radius: "low",
      consequence_block: {
        cb_schema_version: SV,
        creates: [],
        unblocks: [],
        labels: [],
        status_changes: [],
      },
    },
    {
      option_id: "b",
      label: "Approach B",
      blast_radius: "medium",
      consequence_block: {
        cb_schema_version: SV,
        creates: [],
        unblocks: [],
        labels: [],
        status_changes: [],
      },
    },
  ],
  recommendation: { value: "a", why: "A is reversible and lower blast radius." },
  reversible: "Nothing applied until a human picks (§5.3 = CF.6).",
};

it("CF.8 STUCK cross-tier routing is behaviour-identical to lib/stuck-routing.sh + test-stuck-routing.sh + bc-stuck-cross-tier.sh", async () => {
  // ── §9.1 — a no-bearer stuck-route is rejected BEFORE any write ───────────
  // The bash oracle's `do_dedup 401 / bfh 401 ⇒ NO write`. The CF chokepoint
  // (the Worker) rejects 401 BEFORE the DO is contacted — ZERO §4 / sibling
  // writes (structurally, not by convention; the other CF specs' precedent).
  const noAuth = await call(null, "stuck-route", ["unauth-fork", "worker_stuck", ASK]);
  eq("§9.1 no-bearer stuck-route ⇒ 401", noAuth.status, 401);
  ck(
    "§9.1 rejected request performed ZERO writes (no dossier, no bfh)",
    (await dossierCount()) === 0 && !(await bfhExists("unauth-fork"))
  );

  // ── EXIT 1 + EXIT 4 — one fork ⇒ ONE Dossier (worker-self-signal THEN
  //    backstop on the SAME fork) ─────────────────────────────────────────────
  const T = "stuck-fork-1";
  const r1 = await callJson("stuck-route", [T, "worker_stuck", ASK]);
  const DID1 = r1 && r1.dossier_id;
  ck("worker-self-signal routes (echoes a dossier id)", typeof DID1 === "string" && DID1.length > 0);
  eq("deterministic dossier id keyed task_ref (§0.4)", DID1, stuckDossierIdFor(T));
  const d1 = await getDossier(DID1);
  eq("Dossier generated for the first trigger (CF.6)", d1 && d1.trigger, "worker_stuck");
  eq("§7.2 ask → exactly ONE Item", d1 && d1.items && d1.items.length, 1);
  eq(
    "the Item is a pick-option (worker_stuck profile §5.2.1)",
    d1 && d1.items && d1.items[0] && d1.items[0].kind,
    "pick-option"
  );
  const N_AFTER_1 = await dossierCount();

  // SECOND, INDEPENDENT trigger on the SAME fork — the runner backstop.
  const r2 = await callJson("stuck-route", [T, "backstop:permission_denials", ASK]);
  const DID2 = r2 && r2.dossier_id;
  eq("backstop on the SAME fork ⇒ the SAME dossier id (§7.4 dossier dedup)", DID2, DID1);
  eq("two triggers never make two dossiers (count unchanged)", await dossierCount(), N_AFTER_1);
  eq("dedup record binds task_ref → the one dossier", await dedupGet(T), DID1);

  // ── EXIT 2 / §7.3 — a fired backstop ITSELF drives the bead (no worker help)
  const B = "stuck-backstop-only";
  const rB = await callJson("stuck-route", [B, "backstop:entered_plan_mode", ASK]);
  ck("backstop-only trigger routes", rB && typeof rB.dossier_id === "string" && rB.dossier_id.length > 0);
  eq("§7.3 backstop drove the bead to blocked", await beadStatus(B), "blocked");
  ck("§7.3 backstop raised bd human (fork ≠ rot)", (await humanHits(B)) >= 1);
  eq("worker-self-signal fork ALSO ends blocked", await beadStatus(T), "blocked");
  ck("worker-self-signal fork bd human preserved", (await humanHits(T)) >= 1);
  eq(
    "control-plane blocked-for-human record exists, unresolved (S-2 truth)",
    await bfhField(B, "resolved"),
    false
  );

  // ── EXIT 3 / S-2 — human approves ⇒ unblock via reconcile UNDER Dolt lag ──
  const H = "stuck-human-loop";
  const rH = await callJson("stuck-route", [H, "worker_stuck", ASK]);
  const DIDH = rH && rH.dossier_id;
  eq("raised: bead blocked-for-human", await beadStatus(H), "blocked");
  // Simulate Dolt lag / a stale propagation that CLOBBERS the work-plane
  // status back to open while the control plane still says blocked-for-human.
  await clobberBead(H, "open");
  const n1 = await callJson("stuck-reconcile", [H]);
  eq("reconcile acted on the unresolved record", n1 && n1.n, 1);
  eq(
    "Board never lies: reconcile RE-ASSERTS blocked under Dolt lag (S-2)",
    await beadStatus(H),
    "blocked"
  );
  // Human decides on the control plane (the source of truth).
  const hr = await callJson("stuck-resolve", [H, DIDH, `${DIDH}-d1`, { decision: "a" }]);
  ck("human resolves on the control plane", hr && hr.ok === true);
  eq("decision recorded (bfh now resolved)", await bfhField(H, "resolved"), true);
  // Re-clobber the work plane (Dolt lag again) BEFORE the lift reconcile — the
  // lift must be driven by the control-plane record, never by bead status.
  await clobberBead(H, "blocked");
  const n2 = await callJson("stuck-reconcile", [H]);
  eq("reconcile acted on the resolved record", n2 && n2.n, 1);
  eq(
    "human approved ⇒ bead UNBLOCKED via reconcile under Dolt lag (S-2)",
    await beadStatus(H),
    "open"
  );
  ck("resolved record hard-deleted (fork closed)", !(await bfhExists(H)));
  await callJson("stuck-reconcile", [H]);
  eq("reconcile is idempotent (re-run ⇒ no-op, stays open)", await beadStatus(H), "open");

  // ── EXIT 5 — §7.4 DOSSIER-level (task_ref) DISTINCT from per-Item latch ────
  ne(
    "a DIFFERENT task_ref ⇒ an INDEPENDENT dossier id",
    stuckDossierIdFor("other-fork"),
    DID1
  );
  const dH = await getDossier(DIDH);
  eq(
    "per-Item consequence_applied latch UNTOUCHED by stuck-* (CF.6 boundary)",
    dH && dH.items ? dH.items.filter((i) => i && i.consequence_applied === true).length : -1,
    0
  );
  eq(
    "item moved open→answered by the substrate, NOT applied (CF.6 surface)",
    dH && dH.items ? dH.items.filter((i) => i && i.state === "answered").length : -1,
    1
  );
  // The §7.4 STRUCTURE rejects binding the SAME task_ref to a DIFFERENT dossier
  // ("two triggers never make two dossiers"); proven against the primitive.
  const reb = await call(GOOD, "stuck-dedup-record", [T, "some-other-dossier-id"]);
  ck(
    "same task_ref → DIFFERENT id REJECTED by the dedup structure (§7.4)",
    reb.status >= 400 && reb.body && reb.body.ok === false
  );
  eq("binding still points at the original Dossier (no overwrite)", await dedupGet(T), DID1);
  // blocked-for-human is a SIBLING namespace, NOT a §4 record type (absent
  // from the schema.js §4 registry — the bash `co__schema_version` ⇒ "").
  eq(
    "blocked-for-human is NOT a §4 record type (no schema_version)",
    schemaVersion("blocked-for-human"),
    null
  );

  // ════════════════════════════════════════════════════════════════════════
  // STUCK-e2e GATE — the cross-tier OUTCOME bc-stuck-cross-tier.sh asserts
  // (§7.2 two independent triggers + §7.3 a fired backstop MUST itself drive
  // the bead). The §7.2 backstop FIRE recognition (sr_scan_backstop) turns the
  // zero-model-trust stream signal into the `backstop:<token>` trigger exactly
  // as the runner would; CF.8 owns the resulting cross-tier dossier OUTCOME
  // (NOT the §7.1 classifier string — T2/frozen, not asserted here).
  // ════════════════════════════════════════════════════════════════════════

  // §7.2 PRIMARY (worker-driven): bead STAYS blocked-for-human, never reopened.
  const XP = "xt-primary";
  await callJson("stuck-route", [XP, "worker_stuck", ASK]);
  eq("bc-stuck §7.2 primary: bead ENDS blocked (not reset to open)", await beadStatus(XP), "blocked");
  ck("bc-stuck §7.2 primary: bd human flag preserved", (await humanHits(XP)) >= 1);
  ck(
    "bc-stuck §7.2 primary: ONE Dossier for the fork",
    typeof (await getDossier(stuckDossierIdFor(XP))) === "object"
  );

  // §7.2 BACKSTOP A — result.permission_denials[AskUserQuestion] (zero trust).
  const PD_STREAM = [
    { type: "assistant", content: "…" },
    {
      type: "result",
      is_error: false,
      permission_denials: [{ tool: "AskUserQuestion", reason: "disallowed" }],
    },
  ];
  const scanA = await callJson("stuck-scan-backstop", [PD_STREAM]);
  ck("bc-stuck §7.2(b): permission_denials backstop FIRES", scanA && scanA.fired === true);
  eq("…with the permission_denials token", scanA && scanA.token, "permission_denials");
  const XA = "xt-pd";
  await callJson("stuck-route", [XA, `backstop:${scanA.token}`, ASK]);
  eq("bc-stuck §7.3: permission_denials backstop drove bead to blocked", await beadStatus(XA), "blocked");
  ck("bc-stuck §7.3: permission_denials backstop raised bd human", (await humanHits(XA)) >= 1);

  // §7.2 BACKSTOP B — "Entered plan mode." silent-no-op residual gap.
  const EPM_STREAM = [
    { type: "assistant", content: "ok" },
    { type: "tool_result", content: "Entered plan mode. Awaiting approval." },
    { type: "result", is_error: false },
  ];
  const scanB = await callJson("stuck-scan-backstop", [EPM_STREAM]);
  ck("bc-stuck §7.2(b): 'Entered plan mode.' backstop FIRES", scanB && scanB.fired === true);
  eq("…with the entered_plan_mode token", scanB && scanB.token, "entered_plan_mode");
  const XB = "xt-epm";
  await callJson("stuck-route", [XB, `backstop:${scanB.token}`, ASK]);
  eq("bc-stuck §7.3: 'Entered plan mode.' backstop drove bead to blocked", await beadStatus(XB), "blocked");
  ck("bc-stuck §7.3: 'Entered plan mode.' backstop raised bd human", (await humanHits(XB)) >= 1);

  // A benign stream (no denial, no residual) MUST NOT false-fire (the scan is
  // intentionally precise — bc-stuck-cross-tier's zero-false-positive intent).
  const OK_STREAM = [
    { type: "tool_result", content: "ran tests: 12 passed" },
    { type: "result", is_error: false },
  ];
  const scanOk = await callJson("stuck-scan-backstop", [OK_STREAM]);
  ck("backstop scan does NOT false-fire on a benign stream", scanOk && scanOk.fired === false);

  // ── stuck-restart (claude-tools-0wu) — wipe + re-run from scratch ──────────
  // Distinct from stuck-resolve: records NO decision; expires every still-open
  // dossier item (open→expired); flips bfh so the next reconcile lifts the bead.
  const R = "stuck-restart-bead";
  const rR = await callJson("stuck-route", [R, "worker_stuck", ASK]);
  const DIDR = rR && rR.dossier_id;
  ck("stuck-restart fixture: bfh raised + Dossier authored", typeof DIDR === "string" && DIDR.length > 0);
  const dR0 = await getDossier(DIDR);
  eq(
    "before restart: Item is open (the worker_stuck pick-option)",
    dR0 && dR0.items ? dR0.items.filter((i) => i && i.state === "open").length : -1,
    1
  );
  const rr1 = await callJson("stuck-restart", [R]);
  ck("stuck-restart returns ok", rr1 && rr1.ok === true);
  eq("stuck-restart echoes the number of items it expired", rr1 && rr1.expired, 1);
  const dR1 = await getDossier(DIDR);
  eq(
    "still-open Item moved to expired (Option A — no answered/applied)",
    dR1 && dR1.items ? dR1.items.filter((i) => i && i.state === "expired").length : -1,
    1
  );
  eq(
    "NO Item moved to answered (no decision recorded — distinct from stuck-resolve)",
    dR1 && dR1.items ? dR1.items.filter((i) => i && i.state === "answered").length : -1,
    0
  );
  eq("bfh now resolved (next reconcile will lift the bead)", await bfhField(R, "resolved"), true);
  // Idempotent re-run: already-expired item untouched, already-resolved bfh
  // flip is a no-op.
  const rr2 = await callJson("stuck-restart", [R]);
  ck("stuck-restart is idempotent (re-run ⇒ ok)", rr2 && rr2.ok === true);
  eq("expired Item count unchanged after idempotent re-run",
    (await getDossier(DIDR)).items.filter((i) => i && i.state === "expired").length, 1);
  // Reconcile lifts the bead + hard-deletes the bfh (the canonical S-2 leg).
  const n3 = await callJson("stuck-reconcile", [R]);
  eq("reconcile acted on the restart-flipped record", n3 && n3.n, 1);
  eq("stuck-restart + reconcile ⇒ bead UNBLOCKED for re-pick", await beadStatus(R), "open");
  ck("stuck-restart + reconcile ⇒ bfh record hard-deleted", !(await bfhExists(R)));
  // Unsafe / missing args ⇒ rejected; absent bfh ⇒ ok no-op.
  const rrUnsafe = await call(GOOD, "stuck-restart", ["../escape"]);
  ck("stuck-restart rejects unsafe task_ref", rrUnsafe.status >= 400);
  const rrMissing = await callJson("stuck-restart", ["never-stuck-fork"]);
  ck("stuck-restart on a never-stuck task_ref ⇒ ok no-op", rrMissing && rrMissing.ok === true);

  // eslint-disable-next-line no-console
  console.log(
    `\n══ CF.8 differential (vs lib/stuck-routing.sh + test-stuck-routing.sh + bc-stuck-cross-tier.sh): PASS=${PASS} FAIL=${FAIL} ══`
  );
  if (FAIL > 0) {
    // eslint-disable-next-line no-console
    console.log("FAILED:\n  - " + fails.join("\n  - "));
  }
  expect(FAIL, `differential clauses failed: ${fails.join("; ")}`).toBe(0);
});
