-- CF.8 (claude-tools-7g0.8) — STUCK_NEEDS_HUMAN cross-tier routing schema.
--
-- Canonical migration for the a53 hosted-deploy path
-- (`wrangler d1 migrations apply coordinator-records`). The Coordinator DO
-- ALSO applies this DDL lazily + idempotently (CREATE TABLE IF NOT EXISTS)
-- via src/stuck.js `ensureStuckSchema`, so CF.8 is locally-runnable via
-- `wrangler dev` / miniflare with NO account and NO manual migrate step.
-- Same schema either way.
--
-- NONE of these four is a §4 record (CF.8 adds NO §4 record type — the §4
-- registry is CF.1's schema.js, unchanged): a SEPARATE namespace from
-- `records`/`timers`/`work_plane_ops`, mirroring the bash store split + the
-- §10.3-forensic / dossier-dedup "NOT a §4 record" precedent. Adding a §4
-- record type would be a §0/§11 freeze escalation.
--
--   • stuck_dedup       — the §7.4 DOSSIER-level double-trigger dedup binding
--     (key = `task_ref`; the bash `dossier-dedup` namespace analogue). The
--     `task_ref` PRIMARY KEY IS the single-writer create-once test-and-set
--     ("one fork ⇒ one Dossier" BY CONSTRUCTION — the AD1 payoff replacing the
--     bash `mkdir` advisory lock). DISTINCT key space from CF.6's per-Item
--     `id` latch — never collide them (§0.4 two-layer key model).
--   • stuck_bfh         — the COORDINATOR-owned blocked-for-human control
--     plane (the bash `blocked-for-human` namespace). The S-2 SOURCE OF TRUTH
--     the reconcile drives from (NOT the bead's possibly-stale work status).
--   • stuck_bead_status — the per-bead WORK-plane status projection (the bash
--     test fake's `$BDST/<id>` analogue — the readable `bd show` truth a later
--     writer / Dolt lag can clobber; the reconcile re-asserts/lifts it driven
--     by stuck_bfh, never trusting it — S-2).
--   • stuck_work_plane  — append-only `bd <args>` line log (the bash test
--     fake's $BD_HUMAN/$BD_LOG analogue — §7.3 drive evidence + the `bd human`
--     flag). Its OWN table, not CF.6's `work_plane_ops` (the same
--     sibling-namespace discipline bash stuck-routing.sh keeps vs dossier.sh).

CREATE TABLE IF NOT EXISTS stuck_dedup (
  task_ref TEXT PRIMARY KEY,
  json     TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS stuck_bfh (
  task_ref TEXT PRIMARY KEY,
  json     TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS stuck_bead_status (
  bead_ref TEXT PRIMARY KEY,
  status   TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS stuck_work_plane (
  id   INTEGER PRIMARY KEY AUTOINCREMENT,
  line TEXT NOT NULL
);
