# Board — the situational-awareness web app (T6a · claude-tools-p2m)

UX **Flow E**. Answers, in one screen: *"is anything waiting on me, and is the
machine healthy?"* (UX-DESIGN.md principle 4 — honest state).

A Cloudflare **Pages** app shell (Appendix A realization: "web app → Pages";
INTERFACE.md §0.2 — provider primitives are **non-normative**; the contract is
the §-clauses, not "Pages"). No build step, no dependencies.

## What it binds (INTERFACE.md v1 — FROZEN)

| § | How this app binds it |
|---|---|
| **§4.5** | Reads ONLY the read-only work-snapshot projection. No write path to Dolt; Dolt stays work-truth. |
| **§4.2** | Renders `liveness` (Coordinator-derived, **never** re-derived here) + the honest desired≠actual surface. A `stale` runner reads as `stale (last seen Nh ago)` and is structurally incapable of reading as `actual: running` (**S-1**). |
| **§9.1 / §9.2** | The per-deployment bearer is a **server-side** Pages binding; the browser holds no secret and never picks the principal/op. The Coordinator's one `authenticate→principal` chokepoint resolves the constant principal. |
| **§0.3** | An unknown **higher** snapshot `schema_version` is **refused**, never best-effort-rendered. |

## Files

- `board-view.js` — **the pure, headless-testable core.** `(§4.5 projection)
  → view model`. No DOM, no network, no timers. Every honest-state / S-1
  decision lives here. `lib/test-board.sh` drives this against the **real**
  projection from `coordinator.sh co__work_snapshot`.
- `app.js` — browser glue only. The **one** network call in the whole client
  is a credential-less, same-origin, read-only `GET /api/board`. No form, no
  POST, no mutation affordance.
- `../functions/api/board/index.js` — the Pages Function read proxy
  (`/api/board`): the §9.1 chokepoint, Board side. `onRequestGet` only; the
  upstream op is the hard-coded literal `work-snapshot`. No reader write path
  **by construction**. (Lives under the unified `web/functions/` tree per
  claude-tools-b59; the sibling write seam is
  `../functions/api/board/set-desired.js`.)
- `index.html` + `board.css` — responsive shell (phone-first → desktop),
  visual direction from `beads-runner/ux-mocks.html` v1.

## Deliberately NOT here (anti-drift)

- **The Inbox / dossier UI is T6b** (claude-tools-xre). The WAITING-ON-YOU
  lane is a *pointer* (`/inbox#<dossier_ref>` — same-host sibling route in the
  unified `claude-wrangler` Pages project, per UX-DESIGN §2 and the
  consolidation in claude-tools-b59) — it never renders dossier
  `body`/`items[]`. The anti-drift is a UI separation (T6a does not render the
  dossier surface), not a deployment separation.
- **The §10 forensic stream / fetch UI is T6b.** Only Flow G tiers 1–2
  failure metadata (`class` + `retry_state`) — which IS in §4.5 — is shown.
- **No UI-side derived state.** A field the Board needs but §4.5 does not
  emit is a §11 escalation to claude-tools-65z, not a fabrication. *Known
  presentation-only gap:* the ux-mock's numeric `5h%/7d%/spare` capacity
  gauges are **not** in the frozen §4.5 producer (which emits the §6.3 coarse
  `verdict`). Per the task NOTES precedence the contract wins and the mock is
  treated as not-yet-updated; machine-health is fully answerable from
  `verdict` + `liveness` + `desired≠actual` + `failure`, so this is **not**
  an escalation. Formatting `last_heartbeat_at` into "Nh ago" is presentation
  of a contract field, not derived state.

## Deploy (non-normative — Appendix A)

Cloudflare Pages, **unified** project `claude-wrangler` (root = `web/`). The
Board is served at the `/board` route prefix; the Inbox at `/inbox`; the
Intake at `/intake` (UX-DESIGN §2 "one responsive web app"). Pages Functions
live under `web/functions/api/{board,inbox,intake}/...`. Required environment
bindings (the bearer lives server-side only — §9.1/§9.2; never committed):

- `COORDINATOR_URL` — base URL of the Coordinator's §2.3 authed endpoint.
- `COORDINATOR_TOKEN` — the per-deployment bearer secret.

Unset bindings ⇒ the proxy returns an honest `503` (it never fabricates a
projection — S-1 / principle 4).

## Test

```bash
bash beads-runner/lib/test-board.sh   # 51 assertions, EXIT crit 1–4
```

Drives the renderer against the real `coordinator.sh` §4.5 producer (offline
runner S-1, healthy one-screen answer, schema reject, no-write-path by
structure). Not a member of the T1 conformance suite (T1a/T1b own that);
T6a's own focused surface.
