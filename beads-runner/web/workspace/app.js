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
  // an honest interactive map mount. H3 (claude-tools-uxvh3) LANDED the rest: the
  // §8.3 narrative prose (TL;DR → headings) ABOVE this map (#bp-narrative), the
  // ?focus=<id> deep-link contract (bpFocus → opts.focus + the focus banner +
  // scroll-once), the blueprint_meta projection (engine-side, the Workspace card),
  // and the §6.4/§8.2 in-flight overlay WIRING (a best-effort /api/board read →
  // extractBlueprintOverlay → opts.active_domains/activity, lighting worked
  // domains the renderer already supports). The map geometry is [free] (§3.5):
  // this mount renders an honest drill-in TREE, not the spatial grow-to-fit canvas
  // — the customization CONTRACT + the narrative/overlay, not the geometry.
  var bpOpened = Object.create(null); // node id → true: which boxes are drilled in
  var bpRecord = null;                // last blueprint-get body (the B.2 record)
  var bpOverlay = null;               // §8.2 in-flight overlay {active_domains,activity} (best-effort /api/board)
  var bpInFlight = false;             // a customization write is in flight — skip the timer repaint
  var bpFocusDirty = false;          // a NEW focus (deep-link or tap) → zoom-to-fit on it next paint
  var bpRefitDirty = false;          // focus cleared (back to system) → re-fit the whole world next paint

  // ── bpmap-1 positioned-canvas state (claude-tools-bpmap1) ─────────────────────
  // bpView is the pan/zoom of the ONE transformed 'world' (see THE SHARED RENDER
  // CONTRACT comment above renderBlueprintMap): panX/panY are VIEWPORT px, zoom is
  // unitless, world{W,H} the last world extent (for the fit control). The state is
  // PRESERVED across the 30s refresh + drill — auto-fit runs ONCE (fitted), so a
  // repaint never yanks the viewport. bpSelected = the node whose H4 edit
  // affordances show in the panel below the canvas (the gestures, kept working).
  var bpView = { panX: 0, panY: 0, zoom: 1, worldW: 1, worldH: 1,
    originX: 0, originY: 0, labelsHidden: true };
  // §4 detail-panel global toggles (the Diagrammer reference): APIs (boundary
  // boxes on each domain), Internals (open every domain to reveal its capabilities),
  // Edge labels, and the In-flight overlay (light up domains the swarm is working).
  // All default OFF so the macro view is clean — a dozen boxes + traceable arrows.
  var bpToggles = { apis: false, components: false, inflight: false };
  var bpPanelCollapsed = false;     // the detail panel's collapsed state (persists across re-render)
  var bpMini = {};                  // minimap scale/extent for the viewport-rect updater
  var bpUserMovedView = false;      // the user panned/zoomed → stop auto-framing the world
  var bpResizeObs = null;           // ResizeObserver that re-fits when the map settles its size
  var bpSelected = null;            // node id whose edit panel is open (null = none)
  var bpPal = Object.create(null);  // node id → {fill,border,ink}; set each render (bpAssignPalette)
  var BP_MIN_ZOOM = 0.12, BP_MAX_ZOOM = 4;
  var SVG_NS = 'http://www.w3.org/2000/svg';   // bpmap-2 edge/api SVG namespace
  var BP_API_W = 76, BP_API_H = 22, BP_API_GAP = 6;  // §7 boundary-box size (straddles the border)

  // ── per-domain palette (§15.1) — color separates concepts. Each top-level domain
  // gets a distinct pastel hue (cycled by appearance order, so it is stable across
  // refreshes); the client / stores / vendors / externals get fixed hues; a drill-in
  // capability inherits a LIGHTENED tint of its domain's hue. bpAssignPalette returns
  // id → {fill,border,ink}; renderBlueprintNode sets them as --bp-* CSS vars.
  var BP_PAL = [
    { fill: '#cfe0f7', border: '#3b6fb0', ink: '#15325e' }, // blue
    { fill: '#ded0f2', border: '#6b4ca8', ink: '#2e1a57' }, // violet
    { fill: '#f6e2ad', border: '#9c7616', ink: '#4a3606' }, // amber
    { fill: '#f4cabd', border: '#b8472c', ink: '#511507' }, // rust
    { fill: '#bfe2cf', border: '#2f8159', ink: '#0d3a24' }, // teal
    { fill: '#cdd2f0', border: '#5566b0', ink: '#1e2a5e' }, // periwinkle (NOT store-green — domains must stay distinct from the store hue)
    { fill: '#f0dcb6', border: '#8a6c1e', ink: '#3f3008' }, // sand
    { fill: '#bfe0e6', border: '#2d7c8a', ink: '#0c3640' }, // cyan
    { fill: '#f3cdda', border: '#b03f6a', ink: '#511025' }  // pink
  ];
  var BP_PAL_CLIENT = { fill: '#f6d2bf', border: '#c0531f', ink: '#5a2410' };
  var BP_PAL_STORE = { fill: '#cfe6b4', border: '#4f8a35', ink: '#1f3a0e' };
  var BP_PAL_VENDOR = { fill: '#e3d9ee', border: '#6a5a86', ink: '#2f2447' };
  var BP_PAL_EXT = { fill: '#ded6e6', border: '#7a6a92', ink: '#2f2447' };
  var BP_PAL_FALLBACK = { fill: '#dfe3ea', border: '#7f8794', ink: '#2b3038' };

  function bpHexLighten(hex, t) {
    var m = (hex || '').match(/^#?([0-9a-f]{6})$/i);
    if (!m) return hex;
    var n = parseInt(m[1], 16);
    var r = (n >> 16) & 255, g = (n >> 8) & 255, b = n & 255;
    r = Math.round(r + (255 - r) * t);
    g = Math.round(g + (255 - g) * t);
    b = Math.round(b + (255 - b) * t);
    return '#' + ((1 << 24) + (r << 16) + (g << 8) + b).toString(16).slice(1);
  }

  // Map every node id → its palette. Domains by appearance order; client/store/
  // vendor/external fixed; a capability inherits its nearest domain ancestor's hue,
  // lightened. Pure over the view's node list.
  function bpAssignPalette(view) {
    var byId = Object.create(null);
    view.nodes.forEach(function (n) { byId[n.id] = n; });
    var pal = Object.create(null), di = 0;
    view.nodes.forEach(function (n) {
      if (n.kind === 'domain') { pal[n.id] = BP_PAL[di % BP_PAL.length]; di++; }
      else if (n.kind === 'client') pal[n.id] = BP_PAL_CLIENT;
      else if (n.kind === 'store') pal[n.id] = BP_PAL_STORE;
      else if (n.kind === 'vendor') pal[n.id] = BP_PAL_VENDOR;
      else if (n.kind === 'external') pal[n.id] = BP_PAL_EXT;
    });
    view.nodes.forEach(function (n) {
      if (pal[n.id]) return;
      var cur = n, guard = 0, base = null;
      while (cur && guard < 99) {
        if (pal[cur.id]) { base = pal[cur.id]; break; }
        cur = cur.parent ? byId[cur.parent] : null; guard++;
      }
      base = base || BP_PAL_FALLBACK;
      pal[n.id] = { fill: bpHexLighten(base.fill, 0.5), border: base.border, ink: base.ink };
    });
    return pal;
  }

  // top-level container ids (parent==null AND parents a child) — used by the
  // Internals toggle to open every domain at once. Tolerant of a null/odd record.
  function bpTopLevelContainerIds(record) {
    var d = record && record.derived;
    var nodes = (d && Array.isArray(d.nodes)) ? d.nodes : [];
    var hasChild = Object.create(null);
    nodes.forEach(function (n) { if (n && n.parent) hasChild[n.parent] = true; });
    return nodes.filter(function (n) { return n && n.parent == null && hasChild[n.id]; })
      .map(function (n) { return n.id; });
  }

  // Whether to DRAW a domain's §7 api boundary boxes: the global APIs toggle, OR the
  // domain is the focus target / was opened by focus (drilling a domain reveals its
  // entry points). Independent of the Internals toggle so the two read separately.
  function bpShowApisFor(d) {
    return bpToggles.apis || !!d.focused_self || d.open_source === 'focus';
  }
  // pointer pan/pinch bookkeeping (mouse + touch; jsdom never fires these — the
  // render test asserts the DOM, not the gestures).
  var bpPointers = Object.create(null); // pointerId → {x,y} in viewport coords
  var bpPanLast = null;            // last single-pointer pos (incremental pan)
  var bpPanOrigin = null;          // single-pointer down pos (tap-vs-drag threshold)
  var bpPinchDist = 0;             // last two-pointer distance (pinch zoom)
  var bpJustPanned = false;        // a drag/pinch happened → suppress the trailing tap
  var bpHandlersOn = false;        // window-level pointer listeners attached once

  // ?focus=<node-id> deep-link (§8.4). H3 owns the route+param CONTRACT: a Board
  // done·verified card, a decision dossier, or the Flow F FYI link
  // /ws/<ref>/blueprint?focus=<id> and it must RESOLVE (open at that node, full
  // map) — never 404. bpmap-3 makes focus the LIVE interaction state too: tapping a
  // box sets bpFocus (→ the H2 model opens it + its ancestors and DIMS the
  // unconnected, all already exposed on each node); 'back to system' / Esc clears
  // it (the focus-opened boxes auto-collapse, manual/pinned drill-ins survive via
  // the model's open_source pin>manual>focus). A focus id the map doesn't know is
  // honestly surfaced (the view-model notes it + renders the full map), never an
  // error. SEEDED ONCE from the URL ?focus param at mount, then mutated by taps.
  var bpFocus = (function () {
    try {
      var q = new URLSearchParams(location.search);
      var f = q.get('focus');
      return (typeof f === 'string' && f) ? f : null;
    } catch (e) { return null; }
  })();
  bpFocusDirty = !!bpFocus; // a ?focus deep-link zooms-to-focus once on the first paint

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

    // FOCUS banner — when arrived via a ?focus=<id> deep-link (§8.4), say what we
    // focused (and honestly, if the id isn't in this map, that we're showing the
    // whole map instead). Hidden when there is no focus param.
    var focusBanner = Dom.mk('div', 'bp-focus-banner');
    focusBanner.id = 'bp-focus-banner';
    focusBanner.hidden = true;
    body.appendChild(focusBanner);

    // NARRATIVE — the §8.3 skimmable design prose ABOVE the map: TL;DR → section
    // headings/prose (acronyms expanded on first use by the pure view-model), then
    // the map below is the diagram, and the map's drill-in is the drill-down
    // detail (TL;DR → headings → map → detail). Hidden when the record carries no
    // narrative (B.4 — honest absence, the map still renders).
    var nSec = Dom.mk('section', 'bp-narrative');
    nSec.id = 'bp-narrative';
    nSec.hidden = true;
    body.appendChild(nSec);

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

    // MAP — the positioned canvas (bpmap-1): absolutely-placed boxes in a scaled,
    // pannable world. Tap a box to drill (containers) or open its ⋯ editor.
    var mSec = Dom.mk('div', 'bp-sec');
    mSec.id = 'bp-map-sec';
    var mHead = Dom.mk('div', 'bp-sl');
    mHead.id = 'bp-map-sl';
    mHead.textContent = 'MAP · drag to pan · scroll / pinch to zoom · click a domain to dive in · esc to step out · DETAIL panel reveals APIs / internals';
    mSec.appendChild(mHead);
    var mHost = Dom.mk('div', 'bp-map');
    mHost.id = 'bp-map';
    mSec.appendChild(mHost);
    body.appendChild(mSec);
    attachBpPanZoom(mHost); // wheel/pointer pan+zoom (once; the viewport persists)

    // bpmap-3 FOLDED the H4 customization gestures (rename/regroup/pin/hide +
    // split/merge) ONTO the positioned box — a per-node ⋯ popover (buildNodeMenu),
    // REPLACING the flat #bp-edit-panel edit-row list that used to live here.

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

  // Read THIS workspace's Blueprint record (the §8.1 on-demand fetch — the map
  // body stays out of the work-snapshot). The engine returns the B.2 body
  // verbatim, or `null` (no Blueprint yet). SEPARATELY, best-effort, read the
  // work-snapshot (/api/board) for the §8.2 in-flight overlay: this project's
  // blueprint_meta.active_domains + activity light up worked domains on the map.
  // The board read is BEST-EFFORT (G5 wiring) — a board failure leaves the
  // overlay dark (B.4), it NEVER fails the facet; the record read is the one that
  // gates the facet.
  function refreshBlueprint() {
    var pRecord = Net.getJSON('/api/ws/blueprint?project_ref=' + encodeURIComponent(ctx.ref));
    var pOverlay = Net.getJSON('/api/board').then(
      function (snap) { return extractBlueprintOverlay(snap, ctx.ref); },
      function () { return null; } // overlay is best-effort — dark on any board error
    );
    Promise.all([pRecord, pOverlay])
      .then(function (res) {
        bpRecord = res[0];     // may be null (honest empty state)
        bpOverlay = res[1];    // may be null (overlay dark)
        renderBlueprint(res[0]);
      })
      .catch(function (e) {
        showBlueprintError(e && e.message ? e.message : String(e));
      });
  }

  // extractBlueprintOverlay(snapshot, ref) → the §8.2 overlay inputs for `ref`
  // from the work-snapshot: { active_domains, activity }. The renderer's
  // normalizeOverlay folds BOTH — active_domains (the §8.1 union — lights boxes)
  // and activity (the identity-bearing {writer,auxiliary} — the only form that
  // can honestly assert a two-agents-one-domain collision). Tolerant: a missing
  // project / block ⇒ null (dark overlay), never a throw.
  function extractBlueprintOverlay(snapshot, ref) {
    if (!snapshot || typeof snapshot !== 'object') return null;
    var projects = Array.isArray(snapshot.projects) ? snapshot.projects : [];
    var p = null;
    for (var i = 0; i < projects.length; i++) {
      if (projects[i] && projects[i].project_ref === ref) { p = projects[i]; break; }
    }
    if (!p) return null;
    var bm = (p.blueprint_meta && typeof p.blueprint_meta === 'object') ? p.blueprint_meta : null;
    return {
      active_domains: bm && Array.isArray(bm.active_domains) ? bm.active_domains : [],
      activity: (p.activity && typeof p.activity === 'object') ? p.activity : null
    };
  }

  function renderBlueprint(record) {
    // Internals toggle (§4) opens EVERY top-level domain at once; the In-flight
    // toggle gates whether the best-effort overlay lights the map.
    var opened = Object.keys(bpOpened);
    if (bpToggles.components) opened = opened.concat(bpTopLevelContainerIds(record));
    var useOverlay = bpToggles.inflight && bpOverlay;
    var view = BlueprintView.deriveBlueprintView(record, Date.now(), {
      opened: opened,
      focus: bpFocus || undefined,
      active_domains: useOverlay ? bpOverlay.active_domains : undefined,
      activity: useOverlay ? bpOverlay.activity : undefined
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

    // Empty state: no record, or a record with zero nodes (honest, B.4). Hide the
    // whole map section (label + viewport) so the empty box stands alone.
    var isEmpty = !view.found || view.empty;
    Dom.el('bp-emptybox').hidden = !isEmpty;
    var mapSec = Dom.el('bp-map-sec');
    if (mapSec) mapSec.hidden = isEmpty;

    renderBlueprintFocusBanner(view);
    renderBlueprintNarrative(view.narrative);
    renderBlueprintConflicts(record);
    renderBlueprintMap(view);
    renderBlueprintHidden(view);
    renderBlueprintDegraded(view.degraded);
    applyFocusViewport(view);

    var updated = Dom.el('bp-updated');
    if (updated) {
      var age = view.updated_at_age ? (' · updated ' + view.updated_at_age) : '';
      updated.textContent = 'read ' + new Date().toLocaleTimeString() + age;
    }
  }

  // ── §8.4 focus banner — say what a ?focus deep-link resolved to (or didn't) ──
  // The CONTRACT is that the route resolves: a focus id present in the map says
  // "focused on X"; a focus id the map doesn't know says so honestly and shows the
  // whole map (never a 404, never a fabricated node). No focus param ⇒ hidden.
  function renderBlueprintFocusBanner(view) {
    var el = Dom.el('bp-focus-banner');
    if (!el) return;
    Dom.clear(el);
    if (!bpFocus) { el.hidden = true; return; }
    el.hidden = false;
    if (view.focus) {
      el.className = 'bp-focus-banner';
      el.appendChild(document.createTextNode('Focused on '));
      el.appendChild(Dom.mk('code', 'bp-focus-id', view.focus));
      el.appendChild(document.createTextNode(' — the map is opened to it. '));
      // STEP OUT (§3.4.4): 'back to system' clears the focus — the focus-opened
      // boxes auto-collapse, manual/pinned drill-ins survive, the whole map re-fits.
      var back = Dom.mk('button', 'bp-focus-back', '← Back to system');
      back.setAttribute('type', 'button');
      back.addEventListener('click', clearFocus);
      el.appendChild(back);
    } else {
      // Resolved the ROUTE, but the id isn't in this map (stale link / hidden /
      // renamed-away). Honest, never a throw — show the full map.
      el.className = 'bp-focus-banner bp-focus-miss';
      el.appendChild(document.createTextNode('The link pointed at '));
      el.appendChild(Dom.mk('code', 'bp-focus-id', bpFocus));
      el.appendChild(document.createTextNode(
        ', which isn’t in this map (it may be stale or hidden) — showing the whole map.'));
    }
  }

  // ── §8.3 narrative render — TL;DR → section headings/prose, ABOVE the map ─────
  // The pure view-model already expanded acronyms on first use and tolerated a
  // missing/garbled narrative (present:false). This is paint-only: textContent
  // (never innerHTML — XSS-safe by construction). Hidden when no narrative.
  function renderBlueprintNarrative(narrative) {
    var sec = Dom.el('bp-narrative');
    if (!sec) return;
    Dom.clear(sec);
    var n = narrative || {};
    if (!n.present) { sec.hidden = true; return; }
    sec.hidden = false;
    if (n.tldr) {
      var tl = Dom.mk('div', 'bp-tldr');
      tl.appendChild(Dom.mk('span', 'bp-tldr-k', 'TL;DR'));
      tl.appendChild(Dom.mk('span', 'bp-tldr-v', n.tldr));
      sec.appendChild(tl);
    }
    (Array.isArray(n.sections) ? n.sections : []).forEach(function (s) {
      var blk = Dom.mk('div', 'bp-narr-sec');
      if (s.heading) blk.appendChild(Dom.mk('h3', 'bp-narr-h', s.heading));
      if (s.prose) blk.appendChild(Dom.mk('p', 'bp-narr-p', s.prose));
      sec.appendChild(blk);
    });
  }

  // ── focus viewport (§3.4.4 zoom-to-fit + back-to-system) ─────────────────────
  // Apply the viewport move a focus CHANGE asks for, exactly once per change (a 30s
  // refresh sets neither flag, so it never yanks the viewport):
  //   • bpFocusDirty (a deep-link landed, or a tap focused a box) → ZOOM-TO-FIT on
  //     the focus node. Its grown layout rect already contains its open descendants
  //     (the grow-to-fit contract), so fitting that rect frames the focused subtree.
  //   • bpRefitDirty ('back to system' / Esc cleared the focus) → re-fit the whole
  //     world (zoom back out to the system view).
  function applyFocusViewport(view) {
    if (bpFocusDirty && view.focus && bpFitToFocus(view)) {
      bpFocusDirty = false; bpRefitDirty = false;
      return;
    }
    if (bpRefitDirty) {
      bpFit(bpView.worldW, bpView.worldH);
      applyBpWorldTransform();
    }
    bpFocusDirty = false; bpRefitDirty = false;
  }

  // Zoom-to-fit on the focus node's (origin-offset) world rect. The box is placed by
  // a transform on #bp-world inside an overflow:hidden viewport, so we set the world
  // pan+zoom directly (jsdom: clientWidth/Height fall back to a sane viewport).
  function bpFitToFocus(view) {
    var target = null;
    view.nodes.forEach(function (n) { if (n.id === view.focus && n.layout) target = n.layout; });
    if (!target) return false;
    var ox = bpView.originX || 0, oy = bpView.originY || 0;
    bpFitRect(target.x + ox, target.y + oy, target.w, target.h);
    applyBpWorldTransform();
    return true;
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

  /* ════════════════════════════════════════════════════════════════════════════
   * THE SHARED RENDER CONTRACT  (bpmap-1, claude-tools-bpmap1)
   * bpmap-2 (edges + API boundary boxes) and bpmap-3 (focus/dim/drill) BIND to the
   * three facts below — they read this committed code, not a parallel renderer.
   *
   * (1) WORLD COORDINATE SPACE. Units = the H2 model's layout px. Every visible
   *     node carries `n.layout = {x, y, w, h}` (deriveBlueprintView → layoutGrowToFit
   *     / place[id]); coordinates are absolute and ALREADY nested — a child's
   *     {x,y} falls inside its open parent's rect (grow-to-fit), so a box that
   *     contains children literally contains them in world space. Origin (0,0) is
   *     the top-left of the top-left root box; +x → right, +y → down. The world
   *     EXTENT is max(x+w) × max(y+h) over the visible nodes.
   *
   * (2) PAN + ZOOM — ONE transformed container. A single `#bp-world` div
   *     (transform-origin 0 0) carries `translate(panX,panY) scale(zoom)`
   *     (panX/panY in viewport px, zoom unitless — bpView). `#bp-map` is the
   *     viewport and CLIPS (overflow:hidden). Drag pans, wheel/pinch/± zoom
   *     (wheel + pinch are cursor/centroid-anchored). The transform lives on the
   *     world ONLY — never on a node — so a node's style.left/top stays pure world
   *     px and bpmap-2 can place an edge endpoint straight from `n.layout`.
   *
   * (3) LAYERING. `#bp-world` holds TWO sibling layers in the SAME transformed
   *     space, so edges and boxes pan/zoom together and align:
   *        #bp-edge-layer  — an <svg> (world-sized, pointer-events:none) UNDER the
   *                          boxes. bpmap-2 appends resolved/bundled edge <path>s
   *                          here using each node's `n.layout` for endpoints.
   *        #bp-box-layer   — the absolutely-positioned `.bp-node` boxes, OVER the
   *                          edges (appended after the svg). Boxes are appended
   *                          shallow→deep so a child paints over its parent.
   * ════════════════════════════════════════════════════════════════════════════ */
  function renderBlueprintMap(view) {
    var mapHost = Dom.el('bp-map');
    Dom.clear(mapHost);
    if (!view.nodes.length) return;

    var byId = Object.create(null);
    view.nodes.forEach(function (n) { byId[n.id] = n; });
    bpPal = bpAssignPalette(view);   // per-domain hue map for this paint (§15.1)

    // Visible, laid-out nodes only — sorted shallow→deep so a child box is
    // appended AFTER (and therefore paints OVER) its parent.
    var vis = view.nodes.filter(function (n) { return n.visible && n.layout; });
    vis.sort(function (a, b) { return (a.depth || 0) - (b.depth || 0); });

    // §7 API box rects — precomputed (pure) so the world-extent below can include a
    // left-most domain's box straddling into x<0 (out=caller side). bpmap-1 nodes
    // start at origin (0,0); an api overhang is the only source of a negative coord.
    var apiRects = bpApiRects(view, byId);

    // World extent over BOTH the boxes AND the api boundary boxes. nodes pack from
    // (0,0), so minX/minY are 0 unless an api straddles past the origin; maxX/maxY
    // grow for an api hanging right/below. originX/Y shift everything non-negative so
    // nothing is clipped or outside the SVG viewBox; worldW/H is what fit reads.
    var minX = 0, minY = 0, maxX = 1, maxY = 1;
    vis.forEach(function (n) {
      var L = n.layout;
      if (L.x + L.w > maxX) maxX = L.x + L.w;
      if (L.y + L.h > maxY) maxY = L.y + L.h;
    });
    apiRects.forEach(function (r) {
      if (r.rect.x < minX) minX = r.rect.x;
      if (r.rect.y < minY) minY = r.rect.y;
      if (r.rect.x + r.rect.w > maxX) maxX = r.rect.x + r.rect.w;
      if (r.rect.y + r.rect.h > maxY) maxY = r.rect.y + r.rect.h;
    });
    var worldW = maxX - minX, worldH = maxY - minY;
    var originX = -minX, originY = -minY;   // ≥0; 0 in the common (no-overhang) case
    bpView.worldW = worldW; bpView.worldH = worldH;
    bpView.originX = originX; bpView.originY = originY;

    // The ONE transformed world (pan+zoom applied here, nowhere else).
    var world = Dom.mk('div', 'bp-world');
    world.id = 'bp-world';

    // Edge layer (bpmap-2 draws here) — UNDER the boxes, same world coords. Its
    // viewBox origin = (minX,minY), so a path drawn at TRUE n.layout coords lands at
    // the same world pixel as the origin-shifted box layer below (they stay aligned).
    var svg = document.createElementNS(SVG_NS, 'svg');
    svg.setAttribute('id', 'bp-edge-layer');
    svg.setAttribute('width', String(worldW));
    svg.setAttribute('height', String(worldH));
    svg.setAttribute('viewBox', minX + ' ' + minY + ' ' + worldW + ' ' + worldH);
    svg.appendChild(bpArrowDefs());           // <defs> arrowheads (edge + api), once
    world.appendChild(svg);

    // Box layer — the positioned node boxes, OVER the edges. Shifted by the origin
    // offset so a node's style.left stays PURE world px (n.layout.x, the bpmap-1
    // contract) while an api box straddling past x=0 still renders on-canvas.
    var boxLayer = Dom.mk('div', 'bp-box-layer');
    boxLayer.id = 'bp-box-layer';
    boxLayer.style.left = originX + 'px';
    boxLayer.style.top = originY + 'px';
    boxLayer.style.width = worldW + 'px';
    boxLayer.style.height = worldH + 'px';
    vis.forEach(function (n) { boxLayer.appendChild(renderBlueprintNode(n, byId)); });

    // bpmap-2: draw the model's resolved/bundled edges into the SVG, plus the §7
    // API boundary boxes straddling each domain's border (+ an open-domain arrow to
    // the capability the route targets). BOTH consume n.layout in the SAME world, so
    // they align with the boxes — THE SHARED RENDER CONTRACT, layer (3). The model
    // already did the deepest-visible resolution + bundling + density: we just DRAW.
    renderBlueprintEdges(view, svg, byId);
    renderBlueprintApis(svg, boxLayer, byId, apiRects);
    applyBpLabelVisibility();

    world.appendChild(boxLayer);

    mapHost.appendChild(world);

    // Overlays — NOT in the transformed world (fixed in the viewport corners):
    // the detail/toggle panel (top-left), the minimap (top-right), the legend
    // (bottom-left), and the zoom controls (bottom-right).
    mapHost.appendChild(buildBpDetailPanel());
    mapHost.appendChild(buildBpMiniMap(view));
    mapHost.appendChild(buildBpLegend(view));
    mapHost.appendChild(buildBpZoomControls());

    // AUTO-FRAME the whole world on every paint UNTIL the user takes control
    // (pans/zooms) — this self-corrects as the facet's viewport settles its size
    // (the §17 #8 race) and a ResizeObserver (attachBpPanZoom) catches the 0→real
    // resize. A focus owns its own framing (applyFocusViewport), so skip then.
    if (!bpUserMovedView && !bpFocus) bpFit(worldW, worldH);
    applyBpWorldTransform();
  }

  // A positioned node box: absolutely placed at its world layout{x,y,w,h}. A
  // container (open + has visible children) grows to fit (the model sized it); its
  // children are SEPARATE positioned boxes painted over its body. A collapsed node
  // is a compact card. The .bp-node / .bp-focus / .bp-dim / .bp-active /
  // .bp-collision / .bp-kind-* classes are preserved (H3/H4 + the overlay bind to
  // them); marginLeft is GONE (the old indented-list signature the regression test
  // forbids). bpmap-3 INTERACTIONS: tap the box body = FOCUS it (zoom-to-fit + dim
  // the unconnected); the ▸ caret = PEEK (manual drill, no zoom); the ⋯ button =
  // open the per-node EDIT menu folded onto the box (rename/regroup/pin/hide).
  // strip a trailing "(parenthetical)" and trim — a tighter label for a card sub.
  function bpShortLabel(label) {
    return String(label || '').replace(/\s*\([^)]*\)\s*$/, '').trim();
  }
  // append the renamed/regrouped/pin badges to a name/title element.
  function bpAppendBadges(el, n) {
    if (n.renamed) el.appendChild(Dom.mk('span', 'bp-badge', 'renamed'));
    if (n.regrouped) el.appendChild(Dom.mk('span', 'bp-badge', 'regrouped'));
    if (n.pinned) el.appendChild(Dom.mk('span', 'bp-badge bp-badge-pin', '📌'));
  }
  // the ▸/▾ drill caret (collapse when open) — no zoom.
  function bpCaretBtn(n) {
    var caret = Dom.mk('button', 'bp-caret', n.open ? '▾' : '▸');
    caret.setAttribute('type', 'button');
    caret.setAttribute('aria-label', (n.open ? 'collapse ' : 'drill into ') + n.label);
    caret.addEventListener('click', function (e) {
      e.stopPropagation(); if (bpJustPanned) return; toggleOpen(n.id);
    });
    return caret;
  }
  // the ⋯ edit-menu button (opens the on-box H4 popover via selectNode).
  function bpMenuBtn(n) {
    var menu = Dom.mk('button', 'bp-node-menu', '⋯');
    menu.setAttribute('type', 'button');
    menu.setAttribute('aria-label', 'edit ' + n.label);
    menu.addEventListener('click', function (e) {
      e.stopPropagation(); if (bpJustPanned) return; selectNode(n.id);
    });
    return menu;
  }
  // a closed domain's sub-line — the first few capability names inside it (the
  // reference "create · feed · reactions" caption). Empty if it has no children.
  function bpDomainSub(n, byId) {
    var kids = (n.children || []).filter(function (id) { return byId[id] && byId[id].visible !== false; });
    if (!kids.length) return '';
    var names = kids.slice(0, 3).map(function (id) { return bpShortLabel(byId[id].label); })
      .filter(function (s) { return !!s; });
    var more = kids.length - names.length;
    return names.join('  ·  ') + (more > 0 ? '  · +' + more : '');
  }

  // A positioned node box, absolutely placed at its world layout{x,y,w,h}, in one of
  // three render modes: a CLOSED top-level CARD (big title + capability sub + a parts
  // pill — the macro readable unit), an OPEN container (a colored header bar; its
  // children paint as separate boxes over its body), or a capability LEAF (compact
  // label). Each box sets the §15.1 --bp-fill/border/ink palette vars. INTERACTIONS:
  // tap the body = FOCUS (zoom-to-fit + dim the unconnected); the ▸ caret / pill =
  // PEEK (drill, no zoom); the ⋯ button = the on-box H4 EDIT menu.
  function renderBlueprintNode(n, byId) {
    var kids = (n.children || []).filter(function (id) { return byId[id] && byId[id].visible; });
    var isOpen = n.open && kids.length > 0;
    var isTop = !!n.top_level;
    var cls = 'bp-node bp-kind-' + (n.kind_known ? n.kind : 'unknown');
    if (isOpen) cls += ' bp-open';
    else if (isTop) cls += ' bp-card';
    else cls += ' bp-leaf';
    if (n.dimmed) cls += ' bp-dim';
    if (n.active) cls += ' bp-active';
    if (n.collision) cls += ' bp-collision';
    if (n.focused_self) cls += ' bp-focus';
    if (n.id === bpSelected) cls += ' bp-menu-open'; // the box whose ⋯ editor is open
    var card = Dom.mk('div', cls);
    card.setAttribute('data-id', n.id);

    var L = n.layout || { x: 0, y: 0, w: 120, h: 56 };
    card.style.position = 'absolute';
    card.style.left = L.x + 'px';
    card.style.top = L.y + 'px';
    card.style.width = L.w + 'px';
    card.style.height = L.h + 'px';

    var pal = bpPal[n.id] || BP_PAL_FALLBACK;
    card.style.setProperty('--bp-fill', pal.fill);
    card.style.setProperty('--bp-border', pal.border);
    card.style.setProperty('--bp-ink', pal.ink);

    if (isOpen) {
      // OPEN container: a colored header bar (caret · name · count · ⋯). Children
      // render as their own positioned boxes over the (transparent) body.
      var head = Dom.mk('div', 'bp-node-head');
      head.appendChild(bpCaretBtn(n));
      var nameEl = Dom.mk('span', 'bp-name', n.label);
      bpAppendBadges(nameEl, n);
      head.appendChild(nameEl);
      head.appendChild(Dom.mk('span', 'bp-count', String(kids.length)));
      head.appendChild(bpMenuBtn(n));
      card.appendChild(head);
    } else if (isTop) {
      // CLOSED top-level CARD: ⋯ in the corner, a big centered title + capability
      // sub, and a "N parts" pill that drills in (the reference look).
      card.appendChild(bpMenuBtn(n));
      var body = Dom.mk('div', 'bp-card-body');
      var title = Dom.mk('div', 'bp-card-title', n.label);
      bpAppendBadges(title, n);
      body.appendChild(title);
      var sub = bpDomainSub(n, byId);
      if (sub) body.appendChild(Dom.mk('div', 'bp-card-sub', sub));
      card.appendChild(body);
      if (kids.length) {
        var pill = Dom.mk('button', 'bp-card-pill', String(kids.length) + ' parts');
        pill.setAttribute('type', 'button');
        pill.setAttribute('aria-label', 'drill into ' + n.label);
        pill.addEventListener('click', function (e) {
          e.stopPropagation(); if (bpJustPanned) return; toggleOpen(n.id);
        });
        card.appendChild(pill);
      }
    } else {
      // capability LEAF: compact label (+ a caret if it nests) + ⋯.
      var lhead = Dom.mk('div', 'bp-node-head');
      if (kids.length) lhead.appendChild(bpCaretBtn(n));
      var lname = Dom.mk('span', 'bp-name', n.label);
      bpAppendBadges(lname, n);
      lhead.appendChild(lname);
      lhead.appendChild(bpMenuBtn(n));
      card.appendChild(lhead);
    }

    // The H4 edit affordances FOLDED ONTO THE BOX (bpmap-3): when this is the
    // selected node, its ⋯ editor is an on-box popover (NOT the old flat panel
    // below the canvas). It lives inside the card so it pans/zooms glued to the box.
    if (n.id === bpSelected) card.appendChild(buildNodeMenu(n));

    // Tap the box body = FOCUS this node (the model opens it + its ancestors and
    // dims the unconnected; applyFocusViewport zooms-to-fit). A drag that ended here
    // (bpJustPanned) is a pan, not a tap — ignore it.
    card.addEventListener('click', function () {
      if (bpJustPanned) return;
      toggleFocus(n.id);
    });
    return card;
  }

  /* ════════════════════════════════════════════════════════════════════════════
   * bpmap-2 — EDGES + API BOUNDARY BOXES (claude-tools-bpmap2; design §3.2/§3.3, §6/§7)
   * Drawn into the SHARED transformed world bpmap-1 owns: edges + api-arrows go in
   * the SVG #bp-edge-layer (under the boxes), api boxes go in the box layer (over).
   * The H2 model (blueprint-view.js) ALREADY resolved every edge to its deepest
   * VISIBLE ancestor, bundled duplicates, and applied the density rule (macro =
   * domain↔domain only; focused = touching-subtree only). We do NOT re-resolve — we
   * DRAW view.edges / view.apis as given, keyed off each endpoint's n.layout.
   * ════════════════════════════════════════════════════════════════════════════ */
  function svgEl(tag, attrs) {
    var e = document.createElementNS(SVG_NS, tag);
    if (attrs) Object.keys(attrs).forEach(function (k) { e.setAttribute(k, attrs[k]); });
    return e;
  }

  // One <defs> per svg: the two arrowheads (edge = slate, api = sky). markerUnits
  // defaults to strokeWidth so the head scales with the line (and so with zoom).
  function bpArrowDefs() {
    var defs = svgEl('defs');
    // The edge arrowhead uses fill:context-stroke so it inherits each path's
    // (per-source-domain) stroke color — the "traceable colored arrows" of the
    // reference. The api arrowhead keeps its class color.
    [['bp-arrow', 'bp-arrow-head', 'context-stroke'],
     ['bp-arrow-api', 'bp-arrow-head bp-arrow-head-api', 'context-stroke']]
      .forEach(function (t) {
        var m = svgEl('marker', {
          id: t[0], viewBox: '0 0 10 10', refX: '8.5', refY: '5',
          markerWidth: '7', markerHeight: '7', orient: 'auto-start-reverse'
        });
        var p = svgEl('path', { d: 'M0,0 L10,5 L0,10 z', 'class': t[1] });
        if (t[2]) p.setAttribute('fill', t[2]);
        m.appendChild(p);
        defs.appendChild(m);
      });
    return defs;
  }

  // The point on a box's border in the direction of (tx,ty) from its centre — so a
  // line starts/ends AT the box edge (the segment under a box is hidden, and the
  // arrowhead lands just outside the target box where it's visible).
  function bpBorderPoint(L, tx, ty) {
    var cx = L.x + L.w / 2, cy = L.y + L.h / 2;
    var dx = tx - cx, dy = ty - cy;
    if (dx === 0 && dy === 0) return { x: cx, y: cy };
    var sx = dx !== 0 ? (L.w / 2) / Math.abs(dx) : Infinity;
    var sy = dy !== 0 ? (L.h / 2) / Math.abs(dy) : Infinity;
    var s = Math.min(sx, sy);
    return { x: cx + dx * s, y: cy + dy * s };
  }

  // A gently-bowed quadratic between two border points: the control point is offset
  // perpendicular to the segment. Direction-dependent, so a from→to bundle and its
  // to→from reply (kept distinct by the directional bundle_key) bow apart instead of
  // overlapping. Returns {d, mid:{x,y}} (mid = the on-curve point for the label).
  function bpCurve(p1, p2) {
    var mx = (p1.x + p2.x) / 2, my = (p1.y + p2.y) / 2;
    var dx = p2.x - p1.x, dy = p2.y - p1.y;
    var len = Math.sqrt(dx * dx + dy * dy) || 1;
    var bow = Math.min(len * 0.14, 46);
    var cx = mx + (-dy / len) * bow, cy = my + (dx / len) * bow;
    // on-curve midpoint of the quadratic at t=0.5: 0.25·p1 + 0.5·ctrl + 0.25·p2
    var midX = 0.25 * p1.x + 0.5 * cx + 0.25 * p2.x;
    var midY = 0.25 * p1.y + 0.5 * cy + 0.25 * p2.y;
    return {
      d: 'M' + p1.x + ',' + p1.y + ' Q' + cx + ',' + cy + ' ' + p2.x + ',' + p2.y,
      mid: { x: midX, y: midY }
    };
  }

  // Draw view.edges (already resolved/bundled/density-filtered by H2) as curved SVG
  // paths between the two visible boxes. kind=queue is the ASYNC edge → dashed + a
  // label (the via/queue mechanism); every edge carries a toggleable kind label,
  // bundled edges (count>1) annotated ·N. Endpoints come straight from n.layout.
  function renderBlueprintEdges(view, svg, byId) {
    (view.edges || []).forEach(function (e) {
      var fromN = byId[e.from], toN = byId[e.to];
      if (!fromN || !toN || !fromN.layout || !toN.layout) return;  // resolved to a hidden box — skip
      var fL = fromN.layout, tL = toN.layout;
      var fc = { x: fL.x + fL.w / 2, y: fL.y + fL.h / 2 };
      var tc = { x: tL.x + tL.w / 2, y: tL.y + tL.h / 2 };
      var p1 = bpBorderPoint(fL, tc.x, tc.y);
      var p2 = bpBorderPoint(tL, fc.x, fc.y);
      var curve = bpCurve(p1, p2);
      var isAsync = (e.kind === 'queue');
      var cls = 'bp-edge bp-edge-' + (e.kind || 'call') + (isAsync ? ' bp-edge-async' : '');
      var fromPal = bpPal[e.from] || BP_PAL_FALLBACK;   // color the arrow by its source domain
      var path = svgEl('path', { 'class': cls, d: curve.d, 'marker-end': 'url(#bp-arrow)' });
      path.setAttribute('stroke', fromPal.border);
      svg.appendChild(path);
      // the via/queue name as label (edge labels toggle). No queue NAME lives in the
      // §3.2 schema (from/to/kind/bundle_key), so the kind is the via descriptor; a
      // bundle of N collapsed duplicates is annotated ·N.
      var lbl = (e.kind || 'call') + (e.count > 1 ? ' ·' + e.count : '');
      var t = svgEl('text', {
        'class': 'bp-edge-label', x: curve.mid.x, y: curve.mid.y,
        'text-anchor': 'middle', dy: '-3'
      });
      t.textContent = lbl;
      svg.appendChild(t);
    });
  }

  // §7 API boundary boxes — the world rect each VISIBLE route occupies: a small box
  // straddling its domain's LEFT border (out = caller side / left of x=L.x, in = the
  // domain / right of it), boxes for one domain stacked down the border. PURE (no
  // DOM) so the world-extent pre-pass and the renderer agree: a left-most domain
  // (x=0) straddles into x<0, and the world must size to include that overhang.
  function bpApiRects(view, byId) {
    var perDomain = Object.create(null), out = [];
    (view.apis || []).forEach(function (api) {
      if (!api.visible) return;
      var d = byId[api.domain];
      if (!d || !d.layout) return;
      if (!bpShowApisFor(d)) return;   // §4 APIs toggle / focus gates the draw
      var L = d.layout;
      var idx = perDomain[api.domain] || 0;
      perDomain[api.domain] = idx + 1;
      out.push({
        api: api, domain: d,
        rect: {
          x: L.x - BP_API_W / 2, y: L.y + 8 + idx * (BP_API_H + BP_API_GAP),
          w: BP_API_W, h: BP_API_H
        }
      });
    });
    return out;
  }

  // Draw the §7 boundary boxes (precomputed rects) into the box layer, and — when
  // the domain is OPEN — an arrow from each box to the visible internal capability
  // the route targets (api.calls). Boxes → box layer (over the boxes); arrows → SVG.
  // Box rect coords are in TRUE world px (n.layout space); the box layer's origin
  // offset (renderBlueprintMap) maps a negative-x straddle back into the world.
  function renderBlueprintApis(svg, boxLayer, byId, apiRects) {
    apiRects.forEach(function (r) {
      var api = r.api, d = r.domain, rect = r.rect;
      var dp = bpPal[api.domain] || BP_PAL_FALLBACK;   // tint the box to its domain
      var box = Dom.mk('div', 'bp-api');
      box.setAttribute('data-id', api.id);
      box.setAttribute('data-domain', api.domain);
      box.style.position = 'absolute';
      box.style.left = rect.x + 'px';
      box.style.top = rect.y + 'px';
      box.style.width = rect.w + 'px';
      box.style.height = rect.h + 'px';
      box.style.setProperty('--bp-border', dp.border);
      box.style.setProperty('--bp-ink', dp.border);
      box.title = api.route_label + '  →  ' + api.domain;
      box.appendChild(Dom.mk('span', 'bp-api-label', api.route_label));
      boxLayer.appendChild(box);

      // open domain ⇒ arrow from the box to each visible target capability (§7).
      if (!d.open) return;
      (api.calls || []).forEach(function (cid) {
        var c = byId[cid];
        if (!c || !c.visible || !c.layout) return;
        var cc = { x: c.layout.x + c.layout.w / 2, y: c.layout.y + c.layout.h / 2 };
        var ar = { x: rect.x + rect.w / 2, y: rect.y + rect.h / 2 };
        var p1 = bpBorderPoint(rect, cc.x, cc.y);
        var p2 = bpBorderPoint(c.layout, ar.x, ar.y);
        var arrow = svgEl('path', {
          'class': 'bp-api-arrow', d: bpCurve(p1, p2).d, 'marker-end': 'url(#bp-arrow-api)'
        });
        arrow.setAttribute('stroke', dp.border);
        svg.appendChild(arrow);
      });
    });
  }

  // Edge labels toggle (bpView.labelsHidden) → a class on the edge layer; CSS hides
  // .bp-edge-label. Re-applied on every paint so the choice survives refresh + drill.
  function applyBpLabelVisibility() {
    var svg = Dom.el('bp-edge-layer');
    if (!svg) return;
    svg.classList.toggle('bp-hide-labels', bpView.labelsHidden);
  }

  // ── the detail/toggle panel (top-left) — global progressive disclosure (§4) ───
  // The Diagrammer reference's DETAIL card: switches to globally reveal a class of
  // detail at once — APIs (boundary boxes), Internals (open every domain), Edge
  // labels, and the In-flight overlay. Each flips a bpToggles/bpView flag and
  // re-renders (the map preserves pan/zoom across a re-render). The panel rebuilds
  // each paint; bpPanelCollapsed persists its collapsed state.
  function bpToggleRow(label, hint, isOn, setOn) {
    var row = Dom.mk('div', 'bp-tog-row');
    var sw = Dom.mk('button', 'bp-switch' + (isOn ? ' on' : ''));
    sw.setAttribute('type', 'button');
    sw.setAttribute('role', 'switch');
    sw.setAttribute('aria-checked', isOn ? 'true' : 'false');
    sw.setAttribute('aria-label', label);
    sw.appendChild(Dom.mk('span', 'bp-switch-knob'));
    sw.addEventListener('click', function (e) { e.stopPropagation(); setOn(!isOn); });
    row.appendChild(sw);
    var txt = Dom.mk('div', 'bp-tog-txt');
    txt.appendChild(Dom.mk('div', 'bp-tog-label', label));
    if (hint) txt.appendChild(Dom.mk('div', 'bp-tog-hint', hint));
    row.appendChild(txt);
    return row;
  }

  function buildBpDetailPanel() {
    var panel = Dom.mk('div', 'bp-panel' + (bpPanelCollapsed ? ' bp-panel-collapsed' : ''));
    var head = Dom.mk('div', 'bp-panel-head');
    head.appendChild(Dom.mk('span', 'bp-panel-title', 'DETAIL'));
    var col = Dom.mk('button', 'bp-panel-collapse', bpPanelCollapsed ? '+' : '×');
    col.setAttribute('type', 'button');
    col.setAttribute('aria-label', bpPanelCollapsed ? 'expand detail panel' : 'collapse detail panel');
    col.addEventListener('click', function (e) {
      e.stopPropagation();
      bpPanelCollapsed = !bpPanelCollapsed;
      if (bpRecord !== undefined) renderBlueprint(bpRecord);
    });
    head.appendChild(col);
    panel.appendChild(head);

    var bodyT = Dom.mk('div', 'bp-panel-body');
    bodyT.appendChild(bpToggleRow('APIs', 'entry points on each domain',
      bpToggles.apis, function (v) { bpToggles.apis = v; renderBlueprint(bpRecord); bpReframeAfterToggle(); }));
    bodyT.appendChild(bpToggleRow('Internals', 'services inside each domain',
      bpToggles.components, function (v) { bpToggles.components = v; renderBlueprint(bpRecord); bpReframeAfterToggle(); }));
    bodyT.appendChild(bpToggleRow('Edge labels', 'how things connect',
      !bpView.labelsHidden, function (v) { bpView.labelsHidden = !v; renderBlueprint(bpRecord); }));
    bodyT.appendChild(bpToggleRow('In-flight overlay', 'where the swarm is working',
      bpToggles.inflight, function (v) { bpToggles.inflight = v; renderBlueprint(bpRecord); }));
    panel.appendChild(bodyT);
    return panel;
  }

  // ── the minimap (top-right) — the whole world in miniature + a viewport box ───
  function buildBpMiniMap(view) {
    var W = bpView.worldW || 1, H = bpView.worldH || 1;
    var BOX = 150;
    var s = Math.min(BOX / W, BOX / H, 0.5);
    bpMini.s = s; bpMini.W = W; bpMini.H = H;
    var mm = Dom.mk('div', 'bp-minimap');
    var inner = Dom.mk('div', 'bp-minimap-inner');
    inner.id = 'bp-minimap-inner';
    inner.style.width = (W * s) + 'px';
    inner.style.height = (H * s) + 'px';
    var ox = bpView.originX || 0, oy = bpView.originY || 0;
    view.nodes.forEach(function (n) {
      if (!n.visible || !n.layout || !n.top_level) return;
      var pal = bpPal[n.id] || BP_PAL_FALLBACK;
      var cell = Dom.mk('div', 'bp-mm-cell' + (n.active ? ' on' : ''));
      cell.style.left = ((ox + n.layout.x) * s) + 'px';
      cell.style.top = ((oy + n.layout.y) * s) + 'px';
      cell.style.width = Math.max(4, n.layout.w * s) + 'px';
      cell.style.height = Math.max(4, n.layout.h * s) + 'px';
      cell.style.background = pal.fill;
      cell.style.borderColor = pal.border;
      inner.appendChild(cell);
    });
    var vp = Dom.mk('div', 'bp-mm-view');
    vp.id = 'bp-mm-view';
    inner.appendChild(vp);
    inner.addEventListener('click', function (e) {
      var r = inner.getBoundingClientRect();
      bpCenterOn((e.clientX - r.left) / s, (e.clientY - r.top) / s);
    });
    mm.appendChild(inner);
    bpUpdateMiniViewport();
    return mm;
  }

  // Move the world so (localX,localY) — a point in #bp-world local coords — is centred.
  function bpCenterOn(localX, localY) {
    bpUserMovedView = true;            // recentering via the minimap = user control
    var map = Dom.el('bp-map');
    var vw = (map && map.clientWidth) || 800, vh = (map && map.clientHeight) || 480;
    bpView.panX = vw / 2 - localX * bpView.zoom;
    bpView.panY = vh / 2 - localY * bpView.zoom;
    applyBpWorldTransform();
  }

  // Position the minimap's viewport rectangle from the current pan/zoom.
  function bpUpdateMiniViewport() {
    var vp = Dom.el('bp-mm-view');
    if (!vp || !bpMini.s) return;
    var map = Dom.el('bp-map');
    var vw = (map && map.clientWidth) || 800, vh = (map && map.clientHeight) || 480;
    var s = bpMini.s, z = bpView.zoom || 1;
    var left = (-bpView.panX / z) * s, top = (-bpView.panY / z) * s;
    var w = (vw / z) * s, h = (vh / z) * s;
    vp.style.left = left + 'px'; vp.style.top = top + 'px';
    vp.style.width = w + 'px'; vp.style.height = h + 'px';
  }

  // ── the legend + zoom controls (viewport overlays, NOT transformed) ──────────
  function buildBpLegend(view) {
    var legend = Dom.mk('div', 'bp-legend');
    legend.appendChild(Dom.mk('span', null,
      view.counts.top_level + ' top-level · ' + view.counts.nodes + ' nodes · ' +
      view.counts.edges + ' edges'));
    if (view.counts.hidden) legend.appendChild(Dom.mk('span', 'bp-legend-hidden',
      view.counts.hidden + ' hidden'));
    // §6.4/§8.2 in-flight overlay (G5 wiring): lit/collision counts when the
    // work-snapshot reported worked domains. Silent (dark) when nothing active.
    if (view.counts.active) legend.appendChild(Dom.mk('span', 'bp-legend-active',
      view.counts.active + ' in flight'));
    if (view.counts.collisions) legend.appendChild(Dom.mk('span', 'bp-legend-collision',
      view.counts.collisions + ' collision' + (view.counts.collisions === 1 ? '' : 's')));
    return legend;
  }

  function buildBpZoomControls() {
    var box = Dom.mk('div', 'bp-zoom');
    function zb(label, aria, handler) {
      var b = Dom.mk('button', 'bp-zoom-btn', label);
      b.setAttribute('type', 'button');
      b.setAttribute('aria-label', aria);
      b.addEventListener('click', function (e) { e.stopPropagation(); handler(); });
      box.appendChild(b);
    }
    zb('+', 'zoom in', function () { bpZoomBy(1.25); });
    zb('−', 'zoom out', function () { bpZoomBy(0.8); });
    zb('⤢', 'fit the whole map to view', function () {
      bpUserMovedView = true;          // an explicit fit is the user's choice — keep it
      bpFit(bpView.worldW, bpView.worldH);
      applyBpWorldTransform();
    });
    return box;
  }

  // ── pan/zoom math + transform (THE one transformed world) ────────────────────
  function applyBpWorldTransform() {
    var world = Dom.el('bp-world');
    if (!world) return;
    world.style.transform =
      'translate(' + bpView.panX + 'px,' + bpView.panY + 'px) scale(' + bpView.zoom + ')';
    bpUpdateMiniViewport();   // keep the minimap's viewport box in sync with pan/zoom
  }

  function bpClampZoom(z) {
    if (!isFinite(z)) return bpView.zoom;
    return Math.max(BP_MIN_ZOOM, Math.min(BP_MAX_ZOOM, z));
  }

  // Zoom about a viewport point (cx,cy), keeping the world point under it fixed
  // (cursor-anchored wheel / centroid-anchored pinch). pan' = c − worldPoint·zoom'.
  function bpZoomAt(cx, cy, factor) {
    var nz = bpClampZoom(bpView.zoom * factor);
    if (nz === bpView.zoom) return;
    bpUserMovedView = true;            // the user took control of the viewport
    var wx = (cx - bpView.panX) / bpView.zoom;
    var wy = (cy - bpView.panY) / bpView.zoom;
    bpView.panX = cx - wx * nz;
    bpView.panY = cy - wy * nz;
    bpView.zoom = nz;
    applyBpWorldTransform();
  }

  function bpZoomBy(factor) {
    var map = Dom.el('bp-map');
    var vw = (map && map.clientWidth) || 800;
    var vh = (map && map.clientHeight) || 480;
    bpZoomAt(vw / 2, vh / 2, factor);
  }

  // Fit the whole world into the viewport (centered, small margin). Sets bpView
  // pan/zoom; the caller applies the transform.
  function bpFit(w, h) { bpFitRect(0, 0, w, h); }

  // Fit an arbitrary world rect (x,y,w,h, world px incl. the origin offset) into the
  // viewport, centered with a small margin. The shared framing math for both the
  // whole-world fit (bpFit) and the §3.4.4 zoom-to-fit-on-focus (bpFitToFocus). Falls
  // back to a sane viewport size when clientWidth/Height are 0 (jsdom / pre-layout)
  // so the transform is always set.
  function bpFitRect(x, y, w, h) {
    var map = Dom.el('bp-map');
    var vw = (map && map.clientWidth) || 800;
    var vh = (map && map.clientHeight) || 480;
    // Reserve the chrome insets so the fit never tucks content under the detail
    // panel (top-left) or the minimap (top-right) — centre in the FREE region.
    var padL = (bpPanelCollapsed || vw < 620) ? 56 : 264;   // detail panel width + gap (responsive)
    var padR = 28, padT = 26, padB = 26;
    var availW = Math.max(80, vw - padL - padR);
    var availH = Math.max(80, vh - padT - padB);
    w = w || 1; h = h || 1;
    var z = Math.min(availW / w, availH / h, 1.4);
    z = bpClampZoom((isFinite(z) && z > 0) ? z : 1);
    bpView.zoom = z;
    bpView.panX = padL + availW / 2 - (x + w / 2) * z;   // centre in the free region
    bpView.panY = padT + availH / 2 - (y + h / 2) * z;
  }

  // Re-frame the whole world whenever it's safe to (user hasn't grabbed it, no
  // focus is being framed). Called by the ResizeObserver when the map settles size.
  function bpAutoReframe() {
    if (bpUserMovedView || bpFocus) return;
    bpFit(bpView.worldW, bpView.worldH);
    applyBpWorldTransform();
  }

  // A ONE-TIME re-frame after a toggle that changes the world EXTENT (Internals
  // opens every domain; APIs adds the left straddle). The user explicitly asked to
  // reveal a class of detail, so frame the new world even if they had panned — but
  // do NOT re-arm continuous auto-framing (leave bpUserMovedView alone), and never
  // override a focus (which owns its own viewport).
  function bpReframeAfterToggle() {
    if (bpFocus) return;
    bpFit(bpView.worldW, bpView.worldH);
    applyBpWorldTransform();
  }

  // ── pointer pan + pinch zoom (mouse + touch) ─────────────────────────────────
  function bpPointerDist() {
    var ids = Object.keys(bpPointers);
    if (ids.length < 2) return 0;
    var a = bpPointers[ids[0]], b = bpPointers[ids[1]];
    return Math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
  }
  function bpPointerMid() {
    var ids = Object.keys(bpPointers);
    var a = bpPointers[ids[0]], b = bpPointers[ids[1]];
    return { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
  }
  function bpViewportPos(e, map) {
    var r = map.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  }

  // Attached ONCE per facet mount: wheel + pointerdown on the viewport, the
  // pointer move/up/cancel on window (so a drag continues outside the box).
  function attachBpPanZoom(map) {
    // Re-fit when the map element settles its real size (0→full at mount, or a
    // window resize) — the bulletproof fix for the first-paint fit race (§17 #8).
    // Stops auto-framing the moment the user pans/zooms (bpAutoReframe guards).
    if (window.ResizeObserver) {
      if (bpResizeObs) bpResizeObs.disconnect();
      bpResizeObs = new window.ResizeObserver(function () { bpAutoReframe(); });
      bpResizeObs.observe(map);
    }
    map.addEventListener('wheel', function (e) {
      e.preventDefault();
      var p = bpViewportPos(e, map);
      bpZoomAt(p.x, p.y, Math.exp(-e.deltaY * 0.0015)); // smooth, cursor-anchored
    }, { passive: false });
    map.addEventListener('pointerdown', function (e) {
      bpJustPanned = false;
      var p = bpViewportPos(e, map);
      bpPointers[e.pointerId] = p;
      var n = Object.keys(bpPointers).length;
      if (n === 1) { bpPanLast = p; bpPanOrigin = p; bpPinchDist = 0; }
      else if (n === 2) { bpPanLast = null; bpPinchDist = bpPointerDist(); }
      map.classList.add('bp-panning');
    });
    if (!bpHandlersOn) {
      window.addEventListener('pointermove', bpOnPointerMove);
      window.addEventListener('pointerup', bpOnPointerUp);
      window.addEventListener('pointercancel', bpOnPointerUp);
      window.addEventListener('keydown', bpOnKeyDown); // Esc steps out (§3.4.4)
      bpHandlersOn = true;
    }
  }

  // Esc steps OUT, innermost-first: close an open ⋯ editor, else clear the focus
  // (back to system). Guarded to the blueprint facet (the map host must be present)
  // so the once-attached window listener is inert on other facets.
  function bpOnKeyDown(e) {
    if (e.key !== 'Escape') return;
    if (!Dom.el('bp-map')) return;
    if (bpSelected) { bpSelected = null; renderBlueprint(bpRecord); }
    else if (bpFocus) { clearFocus(); }
  }
  function bpOnPointerMove(e) {
    if (!(e.pointerId in bpPointers)) return;
    var map = Dom.el('bp-map');
    if (!map) return;
    var p = bpViewportPos(e, map);
    bpPointers[e.pointerId] = p;
    if (Object.keys(bpPointers).length >= 2) {
      var d = bpPointerDist();
      if (bpPinchDist > 0 && d > 0) {
        var m = bpPointerMid();
        bpZoomAt(m.x, m.y, d / bpPinchDist);
      }
      bpPinchDist = d;
      bpJustPanned = true;
    } else if (bpPanLast) {
      bpUserMovedView = true;          // a drag-pan = the user took control
      bpView.panX += p.x - bpPanLast.x;
      bpView.panY += p.y - bpPanLast.y;
      bpPanLast = p;
      if (bpPanOrigin &&
        (Math.abs(p.x - bpPanOrigin.x) > 4 || Math.abs(p.y - bpPanOrigin.y) > 4)) {
        bpJustPanned = true; // crossed the tap-vs-drag threshold → suppress the tap
      }
      applyBpWorldTransform();
    }
  }
  function bpOnPointerUp(e) {
    if (!(e.pointerId in bpPointers)) return;
    delete bpPointers[e.pointerId];
    var ids = Object.keys(bpPointers);
    if (ids.length === 1) {                       // pinch → single-finger pan
      bpPanLast = bpPointers[ids[0]]; bpPanOrigin = bpPanLast; bpPinchDist = 0;
    } else if (ids.length === 0) {
      bpPanLast = null; bpPanOrigin = null; bpPinchDist = 0;
      var map = Dom.el('bp-map');
      if (map) map.classList.remove('bp-panning');
    }
  }

  // ── focus / drill state transitions (§3.4.4) ─────────────────────────────────
  // FOCUS a node: the H2 model (re-derived with opts.focus) opens it + its ancestor
  // chain and dims everything not connected to it; applyFocusViewport zooms-to-fit on
  // the next paint (bpFocusDirty). Tapping the SAME focused box again steps out.
  function toggleFocus(id) {
    if (bpSelected) bpSelected = null;     // a navigation gesture closes any open editor
    if (bpFocus === id) { clearFocus(); return; }
    bpFocus = id;
    bpFocusDirty = true;
    if (bpRecord !== undefined) renderBlueprint(bpRecord);
  }
  // STEP OUT (back to system / Esc / tap-again): clear the focus. The focus-opened
  // boxes auto-collapse (the model only keeps a box open while it is pinned, manually
  // drilled, or the focus target — open_source pin>manual>focus); the whole world
  // re-fits (bpRefitDirty). Manual drill-ins (bpOpened) and pins are PRESERVED.
  function clearFocus() {
    if (!bpFocus) return;
    bpFocus = null;
    bpRefitDirty = true;
    if (bpRecord !== undefined) renderBlueprint(bpRecord);
  }

  // Open the per-node ⋯ EDITOR, folded ONTO the box (buildNodeMenu). Tapping ⋯ also
  // FOCUSES + zooms the node so the on-box popover (which lives in the transformed
  // world) is readable; tap the same ⋯ to close.
  function selectNode(id) {
    if (bpSelected === id) { bpSelected = null; }
    else {
      bpSelected = id;
      if (bpFocus !== id) { bpFocus = id; bpFocusDirty = true; }
    }
    if (bpRecord !== undefined) renderBlueprint(bpRecord);
  }

  // The H4 customization affordances (rename/regroup/pin/hide + split/merge),
  // KEPT WORKING and now FOLDED ONTO THE BOX (bpmap-3): a popover rendered INSIDE the
  // selected node card (renderBlueprintNode appends it), REPLACING the old flat
  // #bp-edit-panel row list below the canvas. Living inside the card means it pans/
  // zooms glued to the box. Its own click/pointerdown are stopped so a tap on a
  // gesture doesn't bubble to the card (→ toggleFocus) or start a pan.
  function buildNodeMenu(n) {
    var pop = Dom.mk('div', 'bp-node-pop');
    pop.addEventListener('click', function (e) { e.stopPropagation(); });
    pop.addEventListener('pointerdown', function (e) { e.stopPropagation(); });
    var head = Dom.mk('div', 'bp-pop-h');
    head.appendChild(Dom.mk('span', 'bp-edit-panel-t', 'Edit'));
    head.appendChild(Dom.mk('code', 'bp-pop-id', n.id));
    var close = Dom.mk('button', 'bp-act bp-pop-close', '✕');
    close.setAttribute('type', 'button');
    close.setAttribute('aria-label', 'close editor');
    close.addEventListener('click', function () { bpSelected = null; renderBlueprint(bpRecord); });
    head.appendChild(close);
    pop.appendChild(head);
    pop.appendChild(renderNodeEditRow(n)); // the SAME H4 gestures, now on the box
    return pop;
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
      // Hiding a node removes it from the map — step out of it cleanly: close its
      // editor and, if it was the focus, clear focus (+ re-fit) so the next paint
      // shows the whole map, not a stale "isn't in this map" miss banner for it.
      bpSelected = null;
      if (bpFocus === n.id) { bpFocus = null; bpRefitDirty = true; }
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
