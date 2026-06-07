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
  var BV = window.BlueprintView; // wmmc — the H2 map renderer, reused at thumb scale
  var RC = window.RunnerCard;    // claude-tools-758l — shared F2 desired-state controls
  var Net = window.Net;
  var Dom = window.Dom;

  // claude-tools-758l — the F2 desired-state write seam, now ON the workspace card
  // (UX-DESIGN-V2 §2 "one tap from the workspace card"; §4 Flow D). Same shape as
  // board/app.js: an ephemeral per-ref "user just tapped X" capture (cleared the
  // first refresh whose projection reports actual === X) + the actor breadcrumb
  // (C4 captured-not-enforced). In memory only — a reload starts honest.
  // lastSnapshot lets a tap re-render the pending banner without re-fetching.
  var pendingDesired = {};
  var WS_ACTOR = 'ui:workspaces';
  var lastSnapshot = null;

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
    intakeAlert: Dom.el('intake-alert'),
    intakeAlertNum: Dom.el('intake-alert-num'),
    intakeAlertLbl: Dom.el('intake-alert-lbl'),
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

  // L3 (claude-tools-uxvl3) — the per-workspace intake-state strip: the phone-
  // visible thread received → enriching → created / failing(n) / gave-up. We
  // render the renderable `items` the view-model selected (every in-flight /
  // attention intake + a recently-created confirmation), each as a state chip
  // with its detail. A failing(n) / gave-up chip is loud (it's the leak). When
  // there is nothing to show the whole strip is omitted (no empty box).
  function intakeChipLabel(it) {
    if (it.state === 'failing') return 'failing' + (it.attempts ? ' (' + it.attempts + ')' : '');
    if (it.state === 'gave-up') return 'gave up' + (it.attempts ? ' after ' + it.attempts : '');
    if (it.state === 'created') return 'created';
    // claude-tools-t956 — a stale `enriching` (daemon died mid-enrich) is loud:
    // it carries the `attn` row class via it.attention; say so on the chip too.
    if (it.state === 'enriching' && it.stale) return 'enriching (stalled)';
    return it.state; // received | enriching
  }
  function renderIntakeStrip(card) {
    var intake = card.intake;
    if (!intake || !intake.items || intake.items.length === 0) return null;
    var wrap = Dom.mk('div', 'ws-intake');
    var lbl = Dom.mk('div', 'ws-intake-lbl', 'phone intake');
    if (intake.attention_count > 0) {
      lbl.appendChild(Dom.mk('span', 'ws-intake-leak',
        intake.attention_count + (intake.attention_count === 1 ? ' needs you' : ' need you')));
    }
    wrap.appendChild(lbl);
    intake.items.forEach(function (it) {
      var row = Dom.mk('div', 'ws-intake-row state-' + it.state + (it.attention ? ' attn' : ''));
      var chip = Dom.mk('span', 'ws-intake-chip', intakeChipLabel(it));
      row.appendChild(chip);
      // The submitter's own idea excerpt so Brian knows which tap this is.
      if (it.idea_excerpt) {
        var ex = it.idea_excerpt;
        if (ex.length > 48) ex = ex.slice(0, 48) + '…';
        row.appendChild(Dom.mk('span', 'ws-intake-idea', ex));
      }
      // The terminal-success bead, or the failure reason, plus the age.
      if (it.state === 'created' && it.bd_ref) {
        row.appendChild(Dom.mk('span', 'ws-intake-meta', '→ ' + it.bd_ref));
      } else if (it.last_error) {
        var er = it.last_error;
        if (er.length > 40) er = er.slice(0, 40) + '…';
        row.appendChild(Dom.mk('span', 'ws-intake-meta', er));
      }
      if (it.ago && it.ago !== 'unknown') {
        row.appendChild(Dom.mk('span', 'ws-intake-ago', it.ago));
      }
      wrap.appendChild(row);
    });
    return wrap;
  }

  // H3/§6.6/§8.5 — the Blueprint card chip: a small thumbnail + "updated 2h ago"
  // freshness + the §8.2 in-flight count, read from the §8.1 blueprint_meta
  // projection. l75z (claude-tools-l75z) makes the WHOLE chip a DEEP-LINK into the
  // dedicated map (/ws/<ref>/blueprint, bp.href) — §6.6 wants the card's diagram to
  // be "a diagram OR a link to the diagram", and the view-model already carries the
  // href. It is a SIBLING <a> of the board link (renderCard's root is a <div>),
  // never nested — a link cannot nest a link. Omitted when no map exists yet
  // (honest — the intake-strip pattern).
  //
  // wmmc (claude-tools-wmmc) — the §8.5 LIVE mini-MAP render layered on top: the
  // glyph upgrades, in place, to a real thumbnail of `derived` (top-level boxes,
  // lit where work is in flight) once the map body is LAZILY fetched. See the
  // bp* lazy-thumb machinery below. The chip renders meta-only first (one
  // /api/board read — the hub's posture is untouched); the map body is fetched
  // per card only when its chip scrolls into view.
  function renderBlueprintChip(card) {
    var bp = card.blueprint;
    if (!bp || !bp.present) return null;
    var ref = card.project_ref;
    bpMetaByRef[ref] = bp;                         // active_domains + version for the thumb
    var wrap = Dom.mk('a', 'ws-blueprint');        // l75z — the §6.6 deep-link
    wrap.setAttribute('href', bp.href);            // → /ws/<ref>/blueprint
    wrap.setAttribute('aria-label', 'Open Blueprint for ' + ref);
    // The thumbnail host — starts as the H3 box-grid glyph; upgraded to a live
    // mini-map in place (or painted straight from cache on a re-render).
    var thumb = Dom.mk('span', 'ws-bp-thumb', '▦');
    bpThumbEls[ref] = thumb;
    wrap.appendChild(thumb);
    var meta = Dom.mk('span', 'ws-bp-meta');
    meta.appendChild(Dom.mk('span', 'ws-bp-lbl', 'Blueprint'));
    if (bp.updated_ago && bp.updated_ago !== 'unknown') {
      meta.appendChild(Dom.mk('span', 'ws-bp-ago', 'updated ' + bp.updated_ago + ' ago'));
    }
    wrap.appendChild(meta);
    if (bp.active_count > 0) {
      wrap.appendChild(Dom.mk('span', 'ws-bp-active',
        '● ' + bp.active_count + ' in flight'));
    }
    wrap.appendChild(Dom.mk('span', 'ws-bp-go', '→')); // tappable affordance (l75z)

    // wmmc — paint from cache if we already hold this map version; otherwise
    // observe the chip and fetch the map body on first view (lazy).
    var cached = bpThumbCache[ref];
    var version = bp.updated_at || null;
    if (cached && cached.state === 'loaded') {
      paintBpThumb(ref);                                 // from cache — no glyph flash
      if (cached.updated_at !== version) fetchBpThumb(ref); // the map changed ⇒ refresh
    } else if (cached && cached.updated_at === version &&
               (cached.state === 'absent' || cached.state === 'error' ||
                cached.state === 'pending')) {
      /* terminal/in-flight for this version — keep the glyph (honest fallback) */
    } else {
      thumb.setAttribute('data-bp-ref', ref);
      if (bpObserver) bpObserver.observe(thumb);
      else bpIdle(function () { fetchBpThumb(ref); });   // no IO ⇒ deferred, post-paint
    }
    return wrap;
  }

  // ── wmmc: the §8.5 live mini-MAP thumbnail (LAZY per-card blueprint-get) ───────
  // The hub's FIRST paint still makes exactly ONE /api/board read (the meta chip,
  // H3). The mini-map is a post-paint ENHANCEMENT: when a card's Blueprint chip
  // scrolls into view we fetch THAT workspace's map body once (/api/ws/blueprint —
  // the same on-demand B.2 read the facet uses) and render it at thumb scale via
  // BlueprintView.deriveBlueprintThumb. A null/empty/errored fetch leaves the H3
  // meta glyph untouched (the honest fallback — never an error on the hub). Results
  // cache by ref keyed on blueprint_meta.updated_at, so a CHANGED map re-fetches and
  // the 30s re-render repaints an UNCHANGED one from cache without re-hitting the
  // engine. This is why the "one /api/board read" invariant is not violated — the
  // map fetch is lazy, per-visible-card, and additive, exactly as §8.5/§11 allow.
  var bpThumbCache = Object.create(null); // ref -> { state, record, updated_at }
  var bpThumbEls   = Object.create(null); // ref -> the CURRENT thumb element (per render)
  var bpMetaByRef  = Object.create(null); // ref -> card.blueprint (active_domains, updated_at)
  var bpObserver = (typeof window.IntersectionObserver === 'function')
    ? new window.IntersectionObserver(onBpVisible, { rootMargin: '160px' })
    : null;

  function onBpVisible(entries) {
    entries.forEach(function (en) {
      if (!en.isIntersecting) return;
      var ref = en.target.getAttribute('data-bp-ref');
      if (bpObserver) bpObserver.unobserve(en.target);
      if (ref) fetchBpThumb(ref);
    });
  }

  // No-IntersectionObserver fallback: defer to idle so first paint is never blocked
  // (still post-paint; just not viewport-gated).
  function bpIdle(fn) {
    if (typeof window.requestIdleCallback === 'function') window.requestIdleCallback(fn);
    else setTimeout(fn, 250);
  }

  function fetchBpThumb(ref) {
    var meta = bpMetaByRef[ref];
    if (!meta || !BV) return;
    var version = meta.updated_at || null;
    var cached = bpThumbCache[ref];
    // Already terminal / in-flight for THIS map version ⇒ nothing to do.
    if (cached && cached.updated_at === version &&
        (cached.state === 'loaded' || cached.state === 'absent' ||
         cached.state === 'error' || cached.state === 'pending')) return;
    bpThumbCache[ref] = { state: 'pending', record: null, updated_at: version };
    Net.getJSON('/api/ws/blueprint?project_ref=' + encodeURIComponent(ref))
      .then(function (record) {
        bpThumbCache[ref] = {
          state: record == null ? 'absent' : 'loaded',
          record: record,
          updated_at: version
        };
        paintBpThumb(ref);
      })
      .catch(function () {
        // Best-effort (B.4): a failed map read leaves the meta glyph — the board
        // read already succeeded, so the hub never degrades over a thumbnail miss.
        bpThumbCache[ref] = { state: 'error', record: null, updated_at: version };
      });
  }

  // Render the mini-map cells INTO the chip's thumb element, replacing the ▦ glyph.
  // Leaves the glyph untouched on a refusal / empty / no-cell render (honest — the
  // tolerance lives in deriveBlueprintThumb, mirrored here as "keep the fallback").
  var BP_THUMB_MAX_CELLS = 12; // a thumbnail stays a thumbnail; the overflow is counted
  function paintBpThumb(ref) {
    var host = bpThumbEls[ref];
    var cached = bpThumbCache[ref];
    var meta = bpMetaByRef[ref];
    if (!host || !cached || cached.state !== 'loaded' || !BV) return;
    var thumb = BV.deriveBlueprintThumb(cached.record, Date.now(), {
      active_domains: meta ? meta.active_domains : undefined
    });
    if (!thumb.ok || !thumb.found || !thumb.cells.length) return; // keep the glyph
    Dom.clear(host);
    host.classList.add('is-map');
    host.removeAttribute('data-bp-ref');
    thumb.cells.slice(0, BP_THUMB_MAX_CELLS).forEach(function (c) {
      var cell = Dom.mk('span', 'ws-bp-cell kind-' + (c.kind_known ? c.kind : 'unknown') +
        (c.active ? ' active' : '') + (c.collision ? ' collision' : ''));
      cell.setAttribute('title', c.label +
        (c.collision ? ' — collision' : (c.active ? ' — in flight' : '')));
      host.appendChild(cell);
    });
    if (thumb.cells.length > BP_THUMB_MAX_CELLS) {
      host.appendChild(Dom.mk('span', 'ws-bp-cell more',
        '+' + (thumb.cells.length - BP_THUMB_MAX_CELLS)));
    }
  }

  // claude-tools-758l — clear honored pending entries: a project whose ACTUAL now
  // matches its pending state has converged (the daemon honored the tap), so the
  // pending banner is dropped. Mirrors board/app.js's clearHonoredPending.
  function clearHonoredPending(snapshot) {
    var projects = Array.isArray(snapshot && snapshot.projects) ? snapshot.projects : [];
    projects.forEach(function (p) {
      var ref = p && p.project_ref;
      if (!ref || !pendingDesired[ref]) return;
      var actual = p.runner_state && p.runner_state.actual;
      if (actual && actual === pendingDesired[ref].state) delete pendingDesired[ref];
    });
  }

  // claude-tools-758l — the F2 write: POST to the Board's set-desired proxy (the
  // server-side bearer; the client carries no secret — §9.1/§9.2). On success
  // capture the ephemeral pending overlay + re-render (honest, never optimistic:
  // ACTUAL is unchanged until the next refresh reports it), and force an early
  // refresh so the user sees actual catch up sooner. Actor = the workspaces-card
  // breadcrumb (C4 captured-not-enforced).
  function postSetDesired(projectRef, state, btn) {
    if (btn) { btn.disabled = true; btn.classList.add('busy'); }
    Net.postJSON('/api/board/set-desired', {
      project_ref: projectRef,
      desired: { state: state, actor: WS_ACTOR }
    })
      .then(function () {
        pendingDesired[projectRef] = { state: state, set_at_ms: Date.now() };
        if (lastSnapshot) {
          render(WV.deriveWorkspacesView(lastSnapshot, Date.now(),
            { pending_desired: pendingDesired }));
        }
        window.setTimeout(refresh, 1500);
      })
      .catch(function (e) {
        // Honest surfacing — show the error inline on the controls (.rerr is
        // shared CSS). btn.parentNode is .rctrls; its parent is .ws-runner-controls.
        var note = Dom.mk('div', 'rerr',
          'set-desired failed: ' + (e && e.message ? e.message : String(e)));
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

  function renderCard(card) {
    // The card is a container; its BODY links into that workspace's Board (the hub
    // is the anchor — no scavenger hunt; UX-DESIGN-V2 §2). The Blueprint thumbnail
    // below is a SECOND, distinct deep-link (→ /ws/<ref>/blueprint, §6.6/§8.5,
    // l75z), so the root is a <div> holding two sibling <a>s — a link cannot nest
    // a link (invalid HTML), and §6.6 wants the card's diagram to BE that link.
    var root = Dom.mk('div', 'ws-card health-' + card.health);
    var a = Dom.mk('a', 'ws-card-main');
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
    var intakeStrip = renderIntakeStrip(card);
    if (intakeStrip) a.appendChild(intakeStrip);
    a.appendChild(Dom.mk('div', 'ws-go', 'OPEN BOARD →'));
    root.appendChild(a);

    // claude-tools-758l — the F2 desired-state controls (Run/Pause/Spare-only/Stop)
    // as a THIRD sibling of the card body (UX-DESIGN-V2 §2 "one tap from the
    // workspace card"; §4 Flow D). It sits OUTSIDE the <a> body so a tap changes
    // state without navigating (and a link can't nest a button row anyway). The
    // card object already carries controls[]/pending_label from workspaces-view.js,
    // so RunnerCard.renderControls consumes it directly.
    if (RC) {
      var ctrlWrap = Dom.mk('div', 'ws-runner-controls');
      ctrlWrap.appendChild(RC.renderControls(card, postSetDesired, Dom));
      root.appendChild(ctrlWrap);
    }

    // The Blueprint thumbnail is its OWN deep-link into /ws/<ref>/blueprint — a
    // sibling of the board link, never nested inside it (l75z; §6.6/§8.5).
    var bpChip = renderBlueprintChip(card);
    if (bpChip) root.appendChild(bpChip);
    return root;
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

    // L3 — the global intake-leak alert: failing + gave-up phone intakes across
    // all workspaces. Hidden at zero; loud above it (this number going silently
    // >0 was the 19-retry night).
    var leak = view.intake_attention_total || 0;
    el.intakeAlert.hidden = leak === 0;
    if (leak > 0) {
      el.intakeAlertNum.textContent = String(leak);
      el.intakeAlertLbl.textContent = (leak === 1 ? 'phone intake is failing or gave up' : 'phone intakes are failing or gave up')
        + ' — see the workspace cards below';
    }

    el.headDot.classList.toggle('bad',
      view.cards.some(function (c) { return c.health !== 'ok'; }));

    // wmmc — drop any Blueprint-chip observations from the previous render: those
    // thumb elements are about to be discarded, and renderCard re-observes the fresh
    // ones. (Keeps the IntersectionObserver from accumulating detached targets across
    // the 30s refresh. The bpThumbCache survives — it's keyed by ref, not element.)
    if (bpObserver) bpObserver.disconnect();
    Dom.clear(el.cards);
    el.cardsEmpty.hidden = view.cards.length !== 0;
    view.cards.forEach(function (c) { el.cards.appendChild(renderCard(c)); });

    el.footUpdated.textContent = 'updated ' + new Date().toLocaleTimeString();
  }

  function refresh() {
    Net.getJSON('/api/board')
      .then(function (snapshot) {
        // claude-tools-758l — hold the snapshot so a tap can re-render the pending
        // banner without re-fetching, and clear any pending entry the daemon has
        // honored BEFORE deriving (the banner disappears honestly, not on a timer).
        lastSnapshot = snapshot;
        clearHonoredPending(snapshot);
        render(WV.deriveWorkspacesView(snapshot, Date.now(),
          { pending_desired: pendingDesired }));
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
