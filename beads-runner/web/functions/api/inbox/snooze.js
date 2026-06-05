/* beads-runner/web/functions/api/inbox/snooze.js — L1 follow-up (claude-tools-653d).
 *
 * The SNOOZE write proxy — the "get this out of my face NOW, bring it back at T"
 * affordance (inbox-lifecycle §5.6). It DEFERS the dossier out of the foreground
 * NOW and arms a §2.2 timer to RE-SURFACE it (NOT auto-proceed) at the user-set
 * `snooze_until` — the surface-at-T primitive already proven by pairSurface
 * (cf/src/timer.js). It is NOT a §5.2 response: no decision, no consequence
 * application, no per-Item state move — the dossier's items are untouched; only
 * its attention tier (now) and its re-surface timer (at T) change.
 *
 * DISTINCT VERB, NO DEFAULTING (the L1 §5.6 contract): snooze carries its OWN op
 * (`dossier-snooze`); it never reuses respond's payload, never falls back to
 * "apply the recommendation". The body is {dossier_id, snooze_until} ONLY — there
 * is no decision, item_id, or state the client can send.
 *
 * Same §9.1 chokepoint discipline as ./escalate, ./respond and ./expire:
 * server-side bearer only; the client bears no secret, never picks the principal,
 * and never picks the op or the timer semantics — this proxy hard-codes the op.
 * snooze_until is the ONLY caller-supplied datum, so the proxy guards its
 * RFC-3339 shape and future-ness HERE before the round-trip; the engine (§2.2
 * timer arm) re-enforces as the authoritative gate. The op is exposed to the
 * production adapter (cf/pages-dev/adapter.js argsForPost) for this single purpose.
 *
 * WRITE PATH IS NARROW BY CONSTRUCTION: only `onRequestPost` is exported and the
 * upstream op is the HARD-CODED literal `dossier-snooze`. The §5.2 response shape
 * and the renderer's per-Item affordance set are untouched (§11).
 *
 * BINDS INTERFACE.md v1: §9.1, §2.3, §4.1 (the `tier` field), §2.2 (the
 * re-surface timer; engine round-trips the envelope through the §5.1 write gate),
 * §0.3 (the engine rejects an unknown op or a malformed record).
 */

const COORDINATOR_OP = 'dossier-snooze'; // §5.6 snooze — defer now + arm §2.2 re-surface timer. FROZEN here.

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
          'Snooze proxy not configured: COORDINATOR_URL / ' +
          'COORDINATOR_TOKEN bindings are required (server-side only — ' +
          '§9.1/§9.2). No dossier can be snoozed.'
      },
      503
    );
  }

  let payload;
  try {
    payload = await context.request.json();
  } catch (e) {
    return json({ ok: false, error: 'snooze body must be JSON {dossier_id,snooze_until}' }, 400);
  }
  const dossierId = payload && typeof payload.dossier_id === 'string' ? payload.dossier_id.trim() : '';
  if (!dossierId) {
    return json({ ok: false, error: 'need {dossier_id} — snooze acts on the whole dossier (§5.6)' }, 400);
  }
  const snoozeUntil = payload && typeof payload.snooze_until === 'string' ? payload.snooze_until.trim() : '';
  if (!snoozeUntil) {
    return json({ ok: false, error: 'need {snooze_until} — an RFC-3339 instant to re-surface at (§2.2)' }, 400);
  }
  // snooze_until must parse as a real instant AND be in the FUTURE — a past/now
  // time would re-surface immediately (a no-op snooze = a mis-tap, not a §5.6
  // snooze). The engine §2.2 timer arm re-enforces (the authoritative gate); this
  // guard just surfaces a clean 400 before the round-trip (the respond.js posture).
  const t = Date.parse(snoozeUntil);
  if (Number.isNaN(t)) {
    return json({ ok: false, error: 'snooze_until is not a valid RFC-3339 timestamp (§2.2)' }, 400);
  }
  if (t <= Date.now()) {
    return json({ ok: false, error: 'snooze_until must be in the future — a past instant re-surfaces immediately (§2.2)' }, 400);
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
      body: JSON.stringify({ dossier_id: dossierId, snooze_until: snoozeUntil })
    });
  } catch (e) {
    return json(
      {
        ok: false,
        error: 'Coordinator unreachable from the Snooze proxy — your ' +
          'snooze was NOT applied (honest, principle 4): ' +
          (e && e.message ? e.message : String(e))
      },
      502
    );
  }

  if (resp.status === 401 || resp.status === 403) {
    return json(
      { ok: false, error: 'Coordinator rejected the Inbox bearer token (§9.1) — snooze NOT applied' },
      502
    );
  }

  const text = await resp.text();
  // Pass the Coordinator's outcome through verbatim. The client re-fetches the
  // §4 Dossier to render the honest new attention tier + armed timer (never a
  // fabricated ack).
  return new Response(text, {
    status: resp.ok ? 200 : 502,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store'
    }
  });
}
