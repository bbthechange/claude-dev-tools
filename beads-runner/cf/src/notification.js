// CF.9 (claude-tools-7g0.9) — the §4.3 Notification, realized on the CF.1
// substrate. The C3 creation≠dispatch seam.
//
// This is the Cloudflare realization of the bash:
//   lib/notification.sh      (T5.6 §4.3 persisted tiered record,
//                             one-per-Dossier, creation≠dispatch)
// and is differential-bound to lib/test-notification.sh. The CF engine MUST
// exhibit the SAME INTERFACE.md v1 §4.3 (+ §4.1 tier source) / §0.3 behaviour
// as the bash impl + that test — not a re-spec.
//
// THE AD1 PAYOFF (the structural guarantee, same as CF.6): the bash skeleton
// hand-rolls a per-notification `mkdir` advisory lock (`no__with_notif_lock`)
// so each read→decide→write of a §4.3 record is single-writer. Here there is
// NO such advisory lock. The CF.1 singleton Coordinator DO is ONE actor;
// every store-touching notification op runs as ONE serialized critical
// section on that one actor (`co._serialize`, coordinator.js — the SAME tail
// CF.6 dossier ops chain on, so a dossier op and its Notification are
// serialized on the one actor). So "one Notification per Dossier" and
// "dispatched flips false→true EXACTLY ONCE" are TRUE BY CONSTRUCTION of the
// single-threaded executor, not a ported compare-and-set. The notification id
// is still DETERMINISTICALLY derived from the dossier id (one-per-Dossier by
// structure) and `dispatched` is still the §4.3 boolean that flips once — but
// their exactly-once is now structural (the substrate-handoff discipline:
// lean on the single-threaded DO, do NOT hand-roll a latch).
//
// MUST-NOT-TOUCH (bound by the CF.9 issue):
//   • Dossier production + §4.1 tier assignment SOURCE — CF.6. This file
//     CONSUMES `Dossier.tier` (reads the §4.1 envelope; MIRRORS the tier onto
//     the §4.3 record) and NEVER sets/recomputes it. `no_for_generation`
//     consumes CF.6's PUBLIC producer op (`dossier-generate` via the exported
//     `handleDossierOp`) — the module analogue of bash sourcing
//     dossier-gen.sh + calling `dg_generate`; it synthesises NO §5 content
//     and never inspects the body (the Notification deliberately cannot carry
//     it — principle 2).
//   • CF.1 store internals — CF.9 binds the §4.3 `notification` record type
//     (ALREADY in the CF.1 §4 registry, schema.js; CF.9 adds NO §4 record
//     type and edits NO registry) and reuses CF.1's ONE write path
//     `_writeRecord` (§0.3 re-enforced + §9.1 principal stamped THERE, never
//     a use-site literal — C7), exactly as bash notification.sh persists
//     THROUGH `co_request put notification`. The READ path (`getRaw`)
//     replicates CF.1 `opGet`'s byte-identical typed SELECT — the read-side
//     analogue of bash `co_request get notification`, the SAME accepted
//     pattern CF.6 `getRawDossier` documents, NOT a reach past the surface.
//   • The substrate store (CF.1), timer (CF.7), STUCK routing (CF.8), and the
//     OS-notification MECHANISM (osascript — the runner/Local-Agent + T1b
//     surface). C3 DEFERS the channel: `no_dispatch` flips the latch and
//     stores the OPAQUE `channel` tag verbatim; it SENDS NOTHING. The §9.1
//     chokepoint stays the ONE Worker step (CF.1) — no second auth path (C4).
//
// ANTI-DRIFT: binds FROZEN INTERFACE.md v1 §4.3 (+ §4.1 tier source) / §0.3 /
// §0.5. one-per-Dossier + creation≠dispatch are NORMATIVE (C3). The bound
// version is READ from the CF.1 §4 registry (schema.js `schemaVersion`),
// never a competing local literal (§0.5). An INTERFACE gap ⇒ reopen
// claude-tools-65z, bump+re-freeze, Brian sign-off — NEVER diverge, NEVER
// edit INTERFACE.md. (No gap: §4.3 is a complete, self-consistent schema and
// `notification` is already a registered §4 type.) Oracle = lib/
// notification.sh + lib/test-notification.sh.

import { schemaVersion, safeKey } from "./schema.js";
// CF.6's PUBLIC producer op surface — consumed as a black box (the bash
// `dg_generate` analogue), NEVER its internals. This is "consume Dossier
// production", not "touch CF.6": handleDossierOp is the exported op
// dispatcher, exactly what the Worker calls.
import { handleDossierOp } from "./dossier.js";

// ── the ONE bound schema versions, READ from the CF.1 §4 registry ───────────
// §0.3/§0.5: a value with a single normative definition is never restated as
// a competing literal. The Notification's bound version lives in CF.1's
// registry. 1:1 with bash `no__bound_sv` (= `co__schema_version notification`).
export function notifBoundSv() {
  return schemaVersion("notification");
}
// The §4.1 Dossier's bound version — for the §0.3 read-bind when consuming the
// envelope `tier` (mirrors bash `no_emit` reading the tier off `do_dossier_get`,
// which §0.3-binds the dossier read path; never best-effort-parse a forward
// dossier).
function dossierBoundSv() {
  return schemaVersion("dossier");
}

// ── one-per-Dossier id derivation (the C3 / AD7 structural guarantee) ───────
// The notification id is DETERMINISTICALLY derived from the dossier id. A
// second emit for the same dossier binds the SAME store record (one row),
// never a per-Item row and never a duplicate — this IS "exactly one
// Notification per Dossier" by construction, not by a count. Verbatim port of
// bash `no__notif_id` (`printf 'notif.%s'`); `notif.` + a safe dossier id is
// a safe store key.
function notifId(did) {
  return `notif.${did == null ? "" : did}`;
}

// The CF.9 op surface. Kept OUT of CF.1's CAPABILITIES (anti-drift: the
// differential asserts no_emit/no_dispatch are NOT §2 capability lines, just
// as the bash test greps co_capabilities).
export const NOTIFICATION_OPS = new Set([
  "notif-id", // pure — no__notif_id
  "notif-bound-sv", // pure — no__bound_sv
  "notif-validate", // pure — no__validate (the closed-§4.3-set / §0.3 gate)
  "notif-get", // no_get (§0.3 read-bind)
  "notif-get-for-dossier", // no_get_for_dossier
  "notif-emit", // no_emit (the C3 creation seam)
  "notif-dispatch", // no_dispatch (the C3 false→true-once latch)
  "notif-dispatch-for-dossier", // no_dispatch_for_dossier
  "notif-for-generation", // no_for_generation (the C3 creation hook)
]);

// ── primitive shape predicates (mirror the jq type/length tests verbatim) ───
function isObj(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}
function neStr(v) {
  return typeof v === "string" && v.length > 0;
}
// The §0.3 schema_version primitive: a JSON *integer number* only (a string
// "1", a float, a bool is NOT an integer — exactly the in-jq type check the
// bash `no__validate` / CF.1 `validateRecord` apply).
function intSv(v) {
  return typeof v === "number" && Number.isFinite(v) && Number.isInteger(v) && v >= 0
    ? v
    : null;
}
function nowIso() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

const TIERS = ["blocking", "timed-fyi", "digest"];
// The CLOSED §4.3 field set (bash `no__validate`): `principal` is permitted
// (a §4.3 field stamped at the §9.1 chokepoint by CF.1 `_writeRecord` — never
// a literal here, so it may be ABSENT at validate-time, before the write).
// ANY key outside this set is REJECTED: a Notification structurally CANNOT
// carry a body/content field — the §5 dossier body carries the content
// (principle 2).
const CLOSED_43 = [
  "id",
  "schema_version",
  "principal",
  "dossier_ref",
  "tier",
  "created_at",
  "dispatched",
  "dispatched_at",
  "channel",
];

function rej(msg) {
  return { ok: false, msg };
}
const OK = { ok: true };

// ════════════════════════════════════════════════════════════════════════════
// §4.3 — record-shape + §0.3 validation (port of no__validate). The
// terse-by-structure invariant: the §4.3 field set is CLOSED so "the
// notification stays terse" is an ENFORCED invariant, not a convention.
// ════════════════════════════════════════════════════════════════════════════
function validateNotification(o) {
  const bound = notifBoundSv();
  if (bound === null || bound === undefined)
    return rej(
      "notification: reject — 'notification' absent from the §4 registry (schemaVersion) — store-surface contract gap"
    );
  if (!isObj(o)) return rej("notification: reject — not a JSON object (§4.3)");

  // §0.3 schema_version — a JSON integer, type-checked (a string "1", a float,
  // a bool is rejected); an unknown HIGHER version is rejected as "unknown
  // higher" (never best-effort-parsed); any other value is unsupported.
  const sv = intSv(o.schema_version);
  if (sv === null)
    return rej("notification: reject — missing integer schema_version (§4.3 'int' / §0.3)");
  if (sv > bound)
    return rej(
      `notification: reject — schema_version ${sv} is an unknown higher version (bound=${bound}; §0.3 reject, never best-effort-parse)`
    );
  if (sv !== bound)
    return rej(`notification: reject — schema_version ${sv} unsupported (binds v${bound} only; §0.3)`);

  // §4.3 field shapes. dispatched_at/channel keys MUST be present (string|
  // null) so the C3 creation≠dispatch state is EXPLICIT, not inferred from a
  // missing key (verbatim port of the bash jq field checks).
  if (!neStr(o.id)) return rej("notification: reject — §4.3 id: non-empty string required");
  if (!neStr(o.dossier_ref))
    return rej(
      "notification: reject — §4.3 dossier_ref: non-empty string required (the Dossier it announces; one-per-Dossier)"
    );
  if (!(typeof o.tier === "string" && TIERS.includes(o.tier)))
    return rej(
      "notification: reject — §4.3 tier: blocking|timed-fyi|digest (mirrors the §4.1 dossier tier)"
    );
  if (!neStr(o.created_at))
    return rej(
      "notification: reject — §4.3 created_at: RFC-3339 string required (creation≠dispatch: a row exists before any send — C3)"
    );
  if (typeof o.dispatched !== "boolean")
    return rej(
      "notification: reject — §4.3 dispatched: boolean required (false at creation; fire-and-forget forbidden — C3)"
    );
  if (
    !(
      Object.prototype.hasOwnProperty.call(o, "dispatched_at") &&
      (typeof o.dispatched_at === "string" || o.dispatched_at === null)
    )
  )
    return rej("notification: reject — §4.3 dispatched_at: ts|null (key required)");
  if (
    !(
      Object.prototype.hasOwnProperty.call(o, "channel") &&
      (typeof o.channel === "string" || o.channel === null)
    )
  )
    return rej(
      "notification: reject — §4.3 channel: opaque string|null (key required; later digest rollup needs no schema change — C3)"
    );

  // CLOSED §4.3 field set — a Notification NEVER carries content (principle 2:
  // the §5 dossier body carries it). An extra key (body/content/payload/…) is
  // a structural violation of "the notification stays terse" — REJECTED.
  const extra = Object.keys(o).filter((k) => !CLOSED_43.includes(k));
  if (extra.length > 0)
    return rej(
      `notification: reject — key(s) outside the closed §4.3 set: ${extra.join(
        " "
      )} — a Notification carries NO content (the §5 dossier body does — principle 2)`
    );
  return OK;
}

// ════════════════════════════════════════════════════════════════════════════
// store binding — the §4.3 `notification` record type ONLY (CF.1's registry;
// CF.9 adds NO §4 record type). Reads bind §0.3; writes go THROUGH CF.1's ONE
// write path `_writeRecord` (§0.3 re-enforced + §9.1 principal stamped there).
// Mirrors bash notification.sh consuming `co_request get|put notification`.
// ════════════════════════════════════════════════════════════════════════════
function getRaw(co, type, id) {
  return co.db
    .prepare("SELECT json FROM records WHERE type = ? AND id = ?")
    .bind(type, id)
    .first()
    .then((row) => {
      if (!row) return null;
      try {
        return JSON.parse(row.json);
      } catch {
        return { __unparseable: true };
      }
    });
}

// no_get: raw fetch → §0.3 BOUND ON THE READ PATH. The rc DISCRIMINATION is
// NORMATIVE (bash no_get): a caller MUST distinguish truly-ABSENT (safe to
// create / a genuine fire-and-forget) from a row that EXISTS but is
// unknown-higher / unreadable (must NOT be clobbered, must NOT be reported as
// absent). So:
//   { found:false }                 ⇒ truly ABSENT      (bash rc 1)
//   { ok:false, unreadable:true }   ⇒ EXISTS, §0.3-bad  (bash rc 3)
//   { ok:true, rec }                ⇒ readable           (bash rc 0)
async function noGet(co, nid) {
  const raw = await getRaw(co, "notification", nid);
  if (raw === null) return { ok: false, found: false };
  if (raw.__unparseable)
    return {
      ok: false,
      unreadable: true,
      msg:
        "notification: reject (read) — stored record is not valid JSON (§0.3; never best-effort-parse)",
    };
  const bound = notifBoundSv();
  const sv = intSv(raw.schema_version);
  if (sv === null)
    return {
      ok: false,
      unreadable: true,
      msg: "notification: reject (read) — stored record missing integer schema_version (§0.3)",
    };
  if (sv > bound)
    return {
      ok: false,
      unreadable: true,
      msg: `notification: reject (read) — schema_version ${sv} is an unknown higher version (bound=${bound}; §0.3, never best-effort-parse)`,
    };
  return { ok: true, rec: raw };
}

// Read the §4.1 envelope `tier` the single Notification mirrors. §0.3 is bound
// on the dossier read path too (reject an unknown-higher dossier rather than
// best-effort-parse it — the SAME defence bash `do_dossier_get` adds, which
// `no_emit` consumes). A missing OR unreadable dossier collapses to ONE
// rejection (§9.1 collapses 401/absent; no second auth path — C4). The tier is
// NEVER recomputed here (that is CF.6's, §4.1).
async function dossierTier(co, did) {
  const raw = await getRaw(co, "dossier", did);
  if (raw === null || raw.__unparseable)
    return rej(
      `notification: emit — dossier '${did}' not found OR not authorized (§9.1 chokepoint collapses 401/absent; no second auth path — C4)`
    );
  const bound = dossierBoundSv();
  const sv = intSv(raw.schema_version);
  if (sv === null || sv > bound)
    return rej(
      `notification: emit — dossier '${did}' is not readable under the bound schema (§0.3 unknown-higher/malformed; never best-effort-parse)`
    );
  const tier = typeof raw.tier === "string" ? raw.tier : "";
  if (!tier)
    return rej(
      `notification: emit — dossier '${did}' has no §4.1 tier (the single Notification mirrors it — C3)`
    );
  return { ok: true, tier };
}

// ════════════════════════════════════════════════════════════════════════════
// §4.3 EMIT — the C3 creation seam: ONE Notification, dispatched=false. Port
// of no_emit. The CALLER wraps this in co._serialize so the whole
// read→decide→write is ONE critical section on the single-threaded singleton
// DO (one-per-Dossier + idempotency BY CONSTRUCTION — the AD1 payoff).
// ════════════════════════════════════════════════════════════════════════════
async function noEmit(co, principal, did) {
  if (!neStr(did))
    return rej("notification: emit — need <dossier_id> (§4.3 dossier_ref)");

  // MIRROR the §4.1 tier (read off the dossier; NEVER recomputed — CF.6's).
  const dt = await dossierTier(co, did);
  if (!dt.ok) return dt;
  const tier = dt.tier;

  const nid = notifId(did);

  // One-per-Dossier + idempotency. The §0.3 read-rc DISCRIMINATION matters:
  // only truly-ABSENT ⇒ create. A row that EXISTS but is unknown-higher /
  // unreadable MUST NOT be clobbered (that would destroy a forward-version
  // record + reset created_at/the latch — the exact "never best-effort-parse,
  // never silently destroy an unknown-higher record" §0.3 forbids).
  const ex = await noGet(co, nid);
  if (ex.ok) {
    if (ex.rec.dossier_ref === did) {
      // Idempotent success: created_at and the dispatch latch are NEVER reset
      // (re-emit is not a re-creation; one fork ⇒ one Notification).
      return { ok: true, id: nid };
    }
    return rej(
      `notification: emit REJECTED — notification '${nid}' already bound to dossier '${ex.rec.dossier_ref}' (one Notification per Dossier; NOT clobbered — §4.3/C3)`
    );
  }
  if (ex.found !== false) {
    // EXISTS but §0.3-unreadable ⇒ NOT clobbered.
    return rej(
      `notification: emit REJECTED — a stored Notification '${nid}' exists but is not readable under the bound schema (§0.3 unknown-higher/malformed); NOT clobbered (never best-effort-parse, never silently destroy a forward-version record)`
    );
  }

  // Create the §4.3 row: created_at set, dispatched=false, dispatched_at=null,
  // channel=null — BEFORE any send (the C3 creation≠dispatch seam). principal
  // is NOT stamped here (no second auth path; CF.1 `_writeRecord` stamps the
  // §9.1-resolved principal — C7). The record carries ONLY §4.3 fields (terse
  // by structure — principle 2).
  const rec = {
    id: nid,
    schema_version: notifBoundSv(),
    dossier_ref: did,
    tier,
    created_at: nowIso(),
    dispatched: false,
    dispatched_at: null,
    channel: null,
  };
  const v = validateNotification(rec);
  if (!v.ok) return v;
  // Persist via CF.1's ONE write path (re-enforces §0.3; stamps `principal`
  // at the §9.1 chokepoint — never a literal here — C7).
  const w = await co._writeRecord(principal, "notification", nid, rec);
  if (!w.ok) return rej(w.msg || `notification: emit — write rejected (${w.code})`);
  return { ok: true, id: nid };
}

// ════════════════════════════════════════════════════════════════════════════
// §4.3 DISPATCH — the C3 latch: dispatched false→true EXACTLY ONCE. Port of
// no_dispatch. Wrapped by the caller in co._serialize (false→true-once BY
// CONSTRUCTION on the single-threaded actor — the AD1 payoff).
// ════════════════════════════════════════════════════════════════════════════
async function noDispatch(co, principal, nid, channel) {
  if (!neStr(nid)) return rej("notification: dispatch — need <notif_id> (§4.3)");

  // fire-and-forget FORBIDDEN: the row MUST exist (creation≠dispatch — C3).
  // §0.3 read-rc DISCRIMINATION (same as noEmit): truly-ABSENT ⇒ the genuine
  // fire-and-forget rejection; EXISTS-but-§0.3-bad ⇒ a §0.3 rejection, NOT
  // "no row" (mis-reporting it as absent would invite a clobbering emit).
  const g = await noGet(co, nid);
  if (g.found === false)
    return rej(
      `notification: dispatch REJECTED — no Notification '${nid}' exists; fire-and-forget is forbidden — a row MUST precede any send (creation≠dispatch — C3). Emit it first.`
    );
  if (!g.ok)
    return rej(
      `notification: dispatch REJECTED — stored Notification '${nid}' is not readable under the bound schema (§0.3 unknown-higher/malformed); NOT dispatched (never best-effort-parse a forward-version record)`
    );

  const rec = g.rec;
  if (rec.dispatched === true)
    return rej(
      `notification: dispatch REJECTED — '${nid}' already dispatched (single-writer-set; dispatched flips false→true ONCE — C3)`
    );

  // channel: OPAQUE, stored verbatim; keep the prior value (null at creation)
  // when the caller omits it. A later read-side digest rollup keys off this
  // tag with NO schema change (C3).
  const upd = {
    ...rec,
    dispatched: true,
    dispatched_at: nowIso(),
    channel: neStr(channel) ? channel : rec.channel ?? null,
  };
  const v = validateNotification(upd);
  if (!v.ok) return v;
  const w = await co._writeRecord(principal, "notification", nid, upd);
  if (!w.ok) return rej(w.msg || `notification: dispatch — write rejected (${w.code})`);
  return { ok: true };
}

// no_for_generation: the C3 creation hook. Consume CF.6's PUBLIC §5
// sole-producer op (`dossier-generate` — the `dg_generate` analogue), then
// create the SINGLE §4.3 Notification for the freshly-created dossier, so the
// row exists immediately at dossier creation, BEFORE any send. The two steps
// are SEQUENTIAL self-serialized critical sections (dossier-generate
// serializes internally; the emit below is its own co._serialize) — NEVER
// nested (a nested co._serialize on the shared tail would deadlock).
//
// C3 RESIDUAL (observable, never silent — the sibling "observable, not
// swallowed" discipline): if the dossier IS created but the subsequent emit
// fails, a dossier exists with NO Notification. There is no dossier-delete
// surface here (deleting a CF.6 envelope would touch a sibling), so: a LOUD
// §-cited rejection naming the un-announced dossier — observable, and a retry
// is safe (noEmit is idempotent — one-per-Dossier).
async function noForGeneration(co, principal, gi) {
  // CF.6's producer op surface, consumed as a black box (its §5/§4.1 schema
  // is CF.6's — never re-implemented or inspected here).
  const res = await handleDossierOp(co, "dossier-generate", [gi], principal);
  let body = null;
  try {
    body = JSON.parse(await res.text());
  } catch {
    body = null;
  }
  if (!(body && body.ok === true && neStr(body.id)))
    return rej(
      "notification: for-generation — CF.6 dossier-generate did not produce a dossier (no Notification emitted)"
    );
  const did = body.id;
  const e = await co._serialize(() => noEmit(co, principal, did));
  if (!e.ok)
    return rej(
      `notification: for-generation — WARN dossier '${did}' WAS created (CF.6) but emit FAILED: a dossier exists with NO §4.3 Notification — the C3 'row exists at creation' invariant is unmet for '${did}'. Observable, NOT silent; emit is idempotent (one-per-Dossier) so a retry is safe.`
    );
  return { ok: true, id: e.id };
}

// ════════════════════════════════════════════════════════════════════════════
// THE CF.9 DISPATCHER — called from the Coordinator DO for every
// NOTIFICATION_OPS op. Pure ops short-circuit (no store, no serialize). Every
// store-touching op runs INSIDE co._serialize so the single-threaded
// singleton DO processes one critical section at a time (AD1) — EXCEPT
// notif-for-generation, which is two SEQUENTIAL self-serialized steps (it
// must NOT nest co._serialize on the shared tail).
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

export async function handleNotificationOp(co, op, args, principal) {
  const a = args || [];
  try {
    // ── PURE ops (no store, no serialize) ───────────────────────────────────
    if (op === "notif-id") {
      return textRes(notifId(a[0]));
    }
    if (op === "notif-bound-sv") {
      return textRes(String(notifBoundSv()));
    }
    if (op === "notif-validate") {
      const r = validateNotification(a[0]);
      return jsonRes(r, r.ok ? 200 : 422);
    }

    // ── STORE-TOUCHING ops — serialized through the one single-threaded
    //    actor (AD1: one-per-Dossier + dispatched-once BY CONSTRUCTION) ───────
    if (op === "notif-get") {
      return await co._serialize(async () => {
        const g = await noGet(co, a[0]);
        if (g.ok) return textRes(JSON.stringify(g.rec));
        if (g.found === false) return jsonRes({ ok: false, found: false }, 404);
        return jsonRes({ ok: false, msg: g.msg }, 422);
      });
    }
    if (op === "notif-get-for-dossier") {
      return await co._serialize(async () => {
        const g = await noGet(co, notifId(a[0]));
        if (g.ok) return textRes(JSON.stringify(g.rec));
        if (g.found === false) return jsonRes({ ok: false, found: false }, 404);
        return jsonRes({ ok: false, msg: g.msg }, 422);
      });
    }
    if (op === "notif-emit") {
      const r = await co._serialize(() => noEmit(co, principal, a[0]));
      return jsonRes(r, r.ok ? 200 : 422);
    }
    if (op === "notif-dispatch") {
      const r = await co._serialize(() => noDispatch(co, principal, a[0], a[1]));
      return jsonRes(r, r.ok ? 200 : 422);
    }
    if (op === "notif-dispatch-for-dossier") {
      const r = await co._serialize(() =>
        noDispatch(co, principal, notifId(a[0]), a[1])
      );
      return jsonRes(r, r.ok ? 200 : 422);
    }
    if (op === "notif-for-generation") {
      // NOT wrapped here — noForGeneration sequences two self-serialized
      // steps (dossier-generate, then a co._serialize'd emit). Wrapping it
      // would nest co._serialize on the shared tail and deadlock.
      const r = await noForGeneration(co, principal, a[0]);
      return jsonRes(r, r.ok ? 200 : 422);
    }
    return jsonRes({ ok: false, error: `co: unknown notification op '${op}'` }, 400);
  } catch (e) {
    return jsonRes(
      { ok: false, error: `co: notification internal — ${e && e.message ? e.message : e}` },
      500
    );
  }
}
