/* beads-runner/web/board/app.js — T6a (claude-tools-p2m) + F2 (claude-tools-8fh).
 *
 * The browser glue ONLY: fetch the §4.5 projection from the same-origin
 * /api/board read proxy (the §9.1 chokepoint — the client bears NO secret and
 * never picks the principal/op), hand it to the pure board-view.js, paint the
 * DOM. Auto-refresh on a fixed cadence so liveness stays honest (a stale
 * runner must surface — §4.2/S-1).
 *
 * THE ONE WRITE PATH (F2, claude-tools-8fh): the per-workspace toggle row
 * POSTs to /api/board/set-desired (F1, claude-tools-49w) — the Board's ONE Pages
 * write proxy. The hard-coded upstream op lives server-side; the client just
 * sends {project_ref, desired:{state, actor:'ui'}} and renders honestly
 * (principle 4): the projection's ACTUAL never moves until the next refresh
 * reports it; a tap surfaces only a secondary "desired: X (waiting for
 * runner to honor)" banner. The WAITING-ON-YOU lane is still a deep-link
 * pointer into T6b's Inbox — this app NEVER renders the dossier body
 * (anti-drift: that is T6b). All honest-state / S-1 rendering decisions
 * live in board-view.js; this file only writes the derived strings into
 * elements and POSTs the user's tap.
 *
 * ANTI-DRIFT (sibling): the top-of-board per-machine capacity strip
 * (MACHINE-STATE.md v1 §4.A) is rendered by renderMachines from
 * view.machines[]; the derive lives in board-view.js (deriveMachine). The
 * per-runner "capacity: <verdict>" pill was REMOVED in claude-tools-zdxd.5
 * (C4) — per-machine usage is now surfaced ONCE at the top of the board,
 * not duplicated on each workspace row. Empty machines[] ⇒ explicit
 * "no telemetry yet" banner (§3.C), never a phantom "ok".
 *
 * ANTI-DRIFT: binds FROZEN MACHINE-STATE.md v1 (D2).
 * Oracle = MACHINE-STATE.md + test-fixtures/machine-state-v1.json +
 * cf/test/conformance-machine-state.sh.
 * A D2 gap ⇒ reopen D2, bump+re-freeze — NEVER diverge, NEVER edit
 * MACHINE-STATE.md silently.
 */
(function () {
  'use strict';

  var REFRESH_MS = 30000; // re-poll so a runner going stale surfaces (§4.2/S-1)
  var BoardView = window.BoardView;

  // F2 — per-workspace ephemeral capture of "user just tapped X". Map keyed
  // by project_ref; entry is cleared on the first refresh whose projection
  // reports actual === pending state (i.e. the daemon has converged). Lives
  // in memory only; a reload starts honest with no pending overlay.
  var pendingDesired = {};

  // The actor stamped on F2 POSTs. C4: captured-not-enforced (the
  // chokepoint's resolved PRINCIPAL_V1 is authoritative); this is a
  // breadcrumb for forensics, not an auth claim.
  var BOARD_ACTOR = 'ui:board';

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
    machines: document.getElementById('machines'),
    msEmpty: document.getElementById('ms-empty'),
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
        // G1 (claude-tools-b6y): a failing card carries the .failbead class
        // (existing) plus .silent when the projection flags it silent — CSS
        // paints the silent ones LOUDER than loud ones (UX principle 7).
        // The badge row is the deep-link affordance: when failure_href is
        // set we render the badge as an <a> into T6b's Inbox failure view.
        var beadCls = 'bead';
        if (card.failure) {
          beadCls += ' failbead';
          if (card.failure.silent) beadCls += ' silent';
        }
        var b = mk('div', beadCls);
        b.appendChild(mk('div', 'bt', card.title));
        var bf = mk('div', 'bf');
        bf.appendChild(mk('span', null,
          (card.priority != null ? 'P' + card.priority : '·') +
          (card.age ? ' · ' + card.age : '')));
        if (card.waiting_on) bf.appendChild(mk('span', 'wo', card.waiting_on));
        // L3 (claude-tools-2bf): which live workspace currently has this bead
        // as its current_task_ref. Null ⇒ no live runner ⇒ nothing rendered
        // (S-1: a stale runner's last task isn't "currently working").
        if (card.runner) bf.appendChild(mk('span', 'rn', '⚙ ' + card.runner));
        b.appendChild(bf);
        if (card.failure) {
          var href = card.failure.failure_href;
          var badge = mk(href ? 'a' : 'div', 'warn', card.failure.badge);
          if (href) badge.setAttribute('href', href);
          b.appendChild(badge);
        }
        c.appendChild(b);
      });
      el.cols.appendChild(c);
    });
  }

  function postSetDesired(projectRef, state, btn) {
    // The ONE write — POST to F1. Server-side bearer; client carries no
    // secret (§9.1/§9.2) and never picks the op. On success we update the
    // ephemeral pendingDesired and trigger a re-render; the projection's
    // ACTUAL is unchanged until the next /api/board refresh reports it
    // (principle 4 — honest, never optimistic).
    if (btn) { btn.disabled = true; btn.classList.add('busy'); }
    fetch('/api/board/set-desired', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        accept: 'application/json'
      },
      body: JSON.stringify({
        project_ref: projectRef,
        desired: { state: state, actor: BOARD_ACTOR }
      })
    })
      .then(function (resp) {
        return resp.text().then(function (body) {
          var data = null;
          try { data = JSON.parse(body); } catch (e) { data = null; }
          if (!resp.ok || (data && data.ok === false)) {
            var msg = (data && data.error)
              ? data.error
              : 'set-desired returned HTTP ' + resp.status;
            throw new Error(msg);
          }
          return data;
        });
      })
      .then(function () {
        // Capture the pending overlay; refresh() will clear it once the
        // projection's actual catches up. The view model NEVER promotes
        // pending to actual — board-view.js enforces this.
        pendingDesired[projectRef] = { state: state, set_at_ms: Date.now() };
        if (lastSnapshot) render(BoardView.deriveBoardView(
          lastSnapshot, Date.now(), { pending_desired: pendingDesired }));
        // Force an early refresh so the user sees actual catch up sooner.
        setTimeout(refresh, 1500);
      })
      .catch(function (e) {
        // Honest surfacing — show the error inline on the runner row.
        var note = document.createElement('div');
        note.className = 'rerr';
        note.textContent = 'set-desired failed: ' +
          (e && e.message ? e.message : String(e));
        if (btn && btn.parentNode && btn.parentNode.parentNode) {
          var existing = btn.parentNode.parentNode.querySelector('.rerr');
          if (existing) existing.remove();
          btn.parentNode.parentNode.appendChild(note);
        }
      })
      .then(function () {
        if (btn) { btn.disabled = false; btn.classList.remove('busy'); }
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
      // 8ag — a live runner's current task ref as a secondary line under the
      // pill. claude-tools-4g5o — extended to optionally include a TITLE from
      // the §4.6 workspace_inventory join (graceful fallback to ref-only when
      // the projection has no title). Dropped for stale runners by the view
      // (S-1: their last task is honestly unknown).
      if (r.current_task) {
        var line = mk('code', 'workspace-current-task', r.current_task);
        if (r.current_task_title) {
          // Em-dash separator + a visually subordinate title span so the user
          // can still scan refs quickly. Truncate to 60 chars with ellipsis.
          var t = r.current_task_title;
          if (t.length > 60) t = t.slice(0, 60) + '…';
          line.appendChild(document.createTextNode(' — '));
          line.appendChild(mk('span', 'workspace-current-task-title', t));
        }
        box.appendChild(line);
      }
      // S-1: the last-reported actual of a stale runner is muted CONTEXT,
      // never promoted to a live state (board-view.js guarantees this).
      if (r.actual_note) box.appendChild(mk('div', 'rnote', r.actual_note));
      // F2 — per-row toggle controls. Buttons reflect ACTUAL; the active
      // pill is the current actual state (never desired).
      var controlsBox = mk('div', 'rctrls');
      (r.controls || []).forEach(function (c) {
        var btn = mk('button', 'rbtn' + (c.active ? ' active' : ''), c.label);
        btn.setAttribute('type', 'button');
        btn.setAttribute(
          'aria-label',
          'Set ' + r.project_ref + ' desired-state to ' + c.state
        );
        btn.setAttribute('aria-pressed', c.active ? 'true' : 'false');
        btn.dataset.state = c.state;
        btn.addEventListener('click', function () {
          postSetDesired(r.project_ref, c.state, btn);
        });
        controlsBox.appendChild(btn);
      });
      box.appendChild(controlsBox);
      // Pending banner (principle 4): "desired: X (waiting for runner to
      // honor)" — secondary line, never promoted to actual.
      if (r.pending_label) {
        box.appendChild(mk('div', 'rpending', r.pending_label));
      }
      // Stale-controls warning: still tappable, but honestly flagged.
      if (r.stale_controls_note) {
        box.appendChild(mk('div', 'rstale', r.stale_controls_note));
      }
      // The per-runner "capacity: <verdict>" pill was REMOVED in
      // claude-tools-zdxd.5 (C4). Per-machine usage now surfaces ONCE at
      // the top of the board via renderMachines (MACHINE-STATE.md §4).
      el.runners.appendChild(box);
    });
  }

  /* renderMachines(machines, empty) — MACHINE-STATE.md §4.A top-of-board
   * per-machine capacity strip. One row per machines[] entry; deterministic
   * order is the projection's (C3 sorts by runner_id). Empty array ⇒
   * "no telemetry yet" banner (§3.C); the strip is NEVER omitted entirely.
   *
   * Color bands (§4.B) come from the view-model field per-pct (green/amber/
   * red/neutral/stale/missing); CSS paints them. Staleness (§4.C) and gate
   * disabled (§4.D) are surfaced as chips/badges next to the row. */
  function renderMachines(machines, empty) {
    clear(el.machines);
    el.msEmpty.hidden = !empty;
    if (empty) return;
    machines.forEach(function (m) {
      // Row container. `stale` and `gate-disabled` classes drive the muted
      // palette per §4.C/§4.D; the strip itself ALWAYS renders.
      var rowCls = 'mstrip';
      if (!m.fresh) rowCls += ' stale';
      if (m.gate_disabled) rowCls += ' gate-disabled';
      var row = mk('div', rowCls);

      // runner_id — the identity slot
      row.appendChild(mk('span', 'mrid', m.runner_id));

      function numSlot(label, text, band) {
        var slot = mk('span', 'mslot');
        slot.appendChild(mk('span', 'mlbl', label));
        slot.appendChild(mk('span', 'mnum band-' + band, text));
        return slot;
      }
      row.appendChild(numSlot('5h', m.pct_5h_text, m.pct_5h_band));
      row.appendChild(numSlot('7d', m.pct_7d_text, m.pct_7d_band));
      row.appendChild(numSlot('ramp', m.ramp_text, m.ramp_band));

      // <allowed> — gating summary (re-derived from wire fields, mirrors
      // daemon/usage-poll.sh:_usage_poll_compute_allowed).
      row.appendChild(mk('span', 'mallowed', m.allowed_text));

      // "observed <age> ago" — uses the projection's age_seconds (C3).
      row.appendChild(mk('span', 'mobs', 'observed ' + m.age_text + ' ago'));

      // Chips/badges (§4.C/§4.D/§4.E) — degrade per-field, never collapse the row.
      if (m.stale_label) row.appendChild(mk('span', 'mchip stale-chip', m.stale_label));
      if (m.gate_disabled_chip) row.appendChild(mk('span', 'mchip gate-chip', m.gate_disabled_chip));
      if (m.keychain_chip) row.appendChild(mk('span', 'mchip warn-chip', m.keychain_chip));
      if (m.api_chip) row.appendChild(mk('span', 'mchip warn-chip', m.api_chip));
      if (m.partial_chip) row.appendChild(mk('span', 'mchip warn-chip', m.partial_chip));

      el.machines.appendChild(row);
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
    renderMachines(view.machines || [], view.machines_empty === true);
    renderRunners(view.runners);
    el.footUpdated.textContent = 'updated ' +
      new Date().toLocaleTimeString();
  }

  // The last projection we successfully rendered — held so a tap can re-render
  // with the new pending overlay without re-fetching, AND so we can clear
  // stale pending entries the moment actual catches up.
  var lastSnapshot = null;

  function clearHonoredPending(snapshot) {
    // Walk the projection's projects[]: any project whose ACTUAL matches its
    // pending state has been honored by the daemon — clear it. This is what
    // makes the pending banner disappear honestly (never optimistically).
    var projects = Array.isArray(snapshot && snapshot.projects) ? snapshot.projects : [];
    projects.forEach(function (p) {
      var ref = p && p.project_ref;
      if (!ref || !pendingDesired[ref]) return;
      var actual = p.runner_state && p.runner_state.actual;
      if (actual && actual === pendingDesired[ref].state) {
        delete pendingDesired[ref];
      }
    });
  }

  function refresh() {
    // The READ network call: a credential-less, same-origin GET to /api/board.
    // (The Board's ONE write seam is the F2 POST in postSetDesired — both go
    // through Pages-side proxies; neither carries a token client-side.)
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
        lastSnapshot = snapshot;
        clearHonoredPending(snapshot);
        render(BoardView.deriveBoardView(
          snapshot, Date.now(), { pending_desired: pendingDesired }));
      })
      .catch(function (e) {
        showError(e && e.message ? e.message : String(e));
      });
  }

  refresh();
  setInterval(refresh, REFRESH_MS);
})();
