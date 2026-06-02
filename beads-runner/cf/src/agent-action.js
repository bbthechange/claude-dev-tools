// I4 (claude-tools-uxvi4) — design/agent-action.md §2: the control-plane
// `agent-action` engine op (the host-side executor's QUEUE end).
//
// The web tier holds NO host access (Local==remote — the bgw/2dk lesson made
// literal): a Cloudflare Pages site can only POST ops to this engine. But I4's
// stuck actions (nudge / kill+retry / kill+gate) and J3's gate edits need
// HOST-side effects — signal/kill a worker, run gate-defer.sh apply/lift. So we
// reuse the EXACT pattern the runner-lifecycle already runs (set-desired →
// desired-state-poll.sh): the web POSTs an INTENT this module records into a
// transient `agent_actions` queue; the daemon's agent-action-poll.sh reads
// pending intents out-of-band, performs the host effect, and acks. This module
// is the engine end ONLY — it never touches a host (it has no shell).
//
// Three ops, one module, one guard (the gate-meta.js / machine-state.js
// guarded-set precedent; the CF.1 substrate switch below stays byte-identical):
//   • agent-action(<envelope_json>)              — WRITE: validate + enqueue (status:pending)
//   • agent-action-pending(<workspace?>)         — READ:  the daemon's poll (pure aggregation)
//   • agent-action-ack(<action_id>,<status>,<result_json?>) — WRITE: terminal status
//
// STORAGE CLASS = TRANSIENT (Contract A.2 control-row class; work_plane_ops /
// machine_state_reports precedent). It BYPASSES _writeRecord/validateRecord/the
// schema.js §4 registry, is STRUCTURALLY ABSENT from workSnapshot() (A.3) and
// from every notification body (A.2) — a control queue must never page anyone by
// itself. `status` is at-most-once bookkeeping (pending→done|failed), NOT a §4
// lifecycle (§2.1 rebuttal): nobody get()s an action by id, it is never
// versioned, it never enters the read-model.
//
// THE CLOSED INTENT ENUM (host-effecting verbs ONLY, §3): nudge | kill-retry |
// kill-gate | gate-apply | gate-lift. `escalate` is NOT here (it is a pure-engine
// dossier write the web already does); `gate-meta-set` is NOT here (it is a
// direct engine write). This enum is host-effecting only — that is the boundary.
//
// AD1 PAYOFF: the enqueue + the ack are read-modify-writes that run INSIDE
// co._serialize (the singleton single-threaded DO tail), so a daemon ack can
// never interleave with a racing enqueue for the same action_id. The pending
// read is a pure aggregation ⇒ NO serialize (the machine-state.js / activity.js
// pure-op short-circuit precedent).
//
// ANTI-DRIFT: binds FROZEN design/agent-action.md §2/§3 + the Architecture Spine
// A.1 (add-an-op)/A.2 (transient)/A.4 (naming). The §9.1 chokepoint (the Worker)
// has ALREADY authenticated + threaded `principal`; there is NO second auth path
// here (a no/invalid-token op is rejected 401 at the Worker before this module).

import { safeKey } from "./schema.js";

// The I4/J3 op surface. Kept OUT of CF.1's CAPABILITIES (the four §2 lines stay
// exactly four — the machine-state.js anti-drift discipline). Crosses the §2.3
// authed channel like every other op, behind the ONE §9.1 chokepoint.
export const AGENT_ACTION_OPS = new Set([
  "agent-action", // §2.2 enqueue — <envelope_json> → agent_actions (status:pending)
  "agent-action-pending", // §2.2 daemon read — pending rows, optionally one workspace
  "agent-action-ack", // §2.2 daemon write — terminal status (done|failed) for one action_id
]);

// §3 the CLOSED, host-effecting intent enum. Frozen.
export const AGENT_ACTION_INTENTS = new Set([
  "nudge",
  "kill-retry",
  "kill-gate",
  "gate-apply",
  "gate-lift",
]);

// Terminal ack states (§2.2): the daemon reports exactly one of these.
const ACK_STATES = new Set(["done", "failed"]);

// ── lazy + idempotent DDL — the SEPARATE transient `agent_actions` namespace ──
// Mirrors machine-state.js's ensureMachineStateSchema discipline (CREATE TABLE
// IF NOT EXISTS, lazy, per-instance memoised) so the queue is locally-runnable
// with NO account and NO manual migrate step. The canonical migration ships in
// migrations/0011_agent_actions.sql for the deploy path. `agent_actions` is a
// SEPARATE namespace from records/timers/work_plane_ops/forensic_*/
// capacity_reports/machine_state_reports/agent_activity/relay_log/gate_metadata
// — NOT a §4 record.
function ensureAgentActionSchema(co) {
  if (!co._agentActionSchemaReady) {
    co.db
      .prepare(
        "CREATE TABLE IF NOT EXISTS agent_actions (action_id TEXT NOT NULL PRIMARY KEY, workspace TEXT NOT NULL, intent TEXT NOT NULL, target_json TEXT NOT NULL, args_json TEXT, status TEXT NOT NULL, owner TEXT, requested_at TEXT NOT NULL, acked_at TEXT, result_json TEXT)"
      )
      .run();
    co.db
      .prepare(
        "CREATE INDEX IF NOT EXISTS idx_agent_actions_pending ON agent_actions (workspace, status)"
      )
      .run();
    co._agentActionSchemaReady = true;
  }
  return co._agentActionSchemaReady;
}

// RFC-3339 UTC, milliseconds trimmed — the gate-meta.js / dossier.js nowZ()
// convention (so timestamps sort lexicographically the same way everywhere).
function nowZ() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

function strOk(v) {
  return typeof v === "string" && v.length > 0;
}

// ── §3 per-intent required-field validation ─────────────────────────────────
// Returns null if OK, else a short error string. `t` = target object, `a` =
// args object. The required fields are §3's table, verbatim. A gate-apply may
// carry EITHER a single bead_ref OR a bead_refs[] cohort (J3 add-a-gate).
function intentRequirementError(intent, t, a) {
  const beadRef = strOk(t.bead_ref) ? t.bead_ref : "";
  const gateId = strOk(t.gate_id) ? t.gate_id : "";
  const date = strOk(a.date) ? a.date : "";
  const beadRefs = Array.isArray(t.bead_refs)
    ? t.bead_refs.filter((x) => strOk(x))
    : [];
  switch (intent) {
    case "nudge":
    case "kill-retry":
      if (!beadRef) return `${intent} requires target.bead_ref`;
      return null;
    case "kill-gate":
      if (!beadRef) return "kill-gate requires target.bead_ref";
      if (!gateId) return "kill-gate requires target.gate_id";
      if (!date) return "kill-gate requires args.date (gate-defer.sh apply couples label+defer)";
      return null;
    case "gate-apply":
      if (!gateId) return "gate-apply requires target.gate_id";
      if (!beadRef && beadRefs.length === 0)
        return "gate-apply requires target.bead_ref or a non-empty target.bead_refs[]";
      if (!date) return "gate-apply requires args.date (gate-defer.sh apply couples label+defer)";
      return null;
    case "gate-lift":
      if (!gateId) return "gate-lift requires target.gate_id";
      return null;
    default:
      return `unknown intent '${intent}'`;
  }
}

// ── agent-action (enqueue) — validate + mint + INSERT pending ───────────────
// Returns { ok:true, action_id } on enqueue, { ok:false, error } on a bad
// envelope (the proxy passes the body through verbatim; the GUI shows the
// error). Runs INSIDE co._serialize so the INSERT never races an ack.
async function agentActionEnqueue(co, principal, jsonStr) {
  if (jsonStr === undefined || jsonStr === null || String(jsonStr).length === 0) {
    return { ok: false, error: "agent-action needs <envelope_json>" };
  }
  let env;
  try {
    env = JSON.parse(jsonStr);
  } catch {
    return { ok: false, error: "agent-action: envelope is not valid JSON" };
  }
  if (env === null || typeof env !== "object" || Array.isArray(env)) {
    return { ok: false, error: "agent-action: envelope must be a JSON object" };
  }
  const intent = env.intent;
  if (!AGENT_ACTION_INTENTS.has(intent)) {
    return {
      ok: false,
      error: `agent-action: intent must be one of ${[...AGENT_ACTION_INTENTS].join(", ")}`,
    };
  }
  const workspace = env.workspace;
  if (!strOk(workspace) || !safeKey(workspace)) {
    return { ok: false, error: "agent-action: workspace missing / unsafe (the daemon filters on it)" };
  }
  const target = env.target && typeof env.target === "object" && !Array.isArray(env.target) ? env.target : {};
  const args = env.args && typeof env.args === "object" && !Array.isArray(env.args) ? env.args : {};
  const reqErr = intentRequirementError(intent, target, args);
  if (reqErr) return { ok: false, error: `agent-action: ${reqErr}` };
  // owner is a DECLARED input (§2.4 — the bearer is shared, so the principal
  // cannot distinguish you-vs-agent). The GUI proxy passes owner:"you"; an
  // agent passes owner:"agent:<hat>". Default to "you" (the GUI is the primary
  // caller); never derive it from the principal.
  const owner = strOk(env.owner) ? env.owner : "you";

  const actionId = crypto.randomUUID();
  const requestedAt = nowZ();
  await co.db
    .prepare(
      "INSERT INTO agent_actions (action_id, workspace, intent, target_json, args_json, status, owner, requested_at, acked_at, result_json) VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, NULL, NULL)"
    )
    .bind(
      actionId,
      workspace,
      intent,
      JSON.stringify(target),
      JSON.stringify(args),
      owner,
      requestedAt
    )
    .run();
  return { ok: true, action_id: actionId };
}

// ── agent-action-pending (read) — the daemon's poll ─────────────────────────
// Returns { actions:[ {action_id, workspace, intent, target, args, owner,
// requested_at}, … ] } — the pending rows, optionally scoped to one workspace.
// target/args are parsed back to objects for the daemon's convenience. Pure
// read ⇒ NO serialize. Empty ⇒ {actions:[]}, never a throw.
async function agentActionPending(co, workspace) {
  let rows;
  if (strOk(workspace)) {
    rows = await co.db
      .prepare(
        "SELECT action_id, workspace, intent, target_json, args_json, owner, requested_at FROM agent_actions WHERE status = 'pending' AND workspace = ? ORDER BY requested_at ASC"
      )
      .bind(workspace)
      .all();
  } else {
    rows = await co.db
      .prepare(
        "SELECT action_id, workspace, intent, target_json, args_json, owner, requested_at FROM agent_actions WHERE status = 'pending' ORDER BY requested_at ASC"
      )
      .all();
  }
  const actions = [];
  for (const r of (rows && rows.results) || []) {
    let target = {};
    let args = {};
    try {
      target = JSON.parse(r.target_json || "{}");
    } catch {
      target = {};
    }
    try {
      args = JSON.parse(r.args_json || "{}");
    } catch {
      args = {};
    }
    actions.push({
      action_id: r.action_id,
      workspace: r.workspace,
      intent: r.intent,
      target,
      args,
      owner: r.owner || "you",
      requested_at: r.requested_at,
    });
  }
  return { actions };
}

// ── agent-action-ack (write) — terminal status for one action_id ────────────
// Sets status ∈ {done,failed} + acked_at + result_json. Idempotent: a missing
// id ⇒ {ok:false} (never a throw); re-acking an already-terminal action is a
// harmless overwrite. Runs INSIDE co._serialize.
async function agentActionAck(co, actionId, status, resultStr) {
  if (!strOk(actionId)) return { ok: false, error: "agent-action-ack needs <action_id>" };
  if (!ACK_STATES.has(status))
    return { ok: false, error: "agent-action-ack: status must be 'done' or 'failed'" };
  const existing = await co.db
    .prepare("SELECT action_id FROM agent_actions WHERE action_id = ?")
    .bind(actionId)
    .first();
  if (!existing) return { ok: false, error: `agent-action-ack: no action '${actionId}'` };
  let resultJson = null;
  if (strOk(resultStr)) {
    // Tolerate a non-JSON result string — store it verbatim wrapped, never throw.
    try {
      JSON.parse(resultStr);
      resultJson = resultStr;
    } catch {
      resultJson = JSON.stringify({ message: String(resultStr) });
    }
  }
  await co.db
    .prepare(
      "UPDATE agent_actions SET status = ?, acked_at = ?, result_json = ? WHERE action_id = ?"
    )
    .bind(status, nowZ(), resultJson, actionId)
    .run();
  return { ok: true };
}

// ── dispatch ────────────────────────────────────────────────────────────────
function jsonRes(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export async function handleAgentActionOp(co, op, args, principal) {
  const a = args || [];
  ensureAgentActionSchema(co);

  if (op === "agent-action") {
    const r = await co._serialize(() => agentActionEnqueue(co, principal, a[0]));
    return jsonRes(r, r.ok ? 200 : 422);
  }

  if (op === "agent-action-pending") {
    const r = await agentActionPending(co, a[0]);
    return jsonRes(r, 200);
  }

  if (op === "agent-action-ack") {
    const r = await co._serialize(() => agentActionAck(co, a[0], a[1], a[2]));
    return jsonRes(r, r.ok ? 200 : 422);
  }

  return jsonRes({ ok: false, error: `co: unknown agent-action op '${op}'` }, 400);
}
