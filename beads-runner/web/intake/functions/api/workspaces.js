/* beads-runner/web/intake/functions/api/workspaces.js — I1 (claude-tools-tbl).
 *
 * The Intake's WORKSPACE LIST read proxy — feeds Flow A's "project picker"
 * dropdown. The phone UI calls this credential-less, same-origin GET to learn
 * which `project_ref`s the engine currently knows about (every workspace with
 * a stored RunnerState record); the user picks one (or the UI lets it pick)
 * and POSTs to /api/intake (I2).
 *
 * Same §9.1 chokepoint discipline as the sibling read proxies (board.js /
 * inbox.js / dossier.js): the browser holds NO secret and never picks the
 * principal or op (§9.1/§9.2). The proxy attaches the server-side bearer
 * (Pages env binding) and calls the Coordinator's ONE authed endpoint.
 *
 * READ ONLY, BY CONSTRUCTION:
 *   • only `onRequestGet` is exported — POST/PUT/PATCH/DELETE hit Pages' 405.
 *   • the upstream op is the HARD-CODED literal `work-snapshot` — the §4.5
 *     read-only projection producer. The work-snapshot already enumerates
 *     every project_ref the engine has a runner_state for, so we get the
 *     workspace list "for free" off the same producer the Board reads.
 *   • we PROJECT DOWN to just the list of project_refs before returning. The
 *     dropdown does not need liveness, capacity, or lifecycle columns; less
 *     surface here = fewer ways for an intake-time UI bug to leak control-
 *     plane detail.
 *
 * NB: this is intentionally NOT a new engine op (`workspaces`/`list-projects`
 * would have been a second §4.5 producer with its own permissions surface).
 * Reusing work-snapshot keeps the §9.1 op surface frozen — the I1 spec calls
 * out "a new read proxy that GETs the engine's runner_state list" and that
 * IS what work-snapshot enumerates (reconcile.js: "SELECT id FROM records
 * WHERE type = ? — bind('runner_state')").
 *
 * BINDS INTERFACE.md v1: §9.1, §2.3, §4.5 (read-only projection passthrough,
 * projected down to a list view here), §0.3 (the Coordinator is the
 * authoritative gate — the proxy passes through honest errors verbatim).
 */

const COORDINATOR_OP = 'work-snapshot'; // §4.5 read-only producer — FROZEN here.

function json(body, status) {
  return new Response(JSON.stringify(body), {
    status: status || 200,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      // Workspace list is decision-bearing for an INTAKE write — a cached copy
      // could surface a deleted/renamed workspace, which would then 422 at
      // /api/intake. Always re-read.
      'cache-control': 'no-store',
      'x-intake-read-only': 'true'
    }
  });
}

export async function onRequestGet(context) {
  const env = context.env || {};
  const base = env.COORDINATOR_URL;
  const token = env.COORDINATOR_TOKEN;

  if (!base || !token) {
    // Honest degradation — never fabricate a workspace list (principle 4).
    return json(
      {
        ok: false,
        error:
          'Intake workspaces proxy not configured: COORDINATOR_URL / ' +
          'COORDINATOR_TOKEN bindings are required (server-side only — ' +
          '§9.1/§9.2). No workspace list can be served.'
      },
      503
    );
  }

  const upstream = new URL(base.replace(/\/+$/, '') + '/request');
  upstream.searchParams.set('op', COORDINATOR_OP);

  let resp;
  try {
    resp = await fetch(upstream.toString(), {
      method: 'GET',
      headers: { authorization: 'Bearer ' + token, accept: 'application/json' }
    });
  } catch (e) {
    return json(
      {
        ok: false,
        error: 'Coordinator unreachable from the Intake workspaces proxy: ' +
          (e && e.message ? e.message : String(e))
      },
      502
    );
  }

  if (resp.status === 401 || resp.status === 403) {
    return json(
      { ok: false, error: 'Coordinator rejected the Intake bearer token (§9.1)' },
      502
    );
  }

  const text = await resp.text();
  if (!resp.ok) {
    // Pass the engine's reject through verbatim (mirrors board.js / inbox.js).
    return new Response(text, {
      status: resp.status,
      headers: {
        'content-type': 'application/json; charset=utf-8',
        'cache-control': 'no-store',
        'x-intake-read-only': 'true'
      }
    });
  }

  let body;
  try {
    body = JSON.parse(text);
  } catch (e) {
    return json(
      { ok: false, error: 'work-snapshot returned non-JSON: ' + (e && e.message ? e.message : String(e)) },
      502
    );
  }

  // Project DOWN. Only `project_ref` strings — the dropdown does not need
  // anything else. Sorted for stable presentation (the user picks by eye).
  const projects = Array.isArray(body && body.projects) ? body.projects : [];
  const seen = new Set();
  const workspaces = [];
  for (const p of projects) {
    const ref = p && typeof p.project_ref === 'string' ? p.project_ref : '';
    if (!ref || seen.has(ref)) continue;
    seen.add(ref);
    workspaces.push(ref);
  }
  workspaces.sort();

  return json({ ok: true, workspaces: workspaces }, 200);
}
