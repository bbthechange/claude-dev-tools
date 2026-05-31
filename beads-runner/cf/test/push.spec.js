// N2 (claude-tools-uxg1) — phone DELIVERY transport conformance. DESIGN N §2.
//
// Exercises the REAL engine (Worker → §9.1 chokepoint → singleton Coordinator
// DO → D1) via SELF.fetch under the SAME workerd+miniflare runtime `wrangler
// dev` uses, NO Cloudflare account — AND pins the Web-Push CRYPTO directly
// against the RFC 8291 §5 published worked example (a known-answer vector, not
// a self-referential round-trip). This is the OFFLINE half of the uxg1 gate;
// the live-on-a-real-device half is the deploy + phone step (DESIGN N §2.5),
// which needs Brian's Cloudflare creds + device and is handed off in the bead.
//
// What this proves:
//   • RFC 8291 §5: encryptPayload reproduces every intermediate (ecdh_secret,
//     PRK_key, IKM, PRK, CEK, nonce) AND the final 86-byte header + ciphertext
//     byte-for-byte. If the encryption were wrong the bytes would diverge — so
//     this is real crypto, not a stub (the bgw forbidden-local-stub lens).
//   • RFC 8292 VAPID: the Authorization header carries a well-formed ES256 JWT
//     whose signature verifies under the public key and whose claims are right.
//   • subscribe/unsubscribe/list: the transient A.2 store round-trips; a non-
//     https endpoint is rejected; a re-subscribe replaces; unsubscribe removes.
//   • notif-deliver (DRY_RUN): blocking → ONE push per pending blocking notif,
//     ledgered, idempotent on re-run; digest → ONE push per channel group (N→1,
//     never N), ledgered; no VAPID → honest 503 (never a silent fake send).
//   • Anti-drift: `push_subscription` is NOT a §4 type; the four §2 capability
//     lines stay four; the §4 records table never holds a subscription.

import { env, SELF } from "cloudflare:test";
import { it, expect } from "vitest";
import { schemaVersion } from "../src/schema.js";
import {
  encryptPayload,
  vapidAuthHeader,
  serverKeysFromRaw,
  b64urlToBytes,
  bytesToB64url,
} from "../src/push.js";

const GOOD = "bearer-runner-secret-xyz";

let PASS = 0;
let FAIL = 0;
let fails = [];
// Each `it` shares the module-level counters (the machine-state.spec.js ck/PASS
// pattern) but is independent, so reset at the top of every block — otherwise a
// failure in one cascades into every later `expect(FAIL).toBe(0)`.
function reset() {
  PASS = 0;
  FAIL = 0;
  fails = [];
}
function ck(name, cond) {
  if (cond) {
    PASS++;
    // eslint-disable-next-line no-console
    console.log(`  ✓ ${name}`);
  } else {
    FAIL++;
    fails.push(name);
    // eslint-disable-next-line no-console
    console.log(`  ✗ ${name}`);
  }
}

function authReq(bearer, op, args) {
  const headers = { "content-type": "application/json" };
  if (bearer !== null) headers["authorization"] = `Bearer ${bearer}`;
  return new Request("https://coordinator.local/", {
    method: "POST",
    headers,
    body: JSON.stringify({ op, args: args || [] }),
  });
}
async function call(bearer, op, args) {
  const res = await SELF.fetch(authReq(bearer, op, args));
  const ct = res.headers.get("content-type") || "";
  const raw = await res.text();
  let body = null;
  if (ct.includes("application/json")) {
    try {
      body = JSON.parse(raw);
    } catch {
      body = null;
    }
  }
  return { status: res.status, raw, body };
}

const utf8 = (s) => new TextEncoder().encode(s);

// ════════════════════════════════════════════════════════════════════════════
it("N2 Web-Push crypto is byte-faithful to the RFC 8291 §5 known-answer vector", async () => {
  reset();
  // The RFC 8291 §5 "Push Message Encryption Example", verbatim.
  const PLAINTEXT = "V2hlbiBJIGdyb3cgdXAsIEkgd2FudCB0byBiZSBhIHdhdGVybWVsb24"; // b64url
  const SALT = "DGv6ra1nlYgDCS1FRnbzlw";
  const AUTH = "BTBZMqHH6r4Tts7J_aSIgg";
  const AS_PUB = "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8";
  const AS_PRIV = "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw";
  const UA_PUB = "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4";
  const EXP = {
    ecdh: "kyrL1jIIOHEzg3sM2ZWRHDRB62YACZhhSlknJ672kSs",
    prkKey: "Snr3JMxaHVDXHWJn5wdC52WjpCtd2EIEGBykDcZW32k",
    ikm: "S4lYMb_L0FxCeq0WhDx813KgSYqU26kOyzWUdsXYyrg",
    prk: "09_eUZGrsvxChDCGRCdkLiDXrReGOEVeSCdCcPBSJSc",
    cek: "oIhVW04MRdy2XN9CiKLxTg",
    nonce: "4h_95klXJ5E_qnoN",
    header: "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8",
    // The full encrypted message (header ‖ ciphertext) as ONE base64url blob —
    // the authoritative §5 result (header and ciphertext re-align at the byte
    // boundary, so they cannot be compared as separate base64 strings). Taken
    // verbatim from rfc-editor.org/rfc/rfc8291.txt §5 (the 3 wrapped lines,
    // dewrapped).
    full:
      "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml" +
      "mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT" +
      "pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN",
  };

  const serverKeys = await serverKeysFromRaw(AS_PRIV, AS_PUB);
  const { body, intermediates } = await encryptPayload(
    b64urlToBytes(PLAINTEXT),
    b64urlToBytes(UA_PUB),
    b64urlToBytes(AUTH),
    { salt: b64urlToBytes(SALT), serverKeys }
  );
  const i = intermediates;
  ck("ecdh_secret matches RFC 8291 §5", bytesToB64url(i.ecdh) === EXP.ecdh);
  ck("PRK_key matches RFC 8291 §5", bytesToB64url(i.prkKey) === EXP.prkKey);
  ck("IKM matches RFC 8291 §5", bytesToB64url(i.ikm) === EXP.ikm);
  ck("PRK (content) matches RFC 8291 §5", bytesToB64url(i.prk) === EXP.prk);
  ck("CEK matches RFC 8291 §5", bytesToB64url(i.cek) === EXP.cek);
  ck("NONCE matches RFC 8291 §5", bytesToB64url(i.nonce) === EXP.nonce);
  ck("encrypted HEADER matches RFC 8291 §5 (86 octets)", bytesToB64url(i.header) === EXP.header);
  // The full POST body (header ‖ ciphertext) matches the authoritative §5
  // result byte-for-byte — the definitive known-answer proof (not a stub).
  ck("full encrypted message matches RFC 8291 §5 (192 b64url chars)", bytesToB64url(body) === EXP.full);

  expect(FAIL, `RFC 8291 crypto failed: ${fails.join("; ")}`).toBe(0);
});

// ════════════════════════════════════════════════════════════════════════════
it("N2 VAPID Authorization is a valid, verifiable ES256 JWT (RFC 8292)", async () => {
  reset();
  // A throwaway VAPID keypair, generated here so the test owns both halves.
  const kp = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const pubRaw = new Uint8Array(await crypto.subtle.exportKey("raw", kp.publicKey));
  const jwk = await crypto.subtle.exportKey("jwk", kp.privateKey);
  const d = b64urlToBytes(jwk.d);
  const pubB64 = bytesToB64url(pubRaw);
  const privB64 = bytesToB64url(d);

  const endpoint = "https://fcm.googleapis.com/fcm/send/abc123";
  const { authorization } = await vapidAuthHeader(endpoint, pubB64, privB64, "mailto:x@y.z", 1000);

  ck("Authorization is the vapid scheme with t= and k=", /^vapid t=.+,k=.+$/.test(authorization));
  const m = authorization.match(/^vapid t=([^,]+),k=(.+)$/);
  ck("k= echoes the VAPID public key", m && m[2] === pubB64);

  const parts = (m ? m[1] : "").split(".");
  ck("JWT has three segments", parts.length === 3);
  const hdr = JSON.parse(new TextDecoder().decode(b64urlToBytes(parts[0])));
  const pl = JSON.parse(new TextDecoder().decode(b64urlToBytes(parts[1])));
  ck("JWT header alg=ES256 typ=JWT", hdr.alg === "ES256" && hdr.typ === "JWT");
  ck("JWT aud is the endpoint ORIGIN (not the full path)", pl.aud === "https://fcm.googleapis.com");
  ck("JWT sub is the configured subject", pl.sub === "mailto:x@y.z");
  ck("JWT exp = now + 12h", pl.exp === 1000 + 12 * 60 * 60);

  // The signature MUST verify under the public key (proves it is correctly
  // ES256-signed JOSE r‖s, not DER, and not garbage).
  const verifyKey = await crypto.subtle.importKey(
    "jwk",
    { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y, ext: true },
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"]
  );
  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    verifyKey,
    b64urlToBytes(parts[2]),
    utf8(parts[0] + "." + parts[1])
  );
  ck("JWT signature verifies under the VAPID public key", ok === true);

  expect(FAIL, `VAPID JWT failed: ${fails.join("; ")}`).toBe(0);
});

// ════════════════════════════════════════════════════════════════════════════
async function subCount() {
  const r = await env.DB.prepare("SELECT COUNT(*) AS n FROM push_subscriptions").first();
  return r ? r.n : 0;
}
async function freshPushStore() {
  for (const t of ["push_subscriptions", "push_deliveries"]) {
    try {
      await env.DB.prepare(`DELETE FROM ${t}`).run();
    } catch {
      /* not lazily created yet = already empty */
    }
  }
}

it("N2 subscribe/unsubscribe/list — the transient A.2 store round-trips", async () => {
  reset();
  // Ensure the table exists (a push-list touches ensurePushSchema), then clear.
  await call(GOOD, "push-list", []);
  await freshPushStore();

  const EP = "https://fcm.googleapis.com/fcm/send/sub-A";
  const s = await call(GOOD, "push-subscribe", [EP, "p256dh-A", "auth-A"]);
  ck("push-subscribe a valid sub ⇒ ok", s.status === 200 && s.body && s.body.ok === true);
  ck("the subscription is stored", (await subCount()) === 1);

  const list = await call(GOOD, "push-list", []);
  ck("push-list reports count=1 (and leaks no endpoints)", list.body && list.body.count === 1 && !("subscriptions" in list.body));

  // Re-subscribe the SAME endpoint (rotated keys) replaces, not duplicates.
  await call(GOOD, "push-subscribe", [EP, "p256dh-A2", "auth-A2"]);
  ck("re-subscribe the same endpoint REPLACES (still count=1)", (await subCount()) === 1);

  // A non-https endpoint is rejected; nothing written.
  const bad = await call(GOOD, "push-subscribe", ["http://insecure/x", "p", "a"]);
  ck("non-https endpoint ⇒ 422 reject", bad.status === 422 && bad.body && bad.body.ok === false);
  const bad2 = await call(GOOD, "push-subscribe", [EP, "", "auth"]);
  ck("missing p256dh ⇒ 422 reject", bad2.status === 422);
  ck("a rejected subscribe wrote nothing new (still count=1)", (await subCount()) === 1);

  const u = await call(GOOD, "push-unsubscribe", [EP]);
  ck("push-unsubscribe removes the row", u.status === 200 && u.body && u.body.removed === 1);
  ck("the store is empty after unsubscribe", (await subCount()) === 0);

  // §9.1 — no token ⇒ rejected at the chokepoint, nothing written.
  const noTok = await call(null, "push-subscribe", [EP, "p", "a"]);
  ck("no-token push-subscribe ⇒ 401 at the Worker", noTok.status === 401);
  ck("no-token push-subscribe wrote nothing", (await subCount()) === 0);

  expect(FAIL, `subscribe/unsubscribe failed: ${fails.join("; ")}`).toBe(0);
});

// ════════════════════════════════════════════════════════════════════════════
// Seed §4.3-shaped notification rows + the dossier they announce directly in
// D1 (the delivery step only READS tier + dossier_ref + the dossier tldr; it
// never validates the notif), so the test does not need the full CF.6 generate
// + CF.9 fire chain.
async function seedDossier(did, tldr, tier) {
  await env.DB.prepare("INSERT OR REPLACE INTO records (type, id, json) VALUES ('dossier', ?, ?)")
    .bind(did, JSON.stringify({ id: did, schema_version: 1, tier, body: { tldr } }))
    .run();
}
async function seedNotif(did, tier, channel) {
  const id = `notif.${did}`;
  await env.DB.prepare("INSERT OR REPLACE INTO records (type, id, json) VALUES ('notification', ?, ?)")
    .bind(
      id,
      JSON.stringify({
        id,
        schema_version: 1,
        dossier_ref: did,
        tier,
        created_at: "2026-05-30T00:00:00Z",
        dispatched: tier !== "blocking",
        dispatched_at: tier !== "blocking" ? "2026-05-30T00:00:00Z" : null,
        channel: channel || null,
      })
    )
    .run();
}
async function ledgerCount() {
  const r = await env.DB.prepare("SELECT COUNT(*) AS n FROM push_deliveries").first();
  return r ? r.n : 0;
}

// A generated subscription (real ECDH p256dh so encryptPayload runs) + a valid
// VAPID keypair, with DRY_RUN so the full crypto path runs but no network POST.
async function configurePushEnv() {
  const ua = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const p256dh = bytesToB64url(new Uint8Array(await crypto.subtle.exportKey("raw", ua.publicKey)));
  const auth = bytesToB64url(crypto.getRandomValues(new Uint8Array(16)));
  const vapid = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign"]);
  const vpub = bytesToB64url(new Uint8Array(await crypto.subtle.exportKey("raw", vapid.publicKey)));
  const vjwk = await crypto.subtle.exportKey("jwk", vapid.privateKey);
  env.VAPID_PUBLIC_KEY = vpub;
  env.VAPID_PRIVATE_KEY = bytesToB64url(b64urlToBytes(vjwk.d));
  env.VAPID_SUBJECT = "mailto:test@beads.local";
  env.PUSH_DRY_RUN = "1";
  return { p256dh, auth };
}
function clearPushEnv() {
  delete env.VAPID_PUBLIC_KEY;
  delete env.VAPID_PRIVATE_KEY;
  delete env.VAPID_SUBJECT;
  delete env.PUSH_DRY_RUN;
}

it("N2 notif-deliver — tier-keyed cadence, deliver-once ledger, honest no-VAPID", async () => {
  reset();
  await call(GOOD, "push-list", []); // ensure schema
  await freshPushStore();
  await env.DB.prepare("DELETE FROM records WHERE type IN ('notification','dossier')").run();

  // ── no VAPID configured ⇒ honest 503, never a silent fake send ─────────────
  clearPushEnv();
  const unconf = await call(GOOD, "notif-deliver", ["blocking"]);
  ck("notif-deliver with no VAPID ⇒ 503 (honest degradation, not a stub)", unconf.status === 503 && unconf.body && unconf.body.ok === false);

  // ── configure (DRY_RUN) + a subscription ───────────────────────────────────
  const { p256dh, auth } = await configurePushEnv();
  await call(GOOD, "push-subscribe", ["https://fcm.googleapis.com/fcm/send/dev-1", p256dh, auth]);

  // ── BLOCKING: one immediate push per pending blocking notif ────────────────
  await seedDossier("dos-block-1", "Pick the deploy window.", "blocking");
  await seedNotif("dos-block-1", "blocking", null);
  const b1 = await call(GOOD, "notif-deliver", ["blocking"]);
  ck("blocking sweep ⇒ ok 200", b1.status === 200 && b1.body && b1.body.ok === true && b1.body.mode === "blocking");
  ck("blocking sweep pushed exactly 1 notif", b1.body && b1.body.pushed === 1);
  ck("blocking sweep recorded it in the deliver-once ledger", (await ledgerCount()) === 1);

  // Idempotent: a second sweep does NOT re-push (the ledger guards it).
  const b2 = await call(GOOD, "notif-deliver", ["blocking"]);
  ck("re-run blocking sweep pushes 0 (deliver-once, ledger guard)", b2.body && b2.body.pushed === 0 && b2.body.pending === 0);

  // A timed-fyi is NEVER delivered by the blocking sweep.
  await seedDossier("dos-fyi-1", "BE↔FE sync.", "timed-fyi");
  await seedNotif("dos-fyi-1", "timed-fyi", "xws:thirsty");
  const b3 = await call(GOOD, "notif-deliver", ["blocking"]);
  ck("blocking sweep ignores timed-fyi notifs (pending=0)", b3.body && b3.body.pending === 0 && b3.body.pushed === 0);

  // ── DIGEST: N pending in a channel → 1 push, never N ───────────────────────
  await seedDossier("dos-fyi-2", "BE↔FE sync 2.", "timed-fyi");
  await seedNotif("dos-fyi-2", "timed-fyi", "xws:thirsty"); // same channel as dos-fyi-1
  await seedDossier("dos-fyi-3", "Blueprint nudged.", "timed-fyi");
  await seedNotif("dos-fyi-3", "timed-fyi", "blueprint:thirsty"); // a second channel
  const d1 = await call(GOOD, "notif-deliver", ["digest"]);
  ck("digest sweep ⇒ ok 200 mode=digest", d1.status === 200 && d1.body && d1.body.mode === "digest");
  ck("digest groups the 3 fyi notifs into 2 channel groups", d1.body && d1.body.groups === 2);
  ck("digest sends ONE push per group (N→1, never N)", d1.body && d1.body.pushed === 2);
  // All three fyi notifs are now ledgered (1 blocking + 3 fyi = 4 total).
  ck("digest ledgered every folded notif (4 total deliveries)", (await ledgerCount()) === 4);

  // Idempotent: a second digest sweep finds nothing fresh.
  const d2 = await call(GOOD, "notif-deliver", ["digest"]);
  ck("re-run digest sweep finds 0 fresh groups (ledger guard)", d2.body && d2.body.groups === 0 && d2.body.pushed === 0);

  // ── ISOLATION: a malformed subscription must NOT starve a healthy one ──────
  // A bad p256dh throws inside the RFC 8291 ECDH/encrypt; the sweep must isolate
  // that one sub and still deliver to the good one (never abort the whole fan-out).
  await call(GOOD, "push-subscribe", ["https://fcm.googleapis.com/fcm/send/broken", "!!not-base64!!", "auth"]);
  await seedDossier("dos-block-iso", "Healthy delivery despite a broken sub.", "blocking");
  await seedNotif("dos-block-iso", "blocking", null);
  const iso = await call(GOOD, "notif-deliver", ["blocking"]);
  ck("a malformed sub does not crash the sweep (200, ok)", iso.status === 200 && iso.body && iso.body.ok === true);
  ck("the healthy sub still got the push despite the broken one", iso.body && iso.body.pushed === 1);

  clearPushEnv();
  expect(FAIL, `notif-deliver failed: ${fails.join("; ")}`).toBe(0);
});

// ════════════════════════════════════════════════════════════════════════════
it("N2 anti-drift — push is NOT a §4 record; the §2 substrate is untouched", async () => {
  reset();
  ck("'push_subscription' is NOT a §4 record type (absent from schemaVersion)", schemaVersion("push_subscription") === null);
  const gput = await call(GOOD, "put", ["push_subscription", "x", '{"schema_version":1}']);
  ck("put push_subscription ⇒ unknown_type", gput.status === 422 && gput.body && gput.body.code === "unknown_type");
  const caps = await call(GOOD, "capabilities", []);
  const n = (caps.raw.match(/§2/g) || []).length;
  ck("co_capabilities still EXACTLY four §2 lines (substrate untouched)", n === 4);
  ck("co_capabilities does not advertise push-* as a §2 capability", !caps.raw.includes("push-subscribe") && !caps.raw.includes("notif-deliver"));

  // a subscription is never in the §4 records table (separate namespace).
  await call(GOOD, "push-subscribe", ["https://fcm.googleapis.com/fcm/send/canary", "pp", "aa"]);
  const recs = await env.DB.prepare("SELECT json FROM records WHERE type='push_subscription'").all();
  ck("the §4 records table holds NO push_subscription (separate namespace)", ((recs && recs.results) || []).length === 0);

  expect(FAIL, `anti-drift failed: ${fails.join("; ")}`).toBe(0);
});
