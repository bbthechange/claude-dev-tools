/* beads-runner/jsdom/test/cross-ws.test.js — K5 (claude-tools-uxvk5) the
 * /cross-ws ROUTE anti-regression (TESTING-STRATEGY.md §7.4; DESIGN K §6).
 *
 * Drives the REAL web/cross-ws/app.js in jsdom over the two reads the surface
 * binds (relay-log-tail B.3 + per-workspace blueprint-get B.2, both stubbed) and
 * asserts the DOM is the live two-pane surface, NOT the old placeholder:
 *   (a) COUPLING MAP — a fit-to-width SVG with a workspace BOX per relayed
 *       workspace at DISTINCT positions (the bplayout EXISTENCE!=LEGIBILITY
 *       lesson — boxes must spread, not stack) + a drawn coupling EDGE. This is
 *       the H2 model (deriveBlueprintView) reused on the federated record.
 *   (b) RELAY LOG — one row per exchange, the escalated row pointing at its
 *       decision (dossier_ref), the resolved row showing its answer, plus the
 *       counts summary.
 *   (c) the honest EMPTY state (no relays) and the UNAVAILABLE state (a proxy
 *       {ok:false} ⇒ "Relay log unavailable", never a fabricated log).
 *
 * Discipline (§8): deterministic (explicit stubbed reads; no wall-clock matters
 * to structure), no network, assert STRUCTURE not pixels (geometry is [free]).
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
  blueprintView: path.join(WEB, 'workspace', 'blueprint-view.js'),
  crossWsView: path.join(WEB, 'cross-ws', 'cross-ws-view.js'),
  index: path.join(WEB, 'cross-ws', 'index.html'),
  app: path.join(WEB, 'cross-ws', 'app.js'),
};
const read = (p) => fs.readFileSync(p, 'utf8');
function runInWindow(window, src) {
  const s = window.document.createElement('script');
  s.textContent = src;
  window.document.body.appendChild(s);
}
const flush = () => new Promise((r) => setTimeout(r, 0));

// Load the REAL cross-ws shell + app.js with the relay log + per-ref blueprints
// pre-resolved through a stubbed Net (mirrors blueprint-canvas.test.js's loader).
function loadCrossWs(relay, blueprints) {
  const html = read(P.index).replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, '');
  const dom = new JSDOM(html, {
    url: 'https://test.local/cross-ws',
    runScripts: 'dangerously',
    pretendToBeVisual: true,
  });
  const { window } = dom;
  const stub =
    'window.Net = { getJSON: function (url) {' +
    '  if (url.indexOf("/api/cross-ws/relay") === 0) {' +
    '    var relayBody = ' + JSON.stringify(relay) + ';' +
    // __throw mirrors the REAL Net.getJSON: a proxy {ok:false} (502/503) REJECTS
    // (net.js throws on it) — so the production relay-down path is a rejection,
    // not a resolved {ok:false}. The app must catch it into the envelope.
    '    if (relayBody && relayBody.__throw) return Promise.reject(new Error(relayBody.error || "relay read failed"));' +
    '    return Promise.resolve(relayBody);' +
    '  }' +
    '  if (url.indexOf("/api/ws/blueprint") === 0) {' +
    '    var m = url.match(/project_ref=([^&]+)/);' +
    '    var ref = m ? decodeURIComponent(m[1]) : "";' +
    '    var bps = ' + JSON.stringify(blueprints || {}) + ';' +
    '    return Promise.resolve(Object.prototype.hasOwnProperty.call(bps, ref) ? bps[ref] : null);' +
    '  }' +
    '  return Promise.resolve(null);' +
    '} };';
  runInWindow(window, stub);
  runInWindow(window, read(P.dom));
  runInWindow(window, read(P.shell));
  runInWindow(window, read(P.blueprintView));
  runInWindow(window, read(P.crossWsView));
  runInWindow(window, read(P.app));
  return window;
}

async function settle() { for (let i = 0; i < 8; i++) await flush(); }

// SVG class matching is robust via the class attribute (SVG className is not a
// plain string in jsdom) — collect nodes whose class attr lists the token.
function bySvgClass(doc, tag, token) {
  return Array.from(doc.querySelectorAll(tag)).filter((n) => {
    const c = n.getAttribute('class') || '';
    return c.split(/\s+/).indexOf(token) !== -1;
  });
}

const RELAY_GOOD = {
  exchanges: [
    { id: 'x1', from_ws: 'FE', to_ws: 'BE', at: '2026-06-06T09:00:00Z',
      question: 'cancel endpoint shape?', answer: '204 on already-cancelled',
      outcome: 'resolved', dossier_ref: null },
    { id: 'x2', from_ws: 'FE', to_ws: 'BE', at: '2026-06-06T11:30:00Z',
      question: 'refund field name?', answer: '',
      outcome: 'escalated', dossier_ref: 'thirsty-be-12f' },
    { id: 'x3', from_ws: 'BE', to_ws: 'FE', at: '2026-06-06T11:50:00Z',
      question: 'auth header?', answer: 'Bearer in Authorization',
      outcome: 'resolved', dossier_ref: null },
  ],
};
const BLUEPRINTS = {
  FE: { schema_version: 1, project_ref: 'FE', derived: {
    nodes: [
      { id: 'domain:posts', label: 'Posts', kind: 'domain', parent: null },
      { id: 'domain:profile', label: 'Profile', kind: 'domain', parent: null },
    ], edges: [], apis: [] } },
};

test('coupling map: boxes per workspace at distinct positions + a drawn edge (H2 reuse)', async () => {
  const w = loadCrossWs(RELAY_GOOD, BLUEPRINTS);
  try {
    await settle();
    const doc = w.document;

    assert.equal(doc.getElementById('cw').hidden, false, 'the live view is shown, not the error box');
    assert.ok(doc.querySelector('svg.cw-svg') || doc.querySelector('svg'), 'a coupling-map SVG is rendered');

    const boxes = bySvgClass(doc, 'rect', 'cw-node');
    assert.ok(boxes.length >= 2, 'one workspace box per relayed workspace (FE, BE) — got ' + boxes.length);

    // EXISTENCE != LEGIBILITY: the boxes must SPREAD, not stack in one column.
    const xs = new Set(boxes.map((b) => b.getAttribute('x')));
    assert.ok(xs.size >= 2, 'workspace boxes occupy distinct x positions (a 2-D map, not a stack)');

    const edges = bySvgClass(doc, 'line', 'cw-edge');
    assert.ok(edges.length >= 1, 'at least one coupling edge is drawn between workspaces');

    // map-empty must be hidden when coupling exists.
    assert.equal(doc.getElementById('map-empty').hidden, true, 'no "no coupling" banner when coupling exists');
  } finally { w.close(); } // clear app.js's setInterval so node:test can exit
});

test('relay log: a row per exchange, escalation points at the decision, resolved shows the answer', async () => {
  const w = loadCrossWs(RELAY_GOOD, BLUEPRINTS);
  try {
    await settle();
    const doc = w.document;

    const rows = doc.querySelectorAll('.rl-row');
    assert.equal(rows.length, 3, 'one relay row per exchange');

    const summary = doc.getElementById('relay-summary').textContent;
    assert.ok(/3 exchanges/.test(summary), 'summary counts the exchanges');
    assert.ok(/2 resolved/.test(summary) && /1 escalated/.test(summary), 'summary splits resolved vs escalated');

    assert.ok(doc.querySelector('.rl-chip.escalated'), 'the escalated row carries an escalated chip');
    const bodyText = Array.from(doc.querySelectorAll('.rl-a')).map((n) => n.textContent).join(' | ');
    assert.ok(/thirsty-be-12f/.test(bodyText), 'the escalated row points at its decision dossier');
    assert.ok(/204 on already-cancelled/.test(bodyText), 'a resolved row shows its answer');

    assert.equal(doc.getElementById('relay-empty').hidden, true, 'no empty banner when rows exist');
  } finally { w.close(); }
});

test('empty relay log: honest no-coupling + no rows (never a phantom)', async () => {
  const w = loadCrossWs({ exchanges: [] }, {});
  try {
    await settle();
    const doc = w.document;

    assert.equal(doc.getElementById('cw').hidden, false, 'the view still renders (read succeeded, just empty)');
    assert.equal(doc.querySelectorAll('.rl-row').length, 0, 'no relay rows');
    assert.equal(doc.getElementById('relay-empty').hidden, false, 'the "no exchanges yet" banner shows');
    assert.equal(doc.getElementById('map-empty').hidden, false, 'the "no coupling yet" banner shows');
    assert.equal(bySvgClass(doc, 'rect', 'cw-node').length, 0, 'no workspace boxes when there is no coupling');
  } finally { w.close(); }
});

test('unavailable relay log (proxy REJECTS, the real Net path): honest banner, page stays up, never a fabricated log (B.4)', async () => {
  // __throw makes the relay read REJECT, exactly as the live proxy's 502/503
  // {ok:false} does through net.js — the production relay-down path.
  const w = loadCrossWs({ __throw: true, error: 'Coordinator unreachable from the Cross-WS relay read proxy' }, {});
  try {
    await settle();
    const doc = w.document;

    // the page must NOT collapse to the full error box — it degrades in-place.
    assert.equal(doc.getElementById('cw').hidden, false, 'the two-pane view stays up (no full-page error box)');
    assert.equal(doc.getElementById('errbox').hidden, true, 'the page-level error box is NOT shown on a relay-down');

    assert.equal(doc.querySelectorAll('.rl-row').length, 0, 'no fabricated rows on a relay failure');
    const empty = doc.getElementById('relay-empty');
    assert.equal(empty.hidden, false, 'the relay banner is shown');
    assert.ok(/Relay log unavailable/.test(empty.textContent), 'the banner says unavailable');
    assert.ok(/Coordinator unreachable/.test(empty.textContent), 'it surfaces the proxy error');

    // coupling map degrades to the honest empty state (no refs to federate).
    assert.equal(doc.getElementById('map-empty').hidden, false, 'the coupling map shows its honest no-coupling state');
  } finally { w.close(); }
});
