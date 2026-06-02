// CF.3 (claude-tools-7g0.3) — §4.2 RunnerState reconcile semantics + S-1
// liveness derivation + the §4.5 read-only work-snapshot projection PRODUCER,
// realized on the CF.1 substrate.
//
// This is the Cloudflare realization of the bash:
//   lib/coordinator.sh  co__STALE_AFTER / co__actual_ok / co__derive_liveness
//                        / co__heartbeat / co__reconcile / co__work_snapshot
// and is differential-bound to lib/test-coordinator-reconcile.sh +
// lib/test-board.sh (the projection-producer behaviour the renderer drives).
// The CF engine MUST exhibit the SAME INTERFACE.md v1 §4.2/§4.5/§2.4 + §0.5
// STALE_AFTER behaviour as the bash impl + those tests — not a re-spec.
//
// WHY (S-1/S-2, principle 4 — the Board must never lie): `desired ≠ actual`
// is legal and surfaced HONESTLY; `liveness` is DATA derived AT READ TIME
// (never stored — a stored `live` lies the instant the heartbeat stops, C6);
// the §4.5 projection JOINS the Work plane (beads/Dolt — stays work-truth, no
// plane split) with Coordinator state with NO WRITE PATH FROM ANY READER.
//
// THE AD1 PAYOFF (same structural guarantee as CF.5/CF.6/CF.9): the §1.1
// heartbeat ingest is a read-prior→merge→persist over the §4.2 RunnerState
// envelope; it composes on CF.1's ONE gated write path `_writeRecord` (§0.3
// re-enforced + §9.1 principal STAMPED there, never a use-site literal — C7),
// EXACTLY as the bash `co__heartbeat` ends in `co__store_put`. It mirrors the
// substrate's own desired-write RMW (`opSetDesired`) byte-for-byte in shape —
// no hand-rolled latch (the single-threaded Coordinator DO is the critical
// section). `reconcile` and `work-snapshot` are READ-ONLY: they invoke NO
// write primitive, so the §4.5 no-reader-write-path invariant holds BY
// CONSTRUCTION (not a runtime check).
//
// MUST-NOT-TOUCH (bound by the CF.3 issue):
//   • CF.1 substrate (store/auth/§9.1 chokepoint/`opPoll` transport) — CF.3
//     LAYERS on it: `reconcile` calls CF.1 `opPoll` (the liveness-free
//     TRANSPORT) and ADDS the §2.4 SEMANTICS (derive liveness, surface the
//     honest desired≠actual mismatch). `opPoll` itself is byte-unchanged and
//     stays liveness-free (the CF.1 differential asserts that opaque
//     boundary). New ops cross the SAME §2.3/§9.1 front door — they are NOT a
//     fifth §2 capability (CAPABILITIES stays EXACTLY four, untouched).
//   • Lease arbitration / generation fencing — CF.2. This tier only READS a
//     Lease record (via `opPoll`) to SURFACE it; it arbitrates none.
//   • Capacity aggregation VALUES — CF.4. The capacity strip is RENDERED
//     here (the §4.5 contract slot) but the VERDICT is CF.4's coarse
//     §6.3 aggregation. CF.4 is independent and not yet built; mirroring the
//     bash `cap="$(co__ask_capacity standard …)"; [[ -n "$cap" ]] || cap=
//     "unknown"`, an absent aggregation surface degrades to "unknown" —
//     behaviour-identical to the bash oracle when capacity is unavailable.
//     CF.4 surfaces its verdict through THIS exact strip slot; CF.3 computes
//     no 5h/7d numbers and reaches into no CF.4 surface.
//   • Forensic stream — CF.5. Structurally ABSENT from the projection: this
//     producer reads ONLY the §4 `records` table (runner_state/dossier) + the
//     passed work-truth; it never touches CF.5's SEPARATE transient
//     namespace, so the §10 stream is never in the §4.5 projection BY
//     CONSTRUCTION.
//   • Dossier §5 body/items production — CF.6. The WAITING-ON-YOU lane reads
//     stored Dossier item-state COUNTS ONLY (a partly-answered dossier still
//     shows until its last item resolves — AD7); it produces/interprets NO
//     Dossier content.
//   • §4.5 projection RENDERING in the browser — CF.10. CF.3 emits the DATA
//     (derived liveness + honest desired/actual); it renders nothing.
//
// ANTI-DRIFT: binds FROZEN INTERFACE.md v1 §4.2/§4.5/§2.4 + §0.5 STALE_AFTER.
// The bound version + the §4.5 `read_only:true`/`schema_version:1` are the
// frozen contract. An INTERFACE gap ⇒ reopen claude-tools-65z, bump+re-freeze
// — NEVER diverge, NEVER edit INTERFACE.md. (No gap: §4.2 fully defines
// `actual` + `last_heartbeat_at` + the `liveness` derivation, §2.4 the
// reconnect contract, §4.5 the projection shape, §0.5 STALE_AFTER=180s.)
// Oracle = lib/coordinator.sh co__reconcile/co__work_snapshot/co__heartbeat/
// co__derive_liveness + lib/test-coordinator-reconcile.sh + lib/test-board.sh.
//
// ANTI-DRIFT (sibling): the top-level `machines[]` slot ALSO binds FROZEN
// MACHINE-STATE.md v1 (D2). The projection reads `machine_state_reports`
// (the SEPARATE namespace cf/src/machine-state.js owns) — pure read, no
// _serialize (§2.4) — and derives `fresh` + `age_seconds` at projection time
// (§3.A) from `USAGE_POLL_TTL_SECONDS` (server-side; the Board only sees the
// boolean). `projects[].capacity_strip` is DROPPED by C3 per §3.B; §4.5's
// "5h%/7d%/today_spare_line%/actual_7d%" wording is now satisfied by
// `machines[]` carrying them as the per-machine header strip. A D2 gap ⇒
// reopen D2, bump+re-freeze — NEVER diverge, NEVER edit MACHINE-STATE.md.
// Oracle = MACHINE-STATE.md + test-fixtures/machine-state-v1.json +
// cf/test/reconcile.spec.js (the §3.A field-set conformance assertions).

import { safeKey } from "./schema.js";

// The three ops CF.3 owns. Disjoint from the CF.1 substrate switch and every
// sibling op set (DOSSIER_OPS/NOTIFICATION_OPS/FORENSIC_OPS) — dispatched in a
// dedicated guard so the CF.1 substrate stays byte-identical.
export const RECONCILE_OPS = new Set([
  "heartbeat", // co__heartbeat   — §1.1 item-3 UPWARD actual-state ingest (a WRITE)
  "reconcile", // co__reconcile   — §2.4 deliver-desired-state-on-reconnect SEMANTICS (read)
  "work-snapshot", // co__work_snapshot — §4.5 read-only projection PRODUCER (read)
  // claude-tools-8dfb (epic claude-tools-vvgy) — §4.6 workspace_inventory v1
  // INGEST. UPWARD WRITE in the same family as `heartbeat`: it composes on
  // CF.1's ONE gated `_writeRecord` path (§0.3 + §9.1 principal stamp THERE),
  // mirrors the heartbeat validation/stamping shape, and lives in the same
  // RECONCILE_OPS guard so the CF.1 substrate switch stays byte-identical.
  // One row per workspace (`type=workspace_inventory`, `id=project_ref`),
  // overwritten on each write (this is a periodic snapshot, NOT history).
  "workspace-inventory-put",
]);

// ── §0.5 STALE_AFTER — the S-1 liveness boundary, env-overridable, dflt 180 ──
// 1:1 with bash `co__STALE_AFTER() { echo "${STALE_AFTER:-180}"; }` and the
// CF.1/CF.5 env-overridable-constant precedent (schema.js PRINCIPAL_V1 /
// forensic.js forensicBlobTtl). `:-` keeps a present non-empty value (so an
// explicit "10" — the boundary-move arm test-coordinator-reconcile.sh
// exercises — is honoured). Single normative definition is INTERFACE.md §0.5;
// this is an env-overridable lookup whose literal default EQUALS the frozen
// table value (180 s), NEVER a competing normative value.
export function staleAfterSeconds(env) {
  const v = env && env.STALE_AFTER;
  if (v === undefined || v === null || String(v).length === 0) return 180;
  const n = Number(v);
  return Number.isFinite(n) && n >= 0 ? Math.floor(n) : 180;
}

// ── USAGE_POLL_TTL_SECONDS — D2 §1 cadence constant, env-overridable ──────────
// Single normative definition is MACHINE-STATE.md §1 (cadence) + §3.A (freshness
// derivation: `fresh = age_seconds ≤ 2 × USAGE_POLL_TTL_SECONDS`). Default 300 s
// matches the daemon's USAGE_POLL_TTL_SECONDS literal (daemon/usage-poll.sh:69).
// The constant stays SERVER-SIDE — the Board only ever sees the derived `fresh`
// boolean per §3.A, so adjusting the cutoff is a snapshot-side change and never
// requires a Board redeploy. `:-` keeps a present non-empty value (mirrors the
// STALE_AFTER env override discipline above).
export function usagePollTtlSeconds(env) {
  const v = env && env.USAGE_POLL_TTL_SECONDS;
  if (v === undefined || v === null || String(v).length === 0) return 300;
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : 300;
}

// The §4.2 `actual` enum is CLOSED (INTERFACE.md §4.2): runner-reported state
// ∈ {starting,running,idle,stopping,stopped,crashed}. An out-of-enum actual is
// rejected at the §1.1 ingest door (a contract value, not free text). 1:1 with
// bash co__actual_ok.
const ACTUAL_ENUM = new Set([
  "starting",
  "running",
  "idle",
  "stopping",
  "stopped",
  "crashed",
]);
function actualOk(a) {
  return ACTUAL_ENUM.has(a);
}

// co__derive_liveness — THE S-1 derivation (INTERFACE §4.2): `live` iff
// now − last_heartbeat_at ≤ STALE_AFTER, else `stale`. DERIVED AT READ TIME,
// NEVER stored (C6: a stored `live` lies the instant the heartbeat stops).
//
// HONEST degradation (S-1/C6 — liveness is data, never a masking lie), in the
// SAME precedence as the bash impl:
//   1. an UNREADABLE "now" (a non-finite clock read) ⇒ `stale` — recency is
//      unestablishable, and defaulting now=0 would falsely derive `live` for
//      any real heartbeat, exactly the lie this datum forbids (checked BEFORE
//      the heartbeat parse, mirroring bash `date -u +%s || { echo stale; }`);
//   2. a missing / unparseable last_heartbeat_at ⇒ `stale` (a runner never
//      heard from is honestly stale).
// Comparison is in WHOLE seconds (the bash `date +%s` epoch is integer
// seconds; floor both sides so the boundary is behaviour-identical). An
// explicit `nowMs` (the read-time clock the caller already sampled) is honored
// even when it differs from wall-clock — mirroring the bash optional 2nd
// `now_epoch` arg (test-coordinator-reconcile.sh: explicit-now honored when
// the bare clock read is shadowed dead).
//
// Exported: the bash oracle ALSO drops to the in-process `co__derive_liveness`
// predicate for exactly the unreadable-clock / explicit-now honest-degradation
// arms (those cannot be exercised through the op, which always samples its own
// clock) — so the differential mirrors that with a direct call.
export function deriveLiveness(hb, nowMs, staleAfterSec) {
  const now = nowMs === undefined ? Date.now() : nowMs;
  if (!Number.isFinite(now)) return "stale"; // (1) unreadable clock ⇒ honest stale
  if (!hb) return "stale";
  const hbMs = Date.parse(hb);
  if (!Number.isFinite(hbMs)) return "stale"; // (2) unparseable hb ⇒ honest stale
  const nowSec = Math.floor(now / 1000);
  const hbSec = Math.floor(hbMs / 1000);
  return nowSec - hbSec <= staleAfterSec ? "live" : "stale";
}

// RFC-3339 UTC `…Z` (§0.4), seconds precision, matching the substrate's own
// `opSetDesired` timestamp shape (and the bash `+%Y-%m-%dT%H:%M:%SZ`).
function nowIso() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

// Mirror the bash `jq -r '.<field> // ""'` field extraction VERBATIM (the
// shape co__heartbeat uses for project_ref / actual / current_task_ref /
// observed_at). jq's `//` treats ONLY null and false as the default-trigger
// (NOT 0 / NOT ""); `jq -r` prints a scalar as its raw text and a non-scalar
// as compact JSON. So a §1.1 line with a NUMBER project_ref ("123") ingests
// IDENTICALLY to the bash oracle (stringified then safe-key'd / enum-checked /
// stored verbatim), not rejected by a stricter typeof gate — behaviour-
// identity at the ingest door, not a local hardening.
function jqStr(v) {
  if (v === undefined || v === null || v === false) return "";
  if (typeof v === "string") return v;
  if (typeof v === "number" || v === true) return String(v);
  try {
    return JSON.stringify(v);
  } catch {
    return "";
  }
}

// ── normalizeQueueHealth — the §9 / Contract B.1 queue_health sub-block ───────
// claude-tools-uxvq1 (epic claude-tools-mhcp, track Q). queue_health is OPTIONAL
// ADDITIVE telemetry the runner publishes in its §4.6 workspace_inventory record
// (the only tier with bd access — same posture as counts/`verified`). This
// COERCES any input to the FROZEN B.1 shape, defaulting every missing/malformed
// field to a safe value. It does NOT 422 a malformed optional sub-block — a
// reject there would void the whole inventory write over telemetry the contract
// marks optional (the ztb6 canary-422 scar; the same tolerance `verified`
// follows). Used at BOTH the write boundary (persist the normalized block) and
// the read projection (defend a legacy/partial stored block). A null/absent
// input yields the honest all-zero block so projects[].queue_health is UNIFORM
// per B.1 — the Board's empty-queue explainer + net-velocity alarm read it
// directly and never have to special-case "absent".
function intOr0(v) {
  return typeof v === "number" && Number.isFinite(v) && Math.floor(v) === v ? v : 0;
}
function normalizeQueueHealth(qh) {
  const o = qh && typeof qh === "object" && !Array.isArray(qh) ? qh : {};
  const held = o.held && typeof o.held === "object" && !Array.isArray(o.held) ? o.held : {};
  const epics = Array.isArray(o.epics_with_zero_ready_children)
    ? o.epics_with_zero_ready_children.filter((x) => typeof x === "string" && x.length > 0)
    : [];
  // net_velocity_7d is the ONE field that may be NEGATIVE (more closed than
  // created — a healthy, draining queue), so it is NOT floored at 0; it is
  // coerced to a finite integer (rounded — the producer emits an integer, but a
  // legacy/float value is rounded to a stable surfaced number), default 0.
  const nv =
    typeof o.net_velocity_7d === "number" && Number.isFinite(o.net_velocity_7d)
      ? Math.round(o.net_velocity_7d)
      : 0;
  return {
    ready: intOr0(o.ready),
    held: {
      gate: intOr0(held.gate),
      dependency: intOr0(held.dependency),
      scheduled: intOr0(held.scheduled),
    },
    hidden_under_deferred_parent: intOr0(o.hidden_under_deferred_parent),
    net_velocity_7d: nv,
    epics_with_zero_ready_children: epics,
  };
}

// ── normalizeHeldBeads — the §4.6 held_beads channel (J2 claude-tools-uxvj2) ───
// The per-bead holds[] SOURCE the runner publishes (the blocked/deferred/gated
// beads the active in_progress/top_n lists exclude — §3.3). OPTIONAL ADDITIVE at
// schema_version 1 (the verified/queue_health precedent) and TOLERANTLY coerced —
// a malformed/absent block NEVER 422s the inventory write (the ztb6 canary-422
// scar; this is optional telemetry, not a contract value like counts). Each
// element is reshaped to exactly {bead_ref,title,status,stage,labels,blocked_on,
// deferred_until}; a non-object element or one with no bead_ref is dropped.
function normalizeHeldBeads(hb) {
  if (!Array.isArray(hb)) return [];
  const out = [];
  for (const b of hb) {
    if (!b || typeof b !== "object" || Array.isArray(b)) continue;
    if (typeof b.bead_ref !== "string" || b.bead_ref.length === 0) continue;
    out.push({
      bead_ref: b.bead_ref,
      title: typeof b.title === "string" ? b.title : "",
      status: typeof b.status === "string" ? b.status : "",
      stage: typeof b.stage === "string" && b.stage.length > 0 ? b.stage : "unknown",
      labels: Array.isArray(b.labels) ? b.labels.filter((x) => typeof x === "string") : [],
      blocked_on:
        typeof b.blocked_on === "string" && b.blocked_on.length > 0 ? b.blocked_on : null,
      deferred_until:
        typeof b.deferred_until === "string" && b.deferred_until.length > 0
          ? b.deferred_until
          : null,
    });
  }
  return out;
}

// Read a stored §4 record exactly the way CF.1 `opGet` / the bash
// `co__store_get` does — a byte-identical typed SELECT (the SAME accepted
// read-side pattern CF.6 `getRawDossier` / CF.9 `getRaw` document, NOT a reach
// past the surface). Returns the parsed object, or null (absent/corrupt).
async function getRecord(co, type, id) {
  const row = await co.db
    .prepare("SELECT json FROM records WHERE type = ? AND id = ?")
    .bind(type, id)
    .first();
  if (!row) return null;
  try {
    const o = JSON.parse(row.json);
    return o && typeof o === "object" && !Array.isArray(o) ? o : null;
  } catch {
    return null;
  }
}

// ── co__heartbeat — §1.1 item-3 INGEST of the UPWARD actual-state+liveness ───
// Consumes T3's §1.1 outbox heartbeat line VERBATIM (report=="heartbeat").
// Enforces, IN THE SAME ORDER as the bash impl + the §4 store:
//   1. valid JSON object with report=="heartbeat";
//   2. §0.3 — `schema_version` is an INTEGER (a string "1"/float/bool is
//      rejected); an unknown HIGHER version is REJECTED (never
//      best-effort-parsed); the engine binds v1 so any other value is
//      unsupported ⇒ reject;
//   3. closed §4.2 `actual` enum; non-empty SAFE project_ref (§1.1 stamp /
//      store-owner input hygiene);
//   4. §9.1 — the RESOLVED principal is STAMPED (the report's literal is
//      OVERWRITTEN — done by CF.1 `_writeRecord`, never a use-site literal).
// `observed_at` (the wire timestamp) IS last_heartbeat_at — THE S-1 datum;
// absent ⇒ stamped now. MERGES onto the prior RunnerState envelope setting
// ONLY actual / last_heartbeat_at / current_task_ref / updated_at — the
// COORDINATOR-OWNED desired / last_desired_actor are PRESERVED untouched
// (§1.1: the runner never originates desired). Persisted through CF.1's ONE
// gated write path `_writeRecord` (the legitimate up→down write, NOT a reader
// write) — mirroring `co__heartbeat` ending in `co__store_put`, byte-for-byte
// the shape of the substrate's own `opSetDesired`. Nothing persisted on any
// rejection.
async function heartbeat(co, principal, jsonStr) {
  if (jsonStr === undefined || jsonStr === null || jsonStr === "") {
    return jsonRes({ ok: false, error: "co: heartbeat needs <report_json>" }, 422);
  }
  let parsed;
  try {
    parsed = JSON.parse(jsonStr);
  } catch {
    parsed = null;
  }
  if (
    !parsed ||
    typeof parsed !== "object" ||
    Array.isArray(parsed) ||
    parsed.report !== "heartbeat"
  ) {
    return jsonRes(
      {
        ok: false,
        error:
          'co: reject — not a §1.1 heartbeat report (report!="heartbeat" / invalid JSON)',
      },
      422
    );
  }
  const sv = parsed.schema_version;
  const isInt = typeof sv === "number" && Number.isFinite(sv) && Math.floor(sv) === sv;
  if (!isInt) {
    return jsonRes(
      {
        ok: false,
        error: "co: reject — heartbeat missing integer schema_version (§1.1/§0.3)",
      },
      422
    );
  }
  if (sv > 1) {
    return jsonRes(
      {
        ok: false,
        error: `co: reject — heartbeat schema_version ${sv} is an unknown higher version (bound=1; §0.3 reject, never best-effort-parse)`,
      },
      422
    );
  }
  if (sv !== 1) {
    return jsonRes(
      {
        ok: false,
        error: `co: reject — heartbeat schema_version ${sv} unsupported (binds v1 only; §0.3)`,
      },
      422
    );
  }
  // Extract the §1.1 fields EXACTLY as the bash `jq -r '.X // ""'` does (a
  // JSON number/boolean stringifies; null/false/absent ⇒ "") — so a numeric
  // project_ref ingests behaviour-identically to the oracle, never rejected
  // by a stricter JS typeof gate.
  const proj = jqStr(parsed.project_ref);
  const act = jqStr(parsed.actual);
  const cur = jqStr(parsed.current_task_ref);
  let hb = jqStr(parsed.observed_at);
  if (!proj || !safeKey(proj)) {
    return jsonRes(
      {
        ok: false,
        error: `co: reject — heartbeat project_ref '${proj}' missing/unsafe (§1.1 stamp; store-owner input hygiene)`,
      },
      422
    );
  }
  if (!actualOk(act)) {
    return jsonRes(
      {
        ok: false,
        error: `co: reject — heartbeat actual '${act}' not in §4.2 enum {starting,running,idle,stopping,stopped,crashed}`,
      },
      422
    );
  }
  if (!hb) hb = nowIso();
  const now = nowIso();
  // The runner-reported half is the only thing flowing up; a corrupt/absent
  // prior envelope MUST NOT wedge it (mirrors opSetDesired's degrade) — fall
  // back to a fresh base. desired/last_desired_actor are COORDINATOR-OWNED: a
  // fresh base simply has none yet; a merge onto an existing record leaves
  // whatever desired the Coordinator already set intact (the §1.1 line's own
  // `principal` literal is NEVER copied in — it is the §9.1-stamped resolved
  // principal that wins, applied by `_writeRecord`).
  const prev = (await getRecord(co, "runner_state", proj)) || {};
  const base = { ...prev };
  base.project_ref = proj;
  base.schema_version = 1;
  base.actual = act;
  base.last_heartbeat_at = hb;
  base.updated_at = now;
  // claude-tools-lv9c — current_task_ref must be AUTHORITATIVE per heartbeat:
  // an `hb idle` (producer omits the field ⇒ jqStr→"") must CLEAR the prior
  // value, not preserve it via `...prev`. Old runners that omit on idle now get
  // the semantically-correct behaviour. board-view.js already treats null,
  // missing, and "" identically.
  base.current_task_ref = cur || null;
  const w = await co._writeRecord(principal, "runner_state", proj, base);
  if (!w.ok) return jsonRes({ ok: false, code: w.code, error: w.msg }, 422);
  return jsonRes({ ok: true });
}

// ── workspace-inventory-put — §4.6 workspace_inventory v1 INGEST ─────────────
// claude-tools-8dfb (epic claude-tools-vvgy). The CF-side WRITE endpoint that
// the workspace runner producer (separate child) posts to. Validation mirrors
// `heartbeat` above for shape parity:
//   1. valid JSON object with report=="workspace_inventory";
//   2. §0.3 — `schema_version` is an INTEGER (a string "1"/float/bool is
//      rejected); an unknown HIGHER version is REJECTED (never best-effort-
//      parsed); the engine binds v1 so any other value is unsupported ⇒ reject;
//   3. `project_ref` is a non-empty SAFE key (§1.1 stamp / store-owner input
//      hygiene — same gate the substrate's `_writeRecord`/safeKey applies);
//   4. `observed_at` is RFC-3339 UTC `…Z` (§0.4) and is not absurdly old (the
//      h7n-style pre-2024 guard — a malformed/clock-bug timestamp would lie
//      about freshness; mirrors the heartbeat S-1 discipline);
//   5. `counts` is an object with all four required INTEGER keys
//      {open, ready, in_progress, blocked} — a missing or non-int count is a
//      contract value, not "best-effort 0";
//   6. `in_progress_beads` is an array (may be empty); each element MUST carry
//      string `bead_ref` + `title` + `stage`, and MAY carry boolean `verified`
//      (claude-tools-7qf7 — optional additive at v1, default false; see below);
//   7. `top_n_beads` is REQUIRED (array, may be empty); each element MUST carry
//      string `bead_ref` + `title` + `status` + `stage` (and MAY carry the same
//      optional `verified`). No hard cap on length at the write boundary —
//      bounding is the producer's concern (the §4.6 contract notes "a small
//      bounded array of top-N most-recently-touched").
// The wire `principal` field is OVERWRITTEN by the resolved §9.1 principal
// inside `_writeRecord` (NEVER trust the wire's principal — same C7 discipline
// `heartbeat` follows). Persisted through CF.1's ONE gated `_writeRecord` with
// type='workspace_inventory', id=project_ref — one row per workspace,
// INSERT OR REPLACE on each write (no append, no historical accumulation).
// Nothing persisted on any rejection.
const ISO_Z_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/;
async function workspaceInventoryPut(co, principal, jsonStr) {
  if (jsonStr === undefined || jsonStr === null || jsonStr === "") {
    return jsonRes(
      { ok: false, error: "co: workspace-inventory-put needs <report_json>" },
      422
    );
  }
  let parsed;
  try {
    parsed = JSON.parse(jsonStr);
  } catch {
    parsed = null;
  }
  if (
    !parsed ||
    typeof parsed !== "object" ||
    Array.isArray(parsed) ||
    parsed.report !== "workspace_inventory"
  ) {
    return jsonRes(
      {
        ok: false,
        error:
          'co: reject — not a §4.6 workspace_inventory report (report!="workspace_inventory" / invalid JSON)',
      },
      422
    );
  }
  const sv = parsed.schema_version;
  const isInt = typeof sv === "number" && Number.isFinite(sv) && Math.floor(sv) === sv;
  if (!isInt) {
    return jsonRes(
      {
        ok: false,
        error:
          "co: reject — workspace_inventory missing integer schema_version (§4.6/§0.3)",
      },
      422
    );
  }
  if (sv > 1) {
    return jsonRes(
      {
        ok: false,
        error: `co: reject — workspace_inventory schema_version ${sv} is an unknown higher version (bound=1; §0.3 reject, never best-effort-parse)`,
      },
      422
    );
  }
  if (sv !== 1) {
    return jsonRes(
      {
        ok: false,
        error: `co: reject — workspace_inventory schema_version ${sv} unsupported (binds v1 only; §0.3)`,
      },
      422
    );
  }
  const proj = jqStr(parsed.project_ref);
  if (!proj || !safeKey(proj)) {
    return jsonRes(
      {
        ok: false,
        error: `co: reject — workspace_inventory project_ref '${proj}' missing/unsafe (§1.1 stamp; store-owner input hygiene)`,
      },
      422
    );
  }
  const obs = jqStr(parsed.observed_at);
  if (!obs || !ISO_Z_RE.test(obs)) {
    return jsonRes(
      {
        ok: false,
        error: `co: reject — workspace_inventory observed_at '${obs}' is not RFC-3339 UTC '…Z' (§0.4)`,
      },
      422
    );
  }
  const obsMs = Date.parse(obs);
  if (!Number.isFinite(obsMs) || obsMs < Date.parse("2024-01-01T00:00:00Z")) {
    return jsonRes(
      {
        ok: false,
        error: `co: reject — workspace_inventory observed_at '${obs}' pre-2024 / unparseable (S-1 freshness guard)`,
      },
      422
    );
  }
  const counts = parsed.counts;
  if (!counts || typeof counts !== "object" || Array.isArray(counts)) {
    return jsonRes(
      {
        ok: false,
        error: "co: reject — workspace_inventory counts must be an object with {open,ready,in_progress,blocked} integers",
      },
      422
    );
  }
  for (const k of ["open", "ready", "in_progress", "blocked"]) {
    const v = counts[k];
    const ok =
      typeof v === "number" && Number.isFinite(v) && Math.floor(v) === v;
    if (!ok) {
      return jsonRes(
        {
          ok: false,
          error: `co: reject — workspace_inventory counts.${k} missing/non-integer (got ${JSON.stringify(v)})`,
        },
        422
      );
    }
  }
  const ip = parsed.in_progress_beads;
  if (!Array.isArray(ip)) {
    return jsonRes(
      {
        ok: false,
        error: "co: reject — workspace_inventory in_progress_beads must be an array (may be empty)",
      },
      422
    );
  }
  for (let i = 0; i < ip.length; i++) {
    const b = ip[i];
    if (!b || typeof b !== "object" || Array.isArray(b)) {
      return jsonRes(
        {
          ok: false,
          error: `co: reject — workspace_inventory in_progress_beads[${i}] is not an object`,
        },
        422
      );
    }
    for (const k of ["bead_ref", "title", "stage"]) {
      if (typeof b[k] !== "string" || b[k].length === 0) {
        return jsonRes(
          {
            ok: false,
            error: `co: reject — workspace_inventory in_progress_beads[${i}].${k} missing/non-string`,
          },
          422
        );
      }
    }
  }
  const tn = parsed.top_n_beads;
  if (!Array.isArray(tn)) {
    return jsonRes(
      {
        ok: false,
        error: "co: reject — workspace_inventory top_n_beads required (array, may be empty)",
      },
      422
    );
  }
  for (let i = 0; i < tn.length; i++) {
    const b = tn[i];
    if (!b || typeof b !== "object" || Array.isArray(b)) {
      return jsonRes(
        {
          ok: false,
          error: `co: reject — workspace_inventory top_n_beads[${i}] is not an object`,
        },
        422
      );
    }
    for (const k of ["bead_ref", "title", "status", "stage"]) {
      if (typeof b[k] !== "string" || b[k].length === 0) {
        return jsonRes(
          {
            ok: false,
            error: `co: reject — workspace_inventory top_n_beads[${i}].${k} missing/non-string`,
          },
          422
        );
      }
    }
  }
  // Build the persisted envelope. The wire's `principal` field (if any) is
  // discarded — `_writeRecord` stamps the §9.1-resolved principal AFTER the
  // §0.3 gate, OVERWRITING whatever literal the report carried. `runner_id`
  // is carried through verbatim (informational; not part of validation).
  const now = nowIso();
  const obj = {
    schema_version: 1,
    project_ref: proj,
    runner_id: jqStr(parsed.runner_id),
    observed_at: obs,
    counts: {
      open: counts.open,
      ready: counts.ready,
      in_progress: counts.in_progress,
      blocked: counts.blocked,
    },
    in_progress_beads: ip.map((b) => ({
      bead_ref: b.bead_ref,
      title: b.title,
      stage: b.stage,
      // `verified` (claude-tools-7qf7) — OPTIONAL additive field at v1 (no
      // schema_version bump; the same posture as the §4.5 projection card that
      // added `verified` in uxg2 and `kind:"pair"`/`scheduled_at` in uxg6).
      // STRICT boolean: only literal `true` survives; absent/non-bool ⇒ false
      // (un-probed is NOT verified). This is the done·code-vs-done·verified
      // SOURCE the GET-path lifecycle join reads back (see workSnapshot below).
      verified: b.verified === true,
    })),
    top_n_beads: tn.map((b) => ({
      bead_ref: b.bead_ref,
      title: b.title,
      status: b.status,
      stage: b.stage,
      verified: b.verified === true,
    })),
    // queue_health (claude-tools-uxvq1, §9 / B.1) — OPTIONAL additive at v1 (no
    // schema_version bump; the `verified`/`machines[]`/`intake[]` additive
    // precedent). Tolerantly normalized to the frozen B.1 shape and persisted
    // ALWAYS (zeroed default when absent) so projects[].queue_health is uniform
    // in the projection; a malformed block NEVER 422s the inventory write.
    queue_health: normalizeQueueHealth(parsed.queue_health),
    // held_beads (claude-tools-uxvj2, §4.6 / J2) — the per-bead holds[] SOURCE
    // (blocked/deferred/gated beads). OPTIONAL ADDITIVE at v1, tolerantly coerced
    // (never 422s the write — the queue_health posture); persisted ALWAYS ([] when
    // absent) so readHeldBeads has a uniform shape. The §4.5 workSnapshot reads it
    // back into projects[].holds.
    held_beads: normalizeHeldBeads(parsed.held_beads),
    updated_at: now,
  };
  const w = await co._writeRecord(principal, "workspace_inventory", proj, obj);
  if (!w.ok) return jsonRes({ ok: false, code: w.code, error: w.msg }, 422);
  return jsonRes({ ok: true });
}

// ── co__reconcile — §2.4 deliver-desired-state-on-reconnect SEMANTICS ────────
// Returns the CURRENT desired + that runner's lease state, ENRICHED with the
// §4.2 `liveness` DERIVED at read time and `actual` surfaced HONESTLY (the
// `desired ≠ actual` mismatch is a flag, never masked). Reconciliation (the
// current desired-state delivered on reconnect), NOT a durable command queue:
// it returns what is stored NOW (a runner that slept through a desired change
// gets the new desired on its next reconcile). LAYERS on CF.1's `opPoll`
// TRANSPORT (byte-unchanged, stays liveness-free — anti-drift); the liveness
// derivation + the honest mismatch flag are the SEMANTICS this tier ADDS.
// Reads the Lease record ONLY to surface it (no arbitration — CF.2). PURE
// READ: no write primitive is invoked.
async function reconcileData(co, principal, proj, leaseId) {
  // Layer on the CF.1 §2.4 transport exactly as bash co__reconcile calls
  // co__poll. opPoll is read-only (typed SELECTs) and always answers 200/json.
  let base = {};
  try {
    const res = await co.opPoll(principal, proj, leaseId);
    base = await res.json();
  } catch {
    base = {};
  }
  if (!base || typeof base !== "object" || Array.isArray(base)) base = {};
  const rs =
    base.runner_state && typeof base.runner_state === "object" && !Array.isArray(base.runner_state)
      ? base.runner_state
      : {};
  const hb = typeof rs.last_heartbeat_at === "string" ? rs.last_heartbeat_at : "";
  const liveness = deriveLiveness(hb, Date.now(), staleAfterSeconds(co.env));
  const desired = base.desired ?? null;
  const actual = rs.actual ?? null;
  return {
    // Mirror the bash `co__reconcile` main jq `principal:.principal` EXACTLY:
    // in the normal path `opPoll` always sets `principal` to the resolved
    // principal (so this is "brian", behaviour-identical); in the degraded
    // poll-failure path bash emits `principal:null` (jq on base='{}') — so
    // fall to null, NOT the resolved literal, to stay oracle-faithful even in
    // the substrate-down corner.
    principal: base.principal ?? null,
    project_ref: proj,
    desired,
    actual,
    liveness,
    last_heartbeat_at: rs.last_heartbeat_at ?? null,
    current_task_ref: rs.current_task_ref ?? null,
    updated_at: rs.updated_at ?? null,
    lease: base.lease ?? null,
    desired_actual_mismatch:
      desired !== null && actual !== null && desired !== actual,
  };
}

// ── co__work_snapshot — §4.5 the READ-ONLY projection PRODUCER ───────────────
// JOINS the Work plane (beads/Dolt — passed in as the work-truth read; the
// Coordinator NEVER duplicates/owns beads, so Dolt stays work-truth, no plane
// split) with Coordinator state. <beadsStr>, when given, is a JSON array of
// bead cards [{bead_ref,title,stage,priority,age,failure,waiting_on}…]; absent
// / non-array ⇒ an empty Work-plane side (the Coordinator-side projection is
// still honestly produced — the Coordinator never fabricates work-truth).
//
// Per project it carries: the RunnerState (desired + actual + liveness DERIVED
// via reconcile); the capacity strip RENDERED here (the §4.5 contract slot)
// with the VERDICT SURFACED from CF.4's §6.3 aggregation — absent ⇒ "unknown"
// (behaviour-identical to the bash oracle when co__ask_capacity is
// unavailable; CF.4 is independent and not yet built). The lifecycle columns
// (idea│ux│design│impl│docs│tests│done) keyed by each bead's `stage:` label
// (a bead with no/unknown stage buckets under "" — honest: un-staged, NOT
// silently impl). The WAITING-ON-YOU lane = stored Dossiers (this principal)
// with ≥1 still-open item — item-state COUNTS ONLY (a partly-answered dossier
// still shows until its last item resolves — AD7); no Dossier content
// produced/interpreted (CF.6). Per-bead failure metadata from the work-truth
// join (the §10 forensic stream is NEVER here — structurally absent).
//
// NO WRITE PATH FROM ANY READER (§4.5): this reads stored records + the passed
// work-truth and emits JSON ONLY. It invokes NO `_writeRecord` / `opPut` /
// `opSetDesired` / `heartbeat` and runs reconcile's READ-only path — the
// no-reader-write-path invariant holds BY CONSTRUCTION. `work_snapshot` IS a
// §4 type (CF.1 registry) for the publisher's STORED envelope; this READ-side
// producer is a DIFFERENT path and never persists.

// ── beadsFromWorkspaceInventory — the GET-path lifecycle work-truth source ────
// (claude-tools-7qf7). Reprojects the runner-published §4.6 workspace_inventory
// records into the flat bead-card array `workSnapshot` buckets into the §4.5
// lifecycle ladder. Reads ONLY (no write primitive); honest empty on any miss
// (no table, no row, parse error) — never fabricates work-truth. `proj` scopes
// to one workspace (the proxy's optional read filter); absent ⇒ all stored
// inventories. Aggregates each record's `in_progress_beads[]` + `top_n_beads[]`
// and dedups by `bead_ref` (a bead can appear in both lists / across machines).
// `verified` is monotonic across duplicates: ANY occurrence marking the bead
// verified wins (the probe-passed fact does not un-fire). Cards inherit only
// what the §4.6 inventory carries (bead_ref/title/stage/verified); priority,
// age, waiting_on, and failure are absent here and the card() builder defaults
// them to null — honest "the inventory channel doesn't carry these yet."
async function beadsFromWorkspaceInventory(co, proj) {
  let rows = [];
  try {
    if (proj) {
      const r = await co.db
        .prepare("SELECT json FROM records WHERE type = ? AND id = ?")
        .bind("workspace_inventory", proj)
        .first();
      rows = r ? [r] : [];
    } else {
      const r = await co.db
        .prepare("SELECT json FROM records WHERE type = ? ORDER BY id")
        .bind("workspace_inventory")
        .all();
      rows = (r && r.results) || [];
    }
  } catch {
    return []; // table not yet created / read failure ⇒ honest empty
  }
  const byRef = new Map();
  for (const row of rows) {
    let rec;
    try {
      rec = JSON.parse(row.json);
    } catch {
      continue;
    }
    if (!rec || typeof rec !== "object" || Array.isArray(rec)) continue;
    const lists = [];
    if (Array.isArray(rec.in_progress_beads)) lists.push(rec.in_progress_beads);
    if (Array.isArray(rec.top_n_beads)) lists.push(rec.top_n_beads);
    for (const list of lists) {
      for (const b of list) {
        if (!b || typeof b !== "object" || Array.isArray(b)) continue;
        if (typeof b.bead_ref !== "string" || b.bead_ref.length === 0) continue;
        const entry = {
          bead_ref: b.bead_ref,
          title: typeof b.title === "string" ? b.title : null,
          stage: typeof b.stage === "string" ? b.stage : "",
          verified: b.verified === true,
        };
        const prev = byRef.get(b.bead_ref);
        if (!prev) {
          byRef.set(b.bead_ref, entry);
        } else if (!prev.verified && entry.verified) {
          // monotonic verified — keep the verified view of a duplicated bead
          byRef.set(b.bead_ref, entry);
        }
      }
    }
  }
  return Array.from(byRef.values());
}

// ════════════════════════════════════════════════════════════════════════════
// J2 (claude-tools-uxvj2) — the read-time holds[] unifier (DESIGN J §3 / B.1).
// Joins the THREE mechanisms that hold a ready-looking task into ONE array
// derived AT READ time (A.3 — never stored): our editable Gate (the gate:<id>
// label + the J1 gate_metadata annotation), beads-native dependency (blocked +
// blocked_on, read-only), beads-native scheduled (a defer date, read-only,
// optionally owned by a co-present gate). `editable` is true ONLY for gate — the
// projection itself encodes the C3 honesty rule so no UI can fake-edit a
// beads-native hold. The gate branch LEFT-joins gate_metadata; a gate label with
// no metadata row degrades per B.4 (null why/unblocks_when/owner/scope + a
// degraded[] note) — never dropped, never thrown.
// ════════════════════════════════════════════════════════════════════════════

// readGateMeta — bulk read of the J1 `gate_metadata` transient (cf/src/gate-meta.js
// owns the writes). Pure read ⇒ NO _serialize (the readActivity/readMachines
// precedent). The table is lazily created by gate-meta.js on first gate-meta-set;
// if no gate has ever been annotated the SELECT throws "no such table" and we
// honestly degrade to an EMPTY map (NEVER DDL from a reader — the §3.C posture).
// Keyed by the BARE gate id (the gate_id column = the <id> in gate:<id>);
// buildHolds strips the `gate:` label prefix to look a row up (the §3.2 bulk path:
// one read, then an in-memory map — avoids N queries).
async function readGateMeta(co) {
  const map = new Map();
  let results = [];
  try {
    const r = await co.db
      .prepare(
        "SELECT gate_id, why, unblock_condition, owner, scope, set_at FROM gate_metadata"
      )
      .all();
    results = (r && r.results) || [];
  } catch {
    return map; // table not yet created ⇒ honest empty (B.4)
  }
  for (const row of results) {
    if (row && typeof row.gate_id === "string" && row.gate_id.length > 0) {
      map.set(row.gate_id, row);
    }
  }
  return map;
}

// readHeldBeads — the PRODUCTION holds source for the GET path (the §4.6
// workspace_inventory `held_beads` channel the runner publishes). The inventory's
// in_progress_beads/top_n_beads deliberately carry only ACTIVE work (status open/
// in_progress) — a held bead is blocked/deferred and excluded from those lists —
// so the holds[] join needs its OWN published source (§3.3, the 56h trap: if the
// producer doesn't carry labels/blocked_on/deferred_until, the unifier can never
// see them). la_publish_workspace_inventory derives held_beads from its existing
// non-closed `bd list` read (the blocked + deferred + gate-labelled beads) and
// ships it ADDITIVELY (no schema bump — the verified/queue_health precedent).
// Pure read; honest empty on a missing table / row / parse error (never fabricates
// work-truth). `proj` scopes to one workspace; absent ⇒ every stored inventory
// (deduped by bead_ref so the all-projects rollup never double-counts).
async function readHeldBeads(co, proj) {
  let rows = [];
  try {
    if (proj) {
      const r = await co.db
        .prepare("SELECT json FROM records WHERE type = ? AND id = ?")
        .bind("workspace_inventory", proj)
        .first();
      rows = r ? [r] : [];
    } else {
      const r = await co.db
        .prepare("SELECT json FROM records WHERE type = ? ORDER BY id")
        .bind("workspace_inventory")
        .all();
      rows = (r && r.results) || [];
    }
  } catch {
    return []; // table not yet created / read failure ⇒ honest empty
  }
  const out = [];
  const seen = new Set();
  for (const row of rows) {
    let rec;
    try {
      rec = JSON.parse(row.json);
    } catch {
      continue;
    }
    if (!rec || typeof rec !== "object" || Array.isArray(rec)) continue;
    const hb = Array.isArray(rec.held_beads) ? rec.held_beads : [];
    for (const b of hb) {
      if (!b || typeof b !== "object" || Array.isArray(b)) continue;
      if (typeof b.bead_ref !== "string" || b.bead_ref.length === 0) continue;
      if (seen.has(b.bead_ref)) continue; // dedup across workspaces (all-projects mode)
      seen.add(b.bead_ref);
      out.push({
        bead_ref: b.bead_ref,
        // Defaults MIRROR normalizeHeldBeads (the write normalizer) so a bead that
        // round-trips through the store reads back with the same filler — title→"",
        // stage→"unknown" (buildHolds consumes neither today, but the read/write
        // pair claims one shape, so they agree before a facet renders these).
        title: typeof b.title === "string" ? b.title : "",
        stage: typeof b.stage === "string" && b.stage.length > 0 ? b.stage : "unknown",
        status: typeof b.status === "string" ? b.status : "",
        labels: Array.isArray(b.labels) ? b.labels.filter((x) => typeof x === "string") : [],
        blocked_on:
          typeof b.blocked_on === "string" && b.blocked_on.length > 0 ? b.blocked_on : null,
        deferred_until:
          typeof b.deferred_until === "string" && b.deferred_until.length > 0
            ? b.deferred_until
            : null,
      });
    }
  }
  return out;
}

// The gate label shape — mirrors gate-defer.sh `_is_valid_gate_id` / gate-meta.js
// `gateIdOk` with the `gate:` namespace prefix. A label outside this shape is NOT
// a gate (so `gateway`/`gate-foo:x` never false-match — the J4 anti-regression).
const GATE_LABEL_RE = /^gate:[a-z0-9][a-z0-9-]*$/;

// buildHolds — the unifier itself (DESIGN J §3.2). Reads ONLY the passed bead
// array (the same work-truth shape the lifecycle ladder consumes, enriched per
// §3.3 with labels/blocked_on/deferred_until). Order is deterministic for a
// stable UI: gate holds first (sorted by label), then dependency, then scheduled
// (both in bead order). The bash oracle co__work_snapshot derives the identical
// structure from the same bead arg (a true differential twin for the
// beads-derived shape); only the gate METADATA join is CF-side (the bash has no
// gate_metadata store — gates.md §6 — so it degrades every gate to the B.4
// null+degraded shape, the queue_health/current_task_title shape-parity posture).
function buildHolds(beads, gateMetaMap) {
  const gateCount = new Map(); // full "gate:<id>" label -> task_count
  const depHolds = [];
  const schedHolds = [];
  for (const b of beads) {
    if (!b || typeof b !== "object" || Array.isArray(b)) continue;
    const ref = typeof b.bead_ref === "string" ? b.bead_ref : null;
    const gateLabels = Array.isArray(b.labels)
      ? b.labels.filter((x) => typeof x === "string" && GATE_LABEL_RE.test(x))
      : [];
    for (const gl of gateLabels) {
      gateCount.set(gl, (gateCount.get(gl) || 0) + 1);
    }
    const blockedOn =
      typeof b.blocked_on === "string" && b.blocked_on.length > 0 ? b.blocked_on : null;
    if (blockedOn) {
      depHolds.push({
        type: "dependency",
        task_ref: ref,
        blocked_on: blockedOn,
        unblocks_when: `${blockedOn} closes`,
        editable: false,
      });
    }
    const deferredUntil =
      typeof b.deferred_until === "string" && b.deferred_until.length > 0
        ? b.deferred_until
        : null;
    if (deferredUntil) {
      schedHolds.push({
        type: "scheduled",
        task_ref: ref,
        deferred_until: deferredUntil,
        // owning_gate (§3.2 #3): the gate:<id> label co-present on the SAME bead,
        // if any — the gate-defer.sh coupling that lets the UI nest a Scheduled
        // hold under its Gate and show that lifting the gate clears the defer.
        owning_gate: gateLabels.length > 0 ? gateLabels[0] : null,
        unblocks_when: deferredUntil,
        editable: false,
      });
    }
  }
  const gateHolds = Array.from(gateCount.keys())
    .sort()
    .map((gl) => {
      const bareId = gl.slice(5); // strip the "gate:" label prefix → the row key
      const meta = gateMetaMap.get(bareId) || null;
      return {
        type: "gate",
        id: gl,
        task_count: gateCount.get(gl),
        owner: meta && typeof meta.owner === "string" ? meta.owner : null,
        set_at: meta && typeof meta.set_at === "string" ? meta.set_at : null,
        why: meta && typeof meta.why === "string" ? meta.why : null,
        // unblock_condition → unblocks_when (the B.1 field name, §3.2 #1)
        unblocks_when:
          meta && typeof meta.unblock_condition === "string"
            ? meta.unblock_condition
            : null,
        scope: meta && typeof meta.scope === "string" ? meta.scope : null,
        editable: true,
        // B.4 (§3.2 #1): a gate label with no metadata row is rendered honestly
        // (null why/unblock) with a degraded note — NEVER dropped, never thrown.
        degraded: meta ? [] : ["gate placed before metadata existed"],
      };
    });
  return gateHolds.concat(depHolds, schedHolds);
}

async function workSnapshot(co, principal, proj, beadsStr) {
  // Work-truth read (beads/Dolt). Default empty array if absent/invalid — the
  // Coordinator never fabricates work-truth (Dolt is the source).
  let beads = [];
  if (typeof beadsStr === "string" && beadsStr.length > 0) {
    try {
      const b = JSON.parse(beadsStr);
      if (Array.isArray(b)) beads = b;
    } catch {
      beads = [];
    }
  }
  // ── TRANSPORT wiring (claude-tools-7qf7) ────────────────────────────────────
  // The PRODUCTION Board GET path passes NO inline work-truth: the Pages proxy
  // GETs `?op=work-snapshot` and the cf/pages-dev adapter hard-codes the beads
  // arg to "" (a Worker cannot exec `bd` — adapter.js:argsForGet). So with only
  // the inline path, `lifecycle_columns` is EMPTY in prod regardless of stage,
  // and the §3 done·code/done·verified split (uxg2) stays correct-but-dormant.
  //
  // The honest live source is the ALREADY-PUBLISHED work-truth: the §4.6
  // workspace_inventory records the runner publishes (bd → la_publish_workspace_
  // inventory → daemon drain → workspace-inventory-put). When no inline beads
  // are supplied, derive the lifecycle work-truth from those stored records.
  // This NEVER fabricates work-truth — it reprojects what the runner published.
  //
  // Inline beads, when present, still WIN: the differential oracle
  // (lib/coordinator.sh) + every existing test drives this op with an inline
  // array, and that path stays byte-identical. The bash oracle deliberately has
  // NO workspace_inventory store (it is a CF-only §4.6 producer — coordinator.sh
  // co__work_snapshot notes this), so this fallback is CF-side production infra
  // with no bash twin; the SHARED projection SHAPE (card normalisation, the
  // stage ladder, `verified`) stays parallel.
  // J2 (claude-tools-uxvj2) — the holds[] SOURCE. The inline `beads` array carries
  // the per-bead labels/blocked_on/deferred_until directly (the bash-twin / live-
  // verify path), so it doubles as the holds source. The PRODUCTION GET path
  // (beads=="") falls back to the §4.6 inventory: the lifecycle beads come from
  // the active in_progress/top_n lists (which exclude held work), so the held
  // (blocked/deferred/gated) beads are read from the dedicated `held_beads`
  // channel — NOT merged into `beads`, so lifecycle_columns stays the active-work
  // ladder (no Board behaviour change). holds is built from beads ∪ heldBeads.
  let heldBeads = [];
  if (beads.length === 0) {
    beads = await beadsFromWorkspaceInventory(co, proj);
    heldBeads = await readHeldBeads(co, proj);
  }
  // The lifecycle columns are the C1-seam stage ladder, keyed by each bead's
  // `stage:` label (INTERFACE §4.5). Frozen column order; a bead with no/an
  // unknown stage is bucketed under "" (honest: un-staged, not silently impl).
  const stages = ["idea", "ux", "design", "impl", "docs", "tests", "done"];

  // Which RunnerState projects to surface: the one asked, else every stored
  // runner_state record (the Board's per-project strip).
  let projs;
  if (proj) {
    projs = [proj];
  } else {
    const { results } = await co.db
      .prepare("SELECT id FROM records WHERE type = ? ORDER BY id")
      .bind("runner_state")
      .all();
    projs = (results || []).map((r) => r.id).filter((id) => id);
  }

  // Per-project RunnerState (desired+actual+liveness DERIVED). The legacy
  // per-project `capacity_strip` block is DROPPED in this projection per
  // MACHINE-STATE.md §3.B — the §4.5 5h%/7d%/ramp wording is now satisfied by
  // the top-level `machines[]` carrying them as the per-machine header strip
  // (§3.A). The §6.3 gate verdict still flows through report-capacity /
  // ask-capacity unchanged; that channel is internal to the CF.4 capacity
  // module and is NOT surfaced in this projection.
  // I2 (claude-tools-uxvi2) — read the agent_activity transient ONCE for the
  // whole snapshot (filtered per-project below by the §1.4 `workspace` field);
  // one read-time clock for the dot re-derivation. Pure read (readActivity owns
  // the no-_serialize discipline) — the §4.5 no-reader-write invariant holds.
  const activityNowMs = Date.now();
  const activityRows = await readActivity(co);
  // J2 (claude-tools-uxvj2) — the gate_metadata LEFT-join map + the unified
  // holds[]. Read ONCE for the whole snapshot (the §3.2 bulk path). holds is the
  // SAME for every project (per-project shape; the global rollup is UI-side —
  // gates.md §3.4: J2 stays scoped to the single-project read shape, the /ws/<ref>
  // /gates facet always asks per-project), so it is built once and attached to
  // each entry below as a NAMED sub-object (ARCH §6 — never a loose flat key).
  const gateMetaMap = await readGateMeta(co);
  const holds = buildHolds(beads.concat(heldBeads), gateMetaMap);
  const projects = [];
  for (const pr of projs) {
    if (!pr) continue;
    const rec = await reconcileData(co, principal, pr, undefined);
    // Read this project's stored §4.6 workspace_inventory record ONCE — it feeds
    // BOTH the current_task_title join (4g5o) AND the queue_health surface
    // (uxvq1). O(1) per project; no pre-cache, no staleness check (v1 trusts the
    // lookup — bounded staleness comes from the next pickup rewriting the row).
    let wsiParsed = null;
    {
      const wsi = await co.db
        .prepare("SELECT json FROM records WHERE type = ? AND id = ?")
        .bind("workspace_inventory", pr)
        .first();
      if (wsi && typeof wsi.json === "string") {
        try {
          wsiParsed = JSON.parse(wsi.json);
        } catch {
          wsiParsed = null;
        }
        if (!wsiParsed || typeof wsiParsed !== "object" || Array.isArray(wsiParsed)) {
          wsiParsed = null;
        }
      }
    }
    // claude-tools-4g5o — workspace_inventory title join. Graceful degradation:
    // no record / no match / no current_task_ref / unparseable body ⇒ null and
    // the Board renderer falls back to ref-only.
    let currentTaskTitle = null;
    if (typeof rec.current_task_ref === "string" && rec.current_task_ref && wsiParsed) {
      const ip = Array.isArray(wsiParsed.in_progress_beads)
        ? wsiParsed.in_progress_beads : null;
      if (ip) {
        const match = ip.find(
          (b) => b && typeof b === "object" && b.bead_ref === rec.current_task_ref
        );
        if (match && typeof match.title === "string") {
          currentTaskTitle = match.title;
        }
      }
    }
    // claude-tools-uxvq1 — queue_health (§9 / B.1). Surfaced per-project from the
    // runner-published §4.6 record, NORMALIZED to the frozen B.1 shape. Absent
    // record / absent block ⇒ the honest all-zero block (normalizeQueueHealth's
    // default) so projects[].queue_health is UNIFORM — the Board strip always
    // has a block to render (empty-queue explainer + net-velocity alarm, §9).
    const queue_health = normalizeQueueHealth(wsiParsed ? wsiParsed.queue_health : null);
    // I2 (claude-tools-uxvi2) — activity{} (DESIGN I §2): the §1.4 agent_activity
    // rows for THIS workspace (keyed by the wire `workspace` field), projected
    // DOWN to the EXACT B.1 lane shapes. writer = the singular `lane:"writer"`
    // row (or null); auxiliary[] = the 0..N `lane:"auxiliary"` rows, kept in the
    // agent_key order readActivity already SELECTs (deterministic UI).
    const projActivityRows = activityRows.filter((b) => b.workspace === pr);
    const writerRow = pickWriterRow(projActivityRows);
    const activity = {
      writer: writerRow ? projectWriterActivity(writerRow, activityNowMs) : null,
      auxiliary: projActivityRows
        .filter((b) => b.lane === "auxiliary")
        .map((b) => projectAuxActivity(b, activityNowMs)),
    };
    // I2 — runner_health{} (DESIGN I §3): the loop PROCESS, runner_state-derived.
    const runner_health = deriveRunnerHealth(rec);
    projects.push({
      project_ref: rec.project_ref,
      runner_state: {
        desired: rec.desired,
        actual: rec.actual,
        liveness: rec.liveness,
        last_heartbeat_at: rec.last_heartbeat_at,
        current_task_ref: rec.current_task_ref,
        current_task_title: currentTaskTitle,
        desired_actual_mismatch: rec.desired_actual_mismatch,
      },
      runner_health,
      activity,
      holds,
      queue_health,
      lease: rec.lease,
    });
  }

  // WAITING-ON-YOU lane: stored Dossiers for THIS principal with ≥1 still-open
  // item. §4.1 — an item is non-terminal unless its state ∈ {applied,expired};
  // a dossier is open while ≥1 item is non-terminal (a partly-answered dossier
  // — answered-but-not-applied — STILL shows, AD7). COUNTS ONLY: CF.3 never
  // produces or interprets Dossier body/items (CF.6).
  const waiting_on_you = [];
  const { results: drows } = await co.db
    .prepare("SELECT json FROM records WHERE type = ? ORDER BY id")
    .bind("dossier")
    .all();
  for (const dr of drows || []) {
    let d;
    try {
      d = JSON.parse(dr.json);
    } catch {
      continue;
    }
    if (!d || typeof d !== "object" || Array.isArray(d) || d.principal !== principal) {
      continue;
    }
    const items = Array.isArray(d.items) ? d.items : [];
    const openItems = items.filter((it) => {
      const st = it && it.state != null ? it.state : "open";
      return st !== "applied" && st !== "expired";
    }).length;
    // N3 (claude-tools-uxg6) — a `kind:"pair"` SESSION CARD surfaces in the
    // lane regardless of item count: a ready-to-pair envelope is "not iterated
    // as §5 Items" (DESIGN N §4.2) so it legitimately carries 0 items, and the
    // `openItems >= 1` gate would otherwise HIDE it. A pair dossier is a
    // scheduled SESSION the Inbox renders as upcoming→ready off `scheduled_at`
    // (§4.4) — its visibility is driven by kind, not by open-item count.
    const isPair = d.kind === "pair";
    if (openItems >= 1 || isPair) {
      // claude-tools-56h — the projection had been bead_ref/tier/open_item_count
      // ONLY, so the Inbox list rendered N indistinguishable rows ("9 things
      // need you · claude-tools-txj" × 9). Skim fields (tldr/created_at/kind)
      // come from the same dossier object we're already iterating — passing
      // them through costs nothing and lets the UI surface a real preview.
      const body = d.body && typeof d.body === "object" && !Array.isArray(d.body) ? d.body : null;
      const tldr = body && typeof body.tldr === "string" ? body.tldr : "";
      waiting_on_you.push({
        dossier_ref: d.id ?? "",
        dossier_id: d.id ?? "",
        bead_ref: d.bead_ref ?? "",
        tier: d.tier ?? "",
        kind: typeof d.kind === "string" ? d.kind : "",
        tldr,
        created_at: typeof d.created_at === "string" ? d.created_at : null,
        // N3 — the pair appointment time the Inbox renders upcoming→ready off
        // (§4.4); null for every non-pair dossier (a pure passthrough, no
        // schema bump — the §4.1 envelope already carries it for kind:"pair").
        scheduled_at: typeof d.scheduled_at === "string" ? d.scheduled_at : null,
        item_count: items.length,
        open_item_count: openItems,
      });
    }
  }
  // Sort newest-first by created_at (ISO-8601 lexical order ≡ chronological).
  // Items with no created_at sink to the bottom (honest: undated = stale-ish).
  waiting_on_you.sort((a, b) => {
    const ax = a.created_at || "";
    const bx = b.created_at || "";
    if (ax === bx) return 0;
    if (!ax) return 1;
    if (!bx) return -1;
    return bx < ax ? -1 : 1;
  });

  // The join + the lifecycle columns. Each card: title·stage·priority·runner
  // state·age·the one thing it waits on (INTERFACE §4.5). Failure metadata is
  // carried from the work-truth read (Flow G tiers 1–2): class + retry-state
  // + Runner: note timeline + last_runner_note_at + silent-vs-loud flag (the
  // G1 board-badge contract — UX principle 7: silent failures surface louder
  // because they ROT). The §10 forensic stream is structurally absent (never
  // read here, and `forensic_blob`/`stream_json` ARE stripped at the producer
  // — defense-in-depth on top of the renderer drop).
  //
  // `silent` is DERIVED from `class` when the runner doesn't supply it: a
  // class in SILENT_CLASSES (TASK_NOT_CLOSED, TOOL_ERROR:*, SUBAGENT_MISSING,
  // MCP_DOWN) ⇒ silent (looked green but isn't / dependency missing without
  // a hard fail — the "rotting" classes). The runner can override by setting
  // an explicit boolean. Unknown class ⇒ NOT silent (honest default — we do
  // not louden a class we can't classify; only known-silent gets loudened).
  const SILENT_CLASSES = new Set([
    "TASK_NOT_CLOSED",
    "SUBAGENT_MISSING",
    "MCP_DOWN",
  ]);
  const normalizeFailure = (f) => {
    if (!f || typeof f !== "object" || Array.isArray(f)) return null;
    const cls = typeof f.class === "string" && f.class ? f.class : "UNKNOWN_FAILURE";
    const retry = typeof f.retry_state === "string" && f.retry_state ? f.retry_state : null;
    const notes = Array.isArray(f.runner_notes)
      ? f.runner_notes.filter((n) => typeof n === "string")
      : [];
    const lastAt = typeof f.last_runner_note_at === "string" && f.last_runner_note_at
      ? f.last_runner_note_at
      : null;
    const silent = typeof f.silent === "boolean"
      ? f.silent
      : (SILENT_CLASSES.has(cls) || cls.startsWith("TOOL_ERROR"));
    return {
      class: cls,
      retry_state: retry,
      runner_notes: notes,
      last_runner_note_at: lastAt,
      silent,
    };
  };
  const card = (b) => ({
    bead_ref: b.bead_ref ?? null,
    title: b.title ?? null,
    stage: b.stage == null ? "" : b.stage,
    priority: b.priority ?? null,
    age: b.age ?? null,
    waiting_on: b.waiting_on ?? null,
    // GAP G2 (claude-tools-uxg2) — the done·code vs done·verified sub-state
    // (UX-DESIGN-V2.md §3 / principle 11: the headline defence against
    // 'wired-but-not-live'). A per-card boolean passthrough of the work-truth
    // `verified` fact: the production/contract probe passed (web track: deploy
    // + verify-pages-deploy.sh mismatches=0; contract track: a live
    // integration probe). Only the Board's `done` column splits on it, but —
    // like `failure` — it is carried on EVERY card so the §4.5 contract is
    // uniform. STRICT boolean: anything other than literal `true` reads as
    // `false` (honest default — un-probed is NOT verified; "code landed +
    // local tests pass" is NOT "shipped and verified").
    verified: b.verified === true,
    failure: normalizeFailure(b.failure),
  });
  const lifecycle_columns = {};
  for (const s of stages) {
    lifecycle_columns[s] = beads
      .filter((b) => (b.stage == null ? "" : b.stage) === s)
      .map(card);
  }
  lifecycle_columns[""] = beads
    .filter((b) => {
      const st = b.stage == null ? "" : b.stage;
      return stages.indexOf(st) === -1;
    })
    .map(card);

  // ── Top-level `machines[]` — MACHINE-STATE.md §3.A ──────────────────────────
  // Peer to `projects` and `waiting_on_you` (NOT nested per-project — D2 §0.B:
  // machine-state is per-machine). Reads the SEPARATE machine_state_reports
  // namespace cf/src/machine-state.js owns (pure read, no _serialize per §2.4).
  // `fresh` and `age_seconds` are DERIVED at projection time so the Board never
  // has to know USAGE_POLL_TTL_SECONDS. Empty array if no daemon has reported
  // (§3.C empty-state contract: `machines: []` is honest; never absent/null;
  // the snapshot does NOT fabricate a stub). Ordered by `runner_id` (the §2.1
  // PRIMARY KEY) for deterministic UI stability across two-machine futures.
  const machines = await readMachines(co, Date.now());

  // ── Top-level `intake[]` — the L3 (claude-tools-uxvl3) intake-state lane ─────
  // Peer to machines[]/waiting_on_you[] (NOT nested per-project — the hub slices
  // it by project_ref the same way it slices the global Inbox lane). ADDITIVE at
  // schema_version 1 (the machines[] precedent): a new top-level key old v1
  // views harmlessly ignore. Surfaces the received→enriching→created /
  // failing(n) / gave-up thread so the 19-silent-retry leak can never be
  // invisible again (inbox-lifecycle §9.5 #4). Honest [] when no intakes stored.
  const intake = await readIntake(co, principal);

  return jsonRes({
    schema_version: 1,
    principal,
    read_only: true,
    machines,
    projects,
    lifecycle_columns,
    waiting_on_you,
    intake,
  });
}

// ── readMachines — the §3.A projection-side read of the D2 telemetry channel ──
// Pure read of `machine_state_reports` (MACHINE-STATE.md §2.4 — no _serialize).
// The table is lazily created by cf/src/machine-state.js on first ingest; if no
// daemon has ever reported, the SELECT throws "no such table" — we honestly
// degrade to `machines: []` (§3.C empty-state) rather than DDL from a reader.
// Each row's stamped JSON is decorated with `fresh` + `age_seconds` (DERIVED at
// READ time — the same C6 discipline `liveness` follows). A corrupt row is
// skipped (should not happen given the §1.4 strict ingest gate, defensive).
async function readMachines(co, nowMs) {
  let results = [];
  try {
    const r = await co.db
      .prepare("SELECT json FROM machine_state_reports ORDER BY runner_id ASC")
      .all();
    results = (r && r.results) || [];
  } catch {
    return []; // table not yet created ⇒ honest empty (§3.C)
  }
  const ttl = usagePollTtlSeconds(co.env);
  const out = [];
  for (const row of results) {
    let rec;
    try {
      rec = JSON.parse(row.json);
    } catch {
      continue;
    }
    if (!rec || typeof rec !== "object" || Array.isArray(rec)) continue;
    const obsMs = Date.parse(rec.observed_at);
    const ageSec = Number.isFinite(obsMs)
      ? Math.max(0, Math.floor((nowMs - obsMs) / 1000))
      : null;
    const fresh = ageSec !== null && ageSec <= 2 * ttl;
    out.push({ ...rec, fresh, age_seconds: ageSec });
  }
  return out;
}

// ════════════════════════════════════════════════════════════════════════════
// I2 (claude-tools-uxvi2) — activity{} + runner_health{} per-project sub-objects
// (DESIGN I §2 lanes + §3 runner-vs-agent; Contract B.1). Both are READ-TIME
// derivations added to projects[] as NAMED sub-objects (ARCH §6: each track owns
// a sub-object so the shared workSnapshot() seam never merge-collides — never a
// loose flat key). ADDITIVE at schema_version 1 (the queue_health/intake[]
// precedent — the conformance v2 sub-object gate is version-gated and stays
// PENDING until a coordinated bump to 2 lands ALL of {activity,holds,
// queue_health,blueprint_meta,runner_health}; I2 ships 2 of the 5 early without
// bumping). The bash oracle (co__work_snapshot) emits a runner_health TWIN
// (same runner_state-derived values) + an honest-empty activity default for
// SHAPE PARITY — the machines[]/queue_health precedent.
// ════════════════════════════════════════════════════════════════════════════

// ── readActivity — the §1.4 projection-side read of the agent_activity channel ─
// Pure read of the SEPARATE `agent_activity` transient namespace cf/src/
// activity.js (I1) owns — NO _serialize (the readMachines/get-agent-activity
// pure-read precedent). The table is lazily created by activity.js on first
// ingest; if no agent has ever reported, the SELECT throws "no such table" and
// we honestly degrade to [] (the §3.C empty-state discipline readMachines
// follows) rather than DDL from a reader. One pass for the whole snapshot — the
// rows are filtered per-project in workSnapshot by the §1.4 `workspace` field.
// A corrupt row is skipped (should not happen given activity.js's strict ingest
// gate — defensive, mirrors readMachines).
async function readActivity(co) {
  let results = [];
  try {
    const r = await co.db
      .prepare("SELECT json FROM agent_activity ORDER BY agent_key ASC")
      .all();
    results = (r && r.results) || [];
  } catch {
    return []; // table not yet created ⇒ honest empty (§3.C)
  }
  const out = [];
  for (const row of results) {
    let rec;
    try {
      rec = JSON.parse(row.json);
    } catch {
      continue;
    }
    if (rec && typeof rec === "object" && !Array.isArray(rec)) out.push(rec);
  }
  return out;
}

// ── liveness_dot honest re-derivation (D.2 90/180 windows — [spine], not moved) ─
// The reported `liveness_dot` is the worker's EVENT-stream freshness (Δ from
// last_event_ts, computed by the I1 classifier). It is honest WHILE the reporter
// is alive (the §1.4 reporter heartbeats ≤60s, so a stuck-but-reporting writer
// keeps emitting an honest red). But if the WHOLE agent dies, reports stop and
// the stored dot FREEZES at whatever it last was (a stale green = a lie the
// instant the agent stopped — the S-1/C6 "never lie" rule the `liveness`
// derivation already obeys). B.1's writer/aux shape carries NO report-age field,
// so the renderer (I3) cannot recover staleness from the projection — therefore
// the projection itself must encode it in the one liveness field it has (the
// must-protect #2 projection-field rule). We take the WORSE of the reported dot
// and a dot re-derived from the report's own `observed_at` age: this can only
// DOWNGRADE a stale green (never falsely downgrade a fresh agent — the reporter
// writes observed_at on every report and reports while active, so a live agent
// is never report-stale). The 90/180 numbers are the FROZEN D.2 windows
// (green <90s · amber 90–180s · red >180s) — NOT tightened (must-protect #8).
const ACTIVITY_AMBER_SECONDS = 90;
const ACTIVITY_RED_SECONDS = 180;
const DOT_RANK = { green: 0, amber: 1, red: 2 };
function ageSeconds(obs, nowMs) {
  if (typeof obs !== "string") return null;
  const ms = Date.parse(obs);
  if (!Number.isFinite(ms)) return null;
  return Math.max(0, Math.floor((nowMs - ms) / 1000));
}
function reportAgeDot(obs, nowMs) {
  const age = ageSeconds(obs, nowMs);
  if (age === null) return "red"; // unestablishable freshness ⇒ honest red (the deriveLiveness unreadable-clock precedent)
  if (age > ACTIVITY_RED_SECONDS) return "red";
  if (age >= ACTIVITY_AMBER_SECONDS) return "amber";
  return "green";
}
function worseDot(reported, ageBased) {
  const r = DOT_RANK[reported];
  if (r === undefined) return ageBased; // an out-of-enum reported dot can't be trusted ⇒ the age-derived honest value
  return r >= DOT_RANK[ageBased] ? reported : ageBased;
}

// ── projectWriterActivity — project the §1.4 ingest superset DOWN to B.1's
//    EXACT 8-key writer shape (§1.4 / must-protect #2 the 56h projection-drop
//    guard). The wire body carries MORE (current_tool/last_event_ts/kind/…) —
//    those are table-only derivation telemetry and are DELIBERATELY NOT surfaced.
//    state/state_confidence/liveness_dot were gated to their closed D.2 sets at
//    INGEST (activity.js), so they pass through trusted; state_confidence is
//    re-pinned to "derived" (D.2 — nothing semantic is ever asserted).
function projectWriterActivity(body, nowMs) {
  return {
    bead_ref: typeof body.bead_ref === "string" ? body.bead_ref : null,
    title: typeof body.title === "string" ? body.title : null,
    stage: typeof body.stage === "string" ? body.stage : "",
    state: body.state,
    state_confidence: "derived",
    liveness_dot: worseDot(body.liveness_dot, reportAgeDot(body.observed_at, nowMs)),
    seconds_in_state:
      typeof body.seconds_in_state === "number" && Number.isFinite(body.seconds_in_state)
        ? body.seconds_in_state
        : null,
    // touching[] (§1.5, [free] writer stretch) — domain ids for the Blueprint
    // overlay; absent ⇒ [] (degradable, never blocks). Strings only.
    touching: Array.isArray(body.touching)
      ? body.touching.filter((x) => typeof x === "string")
      : [],
  };
}

// ── projectAuxActivity — project DOWN to B.1's NARROWER 5-key aux shape (§1.4).
//    An aux carries NO bead_ref/title/seconds_in_state to the UI (§1.4: the aux
//    pool shows kind+label+state+dot only). `label` is human-readable: prefer an
//    explicit reporter-supplied label, else the title, else the kind ([free]
//    presentation, §8) — never throws, honest "" when none.
function projectAuxActivity(body, nowMs) {
  const label =
    typeof body.label === "string" && body.label
      ? body.label
      : typeof body.title === "string" && body.title
        ? body.title
        : typeof body.kind === "string"
          ? body.kind
          : "";
  return {
    kind: typeof body.kind === "string" ? body.kind : "",
    label,
    state: body.state,
    state_confidence: "derived",
    liveness_dot: worseDot(body.liveness_dot, reportAgeDot(body.observed_at, nowMs)),
  };
}

// ── pickWriterRow — the writer is SINGULAR per workspace by construction (one
//    serial st_run_task loop ⇒ one `writer:<runner_id>` agent_key, §2). Defensive
//    against a transient duplicate (e.g. a runner_id change): keep the row with
//    the newest observed_at (RFC-3339 UTC sorts lexically ≡ chronologically —
//    the latest-wins convention activity.js's ingest uses). null ⇒ no writer.
function pickWriterRow(rows) {
  let best = null;
  let bestObs = "";
  for (const b of rows) {
    if (b.lane !== "writer") continue;
    const obs = typeof b.observed_at === "string" ? b.observed_at : "";
    if (best === null || obs > bestObs) {
      best = b;
      bestObs = obs;
    }
  }
  return best;
}

// ── deriveRunnerHealth — DESIGN I §3: the LOOP PROCESS health, BLUNT and NOT
//    log-derived (the agent-activity §1 signal is separate). Derived purely from
//    the §4.2 RunnerState `rec` (liveness + actual + current_task_ref) that
//    reconcileData already produced — so BOTH the CF producer AND the bash oracle
//    derive it identically (a true differential twin, unlike activity which has
//    no bash store). B.1 shape: {process, heartbeat, last_pickup_at, state}.
//
//    THE SAFETY INVARIANT (findings §180–182 / UX-DESIGN-V2 §5.4 verbatim): a
//    healthy-but-WAITING runner (usage-cooldown / capacity-deny / skip-backoff /
//    starvation) must read `idle`, NEVER `wedged`/stuck. This holds for FREE
//    because v2 runner.sh heartbeats `idle` every ~60s in EVERY waiting state
//    (the skip loop, the capacity-deny RECONCILE re-poll, the idle poll — all
//    RECLAIM_POLL_INTERVAL=60s < STALE_AFTER=180s), so a waiting runner stays
//    FRESH ⇒ idle. The heartbeat freshness IS the "backoff marker" §3 names —
//    only a genuinely hung/dead process drifts past 180s ⇒ stale ⇒ wedged (the
//    krxv/td0y claude-won't-exit wedge). No engine-readable cooldown marker
//    exists or is needed in v1.
//
//    `starved` (alive but the ready set is only-unworkable, the g20/dzc shape)
//    collapses to `idle` here: from runner_state ALONE it is indistinguishable
//    from a deliberately-idle loop (the runner heartbeats `idle` while it scans
//    past unworkable beads), and emitting `starved` on a guess would be a false
//    signal. The bead invariant pins this exactly ("a starved-but-alive runner
//    reads 'idle'"). The enum value stays reserved for a future explicit
//    starvation signal (additive, reversible). `last_pickup_at` has no producer
//    yet ⇒ honest null (the current_task_title:null precedent).
function deriveRunnerHealth(rec) {
  const heartbeat = rec.liveness === "live" ? "fresh" : "stale";
  const dead = rec.actual === "stopped" || rec.actual === "crashed";
  const process = dead ? "dead" : "alive";
  // "in a task" keys off the AUTHORITATIVE §4.2 actual-state (the runner's own
  // report), NOT current_task_ref: a runner that reports `idle` is not working,
  // even if a stale current_task_ref lingered (the lv9c leftover-ref combo).
  const inTask = rec.actual === "running";
  let state;
  if (heartbeat === "stale" && process === "alive") {
    state = "wedged"; // stale + not-explicitly-down + (every backoff stays fresh) ⇒ genuine wedge
  } else if (process === "dead") {
    state = "idle"; // intentionally/terminally down; process:dead carries that truth, never "stuck"
  } else if (inTask) {
    state = "working"; // fresh heartbeat + in a task
  } else {
    state = "idle"; // fresh, no task — incl. cooldown/capacity-deny/skip/starvation (all heartbeat idle)
  }
  return { process, heartbeat, last_pickup_at: null, state };
}

// ── deriveIntakeState — the L3 (claude-tools-uxvl3) phone-visible state thread ─
// inbox-lifecycle §9.5 #4. Maps an intake-request record onto ONE state of the
// frozen thread: received → enriching → created  /  failing → gave-up. Prefers
// the daemon's explicit `dispatch_state` marker (intake-dispatch-poll.sh writes
// "enriching" before each spawn and "created"/"failing"/"gave_up" at the
// outcome); falls back to deriving from {gave_up, processed, dispatch_attempts}
// for legacy records written before L3. Terminal states win: a gave-up record
// is gave-up even if a stale `dispatch_state` lingers; a created record is
// created. The 19-silent-retry leak is exactly `failing`/`gave-up` going
// unsurfaced — so those must never collapse into "received".
function deriveIntakeState(rec) {
  const ds = typeof rec.dispatch_state === "string" ? rec.dispatch_state : "";
  if (rec.gave_up === true || ds === "gave_up") return "gave-up";
  if (rec.processed === true || ds === "created") return "created";
  if (ds === "enriching") return "enriching";
  if (ds === "failing") return "failing";
  const attempts = Number.isInteger(rec.dispatch_attempts) ? rec.dispatch_attempts : 0;
  if (attempts >= 1) return "failing"; // attempted-but-not-yet-terminal ⇒ failing
  return "received";
}

// ── readIntake — the §4.5 intake-state lane (L3 claude-tools-uxvl3) ───────────
// Pure read of the stored `intake-request` records (the Flow A queue markers I2
// writes + I3's daemon annotates). PEER to machines[]/waiting_on_you[] — a
// CF-side production projection with NO bash-oracle twin (like machines[]); the
// snapshot SHAPE stays at schema_version 1 because this is an ADDITIVE top-level
// key (old v1-bound views ignore it; the Workspaces hub reads it). Honest empty
// on a missing table / read failure (§3.C) — never fabricated. Scoped to the
// requesting principal (the §9.1 chokepoint stamps it on every put); a record
// with NO principal is tolerated (legacy / pre-stamp). COUNTS + state ONLY: the
// idea_excerpt is a short single-lined slice of the submitter's OWN idea_text so
// Brian can tell which tap a card is (the full text is never the point here).
async function readIntake(co, principal) {
  let rows = [];
  try {
    const r = await co.db
      .prepare("SELECT json FROM records WHERE type = ? ORDER BY id")
      .bind("intake-request")
      .all();
    rows = (r && r.results) || [];
  } catch {
    return []; // table not yet created / read failure ⇒ honest empty (§3.C)
  }
  const out = [];
  for (const row of rows) {
    let rec;
    try {
      rec = JSON.parse(row.json);
    } catch {
      continue;
    }
    if (!rec || typeof rec !== "object" || Array.isArray(rec)) continue;
    // Principal scoping — strict when present, tolerant when absent (legacy).
    if (typeof rec.principal === "string" && rec.principal !== principal) continue;
    const ideaText = typeof rec.idea_text === "string" ? rec.idea_text : "";
    const excerpt = ideaText.replace(/\s+/g, " ").trim().slice(0, 80);
    const attempts = Number.isInteger(rec.dispatch_attempts) ? rec.dispatch_attempts : 0;
    out.push({
      intake_id: typeof rec.id === "string" ? rec.id : "",
      project_ref: typeof rec.project_ref === "string" ? rec.project_ref : "",
      preset: typeof rec.preset === "string" ? rec.preset : "",
      state: deriveIntakeState(rec),
      attempts,
      idea_excerpt: excerpt,
      bd_ref: typeof rec.enricher_bd_id === "string" ? rec.enricher_bd_id : null,
      outcome: typeof rec.enricher_outcome === "string" ? rec.enricher_outcome : null,
      last_error: typeof rec.last_error === "string" ? rec.last_error : null,
      submitted_at: typeof rec.submitted_at === "string" ? rec.submitted_at : null,
      last_attempt_at: typeof rec.last_attempt_at === "string" ? rec.last_attempt_at : null,
      processed_at: typeof rec.processed_at === "string" ? rec.processed_at : null,
      gave_up_at: typeof rec.gave_up_at === "string" ? rec.gave_up_at : null,
    });
  }
  // Newest-first by submitted_at (ISO-8601 lexical ≡ chronological); undated
  // sinks to the bottom (mirrors the waiting_on_you sort).
  out.sort((a, b) => {
    const ax = a.submitted_at || "";
    const bx = b.submitted_at || "";
    if (ax === bx) return 0;
    if (!ax) return 1;
    if (!bx) return -1;
    return bx < ax ? -1 : 1;
  });
  return out;
}

// Per-module Response helpers (mirroring the sibling modules — coordinator.js's
// json/text are not exported; each layered module owns its own).
function jsonRes(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}

// RECONCILE_OPS dispatch. The §9.1 chokepoint (the Worker) has ALREADY
// authenticated + resolved `principal` and threaded it down — there is NO
// second auth path here (C4); a no/invalid-token heartbeat|reconcile|
// work-snapshot is rejected 401 at the Worker BEFORE this guard and before any
// store touch. `heartbeat` is the legitimate up→down WRITE (composes on CF.1's
// ONE gated write path); `reconcile`/`work-snapshot` are READ-ONLY.
export async function handleReconcileOp(co, op, args, principal) {
  const a = args || [];
  switch (op) {
    case "heartbeat":
      return await heartbeat(co, principal, a[0]);
    case "reconcile":
      return jsonRes(await reconcileData(co, principal, a[0], a[1]));
    case "work-snapshot":
      return await workSnapshot(co, principal, a[0], a[1]);
    case "workspace-inventory-put":
      return await workspaceInventoryPut(co, principal, a[0]);
    default:
      return jsonRes({ ok: false, error: `co: unknown reconcile op '${op}'` }, 400);
  }
}
