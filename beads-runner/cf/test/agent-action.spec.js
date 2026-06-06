// I4 (claude-tools-uxvi4) — design/agent-action.md §2/§3 DIFFERENTIAL conformance.
//
// Exercises the REAL engine (Worker → §9.1 chokepoint → singleton single-threaded
// Coordinator DO → D1) via SELF.fetch under the SAME workerd+miniflare runtime
// `wrangler dev` uses, NO Cloudflare account. Proves the control-plane queue:
//   • enqueue: a valid intent round-trips to a pending agent_actions row;
//   • the closed intent enum + per-intent required fields reject (422, NOTHING written);
//   • the daemon read (agent-action-pending) returns parsed pending rows, scoped;
//   • the daemon ack (agent-action-ack) flips status terminal + drops it from pending;
//   • owner is a DECLARED input (§2.4), preserved verbatim;
//   • ANTI-DRIFT: agent_actions is NOT a §4 record (put unknown_type; never in records);
//   • AUTH: the §9.1 chokepoint rejects a no-bearer hit BEFORE any write.

import { env, SELF } from "cloudflare:test";
import { it, expect } from "vitest";

const GOOD = "bearer-runner-secret-xyz";

let PASS = 0;
let FAIL = 0;
const fails = [];
function ck(name, cond) {
  if (cond) {
    PASS++;
    // eslint-disable-next-line no-console
    console.log(`  ✓ ${name}`);
  } else {
    FAIL++;
    fails.push(name);
    // eslint-disable-next-line no-console
    console.log(`  ✗ ${name}`);
  }
}

function authReq(bearer, op, args) {
  const headers = { "content-type": "application/json" };
  if (bearer !== null) headers["authorization"] = `Bearer ${bearer}`;
  return new Request("https://coordinator.local/", {
    method: "POST",
    headers,
    body: JSON.stringify({ op, args: args || [] }),
  });
}
async function call(bearer, op, args) {
  const res = await SELF.fetch(authReq(bearer, op, args));
  const ct = res.headers.get("content-type") || "";
  const raw = await res.text();
  let body = null;
  if (ct.includes("application/json")) {
    try {
      body = JSON.parse(raw);
    } catch {
      body = null;
    }
  }
  return { status: res.status, raw, body };
}

// A well-formed envelope; overlay overrides (undefined deletes the key).
function envelope(overrides) {
  const base = {
    intent: "nudge",
    workspace: "rhythmGame",
    target: { bead_ref: "rhythmGame-93o" },
    args: { reason: "poke the watchdog" },
    owner: "you",
  };
  return JSON.stringify({ ...base, ...overrides });
}
async function enqueue(bearer, env_) {
  return call(bearer, "agent-action", [env_]);
}
async function pending(bearer, ws) {
  return call(bearer, "agent-action-pending", ws === undefined ? [] : [ws]);
}
async function ack(bearer, id, status, result) {
  const a = [id, status];
  if (result !== undefined) a.push(result);
  return call(bearer, "agent-action-ack", a);
}

async function rowCount() {
  try {
    const r = await env.DB.prepare("SELECT COUNT(*) AS n FROM agent_actions").first();
    return r ? r.n : 0;
  } catch {
    return 0; // table not lazily created yet ⇒ empty
  }
}
async function freshStore() {
  try {
    await env.DB.prepare("DELETE FROM agent_actions").run();
  } catch {
    /* not created yet = already empty */
  }
}

// ════════════════════════════════════════════════════════════════════════════
it("I4 agent-action queue is contract-faithful to design/agent-action.md §2/§3", async () => {
  await freshStore();

  // ── ENQUEUE round-trips to a pending row ───────────────────────────────────
  const r = await enqueue(GOOD, envelope({}));
  ck("a valid nudge enqueues ⇒ 200 {ok:true, action_id}", r.status === 200 && r.body && r.body.ok === true && typeof r.body.action_id === "string" && r.body.action_id.length > 0);
  const id = r.body && r.body.action_id;

  const row = await env.DB.prepare(
    "SELECT action_id, workspace, intent, target_json, args_json, status, owner, requested_at, acked_at FROM agent_actions WHERE action_id = ?"
  )
    .bind(id)
    .first();
  ck("the row landed in the agent_actions namespace", !!row);
  ck("status is 'pending'", row && row.status === "pending");
  ck("intent preserved", row && row.intent === "nudge");
  ck("workspace denorm column preserved (the daemon filters on it)", row && row.workspace === "rhythmGame");
  ck("owner is the DECLARED input, preserved verbatim (§2.4)", row && row.owner === "you");
  ck("requested_at stamped (RFC-3339 Z)", row && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(row.requested_at));
  ck("acked_at is null until the daemon acks", row && (row.acked_at === null || row.acked_at === undefined));
  ck("target_json carries the bead_ref", row && JSON.parse(row.target_json).bead_ref === "rhythmGame-93o");

  // ── agent-action-pending: the daemon read, scoped + parsed ─────────────────
  const p = await pending(GOOD, "rhythmGame");
  ck("agent-action-pending ⇒ 200 {actions:[...]}", p.status === 200 && p.body && Array.isArray(p.body.actions));
  ck("pending surfaces the enqueued action", p.body && p.body.actions.length === 1 && p.body.actions[0].action_id === id);
  ck("pending parses target back to an object", p.body && p.body.actions[0].target && p.body.actions[0].target.bead_ref === "rhythmGame-93o");
  ck("pending parses args back to an object", p.body && p.body.actions[0].args && p.body.actions[0].args.reason === "poke the watchdog");

  const pOther = await pending(GOOD, "someOtherWs");
  ck("pending is workspace-scoped (other workspace ⇒ empty)", pOther.body && pOther.body.actions.length === 0);

  // ── agent-action-ack: terminal status drops it from pending ────────────────
  const ak = await ack(GOOD, id, "done", JSON.stringify({ ok: true, message: "nudged" }));
  ck("agent-action-ack(done) ⇒ 200 {ok:true}", ak.status === 200 && ak.body && ak.body.ok === true);
  const after = await env.DB.prepare("SELECT status, acked_at, result_json FROM agent_actions WHERE action_id = ?").bind(id).first();
  ck("status flipped to 'done'", after && after.status === "done");
  ck("acked_at stamped", after && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(after.acked_at));
  ck("result_json stored", after && after.result_json && JSON.parse(after.result_json).message === "nudged");
  const pAfter = await pending(GOOD, "rhythmGame");
  ck("acked action no longer returned by pending", pAfter.body && pAfter.body.actions.length === 0);

  const akMissing = await ack(GOOD, "no-such-id", "done");
  ck("ack of an unknown action_id ⇒ {ok:false}, never a throw", akMissing.status === 422 && akMissing.body && akMissing.body.ok === false);

  // ── per-intent + enum REJECTIONS (422, NOTHING written) ────────────────────
  const rejects = async (e) => {
    const before = await rowCount();
    const res = await enqueue(GOOD, e);
    const afterN = await rowCount();
    return res.status === 422 && res.body && res.body.ok === false && before === afterN;
  };
  ck("intent not in the closed enum ⇒ rejected", await rejects(envelope({ intent: "escalate" })));
  ck("escalate is NOT an agent-action (it's a dossier write) — rejected", await rejects(envelope({ intent: "gate-meta-set" })));
  ck("missing workspace ⇒ rejected", await rejects(envelope({ workspace: undefined })));
  ck("unsafe workspace (path traversal) ⇒ rejected", await rejects(envelope({ workspace: "../etc" })));
  ck("nudge missing target.bead_ref ⇒ rejected", await rejects(envelope({ intent: "nudge", target: {} })));
  ck("kill-retry missing target.bead_ref ⇒ rejected", await rejects(envelope({ intent: "kill-retry", target: {} })));
  ck("kill-gate missing gate_id ⇒ rejected", await rejects(envelope({ intent: "kill-gate", target: { bead_ref: "x-1" }, args: { date: "2030-01-01" } })));
  ck("kill-gate missing args.date ⇒ rejected", await rejects(envelope({ intent: "kill-gate", target: { bead_ref: "x-1", gate_id: "g1" }, args: {} })));
  ck("gate-apply missing bead_ref AND bead_refs ⇒ rejected", await rejects(envelope({ intent: "gate-apply", target: { gate_id: "g1" }, args: { date: "2030-01-01" } })));
  ck("gate-lift missing gate_id ⇒ rejected", await rejects(envelope({ intent: "gate-lift", target: {} })));
  ck("invalid JSON envelope ⇒ rejected", await rejects("{not-json"));
  ck("empty envelope arg ⇒ rejected", await rejects(""));

  // ── the well-formed gate intents ENQUEUE (J3's enum cases) ─────────────────
  await freshStore();
  const kg = await enqueue(GOOD, envelope({ intent: "kill-gate", target: { bead_ref: "x-1", gate_id: "g1" }, args: { date: "2030-01-01" } }));
  ck("kill-gate with bead_ref+gate_id+date enqueues", kg.status === 200 && kg.body.ok === true);
  const ga = await enqueue(GOOD, envelope({ intent: "gate-apply", target: { gate_id: "g1", bead_refs: ["x-1", "x-2"] }, args: { date: "2030-01-01" } }));
  ck("gate-apply with a bead_refs[] cohort enqueues", ga.status === 200 && ga.body.ok === true);
  const gl = await enqueue(GOOD, envelope({ intent: "gate-lift", target: { gate_id: "g1" }, args: {} }));
  ck("gate-lift with gate_id (no date needed) enqueues", gl.status === 200 && gl.body.ok === true);

  // ── set-desired intent (claude-tools-y6j9, local-first desired-state) ───────
  // The cloud→runner change-request: the daemon consumes it and applies the
  // requested state to the LOCAL .co-store/runner_state.desired. args.state must
  // be the §4.2 wire enum; target carries NO bead_ref (acts on the runner loop).
  await freshStore();
  for (const st of ["running", "paused", "spare-cycles", "stopped"]) {
    const sd = await enqueue(GOOD, envelope({ intent: "set-desired", target: {}, args: { state: st } }));
    ck(`set-desired args.state='${st}' enqueues ⇒ 200`, sd.status === 200 && sd.body && sd.body.ok === true);
    const sdRow = await env.DB.prepare("SELECT intent, args_json FROM agent_actions WHERE action_id = ?").bind(sd.body && sd.body.action_id).first();
    ck(`set-desired '${st}' row preserves intent + args.state`, sdRow && sdRow.intent === "set-desired" && JSON.parse(sdRow.args_json).state === st);
  }
  const sdPend = await pending(GOOD, "rhythmGame");
  ck("pending surfaces set-desired with args.state intact", sdPend.body && sdPend.body.actions.some((a) => a.intent === "set-desired" && a.args && a.args.state === "stopped"));
  ck("set-desired missing args.state ⇒ rejected", await rejects(envelope({ intent: "set-desired", target: {}, args: {} })));
  ck("set-desired bad args.state ⇒ rejected", await rejects(envelope({ intent: "set-desired", target: {}, args: { state: "halt" } })));
  ck("set-desired UI 'spare-only' (un-normalized) ⇒ rejected (proxy must map to spare-cycles)", await rejects(envelope({ intent: "set-desired", target: {}, args: { state: "spare-only" } })));
  ck("set-desired still requires a safe workspace", await rejects(envelope({ intent: "set-desired", workspace: "../etc", target: {}, args: { state: "paused" } })));

  // ── owner default + agent-declared owner ───────────────────────────────────
  await freshStore();
  const noOwner = await enqueue(GOOD, envelope({ owner: undefined }));
  const ownerRow = await env.DB.prepare("SELECT owner FROM agent_actions WHERE action_id = ?").bind(noOwner.body.action_id).first();
  ck("owner defaults to 'you' when absent (the GUI is the primary caller)", ownerRow && ownerRow.owner === "you");
  const agentOwner = await enqueue(GOOD, envelope({ owner: "agent:reconciler" }));
  const agentRow = await env.DB.prepare("SELECT owner FROM agent_actions WHERE action_id = ?").bind(agentOwner.body.action_id).first();
  ck("an agent self-declares owner:'agent:<hat>' (§2.4)", agentRow && agentRow.owner === "agent:reconciler");

  // ── ANTI-DRIFT: agent_actions is NOT a §4 record ───────────────────────────
  const put = await call(GOOD, "put", ["agent_actions", "x-1", JSON.stringify({ id: "x-1" })]);
  ck("put agent_actions ... ⇒ unknown_type (never a §4 record)", put.status >= 400 || (put.body && put.body.ok === false));
  const rec = await env.DB.prepare("SELECT COUNT(*) AS n FROM records WHERE type = 'agent_actions'").first().catch(() => ({ n: 0 }));
  ck("the records table never sees an agent_actions row", rec && rec.n === 0);

  // ── AUTH: the §9.1 chokepoint rejects a no-bearer hit BEFORE any write ──────
  await freshStore();
  const noAuth = await enqueue(null, envelope({}));
  ck("no bearer ⇒ 401 at the §9.1 chokepoint", noAuth.status === 401);
  ck("no-bearer hit wrote NOTHING", (await rowCount()) === 0);

  if (FAIL > 0) console.log(`agent-action FAILURES: ${fails.join(" | ")}`);
  expect(FAIL, `${FAIL} agent-action checks failed`).toBe(0);
  expect(PASS).toBeGreaterThan(30);
});
