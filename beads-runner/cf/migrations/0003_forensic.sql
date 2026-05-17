-- CF.5 (claude-tools-7g0.5) — §10.3 forensic transient-store schema.
--
-- Canonical migration for the a53 hosted-deploy path
-- (`wrangler d1 migrations apply coordinator-records`). The Coordinator DO
-- ALSO applies this DDL lazily + idempotently (CREATE TABLE IF NOT EXISTS) so
-- CF.5 is locally-runnable via `wrangler dev` / miniflare with NO account and
-- NO manual migrate step. Same schema either way (src/forensic.js
-- ensureForensicSchema).
--
-- The §10.3 forensic transient store is a SEPARATE namespace from the §4
-- `records`/`timers` store and the CF.6 `work_plane_ops` sink. It is NOT a §4
-- record (CF.5 adds NO §4 record type — the §4 registry is CF.1's, unchanged;
-- `forensic` is deliberately ABSENT from it, so `get forensic <id>` is
-- `unknown_type` and the blob is structurally absent from the §4.5 projection
-- and §4.3 Notification bodies). Flow G tier-3's ONE controlled crossing of
-- the sync boundary, under AD4's concrete numbers; §10.1/BC-27 (the runner
-- on-disk `.beads/runner-logs/` boundary in run-beads-tasks.sh) is PRESERVED
-- VERBATIM — this transient encrypted path is an ADD, never a relaxation.
--
-- `forensic_blobs`: CIPHERTEXT ONLY at rest (AES-256-GCM armoured envelope) —
--   never plaintext, never the key. The §10.2-redacted blob is stored
--   VERBATIM (this tier re-derives NO redaction; raw stream-json never leaves
--   the machine — that is the runner/Local-Agent tier, T2/T3).
-- `forensic_meta`: content-free ids + timestamps ONLY — the TTL math
--   (created_at + FORENSIC_BLOB_TTL §0.5) + audit source. NO blob body.
-- `forensic_audit`: append-only, content-free control-plane deletion audit
--   (event + ids + timestamps + reason + §9.1 principal; NO forensic content,
--   NO ciphertext, NO key). INSERT-only — never UPDATE/DELETE.
-- `forensic_key`: the SERVER master key — a SERVER SECRET in its OWN table,
--   OUTSIDE the ciphertext namespace (so "the storage layer holds ciphertext
--   only" is true of the blob namespace), generated ONCE (CHECK(id=1) — one
--   key), NEVER returned by any op surface. In the Appendix-A hosted
--   realization this is a Worker/KMS secret; a single-row D1 table is the
--   documented LOCAL-emulation realisation choice (no §11 gap), the §10.3
--   analogue of CF.6's documented `work_plane_ops` choice.
--
-- Hard-delete = IRRECOVERABLE row destruction (DELETE, NOT a tombstone) at the
-- EARLIER of created_at + FORENSIC_BLOB_TTL OR an explicit dismiss; emits one
-- content-free `forensic_audit` row.

CREATE TABLE IF NOT EXISTS forensic_blobs (
  blob_id    TEXT PRIMARY KEY,
  ciphertext TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS forensic_meta (
  blob_id       TEXT PRIMARY KEY,
  dossier_ref   TEXT,
  created_at    TEXT,
  created_epoch INTEGER,
  expires_epoch INTEGER,
  principal     TEXT
);

CREATE TABLE IF NOT EXISTS forensic_audit (
  id   INTEGER PRIMARY KEY AUTOINCREMENT,
  line TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS forensic_key (
  id      INTEGER PRIMARY KEY CHECK (id = 1),
  key_b64 TEXT NOT NULL
);
