/* beads-runner/web/functions/api/ws/gate-meta.js — J1 (claude-tools-uxvj1).
 *
 * The Gates facet's gate_metadata read+write proxy — DESIGN J §2/§4, Flow J.
 * The Gates facet (J3, /ws/<ref>/gates) reads a gate's metadata (why /
 * unblock_condition / owner / scope / set_at) and lets Brian set/edit it. This
 * proxy is the SAME §9.1-disciplined seam exposed over the unified Pages
 * project, so the read+write surface is complete + adapter-mapped per the A.1
 * op-wiring checklist.
 *
 * WHY THIS EXISTS — the §9.1 chokepoint. The browser MUST NOT hold the
 * per-deployment bearer (§9.2); it calls this same-origin proxy with no
 * credentials, the proxy attaches the server-only bearer (a Pages env binding),
 * and the Coordinator resolves the constant principal (C7). Same discipline as
 * the Board read proxy (board/index.js) and the Cross-WS relay proxies.
 *
 * NARROW BY CONSTRUCTION (the Board/Inbox proxy discipline):
 *   • onRequestGet  → the HARD-CODED read op `gate-meta-get` only. The single
 *     client input is the optional `gate_id` filter (omit ⇒ all gates, the J2
 *     projection bulk shape). No write verb is reachable from the reader (§4.5).
 *   • onRequestPost → the HARD-CODED write op `gate-meta-set` only. The client
 *     never selects the op, never holds the bearer (§9.2), never picks the
 *     principal. `owner` is forced to "you" here: this proxy is the GUI seam, so
 *     a gate placed/edited through it is Brian's (§2.3 — owner is an INPUT the
 *     caller declares; an agent uses gate-meta-set directly with
 *     owner:"agent:<hat>", NOT this proxy). The engine owns the authoritative
 *     gate (id shape, REQUIRED why, the closed scope enum).
 *
 * BINDS INTERFACE.md v1 + UX-V2-ARCHITECTURE.md: §9.1 (the one chokepoint,
 * token server-side), §2.3 (authed channel), A.2 (gate_metadata is a transient
 * annotation — the engine, not this proxy, owns the storage class), D.2 (the
 * closed scope enum), B.4 (render tolerance lives in the view; the proxy never
 * rewrites the engine body).
 */

const READ_OP = 'gate-meta-get'; // §2.2 read projection — FROZEN here.
const WRITE_OP = 'gate-meta-set'; // §2.2 upsert producer — FROZEN here.

// The D.2 closed GATE_SCOPE enum, pinned here as the cheap first gate (the
// engine's gate-meta.js GATE_SCOPE_SET is authoritative — a typo is a 422
// BEFORE the round-trip, exactly like relay-append.js pins the outcome enum).
const ALLOWED_SCOPES = ['task', 'cohort'];

function json(body, status) {
  return new Response(JSON.stringify(body), {
    status: status || 200,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store'
    }
  });
}

function notConfigured(kind) {
  return json(
    {
      ok: false,
      error:
        'Gate-metadata ' + kind + ' proxy not configured: COORDINATOR_URL / ' +
        'COORDINATOR_TOKEN bindings are required (the per-deployment bearer ' +
        'lives server-side only — §9.1/§9.2). No gate metadata can be served.'
    },
    503
  );
}

export async function onRequestGet(context) {
  const env = context.env || {};
  const base = env.COORDINATOR_URL;
  const token = env.COORDINATOR_TOKEN; // §9.2-family server secret (Pages binding)

  if (!base || !token) return notConfigured('read');

  // Optional read filter. A non-empty `gate_id` scopes to one gate (the facet
  // edit affordance, engine returns {gate:…|null}); omitting it returns all
  // gates (the J2 projection bulk shape, {gates:[…]}). A READ filter on the
  // §4.5-style producer, never a write selector.
  const url = new URL(context.request.url);
  const gateId = (url.searchParams.get('gate_id') || '').trim();

  const upstream = new URL(base.replace(/\/+$/, '') + '/request');
  upstream.searchParams.set('op', READ_OP);
  if (gateId) upstream.searchParams.set('gate_id', gateId);

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
          'Coordinator unreachable from the gate-metadata read proxy: ' +
          (e && e.message ? e.message : String(e))
      },
      502
    );
  }

  if (resp.status === 401 || resp.status === 403) {
    return json(
      { ok: false, error: 'Coordinator rejected the gate-metadata bearer token (§9.1)' },
      502
    );
  }

  const text = await resp.text();
  // Pass the engine body through VERBATIM. Tolerance (B.4) lives in the
  // view-model, not here; the proxy never best-effort-rewrites the shape.
  return new Response(text, {
    status: resp.ok ? 200 : 502,
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

  if (!base || !token) return notConfigured('write');

  let payload;
  try {
    payload = await context.request.json();
  } catch (e) {
    return json(
      { ok: false, error: 'request body must be JSON {gate:{id, why, unblock_condition?, scope?}}' },
      400
    );
  }

  // Accept either {gate:{...}} (canonical) or the gate fields at the top level
  // (tolerant). The adapter unwraps to the engine's positional <meta_json>; the
  // engine owns the authoritative validation.
  const gate =
    payload && typeof payload.gate === 'object' && payload.gate !== null
      ? payload.gate
      : payload;

  if (!gate || typeof gate !== 'object' || Array.isArray(gate)) {
    return json({ ok: false, error: 'need a gate object (the metadata to set)' }, 400);
  }

  // Cheap first gates (the engine's gate-meta.js is authoritative — these keep
  // the two gates in lockstep so a malformed body is a clear 4xx BEFORE a
  // Coordinator round-trip). Status split mirrors the relay-append.js precedent:
  // a missing/malformed IDENTITY key (the gate id — you cannot even address the
  // row) is a 400; a well-formed body whose CONTENT fails a semantic rule (why
  // required, scope enum) is a 422. The engine maps all of these to one 422 (rc
  // 3) — both are 4xx and the engine is authoritative; this is only the cheap
  // pre-gate.
  const gateId =
    typeof gate.id === 'string' && gate.id.length > 0
      ? gate.id
      : typeof gate.gate_id === 'string' && gate.gate_id.length > 0
        ? gate.gate_id
        : '';
  if (!/^[a-z0-9][a-z0-9-]*$/.test(gateId)) {
    return json(
      { ok: false, error: 'gate needs a valid id (lowercase letters, digits, hyphens — gate:<id> shape)' },
      400
    );
  }
  // why is REQUIRED (B8 / §2.2 — a Gate ALWAYS carries a why).
  if (typeof gate.why !== 'string' || gate.why.trim().length === 0) {
    return json({ ok: false, error: 'gate needs a non-empty why (a Gate always records why it holds work)' }, 422);
  }
  // scope present-and-invalid ⇒ 422 (the closed D.2 enum). Absent ⇒ the engine
  // defaults it to "task"; the proxy does not inject one.
  if (gate.scope !== undefined && gate.scope !== null) {
    const scope = typeof gate.scope === 'string' ? gate.scope.trim() : '';
    if (ALLOWED_SCOPES.indexOf(scope) < 0) {
      return json(
        { ok: false, error: 'unknown scope ' + JSON.stringify(gate.scope) + ' — must be one of ' + JSON.stringify(ALLOWED_SCOPES) },
        422
      );
    }
    gate.scope = scope; // forward the normalised value (lockstep with the engine ===)
  }

  // §2.3 — this is the GUI seam, so the gate is Brian's. owner is forced to
  // "you" server-side: the browser cannot claim to be an agent (an agent uses
  // gate-meta-set directly with owner:"agent:<hat>", never this proxy). The
  // engine stamps no principal-derived owner — owner is the declared INPUT.
  gate.id = gateId;
  gate.owner = 'you';

  const upstream = new URL(base.replace(/\/+$/, '') + '/request');
  upstream.searchParams.set('op', WRITE_OP);

  let resp;
  try {
    resp = await fetch(upstream.toString(), {
      method: 'POST',
      headers: {
        authorization: 'Bearer ' + token,
        'content-type': 'application/json',
        accept: 'application/json'
      },
      body: JSON.stringify({ gate: gate })
    });
  } catch (e) {
    return json(
      {
        ok: false,
        error:
          'Coordinator unreachable from the gate-metadata write proxy — the ' +
          'gate metadata was NOT set (honest, principle 4): ' +
          (e && e.message ? e.message : String(e))
      },
      502
    );
  }

  if (resp.status === 401 || resp.status === 403) {
    return json(
      { ok: false, error: 'Coordinator rejected the gate-metadata bearer token (§9.1) — metadata NOT set' },
      502
    );
  }

  const text = await resp.text();
  return new Response(text, {
    status: resp.ok ? 200 : 502,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store'
    }
  });
}
