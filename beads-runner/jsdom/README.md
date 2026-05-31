# T4 — shell / router / deep-link tests (jsdom)

The **T4 tier** of the offline regression gate (`../run-tests.sh`), filed as
`claude-tools-rznj.3` against TESTING-STRATEGY.md **§7.4**.

## What it pins

The C-shell (`claude-tools-uxvsh`) added a **router** (Contract C.2 route shape),
a **persistent nav**, and **deep-links** — none of which the view-model node tests
(`lib/test-board.sh`, `test-inbox.sh`, …) exercise, because those test the pure
`deriveXView` functions, not routing or the DOM glue. `lib/test-flow-g.sh` pins the
one `#/f/` failure seam in Node + by `grep` (it explicitly notes "the browser GLUE
has no headless DOM"). **This tier fills exactly that gap**: a headless DOM (jsdom)
so the shell/nav/facet glue is tested *behaviorally*, plus coverage of *every*
Contract C.2 route and the cross-route deep-links.

| Group | Asserts |
|---|---|
| **A** | `_redirects` resolves every global route (`/` → board, `/inbox`, `/workspaces`, `/capacity`, `/cross-ws`) + the `/ws/*` facet catch-all, as 200 rewrites |
| **B** | each global route's page mounts the correct view + `Shell.mount({active:…})` key (route→view binding) |
| **C** | `parseWorkspacePath` maps `/ws/<ref>/<facet>` → `{ref,facet}` for all 4 facets + the documented fallbacks |
| **D** | `deriveNav` emits the FROZEN 4-global + 4-facet sets, the active logic (workspace ⇒ hub anchor), and the facet hrefs |
| **E** | `Shell.mount` paints the nav into a real (jsdom) document — 4 global + 4 facet `<a>`, active class/`aria-current`, idempotent re-mount |
| **F** | each `/ws/<ref>/<facet>` route resolves to the **correct mounted view** by running the real `workspace/app.js` in jsdom (board scaffold vs. the H3/I3/J3 placeholders) |
| **G** | deep-links compute the right target: Board→Blueprint (`/ws/<ref>/blueprint`), holds→Gates (`/ws/<ref>/gates`), dossier→focus (`#/d/<id>` ⇆ the Inbox SPA route) |

A broken route mapping (wrong redirect target, a mis-wired facet dispatch, a dropped
nav entry, or a drifted deep-link) fails a Group deterministically.

## "5 global + 4 facet" — the reconciliation

UX-DESIGN-V2 §2.1 prose says "**Five** global views"; the shell's `GLOBAL` set is
**frozen at 4** (`inbox/workspaces/capacity/cross-ws`) per its own comment. The two
agree once you separate *routes* from *nav links*:

- **5 global routes** exist (Group A): `/` (→ `/board/`, the global Board), `/inbox`,
  `/workspaces`, `/capacity`, `/cross-ws`.
- **4 of those mount the persistent nav** with their `active` key. The apex `/board`
  page is the pre-C-shell global Board; Board is integrated into the shell as the
  **workspace board facet**, not as a 5th persistent-nav link (so `board/app.js`
  intentionally does not call `Shell.mount`).

Per §8 ("assert behaviour/structure, not prose") the tests assert the shell's actual
4 nav links + the 5 global routes — never a literal "5 nav links" that the code
does not render.

## Each facet bead extends this

H3 (Blueprint), I3 (Activity), J3 (Gates), K5 (Cross-WS) each ship the facet content
the shell currently placeholders. When they do, they **add their route case here** —
the in-facet deep-link sub-target (Blueprint *area*, dossier *focus slice*, the
per-hold Gates anchor). Group F and Group G carry `EXTENSION POINT (…)` markers
where each plugs in.

## Run

```bash
cd beads-runner/jsdom && npm test         # node --test
# or via the gate:
bash beads-runner/run-tests.sh --tier jsdom
```

## Install model (same as `cf/`)

`node_modules/` is gitignored; `package-lock.json` is committed. A fresh checkout /
CI runs `npm ci` once before the gate. The gate itself never installs — it runs
`npm test` and assumes deps are present, exactly like the `cf` tier. The single
devDep is **jsdom** (no test framework — Node's built-in `node:test` runner).
