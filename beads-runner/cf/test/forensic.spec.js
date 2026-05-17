// CF.5 (claude-tools-7g0.5) — DIFFERENTIAL conformance test.
//
// Mirrors the CF.5-OWNED clauses of the bash focused test
// lib/test-coordinator-forensic.sh (T4.5 §10.3 Coordinator-side forensic
// transient store) + the §10.1/BC-27-preserved cross-check. Every assertion
// exercises the REAL engine via SELF.fetch (Worker → §9.1 chokepoint →
// singleton single-threaded Coordinator DO → D1) under the SAME
// workerd+miniflare runtime `wrangler dev` uses, NO Cloudflare account. The CF
// engine MUST exhibit the SAME INTERFACE.md v1 §10.1/§10.3 (+ §0.5
// FORENSIC_BLOB_TTL) behaviour as the bash oracle + that test:
//   EXIT-1  stored CIPHERTEXT-ONLY; the server key is NEVER returned to any
//           surface and lives OUTSIDE the ciphertext namespace.
//   EXIT-2  hard-delete at the EARLIER of created_at + FORENSIC_BLOB_TTL
//           (§0.5) OR an explicit dismiss; a deleted blob is IRRECOVERABLE —
//           no soft-delete tombstone is fetchable.
//   EXIT-3  a delete emits a control-plane AUDIT EVENT — ids + timestamps +
//           reason ONLY; CONTENT-FREE (no plaintext, no ciphertext, no key).
//   EXIT-4  fetch requires §9 auth and is ON-DEMAND only; the blob NEVER
//           appears in the §4.5 projection (poll/work_snapshot) or a §4.3
//           Notification body.
//   EXIT-5  anti-drift: SEPARATE transient object, NOT a §4 record type,
//           redaction NOT re-derived here (consumed verbatim from §10.2).
//   BC-27   the §10.1 boundary is PRESERVED VERBATIM — the transient path is
//           a SEPARATE add, NOT a weakening: `forensic` is structurally
//           ABSENT from the §4 store/registry/projection.
//
// THE AD1 PAYOFF (same as CF.6/CF.9): a put's encrypt→blob→meta and a
// fetch's read→TTL-check→lazy-destroy each run as ONE serialized critical
// section on the singleton single-threaded DO (co._serialize), so
// "destroyed (irrecoverable)" holds BY CONSTRUCTION — no hand-rolled latch.
//
// `env` (the D1 binding) is used ONLY to read the at-rest namespace directly
// and to plant a past-expiry meta — EXACTLY mirroring the bash test reading
// the on-disk store directly (ENC/META/AUDLOG) and the notification.spec
// "plant directly" precedent. No non-contract debug surface is added: the
// forensic_* tables are the module's OWN namespace, the at-rest object the
// bash test inspects on disk.

import { env, SELF } from "cloudflare:test";
import { it, expect } from "vitest";

const GOOD = "bearer-runner-secret-xyz";
const MARK = "SECRET-FORENSIC-MARKER-9f3a17b2"; // plaintext canary — MUST stay sealed
// A §10.2-shaped redacted blob, consumed VERBATIM (paths kept; file contents
// already stripped to {byte_length,sha256_prefix} BY THE RUNNER — not here).
const BLOB = JSON.stringify({
  tool_use: [{ name: "Read", input: { file_path: "/etc/app/cfg" } }],
  tool_result: [{ is_error: true }],
  stripped: { redacted: true, byte_length: 4096, sha256_prefix: "deadbeefcafe" },
  last_assistant: MARK,
});

let PASS = 0;
let FAIL = 0;
const fails = [];
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
// success = the bash `rc==0` analogue: a 2xx text/plain stdout (the forensic
// ops are stdout/rc-shaped, like co__forensic_*). A rejection / gone is a
// non-2xx EMPTY body ("empty stdout + nonzero rc"; for fetch: no tombstone).
function good(r) {
  return r.status === 200 && r.body === null;
}

// ════════════════════════════════════════════════════════════════════════════
it("CF.5 §10.3 forensic store is behaviour-identical to lib/coordinator.sh co__forensic_* + test-coordinator-forensic.sh", async () => {
  // ── EXIT-1: stored CIPHERTEXT-ONLY; server key never returned; key outside
  //            the ciphertext namespace ───────────────────────────────────────
  const put1 = await call(GOOD, "forensic-put", ["b1", "claude-tools-aaa", BLOB]);
  ck("forensic-put returns the blob id (not ciphertext, not key)", good(put1) && put1.raw === "b1");

  // First forensic op has lazy-DDL'd the SEPARATE namespace — read it directly
  // (the bash ENC/META on-disk analogue).
  const encRow = await env.DB.prepare(
    "SELECT ciphertext FROM forensic_blobs WHERE blob_id = ?"
  ).bind("b1").first();
  ck("ciphertext object written", !!(encRow && encRow.ciphertext));
  const metaRow = await env.DB.prepare(
    "SELECT * FROM forensic_meta WHERE blob_id = ?"
  ).bind("b1").first();
  ck("content-free meta written", !!metaRow);
  const metaKeys = metaRow ? Object.keys(metaRow).sort().join(",") : "";
  ck(
    "meta is content-free (ids + timestamps only, no blob body)",
    metaKeys === "blob_id,created_at,created_epoch,dossier_ref,expires_epoch,principal"
  );
  ck(
    "meta carries NO plaintext canary",
    metaRow && !JSON.stringify(metaRow).includes(MARK)
  );
  const atRest = encRow ? String(encRow.ciphertext) : "";
  ck("at-rest object does NOT contain the plaintext canary", !atRest.includes(MARK));
  ck("at-rest object differs from the plaintext (encrypted)", atRest !== BLOB && !atRest.includes(MARK));
  ck(
    "at-rest object is an armoured AES-256-GCM ciphertext envelope",
    /"alg":"AES-256-GCM"/.test(atRest) && /"iv":/.test(atRest) && /"ct":/.test(atRest)
  );

  // The server master key: a SERVER SECRET in its OWN table, OUTSIDE the
  // ciphertext namespace, never on any surface.
  const keyRow = await env.DB.prepare("SELECT key_b64 FROM forensic_key WHERE id = 1").first();
  ck("server key row exists", !!(keyRow && keyRow.key_b64));
  const KEYVAL = keyRow ? String(keyRow.key_b64) : "";
  ck("server key value is non-empty", KEYVAL.length > 0);
  ck("server key lives OUTSIDE the ciphertext (forensic_blobs) namespace", !atRest.includes(KEYVAL));
  // No forensic_blobs / forensic_meta / forensic_audit row contains the key.
  const blobsAll = await env.DB.prepare("SELECT blob_id, ciphertext FROM forensic_blobs").all();
  const metaAll = await env.DB.prepare("SELECT * FROM forensic_meta").all();
  const keyLeaks =
    JSON.stringify(blobsAll.results || []).includes(KEYVAL) ||
    JSON.stringify(metaAll.results || []).includes(KEYVAL);
  ck("no ciphertext/meta row contains the server key", !keyLeaks);
  ck("forensic-put output never contains the key", !put1.raw.includes(KEYVAL));

  const fet1 = await call(GOOD, "forensic-fetch", ["b1"]);
  ck("forensic-fetch returns the §10.2 blob (the ONE crossing)", good(fet1) && fet1.raw.includes(MARK));
  ck("forensic-fetch output never contains the key", !fet1.raw.includes(KEYVAL));
  let parsed = null;
  try {
    parsed = JSON.parse(fet1.raw);
  } catch {
    parsed = null;
  }
  ck("fetched blob is the VERBATIM §10.2 shape (path kept)", !!parsed && parsed.tool_use[0].input.file_path === "/etc/app/cfg");
  ck("fetched blob keeps the runner's pre-stripped placeholder", !!parsed && parsed.stripped.sha256_prefix === "deadbeefcafe");

  const capsRes = await SELF.fetch(
    new Request("https://coordinator.local/", {
      method: "GET",
      headers: { authorization: `Bearer ${GOOD}` },
    })
  );
  const caps = await capsRes.text();
  ck("CF.1 capabilities still EXACTLY four §2 lines (untouched)", (caps.match(/§2/g) || []).length === 4);
  ck("no forensic op is advertised as a §2 capability", !/forensic-(put|fetch|dismiss|sweep|audit)/.test(caps));
  ck("capabilities never leak the key", !caps.includes(KEYVAL));

  // ── EXIT-2: hard-delete at EARLIER(created_at+TTL, dismiss); irrecoverable ──
  // (a) explicit-dismiss arm — fetch works first, then dismiss destroys it.
  await call(GOOD, "forensic-put", ["b2", "claude-tools-bbb", BLOB]);
  const preDis = await call(GOOD, "forensic-fetch", ["b2"]);
  ck("pre-dismiss fetch returns the blob", good(preDis) && preDis.raw.includes(MARK));
  const dis = await call(GOOD, "forensic-dismiss", ["b2"]);
  ck("dismiss ⇒ success (rc 0, no stdout)", good(dis) && dis.raw === "");
  const b2blob = await env.DB.prepare("SELECT 1 AS x FROM forensic_blobs WHERE blob_id = ?").bind("b2").first();
  const b2meta = await env.DB.prepare("SELECT 1 AS x FROM forensic_meta WHERE blob_id = ?").bind("b2").first();
  ck("dismiss ⇒ ciphertext object destroyed", !b2blob);
  ck("dismiss ⇒ meta destroyed (NO soft-delete tombstone)", !b2meta);
  const postDis = await call(GOOD, "forensic-fetch", ["b2"]);
  ck("dismissed blob fetch ⇒ nonzero (gone)", !good(postDis));
  ck("dismissed blob fetch ⇒ EMPTY (no tombstone returned)", postDis.raw === "");
  const reDis = await call(GOOD, "forensic-dismiss", ["b2"]);
  ck("re-dismiss of an already-gone blob is idempotent success", good(reDis));

  // (b) TTL lazy-fetch arm — a blob past expires_epoch is treated as deleted
  // and hard-deleted lazily on access (the EARLIER-of bound holds with NO
  // sweep — the §2.2 S-6 poll-fallback analogue). Plant past expiry directly
  // (the notification.spec "plant a record directly" precedent) so this is
  // DETERMINISTIC over a REAL encrypted blob, independent of wall-clock/env.
  await call(GOOD, "forensic-put", ["b3", "claude-tools-ccc", BLOB]);
  await env.DB.prepare("UPDATE forensic_meta SET expires_epoch = 1 WHERE blob_id = ?").bind("b3").run();
  const fet3 = await call(GOOD, "forensic-fetch", ["b3"]);
  ck("TTL-expired blob fetch ⇒ nonzero", !good(fet3));
  ck("TTL-expired blob fetch ⇒ EMPTY (treated as deleted)", fet3.raw === "");
  const b3blob = await env.DB.prepare("SELECT 1 AS x FROM forensic_blobs WHERE blob_id = ?").bind("b3").first();
  const b3meta = await env.DB.prepare("SELECT 1 AS x FROM forensic_meta WHERE blob_id = ?").bind("b3").first();
  ck("TTL-expired fetch HARD-DELETED the ciphertext (no tombstone)", !b3blob && !b3meta);

  // (b') env-knob arm — FORENSIC_BLOB_TTL=0 ⇒ expires at creation ⇒ next
  // access deletes, mirroring the bash `export FORENSIC_BLOB_TTL=0` arm
  // VERBATIM (the §0.5 env override; the same env-mutation mechanism
  // coordinator.spec uses for CO_EXPECTED_TOKEN).
  env.FORENSIC_BLOB_TTL = "0";
  await call(GOOD, "forensic-put", ["b3b", "claude-tools-ccc2", BLOB]);
  delete env.FORENSIC_BLOB_TTL; // restore: default 3600 again
  const fet3b = await call(GOOD, "forensic-fetch", ["b3b"]);
  ck("FORENSIC_BLOB_TTL=0 ⇒ blob expires at creation ⇒ fetch nonzero", !good(fet3b));
  const b3bBlob = await env.DB.prepare("SELECT 1 AS x FROM forensic_blobs WHERE blob_id = ?").bind("b3b").first();
  ck("FORENSIC_BLOB_TTL=0 ⇒ fetch HARD-DELETED the ciphertext", !b3bBlob);

  // (c) proactive sweep arm — mirrors the §2.2 S-6 poll-fallback; explicit
  // [now_epoch] (the bash co__forensic_sweep <principal> [now_epoch] knob).
  await call(GOOD, "forensic-put", ["b4", "claude-tools-ddd", BLOB]);
  const future = Math.floor(Date.now() / 1000) + 999999; // >> created+TTL
  const swept = await call(GOOD, "forensic-sweep", [String(future)]);
  ck("forensic-sweep reports the expired blob id", good(swept) && swept.raw.split("\n").includes("b4"));
  const b4blob = await env.DB.prepare("SELECT 1 AS x FROM forensic_blobs WHERE blob_id = ?").bind("b4").first();
  ck("swept blob ciphertext destroyed", !b4blob);
  // A NOT-yet-expired blob (default 3600 s) survives a sweep (EARLIER-of holds).
  await call(GOOD, "forensic-put", ["b5", "claude-tools-eee", BLOB]);
  await call(GOOD, "forensic-sweep", []); // default now ⇒ b5 not expired
  const b5blob = await env.DB.prepare("SELECT 1 AS x FROM forensic_blobs WHERE blob_id = ?").bind("b5").first();
  ck("un-expired blob survives a sweep (TTL not reached)", !!b5blob);
  const keep = await call(GOOD, "forensic-fetch", ["b5"]);
  ck("un-expired blob still fetchable", good(keep) && keep.raw.includes(MARK));

  // ── EXIT-3: delete emits a CONTENT-FREE control-plane audit event ──────────
  const aud = await call(GOOD, "forensic-audit", []);
  const audLines = aud.raw.split("\n").filter((l) => l.length > 0);
  ck("audit log has ≥1 deletion event", audLines.length >= 1);
  const lastAudit = audLines.length ? JSON.parse(audLines[audLines.length - 1]) : {};
  ck("audit event is forensic_blob_deleted", lastAudit.event === "forensic_blob_deleted");
  ck("audit event carries a deleted_at UTC timestamp", typeof lastAudit.deleted_at === "string" && lastAudit.deleted_at.includes("Z"));
  ck("audit event records a reason (dismiss|ttl)", lastAudit.reason === "dismiss" || lastAudit.reason === "ttl");
  const allowedAuditKeys = ["event", "blob_id", "dossier_ref", "created_at", "deleted_at", "reason", "principal"];
  const extraKeys = audLines
    .flatMap((l) => Object.keys(JSON.parse(l)))
    .filter((k) => !allowedAuditKeys.includes(k));
  ck("audit keys ⊆ {event,blob_id,dossier_ref,created_at,deleted_at,reason,principal}", extraKeys.length === 0);
  ck("audit log contains NO plaintext forensic canary", !aud.raw.includes(MARK));
  ck("audit log contains NO ciphertext (no AES-GCM envelope)", !/AES-256-GCM/.test(aud.raw));
  ck("audit log never leaks the server key", !aud.raw.includes(KEYVAL));
  // append-only: a fresh deletion ADDS a line, never rewrites the log.
  await call(GOOD, "forensic-put", ["bAud", "claude-tools-aud", BLOB]);
  await call(GOOD, "forensic-dismiss", ["bAud"]);
  const aud2 = await call(GOOD, "forensic-audit", []);
  ck(
    "audit log is APPEND-ONLY (a new deletion adds, never rewrites)",
    aud2.raw.split("\n").filter((l) => l.length > 0).length === audLines.length + 1
  );
  const tail1 = await call(GOOD, "forensic-audit", ["1"]);
  ck("forensic-audit [n] tails the last n lines", tail1.raw.split("\n").filter((l) => l.length > 0).length === 1);

  // ── EXIT-4: fetch requires §9 auth, is on-demand; never §4.5/notify ───────
  await call(GOOD, "forensic-put", ["b6", "claude-tools-fff", BLOB]);
  // §9 auth at the ONE chokepoint, BEFORE the DO/any decryption.
  const noTok = await call(null, "forensic-fetch", ["b6"]);
  ck("no-token forensic-fetch ⇒ rejected (nonzero)", noTok.status === 401);
  ck("no-token forensic-fetch ⇒ NO plaintext leaked", !noTok.raw.includes(MARK));
  env.CO_EXPECTED_TOKEN = "expected";
  const badTok = await call("wrong", "forensic-fetch", ["b6"]);
  delete env.CO_EXPECTED_TOKEN;
  ck("invalid-token forensic-fetch ⇒ rejected", badTok.status === 401 && !badTok.raw.includes(MARK));
  const noTokPut = await call(null, "forensic-put", ["zz", "d", BLOB]);
  ck("no-token forensic-put ⇒ rejected (authed channel only)", noTokPut.status === 401);
  // On-demand only: the blob is a SEPARATE namespace, never auto-surfaced.
  await call(GOOD, "set-desired", ["projF", "running", "agent-1"]);
  await call(GOOD, "put", ["lease", "projF", JSON.stringify({ schema_version: 1, task_ref: "projF" })]);
  const poll = await call(GOOD, "poll", ["projF", "projF"]);
  ck("§2.4 poll output never contains the blob canary", !poll.raw.includes(MARK));
  ck("§2.4 poll output never contains the blob id b6", !/\bb6\b/.test(poll.raw));
  await call(GOOD, "put", ["work_snapshot", "snapF", JSON.stringify({ schema_version: 1, cards: [] })]);
  await call(GOOD, "put", ["notification", "ntfF", JSON.stringify({ schema_version: 1, tier: "blocking", dossier_ref: "claude-tools-fff" })]);
  const ws = await call(GOOD, "get", ["work_snapshot", "snapF"]);
  const nt = await call(GOOD, "get", ["notification", "ntfF"]);
  ck("§4.5 work_snapshot body has NO forensic canary", !ws.raw.includes(MARK));
  ck("§4.3 notification body has NO forensic canary", !nt.raw.includes(MARK));
  const recAll = await env.DB.prepare("SELECT json FROM records").all();
  ck(
    "the §4 records table holds NO forensic canary (separate namespace)",
    !JSON.stringify(recAll.results || []).includes(MARK)
  );
  const crossing = await call(GOOD, "forensic-fetch", ["b6"]);
  ck("on-demand fetch still works (the ONLY way the blob crosses)", good(crossing) && crossing.raw.includes(MARK));

  // ── EXIT-5 + BC-27: anti-drift — separate object, NOT §4, no re-redaction ──
  // `forensic` is NOT a §4 record type (ABSENT from the schema.js registry —
  // structurally absent from the §4.5 projection / §4.3 body; §10.1/BC-27
  // preserved verbatim: the transient path is a SEPARATE add, not a weakening).
  const putForensicType = await call(GOOD, "put", ["forensic", "x", JSON.stringify({ schema_version: 1 })]);
  ck("'forensic' is NOT a §4 record type ('put forensic' ⇒ unknown_type)", putForensicType.body?.code === "unknown_type");
  const getForensic = await call(GOOD, "get", ["forensic", "b6"]);
  ck("a forensic blob is NOT reachable via the §4 get path", getForensic.status === 404);
  // Anti-drift, proved BEHAVIOURALLY: the §10.2 blob is consumed VERBATIM —
  // what was put is byte-identical to what is fetched. If CF.5 re-derived
  // redaction (T2/T3's job; raw stream-json never leaves the machine) the
  // round-trip would NOT be byte-identical.
  await call(GOOD, "forensic-put", ["bv", "claude-tools-verbatim", BLOB]);
  const verb = await call(GOOD, "forensic-fetch", ["bv"]);
  ck("§10.2 blob round-trips BYTE-IDENTICAL (stored verbatim, NOT re-derived)", good(verb) && verb.raw === BLOB);
  // store-owner input hygiene (the SAME co__safe_key gate the §4 store uses).
  const evilPut = await call(GOOD, "forensic-put", ["..", "d", BLOB]);
  ck("unsafe forensic blob id ('..') rejected at the door", !good(evilPut));
  const evilFetch = await call(GOOD, "forensic-fetch", ["../../etc/x"]);
  ck("unsafe forensic blob id ('/'+'..') rejected at the door", !good(evilFetch));

  // eslint-disable-next-line no-console
  console.log(`\n══ CF.5 differential (vs lib/coordinator.sh co__forensic_* + test-coordinator-forensic.sh): PASS=${PASS} FAIL=${FAIL} ══`);
  if (FAIL > 0) {
    // eslint-disable-next-line no-console
    console.log("FAILED:\n  - " + fails.join("\n  - "));
  }
  expect(FAIL, `differential clauses failed: ${fails.join("; ")}`).toBe(0);
});
