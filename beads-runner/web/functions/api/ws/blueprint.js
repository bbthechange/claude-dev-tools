/* beads-runner/web/functions/api/ws/blueprint.js — H1 (claude-tools-uxvh1).
 *
 * The Blueprint facet's READ proxy — DESIGN H (design/blueprint.md §2.2), Flow
 * H. The Blueprint facet (H3, /ws/<ref>/blueprint) fetches the whole map body
 * on demand via this proxy (the hub snapshot carries only the thumbnail-sized
 * `blueprint_meta`, never the full map — §8.1). This is the SAME §9.1-
 * disciplined seam every facet proxy uses (board/index.js, ws/gate-meta.js).
 *
 * WHY THIS EXISTS — the §9.1 chokepoint. The browser MUST NOT hold the
 * per-deployment bearer (§9.2); it calls this same-origin proxy with no
 * credentials, the proxy attaches the server-only bearer (a Pages env binding),
 * and the Coordinator resolves the constant principal (C7).
 *
 * NARROW BY CONSTRUCTION (the Board/Inbox proxy discipline):
 *   • only `onRequestGet` is exported → the HARD-CODED read op `blueprint-get`
 *     only; no write verb is reachable from the reader (§4.5). The single
 *     client input is the required `project_ref` (which Blueprint to read).
 *   • the engine returns the B.2 record body VERBATIM, or `null` when there is
 *     no Blueprint yet (the §2.2 "missing ⇒ null" empty-state contract). The
 *     proxy passes that through untouched — tolerance (B.4) lives in the view
 *     model (deriveBlueprintView, H3), never here.
 *
 * BINDS INTERFACE.md v1 + UX-V2-ARCHITECTURE.md: §9.1 (the one chokepoint,
 * token server-side), §2.3 (authed channel), A.2 (blueprint is a §4 record — the
 * engine, not this proxy, owns the storage class), B.2 (the record body), B.4
 * (render tolerance lives in the view; the proxy never rewrites the body).
 */

const READ_OP = 'blueprint-get'; // §2.2 read producer — FROZEN here.

function json(body, status) {
  return new Response(JSON.stringify(body), {
    status: status || 200,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store'
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
          'Blueprint read proxy not configured: COORDINATOR_URL / ' +
          'COORDINATOR_TOKEN bindings are required (the per-deployment bearer ' +
          'lives server-side only — §9.1/§9.2). No Blueprint can be served.'
      },
      503
    );
  }

  // The required read input: which workspace's Blueprint. A READ selector on
  // the §2.2 producer, never a write verb. An empty/unknown project_ref simply
  // reads as `null` at the engine (the honest empty state, B.4).
  const url = new URL(context.request.url);
  const projectRef = (url.searchParams.get('project_ref') || '').trim();
  if (!projectRef) {
    return json({ ok: false, error: 'need project_ref (which workspace Blueprint to read)' }, 400);
  }

  const upstream = new URL(base.replace(/\/+$/, '') + '/request');
  upstream.searchParams.set('op', READ_OP);
  upstream.searchParams.set('project_ref', projectRef);

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
          'Coordinator unreachable from the Blueprint read proxy: ' +
          (e && e.message ? e.message : String(e))
      },
      502
    );
  }

  if (resp.status === 401 || resp.status === 403) {
    return json(
      { ok: false, error: 'Coordinator rejected the Blueprint bearer token (§9.1)' },
      502
    );
  }

  const text = await resp.text();
  // Pass the engine body through VERBATIM (the B.2 record body, or `null`).
  // Tolerance (B.4) lives in deriveBlueprintView, not here; the proxy never
  // best-effort-rewrites the shape it does not understand (§0.3).
  return new Response(text, {
    status: resp.ok ? 200 : 502,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store'
    }
  });
}
