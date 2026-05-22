/* beads-runner/web/inbox/functions/api/expire.js — claude-tools-23r.
 *
 * The per-Item EXPIRE write proxy — the "this dossier is stale, get it out of
 * my way" affordance for the Inbox shell. NOT a §5.2 response (no decision,
 * no consequence application): it flips ONE Item from state=open to the §4.1
 * terminal `expired` (a legal sink for the §4.5 lane projection, already used
 * by T5.4's timed-fyi auto-proceed). The UI iterates over the dossier's open
 * items and calls this once per item; partial is first-class (AD7) — any item
 * that has already moved past `open` (e.g. answered/applied) is rejected by
 * the engine's stateCheck (open→expired only; dossier.js:527-533) and that
 * rejection is honestly surfaced, never papered over.
 *
 * Same §9.1 chokepoint discipline as ./respond: server-side bearer only; the
 * client bears no secret, never picks the principal, and never picks the
 * target state — this proxy hard-codes `expired`. The op `item-set-state` is
 * exposed to the Pages adapter for this single purpose (see cf/pages-dev/
 * adapter.js argsForPost).
 *
 * WRITE PATH IS NARROW BY CONSTRUCTION: only `onRequestPost` is exported, the
 * upstream op is the HARD-CODED literal `item-set-state`, and the target
 * state is the HARD-CODED literal `expired`. There is no op or state the
 * client can select. The renderer's deriveDossierView/§5.2 response shape is
 * untouched (§11): the §5.2 affordance set still does not include "expire";
 * this is an at-the-shell archive, not a per-Item response.
 *
 * BINDS INTERFACE.md v1: §9.1, §2.3, §4.1.1 (the Item state field), §4.1's
 * `expired` terminal state, §0.3 (the engine still rejects an unknown op or
 * an illegal transition).
 */

const COORDINATOR_OP = 'item-set-state'; // §4.1.1 state move — FROZEN here.
const TARGET_STATE = 'expired';          // §4.1 terminal — FROZEN here.

function json(body, status) {
  return new Response(JSON.stringify(body), {
    status: status || 200,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store'
    }
  });
}

export async function onRequestPost(context) {
  const env = context.env || {};
  const base = env.COORDINATOR_URL;
  const token = env.COORDINATOR_TOKEN;

  if (!base || !token) {
    return json(
      {
        ok: false,
        error:
          'Expire proxy not configured: COORDINATOR_URL / ' +
          'COORDINATOR_TOKEN bindings are required (server-side only — ' +
          '§9.1/§9.2). No item can be expired.'
      },
      503
    );
  }

  let payload;
  try {
    payload = await context.request.json();
  } catch (e) {
    return json({ ok: false, error: 'expire body must be JSON {dossier_id,item_id}' }, 400);
  }
  const dossierId = payload && typeof payload.dossier_id === 'string' ? payload.dossier_id.trim() : '';
  const itemId = payload && typeof payload.item_id === 'string' ? payload.item_id.trim() : '';
  if (!dossierId || !itemId) {
    return json({ ok: false, error: 'need {dossier_id,item_id} — ONE Item per call (mirrors respond.js AD7 partial shape)' }, 400);
  }

  const upstream = new URL(base.replace(/\/+$/, '') + '/request');
  upstream.searchParams.set('op', COORDINATOR_OP);

  let resp;
  try {
    resp = await fetch(upstream.toString(), {
      method: 'POST',
      headers: {
        authorization: 'Bearer ' + token,
        'content-type': 'application/json',
        accept: 'application/json'
      },
      body: JSON.stringify({ dossier_id: dossierId, item_id: itemId, state: TARGET_STATE })
    });
  } catch (e) {
    return json(
      {
        ok: false,
        error: 'Coordinator unreachable from the Expire proxy — your ' +
          'dismiss was NOT applied (honest, principle 4): ' +
          (e && e.message ? e.message : String(e))
      },
      502
    );
  }

  if (resp.status === 401 || resp.status === 403) {
    return json(
      { ok: false, error: 'Coordinator rejected the Inbox bearer token (§9.1) — expire NOT applied' },
      502
    );
  }

  const text = await resp.text();
  // Pass the Coordinator's outcome through verbatim. An illegal transition
  // (e.g. trying to expire an already-answered item) is a 422 from the engine
  // — surfaced honestly so the client can show "skipped: not in open state",
  // never a fabricated success.
  return new Response(text, {
    status: resp.ok ? 200 : 502,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store'
    }
  });
}
