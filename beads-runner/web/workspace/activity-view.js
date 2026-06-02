/* beads-runner/web/workspace/activity-view.js — Activity facet (I3,
 * claude-tools-uxvi3; DESIGN I §2 + UX-DESIGN-V2 §5.1/§5.2/§5.4).
 *
 * THE PURE, HEADLESS-TESTABLE CORE of the per-workspace Activity facet — the
 * /ws/<ref>/activity view that answers "what is each agent in THIS workspace
 * doing, and is the runner itself healthy?". No DOM, no network, no timers, no
 * write path: input is the §4.5 work-snapshot projection JSON (the SAME
 * /api/board read every facet consumes) + the workspace ref + now-ms; output is
 * a deterministic view model of strings. lib/test-activity-view.sh drives THIS
 * module against a hand-crafted fixture — the producer↔renderer seam asserted
 * against the FROZEN Contract B.1 activity{}/runner_health{} shapes (the I2
 * projection in cf/src/reconcile.js), never against a faked render.
 *
 * What it renders (DESIGN I §2 lanes + §3 health):
 *   • WRITER LANE — exactly one (B.1 activity.writer one|null). The singularity
 *     is STRUCTURAL (one serial run-beads loop per workspace); the UI makes it
 *     obvious. Shows the 8-key writer shape: bead_ref, title, stage, state,
 *     state_confidence, liveness_dot, seconds_in_state, touching[].
 *   • AUXILIARY POOL — 0..N read-only/non-code agents (B.1 activity.auxiliary[],
 *     the narrower 5-key shape: kind, label, state, state_confidence,
 *     liveness_dot). NO bead_ref/title/seconds to the UI (§1.4).
 *   • RUNNER-HEALTH PIP — the loop PROCESS, DISTINCT from agent activity (§5.4:
 *     "the script gets stuck" ≠ "an agent gets stuck"). B.1 runner_health
 *     {process, heartbeat, last_pickup_at, state}; a wedged runner reads "stuck",
 *     a starved-but-alive one reads "idle" (§5.4 verbatim, findings 180-182).
 *
 * HONESTY (the binding rules — see DESIGN I §6 + UX-DESIGN-V2 §5.2):
 *   • DERIVED, shown as LOOKS-LIKE. state_confidence is ALWAYS "derived"
 *     (principle 10) — NEVER an asserted semantic claim. The tool-derived
 *     semantic states (writing-code/running-tests/exploring/thinking) render as
 *     "looks like: …"; every state carries the visible "derived" confidence so
 *     the card never claims ground truth (§5.2 "may show 'looks like: running
 *     tests' rather than asserting it").
 *   • LIVENESS DOT is separate + blunt: green <90s · amber 90-180s · red >180s.
 *     It is consumed VERBATIM from the projection (the I2 producer already took
 *     the WORSE of the reported dot and the report-age dot, so a dead reporter's
 *     frozen-green is already downgraded). This view NEVER re-derives the 90/180
 *     windows — they are FROZEN [spine] (must-protect #8).
 *   • B.4 TOLERANCE. Every field degrades to an honest placeholder + a degraded[]
 *     note — a missing activity block ⇒ writer:null + empty pool + a note; a
 *     missing/garbled field ⇒ a placeholder, NEVER an exception or a blank (the
 *     4xe / inbox-renderer tolerance — never re-add a render refusal). The ONE
 *     hard refusal is an unknown-HIGHER (or missing/non-integer) schema_version (§0.3).
 *
 * ANTI-DRIFT: presentation derivation ONLY — no write path, no fetch, no DOM.
 * Reads ONLY the keys B.1 promises (must-protect #2, the projection-drop guard):
 * the writer's 8 keys + the aux's 5 keys + runner_health's 4 keys. The activity
 * states it labels are the FROZEN D.2 closed set (enums.js ACTIVITY_STATE); an
 * out-of-set state degrades to an honest placeholder rather than fabricating one.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.ActivityView = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // The contract-bound schema version this view understands (§0.3 / §4.5).
  var SUPPORTED_SNAPSHOT_SCHEMA = 1;

  // §5.2 / D.2 "Activity state" — the FROZEN closed set (enums.js ACTIVITY_STATE).
  // Per state: the human PHRASE, an icon idea ([free] §8), and `looks_like` — the
  // tool-derived semantic guesses (§5.2: rendered "looks like: …", never asserted).
  // The liveness-grounded states (waiting-on-you/rate-limited/maybe-stuck) are
  // factual signals (an in-flight ask-brian call / a real 429 / >180s silence) so
  // they read plainly — but EVERY state still carries state_confidence:"derived".
  var STATE_META = {
    'writing-code':   { label: 'writing code',  icon: '✎', looks_like: true  }, // ✎
    'running-tests':  { label: 'running tests', icon: '▶', looks_like: true  }, // ▶
    'exploring':      { label: 'exploring',     icon: '\u{1f50d}', looks_like: true }, // 🔍
    'thinking':       { label: 'thinking',      icon: '◌', looks_like: true  }, // ◌
    'waiting-on-you': { label: 'waiting on you', icon: '⏸', looks_like: false }, // ⏸
    'rate-limited':   { label: 'rate-limited',  icon: '⏳', looks_like: false }, // ⏳
    'maybe-stuck':    { label: 'maybe stuck',   icon: '⚠', looks_like: false }  // ⚠
  };

  // D.2 liveness dot closed set (consumed verbatim; never re-derived here).
  var LIVENESS_DOT = { green: 1, amber: 1, red: 1 };

  // §3/§5.4 runner_health.state closed set → human label + a class hint. A
  // WEDGED runner reads "stuck" (§5.4 verbatim); a STARVED-but-alive one reads
  // "idle" (§5.4: "a starved-but-alive runner reads as idle"). The pip is drawn
  // DISTINCT from the agent dots (the renderer's job; this names the bucket).
  var RUNNER_STATE_META = {
    working: { label: 'working', cls: 'rh-working' },
    idle:    { label: 'idle',    cls: 'rh-idle' },
    starved: { label: 'starved', cls: 'rh-starved' },
    wedged:  { label: 'stuck',   cls: 'rh-wedged' } // §5.4: a wedged runner reads "stuck"
  };

  /* formatDuration(seconds) → "12s" | "2m12s" | "1h03m" | null. PRESENTATION of
   * the writer's seconds_in_state (NOT a liveness decision). null/negative/
   * non-finite ⇒ null (the renderer omits the line — honest absence). */
  function formatDuration(seconds) {
    if (typeof seconds !== 'number' || !isFinite(seconds) || seconds < 0) return null;
    var s = Math.floor(seconds);
    if (s < 60) return s + 's';
    var m = Math.floor(s / 60);
    if (m < 60) return m + 'm' + pad2(s % 60) + 's';
    var h = Math.floor(m / 60);
    return h + 'h' + pad2(m % 60) + 'm';
  }
  function pad2(n) { return n < 10 ? '0' + n : String(n); }

  /* projectAgentState(rawState) → { state, state_label, looks_like,
   *   state_confidence, icon }. Maps a D.2 enum value to its honest display.
   * An out-of-set / missing state degrades to a labeled placeholder (B.4) — the
   * confidence stays "derived" (nothing is ever asserted). The semantic-tool
   * states render "looks like: …"; the rest read plainly. */
  function projectAgentState(rawState) {
    var meta = (typeof rawState === 'string') ? STATE_META[rawState] : null;
    if (!meta) {
      return {
        state: (typeof rawState === 'string' && rawState) ? rawState : 'unknown',
        state_label: (typeof rawState === 'string' && rawState)
          ? ('looks like: ' + rawState) // unknown-but-present: still a derived guess
          : 'state unknown',
        looks_like: (typeof rawState === 'string' && !!rawState),
        state_confidence: 'derived',
        icon: '·', // ·
        unknown: true
      };
    }
    return {
      state: rawState,
      state_label: meta.looks_like ? ('looks like: ' + meta.label) : meta.label,
      looks_like: meta.looks_like,
      state_confidence: 'derived', // ALWAYS — never asserted (principle 10)
      icon: meta.icon,
      unknown: false
    };
  }

  /* normDot(rawDot, degraded, who) → 'green'|'amber'|'red'|'unknown'. Consumes
   * the projection's liveness_dot VERBATIM (the 90/180 windows are the I2
   * producer's; never re-derived here). An out-of-set/missing dot ⇒ 'unknown' +
   * a degraded note (B.4 — honest, not a fabricated green). */
  function normDot(rawDot, degraded, who) {
    if (typeof rawDot === 'string' && LIVENESS_DOT[rawDot]) return rawDot;
    degraded.push(who + ' liveness dot missing/unknown — shown neutral');
    return 'unknown';
  }

  /* deriveWriter(writerObj, degraded) → the writer-lane view model (one) or null.
   * Reads ONLY B.1's 8 writer keys (must-protect #2). Every field degrades to an
   * honest placeholder; a present-but-fieldless writer still renders a lane. */
  function deriveWriter(writerObj, degraded) {
    if (writerObj == null) return null;
    if (typeof writerObj !== 'object') {
      degraded.push('writer block malformed — treated as no writer');
      return null;
    }
    var st = projectAgentState(writerObj.state);
    var touching = Array.isArray(writerObj.touching)
      ? writerObj.touching.filter(function (x) { return typeof x === 'string' && x; })
      : [];
    return {
      bead_ref: (typeof writerObj.bead_ref === 'string' && writerObj.bead_ref)
        ? writerObj.bead_ref : null,
      title: (typeof writerObj.title === 'string' && writerObj.title)
        ? writerObj.title : null,
      stage: (typeof writerObj.stage === 'string') ? writerObj.stage : '',
      state: st.state,
      state_label: st.state_label,
      looks_like: st.looks_like,
      state_confidence: st.state_confidence,
      icon: st.icon,
      liveness_dot: normDot(writerObj.liveness_dot, degraded, 'writer'),
      seconds_in_state: (typeof writerObj.seconds_in_state === 'number'
        && isFinite(writerObj.seconds_in_state)) ? writerObj.seconds_in_state : null,
      duration_label: formatDuration(writerObj.seconds_in_state),
      touching: touching
    };
  }

  /* deriveAux(auxArr, degraded) → the auxiliary-pool view model (0..N). Reads
   * ONLY B.1's 5 aux keys (kind, label, state, state_confidence, liveness_dot) —
   * NO bead_ref/title/seconds (§1.4: the aux pool shows kind+label+state+dot). */
  function deriveAux(auxArr, degraded) {
    if (!Array.isArray(auxArr)) {
      if (auxArr != null) degraded.push('auxiliary pool malformed — shown empty');
      return [];
    }
    return auxArr.map(function (a, i) {
      var o = (a && typeof a === 'object') ? a : {};
      var st = projectAgentState(o.state);
      var kind = (typeof o.kind === 'string' && o.kind) ? o.kind : '';
      var label = (typeof o.label === 'string' && o.label) ? o.label : (kind || '(aux)');
      return {
        kind: kind,
        label: label,
        state: st.state,
        state_label: st.state_label,
        looks_like: st.looks_like,
        state_confidence: st.state_confidence,
        icon: st.icon,
        liveness_dot: normDot(o.liveness_dot, degraded, 'aux ' + (kind || ('#' + i)))
      };
    });
  }

  /* deriveRunnerHealth(rhObj, degraded) → the §5.4 runner-health pip view model,
   * DISTINCT from agent activity. Reads ONLY B.1's 4 keys {process, heartbeat,
   * last_pickup_at, state}. A missing block degrades to an honest "unknown" pip
   * (present:false) — never a fabricated "working". */
  function deriveRunnerHealth(rhObj, degraded) {
    if (rhObj == null || typeof rhObj !== 'object') {
      if (rhObj != null) degraded.push('runner_health malformed — shown unknown');
      else degraded.push('runner_health not reported — shown unknown');
      return {
        present: false,
        state: 'unknown', state_label: 'unknown', state_class: 'rh-unknown',
        process: 'unknown', heartbeat: 'unknown'
      };
    }
    var meta = RUNNER_STATE_META[rhObj.state] || null;
    if (!meta) degraded.push('runner_health.state out of set — shown raw');
    return {
      present: true,
      state: (typeof rhObj.state === 'string' && rhObj.state) ? rhObj.state : 'unknown',
      state_label: meta ? meta.label
        : ((typeof rhObj.state === 'string' && rhObj.state) ? rhObj.state : 'unknown'),
      state_class: meta ? meta.cls : 'rh-unknown',
      process: (rhObj.process === 'alive' || rhObj.process === 'dead')
        ? rhObj.process : 'unknown',
      heartbeat: (rhObj.heartbeat === 'fresh' || rhObj.heartbeat === 'stale')
        ? rhObj.heartbeat : 'unknown'
    };
  }

  /* deriveActivityView(snapshot, ref, nowMs?) → the whole Activity-facet model.
   * On an unknown HIGHER (or missing/non-integer) schema_version it returns an
   * ERROR view (§0.3 — refuse, never best-effort-render). Otherwise:
   *   { ok:true, principal, schema_version, project_ref, found,
   *     runner_health, writer (one|null), auxiliary[], aux_count, degraded[] }
   * `found:false` (no project for this ref in the projection) is NOT a refusal —
   * it degrades to an honest "no runner reported for <ref>" empty state. */
  function deriveActivityView(snapshot, ref, nowMs) {
    var snap = snapshot && typeof snapshot === 'object' ? snapshot : {};

    var sv = snap.schema_version;
    if (typeof sv !== 'number' || Math.floor(sv) !== sv) {
      return {
        ok: false,
        error:
          'snapshot missing an integer schema_version — refusing to render (§4.5/§0.3)'
      };
    }
    if (sv > SUPPORTED_SNAPSHOT_SCHEMA) {
      return {
        ok: false,
        error:
          'unsupported work-snapshot schema_version ' + sv +
          ' (this Activity facet binds v' + SUPPORTED_SNAPSHOT_SCHEMA +
          ') — refusing to best-effort-render (§0.3)'
      };
    }

    var degraded = [];
    var wsRef = (typeof ref === 'string' && ref) ? ref : null;
    var projects = Array.isArray(snap.projects) ? snap.projects : [];

    var proj = null;
    if (wsRef) {
      for (var i = 0; i < projects.length; i++) {
        var p = projects[i];
        if (p && typeof p === 'object' && p.project_ref === wsRef) { proj = p; break; }
      }
    }

    var found = !!proj;
    if (!wsRef) degraded.push('no workspace ref in the URL — nothing to scope to');
    else if (!found) degraded.push('no runner reported for ' + wsRef + ' in this projection');

    var activity = found && proj.activity && typeof proj.activity === 'object'
      ? proj.activity : null;
    if (found && !activity) degraded.push('activity not reported for this workspace');

    var writer = activity ? deriveWriter(activity.writer, degraded) : null;
    var auxiliary = activity ? deriveAux(activity.auxiliary, degraded) : [];
    var runner_health = deriveRunnerHealth(found ? proj.runner_health : null, degraded);

    return {
      ok: true,
      principal: snap.principal || '(unresolved)',
      schema_version: sv,
      project_ref: wsRef,
      found: found,
      runner_health: runner_health,
      writer: writer,
      auxiliary: auxiliary,
      aux_count: auxiliary.length,
      degraded: degraded
    };
  }

  return {
    deriveActivityView: deriveActivityView,
    deriveWriter: deriveWriter,
    deriveAux: deriveAux,
    deriveRunnerHealth: deriveRunnerHealth,
    projectAgentState: projectAgentState,
    formatDuration: formatDuration,
    STATE_META: STATE_META,
    RUNNER_STATE_META: RUNNER_STATE_META,
    SUPPORTED_SNAPSHOT_SCHEMA: SUPPORTED_SNAPSHOT_SCHEMA
  };
});
