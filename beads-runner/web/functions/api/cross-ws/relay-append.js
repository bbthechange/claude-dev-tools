/* beads-runner/web/functions/api/cross-ws/relay-append.js — K2 (claude-tools-uxvk2).
 *
 * The Cross-WS RELAY-LOG append (write) proxy — DESIGN K §3.3, Flow K. One
 * row per cross-workspace exchange is appended after the responder's verdict
 * resolves (outcome:"resolved" for an answer, outcome:"escalated" with the
 * Flow B dossier id for the 20%). The canonical writer is the ask-workspace
 * MCP server (K1) via its engine-bridge; this proxy is the SAME §9.1-disciplined
 * write seam exposed over the unified Pages project (so the write surface is
 * complete + adapter-mapped per the A.1 op-wiring checklist).
 *
 * WRITE PATH IS NARROW BY CONSTRUCTION (the Board/Inbox proxy discipline): only
 * `onRequestPost` is exported and the upstream op is the HARD-CODED literal
 * `relay-log-append`. There is no op the client can select; no read/tail or
 * any other write verb is reachable. The client never holds the bearer (§9.2)
 * and never picks the principal — the §9.1 chokepoint resolves PRINCIPAL_V1
 * server-side (C7); a wire `principal` is ignored.
 *
 * The body is the exchange object; it is forwarded VERBATIM as
 * {exchange:{...}} (the adapter re-stringifies it to the engine's positional
 * `<exchange_json>` arg, the `put` precedent). The engine owns the
 * authoritative gate (closed `outcome` enum, safeKey exchange_id/routing keys);
 * the proxy does only the cheap-and-honest first checks so a malformed body is
 * a clear 4xx BEFORE a Coordinator round-trip.
 *
 * BINDS INTERFACE.md v1 + UX-V2-ARCHITECTURE.md: §9.1 (the one chokepoint,
 * token server-side), §2.3 (authed channel), A.2 (relay_log is an append-only
 * transient — the engine, not this proxy, owns the storage class).
 */

const COORDINATOR_OP = 'relay-log-append'; // append-only write producer — FROZEN here.

// The B.3 closed `outcome` enum, pinned here as the cheap first gate (the
// engine's relay.js outcomeOk is authoritative — a typo is a 422 BEFORE the
// round-trip, exactly like set-desired.js pins the four desired-states).
const ALLOWED_OUTCOMES = ['resolved', 'escalated'];

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
          'Cross-WS relay append proxy not configured: COORDINATOR_URL / ' +
          'COORDINATOR_TOKEN bindings are required (server-side only — ' +
          '§9.1/§9.2). No relay exchange can be appended.'
      },
      503
    );
  }

  let payload;
  try {
    payload = await context.request.json();
  } catch (e) {
    return json(
      { ok: false, error: 'request body must be JSON {exchange:{exchange_id, from_ws, to_ws, outcome, ...}}' },
      400
    );
  }

  // Accept either {exchange:{...}} (canonical) or the exchange fields at the
  // top level (tolerant). The adapter unwraps to the engine's positional
  // <exchange_json>; the engine owns the authoritative validation.
  const exchange =
    payload && typeof payload.exchange === 'object' && payload.exchange !== null
      ? payload.exchange
      : payload;

  if (!exchange || typeof exchange !== 'object' || Array.isArray(exchange)) {
    return json({ ok: false, error: 'need an exchange object (the row to append)' }, 400);
  }

  const exchangeId =
    typeof exchange.exchange_id === 'string' && exchange.exchange_id.length > 0
      ? exchange.exchange_id
      : typeof exchange.id === 'string' && exchange.id.length > 0
        ? exchange.id
        : '';
  if (!exchangeId) {
    return json({ ok: false, error: 'exchange needs a non-empty exchange_id (the stable B.3 id)' }, 400);
  }

  const outcome = typeof exchange.outcome === 'string' ? exchange.outcome.trim() : '';
  if (ALLOWED_OUTCOMES.indexOf(outcome) < 0) {
    // 422: well-formed JSON, semantically invalid (the B.3 closed enum). The
    // engine would reject anyway; this is the cheap first gate.
    return json(
      {
        ok: false,
        error: 'unknown outcome ' + JSON.stringify(outcome) + ' — must be one of ' + JSON.stringify(ALLOWED_OUTCOMES)
      },
      422
    );
  }
  // Forward the NORMALISED outcome so the proxy's pre-gate and the engine's
  // exact === gate (relay.js outcomeOk, no trim) cannot disagree — otherwise a
  // trailing-space "resolved " would pass here then 422 at the engine, surfaced
  // as a confusing 502. The engine remains authoritative; this just keeps the
  // two gates in lockstep (the captured value the proxy validated IS forwarded).
  exchange.outcome = outcome;

  // The §2.3 authed channel: the proxy bears the token; the §9.1 chokepoint
  // validates it and resolves the constant principal. The op is the hard-coded
  // write producer — the client never chooses it. The named-JSON-body
  // {exchange} is unwrapped by the adapter to the engine's positional arg.
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
      body: JSON.stringify({ exchange: exchange })
    });
  } catch (e) {
    return json(
      {
        ok: false,
        error:
          'Coordinator unreachable from the Cross-WS relay append proxy — the ' +
          'exchange was NOT appended (honest, principle 4): ' +
          (e && e.message ? e.message : String(e))
      },
      502
    );
  }

  if (resp.status === 401 || resp.status === 403) {
    return json(
      { ok: false, error: 'Coordinator rejected the Cross-WS bearer token (§9.1) — exchange NOT appended' },
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
