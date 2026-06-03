-- H1 (claude-tools-uxvh1) — DESIGN H (design/blueprint.md §2.1) the `blueprint`
-- §4 record. NEXT migration number after 0011_agent_actions.sql (the design's
-- §2.1 "0007" name predates tracks J/I/K shipping 0008–0011; the number is the
-- only thing that changed — it is the deploy-path ordering, not a contract).
--
-- Canonical migration for the hosted-deploy path
-- (`wrangler d1 migrations apply coordinator-records`). The Coordinator DO ALSO
-- DDLs the `records` table lazily + idempotently (CREATE TABLE IF NOT EXISTS in
-- coordinator.js ensureSchema) so H1 is locally-runnable via `wrangler dev` /
-- miniflare with NO account and NO manual migrate step. Same schema either way.
--
-- ANTI-DRIFT: binds FROZEN UX-V2-ARCHITECTURE.md A.2 (storage class — blueprint
-- is a §4 record) + B.2 (the {derived,customization,narrative,conflicts[]} body)
-- + DESIGN H. A contract gap ⇒ amend the spine doc explicitly (its footer
-- protocol) — NEVER diverge silently.
--
-- A Blueprint IS a §4 record (owned, addressable by (type,id), versioned, in the
-- projection + a §4.3 Notification body) — so UNLIKE the transient tracks J/I/K
-- (gate_metadata / agent_actions / relay_log / agent_activity, each its OWN
-- sibling namespace) it adds NO new table: a `blueprint` row is just a `records`
-- row (type='blueprint', id=<project_ref>, json=<B.2 body>) in the shared §4
-- store CF.1's 0001_init.sql already owns. The type is REGISTERED in
-- schema.js SCHEMA_VERSIONS (blueprint: 1), so `validateRecord` accepts
-- type='blueprint' and the §0.3 integer-≤-bound schema gate applies; `put
-- blueprint <unsafe-id> …` is still rejected by the store-owner id hygiene.
--
-- This migration therefore ships NO DDL of its own beyond re-asserting the
-- shared §4 store idempotently (harmless if already present) — its job is to be
-- the deploy-path SOURCE OF TRUTH that records "blueprint lives in `records`",
-- so the A.1-step-5 migration chain and the op-wiring conformance fixture both
-- have a file to point at. The never-clobber guarantee (a `derived` write and a
-- `customization` write must not erase each other) is NOT a schema concern — it
-- is the SECTIONED read-merge-write in cf/src/blueprint.js, running inside the
-- singleton DO's `_serialize` over this same whole-record `records` row.

CREATE TABLE IF NOT EXISTS records (
  type TEXT NOT NULL,
  id   TEXT NOT NULL,
  json TEXT NOT NULL,
  PRIMARY KEY (type, id)
);
