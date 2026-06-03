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
import { deriveLiveness, staleAfterSeconds, usagePollTtlSeconds } from "../src/reconcile.js";
import machineFixture from "../../test-fixtures/machine-state-v1.json";

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
    // GAP G2 (claude-tools-uxg2) — two `done` beads exercise the done·verified
    // vs done·code split: d1's probe passed (verified:true → done·verified);
    // d2 has no probe fact (absent → done·code, un-probed is NOT verified).
    { bead_ref: "claude-tools-d1", title: "Shipped", stage: "done", priority: 1, age: "3h", verified: true },
    { bead_ref: "claude-tools-d2", title: "Landed", stage: "done", priority: 2, age: "4h" },
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
  // GAP G2 (claude-tools-uxg2) — the per-card `verified` flag (§3 / principle
  // 11). STRICT boolean on EVERY card: literal true ⇒ done·verified, anything
  // else ⇒ done·code (un-probed is NOT "shipped & verified").
  ck(
    "GAP G2 — a done card whose probe passed carries verified:true (done·verified)",
    SNAP.lifecycle_columns.done[0].verified === true
  );
  ck(
    "GAP G2 — a done card with no probe fact carries verified:false (done·code)",
    SNAP.lifecycle_columns.done[1].verified === false
  );
  ck(
    "GAP G2 — verified is a per-card boolean on EVERY card (impl defaults false)",
    SNAP.lifecycle_columns.impl[0].verified === false
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

  // ── L3 (claude-tools-uxvl3) — the intake-state lane (inbox-lifecycle §9.5 #4) ─
  // Seed one intake-request per thread state so the projection's received→
  // enriching→created / failing(n) / gave-up mapping is pinned. The daemon
  // (intake-dispatch-poll.sh) writes the dispatch_state markers in production;
  // here we put the records directly to assert the read-side derivation.
  await call(GOOD, "put", ["intake-request", "intake-recv", JSON.stringify({
    schema_version: 1, id: "intake-recv", idea_text: "  brand new   idea\n", project_ref: "projA",
    preset: "autonomous-until-stuck", processed: false, submitted_at: "2026-05-31T07:00:00Z",
  })]);
  await call(GOOD, "put", ["intake-request", "intake-enr", JSON.stringify({
    schema_version: 1, id: "intake-enr", idea_text: "being worked", project_ref: "projA",
    preset: "autonomous-until-stuck", processed: false, dispatch_attempts: 1,
    dispatch_state: "enriching", last_attempt_at: "2026-05-31T07:05:00Z", submitted_at: "2026-05-31T07:01:00Z",
  })]);
  await call(GOOD, "put", ["intake-request", "intake-ok", JSON.stringify({
    schema_version: 1, id: "intake-ok", idea_text: "done", project_ref: "projA",
    preset: "autonomous-until-stuck", processed: true, dispatch_attempts: 1, dispatch_state: "created",
    enricher_bd_id: "projA-77", enricher_outcome: "created", submitted_at: "2026-05-31T07:02:00Z",
  })]);
  await call(GOOD, "put", ["intake-request", "intake-fail", JSON.stringify({
    schema_version: 1, id: "intake-fail", idea_text: "flaky", project_ref: "projA",
    preset: "autonomous-until-stuck", processed: false, dispatch_attempts: 2, dispatch_state: "failing",
    last_error: "specialist exit=7", submitted_at: "2026-05-31T07:03:00Z",
  })]);
  await call(GOOD, "put", ["intake-request", "intake-dead", JSON.stringify({
    schema_version: 1, id: "intake-dead", idea_text: "abandoned", project_ref: "projB",
    preset: "autonomous-until-stuck", processed: false, dispatch_attempts: 3, dispatch_state: "gave_up",
    gave_up: true, gave_up_at: "2026-05-31T07:10:00Z", last_error: "specialist exit=7",
    submitted_at: "2026-05-31T07:04:00Z",
  })]);
  const SNAPi = await callJson("work-snapshot", ["", BEADS]);
  ck("L3 — intake[] is a top-level array (peer to machines[]/waiting_on_you[])", Array.isArray(SNAPi.intake));
  ck("L3 — every seeded intake-request is surfaced", SNAPi.intake.length === 5);
  const byId = Object.fromEntries(SNAPi.intake.map((x) => [x.intake_id, x]));
  ck("L3 — `received` state (no attempt yet)", byId["intake-recv"].state === "received");
  ck("L3 — `enriching` in-flight marker surfaces", byId["intake-enr"].state === "enriching");
  ck("L3 — `created` terminal-success surfaces with bd_ref", byId["intake-ok"].state === "created" && byId["intake-ok"].bd_ref === "projA-77");
  ck("L3 — `failing` with the retry count (the 19-silent-retry leak)", byId["intake-fail"].state === "failing" && byId["intake-fail"].attempts === 2);
  ck("L3 — `failing` carries last_error", byId["intake-fail"].last_error === "specialist exit=7");
  ck("L3 — `gave-up` terminal-failure surfaces (gave_up flag wins)", byId["intake-dead"].state === "gave-up");
  ck("L3 — gave-up carries attempts + gave_up_at", byId["intake-dead"].attempts === 3 && byId["intake-dead"].gave_up_at === "2026-05-31T07:10:00Z");
  ck("L3 — idea_excerpt is whitespace-collapsed (submitter's own text)", byId["intake-recv"].idea_excerpt === "brand new idea");
  ck("L3 — intake card carries project_ref for the hub's per-workspace slice", byId["intake-dead"].project_ref === "projB");
  // Per-project `capacity_strip` is DROPPED by C3 per MACHINE-STATE.md §3.B.
  // §4.5's strip-fields wording is now satisfied by the top-level `machines[]`
  // carrying them (asserted in the dedicated §3.A block below). A future
  // refactor that re-adds capacity_strip should re-open D2 first.
  ck(
    "projects[].capacity_strip is DROPPED (MACHINE-STATE.md §3.B)",
    !Object.prototype.hasOwnProperty.call(SNAP.projects[0], "capacity_strip")
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

// ════════════════════════════════════════════════════════════════════════════
// C3 (claude-tools-zdxd.4) — §3.A top-level machines[] + freshness derivation.
// Bound to FROZEN MACHINE-STATE.md v1 (D2) + test-fixtures/machine-state-v1.json
// as the single source of truth (the §A drift-blocker).
// ════════════════════════════════════════════════════════════════════════════
it("CF.3 §3.A workSnapshot machines[] projection — D2-faithful (claude-tools-zdxd.4)", async () => {
  let p3PASS = 0;
  let p3FAIL = 0;
  const p3fails = [];
  function p3ck(name, cond) {
    if (cond) {
      p3PASS++;
      // eslint-disable-next-line no-console
      console.log(`  ✓ ${name}`);
    } else {
      p3FAIL++;
      p3fails.push(name);
      // eslint-disable-next-line no-console
      console.log(`  ✗ ${name}`);
    }
  }

  // Reset the D2 namespace so the empty-state / multi-machine arms start clean.
  async function freshMachines() {
    try {
      await env.DB.prepare("DELETE FROM machine_state_reports").run();
    } catch {
      /* lazy table absent ⇒ already empty */
    }
  }

  // Build a §1.1 line by overlaying changes on the canonical fixture (same
  // pattern as machine-state.spec.js). The "_comment_DO_NOT_REMOVE" sentinel
  // is a docstring on the fixture; strip it so the round-trip assertion sees
  // only contract fields.
  function payload() {
    const o = { ...machineFixture };
    delete o._comment_DO_NOT_REMOVE;
    return o;
  }
  function line(overrides) {
    return JSON.stringify({ ...payload(), ...overrides });
  }
  async function report(l) {
    return call(GOOD, "report-machine-state", [l]);
  }

  // The required §3.A field set. A future refactor that drops any of these
  // fails the conformance assertion below — the drift-blocker the bead asks
  // for. §1.1 required + §1.2 optional (present in the fixture) + the
  // projection-derived `fresh`/`age_seconds`.
  const REQUIRED_MACHINE_FIELDS = [
    "runner_id",
    "observed_at",
    "pct_5h",
    "pct_7d",
    "spare_ramp_today",
    "threshold_in_effect",
    "gate_disabled",
    "keychain_ok",
    "usage_api_ok",
    "fresh",
    "age_seconds",
  ];

  // ── EMPTY-STATE (§3.C): machines: [] is honest; NOT absent, NOT null ─────
  await freshMachines();
  const SNAPe = await callJson("work-snapshot", ["", ""]);
  p3ck(
    "§3.C empty-state — `machines` is PRESENT on the snapshot (never absent)",
    Object.prototype.hasOwnProperty.call(SNAPe, "machines")
  );
  p3ck(
    "§3.C empty-state — `machines` is an empty array (never null, never stub)",
    Array.isArray(SNAPe.machines) && SNAPe.machines.length === 0
  );
  p3ck(
    "§3.A — machines[] is TOP-LEVEL (peer to projects/waiting_on_you, not nested)",
    Object.prototype.hasOwnProperty.call(SNAPe, "machines") &&
      Object.prototype.hasOwnProperty.call(SNAPe, "projects") &&
      Object.prototype.hasOwnProperty.call(SNAPe, "waiting_on_you")
  );

  // ── FIXTURE ROUNDTRIP: insert the canonical fixture; assert it surfaces ──
  await freshMachines();
  const fix = payload();
  const ing = await report(JSON.stringify(fix));
  p3ck("canonical fixture ingests (200)", ing.status === 200);
  // Override the daemon-cadence TTL so the test is hermetic against wall-clock
  // age vs the fixture's 2026-05-24 observed_at. The §3.A derivation is
  // `fresh = age_seconds ≤ 2 × TTL`; setting TTL high (1e9) ⇒ fresh=true for
  // any past observed_at, isolating the fixture-roundtrip assertion from the
  // stale-derivation assertion below.
  env.USAGE_POLL_TTL_SECONDS = "1000000000";
  const SNAPf = await callJson("work-snapshot", ["", ""]);
  delete env.USAGE_POLL_TTL_SECONDS;
  p3ck("fixture roundtrip — machines[] has one entry", Array.isArray(SNAPf.machines) && SNAPf.machines.length === 1);
  const m0 = (SNAPf.machines && SNAPf.machines[0]) || {};
  p3ck("fixture roundtrip — runner_id preserved", m0.runner_id === fix.runner_id);
  p3ck("fixture roundtrip — observed_at preserved", m0.observed_at === fix.observed_at);
  p3ck("fixture roundtrip — pct_5h preserved (float OK)", m0.pct_5h === fix.pct_5h);
  p3ck("fixture roundtrip — pct_7d preserved", m0.pct_7d === fix.pct_7d);
  p3ck("fixture roundtrip — spare_ramp_today preserved", m0.spare_ramp_today === fix.spare_ramp_today);
  p3ck("fixture roundtrip — threshold_in_effect preserved", m0.threshold_in_effect === fix.threshold_in_effect);
  p3ck("fixture roundtrip — gate_disabled (§1.2) preserved", m0.gate_disabled === fix.gate_disabled);
  p3ck("fixture roundtrip — keychain_ok (§1.2) preserved", m0.keychain_ok === fix.keychain_ok);
  p3ck("fixture roundtrip — usage_api_ok (§1.2) preserved", m0.usage_api_ok === fix.usage_api_ok);
  p3ck("fixture roundtrip — fresh=true under wide TTL", m0.fresh === true);
  p3ck("fixture roundtrip — age_seconds is a non-negative integer", typeof m0.age_seconds === "number" && m0.age_seconds >= 0 && Math.floor(m0.age_seconds) === m0.age_seconds);
  // §9.1 — the resolved principal was stamped at ingest (the fixture literal
  // "PRINCIPAL_V1" should NOT survive); the projection carries the stamped
  // record verbatim.
  p3ck("fixture roundtrip — §9.1 stamped principal carried through", m0.principal === "brian");

  // ── STALE-DERIVATION: observed_at = now - 3 × TTL ⇒ fresh=false, age>0 ───
  await freshMachines();
  const TTL = usagePollTtlSeconds({}); // 300 — the bare default with no env override
  const staleObsMs = Date.now() - 3 * TTL * 1000;
  const staleObs = new Date(staleObsMs).toISOString().replace(/\.\d{3}Z$/, "Z");
  await report(line({ runner_id: "stalebox", observed_at: staleObs }));
  const SNAPs = await callJson("work-snapshot", ["", ""]);
  const ms = (SNAPs.machines || []).find((m) => m.runner_id === "stalebox");
  p3ck("stale-derivation — record surfaces in machines[]", !!ms);
  p3ck("stale-derivation — fresh=false (observed_at > 2×TTL ago)", ms && ms.fresh === false);
  p3ck("stale-derivation — age_seconds present and ≥ 2×TTL", ms && typeof ms.age_seconds === "number" && ms.age_seconds >= 2 * TTL);

  // ── MULTI-MACHINE: two runner_ids ⇒ both surface, ordered by runner_id ───
  await freshMachines();
  await report(line({ runner_id: "zeta-host", observed_at: new Date().toISOString().replace(/\.\d{3}Z$/, "Z") }));
  await report(line({ runner_id: "alpha-host", observed_at: new Date().toISOString().replace(/\.\d{3}Z$/, "Z") }));
  const SNAPm = await callJson("work-snapshot", ["", ""]);
  p3ck("multi-machine — both records surface", Array.isArray(SNAPm.machines) && SNAPm.machines.length === 2);
  p3ck(
    "multi-machine — ordered by runner_id (alpha before zeta, deterministic for UI)",
    SNAPm.machines &&
      SNAPm.machines[0] &&
      SNAPm.machines[1] &&
      SNAPm.machines[0].runner_id === "alpha-host" &&
      SNAPm.machines[1].runner_id === "zeta-host"
  );

  // ── CONFORMANCE: every required §3.A field is present on a machines[] entry
  // — a future refactor that drops any required field fails this test (the
  // grep-equivalent the bead asks for).
  for (const k of REQUIRED_MACHINE_FIELDS) {
    p3ck(
      `§3.A field-set — machines[0] carries '${k}'`,
      SNAPm.machines && SNAPm.machines[0] && Object.prototype.hasOwnProperty.call(SNAPm.machines[0], k)
    );
  }

  // ── READ-ONLY invariant holds for the new read path too (§4.5) ───────────
  const before = await env.DB.prepare(
    "SELECT type, id FROM records ORDER BY type, id"
  ).all();
  const sigBefore = ((before && before.results) || []).map((r) => `${r.type}.${r.id}`).join("|");
  const beforeM = await env.DB.prepare("SELECT COUNT(*) AS n FROM machine_state_reports").first();
  await callJson("work-snapshot", ["", ""]);
  await callJson("work-snapshot", ["", ""]);
  const after = await env.DB.prepare(
    "SELECT type, id FROM records ORDER BY type, id"
  ).all();
  const sigAfter = ((after && after.results) || []).map((r) => `${r.type}.${r.id}`).join("|");
  const afterM = await env.DB.prepare("SELECT COUNT(*) AS n FROM machine_state_reports").first();
  p3ck("read-only — workSnapshot does NOT mutate the §4 records table", sigBefore === sigAfter);
  p3ck(
    "read-only — workSnapshot does NOT mutate the D2 namespace either",
    (beforeM && beforeM.n) === (afterM && afterM.n)
  );

  // eslint-disable-next-line no-console
  console.log(
    `\n══ CF.3 §3.A machines[] (vs MACHINE-STATE.md v1 + test-fixtures/machine-state-v1.json): PASS=${p3PASS} FAIL=${p3FAIL} ══`
  );
  if (p3FAIL > 0) {
    // eslint-disable-next-line no-console
    console.log("FAILED:\n  - " + p3fails.join("\n  - "));
  }
  expect(p3FAIL, `§3.A machines[] clauses failed: ${p3fails.join("; ")}`).toBe(0);
});

// ════════════════════════════════════════════════════════════════════════════
// I2 (claude-tools-uxvi2) — activity{} + runner_health{} per-project sub-objects
// (DESIGN I §2 lanes + §3 runner-vs-agent; Contract B.1). activity reads the I1
// agent_activity transient and projects each lane DOWN to its EXACT B.1 shape;
// runner_health is derived from runner_state (the loop process, blunt). Bound to
// design/activity.md §2/§3 + UX-V2-ARCHITECTURE.md B.1.
// ════════════════════════════════════════════════════════════════════════════
it("CF.3 I2 workSnapshot activity{} + runner_health{} — DESIGN I §2/§3 + B.1 (claude-tools-uxvi2)", async () => {
  let i2PASS = 0;
  let i2FAIL = 0;
  const i2fails = [];
  function i2ck(name, cond) {
    if (cond) {
      i2PASS++;
      // eslint-disable-next-line no-console
      console.log(`  ✓ ${name}`);
    } else {
      i2FAIL++;
      i2fails.push(name);
      // eslint-disable-next-line no-console
      console.log(`  ✗ ${name}`);
    }
  }

  async function freshActivity() {
    try {
      await env.DB.prepare("DELETE FROM agent_activity").run();
    } catch {
      /* lazy table absent ⇒ already empty */
    }
  }
  // A valid §1.4 agent_activity line (overlay pattern). `state` stays in the
  // closed D.2 enum (the I1 ingest gate rejects anything else, both lanes).
  function actLine(overrides) {
    return JSON.stringify({
      report: "agent_activity",
      schema_version: 1,
      principal: "literal-should-be-overwritten",
      agent_key: "writer:hostX",
      workspace: "projWork",
      lane: "writer",
      kind: "impl",
      bead_ref: "projWork-1",
      title: "wire the input handler",
      stage: "impl",
      state: "writing-code",
      state_confidence: "derived",
      liveness_dot: "green",
      observed_at: ago(2),
      last_event_ts: ago(2),
      seconds_in_state: 12,
      current_tool: "Edit",
      touching: ["Gameplay", "Input"],
      ...overrides,
    });
  }
  const actReport = (l) => call(GOOD, "agent-activity-report", [l]);
  const projOf = (snap, ref) => (snap.projects || []).find((p) => p.project_ref === ref) || {};

  // ── runner_health: derive the 4 states from runner_state (the loop process) ──
  // Each runner_state is seeded via a heartbeat with a controlled actual + a
  // fresh/stale observed_at (liveness is DERIVED from STALE_AFTER at read time).
  await freshActivity();
  await call(GOOD, "heartbeat", [hbLine("hostW", "projWork", "running", "projWork-1", ago(5))]); // fresh + in task ⇒ working
  await call(GOOD, "heartbeat", [hbLine("hostI", "projIdle", "idle", "", ago(5))]); // fresh + no task ⇒ idle
  await call(GOOD, "heartbeat", [hbLine("hostS", "projStarve", "idle", "", ago(5))]); // fresh idle = the starved-but-alive shape ⇒ idle (NEVER stuck)
  await call(GOOD, "heartbeat", [hbLine("hostC", "projCool", "idle", "", ago(5))]); // capacity-deny/cooldown heartbeats idle ⇒ idle (findings 180-182)
  await call(GOOD, "heartbeat", [hbLine("hostG", "projWedged", "running", "projWedged-9", ago(99999))]); // stale + not-down ⇒ wedged
  await call(GOOD, "heartbeat", [hbLine("hostD", "projDead", "stopped", "", ago(5))]); // explicitly stopped ⇒ process dead, state idle (never "stuck")

  const SNAP = await callJson("work-snapshot", ["", ""]);
  const RH = (ref) => projOf(SNAP, ref).runner_health || {};

  i2ck("runner_health is a named sub-object on projects[] (not a flat key)", typeof projOf(SNAP, "projWork").runner_health === "object");
  i2ck("working — fresh heartbeat + in a task", RH("projWork").state === "working");
  i2ck("working — heartbeat fresh", RH("projWork").heartbeat === "fresh");
  i2ck("working — process alive", RH("projWork").process === "alive");
  i2ck("idle — fresh heartbeat, no task", RH("projIdle").state === "idle");
  i2ck("starved-but-alive reads 'idle', NEVER stuck (bead invariant; UX-DESIGN-V2 §5.4)", RH("projStarve").state === "idle");
  i2ck("cooldown/capacity-deny reads 'idle', NEVER wedged (findings §180–182)", RH("projCool").state === "idle");
  i2ck("wedged — stale heartbeat, process not explicitly down (the krxv/td0y wedge)", RH("projWedged").state === "wedged");
  i2ck("wedged — heartbeat stale", RH("projWedged").heartbeat === "stale");
  i2ck("wedged — process still 'alive' (§3: wedged is process-alive-but-stale)", RH("projWedged").process === "alive");
  i2ck("stopped runner — process 'dead' (actual=stopped)", RH("projDead").process === "dead");
  i2ck("stopped runner — state 'idle', NOT wedged (process:dead carries the truth)", RH("projDead").state === "idle");
  i2ck("runner_health carries last_pickup_at (null — no producer yet, honest)", Object.prototype.hasOwnProperty.call(RH("projWork"), "last_pickup_at") && RH("projWork").last_pickup_at === null);
  i2ck(
    "runner_health field-set is EXACTLY {process,heartbeat,last_pickup_at,state} (B.1)",
    JSON.stringify(Object.keys(RH("projWork")).sort()) === JSON.stringify(["heartbeat", "last_pickup_at", "process", "state"])
  );

  // ── activity: writer lane (8-key) + auxiliary pool (5-key), projected DOWN ──
  await freshActivity();
  await actReport(actLine({ agent_key: "writer:hostW", workspace: "projWork", lane: "writer" }));
  await actReport(
    actLine({
      agent_key: "aux:enricher:7771",
      workspace: "projWork",
      lane: "auxiliary",
      kind: "enricher",
      state: "exploring",
      liveness_dot: "green",
      // an aux carries no bead-level identity to the UI; include some in the
      // wire body to prove the projection DROPS them.
      bead_ref: "projWork-99",
      title: "should not surface on an aux",
      seconds_in_state: 44,
    })
  );
  const SNAP2 = await callJson("work-snapshot", ["", ""]);
  const A = projOf(SNAP2, "projWork").activity || {};
  i2ck("activity is a named sub-object on projects[] (not a flat key)", typeof A === "object" && A !== null);
  i2ck("activity.writer is present (one writer row for this workspace)", A.writer && typeof A.writer === "object");
  i2ck("writer projects bead_ref/title/stage from the §1.4 body", A.writer && A.writer.bead_ref === "projWork-1" && A.writer.title === "wire the input handler" && A.writer.stage === "impl");
  i2ck("writer projects the D.2 state + always state_confidence:'derived'", A.writer && A.writer.state === "writing-code" && A.writer.state_confidence === "derived");
  i2ck("writer projects seconds_in_state + touching[] (§1.5)", A.writer && A.writer.seconds_in_state === 12 && JSON.stringify(A.writer.touching) === JSON.stringify(["Gameplay", "Input"]));
  i2ck("writer liveness_dot is green (fresh report)", A.writer && A.writer.liveness_dot === "green");
  i2ck(
    "writer field-set is EXACTLY the B.1 8 keys (current_tool/last_event_ts/kind/observed_at DROPPED — must-protect #2)",
    A.writer &&
      JSON.stringify(Object.keys(A.writer).sort()) ===
        JSON.stringify(["bead_ref", "liveness_dot", "seconds_in_state", "stage", "state", "state_confidence", "title", "touching"])
  );
  i2ck("activity.auxiliary is an array with the one aux row", Array.isArray(A.auxiliary) && A.auxiliary.length === 1);
  const aux0 = (A.auxiliary && A.auxiliary[0]) || {};
  i2ck("aux projects kind + a label + the D.2 state + derived confidence", aux0.kind === "enricher" && aux0.state === "exploring" && aux0.state_confidence === "derived");
  i2ck("aux carries a liveness_dot", aux0.liveness_dot === "green");
  i2ck(
    "aux field-set is EXACTLY the B.1 5 keys (NO bead_ref/title/seconds_in_state — §1.4)",
    JSON.stringify(Object.keys(aux0).sort()) === JSON.stringify(["kind", "label", "liveness_dot", "state", "state_confidence"])
  );

  // ── uniform shape: a workspace with NO activity rows still carries the block ─
  const Aidle = projOf(SNAP2, "projIdle").activity || {};
  i2ck("a workspace with no activity rows ⇒ activity.writer is null (honest)", Aidle.writer === null);
  i2ck("a workspace with no activity rows ⇒ activity.auxiliary is [] (uniform, never absent)", Array.isArray(Aidle.auxiliary) && Aidle.auxiliary.length === 0);

  // ── honesty: a STALE report (reporter died) downgrades a frozen-green dot ───
  // The agent last reported green, but >180s ago — the agent is gone, so a green
  // dot would be a lie (S-1/C6). worseDot re-derives from observed_at age.
  await freshActivity();
  await actReport(actLine({ agent_key: "writer:hostStale", workspace: "projWork", liveness_dot: "green", observed_at: ago(99999) }));
  const SNAP3 = await callJson("work-snapshot", ["projWork", ""]);
  const As = projOf(SNAP3, "projWork").activity || {};
  i2ck("stale report (reporter dead) downgrades a frozen green ⇒ red (never lie)", As.writer && As.writer.liveness_dot === "red");

  // ── READ-ONLY: work-snapshot reads NEVER mutate the agent_activity namespace ─
  const beforeA = await env.DB.prepare("SELECT COUNT(*) AS n FROM agent_activity").first();
  await callJson("work-snapshot", ["", ""]);
  await callJson("work-snapshot", ["projWork", ""]);
  const afterA = await env.DB.prepare("SELECT COUNT(*) AS n FROM agent_activity").first();
  i2ck("read-only — workSnapshot does NOT mutate the agent_activity namespace", (beforeA && beforeA.n) === (afterA && afterA.n));

  // eslint-disable-next-line no-console
  console.log(`\n══ CF.3 I2 activity{}+runner_health{} (vs design/activity.md §2/§3 + B.1): PASS=${i2PASS} FAIL=${i2FAIL} ══`);
  if (i2FAIL > 0) {
    // eslint-disable-next-line no-console
    console.log("FAILED:\n  - " + i2fails.join("\n  - "));
  }
  expect(i2FAIL, `I2 activity/runner_health clauses failed: ${i2fails.join("; ")}`).toBe(0);
});

// ════════════════════════════════════════════════════════════════════════════
// H3 (claude-tools-uxvh3) — blueprint_meta{} per-project sub-object (DESIGN H
// §8.1, A.3/B.1). DERIVED at read time (never stored): updated_at JOINS the
// blueprint §4 record's freshness; thumb_ref points at "render this blueprint at
// thumb size" (§8.5 — the project_ref, null when no map yet); active_domains is
// the §8.2 in-flight overlay union read off the activity.writer.touching Track I
// produces (soft coupling, ARCH §6). A NAMED sub-object so it never collides on
// the shared workSnapshot seam. No record ⇒ the honest all-null/[] block (B.4),
// uniform across projects. The map BODY is NOT inlined (fetched on demand).
// ════════════════════════════════════════════════════════════════════════════
it("CF.3 H3 workSnapshot blueprint_meta{} — DESIGN H §8.1 + B.1 (claude-tools-uxvh3)", async () => {
  let hPASS = 0;
  let hFAIL = 0;
  const hfails = [];
  function hck(name, cond) {
    if (cond) { hPASS++; console.log(`  ✓ ${name}`); }
    else { hFAIL++; hfails.push(name); console.log(`  ✗ ${name}`); }
  }
  const projOf = (snap, ref) => (snap.projects || []).find((p) => p.project_ref === ref) || {};
  const bpPut = (env2) => call(GOOD, "blueprint-put", [JSON.stringify(env2)]);
  const actLine = (o) => JSON.stringify({
    report: "agent_activity", schema_version: 1, principal: "x",
    agent_key: "writer:hostBP", workspace: "projBP", lane: "writer", kind: "impl",
    bead_ref: "projBP-1", title: "t", stage: "impl", state: "writing-code",
    state_confidence: "derived", liveness_dot: "green",
    observed_at: ago(2), last_event_ts: ago(2), seconds_in_state: 5,
    touching: ["domain:posts-feed", "domain:messaging"], ...o,
  });

  try { await env.DB.prepare("DELETE FROM agent_activity").run(); } catch { /* lazy table */ }

  // projBP: a real runner + a blueprint record + a writer touching two domains.
  await call(GOOD, "heartbeat", [hbLine("hostBP", "projBP", "running", "projBP-1", ago(5))]);
  await bpPut({
    project_ref: "projBP", section: "derived", updated_by: "agent:blueprint-update",
    body: { nodes: [
      { id: "domain:posts-feed", label: "Posts & Feed", kind: "domain", parent: null },
      { id: "domain:messaging", label: "Messaging", kind: "domain", parent: null },
    ], edges: [], apis: [] },
  });
  await call(GOOD, "agent-activity-report", [actLine({})]);
  // projBare: a runner but NO blueprint record (the honest empty-meta case).
  await call(GOOD, "heartbeat", [hbLine("hostBare", "projBare", "idle", "", ago(5))]);

  const SNAP = await callJson("work-snapshot", ["", ""]);
  const BM = (ref) => projOf(SNAP, ref).blueprint_meta || null;

  hck("blueprint_meta is a named sub-object on projects[] (not a flat key)", typeof BM("projBP") === "object" && BM("projBP") !== null);
  hck(
    "blueprint_meta field-set is EXACTLY {updated_at,thumb_ref,active_domains} (B.1 §8.1)",
    JSON.stringify(Object.keys(BM("projBP")).sort()) === JSON.stringify(["active_domains", "thumb_ref", "updated_at"])
  );
  hck("updated_at JOINS the blueprint record's freshness (a string)", typeof BM("projBP").updated_at === "string" && BM("projBP").updated_at.length > 0);
  hck("thumb_ref points at the project_ref (§8.5 — render at thumb size)", BM("projBP").thumb_ref === "projBP");
  hck("active_domains is the §8.2 union of writer.touching", JSON.stringify(BM("projBP").active_domains) === JSON.stringify(["domain:posts-feed", "domain:messaging"]));

  // The honest empty-meta case: a project with NO blueprint record carries the
  // block uniformly (B.4) — all null/[] , never absent, never fabricated.
  hck("no blueprint record ⇒ blueprint_meta present (uniform, never absent)", typeof BM("projBare") === "object" && BM("projBare") !== null);
  hck("no blueprint record ⇒ updated_at null (honest)", BM("projBare").updated_at === null);
  hck("no blueprint record ⇒ thumb_ref null (no map to render)", BM("projBare").thumb_ref === null);
  hck("no blueprint record ⇒ active_domains [] (no writer touching)", Array.isArray(BM("projBare").active_domains) && BM("projBare").active_domains.length === 0);

  // The map BODY is NOT inlined into the projection (§8.1 — fetched on demand via
  // blueprint-get). blueprint_meta carries only the thumbnail-sized meta.
  hck("the derived map body is NOT inlined into projects[] (only the meta)", !Object.prototype.hasOwnProperty.call(BM("projBP"), "derived") && !Object.prototype.hasOwnProperty.call(projOf(SNAP, "projBP"), "blueprint"));

  // READ-ONLY: a work-snapshot read never mutates the blueprint record.
  const before = await env.DB.prepare("SELECT json FROM records WHERE type='blueprint' AND id='projBP'").first();
  await callJson("work-snapshot", ["", ""]);
  const after = await env.DB.prepare("SELECT json FROM records WHERE type='blueprint' AND id='projBP'").first();
  hck("read-only — work-snapshot does NOT mutate the blueprint record", (before && before.json) === (after && after.json));

  console.log(`\n══ CF.3 H3 blueprint_meta{} (vs design/blueprint.md §8.1 + B.1): PASS=${hPASS} FAIL=${hFAIL} ══`);
  if (hFAIL > 0) console.log("FAILED:\n  - " + hfails.join("\n  - "));
  expect(hFAIL, `H3 blueprint_meta clauses failed: ${hfails.join("; ")}`).toBe(0);
});

// ════════════════════════════════════════════════════════════════════════════
// J2 (claude-tools-uxvj2) — the holds[] unifier (DESIGN J §3 / B.1). Joins the
// THREE hold mechanisms into projects[].holds, derived AT READ time (A.3): our
// editable Gate (gate:<id> label + the J1 gate_metadata LEFT-join), beads-native
// dependency (blocked_on, read-only), beads-native scheduled (deferred_until,
// read-only, optionally owned by a co-present gate). Two source paths: the inline
// `beads` arg (the bash-twin / live-verify path) AND the production §4.6
// `held_beads` channel (the GET-path source — the active in_progress/top_n lists
// exclude held work). editable is true ONLY for gate (the C3 honesty rule).
// ════════════════════════════════════════════════════════════════════════════
it("CF.3 J2 workSnapshot holds[] unifier — 3 mechanisms + gate_metadata join + held_beads channel (claude-tools-uxvj2)", async () => {
  let jPASS = 0;
  let jFAIL = 0;
  const jfails = [];
  function jck(name, cond) {
    if (cond) {
      jPASS++;
      // eslint-disable-next-line no-console
      console.log(`  ✓ ${name}`);
    } else {
      jFAIL++;
      jfails.push(name);
      // eslint-disable-next-line no-console
      console.log(`  ✗ ${name}`);
    }
  }
  const projOf = (snap, ref) => (snap.projects || []).find((p) => p.project_ref === ref) || {};
  const find = (holds, pred) => (holds || []).find(pred);

  // ── seed the J1 gate_metadata row the gate branch LEFT-joins (bare id) ────────
  const setMeta = await call(GOOD, "gate-meta-set", [
    JSON.stringify({
      id: "audio-redesign",
      why: "audio engine rewrite in flight",
      unblock_condition: "rewrite merged",
      owner: "agent:enricher",
      scope: "cohort",
    }),
  ]);
  jck("gate-meta-set seeded the join row (rc 0 ⇒ 200)", setMeta.status === 200);

  // ── PATH 1: the inline beads arg (bash-twin / live-verify path) ───────────────
  const HBEADS = JSON.stringify([
    { bead_ref: "h-g1", title: "Gated A", stage: "impl", labels: ["gate:audio-redesign", "stage:impl"] },
    { bead_ref: "h-g2", title: "Gated B", stage: "design", labels: ["gate:audio-redesign"] },
    { bead_ref: "h-nm", title: "Gated no-meta", stage: "impl", labels: ["gate:no-meta"] },
    { bead_ref: "h-dep", title: "Blocked", stage: "impl", blocked_on: "h-77a" },
    { bead_ref: "h-s1", title: "Deferred owned", stage: "ux", deferred_until: "2026-07-01", labels: ["gate:audio-redesign"] },
    { bead_ref: "h-s2", title: "Deferred free", stage: "ux", deferred_until: "2026-08-01" },
    { bead_ref: "h-x", title: "No hold", stage: "impl", labels: ["stage:impl", "gateway"] },
  ]);
  const SNAP = await callJson("work-snapshot", ["projHinline", HBEADS]);
  const H = projOf(SNAP, "projHinline").holds;
  jck("holds is a named sub-object on projects[] (not a flat key)", Array.isArray(H));

  // gate (with metadata) — the LEFT-join lights up
  const gate = find(H, (h) => h.type === "gate" && h.id === "gate:audio-redesign");
  jck("gate hold grouped by gate:<id> label (id carries the prefix)", !!gate);
  jck("gate task_count = beads carrying the label (cohort=3: g1,g2,s1)", gate && gate.task_count === 3);
  jck("gate editable:true (our native hold — the ONLY editable type)", gate && gate.editable === true);
  jck("gate why joined from gate_metadata", gate && gate.why === "audio engine rewrite in flight");
  jck("gate unblock_condition → unblocks_when (B.1 field name)", gate && gate.unblocks_when === "rewrite merged");
  jck("gate owner joined (an INPUT, not the principal — §2.3)", gate && gate.owner === "agent:enricher");
  jck("gate scope joined (D.2 closed enum)", gate && gate.scope === "cohort");
  jck("gate set_at joined (the 'set 4d ago' line — non-null)", gate && typeof gate.set_at === "string" && gate.set_at.length > 0);
  jck("gate degraded:[] when metadata present", gate && Array.isArray(gate.degraded) && gate.degraded.length === 0);
  jck(
    "gate field-set is EXACTLY the B.1+§3.2 keys",
    gate &&
      JSON.stringify(Object.keys(gate).sort()) ===
        JSON.stringify(["degraded", "editable", "id", "owner", "scope", "set_at", "task_count", "type", "unblocks_when", "why"])
  );

  // gate (NO metadata) — B.4 degradation, never dropped/thrown
  const gateNm = find(H, (h) => h.type === "gate" && h.id === "gate:no-meta");
  jck("gate with NO metadata row is still rendered (B.4 — not dropped)", !!gateNm);
  jck("gate with no metadata: why null", gateNm && gateNm.why === null);
  jck("gate with no metadata: unblocks_when/owner/scope/set_at all null", gateNm && gateNm.unblocks_when === null && gateNm.owner === null && gateNm.scope === null && gateNm.set_at === null);
  jck("gate with no metadata: degraded[] note present", gateNm && gateNm.degraded[0] === "gate placed before metadata existed");

  // gate ordering (sorted by label) + no false-match
  jck("gate holds sorted by label (audio-redesign before no-meta)", H.filter((h) => h.type === "gate").map((h) => h.id).join(",") === "gate:audio-redesign,gate:no-meta");
  jck("a 'gateway' label does NOT false-match as a gate (^gate: anchor + id shape)", H.filter((h) => h.type === "gate" && h.id === "gateway").length === 0);

  // dependency — beads-native, read-only
  const dep = find(H, (h) => h.type === "dependency");
  jck("dependency hold present (blocked + blocked_on)", dep && dep.task_ref === "h-dep");
  jck("dependency blocked_on carried", dep && dep.blocked_on === "h-77a");
  jck("dependency unblocks_when = '<ref> closes' (honest native)", dep && dep.unblocks_when === "h-77a closes");
  jck("dependency editable:false (beads-native — read-only, C3)", dep && dep.editable === false);

  // scheduled — beads-native, read-only, owning_gate from the co-present label
  const sOwned = find(H, (h) => h.type === "scheduled" && h.task_ref === "h-s1");
  const sFree = find(H, (h) => h.type === "scheduled" && h.task_ref === "h-s2");
  jck("scheduled deferred_until carried", sOwned && sOwned.deferred_until === "2026-07-01");
  jck("scheduled owning_gate = the co-present gate label (nest under gate)", sOwned && sOwned.owning_gate === "gate:audio-redesign");
  jck("scheduled with NO co-present gate ⇒ owning_gate null", sFree && sFree.owning_gate === null);
  jck("scheduled unblocks_when = the defer date", sOwned && sOwned.unblocks_when === "2026-07-01");
  jck("scheduled editable:false (beads-native — read-only, C3)", sOwned && sOwned.editable === false);

  // a bead with no hold trigger produces NO hold
  jck("a bead with no hold trigger produces no hold (h-x absent)", H.filter((h) => h.task_ref === "h-x").length === 0);

  // ── PATH 2: the production §4.6 held_beads channel (end-to-end) ───────────────
  // The runner publishes held (blocked/deferred/gated) beads in the inventory's
  // held_beads channel; the GET path (beads="") reads them back into holds. This
  // is the "seeded gate appears end-to-end" requirement (gates.md §3.3 — the 56h
  // trap) exercised through the REAL ingest → store → projection on the engine.
  const INV = JSON.stringify({
    report: "workspace_inventory",
    schema_version: 1,
    principal: "literal-overwritten",
    runner_id: "hostHolds",
    project_ref: "projHoldsX",
    observed_at: ago(2),
    counts: { open: 0, ready: 0, in_progress: 0, blocked: 1 },
    in_progress_beads: [],
    top_n_beads: [],
    held_beads: [
      { bead_ref: "i-g1", title: "inv gated+deferred", status: "deferred", stage: "impl", labels: ["gate:audio-redesign"], blocked_on: null, deferred_until: "2026-09-01" },
      { bead_ref: "i-dep", title: "inv blocked", status: "blocked", stage: "impl", labels: [], blocked_on: "i-99", deferred_until: null },
    ],
  });
  const putInv = await call(GOOD, "workspace-inventory-put", [INV]);
  jck("workspace-inventory-put with held_beads accepted (200)", putInv.status === 200);
  const SNAPi = await callJson("work-snapshot", ["projHoldsX", ""]); // beads="" ⇒ inventory fallback
  const Hi = projOf(SNAPi, "projHoldsX").holds;
  const gi = find(Hi, (h) => h.type === "gate");
  jck("END-TO-END: a seeded gate bead in held_beads surfaces as a gate hold", gi && gi.id === "gate:audio-redesign" && gi.task_count === 1);
  jck("END-TO-END: the gate_metadata join still lights up through the inventory path", gi && gi.why === "audio engine rewrite in flight" && gi.owner === "agent:enricher");
  const si = find(Hi, (h) => h.type === "scheduled" && h.task_ref === "i-g1");
  jck("END-TO-END: a deferred+gated held bead yields a scheduled hold owned by its gate", si && si.deferred_until === "2026-09-01" && si.owning_gate === "gate:audio-redesign");
  const di = find(Hi, (h) => h.type === "dependency" && h.task_ref === "i-dep");
  jck("END-TO-END: a blocked held bead yields a dependency hold (blocked_on)", di && di.blocked_on === "i-99");

  // ── tolerance: held_beads is OPTIONAL ADDITIVE — absent / malformed never 422s ─
  const invNoHeld = JSON.stringify({
    report: "workspace_inventory", schema_version: 1, principal: "x", runner_id: "r2",
    project_ref: "projHoldsNo", observed_at: ago(2),
    counts: { open: 0, ready: 0, in_progress: 0, blocked: 0 },
    in_progress_beads: [], top_n_beads: [],
  });
  jck("workspace-inventory-put with NO held_beads still accepted (optional additive)", (await call(GOOD, "workspace-inventory-put", [invNoHeld])).status === 200);
  const invBadHeld = JSON.stringify({
    report: "workspace_inventory", schema_version: 1, principal: "x", runner_id: "r3",
    project_ref: "projHoldsBad", observed_at: ago(2),
    counts: { open: 0, ready: 0, in_progress: 0, blocked: 0 },
    in_progress_beads: [], top_n_beads: [],
    held_beads: "not-an-array",
  });
  jck("workspace-inventory-put with MALFORMED held_beads does NOT 422 (ztb6 tolerance)", (await call(GOOD, "workspace-inventory-put", [invBadHeld])).status === 200);
  const SNAPno = await callJson("work-snapshot", ["projHoldsNo", ""]);
  jck("no held_beads ⇒ holds:[] (honest empty)", Array.isArray(projOf(SNAPno, "projHoldsNo").holds) && projOf(SNAPno, "projHoldsNo").holds.length === 0);

  // ── READ-ONLY: holds derivation NEVER mutates a record (§4.5 invariant) ───────
  const before = await recordSig();
  await callJson("work-snapshot", ["projHinline", HBEADS]);
  await callJson("work-snapshot", ["projHoldsX", ""]);
  const after = await recordSig();
  jck("read-only — holds derivation mutates ZERO records (§4.5)", before === after && before.length > 0);

  // eslint-disable-next-line no-console
  console.log(`\n══ CF.3 J2 holds[] unifier (vs DESIGN J §3 + B.1): PASS=${jPASS} FAIL=${jFAIL} ══`);
  if (jFAIL > 0) {
    // eslint-disable-next-line no-console
    console.log("FAILED:\n  - " + jfails.join("\n  - "));
  }
  expect(jFAIL, `J2 holds[] clauses failed: ${jfails.join("; ")}`).toBe(0);
});

// ════════════════════════════════════════════════════════════════════════════
// claude-tools-lv9c — current_task_ref is AUTHORITATIVE per heartbeat.
// Producer (lib/local-agent.sh la_report_heartbeat) OMITS the field on `hb idle`.
// Before this fix, the CF handler only WROTE current_task_ref when non-empty,
// so the prior value leaked through `...prev` indefinitely — the Board kept
// showing a long-closed task as "currently running on" the workspace until a
// new task picked up. Fix: every heartbeat's current_task_ref is authoritative
// (present ⇒ set; missing/empty ⇒ clear to null). Mirrors the bash twin in
// lib/test-coordinator-reconcile.sh (the differential discipline §4.2 owes).
// ════════════════════════════════════════════════════════════════════════════
it("CF.3 lv9c — current_task_ref is AUTHORITATIVE per heartbeat (clear-on-idle)", async () => {
  let lvPASS = 0;
  let lvFAIL = 0;
  const lvFails = [];
  function lvck(name, cond) {
    if (cond) {
      lvPASS++;
      // eslint-disable-next-line no-console
      console.log(`  ✓ ${name}`);
    } else {
      lvFAIL++;
      lvFails.push(name);
      // eslint-disable-next-line no-console
      console.log(`  ✗ ${name}`);
    }
  }
  // The producer's actual wire shape on `hb idle`: current_task_ref OMITTED.
  // Mirrors la_report_heartbeat's `if $cur=="" then {} else {current_task_ref:$cur}`.
  function hbIdleNoCur(prj, at) {
    return JSON.stringify({
      report: "heartbeat",
      schema_version: 1,
      principal: "literal-overwritten",
      runner_id: "hostLv9",
      project_ref: prj,
      actual: "idle",
      observed_at: at,
    });
  }

  // ── Case A: set, then clear via hb idle (field OMITTED, the producer's shape)
  await call(GOOD, "heartbeat", [hbLine("hostLv9", "projLv9A", "running", "claude-tools-xyz", ago(5))]);
  const lvA1 = await getRecord("runner_state", "projLv9A");
  lvck("A1 — running heartbeat sets current_task_ref", lvA1 && lvA1.current_task_ref === "claude-tools-xyz");
  await call(GOOD, "heartbeat", [hbIdleNoCur("projLv9A", ago(1))]);
  const lvA2 = await getRecord("runner_state", "projLv9A");
  lvck(
    "A2 — idle heartbeat (field absent) CLEARS current_task_ref",
    lvA2 && (lvA2.current_task_ref === null || lvA2.current_task_ref === undefined || lvA2.current_task_ref === "")
  );
  lvck("A2 — actual flips to idle", lvA2 && lvA2.actual === "idle");

  // ── Case B: running TASK_A then running TASK_B overwrites (not stale) ────
  await call(GOOD, "heartbeat", [hbLine("hostLv9", "projLv9B", "running", "TASK_A", ago(10))]);
  const lvB1 = await getRecord("runner_state", "projLv9B");
  lvck("B1 — current_task_ref = TASK_A", lvB1 && lvB1.current_task_ref === "TASK_A");
  await call(GOOD, "heartbeat", [hbLine("hostLv9", "projLv9B", "running", "TASK_B", ago(5))]);
  const lvB2 = await getRecord("runner_state", "projLv9B");
  lvck("B2 — current_task_ref overwrites to TASK_B", lvB2 && lvB2.current_task_ref === "TASK_B");

  // ── Case C: preserve actual + last_heartbeat_at while clearing the ref ───
  await call(GOOD, "heartbeat", [hbLine("hostLv9", "projLv9C", "running", "TASK_A", ago(60))]);
  const obs2 = ago(5);
  await call(GOOD, "heartbeat", [hbIdleNoCur("projLv9C", obs2)]);
  const lvC = await getRecord("runner_state", "projLv9C");
  lvck("C — actual reflects new idle", lvC && lvC.actual === "idle");
  lvck("C — last_heartbeat_at reflects new observed_at", lvC && lvC.last_heartbeat_at === obs2);
  lvck(
    "C — current_task_ref cleared on idle",
    lvC && (lvC.current_task_ref === null || lvC.current_task_ref === undefined || lvC.current_task_ref === "")
  );

  // ── Case D: literal "" from wire ALSO clears (identical to omission) ─────
  await call(GOOD, "heartbeat", [hbLine("hostLv9", "projLv9D", "running", "TASK_A", ago(10))]);
  const lvD1 = await getRecord("runner_state", "projLv9D");
  lvck("D1 — current_task_ref = TASK_A", lvD1 && lvD1.current_task_ref === "TASK_A");
  await call(GOOD, "heartbeat", [hbLine("hostLv9", "projLv9D", "idle", "", ago(5))]);
  const lvD2 = await getRecord("runner_state", "projLv9D");
  lvck(
    "D2 — literal empty current_task_ref also clears",
    lvD2 && (lvD2.current_task_ref === null || lvD2.current_task_ref === undefined || lvD2.current_task_ref === "")
  );

  // eslint-disable-next-line no-console
  console.log(
    `\n══ CF.3 lv9c clear-on-idle (vs lib/coordinator.sh + test-coordinator-reconcile.sh): PASS=${lvPASS} FAIL=${lvFAIL} ══`
  );
  if (lvFAIL > 0) {
    // eslint-disable-next-line no-console
    console.log("FAILED:\n  - " + lvFails.join("\n  - "));
  }
  expect(lvFAIL, `lv9c clauses failed: ${lvFails.join("; ")}`).toBe(0);
});

// ════════════════════════════════════════════════════════════════════════════
// claude-tools-4g5o — workspace_inventory join: workSnapshot looks up the
// title for each project's current_task_ref from the stored §4.6
// workspace_inventory record's in_progress_beads[] and exposes it as
// runner_state.current_task_title. Graceful degradation when the record /
// match / ref is absent — the Board renderer falls back to ref-only.
// ════════════════════════════════════════════════════════════════════════════
it("CF.3 workSnapshot joins workspace_inventory.in_progress_beads → runner_state.current_task_title (claude-tools-4g5o)", async () => {
  let pPASS = 0;
  let pFAIL = 0;
  const pfails = [];
  function pck(name, cond) {
    if (cond) {
      pPASS++;
      // eslint-disable-next-line no-console
      console.log(`  ✓ ${name}`);
    } else {
      pFAIL++;
      pfails.push(name);
      // eslint-disable-next-line no-console
      console.log(`  ✗ ${name}`);
    }
  }
  // A minimal conformant §4.6 workspace_inventory payload for the put endpoint
  // (the CF op handler asserts all required fields — see claude-tools-8dfb).
  function wsiPayload(projectRef, inProgress) {
    return JSON.stringify({
      report: "workspace_inventory",
      schema_version: 1,
      principal: "literal-overwritten",
      runner_id: "hostX",
      project_ref: projectRef,
      observed_at: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
      counts: { open: 0, ready: 0, in_progress: inProgress.length, blocked: 0 },
      in_progress_beads: inProgress,
      top_n_beads: [],
    });
  }
  // Make sure each case starts from a known runner_state (so the projection
  // surfaces THIS project) and a known current_task_ref (so the join has a
  // key to look up).
  async function seedRunner(projectRef, taskRef) {
    await call(GOOD, "set-desired", [projectRef, "running", "ui:x"]);
    await call(GOOD, "heartbeat", [
      hbLine("hostX", projectRef, "running", taskRef, ago(5)),
    ]);
  }
  async function pickRunner(projectRef) {
    const snap = await callJson("work-snapshot", ["", ""]);
    return (snap.projects || []).find((p) => p.project_ref === projectRef);
  }

  // ── Case A: workspace_inventory record exists + ref matches in_progress ──
  await seedRunner("projA4g5o", "claude-tools-aaa");
  await call(GOOD, "workspace-inventory-put", [
    wsiPayload("projA4g5o", [
      { bead_ref: "claude-tools-aaa", title: "Alpha title", stage: "impl" },
      { bead_ref: "claude-tools-bbb", title: "Beta title", stage: "impl" },
    ]),
  ]);
  const A = await pickRunner("projA4g5o");
  pck("Case A — projection includes the project", !!A);
  pck(
    "Case A — runner_state.current_task_ref carries the heartbeat ref",
    A && A.runner_state.current_task_ref === "claude-tools-aaa"
  );
  pck(
    "Case A — runner_state HAS current_task_title (contract field present)",
    A && Object.prototype.hasOwnProperty.call(A.runner_state, "current_task_title")
  );
  pck(
    "Case A — current_task_title is the joined title from in_progress_beads",
    A && A.runner_state.current_task_title === "Alpha title"
  );

  // ── Case B: record exists but ref isn't in in_progress_beads ─────────────
  await seedRunner("projB4g5o", "claude-tools-missing");
  await call(GOOD, "workspace-inventory-put", [
    wsiPayload("projB4g5o", [
      { bead_ref: "claude-tools-other", title: "Some other", stage: "impl" },
    ]),
  ]);
  const B = await pickRunner("projB4g5o");
  pck(
    "Case B — ref not in in_progress_beads ⇒ current_task_title is null",
    B && B.runner_state.current_task_title === null
  );
  pck(
    "Case B — current_task_ref still carries the unmatched heartbeat ref",
    B && B.runner_state.current_task_ref === "claude-tools-missing"
  );

  // ── Case C: no workspace_inventory record for the project at all ─────────
  await seedRunner("projC4g5o", "claude-tools-anything");
  // Deliberately DO NOT post a workspace-inventory-put. The join must
  // gracefully degrade without throwing.
  const C = await pickRunner("projC4g5o");
  pck(
    "Case C — no workspace_inventory record ⇒ current_task_title is null",
    C && C.runner_state.current_task_title === null
  );
  pck(
    "Case C — current_task_ref is still present (heartbeat-driven)",
    C && C.runner_state.current_task_ref === "claude-tools-anything"
  );

  // ── Case D: record exists but no current_task_ref (workspace is idle) ────
  await call(GOOD, "set-desired", ["projD4g5o", "running", "ui:x"]);
  await call(GOOD, "heartbeat", [
    hbLine("hostX", "projD4g5o", "idle", "", ago(5)),
  ]);
  await call(GOOD, "workspace-inventory-put", [
    wsiPayload("projD4g5o", [
      { bead_ref: "claude-tools-zzz", title: "Idle-time title", stage: "impl" },
    ]),
  ]);
  const D = await pickRunner("projD4g5o");
  pck(
    "Case D — idle workspace (no current_task_ref) ⇒ title is null",
    D && D.runner_state.current_task_title === null
  );
  pck(
    "Case D — current_task_ref is empty/null when runner is idle",
    D && (!D.runner_state.current_task_ref || D.runner_state.current_task_ref === "")
  );

  // eslint-disable-next-line no-console
  console.log(
    `\n══ CF.3 workspace_inventory.title join (claude-tools-4g5o): PASS=${pPASS} FAIL=${pFAIL} ══`
  );
  if (pFAIL > 0) {
    // eslint-disable-next-line no-console
    console.log("FAILED:\n  - " + pfails.join("\n  - "));
  }
  expect(pFAIL, `4g5o clauses failed: ${pfails.join("; ")}`).toBe(0);
});

// ════════════════════════════════════════════════════════════════════════════
// claude-tools-uxvq1 — §9 / Contract B.1 queue_health: workSnapshot surfaces
// projects[].queue_health from the runner-published §4.6 record (normalized to
// the frozen B.1 shape), defaulting to the honest zeroed block when no
// inventory record / no block exists (uniform shape — the Board strip always
// has a block to render the empty-queue explainer + net-velocity alarm).
// ════════════════════════════════════════════════════════════════════════════
it("CF.3 workSnapshot surfaces projects[].queue_health (§9 / B.1, claude-tools-uxvq1)", async () => {
  let pPASS = 0;
  let pFAIL = 0;
  const pfails = [];
  function pck(name, cond) {
    if (cond) {
      pPASS++;
      // eslint-disable-next-line no-console
      console.log(`  ✓ ${name}`);
    } else {
      pFAIL++;
      pfails.push(name);
      // eslint-disable-next-line no-console
      console.log(`  ✗ ${name}`);
    }
  }
  function wsiWithQh(projectRef, qh) {
    const base = {
      report: "workspace_inventory",
      schema_version: 1,
      principal: "literal-overwritten",
      runner_id: "hostQ",
      project_ref: projectRef,
      observed_at: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
      counts: { open: 0, ready: 0, in_progress: 0, blocked: 0 },
      in_progress_beads: [],
      top_n_beads: [],
    };
    if (qh) base.queue_health = qh;
    return JSON.stringify(base);
  }
  async function seed(projectRef) {
    await call(GOOD, "set-desired", [projectRef, "running", "ui:x"]);
    await call(GOOD, "heartbeat", [hbLine("hostQ", projectRef, "running", "", ago(5))]);
  }
  async function pick(projectRef) {
    const snap = await callJson("work-snapshot", ["", ""]);
    return (snap.projects || []).find((p) => p.project_ref === projectRef);
  }

  // ── Case A: published queue_health surfaces (normalized) ──────────────────
  await seed("projQA");
  await call(GOOD, "workspace-inventory-put", [
    wsiWithQh("projQA", {
      ready: 4,
      held: { gate: 3, dependency: 1, scheduled: 2 },
      hidden_under_deferred_parent: 5,
      net_velocity_7d: 2,
      epics_with_zero_ready_children: ["rg-aaa"],
    }),
  ]);
  const A = await pick("projQA");
  pck("Case A — project carries a queue_health block", A && !!A.queue_health);
  pck("Case A — ready surfaced", A && A.queue_health.ready === 4);
  pck(
    "Case A — held breakdown surfaced (gate/dependency/scheduled)",
    A && A.queue_health.held.gate === 3 && A.queue_health.held.dependency === 1 &&
      A.queue_health.held.scheduled === 2
  );
  pck("Case A — hidden_under_deferred_parent surfaced", A && A.queue_health.hidden_under_deferred_parent === 5);
  pck("Case A — net_velocity_7d surfaced (COMPUTED, not a cutoff)", A && A.queue_health.net_velocity_7d === 2);
  pck(
    "Case A — epics_with_zero_ready_children surfaced",
    A && Array.isArray(A.queue_health.epics_with_zero_ready_children) &&
      A.queue_health.epics_with_zero_ready_children[0] === "rg-aaa"
  );

  // ── Case B: inventory exists but NO queue_health block ⇒ zeroed default ────
  await seed("projQB");
  await call(GOOD, "workspace-inventory-put", [wsiWithQh("projQB", null)]);
  const B = await pick("projQB");
  pck(
    "Case B — no block ⇒ honest zeroed default (uniform B.1 shape)",
    B && B.queue_health && B.queue_health.ready === 0 &&
      B.queue_health.held.scheduled === 0 &&
      Array.isArray(B.queue_health.epics_with_zero_ready_children) &&
      B.queue_health.epics_with_zero_ready_children.length === 0
  );

  // ── Case C: NO inventory record at all ⇒ still a zeroed default block ──────
  await seed("projQC");
  const C = await pick("projQC");
  pck(
    "Case C — no inventory record ⇒ zeroed default block (never absent/null)",
    C && C.queue_health && C.queue_health.ready === 0 && C.queue_health.net_velocity_7d === 0
  );

  // ── Case D: negative net_velocity_7d (draining) preserved through projection
  await seed("projQD");
  await call(GOOD, "workspace-inventory-put", [wsiWithQh("projQD", { net_velocity_7d: -4 })]);
  const D = await pick("projQD");
  pck("Case D — negative net_velocity_7d preserved (draining queue)", D && D.queue_health.net_velocity_7d === -4);

  // eslint-disable-next-line no-console
  console.log(`\n══ CF.3 queue_health projection (claude-tools-uxvq1): PASS=${pPASS} FAIL=${pFAIL} ══`);
  if (pFAIL > 0) {
    // eslint-disable-next-line no-console
    console.log("FAILED:\n  - " + pfails.join("\n  - "));
  }
  expect(pFAIL, `uxvq1 clauses failed: ${pfails.join("; ")}`).toBe(0);
});

// ════════════════════════════════════════════════════════════════════════════
// claude-tools-7qf7 — the GET-path lifecycle work-truth feed + done·verified.
// The PRODUCTION Board GET passes NO inline beads (a Worker can't exec bd), so
// workSnapshot derives the lifecycle work-truth from the runner-published §4.6
// workspace_inventory records, carrying the per-bead `verified` flag through so
// the §3 done·code-vs-done·verified split lights up live. Inline beads STILL
// WIN (the differential oracle path is byte-unchanged).
// ════════════════════════════════════════════════════════════════════════════
it("CF.3 workSnapshot derives lifecycle_columns from stored workspace_inventory on the GET path + carries verified (claude-tools-7qf7)", async () => {
  let qPASS = 0;
  let qFAIL = 0;
  const qfails = [];
  function qck(name, cond) {
    if (cond) {
      qPASS++;
      // eslint-disable-next-line no-console
      console.log(`  ✓ ${name}`);
    } else {
      qFAIL++;
      qfails.push(name);
      // eslint-disable-next-line no-console
      console.log(`  ✗ ${name}`);
    }
  }
  function wsi(projectRef, inProgress, topN) {
    return JSON.stringify({
      report: "workspace_inventory",
      schema_version: 1,
      principal: "literal-overwritten",
      runner_id: "hostQ",
      project_ref: projectRef,
      observed_at: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
      counts: { open: topN.length, ready: 0, in_progress: inProgress.length, blocked: 0 },
      in_progress_beads: inProgress,
      top_n_beads: topN,
    });
  }
  const findCard = (snap, stage, ref) =>
    ((snap.lifecycle_columns || {})[stage] || []).find((c) => c.bead_ref === ref);

  // A workspace whose published inventory carries two done-stage beads (one
  // probe-verified, one not) plus an in-progress impl bead.
  await call(GOOD, "workspace-inventory-put", [
    wsi(
      "qf7done",
      [{ bead_ref: "qf7-impl-1", title: "still building", stage: "impl", verified: false }],
      [
        { bead_ref: "qf7-done-ver", title: "shipped + probed", status: "open", stage: "done", verified: true },
        { bead_ref: "qf7-done-code", title: "code landed, unprobed", status: "open", stage: "done", verified: false },
      ]
    ),
  ]);

  // ── GET path: empty inline beads ⇒ lifecycle derived from the stored feed ──
  const snap = await callJson("work-snapshot", ["", ""]);
  qck(
    "lifecycle_columns is populated on the GET path (was empty before 7qf7)",
    snap.lifecycle_columns && Array.isArray(snap.lifecycle_columns.done)
  );
  const dv = findCard(snap, "done", "qf7-done-ver");
  const dc = findCard(snap, "done", "qf7-done-code");
  const im = findCard(snap, "impl", "qf7-impl-1");
  qck("done-stage verified bead surfaces in the done column", !!dv);
  qck("done·verified — probe-passed bead carries verified:true", dv && dv.verified === true);
  qck("done·code — unprobed bead carries verified:false", dc && dc.verified === false);
  qck("in_progress impl bead buckets under impl (stage ladder honoured)", !!im && im.verified === false);
  qck(
    "derived card defaults absent fields to null (inventory carries no failure/age)",
    dv && dv.failure === null && dv.age === null && dv.waiting_on === null
  );

  // ── Inline beads STILL WIN: a non-empty inline array bypasses the store ────
  const inlineSnap = await callJson("work-snapshot", [
    "",
    JSON.stringify([{ bead_ref: "qf7-inline", title: "inline only", stage: "idea", verified: false }]),
  ]);
  qck(
    "inline beads win — inline bead present",
    !!findCard(inlineSnap, "idea", "qf7-inline")
  );
  qck(
    "inline beads win — stored-inventory beads NOT mixed in",
    !findCard(inlineSnap, "done", "qf7-done-ver")
  );

  // ── Project filter scopes the derived feed to one workspace ────────────────
  await call(GOOD, "workspace-inventory-put", [
    wsi("qf7other", [], [{ bead_ref: "qf7-other-1", title: "elsewhere", status: "open", stage: "design", verified: false }]),
  ]);
  const scoped = await callJson("work-snapshot", ["qf7done", ""]);
  qck("project filter — scoped project's done bead present", !!findCard(scoped, "done", "qf7-done-ver"));
  qck("project filter — OTHER project's bead excluded", !findCard(scoped, "design", "qf7-other-1"));
  const allp = await callJson("work-snapshot", ["", ""]);
  qck("all-projects mode — other project's bead now present", !!findCard(allp, "design", "qf7-other-1"));

  // ── Read-only: the derive-from-store path mutates ZERO records ─────────────
  const sigBefore = await recordSig();
  await callJson("work-snapshot", ["", ""]);
  await callJson("work-snapshot", ["qf7done", ""]);
  const sigAfter = await recordSig();
  qck("derive-from-store is READ-ONLY (no record mutated)", sigBefore === sigAfter && sigBefore.length > 0);

  // eslint-disable-next-line no-console
  console.log(`\n══ CF.3 GET-path lifecycle feed (claude-tools-7qf7): PASS=${qPASS} FAIL=${qFAIL} ══`);
  if (qFAIL > 0) {
    // eslint-disable-next-line no-console
    console.log("FAILED:\n  - " + qfails.join("\n  - "));
  }
  expect(qFAIL, `7qf7 clauses failed: ${qfails.join("; ")}`).toBe(0);
});
