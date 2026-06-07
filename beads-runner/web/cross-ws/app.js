/* beads-runner/web/cross-ws/app.js — K5 (claude-tools-uxvk5) glue.
 *
 * The browser glue ONLY (Contract C.1): read the two §9.1-disciplined,
 * credential-less proxies the surface binds —
 *   • /api/cross-ws/relay        → relay-log-tail (B.3) {exchanges:[...]}
 *   • /api/ws/blueprint?project_ref=<ref> → blueprint-get (B.2), per workspace
 * — hand them to the pure cross-ws-view.js, feed the FEDERATED coupling record
 * to BlueprintView.deriveBlueprintView() (the H2 layout + edge IP, REUSED — the
 * Workspaces-hub deriveBlueprintThumb precedent), paint the coupling map + the
 * relay log with the shared Dom helpers, mount the persistent nav, and
 * auto-refresh so the log + coupling stay current.
 *
 * NO derivation business logic lives here — federation + relay reshaping are in
 * cross-ws-view.js (Node-tested); the H2 IP is in blueprint-view.js. This file
 * only fetches, calls the pure cores, and DRAWS view.nodes/view.edges as given
 * (the §3 shared render contract: world coords; edges UNDER boxes). The coupling
 * painter is a deliberately STATIC, fit-to-width SVG (the /cross-ws layout is
 * [free], DESIGN K §9) — a global overview, not the per-workspace pan/zoom
 * canvas; it reuses the H2 MODEL, not the workspace facet's interaction shell.
 */
(function () {
  'use strict';

  var REFRESH_MS = 30000; // re-poll so the relay log + coupling stay current
  var Net = window.Net;
  var Dom = window.Dom;
  var Shell = window.Shell;
  var CrossWsView = window.CrossWsView;
  var BlueprintView = window.BlueprintView; // H2 — the map model, reused
  var SVGNS = 'http://www.w3.org/2000/svg';
  var inFlight = false;   // no overlapping refresh fetches
  var loadedOnce = false; // first paint done — a later transient blip never tears it down

  var el = {
    loading: Dom.el('loading'),
    view: Dom.el('cw'),
    errbox: Dom.el('errbox'),
    errB: Dom.el('err-b'),
    who: Dom.el('who'),
    headDot: Dom.el('head-dot'),
    map: Dom.el('cw-map'),
    mapEmpty: Dom.el('map-empty'),
    mapDegraded: Dom.el('map-degraded'),
    relaySummary: Dom.el('relay-summary'),
    relay: Dom.el('relay'),
    relayEmpty: Dom.el('relay-empty'),
    relayDegraded: Dom.el('relay-degraded'),
    footUpdated: Dom.el('foot-updated')
  };

  function showError(msg) {
    el.loading.hidden = true;
    el.view.hidden = true;
    el.errbox.hidden = false;
    el.errB.textContent = msg;
    if (el.headDot) { el.headDot.classList.remove('pending'); el.headDot.classList.add('bad'); }
  }

  function svg(tag, attrs) {
    var n = document.createElementNS(SVGNS, tag);
    if (attrs) Object.keys(attrs).forEach(function (k) { n.setAttribute(k, attrs[k]); });
    return n;
  }

  /* edgeBorderPoint(rect, towardsX, towardsY) → the point on `rect`'s border
   * along the line from its center toward (towardsX,towardsY). Lets edges start/
   * end at box borders (arrowheads visible), not buried under the box centers —
   * the bplayout "EXISTENCE != LEGIBILITY" lesson applied to the coupling map. */
  function edgeBorderPoint(r, tx, ty) {
    var cx = r.x + r.w / 2, cy = r.y + r.h / 2;
    var dx = tx - cx, dy = ty - cy;
    if (dx === 0 && dy === 0) return { x: cx, y: cy };
    var hw = r.w / 2, hh = r.h / 2;
    var sx = dx === 0 ? Infinity : hw / Math.abs(dx);
    var sy = dy === 0 ? Infinity : hh / Math.abs(dy);
    var s = Math.min(sx, sy);
    return { x: cx + dx * s, y: cy + dy * s };
  }

  /* renderCoupling(view) — paint the federated coupling map from the H2 model
   * output. STATIC, fit-to-width SVG (one world coordinate system = the model's
   * layout px, via viewBox); edges drawn UNDER boxes (§3 layering). Only VISIBLE
   * top-level boxes show at macro (children are collapsed). Empty ⇒ the honest
   * "no coupling yet" banner — the map region is never silently void. */
  function renderCoupling(view) {
    Dom.clear(el.map);
    // The H2 model only hard-refuses an unknown-higher schema_version; our
    // federated record is always v1, so this is a defensive honesty branch.
    if (!view || view.ok === false) {
      el.mapEmpty.hidden = false;
      el.mapEmpty.textContent = (view && view.error) ? view.error : 'Coupling map unavailable.';
      return;
    }
    var vis = (view.nodes || []).filter(function (n) { return n.visible && n.layout; });
    if (vis.length === 0) {
      el.mapEmpty.hidden = false;
      el.mapEmpty.textContent =
        'No cross-workspace coupling yet — no relay exchanges have linked two workspaces.';
      return;
    }
    el.mapEmpty.hidden = true;

    var byId = Object.create(null);
    vis.forEach(function (n) { byId[n.id] = n; });

    // world bounds over visible boxes (+ pad) → the SVG viewBox.
    var pad = 28;
    var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    vis.forEach(function (n) {
      var l = n.layout;
      if (l.x < minX) minX = l.x;
      if (l.y < minY) minY = l.y;
      if (l.x + l.w > maxX) maxX = l.x + l.w;
      if (l.y + l.h > maxY) maxY = l.y + l.h;
    });
    var W = (maxX - minX) + pad * 2, H = (maxY - minY) + pad * 2;
    var s = svg('svg', {
      'class': 'cw-svg',
      viewBox: (minX - pad) + ' ' + (minY - pad) + ' ' + W + ' ' + H,
      preserveAspectRatio: 'xMidYMid meet',
      role: 'img',
      'aria-label': 'Cross-workspace coupling map'
    });
    // a single arrowhead marker, oriented along each edge.
    var defs = svg('defs');
    var marker = svg('marker', {
      id: 'cw-arrow', viewBox: '0 0 10 10', refX: '9', refY: '5',
      markerWidth: '7', markerHeight: '7', orient: 'auto-start-reverse'
    });
    marker.appendChild(svg('path', { d: 'M0,0 L10,5 L0,10 z', 'class': 'cw-arrow-head' }));
    defs.appendChild(marker);
    s.appendChild(defs);

    // EDGE LAYER (under) — draw the bundled coupling edges between visible boxes.
    var edgeLayer = svg('g', { 'class': 'cw-edge-layer' });
    (view.edges || []).forEach(function (e) {
      var a = byId[e.from], b = byId[e.to];
      if (!a || !b) return;                 // an endpoint resolved out of view
      var ca = { x: a.layout.x + a.layout.w / 2, y: a.layout.y + a.layout.h / 2 };
      var cb = { x: b.layout.x + b.layout.w / 2, y: b.layout.y + b.layout.h / 2 };
      var p1 = edgeBorderPoint(a.layout, cb.x, cb.y);
      var p2 = edgeBorderPoint(b.layout, ca.x, ca.y);
      var cls = 'cw-edge' + (e.kind === 'queue' ? ' cw-edge-async' : '');
      edgeLayer.appendChild(svg('line', {
        'class': cls, x1: p1.x, y1: p1.y, x2: p2.x, y2: p2.y,
        'marker-end': 'url(#cw-arrow)'
      }));
      if (e.count > 1) {
        var t = svg('text', {
          'class': 'cw-edge-label', x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2 - 4,
          'text-anchor': 'middle'
        });
        t.textContent = String(e.count);
        edgeLayer.appendChild(t);
      }
    });
    s.appendChild(edgeLayer);

    // BOX LAYER (over) — one box per visible workspace, with a drill-in count.
    var boxLayer = svg('g', { 'class': 'cw-box-layer' });
    vis.forEach(function (n) {
      var l = n.layout;
      var g = svg('g', { 'class': 'cw-node-g' });
      g.appendChild(svg('rect', {
        'class': 'cw-node', x: l.x, y: l.y, width: l.w, height: l.h, rx: 14, ry: 14
      }));
      var label = svg('text', { 'class': 'cw-node-label', x: l.x + 16, y: l.y + 30 });
      label.textContent = n.label || n.id;
      g.appendChild(label);
      var nChildren = Array.isArray(n.children) ? n.children.length : 0;
      var sub = svg('text', { 'class': 'cw-node-sub', x: l.x + 16, y: l.y + 52 });
      sub.textContent = nChildren > 0
        ? (nChildren + (nChildren === 1 ? ' domain' : ' domains'))
        : 'workspace';
      g.appendChild(sub);
      boxLayer.appendChild(g);
    });
    s.appendChild(boxLayer);

    el.map.appendChild(s);
  }

  /* renderMapDegraded — the federation's honest degraded[] notes (a workspace
   * with no usable slug, an unavailable/newer blueprint). Never hidden silently. */
  function renderMapDegraded(degraded) {
    if (!degraded || !degraded.length) { el.mapDegraded.hidden = true; el.mapDegraded.textContent = ''; return; }
    el.mapDegraded.hidden = false;
    el.mapDegraded.textContent = 'note: ' + degraded.join(' · ');
  }

  /* renderRelay — the auditable exchange list (relay-log-tail, B.3). resolved
   * shows the answer; escalated shows the decision pointer; B.4 tolerant. */
  function renderRelay(rv) {
    Dom.clear(el.relay);
    // proxy/engine error envelope — honest unavailable banner, never a fake log.
    if (rv.unavailable) {
      el.relayEmpty.hidden = false;
      el.relayEmpty.textContent = 'Relay log unavailable: ' + rv.error;
      el.relaySummary.textContent = '';
      renderRelayDegraded(rv.degraded);
      return;
    }
    var c = rv.counts || { total: 0, resolved: 0, escalated: 0 };
    el.relaySummary.textContent = c.total +
      (c.total === 1 ? ' exchange' : ' exchanges') +
      ' · ' + c.resolved + ' resolved · ' + c.escalated + ' escalated';

    el.relayEmpty.hidden = rv.exchanges.length !== 0;
    if (rv.exchanges.length === 0) {
      el.relayEmpty.textContent =
        'No cross-workspace exchanges yet — nothing has been relayed between workspaces.';
    }

    rv.exchanges.forEach(function (x) {
      var row = Dom.mk('div', 'rl-row' + (x.escalated ? ' escalated' : ''));
      var head = Dom.mk('div', 'rl-head');
      head.appendChild(Dom.mk('span', 'rl-pair', x.pair_label));
      var chipCls = 'rl-chip ' + (x.escalated ? 'escalated' : (x.resolved ? 'resolved' : 'unknown'));
      head.appendChild(Dom.mk('span', chipCls, x.outcome));
      head.appendChild(Dom.mk('span', 'rl-time', x.at_label));
      row.appendChild(head);
      row.appendChild(Dom.mk('div', 'rl-q', x.question));
      row.appendChild(Dom.mk('div', 'rl-a' + (x.escalated ? ' esc' : ''), x.body));
      el.relay.appendChild(row);
    });
    renderRelayDegraded(rv.degraded);
  }

  function renderRelayDegraded(degraded) {
    if (!degraded || !degraded.length) { el.relayDegraded.hidden = true; el.relayDegraded.textContent = ''; return; }
    el.relayDegraded.hidden = false;
    el.relayDegraded.textContent = 'note: ' + degraded.join(' · ');
  }

  function render(model, couplingView) {
    el.loading.hidden = true;
    el.errbox.hidden = true;
    el.view.hidden = false;
    if (el.headDot) { el.headDot.classList.remove('pending', 'bad'); }
    renderCoupling(couplingView);
    renderMapDegraded(model.coupling.degraded);
    renderRelay(model.relay);
    el.footUpdated.textContent = 'updated ' + new Date().toLocaleTimeString();
    loadedOnce = true; // a working surface has painted — refresh blips never tear it down
  }

  /* refresh — the read pipeline (A.3 sources only):
   *   1. relay-log-tail (B.3) — the workspaces + coupling come from here. A
   *      down proxy is DEGRADED, not fatal: Net.getJSON rejects on the proxy's
   *      {ok:false} (net.js throws), so we catch it back INTO the {ok:false}
   *      envelope deriveRelayView understands → the honest "unavailable" relay
   *      banner shows and the coupling area still renders (empty), rather than
   *      the whole page collapsing to the error box (the code-review fix).
   *   2. per-workspace blueprint-get (B.2) — best-effort enrichment (drill-in
   *      domains); a null/errored read just leaves a bare workspace box.
   *   3. federate → deriveBlueprintView (H2) → paint.  */
  function refresh() {
    if (inFlight) return; // never overlap a refresh tick with an outstanding read
    inFlight = true;
    Net.getJSON('/api/cross-ws/relay')
      .catch(function (e) {
        // a 502/503 {ok:false} from the proxy rejects in Net — fold it back into
        // the envelope the view-model degrades honestly (NOT a page-fatal throw).
        return { ok: false, error: (e && e.message) ? e.message : String(e) };
      })
      .then(function (relayTail) {
        var refs = CrossWsView.relayWorkspaceRefs(relayTail);
        // best-effort blueprint fetch per workspace — never fails the page.
        var fetches = refs.map(function (ref) {
          return Net.getJSON('/api/ws/blueprint?project_ref=' + encodeURIComponent(ref))
            .then(function (rec) { return { ref: ref, rec: rec }; })
            .catch(function (e) { return { ref: ref, rec: { ok: false, error: (e && e.message) || String(e) } }; });
        });
        return Promise.all(fetches).then(function (results) {
          var bps = {};
          results.forEach(function (r) { bps[r.ref] = r.rec; });
          var model = CrossWsView.deriveCrossWsView(relayTail, bps, Date.now());
          // REUSE H2: hand the federated record to the blueprint map model.
          var couplingView = BlueprintView.deriveBlueprintView(model.coupling.record, Date.now(), {});
          render(model, couplingView);
        });
      })
      .catch(function (e) {
        // last resort (an unexpected exception, not a proxy-down): only collapse
        // to the error box on the FIRST load — a working surface, once painted,
        // is never torn down by a transient refresh-tick blip.
        if (!loadedOnce) showError(e && e.message ? e.message : String(e));
      })
      .then(function () { inFlight = false; });
  }

  // Mount the persistent nav shell with the Cross-WS tab active (Contract C.2).
  Shell.mount({ active: 'cross-ws' });

  refresh();
  setInterval(refresh, REFRESH_MS);
})();
