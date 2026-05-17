-- CF.4 (claude-tools-7g0.4) — §6.3/§6.2 coarse capacity-aggregation schema.
--
-- Canonical migration for the a53 hosted-deploy path
-- (`wrangler d1 migrations apply coordinator-records`). The Coordinator DO
-- ALSO applies this DDL lazily + idempotently (CREATE TABLE IF NOT EXISTS) so
-- CF.4 is locally-runnable via `wrangler dev` / miniflare with NO account and
-- NO manual migrate step. Same schema either way (src/capacity.js
-- ensureCapacitySchema).
--
-- A §1.1 capacity report is NOT a §4 record. `capacity_reports` is a SEPARATE
-- namespace from the §4 `records`/`timers` store, the CF.6 `work_plane_ops`
-- sink, the CF.5 `forensic_*` tables and the CF.8 stuck-routing namespace
-- (CF.4 adds NO §4 record type — the §4 registry is CF.1's, unchanged;
-- `capacity` is deliberately ABSENT from it, so `get capacity <id>` is
-- "reachable, just empty", `put capacity ...` is `unknown_type`, and a
-- capacity report is structurally absent from the §4.5 projection / §4.3
-- Notification bodies — the §10.3-forensic "not a §4 record" precedent).
--
-- WHY (AD2.3 honest rationale): the Coordinator never reads a Keychain or an
-- Anthropic usage API (§1.1). It AGGREGATES the coarse cost-class verdicts the
-- Local Agents (T3) report UP, produced by la_report_capacity and consumed
-- VERBATIM. The 5h/7d hard ceiling (BC-34) is the real guard; the 14.2%/day
-- spare line is a soft ramp. Both were MEASURED at the Local Agent and are
-- already encoded in the reported coarse verdict — this tier AGGREGATES that
-- verdict, it never re-measures (no usage-cache / spare-ramp here).
--
-- `capacity_reports`: one row per (cost_class, runner_id) — the cost_class is
--   a fixed closed enum {standard,low_priority}, the runner_id the only
--   variable component and safeKey-validated at ingest (the bash
--   one-file-per-(runner_id,cost_class) shape). The §1.1 ingest re-enforces
--   §0.3 (unknown HIGHER schema_version REJECTED, never best-effort) + the
--   §6.3 closed enums EXACTLY as the §4 store does, and §9.1 stamps the
--   RESOLVED principal over whatever literal the report carried (C7).
--   `json` keeps the byte-faithful T3 line (modulo the §9.1 stamp) for the
--   latest-wins observed_at compare; `verdict` is a denormalised column ONLY
--   so the §6.3 aggregation is a clean indexed read. The LATEST report per
--   (runner_id,cost_class) wins (a recovered runner re-reporting `ok` with a
--   newer observed_at supersedes its earlier `over`; an older straggler is
--   dropped — RFC-3339 UTC strings sort lexicographically).

CREATE TABLE IF NOT EXISTS capacity_reports (
  cost_class  TEXT NOT NULL,
  runner_id   TEXT NOT NULL,
  verdict     TEXT NOT NULL,
  observed_at TEXT,
  json        TEXT NOT NULL,
  PRIMARY KEY (cost_class, runner_id)
);
