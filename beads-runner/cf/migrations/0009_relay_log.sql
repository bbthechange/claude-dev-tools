-- K2 (claude-tools-uxvk2) — DESIGN K §3: cross-workspace `relay_log` schema.
--
-- Canonical migration for the hosted-deploy path
-- (`wrangler d1 migrations apply coordinator-records`). The Coordinator DO
-- ALSO applies this DDL lazily + idempotently (CREATE TABLE IF NOT EXISTS) so
-- K2 is locally-runnable via `wrangler dev` / miniflare with NO account and
-- NO manual migrate step. Same schema either way (src/relay.js
-- ensureRelaySchema).
--
-- ANTI-DRIFT: binds FROZEN UX-V2-ARCHITECTURE.md A.2 (storage class) + B.3
-- (the relay-log-tail projection shape) + DESIGN K §3. A contract gap ⇒ amend
-- the spine doc explicitly (its footer protocol) — NEVER diverge silently.
--
-- A cross-WS relay exchange is NOT a §4 record. `relay_log` is a SEPARATE
-- namespace from the §4 `records`/`timers` store, the CF.4 `capacity_reports`,
-- the C12 `machine_state_reports`, the CF.5 `forensic_*` tables, the CF.6
-- `work_plane_ops` sink and the CF.8 stuck-routing namespace (K2 adds NO §4
-- record type — the §4 registry is CF.1's, unchanged; `relay_log` is
-- deliberately ABSENT from it, so `get relay_log <id>` is `unknown_type`, and a
-- relay row is structurally absent from the §4.5 projection / §4.3 Notification
-- bodies — it must NEVER page anyone by itself; the batched FYI is K3's job).
-- The forensic_audit / capacity_reports "append-only, not a §4 record"
-- precedent (A.2: "Append-only audit, no (type,id) owner").
--
-- `relay_log`: one row per exchange, append-only (INSERT-only — never
--   UPDATE/DELETE; the dossier on escalate is created BEFORE the responder
--   returns, so one append captures the final outcome — DESIGN K §5.2).
--   Typed columns (not forensic_audit's single opaque `line`) BECAUSE
--   relay-log-tail must FILTER by `project_ref` (B.3) — a JSON-blob line would
--   force a JS scan. `id INTEGER PRIMARY KEY AUTOINCREMENT` is the append-only
--   recency order (forensic_audit precedent); `exchange_id` is the stable B.3
--   `id` (hash of from|to|bead|seq). `dossier_ref` is the Flow B dossier id on
--   escalate, NULL otherwise (B.3 "…|null").

CREATE TABLE IF NOT EXISTS relay_log (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  exchange_id TEXT NOT NULL,
  project_ref TEXT,
  from_ws     TEXT,
  to_ws       TEXT,
  at          TEXT,
  question    TEXT,
  answer      TEXT,
  outcome     TEXT,
  dossier_ref TEXT
);
