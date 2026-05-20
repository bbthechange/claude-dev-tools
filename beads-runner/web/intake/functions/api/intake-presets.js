/* beads-runner/web/intake/functions/api/intake-presets.js — I4 (claude-tools-vvh).
 *
 * The Intake's PRESET CATALOG read proxy. The phone UI calls this same-
 * origin GET on page load to learn the canonical entry-intent presets
 * (UX-DESIGN Flow A) and render one radio card per row. There is no
 * upstream engine call here — the catalog lives entirely in the Pages
 * deployment (it is the same data both proxies frozen-import from
 * `_presets-catalog.js`), so the endpoint is fast and offline-resilient
 * against the Coordinator.
 *
 * WHY A READ PROXY AT ALL (vs. inlining the radios in index.html):
 *   The I4 acceptance says "presets are a single source of truth that
 *   both the UI and the enricher consume". If we hard-coded the radios
 *   in `index.html`, the UI would drift from `_presets-catalog.js` (the
 *   write-proxy's allowlist), and adding a new preset would be a
 *   two-step UI+proxy update with no enforcement. Serving the catalog
 *   from the same module that `intake.js` validates against collapses
 *   the drift surface to one file.
 *
 * SAME §9.1 / §9.2 DISCIPLINE AS THE SIBLING PROXIES:
 *   - Read-only by construction: only `onRequestGet` is exported.
 *   - No secret in the browser; no principal selection client-side.
 *   - The response is JSON, no-store (so a deploy that adds a preset
 *     does not get served from an HTTP cache).
 *
 * RESPONSE SHAPE:
 *   { ok: true, schema_version: 1, presets: [ { value, label, sublabel,
 *     entry_stage, gate_aggressiveness, description }, ... ] }
 *
 * The `description` field is included so an agent inspecting the wire
 * payload (a debug curl, a CI smoke test) can read the same one-line
 * meaning the catalog file shows — no "had to read the source to know
 * what this preset means" hop.
 *
 * BINDS INTERFACE.md v1:
 *   This endpoint does NOT cross §9.1 — it does not call the Coordinator.
 *   It serves a static catalog the Pages deployment carries. The §9.1
 *   chokepoint is still the only path to the engine; nothing about that
 *   shape changes here.
 */

import { PRESETS, SCHEMA_VERSION } from './_presets-catalog.js';

function json(body, status) {
  return new Response(JSON.stringify(body), {
    status: status || 200,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      // The catalog is frozen at deploy time; a UI that booted before a
      // catalog-change deploy would otherwise paint stale radios from a
      // CDN cache. The cost of `no-store` is one round-trip per page
      // load — negligible against an intake's ~5-second budget.
      'cache-control': 'no-store',
      'x-intake-read-only': 'true'
    }
  });
}

export async function onRequestGet() {
  return json({ ok: true, schema_version: SCHEMA_VERSION, presets: PRESETS }, 200);
}
