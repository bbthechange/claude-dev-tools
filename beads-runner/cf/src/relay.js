// K2 (claude-tools-uxvk2) — DESIGN K §3: the cross-workspace `relay_log`
// transient + the `relay-log-append`/`relay-log-tail` ops, realized on the
// CF.1 substrate.
//
// This is the engine sink behind Flow K (UX-DESIGN-V2 §8). The `ask-workspace`
// MCP server (K1) spawns a read-only responder in a sibling workspace, and on
// every exchange appends ONE row here — `outcome:"resolved"` for an answer,
// `outcome:"escalated"` (with the just-created Flow B dossier id) for the 20%
// that becomes a human decision. The `/cross-ws` view (K5) reads it back via
// `relay-log-tail` (the B.3 projection) as the auditable trail behind the
// batched FYIs (K3). It is structurally modeled on cf/src/forensic.js's
// `forensic_audit` (the append-only, INSERT-only, `ORDER BY id` precedent) and
// follows the smallest-transient-module shape of capacity.js/machine-state.js.
//
// CRITICAL BOUNDARY (the substrate-handoff discipline, kept verbatim from the
// capacity/machine-state/forensic siblings — Contract A.2): the relay log is an
// append-only audit with NO `(type,id)` owner, NOT a §4 store record. It lives
// in a SEPARATE `relay_log` namespace (the §10.3-forensic / capacity_reports /
// machine_state_reports "NOT a §4 record" precedent). `relay_log` is ABSENT
// from the schema.js §4 registry and MUST stay absent — so `get relay_log <id>`
// is `unknown_type` and a relay row is structurally absent from the §4.5
// projection and §4.3 Notification bodies (it must NEVER page anyone by itself
// — the batched FYI is K3's job). It bypasses `_writeRecord`/`records`/
// `validateRecord`; the §9.1 chokepoint (the Worker, CF.1) has ALREADY
// authenticated + threaded the resolved `principal` (no second auth path — C4).
//
// THE AD1 PAYOFF (same as CF.4/CF.5/the C12 D2 channel): every store-touching
// op runs INSIDE `co._serialize`, the singleton single-threaded Coordinator DO
// tail, so an append never interleaves with a racing append/read. No
// hand-rolled latch (the substrate-handoff rule: the runtime IS the critical
// section — AD1). `relay-log-tail` is a pure read-only projection ⇒ NO serialize
// (the forensic-audit / get-machine-states / ask-capacity pure-op short-circuit
// precedent).
//
// WHY TYPED COLUMNS (vs forensic_audit's single opaque `line`): `relay-log-tail`
// must FILTER by `project_ref` (B.3) — a JSON-blob line would force a JS scan.
// One INSERT captures the final outcome because the dossier (on escalate) is
// created BEFORE the responder returns (DESIGN K §5.2), so the log never needs
// a mutating second write (append-only holds — A.2).
//
// ANTI-DRIFT: binds FROZEN UX-V2-ARCHITECTURE.md A.2 (storage class) + B.3
// (the `relay-log-tail` projection shape) + DESIGN K §3 (design of record).
// `relay_log` is deliberately NOT a §4 type; the projection shape is B.3
// VERBATIM. A contract gap ⇒ amend the spine doc explicitly (its footer
// protocol) — NEVER diverge silently.

// safeKey is CF.1's ONE store-owner input-hygiene predicate (schema.js). Reuse
// it (never a duplicated predicate that could drift) — the same co__safe_key the
// §4 store and every transient sibling (capacity/forensic/machine-state) gate
// their keys through. Here it guards the stable `exchange_id` (the B.3 `id`) and
// the `project_ref`/`to_ws` routing keys at append.
import { safeKey } from "./schema.js";

// The K2 op surface. Kept OUT of CF.1's CAPABILITIES (the four §2 lines stay
// exactly four — the same anti-drift discipline capacity.js/machine-state.js
// document). Both cross the §2.3 authed channel behind the ONE §9.1 chokepoint
// (no second auth path — C4).
export const RELAY_OPS = new Set([
  "relay-log-append", // DESIGN K §3.3 — INSERT one exchange row (append-only)
  "relay-log-tail", // DESIGN K §3.3 / Contract B.3 — {exchanges:[...]} projection
]);

// The B.3 `outcome` is a CLOSED enum: exactly {resolved, escalated}. An unknown
// value is rejected at append (it is a contract value, not free text) — never
// silently stored. Mirrors capacity.js capacityClassOk / the §6.3 closed enum.
function outcomeOk(o) {
  return o === "resolved" || o === "escalated";
}

// ── lazy + idempotent DDL — the SEPARATE relay_log namespace ────────────────
// Mirrors CF.4/CF.5/C12's ensure*Schema discipline (CREATE TABLE IF NOT EXISTS,
// lazy, per-instance memoised) so K2 is locally-runnable with NO account and NO
// manual migrate step. The canonical migration ships in
// migrations/0009_relay_log.sql for the deploy path. `relay_log` is a SEPARATE
// namespace from `records`/`timers`/`capacity_reports`/`machine_state_reports`/
// `forensic_*`/the stuck-routing tables — NOT a §4 record. Typed columns (not a
// single opaque `line`) so `relay-log-tail`'s B.3 `project_ref` filter is a
// clean indexed read; `id INTEGER PRIMARY KEY AUTOINCREMENT` is the append-only
// recency order (forensic_audit precedent).
function ensureRelaySchema(co) {
  if (!co._relaySchemaReady) {
    co._relaySchemaReady = co.db
      .prepare(
        "CREATE TABLE IF NOT EXISTS relay_log (" +
          "id INTEGER PRIMARY KEY AUTOINCREMENT, " +
          "exchange_id TEXT NOT NULL, " + // stable id (hash of from|to|bead|seq) — the B.3 `id`
          "project_ref TEXT, " + // tail filter key (the from_ws workspace)
          "from_ws TEXT, to_ws TEXT, " +
          "at TEXT, " + // RFC-3339 UTC …Z (§0.4)
          "question TEXT, answer TEXT, " +
          "outcome TEXT, " + // B.3 closed enum: "resolved" | "escalated"
          "dossier_ref TEXT" + // escalated → the Flow B dossier id; else NULL
          ")"
      )
      .run();
  }
  return co._relaySchemaReady;
}

// A string field, coerced to "" when absent/non-string (tolerant display
// fields, B.4-flavoured): from_ws/to_ws/question/answer are stored verbatim and
// degrade at render, never refuse the append. The CLOSED enum (outcome) and the
// identity/routing keys (exchange_id, project_ref) ARE gated — conformance at
// write (the only refusal point), the A.2/B.4 split applied to the sink.
function strField(v) {
  return typeof v === "string" ? v : "";
}

// ── relay-log-append <exchange_json> — DESIGN K §3.3 ────────────────────────
// INSERT one row, never UPDATE/DELETE (append-only, A.2; forensic_audit
// precedent). Called by the MCP server (K1) ONCE per exchange, after the
// verdict resolves: outcome:"resolved" for an answer, outcome:"escalated" (with
// the just-created dossier_ref) for an escalation. The write gate (the single
// refusal point — B.4): valid JSON object; closed `outcome` enum; a non-empty
// safeKey `exchange_id` (the stable B.3 `id`); a present-and-unsafe project_ref
// or to_ws is rejected (routing keys, the store-owner input hygiene every
// sibling applies). Everything else is a tolerant display field. `project_ref`
// defaults to `from_ws` when absent (the tail filter is "the asking workspace").
// `at` is stamped server-side when absent (RFC-3339 UTC …Z, §0.4). Returns
// { rc:0 } on the INSERT, { rc:2 } on a missing arg, { rc:3 } on any reject
// (NOTHING written).
async function relayAppend(co, principal, jsonStr) {
  if (jsonStr === undefined || jsonStr === null || String(jsonStr).length === 0) {
    return { rc: 2 }; // co: relay-log-append needs <exchange_json>
  }
  let ex;
  try {
    ex = JSON.parse(jsonStr);
  } catch {
    return { rc: 3 }; // not a JSON exchange — reject, NOTHING written
  }
  if (ex === null || typeof ex !== "object" || Array.isArray(ex)) {
    return { rc: 3 }; // not an object — reject
  }
  // B.3 closed `outcome` enum — the contract value, never free text.
  if (!outcomeOk(ex.outcome)) {
    return { rc: 3 }; // outcome not in {resolved,escalated}
  }
  // The stable identity / B.3 `id`. Accept `exchange_id` (canonical) or `id`
  // (the B.3 field name) as an alias — the MCP server may emit either.
  const exchangeId =
    typeof ex.exchange_id === "string" && ex.exchange_id.length > 0
      ? ex.exchange_id
      : typeof ex.id === "string" && ex.id.length > 0
        ? ex.id
        : "";
  if (exchangeId.length === 0 || !safeKey(exchangeId)) {
    return { rc: 3 }; // exchange_id missing/unsafe (the stable B.3 `id`)
  }
  const fromWs = strField(ex.from_ws);
  const toWs = strField(ex.to_ws);
  // project_ref is the tail filter key (= the asking/from_ws workspace).
  // Default to from_ws when absent. A present-and-unsafe routing key is
  // rejected (store-owner input hygiene — the capacity/forensic precedent).
  const projectRef =
    typeof ex.project_ref === "string" && ex.project_ref.length > 0
      ? ex.project_ref
      : fromWs;
  if (projectRef.length > 0 && !safeKey(projectRef)) {
    return { rc: 3 }; // project_ref present-and-unsafe
  }
  if (toWs.length > 0 && !safeKey(toWs)) {
    return { rc: 3 }; // to_ws present-and-unsafe routing key
  }
  // `at`: a provided RFC-3339 UTC string wins; else stamp server now (the
  // forensic_meta created_at precedent — trailing-millis trimmed to …Z).
  const at =
    typeof ex.at === "string" && ex.at.length > 0
      ? ex.at
      : new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
  const question = strField(ex.question);
  const answer = strField(ex.answer);
  // dossier_ref: a string on escalate, NULL otherwise (B.3 "…|null"). An empty
  // string is normalised to NULL so the projection emits a clean `null`.
  const dossierRef =
    typeof ex.dossier_ref === "string" && ex.dossier_ref.length > 0
      ? ex.dossier_ref
      : null;
  await co.db
    .prepare(
      "INSERT INTO relay_log (exchange_id, project_ref, from_ws, to_ws, at, question, answer, outcome, dossier_ref) " +
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
    )
    .bind(exchangeId, projectRef, fromWs, toWs, at, question, answer, ex.outcome, dossierRef)
    .run();
  return { rc: 0 };
}

// ── relay-log-tail [project_ref] [n] — DESIGN K §3.3 / Contract B.3 ─────────
// Pure read projection ⇒ NO serialize (the forensic-audit / get-machine-states
// pure-op short-circuit). Reshapes rows to the B.3 projection VERBATIM:
//   { exchanges: [ { id, from_ws, to_ws, at, question, answer, outcome,
//                    dossier_ref } ] }
// ORDER BY id DESC (newest-first; the append-only recency order). A non-empty
// `project_ref` scopes to one workspace's outbound asks (WHERE project_ref = ?,
// a bound param — no injection); omitting it returns the cross-WS log across all
// workspaces (the global /cross-ws view, K5). A positive-integer `n` caps the
// rows (LIMIT n); absent ⇒ all (no silent cap — the forensic_audit_tail
// precedent; the B.3 `id` is the stable exchange_id, not the rowid).
async function relayTail(co, projectRefArg, nArg) {
  const filterPr =
    typeof projectRefArg === "string" && projectRefArg.length > 0 ? projectRefArg : null;
  let limit = null;
  if (nArg != null && /^[0-9]+$/.test(String(nArg))) {
    const n = Number(nArg);
    if (n > 0) limit = n;
  }
  let sql =
    "SELECT exchange_id, from_ws, to_ws, at, question, answer, outcome, dossier_ref FROM relay_log";
  const binds = [];
  if (filterPr !== null) {
    sql += " WHERE project_ref = ?";
    binds.push(filterPr);
  }
  sql += " ORDER BY id DESC";
  if (limit !== null) {
    sql += " LIMIT ?";
    binds.push(limit);
  }
  const stmt = binds.length ? co.db.prepare(sql).bind(...binds) : co.db.prepare(sql);
  const { results } = await stmt.all();
  const exchanges = [];
  for (const r of results || []) {
    exchanges.push({
      id: r.exchange_id, // B.3 `id` = the stable exchange identity
      from_ws: r.from_ws != null ? r.from_ws : "",
      to_ws: r.to_ws != null ? r.to_ws : "",
      at: r.at != null ? r.at : "",
      question: r.question != null ? r.question : "",
      answer: r.answer != null ? r.answer : "",
      outcome: r.outcome != null ? r.outcome : "",
      dossier_ref: r.dossier_ref != null && r.dossier_ref !== "" ? r.dossier_ref : null,
    });
  }
  return { exchanges };
}

// ── RELAY_OPS dispatch ───────────────────────────────────────────────────────
// relay-log-append is an append write ⇒ runs INSIDE co._serialize so the
// singleton single-threaded DO processes one append critical section at a time
// (AD1). relay-log-tail is a pure read ⇒ NO serialize. The §9.1 chokepoint (the
// Worker, CF.1) has ALREADY authenticated + threaded the resolved `principal`
// — there is NO second auth path here (C4); a no/invalid-token relay-* op is
// rejected 401 at the Worker BEFORE this module, so it writes NOTHING.
//
// Response convention (the bash rc+stdout ⇄ HTTP analogue, 1:1 with CF.4/C12):
//   relay-log-append → rc 0 ⇒ text("",200); reject ⇒ text("",422) (empty body,
//                      NOTHING written — the rc 2/3 analogue).
//   relay-log-tail   → JSON 200 { exchanges:[...] } (the B.3 projection).
function textRes(s, status = 200) {
  return new Response(s, { status, headers: { "content-type": "text/plain" } });
}
function jsonRes(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export async function handleRelayOp(co, op, args, principal) {
  const a = args || [];
  await ensureRelaySchema(co);

  if (op === "relay-log-append") {
    const r = await co._serialize(() => relayAppend(co, principal, a[0]));
    if (r.rc === 0) return textRes("", 200); // rc 0, no stdout
    return textRes("", 422); // reject ⇒ empty body, NOTHING written (rc 2/3)
  }

  if (op === "relay-log-tail") {
    const r = await relayTail(co, a[0], a[1]);
    return jsonRes(r, 200); // B.3 { exchanges:[...] }
  }

  return jsonRes({ ok: false, error: `co: unknown relay op '${op}'` }, 400);
}
