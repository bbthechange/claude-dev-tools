-- C12 (claude-tools-zdxd.3) — MACHINE-STATE.md v1 (D2) telemetry schema.
--
-- ANTI-DRIFT: binds FROZEN MACHINE-STATE.md v1 (D2).
-- Oracle = MACHINE-STATE.md + test-fixtures/machine-state-v1.json +
-- cf/test/conformance-machine-state.sh.
-- A D2 gap ⇒ reopen D2, bump+re-freeze — NEVER diverge, NEVER edit
-- MACHINE-STATE.md silently.
--
-- Canonical migration for the hosted-deploy path
-- (`wrangler d1 migrations apply coordinator-records`). The Coordinator DO
-- ALSO applies this DDL lazily + idempotently (CREATE TABLE IF NOT EXISTS) so
-- C12 is locally-runnable via `wrangler dev` / miniflare with NO account and
-- NO manual migrate step. Same schema either way (src/machine-state.js
-- ensureMachineStateSchema).
--
-- A D2 machine_state report is NOT a §4 record. `machine_state_reports` is a
-- SEPARATE namespace from the §4 `records`/`timers` store, the CF.4
-- `capacity_reports` namespace, the CF.6 `work_plane_ops` sink, the CF.5
-- `forensic_*` tables and the CF.8 stuck-routing namespace (C12 adds NO §4
-- record type — the §4 registry is CF.1's, unchanged; `machine_state` is
-- deliberately ABSENT from it, so `get machine_state <id>` is "reachable,
-- just empty", `put machine_state ...` is `unknown_type`, and a machine_state
-- report is structurally absent from the §4.5 projection / §4.3 Notification
-- bodies — the §10.3-forensic / capacity_reports "not a §4 record"
-- precedent).
--
-- WHY this exists separate from CAPACITY (the §0.C Path B rationale — see
-- MACHINE-STATE.md §0): the §1.1 capacity-report contract is a tight closed-
-- enum gate signal ({ok,over}). Display data evolves on a different cadence
-- than gate logic; routing display growth through §1.1 would erode the
-- closed-enum discipline that makes the gate auditable. A separate namespace
-- pays a small one-time cost (a second ingest path) to keep both contracts
-- independently evolvable.
--
-- `machine_state_reports`: one row per `runner_id` (the §2.1 PRIMARY KEY —
--   "NOT per-workspace", §0.B). The §1.1 ingest re-enforces §0.3 (unknown
--   HIGHER schema_version REJECTED, never best-effort) + the §1.1 closed
--   numeric shape EXACTLY as the §4 store does, and §9.1 stamps the RESOLVED
--   principal over whatever literal the report carried (C7). `json` keeps
--   the byte-faithful daemon line (modulo the §9.1 stamp) for the snapshot
--   projection (C3); `observed_at` is a denormalised column ONLY so the
--   latest-wins read-modify-write is a clean indexed lookup. The LATEST
--   report per runner_id wins (a recovered daemon re-reporting newer pcts
--   supersedes its earlier values; an older straggler is dropped — RFC-3339
--   UTC strings sort lexicographically).

CREATE TABLE IF NOT EXISTS machine_state_reports (
  runner_id   TEXT NOT NULL PRIMARY KEY,
  observed_at TEXT NOT NULL,
  json        TEXT NOT NULL
);
