/* beads-runner/web/functions/api/push/unsubscribe.js — N2 (claude-tools-uxg1).
 *
 * The Inbox PWA's Web-Push UNSUBSCRIBE proxy (sibling of ./subscribe.js).
 * DESIGN N §2.2: drop the stored PushSubscription when the user opts out (the
 * browser's pushManager.getSubscription().unsubscribe() path). The delivery
 * step ALSO prunes a 404/410 endpoint server-side; this is the explicit
 * user-initiated opt-out.
 *
 * Same §9.1 discipline: server-side bearer only; the client bears no secret and
 * never picks the op. Only `onRequestPost` is exported; the upstream op is the
 * HARD-CODED literal `push-unsubscribe` (adapter → handlePushOp [endpoint]).
 */

const COORDINATOR_OP = 'push-unsubscribe';

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
    return json(
      {
        ok: false,
        error:
          'Push unsubscribe proxy not configured: COORDINATOR_URL / COORDINATOR_TOKEN ' +
          'bindings are required (server-side only — §9.1/§9.2).'
      },
      503
    );
  }

  let payload;
  try {
    payload = await context.request.json();
  } catch (e) {
    return json({ ok: false, error: 'body must be JSON {endpoint}' }, 400);
  }
  const endpoint = payload && typeof payload.endpoint === 'string' ? payload.endpoint.trim() : '';
  if (!endpoint) return json({ ok: false, error: 'need {endpoint}' }, 400);

  const upstream = new URL(base.replace(/\/+$/, '') + '/request');
  upstream.searchParams.set('op', COORDINATOR_OP);

  let resp;
  try {
    resp = await fetch(upstream.toString(), {
      method: 'POST',
      headers: { authorization: 'Bearer ' + token, 'content-type': 'application/json', accept: 'application/json' },
      body: JSON.stringify({ endpoint: endpoint })
    });
  } catch (e) {
    return json(
      { ok: false, error: 'Coordinator unreachable from the push unsubscribe proxy: ' + (e && e.message ? e.message : String(e)) },
      502
    );
  }
  if (resp.status === 401 || resp.status === 403) {
    return json({ ok: false, error: 'Coordinator rejected the Inbox bearer token (§9.1)' }, 502);
  }
  const text = await resp.text();
  return new Response(text, {
    status: resp.ok ? 200 : 502,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }
  });
}
