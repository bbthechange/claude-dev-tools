/* beads-runner/web/functions/api/cross-ws/relay.js — K2 (claude-tools-uxvk2).
 *
 * The Cross-WS view's RELAY-LOG read proxy — DESIGN K §6.2, Flow K. The
 * `/cross-ws` view (K5) renders the auditable trail of cross-workspace
 * exchanges behind the batched FYIs (K3). This proxy is the read seam: it
 * returns the engine's `relay-log-tail` B.3 projection ({exchanges:[...]}).
 *
 * WHY THIS EXISTS — the §9.1 chokepoint, Cross-WS side. The browser MUST NOT
 * hold the per-deployment bearer (§9.2); it calls this same-origin proxy with
 * no credentials, the proxy attaches the server-only bearer (a Pages env
 * binding), and the Coordinator resolves the constant principal (C7). Same
 * discipline as the Board read proxy (board/index.js).
 *
 * NO WRITE PATH FROM A READER — BY CONSTRUCTION (§4.5): only `onRequestGet` is
 * exported (POST/PUT/PATCH/DELETE hit the Pages default 405), and the upstream
 * op is the HARD-CODED literal `relay-log-tail`. The client cannot select an
 * op or reach the append/any write verb; the only client-supplied inputs are
 * the optional read filters `project_ref` (scope to one workspace's outbound
 * asks; omit ⇒ the global cross-WS log) and `n` (row cap).
 *
 * BINDS INTERFACE.md v1 + UX-V2-ARCHITECTURE.md: §9.1 (the one chokepoint,
 * token server-side), §2.3 (authed channel), B.3 (the relay-log-tail
 * projection shape — passed through VERBATIM), B.4 (render tolerance lives in
 * the view; the proxy never rewrites the body).
 */

const COORDINATOR_OP = 'relay-log-tail'; // B.3 read-only projection — FROZEN here.

function json(body, status) {
  return new Response(JSON.stringify(body), {
    status: status || 200,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'x-cross-ws-read-only': 'true'
    }
  });
}

export async function onRequestGet(context) {
  const env = context.env || {};
  const base = env.COORDINATOR_URL;
  const token = env.COORDINATOR_TOKEN; // §9.2-family server secret (Pages binding)

  if (!base || !token) {
    return json(
      {
        ok: false,
        error:
          'Cross-WS relay read proxy not configured: COORDINATOR_URL / ' +
          'COORDINATOR_TOKEN bindings are required (the per-deployment bearer ' +
          'lives server-side only — §9.1/§9.2). No relay log can be served.'
      },
      503
    );
  }

  // Optional read-only filters. `project_ref` scopes to one workspace's
  // outbound asks (B.3 / DESIGN K §3.3); omitting it returns the cross-WS log
  // across all workspaces. `n` caps the rows. Both are READ filters on the
  // §4.5-style producer, never write selectors.
  const url = new URL(context.request.url);
  const projectRef = (url.searchParams.get('project_ref') || '').trim();
  const n = (url.searchParams.get('n') || '').trim();

  const upstream = new URL(base.replace(/\/+$/, '') + '/request');
  upstream.searchParams.set('op', COORDINATOR_OP);
  if (projectRef) upstream.searchParams.set('project_ref', projectRef);
  if (n) upstream.searchParams.set('n', n);

  let resp;
  try {
    resp = await fetch(upstream.toString(), {
      method: 'GET', // read only — no body, no mutation verb
      headers: {
        authorization: 'Bearer ' + token,
        accept: 'application/json'
      }
    });
  } catch (e) {
    return json(
      {
        ok: false,
        error:
          'Coordinator unreachable from the Cross-WS relay read proxy: ' +
          (e && e.message ? e.message : String(e))
      },
      502
    );
  }

  if (resp.status === 401 || resp.status === 403) {
    return json(
      { ok: false, error: 'Coordinator rejected the Cross-WS bearer token (§9.1)' },
      502
    );
  }

  const text = await resp.text();
  // Pass the B.3 projection body through VERBATIM. Tolerance (B.4) lives in the
  // view-model, not here; the proxy never best-effort-rewrites the shape.
  return new Response(text, {
    status: resp.ok ? 200 : 502,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'x-cross-ws-read-only': 'true'
    }
  });
}
