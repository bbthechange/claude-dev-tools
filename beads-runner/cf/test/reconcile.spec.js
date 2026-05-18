// CF.3 (claude-tools-7g0.3) — DIFFERENTIAL conformance test.
//
// Mirrors lib/test-coordinator-reconcile.sh (the §4.2 RunnerState reconcile +
// S-1 liveness + the §4.5 read-only work-snapshot projection) clause-for-clause
// AND the projection-PRODUCER half of lib/test-board.sh (the §4.5 shape the
// Board renderer drives — CF.10 owns the RENDER; this owns the PRODUCER).
// Every assertion exercises the REAL engine via SELF.fetch (Worker → §9.1
// chokepoint → singleton Coordinator DO → D1) on the SAME workerd+miniflare
// runtime `wrangler dev` uses, NO Cloudflare account. The CF engine MUST
// exhibit the SAME INTERFACE.md v1 §4.2/§4.5/§2.4 + §0.5 STALE_AFTER behaviour
// as coordinator.sh + those tests assert.
//
// Linear single flow with per-file isolated storage (the bash test's
// fresh-mktemp-store analogue). `env` is used ONLY to flip the §0.5
// STALE_AFTER / CO_EXPECTED_TOKEN knobs and to read the opaque stored record —
// EXACTLY mirroring the bash test's STALE_AFTER subshell override + its direct
// store reads. No non-contract debug surface is added to the engine.
//
// The unreadable-clock / explicit-now honest-degradation arms drop to the pure
// `deriveLiveness` import — EXACTLY as test-coordinator-reconcile.sh drops to
// the in-process `co__derive_liveness` predicate for those same two arms
// (they cannot be exercised through the op, which always samples its own
// clock). This is the faithful differential of that bash structure.
//
// CF.4-INDEPENDENCE NOTE: the capacity strip is RENDERED here (the §4.5
// contract slot) but the VERDICT is CF.4's coarse §6.3 aggregation. CF.4 is
// independent of CF.3 and not yet built; mirroring the bash `co__ask_capacity
// … || cap="unknown"`, an absent aggregation surface degrades to "unknown" —
// behaviour-identical to the bash oracle WHEN capacity is unavailable. The
// bash test's later capacity-flips-to-`over` arm exercises T4.4's
// co__ask_capacity, a CF.4 surface (report-capacity/ask-capacity) that is
// MUST-NOT-TOUCH here and does not exist in the CF engine yet — so that arm
// is CF.4's differential, not CF.3's. CF.3 asserts the strip slot is RENDERED
// with the §6.3/T4.4 source tag and the honest "unknown" default.

import { env, SELF } from "cloudflare:test";
import { it, expect } from "vitest";
import { deriveLiveness, staleAfterSeconds } from "../src/reconcile.js";

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
// `co_request GOOD <op> …` returning the parsed JSON payload (reconcile /
// work-snapshot answer 200/json; the bash test pipes stdout through jq).
async function callJson(op, args) {
  const r = await call(GOOD, op, args);
  return r.body;
}
// `co_request GOOD get <type> <id>` — the get op echoes the stored JSON, or
// 404 (absent). Mirrors the bash test's direct store reads.
async function getRecord(type, id) {
  const r = await call(GOOD, "get", [type, id]);
  if (r.status !== 200) return null;
  try {
    return JSON.parse(r.raw);
  } catch {
    return null;
  }
}
// An RFC-3339 UTC `…Z` timestamp <n> seconds in the past (§0.4 — the S-1
// datum is wire time). 1:1 with the bash test's `ago()`.
function ago(n) {
  return new Date(Date.now() - n * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
}
// A §1.1 heartbeat line in T3's VERBATIM coordinator-outbox envelope (the SAME
// shape la_report_capacity / la_report_terminal_reason emit). `principal` is a
// literal that the §9.1 chokepoint MUST overwrite. observed_at IS the
// last_heartbeat_at S-1 datum. 1:1 with the bash test's `hb_line`.
function hbLine(rid, prj, act, cur, at) {
  return JSON.stringify({
    report: "heartbeat",
    schema_version: 1,
    principal: "literal-should-be-overwritten",
    runner_id: rid,
    project_ref: prj,
    actual: act,
    current_task_ref: cur,
    observed_at: at,
  });
}
// The §4 `records` set fingerprint (the bash test's `sig()` — a sorted
// ls|shasum proving reads mutate ZERO records).
async function recordSig() {
  const { results } = await env.DB.prepare(
    "SELECT type, id FROM records ORDER BY type, id"
  ).all();
  return (results || []).map((r) => `${r.type}.${r.id}`).join("|");
}

it("CF.3 reconcile/liveness/work-snapshot is behaviour-identical to lib/coordinator.sh + test-coordinator-reconcile.sh + test-board.sh", async () => {
  // ── EXIT-1: reconcile across a SIMULATED SLEEP/RECONNECT (§2.4 semantics) ──
  // The runner is 'asleep' (no poll). The Coordinator owns desired-state and
  // sets desired=paused while it sleeps; a Lease was written (this tier only
  // SURFACES it — no arbitration, CF.2).
  await call(GOOD, "set-desired", ["projA", "paused", "ui:brian-laptop"]);
  await call(GOOD, "put", [
    "lease",
    "projA",
    JSON.stringify({ schema_version: 1, task_ref: "projA", owner: "hostA", generation: 4 }),
  ]);
  const rc1 = await callJson("reconcile", ["projA", "projA"]);
  ck("reconnect ⇒ desired delivered (paused, set while asleep)", rc1.desired === "paused");
  ck("reconnect ⇒ that runner's lease state surfaced", rc1.lease && rc1.lease.owner === "hostA");
  ck("reconcile stamps the §9.1 resolved principal", rc1.principal === "brian");
  ck("reconcile carries the project_ref", rc1.project_ref === "projA");
  // Reconciliation, NOT a durable command queue: a SECOND desired change while
  // still asleep is not queued — the next reconnect reflects the LATEST
  // desired, never a replayed command sequence.
  await call(GOOD, "set-desired", ["projA", "stopped", "ui:brian-laptop"]);
  const rc2 = await callJson("reconcile", ["projA", "projA"]);
  ck("next reconnect ⇒ the CURRENT desired (stopped), not a queue", rc2.desired === "stopped");
  const rc3 = await callJson("reconcile", ["projA"]);
  ck("reconcile w/o lease arg ⇒ desired still delivered", rc3.desired === "stopped");
  ck("reconcile w/o lease arg ⇒ lease is null (none surfaced)", rc3.lease === null);

  // ── EXIT-2: §4.2 liveness DERIVED at read time (S-1/C6); desired≠actual ────
  await call(GOOD, "heartbeat", [hbLine("hostA", "projA", "running", "ct-1", ago(30))]);
  const rL = await callJson("reconcile", ["projA", "projA"]);
  ck("heartbeat within STALE_AFTER ⇒ liveness = live", rL.liveness === "live");
  ck("actual surfaced from the heartbeat (running)", rL.actual === "running");
  // desired=stopped (Coordinator-owned, unchanged by the heartbeat) ≠
  // actual=running ⇒ the mismatch is surfaced HONESTLY, never masked.
  ck("desired≠actual surfaced honestly (mismatch flag true)", rL.desired_actual_mismatch === true);
  ck("actual NOT masked to desired (still 'running')", rL.actual === "running");
  ck("desired NOT masked to actual (still 'stopped')", rL.desired === "stopped");
  // A heartbeat OLDER than STALE_AFTER ⇒ derives 'stale' — honestly distinct
  // from actual:running (the Board renders 'stale (last seen…)', CF.10).
  await call(GOOD, "heartbeat", [hbLine("hostA", "projA", "running", "ct-1", ago(99999))]);
  const rS = await callJson("reconcile", ["projA", "projA"]);
  ck("heartbeat older than STALE_AFTER ⇒ liveness = stale", rS.liveness === "stale");
  ck("stale liveness does NOT mask actual (still 'running')", rS.actual === "running");
  // The STALE_AFTER boundary is the §0.5 constant (env-overridable; literal
  // default == frozen 180 s). A 30-s-old beat is stale under STALE_AFTER=10
  // and live under the default 180 — DERIVED AT READ TIME (the same stored
  // beat, two reads, two answers — exactly the C6 point).
  await call(GOOD, "heartbeat", [hbLine("hostA", "projA", "idle", "ct-1", ago(30))]);
  env.STALE_AFTER = "10";
  const rVfar = await callJson("reconcile", ["projA", "projA"]);
  ck("STALE_AFTER override moves the boundary (30s>10 ⇒ stale)", rVfar.liveness === "stale");
  delete env.STALE_AFTER;
  const rVnear = await callJson("reconcile", ["projA", "projA"]);
  ck("same beat with default 180s boundary ⇒ live", rVnear.liveness === "live");
  // DERIVED, never STORED (C6: a stored 'live' lies the instant the beat stops).
  const storedRS = await getRecord("runner_state", "projA");
  ck("stored RunnerState carries last_heartbeat_at (the S-1 datum)", !!storedRS.last_heartbeat_at);
  ck(
    "stored RunnerState has NO 'liveness' key (derived at READ)",
    !Object.prototype.hasOwnProperty.call(storedRS, "liveness")
  );
  // A never-heard-from runner is honestly STALE, not masked as live.
  await call(GOOD, "set-desired", ["projNoHB", "running", "ui:x"]);
  const rNo = await callJson("reconcile", ["projNoHB"]);
  ck("no heartbeat ever ⇒ liveness honestly 'stale'", rNo.liveness === "stale");
  // HONEST degradation (S-1/C6) via the pure derivation — the SAME two arms
  // the bash test drops to the in-process co__derive_liveness for.
  ck(
    "unreadable clock ⇒ liveness honestly 'stale' (no false live)",
    deriveLiveness(ago(5), NaN, 180) === "stale"
  );
  ck(
    "explicit now arg still honored when clock is dead",
    deriveLiveness("1970-01-01T00:00:30Z", 100000, 180) === "live"
  );
  ck(
    "missing last_heartbeat_at ⇒ honestly 'stale'",
    deriveLiveness("", Date.now(), 180) === "stale"
  );
  ck(
    "unparseable last_heartbeat_at ⇒ honestly 'stale'",
    deriveLiveness("not-a-timestamp", Date.now(), 180) === "stale"
  );
  ck("§0.5 STALE_AFTER default is the frozen 180 s", staleAfterSeconds({}) === 180);
  ck("§0.5 STALE_AFTER honours a present override", staleAfterSeconds({ STALE_AFTER: "10" }) === 10);

  // ── EXIT-3: §4.5 read-only projection reflects desired+actual+liveness ────
  const BEADS = JSON.stringify([
    {
      bead_ref: "claude-tools-99",
      title: "Impl X",
      stage: "impl",
      priority: 1,
      age: "2h",
      waiting_on: "review",
      failure: { class: "UNKNOWN_FAILURE", retry_state: "1/3", runner_notes: ["Runner: retrying"] },
    },
    { bead_ref: "claude-tools-12", title: "Idea Y", stage: "idea", priority: 2, age: "1d" },
    { bead_ref: "claude-tools-77", title: "Loose", stage: "weird", priority: 3, age: "5m" },
  ]);
  await call(GOOD, "put", [
    "dossier",
    "dOpen",
    JSON.stringify({
      schema_version: 2,
      // claude-tools-4xe — type=dossier writes run the §5.1-core WRITE GATE
      // (_writeRecord); a minimal conformant body round-trips and the §4.5
      // projection still reads only items[] (body stays T6b's). Bash twin:
      // test-coordinator-reconcile.sh same fixture.
      body: { dossier_schema_version: 2, diagrams: [] },
      id: "dOpen",
      bead_ref: "claude-tools-99",
      tier: "blocking",
      items: [
        { id: "i1", state: "open" },
        { id: "i2", state: "applied" },
      ],
    }),
  ]);
  await call(GOOD, "put", [
    "dossier",
    "dResolved",
    JSON.stringify({
      schema_version: 2,
      body: { dossier_schema_version: 2, diagrams: [] }, // claude-tools-4xe write gate
      id: "dResolved",
      bead_ref: "claude-tools-12",
      tier: "digest",
      items: [
        { id: "j1", state: "applied" },
        { id: "j2", state: "expired" },
      ],
    }),
  ]);
  const SNAP = await callJson("work-snapshot", ["projA", BEADS]);
  ck("projection declares itself read_only:true", SNAP.read_only === true);
  ck("projection schema_version is 1 (§4.5)", SNAP.schema_version === 1);
  const P0 = SNAP.projects[0].runner_state;
  ck("projection RunnerState reflects desired", P0.desired === "stopped");
  ck("projection RunnerState reflects actual", P0.actual === "idle");
  ck("projection RunnerState reflects liveness DERIVED", P0.liveness === "live");
  ck("projection surfaces desired≠actual honestly", P0.desired_actual_mismatch === true);
  ck(
    "projection lifecycle column keyed by stage: (impl)",
    SNAP.lifecycle_columns.impl[0].bead_ref === "claude-tools-99"
  );
  ck(
    "projection lifecycle column keyed by stage: (idea)",
    SNAP.lifecycle_columns.idea[0].bead_ref === "claude-tools-12"
  );
  ck(
    'an unknown stage buckets under "" (honest, not silently impl)',
    SNAP.lifecycle_columns[""][0].bead_ref === "claude-tools-77"
  );
  ck(
    "per-bead failure metadata carried (Flow G tiers 1–2)",
    SNAP.lifecycle_columns.impl[0].failure.class === "UNKNOWN_FAILURE"
  );
  ck(
    "card carries the one thing it waits on (§4.5)",
    SNAP.lifecycle_columns.impl[0].waiting_on === "review"
  );
  // WAITING-ON-YOU = Dossiers (this principal) with ≥1 still-open item —
  // COUNTS only; a fully-resolved (all applied/expired) dossier drops off.
  ck("WAITING-ON-YOU lists the dossier with an open item", SNAP.waiting_on_you[0].dossier_ref === "dOpen");
  ck(
    "WAITING-ON-YOU open_item_count is the COUNT (1, applied excluded)",
    SNAP.waiting_on_you[0].open_item_count === 1
  );
  ck("fully-resolved dossier is NOT in WAITING-ON-YOU", SNAP.waiting_on_you.length === 1);
  ck("WAITING-ON-YOU carries the bead_ref it waits on", SNAP.waiting_on_you[0].bead_ref === "claude-tools-99");
  // AD7 — a PARTLY-ANSWERED dossier (an answered-but-not-applied item) STILL
  // shows until its last item resolves (answered is non-terminal).
  await call(GOOD, "put", [
    "dossier",
    "dPartly",
    JSON.stringify({
      schema_version: 2,
      body: { dossier_schema_version: 2, diagrams: [] }, // claude-tools-4xe write gate
      id: "dPartly",
      bead_ref: "claude-tools-55",
      tier: "blocking",
      items: [
        { id: "p1", state: "answered" },
        { id: "p2", state: "applied" },
      ],
    }),
  ]);
  const SNAPp = await callJson("work-snapshot", ["projA", BEADS]);
  const partly = SNAPp.waiting_on_you.find((w) => w.dossier_ref === "dPartly");
  ck("AD7 — a partly-answered dossier STILL shows in WAITING-ON-YOU", !!partly);
  ck("AD7 — its answered-not-applied item counts as still-open (1)", partly && partly.open_item_count === 1);
  // The capacity strip is RENDERED here (the §4.5 slot); the VERDICT is CF.4's
  // §6.3 aggregation — absent ⇒ the honest "unknown" default (behaviour-
  // identical to the bash oracle WHEN co__ask_capacity is unavailable).
  ck("capacity strip RENDERED (verdict slot present, non-empty)", !!SNAP.projects[0].capacity_strip.verdict);
  ck(
    "capacity strip names its source as the §6.3/T4.4 aggregation (surfaced, not measured)",
    SNAP.projects[0].capacity_strip.source.includes("T4.4")
  );
  ck(
    "capacity verdict honestly 'unknown' (CF.4 §6.3 aggregation not present — CF.3 measures none)",
    SNAP.projects[0].capacity_strip.verdict === "unknown"
  );

  // ── EXIT-3: NO write path from any reader (read-only invariant) ───────────
  const before = await recordSig();
  await call(GOOD, "work-snapshot", ["projA", BEADS]);
  await call(GOOD, "work-snapshot", ["", BEADS]); // all-projects mode
  await call(GOOD, "work-snapshot", ["projA", '{"evil":1}']); // adversarial non-array
  await call(GOOD, "work-snapshot", ["projA", "not even json"]);
  await call(GOOD, "reconcile", ["projA"]);
  const after = await recordSig();
  ck("work-snapshot/reconcile reads mutate ZERO records", before === after && before.length > 0);
  const selfMade = await getRecord("work_snapshot", "projA");
  ck("no work_snapshot record self-created by the reader", selfMade === null);
  // All-projects mode still produces an honest projection (the Coordinator-side
  // is produced even with no project arg; here ≥2 runner_state records exist).
  const SNAPall = await callJson("work-snapshot", ["", BEADS]);
  ck("all-projects mode surfaces every stored RunnerState", SNAPall.projects.length >= 2);
  ck("all-projects mode is still read_only:true", SNAPall.read_only === true);

  // ── anti-drift: §1.1 heartbeat consumed VERBATIM; §0.3/§9.1/§4.2 enforced ──
  // A fresh project_ref (no prior envelope) — the bash test's fresh-store arm
  // proving verbatim ingest with NO shape adaptation.
  await call(GOOD, "heartbeat", [
    hbLine("hostZ", "projZ", "running", "ctZ", new Date().toISOString().replace(/\.\d{3}Z$/, "Z")),
  ]);
  const storedZ = await getRecord("runner_state", "projZ");
  ck("verbatim §1.1 line ingests with NO shape adaptation", storedZ.actual === "running");
  ck("observed_at consumed VERBATIM as last_heartbeat_at", !!storedZ.last_heartbeat_at);
  ck("current_task_ref consumed verbatim from the §1.1 line", storedZ.current_task_ref === "ctZ");
  ck("§9.1 — the report's principal literal is OVERWRITTEN", storedZ.principal === "brian");
  // §1.1 field extraction is the bash `jq -r '.X // ""'` VERBATIM: a NUMBER
  // project_ref / current_task_ref stringifies and ingests IDENTICALLY to the
  // oracle (stored under the stringified key / value), never rejected by a
  // stricter JS typeof gate (the clean-context oracle-divergence fix, pinned).
  await call(GOOD, "heartbeat", [
    JSON.stringify({
      report: "heartbeat",
      schema_version: 1,
      project_ref: 123,
      actual: "running",
      current_task_ref: 77,
      observed_at: ago(5),
    }),
  ]);
  const numProj = await getRecord("runner_state", "123");
  ck("numeric project_ref stringifies & ingests like bash jq -r (stored as '123')", numProj !== null);
  ck("numeric project_ref record carries actual verbatim", numProj && numProj.actual === "running");
  ck(
    "numeric current_task_ref stringifies like bash jq -r (stored as '77')",
    numProj && numProj.current_task_ref === "77"
  );
  // §1.1: the runner never originates desired — a heartbeat MUST NOT clobber
  // the COORDINATOR-OWNED desired/last_desired_actor.
  await call(GOOD, "set-desired", ["projKeep", "paused", "ui:owner"]);
  await call(GOOD, "heartbeat", [hbLine("hostK", "projKeep", "crashed", "ctK", ago(5))]);
  const keep = await getRecord("runner_state", "projKeep");
  ck("heartbeat PRESERVES Coordinator-owned desired (paused)", keep.desired === "paused");
  ck("heartbeat PRESERVES last_desired_actor (ui:owner)", keep.last_desired_actor === "ui:owner");
  ck("heartbeat still records the runner-reported actual", keep.actual === "crashed");
  // §0.3 reject-unknown-higher / §4.2 closed enum / store-owner input hygiene.
  const rejSv2 = await call(GOOD, "heartbeat", [
    '{"report":"heartbeat","schema_version":2,"project_ref":"p","actual":"running"}',
  ]);
  ck("heartbeat schema_version 2 ⇒ rejected (§0.3, never best-effort)", rejSv2.status >= 400);
  const rejSvStr = await call(GOOD, "heartbeat", [
    '{"report":"heartbeat","schema_version":"1","project_ref":"p","actual":"running"}',
  ]);
  ck('heartbeat string schema_version "1" ⇒ rejected (§1.1 int)', rejSvStr.status >= 400);
  const rejReport = await call(GOOD, "heartbeat", [
    '{"report":"capacity","schema_version":1,"project_ref":"p","actual":"running"}',
  ]);
  ck('report!="heartbeat" ⇒ rejected (not a §1.1 heartbeat)', rejReport.status >= 400);
  const rejEnum = await call(GOOD, "heartbeat", [
    '{"report":"heartbeat","schema_version":1,"project_ref":"p","actual":"zooming"}',
  ]);
  ck("out-of-enum actual ⇒ rejected (§4.2 closed enum)", rejEnum.status >= 400);
  const rejUnsafe = await call(GOOD, "heartbeat", [
    '{"report":"heartbeat","schema_version":1,"project_ref":"../../etc","actual":"idle"}',
  ]);
  ck("unsafe project_ref ('..') ⇒ rejected at the door", rejUnsafe.status >= 400);
  // None of those rejections persisted a record.
  ck("rejected heartbeat 'p' wrote NOTHING (rejected before any write)", (await getRecord("runner_state", "p")) === null);
  // §9.1 — no/invalid token ⇒ rejected at the ONE chokepoint BEFORE any write.
  const noTokHb = await call(null, "heartbeat", [hbLine("hostN", "projN", "running", "ctN", ago(5))]);
  ck("no-token heartbeat ⇒ rejected (authed channel only)", noTokHb.status === 401);
  ck("no-token heartbeat wrote NOTHING", (await getRecord("runner_state", "projN")) === null);
  const noTokRec = await call(null, "reconcile", ["projA"]);
  ck("no-token reconcile ⇒ rejected", noTokRec.status === 401);
  const noTokWs = await call(null, "work-snapshot", ["projA", BEADS]);
  ck("no-token work-snapshot ⇒ rejected", noTokWs.status === 401);
  env.CO_EXPECTED_TOKEN = "expected";
  const badTokHb = await call("wrong", "heartbeat", [hbLine("h", "pX", "running", "c", ago(5))]);
  ck("invalid-token heartbeat ⇒ rejected", badTokHb.status === 401);
  delete env.CO_EXPECTED_TOKEN;
  ck("invalid-token heartbeat wrote NOTHING", (await getRecord("runner_state", "pX")) === null);

  // ── anti-drift: CF.1 boundary intact (opPoll liveness-free; caps == 4) ────
  // opPoll stays the pure §2.4 TRANSPORT its own CF.1 differential asserts —
  // reconcile is a SEPARATE semantics layer (the boundary CF.3 must hold).
  const pollOut = await callJson("poll", ["projA", "projA"]);
  ck(
    "opPoll (CF.1) still carries NO 'liveness' (boundary intact)",
    !Object.prototype.hasOwnProperty.call(pollOut, "liveness")
  );
  ck(
    "opPoll (CF.1) carries NO desired_actual_mismatch (boundary)",
    !Object.prototype.hasOwnProperty.call(pollOut, "desired_actual_mismatch")
  );
  ck(
    "reconcile (CF.3) DOES derive liveness (the semantics layer)",
    Object.prototype.hasOwnProperty.call(rL, "liveness")
  );
  const capsRes = await SELF.fetch(
    new Request("https://coordinator.local/", {
      method: "GET",
      headers: { authorization: `Bearer ${GOOD}` },
    })
  );
  const caps = await capsRes.text();
  ck("CAPABILITIES (CF.1) still EXACTLY four §2 lines (untouched)", (caps.match(/§2/g) || []).length === 4);
  ck("CAPABILITIES does NOT advertise work-snapshot as a §2 capability", !caps.includes("work-snapshot"));
  // 'work_snapshot' IS a §4 record type (CF.1 registry) for the publisher's
  // STORED envelope — the READ-side producer is a different path that never
  // persists. Proven behaviorally: a v1 envelope stores; a v2 is §0.3-rejected
  // as a known type's unknown-higher version (membership + bound, no op needed).
  const wsV1 = await call(GOOD, "put", [
    "work_snapshot",
    "wsX",
    JSON.stringify({ schema_version: 1, projects: [] }),
  ]);
  ck("'work_snapshot' is a §4 record type — a v1 envelope stores", wsV1.status === 200);
  const wsV2 = await call(GOOD, "put", [
    "work_snapshot",
    "wsX",
    JSON.stringify({ schema_version: 2, projects: [] }),
  ]);
  ck(
    "'work_snapshot' v2 ⇒ §0.3 reject as a KNOWN type's unknown-higher version",
    wsV2.status >= 400 && /higher/i.test((wsV2.body && wsV2.body.error) || "")
  );
  // The §10 forensic stream is NEVER in the §4.5 projection (CF.5 is built;
  // the producer reads ONLY the §4 records table — forensic's SEPARATE
  // transient namespace is structurally never joined here).
  const MARK = "FORENSIC-CANARY-7c1f";
  await call(GOOD, "forensic-put", ["fc1", "claude-tools-99", JSON.stringify({ last_assistant: MARK })]);
  const SNAP2 = await call(GOOD, "work-snapshot", ["projA", BEADS]);
  ck("the §10 forensic stream is NEVER in the §4.5 projection", !SNAP2.raw.includes(MARK));

  // eslint-disable-next-line no-console
  console.log(
    `\n══ CF.3 differential (vs lib/coordinator.sh co__reconcile/co__work_snapshot/co__heartbeat/co__derive_liveness + test-coordinator-reconcile.sh + test-board.sh): PASS=${PASS} FAIL=${FAIL} ══`
  );
  if (FAIL > 0) {
    // eslint-disable-next-line no-console
    console.log("FAILED:\n  - " + fails.join("\n  - "));
  }
  expect(FAIL, `differential clauses failed: ${fails.join("; ")}`).toBe(0);
});
