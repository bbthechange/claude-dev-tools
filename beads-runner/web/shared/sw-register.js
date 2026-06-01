/* beads-runner/web/shared/sw-register.js — claude-tools-4zrn.
 *
 * Registers the shared offline-read service worker (/shared/sw.js) and paints a
 * lightweight "offline — last-known snapshot" badge from the browser's
 * online/offline events. Included by every NON-Inbox page (board, workspaces,
 * capacity, cross-ws, workspace) and deliberately NOT by the Inbox — the Inbox
 * is the live decision/liveness surface (S-1) and owns its own /inbox/sw.js.
 *
 * Contract C (app-shell, web/shared/): a thin, page-agnostic shell concern — no
 * per-view code, no network call of its own. Standalone IIFE; depends on
 * nothing else (loaded after the shared modules, but reaches into none of
 * them). The badge's chrome lives in tokens.css (#offline-badge), like the nav
 * chrome — this file only toggles it. */
(function () {
  'use strict';

  // Defensive: even if this script is ever included on an Inbox route, no-op
  // there — the Inbox must never be offline-cached by the shared worker (S-1).
  if (location.pathname.indexOf('/inbox') === 0) return;

  if ('serviceWorker' in navigator) {
    // scope `/` so the one worker covers every pull surface; the _headers entry
    // serves /shared/sw.js with `Service-Worker-Allowed: /` to permit it. The
    // Inbox's own /inbox/sw.js (scope /inbox/, more specific) still wins for
    // Inbox clients, so this never touches the live surface.
    navigator.serviceWorker.register('/shared/sw.js', { scope: '/' }).catch(function (e) {
      // Honest, non-fatal (principle 4): off-network read is an enhancement;
      // the page still works online without it.
      if (window.console) window.console.warn('[sw] offline-read worker registration failed', e);
    });
  }

  // ── the "you are offline — showing the last-known snapshot" badge ──────────
  // navigator.onLine + the online/offline events are the page-agnostic signal;
  // the badge is honest about WHY the data might not be live, without each
  // view's render path having to learn about caching.
  var badge = null;
  function ensureBadge() {
    if (badge) return badge;
    badge = document.createElement('div');
    badge.id = 'offline-badge';
    badge.setAttribute('role', 'status');
    badge.textContent = '⚡ Offline — showing last-known snapshot';
    document.body.appendChild(badge);
    return badge;
  }
  function reflect() {
    if (navigator.onLine === false) ensureBadge().hidden = false;
    else if (badge) badge.hidden = true;
  }
  window.addEventListener('online', reflect);
  window.addEventListener('offline', reflect);
  if (document.body) reflect();
  else window.addEventListener('DOMContentLoaded', reflect);
})();
