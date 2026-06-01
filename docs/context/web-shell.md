# Context: The frontend app-shell + shipping discipline

> One-liner: ONE unified Cloudflare **Pages** project (`claude-wrangler`, root =
> `web/`) where Board/Inbox/Intake + the facet routes are all routes *inside* it.
> Each page = a vanilla-JS IIFE `app.js` + a pure UMD view-model + CSS, plugged
> into the shared shell. The bearer lives server-side only; one deploy ships all.

**Read this doc FIRST for ANY web task.** It owns the cross-page plumbing every
page depends on: the shared modules (`net`/`dom`/`shell`/`enums`/`tokens`), the
Pages-Function proxy layer (the browser-side §9.1 chokepoint), the routing/header
config, and — non-negotiably — the **deploy-then-verify** discipline (the bgw
scar). A web task is NOT done at commit.

**Owns / scope (the files this doc covers):**
- `beads-runner/web/shared/` — `net.js` (`getJSON`/`postJSON`), `dom.js`
  (`mk`/`clear`/`el`), `shell.js` (`deriveNav`/`mount`/`parseWorkspacePath`),
  `enums.js` (Contract D closed sets), `tokens.css` (design tokens + nav chrome),
  `sw.js` + `sw-register.js` (the shared off-network read worker; §2.4).
- `beads-runner/web/functions/api/**` — the Pages-Function proxies (one per op).
- `beads-runner/web/_headers`, `beads-runner/web/_redirects` — Pages config.
- `beads-runner/verify-pages-deploy.sh` — the deploy-landed byte-compare gate.

**Not here (go to the right doc):**
- The individual pages and their `*-view.js` / `app.js` →
  `docs/context/web-board.md`, `web-inbox.md`, `web-intake.md`, `web-facets.md`.
- The engine the proxies call (the *real* §9.1 chokepoint, `work-snapshot`,
  ops) → `docs/context/engine-cloudflare.md`. The proxy is a thin pass-through;
  the engine owns auth, principal, and validation.
- Notification/push delivery as a pipeline → `docs/context/notifications.md`
  (the inbox PWA service worker + `web/functions/api/push/**` live there).
- The frozen contracts (Contract C/D themselves, INTERFACE §9.1/§9.2) →
  `docs/context/contracts-and-design.md`.

---

## Mental model

Four structural facts explain almost everything:

1. **One Pages project, many routes.** `claude-wrangler` is the *whole* web app;
   its root is `beads-runner/web/`. Board, Inbox, Intake, and the v2 facet routes
   (`/workspaces` `/capacity` `/cross-ws` `/ws/<ref>/<facet>`) are directories
   inside it. **One `wrangler pages deploy` ships every route at once.** There is
   no per-page project anymore (the old `claude-wrangler-{board,inbox,intake}`
   were retired in b59).

2. **Each page is the same three-part shape.** A page dir = `index.html` linking
   `/shared/tokens.css` + its own CSS, then `<script>`s for `/shared/shell.js`,
   its pure UMD view-model (`*-view.js`), and a thin `app.js` IIFE that fetches,
   calls `deriveXView(snapshot, now, opts)`, and paints the result. The view-model
   is **pure + Node-testable** (no DOM/network); `app.js` is the only glue.
   `Shell.mount({active})` paints the nav. Copy `board/` as the template.

3. **The browser holds no secret and never picks the op (§9.1/§9.2).** Pages run
   no auth. The browser calls a **same-origin** proxy at `/api/...` with NO
   credentials. The proxy (a Pages Function) hard-codes the upstream op, attaches
   the server-only `Bearer` (a Pages env binding), and calls the live Worker. The
   Worker's *one* `authenticate→principal` chokepoint resolves the constant
   principal. The client cannot select an op, send a principal, or hold a token.
   - **Read proxy** = `onRequestGet` only, op hard-coded (e.g. `work-snapshot`).
     POST/PUT/etc. hit the Pages 405 default — no write path from a reader.
   - **Write proxy** = `onRequestPost` only, op + type hard-coded, strips any
     client `principal`, cheap-validates the body, attaches `Bearer`, passes the
     engine response through verbatim.

4. **Deploy is a separate, required step from commit (the bgw scar).** Committed
   bytes do NOT reach the live host automatically. A web task is done only when
   `wrangler pages deploy` has run AND `verify-pages-deploy.sh` prints
   `mismatches=0` against `claude-wrangler.pages.dev`.

## Key files

| File | Role |
|---|---|
| `web/shared/net.js` | `Net.getJSON`/`postJSON`. Same-origin, credential-less. Reads body as text FIRST so a non-JSON 5xx surfaces honestly; `{ok:false,error}` envelopes throw the message verbatim. **No place to attach an `Authorization` header — by design.** UMD. |
| `web/shared/dom.js` | `Dom.el`/`clear`/`mk`. `mk` uses `textContent` (never `innerHTML`) — XSS-safe by construction. UMD. |
| `web/shared/shell.js` | The nav. `deriveNav(opts)` is PURE (Node-testable like a view-model) → `{global[], workspace}`; `mount(opts)` paints it into `#shell-nav`; `parseWorkspacePath(pathname)` reads `/ws/<ref>/<facet>`. `GLOBAL`/`FACETS` orders are FROZEN. UMD. |
| `web/shared/enums.js` | `Enums.*` — the Contract D closed sets shared verbatim with the engine (activity state, liveness dot+windows, done sub-state, notification tier, hold type, gate scope). `Object.freeze`d. Conformance test asserts byte-equivalence to the engine constant + §5.2. UMD. |
| `web/shared/tokens.css` | The `:root` design tokens + reset, linked FIRST by every page; also owns the `.shell-nav` chrome painted by `shell.js` + the `#offline-badge` chrome painted by `sw-register.js`. Presentation only. |
| `web/shared/sw.js` | The shared **off-network read** service worker (claude-tools-4zrn, §2.1/§2.4). Scope `/`. Static shell = stale-while-revalidate (boots offline); non-Inbox `/api/…` GET = network-first → last-known cache on failure; writes + cross-origin = passthrough. **HARD-BYPASSES `/inbox`, `/api/inbox`, `/api/push`** (S-1 — the Inbox is the live surface and is never cached/served-stale; its own `/inbox/sw.js` at the more-specific `/inbox/` scope owns those clients) **and `/intake`, `/api/intake`** (the Flow-A write surface — out of the read-only scope, network-only so a stale presets list can't mislead while filing). Read-only last-snapshot, NO offline write. |
| `web/shared/sw-register.js` | Registers `/shared/sw.js` at scope `/` and toggles the `#offline-badge`. Included by every NON-Inbox page; deliberately NOT by the Inbox (S-1). Standalone IIFE. |
| `web/functions/api/<area>/index.js` | READ proxy template (see `board/index.js`): `onRequestGet`, op hard-coded, `Bearer` server-side, `cache-control: no-store`. |
| `web/functions/api/<area>/<name>.js` | WRITE proxy template (see `board/set-desired.js`): `onRequestPost`, op + allowed-values pinned, strips client principal, normalises UI→wire vocab, passes engine response verbatim. |
| `web/_redirects` | Pages routing. Clean URLs (`/inbox` → `/inbox/`) + apex (`/` → `/board/`) + the `/ws/*` facet catch-all → `/workspace/`. All `200` REWRITES (no redirect roundtrip). |
| `web/_headers` | Per-path response headers (inbox SW `no-cache` + `Service-Worker-Allowed`, manifest MIME). First match wins. |
| `verify-pages-deploy.sh` | Byte-compares committed assets under each route prefix (and `shared/`) against the live host; checks the clean-URL + apex rewrites. `mismatches=0` = the deploy landed. |

## Contracts & invariants (don't break these)

- **§9.1/§9.2 — the bearer is server-side only.** `net.js` has no Authorization
  header and must never grow one. Every `/api/...` proxy holds the token as a
  Pages env binding (`COORDINATOR_TOKEN`), hard-codes the op, and strips/ignores
  any client-supplied `principal`. The browser never chooses the op or principal.
- **Reader has no write path, by construction.** A read proxy exports ONLY
  `onRequestGet` and hard-codes a read op. Never add a POST handler or a mutable
  op to a read proxy (mirrors the engine's `work-snapshot` read-only rule).
- **Absolute asset paths only.** Every `index.html` references `/shared/...`,
  `/board/...` etc. ABSOLUTELY, because rewrites serve the same HTML at multiple
  URL depths (apex `/`, `/ws/<ref>/<facet>`). A relative `./x` resolves against
  the request path and 404s (the q6z7 scar).
- **`enums.js` binds FROZEN UX-V2 §5.2 — never edit it to make a test pass.** A
  §5.2 gap means reopen the spine doc and re-freeze. Adding a value not in §5.2,
  or drifting from the engine constant, is the gate-collision failure.
- **Pure view-model, thin app.js.** Keep `deriveXView` DOM-free and Node-tested;
  keep fetch/render in `app.js`. This split is Contract C.1 — don't merge them.
- **`no-store` on API proxy responses.** The projection is liveness-bearing; a
  cached copy lies the instant a heartbeat stops.

## Common changes (recipes)

**THE deploy-then-verify gate (run before EVERY `bd close` on a web task):**
```bash
(cd beads-runner/web && npx wrangler pages deploy . --project-name claude-wrangler)
bash beads-runner/verify-pages-deploy.sh          # all routes; or pass one: board|inbox|…|shared
# A passing run prints  mismatches=0 . Any DRIFT/MISS = the deploy did not land — re-deploy, re-verify.
```
You MUST `cd beads-runner/web` and pass `.` — `wrangler` finds `functions/`
relative to CWD; deploying from the repo root silently ships HTML without the API
proxies. If you also changed the Worker, deploy the Worker FIRST (Pages depend on
Worker ops, not vice-versa). Auth: `wrangler login` interactively, or a Keychain
`CLOUDFLARE_API_TOKEN` (Pages:Edit) for the headless runner.

**Add a new op to the UI:** add the engine op (see `engine-cloudflare.md` — that
includes the pages-dev adapter layer), then add the proxy here. Read = copy
`functions/api/board/index.js`; write = copy `functions/api/board/set-desired.js`
(hard-code op, pin allowed values, strip principal, pass response verbatim). Call
it from `app.js` via `Net.getJSON('/api/<area>/...')` / `Net.postJSON(...)`. Then
deploy + verify (above). A proxy that works in vitest but 404s on the phone is
almost always a missing pages-dev `adapter.js` mapping — that's an engine-side fix.

**Add a new page/route:** make a dir under `web/`, follow the `board/` three-part
shape (absolute asset paths!), add a `_redirects` clean-URL rewrite, register the
route in `verify-pages-deploy.sh`'s `case`/`routes` list (so a stale deploy can't
pass as green), then deploy + verify.

**Change a shared module or token:** edit `web/shared/*`; it changes every page at
once, so deploy + `verify-pages-deploy.sh shared` (it is verified as part of `all`
because a stale `shared/` breaks every route while each page's own bytes still
match — a false green otherwise).

## Gotchas / scars

- **bgw — closed-but-not-shipped.** The standing failure: code committed + local
  tests green, but no deploy, so the phone never sees it. Five separate bugs in 24h.
  `mismatches=0` against the live host is the only acceptance — not a passing test.
- **q6z7 — relative asset paths break under rewrites.** The apex and `/ws/*`
  rewrites serve one HTML at several depths; only absolute `/...` paths survive.
- **Wrong deploy CWD silently drops the proxies.** Deploy from `web/` with `.`,
  never from the repo root — `functions/` is found relative to CWD.
- **F3 — UI vocab ≠ wire vocab.** The write proxy is the seam that normalises
  (e.g. `set-desired.js` maps UI `spare-only` → §4.2 `spare-cycles`); a value that
  passes through un-normalised silently no-ops downstream.
- **CDN caches static assets.** API responses are `no-store`, but static bytes may
  be CDN-cached; use an incognito tab / cache-bust to see an update on the phone.
- **The off-network worker is read-only + Inbox-exempt by design (4zrn).** `sw.js`
  is network-FIRST for `/api/…` (online is always live; cache is the offline
  fallback only) and hard-bypasses the Inbox surfaces (S-1). This does NOT violate
  the `no-store` API rule — `no-store` governs the HTTP/CDN cache (a stale heartbeat
  lying about liveness); the SW only ever substitutes the last-known snapshot when
  the network is *unreachable*, behind an honest `#offline-badge`, on the pull
  surfaces (never the Inbox). Two SWs coexist: `/inbox/sw.js` (push, scope
  `/inbox/`) wins for Inbox clients by longest-scope; `/shared/sw.js` (scope `/`)
  covers everything else. Behavior is gated by `jsdom/test/sw-offline.test.js`.

## Go deeper

- `beads-runner/UX-V2-ARCHITECTURE.md` Contract C (§4) — the app-shell decision,
  the pure-UMD view-model pattern, the Workspace-hub nav model + route shape; and
  Contract D (§5) for the `enums.js` closed sets.
- `docs/runbooks/deploy-pages.md` — the full deploy/verify/auth runbook + the
  "deploy succeeded but feature still broken → missing Worker op" branch.
- `CLAUDE.md` "Web/Pages task-acceptance discipline (lesson from claude-tools-bgw)"
  — the standing rule this doc operationalises.
- `web/board/index.js` + `web/board/set-desired.js` — the read/write proxy
  templates to copy; `web/board/index.html` — the three-part page template.

## Keeping this doc current

When you finish a web task, append anything a future agent will need and didn't
find here: a new shared-module helper, a new proxy pattern, a moved/renamed route,
a fresh deploy scar, a new `_redirects`/`_headers` rule, a new `verify` route.
**Keep it concise — this doc earns its keep only if agents read all of it.** Delete
stale lines; point at the page docs (`web-board.md` etc.) and the engine doc rather
than re-specifying them here. Last substantive update: 2026-05-31.
