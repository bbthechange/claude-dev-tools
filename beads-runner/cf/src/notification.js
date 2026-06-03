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
  "notif-digest", // no_digest (K3 — the read-side group-by-channel rollup)
  "notif-triggers", // N1 — the closed §10.2 catalog (pure)
  "notif-trigger-tiers", // N1 — a trigger's catalog tier(s) (pure)
  "notif-trigger-channel", // N1 — a trigger's batching channel (pure)
  "notif-fire", // N1 — the trigger-catalog spine (emit + tier-guard + route)
]);

// ════════════════════════════════════════════════════════════════════════════
// K3 (claude-tools-uxvk3) — the always-FYI DIGEST ROLLUP (read-side, shared
// with N1). NO schema change: the §4.3 `channel` field ALREADY exists (see the
// `channel` clause in validateNotification + CLOSED_43 above) and is the only
// thing the rollup keys off — "a later read-side digest rollup keys off this
// tag with NO schema change (C3)" (noDispatch comment). This is a pure READ
// op: it enumerates notification records and groups DIGEST-ELIGIBLE ones by
// `channel`. It adds NO §4 record type, edits NO registry, touches NO write
// path. K3 OWNS the cross-WS `xws:` channel convention + the rollup copy; the
// ENGINE (groupDigests) is channel-agnostic so N1 reuses it verbatim.
//
// TIER DISCIPLINE (D.2 — the whole point): ONLY `timed-fyi`/`digest`-tier
// notifications roll up. A `blocking` notification is NEVER swept into a digest
// — it surfaces individually elsewhere (mechanical sync → batched FYI; real
// conflict → an immediate decision). A `channel=null` record is likewise
// excluded (it has no group to join).
// ════════════════════════════════════════════════════════════════════════════

// The tiers a digest is allowed to roll up. `blocking` is DELIBERATELY ABSENT.
const DIGEST_TIERS = ["timed-fyi", "digest"];

// ── [free] K3 defaults (named constants, §9 "deliberately free") ────────────
// Digest CADENCE is daily (UX-DESIGN-V2 §8.2 / ARCH §8 §14.4 "assumed daily").
// This rollup is the read-side projection consumed at digest time; the cadence
// constant documents the assumed sweep interval without coupling the mechanism
// to it (the engine is pull, the cadence is the caller's poll frequency).
export const DIGEST_CADENCE = "daily";
// CHANNEL GRANULARITY for cross-WS: `xws:<project_ref>` (the coarser of the two
// §4.2 options `xws:<project_ref>` vs `xws:<from>:<to>`); finer granularity is
// [free] and a caller may pass a finer channel verbatim — the engine groups on
// whatever opaque string the record carries.
const XWS_PREFIX = "xws:";

// ── the cross-WS channel convention (K3-OWNED) ──────────────────────────────
// xwsChannel(project_ref) => "xws:<project_ref>" — the opaque `channel` tag a
// cross-WS exchange stamps on its `timed-fyi` notification so the rollup can
// group its syncs into ONE digest entry. 1:1 with bash `no__xws_channel`.
export function xwsChannel(projectRef) {
  return `${XWS_PREFIX}${projectRef == null ? "" : projectRef}`;
}

// digestCopy(group) — the K3-OWNED rollup summary copy. Renders the
// "BE↔FE: N syncs today — all resolved, none needed you." style one-liner from
// a digest group. The cross-WS phrasing applies to `xws:`-prefixed channels;
// any other channel degrades to a generic "<channel>: N updates" line (the
// engine is channel-agnostic — N1's non-xws channels still get an honest
// summary). 1:1 with bash `no__digest_copy`. NEVER carries dossier content
// (the digest is the SUMMARY; the relay-log-tail/dossier is the detail behind
// it — principle 2 "the notification carries no content").
export function digestCopy(group) {
  if (!group || typeof group !== "object") return "";
  const ch = typeof group.channel === "string" ? group.channel : "";
  const n = Number.isInteger(group.count) ? group.count : 0;
  const noun = n === 1 ? "sync" : "syncs";
  if (ch.startsWith(XWS_PREFIX)) {
    const ref = ch.slice(XWS_PREFIX.length);
    // "BE↔FE: 6 syncs — all resolved, none needed you." (cross-WS copy)
    return `${ref}: ${n} ${noun} — all resolved, none needed you.`;
  }
  // Generic (N1) channels: an honest non-cross-WS summary.
  const gnoun = n === 1 ? "update" : "updates";
  return `${ch}: ${n} ${gnoun}.`;
}

// ── the generic rollup ENGINE (channel-agnostic — N1 reuses it) ─────────────
// groupDigests(records [, channelPrefix]) — group DIGEST-ELIGIBLE notification
// records by `channel` into one entry per channel. DIGEST-ELIGIBLE =
// tier ∈ {timed-fyi, digest} (EXCLUDE blocking — never rolled up) AND a
// non-null, non-empty `channel`. Optional `channelPrefix` filters to channels
// starting with it (e.g. "xws:" for cross-WS only), mirroring relay-log-tail's
// optional filter. Deterministic order: channel asc, then id asc within
// `dossier_refs`. Returns one entry per channel:
//   { channel, count, tier, dossier_refs:[...] }
// `tier` is the group's tier; if a channel mixes timed-fyi and digest records
// it reports "digest" (the broader bucket). `dossier_refs` is a list of REFS
// (so the UI can expand via relay-log-tail/dossier) — NEVER content.
export function groupDigests(records, channelPrefix) {
  const prefix = neStr(channelPrefix) ? channelPrefix : null;
  const byChannel = new Map();
  for (const rec of records || []) {
    if (!isObj(rec)) continue;
    if (!(typeof rec.tier === "string" && DIGEST_TIERS.includes(rec.tier))) continue;
    const ch = rec.channel;
    if (!neStr(ch)) continue; // channel=null / "" excluded
    if (prefix !== null && !ch.startsWith(prefix)) continue;
    if (!byChannel.has(ch)) byChannel.set(ch, { tiers: new Set(), refs: [], ids: [] });
    const g = byChannel.get(ch);
    g.tiers.add(rec.tier);
    if (neStr(rec.id)) g.ids.push(rec.id);
    if (neStr(rec.dossier_ref)) g.refs.push({ id: neStr(rec.id) ? rec.id : "", ref: rec.dossier_ref });
  }
  const channels = Array.from(byChannel.keys()).sort();
  const digests = channels.map((ch) => {
    const g = byChannel.get(ch);
    // dossier_refs deterministic by id asc (the record id), then ref.
    const refs = g.refs
      .slice()
      .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : a.ref < b.ref ? -1 : a.ref > b.ref ? 1 : 0))
      .map((r) => r.ref);
    return {
      channel: ch,
      count: g.ids.length,
      tier: g.tiers.has("digest") ? "digest" : "timed-fyi",
      dossier_refs: refs,
    };
  });
  return { digests };
}

// noDigest: the read-side rollup op body. Enumerate every §4.3 notification
// record via the SAME typed-SELECT read pattern getRaw uses (read-only, NO
// co._serialize — a pure read like the notif-get read path / forensic tail),
// then hand the parsed records to the channel-agnostic groupDigests engine.
// Only §0.3-readable records participate (an unparseable / unknown-higher row
// is skipped, never best-effort-parsed — the read-path §0.3 discipline).
async function noDigest(co, channelPrefix) {
  const rows = await co.db
    .prepare("SELECT json FROM records WHERE type = 'notification'")
    .all();
  const recs = [];
  const list = (rows && rows.results) || [];
  for (const row of list) {
    let parsed = null;
    try {
      parsed = JSON.parse(row.json);
    } catch {
      continue; // unparseable — skip (never best-effort-parse — §0.3)
    }
    if (!isObj(parsed)) continue;
    const sv = intSv(parsed.schema_version);
    if (sv === null || sv > notifBoundSv()) continue; // §0.3: skip unknown-higher/malformed
    recs.push(parsed);
  }
  return groupDigests(recs, channelPrefix);
}

// ════════════════════════════════════════════════════════════════════════════
// N1 (claude-tools-uxvn1) — the §10.2 TRIGGER CATALOG + the producer-side
// BATCHING SPINE (§10.3). SHARES K3 (cross-ws.md §4.3): the read-side rollup
// ENGINE (groupDigests / noDigest) is K3's and is reused VERBATIM — N1 adds the
// PRODUCER side K3 deferred to it ("K3 owns the cross-WS channel convention +
// the rollup copy; N1 owns the general ... spine ... for the whole trigger
// catalog"). N1 GENERALIZES K3's `xws:` convention to every batchable trigger
// and BINDS each §10.2 trigger to its §4.1 tier. TRIAGE ONLY — the fire path
// passes ONLY (trigger, dossier_id, opaque scope_ref); it carries NO content
// (the §5 dossier body does — principle 2), reuses noEmit/noDispatch (NO new
// write path, NO schema change), and stamps the channel through noDispatch
// EXACTLY as K3's tests demonstrate. Differential oracle: lib/notification.sh
// notif__trigger_policy / notif_fire + their clauses in lib/test-notification.sh.
//
// TIER DISCIPLINE (D.2 + §10.2): `blocking` triggers are NEVER batched (no
// channel — and the K3 read engine excludes blocking too: double safety). Only
// timed-fyi/digest routes a channel. `xws:` is K3-OWNED (reused); the rest
// (`blueprint:`/`intake:`/`queue:`/`agent-gate:`/`stuck:`) are [free] naming.
// ════════════════════════════════════════════════════════════════════════════

// The CLOSED §10.2 catalog (D.2 — shared verbatim with the bash
// notif__trigger_policy `case`). channelPrefix=null ⇒ a non-batched/blocking
// trigger. cross_ws_exchange reuses K3's XWS_PREFIX so it produces EXACTLY
// xwsChannel's tag (no drift). task_maybe_stuck's tier is resolved by the
// I-track failure→tier map (§10.2 r5) — both tiers permitted.
const NOTIF_TRIGGERS = {
  new_dossier: { tiers: ["blocking"], channelPrefix: null }, // §10.2 r1  [Brian B5]
  blueprint_changed: { tiers: ["timed-fyi"], channelPrefix: "blueprint:" }, // r2  [B1/B5]
  cross_ws_exchange: { tiers: ["timed-fyi"], channelPrefix: XWS_PREFIX }, // r3  [C4] K3-owned
  cross_ws_conflict: { tiers: ["blocking"], channelPrefix: null }, // r4  [thirsty §8.3]
  task_maybe_stuck: { tiers: ["timed-fyi", "blocking"], channelPrefix: "stuck:" }, // r5  [B4]
  runner_wedged: { tiers: ["blocking"], channelPrefix: null }, // r6  [B4 §5.4]
  intake_failed: { tiers: ["timed-fyi"], channelPrefix: "intake:" }, // r7  [A leak]
  queue_alarm: { tiers: ["timed-fyi"], channelPrefix: "queue:" }, // r8  [§9 thirsty]
  agent_gate: { tiers: ["timed-fyi"], channelPrefix: "agent-gate:" }, // r9  [B8 §7.4]
  ready_to_pair: { tiers: ["blocking"], channelPrefix: null }, // r10 [Brian] blocking-ish
};

// notifTriggers() — the closed catalog's trigger names (1:1 with the bash
// `case` arms). notifTriggerKnown / notifTriggerTiers / notifTriggerChannel are
// the pure catalog accessors (exported for the differential test, the
// xwsChannel/digestCopy/groupDigests precedent).
export function notifTriggers() {
  return Object.keys(NOTIF_TRIGGERS);
}
export function notifTriggerKnown(t) {
  return Object.prototype.hasOwnProperty.call(NOTIF_TRIGGERS, t);
}
export function notifTriggerTiers(t) {
  const e = NOTIF_TRIGGERS[t];
  return e ? e.tiers.slice() : null;
}
// notifTriggerChannel(trigger, scope) => "<prefix><scope>" for a batchable
// trigger; "" for a KNOWN non-batched (blocking) one; null for an OFF-CATALOG
// trigger (the closed-enum reject — distinct from a known blocking trigger's
// "", so an unknown trigger is never silently treated as "no channel"). This
// is the JS analogue of bash notif_trigger_channel returning nonzero for an
// off-catalog trigger vs empty-stdout+rc0 for a known blocking one.
// cross_ws_exchange yields xwsChannel's "xws:<scope>" exactly.
export function notifTriggerChannel(trigger, scope) {
  const e = NOTIF_TRIGGERS[trigger];
  if (!e) return null; // off-catalog (closed enum — D.2)
  if (!e.channelPrefix) return ""; // known non-batched (blocking) trigger
  return `${e.channelPrefix}${scope == null ? "" : scope}`;
}

// ════════════════════════════════════════════════════════════════════════════
// notifFire(co, principal, trigger, did, scope) — the §10.2 catalog SPINE (port
// of bash notif_fire). validate trigger → noEmit (mirror §4.1 tier) → TIER
// GUARD (catalog binds trigger→tier; mismatch ⇒ a loud producer-bug rejection)
// → CHANNEL ROUTE (batchable + digest-eligible tier ⇒ stamp the channel via
// noDispatch so K3 rolls it up; blocking ⇒ NO channel, left PENDING). Idempotent
// (one-per-Dossier; a re-route to the SAME channel is tolerated, a DIFFERENT one
// rejected). Like noForGeneration this sequences SELF-serialized steps and must
// NOT be wrapped in an outer co._serialize (that would nest + deadlock).
// ════════════════════════════════════════════════════════════════════════════
async function notifFire(co, principal, trigger, did, scope) {
  // Validation ORDER mirrors the bash oracle (notif_fire): <dossier_id> first,
  // then the closed-catalog trigger check — so the two engines emit the SAME
  // diagnostic when BOTH are bad (strict differential equivalence).
  if (!neStr(did))
    return rej("notification: fire — need <dossier_id> (the §5 dossier this trigger announces)");
  if (!notifTriggerKnown(trigger))
    return rej(`notification: fire — unknown §10.2 trigger '${trigger}' (closed catalog — D.2)`);
  const tiers = NOTIF_TRIGGERS[trigger].tiers;

  // emit the ONE Notification (mirrors the dossier §4.1 tier) — its own
  // serialized critical section (NOT nested under an outer serialize).
  const e = await co._serialize(() => noEmit(co, principal, did));
  if (!e.ok) return e;
  const nid = e.id;

  const g = await noGet(co, nid);
  if (!g.ok) return rej(g.msg || `notification: fire — could not read the emitted Notification '${nid}'`);
  const tier = typeof g.rec.tier === "string" ? g.rec.tier : "";
  if (!tier) return rej(`notification: fire — emitted Notification '${nid}' has no tier`);

  // TIER GUARD — the trigger must fire at a catalog-permitted tier.
  if (!tiers.includes(tier))
    return rej(
      `notification: fire REJECTED — trigger '${trigger}' binds tier(s) [${tiers.join(
        " "
      )}] but dossier '${did}' is tier '${tier}' (§10.2 catalog binds trigger→tier; a mismatch is a producer bug — NOT routed)`
    );

  // CHANNEL ROUTE — batchable + digest-eligible tier ⇒ stamp the channel so K3
  // rolls it up; otherwise leave it PENDING (blocking → individual; never
  // batched). Idempotent: an existing route to the SAME channel is success.
  const chan = notifTriggerChannel(trigger, scope);
  if (chan && (tier === "timed-fyi" || tier === "digest")) {
    if (g.rec.dispatched === true) {
      if ((g.rec.channel ?? "") !== chan)
        return rej(
          `notification: fire REJECTED — '${nid}' already routed to channel '${g.rec.channel}'; refusing to re-route to '${chan}' (one dossier ⇒ one batching channel)`
        );
    } else {
      const d = await co._serialize(() => noDispatch(co, principal, nid, chan));
      if (!d.ok) return d;
    }
  }
  return { ok: true, id: nid };
}

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
// (principle 2). EXPORTED so the cross-producer triage-only guard
// (cf/src/notif-triage.js / cf/test/notif-triage.spec.js — claude-tools-n49j)
// can cross-check that the §4.3 record set has not silently widened to admit a
// content field (every CLOSED_43 field MUST be in the independent triage
// vocabulary — a divergence is a loud content-leak red flag).
export const CLOSED_43 = [
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
    // notif-digest (K3): a PURE READ — enumerate notification records and group
    // digest-eligible ones by channel. NO co._serialize (the read-only
    // short-circuit, the notif-get/forensic-tail precedent). Optional arg[0] =
    // a channel prefix filter (e.g. "xws:" for cross-WS only).
    if (op === "notif-digest") {
      const r = await noDigest(co, a[0]);
      return jsonRes(r, 200);
    }
    // notif-* trigger-catalog accessors (N1): PURE — the closed §10.2 catalog,
    // no store. notif-trigger-channel returns text (the bash printf analogue);
    // notif-triggers / notif-trigger-tiers return JSON.
    if (op === "notif-triggers") {
      return jsonRes({ ok: true, triggers: notifTriggers() });
    }
    if (op === "notif-trigger-tiers") {
      const t = notifTriggerTiers(a[0]);
      return t
        ? jsonRes({ ok: true, tiers: t })
        : jsonRes({ ok: false, msg: `notification: unknown §10.2 trigger '${a[0]}' (closed catalog — D.2)` }, 422);
    }
    if (op === "notif-trigger-channel") {
      // off-catalog ⇒ 422 (closed enum — D.2), mirroring notif-trigger-tiers
      // and the bash notif_trigger_channel nonzero reject; a known trigger
      // returns its channel as text ("" for a blocking trigger).
      const ch = notifTriggerChannel(a[0], a[1]);
      return ch === null
        ? jsonRes({ ok: false, msg: `notification: unknown §10.2 trigger '${a[0]}' (closed catalog — D.2)` }, 422)
        : textRes(ch);
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
    if (op === "notif-fire") {
      // NOT outer-wrapped — notifFire sequences SELF-serialized steps (emit,
      // then a co._serialize'd route). Wrapping it would nest co._serialize on
      // the shared tail and deadlock (same as notif-for-generation).
      const r = await notifFire(co, principal, a[0], a[1], a[2]);
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
