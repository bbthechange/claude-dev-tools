# Inbox + Flow-G — the decision web app (T6b · claude-tools-xre)

UX **Flow B/G**. The decision surface: render a §5 Dossier as the document
that *is* the form (Flow B step 4), resolve its Items in any mix, confirm it
landed (step 6), and see failure visibility (Flow G) without going to ask.

A Cloudflare **Pages** app shell that **reuses the T6a Board visual language**
(same tokens/fonts) — it does **not** reimplement the Board or the app shell,
and the UI is **presentation only** (no control logic). No build step, no
dependencies.

## What it binds (INTERFACE.md v1 — FROZEN)

| § | How this app binds it |
|---|---|
| **§5** | **Sole renderer** of the Dossier. §5.1 `body` (tldr · sections[] · diagrams[] · full_detail — **all mandatory**, AD7 skim→full). §5.2 per-Item affordance derived from `kind` ("the doc IS the form"); the **mandatory** `context_anchor` is rendered **inline** (AD7 self-contained-context). §5.2.1 profiles are emergent (one render path). §5.2.2 deterministic-vs-reconciler is mirrored to **honestly preview** "instant" vs "reconciler reads this" — it never *applies* (that is T5). |
| **§4.5** | Reads ONLY the read-only projection: the WAITING-ON-YOU lane (Dossier **pointers**, counts only) + Flow-G tiers 1–2 failure metadata (class + retry-state + `Runner:` notes). |
| **§10.3** | The forensic tier-3 is an explicit, authed, **on-demand** fetch + an explicit dismiss (hard-delete). It is never in the projection and never auto-fetched. |
| **§9.1 / §9.2** | The per-deployment bearer is a **server-side** Pages binding; the browser holds no secret and never picks the principal/op. Each proxy pins exactly one op. |
| **§0.3** | An unknown **higher** `schema_version` / `dossier_schema_version` is **refused**, never best-effort-rendered. |
| **S-2** | The step-6 ack is derived from the re-fetched §4 Dossier's §7.4 per-Item latch — the **control-plane** truth the Coordinator reconciles into beads — **never** a beads/Dolt read. So the bead unblocks with **no Dolt-lag lie**. |

## Files

- `inbox-view.js` — **the pure, headless-testable core.** `(§5 Dossier / §4.5
  projection) → view model`, and `(form-state) → §5.2 response`. No DOM, no
  network, no timers. Every §5 bind / §0.3 refusal / honest deterministic-vs-
  reconciler preview / honest ack lives here. `lib/test-inbox.sh` drives this
  against the **real** T5 producer (`dg_generate`), applier (`do_item_apply`)
  and the §10.3 forensic store.
- `app.js` — browser glue only: hash-routes, fetches the credential-less
  proxies, collects per-Item form state, submits **one response per resolved
  Item** (partial is first-class — AD7), re-fetches for the honest ack.
- `functions/api/inbox.js` — GET proxy, op pinned `work-snapshot` (§4.5 read).
- `functions/api/dossier.js` — GET proxy, op pinned `get` + type `dossier`
  (the §4 record the lane points at).
- `functions/api/respond.js` — **the one write path**: POST proxy, op pinned
  `item-apply` (T5's idempotent per-Item applier). The UI submits a response;
  it never applies one. No Dolt write.
- `functions/api/forensic.js` — GET `forensic-fetch` + POST `forensic-dismiss`
  (§10.3). No put/sweep op is client-reachable.
- `index.html` + `inbox.css` — responsive shell, T6a visual language.

## Deliberately NOT here (anti-drift)

- **No Board / app-shell reimplementation** (T6a owns it). This app reuses the
  visual language and is a sibling surface.
- **No control logic.** Consequence application, the §7.4 per-Item latch, the
  §5.2.2 deterministic/reconciler *routing*, and the S-2 control→work
  reconcile are **T5's**. The UI maps a form to a §5.2 `response` and submits
  it; it derives the ack from the latch, never from Dolt.
- **No fabrication.** A mandatory §5 field that is absent (a `body` tier, or a
  per-Item `context_anchor`) is a **§11 BLOCKING escalation** to
  claude-tools-65z — surfaced as an honest refusal view, never a UI-side
  invention.
- **No forensic stream in the projection.** Only Flow-G tiers 1–2 metadata
  (which IS in §4.5) is shown; the tier-3 redacted stream is the explicit
  on-demand §10.3 pull.

## Deploy (non-normative — Appendix A)

Cloudflare Pages, root = `web/inbox/`. Required env bindings (server-side
only — §9.1/§9.2; never committed):

- `COORDINATOR_URL` — base URL of the Coordinator's §2.3 authed endpoint.
- `COORDINATOR_TOKEN` — the per-deployment bearer secret.

Unset bindings ⇒ every proxy returns an honest `503` (it never fabricates).

## Test

```bash
bash beads-runner/lib/test-inbox.sh   # 81 assertions, EXIT crit 1–3 + anti-drift
```

Drives the renderer/payload-builder against the **real** T5 `dg_generate`
producer, the **real** `do_item_apply` per-Item applier (pure-checkbox
round-trip, S-2 no-Dolt-lag-lie, partial resolution), the §0.3 refusals, the
§11-escalation-not-fabrication anti-drift, the Flow-G leak guard, and the
§10.3 forensic round-trip. Not a member of the T1 conformance suite
(T1a/T1b own that); T6b's own focused surface.
