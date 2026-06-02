// J1 (claude-tools-uxvj1) — DESIGN J §2 gate_metadata transient + gate-meta ops.
//
// This is the engine side of Track J (Gates / the unified Hold view). A bare
// `gate:<id>` bd label is the source of truth for "which beads are held by gate
// X" (gate-defer.sh's existing cohort contract). This module adds the metadata
// Brian asked for — `why`, `unblock_condition`, `owner`, `scope` — keyed to the
// bare gate id, so a single row annotates the whole cohort that carries the
// label. The projection (J2, reconcile.js workSnapshot) LEFT-joins this table
// into each project's `holds[]` array; the Gates facet (J3) renders + edits it.
//
// Structurally modeled on cf/src/machine-state.js (the design §2.1 precedent) —
// same SEPARATE namespace shape, same §0.3-style strictness at write, same §9.1
// principal chokepoint upstream, same §2.3 _serialize-wrapped read-modify-write,
// same response convention. The closest sibling for the typed-input + filterable
// read is cf/src/relay.js.
//
// CRITICAL BOUNDARY (the substrate-handoff discipline, kept verbatim from
// machine-state.js / relay.js — Contract A.2): gate_metadata is a TRANSIENT
// sibling-namespace table that ANNOTATES a beads-label. It has NO independent
// (type,id) lifecycle, is read by JOIN, and NEVER appears in a §4.3 Notification
// body. `gate_metadata` is ABSENT from the schema.js §4 SCHEMA_VERSIONS registry
// and MUST stay absent — so `put gate_metadata ...` is `unknown_type` and a
// gate row is structurally never a §4 record / never in the §4.5 projection's
// record path. It bypasses `_writeRecord`/`records`/`validateRecord`; the §9.1
// chokepoint (the Worker, CF.1) has ALREADY authenticated + threaded the
// resolved `principal` (no second auth path — C4).
//
// THE owner FIELD IS AN INPUT, NOT THE PRINCIPAL (the non-obvious bit, §2.3):
// the engine resolves a single constant principal `PRINCIPAL_V1` for EVERY
// authenticated caller (the GUI proxy and every agent share one bearer), so the
// principal cannot distinguish "you" from "agent:enricher". Therefore `owner` is
// an explicit input field on gate-meta-set — the GUI proxy passes owner:"you";
// an agent placing a gate passes owner:"agent:<hat-id>". Reversible: if a
// per-actor principal ever lands, owner can switch to principal-derived without
// changing the table.
//
// THE AD1 PAYOFF (same as machine-state.js/relay.js): gate-meta-set is a
// read-prev-set_at → preserve → upsert read-modify-write. It runs INSIDE
// `co._serialize`, the singleton single-threaded Coordinator DO tail, so a
// racing edit can never interleave between the set_at read and the write. No
// hand-rolled latch. gate-meta-get is a pure read aggregation ⇒ NO serialize
// (the machine-state / relay-log-tail pure-op short-circuit precedent).
//
// ANTI-DRIFT: binds DESIGN J (design/gates.md §2) + the FROZEN
// UX-V2-ARCHITECTURE.md Contract A.2 (storage class) + D.2 (the closed GATE_SCOPE
// enum {task,cohort}). GATE_SCOPES below is the ENGINE MIRROR of
// web/shared/enums.js GATE_SCOPE; the gate-id shape mirrors gate-defer.sh's
// `_is_valid_gate_id` (^[a-z0-9][a-z0-9-]*$) so the label and the metadata can
// never disagree on what a legal id is. A D.2 gap ⇒ reopen D.2, bump+re-freeze —
// NEVER diverge.

// The J1 op surface. Kept OUT of CF.1's CAPABILITIES (the four §2 lines stay
// exactly four — same anti-drift discipline machine-state.js/relay.js document).
// Both cross the §2.3 authed channel behind the ONE §9.1 chokepoint (no second
// auth path — C4).
export const GATE_META_OPS = new Set([
  "gate-meta-set", // §2.2 upsert — {id,why,unblock_condition,owner,scope} → gate_metadata
  "gate-meta-get", // §2.2 read — one row (id given) or all rows (omitted); the J2 bulk path
]);

// ── the legal gate id — mirrors gate-defer.sh `_is_valid_gate_id` ────────────
// lowercase letters, digits, hyphens, non-empty, must start alnum (no leading
// hyphen). This is the EXACT shape gate-defer.sh enforces on the `gate:<id>`
// label (gate-defer.sh:77-80), so the table key and the label can never disagree
// on what a legal id is. The `gate:` prefix is the label NAMESPACE; this table
// is keyed by the bare id alone (one row serves the whole cohort, §2.1).
function gateIdOk(g) {
  return typeof g === "string" && /^[a-z0-9][a-z0-9-]*$/.test(g);
}

// ── D.2 CLOSED enum mirror (the engine copy) — GATE_SCOPE {task,cohort} ──────
// Mirrors web/shared/enums.js GATE_SCOPE. A scope OUTSIDE this set is rejected
// at write (§2.2: "Reject … a scope outside {task,cohort}"); an ABSENT scope
// defaults to "task" (the single-task gate is the common case, and the closed
// D.2 enum has no null member — the projection always gets a valid value).
export const GATE_SCOPES = ["task", "cohort"];
const GATE_SCOPE_SET = new Set(GATE_SCOPES);

// ── lazy + idempotent DDL — the SEPARATE gate_metadata namespace ─────────────
// Mirrors machine-state.js's ensureMachineStateSchema discipline (CREATE TABLE
// IF NOT EXISTS, lazy, per-instance memoised) so J1 is locally-runnable with NO
// account and NO manual migrate step. The canonical migration ships in
// migrations/0008_gate_metadata.sql for the deploy path. `gate_metadata` is a
// SEPARATE namespace from `records`/`timers`/`capacity_reports`/
// `machine_state_reports`/`relay_log`/`agent_activity` — NOT a §4 record. One
// row per bare gate id (the §2.1 PRIMARY KEY). `set_at` is the FIRST placement
// (preserved across edits so "set 4d ago" stays honest); `updated_at` advances
// on every edit.
function ensureGateMetaSchema(co) {
  if (!co._gateMetaSchemaReady) {
    co._gateMetaSchemaReady = co.db
      .prepare(
        "CREATE TABLE IF NOT EXISTS gate_metadata (" +
          "gate_id TEXT NOT NULL PRIMARY KEY, " + // the <id> in gate:<id>
          "why TEXT, " + // free text (B8: "a why") — REQUIRED at write
          "unblock_condition TEXT, " + // free text or a ref (B8: "what would unblock")
          "owner TEXT, " + // "you" | "agent:<hat>" — an INPUT, not the principal (§2.3)
          "scope TEXT, " + // D.2 closed enum: "task" | "cohort"
          "set_at TEXT NOT NULL, " + // first placement (preserved across edits)
          "updated_at TEXT NOT NULL" + // last edit
          ")"
      )
      .run();
  }
  return co._gateMetaSchemaReady;
}

// A non-empty string.
function strOk(v) {
  return typeof v === "string" && v.length > 0;
}

// An RFC-3339 UTC …Z stamp, trailing-millis trimmed (the relay.js `at`
// precedent). Used for set_at/updated_at when the row is first placed / edited.
function nowZ() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

// Reshape a stored row to the D.2 Gate object the projection/facet read:
//   { id, why, unblock_condition, owner, scope, set_at, updated_at }
// `gate_id` maps to `id` (the D.2 field name). NULL columns surface as `null`
// (B.4 tolerance: an honest absence, never a throw).
function rowToGate(r) {
  return {
    id: r.gate_id,
    why: r.why != null ? r.why : null,
    unblock_condition: r.unblock_condition != null ? r.unblock_condition : null,
    owner: r.owner != null ? r.owner : null,
    scope: r.scope != null ? r.scope : null,
    set_at: r.set_at != null ? r.set_at : null,
    updated_at: r.updated_at != null ? r.updated_at : null,
  };
}

// ── gate-meta-set <meta_json> — §2.2 upsert ─────────────────────────────────
// The write gate (the single refusal point — conformance at write, B.4):
//   1. missing arg                                       ⇒ rc 2
//   2. invalid JSON / not an object                      ⇒ rc 3
//   3. `id` not the gate-defer.sh id shape               ⇒ rc 3
//   4. `why` missing / empty (B8: a Gate ALWAYS has a why)⇒ rc 3
//   5. `scope` present-and-outside {task,cohort}         ⇒ rc 3
//   6. otherwise ⇒ preserve set_at (read prev), upsert, rc 0
// `set_at` is PRESERVED on update (read the existing row; only `updated_at`
// advances) so "set 4d ago" stays honest across edits. `owner`/`unblock_condition`
// are tolerant free-text inputs (string ⇒ stored verbatim, else NULL). `scope`
// defaults to "task" when absent (§2.1 — the closed D.2 enum has no null member).
// Runs INSIDE co._serialize: the set_at read + the write never interleave (AD1).
async function gateMetaSet(co, principal, jsonStr) {
  if (jsonStr === undefined || jsonStr === null || String(jsonStr).length === 0) {
    return { rc: 2 }; // co: gate-meta-set needs <meta_json>
  }
  let m;
  try {
    m = JSON.parse(jsonStr);
  } catch {
    return { rc: 3 }; // not a JSON object — reject, NOTHING written
  }
  if (m === null || typeof m !== "object" || Array.isArray(m)) {
    return { rc: 3 }; // not an object — reject
  }
  // The gate id keys the row. Accept `id` (canonical, the D.2 Gate object field)
  // or `gate_id` (the column name) as an alias.
  const gateId =
    typeof m.id === "string" && m.id.length > 0
      ? m.id
      : typeof m.gate_id === "string" && m.gate_id.length > 0
        ? m.gate_id
        : "";
  if (!gateIdOk(gateId)) {
    return { rc: 3 }; // id missing / not ^[a-z0-9][a-z0-9-]*$ (gate-defer.sh shape)
  }
  // why is REQUIRED (B8 / the bead s6 testing note: a Gate ALWAYS carries a why,
  // so "you didn't tell me about the blocker" can never recur — D.3). Validated
  // on the TRIMMED value (a whitespace-only why is not a why) but STORED verbatim
  // below — we reject emptiness, we don't mangle the caller's text.
  if (!strOk(m.why) || m.why.trim().length === 0) {
    return { rc: 3 }; // why missing / empty / whitespace-only — rejected
  }
  // scope: present-and-invalid ⇒ reject; absent ⇒ default "task".
  let scope;
  if (m.scope === undefined || m.scope === null) {
    scope = "task";
  } else if (typeof m.scope === "string" && GATE_SCOPE_SET.has(m.scope)) {
    scope = m.scope;
  } else {
    return { rc: 3 }; // scope outside the closed D.2 enum {task,cohort}
  }
  const why = m.why;
  const unblockCondition = typeof m.unblock_condition === "string" ? m.unblock_condition : null;
  const owner = typeof m.owner === "string" ? m.owner : null;
  // Preserve set_at across edits: read the existing row's set_at; only
  // updated_at advances. A brand-new row stamps both to now.
  const prev = await co.db
    .prepare("SELECT set_at FROM gate_metadata WHERE gate_id = ?")
    .bind(gateId)
    .first();
  const now = nowZ();
  const setAt = prev && typeof prev.set_at === "string" && prev.set_at.length > 0 ? prev.set_at : now;
  await co.db
    .prepare(
      "INSERT OR REPLACE INTO gate_metadata " +
        "(gate_id, why, unblock_condition, owner, scope, set_at, updated_at) " +
        "VALUES (?, ?, ?, ?, ?, ?, ?)"
    )
    .bind(gateId, why, unblockCondition, owner, scope, setAt, now)
    .run();
  return { rc: 0, id: gateId };
}

// ── gate-meta-get [gate_id] — §2.2 read ──────────────────────────────────────
// Pure read ⇒ NO serialize (the machine-state / relay-log-tail pure-op
// short-circuit). Two shapes, keyed on whether a gate_id is supplied:
//   • gate_id given  → { gate: <Gate object>|null }   (the facet edit path;
//                       missing row ⇒ null, never a throw — §2.2)
//   • gate_id absent → { gates: [<Gate object>...] }  (the J2 projection bulk
//                       path: one read, then an in-memory map — avoids N queries)
// ORDER BY gate_id ASC for a stable bulk listing (the getMachineStates /
// getAgentActivity convention).
async function gateMetaGet(co, gateIdArg) {
  const gateId = typeof gateIdArg === "string" ? gateIdArg.trim() : "";
  if (gateId.length > 0) {
    const row = await co.db
      .prepare(
        "SELECT gate_id, why, unblock_condition, owner, scope, set_at, updated_at " +
          "FROM gate_metadata WHERE gate_id = ?"
      )
      .bind(gateId)
      .first();
    return { gate: row ? rowToGate(row) : null };
  }
  const { results } = await co.db
    .prepare(
      "SELECT gate_id, why, unblock_condition, owner, scope, set_at, updated_at " +
        "FROM gate_metadata ORDER BY gate_id ASC"
    )
    .all();
  const gates = [];
  for (const r of results || []) gates.push(rowToGate(r));
  return { gates };
}

// ── GATE_META_OPS dispatch ───────────────────────────────────────────────────
// gate-meta-set is a preserve-set_at read-modify-write ⇒ runs INSIDE
// co._serialize so the singleton single-threaded DO processes one edit critical
// section at a time (AD1: the set_at read + the write never interleave).
// gate-meta-get is a pure read ⇒ NO serialize.
//
// The §9.1 chokepoint (the Worker, CF.1) has ALREADY authenticated + threaded
// the resolved `principal` — there is NO second auth path here (C4); a no-token /
// invalid-token op is rejected 401 at the Worker BEFORE this module, so it
// writes NOTHING.
//
// Response convention (1:1 with report-machine-state / relay-log-append):
//   gate-meta-set → rc 0 ⇒ text("",200); reject ⇒ text("",422) (empty body,
//                   NOTHING written — the rc 2/3 analogue).
//   gate-meta-get → JSON 200 { gate:…|null } or { gates:[…] }.
function textRes(s, status = 200) {
  return new Response(s, { status, headers: { "content-type": "text/plain" } });
}
function jsonRes(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export async function handleGateMetaOp(co, op, args, principal) {
  const a = args || [];
  await ensureGateMetaSchema(co);

  if (op === "gate-meta-set") {
    const r = await co._serialize(() => gateMetaSet(co, principal, a[0]));
    if (r.rc === 0) return textRes("", 200);
    return textRes("", 422); // reject ⇒ empty body, NOTHING written
  }

  if (op === "gate-meta-get") {
    const r = await gateMetaGet(co, a[0]);
    return jsonRes(r, 200);
  }

  return jsonRes({ ok: false, error: `co: unknown gate-meta op '${op}'` }, 400);
}
