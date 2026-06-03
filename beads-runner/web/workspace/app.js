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
 *   activity               — LIVE facet (I3): writer lane + aux pool + runner-health
 *                            pip (window.ActivityView), with the I4 stuck actions.
 *   gates                  — LIVE facet (J3): the unified Hold view (window.GatesView) —
 *                            gate editable; dependency/scheduled read-only.
 *   blueprint              — HONEST placeholder naming the track that ships it (H3).
 *                            The documented plug-in point; this shell does NOT build
 *                            the placeholder's facet content.
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
  var GatesView = window.GatesView; // J3 (claude-tools-uxvj3)
  var BlueprintView = window.BlueprintView; // H2 (claude-tools-uxvh2) — pure map read-model
  var BlueprintCustomize = window.BlueprintCustomize; // H4 (claude-tools-uxvh4) — pure write-side

  // Which track ships each STILL-placeholder facet (honest placeholder copy).
  // 'activity' graduated in I3, 'gates' in J3, 'blueprint' in H4 — none listed
  // here; the map stays so an unknown/future facet still gets an honest message.
  var FACET_TRACK = {};

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
  } else if (ctx.facet === 'gates') {
    mountGatesFacet();
  } else if (ctx.facet === 'blueprint') {
    mountBlueprintFacet();
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

  // ── placeholder facets (blueprint only — activity I3 + gates J3 graduated) ──
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
  // Resolves to `true` on success / `false` on failure so a caller can refresh
  // ONLY on success (the gates edit handlers, so a failed edit keeps its ✗).
  function runAction(btnEl, statusEl, verb, promise) {
    setRowDisabled(btnEl, true);
    statusEl.className = 'af-actions-status pending';
    statusEl.textContent = verb + ' — sending…';
    return promise.then(function (d) {
      statusEl.className = 'af-actions-status ok';
      var idNote = (d && d.action_id) ? (' (queued; the daemon reconciles within ~30s)')
        : (d && d.id) ? (' (decision card created — see the Inbox)') : '';
      statusEl.textContent = '✓ ' + verb + ' accepted' + idNote;
      return true;
    }).catch(function (e) {
      statusEl.className = 'af-actions-status err';
      statusEl.textContent = '✗ ' + verb + ' failed: ' + (e && e.message ? e.message : String(e));
      return false;
    }).then(function (ok) {
      setRowDisabled(btnEl, false);
      return ok;
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

  // ── gates facet (J3 — the unified Hold view: gate editable, dep+sched read-only) ─
  // REUSES window.GatesView.deriveGatesView (the pure view-model). DESIGN J §4 +
  // the §7.2 mock (NORMATIVE). Three hold types in one list per workspace: our
  // Gate is fully editable (lift / edit why / edit unblock + add-a-gate); the
  // beads-native Dependency + Scheduled holds are READ-ONLY with their honest
  // native note (C3 — "coexist with built-in beads blocked"); a Scheduled hold
  // owned by a Gate nests UNDER it. Writes route through the control plane: the
  // why/unblock metadata is an engine-DIRECT gate-meta-set (no host); the label
  // lift/apply is a HOST-effecting agent-action the daemon reconciles via
  // gate-defer.sh — NEVER a direct web→bd mutation (Local==remote). 30s refresh.
  function mountGatesFacet() {
    Dom.clear(host);
    var wrap = Dom.mk('div', 'gf-wrap');

    var loading = Dom.mk('p', 'gf-loading', 'Reading the projection…');
    loading.id = 'gf-loading';
    wrap.appendChild(loading);

    var errbox = Dom.mk('section', 'gf-errbox');
    errbox.id = 'gf-errbox';
    errbox.hidden = true;
    errbox.appendChild(Dom.mk('div', 'gf-err-h', 'Cannot render this workspace'));
    var errB = Dom.mk('p', 'gf-err-b');
    errB.id = 'gf-err-b';
    errbox.appendChild(errB);
    wrap.appendChild(errbox);

    var body = Dom.mk('section', 'gf-body');
    body.id = 'gf-body';
    body.hidden = true;

    // HELD IN <ref> — the one unified list (gate + dependency + scheduled).
    var heldSec = Dom.mk('div', 'gf-sec');
    var heldHead = Dom.mk('div', 'gf-sl');
    heldHead.id = 'gf-held-sl';
    heldHead.textContent = 'HELD IN ' + ctx.ref;
    heldSec.appendChild(heldHead);
    var listHost = Dom.mk('div', 'gf-list');
    listHost.id = 'gf-list';
    heldSec.appendChild(listHost);
    var emptyEl = Dom.mk('p', 'gf-empty',
      'Nothing is holding a task in ' + ctx.ref + ' — no gates, blocks, or defers.');
    emptyEl.id = 'gf-empty';
    emptyEl.hidden = true;
    heldSec.appendChild(emptyEl);
    body.appendChild(heldSec);

    // ADD-A-GATE — the only ADD affordance (Gates are ours; §7.2/§7.4). The form
    // is intentionally simple (the ergonomics are [free], DESIGN J §10): a bare
    // bead-ref input rather than a picker, because the facet reads ONLY holds[]
    // (must-protect #2) and has no full ready-task list to choose from.
    body.appendChild(buildAddGateForm());

    // Honest "degraded" footnotes (B.4) — every dropped/placeholder field named.
    var degSec = Dom.mk('div', 'gf-degraded');
    degSec.id = 'gf-degraded';
    degSec.hidden = true;
    body.appendChild(degSec);

    var foot = Dom.mk('div', 'gf-foot');
    var boardLink = Dom.mk('a', 'facet-link', 'Open this workspace’s board →');
    boardLink.setAttribute('href', '/ws/' + encodeURIComponent(ctx.ref) + '/board');
    foot.appendChild(boardLink);
    var updated = Dom.mk('span', 'gf-updated', '—');
    updated.id = 'gf-updated';
    foot.appendChild(updated);
    body.appendChild(foot);

    wrap.appendChild(body);
    host.appendChild(wrap);

    refreshGates();
    window.setInterval(refreshGates, REFRESH_MS);
  }

  function showGatesError(msg) {
    var loading = Dom.el('gf-loading');
    var body = Dom.el('gf-body');
    var errbox = Dom.el('gf-errbox');
    if (loading) loading.hidden = true;
    if (body) body.hidden = true;
    if (errbox) { errbox.hidden = false; Dom.el('gf-err-b').textContent = msg; }
    if (healthDot) healthDot.classList.add('bad');
  }

  function refreshGates() {
    Net.getJSON('/api/board')
      .then(function (snapshot) {
        var view = GatesView.deriveGatesView(snapshot, ctx.ref, Date.now());
        renderGates(view);
      })
      .catch(function (e) {
        showGatesError(e && e.message ? e.message : String(e));
      });
  }

  // Repaint only when a write SUCCEEDED — a failed edit keeps its ✗ status line
  // (a repaint rebuilds the card and would wipe it). runAction resolves the flag.
  function refreshOnOk(ok) { if (ok) refreshGates(); }

  function renderGates(view) {
    // The one hard refusal (unknown-HIGHER schema_version) surfaces as an error.
    if (!view.ok) { showGatesError(view.error); return; }

    var loading = Dom.el('gf-loading');
    var errbox = Dom.el('gf-errbox');
    var body = Dom.el('gf-body');
    if (loading) loading.hidden = true;
    if (errbox) errbox.hidden = true;
    if (body) body.hidden = false;
    if (healthDot) healthDot.classList.remove('bad');

    var sl = Dom.el('gf-held-sl');
    if (sl) {
      sl.textContent = 'HELD IN ' + ctx.ref +
        (view.counts && view.counts.total ? ' · ' + view.counts.total + ' hold' +
          (view.counts.total === 1 ? '' : 's') : '');
    }

    var list = Dom.el('gf-list');
    Dom.clear(list);
    // Order = the projection's deterministic order (gates, then dependency, then
    // scheduled), then any out-of-set holds. Read-only holds carry NO edit
    // affordance — the renderer keys on each row's `editable` flag, never decides.
    view.gates.forEach(function (g) { list.appendChild(renderGateCard(g)); });
    view.dependencies.forEach(function (d) { list.appendChild(renderDependencyRow(d)); });
    view.scheduled.forEach(function (s) { list.appendChild(renderScheduledRow(s, false)); });
    view.other.forEach(function (o) { list.appendChild(renderOtherRow(o)); });

    var empty = Dom.el('gf-empty');
    if (empty) empty.hidden = !view.empty;

    renderGatesDegraded(view.degraded);

    var updated = Dom.el('gf-updated');
    if (updated) updated.textContent = 'updated ' + new Date().toLocaleTimeString();
  }

  // A GATE card (⛔) — editable IFF g.editable (the projection's call). Shows
  // name + task count + owner/age + why + unblock, the edit affordances, and any
  // Scheduled holds it owns nested beneath it (§7.2).
  function renderGateCard(g) {
    var card = Dom.mk('div', 'gf-card gf-gate');

    var idr = Dom.mk('div', 'gf-id');
    idr.appendChild(Dom.mk('span', 'gf-glyph', '⛔'));
    idr.appendChild(Dom.mk('span', 'gf-type', 'Gate'));
    idr.appendChild(Dom.mk('code', 'gf-name', g.name));
    idr.appendChild(Dom.mk('span', 'gf-count', g.task_count_label));
    var setBits = 'set by: ' + g.owner_label;
    if (g.set_at_age) setBits += ' · ' + g.set_at_age;
    idr.appendChild(Dom.mk('span', 'gf-setby', setBits));
    card.appendChild(idr);

    var whyLine = Dom.mk('div', 'gf-line' + (g.missing_meta ? ' gf-faint' : ''));
    whyLine.appendChild(Dom.mk('span', 'gf-k', 'why: '));
    whyLine.appendChild(document.createTextNode(g.why_label));
    card.appendChild(whyLine);

    var ubLine = Dom.mk('div', 'gf-line' + (g.unblocks_when ? '' : ' gf-faint'));
    ubLine.appendChild(Dom.mk('span', 'gf-k', 'unblocks when: '));
    ubLine.appendChild(document.createTextNode(g.unblocks_when_label));
    card.appendChild(ubLine);

    // Nested scheduled-under-gate holds (§7.2): lifting the Gate clears these.
    if (g.scheduled_under && g.scheduled_under.length) {
      var nest = Dom.mk('div', 'gf-nest');
      g.scheduled_under.forEach(function (s) { nest.appendChild(renderScheduledRow(s, true)); });
      card.appendChild(nest);
    }

    // EDIT AFFORDANCES — only when the projection says editable (C3). The lift is
    // a HOST effect (agent-action gate-lift → gate-defer.sh lift); the why/unblock
    // edits are engine-DIRECT (gate-meta-set), no host round-trip.
    if (g.editable) {
      var status = Dom.mk('div', 'gf-actions-status');
      status.setAttribute('aria-live', 'polite');
      var row = Dom.mk('div', 'gf-actions-row');

      // Lift is a HOST effect the daemon reconciles within ~30s — we keep the
      // optimistic "queued" status and let the 30s auto-refresh pick up the
      // lifted gate (NO immediate refresh, which would wipe that status).
      gfBtn(row, 'lift gate', 'gf-act-lift', function (b) {
        if (!window.confirm('Lift gate "' + g.name + '"?\n\n' +
          'Removes the gate:' + g.gate_id + ' label (and its defer) from ' +
          g.task_count_label + ', so the runner can pick them up again.')) return;
        runAction(b, status, 'lift gate',
          Net.postJSON('/api/control/gate-action', {
            intent: 'gate-lift', workspace: ctx.ref, target: { gate_id: g.gate_id }
          }));
      });

      gfBtn(row, 'edit why', 'gf-act-edit', function (b) {
        var next = window.prompt('Edit why gate "' + g.name + '" holds work:', g.why || '');
        if (next === null) return; // cancelled
        if (!next.trim()) { setStatus(status, 'err', 'a gate always needs a why — not changed'); return; }
        runAction(b, status, 'edit why',
          Net.postJSON('/api/ws/gate-meta', gateMetaBody(g, { why: next.trim() }))
        ).then(refreshOnOk); // only refresh on success — a failed edit keeps its ✗ status
      });

      gfBtn(row, 'edit unblock', 'gf-act-edit', function (b) {
        var next = window.prompt('Edit the unblock condition for gate "' + g.name +
          '" (what would release it):', g.unblocks_when || '');
        if (next === null) return; // cancelled
        // why is REQUIRED on the upsert; a metadata-less gate has none yet, so
        // ask for it too rather than letting the engine 422 (honest, not a throw).
        var why = g.why;
        if (!why) {
          why = window.prompt('This gate has no recorded why yet — a gate always needs one. Why does it hold work?', '');
          if (why === null) return;
          if (!why.trim()) { setStatus(status, 'err', 'a gate always needs a why — not changed'); return; }
          why = why.trim();
        }
        runAction(b, status, 'edit unblock',
          Net.postJSON('/api/ws/gate-meta', gateMetaBody(g, { why: why, unblock_condition: next.trim() }))
        ).then(refreshOnOk); // only refresh on success — a failed edit keeps its ✗ status
      });

      card.appendChild(row);
      card.appendChild(status);
    }

    return card;
  }

  // gateMetaBody(g, overrides) — build the gate-meta-set body, preserving the
  // gate's current why/unblock/scope and applying the edited field. The engine
  // preserves set_at across edits (§2.2) and the proxy forces owner:"you".
  function gateMetaBody(g, overrides) {
    var gate = {
      id: g.gate_id,
      why: g.why || '',
      scope: g.scope || g.scope_label || 'task'
    };
    if (g.unblocks_when) gate.unblock_condition = g.unblocks_when;
    if (overrides) {
      if (typeof overrides.why === 'string') gate.why = overrides.why;
      if (typeof overrides.unblock_condition === 'string') gate.unblock_condition = overrides.unblock_condition;
    }
    return { gate: gate };
  }

  // A read-only DEPENDENCY row (⛓) — beads-native blocked; NO edit affordance.
  function renderDependencyRow(d) {
    var card = Dom.mk('div', 'gf-card gf-dep gf-readonly');
    var idr = Dom.mk('div', 'gf-id');
    idr.appendChild(Dom.mk('span', 'gf-glyph', '⛓'));
    idr.appendChild(Dom.mk('span', 'gf-type', 'Dependency'));
    idr.appendChild(Dom.mk('code', 'gf-name', d.task_ref_label));
    idr.appendChild(Dom.mk('span', 'gf-count', 'blocked on ' + d.blocked_on_label));
    card.appendChild(idr);
    var line = Dom.mk('div', 'gf-line');
    line.appendChild(Dom.mk('span', 'gf-k', 'unblocks when: '));
    line.appendChild(document.createTextNode(d.unblocks_when_label));
    line.appendChild(Dom.mk('span', 'gf-native', '(' + d.native_note + ')'));
    card.appendChild(line);
    return card;
  }

  // A read-only SCHEDULED row (⏰) — beads-native defer; NO edit affordance.
  // `nested` true ⇒ rendered UNDER its owning Gate (compact, no glyph repeat).
  function renderScheduledRow(s, nested) {
    var card = Dom.mk('div', 'gf-card gf-sched gf-readonly' + (nested ? ' gf-nested' : ''));
    var idr = Dom.mk('div', 'gf-id');
    idr.appendChild(Dom.mk('span', 'gf-glyph', '⏰'));
    idr.appendChild(Dom.mk('span', 'gf-type', 'Scheduled'));
    idr.appendChild(Dom.mk('code', 'gf-name', s.task_ref_label));
    idr.appendChild(Dom.mk('span', 'gf-count', 'deferred until ' + s.deferred_until_label));
    card.appendChild(idr);
    var line = Dom.mk('div', 'gf-line');
    line.appendChild(Dom.mk('span', 'gf-k', 'unblocks when: '));
    line.appendChild(document.createTextNode(s.unblocks_when_label));
    line.appendChild(Dom.mk('span', 'gf-native', '(' + s.native_note + ')'));
    card.appendChild(line);
    return card;
  }

  // An out-of-set hold (B.4) — shown raw, read-only, never coerced into one of
  // the three (which would fake editability). The degraded[] footnote names it.
  function renderOtherRow(o) {
    var card = Dom.mk('div', 'gf-card gf-other gf-readonly');
    var idr = Dom.mk('div', 'gf-id');
    idr.appendChild(Dom.mk('span', 'gf-glyph', '?'));
    idr.appendChild(Dom.mk('span', 'gf-type', String(o.type)));
    if (o.task_ref) idr.appendChild(Dom.mk('code', 'gf-name', o.task_ref));
    card.appendChild(idr);
    card.appendChild(Dom.mk('div', 'gf-line gf-faint', 'unknown hold type — read-only'));
    return card;
  }

  // The ADD-A-GATE form (§7.2/§7.4). Two writes (design/agent-action.md §3 #2):
  //   1. gate-meta-set (engine-DIRECT) — the why/unblock/scope metadata.
  //   2. agent-action gate-apply (HOST) — places the gate:<id> label + the
  //      coupled defer date on the selected bead(s) via gate-defer.sh.
  function buildAddGateForm() {
    var sec = Dom.mk('div', 'gf-sec gf-add');
    sec.appendChild(Dom.mk('div', 'gf-sl', 'ADD A GATE · the only editable hold'));
    var form = Dom.mk('div', 'gf-add-form');

    function field(labelText, el, hint) {
      var f = Dom.mk('label', 'gf-field');
      f.appendChild(Dom.mk('span', 'gf-field-l', labelText));
      f.appendChild(el);
      if (hint) f.appendChild(Dom.mk('span', 'gf-field-h', hint));
      return f;
    }
    function input(ph) {
      var i = Dom.mk('input', 'gf-input');
      i.setAttribute('type', 'text');
      if (ph) i.setAttribute('placeholder', ph);
      return i;
    }

    var idIn = input('audio-redesign');
    var whyIn = input('waiting on the audio-engine decision');
    var unblockIn = input('that decision lands (or you lift this)');
    var dateIn = input('YYYY-MM-DD (blank = indefinite until lifted)');
    var beadsIn = input('rhythmGame-77p rhythmGame-5kq');
    var scopeSel = Dom.mk('select', 'gf-input');
    [['task', 'task — one bead'], ['cohort', 'cohort — many beads, lift once']].forEach(function (o) {
      var opt = Dom.mk('option', null, o[1]);
      opt.setAttribute('value', o[0]);
      scopeSel.appendChild(opt);
    });

    form.appendChild(field('gate id', idIn, 'lowercase, digits, hyphens (gate:<id>)'));
    form.appendChild(field('why (required)', whyIn, 'a Gate always records why it holds work'));
    form.appendChild(field('unblock condition', unblockIn, 'what would release it'));
    form.appendChild(field('defer until', dateIn, 'the unblock date, or blank for indefinite'));
    form.appendChild(field('scope', scopeSel));
    form.appendChild(field('task(s) to hold (required)', beadsIn, 'one or more bead refs, space/comma separated'));

    var status = Dom.mk('div', 'gf-actions-status');
    status.setAttribute('aria-live', 'polite');
    var addBtn = Dom.mk('button', 'gf-act gf-act-add', 'Add gate');
    addBtn.setAttribute('type', 'button');
    addBtn.addEventListener('click', function () {
      submitAddGate({
        btn: addBtn, status: status,
        id: idIn.value.trim(), why: whyIn.value.trim(), unblock: unblockIn.value.trim(),
        date: dateIn.value.trim(), scope: scopeSel.value,
        beads: beadsIn.value.split(/[\s,]+/).map(function (x) { return x.trim(); })
          .filter(function (x) { return x.length > 0; })
      });
    });

    form.appendChild(addBtn);
    sec.appendChild(form);
    sec.appendChild(status);
    return sec;
  }

  function submitAddGate(f) {
    // Cheap client-side gates (the engine + proxies are authoritative — these
    // give immediate, honest feedback before any round-trip).
    if (!/^[a-z0-9][a-z0-9-]*$/.test(f.id)) {
      setStatus(f.status, 'err', 'gate id must be lowercase letters, digits, hyphens (gate:<id> shape)'); return;
    }
    if (!f.why) { setStatus(f.status, 'err', 'a gate always needs a why'); return; }
    if (!f.beads.length) { setStatus(f.status, 'err', 'name at least one task (bead ref) to hold'); return; }
    var date = f.date || FAR_FUTURE; // blank ⇒ "indefinite until lifted" sentinel

    setRowDisabled(f.btn, true);
    setStatus(f.status, 'pending', 'add gate — recording why…');
    // 1) engine-DIRECT metadata write (why/unblock/scope). owner forced to "you".
    var meta = { id: f.id, why: f.why, scope: f.scope };
    if (f.unblock) meta.unblock_condition = f.unblock;
    Net.postJSON('/api/ws/gate-meta', { gate: meta })
      .then(function () {
        // 2) HOST label+defer placement (the daemon reconciles within ~30s).
        setStatus(f.status, 'pending', 'add gate — placing the label on ' + f.beads.length + ' task(s)…');
        return Net.postJSON('/api/control/gate-action', {
          intent: 'gate-apply', workspace: ctx.ref,
          target: { gate_id: f.id, bead_refs: f.beads },
          args: { date: date }
        });
      })
      .then(function (d) {
        var note = (d && d.action_id) ? ' (queued; the daemon places the label within ~30s)' : '';
        setStatus(f.status, 'ok', '✓ gate "' + f.id + '" added' + note);
      })
      .catch(function (e) {
        setStatus(f.status, 'err', '✗ add gate failed: ' + (e && e.message ? e.message : String(e)));
      })
      .then(function () { setRowDisabled(f.btn, false); });
  }

  // gfBtn(row, label, cls, handler) — append a button to an action row; the
  // handler gets the button el. Mirrors the I4 btn() helper, gates-scoped.
  function gfBtn(row, label, cls, handler) {
    var b = Dom.mk('button', 'gf-act ' + cls, label);
    b.setAttribute('type', 'button');
    b.addEventListener('click', function () { handler(b); });
    row.appendChild(b);
    return b;
  }

  // setStatus(el, kind, msg) — paint a status line (kind ∈ pending|ok|err).
  function setStatus(el, kind, msg) {
    if (!el) return;
    el.className = 'gf-actions-status ' + kind;
    el.textContent = msg;
  }

  // Honest degraded[] footnotes (B.4): name every placeholder/dropped field.
  function renderGatesDegraded(degraded) {
    var sec = Dom.el('gf-degraded');
    if (!sec) return;
    Dom.clear(sec);
    degraded = Array.isArray(degraded) ? degraded : [];
    if (degraded.length === 0) { sec.hidden = true; return; }
    sec.hidden = false;
    sec.appendChild(Dom.mk('div', 'gf-degraded-h', 'Degraded (honest gaps)'));
    var ul = Dom.mk('ul', 'gf-degraded-list');
    degraded.forEach(function (d) { ul.appendChild(Dom.mk('li', null, d)); });
    sec.appendChild(ul);
  }

  // ── blueprint facet (H4 — the customization map + conflict-FYI keep/drop) ─────
  // The ONE facet that reads its OWN §4 record (blueprint-get, B.2), NOT the
  // work-snapshot (§8.1 keeps the map out of the projection, fetched on demand).
  // It REUSES window.BlueprintView.deriveBlueprintView (H2, the pure read-side map
  // model) to draw a drill-in node tree, and window.BlueprintCustomize (H4, the
  // pure write-side) to turn a tap into the next `customization` sub-object it
  // POSTs through /api/ws/blueprint-put (section:"customization"). The sectioned
  // engine op (H1) guarantees a concurrent `derived` regen by the updater hat
  // never eats the edit (§2.3 never-clobber). Conflicts (the §5.3 honesty channel)
  // render as a small FYI with one-tap keep/drop; KEEP is the §14.2 default (the
  // customization persists), DROP removes the orphaned override — both re-write
  // customization, never conflicts[] (that is the updater's append-only log).
  //
  // SCOPE LINE (H4 vs H3): H4 owns the customization gestures + the conflict-FYI +
  // an honest interactive map mount. H3 layers the narrative prose (TL;DR →
  // headings) ABOVE this map + the ?focus=<id> deep-link contract + the
  // blueprint_meta projection + the in-flight overlay wiring (G5's renderer
  // overlay is read here only if a future caller passes activity in). The map
  // geometry is [free] (§3.5): this mount renders an honest drill-in TREE, not the
  // spatial grow-to-fit canvas (H3's drawing job) — the customization CONTRACT,
  // not the geometry, is what H4 ships.
  var bpOpened = Object.create(null); // node id → true: which boxes are drilled in
  var bpRecord = null;                // last blueprint-get body (the B.2 record)
  var bpInFlight = false;             // a customization write is in flight — skip the timer repaint

  function mountBlueprintFacet() {
    Dom.clear(host);
    var wrap = Dom.mk('div', 'bp-wrap');

    var loading = Dom.mk('p', 'bp-loading', 'Reading the Blueprint…');
    loading.id = 'bp-loading';
    wrap.appendChild(loading);

    var errbox = Dom.mk('section', 'bp-errbox');
    errbox.id = 'bp-errbox';
    errbox.hidden = true;
    errbox.appendChild(Dom.mk('div', 'bp-err-h', 'Cannot render this Blueprint'));
    var errB = Dom.mk('p', 'bp-err-b');
    errB.id = 'bp-err-b';
    errbox.appendChild(errB);
    wrap.appendChild(errbox);

    var body = Dom.mk('section', 'bp-body');
    body.id = 'bp-body';
    body.hidden = true;

    // EMPTY STATE — honest "no Blueprint yet" (B.4); the updater hat (H5) or an
    // L4 overview-request creates v1 on the first structural close.
    var empty = Dom.mk('div', 'bp-emptybox');
    empty.id = 'bp-emptybox';
    empty.hidden = true;
    empty.appendChild(Dom.mk('div', 'bp-empty-h', 'No Blueprint yet for ' + ctx.ref));
    empty.appendChild(Dom.mk('p', 'bp-empty-b',
      'The living design+map is built on the first structural change (a design / ' +
      'impl / docs task closing), or when you request an overview. Nothing to ' +
      'customize until then.'));
    body.appendChild(empty);

    // CONFLICTS lane — the §5.3 keep/drop FYIs (live conflicts only).
    var cSec = Dom.mk('div', 'bp-sec bp-conflicts-sec');
    cSec.id = 'bp-conflicts-sec';
    cSec.hidden = true;
    var cHead = Dom.mk('div', 'bp-sl bp-sl-warn');
    cHead.id = 'bp-conflicts-sl';
    cHead.textContent = 'YOUR CUSTOMIZATIONS THAT NO LONGER MAP TO CODE';
    cSec.appendChild(cHead);
    var cHost = Dom.mk('div', 'bp-conflicts');
    cHost.id = 'bp-conflicts';
    cSec.appendChild(cHost);
    body.appendChild(cSec);

    // MAP — the drill-in node tree (top-level boxes; tap to drill / edit).
    var mSec = Dom.mk('div', 'bp-sec');
    var mHead = Dom.mk('div', 'bp-sl');
    mHead.id = 'bp-map-sl';
    mHead.textContent = 'MAP · tap a box to drill in; edit to rename / regroup / pin / hide';
    mSec.appendChild(mHead);
    var mHost = Dom.mk('div', 'bp-map');
    mHost.id = 'bp-map';
    mSec.appendChild(mHost);
    body.appendChild(mSec);

    // HIDDEN — nodes Brian hid (so a hide is reversible from off the map).
    var hSec = Dom.mk('div', 'bp-sec bp-hidden-sec');
    hSec.id = 'bp-hidden-sec';
    hSec.hidden = true;
    hSec.appendChild(Dom.mk('div', 'bp-sl', 'HIDDEN (suppressed as noise — tap to bring back)'));
    var hHost = Dom.mk('div', 'bp-hidden-host');
    hHost.id = 'bp-hidden-host';
    hSec.appendChild(hHost);
    body.appendChild(hSec);

    // A single top-of-map status line for customization writes.
    var status = Dom.mk('div', 'bp-actions-status');
    status.id = 'bp-status';
    status.setAttribute('aria-live', 'polite');
    body.appendChild(status);

    // Honest degraded[] footnotes (B.4) — every dropped/placeholder field named.
    var degSec = Dom.mk('div', 'bp-degraded');
    degSec.id = 'bp-degraded';
    degSec.hidden = true;
    body.appendChild(degSec);

    var foot = Dom.mk('div', 'bp-foot');
    var boardLink = Dom.mk('a', 'facet-link', 'Open this workspace’s board →');
    boardLink.setAttribute('href', '/ws/' + encodeURIComponent(ctx.ref) + '/board');
    foot.appendChild(boardLink);
    var updated = Dom.mk('span', 'bp-updated', '—');
    updated.id = 'bp-updated';
    foot.appendChild(updated);
    body.appendChild(foot);

    wrap.appendChild(body);
    host.appendChild(wrap);

    refreshBlueprint();
    window.setInterval(function () { if (!bpInFlight) refreshBlueprint(); }, REFRESH_MS);
  }

  function showBlueprintError(msg) {
    var loading = Dom.el('bp-loading');
    var body = Dom.el('bp-body');
    var errbox = Dom.el('bp-errbox');
    if (loading) loading.hidden = true;
    if (body) body.hidden = true;
    if (errbox) { errbox.hidden = false; Dom.el('bp-err-b').textContent = msg; }
    if (healthDot) healthDot.classList.add('bad');
  }

  // Read THIS workspace's Blueprint record (NOT /api/board) — the §8.1 on-demand
  // fetch. The engine returns the B.2 body verbatim, or `null` (no Blueprint yet).
  function refreshBlueprint() {
    Net.getJSON('/api/ws/blueprint?project_ref=' + encodeURIComponent(ctx.ref))
      .then(function (record) {
        bpRecord = record; // may be null (honest empty state)
        renderBlueprint(record);
      })
      .catch(function (e) {
        showBlueprintError(e && e.message ? e.message : String(e));
      });
  }

  function renderBlueprint(record) {
    var view = BlueprintView.deriveBlueprintView(record, Date.now(), {
      opened: Object.keys(bpOpened)
    });
    // The one hard refusal (unknown-HIGHER schema_version) surfaces as an error.
    if (!view.ok) { showBlueprintError(view.error); return; }

    var loading = Dom.el('bp-loading');
    var errbox = Dom.el('bp-errbox');
    var body = Dom.el('bp-body');
    if (loading) loading.hidden = true;
    if (errbox) errbox.hidden = true;
    if (body) body.hidden = false;
    if (healthDot) healthDot.classList.remove('bad');

    // Empty state: no record, or a record with zero nodes (honest, B.4).
    var isEmpty = !view.found || view.empty;
    Dom.el('bp-emptybox').hidden = !isEmpty;
    Dom.el('bp-map-sl').hidden = isEmpty;

    renderBlueprintConflicts(record);
    renderBlueprintMap(view);
    renderBlueprintHidden(view);
    renderBlueprintDegraded(view.degraded);

    var updated = Dom.el('bp-updated');
    if (updated) {
      var age = view.updated_at_age ? (' · updated ' + view.updated_at_age) : '';
      updated.textContent = 'read ' + new Date().toLocaleTimeString() + age;
    }
  }

  // ── conflict FYIs (§5.3 keep / drop; KEEP is the §14.2 default) ──────────────
  // deriveLiveConflicts is the honest projection over the append-only conflicts[]
  // log (dedup + drop-/keep-/reattach-resolved removed). We render only the live
  // ones; an empty list hides the whole lane.
  function renderBlueprintConflicts(record) {
    var sec = Dom.el('bp-conflicts-sec');
    var hostEl = Dom.el('bp-conflicts');
    var sl = Dom.el('bp-conflicts-sl');
    Dom.clear(hostEl);
    var live = BlueprintCustomize.deriveLiveConflicts(record);
    if (!live.length) { sec.hidden = true; return; }
    sec.hidden = false;
    if (sl) sl.textContent = 'YOUR CUSTOMIZATIONS THAT NO LONGER MAP TO CODE · ' + live.length;

    live.forEach(function (cf) {
      var card = Dom.mk('div', 'bp-conflict');
      var msg = Dom.mk('div', 'bp-conflict-msg');
      var what = cf.custom ? ('“' + cf.custom + '”') : ('your ' + friendlyKind(cf.kind));
      msg.appendChild(document.createTextNode('Your custom ' + friendlyKind(cf.kind) +
        ' ' + what + ' for '));
      msg.appendChild(Dom.mk('code', 'bp-conflict-id', cf.node_id));
      msg.appendChild(document.createTextNode(' no longer maps to any code.'));
      card.appendChild(msg);
      if (cf.note) card.appendChild(Dom.mk('div', 'bp-conflict-note', cf.note));

      var status = Dom.mk('div', 'bp-actions-status');
      status.setAttribute('aria-live', 'polite');
      var row = Dom.mk('div', 'bp-actions-row');

      // KEEP (default): persist the ack, keep the override (never a revert).
      // Both handlers read the FRESHEST customization (cust()) so they compose
      // with a concurrent refresh rather than re-writing a stale captured copy.
      bpBtn(row, 'Keep', 'bp-act-keep', function (b) {
        var next = BlueprintCustomize.keepConflict(cust(), cf);
        if (!next.ok) { setStatus(status, 'err', next.error); return; }
        putCustomization(next.customization, b, status, 'keep');
      });
      // DROP (only when the kind is resolvable): remove the orphaned override.
      if (cf.resolvable) {
        bpBtn(row, 'Drop', 'bp-act-drop', function (b) {
          if (!window.confirm('Drop your custom ' + friendlyKind(cf.kind) +
            ' for ' + cf.node_id + '?\n\nThis removes the override. (Keep is the safe default.)')) return;
          var next = BlueprintCustomize.dropConflict(cust(), cf);
          if (!next.ok) { setStatus(status, 'err', next.error); return; }
          putCustomization(next.customization, b, status, 'drop');
        });
      }
      card.appendChild(row);
      card.appendChild(status);
      hostEl.appendChild(card);
    });
  }

  function friendlyKind(kind) {
    switch (kind) {
      case 'rename-orphan': return 'name';
      case 'regroup-orphan': return 'grouping';
      case 'pin-orphan': return 'pin';
      case 'hide-orphan': return 'hide';
      case 'split-orphan': return 'split';
      case 'merge-orphan': return 'merge';
      default: return 'customization';
    }
  }

  // ── the drill-in node tree (the [free] geometry; the contract is the gestures) ─
  // Render visible top-level boxes; descend into a box's visible children only
  // when it is OPEN (view.open, driven by bpOpened + pins). Each node carries its
  // edit affordances (rename/regroup/pin/hide + split/merge recorders).
  function renderBlueprintMap(view) {
    var mapHost = Dom.el('bp-map');
    Dom.clear(mapHost);
    if (!view.nodes.length) return;

    var byId = Object.create(null);
    view.nodes.forEach(function (n) { byId[n.id] = n; });

    var roots = view.nodes.filter(function (n) { return n.top_level && n.visible; });
    roots.forEach(function (n) { mapHost.appendChild(renderBlueprintNode(n, byId)); });

    // A compact legend of the live overlay / counts (honest, derived).
    var legend = Dom.mk('div', 'bp-legend');
    legend.appendChild(Dom.mk('span', null,
      view.counts.top_level + ' top-level · ' + view.counts.nodes + ' nodes · ' +
      view.counts.edges + ' edges'));
    if (view.counts.hidden) legend.appendChild(Dom.mk('span', 'bp-legend-hidden',
      view.counts.hidden + ' hidden'));
    mapHost.appendChild(legend);
  }

  function renderBlueprintNode(n, byId) {
    var card = Dom.mk('div', 'bp-node bp-kind-' + (n.kind_known ? n.kind : 'unknown') +
      (n.dimmed ? ' bp-dim' : '') + (n.active ? ' bp-active' : '') +
      (n.collision ? ' bp-collision' : ''));
    card.style.marginLeft = (n.depth * 16) + 'px';

    var head = Dom.mk('div', 'bp-node-head');
    var kids = (n.children || []).filter(function (id) { return byId[id] && byId[id].visible; });
    // The drill toggle (only when there are visible children to reveal).
    if (kids.length) {
      var caret = Dom.mk('button', 'bp-caret', n.open ? '▾' : '▸');
      caret.setAttribute('type', 'button');
      caret.setAttribute('aria-label', (n.open ? 'collapse ' : 'drill into ') + n.label);
      caret.addEventListener('click', function () { toggleOpen(n.id); });
      head.appendChild(caret);
    } else {
      head.appendChild(Dom.mk('span', 'bp-caret bp-caret-leaf', '·'));
    }

    head.appendChild(Dom.mk('span', 'bp-kindtag', n.kind_known ? n.kind : (n.kind || '?')));
    var nameEl = Dom.mk('span', 'bp-name', n.label);
    if (n.renamed) nameEl.appendChild(Dom.mk('span', 'bp-badge', 'renamed'));
    if (n.regrouped) nameEl.appendChild(Dom.mk('span', 'bp-badge', 'regrouped'));
    if (n.pinned) nameEl.appendChild(Dom.mk('span', 'bp-badge bp-badge-pin', '📌 pinned'));
    head.appendChild(nameEl);
    if (kids.length) head.appendChild(Dom.mk('span', 'bp-count', String(kids.length)));
    card.appendChild(head);

    // EDIT row — the four first-class overrides (§5.4) + split/merge recorders.
    card.appendChild(renderNodeEditRow(n));

    // children (only when open).
    if (n.open && kids.length) {
      var kidWrap = Dom.mk('div', 'bp-children');
      kids.forEach(function (id) { kidWrap.appendChild(renderBlueprintNode(byId[id], byId)); });
      card.appendChild(kidWrap);
    }
    return card;
  }

  // The per-node edit affordances. Each gesture builds the NEXT customization via
  // the pure BlueprintCustomize controller and POSTs the WHOLE sub-object (the
  // sectioned engine op merges it over derived — never-clobber, §2.3). The exact
  // gesture (prompt vs inline) is [free] (§5.4/§11); a prompt is the honest v1.
  function renderNodeEditRow(n) {
    var row = Dom.mk('div', 'bp-edit-row');
    var status = Dom.mk('div', 'bp-actions-status bp-edit-status');
    status.setAttribute('aria-live', 'polite');

    bpBtn(row, '✎ rename', 'bp-act-edit', function (b) {
      var next = window.prompt('Rename “' + n.label + '” (blank to revert to the derived name “' +
        n.derived_label + '”):', n.renamed ? n.label : '');
      if (next === null) return; // cancelled
      var r = BlueprintCustomize.rename(cust(), n.id, next.trim());
      if (!r.ok) { setStatus(status, 'err', r.error); return; }
      putCustomization(r.customization, b, status, 'rename');
    });

    bpBtn(row, '⤳ regroup', 'bp-act-edit', function (b) {
      var next = window.prompt('Move “' + n.label + '” under which parent? Enter a node id ' +
        '(e.g. domain:messaging), or blank to clear:', n.parent || '');
      if (next === null) return;
      var r = BlueprintCustomize.regroup(cust(), n.id, next.trim());
      if (!r.ok) { setStatus(status, 'err', r.error); return; }
      putCustomization(r.customization, b, status, 'regroup');
    });

    bpBtn(row, n.pinned ? '📌 unpin' : '📌 pin', 'bp-act-toggle', function (b) {
      var r = BlueprintCustomize.setPinned(cust(), n.id, !n.pinned);
      if (!r.ok) { setStatus(status, 'err', r.error); return; }
      putCustomization(r.customization, b, status, n.pinned ? 'unpin' : 'pin');
    });

    bpBtn(row, '🙈 hide', 'bp-act-toggle', function (b) {
      if (!window.confirm('Hide “' + n.label + '” (and anything inside it) as noise?\n\n' +
        'You can bring it back from the HIDDEN list below.')) return;
      var r = BlueprintCustomize.setHidden(cust(), n.id, true);
      if (!r.ok) { setStatus(status, 'err', r.error); return; }
      putCustomization(r.customization, b, status, 'hide');
    });

    // split / merge — recorded now, RENDERED later (§5.4: the map rides on the
    // four above; the renderer recognises but does not yet apply split/merge).
    // Honest: the degraded[] footer notes a recorded split/merge is not yet drawn.
    bpBtn(row, '✂ split', 'bp-act-more', function (b) {
      var note = window.prompt('Record a SPLIT of “' + n.label + '” into two domains. ' +
        'Note what should split out (recorded now; the split RENDER ships later):', '');
      if (note === null) return;
      var r = BlueprintCustomize.addSplit(cust(), { id: n.id, note: note.trim() });
      if (!r.ok) { setStatus(status, 'err', r.error); return; }
      putCustomization(r.customization, b, status, 'split (recorded)');
    });
    bpBtn(row, '⋈ merge', 'bp-act-more', function (b) {
      var other = window.prompt('Record a MERGE of “' + n.label + '” WITH which node? ' +
        'Enter a node id (recorded now; the merge RENDER ships later):', '');
      if (other === null) return;
      var r = BlueprintCustomize.addMerge(cust(), { from: [n.id, other.trim()], into: n.id });
      if (!r.ok) { setStatus(status, 'err', r.error); return; }
      putCustomization(r.customization, b, status, 'merge (recorded)');
    });

    var box = Dom.mk('div', 'bp-edit-box');
    box.appendChild(row);
    box.appendChild(status);
    return box;
  }

  // HIDDEN list — every hidden node id with an "unhide" affordance, so a hide is
  // never a one-way trap (it does not render on the map by construction).
  function renderBlueprintHidden(view) {
    var sec = Dom.el('bp-hidden-sec');
    var hostEl = Dom.el('bp-hidden-host');
    Dom.clear(hostEl);
    var hidden = (bpRecord && bpRecord.customization &&
      Array.isArray(bpRecord.customization.hidden)) ? bpRecord.customization.hidden : [];
    if (!hidden.length) { sec.hidden = true; return; }
    sec.hidden = false;
    hidden.forEach(function (id) {
      var row = Dom.mk('div', 'bp-hidden-row');
      row.appendChild(Dom.mk('code', 'bp-hidden-id', id));
      var status = Dom.mk('div', 'bp-actions-status bp-edit-status');
      var btnRow = Dom.mk('div', 'bp-actions-row');
      bpBtn(btnRow, 'unhide', 'bp-act-toggle', function (b) {
        var r = BlueprintCustomize.setHidden(cust(), id, false);
        if (!r.ok) { setStatus(status, 'err', r.error); return; }
        putCustomization(r.customization, b, status, 'unhide');
      });
      row.appendChild(btnRow);
      row.appendChild(status);
      hostEl.appendChild(row);
    });
  }

  function renderBlueprintDegraded(degraded) {
    var sec = Dom.el('bp-degraded');
    if (!sec) return;
    Dom.clear(sec);
    degraded = Array.isArray(degraded) ? degraded : [];
    if (degraded.length === 0) { sec.hidden = true; return; }
    sec.hidden = false;
    sec.appendChild(Dom.mk('div', 'bp-degraded-h', 'Degraded (honest gaps)'));
    var ul = Dom.mk('ul', 'bp-degraded-list');
    degraded.forEach(function (d) { ul.appendChild(Dom.mk('li', null, d)); });
    sec.appendChild(ul);
  }

  // The CURRENT customization sub-object (from the last fetched record) — the base
  // every builder layers onto. Tolerant of a null/garbled record (BlueprintCustomize
  // normalizes). This is read FRESH each gesture so concurrent refreshes compose.
  function cust() {
    return (bpRecord && bpRecord.customization) ? bpRecord.customization : {};
  }

  function toggleOpen(id) {
    if (bpOpened[id]) delete bpOpened[id];
    else bpOpened[id] = true;
    if (bpRecord !== undefined) renderBlueprint(bpRecord);
  }

  function bpBtn(row, label, cls, handler) {
    var b = Dom.mk('button', 'bp-act ' + cls, label);
    b.setAttribute('type', 'button');
    b.addEventListener('click', function () { handler(b); });
    row.appendChild(b);
    return b;
  }

  // putCustomization — POST the WHOLE merged customization sub-object as the
  // `customization` section (the sectioned engine op never clobbers `derived`).
  // On success: re-fetch the record + re-render (preserving the drill-in state);
  // on failure: keep the ✗ status (a repaint would wipe it). bpInFlight guards the
  // 30s timer from repainting mid-write.
  function putCustomization(customization, btnEl, statusEl, verb) {
    bpInFlight = true;
    return runAction(btnEl, statusEl, verb,
      Net.postJSON('/api/ws/blueprint-put', {
        project_ref: ctx.ref, section: 'customization', body: customization
      })
    ).then(function (ok) {
      bpInFlight = false;
      if (ok) refreshBlueprint();
      return ok;
    });
  }
})();
