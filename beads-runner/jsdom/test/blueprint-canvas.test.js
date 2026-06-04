/* beads-runner/jsdom/test/blueprint-canvas.test.js — the bpmap-1 ANTI-REGRESSION.
 * claude-tools-bpmap1 (positioned-canvas foundation). TESTING-STRATEGY.md §7.4.
 *
 * THE GATE THAT WOULD HAVE CAUGHT THE ORIGINAL SHADOW (claude-tools-bpmap): the H3
 * renderer computed the H2 geometry then drew a flat INDENTED LIST — every node in
 * one column, varying only marginLeft. lib/test-blueprint-view.sh tested the MODEL
 * (layout exists); NOTHING tested the DOM, so the list shipped green. This drives
 * the REAL workspace/app.js in jsdom over a real blueprint record and asserts the
 * DOM is a POSITIONED CANVAS, not a list:
 *   (a) ≥2 visible nodes carry DISTINCT left/top (NOT a single marginLeft column),
 *   (b) the ONE transformed 'world' container exists carrying a pan+zoom transform,
 *       and holds the SVG edge layer + the box layer in the SAME world (the shared
 *       render contract bpmap-2/3 bind to).
 *
 * Discipline (§8): deterministic (the model is fed an explicit record; no
 * wall-clock matters to geometry), no network (Net.getJSON stubbed to resolve the
 * record + an empty snapshot), assert STRUCTURE (positions/layers/transform), never
 * pixel values (the geometry is [free], §3.5 — only its DISTINCTNESS is the contract).
 */
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const WEB = path.resolve(__dirname, '..', '..', 'web');
const P = {
  dom: path.join(WEB, 'shared', 'dom.js'),
  shell: path.join(WEB, 'shared', 'shell.js'),
  boardView: path.join(WEB, 'board', 'board-view.js'),
  activityView: path.join(WEB, 'workspace', 'activity-view.js'),
  gatesView: path.join(WEB, 'workspace', 'gates-view.js'),
  blueprintView: path.join(WEB, 'workspace', 'blueprint-view.js'),
  blueprintCustomize: path.join(WEB, 'workspace', 'blueprint-customize.js'),
  wsIndex: path.join(WEB, 'workspace', 'index.html'),
  wsApp: path.join(WEB, 'workspace', 'app.js'),
};
const read = (p) => fs.readFileSync(p, 'utf8');
function runInWindow(window, src) {
  const s = window.document.createElement('script');
  s.textContent = src;
  window.document.body.appendChild(s);
}
function loadFileInWindow(window, file) { runInWindow(window, read(file)); }
const flush = () => new Promise((r) => setTimeout(r, 0));

// Load the REAL workspace shell + app.js at `pathname` with the blueprint record +
// work-snapshot pre-resolved (mirrors shell-router.test.js's loadBlueprintRouteResolved),
// so the facet's async render actually runs and paints the map.
function loadBlueprint(pathname, record, snapshot) {
  const html = read(P.wsIndex).replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, '');
  const dom = new JSDOM(html, {
    url: 'https://test.local' + pathname,
    runScripts: 'dangerously',
    pretendToBeVisual: true,
  });
  const { window } = dom;
  const stub =
    'window.Net = { getJSON: function (url) {' +
    '  if (url.indexOf("/api/ws/blueprint") === 0) return Promise.resolve(' + JSON.stringify(record) + ');' +
    '  if (url.indexOf("/api/board") === 0) return Promise.resolve(' + JSON.stringify(snapshot) + ');' +
    '  return Promise.resolve(null);' +
    '} };';
  runInWindow(window, stub);
  loadFileInWindow(window, P.dom);
  loadFileInWindow(window, P.shell);
  loadFileInWindow(window, P.boardView);
  loadFileInWindow(window, P.activityView);
  loadFileInWindow(window, P.gatesView);
  loadFileInWindow(window, P.blueprintView);
  loadFileInWindow(window, P.blueprintCustomize);
  loadFileInWindow(window, P.wsApp);
  return window;
}

// A record with TWO top-level domains (→ distinct left) + a nested capability
// under the second (→ distinct top once its domain is opened by ?focus).
const RECORD = {
  schema_version: 1, project_ref: 'projA',
  derived: {
    nodes: [
      { id: 'domain:posts-feed', label: 'Posts & Feed', kind: 'domain', parent: null },
      { id: 'domain:messaging', label: 'Messaging', kind: 'domain', parent: null },
      { id: 'capability:send-dm', label: 'Send a DM', kind: 'capability', parent: 'domain:messaging' },
    ],
    edges: [{ from: 'domain:posts-feed', to: 'domain:messaging', kind: 'call', bundle_key: 'pf->msg' }],
    apis: [],
  },
  customization: {}, narrative: { tldr: 'x', sections: [] }, conflicts: [],
};
const SNAP = { schema_version: 1, projects: [] };

// A record with an API boundary box (a route on posts-feed targeting an internal
// capability) + an ASYNC (queue) edge — for the bpmap-2 edge/api anti-regression.
const RECORD_API = {
  schema_version: 1, project_ref: 'projA',
  derived: {
    nodes: [
      { id: 'domain:posts-feed', label: 'Posts & Feed', kind: 'domain', parent: null },
      { id: 'capability:create-post', label: 'Create a post', kind: 'capability', parent: 'domain:posts-feed' },
      { id: 'domain:messaging', label: 'Messaging', kind: 'domain', parent: null },
    ],
    // a queue edge = the ASYNC (dashed) kind; resolves capability→domain under focus.
    edges: [{ from: 'capability:create-post', to: 'domain:messaging', kind: 'queue', bundle_key: 'cp->msg' }],
    // a route straddling posts-feed's border, arrowing to the capability it calls.
    apis: [{ id: 'api:POST-/posts', domain: 'domain:posts-feed', route: 'POST /posts', calls: ['capability:create-post'] }],
  },
  customization: {}, narrative: { tldr: 'x', sections: [] }, conflicts: [],
};

function edgeLayer(window) {
  const svg = window.document.getElementById('bp-edge-layer');
  assert.ok(svg, 'the #bp-edge-layer SVG (where bpmap-2 draws edges + api arrows) exists');
  return svg;
}

function boxNodeStyles(window) {
  const layer = window.document.getElementById('bp-box-layer');
  assert.ok(layer, 'the #bp-box-layer (the box layer of the transformed world) exists');
  const nodes = Array.prototype.slice.call(layer.querySelectorAll('.bp-node'));
  return nodes.map((el) => ({
    left: el.style.left, top: el.style.top,
    position: el.style.position, marginLeft: el.style.marginLeft,
  }));
}

// ════════════════════════════════════════════════════════════════════════════
test('bpmap-1 (a) — visible nodes are ABSOLUTELY POSITIONED at DISTINCT world coords (not a marginLeft column)', async () => {
  // Focus the nested capability → its domain opens, so parent + child + the sibling
  // domain are all visible: 2 roots side-by-side (distinct left) + a child below
  // its parent (distinct top).
  const window = loadBlueprint('/ws/projA/blueprint?focus=capability:send-dm', RECORD, SNAP);
  try {
    await flush();
    const styles = boxNodeStyles(window);
    assert.ok(styles.length >= 2, 'at least two visible nodes render as positioned boxes');

    // The CORE anti-regression: the old list gave EVERY node the same left and only
    // varied marginLeft. A positioned canvas varies BOTH left and top.
    const lefts = new Set(styles.map((s) => s.left));
    const tops = new Set(styles.map((s) => s.top));
    assert.ok(lefts.size >= 2,
      '>=2 DISTINCT left values (horizontal placement — impossible in the old single-column list)');
    assert.ok(tops.size >= 2,
      '>=2 DISTINCT top values (a drilled child sits below its parent)');
    const pairs = new Set(styles.map((s) => s.left + '|' + s.top));
    assert.ok(pairs.size >= 2, '>=2 DISTINCT (left,top) positions');

    // Every box is position:absolute with explicit px left+top.
    styles.forEach((s) => {
      assert.equal(s.position, 'absolute', 'each node is absolutely positioned');
      assert.match(s.left, /px$/, 'each node carries an absolute left in px');
      assert.match(s.top, /px$/, 'each node carries an absolute top in px');
    });
    // …and NONE uses the old marginLeft-indent signature.
    assert.ok(styles.every((s) => !s.marginLeft),
      'no node uses style.marginLeft (the old indented-list signature is gone)');
  } finally { window.close(); }
});

// ════════════════════════════════════════════════════════════════════════════
test('bpmap-1 (b) — the ONE transformed world carries a pan+zoom transform and holds the edge + box layers (shared coords)', async () => {
  const window = loadBlueprint('/ws/projA/blueprint', RECORD, SNAP);
  try {
    await flush();
    const world = window.document.getElementById('bp-world');
    assert.ok(world, 'the single transformed world container exists');
    // It carries the pan+zoom transform (translate + scale) — applied ONLY here.
    assert.match(world.style.transform, /translate\(/, 'world carries a translate (pan)');
    assert.match(world.style.transform, /scale\(/, 'world carries a scale (zoom)');

    // The layering contract bpmap-2 binds to: an <svg> edge layer UNDER a box
    // layer, BOTH inside the SAME transformed world (so edges align with boxes).
    const svg = window.document.getElementById('bp-edge-layer');
    assert.ok(svg, 'the SVG edge layer exists (bpmap-2 draws resolved/bundled edges here)');
    assert.equal(svg.tagName.toLowerCase(), 'svg', 'the edge layer is an <svg> element');
    assert.ok(world.contains(svg), 'the edge layer is inside the transformed world');
    const boxLayer = window.document.getElementById('bp-box-layer');
    assert.ok(boxLayer && world.contains(boxLayer), 'the box layer is inside the same transformed world');
    // Edge layer precedes the box layer in DOM → edges paint UNDER the boxes.
    const kids = Array.prototype.slice.call(world.children);
    assert.ok(kids.indexOf(svg) < kids.indexOf(boxLayer), 'the edge layer is below the box layer');
  } finally { window.close(); }
});

// ════════════════════════════════════════════════════════════════════════════
// The H3 ?focus deep-link contract must SURVIVE the rewrite: the focused node still
// carries the .bp-focus ring (shell-router.test.js also pins this; re-pinned here
// against the positioned renderer so a bpmap regression that drops it goes RED).
test('bpmap-1 — the focused node still carries .bp-focus (H3 deep-link contract preserved)', async () => {
  const window = loadBlueprint('/ws/projA/blueprint?focus=domain:messaging', RECORD, SNAP);
  try {
    await flush();
    const host = window.document.getElementById('facet-host');
    const focused = host.querySelector('.bp-node.bp-focus');
    assert.ok(focused, 'the ?focus target node keeps the .bp-focus ring on the positioned canvas');
  } finally { window.close(); }
});

// ════════════════════════════════════════════════════════════════════════════
// bpmap-2 (claude-tools-bpmap2) ANTI-REGRESSION: the original shadow rendered
// view.edges as the integer count in a text legend ("N edges") and never drew a
// single <path>; APIs were dropped entirely. These assert the DOM actually carries
// edge PATHS (counts, not a legend string) and API boundary BOXES — so a regression
// back to "edges are just a number" goes RED.
test('bpmap-2 (edges) — view.edges render as SVG <path> elements in the edge layer (not a legend count)', async () => {
  // RECORD carries one cross-domain edge (posts-feed → messaging); at macro both
  // domains are visible so it resolves domain↔domain and must draw a path.
  const window = loadBlueprint('/ws/projA/blueprint', RECORD, SNAP);
  try {
    await flush();
    const svg = edgeLayer(window);
    const paths = svg.querySelectorAll('path.bp-edge, line.bp-edge');
    assert.ok(paths.length >= 1,
      'a non-empty view.edges draws at least one edge <path>/<line> in #bp-edge-layer');
    // …and it is geometry, not text: each carries a path/line definition.
    paths.forEach((p) => {
      const def = p.getAttribute('d') || p.getAttribute('x1');
      assert.ok(def, 'each edge element carries real geometry (a "d" path or line coords)');
    });
    // the via/queue label rides the edge (toggleable) — present by default.
    assert.ok(svg.querySelectorAll('text.bp-edge-label').length >= 1,
      'each edge carries a toggleable kind/via label');
  } finally { window.close(); }
});

test('bpmap-2 (apis) — a domain with apis renders API boundary BOXES + an open-domain target arrow', async () => {
  // Focus the capability so its domain opens → the api box AND its arrow to the
  // internal capability it targets both render.
  const window = loadBlueprint('/ws/projA/blueprint?focus=capability:create-post', RECORD_API, SNAP);
  try {
    await flush();
    const boxLayer = window.document.getElementById('bp-box-layer');
    assert.ok(boxLayer, 'the box layer exists');
    const apiBoxes = boxLayer.querySelectorAll('.bp-api');
    assert.equal(apiBoxes.length, 1,
      'the one visible api renders exactly one boundary box straddling its domain border');
    // each box is absolutely placed at its world position (straddling the border).
    apiBoxes.forEach((b) => {
      assert.equal(b.style.position, 'absolute', 'an api box is absolutely positioned in the world');
      assert.match(b.style.left, /-?\d/, 'an api box carries an absolute world left');
    });
    // posts-feed is the left-most domain (x=0) so its api straddles into x<0; the
    // box layer is shifted by a non-negative origin offset so it stays on-canvas
    // (left + boxLayer.left ≥ 0). A regression that clipped it would leave the box
    // at a negative world pixel with no compensating offset.
    const offset = parseFloat(boxLayer.style.left) || 0;
    assert.ok(offset >= 0, 'the box layer carries a non-negative origin offset');
    apiBoxes.forEach((b) => {
      assert.ok(parseFloat(b.style.left) + offset >= 0,
        'the straddling api box lands at a non-negative world pixel (not clipped off-canvas)');
    });
    // domain is open ⇒ an arrow from the box to the capability it targets (§7).
    const svg = edgeLayer(window);
    assert.ok(svg.querySelectorAll('path.bp-api-arrow').length >= 1,
      'an open domain draws the api→target capability arrow');
    // the queue (async) edge is dashed (its own anti-regression for the async rule).
    assert.ok(svg.querySelectorAll('path.bp-edge-async').length >= 1,
      'a queue (async) edge renders dashed (.bp-edge-async)');
  } finally { window.close(); }
});
