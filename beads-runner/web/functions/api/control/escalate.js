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
 */

const COORDINATOR_OP = 'dossier-generate'; // FROZEN here — the client never selects the op.

function json(body, status) {
  return new Response(JSON.stringify(body), {
    status: status || 200,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }
  });
}

// A minimal §5-valid pick-option (empty consequence_block — the engine's author()
// stamps cb_schema_version). v1 escalate SURFACES the choice; it does not
// auto-apply a work mutation (that is a separate control→work wiring).
function opt(option_id, label, blast_radius) {
  return {
    option_id, label, blast_radius,
    consequence_block: { creates: [], unblocks: [], labels: [], status_changes: [] }
  };
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

  const what = title ? (beadRef + ' — ' + title) : beadRef;
  // Stable id per bead so re-escalating the same stuck task does not pile up
  // duplicate cards (the §7.4 dedup layer keys on principal+bead_ref).
  const gi = {
    id: 'stuck-' + beadRef,
    kind: 'decide',
    trigger: 'worker_stuck',
    bead_ref: beadRef,
    tier: 'blocking',
    timer_fire_at: null,
    source: {
      tldr: 'A worker on ' + what + ' looks stuck — what should I do?',
      ask: 'How should this stuck task proceed?',
      sections: [{
        heading: 'Why this surfaced',
        prose: 'The Activity view flagged this worker as maybe-stuck (no progress past the soft window)'
          + (reason ? ('. Note: ' + reason) : '.')
          + ' Escalated from the Activity stuck-actions so the decision lands in the Inbox.'
      }],
      diagrams: [],
      full_detail: 'This is a surfacing-only escalation (DESIGN I §4): the four options below are recorded for the audit trail; act on the chosen one from the Activity/Board controls. Nudge keeps the worker alive; Kill+retry re-dispatches a fresh worker on the same bead; Kill+Gate stops re-dispatch until a gate lifts.'
    },
    items: [{
      id: 'stuck-decision',
      kind: 'pick-option',
      framing: {
        ask: 'What should happen to ' + what + '?',
        why: 'A stuck worker burns budget; the four host actions have different blast radii.'
      },
      context_anchor: {
        where: 'Activity view — workspace ' + (projectRef || '(unknown)') + ', worker on ' + beadRef,
        expansion: 'Flagged maybe-stuck (silence past the soft window). The watchdog will eventually kill it on idle; this asks for an explicit decision first.'
      },
      reversible: 'Reversible — nudge/escalate are pure; kill+retry loses in-flight work but the bead is intact; kill+gate is undone by lifting the gate.',
      options: [
        opt('nudge', 'Nudge (keep alive)', 'extends the watchdog grace one window; no kill'),
        opt('kill-retry', 'Kill + retry', 'terminates the worker; the loop re-dispatches a fresh worker on the same bead'),
        opt('kill-gate', 'Kill + Gate', 'terminates AND gates the bead so it stops being retried until the gate lifts'),
        opt('abandon', 'Leave it / decide later', 'no action now; revisit')
      ],
      recommendation: {
        value: 'kill-retry',
        why: 'A fresh context window most often clears a transient stall; gate only if it is structurally blocked.'
      }
    }]
  };

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
