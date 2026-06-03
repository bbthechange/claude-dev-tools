/* beads-runner/jsdom/test/sw-offline.test.js — claude-tools-4zrn.
 *
 * The off-network read path for the NON-Inbox surfaces (UX-DESIGN-V2 §2.1/§2.4
 * "local == remote ... reachable off-network and while the laptop sleeps").
 *
 * Two kinds of coverage, both deterministic + offline (§8 discipline):
 *   1. BEHAVIORAL — load the real web/shared/sw.js into a mocked service-worker
 *      realm (fake self/caches/fetch/Response via node:vm) and dispatch fetch
 *      events. Proves the contract the bead's ACCEPTANCE names: with the network
 *      BLOCKED, a previously-seen non-Inbox route serves its last-known snapshot;
 *      and the live Inbox surface (S-1) is NEVER cached or served stale.
 *   2. WIRING — grep the real source: every non-Inbox page registers the worker,
 *      the Inbox does NOT (S-1), and _headers permits the root scope.
 *
 * This is the offline regression-gate proof; the live deploy + verify-pages-
 * deploy.sh mismatches=0 (T8, manual at close) is the separate acceptance gate
 * that the bytes actually shipped (the bgw discipline).
 */
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const WEB = path.resolve(__dirname, '..', '..', 'web');
const read = (p) => fs.readFileSync(p, 'utf8');
const ORIGIN = 'https://test.local';
const flush = () => new Promise((r) => setImmediate(r));

// ── a minimal service-worker realm to run the REAL sw.js against ─────────────
function makeResponse(body, init) {
  init = init || {};
  const status = init.status == null ? 200 : init.status;
  return {
    _body: body,
    status,
    ok: status >= 200 && status < 300,
    headers: init.headers || {},
    clone() {
      return makeResponse(body, init);
    },
    text() {
      return Promise.resolve(String(body));
    }
  };
}
function makeCache() {
  const store = new Map(); // url string -> Response
  return {
    _store: store,
    match: (req) => Promise.resolve(store.get(req.url)),
    put: (req, resp) => {
      store.set(req.url, resp);
      return Promise.resolve();
    },
    keys: () => Promise.resolve([...store.keys()])
  };
}
function makeCacheStorage(seed) {
  const caches = new Map(); // name -> cache
  (seed || []).forEach((n) => caches.set(n, makeCache()));
  return {
    _caches: caches,
    open(name) {
      if (!caches.has(name)) caches.set(name, makeCache());
      return Promise.resolve(caches.get(name));
    },
    keys: () => Promise.resolve([...caches.keys()]),
    delete: (name) => Promise.resolve(caches.delete(name)),
    has: (name) => Promise.resolve(caches.has(name))
  };
}

// Load sw.js fresh into its own realm. Returns helpers to drive it.
function newEnv(opts) {
  opts = opts || {};
  const handlers = {};
  const sandbox = {
    Promise,
    JSON,
    URL,
    console: { warn() {}, error() {}, log() {} },
    caches: makeCacheStorage(opts.seedCaches),
    fetch: null, // set per-test
    Response: function Response(body, init) {
      return makeResponse(body, init);
    },
    self: {
      location: { origin: ORIGIN },
      addEventListener: (type, fn) => {
        handlers[type] = fn;
      },
      skipWaiting: () => Promise.resolve(),
      clients: { claim: () => Promise.resolve() }
    }
  };
  vm.createContext(sandbox);
  vm.runInContext(read(path.join(WEB, 'shared', 'sw.js')), sandbox);

  function setFetch(fn) {
    sandbox.fetch = fn;
  }
  function reqOf(url, o) {
    o = o || {};
    return { url, method: o.method || 'GET', mode: o.mode || 'cors' };
  }
  function dispatchFetch(req) {
    const event = { request: req, _responded: undefined, _waited: undefined };
    event.respondWith = (p) => {
      event._responded = p;
    };
    event.waitUntil = (p) => {
      event._waited = p;
    };
    handlers.fetch(event);
    return event;
  }
  // The two fetch behaviours we toggle: a live 200, or an offline reject.
  const online = (body) => () => Promise.resolve(makeResponse(body, { status: 200 }));
  const offline = () => () => Promise.reject(new Error('Failed to fetch'));

  return { handlers, sandbox, setFetch, reqOf, dispatchFetch, online, offline };
}

// ════════════════════════════════════════════════════════════════════════════
test('install + activate register the lifecycle and prune only OUR superseded caches', async () => {
  const env = newEnv({ seedCaches: ['beads-shell-v0', 'beads-snapshot-v0', 'someone-elses-cache'] });
  assert.equal(typeof env.handlers.install, 'function');
  assert.equal(typeof env.handlers.activate, 'function');
  assert.equal(typeof env.handlers.fetch, 'function');

  const ev = { _waited: undefined, waitUntil(p) { this._waited = p; } };
  env.handlers.activate(ev);
  await ev._waited;
  const names = await env.sandbox.caches.keys();
  // The v0 ones (our prefixes, superseded) are gone…
  assert.ok(!names.includes('beads-shell-v0'), 'stale beads-shell-v0 pruned');
  assert.ok(!names.includes('beads-snapshot-v0'), 'stale beads-snapshot-v0 pruned');
  // …a cache that isn't ours is left untouched (we never delete what we didn't make).
  assert.ok(names.includes('someone-elses-cache'), 'foreign cache left alone');
});

// ── THE CORE ACCEPTANCE: network blocked → last-known snapshot served ─────────
test('a non-Inbox API read: live when online, then served from cache when the network is BLOCKED', async () => {
  const env = newEnv();
  const req = env.reqOf(ORIGIN + '/api/board');

  // 1) ONLINE: a live 200 is returned AND cached for next time.
  env.setFetch(env.online('{"ok":true,"projects":["live-snapshot"]}'));
  let ev = env.dispatchFetch(req);
  let resp = await ev._responded;
  assert.equal(resp.status, 200);
  assert.match(await resp.text(), /live-snapshot/, 'online read is the live projection');
  await flush(); // let the fire-and-forget cache.put settle

  // 2) OFFLINE (network blocked): the SAME route serves the last-known snapshot.
  env.setFetch(env.offline());
  ev = env.dispatchFetch(req);
  resp = await ev._responded;
  assert.equal(resp.status, 200, 'offline read still 200 — from cache');
  assert.match(await resp.text(), /live-snapshot/, 'offline serves the LAST-KNOWN snapshot');
});

test('a non-Inbox API read offline with NOTHING cached returns an honest {ok:false} 503 (never a silent empty render)', async () => {
  const env = newEnv();
  env.setFetch(env.offline());
  const ev = env.dispatchFetch(env.reqOf(ORIGIN + '/api/capacity'));
  const resp = await ev._responded;
  assert.equal(resp.status, 503);
  const body = JSON.parse(resp._body);
  assert.equal(body.ok, false);
  assert.match(body.error, /offline/i, 'the error is honest about being offline');
});

test('an upstream error (non-200) is NOT cached — it must never become the last-known truth', async () => {
  const env = newEnv();
  const req = env.reqOf(ORIGIN + '/api/board');
  // Upstream returns a 503 {ok:false} (Coordinator unreachable). It passes
  // through, but must NOT be cached.
  env.setFetch(() => Promise.resolve(makeResponse('{"ok":false,"error":"upstream down"}', { status: 503 })));
  let ev = env.dispatchFetch(req);
  let resp = await ev._responded;
  assert.equal(resp.status, 503, 'the upstream error passes through verbatim when online');
  await flush();
  // Now go offline: since the error was not cached, we get the honest offline
  // envelope, NOT the cached upstream error masquerading as a snapshot.
  env.setFetch(env.offline());
  ev = env.dispatchFetch(req);
  resp = await ev._responded;
  assert.match(JSON.parse(resp._body).error, /no cached snapshot/i, 'no poisoned cache');
});

// ── S-1: the Inbox is the live surface — NEVER cached / served stale ──────────
for (const p of ['/inbox', '/inbox/', '/inbox/sw.js', '/api/inbox/list', '/api/push/subscribe']) {
  test(`S-1: ${p} is hard-bypassed (handler does not respondWith → straight to network)`, () => {
    const env = newEnv();
    env.setFetch(env.online('{"should":"never be served from cache"}'));
    const ev = env.dispatchFetch(env.reqOf(ORIGIN + p));
    assert.equal(ev._responded, undefined, `${p} must passthrough — the worker never intercepts the live Inbox`);
  });
}

// ── Intake is the Flow-A WRITE surface — DECIDED network-only (claude-tools-bnbb):
//    not in the §2.1 read-model view map, has no offline write path, and caching
//    its workspace list would violate Intake's `no-store` "don't add caching"
//    invariant (a stale list 422s at submit). So it stays bypassed. ─────────────
for (const p of ['/intake', '/intake/', '/api/intake/presets', '/api/intake/workspaces']) {
  test(`scope: ${p} is bypassed (Intake is a write surface, network-only — no stale presets while filing)`, () => {
    const env = newEnv();
    env.setFetch(env.online('{"presets":["stale"]}'));
    const ev = env.dispatchFetch(env.reqOf(ORIGIN + p));
    assert.equal(ev._responded, undefined, `${p} must passthrough — Intake is never offline-cached`);
  });
}

// ── prefix matching has a boundary: /inbox bypasses but a sibling-prefixed
//    route (e.g. a future /workspaces page) is NOT collateral-bypassed ─────────
test('the bypass is boundary-anchored: a non-Inbox /api read that merely shares a prefix is still cached', async () => {
  const env = newEnv();
  // /api/inboxes-archive does not exist, but the point is structural: a path that
  // is NOT under /api/inbox/ must take the network-first cache path, not bypass.
  const req = env.reqOf(ORIGIN + '/api/workspaces');
  env.setFetch(env.online('{"ok":true,"v":1}'));
  let ev = env.dispatchFetch(req);
  assert.notEqual(ev._responded, undefined, 'a real non-Inbox API read IS intercepted (network-first)');
  await ev._responded;
  await flush();
  env.setFetch(env.offline());
  ev = env.dispatchFetch(req);
  const resp = await ev._responded;
  assert.match(await resp.text(), /"v":1/, 'served from cache offline — proves it was not bypassed');
});

// ── no offline WRITE path, and never a proxy for third-party origins ──────────
test('a write (non-GET) is never intercepted — there is no offline write path', () => {
  const env = newEnv();
  env.setFetch(env.online('{}'));
  const ev = env.dispatchFetch(env.reqOf(ORIGIN + '/api/board/set-desired', { method: 'POST' }));
  assert.equal(ev._responded, undefined, 'POST passes straight through');
});
test('a cross-origin GET (fonts/CDN) is never intercepted', () => {
  const env = newEnv();
  env.setFetch(env.online('font-bytes'));
  const ev = env.dispatchFetch(env.reqOf('https://fonts.googleapis.com/css2?family=Fraunces'));
  assert.equal(ev._responded, undefined, 'cross-origin passes straight through');
});

// ── the app SHELL boots off-network (stale-while-revalidate) ─────────────────
test('the app shell is served from cache when offline after one online visit (SWR)', async () => {
  const env = newEnv();
  const req = env.reqOf(ORIGIN + '/board/', { mode: 'navigate' });
  env.setFetch(env.online('<!doctype html><title>Board</title>'));
  let ev = env.dispatchFetch(req);
  let resp = await ev._responded;
  assert.match(await resp.text(), /Board/, 'online navigation is the live shell');
  await flush();

  env.setFetch(env.offline());
  ev = env.dispatchFetch(req);
  resp = await ev._responded;
  assert.equal(resp.status, 200);
  assert.match(await resp.text(), /Board/, 'offline navigation serves the cached shell — the page boots off-network');
});
test('a NEVER-visited navigation offline returns the honest offline shell, not a broken page', async () => {
  const env = newEnv();
  env.setFetch(env.offline());
  const ev = env.dispatchFetch(env.reqOf(ORIGIN + '/capacity/', { mode: 'navigate' }));
  const resp = await ev._responded;
  assert.equal(resp.status, 503);
  assert.match(String(resp._body), /Offline/, 'an honest offline notice');
  assert.match(String(resp.headers['content-type'] || ''), /text\/html/, 'served as HTML, not a JSON blob in the viewport');
});

// ════════════════════════════════════════════════════════════════════════════
// WIRING — the real source registers the worker on every pull surface, never on
// the Inbox (S-1), and _headers permits the root scope.
test('_headers serves /shared/sw.js with Service-Worker-Allowed: / (root-scope registration)', () => {
  const h = read(path.join(WEB, '_headers'));
  assert.match(h, /^\/shared\/sw\.js$/m, '_headers has a /shared/sw.js block');
  // the block grants the root scope (so a /shared/-located worker can claim /).
  const block = h.slice(h.indexOf('/shared/sw.js'));
  assert.match(block, /Service-Worker-Allowed:\s*\//, 'the SW is allowed the root scope');
  assert.match(block, /Cache-Control:\s*no-cache/, 'the SW itself is served no-cache so updates land promptly');
});

test('sw-register.js registers /shared/sw.js at scope / and bails on the Inbox (S-1 guard)', () => {
  const reg = read(path.join(WEB, 'shared', 'sw-register.js'));
  assert.match(reg, /register\(\s*['"]\/shared\/sw\.js['"]\s*,\s*\{\s*scope:\s*['"]\/['"]/, 'registers at root scope');
  assert.match(reg, /\/inbox/, 'has the defensive Inbox bail (never offline-cache the live surface)');
});

const PULL_PAGES = ['board', 'workspaces', 'capacity', 'cross-ws', 'workspace'];
for (const dir of PULL_PAGES) {
  test(`${dir}/index.html registers the shared offline-read worker`, () => {
    const idx = read(path.join(WEB, dir, 'index.html'));
    assert.match(idx, /<script[^>]+\/shared\/sw-register\.js/, `${dir} must load /shared/sw-register.js`);
  });
}
test('the Inbox does NOT register the shared offline-read worker (S-1: it is the live surface)', () => {
  const idx = read(path.join(WEB, 'inbox', 'index.html'));
  assert.doesNotMatch(idx, /\/shared\/sw-register\.js/, 'the Inbox keeps its own push-only /inbox/sw.js — never the offline cache');
});
