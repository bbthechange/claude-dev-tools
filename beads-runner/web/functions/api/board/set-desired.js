/* beads-runner/web/functions/api/board/set-desired.js — F1 (claude-tools-49w).
 *
 * The Board's per-workspace DESIRED-STATE write proxy — UX-DESIGN Flow D
 * closed loop, Board side. The phone changes a workspace's desired-state
 * toggle; the daemon (M3, claude-tools-cgh) discovers it on its next poll and
 * converges actual→desired by spawning (`running`) / killing (`stopped`) the
 * workspace runner. This proxy is the ONE Board-side write seam that puts the
 * new desired-state into the engine's RunnerState; it never spawns or kills
 * anything itself — convergence is the daemon's job.
 *
 * Same §9.1 chokepoint discipline as the Inbox response proxy: the
 * per-deployment bearer lives server-side only (a Pages env binding); the
 * browser holds no secret (§9.2) and never picks the principal — §9.1 stamps
 * the resolved PRINCIPAL_V1 on the RunnerState record (the client MUST NOT
 * send a principal; if it does, the chokepoint is authoritative and ignores
 * it). All actors authenticate identically — no UI-vs-agent split (C4); the
 * Board client's `actor:'user'` is captured-not-enforced (the §0.C
 * downgrade/promote asymmetry is §0.C-DEFERRED and MUST NOT be enforced here).
 *
 * WRITE PATH IS NARROW BY CONSTRUCTION: only `onRequestPost` is exported and
 * the upstream op is the HARD-CODED literal `set-desired`. There is no op the
 * client can select; no put/get/poll/lease/forensic/item-apply verb is
 * reachable; nothing here writes Dolt (Dolt stays work-truth — the daemon
 * reconciles control→work on its own cadence).
 *
 * VALIDATION at the proxy is the cheap-and-honest first gate: the four
 * desired-state strings are pinned here so a typo is rejected with a clear
 * 422 BEFORE we burn a Coordinator round-trip. The engine still owns the
 * authoritative validation (unsafe project_ref, store gate, §0.3 schema gate)
 * — unknown workspace refs pass through and the engine rejects them.
 *
 * BINDS INTERFACE.md v1: §9.1 (the one chokepoint, token server-side), §2.3
 * (authed channel transport), §4.2 (desired captured here; liveness/actual
 * are derived elsewhere — never re-derived by a writer), §0.3 (an unknown-
 * higher schema_version is the Coordinator's to reject; the proxy passes the
 * body through verbatim and never best-effort-rewrites it).
 */

const COORDINATOR_OP = 'set-desired'; // §2.4 C4-seam captured-actor — FROZEN here.

// The four legal desired-states, per UX-DESIGN Flow D + INTERFACE §4.2.
// Pinned as a frozen literal so a UI typo is a 422 here, BEFORE the engine
// burns a round-trip; the engine's store/schema gate is still authoritative.
//
// UI ↔ WIRE vocabulary (F3, claude-tools-6mx — Flow D end-to-end gap):
//   UX-DESIGN names the four toggles `{running, paused, spare-only, stopped}`.
//   INTERFACE.md §4.2 names the §4.2 RunnerState.desired enum
//   `{running, paused, spare-cycles, stopped}` — and the daemon (M3) and
//   workspace runner C2 gate both READ `spare-cycles` literally. Without a
//   translation here, a `spare-only` tap would land in the engine verbatim,
//   the daemon would coerce it to empty (out-of-enum) and no-op forever, and
//   the C2 gate would never fire — Flow D would silently break for one of its
//   four states. The proxy is the UI/wire seam, so the normalisation lives
//   here: validate the UI name, then send the §4.2 enum.
const ALLOWED_STATES = ['running', 'paused', 'spare-only', 'stopped'];
const WIRE_STATE = {
  running:      'running',
  paused:       'paused',
  'spare-only': 'spare-cycles',
  stopped:      'stopped'
};

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
          'Set-desired proxy not configured: COORDINATOR_URL / ' +
          'COORDINATOR_TOKEN bindings are required (server-side only — ' +
          '§9.1/§9.2). No desired-state change can be applied.'
      },
      503
    );
  }

  let payload;
  try {
    payload = await context.request.json();
  } catch (e) {
    return json(
      { ok: false, error: 'request body must be JSON {project_ref, desired:{state, actor}}' },
      400
    );
  }

  const projectRef =
    payload && typeof payload.project_ref === 'string' ? payload.project_ref.trim() : '';
  const desired = payload && payload.desired;
  const state =
    desired && typeof desired.state === 'string' ? desired.state.trim() : '';
  const actor =
    desired && typeof desired.actor === 'string' ? desired.actor.trim() : '';

  if (!projectRef) {
    return json({ ok: false, error: 'need project_ref (non-empty string)' }, 400);
  }
  if (!state) {
    return json(
      { ok: false, error: 'need desired.state ∈ ' + JSON.stringify(ALLOWED_STATES) },
      400
    );
  }
  if (ALLOWED_STATES.indexOf(state) < 0) {
    // 422 because the body is well-formed JSON but semantically invalid (the
    // four desired-states are a frozen set — Flow D / INTERFACE §4.2). The
    // engine would reject anyway; this is just the cheap first gate.
    return json(
      {
        ok: false,
        error:
          'unknown desired.state ' + JSON.stringify(state) +
          ' — must be one of ' + JSON.stringify(ALLOWED_STATES)
      },
      422
    );
  }
  if (!actor) {
    return json(
      { ok: false, error: 'need desired.actor (non-empty string; captured-not-enforced — C4)' },
      400
    );
  }

  // The §2.3 authed channel: the proxy bears the token; the Coordinator's one
  // §9.1 chokepoint validates it and resolves the constant principal. The op
  // is the hard-coded write producer — the client never chooses it.
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
      // Mirror the desired's named-JSON-body shape exactly — the adapter unwraps
      // to the engine's positional `[proj, state, actor]` args (§2.4
      // opSetDesired). The client never sets a principal; if they tried, the
      // chokepoint would overwrite it on the way in. F3: the UI's `spare-only`
      // is normalised to the §4.2 wire enum `spare-cycles` here so the engine
      // store, the daemon's M3 enum filter, and the runner's C2 gate all see
      // the same canonical value.
      body: JSON.stringify({
        project_ref: projectRef,
        desired: { state: WIRE_STATE[state], actor: actor }
      })
    });
  } catch (e) {
    return json(
      {
        ok: false,
        error:
          'Coordinator unreachable from the set-desired proxy — the workspace ' +
          'desired-state was NOT changed (honest, principle 4): ' +
          (e && e.message ? e.message : String(e))
      },
      502
    );
  }

  if (resp.status === 401 || resp.status === 403) {
    return json(
      { ok: false, error: 'Coordinator rejected the Board bearer token (§9.1) — desired-state NOT changed' },
      502
    );
  }

  const text = await resp.text();
  // Pass the Coordinator's outcome through verbatim. On success the engine
  // returns {ok:true} and the new RunnerState lives in D1; the daemon's M3
  // poll picks it up on its next tick and converges actual→desired. The
  // Board re-fetches /api/board to render the new desired alongside the
  // (lagging) actual — honest state, never optimistic.
  return new Response(text, {
    status: resp.ok ? 200 : 502,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store'
    }
  });
}
