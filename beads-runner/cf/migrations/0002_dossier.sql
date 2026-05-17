-- CF.6 (claude-tools-7g0.6) — §5.3 ConsequenceBlock control→work sink schema.
--
-- Canonical migration for the a53 hosted-deploy path
-- (`wrangler d1 migrations apply coordinator-records`). The Coordinator DO
-- ALSO applies this DDL lazily + idempotently (CREATE TABLE IF NOT EXISTS) so
-- CF.6 is locally-runnable via `wrangler dev` / miniflare with NO account and
-- NO manual migrate step. Same schema either way.
--
-- `work_plane_ops`: one row per `bd <args>` line the §5.3 applier drives
--   against the WORK plane (control→work, §1.1/§7.3). This is the LOCAL-
--   emulation analogue of the bash tests' PATH-injected logging `bd` fake
--   writing $BD_LOG — a Worker cannot exec `bd`; the real hosted `bd` wiring
--   is a deploy-path concern, not this child (documented in src/dossier.js).
--   It is NOT a §4 record (CF.6 adds NO §4 record type — the §4 registry is
--   CF.1's, unchanged): a SEPARATE namespace from `records`/`timers`,
--   mirroring the bash store split + the §10.3-forensic "not a §4 record"
--   precedent. The synthesised create id is `bd-fake-<rowcount-after-insert>`,
--   the exact scheme the bash fake uses (`n=$(wc -l < $BD_LOG)` post-append):
--   it derives from COUNT(*) (which tracks the differential's `DELETE FROM
--   work_plane_ops` reset), NOT from the AUTOINCREMENT `id` (which does not
--   reset on DELETE). `id` is a stable row identity for forensics only —
--   never the create-id source (see src/dossier.js wpBd).

CREATE TABLE IF NOT EXISTS work_plane_ops (
  id   INTEGER PRIMARY KEY AUTOINCREMENT,
  line TEXT NOT NULL
);
