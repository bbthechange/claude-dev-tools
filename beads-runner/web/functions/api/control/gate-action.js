/* beads-runner/web/functions/api/control/gate-action.js — J3 (claude-tools-uxvj3).
 *
 * The Gates facet's LABEL-mutating write proxy (design/agent-action.md §7). The
 * phone taps "lift gate" / "add a gate" on the /ws/<ref>/gates facet; this proxy
 * enqueues a host-effecting INTENT into the engine's transient `agent_actions`
 * queue. The daemon's agent-action-poll.sh then runs `gate-defer.sh apply/lift`
 * in the workspace out-of-band (it places/removes the `gate:<id>` label + the
 * coupled defer — the bd mutation the engine cannot do; Local==remote, the GUI
 * holds no host access — the bgw/2dk lesson made literal).
 *
 * WHY A SEPARATE PROXY FROM agent-action.js. The Activity facet's stuck-action
 * proxy (../agent-action.js) hard-allows ONLY the three I4 process intents
 * (nudge / kill-retry / kill-gate) and explicitly rejects gate-apply/gate-lift
 * ("gate-apply / gate-lift are J3's Gates-facet proxy"). This is that proxy: it
 * hard-allows ONLY the two LABEL intents. Both hit the SAME engine op
 * (`agent-action`) and the SAME closed-enum / per-intent-required-field gate in
 * cf/src/agent-action.js; splitting the proxies keeps each facet's reachable
 * intent set narrow-by-construction (the Board/Inbox proxy discipline). The
 * gate's WHY/UNBLOCK/SCOPE metadata is NOT set here — it is a pure engine write
 * the facet does directly against ../../ws/gate-meta (gate-meta-set); this proxy
 * is ONLY the label+defer mutation that needs the host (agent-action.md §3 #2).
 *
 * Same §9.1 chokepoint discipline as set-desired.js / agent-action.js: the
 * per-deployment bearer lives server-side only (a Pages env binding); the browser
 * holds no secret and never picks the principal. The upstream op is the
 * HARD-CODED literal `agent-action`; no other op is reachable. `owner:"you"` is
 * stamped HERE (§2.4 — the GUI self-declares; an agent would use gate-defer.sh
 * with owner:"agent:<hat>"), the client may not override it. The engine still
 * owns the authoritative per-intent required-field gate; this is the cheap first
 * gate (a clear 4xx BEFORE the round-trip).
 */

const COORDINATOR_OP = 'agent-action'; // FROZEN here — the client never selects the op.

// The TWO label intents the Gates facet owns (design/agent-action.md §7).
const ALLOWED_INTENTS = ['gate-apply', 'gate-lift'];

function json(body, status) {
  return new Response(JSON.stringify(body), {
    status: status || 200,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }
  });
}

export async function onRequestPost(context) {
  const env = context.env || {};
  const base = env.COORDINATOR_URL;
  const token = env.COORDINATOR_TOKEN;
  if (!base || !token) {
    return json({ ok: false, error: 'gate-action proxy not configured: COORDINATOR_URL / COORDINATOR_TOKEN bindings are required (server-side only — §9.1/§9.2).' }, 503);
  }

  let payload;
  try {
    payload = await context.request.json();
  } catch (e) {
    return json({ ok: false, error: 'request body must be JSON {intent, workspace, target:{...}, args?:{...}}' }, 400);
  }

  const intent = payload && typeof payload.intent === 'string' ? payload.intent.trim() : '';
  const workspace = payload && typeof payload.workspace === 'string' ? payload.workspace.trim() : '';
  const target = payload && payload.target && typeof payload.target === 'object' && !Array.isArray(payload.target) ? payload.target : {};
  const args = payload && payload.args && typeof payload.args === 'object' && !Array.isArray(payload.args) ? payload.args : {};

  if (ALLOWED_INTENTS.indexOf(intent) < 0) {
    // 422 — well-formed JSON, semantically invalid (the two Gates intents are a
    // frozen set here; nudge/kill-* live behind the Activity facet's proxy).
    return json({ ok: false, error: 'intent must be one of ' + JSON.stringify(ALLOWED_INTENTS) + ' (nudge/kill-retry/kill-gate are the Activity facet; gate metadata is gate-meta-set, not an action)' }, 422);
  }
  if (!workspace) {
    return json({ ok: false, error: 'need workspace (the project_ref the daemon filters on)' }, 400);
  }
  // The BARE gate id (gate-defer.sh builds the gate:<id> label itself). Both
  // intents need it; gate-apply additionally needs a target bead + a defer date.
  if (typeof target.gate_id !== 'string' || !/^[a-z0-9][a-z0-9-]*$/.test(target.gate_id)) {
    return json({ ok: false, error: 'need a valid target.gate_id (the BARE id — lowercase letters, digits, hyphens; gate-defer builds the gate:<id> label)' }, 422);
  }
  if (intent === 'gate-apply') {
    const hasOne = typeof target.bead_ref === 'string' && target.bead_ref.length > 0;
    const hasMany = Array.isArray(target.bead_refs) && target.bead_refs.some((x) => typeof x === 'string' && x.length > 0);
    if (!hasOne && !hasMany) {
      return json({ ok: false, error: 'gate-apply needs target.bead_ref or a non-empty target.bead_refs[] (the task(s) to hold)' }, 422);
    }
    if (typeof args.date !== 'string' || !args.date) {
      return json({ ok: false, error: 'gate-apply needs args.date (gate-defer.sh apply couples the gate:<id> label with a defer date — use a far-future sentinel for "indefinite until lifted")' }, 422);
    }
  }

  // The §2.3 authed channel: the proxy bears the token; the Coordinator's one
  // §9.1 chokepoint validates it and resolves the constant principal. owner is
  // stamped server-side (§2.4) — the GUI is "you"; the client cannot pick it.
  const upstream = new URL(base.replace(/\/+$/, '') + '/request');
  upstream.searchParams.set('op', COORDINATOR_OP);

  let resp;
  try {
    resp = await fetch(upstream.toString(), {
      method: 'POST',
      headers: { authorization: 'Bearer ' + token, 'content-type': 'application/json', accept: 'application/json' },
      body: JSON.stringify({
        action: { intent, workspace, target, args, owner: 'you' }
      })
    });
  } catch (e) {
    return json({ ok: false, error: 'Coordinator unreachable from the gate-action proxy — the action was NOT enqueued (honest, principle 4): ' + (e && e.message ? e.message : String(e)) }, 502);
  }

  if (resp.status === 401 || resp.status === 403) {
    return json({ ok: false, error: 'Coordinator rejected the bearer token (§9.1) — action NOT enqueued' }, 502);
  }
  const text = await resp.text();
  // Pass the engine's outcome through verbatim. On success {ok:true, action_id};
  // the daemon picks it up on its next ~30s poll and runs gate-defer.sh.
  return new Response(text, {
    status: resp.ok ? 200 : 502,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }
  });
}
