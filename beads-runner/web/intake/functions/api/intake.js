/* beads-runner/web/intake/functions/api/intake.js — I2 (claude-tools-x9u).
 *
 * The Flow A INTAKE write proxy — the ONE legitimate write path for "phone
 * intake": one text box + project picker + preset chooser (UX-DESIGN Flow A).
 * It carries ONE intake-request record to the engine's §2.1 `put` op; nothing
 * here dispatches the enricher (that is I3 / claude-tools-06i, the daemon
 * polls for new intake-request records on its own cadence and runs the
 * enricher hat — split submission from dispatch keeps the proxy tiny).
 *
 * Same §9.1 chokepoint discipline as respond.js + set-desired.js: the
 * per-deployment bearer lives server-side only (a Pages env binding); the
 * browser holds no secret (§9.2) and never picks the principal — §9.1 stamps
 * the resolved PRINCIPAL_V1 on the intake-request record (the client MUST
 * NOT send a principal; if it does, it is ignored — the chokepoint is
 * authoritative, C4 seam).
 *
 * WRITE PATH IS NARROW BY CONSTRUCTION: only `onRequestPost` is exported AND
 * the upstream op is the HARD-CODED literal `put`, AND the §4 record type is
 * the HARD-CODED literal `intake-request`. There is no op the client can
 * select; no type the client can name; no set-desired/item-apply/forensic
 * verb is reachable; nothing here writes Dolt. A typo'd preset is rejected
 * with a 422 BEFORE we burn a Coordinator round-trip; the engine still owns
 * the authoritative schema gate (unknown type, unsafe id, §0.3) — unknown
 * workspace refs and unknown presets that this proxy somehow lets through
 * would still be rejected on the engine side.
 *
 * BINDS INTERFACE.md v1: §9.1 (the one chokepoint, token server-side), §2.3
 * (authed channel transport), §2.1 (put), §4 (intake-request is a v1 record),
 * §0.3 (schema_version int; the engine enforces).
 */

import { ALLOWED_PRESET_VALUES } from './_presets-catalog.js';

const COORDINATOR_OP = 'put';                    // §2.1 — FROZEN here.
const RECORD_TYPE = 'intake-request';            // §4 v1 — FROZEN here.
const RECORD_SCHEMA_VERSION = 1;                 // §0.3 / §4 — bound to engine SCHEMA_VERSIONS.

// Preset allowlist (UX-DESIGN Flow A). Sourced from the I4 catalog mirror
// (`_presets-catalog.js`), which is the same module the `/api/intake-presets`
// read proxy serves to the browser. A UI typo'd preset is a 422 here,
// BEFORE the engine burns a round-trip — and a UI / proxy drift on the
// allowlist is impossible by construction (one mirror, two importers).
// Adding a preset = a row in `agents/intake-presets.json` + a mirror row
// in `_presets-catalog.js` + a bullet in `agents/enricher.system.md`
// (the one-PR playbook in `agents/intake-presets.md`).
const ALLOWED_PRESETS = ALLOWED_PRESET_VALUES;

// project_ref format gate. Same shape as the engine's safeKey (the store-owner
// input hygiene gate in cf/src/schema.js): non-empty, no '..' segment, only
// [A-Za-z0-9._-]. We mirror it here so the proxy rejects malformed refs as a
// cheap first gate; the engine is still the authoritative gate, and unknown-
// but-well-formed refs pass through (the I3 daemon dispatch is what surfaces
// "no such workspace" — there is no live workspace list to consult here
// without burning a second round-trip per submission).
const SAFE_PROJECT_REF = /^[A-Za-z0-9._-]+$/;

// idea_text size cap. UX-DESIGN Flow A is "one text box, one sentence" — a
// few KB is plenty. A larger payload is almost certainly a bug or abuse; we
// reject before paying for a Coordinator round-trip. Engine has its own
// implicit ceiling (D1 cell size), but the failure mode there is much worse.
const MAX_IDEA_TEXT_BYTES = 8192;

function json(body, status) {
  return new Response(JSON.stringify(body), {
    status: status || 200,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store'
    }
  });
}

// Generate an intake-request id that:
//   • is safeKey-compliant (engine's store-owner hygiene gate — [A-Za-z0-9._-]
//     only, no '..'),
//   • is monotonic-ish so the daemon's poll-and-process loop has a natural
//     order to walk (timestamp prefix),
//   • carries enough entropy that two phone taps in the same millisecond do
//     not collide (the random suffix).
// The daemon never PARSES this id — it is opaque storage. Comments only.
function newIntakeId() {
  const ts = new Date().toISOString().replace(/[:.]/g, '-').replace(/Z$/, 'Z');
  // crypto.randomUUID is available in Workers runtime; fall back to Math.random
  // only as a belt-and-suspenders for older Pages runtimes.
  let suffix;
  try {
    suffix = (typeof crypto !== 'undefined' && crypto.randomUUID)
      ? crypto.randomUUID().replace(/-/g, '').slice(0, 12)
      : Math.random().toString(36).slice(2, 14);
  } catch (e) {
    suffix = Math.random().toString(36).slice(2, 14);
  }
  return 'intake-' + ts + '-' + suffix;
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
          'Intake proxy not configured: COORDINATOR_URL / COORDINATOR_TOKEN ' +
          'bindings are required (server-side only — §9.1/§9.2). No intake ' +
          'request can be submitted.'
      },
      503
    );
  }

  let payload;
  try {
    payload = await context.request.json();
  } catch (e) {
    return json(
      { ok: false, error: 'request body must be JSON {idea_text, project_ref, preset}' },
      400
    );
  }

  const ideaText =
    payload && typeof payload.idea_text === 'string' ? payload.idea_text.trim() : '';
  const projectRef =
    payload && typeof payload.project_ref === 'string' ? payload.project_ref.trim() : '';
  const preset =
    payload && typeof payload.preset === 'string' ? payload.preset.trim() : '';

  if (!ideaText) {
    return json({ ok: false, error: 'need idea_text (non-empty string — UX-DESIGN Flow A)' }, 400);
  }
  // Byte-size, not character-count, since the engine pays in bytes.
  if (new TextEncoder().encode(ideaText).length > MAX_IDEA_TEXT_BYTES) {
    return json(
      {
        ok: false,
        error:
          'idea_text exceeds ' + MAX_IDEA_TEXT_BYTES + ' bytes — Flow A is "one ' +
          'text box, one sentence"; this submission was NOT enqueued'
      },
      413
    );
  }
  if (!projectRef) {
    return json({ ok: false, error: 'need project_ref (non-empty string)' }, 400);
  }
  if (!SAFE_PROJECT_REF.test(projectRef)) {
    return json(
      {
        ok: false,
        error:
          'project_ref ' + JSON.stringify(projectRef) +
          ' is malformed — allowed [A-Za-z0-9._-], no "/" or ".."'
      },
      422
    );
  }
  if (!preset) {
    return json(
      { ok: false, error: 'need preset ∈ ' + JSON.stringify(ALLOWED_PRESETS) },
      400
    );
  }
  if (ALLOWED_PRESETS.indexOf(preset) < 0) {
    // 422 because the body is well-formed JSON but semantically invalid (the
    // preset list is frozen — UX-DESIGN Flow A). Extending the list is a
    // deliberate code change here + an enricher-hat update.
    return json(
      {
        ok: false,
        error:
          'unknown preset ' + JSON.stringify(preset) +
          ' — must be one of ' + JSON.stringify(ALLOWED_PRESETS)
      },
      422
    );
  }

  const id = newIntakeId();
  const now = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');

  // The §4 record. principal is INTENTIONALLY ABSENT — the §9.1 chokepoint
  // stamps it on the way in (C7; cf/src/coordinator.js _writeRecord). If the
  // client tried to inject one, the engine would overwrite it; we strip it
  // here as a defensive belt (matches respond.js's `delete response.principal`).
  const record = {
    schema_version: RECORD_SCHEMA_VERSION,
    id: id,
    idea_text: ideaText,
    project_ref: projectRef,
    preset: preset,
    processed: false,        // I3 daemon flips this to true once the enricher is dispatched
    submitted_at: now
  };

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
      // Mirror the named-JSON-body shape the adapter unwraps for `put`:
      //   { type, id, record } → positional opPut(principal, type, id, jsonStr)
      // The adapter re-stringifies `record` because opPut's third arg is a JSON
      // STRING (the engine parses it itself — matches the bash co__store_put
      // contract).
      body: JSON.stringify({ type: RECORD_TYPE, id: id, record: record })
    });
  } catch (e) {
    return json(
      {
        ok: false,
        error:
          'Coordinator unreachable from the intake proxy — your idea was NOT ' +
          'enqueued (honest, principle 4): ' +
          (e && e.message ? e.message : String(e))
      },
      502
    );
  }

  if (resp.status === 401 || resp.status === 403) {
    return json(
      { ok: false, error: 'Coordinator rejected the Intake bearer token (§9.1) — request NOT enqueued' },
      502
    );
  }

  const text = await resp.text();
  let upstreamBody = null;
  try {
    upstreamBody = JSON.parse(text);
  } catch {
    upstreamBody = null;
  }
  if (!resp.ok || !upstreamBody || upstreamBody.ok !== true) {
    // Pass the engine's reject through verbatim so the UI can surface the
    // real cause (unknown type / unsafe id / schema_version mismatch). The
    // engine is the authoritative gate; the proxy is only the cheap first one.
    return new Response(text, {
      status: resp.ok ? 502 : resp.status,
      headers: {
        'content-type': 'application/json; charset=utf-8',
        'cache-control': 'no-store'
      }
    });
  }
  // Success: return the engine ack PLUS the assigned intake id so the UI can
  // show a confirmation (the I1 phone UI shows "submitted: <id>" so Brian has
  // a handle to grep for if it doesn't show up on the Board within ~60s).
  return json({ ok: true, intake_id: id }, 200);
}
