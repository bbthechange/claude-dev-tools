// H1 (claude-tools-uxvh1) — DESIGN H (design/blueprint.md §2) the `blueprint`
// §4 record + its two ops `blueprint-put` / `blueprint-get`.
//
// This is the engine side of Track H (the Blueprint — the living design+map of
// a workspace). UNLIKE the transient sibling modules (gate-meta/relay/activity/
// agent-action), a Blueprint IS a §4 record (UX-V2-ARCHITECTURE A.2): it is
// owned, addressable by (type,id), versioned, and it appears in the projection
// (`blueprint_meta`, H3) + a §4.3 Notification body (the Flow-F FYI, H5). So it
// goes through the FULL §4 machinery — `co._writeRecord` (the ONE gated write
// path) → `validateRecord` (schema.js, §0.3 integer-≤-bound gate) → §9.1
// principal-stamp — exactly like cf/src/lease.js (the smallest clean §4-record
// template). `blueprint` is REGISTERED in schema.js SCHEMA_VERSIONS (= 1) and
// reuses the shared `records` table; this module adds NO new table (the
// deploy-path migration 0012_blueprint.sql is records-reuse, no DDL of its own).
//
// ── THE LOAD-BEARING SEAM: sectioned read-merge-write (blueprint.md §2.3) ────
// A §4 write is whole-record `INSERT OR REPLACE`. The Blueprint has two writers
// that must NEVER overwrite each other's layer: the updater hat writes only
// `derived` (+ appends `conflicts[]`); the GUI writes only `customization`. If
// either POSTed a whole record, last-write-wins would silently erase the other
// layer (the must-protect #3 clobber, principle 9). So `blueprint-put` is
// SECTIONED: it takes a `section` ∈ {derived, customization, narrative} (plus a
// `conflicts-append` mode) and a `body`, then — INSIDE the DO's single-threaded
// `co._serialize` — READs the current record, replaces ONLY that one section,
// and writes the whole merged record back through `_writeRecord`. Because the
// singleton DO serialises, a racing `derived` write and `customization` write
// BOTH land, each merging over the other's last value; neither clobbers the
// other's section. This is the SAME read-modify-write-in-_serialize pattern
// cf/src/gate-meta.js uses to preserve `set_at`, and the SAME `_writeRecord`
// composition cf/src/lease.js uses for grant/renew (the AD1 payoff: the runtime
// IS the critical section — no hand-rolled lock).
//
// "Read-only hat" ≠ "no engine writes" (blueprint.md §2.4): the updater is a
// tree-read-only aux agent, but `blueprint-put` is a legitimate aux action — it
// writes the ENGINE, never the git tree (exactly as the enricher writes beads).
//
// THE §9.1 chokepoint (the Worker, CF.1) has ALREADY authenticated + threaded
// the resolved `principal` — there is NO second auth path here (C4); a no-token
// / invalid-token op is rejected 401 at the Worker BEFORE this module, so it
// writes NOTHING. `_writeRecord` OVERWRITES `obj.principal` with the resolved
// principal (C7) — the `updated_by` field below is a SEPARATE, human-facing
// input ("agent:blueprint-update" | "you"), NOT the principal (the §2.3 owner-
// is-an-input precedent from gate-meta.js).
//
// ANTI-DRIFT: binds DESIGN H (design/blueprint.md §2) + FROZEN
// UX-V2-ARCHITECTURE.md A.2 (storage class) / B.2 (the record body) / A.1 (the
// add-an-op checklist) / B.4 (tolerance: a missing blueprint reads as `null`,
// the facet's honest empty state — never a throw). A.4 names (the op spelling,
// the section names, the `conflicts-append` mode) are pre-ship conventions; a
// contract change ⇒ amend the spine doc explicitly, NEVER diverge silently.

// The H1 op surface. Kept OUT of CF.1's CAPABILITIES (the four §2 lines stay
// exactly four — the same anti-drift discipline every sibling module documents).
// Dispatched by a guard in coordinator.js fetch() BEFORE the substrate switch
// (which stays byte-stable). Both cross the §2.3 authed channel behind the ONE
// §9.1 chokepoint (no second auth path — C4).
export const BLUEPRINT_OPS = new Set([
  "blueprint-put", // §2.2 sectioned read-merge-write (one envelope {project_ref,section,body,updated_by})
  "blueprint-get", // §2.2 read the (blueprint, project_ref) body; missing ⇒ null
]);

// The §2.2 section enum. `derived` | `customization` | `narrative` REPLACE that
// one layer; `conflicts-append` is its OWN mode (§2.3) — it PUSHES onto
// `conflicts[]` rather than replacing it, so the updater can record a fresh
// orphan without dropping prior un-acknowledged FYIs.
const SECTION_REPLACE = new Set(["derived", "customization", "narrative"]);
const CONFLICTS_APPEND = "conflicts-append";

// An RFC-3339 UTC …Z stamp, trailing-millis trimmed (the gate-meta.js / relay.js
// `nowZ` precedent) — used for updated_at on every write.
function nowZ() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

function isPlainObject(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

// A fresh, schema-valid empty Blueprint (blueprint.md §2.3 freshEmptyBlueprint):
// the very first `blueprint-put` for a workspace has no prior record to merge
// over, so we seed a v1 skeleton with empty layers. `schema_version: 1` is
// MANDATORY (validateRecord rejects a record without an integer schema_version
// bound to v1). Both `derived` and `customization` carry their full sub-shape
// (B.2 / §3 / §5.1) so a section-only write never leaves a half-formed layer.
function freshEmptyBlueprint(projectRef) {
  return {
    schema_version: 1,
    project_ref: projectRef,
    derived: { nodes: [], edges: [], apis: [] },
    customization: { renames: {}, regroups: {}, pins: [], hidden: [], splits: [], merges: [] },
    narrative: { tldr: "", sections: [] },
    conflicts: [],
    updated_at: null, // stamped on every write
    updated_by: null,
  };
}

// Read the current (blueprint, project_ref) record body from the shared
// `records` table, or null if absent / corrupt. Mirrors the lease.js direct
// SELECT (a §4 record read), NOT a generic surface: hard-coded type `blueprint`.
async function readBlueprint(co, projectRef) {
  const row = await co.db
    .prepare("SELECT json FROM records WHERE type = 'blueprint' AND id = ?")
    .bind(projectRef)
    .first();
  if (!row) return null;
  try {
    const o = JSON.parse(row.json);
    return isPlainObject(o) ? o : null;
  } catch {
    return null; // corrupt prior ⇒ treated as absent (graceful degrade, B.4)
  }
}

// ── blueprint-put <envelope_json> — §2.2 sectioned read-merge-write ──────────
// The envelope is {project_ref, section, body, updated_by}. The write gate (the
// single refusal point — conformance at WRITE, B.4):
//   1. missing arg                                          ⇒ rc 2
//   2. invalid JSON / not an object                         ⇒ rc 3
//   3. `project_ref` not a safe §4 id                       ⇒ rc 3
//   4. `section` ∉ {derived,customization,narrative,conflicts-append} ⇒ rc 3
//   5. body wrong shape for the section                     ⇒ rc 3
//        • replace sections: body MUST be a JSON object
//        • conflicts-append: body MUST be a JSON object (one conflict entry)
//   6. otherwise ⇒ read-merge-write the whole record, rc 0
// Runs INSIDE co._serialize so the read + the write never interleave (AD1) —
// the never-clobber guarantee. The whole merged record passes `validateRecord`
// + the §9.1 stamp inside `_writeRecord` (a propagated reject is rc 3).
async function blueprintPut(co, principal, jsonStr) {
  if (jsonStr === undefined || jsonStr === null || String(jsonStr).length === 0) {
    return { rc: 2 }; // co: blueprint-put needs <envelope_json>
  }
  let env;
  try {
    env = JSON.parse(jsonStr);
  } catch {
    return { rc: 3 }; // not JSON — reject, NOTHING written
  }
  if (!isPlainObject(env)) return { rc: 3 };

  const projectRef = typeof env.project_ref === "string" ? env.project_ref : "";
  if (!projectRef || !safeIdLocal(projectRef)) {
    return { rc: 3 }; // project_ref missing / not a safe §4 id
  }

  const section = typeof env.section === "string" ? env.section : "";
  const isReplace = SECTION_REPLACE.has(section);
  const isAppend = section === CONFLICTS_APPEND;
  if (!isReplace && !isAppend) {
    return { rc: 3 }; // unknown section
  }

  // body must be a JSON object for both modes (a replace layer is an object; a
  // single conflict entry is an object). We reject an array / scalar / null.
  if (!isPlainObject(env.body)) {
    return { rc: 3 }; // body wrong shape for the section
  }

  const updatedBy = typeof env.updated_by === "string" ? env.updated_by : null;

  // read-merge-write — the §2.3 critical section (runs inside co._serialize).
  const cur = (await readBlueprint(co, projectRef)) || freshEmptyBlueprint(projectRef);
  if (isReplace) {
    cur[section] = env.body; // derived | customization | narrative
  } else {
    // conflicts-append: push, never replace (§2.3) — so a fresh orphan is
    // recorded without dropping prior un-acknowledged FYIs.
    const prior = Array.isArray(cur.conflicts) ? cur.conflicts : [];
    cur.conflicts = prior.concat([env.body]);
  }
  // Always re-assert the §4 invariants so the merged record passes the gate
  // regardless of what a prior (or fresh) record carried.
  cur.schema_version = 1;
  cur.project_ref = projectRef;
  cur.updated_at = nowZ();
  cur.updated_by = updatedBy;

  const w = await co._writeRecord(principal, "blueprint", projectRef, cur);
  if (!w.ok) return { rc: 3, code: w.code, msg: w.msg }; // gate reject ⇒ NOTHING written
  return { rc: 0, project_ref: projectRef };
}

// The §4 store-owner id hygiene, mirrored locally so blueprint-put rejects an
// unsafe project_ref at the FIRST gate (before building a fresh skeleton),
// identical to schema.js safeKey (which _writeRecord re-applies authoritatively).
function safeIdLocal(k) {
  if (typeof k !== "string" || k.length === 0) return false;
  if (k.includes("..")) return false;
  return /^[A-Za-z0-9._-]+$/.test(k);
}

// ── blueprint-get <project_ref> — §2.2 read ─────────────────────────────────
// Pure read ⇒ NO serialize (the gate-meta-get / opGet pure-op short-circuit).
// Returns the stored §4 record body VERBATIM (the B.2 shape, the opGet
// convention — extra fields like the stamped `principal` are tolerated by the
// renderer, B.4), or `null` when there is no Blueprint yet (NEVER a throw — the
// facet renders an honest "no Blueprint yet, request one" empty state, B.4). An
// absent / unsafe / unknown project_ref is identically "reachable, just empty"
// ⇒ null (the opGet "no type gate on read" posture).
async function blueprintGet(co, projectRefArg) {
  const projectRef = typeof projectRefArg === "string" ? projectRefArg : "";
  if (!projectRef) return { found: false };
  const row = await co.db
    .prepare("SELECT json FROM records WHERE type = 'blueprint' AND id = ?")
    .bind(projectRef)
    .first();
  if (!row) return { found: false };
  return { found: true, json: row.json };
}

function jsonRes(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}
function rawJsonRes(jsonStr, status = 200) {
  return new Response(jsonStr, {
    status,
    headers: { "content-type": "application/json" },
  });
}

// ── BLUEPRINT_OPS dispatch ───────────────────────────────────────────────────
// blueprint-put is a read-merge-write ⇒ runs INSIDE co._serialize so the
// singleton single-threaded DO processes one section write critical section at
// a time (the never-clobber guarantee, §2.3). blueprint-get is a pure read ⇒
// NO serialize.
//
// Response convention:
//   blueprint-put → rc 0 ⇒ {ok:true, project_ref}; reject ⇒ 422 {ok:false,...}
//                   (empty/whole-record write — NOTHING written on reject).
//   blueprint-get → 200 with the stored body VERBATIM, or 200 `null` when
//                   there is no Blueprint yet (the missing ⇒ null contract).
export async function handleBlueprintOp(co, op, args, principal) {
  const a = args || [];

  if (op === "blueprint-put") {
    const r = await co._serialize(() => blueprintPut(co, principal, a[0]));
    if (r.rc === 0) return jsonRes({ ok: true, project_ref: r.project_ref }, 200);
    // rc 2 (missing arg) and rc 3 (bad body / gate reject) both ⇒ 422, NOTHING
    // written (the conformance-at-write refusal — the agent gets a hard failure,
    // never a false-success the facet would wall).
    return jsonRes(
      { ok: false, code: r.code || "reject", error: r.msg || "co: blueprint-put reject — bad envelope / section / body (nothing written)" },
      422
    );
  }

  if (op === "blueprint-get") {
    const r = await blueprintGet(co, a[0]);
    if (!r.found) return jsonRes(null, 200); // missing ⇒ null (the B.4 empty state)
    return rawJsonRes(r.json, 200); // the stored body verbatim
  }

  return jsonRes({ ok: false, error: `co: unknown blueprint op '${op}'` }, 400);
}
