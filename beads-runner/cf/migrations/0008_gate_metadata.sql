-- J1 (claude-tools-uxvj1) — DESIGN J §2 gate_metadata transient schema.
--
-- ANTI-DRIFT: binds DESIGN J (beads-runner/design/gates.md §2) + the FROZEN
-- UX-V2-ARCHITECTURE.md Contract A.2 (storage class — gate_metadata is a
-- TRANSIENT annotation, not a §4 record) + D.2 (the closed GATE_SCOPE enum
-- {task,cohort}). Oracle = design/gates.md §2 + web/shared/enums.js GATE_SCOPE
-- + cf/src/gate-meta.js (ensureGateMetaSchema) + cf/test/gate-meta.spec.js.
-- A D.2 gap ⇒ reopen D.2, bump+re-freeze — NEVER diverge.
--
-- Canonical migration for the hosted-deploy path
-- (`wrangler d1 migrations apply coordinator-records`). The Coordinator DO ALSO
-- applies this DDL lazily + idempotently (CREATE TABLE IF NOT EXISTS) so J1 is
-- locally-runnable via `wrangler dev` / miniflare with NO account and NO manual
-- migrate step. Same schema either way (src/gate-meta.js ensureGateMetaSchema).
--
-- gate_metadata ANNOTATES a beads-label. The `gate:<id>` bd LABEL is the source
-- of truth for cohort membership (gate-defer.sh apply/lift); this table adds the
-- metadata the bare label lacks — why / unblock_condition / owner / scope —
-- keyed to the bare gate id so a single row serves the whole cohort. It is NOT
-- a §4 record (Contract A.2): a SEPARATE namespace from the §4 `records`/`timers`
-- store, the CF.4 `capacity_reports`, the C12 `machine_state_reports`, the CF.6
-- `work_plane_ops` sink, the CF.5 `forensic_*` tables, the CF.8 stuck-routing
-- namespace, the K2 `relay_log` and the I1 `agent_activity` namespaces (J1 adds
-- NO §4 record type — the §4 registry is CF.1's, unchanged; `gate_metadata` is
-- deliberately ABSENT from it, so it is structurally absent from the §4.5
-- projection's record path and from every §4.3 Notification body — a gate
-- NEVER pages anyone by itself; the agent-gate FYI is Track N/K3's batched job,
-- design/gates.md §6). Read by JOIN: the J2 projection (reconcile.js
-- workSnapshot) LEFT-joins this into each project's `holds[]`.
--
-- `gate_metadata`: one row per BARE gate id (the <id> in gate:<id>; the §2.1
--   PRIMARY KEY). `why` is REQUIRED at write (B8 — a Gate always carries a why,
--   so the invisible-defer class can never recur, D.3); the engine rejects a set
--   without one. `owner` is an INPUT, not the principal (§2.3: the GUI passes
--   "you", an agent passes "agent:<hat>" — one shared bearer can't distinguish
--   them). `scope` is the closed D.2 enum {task,cohort} (default "task" when
--   absent). `set_at` is the FIRST placement, PRESERVED across edits (only
--   `updated_at` advances) so "set 4d ago" stays honest. A dormant row (its
--   label carried by no bead) is harmless — it is simply not rendered as a live
--   hold (a hold needs task_count >= 1); no delete op is required for v1.

CREATE TABLE IF NOT EXISTS gate_metadata (
  gate_id           TEXT NOT NULL PRIMARY KEY,
  why               TEXT,
  unblock_condition TEXT,
  owner             TEXT,
  scope             TEXT,
  set_at            TEXT NOT NULL,
  updated_at        TEXT NOT NULL
);
