/* beads-runner/web/inbox/app.js — T6b (claude-tools-xre).
 *
 * Browser glue ONLY. The decision LOGIC (what is deterministic vs reconciler,
 * the §5 render, the §5.2 response payload, the honest ack) lives in the pure
 * inbox-view.js; consequence application + the §7.4 latch + the S-2
 * control→work reconcile live in T5 (the Coordinator). This file: hash-routes,
 * fetches the credential-less same-origin proxies (the §9.1 chokepoint is
 * server-side — the client bears no secret and never picks the principal),
 * collects per-Item form state, and submits ONE response per resolved Item
 * (partial is first-class — AD7; an untouched item is simply never sent and
 * blocks nothing). After submit it RE-FETCHES the §4 Dossier and renders the
 * ack from the latch-true control-plane record — never a Dolt read, so no
 * Dolt-lag lie (EXIT crit 1 / S-2).
 *
 * Routes (hash): #/  or #/inbox → list ; #/d/<id> (or bare #<id>, the Board's
 * deep-link) → dossier ; #/f/<bead_ref> → Flow-G failure.
 */
(function () {
  'use strict';
  var IV = window.InboxView;

  // Shared glue (UMD): network (window.Net) + DOM helpers (window.Dom) + the
  // persistent nav shell (window.Shell) now live ONCE in /shared/*.js — see
  // index.html. Call sites below use Net.* / Dom.* directly; behavior is
  // byte-identical (pure dedup, no logic change).
  function show(view) {
    ['v-list', 'v-dossier', 'v-confirm', 'v-failure', 'errbox'].forEach(function (v) {
      Dom.el(v).hidden = v !== view;
    });
    Dom.el('loading').hidden = true;
    Dom.el('ddock').hidden = view !== 'v-dossier';
    Dom.el('back').hidden = view === 'v-list';
    Dom.el('scroll').scrollTop = 0;
  }
  function showError(h, b) {
    Dom.el('err-h').textContent = h || 'Cannot render';
    Dom.el('err-b').textContent = b || '';
    Dom.el('dot').classList.add('bad');
    show('errbox');
  }
  function toast(m) {
    var p = Dom.el('pop'); Dom.el('popmsg').textContent = m;
    p.classList.add('on'); clearTimeout(toast._t);
    toast._t = setTimeout(function () { p.classList.remove('on'); }, 2800);
  }
  function stamp() { Dom.el('foot-updated').textContent = 'updated ' + new Date().toLocaleTimeString(); }

  // ── network: every call is same-origin + credential-less (§9.1). The
  // getJSON/postJSON impls now live ONCE in /shared/net.js (window.Net) — same
  // honest error discipline; call sites use Net.getJSON / Net.postJSON directly.

  // ── INBOX LIST + Flow-G glance ────────────────────────────────────────────
  var lastSnapshot = null;
  function loadList() {
    show('loading'); Dom.el('loading').hidden = false;
    Net.getJSON('/api/inbox').then(function (snap) {
      lastSnapshot = snap;
      var v = IV.deriveInboxList(snap, Date.now());
      if (!v.ok) { showError('Cannot render the Inbox', v.error); return; }
      Dom.el('who').textContent = v.principal;
      Dom.el('title').textContent = 'Inbox';
      Dom.el('dot').classList.toggle('bad', v.failures.length > 0);
      Dom.el('list-sub').textContent = v.items.length === 0
        ? 'The product. Nothing needs you — everything is flowing.'
        : 'The product. ' + v.items.length +
          (v.items.length === 1 ? ' thing' : ' things') + ' need you' +
          (v.failures.length ? ' · ' + v.failures.length + ' failing' : '') + '.';
      var rows = Dom.el('rows'); Dom.clear(rows);
      Dom.el('list-empty').hidden = v.items.length !== 0;
      v.items.forEach(function (it) {
        var a = Dom.mk('a', 'inrow t-' + it.tier);
        a.setAttribute('href', it.dossier_href || '#/');
        // claude-tools-56h — tier strip now carries bead_ref + time-ago + an
        // item-count badge (when > 1). Without these, 9 dossiers on the same
        // bead were visually identical and the user had to tap each one to
        // tell them apart.
        var tier = Dom.mk('div', 'tier');
        tier.appendChild(Dom.mk('span', 'tg', it.tier));
        var refTxt = it.bead_ref || it.dossier_ref || '';
        if (it.time_ago) refTxt = refTxt ? refTxt + ' · ' + it.time_ago : it.time_ago;
        if (it.dossier_short) refTxt = refTxt ? refTxt + ' · #' + it.dossier_short : '#' + it.dossier_short;
        tier.appendChild(Dom.mk('span', 'ref', refTxt));
        if (it.count_badge) {
          var cnt = Dom.mk('span', 'cnt', it.count_badge + (it.item_count === 1 ? ' item' : ' items'));
          tier.appendChild(cnt);
        }
        a.appendChild(tier);
        // Title prefers the dossier's tldr (the skim entry point — AD7); falls
        // back to the legacy "N things need you" phrase for any item the
        // producer couldn't enrich (older snapshot / body-less dossier).
        a.appendChild(Dom.mk('div', 'h', it.tldr || it.label));
        a.appendChild(Dom.mk('div', 'd', it.auto_proceeds
          ? 'Read-mostly — auto-proceeds on silence (reversible). Open to skim or object.'
          : 'Open the dossier — skim it, then resolve in any mix. Your “no” is one tap.'));
        rows.appendChild(a);
      });
      var fg = Dom.el('flowg'); var fails = Dom.el('fails'); Dom.clear(fails);
      fg.hidden = v.failures.length === 0;
      v.failures.forEach(function (f) {
        var c = Dom.mk('a', 'failrow');
        c.setAttribute('href', f.failure_href || '#/');
        c.appendChild(Dom.mk('div', 'fbadge', f.badge));
        c.appendChild(Dom.mk('div', 'h', f.title + '  ·  ' + f.bead_ref));
        c.appendChild(Dom.mk('div', 'd', f.class_plain));
        fails.appendChild(c);
      });
      show('v-list'); stamp();
    }).catch(function (e) { showError('Cannot reach the Inbox proxy', e.message); });
  }

  // ── DOSSIER render — the §5 doc IS the form ───────────────────────────────
  var curDossier = null;     // raw §4 record
  var curView = null;        // InboxView.deriveDossierView model
  var formState = {};        // item_id → {action, option_id?, edited_value?, text?}
  var density = 'skim';

  function loadDossier(id) {
    show('loading'); Dom.el('loading').hidden = false;
    Net.getJSON('/api/inbox/dossier?id=' + encodeURIComponent(id)).then(function (rec) {
      curDossier = rec;
      var v = IV.deriveDossierView(rec);
      curView = v;
      if (!v.ok) {
        // ANTI-DRIFT: a missing MANDATORY §5 field is a §11 escalation, NOT a
        // best-effort render. Surface it verbatim — never fabricate.
        // claude-tools-4xe: the ONLY non-render is §0.3 unknown-HIGHER —
        // shown as a plain "update the app" message, never §11/contract jargon.
        showError(v.too_new ? 'Update the app to view this' : 'Cannot show this decision', v.error);
        return;
      }
      formState = {};
      renderDossier(v);
      show('v-dossier'); stamp();
    }).catch(function (e) { showError('Cannot fetch the dossier', e.message); });
  }

  // §5.1 v2 (§11 Mermaid amendment): diagrams[].content is Mermaid source and
  // MUST render as an actual diagram (SVG), never source text in a <pre>.
  // Uses mermaid.run({nodes}): Mermaid (securityLevel:'strict', DOMPurify
  // built in) sanitizes and inserts the SVG into the node itself — this code
  // never assigns innerHTML. Awaits window.__mermaidReady (index.html). If
  // mermaid never loads, or one diagram fails to parse, that ONE diagram
  // degrades to a labeled source block + an explicit note — the dossier is
  // never blocked (a malformed diagram is a generator bug surfaced honestly,
  // not a dead Inbox).
  function diagramFallback(host, src, why) {
    Dom.clear(host);
    host.appendChild(Dom.mk('div', 'dgerr', why || 'could not render — showing Mermaid source'));
    host.appendChild(Dom.mk('pre', 'dgc dgc-fallback', src));
  }
  function renderDiagrams(pending) {
    // Skip a host detached by a re-render between schedule and settle (a new
    // renderDossier already cleared #d-diagrams) — avoids dead work on a
    // node that is no longer in the document.
    function live(p) { return p.host && p.host.isConnected !== false && p.host.isConnected; }
    window.__mermaidReady.then(function (mermaid) {
      var run = pending.filter(live);
      if (!run.length) return;
      var nodes = run.map(function (p) { return p.node; });
      Promise.resolve(
        mermaid.run({ nodes: nodes, suppressErrors: true })
      ).then(function () {
        run.forEach(function (p) {
          // On success Mermaid replaced the node's content with an <svg>.
          if (live(p) && (!p.node.querySelector || !p.node.querySelector('svg'))) {
            diagramFallback(p.host, p.src, 'Mermaid could not parse this diagram — showing source');
          }
        });
      }).catch(function () {
        run.forEach(function (p) {
          if (live(p)) diagramFallback(p.host, p.src, 'Mermaid could not parse this diagram — showing source');
        });
      });
    }).catch(function () {
      pending.forEach(function (p) {
        if (live(p)) diagramFallback(p.host, p.src, 'diagram renderer unavailable — showing Mermaid source');
      });
    });
  }

  function renderDossier(v) {
    Dom.el('title').textContent = v.profile === 'overview' ? 'Overview' : 'Dossier';
    Dom.el('back').hidden = false;
    Dom.el('d-tier').textContent = v.tier;
    Dom.el('d-tier').className = 'badge t-' + v.tier;
    Dom.el('d-meta').textContent = v.bead_ref + ' · ' + (v.trigger || v.kind) +
      ' · ' + v.rollup.total + ' call' + (v.rollup.total === 1 ? '' : 's');
    Dom.el('d-eyer').textContent = (v.profile === 'overview' ? 'PROACTIVE OVERVIEW' : 'DECISION DOSSIER') +
      ' · ' + (v.trigger || v.kind);
    Dom.el('d-title').textContent = v.body.tldr;
    Dom.el('d-tldr').textContent = v.body.tldr;
    var fb = Dom.el('fyi-banner');
    fb.hidden = !v.auto_proceeds;
    if (v.auto_proceeds) fb.textContent = 'Read-mostly brief — not a blocker. ' + v.timer_note +
      '. Flag a concern on anything that looks wrong; silence is a valid input (principle 6).';

    var secs = Dom.el('d-sections'); Dom.clear(secs);
    // claude-tools-4xe — a non-blocking, honest notice when this accepted
    // dossier had to be shown best-effort (legacy/pre-write-gate record). It
    // never blocks reading or answering; it just refuses to silently paper
    // over a gap.
    if (v.degraded && v.degraded.length) {
      var dn = Dom.mk('div', 'dgerr d-degraded',
        'Shown best-effort — some parts were incomplete: ' + v.degraded.join(' '));
      secs.appendChild(dn);
    }
    // B3 (claude-tools-95m) — DEGRADED-AUTHOR badge. A distinct small badge in
    // the meta bar + an honest notice in the body so Brian sees at a glance
    // that the dossier-builder agent did NOT author this one (the jq
    // deterministic shape-coercer ran instead). Kept separate from the
    // generic .degraded notice above so a fallback-authored dossier is never
    // just rendered as if it were normal.
    if (v.body && v.body.authored_by === 'fallback') {
      var meta = Dom.el('d-meta');
      if (meta && !meta.querySelector('.d-author-badge')) {
        var ab = Dom.mk('span', 'd-author-badge',
          v.body.authored_by_reason === 'no_DG_AUTHOR_CMD' ? 'fallback author' : 'degraded author');
        ab.title = v.body.authored_by_note || 'Authored by the deterministic fallback.';
        meta.appendChild(ab);
      }
      if (v.body.authored_by_note) {
        secs.appendChild(Dom.mk('div', 'dgerr d-author-note', v.body.authored_by_note));
      }
    }
    v.body.sections.forEach(function (s) {
      var d = Dom.mk('div', 'dsec');
      d.appendChild(Dom.mk('h2', null, s.heading));
      d.appendChild(Dom.mk('p', 'prose', s.prose));
      secs.appendChild(d);
    });
    var dgs = Dom.el('d-diagrams'); Dom.clear(dgs);
    var pending = [];
    v.body.diagrams.forEach(function (g) {
      var d = Dom.mk('div', 'diagram');
      d.appendChild(Dom.mk('div', 'dgl', g.caption));
      if (g.degraded) {
        // Not Mermaid / empty: a clearly-LABELED warning block + the raw text,
        // never a silent <pre> masquerading as a rendered diagram, never a
        // dropped diagram (claude-tools-4xe criterion 2 / INTERFACE §5.1).
        d.appendChild(Dom.mk('div', 'dgerr', g.note || 'This diagram could not be rendered.'));
        if (g.content) d.appendChild(Dom.mk('pre', 'dgc dgc-fallback', g.content));
        dgs.appendChild(d);
        return;
      }
      var host = Dom.mk('div', 'dgsvg');
      // The Mermaid SOURCE goes in as textContent (never innerHTML);
      // mermaid.run() replaces this node's content with sanitized SVG.
      var node = Dom.mk('pre', 'mermaid', g.content);
      host.appendChild(node);
      d.appendChild(host);
      dgs.appendChild(d);
      pending.push({ host: host, node: node, src: g.content });
    });
    if (pending.length) renderDiagrams(pending);
    Dom.el('d-full').textContent = v.body.full_detail;

    var box = Dom.el('d-items'); Dom.clear(box);
    v.items.forEach(function (it) { box.appendChild(renderItem(it)); });
    applyDensity();
    recount();
  }

  // The affordance is rendered FROM item.kind (§5.2). reject/edit/freeform/
  // object are each ONE control — symmetric with approve (principle 3 / EXIT
  // crit 2: no penalty path). context_anchor is rendered INLINE, always (AD7).
  function renderItem(it) {
    var du = Dom.mk('div', 'du');
    du.dataset.item = it.id;
    if (it.terminal) du.classList.add('done');

    var q = Dom.mk('div', 'du-q');
    q.appendChild(Dom.mk('div', 'du-tag', it.kind));
    q.appendChild(Dom.mk('div', 'du-ttl', it.framing.ask || '(ask)'));
    if (it.framing.why) q.appendChild(Dom.mk('div', 'du-why', it.framing.why));
    // MANDATORY context_anchor, inline (the AD7 self-contained-context line).
    var ca = Dom.mk('div', 'du-anchor');
    ca.appendChild(Dom.mk('span', 'cl', 'WHERE'));
    ca.appendChild(Dom.mk('span', 'ct', it.context_anchor.where + ' — ' + it.context_anchor.expansion));
    q.appendChild(ca);
    if (it.recommendation && it.recommendation.value != null) {
      var rec = Dom.mk('div', 'du-rec');
      rec.appendChild(Dom.mk('span', 'rl', 'REC'));
      rec.appendChild(Dom.mk('span', 'rt', String(it.recommendation.value) +
        (it.recommendation.why ? ' — ' + it.recommendation.why : '')));
      q.appendChild(rec);
    }
    q.appendChild(Dom.mk('div', 'du-rev', '↩ ' + it.reversible));
    du.appendChild(q);

    if (it.terminal) {
      du.appendChild(Dom.mk('div', 'du-resolved', '✓ ' + (it.response_summary || it.state)));
      return du;
    }

    var acts = Dom.mk('div', 'du-acts');
    it.affordances.forEach(function (a) {
      var b = Dom.mk('button', 'k k-' + a, ({
        approve: 'Approve', reject: 'Reject', pick: 'Options',
        edit: 'Edit', freeform: 'React', object: 'Object'
      })[a] || a);
      b.type = 'button';
      b.addEventListener('click', function () { actItem(du, it, a); });
      acts.appendChild(b);
    });
    du.appendChild(acts);

    // expandable sub-controls (options / edit / freeform)
    var ex = Dom.mk('div', 'du-ex'); ex.hidden = true;
    if (it.options.length) {
      var ow = Dom.mk('div', 'du-opts'); ow.appendChild(Dom.mk('div', 'ol', 'PICK AN OPTION'));
      it.options.forEach(function (o) {
        var ch = Dom.mk('button', 'optchip', '');
        ch.type = 'button';
        ch.appendChild(Dom.mk('span', 'oc', o.label));
        if (o.blast_radius) ch.appendChild(Dom.mk('small', null, o.blast_radius));
        ch.addEventListener('click', function () {
          ow.querySelectorAll('.optchip').forEach(function (x) { x.classList.remove('sel'); });
          ch.classList.add('sel');
          setItem(du, it, { action: 'pick', option_id: o.option_id });
        });
        ow.appendChild(ch);
      });
      ex.appendChild(ow);
    }
    if (it.affordances.indexOf('edit') >= 0) {
      var ew = Dom.mk('div', 'du-editwrap');
      ew.appendChild(Dom.mk('div', 'el', 'EDIT THE RECOMMENDATION — the reconciler reads this (§5.2.2)'));
      var ed = Dom.mk('div', 'du-edit'); ed.contentEditable = 'true'; ed.spellcheck = false;
      ed.textContent = (it.recommendation && it.recommendation.value != null)
        ? String(it.recommendation.value) : '';
      ed.addEventListener('input', function () {
        setItem(du, it, { action: 'edit', edited_value: ed.textContent.trim() });
      });
      ew.appendChild(ed); ex.appendChild(ew);
    }
    var nw = Dom.mk('div', 'du-notewrap');
    var ta = Dom.mk('textarea', 'du-note'); ta.rows = 2;
    ta.placeholder = it.kind === 'fyi-objectable'
      ? 'Why are you objecting? (optional)'
      : 'Your reaction or correction…';
    ta.addEventListener('input', function () {
      var t = ta.value.trim();
      if (it.kind === 'fyi-objectable') {
        if (t) setItem(du, it, { action: 'object', text: t });
      } else if (t) {
        setItem(du, it, { action: 'freeform', text: t });
      }
    });
    nw.appendChild(ta); ex.appendChild(nw);
    du.appendChild(ex);
    du.appendChild(Dom.mk('div', 'du-state'));
    return du;
  }

  function actItem(du, it, action) {
    if (action === 'approve' || action === 'reject') {
      setItem(du, it, { action: action });
      du.querySelector('.du-ex').hidden = true;
      return;
    }
    if (action === 'object') {
      setItem(du, it, { action: 'object' });
      return;
    }
    // pick / edit / freeform → reveal the sub-control (still ONE tap to the
    // affordance; the control is where the value goes — not a penalty path).
    var ex = du.querySelector('.du-ex'); ex.hidden = false;
    if (action === 'freeform') { var n = ex.querySelector('.du-note'); if (n) n.focus(); }
    if (action === 'edit') { var e = ex.querySelector('.du-edit'); if (e) e.focus(); }
  }

  // Validate via the PURE builder so the UI honestly previews deterministic
  // vs reconciler BEFORE submit (principle 4/5 — never a false-instant).
  function setItem(du, it, input) {
    var r = IV.buildItemResponse(it, input, Date.now());
    var st = du.querySelector('.du-state');
    if (!r.ok) { st.textContent = '⚠ ' + r.error; st.className = 'du-state bad'; return; }
    // §5.2 `response` carries ONE decision per Item — one action per item by
    // construction. If a non-pick action replaces a staged pick, clear the
    // option-chip highlight so the UI can never show a selection that is NOT
    // in the submitted payload (the rendered state must equal formState).
    if (input.action !== 'pick') {
      du.querySelectorAll('.optchip.sel').forEach(function (c) { c.classList.remove('sel'); });
    }
    formState[it.id] = input;
    du.dataset.state = input.action;
    du.classList.add('touched');
    st.className = 'du-state ' + r.mode;
    st.textContent = (input.action === 'reject' ? 'Reject' :
      input.action.charAt(0).toUpperCase() + input.action.slice(1)) +
      ' · ' + r.preview;
    recount();
  }

  function recount() {
    if (!curView) return;
    var total = curView.rollup.total;
    var alreadyTerminal = curView.items.filter(function (x) { return x.terminal; }).length;
    var nowResolved = Object.keys(formState).length;
    var resolved = alreadyTerminal + nowResolved;
    Dom.el('progT').textContent = total;
    Dom.el('progN').textContent = resolved;
    Dom.el('prog').style.width = total ? (resolved / total * 100) + '%' : '0%';
    var openLeft = total - resolved;
    var ov = curView.profile === 'overview' || curView.auto_proceeds;
    Dom.el('dsum').textContent = nowResolved === 0
      ? (ov ? 'Read-mostly. Touch only what looks wrong — silence auto-proceeds (reversible).'
            : 'Resolve in any mix. ' + openLeft + ' open · partial is fine, untouched items block nothing (AD7).')
      : nowResolved + ' staged · ' + openLeft + ' still open';
    Dom.el('dsubmit').textContent = ov && nowResolved === 0
      ? 'Acknowledge' : (nowResolved === 0 ? 'Submit' : 'Submit ' + nowResolved);
    // claude-tools-23r — show the dismiss-as-stale button only when there is
    // at least one item in state=open (the only state the engine's stateCheck
    // legally moves to `expired`; an `answered` item is mid-reconcile and is
    // NOT this affordance's target).
    var dismissable = openItemIds().length;
    Dom.el('ddismiss').hidden = dismissable === 0;
    Dom.el('ddismiss').textContent = dismissable > 1
      ? 'Dismiss ' + dismissable + ' as stale' : 'Dismiss as stale';
    // claude-tools-uxl1b §5.6 — defer/escalate toggle the dossier's ATTENTION
    // TIER. Offer each only when it would actually move (defer hidden once
    // already at digest; escalate hidden once at blocking) and only while the
    // dossier is still pending (≥1 non-terminal item — the same "on the Inbox"
    // condition waiting_on_you uses). Reset disabled/label on every render so a
    // re-render after a move always gives a clean slate.
    var pending = alreadyTerminal < total;
    var defBtn = Dom.el('ddefer'), escBtn = Dom.el('descalate');
    defBtn.hidden = !(pending && curView.tier !== 'digest');
    escBtn.hidden = !(pending && curView.tier !== 'blocking');
    if (!defBtn.hidden) { defBtn.disabled = false; defBtn.textContent = 'Defer'; }
    if (!escBtn.hidden) { escBtn.disabled = false; escBtn.textContent = 'Escalate'; }
  }

  // claude-tools-23r — ids of items where state==='open' (NOT 'answered').
  // The engine's dossier.js stateCheck allows ONLY open→expired; an `answered`
  // item is mid-reconcile and would 422 here. Honesty over false success: we
  // never attempt to expire an item the engine would reject, and we say so.
  function openItemIds() {
    if (!curView) return [];
    return curView.items
      .filter(function (x) { return x.state === 'open'; })
      .map(function (x) { return x.id; });
  }

  function applyDensity() {
    Dom.el('v-dossier').classList.toggle('d-skim', density === 'skim');
    Dom.el('v-dossier').classList.toggle('d-full', density === 'full');
    Dom.el('den-skim').classList.toggle('on', density === 'skim');
    Dom.el('den-full').classList.toggle('on', density === 'full');
  }

  // ── SUBMIT — one POST per resolved Item; partial is first-class (AD7) ──────
  function submitDossier() {
    var ids = Object.keys(formState);
    if (ids.length === 0) {
      // An overview/timed-fyi with nothing touched: silence is a valid input
      // (principle 6) — nothing to write; just go to the honest ack.
      if (curView && (curView.profile === 'overview' || curView.auto_proceeds)) {
        return refetchAck();
      }
      toast('Nothing staged. Resolve at least one call, or just leave — untouched items block nothing.');
      return;
    }
    Dom.el('dsubmit').disabled = true;
    Dom.el('dsubmit').textContent = 'Submitting…';
    var chain = Promise.resolve();
    var errs = [];
    ids.forEach(function (iid) {
      var it = curView.items.filter(function (x) { return x.id === iid; })[0];
      var built = IV.buildItemResponse(it, formState[iid], Date.now());
      if (!built.ok) { errs.push(iid + ': ' + built.error); return; }
      chain = chain.then(function () {
        return Net.postJSON('/api/inbox/respond', {
          dossier_id: curView.id, item_id: iid, response: built.response
        }).catch(function (e) { errs.push(iid + ': ' + e.message); });
      });
    });
    chain.then(function () {
      Dom.el('dsubmit').disabled = false;
      // Honest re-fetch is the source of truth (failed items correctly show
      // as still-open, S-2). errs[] is passed through so the ack states
      // PERSISTENTLY which submits failed and why — not a vanishing toast
      // (principle 4: never mask the real failure).
      refetchAck(errs);
    });
  }

  // ── DISMISS-AS-STALE (claude-tools-23r) ───────────────────────────────────
  // An at-the-shell "this is stale, get it out of my way" affordance, gated
  // behind a window.confirm so it cannot be a foot-gun. It flips every open
  // item to the §4.1 terminal state `expired` (the same legal sink T5.4's
  // timed-fyi auto-proceed uses), one POST per open item — partial is
  // first-class (AD7). The ack is the RE-FETCHED §4 record's latch-true state
  // (no Dolt-lag lie). It is NOT a §5.2 response; the renderer's per-Item
  // affordance set is untouched.
  function dismissDossier() {
    if (!curView) return;
    var ids = openItemIds();
    if (ids.length === 0) {
      toast('Nothing to dismiss — every item is already resolved or in-flight.');
      return;
    }
    var msg = 'Mark ' + ids.length + ' open item' + (ids.length === 1 ? '' : 's') +
      ' as expired and drop this dossier from the Inbox?\n\n' +
      'Expired is a terminal state — applying a response later is no longer possible. ' +
      'Already-answered items (mid-reconcile) are left alone.';
    if (!window.confirm(msg)) return;
    Dom.el('ddismiss').disabled = true;
    Dom.el('ddismiss').textContent = 'Dismissing…';
    Dom.el('dsubmit').disabled = true;
    var chain = Promise.resolve();
    var errs = [];
    ids.forEach(function (iid) {
      chain = chain.then(function () {
        return Net.postJSON('/api/inbox/expire', {
          dossier_id: curView.id, item_id: iid
        }).catch(function (e) { errs.push(iid + ': ' + e.message); });
      });
    });
    chain.then(function () {
      Dom.el('ddismiss').disabled = false;
      Dom.el('dsubmit').disabled = false;
      // Honest re-fetch is the source of truth: any item the engine refused
      // to expire (illegal transition) correctly reads back as still-open.
      refetchAck(errs);
    });
  }

  // ── DEFER / ESCALATE (claude-tools-uxl1b §5.6) ─────────────────────────────
  // Attention-tier moves on the WHOLE dossier — distinct verbs, each its own
  // engine op (defer→tier:digest, escalate→tier:blocking); neither resolves an
  // item or consumes the recommendation. They are REVERSIBLE (each undoes the
  // other), so — unlike dismiss-as-stale — there is no window.confirm. One POST;
  // the honest source of truth is the RE-FETCHED §4 record: we re-render the
  // dossier so the new tier + the re-toggled buttons reflect the engine, never
  // an optimistic local patch (S-2 discipline). The dossier stays open — this
  // is NOT a resolution, so it goes back to the dossier view, not the ack.
  function attentionMove(verb, path, btnId, busyLabel) {
    if (!curView) return;
    var id = curView.id;
    var btn = Dom.el(btnId);
    Dom.el('ddefer').disabled = true;
    Dom.el('descalate').disabled = true;
    btn.textContent = busyLabel;
    Net.postJSON(path, { dossier_id: id }).then(function () {
      toast(verb === 'defer'
        ? 'Deferred — moved to the daily-digest roundup. Escalate to pull it back.'
        : 'Escalated — back in the foreground decision lane.');
      loadDossier(id); // re-fetch → honest new tier + recount() re-toggles/cleans the buttons
    }).catch(function (e) {
      // Nothing changed server-side; recount() does not run, so reset here.
      Dom.el('ddefer').disabled = false;
      Dom.el('descalate').disabled = false;
      btn.textContent = verb === 'defer' ? 'Defer' : 'Escalate';
      toast(e.message); // honest: unreachable / rejected, never masked
    });
  }
  function deferDossier() { attentionMove('defer', '/api/inbox/defer', 'ddefer', 'Deferring…'); }
  function escalateDossier() { attentionMove('escalate', '/api/inbox/escalate', 'descalate', 'Escalating…'); }

  // EXIT crit 1 / S-2: the ack is the RE-FETCHED §4 Dossier's latch-true
  // state (control-plane truth the Coordinator reconciles into beads) — NOT a
  // Dolt read. "You don't need to go check" is honest because of this.
  function refetchAck(errs) {
    errs = errs || [];
    Net.getJSON('/api/inbox/dossier?id=' + encodeURIComponent(curView.id)).then(function (rec) {
      var c = IV.deriveConfirm(rec);
      if (!c.ok) { showError('Cannot render the ack', c.error); return; }
      Dom.el('title').textContent = 'Confirmed';
      Dom.el('cf-h').textContent = errs.length
        ? 'Partial — some submits failed.'
        : (c.all_resolved ? 'One pass. Whole stage cleared.' : 'Partial — and that’s fine.');
      Dom.el('cf-ack').textContent = c.honest_note;
      var rc = Dom.el('cf-receipt'); Dom.clear(rc);
      // Persistent, not a toast: exactly which items did NOT apply and why
      // (they correctly read as still-open above — this is the honest cause).
      errs.forEach(function (e) {
        rc.appendChild(Dom.mk('div', 'ri am', '⚠ NOT applied — ' + e));
      });
      if (c.receipt.deterministic_count) {
        rc.appendChild(Dom.mk('div', 'ri', '✓ ' + c.receipt.deterministic_count +
          ' applied deterministically — pre-declared, instant (§5.2.2)'));
      }
      if (c.receipt.reconciler_count) {
        rc.appendChild(Dom.mk('div', 'ri', '↻ ' + c.receipt.reconciler_count +
          ' to the reconciler — re-surfaces only if it conflicts or opens a new question'));
      }
      rc.appendChild(Dom.mk('div', 'ri', '✓ ' + c.bead_ref +
        ' reconciled by the Coordinator (control→work, S-2) — no Dolt-lag lie'));
      if (c.receipt.still_open) {
        rc.appendChild(Dom.mk('div', 'ri am', '· ' + c.receipt.still_open +
          ' left open — partial resolution is first-class (AD7); return anytime'));
      }
      show('v-confirm'); stamp();
    }).catch(function (e) { showError('Cannot confirm', e.message); });
  }

  // ── FLOW G failure (tiers 1–2) + §10.3 forensic (tier-3, on demand) ───────
  function loadFailure(beadRef) {
    var run = function (snap) {
      var v = IV.deriveFailureView(snap, beadRef);
      if (!v.ok) { showError('Cannot render the failure', v.error); return; }
      Dom.el('title').textContent = 'Failure';
      Dom.el('dot').classList.add('bad');
      var fc = Dom.el('f-class'); Dom.clear(fc);
      fc.appendChild(Dom.mk('div', 'ft', v.glance.class + (v.glance.retry_state ? '  ·  ' + v.glance.retry_state : '')));
      fc.appendChild(Dom.mk('div', 'fp', v.glance.class_plain));
      Dom.el('f-tier').textContent = v.summary.silent
        ? v.summary.silent_note : '▸ synced metadata — always visible remote (§4.5).';
      Dom.el('f-tier').classList.toggle('silent', v.summary.silent);
      var fn = Dom.el('f-notes'); Dom.clear(fn);
      if (v.summary.runner_notes.length === 0) fn.appendChild(Dom.mk('div', 'dim', 'No Runner: notes in the synced metadata.'));
      v.summary.runner_notes.forEach(function (n) { fn.appendChild(Dom.mk('div', 'rnote', 'Runner: ' + n)); });
      Dom.el('f-forensic-note').textContent = v.forensic.note;
      Dom.el('f-redbox').hidden = true;
      Dom.el('f-redout').textContent = '';
      var ttl = Dom.el('f-ttl'); if (ttl) { ttl.textContent = ''; ttl.classList.remove('expired'); }
      clearForensicTtlTimer();
      Dom.el('f-dismiss').hidden = true;
      var fb = Dom.el('f-fetch');
      fb.disabled = false;
      fb.textContent = 'Fetch redacted forensic log';
      fb.onclick = function () { fetchForensic(beadRef); };
      Dom.el('f-dismiss').onclick = function () { dismissForensic(beadRef); };
      show('v-failure'); stamp();
    };
    if (lastSnapshot) run(lastSnapshot);
    else Net.getJSON('/api/inbox').then(function (s) { lastSnapshot = s; run(s); })
      .catch(function (e) { showError('Cannot reach the Inbox proxy', e.message); });
  }

  // §10.3: explicit, authed, on-demand. The blob id is correlated by bead_ref
  // (a presentation key — the Coordinator is the authority; a gone/expired
  // blob returns an honest 410, never a fabricated body). The redacted body
  // is the §10.2-shape JSON produced AT THE RUNNER (AD4): file bodies are
  // already stripped to {redacted, byte_length, sha256_prefix} BEFORE
  // transit; the tool_use sequence + errors + last assistant turn survive.
  // This tier renders it; it never re-derives redaction.
  var forensicTtlTimer = null;
  function clearForensicTtlTimer() {
    if (forensicTtlTimer) { clearInterval(forensicTtlTimer); forensicTtlTimer = null; }
  }
  function renderForensicTtl(expiresEpoch) {
    var ttl = Dom.el('f-ttl');
    if (!ttl) return;
    clearForensicTtlTimer();
    if (!expiresEpoch || !isFinite(expiresEpoch)) {
      ttl.textContent = 'self-destructs server-side at its TTL (§10.3)';
      return;
    }
    function tick() {
      var rem = Math.max(0, Math.floor(expiresEpoch - Date.now() / 1000));
      if (rem <= 0) {
        ttl.textContent = '✗ self-destructed — hard-deleted server-side (§10.3)';
        ttl.classList.add('expired');
        clearForensicTtlTimer();
        return;
      }
      var mins = Math.floor(rem / 60);
      var secs = rem % 60;
      var s = mins > 0
        ? 'self-destructs in ' + mins + ' min' + (mins === 1 ? '' : 's') +
          (mins < 5 ? ' ' + secs + 's' : '')
        : 'self-destructs in ' + secs + 's';
      ttl.textContent = '⏳ ' + s + ' — hard-deleted server-side at TTL (§10.3)';
    }
    tick();
    forensicTtlTimer = setInterval(tick, 1000);
  }
  function prettyForensic(text) {
    if (typeof text !== 'string') return JSON.stringify(text, null, 2);
    var t = text.trim();
    if (!t) return '(empty body)';
    try { return JSON.stringify(JSON.parse(t), null, 2); }
    catch (e) { return text; } // not JSON — show verbatim (§10.2 is opaque here)
  }
  function fetchForensic(beadRef) {
    var fb = Dom.el('f-fetch');
    fb.disabled = true; fb.textContent = 'Pulling over the authed channel…';
    fetch('/api/inbox/forensic?id=' + encodeURIComponent(beadRef), {
      method: 'GET',
      headers: { accept: 'application/json' }
    }).then(function (r) {
      var expHdr = r.headers.get('x-forensic-expires-epoch');
      var expEpoch = expHdr ? Number(expHdr) : null;
      return r.text().then(function (t) {
        if (!r.ok) {
          // honest pass-through of the proxy's structured error (gone/expired)
          var msg;
          try { var j = JSON.parse(t); msg = (j && j.error) || ('HTTP ' + r.status); }
          catch (e) { msg = 'HTTP ' + r.status; }
          throw new Error(msg);
        }
        return { body: t, expEpoch: expEpoch };
      });
    }).then(function (res) {
      var det = Dom.el('f-redbox');
      var out = Dom.el('f-redout');
      out.textContent = prettyForensic(res.body);
      det.hidden = false;
      det.open = true;
      renderForensicTtl(res.expEpoch);
      fb.textContent = '✓ Redacted log fetched · transient, not persisted client-side';
      Dom.el('f-dismiss').hidden = false;
    }).catch(function (e) {
      fb.disabled = false; fb.textContent = 'Fetch redacted forensic log';
      toast(e.message); // honest: gone/expired/unreachable, never masked
    });
  }
  function dismissForensic(beadRef) {
    Net.postJSON('/api/inbox/forensic', { id: beadRef }).then(function () {
      clearForensicTtlTimer();
      Dom.el('f-redbox').hidden = true;
      Dom.el('f-dismiss').hidden = true;
      Dom.el('f-fetch').textContent = '✓ Dismissed — hard-deleted server-side (§10.3)';
      Dom.el('f-fetch').disabled = true;
      toast('Forensic blob hard-deleted (irrecoverable — §10.3).');
    }).catch(function (e) { toast(e.message); });
  }

  // ── routing ───────────────────────────────────────────────────────────────
  function route() {
    var h = location.hash.replace(/^#/, '');
    Dom.el('dot').classList.remove('bad');
    if (!h || h === '/' || h === '/inbox') return loadList();
    var m;
    if ((m = h.match(/^\/d\/(.+)$/))) return loadDossier(m[1]);
    if ((m = h.match(/^\/f\/(.+)$/))) return loadFailure(m[1]);
    // bare #<dossier_ref> — the Board's deep-link form (/inbox#<dossier_ref>).
    if (h && h[0] !== '/') return loadDossier(h);
    return loadList();
  }

  Dom.el('back').addEventListener('click', function () { location.hash = '#/'; });
  Dom.el('cf-back').addEventListener('click', function () { location.hash = '#/'; });
  Dom.el('dsubmit').addEventListener('click', submitDossier);
  Dom.el('ddismiss').addEventListener('click', dismissDossier);
  Dom.el('ddefer').addEventListener('click', deferDossier);
  Dom.el('descalate').addEventListener('click', escalateDossier);
  Dom.el('den-skim').addEventListener('click', function () { density = 'skim'; applyDensity(); });
  Dom.el('den-full').addEventListener('click', function () { density = 'full'; applyDensity(); });
  window.addEventListener('hashchange', route);
  // Paint the persistent global nav once on load (Contract C.2). The Inbox is
  // the product — one tap from anywhere; this is the only nav-shell wiring.
  Shell.mount({ active: 'inbox' });
  route();
})();
