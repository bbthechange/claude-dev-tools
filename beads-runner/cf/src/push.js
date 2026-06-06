// N2 (claude-tools-uxg1) — phone DELIVERY transport. DESIGN N §2
// (beads-runner/design/notifications.md). The seam that turns a dispatched
// §4.3 Notification (which "pages no one" — notification.js:31-36) into a real
// Web Push on Brian's installed Inbox PWA.
//
// WHAT THIS IS (DESIGN N §2.2, three parts — this module is parts 2+3):
//   2. A TRANSIENT push-SUBSCRIPTION store (A.2 storage class — NOT a §4
//      record). Lives in its OWN `push_subscriptions` sibling D1 namespace
//      (lazy + idempotent DDL), the forensic.js / capacity.js / machine-state.js
//      "NOT a §4 record" precedent. `push_subscription` is ABSENT from the §4
//      registry (schema.js) and MUST stay absent — NO INTERFACE §4.3 change
//      (uxg1 scope line). One row per browser endpoint.
//   3. The DELIVERY step `notif-deliver`: given the dispatched notifications,
//      it reads each tier + the dossier's §5.1 TL;DR and POSTs a real Web Push
//      (RFC 8291 aes128gcm content encryption + RFC 8292 VAPID auth) to every
//      stored subscription. The payload is TRIAGE ONLY — { tldr, dossier_ref,
//      tier, url } → "Decision: <TL;DR> — tap to open." It NEVER carries the §5
//      body (principle 2; the §4.3 closed-set discipline extended to the wire).
//
// TIER-KEYED CADENCE (DESIGN N §2.3 — D.2 + must-protect #5, load-bearing):
//   • `blocking`     → ONE immediate, individual push (mode "blocking").
//   • `timed-fyi`/`digest` → NEVER an individual push; folded into the K3
//     daily-digest sweep (mode "digest"): N pending in a channel → 1 push,
//     never N. This reuses the K3 rollup ENGINE (groupDigests/digestCopy,
//     notification.js) VERBATIM — N2 is the THIRD consumer of the shared
//     batching spine and adds NOTHING to it (DESIGN N §3).
//
// DELIVER-ONCE without touching the closed §4.3 record: the §4.3 `dispatched`
// latch is overloaded across producers (notifFire leaves a blocking notif
// PENDING=false but routes a timed-fyi to dispatched=true; ask-brian's
// emit_and_dispatch flips it; Flow-F flips it) — so it is NOT a reliable
// "pushed to the phone once" flag. N2 keeps its OWN transient delivery LEDGER
// (`push_deliveries`, keyed by notification id) — also A.2, also NOT a §4
// record. A notification is pushed at most once (immediate OR digest); the
// ledger is the idempotency guard, INSERT OR IGNORE. The §4.3 record is
// untouched (uxg1: "NO INTERFACE §4.3 change").
//
// REVERSIBILITY (DESIGN N §2.4): the §4.3 `channel` tag is opaque and
// already-present; an alternative/additional transport (`email:`/`telegram:`/
// `pushover:`) is a pure add here with NO schema change. Web Push is the spine
// pick (ARCH line 283 "the Inbox is the only push surface"; zero new vendor —
// VAPID is a self-generated key pair). This module is the single place a second
// transport plugs in later.
//
// SUBSTRATE-HANDOFF: every store write composes on the singleton single-
// threaded DO's `co._serialize` tail (AD1). The §9.1 chokepoint (the Worker)
// has ALREADY authenticated + threaded `principal` — no second auth path (C4);
// a no/invalid-token push-* op is rejected 401 at the Worker BEFORE this
// module, so it writes NOTHING and sends NOTHING.

// The K3 rollup engine — reused VERBATIM (DESIGN N §3; N2 adds nothing to it).
import { groupDigests, digestCopy } from "./notification.js";

// ── the N2 op surface (kept OUT of the four §2 CAPABILITIES, the
//    machine-state.js / capacity.js anti-drift discipline) ───────────────────
export const PUSH_OPS = new Set([
  "push-subscribe", // store a browser PushSubscription (A.2 transient)
  "push-unsubscribe", // drop a subscription (browser opt-out / 410-pruned)
  "push-list", // pure read — debug/verify count (no endpoints leaked)
  "notif-deliver", // the delivery sweep: arg[0] = "blocking" | "digest"
]);

// ════════════════════════════════════════════════════════════════════════════
// lazy + idempotent DDL — the SEPARATE transient namespaces (A.2). Mirrors the
// machine-state.js / capacity.js ensure*Schema discipline so push is locally-
// runnable with NO account and NO manual migrate. Canonical migration ships in
// migrations/0007_push.sql for the deploy path. NEITHER table is a §4 record.
// ════════════════════════════════════════════════════════════════════════════
function ensurePushSchema(co) {
  if (!co._pushSchemaReady) {
    co._pushSchemaReady = (async () => {
      await co.db
        .prepare(
          "CREATE TABLE IF NOT EXISTS push_subscriptions (endpoint TEXT NOT NULL PRIMARY KEY, principal TEXT, p256dh TEXT NOT NULL, auth TEXT NOT NULL, created_at TEXT NOT NULL)"
        )
        .run();
      await co.db
        .prepare(
          "CREATE TABLE IF NOT EXISTS push_deliveries (notif_id TEXT NOT NULL PRIMARY KEY, delivered_at TEXT NOT NULL, kind TEXT NOT NULL)"
        )
        .run();
    })();
  }
  return co._pushSchemaReady;
}

// ════════════════════════════════════════════════════════════════════════════
// Web Push CRYPTO — RFC 8291 (aes128gcm content encryption) + RFC 8292 (VAPID),
// implemented on WebCrypto (the SubtleCrypto the Worker runtime exposes; no npm
// `web-push` — that is Node-only). EXPORTED so cf/test/push.spec.js can pin it
// against the RFC 8291 §5 known-answer vector AND a round-trip decrypt, offline.
// ════════════════════════════════════════════════════════════════════════════

const enc = new TextEncoder();

export function b64urlToBytes(s) {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/") + pad;
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
export function bytesToB64url(buf) {
  const u8 = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  let bin = "";
  for (let i = 0; i < u8.length; i++) bin += String.fromCharCode(u8[i]);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function concatBytes(...arrs) {
  let n = 0;
  for (const a of arrs) n += a.length;
  const out = new Uint8Array(n);
  let o = 0;
  for (const a of arrs) {
    out.set(a, o);
    o += a.length;
  }
  return out;
}

// HMAC-SHA256(key, data) → 32 bytes.
async function hmacSha256(keyBytes, dataBytes) {
  const k = await crypto.subtle.importKey(
    "raw",
    keyBytes,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sig = await crypto.subtle.sign("HMAC", k, dataBytes);
  return new Uint8Array(sig);
}
// HKDF-extract (RFC 5869) = HMAC(salt, ikm).
async function hkdfExtract(saltBytes, ikmBytes) {
  return hmacSha256(saltBytes, ikmBytes);
}
// HKDF-expand (RFC 5869), single block (length ≤ 32 — all Web Push outputs are).
// T(1) = HMAC(prk, info || 0x01); return first `length` bytes.
async function hkdfExpand(prkBytes, infoBytes, length) {
  const t = await hmacSha256(prkBytes, concatBytes(infoBytes, new Uint8Array([1])));
  return t.slice(0, length);
}

// importEcdhPrivateRaw(d32, pub65) — a raw P-256 scalar + its uncompressed
// public point → an ECDH private CryptoKey (for deriveBits). Used for the
// (test-injected) deterministic server ephemeral key; the live path generates
// a fresh ephemeral per push.
async function importEcdhPrivateRaw(d32, pub65) {
  const x = pub65.slice(1, 33);
  const y = pub65.slice(33, 65);
  return crypto.subtle.importKey(
    "jwk",
    {
      kty: "EC",
      crv: "P-256",
      d: bytesToB64url(d32),
      x: bytesToB64url(x),
      y: bytesToB64url(y),
      ext: true,
    },
    { name: "ECDH", namedCurve: "P-256" },
    false,
    ["deriveBits"]
  );
}
async function importEcdhPublicRaw(pub65) {
  return crypto.subtle.importKey(
    "raw",
    pub65,
    { name: "ECDH", namedCurve: "P-256" },
    false,
    []
  );
}
// Generate a fresh server ephemeral ECDH keypair; return {privateKey, publicRaw}.
async function generateServerKeys() {
  const kp = await crypto.subtle.generateKey(
    { name: "ECDH", namedCurve: "P-256" },
    true,
    ["deriveBits"]
  );
  const pub = new Uint8Array(await crypto.subtle.exportKey("raw", kp.publicKey));
  return { privateKey: kp.privateKey, publicRaw: pub };
}
// Test seam (cf/test/push.spec.js): build a DETERMINISTIC server ECDH keypair
// from the raw base64url halves, so encryptPayload can reproduce the RFC 8291
// §5 known-answer vector exactly. NOT used in the live path (which generates a
// fresh ephemeral per push via generateServerKeys).
export async function serverKeysFromRaw(privB64url, pubB64url) {
  const pub = b64urlToBytes(pubB64url);
  const privateKey = await importEcdhPrivateRaw(b64urlToBytes(privB64url), pub);
  return { privateKey, publicRaw: pub };
}

// ECDH shared secret (the X coordinate, 32 bytes) — RFC 8291 ecdh_secret.
async function ecdhSecret(serverPrivateKey, uaPublicRaw) {
  const pub = await importEcdhPublicRaw(uaPublicRaw);
  const bits = await crypto.subtle.deriveBits(
    { name: "ECDH", public: pub },
    serverPrivateKey,
    256
  );
  return new Uint8Array(bits);
}

// encryptPayload(plaintextBytes, uaPublicRaw, authSecretBytes, opts?) — the RFC
// 8291 §3.4 + RFC 8188 aes128gcm record. Returns { body, intermediates } where
// `body` is the full message (86-byte header ‖ ciphertext) ready to POST.
// opts.salt (16 B) + opts.serverKeys ({privateKey, publicRaw}) are the test
// seam for the deterministic §5 known-answer; both default to fresh-random.
export async function encryptPayload(plaintextBytes, uaPublicRaw, authSecretBytes, opts = {}) {
  const serverKeys = opts.serverKeys || (await generateServerKeys());
  const salt = opts.salt || crypto.getRandomValues(new Uint8Array(16));

  const ecdh = await ecdhSecret(serverKeys.privateKey, uaPublicRaw);

  // RFC 8291 §3.4: IKM = HKDF(auth_secret, ecdh_secret, key_info, 32),
  // key_info = "WebPush: info" ‖ 0x00 ‖ ua_public ‖ as_public.
  const keyInfo = concatBytes(
    enc.encode("WebPush: info"),
    new Uint8Array([0]),
    uaPublicRaw,
    serverKeys.publicRaw
  );
  const prkKey = await hkdfExtract(authSecretBytes, ecdh);
  const ikm = await hkdfExpand(prkKey, keyInfo, 32);

  // RFC 8188 §2.1: PRK = HKDF-extract(salt, IKM); CEK/NONCE = HKDF-expand.
  const prk = await hkdfExtract(salt, ikm);
  const cek = await hkdfExpand(prk, enc.encode("Content-Encoding: aes128gcm\0"), 16);
  const nonce = await hkdfExpand(prk, enc.encode("Content-Encoding: nonce\0"), 12);

  // Single LAST record: plaintext ‖ 0x02 delimiter (no extra zero padding).
  const record = concatBytes(plaintextBytes, new Uint8Array([2]));
  const aesKey = await crypto.subtle.importKey("raw", cek, { name: "AES-GCM" }, false, ["encrypt"]);
  const ct = new Uint8Array(
    await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, tagLength: 128 }, aesKey, record)
  );

  // RFC 8188 header: salt(16) ‖ rs(4, uint32 BE = 4096) ‖ idlen(1) ‖ keyid(as_public).
  const rs = new Uint8Array([0x00, 0x00, 0x10, 0x00]); // 4096
  const header = concatBytes(salt, rs, new Uint8Array([serverKeys.publicRaw.length]), serverKeys.publicRaw);
  const body = concatBytes(header, ct);

  return {
    body,
    intermediates: { ecdh, prkKey, ikm, prk, cek, nonce, salt, ciphertext: ct, header },
  };
}

// vapidAuthHeader(endpoint, vapidPublicB64url, vapidPrivateB64url, subject, nowSec?)
// — RFC 8292 VAPID. Returns { authorization } = "vapid t=<JWT>,k=<pubkey>".
// The JWT is ES256 over {aud:<origin>, exp:<now+12h>, sub:<subject>}.
export async function vapidAuthHeader(endpoint, vapidPublicB64url, vapidPrivateB64url, subject, nowSec) {
  const aud = new URL(endpoint).origin;
  const now = typeof nowSec === "number" ? nowSec : Math.floor(Date.now() / 1000);
  const exp = now + 12 * 60 * 60; // ≤ 24h (RFC 8292 §2)
  const headerB64 = bytesToB64url(enc.encode(JSON.stringify({ typ: "JWT", alg: "ES256" })));
  const payloadB64 = bytesToB64url(enc.encode(JSON.stringify({ aud, exp, sub: subject })));
  const signingInput = `${headerB64}.${payloadB64}`;

  const pub = b64urlToBytes(vapidPublicB64url); // 0x04 ‖ X ‖ Y
  const d = b64urlToBytes(vapidPrivateB64url); // 32-byte scalar
  const priv = await crypto.subtle.importKey(
    "jwk",
    {
      kty: "EC",
      crv: "P-256",
      d: bytesToB64url(d),
      x: bytesToB64url(pub.slice(1, 33)),
      y: bytesToB64url(pub.slice(33, 65)),
      ext: true,
    },
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
  // WebCrypto ECDSA yields the JOSE raw r‖s (64 bytes) JWS wants — not DER.
  const sig = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, priv, enc.encode(signingInput))
  );
  const jwt = `${signingInput}.${bytesToB64url(sig)}`;
  return { authorization: `vapid t=${jwt},k=${vapidPublicB64url}` };
}

// ════════════════════════════════════════════════════════════════════════════
// the SUBSCRIPTION store (transient A.2) — subscribe / unsubscribe / list.
// ════════════════════════════════════════════════════════════════════════════
function neStr(v) {
  return typeof v === "string" && v.length > 0;
}
function nowIso() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}
// A push endpoint MUST be an absolute https URL (the push service). This is the
// only input-hygiene gate the store needs — the columns are parameter-bound, so
// there is no key-injection surface (the safeKey precedent is for store IDs).
function endpointOk(e) {
  if (!neStr(e)) return false;
  try {
    return new URL(e).protocol === "https:";
  } catch {
    return false;
  }
}

async function pushSubscribe(co, principal, endpoint, p256dh, auth) {
  if (!endpointOk(endpoint))
    return { ok: false, msg: "push-subscribe: reject — endpoint must be an absolute https URL" };
  if (!neStr(p256dh) || !neStr(auth))
    return { ok: false, msg: "push-subscribe: reject — p256dh and auth (the §RFC8291 subscription keys) are required" };
  await co.db
    .prepare(
      "INSERT OR REPLACE INTO push_subscriptions (endpoint, principal, p256dh, auth, created_at) VALUES (?, ?, ?, ?, ?)"
    )
    .bind(endpoint, principal, p256dh, auth, nowIso())
    .run();
  return { ok: true };
}

async function pushUnsubscribe(co, endpoint) {
  if (!neStr(endpoint)) return { ok: false, msg: "push-unsubscribe: reject — endpoint required" };
  const r = await co.db
    .prepare("DELETE FROM push_subscriptions WHERE endpoint = ?")
    .bind(endpoint)
    .run();
  const removed = (r && r.meta && r.meta.changes) || 0;
  return { ok: true, removed };
}

async function loadSubscriptions(co) {
  const { results } = await co.db
    .prepare("SELECT endpoint, p256dh, auth FROM push_subscriptions")
    .all();
  return results || [];
}

// ── the delivery LEDGER (transient A.2) — deliver-once across sweeps ─────────
async function ledgerHas(co, notifId) {
  const r = await co.db
    .prepare("SELECT 1 AS x FROM push_deliveries WHERE notif_id = ?")
    .bind(notifId)
    .first();
  return !!r;
}
async function ledgerMark(co, notifId, kind) {
  // INSERT OR IGNORE: the idempotency guard. A concurrent sweep cannot double-
  // record; the worst case (two overlapping sweeps) is one duplicate push, not
  // a stuck record — and the daemon calls deliver sequentially on a timer.
  await co.db
    .prepare("INSERT OR IGNORE INTO push_deliveries (notif_id, delivered_at, kind) VALUES (?, ?, ?)")
    .bind(notifId, nowIso(), kind)
    .run();
}

// ── targeted deliver-once EVICTION (claude-tools-h8e6) ───────────────────────
// Remove ONE notification's deliver-once row so the NEXT notif-deliver sweep
// re-dispatches a single FRESH push for it. The deliver-once ledger (INSERT OR
// IGNORE on notif_id) is precisely what keeps a re-fired notification SILENT
// after its first delivery — the property pairSurface relies on, and the
// property a §5.6 SNOOZE re-surface must DEFEAT: the user snoozed to 9am and
// expects a 9am ping, not a silent re-entry into the blocking lane. This is the
// ONE narrow seam that re-arms a fresh push without touching normal dedup — it
// is called ONLY by the re-surface fire-action (timer.js snoozeSurface), so the
// ordinary "push at most once" guarantee for every other notification is
// unchanged. Idempotent + best-effort: evicting a notif that was never
// delivered removes 0 rows (a harmless no-op). ensurePushSchema first so a
// re-surface that runs before any delivery sweep still finds the table. Returns
// the rows removed. EXPORTED for the sibling re-surface handler to call (the
// dossierTldr / blockingWirePayload cross-module-export precedent).
export async function evictDelivery(co, notifId) {
  if (!neStr(notifId)) return 0;
  await ensurePushSchema(co);
  const r = await co.db
    .prepare("DELETE FROM push_deliveries WHERE notif_id = ?")
    .bind(notifId)
    .run();
  return (r && r.meta && r.meta.changes) || 0;
}

// ════════════════════════════════════════════════════════════════════════════
// THE WIRE TRIAGE PAYLOAD builders — the SINGLE place each phone-bound payload is
// constructed (consumed by deliverBlocking/deliverDigest below). Extracted +
// EXPORTED so the cross-producer triage-only guard (cf/test/notif-triage.spec.js,
// claude-tools-n49j) pins them: a notification carries ONLY triage (TL;DR + tier
// + a deep link / a digest fan-in count), NEVER the §5 dossier body (principle 2;
// the §4.3 closed-set discipline extended to the wire). Adding any content field
// here trips the guard.
// ════════════════════════════════════════════════════════════════════════════

// blocking: ONE decision → its §5.1 TL;DR + a deep link to the dossier. `tldr`
// is the SHORT triage line read off the dossier (dossierTldr — body.tldr only),
// never the §5 body.
export function blockingWirePayload(dossierRef, tldr) {
  return {
    tldr,
    dossier_ref: dossierRef,
    tier: "blocking",
    url: `/inbox#/d/${dossierRef}`,
  };
}

// digest: ONE channel rollup → the K3 summary line (digestCopy — channel + count
// only, never content) + a link to the Inbox. No per-dossier ref (the group is
// the unit); the count is the fan-in, not content.
export function digestWirePayload(group) {
  return {
    tldr: digestCopy(group),
    dossier_ref: null,
    tier: group.tier,
    channel: group.channel,
    count: group.count,
    url: "/inbox",
  };
}

// ── read the dossier §5.1 TL;DR (TRIAGE ONLY — never the §5 body, principle 2).
// EXPORTED so the triage guard proves the reader returns ONLY the §5.1 TL;DR (a
// canary planted in the §5 body must NOT come back).
export async function dossierTldr(co, did) {
  const row = await co.db
    .prepare("SELECT json FROM records WHERE type = 'dossier' AND id = ?")
    .bind(did)
    .first();
  if (!row) return null;
  try {
    const d = JSON.parse(row.json);
    return d && d.body && neStr(d.body.tldr) ? d.body.tldr : null;
  } catch {
    return null;
  }
}

// ── enumerate the §4.3 notification records (the same typed SELECT noDigest
//    uses — read-only). Skips unparseable rows (§0.3, never best-effort-parse).
async function loadNotifications(co) {
  const { results } = await co.db
    .prepare("SELECT json FROM records WHERE type = 'notification'")
    .all();
  const out = [];
  for (const row of results || []) {
    try {
      const r = JSON.parse(row.json);
      if (r && typeof r === "object" && !Array.isArray(r)) out.push(r);
    } catch {
      /* skip */
    }
  }
  return out;
}

// ════════════════════════════════════════════════════════════════════════════
// the DELIVERY step — POST one Web Push to one subscription. Returns
// { ok } | { ok:false, gone } | { ok:false, status }. DRY_RUN (the test seam +
// a deploy-time safety) builds the encrypted payload + VAPID JWT (so the crypto
// path is fully exercised) but skips the network POST and reports ok.
// ════════════════════════════════════════════════════════════════════════════
async function sendPush(co, sub, payloadObj, vapid) {
  const plaintext = enc.encode(JSON.stringify(payloadObj));
  const encd = await encryptPayload(plaintext, b64urlToBytes(sub.p256dh), b64urlToBytes(sub.auth));
  const auth = await vapidAuthHeader(sub.endpoint, vapid.publicKey, vapid.privateKey, vapid.subject);
  if (vapid.dryRun) return { ok: true, dryRun: true };
  let res;
  try {
    res = await fetch(sub.endpoint, {
      method: "POST",
      headers: {
        Authorization: auth.authorization,
        "Content-Encoding": "aes128gcm",
        "Content-Type": "application/octet-stream",
        TTL: "86400",
      },
      body: encd.body,
    });
  } catch (e) {
    return { ok: false, status: 0, error: e && e.message ? e.message : String(e) };
  }
  if (res.status === 201 || res.status === 200 || res.status === 202) return { ok: true };
  if (res.status === 404 || res.status === 410) return { ok: false, gone: true };
  return { ok: false, status: res.status };
}

// Resolve VAPID config from env. Returns null (honest degradation) if the key
// pair is not configured — delivery cannot fabricate a push (S-1/principle 4).
function vapidConfig(co) {
  const e = co.env || {};
  const publicKey = e.VAPID_PUBLIC_KEY;
  const privateKey = e.VAPID_PRIVATE_KEY;
  const subject = neStr(e.VAPID_SUBJECT) ? e.VAPID_SUBJECT : "mailto:bbthechange@gmail.com";
  const dryRun = e.PUSH_DRY_RUN === "1" || e.PUSH_DRY_RUN === 1 || e.PUSH_DRY_RUN === true;
  if (!neStr(publicKey) || !neStr(privateKey)) return null;
  return { publicKey, privateKey, subject, dryRun };
}

// fan one payload out to every subscription; prune 404/410 (gone) endpoints.
// Returns { sent, failed, pruned }.
async function fanOut(co, subs, payloadObj, vapid) {
  let sent = 0;
  let failed = 0;
  let pruned = 0;
  for (const sub of subs) {
    let r;
    try {
      r = await sendPush(co, sub, payloadObj, vapid);
    } catch (e) {
      // A throw here (e.g. a malformed p256dh/auth that breaks the RFC 8291
      // ECDH/encrypt or the VAPID JWT build) is ISOLATED to this one
      // subscription — it must NEVER abort the whole sweep and starve delivery
      // to every other (healthy) device. Count it failed and move on; it is not
      // pruned (a conservative choice — a structural problem just keeps failing
      // harmlessly rather than risking a mass-delete on a transient fault).
      failed++;
      continue;
    }
    if (r.ok) {
      sent++;
    } else if (r.gone) {
      pruned++;
      await co.db.prepare("DELETE FROM push_subscriptions WHERE endpoint = ?").bind(sub.endpoint).run();
    } else {
      failed++;
    }
  }
  return { sent, failed, pruned };
}

// ── notif-deliver mode "blocking": ONE immediate push per blocking notif not
//    yet in the ledger. The load-bearing path (DESIGN N §2.3).
async function deliverBlocking(co, vapid) {
  const subs = await loadSubscriptions(co);
  const notifs = await loadNotifications(co);
  let pending = 0;
  let pushed = 0;
  let sent = 0;
  let pruned = 0;
  for (const n of notifs) {
    if (n.tier !== "blocking") continue;
    if (!neStr(n.id) || !neStr(n.dossier_ref)) continue;
    if (await ledgerHas(co, n.id)) continue;
    pending++;
    if (subs.length === 0) continue; // nothing to deliver to — leave unledgered
    const tldr = (await dossierTldr(co, n.dossier_ref)) || "A decision needs you.";
    const payload = blockingWirePayload(n.dossier_ref, tldr);
    const r = await fanOut(co, subs, payload, vapid);
    sent += r.sent;
    pruned += r.pruned;
    if (r.sent > 0) {
      await ledgerMark(co, n.id, "blocking");
      pushed++;
    }
  }
  return { ok: true, mode: "blocking", subscriptions: subs.length, pending, pushed, pushes: sent, pruned };
}

// ── notif-deliver mode "digest": the K3 daily sweep. Group the FRESH (not-yet-
//    ledgered) digest-eligible notifs by channel via groupDigests (the K3
//    engine, verbatim); send ONE push per channel group; ledger every notif
//    folded into a delivered group. N pending → 1 push, never N (must-protect
//    #5). `blocking` is never swept (groupDigests excludes it — double safety).
async function deliverDigest(co, vapid) {
  const subs = await loadSubscriptions(co);
  const notifs = await loadNotifications(co);

  // fresh = digest-eligible (groupDigests' own filter) AND not yet delivered.
  const fresh = [];
  for (const n of notifs) {
    if (!neStr(n.id)) continue;
    if (!(n.tier === "timed-fyi" || n.tier === "digest")) continue;
    if (!neStr(n.channel)) continue;
    if (await ledgerHas(co, n.id)) continue;
    fresh.push(n);
  }
  const { digests } = groupDigests(fresh);
  let pushed = 0;
  let sent = 0;
  let pruned = 0;
  for (const g of digests) {
    const payload = digestWirePayload(g);
    let delivered = true;
    if (subs.length > 0) {
      const r = await fanOut(co, subs, payload, vapid);
      sent += r.sent;
      pruned += r.pruned;
      delivered = r.sent > 0;
    } else {
      delivered = false; // no subscriptions — leave the group unledgered
    }
    if (delivered) {
      pushed++;
      for (const n of fresh) {
        if (n.channel === g.channel) await ledgerMark(co, n.id, "digest");
      }
    }
  }
  return {
    ok: true,
    mode: "digest",
    subscriptions: subs.length,
    groups: digests.length,
    pushed,
    pushes: sent,
    pruned,
  };
}

// ════════════════════════════════════════════════════════════════════════════
// the PUSH_OPS dispatcher. Store writes (subscribe/unsubscribe) run INSIDE
// co._serialize (AD1). notif-deliver does pure reads + a network fan-out + a
// short INSERT-OR-IGNORE ledger write per success: it is DELIBERATELY NOT
// wrapped in an outer co._serialize, so a multi-second push fan-out does not
// block every other op on the singleton DO (the ledger is the idempotency
// guard instead). push-list is a pure read.
// ════════════════════════════════════════════════════════════════════════════
function jsonRes(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export async function handlePushOp(co, op, args, principal) {
  const a = args || [];
  await ensurePushSchema(co);
  try {
    if (op === "push-subscribe") {
      const r = await co._serialize(() => pushSubscribe(co, principal, a[0], a[1], a[2]));
      return jsonRes(r, r.ok ? 200 : 422);
    }
    if (op === "push-unsubscribe") {
      const r = await co._serialize(() => pushUnsubscribe(co, a[0]));
      return jsonRes(r, r.ok ? 200 : 422);
    }
    if (op === "push-list") {
      const subs = await loadSubscriptions(co);
      // count only — endpoints are delivery plumbing, never leaked to a reader.
      return jsonRes({ ok: true, count: subs.length });
    }
    if (op === "notif-deliver") {
      const mode = a[0] === "digest" ? "digest" : "blocking";
      const vapid = vapidConfig(co);
      if (!vapid)
        return jsonRes(
          {
            ok: false,
            error:
              "notif-deliver: VAPID not configured (VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY Worker secrets required — no push can be sent; honest degradation, NOT a stub)",
          },
          503
        );
      const r = mode === "digest" ? await deliverDigest(co, vapid) : await deliverBlocking(co, vapid);
      return jsonRes(r, 200);
    }
    return jsonRes({ ok: false, error: `co: unknown push op '${op}'` }, 400);
  } catch (e) {
    return jsonRes({ ok: false, error: `co: push internal — ${e && e.message ? e.message : e}` }, 500);
  }
}
