/* beads-runner/web/inbox/sw.js — N2 (claude-tools-uxg1) — the Inbox PWA
 * service worker. DESIGN N §2.2 part 1: wake on a `push` and ring the ONE push
 * surface (ARCH line 283 — "the Inbox is the only push surface").
 *
 * It does TWO things and nothing else (it is NOT an offline cache — the Inbox
 * reads live liveness/decision state and must never serve a stale projection,
 * S-1; so there is deliberately no fetch-caching handler):
 *   • `push`            → render a TRIAGE-only system notification from the
 *                         payload { tldr, dossier_ref, tier, url } (principle 2:
 *                         the §5 body NEVER crosses the wire — only the TL;DR +
 *                         a deep link).
 *   • `notificationclick` → focus an open Inbox tab at the deep link, or open
 *                         one (/inbox#/d/<dossier_ref> for a decision; /inbox
 *                         for a digest).
 */
'use strict';

// Take over immediately so the first install can receive a push without a
// reload (the one-time subscribe → first push should "just work").
self.addEventListener('install', function (e) {
  self.skipWaiting();
});
self.addEventListener('activate', function (e) {
  e.waitUntil(self.clients.claim());
});

self.addEventListener('push', function (e) {
  var data = {};
  try {
    data = e.data ? e.data.json() : {};
  } catch (err) {
    data = {};
  }
  var tier = data.tier || 'blocking';
  var isDigest = data.dossier_ref == null || tier === 'digest' || tier === 'timed-fyi';
  var title = isDigest ? 'Beads — daily digest' : 'Beads — a decision needs you';
  var body = data.tldr || (isDigest ? 'Updates are waiting in your Inbox.' : 'Tap to open the dossier.');
  var url = typeof data.url === 'string' && data.url ? data.url : '/inbox';

  e.waitUntil(
    self.registration.showNotification(title, {
      body: body,
      tag: data.dossier_ref || ('digest:' + (data.channel || 'all')),
      renotify: true,
      // A real decision should not auto-dismiss before Brian sees it; a digest
      // is read-mostly and may.
      requireInteraction: !isDigest,
      data: { url: url },
      icon: '/inbox/icon.svg',
      badge: '/inbox/icon.svg'
    })
  );
});

self.addEventListener('notificationclick', function (e) {
  e.notification.close();
  var target = (e.notification.data && e.notification.data.url) || '/inbox';
  e.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (cls) {
      for (var i = 0; i < cls.length; i++) {
        var c = cls[i];
        // Focus an already-open Inbox tab and route it to the deep link.
        if (c.url.indexOf('/inbox') !== -1 && 'focus' in c) {
          c.navigate(target);
          return c.focus();
        }
      }
      if (self.clients.openWindow) return self.clients.openWindow(target);
    })
  );
});
