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

  var el = function (id) { return document.getElementById(id); };
  function clear(n) { while (n.firstChild) n.removeChild(n.firstChild); }
  function mk(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }
  function show(view) {
    ['v-list', 'v-dossier', 'v-confirm', 'v-failure', 'errbox'].forEach(function (v) {
      el(v).hidden = v !== view;
    });
    el('loading').hidden = true;
    el('ddock').hidden = view !== 'v-dossier';
    el('back').hidden = view === 'v-list';
    el('scroll').scrollTop = 0;
  }
  function showError(h, b) {
    el('err-h').textContent = h || 'Cannot render';
    el('err-b').textContent = b || '';
    el('dot').classList.add('bad');
    show('errbox');
  }
  function toast(m) {
    var p = el('pop'); el('popmsg').textContent = m;
    p.classList.add('on'); clearTimeout(toast._t);
    toast._t = setTimeout(function () { p.classList.remove('on'); }, 2800);
  }
  function stamp() { el('foot-updated').textContent = 'updated ' + new Date().toLocaleTimeString(); }

  // ── network: every call is same-origin + credential-less (§9.1) ───────────
  function getJSON(url) {
    return fetch(url, { method: 'GET', headers: { accept: 'application/json' } })
      .then(function (r) {
        return r.text().then(function (t) {
          var d; try { d = JSON.parse(t); } catch (e) {
            throw new Error('proxy returned non-JSON (HTTP ' + r.status + ')');
          }
          if (d && d.ok === false && d.error) throw new Error(d.error);
          if (!r.ok) throw new Error('proxy HTTP ' + r.status);
          return d;
        });
      });
  }
  function postJSON(url, body) {
    return fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json', accept: 'application/json' },
      body: JSON.stringify(body)
    }).then(function (r) {
      return r.text().then(function (t) {
        var d; try { d = JSON.parse(t); } catch (e) { d = { ok: r.ok, raw: t }; }
        if (d && d.ok === false && d.error) throw new Error(d.error);
        if (!r.ok) throw new Error('write proxy HTTP ' + r.status);
        return d;
      });
    });
  }

  // ── INBOX LIST + Flow-G glance ────────────────────────────────────────────
  var lastSnapshot = null;
  function loadList() {
    show('loading'); el('loading').hidden = false;
    getJSON('/api/inbox').then(function (snap) {
      lastSnapshot = snap;
      var v = IV.deriveInboxList(snap);
      if (!v.ok) { showError('Cannot render the Inbox', v.error); return; }
      el('who').textContent = v.principal;
      el('title').textContent = 'Inbox';
      el('dot').classList.toggle('bad', v.failures.length > 0);
      el('list-sub').textContent = v.items.length === 0
        ? 'The product. Nothing needs you — everything is flowing.'
        : 'The product. ' + v.items.length +
          (v.items.length === 1 ? ' thing' : ' things') + ' need you' +
          (v.failures.length ? ' · ' + v.failures.length + ' failing' : '') + '.';
      var rows = el('rows'); clear(rows);
      el('list-empty').hidden = v.items.length !== 0;
      v.items.forEach(function (it) {
        var a = mk('a', 'inrow t-' + it.tier);
        a.setAttribute('href', it.dossier_href || '#/');
        var tier = mk('div', 'tier');
        tier.appendChild(mk('span', 'tg', it.tier));
        tier.appendChild(mk('span', 'ref', it.bead_ref || it.dossier_ref));
        a.appendChild(tier);
        a.appendChild(mk('div', 'h', it.label));
        a.appendChild(mk('div', 'd', it.auto_proceeds
          ? 'Read-mostly — auto-proceeds on silence (reversible). Open to skim or object.'
          : 'Open the dossier — skim it, then resolve in any mix. Your “no” is one tap.'));
        rows.appendChild(a);
      });
      var fg = el('flowg'); var fails = el('fails'); clear(fails);
      fg.hidden = v.failures.length === 0;
      v.failures.forEach(function (f) {
        var c = mk('a', 'failrow');
        c.setAttribute('href', f.failure_href || '#/');
        c.appendChild(mk('div', 'fbadge', f.badge));
        c.appendChild(mk('div', 'h', f.title + '  ·  ' + f.bead_ref));
        c.appendChild(mk('div', 'd', f.class_plain));
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
    show('loading'); el('loading').hidden = false;
    getJSON('/api/dossier?id=' + encodeURIComponent(id)).then(function (rec) {
      curDossier = rec;
      var v = IV.deriveDossierView(rec);
      curView = v;
      if (!v.ok) {
        // ANTI-DRIFT: a missing MANDATORY §5 field is a §11 escalation, NOT a
        // best-effort render. Surface it verbatim — never fabricate.
        showError(v.escalation ? 'Refusing to render — §11 escalation' : 'Cannot render this dossier', v.error);
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
    clear(host);
    host.appendChild(mk('div', 'dgerr', why || 'could not render — showing Mermaid source'));
    host.appendChild(mk('pre', 'dgc dgc-fallback', src));
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
    el('title').textContent = v.profile === 'overview' ? 'Overview' : 'Dossier';
    el('back').hidden = false;
    el('d-tier').textContent = v.tier;
    el('d-tier').className = 'badge t-' + v.tier;
    el('d-meta').textContent = v.bead_ref + ' · ' + (v.trigger || v.kind) +
      ' · ' + v.rollup.total + ' call' + (v.rollup.total === 1 ? '' : 's');
    el('d-eyer').textContent = (v.profile === 'overview' ? 'PROACTIVE OVERVIEW' : 'DECISION DOSSIER') +
      ' · ' + (v.trigger || v.kind);
    el('d-title').textContent = v.body.tldr;
    el('d-tldr').textContent = v.body.tldr;
    var fb = el('fyi-banner');
    fb.hidden = !v.auto_proceeds;
    if (v.auto_proceeds) fb.textContent = 'Read-mostly brief — not a blocker. ' + v.timer_note +
      '. Flag a concern on anything that looks wrong; silence is a valid input (principle 6).';

    var secs = el('d-sections'); clear(secs);
    v.body.sections.forEach(function (s) {
      var d = mk('div', 'dsec');
      d.appendChild(mk('h2', null, s.heading));
      d.appendChild(mk('p', 'prose', s.prose));
      secs.appendChild(d);
    });
    var dgs = el('d-diagrams'); clear(dgs);
    var pending = [];
    v.body.diagrams.forEach(function (g) {
      var d = mk('div', 'diagram');
      d.appendChild(mk('div', 'dgl', g.caption));
      var host = mk('div', 'dgsvg');
      // The Mermaid SOURCE goes in as textContent (never innerHTML);
      // mermaid.run() replaces this node's content with sanitized SVG.
      var node = mk('pre', 'mermaid', g.content);
      host.appendChild(node);
      d.appendChild(host);
      dgs.appendChild(d);
      pending.push({ host: host, node: node, src: g.content });
    });
    if (pending.length) renderDiagrams(pending);
    el('d-full').textContent = v.body.full_detail;

    var box = el('d-items'); clear(box);
    v.items.forEach(function (it) { box.appendChild(renderItem(it)); });
    applyDensity();
    recount();
  }

  // The affordance is rendered FROM item.kind (§5.2). reject/edit/freeform/
  // object are each ONE control — symmetric with approve (principle 3 / EXIT
  // crit 2: no penalty path). context_anchor is rendered INLINE, always (AD7).
  function renderItem(it) {
    var du = mk('div', 'du');
    du.dataset.item = it.id;
    if (it.terminal) du.classList.add('done');

    var q = mk('div', 'du-q');
    q.appendChild(mk('div', 'du-tag', it.kind));
    q.appendChild(mk('div', 'du-ttl', it.framing.ask || '(ask)'));
    if (it.framing.why) q.appendChild(mk('div', 'du-why', it.framing.why));
    // MANDATORY context_anchor, inline (the AD7 self-contained-context line).
    var ca = mk('div', 'du-anchor');
    ca.appendChild(mk('span', 'cl', 'WHERE'));
    ca.appendChild(mk('span', 'ct', it.context_anchor.where + ' — ' + it.context_anchor.expansion));
    q.appendChild(ca);
    if (it.recommendation && it.recommendation.value != null) {
      var rec = mk('div', 'du-rec');
      rec.appendChild(mk('span', 'rl', 'REC'));
      rec.appendChild(mk('span', 'rt', String(it.recommendation.value) +
        (it.recommendation.why ? ' — ' + it.recommendation.why : '')));
      q.appendChild(rec);
    }
    q.appendChild(mk('div', 'du-rev', '↩ ' + it.reversible));
    du.appendChild(q);

    if (it.terminal) {
      du.appendChild(mk('div', 'du-resolved', '✓ ' + (it.response_summary || it.state)));
      return du;
    }

    var acts = mk('div', 'du-acts');
    it.affordances.forEach(function (a) {
      var b = mk('button', 'k k-' + a, ({
        approve: 'Approve', reject: 'Reject', pick: 'Options',
        edit: 'Edit', freeform: 'React', object: 'Object'
      })[a] || a);
      b.type = 'button';
      b.addEventListener('click', function () { actItem(du, it, a); });
      acts.appendChild(b);
    });
    du.appendChild(acts);

    // expandable sub-controls (options / edit / freeform)
    var ex = mk('div', 'du-ex'); ex.hidden = true;
    if (it.options.length) {
      var ow = mk('div', 'du-opts'); ow.appendChild(mk('div', 'ol', 'PICK AN OPTION'));
      it.options.forEach(function (o) {
        var ch = mk('button', 'optchip', '');
        ch.type = 'button';
        ch.appendChild(mk('span', 'oc', o.label));
        if (o.blast_radius) ch.appendChild(mk('small', null, o.blast_radius));
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
      var ew = mk('div', 'du-editwrap');
      ew.appendChild(mk('div', 'el', 'EDIT THE RECOMMENDATION — the reconciler reads this (§5.2.2)'));
      var ed = mk('div', 'du-edit'); ed.contentEditable = 'true'; ed.spellcheck = false;
      ed.textContent = (it.recommendation && it.recommendation.value != null)
        ? String(it.recommendation.value) : '';
      ed.addEventListener('input', function () {
        setItem(du, it, { action: 'edit', edited_value: ed.textContent.trim() });
      });
      ew.appendChild(ed); ex.appendChild(ew);
    }
    var nw = mk('div', 'du-notewrap');
    var ta = mk('textarea', 'du-note'); ta.rows = 2;
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
    du.appendChild(mk('div', 'du-state'));
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
    el('progT').textContent = total;
    el('progN').textContent = resolved;
    el('prog').style.width = total ? (resolved / total * 100) + '%' : '0%';
    var openLeft = total - resolved;
    var ov = curView.profile === 'overview' || curView.auto_proceeds;
    el('dsum').textContent = nowResolved === 0
      ? (ov ? 'Read-mostly. Touch only what looks wrong — silence auto-proceeds (reversible).'
            : 'Resolve in any mix. ' + openLeft + ' open · partial is fine, untouched items block nothing (AD7).')
      : nowResolved + ' staged · ' + openLeft + ' still open';
    el('dsubmit').textContent = ov && nowResolved === 0
      ? 'Acknowledge' : (nowResolved === 0 ? 'Submit' : 'Submit ' + nowResolved);
  }

  function applyDensity() {
    el('v-dossier').classList.toggle('d-skim', density === 'skim');
    el('v-dossier').classList.toggle('d-full', density === 'full');
    el('den-skim').classList.toggle('on', density === 'skim');
    el('den-full').classList.toggle('on', density === 'full');
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
    el('dsubmit').disabled = true;
    el('dsubmit').textContent = 'Submitting…';
    var chain = Promise.resolve();
    var errs = [];
    ids.forEach(function (iid) {
      var it = curView.items.filter(function (x) { return x.id === iid; })[0];
      var built = IV.buildItemResponse(it, formState[iid], Date.now());
      if (!built.ok) { errs.push(iid + ': ' + built.error); return; }
      chain = chain.then(function () {
        return postJSON('/api/respond', {
          dossier_id: curView.id, item_id: iid, response: built.response
        }).catch(function (e) { errs.push(iid + ': ' + e.message); });
      });
    });
    chain.then(function () {
      el('dsubmit').disabled = false;
      // Honest re-fetch is the source of truth (failed items correctly show
      // as still-open, S-2). errs[] is passed through so the ack states
      // PERSISTENTLY which submits failed and why — not a vanishing toast
      // (principle 4: never mask the real failure).
      refetchAck(errs);
    });
  }

  // EXIT crit 1 / S-2: the ack is the RE-FETCHED §4 Dossier's latch-true
  // state (control-plane truth the Coordinator reconciles into beads) — NOT a
  // Dolt read. "You don't need to go check" is honest because of this.
  function refetchAck(errs) {
    errs = errs || [];
    getJSON('/api/dossier?id=' + encodeURIComponent(curView.id)).then(function (rec) {
      var c = IV.deriveConfirm(rec);
      if (!c.ok) { showError('Cannot render the ack', c.error); return; }
      el('title').textContent = 'Confirmed';
      el('cf-h').textContent = errs.length
        ? 'Partial — some submits failed.'
        : (c.all_resolved ? 'One pass. Whole stage cleared.' : 'Partial — and that’s fine.');
      el('cf-ack').textContent = c.honest_note;
      var rc = el('cf-receipt'); clear(rc);
      // Persistent, not a toast: exactly which items did NOT apply and why
      // (they correctly read as still-open above — this is the honest cause).
      errs.forEach(function (e) {
        rc.appendChild(mk('div', 'ri am', '⚠ NOT applied — ' + e));
      });
      if (c.receipt.deterministic_count) {
        rc.appendChild(mk('div', 'ri', '✓ ' + c.receipt.deterministic_count +
          ' applied deterministically — pre-declared, instant (§5.2.2)'));
      }
      if (c.receipt.reconciler_count) {
        rc.appendChild(mk('div', 'ri', '↻ ' + c.receipt.reconciler_count +
          ' to the reconciler — re-surfaces only if it conflicts or opens a new question'));
      }
      rc.appendChild(mk('div', 'ri', '✓ ' + c.bead_ref +
        ' reconciled by the Coordinator (control→work, S-2) — no Dolt-lag lie'));
      if (c.receipt.still_open) {
        rc.appendChild(mk('div', 'ri am', '· ' + c.receipt.still_open +
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
      el('title').textContent = 'Failure';
      el('dot').classList.add('bad');
      var fc = el('f-class'); clear(fc);
      fc.appendChild(mk('div', 'ft', v.glance.class + (v.glance.retry_state ? '  ·  ' + v.glance.retry_state : '')));
      fc.appendChild(mk('div', 'fp', v.glance.class_plain));
      el('f-tier').textContent = v.summary.silent
        ? v.summary.silent_note : '▸ synced metadata — always visible remote (§4.5).';
      el('f-tier').classList.toggle('silent', v.summary.silent);
      var fn = el('f-notes'); clear(fn);
      if (v.summary.runner_notes.length === 0) fn.appendChild(mk('div', 'dim', 'No Runner: notes in the synced metadata.'));
      v.summary.runner_notes.forEach(function (n) { fn.appendChild(mk('div', 'rnote', 'Runner: ' + n)); });
      el('f-forensic-note').textContent = v.forensic.note;
      el('f-redout').hidden = true;
      el('f-dismiss').hidden = true;
      var fb = el('f-fetch');
      fb.disabled = false;
      fb.textContent = 'Fetch redacted forensic log';
      fb.onclick = function () { fetchForensic(beadRef); };
      el('f-dismiss').onclick = function () { dismissForensic(beadRef); };
      show('v-failure'); stamp();
    };
    if (lastSnapshot) run(lastSnapshot);
    else getJSON('/api/inbox').then(function (s) { lastSnapshot = s; run(s); })
      .catch(function (e) { showError('Cannot reach the Inbox proxy', e.message); });
  }

  // §10.3: explicit, authed, on-demand. The blob id is correlated by bead_ref
  // (a presentation key — the Coordinator is the authority; a gone/expired
  // blob returns an honest 410, never a fabricated body).
  function fetchForensic(beadRef) {
    var fb = el('f-fetch');
    fb.disabled = true; fb.textContent = 'Pulling over the authed channel…';
    getJSON('/api/forensic?id=' + encodeURIComponent(beadRef)).then(function (blob) {
      var out = el('f-redout');
      out.hidden = false;
      out.textContent = typeof blob === 'string' ? blob : JSON.stringify(blob, null, 2);
      fb.textContent = '✓ Redacted log fetched · transient, not persisted client-side';
      el('f-dismiss').hidden = false;
    }).catch(function (e) {
      fb.disabled = false; fb.textContent = 'Fetch redacted forensic log';
      toast(e.message); // honest: gone/expired/unreachable, never masked
    });
  }
  function dismissForensic(beadRef) {
    postJSON('/api/forensic', { id: beadRef }).then(function () {
      el('f-redout').hidden = true;
      el('f-dismiss').hidden = true;
      el('f-fetch').textContent = '✓ Dismissed — hard-deleted server-side (§10.3)';
      el('f-fetch').disabled = true;
      toast('Forensic blob hard-deleted (irrecoverable — §10.3).');
    }).catch(function (e) { toast(e.message); });
  }

  // ── routing ───────────────────────────────────────────────────────────────
  function route() {
    var h = location.hash.replace(/^#/, '');
    el('dot').classList.remove('bad');
    if (!h || h === '/' || h === '/inbox') return loadList();
    var m;
    if ((m = h.match(/^\/d\/(.+)$/))) return loadDossier(m[1]);
    if ((m = h.match(/^\/f\/(.+)$/))) return loadFailure(m[1]);
    // bare #<dossier_ref> — the Board's deep-link form (/inbox#<dossier_ref>).
    if (h && h[0] !== '/') return loadDossier(h);
    return loadList();
  }

  el('back').addEventListener('click', function () { location.hash = '#/'; });
  el('cf-back').addEventListener('click', function () { location.hash = '#/'; });
  el('dsubmit').addEventListener('click', submitDossier);
  el('den-skim').addEventListener('click', function () { density = 'skim'; applyDensity(); });
  el('den-full').addEventListener('click', function () { density = 'full'; applyDensity(); });
  window.addEventListener('hashchange', route);
  route();
})();
