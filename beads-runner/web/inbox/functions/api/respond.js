/* beads-runner/web/inbox/functions/api/respond.js — T6b (claude-tools-xre).
 *
 * The per-Item RESPONSE write proxy — the ONE legitimate write path T6b
 * OWNS: the decision surface (Flow B step 4, "the doc IS the form"). It is
 * NOT a Dolt writer and NOT a consequence applier. It carries one §5.2
 * `response` for ONE Item to the Coordinator's idempotent per-Item applier
 * (T5 `do_item_apply`, op pinned `item-apply`), which owns §5.2.2
 * deterministic-vs-reconciler routing, the §7.4 per-Item idempotency latch,
 * and the S-2 control→work reconcile back into beads. The UI submits a
 * response; it never applies one (anti-drift: presentation only, control
 * logic is T5).
 *
 * Same §9.1 chokepoint discipline: server-side bearer only; the client bears
 * no secret and never picks the principal — §9.1 stamps the resolved
 * PRINCIPAL_V1 on the response record (the client MUST NOT send a principal;
 * if it does, it is ignored — the chokepoint is authoritative, C4 seam).
 *
 * PARTIAL by construction (AD7): exactly ONE {dossier_id,item_id,response}
 * per call. Unanswered siblings are simply never sent — they block nothing
 * (§4.1 rollup is informational, never a gate). The §7.4 per-Item latch makes
 * a double-tap / retry of the SAME item exactly-once on the Coordinator side;
 * this proxy therefore stays a thin, idempotent passthrough.
 *
 * WRITE PATH IS NARROW BY CONSTRUCTION: only `onRequestPost` is exported and
 * the upstream op is the HARD-CODED literal `item-apply`. There is no op the
 * client can select; no set-desired/heartbeat/lease/forensic/put verb is
 * reachable; nothing here writes Dolt (Dolt stays work-truth — the Coordinator
 * reconciles control→work, S-2; the Board/Inbox never lie under Dolt lag).
 *
 * BINDS INTERFACE.md v1: §9.1, §2.3, §5.2 (the response shape), §5.2.2
 * (deterministic vs reconciler — applied by T5, not here), §7.4 (per-Item
 * idempotency — enforced by T5), §4.1.1 (the Item record T5 mutates).
 */

const COORDINATOR_OP = 'item-apply'; // §5.2.2/§7.4 per-Item applier — FROZEN.

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
          'Response proxy not configured: COORDINATOR_URL / ' +
          'COORDINATOR_TOKEN bindings are required (server-side only — ' +
          '§9.1/§9.2). No response can be submitted.'
      },
      503
    );
  }

  let payload;
  try {
    payload = await context.request.json();
  } catch (e) {
    return json({ ok: false, error: 'response body must be JSON {dossier_id,item_id,response}' }, 400);
  }
  const dossierId = payload && typeof payload.dossier_id === 'string' ? payload.dossier_id.trim() : '';
  const itemId = payload && typeof payload.item_id === 'string' ? payload.item_id.trim() : '';
  const response = payload && payload.response;
  if (!dossierId || !itemId || !response || typeof response !== 'object') {
    return json({ ok: false, error: 'need {dossier_id,item_id,response:{…}} — exactly ONE Item per call (AD7 partial)' }, 400);
  }
  // The client never picks the principal (§9.1). Strip any client-sent one so
  // the chokepoint stays the sole authority (defensive — C4 seam).
  if ('principal' in response) delete response.principal;

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
      body: JSON.stringify({ dossier_id: dossierId, item_id: itemId, response: response })
    });
  } catch (e) {
    return json(
      {
        ok: false,
        error: 'Coordinator unreachable from the Response proxy — your ' +
          'response was NOT applied (honest, principle 4): ' +
          (e && e.message ? e.message : String(e))
      },
      502
    );
  }

  if (resp.status === 401 || resp.status === 403) {
    return json(
      { ok: false, error: 'Coordinator rejected the Inbox bearer token (§9.1) — response NOT applied' },
      502
    );
  }

  const text = await resp.text();
  // Pass the Coordinator's apply outcome through verbatim (it reports
  // deterministic-applied vs reconciler-dispatched per §5.2.2). The client
  // re-fetches the §4 Dossier to render the honest, latch-true ack (S-2).
  return new Response(text, {
    status: resp.ok ? 200 : 502,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store'
    }
  });
}
