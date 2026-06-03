/* beads-runner/web/functions/api/control/escalate.js — I4 (claude-tools-uxvi4).
 *
 * The Activity facet's "Escalate to decision" stuck-action (DESIGN I §4). Unlike
 * Nudge/Kill+retry/Kill+Gate, escalate is NOT an agent-action and causes NO host
 * effect — it is a PURE ENGINE WRITE that converts a stuck task into a Flow B
 * decision card the Inbox then drives (design/agent-action.md §3 boundary 1).
 *
 * It builds a §5-VALID `worker_stuck` / tier:`blocking` dossier SERVER-SIDE (the
 * client sends only {bead_ref, project_ref, title?, reason?} — it cannot inject an
 * arbitrary dossier) and POSTs the engine's `dossier-generate` op, whose internal
 * author() templates {body, items[]} from the generation-input and whose §5 gate
 * (validateDossier) refuses anything malformed. The card offers four pick-options
 * (retry / gate / abandon / take over) with EMPTY consequence_blocks: the pick is
 * recorded and surfaced; Brian acts on it (v1 keeps escalate a pure surfacing
 * action — no auto-applied work mutation, which would be a separate control→work
 * wiring). Same §9.1 chokepoint discipline as set-desired.js (bearer server-side).
 *
 * The gi TEMPLATE itself lives in the shared builder web/shared/stuck-dossier.js
 * (claude-tools-x949) so the offline §5 guard cf/test/escalate-dossier.spec.js
 * imports the SAME source and a drift out of §5 reds the gate — it no longer
 * needs live-verify to surface.
 */

import { buildStuckGi } from '../../../shared/stuck-dossier.js';

const COORDINATOR_OP = 'dossier-generate'; // FROZEN here — the client never selects the op.

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
    return json({ ok: false, error: 'escalate proxy not configured: COORDINATOR_URL / COORDINATOR_TOKEN bindings are required (server-side only — §9.1/§9.2).' }, 503);
  }

  let payload;
  try {
    payload = await context.request.json();
  } catch (e) {
    return json({ ok: false, error: 'request body must be JSON {bead_ref, project_ref, title?, reason?}' }, 400);
  }
  const beadRef = payload && typeof payload.bead_ref === 'string' ? payload.bead_ref.trim() : '';
  const projectRef = payload && typeof payload.project_ref === 'string' ? payload.project_ref.trim() : '';
  const title = payload && typeof payload.title === 'string' ? payload.title.trim() : '';
  const reason = payload && typeof payload.reason === 'string' ? payload.reason.trim() : '';
  if (!beadRef) {
    return json({ ok: false, error: 'need bead_ref — escalate converts a specific stuck task into a Flow B dossier' }, 400);
  }

  // Build the §5-valid gi from the shared template (web/shared/stuck-dossier.js)
  // — the SAME builder the offline §5 spec imports, so the two cannot drift.
  const gi = buildStuckGi({ beadRef, projectRef, title, reason });

  const upstream = new URL(base.replace(/\/+$/, '') + '/request');
  upstream.searchParams.set('op', COORDINATOR_OP);

  let resp;
  try {
    resp = await fetch(upstream.toString(), {
      method: 'POST',
      headers: { authorization: 'Bearer ' + token, 'content-type': 'application/json', accept: 'application/json' },
      body: JSON.stringify({ gi })
    });
  } catch (e) {
    return json({ ok: false, error: 'Coordinator unreachable from the escalate proxy — no dossier was created (honest, principle 4): ' + (e && e.message ? e.message : String(e)) }, 502);
  }
  if (resp.status === 401 || resp.status === 403) {
    return json({ ok: false, error: 'Coordinator rejected the bearer token (§9.1) — no dossier created' }, 502);
  }
  const text = await resp.text();
  return new Response(text, {
    status: resp.ok ? 200 : 502,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }
  });
}
