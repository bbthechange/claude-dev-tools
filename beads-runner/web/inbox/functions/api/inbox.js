/* beads-runner/web/inbox/functions/api/inbox.js — T6b (claude-tools-xre).
 *
 * The Inbox's READ proxy — a Cloudflare Pages Function (Appendix A
 * realization; §0.2 — provider primitives are NON-NORMATIVE). It is the §9.1
 * chokepoint, Inbox side: the browser holds NO secret and never picks the
 * principal/op (§9.1/§9.2). The client GETs this same-origin proxy with no
 * credentials; the proxy attaches the server-only bearer (a Pages env
 * binding) and calls the Coordinator's authed endpoint, which resolves the
 * constant principal = PRINCIPAL_V1 (AD6; C7 later, no schema change).
 *
 * READ ONLY, BY CONSTRUCTION (EXIT crit 3): only `onRequestGet` is exported,
 * and the upstream op is the HARD-CODED literal `work-snapshot` — the §4.5
 * read-only projection producer. This proxy cannot reach any write op or
 * Dolt; it serves the same projection the Board reads (the Inbox renders the
 * WAITING-ON-YOU lane + Flow-G tiers 1–2 from it). The §4 Dossier RECORD that
 * the lane points at is fetched by the SEPARATE read proxy ./dossier; the
 * per-Item RESPONSE write is the SEPARATE ./respond proxy. One op per proxy —
 * the client never selects an op (the Board's frozen discipline).
 *
 * BINDS INTERFACE.md v1: §9.1 (one chokepoint, token server-side), §2.3
 * (authed transport), §4.5 (read-only projection passthrough), §0.3 (the
 * Coordinator's to reject an unknown-higher version; the proxy passes the
 * body through verbatim, never best-effort-rewrites it).
 */

const COORDINATOR_OP = 'work-snapshot'; // §4.5 read-only producer — FROZEN here.

function json(body, status) {
  return new Response(JSON.stringify(body), {
    status: status || 200,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      // Liveness/decision-bearing (§4.2 derived at read time) — a cached copy
      // would lie the instant a heartbeat stops or an item resolves (S-1/S-2).
      'cache-control': 'no-store',
      'x-inbox-read-only': 'true'
    }
  });
}

export async function onRequestGet(context) {
  const env = context.env || {};
  const base = env.COORDINATOR_URL;
  const token = env.COORDINATOR_TOKEN; // §9.2-family server secret (Pages binding)

  if (!base || !token) {
    // Honest degradation — never fabricate a projection (S-1/principle 4).
    return json(
      {
        ok: false,
        error:
          'Inbox read proxy not configured: COORDINATOR_URL / COORDINATOR_TOKEN ' +
          'bindings are required (the per-deployment bearer lives server-side ' +
          'only — §9.1/§9.2). No projection can be served.'
      },
      503
    );
  }

  const upstream = new URL(base.replace(/\/+$/, '') + '/request');
  upstream.searchParams.set('op', COORDINATOR_OP);

  let resp;
  try {
    resp = await fetch(upstream.toString(), {
      method: 'GET', // read only — no body, no mutation verb
      headers: { authorization: 'Bearer ' + token, accept: 'application/json' }
    });
  } catch (e) {
    return json(
      {
        ok: false,
        error: 'Coordinator unreachable from the Inbox read proxy: ' +
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

  const text = await resp.text();
  // Pass the projection through VERBATIM. §0.3 reject-unknown-higher is the
  // Coordinator's and the client renderer's (inbox-view.js) — not the proxy's.
  return new Response(text, {
    status: resp.ok ? 200 : 502,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'x-inbox-read-only': 'true'
    }
  });
}
