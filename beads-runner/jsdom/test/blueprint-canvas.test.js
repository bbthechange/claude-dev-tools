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
