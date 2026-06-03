// CF.1 (claude-tools-7g0.1) — DIFFERENTIAL conformance test.
//
// Mirrors lib/test-coordinator.sh EXIT-1..5 + the §2.4 transport block, one
// linear flow (the bash script is linear; isolatedStorage gives this single
// test the bash test's fresh-mktemp-store analogue). Every assertion exercises
// the REAL engine via SELF.fetch (Worker -> §9.1 chokepoint -> singleton
// Coordinator DO -> D1) under the SAME workerd+miniflare runtime `wrangler dev`
// uses, with NO Cloudflare account. The CF engine MUST exhibit the SAME
// INTERFACE.md v1 behavior on these §-clauses as coordinator.sh asserts.
//
// `env` (the D1 binding the singleton DO writes through) is used ONLY to plant
// a corrupt prior record and to read the opaque timer row — EXACTLY mirroring
// the bash test reading/writing the store files directly. No non-contract
// debug surface is added to the engine.

import { env, SELF } from "cloudflare:test";
import { it, expect } from "vitest";

const GOOD = "bearer-runner-secret-xyz"; // a present, valid v1 bearer

// Soft-assert harness mirroring test-coordinator.sh ok/bad/ck + the final
// `[[ FAIL -eq 0 ]]` — every clause is checked (a throw would stop the linear
// flow the bash oracle runs to completion).
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
  let body = null;
  const raw = await res.text();
  if (ct.includes("application/json")) {
    try {
      body = JSON.parse(raw);
    } catch {
      body = null;
    }
  }
  return { status: res.status, raw, body };
}
// Read a stored §4 record exactly the way `co_request GOOD get <type> <id>`
// does (the get op echoes the stored JSON, or 404 = absent).
async function getRecord(type, id) {
  const r = await call(GOOD, "get", [type, id]);
  if (r.status !== 200) return null;
  try {
    return JSON.parse(r.raw);
  } catch {
    return null;
  }
}

it("CF.1 substrate is behaviour-identical to coordinator.sh + test-coordinator.sh", async () => {
  // ── EXIT-1: the shell stands up; the four §2 capabilities are reachable ──
  const capsRes = await SELF.fetch(
    new Request("https://coordinator.local/", {
      method: "GET",
      headers: { authorization: `Bearer ${GOOD}` },
    })
  );
  const caps = await capsRes.text();
  ck("co_capabilities lists §2.1 store", caps.includes("§2.1 store"));
  ck("co_capabilities lists §2.2 timer", caps.includes("§2.2 durable one-shot"));
  ck("co_capabilities lists §2.3 authed/§9.1 choke", caps.includes("§2.3 authed"));
  ck("co_capabilities lists §2.4 deliver-desired", caps.includes("§2.4 deliver-desired"));
  ck("exactly four §2 capability lines", (caps.match(/§2/g) || []).length === 4);
  const tdue = await call(GOOD, "timer-due", []);
  const getNope = await call(GOOD, "get", ["lease", "nope"]);
  ck(
    "all four reachable via dispatch (timer-due ok; get-missing reachable-but-empty)",
    tdue.status === 200 && (getNope.status === 200 || getNope.status === 404)
  );

  // ── EXIT-2: §9.1 ONE chokepoint; no/invalid token ⇒ reject BEFORE any write ──
  // Authoritative principal resolution after a VALID bearer (poll echoes the
  // resolved principal — the observable analogue of co_authenticate's stdout).
  const pollP = await call(GOOD, "poll", ["projAuth", ""]);
  ck("valid bearer ⇒ principal resolves", pollP.status === 200 && !!pollP.body && !!pollP.body.principal);
  ck("resolved principal == PRINCIPAL_V1 ('brian')", !!pollP.body && pollP.body.principal === "brian");
  // Missing bearer rejected, nothing resolved (no Authorization header at all).
  const noTok = await call(null, "poll", ["x", ""]);
  ck("missing bearer ⇒ request rejected (401)", noTok.status === 401);
  // Invalid bearer (CO_EXPECTED_TOKEN mismatch) rejected — the §9.1 validity
  // knob, mirroring the bash CO_EXPECTED_TOKEN env path.
  env.CO_EXPECTED_TOKEN = "expected";
  const badTok = await call("wrong", "poll", ["x", ""]);
  ck("invalid bearer ⇒ request rejected (401)", badTok.status === 401);
  const rightTok = await call("expected", "poll", ["x", ""]);
  ck("matching expected token ⇒ accepted", rightTok.status === 200 && rightTok.body.principal === "brian");
  // Structural invariant: a rejected request performs NO §4 write.
  const noTokPut = await call(
    null,
    "put",
    ["runner_state", "projX", '{"schema_version":1,"desired":"running"}']
  );
  ck("no-token put ⇒ request rejected (401)", noTokPut.status === 401);
  const badTokPut = await call(
    "badtok",
    "put",
    ["runner_state", "projY", '{"schema_version":1,"desired":"running"}']
  );
  ck("invalid-token put ⇒ request rejected (401)", badTokPut.status === 401);
  delete env.CO_EXPECTED_TOKEN; // restore: any non-empty bearer valid again
  ck("no-token put ⇒ ZERO §4 records written (projX absent)", (await getRecord("runner_state", "projX")) === null);
  ck("invalid-token put ⇒ still ZERO §4 records (projY absent)", (await getRecord("runner_state", "projY")) === null);
  const cntRej = await env.DB.prepare(
    "SELECT COUNT(*) AS n FROM records WHERE id IN ('projX','projY')"
  ).first();
  ck("rejected writes left ZERO rows in the §4 store", cntRej && cntRej.n === 0);

  // ── EXIT-3: §4 round-trip + §9.1 principal stamp + §0.3 reject-higher ──
  // A §4 record carrying a DIFFERENT principal literal must come back stamped
  // with the RESOLVED principal (never the use-site literal — C7/§9.1).
  await call(
    GOOD,
    "put",
    [
      "notification",
      "n1",
      '{"schema_version":1,"dossier_ref":"d1","tier":"blocking","principal":"someone-else"}',
    ]
  );
  const n1 = await getRecord("notification", "n1");
  ck("notification round-trips", !!n1);
  ck("stored principal == PRINCIPAL_V1 (stamped)", !!n1 && n1.principal === "brian");
  ck("use-site literal 'someone-else' overwritten", !!n1 && n1.principal !== "someone-else");
  // Every §4 record TYPE round-trips (store owner). dossier is bound to v2
  // (the §11 Mermaid amend single-source bump 1→2); the other §4 record types
  // stay bound 1, so each is put at its OWN bound schema_version.
  for (const t of ["dossier", "runner_state", "notification", "lease", "work_snapshot"]) {
    const sv = t === "dossier" ? 2 : 1;
    // claude-tools-4xe — type=dossier now also runs the §5.1-core WRITE GATE
    // in _writeRecord: the body MUST be §5.1-core conformant (or the §5.2.2
    // reconcile-pointer). A bodyless round-trip is no longer accepted — by
    // design (the gate is on the WRITE boundary, not render-time). The
    // substrate still does NOT validate the full §5; a minimal conformant body
    // (bound dossier_schema_version + []-diagrams) round-trips. Bash twin:
    // test-coordinator.sh same fixture.
    const rtj = t === "dossier"
      ? '{"schema_version":2,"body":{"dossier_schema_version":2,"diagrams":[]}}'
      : `{"schema_version":${sv}}`;
    await call(GOOD, "put", [t, `rt_${t}`, rtj]);
    const rec = await getRecord(t, `rt_${t}`);
    ck(`§4 ${t} round-trips with principal stamped`, !!rec && rec.principal === "brian");
  }
  // §0.3 — an unknown HIGHER schema_version is rejected, NOT best-effort-parsed.
  const hi = await call(GOOD, "put", ["runner_state", "hi", '{"schema_version":2,"desired":"running"}']);
  ck("schema_version 2 (> bound 1) ⇒ rejected", hi.status !== 200 && hi.body && hi.body.ok === false);
  ck("rejected higher-version record NOT persisted", (await getRecord("runner_state", "hi")) === null);
  const noSv = await call(GOOD, "put", ["dossier", "nov", '{"id":"x"}']);
  ck("missing schema_version ⇒ rejected", noSv.status !== 200 && noSv.body && noSv.body.ok === false);
  const badType = await call(GOOD, "put", ["bogus_type", "z", '{"schema_version":1}']);
  ck("unknown §4 record type ⇒ rejected", badType.status !== 200 && badType.body && badType.body.ok === false);
  // §4 mandates `schema_version : int` — a JSON *string* "1" MUST NOT slip past.
  const strSv = await call(GOOD, "put", ["dossier", "dstr", '{"schema_version":"1"}']);
  ck('string schema_version "1" ⇒ rejected (§4 int)', strSv.status !== 200 && strSv.body && strSv.body.ok === false);
  ck("rejected string-version record NOT persisted", (await getRecord("dossier", "dstr")) === null);
  // Store-owner input hygiene: a traversal-shaped id is rejected at the door.
  const slashId = await call(GOOD, "put", ["lease", "../../etc/evil", '{"schema_version":1}']);
  ck("unsafe id with '/' ⇒ rejected", slashId.status !== 200 && slashId.body && slashId.body.ok === false);
  const dotId = await call(GOOD, "put", ["lease", "..", '{"schema_version":1}']);
  ck("unsafe id with '..' ⇒ rejected", dotId.status !== 200 && dotId.body && dotId.body.ok === false);
  const cntEvil = await env.DB.prepare(
    "SELECT COUNT(*) AS n FROM records WHERE type='lease' AND (id='..' OR id LIKE '%/%')"
  ).first();
  ck("no unsafe-id record escaped into the §4 store", cntEvil && cntEvil.n === 0);

  // ── EXIT-4: C4 seam — last_desired_actor captured, ALL actors equal ──
  await call(GOOD, "set-desired", ["projA", "paused", "agent-runner-7"]);
  const rsA = await getRecord("runner_state", "projA");
  ck("set-desired persists RunnerState", !!rsA);
  ck("desired captured (paused)", !!rsA && rsA.desired === "paused");
  ck("last_desired_actor captured (agent-runner-7)", !!rsA && rsA.last_desired_actor === "agent-runner-7");
  ck("RunnerState principal stamped PRINCIPAL_V1", !!rsA && rsA.principal === "brian");
  // A DIFFERENT actor class (a 'ui' actor) is authorised IDENTICALLY — no
  // split, no §0.C asymmetry: the call succeeds, the actor captured verbatim.
  await call(GOOD, "set-desired", ["projA", "running", "ui:brian-laptop"]);
  const rsA2 = await getRecord("runner_state", "projA");
  ck("ui-actor desired change authorised equally", !!rsA2 && rsA2.desired === "running");
  ck("ui actor captured verbatim (no UI/agent split)", !!rsA2 && rsA2.last_desired_actor === "ui:brian-laptop");
  // A corrupt prior RunnerState MUST NOT wedge the desired-state control path:
  // set-desired degrades to a fresh base, still capturing the actor. Plant the
  // corruption straight into D1 — the analogue of the bash test's
  // `printf 'not json' > records/runner_state.projCorrupt.json`.
  await env.DB.prepare(
    "INSERT OR REPLACE INTO records (type,id,json) VALUES ('runner_state','projCorrupt','not json at all')"
  ).run();
  const sdC = await call(GOOD, "set-desired", ["projCorrupt", "stopped", "agent-9"]);
  ck("corrupt prior ⇒ set-desired still succeeds", sdC.status === 200);
  const rsC = await getRecord("runner_state", "projCorrupt");
  ck("corrupt prior ⇒ desired still captured (stopped)", !!rsC && rsC.desired === "stopped");
  ck("corrupt prior ⇒ last_desired_actor still captured", !!rsC && rsC.last_desired_actor === "agent-9");

  // ── EXIT-5-adjacent: §2.2 timer is a SURFACE with the S-6 poll-fallback ──
  await call(GOOD, "timer-arm", ["tmr-past", "2000-01-01T00:00:00Z"]);
  await call(GOOD, "timer-arm", ["tmr-future", "2999-01-01T00:00:00Z"]);
  const due = (await call(GOOD, "timer-due", [])).raw.split("\n").filter(Boolean);
  ck("armed past timer surfaces on poll (S-6 missed⇒poll)", due.includes("tmr-past"));
  ck("future timer does NOT surface", !due.includes("tmr-future"));
  await call(GOOD, "timer-ack", ["tmr-past"]);
  const due2 = (await call(GOOD, "timer-due", [])).raw.split("\n").filter(Boolean);
  ck("acked timer no longer surfaces (ack surface works)", !due2.includes("tmr-past"));
  // Anti-drift: the armed timer record is the OPAQUE shape — exactly
  // {timer_id,fire_at,armed_at,acked}, NO dossier/item/consequence coupling
  // (fire(dossier_id) + the per-Item latch are CF.6/CF.7, not this substrate).
  const tRow = await env.DB.prepare(
    "SELECT timer_id, fire_at, armed_at, acked FROM timers WHERE timer_id='tmr-future'"
  ).first();
  const tkeys = tRow ? Object.keys(tRow).sort().join(",") : "";
  ck("armed timer record is the opaque shape (CF.6/CF.7 boundary)", tkeys === "acked,armed_at,fire_at,timer_id");
  const tInfo = await env.DB.prepare("PRAGMA table_info(timers)").all();
  const tcols = (tInfo.results || []).map((r) => r.name).join(",");
  ck(
    "timers table carries NO dossier/item/consequence column (CF.6/CF.7 boundary)",
    !/dossier|consequence|item/.test(tcols)
  );

  // ── §2.4 deliver-desired-state is TRANSPORT (returns stored desired+lease) ──
  await call(
    GOOD,
    "put",
    ["lease", "projA", '{"schema_version":1,"task_ref":"projA","owner":"runner-7"}']
  );
  const poll = (await call(GOOD, "poll", ["projA", "projA"])).body;
  ck("poll returns the stored desired", !!poll && poll.desired === "running");
  ck("poll returns the stored lease record", !!poll && poll.lease && poll.lease.owner === "runner-7");
  ck("poll stamps the resolved principal", !!poll && poll.principal === "brian");
  // Anti-drift: poll derived NO liveness and ran NO reconcile (CF.3 surface).
  ck("poll output carries NO 'liveness' (CF.3 boundary)", !!poll && !("liveness" in poll));

  // ── review-pinned oracle parity (paths outside the EXIT-1..5 clauses that
  //    MUST still match coordinator.sh exactly — locked so they cannot
  //    silently regress) ──
  // co__store_get has NO record-type check: a get on an unknown type is
  // identically "reachable, just empty" (return 1), NOT a typed reject.
  const getUnknown = await call(GOOD, "get", ["bogus_type", "x"]);
  ck("get on unknown type ⇒ reachable-but-empty (404, not a 422 reject)", getUnknown.status === 404);
  // co__set_desired ends in co__store_put ⇒ an unsafe proj id is run through
  // co__safe_key and REJECTED, nothing written (same as the bash oracle).
  const sdUnsafe = await call(GOOD, "set-desired", ["../../evil", "running", "agent-x"]);
  ck("set-desired with unsafe proj id ⇒ rejected", sdUnsafe.status !== 200 && sdUnsafe.body && sdUnsafe.body.ok === false);
  const evilRs = await env.DB.prepare(
    "SELECT COUNT(*) AS n FROM records WHERE type='runner_state' AND id='../../evil'"
  ).first();
  ck("unsafe-proj set-desired wrote ZERO rows", evilRs && evilRs.n === 0);
  // co__store_put precedence: known-type check precedes the JSON parse, so an
  // unknown type beats an invalid-JSON body (type gate wins).
  const putPrec = await call(GOOD, "put", ["bogus_type", "z", "not json at all"]);
  ck(
    "put unknown-type + invalid-JSON ⇒ unknown-type reject wins (precedence)",
    putPrec.status !== 200 && putPrec.body && putPrec.body.code === "unknown_type"
  );

  // ── I2 (claude-tools-x9u) intake-request §4 type — additive surface ──
  // The /api/intake proxy hard-codes op=put + type=intake-request; the engine
  // accepts it via the SAME _writeRecord chokepoint as every other §4 record,
  // which means the §9.1 principal stamp + §0.3 schema gate apply identically.
  // The daemon (I3, claude-tools-06i) polls for these records on its own cadence
  // — the engine stays a dumb store here, no special handler.
  const irBody = JSON.stringify({
    schema_version: 1,
    id: "intake-2026-05-20T07-00-00Z-abc",
    idea_text: "let the runner pick this up tomorrow",
    project_ref: "thirsty",
    preset: "autonomous-until-stuck",
    processed: false,
    submitted_at: "2026-05-20T07:00:00Z",
    principal: "someone-else", // chokepoint MUST overwrite this — C7
  });
  const irPut = await call(GOOD, "put", [
    "intake-request",
    "intake-2026-05-20T07-00-00Z-abc",
    irBody,
  ]);
  ck("intake-request put accepted (§4 round-trip)", irPut.status === 200 && irPut.body && irPut.body.ok === true);
  const irRec = await getRecord("intake-request", "intake-2026-05-20T07-00-00Z-abc");
  ck("intake-request round-trips with idea_text intact", !!irRec && irRec.idea_text === "let the runner pick this up tomorrow");
  ck("intake-request principal stamped PRINCIPAL_V1 (C7 — client literal overwritten)", !!irRec && irRec.principal === "brian");
  ck("intake-request preset round-trips verbatim", !!irRec && irRec.preset === "autonomous-until-stuck");
  // §0.3 — higher schema_version for intake-request is rejected (substrate binds v1).
  const irHi = await call(GOOD, "put", [
    "intake-request",
    "intake-hi",
    '{"schema_version":2,"idea_text":"x","project_ref":"y","preset":"z"}',
  ]);
  ck("intake-request schema_version 2 ⇒ rejected", irHi.status !== 200 && irHi.body && irHi.body.ok === false);

  // ── I3 (claude-tools-06i) intake-pending — narrow per-machine queue read ──
  // The daemon polls the engine for unprocessed intake-request records via the
  // `intake-pending` op. Returns a JSON ARRAY filtered to processed===false,
  // ordered lexicographically by id (timestamp-prefixed ⇒ rough FIFO across
  // taps). Hard-coded type + filter — cannot be turned into a generic listing.
  // Seed a second pending + a processed record alongside the abc record above.
  const irBody2 = JSON.stringify({
    schema_version: 1,
    id: "intake-2026-05-20T07-01-00Z-def",
    idea_text: "second pending tap",
    project_ref: "thirsty",
    preset: "collaborative-stage",
    processed: false,
    submitted_at: "2026-05-20T07:01:00Z",
  });
  await call(GOOD, "put", ["intake-request", "intake-2026-05-20T07-01-00Z-def", irBody2]);
  const irBodyDone = JSON.stringify({
    schema_version: 1,
    id: "intake-2026-05-20T07-02-00Z-ghi",
    idea_text: "already enriched",
    project_ref: "thirsty",
    preset: "autonomous-until-stuck",
    processed: true,
    submitted_at: "2026-05-20T07:02:00Z",
    enricher_bd_id: "thirsty-001",
  });
  await call(GOOD, "put", ["intake-request", "intake-2026-05-20T07-02-00Z-ghi", irBodyDone]);
  // L3 follow-up (claude-tools-t956): a terminal gave_up:true record. It stays
  // processed=false forever, so the OLD filter re-returned it every ~30s cadence
  // (monotonic queue growth). intake-pending MUST exclude it now — mirrors the
  // bash twin co__intake_pending. (gave-up records still surface on the phone via
  // the separate readIntake projection; this op is ONLY the daemon's work queue.)
  const irBodyGaveUp = JSON.stringify({
    schema_version: 1,
    id: "intake-2026-05-20T07-03-00Z-jkl",
    idea_text: "tap that gave up",
    project_ref: "thirsty",
    preset: "autonomous-until-stuck",
    processed: false,
    gave_up: true,
    gave_up_at: "2026-05-20T07:30:00Z",
    dispatch_attempts: 3,
    dispatch_state: "gave_up",
    submitted_at: "2026-05-20T07:03:00Z",
  });
  await call(GOOD, "put", ["intake-request", "intake-2026-05-20T07-03-00Z-jkl", irBodyGaveUp]);

  const irPending = await call(GOOD, "intake-pending", []);
  ck("intake-pending returns 200", irPending.status === 200);
  let irList = null;
  try {
    irList = JSON.parse(irPending.raw);
  } catch {
    irList = null;
  }
  ck("intake-pending returns a JSON array", Array.isArray(irList));
  ck("intake-pending returns exactly the 2 processed=false records (skips processed=true AND gave_up)", Array.isArray(irList) && irList.length === 2);
  ck(
    "intake-pending skips the processed=true record (ghi)",
    Array.isArray(irList) && !irList.some(r => r && r.id === "intake-2026-05-20T07-02-00Z-ghi")
  );
  ck(
    "intake-pending excludes the terminal gave_up record (jkl) — claude-tools-t956",
    Array.isArray(irList) && !irList.some(r => r && r.id === "intake-2026-05-20T07-03-00Z-jkl")
  );
  ck(
    "intake-pending is ordered by id ASC (abc before def — FIFO)",
    Array.isArray(irList) &&
      irList.length === 2 &&
      irList[0].id === "intake-2026-05-20T07-00-00Z-abc" &&
      irList[1].id === "intake-2026-05-20T07-01-00Z-def"
  );

  // Round-trip: after the daemon re-PUTs def with processed=true, the next
  // intake-pending must drop it from the queue (the I3 mark-processed loop).
  const irDefRec = JSON.parse(irBody2);
  irDefRec.processed = true;
  irDefRec.enricher_bd_id = "thirsty-002";
  irDefRec.enricher_outcome = "created";
  await call(GOOD, "put", [
    "intake-request",
    "intake-2026-05-20T07-01-00Z-def",
    JSON.stringify(irDefRec),
  ]);
  const irPending2 = await call(GOOD, "intake-pending", []);
  const irList2 = (() => {
    try {
      return JSON.parse(irPending2.raw);
    } catch {
      return null;
    }
  })();
  ck("intake-pending after mark-processed re-put drops the record", Array.isArray(irList2) && irList2.length === 1);
  ck(
    "remaining pending is the still-unprocessed abc record",
    Array.isArray(irList2) && irList2.length === 1 && irList2[0].id === "intake-2026-05-20T07-00-00Z-abc"
  );

  // eslint-disable-next-line no-console
  console.log(`\n══ CF.1 differential (vs coordinator.sh): PASS=${PASS} FAIL=${FAIL} ══`);
  if (FAIL > 0) {
    // eslint-disable-next-line no-console
    console.log("FAILED:\n  - " + fails.join("\n  - "));
  }
  expect(FAIL, `differential clauses failed: ${fails.join("; ")}`).toBe(0);
});
