/* beads-runner/web/board/app.js — T6a (claude-tools-p2m).
 *
 * The browser glue ONLY: fetch the §4.5 projection from the same-origin
 * /api/board read proxy (the §9.1 chokepoint — the client bears NO secret and
 * never picks the principal/op), hand it to the pure board-view.js, paint the
 * DOM. Auto-refresh on a fixed cadence so liveness stays honest (a stale
 * runner must surface — §4.2/S-1).
 *
 * NO WRITE PATH (EXIT crit 3): the ONLY network call in the whole client is a
 * credential-less GET of the read proxy. There is no form, no POST, no
 * mutation affordance. The WAITING-ON-YOU lane is a deep-link pointer into
 * T6b's Inbox — this app NEVER renders the dossier body (anti-drift: that is
 * T6b). All honest-state / S-1 rendering decisions live in board-view.js;
 * this file only writes the derived strings into elements.
 */
(function () {
  'use strict';

  var REFRESH_MS = 30000; // re-poll so a runner going stale surfaces (§4.2/S-1)
  var BoardView = window.BoardView;

  var el = {
    loading: document.getElementById('loading'),
    board: document.getElementById('board'),
    errbox: document.getElementById('errbox'),
    errB: document.getElementById('err-b'),
    who: document.getElementById('who'),
    healthDot: document.getElementById('health-dot'),
    healthHb: document.getElementById('health-hb'),
    healthHeadline: document.getElementById('health-headline'),
    healthTags: document.getElementById('health-tags'),
    strip: document.getElementById('strip'),
    woy: document.getElementById('woy'),
    woyEmpty: document.getElementById('woy-empty'),
    woyCount: document.getElementById('woy-count'),
    cols: document.getElementById('cols'),
    runners: document.getElementById('runners'),
    footUpdated: document.getElementById('foot-updated')
  };

  function clear(node) { while (node.firstChild) node.removeChild(node.firstChild); }
  function mk(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }

  function showError(msg) {
    el.loading.hidden = true;
    el.board.hidden = true;
    el.errbox.hidden = false;
    el.errB.textContent = msg;
    el.healthDot.classList.add('bad');
  }

  function renderHealth(h) {
    el.healthHeadline.textContent = h.headline;
    el.healthHb.textContent = h.ok ? 'ALL NOMINAL' : 'NEEDS ATTENTION';
    el.healthHb.classList.toggle('bad', !h.ok);
    el.strip.classList.toggle('bad', !h.ok);
    el.healthDot.classList.toggle('bad', !h.ok);
    clear(el.healthTags);
    h.tags.forEach(function (t) {
      el.healthTags.appendChild(mk('span', 'tg ' + t.kind, t.text));
    });
  }

  function renderWaiting(list) {
    clear(el.woy);
    el.woyCount.textContent = String(list.length);
    el.woyEmpty.hidden = list.length !== 0;
    list.forEach(function (w) {
      // A POINTER into T6b's Inbox — the dossier body is NOT rendered here.
      var card = mk(w.inbox_href ? 'a' : 'div', 'waitcard');
      if (w.inbox_href) card.setAttribute('href', w.inbox_href);
      var meta = mk('div', 'meta');
      meta.appendChild(mk('span', 'p', w.tier || 'decide'));
      meta.appendChild(mk('span', null, w.bead_ref || '(bead)'));
      card.appendChild(meta);
      card.appendChild(mk('div', 'ask', w.label));
      card.appendChild(mk('div', 'go', 'OPEN IN INBOX →'));
      el.woy.appendChild(card);
    });
  }

  function renderLifecycle(cols, gatedStages) {
    clear(el.cols);
    cols.forEach(function (col) {
      // A column is a "gate" (amber) when a bead in it is in WAITING-ON-YOU —
      // a presentation link between two projection facts, not derived state.
      var c = mk('div', 'col' + (gatedStages[col.stage] ? ' gate' : ''));
      var head = mk('div', 'col-h');
      head.appendChild(mk('span', null, col.label));
      head.appendChild(mk('span', 'c', String(col.count)));
      c.appendChild(head);
      if (col.cards.length === 0) {
        c.appendChild(mk('div', 'col-empty', '—'));
      }
      col.cards.forEach(function (card) {
        var b = mk('div', 'bead' + (card.failure ? ' failbead' : ''));
        b.appendChild(mk('div', 'bt', card.title));
        var bf = mk('div', 'bf');
        bf.appendChild(mk('span', null,
          (card.priority != null ? 'P' + card.priority : '·') +
          (card.age ? ' · ' + card.age : '')));
        if (card.waiting_on) bf.appendChild(mk('span', 'wo', card.waiting_on));
        b.appendChild(bf);
        if (card.failure) b.appendChild(mk('div', 'warn', card.failure.badge));
        c.appendChild(b);
      });
      el.cols.appendChild(c);
    });
  }

  function renderRunners(runners) {
    clear(el.runners);
    if (runners.length === 0) {
      el.runners.appendChild(mk('div', 'col-empty', 'No runners reported.'));
      return;
    }
    runners.forEach(function (r) {
      var box = mk('div', 'runner' + (r.liveness === 'stale' ? ' stale' : ''));
      box.appendChild(mk('div', 'rp', r.project_ref));
      var st = mk('div', 'rstate');
      st.appendChild(mk('span', 'pill ' + r.state_class));
      st.appendChild(mk('span', null, r.state_label));
      box.appendChild(st);
      // S-1: the last-reported actual of a stale runner is muted CONTEXT,
      // never promoted to a live state (board-view.js guarantees this).
      if (r.actual_note) box.appendChild(mk('div', 'rnote', r.actual_note));
      var cap = mk('div', 'rcap' + (r.capacity_verdict === 'over' ? ' over' : ''),
        'capacity: ' + r.capacity_verdict);
      box.appendChild(cap);
      el.runners.appendChild(box);
    });
  }

  function render(view) {
    if (!view.ok) { showError(view.error); return; }
    el.loading.hidden = true;
    el.errbox.hidden = true;
    el.board.hidden = false;
    el.who.textContent = view.principal;
    renderHealth(view.health);
    renderWaiting(view.waiting_on_you);
    // Map WAITING-ON-YOU bead_refs → their stage column so the column reads
    // as a gate (presentation linkage of two projection facts; no new state).
    var waitingBeads = {};
    view.waiting_on_you.forEach(function (w) {
      if (w.bead_ref) waitingBeads[w.bead_ref] = true;
    });
    var gatedStages = {};
    view.lifecycle.forEach(function (col) {
      col.cards.forEach(function (card) {
        if (waitingBeads[card.bead_ref]) gatedStages[col.stage] = true;
      });
    });
    renderLifecycle(view.lifecycle, gatedStages);
    renderRunners(view.runners);
    el.footUpdated.textContent = 'updated ' +
      new Date().toLocaleTimeString();
  }

  function refresh() {
    // The ONE network call: a credential-less, same-origin, read-only GET.
    fetch('/api/board', { method: 'GET', headers: { accept: 'application/json' } })
      .then(function (resp) {
        return resp.text().then(function (body) {
          var data;
          try { data = JSON.parse(body); }
          catch (e) {
            throw new Error('projection was not JSON (HTTP ' + resp.status + ')');
          }
          // The proxy's own honest error envelope ({ok:false,error}) — surface
          // it verbatim (covers 502/503: Coordinator unreachable / unconfigured).
          if (data && data.ok === false && data.error) {
            throw new Error(data.error);
          }
          // A non-object body (null/scalar) or a non-envelope HTTP failure must
          // surface the HTTP status honestly, NOT be misreported downstream as
          // a schema error (principle 4 — never mask the real failure).
          if (!resp.ok || data === null || typeof data !== 'object') {
            throw new Error('Board read proxy returned HTTP ' + resp.status +
              ' with no usable projection body');
          }
          return data;
        });
      })
      .then(function (snapshot) {
        render(BoardView.deriveBoardView(snapshot));
      })
      .catch(function (e) {
        showError(e && e.message ? e.message : String(e));
      });
  }

  refresh();
  setInterval(refresh, REFRESH_MS);
})();
