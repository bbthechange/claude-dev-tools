/* beads-runner/web/shared/shell.js — C-shell (claude-tools-uxvsh).
 *
 * THE persistent navigation shell every view plugs into (Contract C.2,
 * UX-DESIGN-V2 §2). It renders:
 *   • the GLOBAL row, always present:  Inbox · Workspaces · Capacity · Cross-WS
 *   • the WORKSPACE row, only inside a workspace context (entered by tapping a
 *     Workspaces-hub card):  Board · Blueprint · Activity · Gates
 *
 * Route shape (Contract C.2 — the spine seam; the impl below is [free]):
 *   global    /inbox /workspaces /capacity /cross-ws
 *   facet     /ws/<ref>/{board,blueprint,activity,gates}
 * Switching facets never leaves the workspace context (the ref stays in the
 * URL). When a workspace context is active the GLOBAL "Workspaces" link is
 * highlighted too, so the hub is always the anchor (no scavenger hunt, §2).
 *
 * Split like the view-models: `deriveNav(opts)` is PURE (no DOM) and returns
 * the nav model, so it is Node-testable exactly like deriveBoardView; `mount`
 * paints that model into the page. The facet UIs (Blueprint=H3, Activity=I3,
 * Gates=J3) and the global Cross-WS map (K5) plug into this shell unchanged —
 * they own their view, this owns the chrome around it.
 *
 * UMD: `window.Shell` in the browser, requireable in Node for deriveNav tests. */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.Shell = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // The 4 global surfaces (UX-DESIGN-V2 §2.1) — FROZEN order. `key` is the
  // identifier a page passes as opts.active; `href` is the Contract C.2 route.
  var GLOBAL = [
    { key: 'inbox',      label: 'Inbox',      href: '/inbox' },
    { key: 'workspaces', label: 'Workspaces', href: '/workspaces' },
    { key: 'capacity',   label: 'Capacity',   href: '/capacity' },
    { key: 'cross-ws',   label: 'Cross-WS',   href: '/cross-ws' }
  ];

  // The 4 workspace facets (UX-DESIGN-V2 §2.1) — FROZEN order.
  var FACETS = [
    { key: 'board',     label: 'Board' },
    { key: 'blueprint', label: 'Blueprint' },
    { key: 'activity',  label: 'Activity' },
    { key: 'gates',     label: 'Gates' }
  ];

  function encodeRef(ref) {
    // Refs are simple project ids today, but encode defensively so a ref with
    // a reserved char cannot break the path. Never throws.
    try { return encodeURIComponent(String(ref)); } catch (e) { return String(ref); }
  }

  /* deriveNav(opts) → pure nav model.
   *   opts.active    : one of the GLOBAL keys (or a facet key) — the current view.
   *   opts.workspace : { ref, facet } when inside a workspace context, else null.
   * Returns { global:[{key,label,href,active}], workspace: null | {ref, facet,
   * tabs:[{key,label,href,active}]} }. When a workspace is active the global
   * 'workspaces' entry is also marked active (the hub stays the anchor). */
  function deriveNav(opts) {
    var o = opts || {};
    var ws = (o.workspace && o.workspace.ref) ? o.workspace : null;
    var activeFacet = ws ? (ws.facet || 'board') : null;
    // A workspace context implies the Workspaces hub is the active global anchor;
    // a bare global view uses its own key.
    var activeGlobal = ws ? 'workspaces' : (o.active || null);

    var global = GLOBAL.map(function (g) {
      return { key: g.key, label: g.label, href: g.href, active: g.key === activeGlobal };
    });

    var workspace = null;
    if (ws) {
      var ref = ws.ref;
      workspace = {
        ref: ref,
        facet: activeFacet,
        tabs: FACETS.map(function (f) {
          return {
            key: f.key,
            label: f.label,
            href: '/ws/' + encodeRef(ref) + '/' + f.key,
            active: f.key === activeFacet
          };
        })
      };
    }
    return { global: global, workspace: workspace };
  }

  // ── DOM mount (browser only) ───────────────────────────────────────────────
  function rowLink(item) {
    var a = document.createElement('a');
    a.setAttribute('href', item.href);
    a.textContent = item.label;
    if (item.active) {
      a.className = 'active';
      a.setAttribute('aria-current', 'page');
    }
    return a;
  }

  /* mount(opts) — paint the nav model into the page.
   * Target: an existing element with id="shell-nav" if present, otherwise a
   * <nav> is created and prepended as the first child of <body>. Idempotent —
   * re-mounting clears and repaints (a workspace shell repaints on facet
   * switch). Returns the nav model (the deriveNav result) for callers/tests. */
  function mount(opts) {
    var model = deriveNav(opts);
    if (typeof document === 'undefined') return model;

    var nav = document.getElementById('shell-nav');
    if (!nav) {
      nav = document.createElement('nav');
      nav.id = 'shell-nav';
      if (document.body) document.body.insertBefore(nav, document.body.firstChild);
    }
    nav.className = 'shell-nav';
    nav.setAttribute('aria-label', 'Primary');
    while (nav.firstChild) nav.removeChild(nav.firstChild);

    var globalRow = document.createElement('div');
    globalRow.className = 'shell-row shell-global';
    model.global.forEach(function (g) { globalRow.appendChild(rowLink(g)); });
    nav.appendChild(globalRow);

    if (model.workspace) {
      var tabsRow = document.createElement('div');
      tabsRow.className = 'shell-row shell-tabs';
      var label = document.createElement('span');
      label.className = 'shell-ws-label';
      var crumb = document.createElement('span');
      crumb.className = 'crumb';
      crumb.textContent = 'ws ›';
      label.appendChild(crumb);
      label.appendChild(document.createTextNode(model.workspace.ref));
      tabsRow.appendChild(label);
      model.workspace.tabs.forEach(function (t) { tabsRow.appendChild(rowLink(t)); });
      nav.appendChild(tabsRow);
    }
    return model;
  }

  /* parseWorkspacePath(pathname) → { ref, facet } | null.
   * The /ws/<ref>/<facet> reader the workspace-shell catch-all page uses to
   * learn which facet of which workspace it is rendering. Unknown facet falls
   * back to 'board' (the default facet). Returns null for non-/ws/ paths. */
  function parseWorkspacePath(pathname) {
    var p = String(pathname || '');
    var m = p.match(/^\/ws\/([^/]+)(?:\/([^/]+))?\/?$/);
    if (!m) return null;
    var ref;
    try { ref = decodeURIComponent(m[1]); } catch (e) { ref = m[1]; }
    var facet = m[2] || 'board';
    var known = FACETS.some(function (f) { return f.key === facet; });
    return { ref: ref, facet: known ? facet : 'board' };
  }

  return {
    deriveNav: deriveNav,
    mount: mount,
    parseWorkspacePath: parseWorkspacePath,
    GLOBAL: GLOBAL,
    FACETS: FACETS
  };
});
