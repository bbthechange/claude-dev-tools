// claude-tools-n49j — the CROSS-PRODUCER triage-only guard (principle 2).
//
// GAP this closes (audit wzejgmopj critic): UX-DESIGN-V2 §10 + §11 principle 2
// require that notifications only TRIAGE, never carry content. That was verified
// only piecemeal — the N2 transport mechanics (push.spec.js, which never inspects
// the payload SHAPE), the §4.3 validator in isolation, and ONE fired trigger
// (notification.spec.js N1). It was NOT pinned across ALL §10.2 catalog trigger
// sources, so a future trigger could embed dossier content with nothing to catch
// it (e.g. a content-bearing scope → channel, or a wire field that copies the §5
// body).
//
// This spec is the single cross-producer pin: it drives EVERY §10.2 trigger
// through the REAL engine and runs BOTH N2 wire payloads through ONE shared
// assertion (cf/src/notif-triage.js). It fails if ANY producer embeds content.
// Safety-net (P3), not a feature.
//
// THE CANARY METHOD: each seeded dossier carries a unique CONTENT marker in its
// §5 body (full_detail / sections) but NOT in its §5.1 TL;DR. Any producer that
// leaks the §5 body — into a new key, or by copying the body into an allowed
// field (tldr ← body, scope ← body → channel) — drags the canary into the
// payload, where the shared guard catches it. The §5.1 TL;DR itself is triage
// (a short line), so it is allowed; only the BODY is content.

import { env, SELF } from "cloudflare:test";
import { it, expect } from "vitest";
import {
  notifTriggers,
  notifTriggerTiers,
  notifTriggerChannel,
  groupDigests,
  digestCopy,
  CLOSED_43,
} from "../src/notification.js";
import { blockingWirePayload, digestWirePayload, dossierTldr } from "../src/push.js";
import { triageViolations, isTriageOnly, TRIAGE_KEYS } from "../src/notif-triage.js";

const GOOD = "bearer-runner-secret-xyz";

// A unique §5-body content marker. Present in every seeded dossier's BODY, never
// in its TL;DR. If it ever surfaces in a notification payload, content leaked.
const CANARY = "CONTENT-LEAK-CANARY::§5-body::do-not-page-this::7f3a9c";

let PASS = 0;
let FAIL = 0;
let fails = [];
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
function good(r) {
  return !!(r && r.body && r.body.ok === true);
}

// Seed a dossier directly in D1 (like push.spec.js) — the fire/deliver paths only
// READ tier + dossier_ref + body.tldr, so this avoids the full §4.1 dossier
// schema. The §5 body carries the CANARY; the §5.1 TL;DR does NOT.
async function seedDossier(did, tier, tldr) {
  await env.DB.prepare("INSERT OR REPLACE INTO records (type, id, json) VALUES ('dossier', ?, ?)")
    .bind(
      did,
      JSON.stringify({
        id: did,
        schema_version: 1,
        tier,
        body: {
          tldr, // §5.1 TL;DR — triage, canary-free
          full_detail: CANARY, // §5 body — content, the canary lives here
          sections: [{ heading: "Detail", prose: CANARY }],
        },
      })
    )
    .run();
}
// Read the §4.3 notification record the fire produced, straight from the store.
async function notifRec(did) {
  const row = await env.DB.prepare("SELECT json FROM records WHERE type = 'notification' AND id = ?")
    .bind(`notif.${did}`)
    .first();
  if (!row) return null;
  try {
    return JSON.parse(row.json);
  } catch {
    return null;
  }
}

// ════════════════════════════════════════════════════════════════════════════
// (1) EVERY §10.2 trigger emits a triage-only §4.3 record — the cross-trigger pin.
// ════════════════════════════════════════════════════════════════════════════
it("claude-tools-n49j — every §10.2 trigger emits a triage-only §4.3 record (no content)", async () => {
  reset();

  // The catalog is the CLOSED set of 10 (so this loop genuinely covers ALL
  // trigger sources; a new trigger added later is automatically swept in).
  const triggers = notifTriggers();
  ck("the §10.2 catalog is the closed set of 10 triggers", triggers.length === 10);
  const opTriggers = await call(GOOD, "notif-triggers", []);
  ck(
    "notif-triggers op agrees with the in-process catalog (no drift)",
    opTriggers.body && Array.isArray(opTriggers.body.triggers) && opTriggers.body.triggers.length === triggers.length
  );

  for (const tr of triggers) {
    const tiers = notifTriggerTiers(tr); // every tier this trigger may fire at
    ck(`${tr}: catalog binds at least one tier`, Array.isArray(tiers) && tiers.length > 0);
    for (const tier of tiers) {
      const did = `n49j_rec_${tr}_${tier.replace(/-/g, "_")}`;
      await seedDossier(did, tier, `${tr} needs triage`);
      // a NORMAL short opaque scope (the channel suffix for a batchable trigger).
      const fr = await call(GOOD, "notif-fire", [tr, did, "scopeX"]);
      ck(`fire(${tr}@${tier}) succeeds via the real engine`, good(fr));
      const rec = await notifRec(did);
      ck(`fire(${tr}@${tier}) wrote a §4.3 record`, rec !== null);
      const v = triageViolations(rec, { canary: CANARY });
      ck(`${tr}@${tier}: §4.3 record is TRIAGE-ONLY (no content, no §5 canary)`, rec !== null && v.length === 0);
      if (rec !== null && v.length > 0) {
        // eslint-disable-next-line no-console
        console.log(`     ↳ ${tr}@${tier} violations: ${v.join(" | ")}`);
      }
    }
  }

  expect(FAIL, `§4.3 record cross-trigger triage check failed: ${fails.join("; ")}`).toBe(0);
});

// ════════════════════════════════════════════════════════════════════════════
// (2) The N2 WIRE payloads (the bytes bound for the phone) are triage-only.
//     deliverBlocking/deliverDigest build via these exact builders + reader
//     (push.js), so checking the builders here is faithful to what is sent.
// ════════════════════════════════════════════════════════════════════════════
it("claude-tools-n49j — the N2 wire payloads (blocking + digest) are triage-only", async () => {
  reset();

  // ── BLOCKING wire payload ──────────────────────────────────────────────────
  // Exercise the REAL §5.1 TL;DR reader (dossierTldr) against a canary dossier:
  // it must return ONLY the TL;DR, never the §5 body.
  await seedDossier("n49j_wire_block", "blocking", "Pick the deploy window.");
  const tldr = await dossierTldr({ db: env.DB }, "n49j_wire_block");
  ck("dossierTldr returns the §5.1 TL;DR, NOT the §5 body", tldr === "Pick the deploy window.");
  ck("dossierTldr does NOT leak the §5 body canary", typeof tldr === "string" && !tldr.includes(CANARY));
  const wb = blockingWirePayload("n49j_wire_block", tldr || "A decision needs you.");
  ck("blocking wire payload is TRIAGE-ONLY (closed key-set, no canary)", isTriageOnly(wb, { canary: CANARY }));
  ck(
    "blocking wire payload carries only {tldr,dossier_ref,tier,url}",
    Object.keys(wb).every((k) => ["tldr", "dossier_ref", "tier", "url"].includes(k))
  );
  ck("blocking wire payload deep-links to the dossier", wb.url === "/inbox#/d/n49j_wire_block");

  // ── DIGEST wire payload ────────────────────────────────────────────────────
  // Fire two batchable timed-fyi triggers on ONE channel, roll them up with the
  // REAL K3 engine, and build the digest wire payload the sweep would send.
  await seedDossier("n49j_wire_d1", "timed-fyi", "BE↔FE sync 1");
  await seedDossier("n49j_wire_d2", "timed-fyi", "BE↔FE sync 2");
  ck("fire(cross_ws_exchange) d1 succeeds", good(await call(GOOD, "notif-fire", ["cross_ws_exchange", "n49j_wire_d1", "BE"])));
  ck("fire(cross_ws_exchange) d2 succeeds", good(await call(GOOD, "notif-fire", ["cross_ws_exchange", "n49j_wire_d2", "BE"])));
  // Roll up an EXPLICIT two-record array, deliberately NOT the store-wide
  // notif-digest op: D1 isolation is per-FILE (vitest.config.js), so test (1)'s
  // accumulated channel-stamped records share this store. Feeding the two we
  // just fired keeps this assertion about the wire-payload SHAPE, not the rollup
  // count — do not switch this to a whole-store sweep.
  const { digests } = groupDigests([await notifRec("n49j_wire_d1"), await notifRec("n49j_wire_d2")]);
  ck("the two syncs roll up to ONE channel group (count=2)", digests.length === 1 && digests[0].count === 2);
  const wd = digestWirePayload(digests[0]);
  ck("digest wire payload is TRIAGE-ONLY (closed key-set, no canary)", isTriageOnly(wd, { canary: CANARY }));
  ck(
    "digest wire payload carries only {tldr,dossier_ref,tier,channel,count,url}",
    Object.keys(wd).every((k) => ["tldr", "dossier_ref", "tier", "channel", "count", "url"].includes(k))
  );
  ck("digest wire payload tldr is the K3 summary line (channel+count, not content)", wd.tldr === digestCopy(digests[0]));
  ck("digest wire payload carries no per-dossier body — only the rollup", wd.dossier_ref === null);

  expect(FAIL, `wire-payload triage check failed: ${fails.join("; ")}`).toBe(0);
});

// ════════════════════════════════════════════════════════════════════════════
// (3) The shared guard HAS TEETH — it catches the exact leak vectors the critic
//     feared, and stays in sync with the §4.3 record set.
// ════════════════════════════════════════════════════════════════════════════
it("claude-tools-n49j — the triage guard catches content leaks (and is not vacuous)", async () => {
  reset();

  // The §4.3 record set must NOT have silently widened to admit a content field:
  // every CLOSED_43 field is in the independent triage vocabulary. If a future
  // edit added `body`/`content` to CLOSED_43, validateNotification would accept
  // it — but this cross-check (independent of CLOSED_43) red-flags it.
  const drift = CLOSED_43.filter((k) => !TRIAGE_KEYS.has(k));
  ck("every §4.3 record field is in the triage vocabulary (§4.3 set has not widened to content)", drift.length === 0);

  // teeth #1: a content KEY (body/content/payload/options/…) is flagged.
  for (const leakKey of ["body", "content", "payload", "options", "mermaid", "sections", "full_detail"]) {
    const leaky = { tldr: "ok", dossier_ref: "d", tier: "blocking", url: "/inbox", [leakKey]: "the §5 body" };
    ck(`a payload with a '${leakKey}' key is FLAGGED (content leak)`, triageViolations(leaky).length > 0);
  }

  // teeth #2: content copied into an ALLOWED field (tldr ← §5 body) is caught by
  // the canary scan even though the key-set is clean.
  const tldrLeak = { tldr: `summary ${CANARY}`, dossier_ref: "d", tier: "blocking", url: "/inbox" };
  ck("a clean key-set but body-in-tldr is FLAGGED by the canary scan", triageViolations(tldrLeak, { canary: CANARY }).length > 0);

  // teeth #3 — THE CRITIC'S VECTOR: a trigger that embeds §5 content in its
  // scope → channel. Fire a batchable trigger with the canary as the scope; the
  // resulting §4.3 record's channel carries the content, and the shared guard
  // catches it. (This is what "a future trigger could embed content with nothing
  // to catch it" looks like — and now something catches it.)
  await seedDossier("n49j_scopeleak", "timed-fyi", "a sync");
  ck(
    "fire with a content-bearing scope succeeds (the channel is opaque)",
    good(await call(GOOD, "notif-fire", ["cross_ws_exchange", "n49j_scopeleak", CANARY]))
  );
  const leakedRec = await notifRec("n49j_scopeleak");
  ck("the content-bearing scope did land in the channel tag", leakedRec && typeof leakedRec.channel === "string" && leakedRec.channel.includes(CANARY));
  ck(
    "the shared guard CATCHES a trigger that embeds content in its scope→channel (the critic's vector)",
    leakedRec !== null && triageViolations(leakedRec, { canary: CANARY }).length > 0
  );

  // sanity: a genuinely triage-only record/payload passes both checks.
  const clean = { id: "notif.d", schema_version: 1, principal: "brian", dossier_ref: "d", tier: "blocking", created_at: "t", dispatched: false, dispatched_at: null, channel: null };
  ck("a genuine §4.3 record passes the guard (no false positive)", isTriageOnly(clean, { canary: CANARY }));

  // every trigger's channel for a NORMAL scope is a short opaque tag (prefix+scope
  // or ""), never a multi-line/body-shaped string — a cheap structural smell test.
  for (const tr of notifTriggers()) {
    const ch = notifTriggerChannel(tr, "scopeX");
    ck(`${tr}: channel for a normal scope is a single-line opaque tag`, typeof ch === "string" && !ch.includes("\n"));
  }

  expect(FAIL, `guard-teeth check failed: ${fails.join("; ")}`).toBe(0);
});
