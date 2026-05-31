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
//      string `bead_ref` + `title` + `stage`;
//   7. `top_n_beads` is REQUIRED (array, may be empty); each element MUST carry
//      string `bead_ref` + `title` + `status` + `stage`. No hard cap on length
//      at the write boundary — bounding is the producer's concern (the §4.6
//      contract notes "a small bounded array of top-N most-recently-touched").
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
    })),
    top_n_beads: tn.map((b) => ({
      bead_ref: b.bead_ref,
      title: b.title,
      status: b.status,
      stage: b.stage,
    })),
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
  const projects = [];
  for (const pr of projs) {
    if (!pr) continue;
    const rec = await reconcileData(co, principal, pr, undefined);
    // claude-tools-4g5o — workspace_inventory join: look up the title for
    // current_task_ref from the stored §4.6 workspace_inventory record's
    // in_progress_beads[]. Graceful degradation: no record / no match / no
    // current_task_ref / unparseable body ⇒ current_task_title=null and the
    // Board renderer falls back to ref-only. O(1) per project (typically one
    // in_progress bead per workspace); deliberately no pre-cache, no staleness
    // check (v1 trusts the lookup — bounded staleness comes from next pickup
    // rewriting the record).
    let currentTaskTitle = null;
    if (typeof rec.current_task_ref === "string" && rec.current_task_ref) {
      const wsi = await co.db
        .prepare("SELECT json FROM records WHERE type = ? AND id = ?")
        .bind("workspace_inventory", pr)
        .first();
      if (wsi && typeof wsi.json === "string") {
        let parsed = null;
        try {
          parsed = JSON.parse(wsi.json);
        } catch {
          parsed = null;
        }
        const ip = parsed && Array.isArray(parsed.in_progress_beads)
          ? parsed.in_progress_beads : null;
        if (ip) {
          const match = ip.find(
            (b) => b && typeof b === "object" && b.bead_ref === rec.current_task_ref
          );
          if (match && typeof match.title === "string") {
            currentTaskTitle = match.title;
          }
        }
      }
    }
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

  return jsonRes({
    schema_version: 1,
    principal,
    read_only: true,
    machines,
    projects,
    lifecycle_columns,
    waiting_on_you,
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
