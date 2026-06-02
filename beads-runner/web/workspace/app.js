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
  var ActivityView = window.ActivityView; // I3 (claude-tools-uxvi3)

  // Which track ships each STILL-placeholder facet (honest placeholder copy).
  // 'activity' graduated to live content in I3, so it is NOT listed here.
  var FACET_TRACK = { blueprint: 'H3', gates: 'J3' };

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
  } else if (ctx.facet === 'activity') {
    mountActivityFacet();
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

  // ── activity facet (I3 — writer lane + aux pool + liveness dots) ─────────────
  // REUSES window.ActivityView.deriveActivityView (the pure view-model). Builds
  // the static scaffold ONCE; refresh repaints the dynamic regions in place so a
  // runner/agent going stale surfaces (30s, same cadence as the board facet).
  // I4 (claude-tools-uxvi4) adds the WRITE path: a maybe-stuck writer exposes the
  // four tappable stuck actions (Nudge / Escalate / Kill+retry / Kill+Gate),
  // which route through the control plane (an agent-action intent the daemon
  // reconciles, or a dossier write) — never a direct web→process kill.
  function mountActivityFacet() {
    Dom.clear(host);
    var wrap = Dom.mk('div', 'af-wrap');

    var loading = Dom.mk('p', 'af-loading', 'Reading the projection…');
    loading.id = 'af-loading';
    wrap.appendChild(loading);

    var errbox = Dom.mk('section', 'af-errbox');
    errbox.id = 'af-errbox';
    errbox.hidden = true;
    errbox.appendChild(Dom.mk('div', 'af-err-h', 'Cannot render this workspace'));
    var errB = Dom.mk('p', 'af-err-b');
    errB.id = 'af-err-b';
    errbox.appendChild(errB);
    wrap.appendChild(errbox);

    var body = Dom.mk('section', 'af-body');
    body.id = 'af-body';
    body.hidden = true;

    // RUNNER HEALTH — the loop PROCESS, drawn DISTINCT from agent activity (§5.4).
    var rhSec = Dom.mk('div', 'af-sec');
    rhSec.appendChild(Dom.mk('div', 'af-sl', 'RUNNER HEALTH · the loop process (§5.4)'));
    var rhHost = Dom.mk('div', 'af-rh-host');
    rhHost.id = 'af-rh-host';
    rhSec.appendChild(rhHost);
    body.appendChild(rhSec);

    // WRITER LANE — exactly one (serial), by construction.
    var wSec = Dom.mk('div', 'af-sec');
    wSec.appendChild(Dom.mk('div', 'af-sl', 'WRITER LANE · serial — exactly one'));
    var wHost = Dom.mk('div', 'af-writer-host');
    wHost.id = 'af-writer-host';
    wSec.appendChild(wHost);
    body.appendChild(wSec);

    // AUXILIARY POOL — 0..N read-only / non-code agents, parallel with the writer.
    var aSec = Dom.mk('div', 'af-sec');
    var aHead = Dom.mk('div', 'af-sl');
    aHead.id = 'af-aux-sl';
    aHead.textContent = 'AUXILIARY POOL · parallel — read-only or non-code';
    aSec.appendChild(aHead);
    var aHost = Dom.mk('div', 'af-aux-host');
    aHost.id = 'af-aux-host';
    aSec.appendChild(aHost);
    body.appendChild(aSec);

    // Honest "degraded" footnotes (B.4) — every dropped/placeholder field is named.
    var degSec = Dom.mk('div', 'af-degraded');
    degSec.id = 'af-degraded';
    degSec.hidden = true;
    body.appendChild(degSec);

    // Foot: link to the board facet + a quiet updated stamp.
    var foot = Dom.mk('div', 'af-foot');
    var boardLink = Dom.mk('a', 'facet-link', 'Open this workspace’s board →');
    boardLink.setAttribute('href', '/ws/' + encodeURIComponent(ctx.ref) + '/board');
    foot.appendChild(boardLink);
    var updated = Dom.mk('span', 'af-updated', '—');
    updated.id = 'af-updated';
    foot.appendChild(updated);
    body.appendChild(foot);

    wrap.appendChild(body);
    host.appendChild(wrap);

    refreshActivity();
    window.setInterval(refreshActivity, REFRESH_MS);
  }

  function showActivityError(msg) {
    var loading = Dom.el('af-loading');
    var body = Dom.el('af-body');
    var errbox = Dom.el('af-errbox');
    if (loading) loading.hidden = true;
    if (body) body.hidden = true;
    if (errbox) { errbox.hidden = false; Dom.el('af-err-b').textContent = msg; }
    if (healthDot) healthDot.classList.add('bad');
  }

  function refreshActivity() {
    Net.getJSON('/api/board')
      .then(function (snapshot) {
        var view = ActivityView.deriveActivityView(snapshot, ctx.ref, Date.now());
        renderActivity(view);
      })
      .catch(function (e) {
        showActivityError(e && e.message ? e.message : String(e));
      });
  }

  function renderActivity(view) {
    // The one hard refusal (unknown-HIGHER schema_version) surfaces as an error.
    if (!view.ok) { showActivityError(view.error); return; }

    var loading = Dom.el('af-loading');
    var errbox = Dom.el('af-errbox');
    var body = Dom.el('af-body');
    if (loading) loading.hidden = true;
    if (errbox) errbox.hidden = true;
    if (body) body.hidden = false;

    // The coarse header pip lights ONLY on the contract's named alarm states
    // (UX-DESIGN-V2 §5.3/§5.4, DESIGN I §4): a WEDGED runner OR a MAYBE-STUCK
    // writer. A deliberately-stopped runner reports process:'dead' + state:'idle'
    // (intentional/terminal down, never "stuck" — DESIGN I §3), so it stays
    // NEUTRAL — we never read a clean stop as trouble. (The producer collapses
    // stopped+crashed into 'dead', so we key on the named alarm, not 'dead'.)
    if (healthDot) {
      var rh = view.runner_health || {};
      var w = view.writer;
      var alarm = rh.state === 'wedged' || (w && w.state === 'maybe-stuck');
      if (alarm) healthDot.classList.add('bad');
      else healthDot.classList.remove('bad');
    }

    renderRunnerHealth(view.runner_health);
    renderWriter(view.writer);
    renderAux(view.auxiliary, view.found);
    renderDegraded(view.degraded);

    var updated = Dom.el('af-updated');
    if (updated) updated.textContent = 'updated ' + new Date().toLocaleTimeString();
  }

  // RUNNER-HEALTH PIP — a labeled CHIP (square indicator), deliberately a
  // different visual register from the round agent liveness dots (§5.4 distinct).
  function renderRunnerHealth(rh) {
    var hostEl = Dom.el('af-rh-host');
    Dom.clear(hostEl);
    rh = rh || {};
    var chip = Dom.mk('div', 'af-rh ' + (rh.state_class || 'rh-unknown'));
    chip.appendChild(Dom.mk('span', 'af-rh-pip'));
    chip.appendChild(Dom.mk('span', 'af-rh-state', rh.state_label || 'unknown'));
    var meta = Dom.mk('span', 'af-rh-meta',
      'process ' + (rh.process || 'unknown') + ' · heartbeat ' + (rh.heartbeat || 'unknown'));
    chip.appendChild(meta);
    hostEl.appendChild(chip);
  }

  // Build the round liveness dot + the derived state line shared by both lanes.
  // The dot color is green/amber/red (consumed verbatim); 'unknown' reads neutral.
  function buildStateLine(agent) {
    var line = Dom.mk('div', 'af-state');
    line.appendChild(Dom.mk('span', 'af-dot dot-' + (agent.liveness_dot || 'unknown')));
    if (agent.icon) line.appendChild(Dom.mk('span', 'af-icon', agent.icon));
    line.appendChild(Dom.mk('span', 'af-state-label', agent.state_label));
    // state_confidence is ALWAYS "derived" — show it so the card never asserts.
    line.appendChild(Dom.mk('span', 'af-conf', agent.state_confidence || 'derived'));
    return line;
  }

  // WRITER LANE — one card, or an honest "no writer" empty state.
  function renderWriter(writer) {
    var hostEl = Dom.el('af-writer-host');
    Dom.clear(hostEl);
    if (!writer) {
      hostEl.appendChild(Dom.mk('div', 'af-empty',
        'No writer active in ' + ctx.ref + ' right now.'));
      return;
    }
    var card = Dom.mk('div', 'af-card af-writer');
    // Identity row: bead_ref + title + stage (each honest-absent if missing).
    var idr = Dom.mk('div', 'af-id');
    if (writer.bead_ref) idr.appendChild(Dom.mk('code', 'af-ref', writer.bead_ref));
    if (writer.title) {
      var t = writer.title;
      if (t.length > 72) t = t.slice(0, 72) + '…';
      idr.appendChild(Dom.mk('span', 'af-title', t));
    }
    if (writer.stage) idr.appendChild(Dom.mk('span', 'af-stage', writer.stage));
    if (!writer.bead_ref && !writer.title) {
      idr.appendChild(Dom.mk('span', 'af-title af-faint', '(no bead reported)'));
    }
    card.appendChild(idr);
    card.appendChild(buildStateLine(writer));
    // Meta row: time-in-state + touching domains (Blueprint overlay hint, §1.5).
    var metaBits = [];
    if (writer.duration_label) metaBits.push(writer.duration_label + ' in state');
    if (writer.touching && writer.touching.length) {
      metaBits.push('touching: ' + writer.touching.join(' ▸ '));
    }
    if (metaBits.length) card.appendChild(Dom.mk('div', 'af-meta', metaBits.join(' · ')));
    // I4 (claude-tools-uxvi4): a maybe-stuck writer exposes the four tappable
    // stuck actions (DESIGN I §4). They route through the control plane (an
    // agent-action INTENT the daemon reconciles, or a dossier write) — NEVER a
    // direct web→process kill (Local==remote). Shown only when there's a bead to
    // target and the writer is flagged maybe-stuck.
    if (writer.state === 'maybe-stuck' && writer.bead_ref) {
      card.appendChild(renderStuckActions(writer));
    }
    hostEl.appendChild(card);
  }

  // ── I4 stuck actions (Nudge / Escalate / Kill+retry / Kill+Gate) ────────────
  // Each writes through a same-origin control proxy (bearer server-side); the
  // host effect is the daemon's job. Optimistic status line; destructive kills
  // are confirm()-gated. The buttons disable while a request is in flight.
  var FAR_FUTURE = '2999-01-01'; // "indefinite until lifted" defer sentinel (gate-defer needs a date)

  function renderStuckActions(writer) {
    var box = Dom.mk('div', 'af-actions');
    box.appendChild(Dom.mk('div', 'af-actions-h',
      'Looks stuck — act (routes through the control plane, not a direct kill):'));
    var row = Dom.mk('div', 'af-actions-row');
    var status = Dom.mk('div', 'af-actions-status');
    status.setAttribute('aria-live', 'polite');

    function btn(label, cls, handler) {
      var b = Dom.mk('button', 'af-act ' + cls, label);
      b.setAttribute('type', 'button');
      b.addEventListener('click', function () { handler(b, status); });
      row.appendChild(b);
      return b;
    }

    btn('Nudge', 'af-act-nudge', function (b, st) {
      runAction(b, st, 'nudge',
        Net.postJSON('/api/control/agent-action', agentActionBody('nudge', writer)));
    });
    btn('Escalate →', 'af-act-escalate', function (b, st) {
      runAction(b, st, 'escalate',
        Net.postJSON('/api/control/escalate', {
          bead_ref: writer.bead_ref, project_ref: ctx.ref, title: writer.title || ''
        }));
    });
    btn('Kill + retry', 'af-act-kill', function (b, st) {
      if (!window.confirm('Kill the worker on ' + writer.bead_ref +
        ' and re-dispatch a fresh one on the same bead?\n\n(In-flight work is lost; the bead is intact.)')) return;
      runAction(b, st, 'kill+retry',
        Net.postJSON('/api/control/agent-action', agentActionBody('kill-retry', writer)));
    });
    btn('Kill + Gate', 'af-act-gate', function (b, st) {
      var why = window.prompt('Kill + Gate — why is ' + writer.bead_ref +
        ' being held? (stops re-dispatch until the gate is lifted)', 'stuck — needs investigation');
      if (why === null) return; // cancelled
      // Disable the row SYNCHRONOUSLY (before the pre-flight gate-meta POST) so a
      // double-click can't enqueue two kill-gate actions while gate-meta is in
      // flight; runAction re-enables on completion.
      setRowDisabled(b, true);
      var gateId = mkGateId(writer.bead_ref);
      // Two writes (design/agent-action.md §3): the why/scope annotation is a
      // direct engine write (gate-meta-set, best-effort); the label+kill is the
      // agent-action the daemon reconciles. The kill-gate is the load-bearing one
      // — the metadata is annotation, so we proceed even if it fails.
      Net.postJSON('/api/ws/gate-meta', { gate: { id: gateId, why: why || 'stuck', scope: 'task' } })
        .catch(function () { /* annotation is best-effort; the gate still applies */ })
        .then(function () {
          var body = agentActionBody('kill-gate', writer);
          body.target.gate_id = gateId;
          body.args.date = FAR_FUTURE;
          return runAction(b, st, 'kill+gate',
            Net.postJSON('/api/control/agent-action', body));
        });
    });

    box.appendChild(row);
    box.appendChild(status);
    return box;
  }

  function agentActionBody(intent, writer) {
    return {
      intent: intent,
      workspace: ctx.ref,
      target: { bead_ref: writer.bead_ref },
      args: { reason: 'from the Activity view' }
    };
  }

  // gate:<id> shape is ^[a-z0-9][a-z0-9-]*$ (gate-defer.sh / gate-meta gate-id).
  function mkGateId(beadRef) {
    var id = ('stuck-' + beadRef).toLowerCase()
      .replace(/[^a-z0-9-]+/g, '-')
      .replace(/^[^a-z0-9]+/, '')
      .replace(/-+$/, '');
    return id || 'stuck';
  }

  // Enable/disable every button in the action row a button belongs to.
  function setRowDisabled(btnEl, disabled) {
    var rowEl = btnEl ? btnEl.parentNode : null;
    var btns = rowEl ? rowEl.querySelectorAll('button') : [];
    for (var i = 0; i < btns.length; i++) btns[i].disabled = !!disabled;
  }

  // Disable the bar's buttons, show an optimistic status, then ✓/✗ the outcome.
  // Idempotent on the disable (Kill+Gate disables synchronously up-front).
  function runAction(btnEl, statusEl, verb, promise) {
    setRowDisabled(btnEl, true);
    statusEl.className = 'af-actions-status pending';
    statusEl.textContent = verb + ' — sending…';
    return promise.then(function (d) {
      statusEl.className = 'af-actions-status ok';
      var idNote = (d && d.action_id) ? (' (queued; the daemon reconciles within ~30s)')
        : (d && d.id) ? (' (decision card created — see the Inbox)') : '';
      statusEl.textContent = '✓ ' + verb + ' accepted' + idNote;
    }).catch(function (e) {
      statusEl.className = 'af-actions-status err';
      statusEl.textContent = '✗ ' + verb + ' failed: ' + (e && e.message ? e.message : String(e));
    }).then(function () {
      setRowDisabled(btnEl, false);
    });
  }

  // AUXILIARY POOL — 0..N cards (kind + label + derived state + dot). Honest
  // empty state distinguishes "found the workspace, no aux" from "no workspace".
  function renderAux(aux, found) {
    var hostEl = Dom.el('af-aux-host');
    var sl = Dom.el('af-aux-sl');
    Dom.clear(hostEl);
    aux = aux || [];
    if (sl) {
      sl.textContent = 'AUXILIARY POOL · parallel — read-only or non-code' +
        (aux.length ? ' · ' + aux.length : '');
    }
    if (aux.length === 0) {
      hostEl.appendChild(Dom.mk('div', 'af-empty',
        found ? 'No auxiliary agents running.'
              : 'No runner reported for ' + ctx.ref + '.'));
      return;
    }
    aux.forEach(function (a) {
      var card = Dom.mk('div', 'af-card af-aux');
      var idr = Dom.mk('div', 'af-id');
      if (a.kind) idr.appendChild(Dom.mk('span', 'af-kind', a.kind));
      if (a.label && a.label !== a.kind) idr.appendChild(Dom.mk('span', 'af-title', a.label));
      card.appendChild(idr);
      card.appendChild(buildStateLine(a));
      hostEl.appendChild(card);
    });
  }

  // Honest degraded[] footnotes (B.4): name every placeholder/dropped field.
  function renderDegraded(degraded) {
    var sec = Dom.el('af-degraded');
    if (!sec) return;
    Dom.clear(sec);
    degraded = Array.isArray(degraded) ? degraded : [];
    if (degraded.length === 0) { sec.hidden = true; return; }
    sec.hidden = false;
    sec.appendChild(Dom.mk('div', 'af-degraded-h', 'Degraded (honest gaps)'));
    var ul = Dom.mk('ul', 'af-degraded-list');
    degraded.forEach(function (d) { ul.appendChild(Dom.mk('li', null, d)); });
    sec.appendChild(ul);
  }
})();
