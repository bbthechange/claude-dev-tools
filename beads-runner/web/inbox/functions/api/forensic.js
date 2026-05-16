/* beads-runner/web/inbox/functions/api/forensic.js — T6b (claude-tools-xre).
 *
 * The Flow-G tier-3 FORENSIC proxy (§10.3). Forensic content is the single
 * controlled crossing of the sync boundary: raw stream-json holds file
 * contents + model output and NEVER rides the beads sync; it is redacted AT
 * the runner before transit (§10.2) and stored encrypted, ciphertext-only,
 * server-side, hard-deleted at the EARLIER of its TTL (FORENSIC_BLOB_TTL) or
 * an explicit user dismiss (§10.3). It is NEVER in the §4.5 projection, NEVER
 * auto-fetched, NEVER in a notify/digest body (principle 2). This proxy is
 * the explicit, authed, ON-DEMAND pull the human triggers — and the explicit
 * dismiss ("done with forensic" ⇒ hard-delete now).
 *
 * Same §9.1 chokepoint: server-side bearer only; client never picks the
 * principal. The decrypted redacted blob crosses the §2.3 authed channel; the
 * key is NEVER exposed to the client (§10.3).
 *
 * ONE op per method, each HARD-CODED (the Board/Inbox proxy discipline):
 *   • GET  → `forensic-fetch`   (§10.3 explicit on-demand authed pull)
 *   • POST → `forensic-dismiss` (§10.3 "done with forensic" ⇒ hard-delete;
 *            idempotent — dismissing an absent/already-gone blob is success)
 * No put/sweep/audit op is reachable (sweep is the Coordinator's TTL
 * poll-fallback, not a client action). No Dolt path.
 *
 * BINDS INTERFACE.md v1: §9.1, §2.3, §10.2 (redacted-at-runner shape — opaque
 * here), §10.3 (TTL/dismiss/encrypt/fetch contract).
 */

const OP_FETCH = 'forensic-fetch';     // §10.3 on-demand pull — FROZEN here.
const OP_DISMISS = 'forensic-dismiss'; // §10.3 hard-delete now — FROZEN here.

function json(body, status) {
  return new Response(JSON.stringify(body), {
    status: status || 200,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      // Forensic content must never be cached client- or edge-side (§10.3
      // delete = irrecoverable; a cached copy would defeat the TTL/dismiss).
      'cache-control': 'no-store',
      'x-forensic': 'redacted-transient'
    }
  });
}

function guard(env) {
  if (!env.COORDINATOR_URL || !env.COORDINATOR_TOKEN) {
    return json(
      {
        ok: false,
        error:
          'Forensic proxy not configured: COORDINATOR_URL / ' +
          'COORDINATOR_TOKEN bindings are required (server-side only — ' +
          '§9.1/§9.2). No forensic blob can be fetched or dismissed.'
      },
      503
    );
  }
  return null;
}

export async function onRequestGet(context) {
  const env = context.env || {};
  const g = guard(env);
  if (g) return g;

  const url = new URL(context.request.url);
  const id = (url.searchParams.get('id') || '').trim();
  if (!id) return json({ ok: false, error: 'forensic fetch needs ?id=<blob_id> (§10.3 explicit pull)' }, 400);

  const upstream = new URL(env.COORDINATOR_URL.replace(/\/+$/, '') + '/request');
  upstream.searchParams.set('op', OP_FETCH);
  upstream.searchParams.set('id', id);

  let resp;
  try {
    resp = await fetch(upstream.toString(), {
      method: 'GET',
      headers: { authorization: 'Bearer ' + env.COORDINATOR_TOKEN, accept: 'application/json' }
    });
  } catch (e) {
    return json({ ok: false, error: 'Coordinator unreachable from the Forensic proxy: ' + (e && e.message ? e.message : String(e)) }, 502);
  }
  if (resp.status === 401 || resp.status === 403) {
    return json({ ok: false, error: 'Coordinator rejected the Inbox bearer token (§9.1)' }, 502);
  }
  if (resp.status === 404 || resp.status === 410) {
    // §10.3: a destroyed/expired blob is irrecoverable — there is no
    // fetchable tombstone. Honest, not masked.
    return json({ ok: false, error: 'Forensic blob ' + id + ' is gone — past its TTL or dismissed (§10.3: delete is irrecoverable, no tombstone)' }, 410);
  }

  const text = await resp.text();
  return new Response(text, {
    status: resp.ok ? 200 : 502,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'x-forensic': 'redacted-transient'
    }
  });
}

export async function onRequestPost(context) {
  const env = context.env || {};
  const g = guard(env);
  if (g) return g;

  let payload;
  try { payload = await context.request.json(); }
  catch (e) { return json({ ok: false, error: 'dismiss body must be JSON {id}' }, 400); }
  const id = payload && typeof payload.id === 'string' ? payload.id.trim() : '';
  if (!id) return json({ ok: false, error: 'forensic dismiss needs {id} (§10.3 "done with forensic" ⇒ hard-delete)' }, 400);

  const upstream = new URL(env.COORDINATOR_URL.replace(/\/+$/, '') + '/request');
  upstream.searchParams.set('op', OP_DISMISS);

  let resp;
  try {
    resp = await fetch(upstream.toString(), {
      method: 'POST',
      headers: {
        authorization: 'Bearer ' + env.COORDINATOR_TOKEN,
        'content-type': 'application/json',
        accept: 'application/json'
      },
      body: JSON.stringify({ id: id })
    });
  } catch (e) {
    return json({ ok: false, error: 'Coordinator unreachable from the Forensic proxy: ' + (e && e.message ? e.message : String(e)) }, 502);
  }
  if (resp.status === 401 || resp.status === 403) {
    return json({ ok: false, error: 'Coordinator rejected the Inbox bearer token (§9.1)' }, 502);
  }

  const text = await resp.text();
  return new Response(text, {
    status: resp.ok ? 200 : 502,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'x-forensic': 'redacted-transient'
    }
  });
}
