/* beads-runner/web/functions/api/inbox/dossier.js — T6b (claude-tools-xre).
 *
 * The Dossier READ proxy — fetches the ONE §4.1 Dossier RECORD a
 * WAITING-ON-YOU lane row points at, so the Inbox can render the §5
 * `body`⊃`items[]` (the dossier is the projection's referenced unit — EXIT
 * crit 3 "reads only the Coordinator projection"). Same §9.1 chokepoint
 * discipline as ./inbox: server-side bearer only, client never picks the
 * principal; ONE pinned op.
 *
 * READ ONLY, BY CONSTRUCTION: only `onRequestGet` is exported and the
 * upstream op is the HARD-CODED literal `get` with the HARD-CODED record
 * type `dossier`. The client supplies only an opaque dossier `id` (a read
 * selector, never a write verb, never a second op). The Coordinator's §0.3
 * reject-unknown-higher applies on its side; this proxy passes the record
 * through verbatim for inbox-view.js to bind/refuse.
 *
 * BINDS INTERFACE.md v1: §9.1, §2.3, §4.1 (the stored Dossier envelope —
 * read), §5 (the body⊃items[] the renderer binds), §0.3.
 */

const COORDINATOR_OP = 'get';            // §4 store read — FROZEN here.
const RECORD_TYPE = 'dossier';           // the §4.1 record type — FROZEN here.

function json(body, status) {
  return new Response(JSON.stringify(body), {
    status: status || 200,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'x-inbox-read-only': 'true'
    }
  });
}

export async function onRequestGet(context) {
  const env = context.env || {};
  const base = env.COORDINATOR_URL;
  const token = env.COORDINATOR_TOKEN;

  if (!base || !token) {
    return json(
      {
        ok: false,
        error:
          'Dossier read proxy not configured: COORDINATOR_URL / ' +
          'COORDINATOR_TOKEN bindings are required (server-side only — ' +
          '§9.1/§9.2). No dossier can be served.'
      },
      503
    );
  }

  const url = new URL(context.request.url);
  const id = (url.searchParams.get('id') || '').trim();
  if (!id) {
    return json({ ok: false, error: 'dossier read needs ?id=<dossier_ref> (the §4.5 lane pointer)' }, 400);
  }

  const upstream = new URL(base.replace(/\/+$/, '') + '/request');
  upstream.searchParams.set('op', COORDINATOR_OP);
  upstream.searchParams.set('type', RECORD_TYPE);
  upstream.searchParams.set('id', id);

  let resp;
  try {
    resp = await fetch(upstream.toString(), {
      method: 'GET', // read only
      headers: { authorization: 'Bearer ' + token, accept: 'application/json' }
    });
  } catch (e) {
    return json(
      {
        ok: false,
        error: 'Coordinator unreachable from the Dossier read proxy: ' +
          (e && e.message ? e.message : String(e))
      },
      502
    );
  }

  if (resp.status === 401 || resp.status === 403) {
    return json(
      { ok: false, error: 'Coordinator rejected the Inbox bearer token (§9.1)' },
      502
    );
  }
  if (resp.status === 404) {
    return json({ ok: false, error: 'Dossier ' + id + ' not found (or not for this principal — the §9.1 chokepoint collapses 401 and absent; C4 seam)' }, 404);
  }

  const text = await resp.text();
  return new Response(text, {
    status: resp.ok ? 200 : 502,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'x-inbox-read-only': 'true'
    }
  });
}
