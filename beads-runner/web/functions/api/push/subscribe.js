/* beads-runner/web/functions/api/push/subscribe.js — N2 (claude-tools-uxg1).
 *
 * The Inbox PWA's Web-Push SUBSCRIBE proxy — a Cloudflare Pages Function
 * (Appendix A realization; §0.2 — provider primitives are NON-NORMATIVE).
 * DESIGN N §2.2 part 2: store the browser's PushSubscription so the delivery
 * step (notif-deliver) can encrypt a push to it.
 *
 * Same §9.1 chokepoint discipline as inbox/respond.js: the browser holds NO
 * secret and never picks the principal/op (§9.1/§9.2). The PWA POSTs this
 * same-origin proxy with no credentials and the standard PushSubscription JSON
 * ({endpoint, keys:{p256dh, auth}}); the proxy attaches the server-only bearer
 * and calls the Coordinator's `/request?op=push-subscribe`, which the adapter
 * unwraps to handlePushOp's positional [endpoint, p256dh, auth]. The engine
 * (src/push.js) owns the store + the https/keys input gate; this proxy is a
 * thin, narrow passthrough.
 *
 * WRITE PATH IS NARROW BY CONSTRUCTION: only `onRequestPost` is exported and
 * the upstream op is the HARD-CODED literal `push-subscribe`. A subscription is
 * a TRANSIENT A.2 record (delivery plumbing) — NOT a §4 record, NO INTERFACE
 * §4.3 change. The push payload it enables is TRIAGE ONLY (principle 2).
 */

const COORDINATOR_OP = 'push-subscribe';

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
          'Push subscribe proxy not configured: COORDINATOR_URL / COORDINATOR_TOKEN ' +
          'bindings are required (server-side only — §9.1/§9.2). Cannot subscribe.'
      },
      503
    );
  }

  let payload;
  try {
    payload = await context.request.json();
  } catch (e) {
    return json({ ok: false, error: 'body must be a PushSubscription JSON {endpoint, keys:{p256dh, auth}}' }, 400);
  }
  // Accept either the standard PushSubscription.toJSON() shape ({endpoint,
  // keys:{p256dh,auth}}) or a flat {endpoint,p256dh,auth}.
  const endpoint = payload && typeof payload.endpoint === 'string' ? payload.endpoint.trim() : '';
  const keys = (payload && typeof payload.keys === 'object' && payload.keys) || payload || {};
  const p256dh = typeof keys.p256dh === 'string' ? keys.p256dh.trim() : '';
  const auth = typeof keys.auth === 'string' ? keys.auth.trim() : '';
  if (!endpoint || !p256dh || !auth) {
    return json({ ok: false, error: 'need {endpoint, keys:{p256dh, auth}} from PushManager.subscribe()' }, 400);
  }

  const upstream = new URL(base.replace(/\/+$/, '') + '/request');
  upstream.searchParams.set('op', COORDINATOR_OP);

  let resp;
  try {
    resp = await fetch(upstream.toString(), {
      method: 'POST',
      headers: { authorization: 'Bearer ' + token, 'content-type': 'application/json', accept: 'application/json' },
      body: JSON.stringify({ endpoint: endpoint, p256dh: p256dh, auth: auth })
    });
  } catch (e) {
    return json(
      { ok: false, error: 'Coordinator unreachable from the push subscribe proxy: ' + (e && e.message ? e.message : String(e)) },
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
