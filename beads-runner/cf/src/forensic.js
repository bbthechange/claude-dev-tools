// CF.5 (claude-tools-7g0.5) — the §10.3 Coordinator-side forensic transient
// store, realized on the CF.1 substrate. Flow G tier-3's ONE controlled
// crossing of the sync boundary.
//
// This is the Cloudflare realization of the bash:
//   lib/coordinator.sh  co__forensic_* (T4.5, claude-tools-guq; lines
//                        ~487-720: ensure_key / encrypt / decrypt / audit /
//                        destroy / put / fetch / dismiss / sweep / audit_tail)
// and is differential-bound to lib/test-coordinator-forensic.sh +
// conformance/assertions/bc-27-logdir-security.sh. The CF engine MUST exhibit
// the SAME INTERFACE.md v1 §10.1/§10.3 (+ §0.5 FORENSIC_BLOB_TTL) behaviour as
// the bash impl + those tests — not a re-spec.
//
// CRITICAL BOUNDARY (the substrate-handoff discipline, kept verbatim): the
// forensic store is a SEPARATE TRANSIENT ENCRYPTED namespace. It is NOT a §4
// record. It is deliberately NOT routed through CF.1's `_writeRecord` / the §4
// `records` table / `validateRecord` / `schemaVersion` — `forensic` is ABSENT
// from the schema.js §4 registry and MUST stay absent (so `get forensic <id>`
// is `unknown_type`, structurally proving "never a §4 record / never in the
// §4.5 projection / never in a §4.3 Notification body"). Its own surface:
//   • `forensic_blobs`  — CIPHERTEXT ONLY at rest (AES-256-GCM armoured).
//   • `forensic_meta`   — content-free ids+timestamps (TTL math + audit).
//   • `forensic_audit`  — append-only content-free deletion audit log.
//   • `forensic_key`    — the SERVER master key, a SERVER SECRET in its OWN
//                         table (OUTSIDE the ciphertext namespace, so "the
//                         storage layer holds ciphertext only" is true of the
//                         blob namespace), NEVER returned by ANY op surface.
// In the Appendix-A hosted realization the master key is a Worker/KMS secret,
// never the encrypted object store; here (LOCAL emulation, NO account) it is a
// single-row D1 table generated once — a documented realisation choice, NOT an
// INTERFACE divergence (no §11 gap), the §10.3 analogue of CF.6's documented
// `work_plane_ops` choice. AES-256-GCM (Web Crypto) realizes the §10.3
// "encrypted at rest with a server-managed key (AES-256)" requirement; openssl
// AES-256-CBC/PBKDF2 is the bash impl's at-rest format, not a §10.3 normative
// byte shape — the contract is the §-behaviour, asserted here.
//
// THE AD1 PAYOFF (same as CF.6/CF.9): the bash impl performs put = encrypt →
// write blob → write meta as a sequence; here every store-touching forensic op
// runs as ONE serialized critical section on the singleton single-threaded
// Coordinator DO (`co._serialize`, coordinator.js — the SAME tail CF.6/CF.9
// chain on), so a put's blob+meta+key writes never interleave with a racing
// dismiss/sweep and "destroyed (irrecoverable), not destroyed-exactly-once"
// holds BY CONSTRUCTION. No hand-rolled latch (the substrate-handoff rule).
//
// MUST-NOT-TOUCH (bound by the CF.5 issue): substrate store/timer (CF.1),
// lease (CF.2), reconcile/projection (CF.3 — forensic is NEVER in the §4.5
// projection), capacity (CF.4), Dossier (CF.6). The runner-side §10.2
// redaction-BEFORE-transit stays bash (Local Agent tier — raw stream-json
// never leaves the machine; not a CF surface). This tier RECEIVES the
// already-§10.2-redacted blob and stores it VERBATIM — it MUST NOT re-derive
// redaction (no stream-json parsing); the round-trip is byte-identical.
//
// §10.1 BC-27 PRESERVED VERBATIM: BC-27 is the runner-side on-disk
// `.beads/runner-logs/` `*`+`!.gitignore` boundary (run-beads-tasks.sh,
// asserted by conformance/assertions/bc-27-logdir-security.sh). This module is
// a SEPARATE transient encrypted D1 namespace inside the hosted Coordinator —
// it does NOT touch and does NOT weaken that boundary (the transient path is
// an ADD, never a relaxation). CF.5 edits no bash; BC-27 stays GREEN by
// construction (nothing on its path changes).
//
// ANTI-DRIFT: binds FROZEN INTERFACE.md v1 §10.1/§10.3 + §0.5
// FORENSIC_BLOB_TTL. Oracle = coordinator.sh co__forensic_* +
// test-coordinator-forensic.sh + bc-27-logdir-security.sh. An INTERFACE gap ⇒
// reopen claude-tools-65z, bump+re-freeze — NEVER diverge, NEVER edit
// INTERFACE.md. (No gap: §10.3 is a complete, self-consistent transient-store
// contract; `forensic` is deliberately NOT a §4 type.)

// safeKey is CF.1's ONE store-owner input-hygiene predicate (schema.js). Reuse
// it (never a duplicated predicate that could drift) — the bash oracle gates
// every forensic blob id through the SAME co__safe_key the §4 store uses.
import { safeKey } from "./schema.js";

// The CF.5 op surface. Kept OUT of CF.1's CAPABILITIES (anti-drift: the
// differential asserts the forensic ops are NOT §2 capability lines, exactly
// as test-coordinator-forensic.sh greps co_capabilities for four §2 lines).
export const FORENSIC_OPS = new Set([
  "forensic-put", // co__forensic_put — store the §10.2 blob ENCRYPTED
  "forensic-fetch", // co__forensic_fetch — the ONE authed on-demand crossing
  "forensic-dismiss", // co__forensic_dismiss — explicit "done" ⇒ hard-delete
  "forensic-sweep", // co__forensic_sweep — TTL poll-fallback hard-delete
  "forensic-audit", // co__forensic_audit_tail — content-free deletion log
]);

// ── §0.5 FORENSIC_BLOB_TTL — env-overridable, default 3600 ──────────────────
// 1:1 with bash `co__FORENSIC_BLOB_TTL() { echo "${FORENSIC_BLOB_TTL:-3600}"; }`
// (`:-` keeps a present non-empty value, so an explicit "0" is honoured — the
// immediate-expiry arm test-coordinator-forensic.sh exercises). Single
// normative definition is INTERFACE.md §0.5; this is an env-overridable lookup
// whose literal default EQUALS the frozen table value, never a competing
// normative value.
function forensicBlobTtl(env) {
  const v = env && env.FORENSIC_BLOB_TTL;
  if (v === undefined || v === null || String(v).length === 0) return 3600;
  const n = Number(v);
  return Number.isFinite(n) && n >= 0 ? Math.floor(n) : 3600;
}

// ── lazy + idempotent DDL — the SEPARATE transient namespace ─────────────────
// Mirrors CF.1's `ensureSchema` discipline (CREATE TABLE IF NOT EXISTS, lazy,
// per-instance memoised) so CF.5 is locally-runnable with NO account and NO
// manual migrate step. The canonical migration ships in
// migrations/0003_forensic.sql for the a53 deploy path. These four tables are
// a SEPARATE namespace from `records`/`timers`/`work_plane_ops` — NOT a §4
// record (the §10.3 "not a §4 record" precedent CF.1/CF.6 already document).
function ensureForensicSchema(co) {
  if (!co._forensicSchemaReady) {
    co._forensicSchemaReady = (async () => {
      // CIPHERTEXT ONLY — never plaintext, never the key.
      await co.db
        .prepare(
          "CREATE TABLE IF NOT EXISTS forensic_blobs (blob_id TEXT PRIMARY KEY, ciphertext TEXT NOT NULL)"
        )
        .run();
      // content-free meta: ids + timestamps only (TTL math + audit source).
      await co.db
        .prepare(
          "CREATE TABLE IF NOT EXISTS forensic_meta (blob_id TEXT PRIMARY KEY, dossier_ref TEXT, created_at TEXT, created_epoch INTEGER, expires_epoch INTEGER, principal TEXT)"
        )
        .run();
      // append-only, content-free control-plane deletion audit.
      await co.db
        .prepare(
          "CREATE TABLE IF NOT EXISTS forensic_audit (id INTEGER PRIMARY KEY AUTOINCREMENT, line TEXT NOT NULL)"
        )
        .run();
      // the SERVER master key — a SERVER SECRET in its OWN table, OUTSIDE the
      // ciphertext namespace, NEVER returned by any op (CHECK(id=1): one key).
      await co.db
        .prepare(
          "CREATE TABLE IF NOT EXISTS forensic_key (id INTEGER PRIMARY KEY CHECK (id = 1), key_b64 TEXT NOT NULL)"
        )
        .run();
    })();
  }
  return co._forensicSchemaReady;
}

// Encryption is a HARD security boundary: if no AES-256 primitive is available
// the store FAILS CLOSED (put writes NOTHING, returns nonzero) — it MUST NEVER
// silently degrade to plaintext at rest (contrast BC-34's deliberate
// fail-OPEN usage gate: a different domain, a different posture). Web Crypto is
// always present in workerd; the check is kept for behaviour-identity with the
// bash `co__forensic_have_crypto` fail-closed structure.
function forensicHaveCrypto() {
  return (
    typeof crypto !== "undefined" &&
    !!crypto.subtle &&
    typeof crypto.subtle.encrypt === "function" &&
    typeof crypto.getRandomValues === "function"
  );
}

function b64encode(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s);
}
function b64decode(str) {
  const bin = atob(str);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// Generate the 256-bit server master key ONCE, in its own table OUTSIDE the
// ciphertext namespace; NEVER printed, NEVER returned by any op. INSERT OR
// IGNORE keeps the first key under a create race (the single-threaded DO makes
// this race impossible anyway — defence in depth, mirroring the bash umask).
async function forensicEnsureKey(co) {
  const row = await co.db
    .prepare("SELECT key_b64 FROM forensic_key WHERE id = 1")
    .first();
  if (row && row.key_b64) return row.key_b64;
  if (!forensicHaveCrypto()) return null;
  const raw = new Uint8Array(32);
  crypto.getRandomValues(raw);
  await co.db
    .prepare("INSERT OR IGNORE INTO forensic_key (id, key_b64) VALUES (1, ?)")
    .bind(b64encode(raw))
    .run();
  const r2 = await co.db
    .prepare("SELECT key_b64 FROM forensic_key WHERE id = 1")
    .first();
  return r2 && r2.key_b64 ? r2.key_b64 : null;
}

async function importAesKey(keyB64) {
  return crypto.subtle.importKey(
    "raw",
    b64decode(keyB64),
    { name: "AES-GCM" },
    false,
    ["encrypt", "decrypt"]
  );
}

// AES-256-GCM under the server key, fresh random 96-bit IV per blob. The
// at-rest object is an armoured JSON envelope {v,alg,iv,ct} (base64) — it is
// unambiguously CIPHERTEXT (carries the GCM auth tag; bears NO plaintext). The
// key is read from the server-secret table, NEVER an argument on any surface.
async function forensicEncrypt(keyB64, plaintext) {
  const key = await importAesKey(keyB64);
  const iv = new Uint8Array(12);
  crypto.getRandomValues(iv);
  const ct = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: "AES-GCM", iv },
      key,
      new TextEncoder().encode(plaintext)
    )
  );
  return JSON.stringify({
    v: 1,
    alg: "AES-256-GCM",
    iv: b64encode(iv),
    ct: b64encode(ct),
  });
}
async function forensicDecrypt(keyB64, armored) {
  let box;
  try {
    box = JSON.parse(armored);
  } catch {
    return null;
  }
  if (!box || !box.iv || !box.ct) return null;
  try {
    const key = await importAesKey(keyB64);
    const pt = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: b64decode(box.iv) },
      key,
      b64decode(box.ct)
    );
    return new TextDecoder().decode(pt);
  } catch {
    return null;
  }
}

// A content-free control-plane audit line: ids + timestamps + reason + the
// §9.1 resolved principal ONLY. NO forensic content, NO ciphertext, NO key.
// Append-only (§10.3) — INSERT, never UPDATE/DELETE.
async function forensicAudit(co, event, blobId, dossierRef, createdAt, reason, principal) {
  const now = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
  const line = JSON.stringify({
    event,
    blob_id: blobId,
    dossier_ref: dossierRef,
    created_at: createdAt,
    deleted_at: now,
    reason,
    principal,
  });
  await co.db
    .prepare("INSERT INTO forensic_audit (line) VALUES (?)")
    .bind(line)
    .run();
}

// IRRECOVERABLE destruction (§10.3): DELETE the ciphertext AND its meta — NO
// tombstone / soft-delete marker left behind — then emit the content-free
// audit event from the meta's ids/timestamps (read BEFORE delete). Idempotent:
// already-gone is success with NO audit (a TTL sweep and a dismiss may race;
// the contract is "destroyed", not "destroyed exactly once by me" — 1:1 with
// the bash `[[ -f ep || -f mp ]] || return 0`).
async function forensicDestroy(co, blobId, reason, principal) {
  if (!safeKey(blobId)) return false;
  const meta = await co.db
    .prepare("SELECT dossier_ref, created_at FROM forensic_meta WHERE blob_id = ?")
    .bind(blobId)
    .first();
  const blob = await co.db
    .prepare("SELECT 1 AS x FROM forensic_blobs WHERE blob_id = ?")
    .bind(blobId)
    .first();
  if (!meta && !blob) return true; // already irrecoverable ⇒ ok (no audit)
  const dref = meta && meta.dossier_ref != null ? meta.dossier_ref : "";
  const ca = meta && meta.created_at != null ? meta.created_at : "";
  await co.db.prepare("DELETE FROM forensic_blobs WHERE blob_id = ?").bind(blobId).run();
  await co.db.prepare("DELETE FROM forensic_meta WHERE blob_id = ?").bind(blobId).run();
  await forensicAudit(co, "forensic_blob_deleted", blobId, dref, ca, reason, principal);
  const g1 = await co.db
    .prepare("SELECT 1 AS x FROM forensic_blobs WHERE blob_id = ?")
    .bind(blobId)
    .first();
  const g2 = await co.db
    .prepare("SELECT 1 AS x FROM forensic_meta WHERE blob_id = ?")
    .bind(blobId)
    .first();
  return !g1 && !g2; // no tombstone — both rows gone
}

// co__forensic_put — store the ALREADY-§10.2-redacted blob ENCRYPTED.
// Ciphertext-only at rest; a content-free meta (ids + timestamps) sits
// alongside for TTL math + audit. NO redaction is performed or re-derived here
// (anti-drift — verbatim consume of the §10.2 shape; the bytes are opaque to
// this tier). Precedence is IDENTICAL to co__forensic_put:
//   1. <id> & <redacted> present;  2. safe id;  3. crypto+key (else
//   fail-closed, nothing written);  4. encrypt (else fail-closed);  5. write.
async function forensicPut(co, principal, blobId, dossierRef, redacted) {
  if (!blobId || !redacted) return { rc: 2 };
  if (!safeKey(blobId)) return { rc: 2 };
  const keyB64 = await forensicEnsureKey(co);
  if (!forensicHaveCrypto() || !keyB64) return { rc: 5 }; // fail-closed: no plaintext at rest
  let armored;
  try {
    armored = await forensicEncrypt(keyB64, redacted);
  } catch {
    return { rc: 5 };
  }
  if (!armored || armored.length === 0) return { rc: 5 };
  const now = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
  const epoch = Math.floor(Date.now() / 1000);
  const exp = epoch + forensicBlobTtl(co.env);
  // The caller wraps this in co._serialize ⇒ blob THEN meta is ONE critical
  // section on the one actor (the AD1 payoff; no hand-rolled latch).
  await co.db
    .prepare("INSERT OR REPLACE INTO forensic_blobs (blob_id, ciphertext) VALUES (?, ?)")
    .bind(blobId, armored)
    .run();
  await co.db
    .prepare(
      "INSERT OR REPLACE INTO forensic_meta (blob_id, dossier_ref, created_at, created_epoch, expires_epoch, principal) VALUES (?, ?, ?, ?, ?, ?)"
    )
    .bind(blobId, dossierRef || "", now, epoch, exp, principal)
    .run();
  return { rc: 0, id: blobId };
}

// co__forensic_fetch — §9 explicit authed on-demand pull, the ONE controlled
// crossing. Returns the decrypted §10.2 blob (NEVER the key). A blob that is
// gone OR past its TTL returns NOTHING and nonzero: a destroyed blob is
// irrecoverable and there is no fetchable tombstone. Reaching the TTL on a
// fetch hard-deletes LAZILY (the EARLIER-of bound holds with no sweep —
// analogous to the §2.2 S-6 poll-fallback).
async function forensicFetch(co, principal, blobId) {
  if (!blobId) return { rc: 2 };
  if (!safeKey(blobId)) return { rc: 2 };
  const blob = await co.db
    .prepare("SELECT ciphertext FROM forensic_blobs WHERE blob_id = ?")
    .bind(blobId)
    .first();
  const meta = await co.db
    .prepare("SELECT expires_epoch FROM forensic_meta WHERE blob_id = ?")
    .bind(blobId)
    .first();
  if (!blob || !meta) return { rc: 1 }; // gone ⇒ irrecoverable, no tombstone
  const exp = meta.expires_epoch != null ? Number(meta.expires_epoch) : 0;
  const now = Math.floor(Date.now() / 1000);
  if (now >= exp) {
    await forensicDestroy(co, blobId, "ttl", principal);
    return { rc: 1 }; // TTL reached ⇒ treated as deleted (lazy hard-delete)
  }
  const keyB64 = await forensicEnsureKey(co);
  if (!keyB64) return { rc: 1 };
  const plain = await forensicDecrypt(keyB64, blob.ciphertext);
  if (plain === null) return { rc: 1 };
  // expires_epoch is content-free meta (§10.3 audit shape: ids+timestamps
  // only). Surfaced for the Flow-G UI's "self-destructs in X" countdown so
  // the human sees the TTL bound without a second probe. NOT in the
  // plaintext body (the §10.2 contract — stdout stays byte-identical).
  return { rc: 0, plaintext: plain, expires_epoch: exp };
}

// co__forensic_dismiss — the explicit user "dismiss / done with forensic"
// action ⇒ hard-delete now (the other arm of the EARLIER-of). Idempotent:
// dismissing an absent / already-gone blob is success.
async function forensicDismiss(co, principal, blobId) {
  if (!blobId) return { rc: 2 };
  if (!safeKey(blobId)) return { rc: 2 };
  const ok = await forensicDestroy(co, blobId, "dismiss", principal);
  return { rc: ok ? 0 : 5 };
}

// co__forensic_sweep — TTL poll-fallback (mirrors co__timer_due / the §2.2 S-6
// backstop): hard-delete every blob whose expires_epoch ≤ now and report its
// id. Deterministic, no daemon — a missed sweep never strands a blob past TTL
// (next sweep OR next fetch destroys it). `[now_epoch]` overridable, exactly
// like the bash `co__forensic_sweep <principal> [now_epoch]`.
async function forensicSweep(co, principal, nowArg) {
  // Literal bash precedence (co__forensic_sweep): `now="${2:-}"; [[ -n "$now"
  // ]] || now=$(date +%s)` — a NON-EMPTY arg is used as-is; a non-numeric arg
  // coerces to 0 in bash's `[[ "$now" -ge "$exp" ]]` arithmetic context (⇒
  // nothing expired, since exp is a positive epoch). ONLY an absent/empty arg
  // falls back to wall-clock. (Strict oracle conformance, not a wall-clock
  // fallback on garbage — that would diverge from the bash impl.)
  let now;
  if (nowArg != null && String(nowArg).length > 0) {
    const n = Number(nowArg);
    now = Number.isFinite(n) ? Math.floor(n) : 0;
  } else {
    now = Math.floor(Date.now() / 1000);
  }
  const { results } = await co.db
    .prepare("SELECT blob_id, expires_epoch FROM forensic_meta")
    .all();
  const swept = [];
  for (const r of results || []) {
    const bid = r.blob_id;
    if (!bid) continue;
    const exp = r.expires_epoch != null ? Number(r.expires_epoch) : 0;
    if (now >= exp) {
      const ok = await forensicDestroy(co, bid, "ttl", principal);
      if (ok) swept.push(bid);
    }
  }
  return { rc: 0, swept };
}

// co__forensic_audit_tail — the content-free deletion audit (observability;
// ids + timestamps + reason, by construction NO forensic content / ciphertext
// / key). With a numeric [n] ⇒ the last n lines (tail -n n); else the whole
// log (cat). Newline-terminated lines, matching the bash stdout the
// differential greps.
async function forensicAuditTail(co, nArg) {
  const { results } = await co.db
    .prepare("SELECT line FROM forensic_audit ORDER BY id ASC")
    .all();
  let lines = (results || []).map((r) => r.line);
  if (nArg != null && /^[0-9]+$/.test(String(nArg))) {
    const n = Number(nArg);
    lines = lines.slice(Math.max(0, lines.length - n));
  }
  return lines.join("\n") + (lines.length ? "\n" : "");
}

// ════════════════════════════════════════════════════════════════════════════
// FORENSIC_OPS dispatch. Every store-touching op runs INSIDE co._serialize so
// the singleton single-threaded DO processes one §10.3 critical section at a
// time (AD1: encrypt→blob→meta, or read→TTL-check→lazy-destroy, never
// interleaved with a racing dismiss/sweep). forensic-audit is a read-only tail
// ⇒ no serialize (mirrors notification.js's pure-op short-circuit). The §9.1
// chokepoint (the Worker, CF.1) has ALREADY authenticated + threaded the
// resolved `principal` — there is NO second auth path here (C4); a
// no-token/invalid-token forensic-* is rejected 401 at the Worker BEFORE this
// module (and before any decryption), so no plaintext can leak.
//
// Response convention (the bash rc+stdout ⇄ HTTP analogue, 1:1 with how the
// CF.1 substrate maps opTimer/opGet): a data op returns `text(stdout)` 200; a
// rejection/gone returns an EMPTY-body non-2xx ("empty stdout + nonzero rc",
// and for fetch specifically: NO tombstone returned). This keeps the
// differential assertions byte-faithful to test-coordinator-forensic.sh.
// ════════════════════════════════════════════════════════════════════════════
function textRes(s, status = 200) {
  return new Response(s, { status, headers: { "content-type": "text/plain" } });
}
function jsonRes(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export async function handleForensicOp(co, op, args, principal) {
  const a = args || [];
  try {
    await ensureForensicSchema(co);

    if (op === "forensic-put") {
      const r = await co._serialize(() =>
        forensicPut(co, principal, a[0], a[1], a[2])
      );
      if (r.rc === 0) return textRes(r.id); // stdout = blob id (not ct, not key)
      return textRes("", r.rc === 2 ? 422 : 500); // empty + nonzero (nothing written)
    }
    if (op === "forensic-fetch") {
      const r = await co._serialize(() => forensicFetch(co, principal, a[0]));
      if (r.rc === 0) {
        // The ONE crossing. Body stays the §10.2 plaintext blob (the contract
        // — test-coordinator-forensic.sh + forensic.spec.js read this verbatim).
        // The expires_epoch is surfaced as a CONTENT-FREE header (ids+timestamps
        // only, §10.3 audit shape) so the Inbox can render the "self-destructs
        // in X" countdown without a second probe. The header carries no
        // plaintext / ciphertext / key.
        const h = { "content-type": "text/plain" };
        if (r.expires_epoch != null) {
          h["x-forensic-expires-epoch"] = String(r.expires_epoch);
        }
        return new Response(r.plaintext, { status: 200, headers: h });
      }
      if (r.rc === 2) return textRes("", 422); // unsafe/missing — empty + nonzero
      return textRes("", 404); // gone/expired/decrypt-fail — EMPTY, no tombstone
    }
    if (op === "forensic-dismiss") {
      const r = await co._serialize(() => forensicDismiss(co, principal, a[0]));
      if (r.rc === 0) return textRes("", 200); // rc 0, no stdout (incl. idempotent)
      return textRes("", r.rc === 2 ? 422 : 500);
    }
    if (op === "forensic-sweep") {
      const r = await co._serialize(() => forensicSweep(co, principal, a[0]));
      return textRes(r.swept.join("\n") + (r.swept.length ? "\n" : ""));
    }
    if (op === "forensic-audit") {
      // read-only tail — no store mutation ⇒ no serialize (pure short-circuit).
      return textRes(await forensicAuditTail(co, a[0]));
    }
    return jsonRes({ ok: false, error: `co: unknown forensic op '${op}'` }, 400);
  } catch {
    // §10.3 leak-proof failure mode: behaviour-identical to the bash oracle
    // (errors → stderr, stdout ALWAYS empty, nonzero rc). The error object is
    // DELIBERATELY NOT surfaced — a thrown D1 error's `.message` can echo a
    // bound parameter (the ciphertext) and an encrypt/decrypt throw can carry
    // plaintext; this is the ONE controlled crossing, so a diagnostic body
    // here would be a ciphertext/plaintext leak vector. Empty body, nonzero.
    return textRes("", 500);
  }
}
