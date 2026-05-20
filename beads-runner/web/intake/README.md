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
- `app.js` — browser glue only. Two network calls:
  - `GET  /api/workspaces` once on load (populates the picker).
  - `POST /api/intake` on submit (the I2 write proxy).
- `functions/api/workspaces.js` — Pages Function read proxy. `onRequestGet`
  only; upstream op hard-coded to `work-snapshot`; projects the response
  down to a sorted list of `project_ref` strings.
- `functions/api/intake.js` — I2 (claude-tools-x9u) write proxy.
  `onRequestPost` only; upstream op hard-coded to `put`; record type
  hard-coded to `intake-request`; preset allowlist frozen here. Already
  shipped by I2 — this app is its first caller.

## The preset list

UX-DESIGN Flow A names two presets; both are exposed as radio cards (the
default selection is `autonomous-until-stuck`):

| value | label | meaning |
|---|---|---|
| `autonomous-until-stuck` | Send it down the pipeline | …until it gets reasonably stuck. |
| `collaborative-stage` | Go over the UI with me | I want to collaborate at the stage where it lands. |

The list is intentionally **extensible**. Adding a new preset is a
deliberate two-step code change:

1. Append the value to `ALLOWED_PRESETS` in
   `functions/api/intake.js` (proxy-side allowlist — typo'd presets get
   422'd before the engine burns a round-trip).
2. Add a radio card to `index.html`. Update the enricher hat so it knows
   what to do with the new value.

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

Cloudflare Pages, root = `web/intake/`. Required environment bindings
(server-side only — §9.1/§9.2; never committed):

- `COORDINATOR_URL` — base URL of the Coordinator's §2.3 authed endpoint.
- `COORDINATOR_TOKEN` — the per-deployment bearer secret.

Unset bindings ⇒ both proxies return an honest `503` (they never fabricate
a workspace list and never claim to have enqueued a submission — principle
4).

## Acceptance (I1)

Brian on his phone navigates to `/intake`, types one sentence, picks a
workspace + preset, submits; the request lands in the engine; the Board
reflects the new bead within seconds.
