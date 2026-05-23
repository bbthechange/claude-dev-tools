/* beads-runner/web/functions/api/board/index.js — T6a (claude-tools-p2m).
 *
 * The Board's read proxy — a Cloudflare Pages Function (Appendix A
 * realization: "web app → Pages"; §0.2 — provider primitives are
 * NON-NORMATIVE, the contract is the §-clauses below, not "Pages").
 *
 * WHY THIS EXISTS — the §9.1 chokepoint, Board side. Every control-plane
 * request crosses ONE authenticate(request)→principal step at the Coordinator
 * (§2.3/§9.1, no UI-vs-agent split — C4). The browser MUST NOT hold the
 * per-deployment bearer secret (§9.2 — secrets never in a client-shipped /
 * committable location). So the client calls THIS same-origin proxy with no
 * credentials; the proxy attaches the server-only bearer (a Pages env binding)
 * and calls the Coordinator's authed endpoint. The Coordinator resolves the
 * constant principal = PRINCIPAL_V1 (AD6; C7 later = real tokens, no schema
 * change). The Board never sees or chooses the principal.
 *
 * NO WRITE PATH FROM ANY READER — BY CONSTRUCTION (EXIT crit 3, §4.5):
 *   • only `onRequestGet` is exported — POST/PUT/PATCH/DELETE hit the Pages
 *     default 405; there is no handler that could mutate.
 *   • the upstream op is the HARD-CODED literal `work-snapshot` — the §4.5
 *     READ-ONLY projection producer. The client cannot select an op, a
 *     project beyond a read filter, or any write verb; nothing here can reach
 *     put / set-desired / heartbeat / lease / forensic write ops, or Dolt.
 *   • Dolt stays work-truth; this returns the Coordinator's read-join
 *     projection only — no second datastore, no write-back.
 *
 * BINDS INTERFACE.md v1: §9.1 (the one chokepoint, token server-side), §2.3
 * (authed channel transport), §4.5 (read-only projection passthrough), §0.3
 * (an unknown-higher schema_version is the Coordinator's to reject; the proxy
 * passes the body through verbatim and never best-effort-rewrites it).
 */

const COORDINATOR_OP = 'work-snapshot'; // §4.5 read-only producer — FROZEN here.

function json(body, status) {
  return new Response(JSON.stringify(body), {
    status: status || 200,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      // The projection is liveness-bearing (§4.2 derived at read time) — a
      // cached copy would lie the instant a heartbeat stops (C6/S-1).
      'cache-control': 'no-store',
      'x-board-read-only': 'true'
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
          'Board read proxy not configured: COORDINATOR_URL / COORDINATOR_TOKEN ' +
          'bindings are required (the per-deployment bearer lives server-side ' +
          'only — §9.1/§9.2). No projection can be served.'
      },
      503
    );
  }

  // Optional read-only filter: a single project_ref to scope the snapshot.
  // It is a READ filter on the §4.5 producer, never a write selector.
  const url = new URL(context.request.url);
  const projectRef = (url.searchParams.get('project') || '').trim();

  // The §2.3 authed channel: the proxy bears the token; the Coordinator's one
  // §9.1 chokepoint validates it and resolves the constant principal. The op
  // is the hard-coded read producer — the client never chooses it.
  const upstream = new URL(base.replace(/\/+$/, '') + '/request');
  upstream.searchParams.set('op', COORDINATOR_OP);
  if (projectRef) upstream.searchParams.set('project', projectRef);

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
        error: 'Coordinator unreachable from the Board read proxy: ' +
          (e && e.message ? e.message : String(e))
      },
      502
    );
  }

  if (resp.status === 401 || resp.status === 403) {
    // The §9.1 chokepoint rejected the bearer — surfaced honestly, not masked.
    return json(
      { ok: false, error: 'Coordinator rejected the Board bearer token (§9.1)' },
      502
    );
  }

  const text = await resp.text();
  // Pass the projection body through VERBATIM. §0.3 reject-unknown-higher is
  // the Coordinator's contract and the client renderer's (board-view.js) —
  // the proxy never best-effort-rewrites a schema it does not understand.
  return new Response(text, {
    status: resp.ok ? 200 : 502,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'x-board-read-only': 'true'
    }
  });
}
