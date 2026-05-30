/* beads-runner/web/shared/dom.js — C-shell (claude-tools-uxvsh).
 *
 * THE shared DOM helpers (Contract C.1). `mk`/`clear`/`el` were re-implemented
 * in every page; they live here ONCE as `window.Dom`. Pure presentation glue —
 * no network, no app state.
 *
 *   Dom.el(id)            → document.getElementById(id)
 *   Dom.clear(node)       → remove every child (idempotent)
 *   Dom.mk(tag, cls, txt) → create an element with an optional class + textContent
 *
 * `mk` uses textContent (never innerHTML) so callers cannot accidentally inject
 * markup — the same XSS-safe discipline the existing views rely on. */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.Dom = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  function el(id) { return document.getElementById(id); }

  function clear(node) {
    if (!node) return node;
    while (node.firstChild) node.removeChild(node.firstChild);
    return node;
  }

  function mk(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }

  return { el: el, clear: clear, mk: mk };
});
