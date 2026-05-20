/* beads-runner/web/intake/functions/api/_presets-catalog.js — I4 (claude-tools-vvh).
 *
 * Pages-side MIRROR of `beads-runner/agents/intake-presets.json` (the
 * canonical entry-intent preset catalog; UX-DESIGN Flow A, I4 spec).
 *
 * WHY THE MIRROR (read this twice):
 *   Cloudflare Pages Functions cannot read the repo's `agents/` tree at
 *   request time — they only see files inside their own deployment root
 *   (`web/intake/`). The honest options were:
 *     1. Bundle the JSON via a build step. (Vetoed — `intake/README.md`
 *        says "No build step."; we want this app to stay diff-readable.)
 *     2. Mirror the catalog inline here and link the two files in the
 *        docs (one PR touches both — see `agents/intake-presets.md`,
 *        "Adding a preset — the one-PR playbook").
 *   We took (2). The mirror is one file in one location; both proxies
 *   (`intake.js` write + `intake-presets.js` read) import it, so a drift
 *   between the mirror and the engine-facing allowlist is impossible.
 *   A drift between THIS file and `agents/intake-presets.json` is what
 *   the playbook PR is designed to prevent.
 *
 * UNDERSCORE PREFIX:
 *   Cloudflare Pages Functions treat files whose basename starts with `_`
 *   as NON-ROUTABLE — so this module is import-only; it does NOT register
 *   `/api/_presets-catalog` as a public route. (The public read endpoint
 *   is `/api/intake-presets`, served by `intake-presets.js`, which
 *   imports this file.)
 *
 * SHAPE CONTRACT:
 *   Each entry has the exact same five fields as the canonical JSON:
 *     - `value`               (string, opaque id; the preset key)
 *     - `label`               (string, UI radio title)
 *     - `sublabel`            (string, UI radio subtitle)
 *     - `entry_stage`         (one of: idea | ux | design | impl | docs | tests)
 *     - `gate_aggressiveness` (one of: auto-advance | gate-human)
 *     - `description`         (string, one-line meaning)
 *   Order is the UI radio order; index 0 is the default selection.
 *
 *   The schema is FROZEN with the canonical JSON. Changing the shape (a
 *   sixth field, a renamed key) is a deliberate I4-shape change, not a
 *   catalog row addition — it would require updating every consumer in
 *   the same PR.
 */

export const SCHEMA_VERSION = 1;

// Object.freeze on each row + the outer array, so a stray future mutation
// (e.g., a test that did `PRESETS.push(...)`) cannot silently poison the
// Worker isolate that both proxies share. The "FROZEN at v1" comment in
// the header is then enforced at runtime, not just by convention.
export const PRESETS = Object.freeze([
  Object.freeze({
    value: 'autonomous-until-stuck',
    label: 'Send it down the pipeline',
    sublabel: '…until it gets reasonably stuck.',
    entry_stage: 'impl',
    gate_aggressiveness: 'auto-advance',
    description:
      'Default. No human gate on pickup; the runner picks the bead up ' +
      'at stage:impl and only surfaces if a worker hits a real fork ' +
      '(STUCK_NEEDS_HUMAN).'
  }),
  Object.freeze({
    value: 'collaborative-stage',
    label: 'Go over the UI with me',
    sublabel: 'I want to collaborate at the stage where it lands.',
    entry_stage: 'ux',
    gate_aggressiveness: 'gate-human',
    description:
      'Bead lands at stage:ux and is routed to the Inbox as ' +
      '"ready to pair" — the runner does NOT auto-pick-up. The human ' +
      'asked to be IN the stage, not just approve its output.'
  })
]);

// Convenience derived view — the allowlist `intake.js` validates against.
// Computed once at module load (PRESETS is FROZEN at v1).
export const ALLOWED_PRESET_VALUES = Object.freeze(
  PRESETS.map(function (p) { return p.value; })
);
