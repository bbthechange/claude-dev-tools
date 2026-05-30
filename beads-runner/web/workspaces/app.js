/* beads-runner/web/workspaces/app.js — Workspaces Hub (label: workspaces-hub).
 *
 * THE THIN BROWSER GLUE ONLY. All honest-state / S-1 / derived-tally decisions
 * live in the pure workspaces-view.js; this file only:
 *   • Net.getJSON('/api/board') — the same credential-less, same-origin §4.5
 *     projection read the Board uses (the client bears NO secret, never picks
 *     the principal or op — §9.1/§9.2).
 *   • hands the parsed snapshot to deriveWorkspacesView(snap, <browser-now-ms>)
 *   • paints the cards via the shared Dom helpers (textContent — never innerHTML)
 *   • Shell.mount({active:'workspaces'}) — the persistent nav (Contract C.2)
 *   • a 30s auto-refresh (REFRESH_MS) so a workspace going stale surfaces (§4.2)
 *
 * NO rendering business logic that belongs in the view-model lives here, and
 * there is NO write path — the hub is read-only; each card is an <a> into that
 * workspace's Board. The Inbox is still the product, so decisions_total is
 * surfaced prominently at the top.
 */
(function () {
  'use strict';

  var REFRESH_MS = 30000; // re-poll so a workspace going stale surfaces (§4.2/S-1)
  var WV = window.WorkspacesView;
  var Net = window.Net;
  var Dom = window.Dom;

  var el = {
    loading: Dom.el('loading'),
    hub: Dom.el('hub'),
    errbox: Dom.el('errbox'),
    errB: Dom.el('err-b'),
    who: Dom.el('who'),
    headDot: Dom.el('head-dot'),
    decTotal: Dom.el('dec-total'),
    decLabel: Dom.el('dec-label'),
    decLink: Dom.el('dec-link'),
    cards: Dom.el('cards'),
    cardsEmpty: Dom.el('cards-empty'),
    footUpdated: Dom.el('foot-updated')
  };

  function showError(msg) {
    el.loading.hidden = true;
    el.hub.hidden = true;
    el.errbox.hidden = false;
    el.errB.textContent = msg;
    el.headDot.classList.add('bad');
  }

  // The DERIVED-FROM-BOARD lifecycle tally on a card. Honest by label: the
  // view-model flags stage_counts `derived:true`, so we render an explicit
  // "derived from board" caption — it is NOT an authoritative per-project
  // projection (Q1's queue_health supersedes it later).
  function renderStageStrip(card) {
    var wrap = Dom.mk('div', 'ws-stages');
    var lbl = Dom.mk('div', 'ws-stages-lbl', 'lifecycle · derived from board');
    wrap.appendChild(lbl);
    if (!card.stage_total) {
      wrap.appendChild(Dom.mk('div', 'ws-stages-empty', 'no beads attributed by ref-prefix'));
      return wrap;
    }
    var row = Dom.mk('div', 'ws-stage-row');
    WV.STAGE_ORDER.forEach(function (stage) {
      var n = card.stage_counts[stage] || 0;
      if (!n) return; // only surface non-empty stages, to keep the strip skimmable
      var chip = Dom.mk('span', 'ws-stage');
      chip.appendChild(Dom.mk('span', 'ws-stage-name', stage === '' ? 'unstaged' : stage));
      chip.appendChild(Dom.mk('span', 'ws-stage-n', String(n)));
      row.appendChild(chip);
    });
    wrap.appendChild(row);
    return wrap;
  }

  function renderCard(card) {
    // Each card is a link into that workspace's Board (the hub is the anchor —
    // no scavenger hunt; UX-DESIGN-V2 §2).
    var a = Dom.mk('a', 'ws-card health-' + card.health);
    a.setAttribute('href', card.href);

    var head = Dom.mk('div', 'ws-head');
    var idwrap = Dom.mk('div', 'ws-id');
    idwrap.appendChild(Dom.mk('span', 'ws-dot ' + card.health));
    idwrap.appendChild(Dom.mk('span', 'ws-ref', card.project_ref));
    head.appendChild(idwrap);
    // A decisions badge on the card when this workspace has open Inbox items.
    if (card.decisions > 0) {
      var db = Dom.mk('span', 'ws-decisions',
        card.decisions + (card.decisions === 1 ? ' needs you' : ' need you'));
      head.appendChild(db);
    }
    a.appendChild(head);

    // The honest mode pill + state label (actual; target: desired; or stale).
    var state = Dom.mk('div', 'ws-state');
    state.appendChild(Dom.mk('span', 'ws-pill ' + card.health));
    state.appendChild(Dom.mk('span', 'ws-state-label', card.state_label));
    a.appendChild(state);

    // current_task — a LIVE runner's current_task_ref (+ optional title). The
    // view-model drops this for stale runners (S-1), so absence is honest.
    if (card.current_task) {
      var ct = Dom.mk('code', 'ws-current-task', card.current_task);
      if (card.current_task_title) {
        var t = card.current_task_title;
        if (t.length > 60) t = t.slice(0, 60) + '…';
        ct.appendChild(document.createTextNode(' — '));
        ct.appendChild(Dom.mk('span', 'ws-current-task-title', t));
      }
      a.appendChild(ct);
    } else if (card.is_stale) {
      a.appendChild(Dom.mk('div', 'ws-stale-note',
        'last seen ' + card.ago + ' ago — current task unknown'));
    }

    a.appendChild(renderStageStrip(card));
    a.appendChild(Dom.mk('div', 'ws-go', 'OPEN BOARD →'));
    return a;
  }

  function render(view) {
    if (!view.ok) { showError(view.error); return; }
    el.loading.hidden = true;
    el.errbox.hidden = true;
    el.hub.hidden = false;
    el.who.textContent = view.principal;

    // The Inbox is still the product: surface decisions_total prominently.
    var total = view.decisions_total || 0;
    el.decTotal.textContent = String(total);
    el.decLabel.textContent = total === 0
      ? 'Nothing waiting on you across all workspaces.'
      : (total === 1 ? 'decision waiting on you' : 'decisions waiting on you');
    el.decLink.hidden = total === 0;
    el.headDot.classList.toggle('bad',
      view.cards.some(function (c) { return c.health !== 'ok'; }));

    Dom.clear(el.cards);
    el.cardsEmpty.hidden = view.cards.length !== 0;
    view.cards.forEach(function (c) { el.cards.appendChild(renderCard(c)); });

    el.footUpdated.textContent = 'updated ' + new Date().toLocaleTimeString();
  }

  function refresh() {
    Net.getJSON('/api/board')
      .then(function (snapshot) {
        render(WV.deriveWorkspacesView(snapshot, Date.now()));
      })
      .catch(function (e) {
        showError(e && e.message ? e.message : String(e));
      });
  }

  // Persistent nav — the Workspaces hub is the active global anchor (Contract C.2).
  if (window.Shell) window.Shell.mount({ active: 'workspaces' });

  refresh();
  setInterval(refresh, REFRESH_MS);
})();
