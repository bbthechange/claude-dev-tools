-- I1 (claude-tools-uxvi1) — DESIGN I §1.4 agent_activity telemetry schema.
--
-- ANTI-DRIFT: binds DESIGN I (beads-runner/design/activity.md §1.2/§1.4) + the
-- FROZEN UX-V2-ARCHITECTURE.md Contract D.2 (the closed 7-state activity enum +
-- the 90/180s liveness windows). Oracle = design/activity.md + the bash
-- lib/activity-classifier.sh + test-fixtures/agent-activity-v1.json +
-- cf/src/activity.js (ensureActivitySchema) + cf/test/activity.spec.js.
-- A D.2 gap ⇒ reopen D.2, bump+re-freeze — NEVER diverge.
--
-- Canonical migration for the hosted-deploy path
-- (`wrangler d1 migrations apply coordinator-records`). The Coordinator DO ALSO
-- applies this DDL lazily + idempotently (CREATE TABLE IF NOT EXISTS) so I1 is
-- locally-runnable via `wrangler dev` / miniflare with NO account and NO manual
-- migrate step. Same schema either way (src/activity.js ensureActivitySchema).
--
-- An agent_activity report is EPHEMERAL telemetry, NOT a §4 record (Contract
-- A.2 "Ephemeral telemetry, aggregation-only read"). `agent_activity` is a
-- SEPARATE namespace from the §4 `records`/`timers` store, the CF.4
-- `capacity_reports` namespace, the C12 `machine_state_reports` namespace, the
-- CF.6 `work_plane_ops` sink, the CF.5 `forensic_*` tables, the CF.8
-- stuck-routing namespace and the K2 `relay_log` namespace (I1 adds NO §4
-- record type — the §4 registry is CF.1's, unchanged; `agent_activity` is
-- deliberately ABSENT from it, so it is structurally absent from the §4.5
-- projection's record path and from every §4.3 Notification body — activity
-- NEVER pages anyone by itself, DESIGN I §1.4 / the machine_state_reports
-- precedent).
--
-- WHY this exists separate from CAPACITY/MACHINE-STATE: it carries the
-- per-AGENT derived activity state (one writer + 0..N read-only aux per
-- workspace), keyed on `agent_key`, on the cadence of the worker stream — a
-- different cardinality and cadence than the per-MACHINE telemetry. The
-- projection (I2, reconcile.js workSnapshot) joins this back into each
-- project's `activity{}` sub-object, projecting each lane DOWN to its exact
-- B.1 shape; the wire body here is the §1.4 ingest SUPERSET, never read raw by
-- the UI.
--
-- `agent_activity`: one row per `agent_key` (the latest-wins PRIMARY KEY —
--   `writer:<runner_id>` is singular per workspace by construction;
--   `aux:<kind>:<dispatch_id>` for an aux). The §1.4 ingest re-enforces §0.3
--   (unknown HIGHER schema_version REJECTED, never best-effort) + the D.2
--   closed enum (state ∈ the 7-set, state_confidence === "derived", liveness_dot
--   ∈ {green,amber,red}, lane ∈ {writer,auxiliary}) EXACTLY as the §4 store
--   gates, and §9.1 stamps the RESOLVED principal over whatever literal the
--   report carried. `json` keeps the byte-faithful wire body (modulo the §9.1
--   stamp); `observed_at` is a denormalised column ONLY so the latest-wins
--   read-modify-write is a clean indexed lookup. The LATEST report per
--   agent_key wins (an older straggler is dropped — RFC-3339 UTC strings sort
--   lexicographically).

CREATE TABLE IF NOT EXISTS agent_activity (
  agent_key   TEXT NOT NULL PRIMARY KEY,
  observed_at TEXT NOT NULL,
  json        TEXT NOT NULL
);
