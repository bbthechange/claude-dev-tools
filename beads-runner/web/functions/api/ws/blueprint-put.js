/* beads-runner/web/functions/api/ws/blueprint-put.js — H1 (claude-tools-uxvh1).
 *
 * The Blueprint facet's WRITE proxy — DESIGN H (design/blueprint.md §2.2/§5.4),
 * Flow H. The GUI seam for the `customization` layer: Brian taps a node on the
 * map and renames / regroups / pins / hides it (H4), which POSTs the whole
 * merged `customization` sub-object through this proxy. The SECTIONED engine op
 * guarantees a concurrent `derived` regen (the updater hat) never eats the edit
 * (§2.3 never-clobber). Same §9.1-disciplined seam as ws/gate-meta.js +
 * board/set-desired.js.
 *
 * WHY THIS EXISTS — the §9.1 chokepoint. The browser MUST NOT hold the
 * per-deployment bearer (§9.2); it calls this same-origin proxy with no
 * credentials, the proxy attaches the server-only bearer (a Pages env binding),
 * and the Coordinator resolves the constant principal + stamps it (C7). The
 * client never sees or chooses the principal.
 *
 * NARROW BY CONSTRUCTION (the Board/Inbox proxy discipline):
 *   • only `onRequestPost` is exported → the HARD-CODED write op `blueprint-put`
 *     only. The client never selects the op, never holds the bearer (§9.2).
 *   • this is the GUI seam, so `updated_by` is forced to "you" server-side: a
 *     Blueprint edited through the browser is Brian's (§2.3 — updated_by is an
 *     INPUT the caller declares; the updater HAT calls blueprint-put directly
 *     with updated_by:"agent:blueprint-update", NOT this proxy). The GUI writes
 *     ONLY the `customization` (or `narrative`) section — `derived` is the
 *     machine's layer; the proxy refuses a GUI `derived` write so the human seam
 *     can never overwrite machine truth (principle 9 / must-protect #3).
 *   • the engine owns the authoritative gate (safe project_ref, the closed
 *     section set, the body shape, the §0.3 schema gate inside _writeRecord).
 *
 * BINDS INTERFACE.md v1 + UX-V2-ARCHITECTURE.md: §9.1 (the one chokepoint,
 * token server-side), §2.3 (authed channel; updated_by is the declared input),
 * A.2 (blueprint is a §4 record — the engine owns the storage class), B.2 (the
 * sectioned body), B.4 (the engine refuses non-conformant writes; tolerance is
 * a render concern).
 */

const WRITE_OP = 'blueprint-put'; // §2.2 sectioned producer — FROZEN here.

// The §2.2 sections a GUI caller may write. `derived` is DELIBERATELY EXCLUDED:
// it is the machine's layer (only the updater hat writes it, calling the engine
// op directly). A GUI `derived` write would be exactly the clobber principle 9
// forbids, so this seam refuses it. `conflicts-append` is the updater's mode,
// not a GUI gesture (the facet resolves a conflict by re-writing customization),
// so it is also excluded from the GUI seam.
const GUI_SECTIONS = ['customization', 'narrative'];

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
          'Blueprint write proxy not configured: COORDINATOR_URL / ' +
          'COORDINATOR_TOKEN bindings are required (server-side only — ' +
          '§9.1/§9.2). No Blueprint change can be applied.'
      },
      503
    );
  }

  let payload;
  try {
    payload = await context.request.json();
  } catch (e) {
    return json(
      { ok: false, error: 'request body must be JSON {project_ref, section, body}' },
      400
    );
  }

  const projectRef =
    payload && typeof payload.project_ref === 'string' ? payload.project_ref.trim() : '';
  const section =
    payload && typeof payload.section === 'string' ? payload.section.trim() : '';
  const body = payload && payload.body;

  if (!projectRef) {
    return json({ ok: false, error: 'need project_ref (which workspace Blueprint to write)' }, 400);
  }
  // Cheap first gate (the engine is authoritative): a GUI caller may write only
  // the human layers. `derived` / `conflicts-append` are refused here so the GUI
  // seam can never overwrite machine truth (principle 9 / must-protect #3).
  if (GUI_SECTIONS.indexOf(section) < 0) {
    return json(
      {
        ok: false,
        error:
          'unknown or non-GUI section ' + JSON.stringify(section) +
          ' — the Blueprint GUI may write only ' + JSON.stringify(GUI_SECTIONS) +
          ' (derived is the machine layer; the updater hat writes it directly)'
      },
      422
    );
  }
  // body must be a JSON object (the section content). A 422 here is the cheap
  // pre-gate; the engine re-checks and writes NOTHING on a bad body.
  if (body === null || typeof body !== 'object' || Array.isArray(body)) {
    return json({ ok: false, error: 'need a body object (the ' + section + ' layer to set)' }, 422);
  }

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
      // Mirror the named-JSON-body shape the adapter unwraps to the engine's
      // positional [<envelope_json>]. §2.3: this is the GUI seam, so updated_by
      // is forced to "you" server-side (the browser cannot claim to be an agent;
      // the updater hat uses the engine op directly with
      // updated_by:"agent:blueprint-update"). The client never sets a principal;
      // the §9.1 chokepoint stamps the resolved one on the way in.
      body: JSON.stringify({
        project_ref: projectRef,
        section: section,
        body: body,
        updated_by: 'you'
      })
    });
  } catch (e) {
    return json(
      {
        ok: false,
        error:
          'Coordinator unreachable from the Blueprint write proxy — the ' +
          'Blueprint was NOT changed (honest, principle 4): ' +
          (e && e.message ? e.message : String(e))
      },
      502
    );
  }

  if (resp.status === 401 || resp.status === 403) {
    return json(
      { ok: false, error: 'Coordinator rejected the Blueprint bearer token (§9.1) — Blueprint NOT changed' },
      502
    );
  }

  const text = await resp.text();
  // Pass the Coordinator's outcome through verbatim (on success {ok:true,
  // project_ref}; on a bad write a 422 the facet surfaces honestly).
  return new Response(text, {
    status: resp.ok ? 200 : 502,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store'
    }
  });
}
