-- 0011_agent_actions.sql — I4 (claude-tools-uxvi4) / design/agent-action.md §2.1.
--
-- The control-plane `agent_actions` TRANSIENT command queue: a one-shot intent
-- the web tier enqueues and the per-machine daemon's agent-action-poll.sh
-- consumes out-of-band to cause a HOST-side effect (signal/kill a worker, run
-- gate-defer.sh apply/lift). It is the imperative one-shot sibling of the
-- declarative `set-desired` level — a command queue, NOT a desired-state.
--
-- STORAGE CLASS = TRANSIENT (Contract A.2 "control rows", work_plane_ops /
-- machine_state_reports precedent): NOT a §4 record. It bypasses _writeRecord /
-- validateRecord / the schema.js registry; it is STRUCTURALLY ABSENT from
-- workSnapshot() (A.3) and from every notification body (A.2) — a control queue
-- must never page anyone by itself. The DO lazy-DDLs the SAME shape in
-- cf/src/agent-action.js (the machine-state.js ensureSchema pattern); this file
-- is the deploy-path source of truth (A.1 step 5).
--
-- `status` is at-most-once bookkeeping (pending → done|failed|expired), NOT a §4
-- lifecycle: nobody get()s an action by id later, it is never versioned, it
-- never enters the read projection. The anticipated GC LANDED in claude-tools-jzzw
-- (incident 2026-06-14): cf/src/agent-action.js `gcAgentActions` expires pendings
-- past AGENT_ACTION_TTL_SECONDS to a terminal `expired` (so a long daemon-down
-- window can't replay a backlog en masse) and deletes terminal rows past
-- AGENT_ACTION_RETENTION_SECONDS. The schema is unchanged — `expired` is just a
-- 4th value of the existing `status TEXT` column, no migration needed.
CREATE TABLE IF NOT EXISTS agent_actions (
  action_id    TEXT NOT NULL PRIMARY KEY,  -- engine-minted, opaque, idempotency key
  workspace    TEXT NOT NULL,              -- project_ref (the daemon filters on this)
  intent       TEXT NOT NULL,              -- the closed §3 enum
  target_json  TEXT NOT NULL,              -- {bead_ref?, gate_id?, bead_refs?}
  args_json    TEXT,                        -- {reason?, date?, …} intent-specific
  status       TEXT NOT NULL,              -- pending | done | failed
  owner        TEXT,                        -- "you" | "agent:<hat>" (declared, §2.4)
  requested_at TEXT NOT NULL,
  acked_at     TEXT,                         -- when the daemon reported terminal status
  result_json  TEXT                          -- the daemon's {ok, message} on ack
);

-- The daemon polls `pending` rows scoped to one workspace each tick — index the
-- two columns that read filters together so the poll stays cheap as done/failed
-- rows accumulate before a GC sweep.
CREATE INDEX IF NOT EXISTS idx_agent_actions_pending
  ON agent_actions (workspace, status);
