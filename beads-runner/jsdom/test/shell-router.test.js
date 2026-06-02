/* beads-runner/jsdom/test/shell-router.test.js — the T4 jsdom tier.
 * TEST-INFRA (claude-tools-rznj.3). TESTING-STRATEGY.md §7.4.
 *
 * DETERMINISTIC shell/router/deep-link tests for the C-shell (claude-tools-uxvsh):
 * the Contract C.2 route shape, the persistent nav (Shell.deriveNav/mount), the
 * /ws/<ref>/<facet> catch-all dispatch (workspace/app.js), and the cross-route
 * deep-links. Uses jsdom — NOT a real browser (§8: no Playwright; the full-browser
 * tier is the flaky/fragile category for a single-dev mobile web app). Node's
 * built-in node:test runner + node:assert; jsdom is the single devDep.
 *
 * WHY THIS TIER EXISTS: the view-model node tests (lib/test-board.sh, test-inbox.sh)
 * test the pure deriveXView functions; lib/test-flow-g.sh pins the one #/f/ failure
 * seam in Node + by grep (it explicitly notes "the browser GLUE has no headless
 * DOM"). This tier adds the headless DOM so the shell/nav/facet glue is asserted
 * BEHAVIORALLY, and covers every C.2 route + the deep-links the bead names
 * (Board→Blueprint, holds→Gates, dossier→focus slice).
 *
 * Discipline (§8): deterministic (no wall-clock — an explicit `now=0` is passed to
 * every view-model call), no network (the board facet's Net.getJSON is stubbed to a
 * never-settling promise — the board SCAFFOLD mounts synchronously before the fetch,
 * which is all "which view mounted" needs), assert structure/route-target not prose.
 */
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

// ── paths to the real source under test (jsdom/test/ → ../../web/…) ──────────
const WEB = path.resolve(__dirname, '..', '..', 'web');
const P = {
  shell:      path.join(WEB, 'shared', 'shell.js'),
  dom:        path.join(WEB, 'shared', 'dom.js'),
  boardView:  path.join(WEB, 'board', 'board-view.js'),
  activityView: path.join(WEB, 'workspace', 'activity-view.js'), // I3 (claude-tools-uxvi3)
  gatesView:  path.join(WEB, 'workspace', 'gates-view.js'), // J3 (claude-tools-uxvj3)
  inboxView:  path.join(WEB, 'inbox', 'inbox-view.js'),
  inboxApp:   path.join(WEB, 'inbox', 'app.js'),
  wsIndex:    path.join(WEB, 'workspace', 'index.html'),
  wsApp:      path.join(WEB, 'workspace', 'app.js'),
  redirects:  path.join(WEB, '_redirects'),
};
const read = (p) => fs.readFileSync(p, 'utf8');

// shell.js + inbox-view.js are UMD modules — requireable in Node for the pure
// (no-DOM) function tests, exactly as lib/test-flow-g.sh drives them.
const Shell = require(P.shell);
const InboxView = require(P.inboxView);

// ── tiny _redirects parser (format: "<from> <to> <status>", # comments) ──────
function parseRedirects(text) {
  const map = {};
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const parts = line.split(/\s+/);
    if (parts.length < 2) continue;
    map[parts[0]] = { to: parts[1], status: parts[2] || '' };
  }
  return map;
}

// ── jsdom helpers ────────────────────────────────────────────────────────────
// Run a chunk of JS inside a jsdom window (the browser code path: UMD modules
// take their `else root.X = factory()` branch and attach to window; their
// functions close over window.document). Dynamic-insertion executes
// synchronously under runScripts:'dangerously' and — unlike embedding source in
// an HTML string — is immune to a literal "</script>" in the source.
function runInWindow(window, src) {
  const s = window.document.createElement('script');
  s.textContent = src;
  window.document.body.appendChild(s);
}
function loadFileInWindow(window, file) { runInWindow(window, read(file)); }

// A bare jsdom page (no scripts) for the Shell.mount() paint tests.
function blankWindow(url) {
  const dom = new JSDOM('<!doctype html><html><body></body></html>',
    { url: url || 'https://test.local/', runScripts: 'dangerously' });
  return dom.window;
}

// Load the REAL workspace/index.html (scripts stripped) at `pathname`, then inject
// the page's modules + glue in load order: a Net stub (no network), dom.js,
// shell.js, board-view.js, then workspace/app.js (the IIFE that parses the path
// and mounts nav + the active facet). Returns the window for DOM assertions.
function loadWorkspaceRoute(pathname) {
  const html = read(P.wsIndex).replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, '');
  const dom = new JSDOM(html, {
    url: 'https://test.local' + pathname,
    runScripts: 'dangerously',
    pretendToBeVisual: true,
  });
  const { window } = dom;
  // Net stub: getJSON returns a never-settling promise. The board facet builds
  // its scaffold synchronously in mountBoardFacet() before this resolves, so
  // "which facet mounted" is decided without any network. setInterval(30s) is
  // registered but never fires in-test; window.close() (below) clears it.
  runInWindow(window, 'window.Net = { getJSON: function () { return new Promise(function () {}); } };');
  loadFileInWindow(window, P.dom);
  loadFileInWindow(window, P.shell);
  loadFileInWindow(window, P.boardView);
  loadFileInWindow(window, P.activityView); // I3 — app.js reads window.ActivityView
  loadFileInWindow(window, P.gatesView); // J3 — app.js reads window.GatesView
  loadFileInWindow(window, P.wsApp);
  return window;
}

// DOM query convenience.
const hrefs = (els) => Array.prototype.map.call(els, (a) => a.getAttribute('href'));
const text = (el) => (el && el.textContent ? el.textContent : '');

// ════════════════════════════════════════════════════════════════════════════
test('A — Contract C.2 route table: _redirects resolves every global route + the /ws/* catch-all', () => {
  const r = parseRedirects(read(P.redirects));
  // The 5 GLOBAL routes (the "five global views"): the apex Board + the 4 nav globals.
  assert.equal(r['/'].to, '/board/', 'apex / → the global Board (the 5th global surface)');
  assert.equal(r['/inbox'].to, '/inbox/');
  assert.equal(r['/workspaces'].to, '/workspaces/');
  assert.equal(r['/capacity'].to, '/capacity/');
  assert.equal(r['/cross-ws'].to, '/cross-ws/');
  // The ONE catch-all that serves all 4 facets of all workspaces.
  assert.equal(r['/ws/*'].to, '/workspace/', '/ws/* → the single workspace-shell page');
  // Every one is a 200 REWRITE (clean URL stays put → deep-linkable; not a 301/302).
  for (const k of ['/', '/inbox', '/workspaces', '/capacity', '/cross-ws', '/ws/*']) {
    assert.equal(r[k].status, '200', `${k} must be a 200 rewrite, not a redirect`);
  }
});

// ════════════════════════════════════════════════════════════════════════════
// B — each global route's page mounts the right view + the right nav active key.
// Structural (the route→view binding lives in static HTML + a Shell.mount call),
// so a page that stops loading its view, or mounts the wrong active key, goes RED.
const GLOBAL_PAGES = [
  { route: '/inbox',      dir: 'inbox',      view: 'inbox-view.js',      active: 'inbox' },
  { route: '/workspaces', dir: 'workspaces', view: 'workspaces-view.js', active: 'workspaces' },
  { route: '/capacity',   dir: 'capacity',   view: 'capacity-view.js',   active: 'capacity' },
];
for (const g of GLOBAL_PAGES) {
  test(`B — ${g.route} page loads ${g.view} and mounts Shell active:'${g.active}'`, () => {
    const idx = read(path.join(WEB, g.dir, 'index.html'));
    assert.match(idx, new RegExp('/' + g.dir + '/' + g.view.replace('.', '\\.')),
      `${g.dir}/index.html must load its view module ${g.view}`);
    assert.match(idx, new RegExp('/' + g.dir + '/app\\.js'), `${g.dir}/index.html must load app.js`);
    const app = read(path.join(WEB, g.dir, 'app.js'));
    assert.match(app, new RegExp("Shell\\.mount\\(\\{\\s*active:\\s*'" + g.active + "'"),
      `${g.dir}/app.js must mount the persistent nav with active:'${g.active}'`);
  });
}
test("B — /cross-ws is the honest placeholder: mounts Shell active:'cross-ws', loads no network module (K5 ships content)", () => {
  const idx = read(path.join(WEB, 'cross-ws', 'index.html'));
  assert.match(idx, /\/shared\/shell\.js/, 'cross-ws loads the shell module');
  assert.match(idx, /Shell\.mount\(\{\s*active:\s*'cross-ws'/, "cross-ws mounts the nav active:'cross-ws'");
  // It invents no data: the honest structural signal is that it loads no network
  // module and makes no live call (assert the absence of the net.js script + a
  // real fetch( — NOT the bare "/api/" substring, which legitimately appears in a
  // comment explaining what the page does NOT do; §8: never grep a comment).
  assert.doesNotMatch(idx, /<script[^>]+\/shared\/net\.js/, 'cross-ws loads no network module — nothing to read until track K');
  assert.doesNotMatch(idx, /fetch\(|getJSON\(/, 'cross-ws makes no live call');
});
test('B — apex /board page loads board-view.js + app.js (the global Board; Board is also the workspace facet)', () => {
  const idx = read(path.join(WEB, 'board', 'index.html'));
  assert.match(idx, /\/board\/board-view\.js/);
  assert.match(idx, /\/board\/app\.js/);
});

// ════════════════════════════════════════════════════════════════════════════
const FACETS = ['board', 'blueprint', 'activity', 'gates'];
test('C — parseWorkspacePath maps /ws/<ref>/<facet> → {ref,facet} for every facet', () => {
  for (const f of FACETS) {
    assert.deepEqual(Shell.parseWorkspacePath('/ws/projA/' + f), { ref: 'projA', facet: f });
  }
});
test('C — parseWorkspacePath fallbacks: bare ref, trailing slash, unknown facet, encoded ref, non-/ws path', () => {
  assert.deepEqual(Shell.parseWorkspacePath('/ws/projA'), { ref: 'projA', facet: 'board' }, 'no facet → default board');
  assert.deepEqual(Shell.parseWorkspacePath('/ws/projA/'), { ref: 'projA', facet: 'board' });
  assert.deepEqual(Shell.parseWorkspacePath('/ws/projA/board/'), { ref: 'projA', facet: 'board' }, 'trailing slash tolerated');
  assert.equal(Shell.parseWorkspacePath('/ws/projA/bogus').facet, 'board', 'unknown facet falls back to board');
  assert.equal(Shell.parseWorkspacePath('/ws/proj%2Fx/board').ref, 'proj/x', 'ref is percent-decoded');
  assert.equal(Shell.parseWorkspacePath('/inbox'), null, 'a global route is not a /ws path');
  assert.equal(Shell.parseWorkspacePath('/'), null);
});

// ════════════════════════════════════════════════════════════════════════════
test('D — deriveNav: the FROZEN 4-global set (keys, order, hrefs)', () => {
  assert.deepEqual(Shell.GLOBAL.map((g) => g.key), ['inbox', 'workspaces', 'capacity', 'cross-ws']);
  const nav = Shell.deriveNav({ active: 'inbox' });
  assert.equal(nav.global.length, 4);
  assert.deepEqual(nav.global.map((g) => g.href), ['/inbox', '/workspaces', '/capacity', '/cross-ws']);
  assert.equal(nav.workspace, null, 'a bare global view has no workspace context');
});
test('D — deriveNav: each global key marks exactly itself active', () => {
  for (const key of ['inbox', 'workspaces', 'capacity', 'cross-ws']) {
    const nav = Shell.deriveNav({ active: key });
    const actives = nav.global.filter((g) => g.active).map((g) => g.key);
    assert.deepEqual(actives, [key], `active:'${key}' marks exactly that one global link`);
  }
});
test('D — deriveNav: workspace context emits the FROZEN 4 facets + hub anchor + facet hrefs', () => {
  assert.deepEqual(Shell.FACETS.map((f) => f.key), FACETS);
  const nav = Shell.deriveNav({ workspace: { ref: 'projA', facet: 'blueprint' } });
  assert.ok(nav.workspace, 'a workspace context produces a workspace nav block');
  assert.deepEqual(nav.workspace.tabs.map((t) => t.key), FACETS);
  assert.deepEqual(nav.workspace.tabs.map((t) => t.href),
    ['/ws/projA/board', '/ws/projA/blueprint', '/ws/projA/activity', '/ws/projA/gates']);
  assert.deepEqual(nav.workspace.tabs.filter((t) => t.active).map((t) => t.key), ['blueprint'],
    'exactly the named facet is active');
  // Inside a workspace, the GLOBAL "Workspaces" hub is the active anchor (no scavenger hunt, §2).
  assert.deepEqual(nav.global.filter((g) => g.active).map((g) => g.key), ['workspaces']);
});
test('D — deriveNav: a workspace with no facet defaults to the board facet', () => {
  const nav = Shell.deriveNav({ workspace: { ref: 'projA' } });
  assert.equal(nav.workspace.facet, 'board');
  assert.deepEqual(nav.workspace.tabs.filter((t) => t.active).map((t) => t.key), ['board']);
});
test('D — deriveNav: NO failure/forensic facet (a Board failure must deep-link OUT to the Inbox — cf. test-flow-g)', () => {
  const nav = Shell.deriveNav({ workspace: { ref: 'projA', facet: 'board' } });
  assert.equal(nav.workspace.tabs.filter((t) => t.key === 'failure' || t.key === 'forensic').length, 0);
});

// ════════════════════════════════════════════════════════════════════════════
// E — Shell.mount paints the nav into a real (jsdom) document. The browser code
// path: shell.js + dom.js loaded as page scripts (attach to window), then
// window.Shell.mount(opts) writes the DOM. This is the BEHAVIORAL "the nav
// renders the global + facet set" the bead names.
function mountInWindow(window, opts) {
  loadFileInWindow(window, P.dom);
  loadFileInWindow(window, P.shell);
  runInWindow(window, 'window.__navModel = window.Shell.mount(' + JSON.stringify(opts) + ');');
  return window.document.getElementById('shell-nav');
}
test('E — mount() paints the 4 global links into the document; the active one carries aria-current', () => {
  const window = blankWindow('https://test.local/capacity');
  try {
    const nav = mountInWindow(window, { active: 'capacity' });
    assert.ok(nav, 'a <nav id="shell-nav"> is created');
    assert.equal(window.document.body.firstChild, nav, 'nav is prepended as the first child of <body>');
    assert.equal(nav.getAttribute('aria-label'), 'Primary');
    const globalRow = nav.querySelector('.shell-global');
    const links = globalRow.querySelectorAll('a');
    assert.equal(links.length, 4, 'exactly 4 global links rendered');
    assert.deepEqual(hrefs(links), ['/inbox', '/workspaces', '/capacity', '/cross-ws']);
    const active = nav.querySelectorAll('a.active');
    assert.equal(active.length, 1, 'exactly one active link');
    assert.equal(active[0].getAttribute('href'), '/capacity');
    assert.equal(active[0].getAttribute('aria-current'), 'page');
    assert.equal(nav.querySelector('.shell-tabs'), null, 'no facet row outside a workspace');
  } finally { window.close(); }
});
test('E — mount() in a workspace paints 4 global + 4 facet links (the 4+4 set) with the ref crumb', () => {
  const window = blankWindow('https://test.local/ws/projA/gates');
  try {
    const nav = mountInWindow(window, { workspace: { ref: 'projA', facet: 'gates' } });
    const globalLinks = nav.querySelectorAll('.shell-global a');
    assert.equal(globalLinks.length, 4);
    // Inside a workspace the global "Workspaces" hub link is the active anchor.
    assert.equal(nav.querySelector('.shell-global a.active').getAttribute('href'), '/workspaces');
    const tabsRow = nav.querySelector('.shell-tabs');
    assert.ok(tabsRow, 'the facet tab strip is rendered inside a workspace');
    assert.match(text(tabsRow.querySelector('.shell-ws-label')), /projA/, 'the ws-ref crumb names the workspace');
    const tabLinks = tabsRow.querySelectorAll('a');
    assert.equal(tabLinks.length, 4, 'exactly 4 facet tabs');
    assert.deepEqual(hrefs(tabLinks),
      ['/ws/projA/board', '/ws/projA/blueprint', '/ws/projA/activity', '/ws/projA/gates']);
    assert.equal(tabsRow.querySelector('a.active').getAttribute('href'), '/ws/projA/gates');
    // The full rendered set: 4 global + 4 facet = 8 links painted into the DOM.
    assert.equal(nav.querySelectorAll('a').length, 8);
  } finally { window.close(); }
});
test('E — mount() is idempotent: re-mounting another facet repaints in place (no second nav, no stale active)', () => {
  const window = blankWindow('https://test.local/ws/projA/board');
  try {
    loadFileInWindow(window, P.dom);
    loadFileInWindow(window, P.shell);
    runInWindow(window, "window.Shell.mount({ workspace: { ref: 'projA', facet: 'board' } });");
    runInWindow(window, "window.Shell.mount({ workspace: { ref: 'projA', facet: 'gates' } });");
    assert.equal(window.document.querySelectorAll('nav#shell-nav').length, 1, 'still exactly one nav');
    const nav = window.document.getElementById('shell-nav');
    assert.equal(nav.querySelectorAll('a').length, 8, 'still 4 global + 4 facet after repaint');
    const active = nav.querySelector('.shell-tabs a.active');
    assert.equal(active.getAttribute('href'), '/ws/projA/gates', 'the new facet is active');
    assert.equal(nav.querySelectorAll('.shell-tabs a.active').length, 1, 'the old facet is no longer active');
  } finally { window.close(); }
});

// ════════════════════════════════════════════════════════════════════════════
// F — each /ws/<ref>/<facet> route resolves to the CORRECT MOUNTED VIEW. Runs the
// real workspace/app.js in jsdom and asserts which facet actually mounted. This is
// the strongest "resolves to the correct mounted view" + "a broken route mapping
// fails deterministically" coverage: a mis-wired dispatch mounts the wrong subtree.
test('F — /ws/<ref>/board mounts the BOARD facet scaffold (reuses BoardView), not a placeholder', () => {
  const window = loadWorkspaceRoute('/ws/projA/board');
  try {
    const host = window.document.getElementById('facet-host');
    assert.ok(host.querySelector('.bf-wrap'), 'the board-facet scaffold (.bf-wrap) mounted');
    assert.equal(host.querySelector('.facet-placeholder'), null, 'the board route is NOT a placeholder');
    assert.match(text(window.document.getElementById('who')), /projA/, 'the scope crumb names the workspace');
    // The nav agrees: workspaces hub active + the board facet tab active.
    const nav = window.document.getElementById('shell-nav');
    assert.equal(nav.querySelector('.shell-global a.active').getAttribute('href'), '/workspaces');
    assert.equal(nav.querySelector('.shell-tabs a.active').getAttribute('href'), '/ws/projA/board');
  } finally { window.close(); }
});
// I3 (claude-tools-uxvi3): the Activity facet GRADUATED from placeholder to live
// content — it now mounts the .af-wrap scaffold (writer lane + aux pool +
// runner-health pip), the EXTENSION POINT below anticipated. Blueprint (H3) and
// Gates (J3) remain honest placeholders.
test('F — /ws/<ref>/activity mounts the LIVE Activity facet scaffold (writer lane + aux pool), not a placeholder', () => {
  const window = loadWorkspaceRoute('/ws/projA/activity');
  try {
    const host = window.document.getElementById('facet-host');
    // The static scaffold mounts SYNCHRONOUSLY (before the never-settling fetch),
    // exactly like the board facet's .bf-wrap — that is all "which facet mounted"
    // needs. The dynamic regions (.af-writer-host / .af-aux-host / the runner-health
    // pip) exist as the scaffold; the data paints once /api/board resolves.
    assert.ok(host.querySelector('.af-wrap'), 'the activity-facet scaffold (.af-wrap) mounted');
    assert.ok(host.querySelector('.af-writer-host'), 'the writer lane host mounted');
    assert.ok(host.querySelector('.af-aux-host'), 'the auxiliary-pool host mounted');
    assert.ok(host.querySelector('#af-rh-host'), 'the distinct runner-health pip host mounted');
    assert.equal(host.querySelector('.facet-placeholder'), null, 'the activity route is NOT a placeholder');
    assert.equal(host.querySelector('.bf-wrap'), null, 'the activity route did NOT mount the board scaffold');
    // Dispatch + nav agree: the activity facet tab is the active one.
    const nav = window.document.getElementById('shell-nav');
    assert.equal(nav.querySelector('.shell-tabs a.active').getAttribute('href'), '/ws/projA/activity');
  } finally { window.close(); }
});
// J3 (claude-tools-uxvj3): the Gates facet GRADUATED from placeholder to live
// content — it now mounts the .gf-wrap scaffold (the unified Hold list +
// add-a-gate form), the EXTENSION POINT below anticipated. Only Blueprint (H3)
// remains an honest placeholder.
test('F — /ws/<ref>/gates mounts the LIVE Gates facet scaffold (unified Hold list + add-a-gate), not a placeholder', () => {
  const window = loadWorkspaceRoute('/ws/projA/gates');
  try {
    const host = window.document.getElementById('facet-host');
    // The static scaffold mounts SYNCHRONOUSLY (before the never-settling fetch),
    // exactly like the board/activity facets — that is all "which facet mounted"
    // needs. The dynamic hold list (#gf-list) paints once /api/board resolves.
    assert.ok(host.querySelector('.gf-wrap'), 'the gates-facet scaffold (.gf-wrap) mounted');
    assert.ok(host.querySelector('#gf-list'), 'the unified Hold list host mounted');
    assert.ok(host.querySelector('.gf-add'), 'the add-a-gate form (the only editable hold) mounted');
    assert.equal(host.querySelector('.facet-placeholder'), null, 'the gates route is NOT a placeholder');
    assert.equal(host.querySelector('.bf-wrap'), null, 'the gates route did NOT mount the board scaffold');
    // Dispatch + nav agree: the gates facet tab is the active one.
    const nav = window.document.getElementById('shell-nav');
    assert.equal(nav.querySelector('.shell-tabs a.active').getAttribute('href'), '/ws/projA/gates');
  } finally { window.close(); }
});
const PLACEHOLDER_FACETS = [
  { facet: 'blueprint', label: 'Blueprint', track: 'H3' },
];
for (const pf of PLACEHOLDER_FACETS) {
  test(`F — /ws/<ref>/${pf.facet} mounts the honest ${pf.label} placeholder (names track ${pf.track})`, () => {
    const window = loadWorkspaceRoute('/ws/projA/' + pf.facet);
    try {
      const host = window.document.getElementById('facet-host');
      const ph = host.querySelector('.facet-placeholder');
      assert.ok(ph, `the ${pf.facet} route mounts a placeholder facet`);
      assert.match(text(ph), new RegExp(pf.label), `placeholder names the ${pf.label} facet`);
      assert.match(text(ph), new RegExp(pf.track), `placeholder honestly names the shipping track ${pf.track}`);
      assert.equal(host.querySelector('.bf-wrap'), null, `the ${pf.facet} route did NOT mount the board scaffold`);
      // The facet tab for THIS facet is the active one (dispatch + nav agree).
      const nav = window.document.getElementById('shell-nav');
      assert.equal(nav.querySelector('.shell-tabs a.active').getAttribute('href'), '/ws/projA/' + pf.facet);
      // EXTENSION POINT (claude-tools-uxvh3/uxvi3/uxvj3): when this facet ships its
      // real content, replace the placeholder assertion with the mounted-view +
      // in-facet deep-link (e.g. Blueprint AREA, Gates per-hold anchor) assertion.
    } finally { window.close(); }
  });
}
test('F — bare /workspace/ (no ref in the URL) mounts the honest "Pick a workspace" empty state, not a guessed board', () => {
  const window = loadWorkspaceRoute('/workspace/');
  try {
    const host = window.document.getElementById('facet-host');
    assert.ok(host.querySelector('.facet-empty'), 'the no-context empty state mounted');
    assert.match(text(host), /Pick a workspace/);
    assert.equal(host.querySelector('.bf-wrap'), null, 'no board scaffold without a ref');
    // The global nav still paints, with the Workspaces hub active (the anchor).
    const nav = window.document.getElementById('shell-nav');
    assert.equal(nav.querySelector('.shell-global a.active').getAttribute('href'), '/workspaces');
    assert.equal(nav.querySelector('.shell-tabs'), null, 'no facet strip without a workspace context');
  } finally { window.close(); }
});

// ════════════════════════════════════════════════════════════════════════════
// G — deep-links compute the right target. The bead names three:
//   Board→Blueprint area, dossier→focus slice, holds→Gates.
// The ROUTE target of each is pinned here; the in-facet sub-anchor (the "area"
// / "slice" within the facet) ships with the facet bead and is marked EXTENSION.
test('G — Board→Blueprint deep-link target is /ws/<ref>/blueprint (deriveNav facet href)', () => {
  const tabs = Shell.deriveNav({ workspace: { ref: 'projA', facet: 'board' } }).workspace.tabs;
  const blueprint = tabs.find((t) => t.key === 'blueprint');
  assert.equal(blueprint.href, '/ws/projA/blueprint');
  // EXTENSION POINT (claude-tools-uxvh3): the Board→Blueprint AREA anchor (deep-link
  // to a specific domain in the living map) ships with H3 — add its case here.
});
test('G — holds→Gates deep-link target is /ws/<ref>/gates (deriveNav facet href)', () => {
  const tabs = Shell.deriveNav({ workspace: { ref: 'projA', facet: 'board' } }).workspace.tabs;
  const gates = tabs.find((t) => t.key === 'gates');
  assert.equal(gates.href, '/ws/projA/gates');
  // EXTENSION POINT (claude-tools-uxvj3): the per-hold Gates anchor (a Board card's
  // "waiting on X" → that specific hold in the Gates view) ships with J3.
});
test('G — dossier→focus slice: inbox-view emits #/d/<id> and the Inbox SPA route extracts it (seam executes)', () => {
  // The dossier row's deep-link target, computed by the REAL view model (now=0).
  const snap = { schema_version: 1, waiting_on_you: [{ dossier_id: 'd-abc-123', bead_ref: 'claude-tools-9', tier: 'blocking', open_item_count: 1 }] };
  const list = InboxView.deriveInboxList(snap, 0);
  assert.equal(list.ok, true);
  const href = list.items[0].dossier_href;
  assert.equal(href, '#/d/d-abc-123', 'a dossier row deep-links to its focus slice #/d/<id>');
  // Execute the Inbox SPA's OWN route regex on that exact href → it must extract
  // the id (the seam, not two independent greps — the test-flow-g idiom).
  const m = href.replace(/^#/, '').match(/^\/d\/(.+)$/);
  assert.equal(m && m[1], 'd-abc-123', 'the #/d/ route captures the dossier id');
  // …and pin that the Inbox SPA actually uses that route literal → loadDossier,
  // so the producer (href) ⇆ consumer (route) seam cannot silently drift.
  const inboxApp = read(P.inboxApp);
  assert.match(inboxApp, /\/\^\\\/d\\\/\(\.\+\)\$\//, 'Inbox SPA routes the /^\\/d\\/(.+)$/ literal');
  assert.match(inboxApp, /loadDossier\(m\[1\]\)/, 'Inbox SPA routes #/d/<id> → loadDossier');
});
