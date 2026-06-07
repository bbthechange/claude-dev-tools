/* beads-runner/web/shared/runner-card.js — claude-tools-758l.
 *
 * THE shared per-runner CARD renderer (Contract C.1, the dom.js sibling). The
 * runner's honest state row + the Flow-D desired-state control row were built
 * inline in board/app.js and (state row only) in workspace/app.js; they live
 * here ONCE as `window.RunnerCard` so the Board (/board), the per-workspace
 * Board facet (/ws/<ref>/board), and the Workspaces card (/workspaces) render
 * the runner state + Run/Pause/Spare-only/Stop controls IDENTICALLY (UX-DESIGN-V2
 * §2 "one tap from the workspace card"; §4 Flow D "honest state: the Board shows
 * actual").
 *
 *   RunnerCard.renderStateRow(r, Dom)
 *     → a DocumentFragment: the state pill + label, the live current_task line,
 *       the stale actual_note, and the stale-controls warning. The READ display.
 *   RunnerCard.renderControls(r, onSetDesired, Dom)
 *     → a DocumentFragment: the div.rctrls of four button.rbtn (from r.controls[],
 *       produced by board-view.js / workspaces-view.js) + the pending banner. Each
 *       button's tap calls onSetDesired(r.project_ref, c.state, btn); the CALLER
 *       owns the POST + the pendingDesired bookkeeping (so the §9.1 write seam
 *       stays page-local — this module has NO network).
 *
 * Presentation ONLY (the dom.js discipline): no network, no app state, no
 * honest-state decisions. `active`/`pending_label`/`stale_controls_note` are
 * consumed verbatim from the view-model — S-1 (a stale runner has no active
 * button) and principle 4 (the pending banner never promotes actual) are
 * enforced UPSTREAM in the pure view-models, never here. Uses the passed `Dom`
 * helper (textContent, never innerHTML — XSS-safe by construction). The CSS lives
 * in /shared/tokens.css (the control selectors are bare so they also style the
 * Workspaces card's .ws-runner-controls wrapper). */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.RunnerCard = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // The state row: pill + label, then the optional live current-task line, the
  // stale last-reported actual_note, and the stale-controls warning. Each is
  // gated on the view-model field (absent ⇒ honestly nothing) — the view drops
  // current_task for a stale runner (S-1), so absence is correct, not a bug.
  function renderStateRow(r, Dom) {
    var frag = document.createDocumentFragment();

    var st = Dom.mk('div', 'rstate');
    st.appendChild(Dom.mk('span', 'pill ' + r.state_class));
    st.appendChild(Dom.mk('span', null, r.state_label));
    frag.appendChild(st);

    // 8ag/4g5o — a LIVE runner's current_task_ref (+ optional title, truncated).
    if (r.current_task) {
      var line = Dom.mk('code', 'workspace-current-task', r.current_task);
      if (r.current_task_title) {
        var t = r.current_task_title;
        if (t.length > 60) t = t.slice(0, 60) + '…';
        line.appendChild(document.createTextNode(' — '));
        line.appendChild(Dom.mk('span', 'workspace-current-task-title', t));
      }
      frag.appendChild(line);
    }

    // S-1 — a stale runner's last-reported actual is muted CONTEXT, never a pill.
    if (r.actual_note) frag.appendChild(Dom.mk('div', 'rnote', r.actual_note));
    // Stale-controls warning: still tappable, but honestly flagged.
    if (r.stale_controls_note) frag.appendChild(Dom.mk('div', 'rstale', r.stale_controls_note));

    return frag;
  }

  // The control row: four buttons keyed to r.controls[] (Run / Pause /
  // Spare-only / Stop), then the optional pending banner. `active` reflects the
  // current ACTUAL (the view-model enforces — never desired). Each tap delegates
  // to onSetDesired so the calling page owns the write + the ephemeral pending
  // capture (principle 4: the pending banner is a separate, secondary line and
  // never promotes actual).
  function renderControls(r, onSetDesired, Dom) {
    var frag = document.createDocumentFragment();

    var controlsBox = Dom.mk('div', 'rctrls');
    (r.controls || []).forEach(function (c) {
      var btn = Dom.mk('button', 'rbtn' + (c.active ? ' active' : ''), c.label);
      btn.setAttribute('type', 'button');
      btn.setAttribute('aria-label',
        'Set ' + r.project_ref + ' desired-state to ' + c.state);
      btn.setAttribute('aria-pressed', c.active ? 'true' : 'false');
      btn.dataset.state = c.state;
      btn.addEventListener('click', function () {
        onSetDesired(r.project_ref, c.state, btn);
      });
      controlsBox.appendChild(btn);
    });
    frag.appendChild(controlsBox);

    // Pending banner (principle 4): "desired: X (waiting for runner to honor)" —
    // a separate line, never promoted to the actual pill. Cleared by the caller
    // when the next refresh reports actual === pending.
    if (r.pending_label) frag.appendChild(Dom.mk('div', 'rpending', r.pending_label));

    return frag;
  }

  return { renderStateRow: renderStateRow, renderControls: renderControls };
});
