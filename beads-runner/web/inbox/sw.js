/* beads-runner/web/inbox/sw.js — N2 (claude-tools-uxg1) — the Inbox PWA
 * service worker. DESIGN N §2.2 part 1: wake on a `push` and ring the ONE push
 * surface (ARCH line 283 — "the Inbox is the only push surface").
 *
 * It does the push-surface job and nothing else (it is NOT an offline cache —
 * the Inbox reads live liveness/decision state and must never serve a stale
 * projection, S-1; so there is deliberately no fetch-caching handler):
 *   • `push`            → render a TRIAGE-only system notification from the
 *                         payload { tldr, dossier_ref, tier, url } (principle 2:
 *                         the §5 body NEVER crosses the wire — only the TL;DR +
 *                         a deep link).
 *   • `notificationclick` → focus an open Inbox tab at the deep link, or open
 *                         one (/inbox#/d/<dossier_ref> for a decision; /inbox
 *                         for a digest).
 *   • `pushsubscriptionchange` → push-infrastructure MAINTENANCE (not a new
 *                         capability): when the browser rotates/expires the
 *                         subscription, re-POST the renewed endpoint to the
 *                         /api/push/subscribe proxy so delivery doesn't silently
 *                         die (stale endpoint → 410 at notif-deliver → row
 *                         pruned → Brian stops being paged with no signal).
 */
'use strict';

// VAPID public key — MIRRORS the constant in web/inbox/push.js:23. The
// `pushsubscriptionchange` handler below may have to re-subscribe when the
// browser couldn't auto-renew, and the SW has no access to push.js's IIFE
// scope (separate execution context), so the key must be duplicated here. It
// is PUBLIC by design (the applicationServerKey every subscriber needs — safe
// to embed; see notifications.md "VAPID private key is server-side only"). The
// two copies MUST match: rotate both in lockstep (and the Worker secret
// VAPID_PRIVATE_KEY).
var VAPID_PUBLIC_KEY =
  'BFP6x3cxQPGjFJHTW3xqjW9IMDfJByLm4znvSxejYT4kgaJ59K_wcA7-tFDJsUlvPvsEHUvX6L1SNFaGJbzZA38';

// RFC 8292 applicationServerKey wants the raw key as a Uint8Array. Mirror of
// the helper in push.js (same reason as the constant above — no shared scope).
function urlB64ToUint8Array(b64) {
  var pad = '='.repeat((4 - (b64.length % 4)) % 4);
  var base = (b64 + pad).replace(/-/g, '+').replace(/_/g, '/');
  var raw = atob(base);
  var out = new Uint8Array(raw.length);
  for (var i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}

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

// Push-subscription rotation maintenance. Browsers periodically rotate a
// PushSubscription (expiry, browser/OS update, endpoint recycling). When that
// happens the stored endpoint in push_subscriptions goes stale, notif-deliver
// gets a 410 from the push service, push.js prunes the dead row, and paging
// silently stops. This handler re-registers the renewed subscription so the
// link self-heals.
//
// It runs in the SW context (no DOM, no window.Net), so it fetch()es the
// same-origin /api/push/{subscribe,unsubscribe} proxies directly — they attach
// the server bearer server-side (§9.1/§9.2), so the SW bears no secret.
self.addEventListener('pushsubscriptionchange', function (e) {
  e.waitUntil(
    // newSubscription is set when the browser already auto-renewed; otherwise
    // re-subscribe ourselves with the (public) applicationServerKey.
    (e.newSubscription
      ? Promise.resolve(e.newSubscription)
      : self.registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: urlB64ToUint8Array(VAPID_PUBLIC_KEY)
        })
    ).then(function (sub) {
      var ops = [
        fetch('/api/push/subscribe', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify(sub.toJSON())
        })
      ];
      // Best-effort cleanup of the rotated-out endpoint. Not required for
      // correctness — notif-deliver already prunes 404/410s — but tidy.
      if (e.oldSubscription) {
        ops.push(
          fetch('/api/push/unsubscribe', {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ endpoint: e.oldSubscription.endpoint })
          })
        );
      }
      return Promise.all(ops);
    })
  );
});
