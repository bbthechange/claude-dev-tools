/* beads-runner/web/functions/api/control/agent-action.js — I4 (claude-tools-uxvi4).
 *
 * The Activity facet's STUCK-ACTION write proxy (design/agent-action.md §5). The
 * phone taps Nudge / Kill+retry / Kill+Gate on a maybe-stuck writer; this proxy
 * enqueues a host-effecting INTENT into the engine's transient `agent_actions`
 * queue. The daemon's agent-action-poll.sh then reconciles the host out-of-band
 * (drops the runner-honored control marker / runs gate-defer.sh). The web tier
 * NEVER signals a process directly — Local==remote; the GUI holds no host access
 * (the bgw/2dk lesson made literal).
 *
 * Same §9.1 chokepoint discipline as set-desired.js: the per-deployment bearer
 * lives server-side only (a Pages env binding); the browser holds no secret and
 * never picks the principal. The upstream op is the HARD-CODED literal
 * `agent-action`; no other op is reachable. `owner:"you"` is stamped HERE (§2.4 —
 * the GUI self-declares; an agent would pass owner:"agent:<hat>"), the client may
 * not override it.
 *
 * NARROW BY CONSTRUCTION: only `onRequestPost` is exported; only the THREE I4
 * intents are accepted (nudge / kill-retry / kill-gate). gate-apply / gate-lift
 * are J3's Gates-facet proxy — NOT reachable here. Escalate is NOT an agent-action
 * (it is a pure dossier write — see ./escalate.js). The engine still owns the
 * authoritative per-intent required-field gate; this is the cheap first gate.
 */

const COORDINATOR_OP = 'agent-action'; // FROZEN here — the client never selects the op.

// The THREE process intents the Activity facet owns (design/agent-action.md §7).
const ALLOWED_INTENTS = ['nudge', 'kill-retry', 'kill-gate'];

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
    return json({ ok: false, error: 'agent-action proxy not configured: COORDINATOR_URL / COORDINATOR_TOKEN bindings are required (server-side only — §9.1/§9.2).' }, 503);
  }

  let payload;
  try {
    payload = await context.request.json();
  } catch (e) {
    return json({ ok: false, error: 'request body must be JSON {intent, workspace, target:{...}, args?:{...}}' }, 400);
  }

  const intent = payload && typeof payload.intent === 'string' ? payload.intent.trim() : '';
  const workspace = payload && typeof payload.workspace === 'string' ? payload.workspace.trim() : '';
  const target = payload && payload.target && typeof payload.target === 'object' ? payload.target : {};
  const args = payload && payload.args && typeof payload.args === 'object' ? payload.args : {};

  if (ALLOWED_INTENTS.indexOf(intent) < 0) {
    // 422 — well-formed JSON, semantically invalid (the three Activity intents
    // are a frozen set here; gate-apply/gate-lift live behind the Gates facet).
    return json({ ok: false, error: 'intent must be one of ' + JSON.stringify(ALLOWED_INTENTS) + ' (gate-apply/gate-lift are the Gates facet; escalate is a dossier write)' }, 422);
  }
  if (!workspace) {
    return json({ ok: false, error: 'need workspace (the project_ref the daemon filters on)' }, 400);
  }
  if (!target.bead_ref || typeof target.bead_ref !== 'string') {
    return json({ ok: false, error: 'need target.bead_ref (the stuck worker\'s bead)' }, 400);
  }
  if (intent === 'kill-gate' && (!target.gate_id || !args.date)) {
    return json({ ok: false, error: 'kill-gate needs target.gate_id + args.date (gate-defer.sh apply couples the gate:<id> label with a defer date)' }, 422);
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
    return json({ ok: false, error: 'Coordinator unreachable from the agent-action proxy — the action was NOT enqueued (honest, principle 4): ' + (e && e.message ? e.message : String(e)) }, 502);
  }

  if (resp.status === 401 || resp.status === 403) {
    return json({ ok: false, error: 'Coordinator rejected the bearer token (§9.1) — action NOT enqueued' }, 502);
  }
  const text = await resp.text();
  // Pass the engine's outcome through verbatim. On success {ok:true, action_id};
  // the daemon picks it up on its next ~30s poll and reconciles the host.
  return new Response(text, {
    status: resp.ok ? 200 : 502,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }
  });
}
