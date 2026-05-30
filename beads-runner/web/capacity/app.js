/* beads-runner/web/capacity/app.js — C-shell CAPACITY global view glue
 * (unit label: capacity-view).
 *
 * The browser glue ONLY: read the §4.5 projection from the same-origin
 * /api/board read proxy via the shared Net.getJSON (the §9.1 chokepoint — the
 * client bears NO secret and never picks the principal/op), hand it to the
 * pure capacity-view.js, paint the DOM with the shared Dom helpers, mount the
 * persistent nav shell with the 'capacity' tab active, and auto-refresh on a
 * fixed cadence so the budget numbers and modes stay honest.
 *
 * NO rendering business logic lives here — every band/allowed/mode decision is
 * in capacity-view.js (so it is Node-testable). This file only writes derived
 * strings into elements and toggles honest loading/error/empty states.
 *
 * Honesty discipline (binding): an unknown-HIGHER schema_version surfaces the
 * view-model's "update the app" error verbatim; an empty machines[] surfaces
 * the explicit "no telemetry yet" banner (§3.C) — NEVER a phantom ok. A stale
 * runner is rendered as stale, never promoted to a live mode.
 */
(function () {
  'use strict';

  var REFRESH_MS = 30000; // re-poll so budget + liveness stay honest
  var Net = window.Net;
  var Dom = window.Dom;
  var Shell = window.Shell;
  var CapacityView = window.CapacityView;

  var el = {
    loading: Dom.el('loading'),
    view: Dom.el('cap'),
    errbox: Dom.el('errbox'),
    errB: Dom.el('err-b'),
    who: Dom.el('who'),
    headDot: Dom.el('head-dot'),
    machines: Dom.el('machines'),
    msEmpty: Dom.el('ms-empty'),
    modes: Dom.el('modes'),
    modesEmpty: Dom.el('modes-empty'),
    footUpdated: Dom.el('foot-updated')
  };

  function showError(msg) {
    el.loading.hidden = true;
    el.view.hidden = true;
    el.errbox.hidden = false;
    el.errB.textContent = msg;
    if (el.headDot) el.headDot.classList.add('bad');
  }

  /* renderMachines — the DEDICATED detailed capacity surface. One labeled card
   * per machines[] entry; empty ⇒ "no telemetry yet" banner (§3.C), the cards
   * region is NEVER silently void. Band/allowed/chips come from the view-model
   * field-by-field; CSS paints the bands. */
  function renderMachines(machines, empty) {
    Dom.clear(el.machines);
    el.msEmpty.hidden = !empty;
    if (empty) return;

    machines.forEach(function (m) {
      var cardCls = 'mcard';
      if (!m.fresh) cardCls += ' stale';
      if (m.gate_disabled) cardCls += ' gate-disabled';
      var card = Dom.mk('div', cardCls);

      // Header — runner_id + observed age + breadcrumb chips.
      var head = Dom.mk('div', 'mcard-h');
      head.appendChild(Dom.mk('span', 'mrid', m.runner_id));
      var chips = Dom.mk('span', 'mchips');
      if (m.stale_chip) chips.appendChild(Dom.mk('span', 'chip stale-chip', m.stale_chip));
      if (m.gate_disabled_chip) chips.appendChild(Dom.mk('span', 'chip gate-chip', m.gate_disabled_chip));
      if (m.keychain_chip) chips.appendChild(Dom.mk('span', 'chip warn-chip', m.keychain_chip));
      if (m.api_chip) chips.appendChild(Dom.mk('span', 'chip warn-chip', m.api_chip));
      if (m.partial_chip) chips.appendChild(Dom.mk('span', 'chip warn-chip', m.partial_chip));
      head.appendChild(chips);
      card.appendChild(head);

      // The three labeled metrics — the detail this dedicated surface exists
      // to show (vs. the Board's compact inline strip).
      var metrics = Dom.mk('div', 'metrics');
      function metric(label, text, band, sub) {
        var cell = Dom.mk('div', 'metric band-' + band);
        cell.appendChild(Dom.mk('div', 'm-lbl', label));
        cell.appendChild(Dom.mk('div', 'm-num', text));
        if (sub) cell.appendChild(Dom.mk('div', 'm-sub', sub));
        return cell;
      }
      metrics.appendChild(metric('5h window', m.pct_5h_text, m.pct_5h_band, 'quota used'));
      metrics.appendChild(metric('7d window', m.pct_7d_text, m.pct_7d_band, 'quota used'));
      metrics.appendChild(metric('spare ramp', m.ramp_text, m.ramp_band, 'today’s soft line'));
      card.appendChild(metrics);

      // Allowed cost classes + observed age — the gating answer.
      var foot = Dom.mk('div', 'mcard-f');
      var allowed = Dom.mk('span', 'm-allowed');
      allowed.appendChild(Dom.mk('span', 'm-allowed-lbl', 'allowed'));
      allowed.appendChild(Dom.mk('span', 'm-allowed-val', m.allowed_text));
      foot.appendChild(allowed);
      foot.appendChild(Dom.mk('span', 'm-obs', 'observed ' + m.age_text + ' ago'));
      card.appendChild(foot);

      el.machines.appendChild(card);
    });
  }

  /* renderModes — one row per project: honest actual mode + target on mismatch
   * + liveness. A stale runner reads "stale (last: …)" — never a live mode. */
  function renderModes(modes) {
    Dom.clear(el.modes);
    el.modesEmpty.hidden = modes.length !== 0;
    modes.forEach(function (md) {
      var row = Dom.mk('div', 'mode' +
        (md.liveness === 'stale' ? ' stale' : '') +
        (md.mismatch ? ' mismatch' : ''));
      row.appendChild(Dom.mk('div', 'mode-ref', md.project_ref));
      var right = Dom.mk('div', 'mode-state');
      // The mode pill — color keyed by liveness/mismatch (CSS). A live,
      // matching mode is mint; a mismatch is amber; a stale runner is muted.
      var pillCls = 'mode-pill';
      if (md.liveness === 'stale') pillCls += ' s-stale';
      else if (md.mismatch) pillCls += ' s-mismatch';
      else if (md.live_mode) pillCls += ' s-live';
      right.appendChild(Dom.mk('span', pillCls));
      right.appendChild(Dom.mk('span', 'mode-label', md.mode_label));
      row.appendChild(right);
      el.modes.appendChild(row);
    });
  }

  function render(view) {
    if (!view.ok) { showError(view.error); return; }
    el.loading.hidden = true;
    el.errbox.hidden = true;
    el.view.hidden = false;
    if (el.who) el.who.textContent = view.principal;
    if (el.headDot) el.headDot.classList.remove('bad');
    renderMachines(view.machines || [], view.machines_empty === true);
    renderModes(view.modes || []);
    el.footUpdated.textContent = 'updated ' + new Date().toLocaleTimeString();
  }

  function refresh() {
    // The READ network call: a credential-less, same-origin GET to /api/board
    // via the shared Net helper (it reads the body as text first and surfaces
    // the proxy's honest {ok:false,error} envelope verbatim — principle 4).
    Net.getJSON('/api/board')
      .then(function (snapshot) {
        render(CapacityView.deriveCapacityView(snapshot, Date.now()));
      })
      .catch(function (e) {
        showError(e && e.message ? e.message : String(e));
      });
  }

  // Mount the persistent nav shell with the Capacity tab active (Contract C.2).
  Shell.mount({ active: 'capacity' });

  refresh();
  setInterval(refresh, REFRESH_MS);
})();
