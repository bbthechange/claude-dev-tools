/* beads-runner/web/shared/sw.js — claude-tools-4zrn — the SHARED offline-read
 * service worker for the NON-Inbox surfaces.
 *
 * WHY: UX-DESIGN-V2 §2.1/§2.4 ("Local == remote") promises EVERY surface is
 * "reachable off-network and while the laptop sleeps." The Inbox got its PWA
 * service worker in N2, but that one is push-only and deliberately NOT an
 * offline cache (inbox/sw.js header: the Inbox reads live liveness/decision
 * state and must never serve a stale projection — S-1). So Board / Blueprint /
 * Activity / Gates / Workspaces / Capacity / Cross-WS had no off-network read
 * path at all. This worker is that path.
 *
 * SCOPE DECISION (this bead, per its ACCEPTANCE "decide scope"): read-only
 * LAST-KNOWN snapshot, NOT full offline write. Concretely:
 *   • Static app-shell (navigations + CSS/JS/tokens/icons) → STALE-WHILE-
 *     REVALIDATE, so the shell BOOTS off-network and silently updates for next
 *     load. (verify-pages-deploy.sh byte-compares the LIVE host, not this cache,
 *     so SWR never masks a stale deploy — the bgw gate is unaffected.)
 *   • Non-Inbox API reads (/api/… GET) → NETWORK-FIRST: always live when online,
 *     fall back to the last cached snapshot ONLY when the network is
 *     unreachable. This is the "last-known render" the bead asks for.
 *   • Writes (any non-GET) and cross-origin (fonts/CDN) → never touched
 *     (passthrough). There is deliberately no offline write path.
 *
 * THE INBOX IS DELIBERATELY EXEMPT (S-1). This worker registers at scope `/`,
 * but the Inbox owns the more-specific scope `/inbox/` via its own
 * /inbox/sw.js, so the Inbox's clients are never controlled by this worker.
 * As belt-and-suspenders, the fetch handler HARD-BYPASSES /inbox, /api/inbox
 * and /api/push: those always go straight to the network, are never cached, and
 * are never served from cache. The Inbox must never show a stale projection.
 *
 * INTAKE IS ALSO BYPASSED (scope, not S-1). Because this worker is scope `/`, it
 * would otherwise sweep in /intake too — but Intake is the Flow-A WRITE surface,
 * outside this bead's read-only scope, with no offline write path. /intake and
 * /api/intake stay network-only so a stale presets/workspaces list can't mislead
 * someone filing work. See isBypassed().
 *
 * HONESTY (principle 4): an offline read with no cached snapshot yet returns an
 * honest JSON {ok:false,error} 503 envelope — the SAME shape the views already
 * surface (board/app.js refresh(), Net.getJSON) — never a silent empty render.
 */
'use strict';

var VERSION = 'v1';
var STATIC_CACHE = 'beads-shell-' + VERSION; // app-shell static assets (SWR)
var API_CACHE = 'beads-snapshot-' + VERSION; // last-known non-Inbox API reads
var OURS = [STATIC_CACHE, API_CACHE];

// Activate the new worker immediately so the very first visit starts caching.
self.addEventListener('install', function () {
  self.skipWaiting();
});

self.addEventListener('activate', function (e) {
  e.waitUntil(
    caches
      .keys()
      .then(function (keys) {
        // Drop our own superseded versions; never touch caches that aren't
        // ours (the Inbox keeps none, but be precise regardless).
        return Promise.all(
          keys.map(function (k) {
            var ours = k.indexOf('beads-shell-') === 0 || k.indexOf('beads-snapshot-') === 0;
            if (ours && OURS.indexOf(k) === -1) return caches.delete(k);
            return null;
          })
        );
      })
      .then(function () {
        return self.clients.claim();
      })
  );
});

// Prefix match with a path boundary, so `/inbox` matches `/inbox` and
// `/inbox/…` but NOT `/inboxes` (and `/intake` not `/intaker`).
function underPath(pathname, base) {
  return pathname === base || pathname.indexOf(base + '/') === 0;
}

// Paths this worker must NEVER cache or serve from cache (it returns without
// respondWith → the browser fetches them normally, always live):
//   • /inbox, /api/inbox, /api/push — the live Inbox decision/liveness surface
//     + its push plumbing (S-1). The Inbox must never show a stale projection.
//   • /intake, /api/intake — Intake is the Flow-A WRITE surface (file new work).
//     It is deliberately OUTSIDE this bead's read-only scope (which is the pull
//     surfaces the bead enumerates: Board/Blueprint/Activity/Gates/Workspaces/
//     Capacity/Cross-WS). There is no offline write path, and a cached-stale
//     presets/workspaces list while filing would mislead — so Intake stays
//     network-only. (The worker registers at scope `/`, so without this it
//     would otherwise sweep Intake in implicitly.)
function isBypassed(url) {
  var p = url.pathname;
  return (
    underPath(p, '/inbox') ||
    underPath(p, '/api/inbox') ||
    underPath(p, '/api/push') ||
    underPath(p, '/intake') ||
    underPath(p, '/api/intake')
  );
}
function isApiRead(url) {
  return url.pathname.indexOf('/api/') === 0;
}

function jsonError(status, msg) {
  return new Response(JSON.stringify({ ok: false, error: msg }), {
    status: status,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store' }
  });
}

function offlineShell() {
  // Minimal honest HTML for a NEVER-visited navigation while offline (nothing
  // cached to render). A visited route returns its cached shell instead.
  return new Response(
    '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
      '<title>Offline</title><body style="font:14px/1.5 ui-monospace,monospace;background:#080a0e;color:#e8ebf1;padding:2rem">' +
      '<p>⚡ Offline — this view has not been opened on this device yet, so there is no last-known snapshot to show.</p>' +
      '<p style="color:#8b94a6">Reconnect and reload; it will be available off-network after one online visit.</p>',
    { status: 503, headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' } }
  );
}

self.addEventListener('fetch', function (e) {
  var req = e.request;
  // Only same-origin GETs are eligible. Writes (POST/PUT/…) and cross-origin
  // requests (fonts/CDN) are left entirely to the browser — no offline write
  // path, and we never become a proxy for third-party origins.
  if (req.method !== 'GET') return;
  var url;
  try {
    url = new URL(req.url);
  } catch (err) {
    return;
  }
  if (url.origin !== self.location.origin) return;
  // S-1 + scope: the live Inbox and the Intake write surface passthrough — never
  // cached, never served stale by this worker.
  if (isBypassed(url)) return;

  if (isApiRead(url)) {
    e.respondWith(networkFirst(req));
    return;
  }
  // Everything else same-origin (navigations, CSS, JS, tokens, icons) is the
  // app shell → stale-while-revalidate so it boots offline.
  e.respondWith(staleWhileRevalidate(req));
});

function networkFirst(req) {
  return fetch(req)
    .then(function (resp) {
      // Cache a clone of a USABLE snapshot for the next offline read. Only a
      // real 200 — an upstream {ok:false} 5xx must not become the cached truth
      // (principle 4: never let an error masquerade as the last-known state).
      if (resp && resp.ok) {
        var copy = resp.clone();
        caches.open(API_CACHE).then(function (c) {
          c.put(req, copy);
        });
      }
      return resp;
    })
    .catch(function () {
      // Network unreachable (offline / laptop asleep): serve the last-known
      // snapshot if we have one, else an honest offline envelope.
      return caches.open(API_CACHE).then(function (c) {
        return c.match(req).then(function (hit) {
          return hit || jsonError(503, 'offline — no cached snapshot for this view yet');
        });
      });
    });
}

function staleWhileRevalidate(req) {
  return caches.open(STATIC_CACHE).then(function (c) {
    return c.match(req).then(function (hit) {
      var net = fetch(req)
        .then(function (resp) {
          if (resp && resp.ok) c.put(req, resp.clone());
          return resp;
        })
        .catch(function () {
          return null;
        });
      // Serve cache immediately if present (and revalidate in the background);
      // otherwise wait for the network. If both miss while offline, give a
      // navigation the honest offline shell, other assets the JSON envelope.
      if (hit) return hit;
      return net.then(function (resp) {
        if (resp) return resp;
        return req.mode === 'navigate'
          ? offlineShell()
          : jsonError(503, 'offline — this asset is not cached yet');
      });
    });
  });
}
