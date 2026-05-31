-- N2 (claude-tools-uxg1) — phone DELIVERY transport schema. DESIGN N §2
-- (beads-runner/design/notifications.md).
--
-- Canonical migration for the hosted-deploy path
-- (`wrangler d1 migrations apply coordinator-records`). The Coordinator DO
-- ALSO applies this DDL lazily + idempotently (CREATE TABLE IF NOT EXISTS) so
-- N2 is locally-runnable via `wrangler dev` / miniflare with NO account and NO
-- manual migrate step. Same schema either way (src/push.js ensurePushSchema).
--
-- NEITHER table is a §4 record (DESIGN N §2.2 — A.2 storage class). They are
-- SEPARATE namespaces from the §4 `records`/`timers` store, the CF.4
-- `capacity_reports`, the C12 `machine_state_reports`, the CF.6
-- `work_plane_ops` sink, the CF.5 `forensic_*` tables and the CF.8 stuck
-- namespace — the §10.3-forensic "not a §4 record" precedent. N2 adds NO §4
-- record type (the §4 registry is CF.1's, unchanged) and makes NO INTERFACE
-- §4.3 change: the Notification record is untouched (uxg1 scope). So
-- `put push_subscription ...` is `unknown_type` and a subscription is
-- structurally absent from the §4.5 projection / §4.3 Notification bodies.
--
-- `push_subscriptions`: one row per browser Web-Push endpoint (the §2.1
--   PRIMARY KEY). `p256dh`/`auth` are the RFC 8291 subscription keys the
--   delivery step encrypts to; `principal` is the §9.1-resolved owner. A
--   re-subscribe (rotated keys) INSERT OR REPLACEs the same endpoint; a 404/410
--   from the push service prunes the row (the subscription is gone).
--
-- `push_deliveries`: the deliver-once LEDGER, one row per notification id
--   already pushed (immediate OR folded into a digest). The §4.3 `dispatched`
--   latch is overloaded across producers and is NOT a reliable "pushed to the
--   phone" flag, so N2 keeps its own transient ledger — INSERT OR IGNORE is the
--   idempotency guard so a re-running sweep never double-pushes. `kind` records
--   how it was delivered ("blocking" | "digest").

CREATE TABLE IF NOT EXISTS push_subscriptions (
  endpoint    TEXT NOT NULL PRIMARY KEY,
  principal   TEXT,
  p256dh      TEXT NOT NULL,
  auth        TEXT NOT NULL,
  created_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS push_deliveries (
  notif_id     TEXT NOT NULL PRIMARY KEY,
  delivered_at TEXT NOT NULL,
  kind         TEXT NOT NULL
);
