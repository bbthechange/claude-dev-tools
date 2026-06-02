// I1 (claude-tools-uxvi1) — DESIGN I §1.4 agent_activity transient ingest.
//
// This is the engine side of the Activity telemetry channel: the runner's
// writer lane (and, via I5, the daemon's read-only aux streams) classify each
// claude `--output-format stream-json` worker into the closed D.2 activity enum
// + a blunt liveness dot and report it here, latest-wins per `agent_key`. The
// projection (I2, reconcile.js workSnapshot) reads this table back and projects
// each lane DOWN to its exact B.1 shape; the Activity facet (I3) renders that.
//
// Structurally modeled on cf/src/machine-state.js — same SEPARATE namespace
// shape, same §0.3 strictness at ingest, same §9.1 principal stamp, same §2.3
// _serialize-wrapped latest-wins read-modify-write, same response convention.
//
// CRITICAL BOUNDARY (the substrate-handoff discipline, kept verbatim from
// machine-state.js / capacity.js): an agent_activity report is EPHEMERAL
// telemetry (Contract A.2 "Ephemeral telemetry, aggregation-only read",
// machine_state_reports precedent), NOT a §4 store record. It lives in a
// SEPARATE `agent_activity` namespace. `agent_activity` is ABSENT from the
// schema.js §4 registry and MUST stay absent — so it is structurally absent
// from the §4.5 projection's record path and from every §4.3 Notification body:
// activity NEVER pages anyone by itself (DESIGN I §1.4). The §1.4 ingest
// re-enforces §0.3 (unknown HIGHER schema_version REJECTED, never best-effort)
// + the D.2 closed enum EXACTLY as the §4 store does, and §9.1 stamps the
// RESOLVED principal over whatever literal the report carried.
//
// THE AD1 PAYOFF (same as machine-state.js): the ingest is a read-prev-
// observed_at → compare → write read-modify-write. It runs INSIDE
// `co._serialize`, the singleton single-threaded Coordinator DO tail, so a
// racing straggler can never interleave between the observed_at compare and the
// write. No hand-rolled latch. `get-agent-activity` is a pure read-only
// aggregation ⇒ no serialize (the machine-state / forensic-audit pure-op
// short-circuit precedent).
//
// ANTI-DRIFT: binds DESIGN I (design/activity.md §1.2/§1.4) + the FROZEN
// UX-V2-ARCHITECTURE.md Contract D.2 closed activity enum. ACTIVITY_STATES below
// is the ENGINE MIRROR of web/shared/enums.js ACTIVITY_STATE + the bash
// lib/activity-classifier.sh enum; cf/test/conformance-contract-v2.sh PART D
// asserts the three stay byte-equivalent. Extending the enum ⇒ reopen D.2,
// bump+re-freeze — NEVER diverge.

// ── agent_key input hygiene — safeKey + the ':' contract delimiter ───────────
// The §4 store's safeKey (schema.js) rejects ':' (its charset is
// [A-Za-z0-9._-]). But an agent_key is STRUCTURALLY colon-delimited by DESIGN I
// §1.4 — `writer:<runner_id>` (one per workspace) / `aux:<kind>:<dispatch_id>`
// — so this namespace owns its OWN key predicate: the SAME hygiene (non-empty,
// no ".." traversal segment, a closed charset) widened by exactly the ':'
// delimiter the contract mandates. This is the relay_log "module owns its key
// shape" precedent, not a drift from safeKey.
function agentKeyOk(k) {
  if (typeof k !== "string" || k.length === 0) return false;
  if (k.includes("..")) return false;
  return /^[A-Za-z0-9._:-]+$/.test(k);
}

// ── D.2 CLOSED enum mirror (the engine copy; PART D asserts byte-equivalence) ─
// 7 derived activity states, frozen. Order is irrelevant (PART D compares as a
// set); kept identical to web/shared/enums.js ACTIVITY_STATE for readability.
export const ACTIVITY_STATES = [
  "writing-code",
  "running-tests",
  "exploring",
  "thinking",
  "waiting-on-you",
  "rate-limited",
  "maybe-stuck",
];
const ACTIVITY_STATE_SET = new Set(ACTIVITY_STATES);
const LIVENESS_DOTS = new Set(["green", "amber", "red"]);
const LANES = new Set(["writer", "auxiliary"]);

// The I1 op surface. Kept OUT of CF.1's CAPABILITIES (the four §2 lines stay
// exactly four — same anti-drift discipline machine-state.js documents). These
// cross the §2.3 authed channel like every other op, behind the ONE §9.1
// chokepoint (no second auth path).
export const ACTIVITY_OPS = new Set([
  "agent-activity-report", // §1.4 ingest — D.2 wire-format → agent_activity (latest-wins per agent_key)
  "get-agent-activity", // pure read aggregation — returns {agents:[...]}
]);

// ── lazy + idempotent DDL — the SEPARATE Activity namespace ──────────────────
// Mirrors machine-state.js's ensureMachineStateSchema discipline (CREATE TABLE
// IF NOT EXISTS, lazy, per-instance memoised) so Activity is locally-runnable
// with NO account and NO manual migrate step. The canonical migration ships in
// migrations/0010_agent_activity.sql for the deploy path. `agent_activity` is a
// SEPARATE namespace from `records`/`timers`/`work_plane_ops`/`forensic_*`/
// `capacity_reports`/`machine_state_reports`/`relay_log` — NOT a §4 record.
// One row per `agent_key` (the latest-wins PRIMARY KEY: `writer:<runner_id>`
// is singular per workspace by construction; `aux:<kind>:<dispatch_id>` for an
// aux — DESIGN I §1.4).
function ensureActivitySchema(co) {
  if (!co._activitySchemaReady) {
    co._activitySchemaReady = co.db
      .prepare(
        "CREATE TABLE IF NOT EXISTS agent_activity (agent_key TEXT NOT NULL PRIMARY KEY, observed_at TEXT NOT NULL, json TEXT NOT NULL)"
      )
      .run();
  }
  return co._activitySchemaReady;
}

// A non-empty string.
function strOk(v) {
  return typeof v === "string" && v.length > 0;
}

// ── §1.4 INGEST (agent-activity-report) — rejection chain VERBATIM ──────────
// Enforces, in the SAME order as the machine-state.js §1.4 precedent (so an
// earlier-gate rejection wins identically):
//   1. invalid JSON / not an object / report !== "agent_activity"   ⇒ rc 3
//   2. schema_version not an integer                                 ⇒ rc 3
//   3. schema_version > 1 (unknown HIGHER)                           ⇒ rc 3 (§0.3 — never best-effort)
//   4. schema_version !== 1                                          ⇒ rc 3
//   5. agent_key missing / non-string / unsafeKey                    ⇒ rc 3
//   6. observed_at missing / non-string                             ⇒ rc 3
//   7. lane not in {writer,auxiliary}                                ⇒ rc 3
//   8. state not in the CLOSED D.2 enum                              ⇒ rc 3
//   9. state_confidence !== "derived" (D.2 — nothing semantic asserted) ⇒ rc 3
//  10. liveness_dot not in {green,amber,red}                         ⇒ rc 3
//  11. otherwise ⇒ stamp principal (§9.1), store, rc 0
// Everything ELSE in the §1.4 body (workspace, kind, bead_ref, title, stage,
// last_event_ts, seconds_in_state, current_tool, touching) is TOLERATED
// verbatim — it is debug/projection-input telemetry, not gated (the projection
// I2 reads only the B.1 subset; the wire body is a superset, DESIGN I §1.4).
// The LATEST report per agent_key wins: a stored record with a strictly-newer
// observed_at is NOT clobbered by an older straggler (RFC-3339 UTC strings sort
// lexicographically — the machine-state.js convention).
async function activityReport(co, principal, jsonStr) {
  if (jsonStr === undefined || jsonStr === null || String(jsonStr).length === 0) {
    return { rc: 2 }; // co: agent-activity-report needs <report_json>
  }
  let parsed;
  try {
    parsed = JSON.parse(jsonStr);
  } catch {
    return { rc: 3 }; // (1) — invalid JSON
  }
  if (
    parsed === null ||
    typeof parsed !== "object" ||
    Array.isArray(parsed) ||
    parsed.report !== "agent_activity"
  ) {
    return { rc: 3 }; // (1) — not an object / report!="agent_activity"
  }
  const sv = parsed.schema_version;
  const isInt = typeof sv === "number" && Number.isFinite(sv) && Math.floor(sv) === sv;
  if (!isInt) {
    return { rc: 3 }; // (2) — schema_version not an integer
  }
  if (sv > 1) {
    return { rc: 3 }; // (3) — unknown HIGHER version (§0.3 reject)
  }
  if (sv !== 1) {
    return { rc: 3 }; // (4) — unsupported version (binds v1 only)
  }
  const key = parsed.agent_key;
  if (!strOk(key) || !agentKeyOk(key)) {
    return { rc: 3 }; // (5) — agent_key missing/non-string/unsafeKey
  }
  const obs = parsed.observed_at;
  if (!strOk(obs)) {
    return { rc: 3 }; // (6) — observed_at missing/non-string
  }
  if (!LANES.has(parsed.lane)) {
    return { rc: 3 }; // (7) — lane not in {writer,auxiliary}
  }
  if (!ACTIVITY_STATE_SET.has(parsed.state)) {
    return { rc: 3 }; // (8) — state not in the closed D.2 enum
  }
  if (parsed.state_confidence !== "derived") {
    return { rc: 3 }; // (9) — D.2: every derived state is "derived", never asserted
  }
  if (!LIVENESS_DOTS.has(parsed.liveness_dot)) {
    return { rc: 3 }; // (10) — liveness_dot not in {green,amber,red}
  }
  // §9.1 stamp: the RESOLVED principal, OVERWRITING whatever literal the report
  // carried. The fixture deliberately carries "PRINCIPAL_V1" so a round-trip
  // test proves the stamp ran.
  parsed.principal = principal;
  // Latest-wins per agent_key: keep the report with the newer observed_at. Only
  // an older straggler (both non-empty and strictly older) is dropped — the
  // exact machine-state.js `obs < pobs` condition.
  const prev = await co.db
    .prepare("SELECT observed_at FROM agent_activity WHERE agent_key = ?")
    .bind(key)
    .first();
  if (prev) {
    const pobs = typeof prev.observed_at === "string" ? prev.observed_at : "";
    if (pobs.length > 0 && obs.length > 0 && obs < pobs) {
      return { rc: 0 }; // older straggler ⇒ keep the newer stored report
    }
  }
  await co.db
    .prepare(
      "INSERT OR REPLACE INTO agent_activity (agent_key, observed_at, json) VALUES (?, ?, ?)"
    )
    .bind(key, obs, JSON.stringify(parsed))
    .run();
  return { rc: 0 };
}

// get-agent-activity — pure read aggregation, returns
//   { agents: [ <stamped record>, ... ] }
// ordered by agent_key. Pure read ⇒ no serialize (the machine-state /
// forensic-audit pure-op short-circuit precedent). Used directly for debugging
// + the live-verify probe; the I2 snapshot projection is the production
// consumer.
async function getAgentActivity(co) {
  const { results } = await co.db
    .prepare("SELECT json FROM agent_activity ORDER BY agent_key ASC")
    .all();
  const agents = [];
  for (const row of results || []) {
    try {
      agents.push(JSON.parse(row.json));
    } catch {
      // skip a corrupt row; should not happen given the strict ingest gate
    }
  }
  return { agents };
}

// ── ACTIVITY_OPS dispatch ───────────────────────────────────────────────────
// agent-activity-report is a latest-wins read-modify-write ⇒ runs INSIDE
// co._serialize so the singleton single-threaded DO processes one ingest
// critical section at a time (AD1: the observed_at compare + the write never
// interleave with a racing straggler for the same agent_key).
// get-agent-activity is a pure read ⇒ NO serialize.
//
// The §9.1 chokepoint (the Worker, CF.1) has ALREADY authenticated + threaded
// the resolved `principal` — there is NO second auth path here; a no-token /
// invalid-token op is rejected 401 at the Worker BEFORE this module, so it
// writes NOTHING.
//
// Response convention (1:1 with report-machine-state):
//   agent-activity-report → rc 0 ⇒ text("", 200); reject ⇒ text("", 422)
//   get-agent-activity    → JSON 200 { agents: [...] }
function textRes(s, status = 200) {
  return new Response(s, { status, headers: { "content-type": "text/plain" } });
}
function jsonRes(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export async function handleActivityOp(co, op, args, principal) {
  const a = args || [];
  await ensureActivitySchema(co);

  if (op === "agent-activity-report") {
    const r = await co._serialize(() => activityReport(co, principal, a[0]));
    if (r.rc === 0) return textRes("", 200);
    return textRes("", 422); // reject ⇒ empty body, NOTHING written
  }

  if (op === "get-agent-activity") {
    const r = await getAgentActivity(co);
    return jsonRes(r, 200);
  }

  return jsonRes({ ok: false, error: `co: unknown activity op '${op}'` }, 400);
}
