/* beads-runner/web/intake/app.js — I1 (claude-tools-tbl).
 *
 * Browser glue ONLY. Three same-origin, credential-less network calls:
 *   GET  /api/intake/presets    — catalog of entry-intent presets (I4)
 *   GET  /api/intake/workspaces — list of project_refs for the picker dropdown
 *   POST /api/intake            — the ONE write (I2 proxy stamps principal via §9.1)
 *
 * The browser holds NO secret (§9.2) and never picks the principal or op
 * (§9.1) — both proxies are server-side and hard-code their op. This file
 * does not derive control-plane state, never re-renders a "fake" projection,
 * and surfaces a write failure verbatim from the engine (principle 4).
 *
 * The submit affordance is enabled only when the three required fields are
 * non-empty; the preset starts pre-selected so a default Flow A intake is
 * "type one sentence, pick workspace, tap Submit" — ~5 seconds.
 */
(function () {
  'use strict';

  var el = function (id) { return document.getElementById(id); };

  function show(view) {
    el('form').hidden = view !== 'form';
    el('confirm').hidden = view !== 'confirm';
  }
  function toast(m) {
    var p = el('pop'); el('popmsg').textContent = m;
    p.classList.add('on'); clearTimeout(toast._t);
    toast._t = setTimeout(function () { p.classList.remove('on'); }, 2800);
  }

  // ── network ────────────────────────────────────────────────────────────────
  // Identical contract on both proxies: { ok: bool, error?: string, ... }.
  // We always read the body as text first so a non-JSON 5xx still surfaces
  // the HTTP status honestly (never silently render an empty state).
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

  // ── preset radio cards (I4 · claude-tools-vvh) ────────────────────────────
  // Rendered at run-time from /api/intake/presets so the radio set is
  // catalog-driven (agents/intake-presets.json → _presets-catalog.js →
  // /api/intake/presets). The browser does NOT carry a hard-coded preset
  // list; adding a preset to the catalog ships a new radio on next deploy
  // with no client edit.
  var presetsLoaded = false;
  function loadPresets() {
    var box = el('presets');
    if (!box) return;  // DOM regression — fail safely (Submit stays disabled).
    var loading = el('presets-loading');
    // Defensive: if loadPresets() ever runs twice (a wiring regression or a
    // future "retry" affordance), wipe previously-rendered radio labels so
    // we never paint duplicates. The <legend> stays so screen-reader
    // semantics survive the re-render.
    Array.prototype.slice.call(box.querySelectorAll('label.preset'))
      .forEach(function (n) { n.parentNode.removeChild(n); });
    getJSON('/api/intake/presets').then(function (d) {
      var ps = d && Array.isArray(d.presets) ? d.presets : [];
      if (ps.length === 0) {
        // Honest empty: the catalog file has no rows. A submit is
        // impossible without a preset, so we leave the loading line
        // visible (changed) and never enable Submit. (This should never
        // happen in practice; the catalog has a v1 default.)
        if (loading) loading.textContent = 'No entry intents configured.';
        presetsLoaded = true;
        refreshSubmit();
        return;
      }
      if (loading && loading.parentNode) loading.parentNode.removeChild(loading);
      ps.forEach(function (p, i) {
        if (!p || typeof p.value !== 'string') return;
        var lbl = document.createElement('label');
        lbl.className = 'preset';
        var radio = document.createElement('input');
        radio.type = 'radio';
        radio.name = 'preset';
        radio.value = p.value;
        if (i === 0) radio.checked = true;
        radio.addEventListener('change', refreshSubmit);
        var t = document.createElement('span');
        t.className = 'ptitle';
        t.textContent = p.label || p.value;
        var s = document.createElement('span');
        s.className = 'psub';
        s.textContent = p.sublabel || '';
        lbl.appendChild(radio);
        lbl.appendChild(t);
        lbl.appendChild(s);
        box.appendChild(lbl);
      });
      presetsLoaded = true;
      refreshSubmit();
    }).catch(function (e) {
      // Don't fabricate a preset list. Surface the honest reason and
      // leave Submit disabled — there is no safe default to inline here
      // (the engine-side allowlist may have changed).
      if (loading) loading.textContent = 'Cannot load entry intents: ' + e.message;
      el('dot').classList.add('bad');
    });
  }

  // ── workspace dropdown ────────────────────────────────────────────────────
  var workspacesLoaded = false;
  function loadWorkspaces() {
    var sel = el('workspace');
    var hint = el('ws-hint');
    getJSON('/api/intake/workspaces').then(function (d) {
      // Reset the loading placeholder.
      while (sel.firstChild) sel.removeChild(sel.firstChild);
      var ws = Array.isArray(d.workspaces) ? d.workspaces : [];
      if (ws.length === 0) {
        // Honest empty — the engine has no known workspaces. The user can
        // still type a fresh project_ref; we expose a manual option so a
        // first-ever intake on a new deployment is not blocked.
        var opt = document.createElement('option');
        opt.value = ''; opt.disabled = true; opt.selected = true;
        opt.textContent = 'No known workspaces';
        sel.appendChild(opt);
        hint.hidden = false;
        hint.textContent = 'No workspaces yet — start a runner first.';
        sel.disabled = true;
      } else {
        var placeholder = document.createElement('option');
        placeholder.value = ''; placeholder.disabled = true; placeholder.selected = true;
        placeholder.textContent = ws.length === 1
          ? 'Pick workspace (1 known)'
          : 'Pick workspace (' + ws.length + ' known)';
        sel.appendChild(placeholder);
        ws.forEach(function (ref) {
          var opt = document.createElement('option');
          opt.value = ref;
          opt.textContent = ref;
          sel.appendChild(opt);
        });
        // Flow A "let it pick" affordance: if there is only one workspace,
        // pre-select it so the picker is a single tap to confirm — the
        // common case on a one-project deployment.
        if (ws.length === 1) {
          sel.value = ws[0];
          hint.hidden = false;
          hint.textContent = 'One known workspace — pre-selected.';
        }
        sel.disabled = false;
      }
      workspacesLoaded = true;
      refreshSubmit();
    }).catch(function (e) {
      // Don't fabricate a workspace list. Show the picker as disabled and
      // surface the honest reason — the user can retry by reloading. The
      // page is not usable until the picker works (no workspace = no write).
      while (sel.firstChild) sel.removeChild(sel.firstChild);
      var opt = document.createElement('option');
      opt.value = ''; opt.disabled = true; opt.selected = true;
      opt.textContent = 'Cannot load workspaces';
      sel.appendChild(opt);
      sel.disabled = true;
      hint.hidden = false;
      hint.textContent = 'Workspace list unavailable: ' + e.message;
      el('dot').classList.add('bad');
    });
  }

  // ── form state ────────────────────────────────────────────────────────────
  function selectedPreset() {
    var radios = document.querySelectorAll('input[name="preset"]');
    for (var i = 0; i < radios.length; i++) {
      if (radios[i].checked) return radios[i].value;
    }
    return '';
  }
  function refreshSubmit() {
    var idea = el('idea').value.trim();
    var ws = el('workspace').value;
    var preset = selectedPreset();
    var ok = !!idea && !!ws && !!preset && workspacesLoaded && presetsLoaded;
    el('submit').disabled = !ok;
  }

  // ── submit ────────────────────────────────────────────────────────────────
  var submitting = false;
  function onSubmit(ev) {
    ev.preventDefault();
    if (submitting) return;
    var idea = el('idea').value.trim();
    var ws = el('workspace').value;
    var preset = selectedPreset();
    var err = el('errline');
    err.hidden = true; err.textContent = '';

    if (!idea) {
      err.textContent = 'Type one sentence first.';
      err.hidden = false; return;
    }
    if (!ws) {
      err.textContent = 'Pick a workspace.';
      err.hidden = false; return;
    }
    if (!preset) {
      err.textContent = 'Pick an entry intent.';
      err.hidden = false; return;
    }

    submitting = true;
    var btn = el('submit');
    btn.disabled = true;
    el('submit-label').textContent = 'Submitting…';

    postJSON('/api/intake', {
      idea_text: idea,
      project_ref: ws,
      preset: preset
    }).then(function (d) {
      // Successful enqueue. The I2 proxy returns the assigned intake id so
      // Brian has a handle to grep for if the bead does not appear within
      // ~60s (mirrors the proxy's own comment).
      var rec = el('receipt');
      rec.textContent = d && d.intake_id
        ? 'Intake id: ' + d.intake_id
        : 'Enqueued.';
      show('confirm');
      submitting = false;
      el('submit-label').textContent = 'Submit';
    }).catch(function (e) {
      submitting = false;
      el('submit-label').textContent = 'Submit';
      btn.disabled = false;
      err.textContent = e && e.message ? e.message : 'Submit failed.';
      err.hidden = false;
      // Toast so the message catches the eye even if the form is scrolled.
      toast('Not enqueued — see error.');
    });
  }

  // ── reset for "Another" ───────────────────────────────────────────────────
  function resetForAnother() {
    el('idea').value = '';
    el('errline').hidden = true; el('errline').textContent = '';
    // Keep the previously-picked workspace + preset — Flow A repeats are
    // usually same workspace, same intent. The user can change either.
    show('form');
    refreshSubmit();
    // Focus the text area so the keyboard pops back up on phones (one tap
    // less to start the next idea).
    try { el('idea').focus(); } catch (_) {}
  }

  // ── wire up ───────────────────────────────────────────────────────────────
  document.addEventListener('DOMContentLoaded', function () {
    el('form').addEventListener('submit', onSubmit);
    el('idea').addEventListener('input', refreshSubmit);
    el('workspace').addEventListener('change', refreshSubmit);
    // Note: preset radios are rendered by loadPresets() and bind their
    // own change handlers there — no static document.querySelectorAll
    // sweep here, since the radio set is run-time-rendered (I4).
    el('another').addEventListener('click', resetForAnother);
    loadPresets();
    loadWorkspaces();
    refreshSubmit();
  });
}());
