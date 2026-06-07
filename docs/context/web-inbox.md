# Context: The Inbox page (UX Flow B — "waiting on you")

> One-liner: the phone's decision surface — render a §5 Dossier as the document
> that *is* the form, resolve its Items in any mix, confirm it landed, and see
> Flow-G failures. Plus the PWA (service worker + push subscription). The
> renderer is deliberately **tolerant**; the one refusal is the §0.3 schemaGate.

**Read this doc when** your task touches: anything under `beads-runner/web/inbox/`
(the renderer/verbs/PWA), or the inbox Pages proxies under
`web/functions/api/inbox/`. The driving question is Flow B: *"something is waiting
on me — let me read it, decide, and know it landed, without going to ask."*

**Owns / scope (the files this doc covers):**
- `web/inbox/inbox-view.js` — the **pure, headless core**: `(Dossier / §4.5
  snapshot) → view model` and `(form-state) → §5.2 response`. No DOM/network/timers.
- `web/inbox/app.js` — browser glue: hash-routes, fetches the credential-less
  proxies, collects per-Item form state, renders, the inbox verbs.
- `web/inbox/{push.js, sw.js, manifest.webmanifest, icon.svg}` — the PWA: the
  phone end of the push pipeline (subscribe + wake-on-push + deep-link).
- `web/inbox/{index.html, inbox.css}` — the shell (reuses the Board visual language).
- `web/functions/api/inbox/{index,dossier,respond,defer,escalate,snooze,expire,forensic}.js`
  — one server-side proxy per verb, each pinning exactly one engine op.

**Not here (go to the right doc):**
- The push DELIVERY pipeline end-to-end (engine trigger → web-push → daemon poll
  → this sw.js) → `notifications.md`. `push.js`/`sw.js` are only its phone *end*.
- The engine dossier/forensic/notification modules → `engine-cloudflare.md`.
- The app shell, `/shared/*`, the unified Pages project, deploy+verify →
  `web-shell.md` (**READ FOR ANY WEB TASK**).
- The Board (Flow E) → `web-board.md`; Intake (Flow A) → `web-intake.md`.
- The MCP server that *authored* the dossier → `mcp-askbrian.md`.
- The frozen §-contracts (§5/§4.5/§0.3/S-2) → `contracts-and-design.md`.

---

## Mental model

Four facts explain the page:

1. **Presentation only — zero control logic.** This surface maps a §5 Dossier to
   pixels and a form to a §5.2 `response`; it **never applies** anything.
   Consequence application, the §7.4 per-Item idempotency latch, the §5.2.2
   deterministic-vs-reconciler *routing*, and the S-2 control→work reconcile are
   all the engine/T5's. The Inbox honestly *previews* the split and *reads back*
   the latch — it never re-derives state.

2. **The doc IS the form (§5.2).** Each Item's `kind` (a closed enum) *is* its
   response affordance — the renderer derives the control from `kind`, never
   invents one. The mandatory `context_anchor` renders inline (self-contained
   context). Partial resolution is first-class: you answer one Item per submit and
   leave the rest open with no penalty.

3. **Tolerance at render, conformance at write (the 4xe scar — see below).**
   Every dossier field that is missing/malformed degrades to a clearly-LABELED
   best-effort fallback recorded in a `degraded[]` note — never a silent
   fabrication, never a blank wall. A dossier the engine *accepted* (incl. legacy
   pre-gate records) is ALWAYS readable AND answerable.

4. **One refusal only: the §0.3 integer schemaGate.** An unknown *higher*
   `schema_version`/`dossier_schema_version` is refused with a plain-English "this
   was made by a newer app, update to open it" message — a vN renderer genuinely
   cannot honor a v(N+1) artifact, so best-effort would be a lie. Everything else
   renders. **Never re-add any other render refusal.**

## Key files

| File | Role |
|---|---|
| `inbox-view.js` | The pure core. `deriveInboxList` (§4.5 lane + Flow-G glance, ranked newest-first — also derives the **`kind:"pair"` third mode**: `upcoming`↔`ready` off `scheduled_at`, painted as "ready to pair on X" never "decide X", DESIGN N §4.4 / claude-tools-uxg6), `deriveDossierView` (the §5 render model — the ONE refusal lives here), `deriveItem` (always answerable, never `{missing}`), `buildItemResponse` (form→§5.2 payload + honest deterministic/reconciler preview), `deriveConfirm` (S-2 no-Dolt-lag ack), `deriveFailureView` (Flow-G tiers 1–2 + §10.3 affordance). `schemaGate`/`unknownHigher` = the §0.3 gate. `looksLikeMermaid` = byte-port of the engine/bash predicate. `blueprintFocusLink` = the §6.4 dossier↔Blueprint bridge classifier (claude-tools-uxg3). |
| `app.js` | Browser glue. Hash routes: `#/`→list, `#/d/<id>`→dossier, `#/f/<bead>`→failure. Renders diagrams (Mermaid→SVG, the authoritative parse), submits the verbs, polls `/api/inbox`. No control logic. |
| `push.js` | N2 web-push subscribe glue: registers `sw.js`, captures Notification permission + `PushSubscription`, POSTs it to `/api/push/subscribe`. Holds only the PUBLIC VAPID key (private half is a Worker secret). |
| `sw.js` | The service worker. Does exactly two things: `push`→show a TRIAGE-only notification from `{tldr,dossier_ref,tier,url}` (the §5 body NEVER crosses the wire); `notificationclick`→focus/open the Inbox at the deep link. Deliberately NOT an offline cache (S-1: never serve a stale projection). |
| `manifest.webmanifest` / `icon.svg` | PWA install metadata, scope `/inbox/`. |
| `functions/api/inbox/index.js` | GET `/api/inbox` → op `work-snapshot` (§4.5 read). `onRequestGet` only. |
| `…/dossier.js` | GET `/api/inbox/dossier?id=` → op `get` + type `dossier`. |
| `…/respond.js` | **The one write path.** POST `/api/inbox/respond` → op `item-apply` (T5's idempotent per-Item applier). UI submits a response; never applies. |
| `…/defer.js` / `…/escalate.js` | POST → op `dossier-defer` (tier→digest) / `dossier-escalate` (tier→blocking). Attention-tier moves only; resolve nothing. |
| `…/snooze.js` | POST `/api/inbox/snooze` → op `dossier-snooze` `{dossier_id, snooze_until}` (claude-tools-653d). DEFERS now (tier→digest) AND arms the §2.2 timer to RE-SURFACE (not auto-proceed) at the user-set future instant; the proxy guards the RFC-3339 shape + future-ness. UI = preset chips (1h/3h/Tomorrow/Next week) computing an RFC-3339 `Z` client-side. The fire-action (`snooze-surface`) lives in `cf/src/timer.js`, NOT a dossier op. |
| `…/expire.js` | POST `/api/inbox/expire` → op `item-set-state` + target `expired` (the "dismiss as stale" verb). |
| `…/forensic.js` | GET op `forensic-fetch` + POST op `forensic-dismiss` (§10.3 on-demand redacted blob; hard-delete). No put/sweep op is client-reachable. |

## Contracts & invariants (don't break these)

- **The renderer is tolerant; never re-add a render refusal (4xe).** The §5.1
  conformance gate is at the engine's ONE dossier write path; this renderer's
  job is the complement — every accepted dossier stays readable + answerable.
  `deriveItem` ALWAYS returns `{ item }`. The ONLY refusal is `unknownHigher`.
- **`kind` is a closed enum; the affordance is derived from it.** Don't invent a
  control. An unknown/absent kind degrades to a freeform answer (still answerable),
  never a dropped item.
- **No fabrication.** A missing mandatory field becomes a labeled `degraded[]`
  placeholder, never an invented value and never a silent `<pre>` posing as a
  rendered diagram.
- **Each proxy pins exactly one op server-side; the browser holds no secret**
  (§9.1/§9.2). The client never picks the principal or the op. Unset
  `COORDINATOR_URL`/`COORDINATOR_TOKEN` bindings ⇒ honest `503`, never a fabricated
  answer.
- **The ack reads the latch, not Dolt (S-2).** `deriveConfirm` derives "it
  landed" strictly from the re-fetched §4 Dossier's per-Item
  `state`/`consequence_applied` — the control-plane truth the Coordinator
  reconciles into beads — so "you don't need to go check" carries no Dolt-lag lie.
- **Post-action UI state DERIVES from the engine record — no in-memory patch
  (inbox-lifecycle §6.4; claude-tools-uxa2).** Every action reconciles by
  RE-FETCHING the §4 record (`refetchAck`/`loadDossier`), never by hand-bumping a
  local counter. The "N / total resolved" DOM (`progN`) is written in exactly ONE
  place — `recount()`, deriving from `curView.items[].terminal` (engine-derived) +
  staged `formState` (reset to `{}` on every re-fetch); `curView` is assigned in
  exactly ONE place (`loadDossier`, from `deriveDossierView` of a fresh GET). This
  is what kills the §6 "shows 0/1 resolved after the engine already resolved" drift.
  Regression-locked by the `claude-tools-uxa2` section in `test-inbox.sh`.
- **The deterministic/reconciler split is mirrored, never re-decided.**
  `isDeterministicResponse` is the exact mirror of `consequence.sh
  do__is_deterministic`. The preview must never promise "instant" for an
  edit/freeform/object (those are the reconciler path). Change one → change both.
- **The §5 body never crosses the push wire** (principle 2). `sw.js` shows only
  the TL;DR + a deep link; the full dossier is fetched in-app over the authed proxy.
- **Forensic (§10.3) is on-demand only** — never in the projection, never
  auto-fetched, never in a notify/digest body.

## Common changes (recipes)

**Tweak how a dossier field renders / add a tolerant fallback:**
Edit the derive in `inbox-view.js` (e.g. `deriveDossierView`/`deriveItem`); push
a labeled note into `degraded[]` for any gap. Then paint it in `app.js`. Drive it
headless via `bash beads-runner/lib/test-inbox.sh` (171 assertions against the REAL
`dg_generate` producer + `do_item_apply` applier — not a hand-faked shape).

**Add/change an inbox verb (a new button → engine op):**
1. New Pages proxy `web/functions/api/inbox/<verb>.js` pinning exactly one op
   (copy `defer.js`); strip any client `principal`, attach `Bearer` server-side,
   503 on unset bindings, pass the engine response verbatim.
2. The op must exist in the engine + (if needed) the pages-dev `adapter.js`
   (`engine-cloudflare.md`'s add-an-op checklist — the 2dk forgotten-layer scar).
3. Wire the button in `app.js` (`Net.postJSON('/api/inbox/<verb>', …)`); show an
   honest toast on failure.

**Situate a decision on the map (the dossier↔Blueprint bridge, §6.4):** the
producer puts the Blueprint facet's `?focus=<id>` deep-link
(`/ws/<ref>/blueprint?focus=<node-id>`) in a §5.2 `context_anchor.link` (an
existing optional field — **no schema bump**). `inbox-view.js
blueprintFocusLink` classifies it (and scheme-guards it — only `http(s)`/root-
relative, so the first content-derived href can't be a `javascript:` foot-gun) →
`context_anchor.blueprint_focus {href,ref,node_id}`; `app.js renderItem` paints
it as the `.du-bp` "Where this sits in the Blueprint" affordance (same-app nav;
H3's `/ws/<ref>/blueprint` route resolves it). The dossier **borrows** a
focus-view — it never renders the map. A non-blueprint / absent `link` mints no
bridge and paints nothing extra (the raw `link` stays on the view model but is
not surfaced — tolerant, no wall). Bridge ref doc: `dossier-builder.system.md`
context_anchor row.

**Touch the PWA (push/subscribe/notification):** edit `push.js`/`sw.js`, but the
delivery contract (payload shape `{tldr,dossier_ref,tier,url}`, VAPID pairing,
daemon poll) is owned by `notifications.md` — coordinate there.

**The gate before `bd close` (this is a WEB task — the bgw lesson):**
```bash
bash beads-runner/lib/test-inbox.sh                          # headless renderer suite
bash beads-runner/run-tests.sh --changed                     # offline regression gate
(cd beads-runner/web && npx wrangler pages deploy . --project-name claude-wrangler)
bash beads-runner/verify-pages-deploy.sh inbox               # MUST print mismatches=0
```
Code committed + local green is **not** done. Done = the live host serves the new
bytes (`mismatches=0`).

## Gotchas / scars

- **4xe (the load-bearing scar, a bd memory).** The prior "refuse a malformed
  dossier" line was the *bug*. Conformance moved to WRITE; the renderer is
  tolerant. See `bd memory 4xe-write-gate-render-tolerance` — never re-introduce
  a render refusal beyond `unknownHigher`.
- **56h — the lane was unskimmable.** Nine identical "1 thing needs you" rows.
  Fixed by joining skim fields (tldr/created_at/kind) onto each lane entry, a
  short `dossier_short` id badge, a `time_ago`, and newest-first sort within tier.
  Keep the lane distinguishable.
- **`schema_version` is integer-typed at the gate.** A JSON string `"1"`, float,
  or bool fails `schemaGate` (mirrors the engine/bash type-check). A *missing* or
  ≤bound version still renders tolerantly; only an unknown *higher* refuses.
- **Diagrams: `looksLikeMermaid` is a byte-for-byte port** of `dossier-gen.sh
  dg__is_mermaid` AND `cf/src/dossier.js looksLikeMermaid` (the §8bm differential
  requirement: split on `\n` only, ASCII space/tab only — never `\s`). Don't
  "improve" it locally; the three must stay equal. A non-Mermaid diagram renders
  as a labeled warning block, never a silent `<pre>`.
- **B3 degraded-author badge.** `body.authored_by:"fallback"` means the
  dossier-builder agent failed and the jq shape-coercer ran; surface it distinctly
  (lower-quality), not as a generic degraded note. Absent ⇒ "unknown" (legacy), not
  fallback.
- **`expire` only does `open→expired`.** The engine's `dossier.js stateCheck`
  rejects an `answered` item; `app.js` hides the verb when it wouldn't move and an
  illegal attempt reads back as still-open (no false success).
- **`sw.js` is intentionally cache-free.** Don't add a fetch handler — a cached
  projection would lie about liveness/decision state (S-1).
- **A `kind:"pair"` card is a 0-Item SESSION card, not a decide dossier (uxg6/N3).**
  It carries `scheduled_at`, not Items — render "ready to pair on X", never decide
  affordances. `upcoming` (before `scheduled_at`) is a deferred card that does NOT
  push; the §2.2 timer fires at the appointment → `pairSurface` promotes it to
  `ready` + emits the blocking `ready_to_pair` notif (delivered by N2, **not**
  auto-proceed). The producer is `pair-create` (CLI `pair-create.sh` / engine op,
  claude-tools-l6vx); the surface fire-action is `cf/src/timer.js pairSurface`.

## Go deeper

- `beads-runner/web/inbox/README.md` — the §-by-§ bind table + the anti-drift "NOT
  here" list (read fully before a structural change).
- `docs/inbox-lifecycle.md` — the deep Flow A/B lifecycle source (five-stage
  contract; 1032 lines — skim the relevant stage, don't read all).
- `beads-runner/UX-DESIGN-V2.md` Flow B (the decision loop) + §5.6 (defer/escalate).
- `beads-runner/lib/test-inbox.sh` — the executable spec for the renderer/payload core.
- `bd memory 4xe-write-gate-render-tolerance` — the tolerance invariant, in force.

## Keeping this doc current

When you finish a task here, append anything a future agent will need and didn't
find: a new verb/proxy pattern, a moved derive, a fresh degraded-fallback, a new
scar, a changed §5/§4.5 field, a PWA payload change. **Keep it concise — this doc
earns its keep only if agents read all of it.** Delete stale lines; don't let it
grow into a copy of the README or INTERFACE.md. Last substantive update: 2026-06-07.
