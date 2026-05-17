-- CF.1 (claude-tools-7g0.1) — §2.1 / §4 strongly-consistent record store schema.
--
-- Canonical migration for the a53 hosted-deploy path
-- (`wrangler d1 migrations apply coordinator-records`). The Coordinator DO
-- ALSO applies this DDL lazily + idempotently (CREATE TABLE IF NOT EXISTS) so
-- the substrate is locally-runnable via `wrangler dev` / miniflare with NO
-- account and NO manual migrate step. Same schema either way.
--
-- `records`: every §4 record type (dossier, runner_state, notification, lease,
--   work_snapshot), keyed by (type,id) — the (type,id) the singleton
--   single-threaded Coordinator DO serialises every write on (§2.1 / §7.4 /
--   AD1 single-writer BY CONSTRUCTION). `json` holds the principal-stamped
--   (§9.1), §0.3-validated envelope verbatim.
-- `timers`: the §2.2 one-shot timer surface — a SEPARATE namespace from §4
--   records (a timer is NOT a §4 record; mirrors the bash store/timers/ split).
--   Opaque shape only: {timer_id,fire_at,armed_at,acked}. fire(dossier_id)
--   wiring + the per-Item exactly-once latch are CF.6/CF.7, NOT here.

CREATE TABLE IF NOT EXISTS records (
  type TEXT NOT NULL,
  id   TEXT NOT NULL,
  json TEXT NOT NULL,
  PRIMARY KEY (type, id)
);

CREATE TABLE IF NOT EXISTS timers (
  timer_id TEXT PRIMARY KEY,
  fire_at  TEXT NOT NULL,
  armed_at TEXT,
  acked    INTEGER NOT NULL DEFAULT 0
);
