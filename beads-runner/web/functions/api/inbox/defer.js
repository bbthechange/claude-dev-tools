/* beads-runner/web/functions/api/inbox/defer.js — L1 follow-up (claude-tools-uxl1b).
 *
 * The DEFER write proxy — the "push this out of my way without resolving it"
 * affordance (inbox-lifecycle §5.6). It lowers the dossier's §4.1 attention
 * tier to `digest` (the daily-digest roundup) via the engine op `dossier-defer`.
 * It is NOT a §5.2 response: no decision, no consequence application, no
 * per-Item state move — the dossier STAYS on the Inbox (it still has open
 * items), just out of the foreground decision lane. Reversible by escalate.
 *
 * DISTINCT VERB, NO DEFAULTING (the L1 §5.6 contract): defer carries its OWN
 * op (`dossier-defer`); it never reuses respond's payload, never falls back to
 * "apply the recommendation". The body is {dossier_id} ONLY — there is no
 * decision, item_id, or state the client can send.
 *
 * Same §9.1 chokepoint discipline as ./respond and ./expire: server-side bearer
 * only; the client bears no secret, never picks the principal, and never picks
 * the op or the target tier — this proxy hard-codes both. The op is exposed to
 * the production adapter (cf/pages-dev/adapter.js argsForPost) for this single
 * purpose.
 *
 * WRITE PATH IS NARROW BY CONSTRUCTION: only `onRequestPost` is exported and
 * the upstream op is the HARD-CODED literal `dossier-defer`. The §5.2 response
 * shape and the renderer's per-Item affordance set are untouched (§11).
 *
 * BINDS INTERFACE.md v1: §9.1, §2.3, §4.1 (the `tier` field; engine still
 * round-trips the envelope through the §5.1 write gate), §0.3 (the engine
 * rejects an unknown op or a malformed record).
 */

const COORDINATOR_OP = 'dossier-defer'; // §5.6 defer — tier→digest. FROZEN here.

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
          'Defer proxy not configured: COORDINATOR_URL / ' +
          'COORDINATOR_TOKEN bindings are required (server-side only — ' +
          '§9.1/§9.2). No dossier can be deferred.'
      },
      503
    );
  }

  let payload;
  try {
    payload = await context.request.json();
  } catch (e) {
    return json({ ok: false, error: 'defer body must be JSON {dossier_id}' }, 400);
  }
  const dossierId = payload && typeof payload.dossier_id === 'string' ? payload.dossier_id.trim() : '';
  if (!dossierId) {
    return json({ ok: false, error: 'need {dossier_id} — defer acts on the whole dossier (§5.6)' }, 400);
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
      body: JSON.stringify({ dossier_id: dossierId })
    });
  } catch (e) {
    return json(
      {
        ok: false,
        error: 'Coordinator unreachable from the Defer proxy — your ' +
          'defer was NOT applied (honest, principle 4): ' +
          (e && e.message ? e.message : String(e))
      },
      502
    );
  }

  if (resp.status === 401 || resp.status === 403) {
    return json(
      { ok: false, error: 'Coordinator rejected the Inbox bearer token (§9.1) — defer NOT applied' },
      502
    );
  }

  const text = await resp.text();
  // Pass the Coordinator's outcome through verbatim. The client re-fetches the
  // §4 Dossier to render the honest new attention tier (never a fabricated ack).
  return new Response(text, {
    status: resp.ok ? 200 : 502,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store'
    }
  });
}
