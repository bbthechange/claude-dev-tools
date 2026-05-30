/* beads-runner/web/shared/net.js — C-shell (claude-tools-uxvsh).
 *
 * THE single same-origin, credential-less network module every view shares
 * (Contract C.1). Until now `getJSON`/`postJSON` were copy-pasted verbatim
 * into inbox/app.js and intake/app.js (and board kept its own inline reads).
 * They live here ONCE.
 *
 * §9.1/§9.2 invariant (carried): the browser bears NO secret and never picks
 * the principal or the op. These helpers ONLY hit same-origin Pages proxies
 * (`/api/...`); the proxy holds the Bearer server-side. There is intentionally
 * no place to attach an Authorization header here.
 *
 * Error discipline (principle 4 — never mask the real failure): read the body
 * as text FIRST, so a non-JSON 5xx still surfaces the HTTP status honestly
 * instead of being misreported as a parse error. The proxy's own honest
 * envelope ({ ok:false, error }) is surfaced verbatim. A non-ok HTTP status
 * with no usable envelope throws the status.
 *
 * UMD so the (pure-ish) helpers can be required in Node for a smoke test, and
 * attached to `window.Net` in the browser. No DOM, no timers, no global state. */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.Net = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  function getJSON(url) {
    return fetch(url, { method: 'GET', headers: { accept: 'application/json' } })
      .then(function (r) {
        return r.text().then(function (t) {
          var d;
          try { d = JSON.parse(t); }
          catch (e) { throw new Error('proxy returned non-JSON (HTTP ' + r.status + ')'); }
          if (d && d.ok === false && d.error) throw new Error(d.error);
          if (!r.ok) throw new Error('proxy HTTP ' + r.status);
          return d;
        });
      });
  }

  function postJSON(url, body) {
    return fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json', accept: 'application/json' },
      body: JSON.stringify(body)
    }).then(function (r) {
      return r.text().then(function (t) {
        var d;
        try { d = JSON.parse(t); } catch (e) { d = { ok: r.ok, raw: t }; }
        if (d && d.ok === false && d.error) throw new Error(d.error);
        if (!r.ok) throw new Error('write proxy HTTP ' + r.status);
        return d;
      });
    });
  }

  return { getJSON: getJSON, postJSON: postJSON };
});
