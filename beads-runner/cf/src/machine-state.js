// C12 (claude-tools-zdxd.3) — MACHINE-STATE.md v1 (D2) engine ingest.
//
// This is the engine side of the D2 telemetry channel: a §1.1-style upward
// per-machine report carrying the human-facing 5h/7d numbers the Board
// renders. It is structurally modeled on cf/src/capacity.js — same SEPARATE
// namespace shape, same §0.3 strictness at ingest, same §9.1 principal stamp,
// same §2.3 _serialize-wrapped read-modify-write, same response convention.
//
// CRITICAL BOUNDARY (the substrate-handoff discipline, kept verbatim from
// capacity.js): a machine_state report is a §1.1 UP report, NOT a §4 store
// record. It lives in a SEPARATE `machine_state_reports` namespace (the
// §10.3-forensic / dossier-dedup / capacity_reports "NOT a §4 record"
// precedent). `machine_state` is ABSENT from the schema.js §4 registry and
// MUST stay absent — so `get machine_state <id>` is "reachable, just empty"
// and `put machine_state ...` is `unknown_type`, structurally proving "never
// a §4 record / never in the §4.5 projection / never in a §4.3 Notification
// body". The §1.4 ingest re-enforces §0.3 (unknown HIGHER schema_version
// REJECTED, never best-effort) + the §1.1 closed shape EXACTLY as the §4
// store does, and §9.1 stamps the RESOLVED principal over whatever literal
// the report carried (C7).
//
// THE AD1 PAYOFF (same as CF.4): the ingest is a read-prev-observed_at →
// compare → write read-modify-write. It runs INSIDE `co._serialize`, the
// singleton single-threaded Coordinator DO tail, so a racing straggler can
// never interleave between the observed_at compare and the write. No
// hand-rolled latch (the substrate-handoff rule: the runtime IS the critical
// section — AD1). `get-machine-states` is a pure read-only aggregation ⇒ no
// serialize (the forensic-audit / notification / ask-capacity pure-op
// short-circuit precedent).
//
// SEPARATE FROM §6.3 CAPACITY (the §0.C Path B rationale): the gate continues
// to run on the §1.1 capacity report's coarse {ok,over} verdict, untouched;
// the Board reads THIS channel for the per-machine pcts. Two channels, two
// cadences, one freeze each — see MACHINE-STATE.md §0.C. A future maintainer
// who tries to "unify" the two by routing the gate through telemetry is
// reintroducing the failure mode this separation prevents.
//
// ANTI-DRIFT: binds FROZEN MACHINE-STATE.md v1 (D2).
// Oracle = MACHINE-STATE.md + test-fixtures/machine-state-v1.json +
// cf/test/machine-state.spec.js.
// A D2 gap ⇒ reopen D2, bump+re-freeze — NEVER diverge, NEVER edit
// MACHINE-STATE.md silently.

// safeKey is CF.1's ONE store-owner input-hygiene predicate (schema.js). Reuse
// it (never a duplicated predicate that could drift) — the bash oracle for the
// parallel capacity channel gates every runner_id through the SAME safeKey
// the §4 store uses (capacity.js precedent).
import { safeKey } from "./schema.js";

// The C12 op surface. Kept OUT of CF.1's CAPABILITIES (the four §2 lines stay
// exactly four — same anti-drift discipline capacity.js documents). These
// cross the §2.3 authed channel like every other op, behind the ONE §9.1
// chokepoint (no second auth path — C4).
export const MACHINE_STATE_OPS = new Set([
  "report-machine-state", // §1.1 ingest — D2 wire-format → machine_state_reports
  "get-machine-states", // pure read aggregation — returns {machines:[...]}
]);

// ── lazy + idempotent DDL — the SEPARATE D2 namespace ───────────────────────
// Mirrors CF.4's ensureCapacitySchema discipline (CREATE TABLE IF NOT EXISTS,
// lazy, per-instance memoised) so machine-state is locally-runnable with NO
// account and NO manual migrate step. The canonical migration ships in
// migrations/0006_machine_state.sql for the deploy path. `machine_state_reports`
// is a SEPARATE namespace from `records`/`timers`/`work_plane_ops`/`forensic_*`/
// `capacity_reports` — NOT a §4 record. One row per `runner_id` (the §2.1
// PRIMARY KEY): one machine, one strip (§0.B "NOT per-workspace").
function ensureMachineStateSchema(co) {
  if (!co._machineStateSchemaReady) {
    co._machineStateSchemaReady = co.db
      .prepare(
        "CREATE TABLE IF NOT EXISTS machine_state_reports (runner_id TEXT NOT NULL PRIMARY KEY, observed_at TEXT NOT NULL, json TEXT NOT NULL)"
      )
      .run();
  }
  return co._machineStateSchemaReady;
}

// A pct value is a finite number in [0, 200] (§1.1; out-of-range ⇒ REJECT).
// Floats are OK (the Anthropic API may return one); a string/bool/null is not.
function pctOk(v) {
  return typeof v === "number" && Number.isFinite(v) && v >= 0 && v <= 200;
}

// An integer in [lo, hi]. Used for spare_ramp_today + threshold_in_effect
// (both §1.1 require integer in [0, 100]).
function intInRange(v, lo, hi) {
  return (
    typeof v === "number" &&
    Number.isFinite(v) &&
    Math.floor(v) === v &&
    v >= lo &&
    v <= hi
  );
}

// ── §1.1 INGEST (report-machine-state) — §1.4 rejection chain VERBATIM ──────
// Enforces, in the SAME order as MACHINE-STATE.md §1.4 (so an earlier-gate
// rejection wins identically — the capacity.js precedent):
//   1. invalid JSON / not an object / report !== "machine_state" ⇒ rc 3
//   2. schema_version not an integer ⇒ rc 3
//   3. schema_version > 1 (unknown HIGHER) ⇒ rc 3 (§0.3 — never best-effort)
//   4. schema_version !== 1 ⇒ rc 3
//   5. runner_id missing / non-string / unsafeKey ⇒ rc 3
//   6. observed_at missing / non-string ⇒ rc 3
//   7. any required §1.1 numeric field out of contract ⇒ rc 3
//   8. otherwise ⇒ stamp principal (§9.1), store, rc 0
// The LATEST report per runner_id wins: a stored record with a strictly-newer
// observed_at is NOT clobbered by an older straggler (RFC-3339 UTC strings
// sort lexicographically — the bash capacity.js convention). Returns
// { rc:0 } on a write OR kept-newer-stored skip, { rc:3 } on any rejection
// (NOTHING written), { rc:2 } on a missing arg (the bash rc-2 analogue).
async function machineStateReport(co, principal, jsonStr) {
  if (jsonStr === undefined || jsonStr === null || String(jsonStr).length === 0) {
    return { rc: 2 }; // co: report-machine-state needs <report_json>
  }
  let parsed;
  try {
    parsed = JSON.parse(jsonStr);
  } catch {
    return { rc: 3 }; // §1.4(1) — invalid JSON
  }
  if (
    parsed === null ||
    typeof parsed !== "object" ||
    Array.isArray(parsed) ||
    parsed.report !== "machine_state"
  ) {
    return { rc: 3 }; // §1.4(1) — not an object / report!="machine_state"
  }
  const sv = parsed.schema_version;
  const isInt = typeof sv === "number" && Number.isFinite(sv) && Math.floor(sv) === sv;
  if (!isInt) {
    return { rc: 3 }; // §1.4(2) — schema_version not an integer
  }
  if (sv > 1) {
    return { rc: 3 }; // §1.4(3) — unknown HIGHER version (§0.3 reject)
  }
  if (sv !== 1) {
    return { rc: 3 }; // §1.4(4) — unsupported version (binds v1 only)
  }
  const rid = parsed.runner_id;
  if (typeof rid !== "string" || rid.length === 0 || !safeKey(rid)) {
    return { rc: 3 }; // §1.4(5) — runner_id missing/non-string/unsafeKey
  }
  const obs = parsed.observed_at;
  if (typeof obs !== "string" || obs.length === 0) {
    return { rc: 3 }; // §1.4(6) — observed_at missing/non-string
  }
  // §1.4(7) — the closed §1.1 numeric shape. Each required numeric field
  // must be present, a finite number, and in its contract range. The
  // out-of-range arms (pct_5h=-1, threshold_in_effect=200, etc.) are the
  // §1.4 reject path that writes NOTHING.
  if (!pctOk(parsed.pct_5h)) {
    return { rc: 3 }; // §1.4(7) — pct_5h missing / wrong type / out of [0,200]
  }
  if (!pctOk(parsed.pct_7d)) {
    return { rc: 3 }; // §1.4(7) — pct_7d
  }
  if (!intInRange(parsed.spare_ramp_today, 0, 100)) {
    return { rc: 3 }; // §1.4(7) — spare_ramp_today
  }
  if (!intInRange(parsed.threshold_in_effect, 0, 100)) {
    return { rc: 3 }; // §1.4(7) — threshold_in_effect
  }
  // §9.1 stamp: the RESOLVED principal, OVERWRITING whatever literal the
  // report put. The fixture deliberately carries "PRINCIPAL_V1" so a
  // round-trip test proves the stamp ran.
  parsed.principal = principal;
  // Latest-wins per runner_id: keep the report with the newer observed_at.
  // Only an older straggler (both non-empty and strictly older) is dropped
  // — the exact bash `[[ -n "$pobs" && -n "$nobs" && "$nobs" < "$pobs" ]]`
  // condition from capacity.js.
  const prev = await co.db
    .prepare("SELECT observed_at FROM machine_state_reports WHERE runner_id = ?")
    .bind(rid)
    .first();
  if (prev) {
    const pobs = typeof prev.observed_at === "string" ? prev.observed_at : "";
    if (pobs.length > 0 && obs.length > 0 && obs < pobs) {
      return { rc: 0 }; // older straggler ⇒ keep the newer stored report
    }
  }
  await co.db
    .prepare(
      "INSERT OR REPLACE INTO machine_state_reports (runner_id, observed_at, json) VALUES (?, ?, ?)"
    )
    .bind(rid, obs, JSON.stringify(parsed))
    .run();
  return { rc: 0 };
}

// get-machine-states — pure read aggregation, returns
//   { machines: [ <stamped record>, ... ] }
// ordered by runner_id (the §2.1 PRIMARY KEY). Pure read ⇒ no serialize
// (the forensic-audit / notification / ask-capacity pure-op short-circuit
// precedent). Used directly for debugging; the §3.A snapshot projection
// (C3) is the production consumer.
async function getMachineStates(co) {
  const { results } = await co.db
    .prepare("SELECT json FROM machine_state_reports ORDER BY runner_id ASC")
    .all();
  const machines = [];
  for (const row of results || []) {
    try {
      machines.push(JSON.parse(row.json));
    } catch {
      // skip a corrupt row; should not happen given the strict ingest gate
    }
  }
  return { machines };
}

// ── MACHINE_STATE_OPS dispatch ──────────────────────────────────────────────
// report-machine-state is a latest-wins read-modify-write ⇒ runs INSIDE
// co._serialize so the singleton single-threaded DO processes one ingest
// critical section at a time (AD1: the observed_at compare + the write never
// interleave with a racing straggler for the same runner_id).
// get-machine-states is a pure read ⇒ NO serialize.
//
// The §9.1 chokepoint (the Worker, CF.1) has ALREADY authenticated + threaded
// the resolved `principal` — there is NO second auth path here (C4); a
// no-token / invalid-token op is rejected 401 at the Worker BEFORE this
// module, so it writes NOTHING.
//
// Response convention (1:1 with report-capacity):
//   report-machine-state → rc 0 ⇒ text("", 200); reject ⇒ text("", 422)
//   get-machine-states   → JSON 200 { machines: [...] }
function textRes(s, status = 200) {
  return new Response(s, { status, headers: { "content-type": "text/plain" } });
}
function jsonRes(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export async function handleMachineStateOp(co, op, args, principal) {
  const a = args || [];
  await ensureMachineStateSchema(co);

  if (op === "report-machine-state") {
    const r = await co._serialize(() => machineStateReport(co, principal, a[0]));
    if (r.rc === 0) return textRes("", 200);
    return textRes("", 422); // reject ⇒ empty body, NOTHING written
  }

  if (op === "get-machine-states") {
    const r = await getMachineStates(co);
    return jsonRes(r, 200);
  }

  return jsonRes({ ok: false, error: `co: unknown machine-state op '${op}'` }, 400);
}
