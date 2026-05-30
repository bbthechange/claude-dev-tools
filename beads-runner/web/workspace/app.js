/* beads-runner/web/workspace/app.js — C-shell (claude-tools-uxvsh).
 *
 * The browser glue for the WORKSPACE-CONTEXT SHELL. It learns which facet of
 * which workspace it is rendering from the URL (Shell.parseWorkspacePath), paints
 * the persistent nav (Shell.mount), and mounts the active facet into #facet-host.
 *
 * Facets:
 *   board                  — REUSES window.BoardView.deriveBoardView verbatim, then
 *                            renders a board SCOPED to ctx.ref: the scoped runner
 *                            state + the lifecycle cards attributable to ctx.ref,
 *                            plus a link to the full global /board. READ-ORIENTED:
 *                            there is NO set-desired control here (control stays on
 *                            the global /board — this facet never widens the write
 *                            path). 30s refresh.
 *   blueprint/activity/gates — HONEST placeholders naming the track that ships them
 *                            (H3/I3/J3). The documented plug-in point; this shell
 *                            does NOT build the facet content.
 *
 * Honesty discipline (the shared brief): nothing fabricated; a stale runner is
 * shown as stale (BoardView enforces S-1); an unknown-HIGHER schema_version is the
 * one hard refusal (BoardView returns ok:false and we surface it). All board
 * presentation decisions live in board-view.js; this file only writes derived
 * strings into elements via the shared Dom helpers and owns the 30s refresh. */
(function () {
  'use strict';

  var REFRESH_MS = 30000; // re-poll so a runner going stale surfaces (§4.2/S-1)
  var Net = window.Net;
  var Dom = window.Dom;
  var Shell = window.Shell;
  var BoardView = window.BoardView;

  // Which track ships each non-board facet (honest placeholder copy).
  var FACET_TRACK = { blueprint: 'H3', activity: 'I3', gates: 'J3' };

  var host = Dom.el('facet-host');
  var who = Dom.el('who');
  var healthDot = Dom.el('health-dot');

  var ctx = Shell.parseWorkspacePath(location.pathname);

  // No ref in the URL (someone hit /workspace/ directly) — honest "pick a
  // workspace" message, never a guessed/blank board. Still paint the global nav.
  if (!ctx) {
    Shell.mount({ active: 'workspaces' });
    who.textContent = 'no workspace';
    renderNoContext();
    return;
  }

  // Paint the persistent nav: global row (Workspaces highlighted because we're
  // inside a workspace context) + the facet tab strip with ctx.facet active.
  Shell.mount({ workspace: { ref: ctx.ref, facet: ctx.facet } });
  who.textContent = ctx.ref;

  if (ctx.facet === 'board') {
    mountBoardFacet();
  } else {
    mountPlaceholder(ctx.facet);
  }

  // ── no-context (bare /workspace/) ──────────────────────────────────────────
  function renderNoContext() {
    Dom.clear(host);
    var box = Dom.mk('div', 'facet-empty');
    box.appendChild(Dom.mk('div', 'facet-empty-h', 'Pick a workspace'));
    box.appendChild(Dom.mk('p', 'facet-empty-b',
      'This page renders a single workspace, but no workspace ref is in the URL ' +
      '(expected /ws/<ref>/<facet>).'));
    var link = Dom.mk('a', 'facet-link', 'Go to Workspaces →');
    link.setAttribute('href', '/workspaces');
    box.appendChild(link);
    host.appendChild(box);
  }

  // ── placeholder facets (blueprint / activity / gates) ───────────────────────
  function mountPlaceholder(facet) {
    Dom.clear(host);
    var track = FACET_TRACK[facet] || '?';
    var label = facet.charAt(0).toUpperCase() + facet.slice(1);
    var box = Dom.mk('div', 'facet-placeholder');
    box.appendChild(Dom.mk('div', 'facet-placeholder-h',
      label + ' for ' + ctx.ref));
    box.appendChild(Dom.mk('p', 'facet-placeholder-b',
      'ships with track ' + track));
    host.appendChild(box);
  }

  // ── board facet (REUSES window.BoardView, scoped to ctx.ref) ────────────────
  // Build the static board-facet scaffold ONCE; refresh repaints the dynamic
  // regions in place so the auto-refresh doesn't tear down the whole subtree.
  function mountBoardFacet() {
    Dom.clear(host);
    var wrap = Dom.mk('div', 'bf-wrap');

    var loading = Dom.mk('p', 'bf-loading', 'Reading the projection…');
    loading.id = 'bf-loading';
    wrap.appendChild(loading);

    var errbox = Dom.mk('section', 'bf-errbox');
    errbox.id = 'bf-errbox';
    errbox.hidden = true;
    errbox.appendChild(Dom.mk('div', 'bf-err-h', 'Cannot render this workspace'));
    var errB = Dom.mk('p', 'bf-err-b');
    errB.id = 'bf-err-b';
    errbox.appendChild(errB);
    wrap.appendChild(errbox);

    var body = Dom.mk('section', 'bf-body');
    body.id = 'bf-body';
    body.hidden = true;

    // RUNNER (scoped to this ref) — honest state, S-1 liveness.
    var runnerSec = Dom.mk('div', 'bf-sec');
    runnerSec.appendChild(Dom.mk('div', 'bf-sl', 'RUNNER · honest state (§4.2)'));
    var runnerHost = Dom.mk('div', 'bf-runner-host');
    runnerHost.id = 'bf-runner-host';
    runnerSec.appendChild(runnerHost);
    body.appendChild(runnerSec);

    // LIFECYCLE (cards attributable to this ref) — grouped by stage.
    var lcSec = Dom.mk('div', 'bf-sec');
    lcSec.appendChild(Dom.mk('div', 'bf-sl', 'LIFECYCLE · cards for ' + ctx.ref));
    var lcHost = Dom.mk('div', 'cols');
    lcHost.id = 'bf-cols';
    lcSec.appendChild(lcHost);
    var lcEmpty = Dom.mk('p', 'bf-empty',
      'No lifecycle cards attributable to ' + ctx.ref + ' yet.');
    lcEmpty.id = 'bf-lc-empty';
    lcEmpty.hidden = true;
    lcSec.appendChild(lcEmpty);
    body.appendChild(lcSec);

    // Link to the full global board (control + cross-workspace view lives there).
    var foot = Dom.mk('div', 'bf-foot');
    var globalLink = Dom.mk('a', 'facet-link', 'Open the full board →');
    globalLink.setAttribute('href', '/board');
    foot.appendChild(globalLink);
    var updated = Dom.mk('span', 'bf-updated', '—');
    updated.id = 'bf-updated';
    foot.appendChild(updated);
    body.appendChild(foot);

    wrap.appendChild(body);
    host.appendChild(wrap);

    refreshBoard();
    window.setInterval(refreshBoard, REFRESH_MS);
  }

  function showBoardError(msg) {
    var loading = Dom.el('bf-loading');
    var body = Dom.el('bf-body');
    var errbox = Dom.el('bf-errbox');
    if (loading) loading.hidden = true;
    if (body) body.hidden = true;
    if (errbox) { errbox.hidden = false; Dom.el('bf-err-b').textContent = msg; }
    if (healthDot) healthDot.classList.add('bad');
  }

  function refreshBoard() {
    Net.getJSON('/api/board')
      .then(function (snapshot) {
        var view = BoardView.deriveBoardView(snapshot, Date.now());
        renderBoard(view);
      })
      .catch(function (e) {
        showBoardError(e && e.message ? e.message : String(e));
      });
  }

  function renderBoard(view) {
    // The one hard refusal (unknown-HIGHER schema_version) surfaces as an error.
    if (!view.ok) { showBoardError(view.error); return; }

    var loading = Dom.el('bf-loading');
    var errbox = Dom.el('bf-errbox');
    var body = Dom.el('bf-body');
    if (loading) loading.hidden = true;
    if (errbox) errbox.hidden = true;
    if (body) body.hidden = false;
    if (healthDot) healthDot.classList.remove('bad');

    renderScopedRunners(view);
    renderScopedLifecycle(view);

    var updated = Dom.el('bf-updated');
    if (updated) updated.textContent = 'updated ' + new Date().toLocaleTimeString();
  }

  // Scoped runner state: only runners whose project_ref === ctx.ref. Honest
  // empty state when this ref has no runner. The view model already enforced
  // S-1 (a stale runner reads as stale, never promoted to a live state).
  function renderScopedRunners(view) {
    var runnerHost = Dom.el('bf-runner-host');
    Dom.clear(runnerHost);
    var runners = (view.runners || []).filter(function (r) {
      return r.project_ref === ctx.ref;
    });
    if (runners.length === 0) {
      runnerHost.appendChild(Dom.mk('div', 'bf-empty',
        'No runner reported for ' + ctx.ref + '.'));
      return;
    }
    runners.forEach(function (r) {
      var box = Dom.mk('div', 'runner' + (r.liveness === 'stale' ? ' stale' : ''));
      box.appendChild(Dom.mk('div', 'rp', r.project_ref));
      var st = Dom.mk('div', 'rstate');
      st.appendChild(Dom.mk('span', 'pill ' + r.state_class));
      st.appendChild(Dom.mk('span', null, r.state_label));
      box.appendChild(st);
      // A live runner's current task (ref + optional title). Dropped for stale
      // runners by the view model (S-1: their last task is honestly unknown).
      if (r.current_task) {
        var line = Dom.mk('code', 'workspace-current-task', r.current_task);
        if (r.current_task_title) {
          var t = r.current_task_title;
          if (t.length > 60) t = t.slice(0, 60) + '…';
          line.appendChild(document.createTextNode(' — '));
          line.appendChild(Dom.mk('span', 'workspace-current-task-title', t));
        }
        box.appendChild(line);
      }
      // Stale runner's last-reported actual is muted CONTEXT, never promoted.
      if (r.actual_note) box.appendChild(Dom.mk('div', 'rnote', r.actual_note));
      if (r.stale_controls_note) {
        box.appendChild(Dom.mk('div', 'rstale', r.stale_controls_note));
      }
      // NOTE: NO set-desired controls here — control stays on the global /board
      // (this facet is read-oriented; it never widens the write path).
      runnerHost.appendChild(box);
    });
  }

  // Scoped lifecycle: cards whose bead_ref starts with ctx.ref + '-', grouped by
  // the view model's FROZEN stage order. Only stages with at least one scoped
  // card render a column (the global board shows all eight; here we keep it tight).
  function renderScopedLifecycle(view) {
    var cols = Dom.el('bf-cols');
    var empty = Dom.el('bf-lc-empty');
    Dom.clear(cols);
    var prefix = ctx.ref + '-';
    var totalScoped = 0;
    (view.lifecycle || []).forEach(function (col) {
      var scopedCards = (col.cards || []).filter(function (c) {
        return typeof c.bead_ref === 'string' && c.bead_ref.indexOf(prefix) === 0;
      });
      if (scopedCards.length === 0) return;
      totalScoped += scopedCards.length;
      var c = Dom.mk('div', 'col');
      var head = Dom.mk('div', 'col-h');
      head.appendChild(Dom.mk('span', null, col.label));
      head.appendChild(Dom.mk('span', 'c', String(scopedCards.length)));
      c.appendChild(head);
      scopedCards.forEach(function (card) {
        var beadCls = 'bead';
        if (card.failure) {
          beadCls += ' failbead';
          if (card.failure.silent) beadCls += ' silent';
        }
        var b = Dom.mk('div', beadCls);
        b.appendChild(Dom.mk('div', 'bt', card.title));
        var bf = Dom.mk('div', 'bf');
        bf.appendChild(Dom.mk('span', null,
          (card.priority != null ? 'P' + card.priority : '·') +
          (card.age ? ' · ' + card.age : '')));
        if (card.waiting_on) bf.appendChild(Dom.mk('span', 'wo', card.waiting_on));
        if (card.runner) bf.appendChild(Dom.mk('span', 'rn', '⚙ ' + card.runner));
        b.appendChild(bf);
        // A failing card deep-links into the Inbox failure view (read-only pointer).
        if (card.failure) {
          var href = card.failure.failure_href;
          var badge = Dom.mk(href ? 'a' : 'div', 'warn', card.failure.badge);
          if (href) badge.setAttribute('href', href);
          b.appendChild(badge);
        }
        c.appendChild(b);
      });
      cols.appendChild(c);
    });
    empty.hidden = totalScoped !== 0;
  }
})();
