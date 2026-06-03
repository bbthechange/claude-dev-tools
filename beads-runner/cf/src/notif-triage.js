// claude-tools-n49j — the cross-producer TRIAGE-ONLY invariant (principle 2).
//
// UX-DESIGN-V2 §10 + §11 principle 2 + design/notifications.md §5: a
// notification — whether the persisted §4.3 record OR the wire payload pushed to
// the phone — only TRIAGES. It carries the §5.1 TL;DR + the tier + a deep link
// (and, for a digest, the fan-in count). It NEVER carries the §5 dossier /
// decision body. "The notification carries no content; the §5 dossier body does."
//
// This is the SHARED assertion EVERY notification producer must satisfy:
//   • noEmit          — the §4.3 record (notification.js)
//   • notifFire       — the trigger → channel routing (the §10.2 catalog)
//   • digestCopy      — the K3 rollup summary line (notification.js)
//   • blockingWirePayload / digestWirePayload — the N2 wire payloads (push.js)
// so a FUTURE §10.2 trigger or transport that embeds dossier content fails loudly
// (this guard's spec, cf/test/notif-triage.spec.js) instead of silently paging
// Brian the whole dossier. Safety-net (P3), not a feature — pure, no store/crypto.
//
// INDEPENDENCE IS THE POINT: the triage vocabulary below is hardcoded here, NOT
// imported from notification.js's CLOSED_43. If someone widened the §4.3 record
// set itself to admit a `body`/`content` field, deriving from CLOSED_43 would
// make this guard blindly accept it. Instead the two definitions are independent
// and the spec cross-checks CLOSED_43 ⊆ TRIAGE_KEYS — so a §4.3 widening to a
// content field is red-flagged, not absorbed.

// The §4.3 record fields (the persisted Notification — terse by structure).
export const RECORD_TRIAGE_FIELDS = [
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

// The wire-only fields the N2 delivery payload adds on top of the record fields:
// the §5.1 TL;DR (a SHORT triage line — never the body), the deep link, and the
// digest fan-in count.
export const WIRE_TRIAGE_FIELDS = ["tldr", "url", "count"];

// The closed triage vocabulary = record fields ∪ wire fields. ANY key outside it
// is a structural content leak (a body/content/payload/options/markdown/mermaid/
// consequence/decision/sections/detail/items/full_detail field, …).
export const TRIAGE_KEYS = new Set([...RECORD_TRIAGE_FIELDS, ...WIRE_TRIAGE_FIELDS]);

function isObj(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

// triageViolations(payload, {canary}) → string[] of reasons it is NOT triage-only
// (empty ⇒ clean). TWO independent checks:
//   1. CLOSED KEY-SET — no key outside TRIAGE_KEYS (the structural guarantee:
//      a content field cannot even be NAMED in a triage payload).
//   2. CANARY scan — a unique dossier-CONTENT marker (planted in the §5 body but
//      NOT in the §5.1 TL;DR) must appear NOWHERE in the payload. Catches a
//      producer that copies the body into an ALLOWED field (e.g. tldr ← body, or
//      a content-bearing scope → channel) — a leak the key-set alone would miss.
//      The canary is a SENTINEL: it catches the exact marker, so the closed
//      key-set (check 1) is the structural backstop for any body fragment that
//      lacks it. Together they cover the realistic vectors; the spec plants the
//      canary in EVERY producer's source dossier so a body-copy drags it through.
export function triageViolations(payload, opts = {}) {
  const out = [];
  if (!isObj(payload)) {
    return ["payload is not a JSON object (a triage payload must be an object)"];
  }
  for (const k of Object.keys(payload)) {
    if (!TRIAGE_KEYS.has(k)) {
      out.push(
        `key '${k}' is outside the closed triage vocabulary — a notification carries NO content (the §5 dossier body does — principle 2)`
      );
    }
  }
  const canary = opts.canary;
  if (typeof canary === "string" && canary.length > 0) {
    if (JSON.stringify(payload).includes(canary)) {
      out.push(
        `dossier content canary leaked into the payload — the §5 body must stay in the dossier; notifications only triage (principle 2)`
      );
    }
  }
  return out;
}

export function isTriageOnly(payload, opts) {
  return triageViolations(payload, opts).length === 0;
}
