/* beads-runner/web/inbox/push.js — N2 (claude-tools-uxg1) — the Inbox PWA's
 * Web-Push subscribe glue. DESIGN N §2.2 part 1 (the browser side).
 *
 * Registers the service worker, captures the one-time Notification permission +
 * PushSubscription, and POSTs it to the same-origin /api/push/subscribe proxy
 * (the browser bears NO secret — §9.1/§9.2; window.Net hits the proxy, which
 * attaches the server bearer). A single header toggle reflects/drives state.
 *
 * Loaded AFTER /shared/net.js and /inbox/app.js (see index.html), and is
 * deliberately standalone (it never reaches into app.js's closure) so it is a
 * pure additive layer on the frozen Inbox shell.
 *
 * The VAPID PUBLIC key below is PUBLIC by design (it is the applicationServerKey
 * every subscriber needs). The matching PRIVATE key is a Worker SECRET
 * (VAPID_PRIVATE_KEY) and lives ONLY server-side. If the key pair is rotated,
 * regenerate both and update this constant + the Worker secret in lockstep.
 */
(function () {
  'use strict';

  // N2 VAPID public key (raw P-256 uncompressed point, base64url). Pair: the
  // private half is the Worker secret VAPID_PRIVATE_KEY (never in the repo).
  var VAPID_PUBLIC_KEY =
    'BFP6x3cxQPGjFJHTW3xqjW9IMDfJByLm4znvSxejYT4kgaJ59K_wcA7-tFDJsUlvPvsEHUvX6L1SNFaGJbzZA38';

  var supported =
    'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;

  var btn = document.getElementById('notif-toggle');

  function setBtn(label, disabled) {
    if (!btn) return;
    btn.hidden = false;
    btn.textContent = label;
    btn.disabled = !!disabled;
  }

  // RFC 8292 applicationServerKey wants the raw key as a Uint8Array.
  function urlB64ToUint8Array(b64) {
    var pad = '='.repeat((4 - (b64.length % 4)) % 4);
    var base = (b64 + pad).replace(/-/g, '+').replace(/_/g, '/');
    var raw = atob(base);
    var out = new Uint8Array(raw.length);
    for (var i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
    return out;
  }

  var swReg = null;

  function reflect() {
    if (!supported) {
      setBtn('Notifications unsupported', true);
      return;
    }
    if (Notification.permission === 'denied') {
      setBtn('🔕 Notifications blocked', true);
      return;
    }
    if (!swReg) {
      setBtn('🔔 Enable notifications', false);
      return;
    }
    swReg.pushManager.getSubscription().then(function (sub) {
      if (sub) setBtn('🔔 Notifications on — tap to turn off', false);
      else setBtn('🔔 Enable notifications', false);
    });
  }

  function subscribe() {
    setBtn('…', true);
    Notification.requestPermission()
      .then(function (perm) {
        if (perm !== 'granted') throw new Error('permission ' + perm);
        return swReg.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: urlB64ToUint8Array(VAPID_PUBLIC_KEY)
        });
      })
      .then(function (sub) {
        return window.Net.postJSON('/api/push/subscribe', sub.toJSON());
      })
      .then(function () {
        reflect();
      })
      .catch(function (e) {
        // Honest failure surfaced on the button itself (principle 4).
        setBtn('Could not enable (' + (e && e.message ? e.message : 'error') + ')', false);
        // eslint-disable-next-line no-console
        console.error('[push] subscribe failed', e);
      });
  }

  function unsubscribe() {
    setBtn('…', true);
    swReg.pushManager.getSubscription().then(function (sub) {
      if (!sub) {
        reflect();
        return;
      }
      var endpoint = sub.endpoint;
      sub
        .unsubscribe()
        .then(function () {
          return window.Net.postJSON('/api/push/unsubscribe', { endpoint: endpoint });
        })
        .then(function () {
          reflect();
        })
        .catch(function (e) {
          setBtn('Could not turn off (' + (e && e.message ? e.message : 'error') + ')', false);
        });
    });
  }

  function onClick() {
    if (!swReg) return;
    swReg.pushManager.getSubscription().then(function (sub) {
      if (sub) unsubscribe();
      else subscribe();
    });
  }

  if (!supported) {
    reflect();
    return;
  }
  if (btn) btn.addEventListener('click', onClick);

  navigator.serviceWorker
    .register('/inbox/sw.js')
    .then(function (reg) {
      swReg = reg;
      reflect();
    })
    .catch(function (e) {
      // eslint-disable-next-line no-console
      console.error('[push] service worker registration failed', e);
      setBtn('Notifications unavailable', true);
    });
})();
