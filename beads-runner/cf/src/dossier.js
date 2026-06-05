// CF.6 (claude-tools-7g0.6) — the Dossier/Item logic, realized on the CF.1
// substrate. THE AD1 PAYOFF.
//
// This is the Cloudflare realization of the bash T5 trio:
//   lib/dossier.sh      (T5.1 §4.1/§4.1.1 envelope + per-Item state machine +
//                         PRIMITIVE 1 consequence_applied latch)
//   lib/dossier-gen.sh  (T5.2 §5 sole producer: body⊃items[] generation)
//   lib/consequence.sh  (T5.3 §5.3 apply + §7.4 per-Item layer + §5.2.2 route)
// and is differential-bound to lib/test-{dossier,dossier-gen,consequence}.sh.
//
// THE AD1 PAYOFF (the whole point of this child): the bash skeleton hand-rolls
// a per-dossier `mkdir` advisory lock (`do__with_dossier_lock`) so the
// read→decide→write of a per-Item op is single-writer. Here there is NO such
// advisory lock. The CF.1 singleton Coordinator DO is ONE actor; CF.6 runs
// every per-Item read→route→apply→latch→state→persist as ONE serialized
// critical section on that one actor (`co._serialize`, coordinator.js). So
// "same item response applied twice ⇒ consequence applied EXACTLY once" and
// "resolve 6 of 15, the other 9 untouched" are TRUE BY CONSTRUCTION of the
// single-threaded executor (Appendix A: one DO per dossier-Item), not a ported
// compare-and-set. The `consequence_applied` boolean is still the §4.1.1 STATE
// that flips false→true once — but its exactly-once is now structural.
//
// REALIZATION BOUNDARY (honest, non-normative — the §0.2/Appendix-A discipline
// consequence.sh documents): §7.4 legislates the LATCH (the strongly-consistent
// CONTROL plane) — delivered here under the one-actor serialized section. The
// §5.3 ConsequenceBlock targets the EVENTUAL WORK plane (beads/`bd`). A Worker
// cannot exec `bd`; the work-plane sink here is the `work_plane_ops` D1 table
// recording each `bd <args>` line verbatim — the exact analogue of the bash
// tests' PATH-injected logging `bd` fake writing $BD_LOG (same space-joined
// arg shape, same `bd-fake-N` create-id scheme). The real hosted `bd` wiring
// is a deploy-path concern, not this LOCAL-emulation child; this is a
// documented realisation choice, NOT an INTERFACE divergence (no §11 gap).
//
// MUST-NOT-TOUCH (bound by the CF.6 issue): CF.1 store internals — CF.6 binds
// the §4.1 `dossier` record type (ALREADY in the CF.1 §4 registry; CF.6 adds
// NO §4 record type) and reuses CF.1's ONE write path `_writeRecord` (§0.3
// re-enforced + §9.1 principal stamped there, never a use-site literal — C7),
// exactly as bash dossier.sh persists THROUGH `co_request put dossier`. The
// READ path (getRawDossier) replicates CF.1 `opGet`'s byte-identical typed
// SELECT on the §4.1 `dossier` record — CF.1 exposes NO parsed-read accessor
// (opGet returns a Response), so this is the read-side analogue of bash
// `co_request get dossier`, NOT a reach past the store surface; if CF.1 ever
// adds a parsed-read seam, bind it here instead. The
// dossier-level `task_ref` dedup (one fork ⇒ one Dossier) is CF.8's DISTINCT
// dossier-level key — deliberately ABSENT here (per-Item layer only). The §2.2
// fire(dossier_id) timer + S-6 poll-fallback is CF.7 (this file EXPOSES the
// idempotent `item-apply` entrypoint; it owns NO timer). Notification = CF.9.
// §5 RENDERING (Inbox HTML) = CF.10. The §9.1 chokepoint stays the ONE Worker
// step (CF.1) — no second auth path is added here (C4).
//
// ANTI-DRIFT: binds FROZEN INTERFACE.md v1 §4.1/§4.1.1/§5.1/§5.2/§5.2.1/§5.2.2/
// §5.3/§7.4 + Appendix A. The §5 sub-versions (`dossier_schema_version`,
// `cb_schema_version`) track the ONE bound source (schema.js `schemaVersion`),
// never a competing literal (§0.5). Oracle = the bash T5 trio + their tests.

import { schemaVersion, safeKey } from "./schema.js";

// ── the ONE bound schema version, READ from the CF.1 §4 registry ────────────
// §0.3/§0.5: a value with a single normative definition is never restated as a
// competing literal. The Dossier's bound version lives in CF.1's registry;
// every §5 sub-version (dossier_schema_version / cb_schema_version) tracks it.
// 1:1 with the bash `do__bound_sv` (= `co__schema_version dossier`).
export function boundSv() {
  return schemaVersion("dossier");
}

// The CF.6 op surface. Kept OUT of CF.1's CAPABILITIES (anti-drift: the
// differential asserts do_dossier/dg_generate/do_item_apply are NOT §2 lines).
export const DOSSIER_OPS = new Set([
  "dossier-put",
  "dossier-get",
  "dossier-rollup",
  "item-state-check",
  "item-set-state",
  "item-latch",
  "validate-body",
  "validate-item",
  "validate-dossier",
  "cb-applyable",
  "dossier-generate",
  "dossier-from-worker-ask",
  "item-apply",
  // L2 (claude-tools-uxvl2) — WORK→CONTROL auto-close. inbox-lifecycle §7
  // (Option 2): when a bead resolves OUTSIDE the dossier tap, the per-machine
  // daemon publishes this over the zdxd D2 channel and the engine expires /
  // applies-preserving the still-open items for that bead_ref.
  "bead-status-changed",
  // L1 follow-up (claude-tools-uxl1b) §5.6 — the two remaining Inbox verbs, as
  // DISTINCT engine ops (no verb defaults to another's payload). They adjust
  // the §4.1 attention TIER without resolving any item; see dossierSetAttention.
  "dossier-defer",   // §5.6 defer    — tier→digest   ("push out without resolution")
  "dossier-escalate", // §5.6 escalate — tier→blocking ("promote to higher-attention surface")
]);

// ── primitive shape predicates (mirror the jq type/length tests verbatim) ───
function isObj(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}
function neStr(v) {
  // §4.1 id/kind/bead_ref/created_at: "non-empty string" (NOT trimmed — the
  // bash check is `(.x|type)=="string" and (.x|length)>0`).
  return typeof v === "string" && v.length > 0;
}
function trimNE(v) {
  // §5.1/§5.2 prose tiers: the bash check trims first
  // (`(.x|gsub("^\\s+|\\s+$";""))|length>0`).
  return typeof v === "string" && v.trim().length > 0;
}
// jq `a // b`: a unless a is null/false (then b). Used for the §5.3 action
// arrays and option/recommendation fallbacks.
function orEmptyArr(v) {
  return v === null || v === undefined || v === false ? [] : v;
}
// The §0.3 schema_version primitive: a JSON *integer number* only (a string
// "1", a float, a bool is NOT an integer — exactly the in-jq type check).
function intSv(v) {
  return typeof v === "number" && Number.isFinite(v) && Number.isInteger(v) && v >= 0
    ? v
    : null;
}
function nowIso() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

const TRIGGERS = ["human_flag", "worker_stuck", "stage_gate", "proactive_checkpoint"];
const TIERS = ["blocking", "timed-fyi", "digest"];
const ITEM_STATES = ["open", "answered", "applied", "expired"];
// §5.2 CLOSED response-affordance enum (distinct from the §4.1 OPEN `kind`).
const ITEM_KINDS = [
  "approve-reject",
  "pick-option",
  "approve-recommendation",
  "freeform-edit",
  "fyi-objectable",
];

function rej(msg) {
  return { ok: false, msg };
}
const OK = { ok: true };

// ════════════════════════════════════════════════════════════════════════════
// §4.1 / §4.1.1 — ENVELOPE + per-Item RECORD validation  (port of
// dossier.sh do_dossier_validate). §0.3 is enforced HERE; `kind` is the OPEN
// C2 discriminator (present non-empty string ONLY — unknown kinds NOT
// rejected); `body` is OPAQUE (object) — its §5 shape is the generator's.
// ════════════════════════════════════════════════════════════════════════════
function validateEnvelope(o) {
  const bound = boundSv();
  if (bound === null || bound === undefined) {
    return rej("dossier: reject — 'dossier' absent from the §4 registry (store-surface contract gap)");
  }
  if (!isObj(o)) return rej("dossier: reject — not a JSON object (§4.1 envelope)");

  const sv = intSv(o.schema_version);
  if (sv === null) return rej("dossier: reject — missing integer schema_version (§4.1 'int' / §0.3)");
  if (sv > bound)
    return rej(`dossier: reject — schema_version ${sv} is an unknown higher version (bound=${bound}; §0.3 reject, never best-effort-parse)`);
  if (sv !== bound)
    return rej(`dossier: reject — schema_version ${sv} unsupported (substrate binds v${bound} only; §0.3)`);

  if (!neStr(o.id)) return rej("dossier: reject — §4.1 id: non-empty string required");
  if (!neStr(o.kind)) return rej("dossier: reject — §4.1 kind: non-empty string required (C2 open discriminator)");
  if (!(typeof o.trigger === "string" && TRIGGERS.includes(o.trigger)))
    return rej("dossier: reject — §4.1 trigger: human_flag|worker_stuck|stage_gate|proactive_checkpoint");
  if (!neStr(o.bead_ref)) return rej("dossier: reject — §4.1 bead_ref: non-empty string required");
  if (!(typeof o.tier === "string" && TIERS.includes(o.tier)))
    return rej("dossier: reject — §4.1 tier: blocking|timed-fyi|digest");
  if (!neStr(o.created_at)) return rej("dossier: reject — §4.1 created_at: RFC-3339 string required");
  if (!(Object.prototype.hasOwnProperty.call(o, "timer_fire_at") &&
        (typeof o.timer_fire_at === "string" || o.timer_fire_at === null)))
    return rej("dossier: reject — §4.1 timer_fire_at: string|null (key required)");
  if (!isObj(o.body)) return rej("dossier: reject — §4.1 body: object required (opaque here — §5 shape is the generator)");
  if (!Array.isArray(o.items))
    return rej("dossier: reject — §4.1 items[]: array required (may be empty — Flow F overview, §5.2.1)");

  // §4.1.1 per-Item RECORD fields ONLY (state · response|null ·
  // consequence_applied:bool · applied_at:ts|null) + the §0.4 per-Item key.
  for (let i = 0; i < o.items.length; i++) {
    const it = o.items[i];
    if (!isObj(it)) return rej(`dossier: reject — §4.1.1 items[${i}]: object required`);
    if (!neStr(it.id)) return rej(`dossier: reject — §4.1.1 items[${i}].id: non-empty string (§0.4 per-Item key)`);
    if (!(typeof it.state === "string" && ITEM_STATES.includes(it.state)))
      return rej(`dossier: reject — §4.1.1 items[${i}].state: open|answered|applied|expired`);
    if (!(Object.prototype.hasOwnProperty.call(it, "response") &&
          (isObj(it.response) || it.response === null)))
      return rej(`dossier: reject — §4.1.1 items[${i}].response: object|null (key required)`);
    if (typeof it.consequence_applied !== "boolean")
      return rej(`dossier: reject — §4.1.1 items[${i}].consequence_applied: boolean latch required`);
    if (!(Object.prototype.hasOwnProperty.call(it, "applied_at") &&
          (typeof it.applied_at === "string" || it.applied_at === null)))
      return rej(`dossier: reject — §4.1.1 items[${i}].applied_at: ts|null (key required)`);
  }
  // §0.4 per-Item idempotency key MUST be unique within items[].
  const seen = new Set();
  for (const it of o.items) {
    if (seen.has(it.id))
      return rej(`dossier: reject — duplicate Item id '${it.id}' within items[] (§0.4 per-Item key must be unique)`);
    seen.add(it.id);
  }
  return OK;
}

// ── DERIVED rollup — §4.1 (AD7). INFORMATIONAL, NEVER A GATE. ───────────────
// `open` while ≥1 item is non-terminal (open|answered); `resolved` when every
// item is terminal (applied|expired); a zero-item envelope is vacuously
// `resolved`. NOTHING in this file branches on it to permit/deny an Item op.
function rollup(o) {
  if (!o || !Array.isArray(o.items)) return "open";
  return o.items.some((it) => it && (it.state === "open" || it.state === "answered"))
    ? "open"
    : "resolved";
}
// Re-derive `.state` on every write AND every read — a stored rollup is never
// trusted as authoritative (it is derived, §4.1).
function stampRollup(o) {
  return { ...o, state: rollup(o) };
}

// ════════════════════════════════════════════════════════════════════════════
// §5.3 ConsequenceBlock — the FROZEN machine-applyable schema. ONE binding
// shared by the producer gate (dg__cb_applyable) and the apply gate
// (do__cb_validate) — each tier binds the frozen schema, same predicate.
// ════════════════════════════════════════════════════════════════════════════
function validateCb(cb, tag = "§5.3 ConsequenceBlock") {
  const bound = boundSv();
  if (bound === null || bound === undefined)
    return rej("dossier-gen: reject — 'dossier' absent from the §4 registry — store-surface contract gap (§0.5)");
  if (!isObj(cb)) return rej(`reject — ${tag} not a JSON object (§5.3)`);
  const sv = intSv(cb.cb_schema_version);
  if (sv === null) return rej(`reject — ${tag} missing integer cb_schema_version (§5.3 'int' / §0.3)`);
  if (sv > bound)
    return rej(`reject — ${tag} cb_schema_version ${sv} is an unknown higher version (bound=${bound}; §0.3, never best-effort-parse)`);
  if (sv !== bound)
    return rej(`reject — ${tag} cb_schema_version ${sv} unsupported (binds v${bound} only; §0.3)`);
  for (const k of ["creates", "unblocks", "labels", "status_changes"]) {
    if (!Array.isArray(orEmptyArr(cb[k])))
      return rej(`reject — ${tag} creates/unblocks/labels/status_changes must each be arrays (§5.3 machine-applyable)`);
  }
  return OK;
}

// ════════════════════════════════════════════════════════════════════════════
// §5.1 v2 (§11 Mermaid amendment): diagrams[].content MUST be Mermaid source.
// Port of dossier-gen.sh dg__is_mermaid — kept byte-for-byte equivalent so the
// hosted engine's verdict ≡ the bash oracle (epic claude-tools-8bm I1 rule).
// Byte-for-byte equivalent to dossier-gen.sh dg__is_mermaid AND
// web/inbox/inbox-view.js looksLikeMermaid: \n-split (strip trailing \r),
// ASCII space+tab ONLY (never \s — diverges on Unicode), keyword as a FULL
// token followed by ASCII sp/tab/colon OR end-of-line (no open wildcard ⇒
// no U+2028/U+2029 `.` divergence). §8bm differential-equivalence.
const MM_KW =
  "(graph|flowchart|sequenceDiagram|classDiagram|stateDiagram(-v2)?|erDiagram|journey|gantt|pie|mindmap|timeline|gitGraph|quadrantChart|requirementDiagram|C4Context|C4Container|C4Component|C4Dynamic|C4Deployment|sankey-beta|xychart-beta|block-beta|zenuml|architecture-beta|packet-beta)";
const MM_BLANK = /^[ \t]*$/, MM_FM = /^[ \t]*---[ \t]*$/, MM_CMT = /^[ \t]*%%/;
const MM_HEAD = new RegExp("^[ \\t]*" + MM_KW + "([ \\t:]|$)");
function looksLikeMermaid(s) {
  if (typeof s !== "string" || s === "") return false;
  const lines = s.split("\n");
  let inFm = false, seenFm = false;
  for (let i = 0; i < lines.length; i++) {
    const ln = lines[i].replace(/\r$/, "");
    if (MM_BLANK.test(ln)) continue;
    if (!seenFm && !inFm && MM_FM.test(ln)) { inFm = true; seenFm = true; continue; }
    if (inFm) { if (MM_FM.test(ln)) inFm = false; continue; }
    if (MM_CMT.test(ln)) continue; // %% comment / %%{init}%% directive
    return MM_HEAD.test(ln);
  }
  return false;
}

// §5.1 body — all four tiers MANDATORY (AD7)  (port of dg__validate_body)
// ════════════════════════════════════════════════════════════════════════════
function validateBody(b) {
  const bound = boundSv();
  if (bound === null || bound === undefined)
    return rej("dossier-gen: reject — 'dossier' absent from the §4 registry — store-surface contract gap (§0.5)");
  if (!isObj(b)) return rej("dossier-gen: reject — body not a JSON object (§5.1)");
  const sv = intSv(b.dossier_schema_version);
  if (sv === null) return rej("dossier-gen: reject — body missing integer dossier_schema_version (§5.1 'int' / §0.3)");
  if (sv > bound)
    return rej(`dossier-gen: reject — dossier_schema_version ${sv} is an unknown higher version (bound=${bound}; §0.3, never best-effort-parse)`);
  if (sv !== bound)
    return rej(`dossier-gen: reject — dossier_schema_version ${sv} unsupported (binds v${bound} only; §0.3)`);

  if (!trimNE(b.tldr))
    return rej("dossier-gen: reject — §5.1 tldr: non-empty string required (the skim entry point — AD7)");
  if (!(Array.isArray(b.sections) && b.sections.length > 0))
    return rej("dossier-gen: reject — §5.1 sections[]: ≥1 {heading,prose} required (an empty sections[] is the decision-singular AD7 regression — PROHIBITED)");
  if (!Array.isArray(b.diagrams))
    return rej("dossier-gen: reject — §5.1 diagrams[]: array required ([] ONLY when genuinely non-structural — AD7)");
  if (!trimNE(b.full_detail))
    return rej("dossier-gen: reject — §5.1 full_detail: non-empty stand-alone prose required (NOT optional — AD7)");

  for (let i = 0; i < b.sections.length; i++) {
    const s = b.sections[i];
    if (!(isObj(s) && trimNE(s.heading)))
      return rej(`dossier-gen: reject — §5.1 sections[${i}].heading: non-empty string`);
    if (!trimNE(s.prose))
      return rej(`dossier-gen: reject — §5.1 sections[${i}].prose: non-empty string (enough text to convey the point without full_detail)`);
  }
  for (let i = 0; i < b.diagrams.length; i++) {
    const d = b.diagrams[i];
    if (!(isObj(d) && trimNE(d.caption)))
      return rej(`dossier-gen: reject — §5.1 diagrams[${i}].caption: non-empty string`);
    if (!trimNE(d.content))
      return rej(`dossier-gen: reject — §5.1 diagrams[${i}].content: non-empty string`);
  }
  // v2 §11 Mermaid amendment — content MUST be Mermaid (prose/ASCII REJECTED,
  // the §5.2 contextless-anchor discipline). Same diagnostic as the bash gate.
  for (let i = 0; i < b.diagrams.length; i++) {
    if (!looksLikeMermaid(b.diagrams[i].content))
      return rej(`dossier-gen: reject — §5.1 diagrams[${i}].content: MUST be Mermaid source (v2 §11) — prose/ASCII is a contract violation, not a wording nit; expected a Mermaid diagram-type header (graph/flowchart/sequenceDiagram/… optionally after ---frontmatter--- or %%{init}%%)`);
  }
  return OK;
}

// ════════════════════════════════════════════════════════════════════════════
// claude-tools-4xe — the §5.1-CORE WRITE GATE: the conformance gate moved to
// the RIGHT boundary (the engine's ONE dossier write path), not render-time.
//
// THE BUG this kills: the §11/vkc work enforced Mermaid + dossier_schema_version
// as a RENDER-time refusal while the WRITE path (validateEnvelope treats body
// as OPAQUE) accepted the same non-conformance — so an agent got a FALSE
// SUCCESS (put returned ok) AND the human hit a wall instead of the decision.
//
// A persisted `dossier` body MUST be EITHER:
//   (a) the §5.2.2 OPAQUE reconcile-pointer (T5.3 artifact — `body.reconcile_of`
//       present; contractually NOT §5 content, deliberately body-opaque so the
//       reconciler can round-trip it — test-consequence.sh:211/305), OR
//   (b) §5.1-CORE conformant: an integer `dossier_schema_version` EQUAL to the
//       bound version (§0.3 — an unknown HIGHER version is REJECTED, never
//       best-effort-parsed) AND every `diagrams[].content` Mermaid (v2 §11).
//
// This is deliberately NARROWER than the full §5 producer gate
// (validateDossier: tldr/sections≥1/full_detail/per-item §5.2): the substrate
// MUST still round-trip the opaque reconcile-pointer + the envelope/state-
// machine/latch test bodies (which carry the bound version + []-diagrams), and
// internal re-puts re-persist an already-§5-valid body. The full §5 gate stays
// where the contract puts it — the §5 SOLE PRODUCER (dossier-generate /
// dossier-from-worker-ask). This gate is the minimum that makes "the engine
// accepts a body the Inbox can never render" structurally impossible.
//
// Bash twin: lib/dossier.sh do_dossier_put (same predicate, same reconcile-
// pointer exemption, same single-source Mermaid algorithm — §8bm differential
// equivalence). Wired into the ONE store write (coordinator.js _writeRecord)
// so NO dossier write path — dossier-put, generic put, internal re-put — can
// skip it; the reconcile-pointer is the sole, contract-defined exemption.
export function dossierWriteBodyOk(body) {
  // §5.2.2 opaque reconcile-pointer — the ONE contract-defined exemption.
  if (isObj(body) && neStr(body.reconcile_of)) return OK;
  const bound = boundSv();
  if (bound === null || bound === undefined)
    return rej("dossier: reject (write) — 'dossier' absent from the §4 registry (store-surface contract gap; §0.5)");
  if (!isObj(body))
    return rej("dossier: reject (write) — §5.1 body must be a JSON object (claude-tools-4xe write gate; the engine refuses a non-conformant body so the agent never gets a false-success put)");
  const sv = intSv(body.dossier_schema_version);
  if (sv === null)
    return rej("dossier: reject (write) — body missing integer dossier_schema_version (§5.1 'int' / §0.3) — refused at WRITE so the agent gets a hard failure, never a false-success put the Inbox would wall (claude-tools-4xe)");
  if (sv > bound)
    return rej(`dossier: reject (write) — dossier_schema_version ${sv} is an unknown higher version (bound=${bound}; §0.3 reject, never best-effort-parse)`);
  if (sv !== bound)
    return rej(`dossier: reject (write) — dossier_schema_version ${sv} unsupported (binds v${bound} only; §0.3)`);
  const dgs = Array.isArray(body.diagrams) ? body.diagrams : [];
  for (let i = 0; i < dgs.length; i++) {
    const d = dgs[i];
    const content = isObj(d) && typeof d.content === "string" ? d.content : "";
    if (!looksLikeMermaid(content))
      return rej(`dossier: reject (write) — §5.1 diagrams[${i}].content MUST be Mermaid source (v2 §11) — prose/ASCII is a contract violation; the engine refuses it at WRITE so the agent gets a hard failure, never a false-success put the Inbox would wall (claude-tools-4xe)`);
  }
  return OK;
}

// ════════════════════════════════════════════════════════════════════════════
// §5.2 Item — kind enum · MANDATORY context_anchor · framing · reversible ·
//             per-kind options/recommendation · machine-applyable §5.3 block
//             (port of dg__validate_item)
// ════════════════════════════════════════════════════════════════════════════
function validateItem(it) {
  if (!isObj(it)) return rej("dossier-gen: reject — Item not a JSON object (§5.2)");
  const id = typeof it.id === "string" ? it.id : "";
  if (!id) return rej("dossier-gen: reject — §5.2 Item.id: non-empty string required (§0.4 per-Item key)");
  if (!safeKey(id))
    return rej(`dossier-gen: reject — §5.2 Item.id '${id}' unsafe ([A-Za-z0-9._-], no '..'; §0.4 per-Item key)`);

  const kind = typeof it.kind === "string" ? it.kind : "";
  if (!ITEM_KINDS.includes(kind))
    return rej(`dossier-gen: reject — §5.2 Item.kind '${kind}' not in the CLOSED enum (approve-reject|pick-option|approve-recommendation|freeform-edit|fyi-objectable)`);

  if (!(isObj(it.framing) && trimNE(it.framing.ask)))
    return rej(`dossier-gen: reject — Item '${id}': §5.2 framing: object with a non-empty .ask required (the per-item ask + why, self-contained)`);
  if (!(isObj(it.context_anchor) && trimNE(it.context_anchor.where) && trimNE(it.context_anchor.expansion)))
    return rej(`dossier-gen: reject — Item '${id}': §5.2 context_anchor{where,expansion}: MANDATORY non-empty — a contextless ask is a CONTRACT VIOLATION, not a wording nit (AD7 self-contained-context invariant); REJECTED, nothing written`);
  if (!trimNE(it.reversible))
    return rej(`dossier-gen: reject — Item '${id}': §5.2 reversible: non-empty string required (what the choice forecloses / how reversible)`);

  if (kind === "pick-option") {
    if (!(Array.isArray(it.options) && it.options.length >= 1))
      return rej(`dossier-gen: reject — Item '${id}': §5.2 pick-option needs options[] (≥1 {option_id,label,blast_radius,consequence_block})`);
    if (!(isObj(it.recommendation) && trimNE(it.recommendation.value) && trimNE(it.recommendation.why)))
      return rej(`dossier-gen: reject — Item '${id}': §5.2 pick-option needs recommendation{value,why} (non-empty; editable inline)`);
    const ids = new Set();
    for (let o = 0; o < it.options.length; o++) {
      const opt = it.options[o];
      const oid = isObj(opt) && typeof opt.option_id === "string" ? opt.option_id : "";
      if (!(isObj(opt) && trimNE(opt.option_id) && trimNE(opt.label) && trimNE(opt.blast_radius)))
        return rej(`dossier-gen: reject — Item '${id}' options[${o}]: §5.2 {option_id,label,blast_radius} each non-empty required`);
      const ocb = opt.consequence_block;
      if (ocb === undefined || ocb === null || ocb === false)
        return rej(`dossier-gen: reject — Item '${id}' option '${oid}': §5.2 every option MUST pre-declare a consequence_block (the chosen-option block applied at resolve)`);
      const cv = validateCb(ocb, `Item '${id}' option '${oid}' consequence_block`);
      if (!cv.ok) return cv;
      if (ids.has(oid))
        return rej(`dossier-gen: reject — Item '${id}': duplicate option_id '${oid}' (chosen-option block must be unambiguous — §5.2/§5.3)`);
      ids.add(oid);
    }
  } else {
    if (kind === "approve-recommendation") {
      if (!(isObj(it.recommendation) && trimNE(it.recommendation.value) && trimNE(it.recommendation.why)))
        return rej(`dossier-gen: reject — Item '${id}': §5.2 approve-recommendation needs recommendation{value,why} (non-empty)`);
    }
    const icb = it.consequence_block;
    if (icb === undefined || icb === null || icb === false)
      return rej(`dossier-gen: reject — Item '${id}': §5.2/§5.3 a pre-declared consequence_block is required (kind '${kind}')`);
    const cv = validateCb(icb, `Item '${id}' consequence_block`);
    if (!cv.ok) return cv;
  }
  return OK;
}

// §5.2.1 PROFILES are EMERGENT — ONE validator, NO per-profile schema branch
// (port of dg__validate_dossier): §4.1/§4.1.1 (reused) → §5.1 body → §5.2 each
// item. items[] MAY be empty (Flow F overview) — zero items ⇒ zero per-item
// checks, SAME shape, NO branch.
function validateDossier(env) {
  const ev = validateEnvelope(env);
  if (!ev.ok) return ev;
  if (!isObj(env.body)) return rej("dossier-gen: reject — no .body (§5.1)");
  const bv = validateBody(env.body);
  if (!bv.ok) return bv;
  if (!Array.isArray(env.items)) return rej("dossier-gen: reject — items[] not an array (§5.2)");
  for (const it of env.items) {
    const iv = validateItem(it);
    if (!iv.ok) return iv;
  }
  return OK;
}

// ════════════════════════════════════════════════════════════════════════════
// The single AUTHORING seam — ONE pass, swappable (§0.2 / §0.C). Port of
// dg__author: a single DETERMINISTIC transform of the §7.2 raw material into
// the §5 shape. The provider-agnostic swap (bash DG_AUTHOR_CMD piping to a real
// model) is realized here as `env.DG_AUTHOR_FIXTURE` (a Worker cannot exec a
// shell cmd) — the SAME env-knob pattern CF.1 uses for CO_EXPECTED_TOKEN. The
// output goes through the SAME frozen §5 gate regardless of which authored it
// (the schema is the contract, never the generator). Bound: the SCHEMA +
// item-granularity, NEVER the pass count.
// ════════════════════════════════════════════════════════════════════════════
function author(gi, sv, fixtureRaw) {
  if (fixtureRaw) {
    try {
      const f = JSON.parse(fixtureRaw);
      return isObj(f) ? f : null;
    } catch {
      return null;
    }
  }
  const s = isObj(gi.source) ? gi.source : {};
  const tldr = s.tldr ?? s.ask ?? "Decision required.";
  let sections;
  if (Array.isArray(s.sections) && s.sections.length > 0) {
    sections = s.sections;
  } else if (Array.isArray(s.options) && s.options.length > 0) {
    sections = [
      {
        heading: "Options",
        prose: s.options
          .map(
            (o) =>
              (o.label ?? o.option_id ?? "option") +
              (typeof o.blast_radius === "string" ? " — " + o.blast_radius : "")
          )
          .join("; "),
      },
      {
        heading: "Recommendation",
        prose:
          String((s.recommendation && s.recommendation.value) ?? "—") +
          " — " +
          String((s.recommendation && s.recommendation.why) ?? ""),
      },
    ];
  } else {
    sections = [{ heading: "Summary", prose: s.ask ?? tldr }];
  }
  const diagrams = Array.isArray(s.diagrams) ? s.diagrams : [];
  const full =
    s.full_detail ??
    (s.ask ?? tldr) +
      (typeof s.reversible === "string" ? "\n\nReversibility: " + s.reversible : "");

  const stampCb = (cb) =>
    isObj(cb) ? { ...cb, cb_schema_version: cb.cb_schema_version ?? sv } : cb;

  const items = (Array.isArray(gi.items) ? gi.items : []).map((it) => {
    const out = { ...it };
    if (it.kind === "pick-option") {
      out.consequence_block = it.consequence_block ?? {};
      if (Array.isArray(it.options)) {
        out.options = it.options.map((o) => ({
          ...o,
          consequence_block: stampCb(o.consequence_block),
        }));
      }
    } else {
      out.consequence_block = stampCb(it.consequence_block);
    }
    return out;
  });

  return {
    body: {
      dossier_schema_version: sv,
      tldr,
      sections,
      diagrams,
      full_detail: full,
    },
    items,
  };
}

// ════════════════════════════════════════════════════════════════════════════
// Per-Item STATE MACHINE — the ONLY legal transitions (port of
// do_item_state_check). PURE: open→answered, answered→applied, open→expired.
// EVERYTHING else (no-op, skip, terminal escape, rewind, unknown) is ILLEGAL.
// ════════════════════════════════════════════════════════════════════════════
function stateCheck(from, to) {
  return (
    (from === "open" && to === "answered") ||
    (from === "answered" && to === "applied") ||
    (from === "open" && to === "expired")
  );
}

// ════════════════════════════════════════════════════════════════════════════
// §5.2.2 PER-ITEM routing — pure-deterministic vs reconciler (port of
// do__is_deterministic). PURE.
// ════════════════════════════════════════════════════════════════════════════
function isDeterministic(item, resp) {
  const dec = isObj(resp) && typeof resp.decision === "string" ? resp.decision : "";
  const kind = isObj(item) && typeof item.kind === "string" ? item.kind : "";
  const edited =
    isObj(resp) &&
    Object.prototype.hasOwnProperty.call(resp, "edited_value") &&
    resp.edited_value !== null;
  if (!["approve-reject", "pick-option", "approve-recommendation", "fyi-objectable"].includes(kind))
    return false;
  if (edited) return false;
  return dec === "approve" || dec === "reject" || dec === "pick";
}

// do__select_cb: pick-option ⇒ the CHOSEN option's block; every other
// deterministic kind ⇒ the item's own pre-declared block.
function selectCb(item, resp) {
  const kind = item.kind;
  if (kind === "pick-option") {
    const sel = isObj(resp) && typeof resp.selected_option_id === "string" ? resp.selected_option_id : "";
    if (!sel) return rej("consequence: pick-option response has no selected_option_id (§5.2)");
    const opts = Array.isArray(item.options) ? item.options : [];
    const opt = opts.find((o) => o && o.option_id === sel);
    const cb = opt ? opt.consequence_block : undefined;
    if (cb === undefined || cb === null || cb === false)
      return rej(`consequence: selected_option_id '${sel}' not among this item's options (§5.2)`);
    return { ok: true, cb };
  }
  const cb = item.consequence_block;
  if (cb === undefined || cb === null || cb === false)
    return rej("consequence: item has no consequence_block (§5.2/§5.3)");
  return { ok: true, cb };
}

// ════════════════════════════════════════════════════════════════════════════
// store binding — the §4.1 `dossier` record type ONLY (CF.1's registry; CF.6
// adds NO §4 record type). Reads bind the schema (a typed SELECT on the §4.1
// record), writes go THROUGH CF.1's ONE write path `_writeRecord` (§0.3
// re-enforced + §9.1 principal stamped there). Mirrors bash dossier.sh
// consuming `co_request get|put dossier` — never the store internals.
// ════════════════════════════════════════════════════════════════════════════
async function getRawDossier(co, id) {
  const row = await co.db
    .prepare("SELECT json FROM records WHERE type = ? AND id = ?")
    .bind("dossier", id)
    .first();
  if (!row) return null;
  try {
    return JSON.parse(row.json);
  } catch {
    return null;
  }
}
// do_dossier_get: raw fetch → §0.3 BOUND ON THE READ PATH (reject an
// unknown-higher stored record rather than best-effort-parse it; a v<bound or
// ==bound is served — the bash read path is lenient there) → re-derive
// `.state`. { ok:false, found:false } when absent; { ok:false } on §0.3
// reject; { ok:true, rec } otherwise.
async function getDossier(co, id) {
  const raw = await getRawDossier(co, id);
  if (raw === null) return { ok: false, found: false };
  const bound = boundSv();
  const sv = intSv(raw.schema_version);
  if (sv === null)
    return rej("dossier: reject (read) — stored record missing integer schema_version (§0.3)");
  if (sv > bound)
    return rej(`dossier: reject (read) — schema_version ${sv} is an unknown higher version (bound=${bound}; §0.3, never best-effort-parse)`);
  return { ok: true, rec: stampRollup(raw) };
}
// do_dossier_put: validate (§4.1/§4.1.1/§0.3) → stamp the DERIVED rollup →
// persist via CF.1 `_writeRecord` (re-enforces §0.3, STAMPS principal §9.1 —
// never a use-site literal, C7). A validation failure performs NO write.
async function putDossier(co, principal, env) {
  const v = validateEnvelope(env);
  if (!v.ok) return v;
  if (!neStr(env.id)) return rej("dossier: reject — no id (§4.1)");
  const canon = stampRollup(env);
  const w = await co._writeRecord(principal, "dossier", canon.id, canon);
  if (!w.ok) return rej(w.msg || `dossier: reject — ${w.code}`);
  return { ok: true, id: canon.id };
}

// ── §5.3 ConsequenceBlock → WORK PLANE (port of do__apply_cb) ───────────────
// Records each `bd <args>` line into work_plane_ops verbatim (the bash
// $BD_LOG analogue). The create-id is `bd-fake-<rowcount-after-insert>` —
// the EXACT scheme the bash test fake uses (`n=$(wc -l < $BD_LOG)` post-
// append), so the deps[] id-scrape resolves and the differential greps match.
async function wpBd(co, argv) {
  const line = argv.join(" ");
  await co.db.prepare("INSERT INTO work_plane_ops (line) VALUES (?)").bind(line).run();
  if (argv[0] === "create") {
    // The create id MUST be `bd-fake-<COUNT(*) post-insert>` — the bash fake is
    // `n=$(wc -l < $BD_LOG)` AFTER appending, and the differential resets the
    // sink with `DELETE FROM work_plane_ops` between scenarios. COUNT(*) tracks
    // that truncation; the table's AUTOINCREMENT `id` does NOT reset on DELETE,
    // so it is DELIBERATELY NOT used here — a future "use last_row_id" change
    // would silently break bash-fake parity. Do not "optimise" this.
    const c = await co.db.prepare("SELECT COUNT(*) AS n FROM work_plane_ops").first();
    return `bd-fake-${c ? c.n : 0}`;
  }
  return null;
}
async function applyCb(co, cb) {
  // creates[] — { title, type, priority, labels[], description, deps[] }.
  // §5.3 lists NO declared defaults: an ABSENT type/priority/description is
  // OMITTED from `bd create` (bd's own default), NEVER synthesised here.
  for (const c of orEmptyArr(cb.creates)) {
    const title = typeof c.title === "string" ? c.title : "";
    if (!title) continue;
    const argv = ["create", "--title", title];
    const typ = typeof c.type === "string" ? c.type : "";
    if (typ) argv.push("--type", typ);
    const pri = typeof c.priority === "number" ? String(c.priority) : "";
    if (pri) argv.push("-p", pri);
    const lbls = orEmptyArr(c.labels).join(",");
    if (lbls) argv.push("--labels", lbls);
    const desc = typeof c.description === "string" ? c.description : "";
    if (desc) argv.push("-d", desc);
    const newid = await wpBd(co, argv);
    if (newid) {
      for (const d of orEmptyArr(c.deps)) {
        if (d) await wpBd(co, ["dep", "add", newid, String(d)]);
      }
    }
  }
  // unblocks[] — bead_refs released back to open (BC-15; control→work)
  for (const ref of orEmptyArr(cb.unblocks)) {
    if (ref) await wpBd(co, ["update", String(ref), "--status=open"]);
  }
  // labels[] — { bead_ref, add[], remove[] }
  for (const l of orEmptyArr(cb.labels)) {
    const ref = isObj(l) && typeof l.bead_ref === "string" ? l.bead_ref : "";
    if (!ref) continue;
    const argv = [];
    for (const a of orEmptyArr(l.add)) if (a) argv.push("--add-label", String(a));
    for (const a of orEmptyArr(l.remove)) if (a) argv.push("--remove-label", String(a));
    if (argv.length) await wpBd(co, ["update", ref, ...argv]);
  }
  // status_changes[] — { bead_ref, to_status }
  for (const sc of orEmptyArr(cb.status_changes)) {
    const ref = isObj(sc) && typeof sc.bead_ref === "string" ? sc.bead_ref : "";
    const to = isObj(sc) && typeof sc.to_status === "string" ? sc.to_status : "";
    if (ref && to) await wpBd(co, ["update", ref, `--status=${to}`]);
  }
}

// do__emit_followup: the §5.2.2 RECONCILER artifact — a follow-up Dossier
// SCOPED TO THIS ITEM. The original item's §5 fields are carried VERBATIM
// (copied, NEVER synthesised — §5 generation is a sibling); body is an OPAQUE
// reconcile-pointer (NOT §5 content). Deterministic follow-up id so a
// double-tap can never fork two follow-ups. Sibling Items NOT carried/touched.
async function emitFollowup(co, principal, doss, item, resp) {
  const odid = doss.id;
  const oiid = item.id;
  if (!safeKey(odid))
    return rej(`consequence: reconciler — unsafe dossier id '${odid}' for the follow-up namespace ([A-Za-z0-9._-], no '..')`);
  if (!safeKey(oiid))
    return rej(`consequence: reconciler — unsafe Item id '${oiid}' for the follow-up namespace ([A-Za-z0-9._-], no '..')`);
  const fid = `${odid}-fu-${oiid}`;
  const sv = boundSv();
  const now = nowIso();
  const carry = {
    ...item,
    id: `${oiid}-r1`,
    state: "open",
    response: null,
    consequence_applied: false,
    applied_at: null,
  };
  const env = {
    id: fid,
    schema_version: sv,
    kind: doss.kind,
    trigger: doss.trigger,
    bead_ref: doss.bead_ref,
    tier: doss.tier,
    created_at: now,
    timer_fire_at: null,
    body: {
      reconcile_of: doss.id,
      reconcile_item: oiid,
      reason:
        "freeform/edited/object — needs interpretation (§5.2.2 reconciler); §5 generation = a sibling",
      prior_response: resp,
    },
    items: [carry],
  };
  const w = await putDossier(co, principal, env);
  if (!w.ok) return w;
  return { ok: true, fid };
}

// ════════════════════════════════════════════════════════════════════════════
// THE IDEMPOTENT PER-ITEM APPLY ENTRYPOINT (§5.3 + §7.4 per-Item + §5.2.2).
// Port of do_item_apply. Idempotent BY CONSTRUCTION: the caller wraps this in
// co._serialize so the whole read→route→apply→latch→state→persist is ONE
// critical section on the single-threaded singleton DO (the AD1 payoff). A
// double-tap OR a §2.2 alarm racing the poll-fallback (S-6) ⇒ EXACTLY ONCE.
// ════════════════════════════════════════════════════════════════════════════
async function itemApply(co, principal, did, iid, respArg) {
  const g = await getDossier(co, did);
  if (!g.ok)
    return rej(
      "consequence: apply — dossier not found OR not authorized (the §9.1 chokepoint collapses 401 and absent; no second auth path — C4)"
    );
  const rec = g.rec;
  const idx = (rec.items || []).findIndex((it) => it && it.id === iid);
  if (idx < 0) return rej(`consequence: apply — Item '${iid}' not in '${did}' (§0.4)`);
  const item = rec.items[idx];
  const st = item.state;
  const la = item.consequence_applied;

  // ── §7.4 PER-ITEM IDEMPOTENCY LAYER — the exactly-once gate ───────────────
  // The second caller (double-tap, OR §2.2 alarm racing poll-fallback) sees
  // the latch already true / state already applied and returns idempotent
  // success having applied NOTHING. Structural here: it ran AFTER the first in
  // the one serialized critical section, so it observes the committed latch.
  if (la === true || st === "applied") return { ok: true, idempotent: true };
  if (st === "expired")
    return rej(`consequence: apply REJECTED — Item '${iid}' is expired (auto-proceed already lapsed; §4.1.1/§5.2)`);

  let resp = respArg;
  if (st === "open") {
    if (!isObj(resp))
      return rej(`consequence: apply — open Item '${iid}' needs a response object (§4.1.1 .response)`);
    if (!stateCheck("open", "answered"))
      return rej(`consequence: apply — open→answered illegal (§4.1.1/§5.2)`);
  } else if (st === "answered") {
    // The recorded response is authoritative; a passed retry body is ignored.
    resp = isObj(item.response) ? item.response : null;
    if (!isObj(resp))
      return rej(`consequence: apply — answered Item '${iid}' has no recorded .response (§4.1.1)`);
  } else {
    return rej(`consequence: apply REJECTED — Item '${iid}' in unexpected state '${st}'`);
  }
  // ── L1 (claude-tools-uxvl1) §5.6 — EMPTY-PAYLOAD HARD REJECT ────────────────
  // A §5.2 response MUST carry a non-empty `decision`. An empty/contentless
  // payload ({} — e.g. a mis-wired "dismiss" tap, or a decision-less recorded
  // response) is REJECTED here: it must NEVER fall through to the §5.2.2
  // reconciler (which would mark the Item `applied` and emit a follow-up; the
  // runner's resume poll would then re-dispatch the worker with "Raw response
  // (§5.2): {}"). No verb may default to another verb's payload — "dismiss as
  // stale" is its OWN verb (item-set-state→expired), never an empty apply
  // (inbox-lifecycle §5.4/§5.6). The §7.4 idempotency latch is NOT touched on a
  // reject (NO write), so a later real decision on this Item still applies.
  if (typeof resp.decision !== "string" || resp.decision.trim() === "")
    return rej(
      `consequence: apply REJECTED — Item '${iid}' response carries no §5.2 decision (empty/contentless payload). Each Inbox verb sends its own decision; an empty payload never defaults to "apply the recommendation" (inbox-lifecycle §5.4/§5.6).`
    );
  if (!stateCheck("answered", "applied"))
    return rej(`consequence: apply — answered→applied illegal (§4.1.1/§5.2)`);

  const now = nowIso();
  const items = rec.items.slice();

  if (isDeterministic(item, resp)) {
    // ── §5.2.2 DETERMINISTIC: apply the pre-declared §5.3 block ─────────────
    const sel = selectCb(item, resp);
    if (!sel.ok) return sel;
    const cv = validateCb(sel.cb);
    if (!cv.ok) return cv; // §0.3-reject ⇒ NO work-plane op, latch NOT flipped
    await applyCb(co, sel.cb); // control→work (BEFORE the latch — apply-then-latch)
    items[idx] = {
      ...item,
      response: resp,
      consequence_applied: true,
      applied_at: now,
      state: "applied",
    };
    const w = await putDossier(co, principal, { ...rec, items });
    if (!w.ok) return w;
    return { ok: true };
  }

  // ── §5.2.2 RECONCILER: emit the item-scoped follow-up Dossier ────────────
  // The consequence here IS "reconciler dispatched"; it too is exactly-once
  // (the same latch gates it). Resolved siblings are NEVER re-opened.
  const fu = await emitFollowup(co, principal, rec, item, resp);
  if (!fu.ok) return fu;
  items[idx] = {
    ...item,
    response: { ...resp, reconcile_followup: fu.fid },
    consequence_applied: true,
    applied_at: now,
    state: "applied",
  };
  const w = await putDossier(co, principal, { ...rec, items });
  if (!w.ok) return w;
  return { ok: true };
}

// ── per-Item state move (port of do_item_set_state) ─────────────────────────
async function itemSetState(co, principal, did, iid, to, respArg) {
  const g = await getDossier(co, did);
  if (!g.ok) return rej(`dossier: set-state — dossier '${did}' not found`);
  const rec = g.rec;
  const idx = (rec.items || []).findIndex((it) => it && it.id === iid);
  if (idx < 0) return rej(`dossier: set-state — Item '${iid}' not in '${did}' (§0.4)`);
  const cur = rec.items[idx].state;
  if (!stateCheck(cur, to))
    return rej(
      `dossier: set-state REJECTED — illegal transition ${cur}->${to} for Item '${iid}' (legal: open->answered->applied | open->expired; §4.1.1/§5.2)`
    );
  const items = rec.items.slice();
  if (respArg !== undefined && respArg !== null) {
    if (!isObj(respArg))
      return rej("dossier: set-state — response must be a JSON object|absent (§4.1.1 .response)");
    items[idx] = { ...rec.items[idx], state: to, response: respArg };
  } else {
    items[idx] = { ...rec.items[idx], state: to };
  }
  const w = await putDossier(co, principal, { ...rec, items });
  if (!w.ok) return w;
  return { ok: true };
}

// ════════════════════════════════════════════════════════════════════════════
// L1 follow-up (claude-tools-uxl1b) §5.6 — DEFER / ESCALATE: the two remaining
// Inbox verbs, realized as DISTINCT engine ops (no verb defaults to another
// verb's payload — the L1 empty-payload bug class). They adjust the dossier's
// §4.1 ATTENTION TIER and DISARM any §2.2 auto-proceed timer: no §5.2 response,
// no §5.3 ConsequenceBlock, no per-Item state move — but timer_fire_at is
// nulled (and the substrate timer soft-disarmed) because both targets are
// non-auto-proceed tiers (claude-tools-fyci; see TOTAL+IDEMPOTENT below).
//
//   • defer    (dossier-defer)    → tier = "digest"   — "push out without
//       resolution" (inbox-lifecycle §5.6): drop the card from the foreground
//       decision lane into the daily-digest roundup. It STAYS on the Inbox
//       (waiting_on_you counts non-terminal items, tier-agnostic) — it is just
//       no longer an individual interrupt.
//   • escalate (dossier-escalate) → tier = "blocking" — "promote to higher-
//       attention surface" (§5.6): pull the card back into the foreground
//       decision lane (the tier N2 delivery keys off for an immediate push).
//
// WHY `tier`, and why these verbs NEVER target `timed-fyi`: §4.1 binds `tier`
// as the attention level ("Drives the single Notification (C3)"). The verbs
// toggle the two HUMAN-MANAGED attention levels — foreground `blocking` ⟷
// background `digest`. `timed-fyi` is the DISTINCT auto-proceed lane (Flow F
// overviews ride a §2.2 timer; timer.js fireDossier auto-applies fyi-objectable
// items on silence). Pushing a decision dossier INTO timed-fyi would arm a
// silent auto-apply (the §5.6 / L1 hazard) AND make the renderer's
// `auto_proceeds` (tier==="timed-fyi") falsely promise auto-proceed for
// pick-option items. So defer/escalate move OUT of timed-fyi in either
// direction (escalate→blocking, defer→digest) — turning auto-proceed OFF, the
// safe direction — and never into it. (fireDossier no-ops on a non-timed-fyi
// tier, so neither op can ever trigger an auto-apply.)
//
// TOTAL + IDEMPOTENT: defined for every tier; re-running at the target tier is
// { ok:true, idempotent:true } with NO write. items[] / response /
// consequence_applied / the §4.3 Notification record are ALL left exactly as
// they were. The §7.4 latch is never touched, so a real later decision on any
// item still applies. The ONE field a real move also writes is timer_fire_at →
// null (claude-tools-fyci): both targets are non-auto-proceed tiers, so the
// stored record must not carry an armed §2.2 timer — clearing it at the source
// kills the digest+armed-timer edge that split o2mk's L2 auto-close
// discriminators. (A no-op move — from===target — writes nothing, so an already
// digest/blocking card's null timer is never even re-touched.) Bash twin:
// lib/dossier.sh do_dossier_defer / do_dossier_escalate (same targets, same
// idempotency, same disarm).
const ATTENTION_BY_VERB = { defer: "digest", escalate: "blocking" };

async function dossierSetAttention(co, principal, did, verb) {
  const target = ATTENTION_BY_VERB[verb];
  if (!target) return rej(`dossier: ${verb} — unknown attention verb (defer|escalate)`);
  if (!neStr(did)) return rej(`dossier: ${verb} — need <dossier_id> (§4.1)`);
  const g = await getDossier(co, did);
  if (!g.ok)
    return rej(
      `dossier: ${verb} — dossier '${did}' not found OR not authorized (the §9.1 chokepoint collapses 401 and absent; no second auth path — C4)`
    );
  const rec = g.rec;
  const from = typeof rec.tier === "string" ? rec.tier : "";
  // Idempotent at the target attention tier — NO write (so a no-op defer/
  // escalate never churns the record or re-stamps applied_at on anything).
  if (from === target) return { ok: true, idempotent: true, tier: target };
  // Move `.tier` AND DISARM (claude-tools-fyci). The target is ALWAYS a
  // non-auto-proceed tier (digest|blocking) — §4.1 binds an armed §2.2 timer to
  // `timed-fyi` ONLY — so the moved record MUST carry timer_fire_at=null. Clear
  // it in the SAME write: without this, deferring/escalating an ARMED timed-fyi
  // card would strand a stale timer_fire_at, the ONE row where o2mk's two L2
  // auto-close discriminators disagree (engine beadStatusChanged skips on
  // timer_fire_at!=null, but the daemon select_open_beads emits on
  // tier∈{blocking,digest}). Nulling at the source makes digest/blocking ≡
  // no-armed-timer hold for the STORED record, not just by construction of the
  // arm path. putDossier re-validates the §4.1 envelope + the §5.1 write gate
  // and re-derives the rollup; everything else round-trips verbatim.
  const w = await putDossier(co, principal, { ...rec, tier: target, timer_fire_at: null });
  if (!w.ok) return w;
  // Soft-disarm any prior §2.2 one-shot fire on the substrate surface — the
  // same timer-ack primitive tfArm uses for its non-timed-fyi soft-disarm.
  // Best-effort ONLY: fireDossier already no-ops on a non-timed-fyi tier and
  // the per-Item §7.4 latch is the truth, so a failed/absent ack is harmless.
  try { await co.opTimerAck(did); } catch { /* non-fatal — see timer.js timerAck */ }
  return { ok: true, from, tier: target };
}

// ════════════════════════════════════════════════════════════════════════════
// L2 (claude-tools-uxvl2) — WORK→CONTROL auto-close. inbox-lifecycle §7 (Opt 2).
//
// When a bead resolves OUTSIDE the dossier tap (bd close / blocked→open /
// `human` label dropped), the per-machine daemon publishes a
// `bead_status_changed` report over the zdxd D2 channel (the SAME outbox →
// la_outbox_drain → co_request transport the machine_state telemetry rides).
// This op looks up THIS principal's dossiers for that bead_ref and drops the
// stale card off the Inbox by moving every still-open item to a terminal state.
//
// POLICY (§7.6.3 decision-vs-expiry):
//   • open      → expired   — no decision was ever made; the bead moved on.
//   • answered  → applied   — a human decision IS recorded; PRESERVE it (the
//                             item's .response is carried verbatim) but DO NOT
//                             fire the §5.3 ConsequenceBlock. The `applied`
//                             path that fires the CB stays reserved for an
//                             explicit Inbox tap (item-apply); auto-firing it
//                             here would be wrong on the audit plane.
//   • applied / expired     — already terminal ⇒ untouched (idempotent no-op).
//
// THE §7.9 GOTCHA — this MUST go through the item-set-state STATE MOVE, never
// item-apply: item-apply on a non-deterministic answer CLONES a `<did>-fu-`
// follow-up dossier (§5.2.2 reconciler) AND fires the CB. itemSetState moves
// `.state` ONLY (the §4.1.1 legal-transition gate already permits open→expired
// and answered→applied), applies NO ConsequenceBlock, and re-reads the dossier
// fresh per call — so per-item moves compose correctly inside the one serialized
// critical section handleDossierOp wraps this in.
//
// IDEMPOTENT (§7.6.4): a duplicate event (or one racing the bead's last open
// item already gone terminal) is a no-op — returns { ok:true, idempotent:true },
// NEVER a hard rej; the §4.1.1 state machine is monotonic so a re-move would be
// illegal-and-rejected, and this op simply skips terminal items instead.
//
// v1 SKIP (§7.9 gotcha): a stored sub-bound (v1) dossier CANNOT be written back
// (the write gate binds v(bound)); itemSetState's putDossier would reject it. We
// SKIP such a dossier (leave its items as-is, count it) rather than crash. A
// separate v1-purge pass is the contract-defined way to retire those.
//
// The `bead_status_changed` REPORT itself binds a v1 WIRE schema (the D2-family
// report version, DISTINCT from the dossier envelope's bound version).
const BSC_REPORT_SV = 1;

function parseBscReport(a0) {
  if (isObj(a0)) return a0;
  if (typeof a0 === "string") {
    try {
      const o = JSON.parse(a0);
      return isObj(o) ? o : null;
    } catch {
      return null;
    }
  }
  return null;
}

async function beadStatusChanged(co, principal, a0) {
  const rep = parseBscReport(a0);
  if (!rep) return rej("bead-status-changed: reject — report not a JSON object");
  if (rep.report !== "bead_status_changed")
    return rej('bead-status-changed: reject — report!="bead_status_changed" (§1.1 shape)');
  const rsv = intSv(rep.schema_version);
  if (rsv === null)
    return rej("bead-status-changed: reject — missing integer schema_version (§0.3)");
  if (rsv > BSC_REPORT_SV)
    return rej(`bead-status-changed: reject — schema_version ${rsv} is an unknown higher version (bound=${BSC_REPORT_SV}; §0.3, never best-effort-parse)`);
  if (rsv !== BSC_REPORT_SV)
    return rej(`bead-status-changed: reject — schema_version ${rsv} unsupported (binds v${BSC_REPORT_SV} only; §0.3)`);
  if (!neStr(rep.bead_ref))
    return rej("bead-status-changed: reject — §1.1 bead_ref: non-empty string required");
  const bref = rep.bead_ref;

  const bound = boundSv();
  // Scan stored Dossiers; act ONLY on THIS principal's dossiers for this
  // bead_ref — the SAME principal+bead scoping the waiting_on_you projection
  // (reconcile.js) uses. COUNTS the cross-cutting outcomes for an audit record.
  const { results: drows } = await co.db
    .prepare("SELECT json FROM records WHERE type = ? ORDER BY id")
    .bind("dossier")
    .all();
  const transitions = [];
  let skipped_v1 = 0;
  let matched_dossiers = 0;
  for (const dr of drows || []) {
    let d;
    try {
      d = JSON.parse(dr.json);
    } catch {
      continue;
    }
    if (!isObj(d) || d.principal !== principal || d.bead_ref !== bref) continue;
    // TIER SCOPING (refined — claude-tools-o2mk) — auto-close BLOCKING decision
    // dossiers AND any non-blocking dossier with NO ARMED auto-proceed timer
    // (timer_fire_at == null). The exemption protects ONLY a GENUINE
    // auto-proceeder: a non-blocking dossier with an ARMED timer
    // (a Flow F `overview-<bead_ref>` timed-fyi card) rides its OWN §2.2 timer
    // (CF.7); force-expiring it on bead-resolution would defeat the 24h objection
    // window that is Flow F's entire point. A bead can carry BOTH a `stuck-<ref>`
    // (blocking) and an armed `overview-<ref>` (timed-fyi) — this preserves the
    // latter. But a §5.6-DEFERRED decision card (the escalate inverse: tier
    // lowered blocking→digest WITHOUT arming any timer — bd memory
    // inbox-verb-defer-escalate-tier-mapping) has NO timer to ride; the old
    // blocking-only skip stranded it as a stale Inbox card when its bead later
    // resolved OUTSIDE the tap. "Armed" = a non-empty string timer_fire_at, the
    // exact value timer.js writes (else null) — an absent/null/empty window is
    // NOT an auto-proceeder, so it auto-closes like a blocking card.
    //
    // SNOOZE refinement (claude-tools-653d): a §5.6-SNOOZED card is tier=digest
    // WITH an armed timer (timer_fire_at + snoozed_until = snooze_until) — the
    // shape fyci's "digest/blocking ≡ no-armed-timer" invariant otherwise forbids,
    // re-opened deliberately by snooze (it keeps a RE-SURFACE alarm). A snooze is
    // NOT an auto-proceeder — its timer RE-SURFACES (timer.js snoozeSurface), it
    // never auto-applies — so a snoozed card whose bead resolves OUTSIDE must
    // auto-close like any blocking/digest card (drop the dead card), NOT be
    // skipped as a Flow-F auto-proceeder. So the exemption is narrowed from "armed
    // timer ⇒ skip" to "GENUINELY timed-fyi ⇒ skip": the only tier that ever
    // legitimately carries an armed AUTO-PROCEED timer is `timed-fyi` (a Flow-F
    // `overview-<ref>` card). `&& !snoozed` is belt-and-suspenders (a snooze rides
    // `digest`, so `tier === "timed-fyi"` already excludes it) documenting intent.
    const armedTimer = typeof d.timer_fire_at === "string" && d.timer_fire_at !== "";
    const snoozed = typeof d.snoozed_until === "string" && d.snoozed_until !== "";
    if (d.tier === "timed-fyi" && armedTimer && !snoozed) continue;
    matched_dossiers++;
    // §7.9 v1-skip: a sub-bound stored dossier cannot be written back.
    if (intSv(d.schema_version) !== bound) {
      skipped_v1++;
      continue;
    }
    const items = Array.isArray(d.items) ? d.items : [];
    for (const it of items) {
      if (!isObj(it)) continue;
      let to = null;
      if (it.state === "open") to = "expired";
      else if (it.state === "answered") to = "applied"; // preserve .response
      else continue; // applied|expired ⇒ terminal, idempotent no-op
      // item-set-state STATE MOVE ONLY (NOT item-apply — §7.9). respArg omitted
      // ⇒ the recorded .response is carried verbatim (apply-preserving). A
      // rejected move (should not happen — the gate already permits these two)
      // is logged in the count but does not abort the sweep.
      const r = await itemSetState(co, principal, d.id, it.id, to);
      if (r.ok) transitions.push({ dossier_id: d.id, item_id: it.id, from: it.state, to });
    }
  }
  return {
    ok: true,
    idempotent: transitions.length === 0,
    bead_ref: bref,
    matched_dossiers,
    skipped_v1,
    transitions,
  };
}

// ── PRIMITIVE 1: the per-Item consequence_applied latch (port of
// do_item_latch). Flips false→true EXACTLY ONCE + stamps applied_at; a SECOND
// writer (latch already true) is REJECTED. Exactly-once is BY CONSTRUCTION of
// the serialized single-threaded section — NOT a hand-rolled CAS. It is a
// PRIMITIVE: it moves NO `.state` and applies NO ConsequenceBlock (orthogonal).
async function itemLatch(co, principal, did, iid) {
  const g = await getDossier(co, did);
  if (!g.ok) return rej(`dossier: latch — dossier '${did}' not found`);
  const rec = g.rec;
  const idx = (rec.items || []).findIndex((it) => it && it.id === iid);
  if (idx < 0) return rej(`dossier: latch — Item '${iid}' not in '${did}' (§0.4)`);
  if (rec.items[idx].consequence_applied === true)
    return rej(
      `dossier: latch REJECTED — Item '${iid}' consequence_applied already true (single-writer-set; false→true ONCE; §7.4 per-Item / §4.1.1)`
    );
  const items = rec.items.slice();
  items[idx] = { ...rec.items[idx], consequence_applied: true, applied_at: nowIso() };
  const w = await putDossier(co, principal, { ...rec, items });
  if (!w.ok) return w;
  return { ok: true };
}

// ── §5 SOLE PRODUCER (port of dg_generate / dg_from_worker_ask) ─────────────
async function dossierGenerate(co, principal, gi) {
  if (!isObj(gi)) return rej("dossier-gen: reject — generation input not a JSON object");
  if (!neStr(gi.id))
    return rej("dossier-gen: reject — generation input has no dossier id (§4.1; the §7.4 dedup layer supplies it)");
  const sv = boundSv();
  const content = author(gi, sv, co.env && co.env.DG_AUTHOR_FIXTURE);
  if (!(isObj(content) && isObj(content.body) && Array.isArray(content.items)))
    return rej("dossier-gen: reject — authoring did not yield {body,items[]} (§5)");
  const now = nowIso();
  const env = {
    id: gi.id,
    schema_version: sv,
    kind: gi.kind ?? "decide",
    trigger: gi.trigger,
    bead_ref: gi.bead_ref,
    tier: gi.tier,
    created_at: gi.created_at ?? now,
    timer_fire_at: gi.timer_fire_at ?? null,
    body: content.body,
    items: content.items.map((it) => ({
      ...it,
      state: "open",
      response: null,
      consequence_applied: false,
      applied_at: null,
    })),
  };
  // REJECT on ANY §5 violation BEFORE any write (a missing context_anchor is a
  // contract violation, not a wording nit — refused here, nothing persisted).
  const dv = validateDossier(env);
  if (!dv.ok) return dv;
  const w = await putDossier(co, principal, env);
  if (!w.ok) return w;
  return { ok: true, id: gi.id };
}

function fromWorkerAsk(co, principal, did, bref, ask) {
  if (!isObj(ask)) return Promise.resolve(rej("dossier-gen: reject — worker structured ask not a JSON object (§7.2)"));
  if (!(neStr(did) && neStr(bref)))
    return Promise.resolve(rej("dossier-gen: reject — need <dossier_id> <bead_ref> (§7.2/§7.4: id is the dedup'd one)"));
  const gi = {
    id: did,
    kind: "decide",
    trigger: "worker_stuck",
    bead_ref: bref,
    tier: "blocking",
    timer_fire_at: null,
    source: {
      tldr: ask.tldr ?? ask.ask ?? "Worker reached a fork it must not resolve.",
      ask: ask.ask ?? ask.tldr ?? "Pick how to proceed.",
      options: ask.options ?? [],
      recommendation: ask.recommendation ?? null,
      reversible: ask.reversible ?? "Unspecified by the worker ask (§7.2).",
    },
    items: [
      {
        id: `${did}-d1`,
        kind: "pick-option",
        framing: {
          ask: ask.ask ?? ask.tldr ?? "Pick how the worker should proceed.",
          why:
            (ask.recommendation && ask.recommendation.why) ??
            "The worker reached a decision it must not make unilaterally (§7.2).",
        },
        context_anchor: {
          where: `Worker fork on ${bref} — a blocked decision the runner cannot resolve (§7.2 worker-driven STUCK).`,
          expansion:
            ask.tldr ??
            ask.ask ??
            "The worker emitted a structured ask and exited; this is the pick-one decision it could not make.",
        },
        options: ask.options ?? [],
        recommendation: ask.recommendation ?? null,
        reversible: ask.reversible ?? "Unspecified by the worker ask (§7.2).",
      },
    ],
  };
  return dossierGenerate(co, principal, gi);
}

// ════════════════════════════════════════════════════════════════════════════
// THE CF.6 DISPATCHER — called from the Coordinator DO for every DOSSIER_OPS
// op. Pure helper ops short-circuit (no store, no serialization). Every op
// that touches the §4.1 store runs INSIDE co._serialize so the single-threaded
// singleton DO processes one dossier critical section at a time (AD1).
// ════════════════════════════════════════════════════════════════════════════
function jsonRes(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}
function textRes(s, status = 200) {
  return new Response(s, { status, headers: { "content-type": "text/plain" } });
}

export async function handleDossierOp(co, op, args, principal) {
  const a = args || [];
  try {
    // ── PURE ops (the bash PURE functions; no store, no serialize) ──────────
    if (op === "item-state-check") {
      return jsonRes({ ok: stateCheck(a[0], a[1]) }, stateCheck(a[0], a[1]) ? 200 : 422);
    }
    if (op === "dossier-rollup") {
      return textRes(rollup(a[0]));
    }
    if (op === "validate-body") {
      const r = validateBody(a[0]);
      return jsonRes(r, r.ok ? 200 : 422);
    }
    if (op === "validate-item") {
      const r = validateItem(a[0]);
      return jsonRes(r, r.ok ? 200 : 422);
    }
    if (op === "validate-dossier") {
      const r = validateDossier(a[0]);
      return jsonRes(r, r.ok ? 200 : 422);
    }
    if (op === "cb-applyable") {
      const r = validateCb(a[0]);
      return jsonRes(r, r.ok ? 200 : 422);
    }

    // ── STORE-TOUCHING ops — serialized through the one single-threaded
    //    actor (AD1: idempotency + partial application BY CONSTRUCTION) ──────
    return await co._serialize(async () => {
      if (op === "dossier-put") {
        const r = await putDossier(co, principal, a[0]);
        return jsonRes(r, r.ok ? 200 : 422);
      }
      if (op === "dossier-get") {
        const r = await getDossier(co, a[0]);
        if (r.ok) return textRes(JSON.stringify(r.rec));
        if (r.found === false) return jsonRes({ ok: false, found: false }, 404);
        return jsonRes(r, 422);
      }
      if (op === "item-set-state") {
        const r = await itemSetState(co, principal, a[0], a[1], a[2], a[3]);
        return jsonRes(r, r.ok ? 200 : 422);
      }
      if (op === "item-latch") {
        const r = await itemLatch(co, principal, a[0], a[1]);
        return jsonRes(r, r.ok ? 200 : 422);
      }
      if (op === "item-apply") {
        const r = await itemApply(co, principal, a[0], a[1], a[2]);
        return jsonRes(r, r.ok ? 200 : 422);
      }
      if (op === "dossier-defer" || op === "dossier-escalate") {
        // L1 follow-up (claude-tools-uxl1b) §5.6 — DISTINCT attention verbs.
        // Serialized like every store-touching op so a tier move never
        // interleaves with a racing tap on the same dossier (AD1).
        const verb = op === "dossier-defer" ? "defer" : "escalate";
        const r = await dossierSetAttention(co, principal, a[0], verb);
        return jsonRes(r, r.ok ? 200 : 422);
      }
      if (op === "bead-status-changed") {
        // L2 (claude-tools-uxvl2) — WORK→CONTROL auto-close. Runs inside the
        // one serialized critical section so its per-item itemSetState moves
        // never interleave with a racing Inbox tap on the same dossier (AD1).
        const r = await beadStatusChanged(co, principal, a[0]);
        return jsonRes(r, r.ok ? 200 : 422);
      }
      if (op === "dossier-generate") {
        const r = await dossierGenerate(co, principal, a[0]);
        return jsonRes(r, r.ok ? 200 : 422);
      }
      if (op === "dossier-from-worker-ask") {
        const r = await fromWorkerAsk(co, principal, a[0], a[1], a[2]);
        return jsonRes(r, r.ok ? 200 : 422);
      }
      return jsonRes({ ok: false, error: `co: unknown dossier op '${op}'` }, 400);
    });
  } catch (e) {
    return jsonRes({ ok: false, error: `co: dossier internal — ${e && e.message ? e.message : e}` }, 500);
  }
}
