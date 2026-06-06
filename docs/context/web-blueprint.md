# Context: The Blueprint diagram (Flow H — the living design map)

> One-liner: the per-workspace **interactive system map** — a pan/zoom canvas of
> color-coded "domain" squircles you drill into, with a global detail-toggle panel,
> a minimap, an in-flight overlay, and a sticky customization layer. It is the
> single richest UI in the app: a **pure read-model** (`blueprint-view.js`) + a
> **pure write-model** (`blueprint-customize.js`) + a **positioned-canvas renderer**
> living in `web/workspace/app.js`. This doc is the orientation for working on the
> *diagram itself* — `web-facets.md` covers only its place in the facet nav.

**Read this doc when** your task touches the Blueprint MAP: the layout algorithm,
the edge/density rendering, the node taxonomy, the detail-panel toggles, the
minimap, drill-in/focus, the palette, the customization gestures, the in-flight
overlay, or `?focus=` deep-links. Code: `web/workspace/blueprint-view.js`,
`web/workspace/blueprint-customize.js`, and the `mountBlueprintFacet …` /
`renderBlueprint* …` block of `web/workspace/app.js` (+ the `.bp-*` block of
`web/workspace/workspace.css`).

**Not here:** the facet-route shell / `/ws/<ref>/<facet>` nav / the other facets →
`web-facets.md` (read it for the shell rules). The unified Pages deploy/verify
discipline → `web-shell.md`. The engine `/api/ws/blueprint` record + `blueprint_meta`
projection → `engine-cloudflare.md`. The frozen Contract B/C vocabulary →
`contracts-and-design.md`.

---

## 0. The design sources of truth (the WHAT and the IP)

- **`beads-runner/UX-DESIGN-V2.md` §6 (Flow H)** — the product requirement: a
  persistent, always-current Map + Narrative per workspace, auto-generated, with a
  sticky customization layer, an in-flight overlay, and decisions situated on the
  map. This is the **WHAT** (Brian-tagged requirements B1).
- **`~/Downloads/HANDOFF.md`** (the "Diagrammer" prototype spec) — the **interaction
  model + algorithms IP**, which the implementation ports. The sections that bind:
  - **§0 Requirements traceability** — the authoritative list of what was asked for
    (read it before changing behavior).
  - **§10 Decomposition methodology** — *how a real system becomes this map*: what
    is a top-level node (product domains, the client, shared stores, each external
    vendor) vs a child capability vs an edge (queues are **edges**, not nodes) vs an
    API. This is the intellectual core; the diagram is only as good as this step.
  - **§13 layout** (grow-to-fit), **§14 edge resolution + density** (the legibility
    IP), **§15 visual spec** (palette, three render modes), **§16 interaction**,
    **§17 pitfalls already encountered** (do not rediscover these).
- The look/feel target is the reference screenshots in that handoff: a bright
  "paper" canvas, pastel color-coded squircles, traceable colored arrows, a DETAIL
  toggle card, a minimap.

> The geometry/code does **not** transfer verbatim from the prototype — it was
> React+Babel. We ported the **model + the two algorithms** (layout, edge
> resolution) into this codebase's vanilla-UMD + Pages-static idiom.

---

## 1. The data it renders (the §4 record, NOT the work-snapshot)

The Blueprint is the **one facet that reads its own §4 record** — `GET
/api/ws/blueprint?project_ref=<ref>` (the `blueprint-get` body, Contract B.2), fetched
on demand. It is deliberately kept **out** of the `/api/board` work-snapshot (§8.1)
because the map body is large. Shape:

```
{ schema_version, project_ref, updated_at, updated_by,
  derived: { nodes:[…], edges:[…], apis:[…] },   // the auto-generated map
  customization: { renames, regroups, pins, hidden, splits, merges },  // Brian's overrides
  narrative: { tldr, sections:[…] },             // §8.3 prose ABOVE the map
  conflicts: [ … ] }                              // §5.3 orphaned-override log
```

- **Node** = `{ id:"kind:slug", parent, kind, label, … }`. `kind ∈ {domain, client,
  store, vendor, external, capability}`. Top-level kinds = domain/client/store/
  vendor/external; **capability** is the drill-in child. Queues are **edges**, never
  nodes.
- **Edge** = `{ from, to, kind, bundle_key }`. `kind ∈ {call, queue, data, depends}`
  (FROZEN closed set); `queue` = the async/dashed edge.
- **API** = `{ id, domain, route, calls:[capability ids] }` — a public entry route
  that straddles its domain's border.

Best-effort SECOND read: `/api/board` for the **in-flight overlay** only
(`blueprint_meta.active_domains` + `activity`). A board failure leaves the overlay
dark; it never fails the facet.

---

## 2. The three modules + the model/renderer split

| Module | Role |
|---|---|
| `web/workspace/blueprint-view.js` | **PURE read-model** `deriveBlueprintView(record, nowMs, opts)`. No DOM/net/timers. Does ALL the IP: taxonomy parse, customization transform, open-set/visibility, edge resolve+bundle+density, API boundary resolution, focus/dim, in-flight overlay, narrative parse, and the **layout** (`layoutGrowToFit`). Emits per-node render state + `n.layout{x,y,w,h}`. Also `deriveBlueprintThumb` (the Workspaces-hub thumbnail) + `makeNodeId`. The ONE hard refusal is an unknown-higher/missing `schema_version`; everything else degrades per-field with `degraded[]`. |
| `web/workspace/blueprint-customize.js` | **PURE write-model** `window.BlueprintCustomize`. Six override builders (rename/regroup/setPinned/setHidden/addSplit/addMerge), each pure (never mutates input → the in-memory never-clobber, §2.3). Conflict `keepConflict`/`dropConflict`; `deriveLiveConflicts` over the append-only `conflicts[]`. |
| `web/workspace/app.js` (the blueprint block) | **The renderer + interaction shell.** Reads the record, calls the model, paints the positioned canvas, owns pan/zoom + drill/focus + the toggle panel + minimap + the on-box edit popover + the overlay wiring. **Holds NO map logic** the model owns — it draws `view.nodes/edges/apis` as given. |

`opts` into `deriveBlueprintView`: `{ focus, opened[], scale, active_domains,
activity }`. The renderer threads its toggle state into `opts` (see §5).

---

## 3. THE SHARED RENDER CONTRACT (do not break)

The renderer paints into **one transformed world**. The big comment above
`renderBlueprintMap` in `app.js` is canonical; the three facts:

1. **World coordinate space** = the model's layout px. Every visible node carries
   `n.layout{x,y,w,h}` (absolute, already nested — a child's rect falls inside its
   open parent's rect). Origin (0,0) = top-left of the top-left root box.
2. **Pan + zoom = ONE transformed container** `#bp-world` (transform-origin 0 0)
   carrying `translate(panX,panY) scale(zoom)`. `#bp-map` is the viewport and clips.
   The transform lives on the world ONLY — never on a node — so a node's
   `style.left/top` stays pure world px.
3. **Layering** — `#bp-world` holds two sibling layers in the SAME transformed
   space: `#bp-edge-layer` (an `<svg>`, world-sized, pointer-events:none, UNDER) and
   `#bp-box-layer` (the absolutely-positioned `.bp-node` boxes, OVER, painted
   shallow→deep so a child paints over its parent). A left-overhanging API straddle
   shifts the box layer by a non-negative `originX/originY`; the SVG `viewBox` origin
   matches, so edges (drawn at true world coords) align with boxes.

---

## 4. The layout algorithm (`layoutGrowToFit`) — §13, geometry is [free]

The macro map is a **LEFT→RIGHT band layout** (claude-tools-p5me, matching the
reference; NOT a 1-D strip, NOT top→bottom rows):

- Roots group into lanes by `bandOf(kind)`; `BAND_ORDER = [client, domain, store,
  vendor, ext]` laid out as **columns left→right** (client on the left, externals on
  the right — the "caller → domains → stores/vendors" reading order).
- The **domain lane packs into 2 columns**; other lanes are single vertical stacks.
  Lanes are vertically **centered** against the tallest lane.
- **Kind-aware sizes:** a closed top-level box is a big `CARD_W×CARD_H` card; a
  capability is a small `LEAF_W×LEAF_H` leaf; an **open container grows to fit** its
  children in a near-square grid + a header bar (`HEADER`), siblings reflow.
- `MARGIN` (first lane inset) `>` the §7 api half-overhang, and the domain lane's
  column gap reserves `API_PAD`, so API straddle boxes never collide and the
  leftmost domain's straddle lands at a non-negative world x.
- Constants live at the top of `blueprint-view.js`. **The numbers are [free]
  (§3.5)** — never asserted by a test; the *contract* is the 2-D spread (distinct x
  AND y among top-level boxes) so edges read as traceable arrows.

> A future agent may swap this whole function for elk/dagre/React-Flow without
> touching the schema or the edge IP. Keep the invariant: closed = compact; open
> size = f(open children); API stack reserves room; nothing clips.

---

## 5. Interaction & the toggle model

- **Macro → drill:** tap a domain BODY = `toggleFocus` → the model re-derives with
  `opts.focus` (opens it + its ancestors and **dims** everything not connected),
  and `applyFocusViewport` zooms-to-fit on the focus rect (`bpFocusDirty`-gated so
  the 30s refresh never yanks the viewport). The `▸` caret / "N parts" pill =
  `toggleOpen` (manual PEEK, no zoom). `Esc` / "← Back to system" = `clearFocus`
  (focus-opened boxes auto-collapse via `open_source` pin>manual>focus; manual/pins
  survive; the world re-fits via `bpRefitDirty`).
- **The DETAIL panel** (`buildBpDetailPanel`, top-left) — global progressive
  disclosure, each toggle re-derives the view:
  - **APIs** → `bpToggles.apis`. **Renderer-side gate** (`bpShowApisFor` in
    `bpApiRects`): draw a domain's §7 boundary boxes when the toggle is on OR the
    domain is focus-opened. The MODEL still sets `api.visible = isVisible(domain)` —
    **do not move this gate into the model** (the lib test pins it; see §7).
  - **Internals** → `bpToggles.components`. Renderer adds every top-level container
    id (`bpTopLevelContainerIds`) to `opts.opened`, opening all domains at once.
  - **Edge labels** → `bpView.labelsHidden` (a class on the edge layer; the label
    `<text>` elements always render so the jsdom existence check holds).
  - **In-flight overlay** → `bpToggles.inflight` gates whether the best-effort board
    overlay is passed into `opts.active_domains/activity` (lights worked domains;
    ≥2 distinct agents in one box = a collision ring).
- **Minimap** (`buildBpMiniMap`, top-right) — the whole world in miniature + a live
  viewport rect (`bpUpdateMiniViewport`, called from `applyBpWorldTransform`);
  click-to-recenter (`bpCenterOn`).
- **Zoom controls** (`buildBpZoomControls`, bottom-right) — a vertical stack: **`⛶`
  fullscreen toggle** (top), then `+` / `−` zoom, then `⤢` **fit-to-view**. `⛶`
  (`bpToggleFullscreen`, claude-tools-e7p3) CSS-**maximizes** `#bp-map`
  (`position:fixed;inset:0;z-index:120` via the `.bp-fullscreen` class — NOT the
  browser Fullscreen API, which iOS only allows on `<video>`); the overlays ride
  along (children of `#bp-map`), the class survives the 30s repaint (it's on the
  persistent map element, and `buildBpZoomControls` reconciles `bpFullscreen` from
  it), and **Esc exits** (lowest-priority in `bpOnKeyDown`: editor → focus →
  fullscreen). `⤢` is distinct: it only re-fits — a near no-op when already
  auto-framed (the original "the fit button does nothing" report → e7p3 added the
  real fullscreen toggle alongside it).
- **Auto-frame** — the map frames the whole world on every render **until the user
  pans/zooms** (`bpUserMovedView`), plus a **`ResizeObserver`** on `#bp-map`
  (`bpAutoReframe`) that re-fits when the viewport settles its size. This is the
  bulletproof fix for the §17 #8 first-paint race (a below-the-fold facet reports a
  tiny viewport at mount → flooring the zoom). `bpFitRect` reserves panel/minimap
  insets so the leftmost client box never hides under the panel.
- **`?focus=<id>` deep-link** — seeded once from the URL; resolves to open-at-node
  (honest miss banner if the id isn't in the map). The bridge from a decision
  dossier / Board done-verified card to the map (§6.4/§8.4).
- **Customization** — the `⋯` button opens an **on-box popover** (`buildNodeMenu` →
  `renderNodeEditRow`) with rename/regroup/pin/hide (+ recorded split/merge); each
  POSTs the whole customization sub-object via `POST /api/ws/blueprint-put`. The
  §5.3 keep/drop conflict lane + the HIDDEN-restore list live below the canvas.

---

## 6. Palette (§15.1) — color separates concepts

`bpAssignPalette(view)` (renderer) maps each node id → `{fill,border,ink}`, set as
`--bp-fill/--bp-border/--bp-ink` on each box: each **domain** gets a distinct pastel
hue (cycled by appearance order, stable across refresh); client/store/vendor/
external get fixed hues; a **capability inherits a lightened tint** of its domain
(`bpHexLighten`). Edges are stroked by their **source-domain** hue, with
`fill:context-stroke` arrowheads so the head matches the line. The map surface is a
light dotted "paper" canvas inside the dark app shell (CSS `.bp-map`).

---

## 7. Contracts & invariants (don't break these)

- **The model is pure; the renderer is dumb.** No DOM/net/timer/write-path in
  `*-view.js`/`*-customize.js`. A rule that belongs in the model goes in the model
  (so the Node test pins it).
- **`api.visible == isVisible(domain)` in the model** — `lib/test-blueprint-view.sh`
  (line ~239) pins this. The APIs-toggle gate is **renderer-side** (§5). Same for
  Internals (the renderer adds ids to `opts.opened`; the model has no
  "components" concept).
- **One hard refusal:** unknown-higher / missing / non-integer `schema_version` →
  `{ok:false,error}` ("update the app"). Everything else degrades per-field with an
  honest `degraded[]` note — never fabricate (the 4xe write-gate / render-tolerance
  line; dossier conformance is enforced at WRITE, the renderer is tolerant).
- **Customization never clobbers** derived (§2.3) — builders are pure; an orphaned
  override surfaces as a keep/drop FYI, never a silent revert (§14.2 default = keep).
- **Geometry is [free] (§3.5)** — the layout numbers are never asserted; only the
  2-D spread + edge legibility are.

---

## 8. Testing & shipping

- `lib/test-blueprint-view.sh` (Node-require, ~207 checks) — taxonomy, edge
  resolution/bundle/density, focus/dim, customization, overlay, narrative, thumb,
  the schema refusal. **Pins `api.visible`.**
- `lib/test-blueprint-customize.sh` — the pure write-side builders + conflicts.
- `jsdom/test/blueprint-canvas.test.js` — drives the REAL `app.js` renderer over a
  record and asserts the DOM is a **positioned canvas, not a list**: distinct
  absolute x AND y (the `bpmap-1`/`bplayout` anti-regressions — **EXISTENCE !=
  LEGIBILITY**: a 1-D row passes "an edge exists"; these assert a real 2-D spread,
  non-degenerate edge bboxes, a container that grows on open), the focus ring +
  dim, the on-box `⋯` popover, the API boundary box + open-domain arrow + dashed
  async edge. Fixtures encode layout expectations — e.g. `RECORD_BANDS` needs ≥3
  domains so the 2-col pack wraps to ≥2 rows under the left→right orientation.
- **Web-track acceptance (the bgw gate):** committed code is NOT done. Deploy the
  unified Pages project + `verify-pages-deploy.sh` → `mismatches=0`, then eyeball
  the LIVE map. See `web-shell.md`.

---

## 9. Scars / pitfalls (don't rediscover these)

- **bfcache fooled live-verify (claude-tools-p5me).** A *reused* browser tab
  replayed a bfcache'd OLD page byte-identically across redeploys (same world
  transform), masking a working fix — `curl` confirmed the new bytes were live
  (`cache-control: must-revalidate` rules out CDN staleness). **Live-verify a
  redeploy in a FRESH tab.** (bd memory `blueprint-live-verify-bfcache`.)
- **The shared service worker serves stale `app.js` for ONE more load (e7p3).**
  Even in a *fresh* tab, `/shared/sw.js` (cache `beads-shell-v1`) is
  stale-while-revalidate: the first post-deploy page paint runs the OLD cached
  `app.js` (the `⛶` button was absent) while the SW revalidates in the background;
  a `fetch('/workspace/app.js')` already returns the NEW bytes. **Reload the fresh
  tab once** (or the new feature looks un-deployed). `verify-pages-deploy.sh`
  (`curl`, no SW) sees `mismatches=0` immediately — it can't catch this; only a
  second in-browser load does. (Note: a JS `.length` of the served `app.js` reads
  ~1.9KB *under* the byte count — multi-byte glyphs like `⛶`/`⤢`/`·`.)
- **EXISTENCE != LEGIBILITY (bplayout).** The bpmap gate passed for a cramped 1-D
  strip with hidden edge slivers. A green DOM-existence test is not a legible map —
  the canvas test now asserts 2-D spread + non-degenerate edges; the final check is
  a human eyeball on the live deploy.
- **The §17 prototype pitfalls still apply:** z-index strictly by depth (never let
  focus/lit change stacking, or a focused container paints over its own children);
  cache *every* node's size for edge anchors (NaN otherwise); compute dim against
  the focused-subtree predicate, not a mutating keep-set (else a hub like the engine
  pulls everything back); snapshot `autoOpened` before resetting it on drill-out;
  reserve API overhang room; **the first-paint fit race** (now solved by the
  ResizeObserver + fit-until-user-moves, §5 — do not regress to a one-shot `fitted`
  flag).

---

## 10. Where the map appears + how to extend

- The **Blueprint facet** `/ws/<ref>/blueprint` (primary). The **Workspaces hub**
  card shows a live mini-thumbnail (`deriveBlueprintThumb`). A decision dossier /
  Board done-verified card deep-links via `?focus=<id>`.
- **Add a node kind / change taxonomy** → `NODE_KIND`/`TOP_LEVEL_KIND`/`bandOf` in
  `blueprint-view.js` + a palette case in `bpAssignPalette` + a `lib` assertion.
- **Change the layout** → `layoutGrowToFit` only (geometry [free]); keep the §3 render
  contract + re-green `blueprint-canvas.test.js`.
- **Add a global toggle** → a `bpToggles` flag + a `bpToggleRow` in
  `buildBpDetailPanel` + the gate (renderer-side if it's a draw concern; via
  `opts.opened`/a model opt if it changes derivation). Re-derive on flip.
- **Real data ingestion** (deriving `derived.{nodes,edges,apis}` from source/AST/
  OpenAPI) is the blueprint-update hat's job (UX-DESIGN-V2 §6.2), not the renderer.

## Go deeper

- `~/Downloads/HANDOFF.md` (the Diagrammer IP — §10/§13/§14/§17 especially).
- `beads-runner/UX-DESIGN-V2.md` §6 (Flow H, the WHAT) + §0 provenance.
- `beads-runner/design/blueprint.md` (the track-H design doc).
- `web-facets.md` (the facet shell), `web-shell.md` (deploy/verify), `engine-cloudflare.md`
  (`/api/ws/blueprint` record + `blueprint_meta`).

## Keeping this doc current

When you change the diagram, update the section that moved (a new constant block, a
moved gate, a new toggle, a fresh scar) and delete stale lines. Keep it the
authoritative map doc; let `web-facets.md` stay the facet-shell view that points
here. Last substantive update: 2026-06-05 (claude-tools-p5me — the redesign:
left→right banding, the DETAIL panel, palette, minimap, auto-frame; this doc created
to lift the diagram out of `web-facets.md`). 2026-06-05 also: claude-tools-e7p3 — the
`⛶` fullscreen toggle (§5) + the service-worker stale-app.js live-verify scar (§9).
