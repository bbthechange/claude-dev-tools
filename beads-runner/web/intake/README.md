# Intake — the phone Flow A entry surface (I1 · claude-tools-tbl)

UX **Flow A** (`UX-DESIGN.md`). One text box + project picker + preset
chooser. Brian taps the icon, types one sentence, taps Submit — ~5 seconds
of effort. The submission lands as an `intake-request` record (§4); the
daemon picks it up on its next sweep and dispatches the enricher; the Board
reflects the new bead within seconds (I1 ACCEPTANCE).

A Cloudflare **Pages** app (Appendix A realization; INTERFACE.md §0.2 —
provider primitives are **non-normative**, the contract is the §-clauses).
No build step. No dependencies.

## What it binds (INTERFACE.md v1 — FROZEN)

| § | How this app binds it |
|---|---|
| **§9.1 / §9.2** | The per-deployment bearer is a **server-side** Pages binding; the browser holds no secret and never picks the principal/op. Both proxies (read + write) hard-code their op. |
| **§4** | The one write is exactly one `intake-request` record. The §9.1 chokepoint stamps `principal` server-side — the client never sends it. |
| **§4.5** | The workspace dropdown is filled from the read-only `work-snapshot` projection's `projects[].project_ref`. No second engine op was added for this. |
| **§0.3** | The proxies pass through honest engine errors verbatim — unknown type / unsafe id / schema_version mismatch — never best-effort-rewritten. |

## Files

- `index.html` — phone-first form (one textarea, one `<select>`, radio-card
  preset chooser, big amber Submit). Reuses the T6a/T6b tokens + fonts —
  same product, not a third look.
- `intake.css` — `--tap: 44px` floor, no hover-only states, 16px+ font sizes
  to dodge iOS auto-zoom, layout that survives the on-screen keyboard.
- `app.js` — browser glue only. Three network calls:
  - `GET  /api/intake/presets` once on load (catalog → preset radios).
  - `GET  /api/intake/workspaces` once on load (populates the picker).
  - `POST /api/intake` on submit (the I2 write proxy).
- `../functions/api/intake/workspaces.js` — Pages Function read proxy
  (`/api/intake/workspaces`). `onRequestGet` only; upstream op hard-coded to
  `work-snapshot`; projects the response down to a sorted list of
  `project_ref` strings.
- `../functions/api/intake/index.js` — I2 (claude-tools-x9u) write proxy
  (`/api/intake`). `onRequestPost` only; upstream op hard-coded to `put`;
  record type hard-coded to `intake-request`; preset allowlist imported from
  the I4 catalog mirror (`_presets-catalog.js`) so the UI and the write
  validator cannot drift.
- `../functions/api/intake/presets.js` — I4 (claude-tools-vvh) catalog read
  proxy (`/api/intake/presets`). `onRequestGet` only; serves the preset
  catalog the UI renders its radio cards from. No engine round-trip; the data
  lives entirely in `_presets-catalog.js`.
- `../functions/api/intake/_presets-catalog.js` — I4 (claude-tools-vvh)
  Pages-side mirror of `agents/intake-presets.json` (the canonical catalog).
  Underscore-prefixed → non-routable; imported by both proxies above.

## The preset list

The catalog is **catalog-driven, not hard-coded**. The UI fetches
`/api/intake/presets` on page load and renders one radio card per row.
The canonical source of truth is
**`beads-runner/agents/intake-presets.json`**; the unified Pages tree carries
a 1-for-1 mirror at `web/functions/api/intake/_presets-catalog.js` that both
proxies import.

v1 catalog (see `beads-runner/agents/intake-presets.md` for the full
table and the add-a-preset playbook):

| `value` | label | `entry_stage` | `gate_aggressiveness` |
|---|---|---|---|
| `autonomous-until-stuck` (default) | Send it down the pipeline | `impl` | `auto-advance` |
| `collaborative-stage` | Go over the UI with me | `ux` | `gate-human` |

**Adding a preset is a documented one-PR change** — see
`beads-runner/agents/intake-presets.md` "Adding a preset — the one-PR
playbook". The playbook is: one row in the JSON, one mirror row in
`web/functions/api/intake/_presets-catalog.js`, one bullet in
`agents/enricher.system.md`, one `value:gate_aggressiveness` data row in
`gate-policy.sh` `PRESET_ENUM` (no code branch — the verdict is derived,
claude-tools-uxgpre). No edit to `index.html` is required — the radios
re-render from the catalog on next deploy.

## Deliberately NOT here (anti-drift)

- **No client-side principal**. The §9.1 chokepoint stamps it server-side.
- **No second engine op for the workspace list.** `work-snapshot` already
  enumerates every stored `runner_state.project_ref`; the proxy projects it
  down. Adding a `list-projects` op would have widened the §9.1 surface.
- **No write affordance beyond `intake-request`**. Nothing here can
  set-desired, respond, or reach Dolt.
- **No voice-to-text**. The I1 spec marks this as bonus, not required —
  the native iOS/Android keyboard dictation already covers it; we don't
  ship a separate Web Speech path.

## Deploy (non-normative — Appendix A)

Cloudflare Pages, **unified** project `claude-wrangler` (root = `web/`). The
Intake is served at the `/intake` route prefix alongside `/board` and
`/inbox` (UX-DESIGN §2 "one responsive web app"; consolidation in
claude-tools-b59). Pages Functions live under
`web/functions/api/intake/...`. Required environment bindings (server-side
only — §9.1/§9.2; never committed):

- `COORDINATOR_URL` — base URL of the Coordinator's §2.3 authed endpoint.
- `COORDINATOR_TOKEN` — the per-deployment bearer secret.

Unset bindings ⇒ both proxies return an honest `503` (they never fabricate
a workspace list and never claim to have enqueued a submission — principle
4).

## Acceptance (I1)

Brian on his phone navigates to `/intake`, types one sentence, picks a
workspace + preset, submits; the request lands in the engine; the Board
reflects the new bead within seconds.
