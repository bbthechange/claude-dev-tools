/* beads-runner/web/capacity/capacity-view.js — C-shell CAPACITY global view
 * (unit label: capacity-view; UX-DESIGN-V2 §2.1/§2.2).
 *
 * THE PURE, HEADLESS-TESTABLE CORE of the Capacity view. It answers the §2.2
 * question — "How much Claude budget is left, and what mode is each project
 * in?" — by turning the §4.5 work-snapshot projection (the SAME /api/board
 * read the Board consumes) into a deterministic view model of strings + bands.
 * No DOM, no network, no timers, no write path — input is the projection JSON,
 * output is `{ ok, … }`. capacity/app.js drives this; lib/test-capacity-view.sh
 * asserts it via a Node require, mirroring lib/test-board.sh's technique.
 *
 * TWO SURFACES, ONE READ:
 *   • machines[] — the DEDICATED detailed capacity surface. Where the Board's
 *     top strip is compact, here machines are the PRIMARY content, so each row
 *     carries labeled per-metric bands, the allowed-classes line, the observed
 *     age, and the keychain/api/partial breadcrumb chips.
 *   • modes[]    — one row per project: its HONEST actual runner mode, the
 *     desired target on a mismatch, and the liveness (a stale runner is NEVER
 *     promoted to a live mode — principle 4 / S-1).
 *
 * ANTI-DRIFT (band + allowed semantics): this module RE-IMPLEMENTS the §4.B
 * color bands and the §4.A <allowed> line self-contained but LOGICALLY
 * IDENTICAL to web/board/board-view.js deriveMachine, which binds FROZEN
 * MACHINE-STATE.md v1 (D2). Capacity and the Board MUST agree — they read the
 * same machines[] shape and the same gate semantic:
 *   bands are driven by `threshold_in_effect` (NEVER a hardcoded 70); gate
 *   disabled (threshold===0 or gate_disabled===true) or threshold≤0 ⇒ neutral
 *   (un-banded); a missing pct ⇒ '—' + 'partial' chip (degrade per-field, §4.E);
 *   a stale record (fresh===false) ⇒ grayed + 'stale' badge (§4.C). The
 *   <allowed_text> mirrors daemon/usage-poll.sh:_usage_poll_compute_allowed.
 * If the daemon's rule or the band formula moves, BOTH this and board-view.js
 * update in lockstep; a divergence is a D2 drift — reopen D2, never edit it
 * silently. Oracle = MACHINE-STATE.md + test-fixtures/machine-state-v1.json +
 * lib/test-capacity-view.sh.
 *
 * §0.3 strictness (the 4xe write-gate/render-tolerance line): the ONLY hard
 * refusal is an unknown-HIGHER schema_version (or a missing/non-integer one) —
 * we return `{ ok:false, error }` and the app shows "update the app". Every
 * other gap degrades per-field with an honest placeholder; never fabricate.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.CapacityView = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // The contract-bound projection schema this view understands (§4.5/§0.3).
  var SUPPORTED_SNAPSHOT_SCHEMA = 1;

  /* formatPct(n) → "<n>%" | "—". Defensive per §4.E: a non-number degrades to
   * an em-dash, never a fabricated 0%. Whole numbers render without a decimal;
   * floats keep one. Mirrors board-view.js formatPct exactly. */
  function formatPct(n) {
    if (typeof n !== 'number' || !isFinite(n)) return '—';
    if (n === Math.floor(n)) return n + '%';
    return n.toFixed(1) + '%';
  }

  /* formatAgeSeconds(s) → "<n>s" | "<n>m" | "<n>h" | "<n>d" | "unknown".
   * Same bucketing as board-view.js formatAgeSeconds — one observed-age idiom
   * across both surfaces. */
  function formatAgeSeconds(s) {
    if (typeof s !== 'number' || !isFinite(s) || s < 0) return 'unknown';
    if (s < 90) return Math.floor(s) + 's';
    var m = Math.floor(s / 60);
    if (m < 90) return m + 'm';
    var h = Math.floor(m / 60);
    if (h < 48) return h + 'h';
    return Math.floor(h / 24) + 'd';
  }

  /* deriveMachineRow(rec) → one detailed per-machine capacity row.
   * `rec` is a snapshot.machines[] entry shaped per MACHINE-STATE.md §3.A.
   * Render-tolerance: NEVER refuses a row; degrades per-field. The band +
   * allowed logic is LOGICALLY IDENTICAL to board-view.js deriveMachine (see
   * the anti-drift banner). */
  function deriveMachineRow(rec) {
    var r = (rec && typeof rec === 'object' && !Array.isArray(rec)) ? rec : {};
    var t = (typeof r.threshold_in_effect === 'number' && isFinite(r.threshold_in_effect))
      ? r.threshold_in_effect : null;
    // §4.D — gate disabled when the convenience mirror is set OR threshold is 0.
    var gateDisabled = r.gate_disabled === true || t === 0;

    var has5h = typeof r.pct_5h === 'number' && isFinite(r.pct_5h);
    var has7d = typeof r.pct_7d === 'number' && isFinite(r.pct_7d);
    var hasRamp = typeof r.spare_ramp_today === 'number' && isFinite(r.spare_ramp_today);
    var partial = !has5h || !has7d || !hasRamp;

    // §4.B color bands — driven by threshold_in_effect, NEVER a Board constant.
    // gate disabled / threshold≤0 / null ⇒ neutral (un-banded); missing pct ⇒
    // 'missing' (no false color). Identical formula to board-view.js band().
    function band(pct, has) {
      if (!has) return 'missing';
      if (gateDisabled || t === null || t <= 0) return 'neutral';
      if (pct >= t) return 'red';
      if (pct >= 0.5 * t) return 'amber';
      return 'green';
    }

    // §4.C staleness: the projection's `fresh` flag is authoritative (C3
    // derives it from age_seconds ≤ 2×USAGE_POLL_TTL_SECONDS); we do NOT
    // re-derive. fresh===false ⇒ grayed numbers ('stale' band) + a badge.
    var fresh = r.fresh !== false;
    var pct5hBand = fresh ? band(r.pct_5h, has5h) : 'stale';
    var pct7dBand = fresh ? band(r.pct_7d, has7d) : 'stale';
    var rampBand = fresh ? 'neutral' : 'stale';

    // <allowed> — mirror of daemon/usage-poll.sh:_usage_poll_compute_allowed.
    // Same formula keeps Capacity, the Board, and the daemon on one gate
    // semantic. A divergence is a D2 drift (reopen, never silently edit).
    var allowedText;
    if (gateDisabled || t === null || t <= 0) {
      allowedText = 'standard,low_priority';
    } else if ((has5h && r.pct_5h >= t) || (has7d && r.pct_7d >= t)) {
      allowedText = '(none — over)';
    } else if (has7d && hasRamp && r.pct_7d >= r.spare_ramp_today) {
      allowedText = 'standard';
    } else {
      allowedText = 'standard,low_priority';
    }

    var ageSec = (typeof r.age_seconds === 'number' && isFinite(r.age_seconds))
      ? r.age_seconds : null;
    var ageStr = formatAgeSeconds(ageSec);

    var rid = (typeof r.runner_id === 'string' && r.runner_id) ? r.runner_id : '—';

    return {
      runner_id: rid,
      pct_5h_text: formatPct(r.pct_5h),
      pct_5h_band: pct5hBand,
      pct_7d_text: formatPct(r.pct_7d),
      pct_7d_band: pct7dBand,
      ramp_text: formatPct(r.spare_ramp_today),
      ramp_band: rampBand,
      allowed_text: allowedText,
      age_text: ageStr,
      fresh: fresh,
      gate_disabled: gateDisabled,
      // Breadcrumb chips (§4.C/§4.D/§4.E) — degrade per-field, never collapse.
      stale_chip: fresh ? null : ('stale ' + ageStr),
      gate_disabled_chip: gateDisabled ? 'gate disabled' : null,
      keychain_chip: r.keychain_ok === false ? 'keychain unreadable' : null,
      api_chip: r.usage_api_ok === false ? 'usage API failed' : null,
      partial_chip: partial ? 'partial' : null
    };
  }

  // §4.2 runner `actual` is a CLOSED enum; the closed desired/actual mode set
  // is running | paused | spare-only | stopped (brief / §4.5). A live runner
  // reads as its honest actual; we NEVER paint desired over actual (principle
  // 4) and a stale runner is NEVER promoted to a live mode (S-1).
  var ACTUAL_LIVE_MODES = {
    running: 1, paused: 1, 'spare-only': 1, stopped: 1, idle: 1, starting: 1
  };

  /* deriveModeRow(p) → one per-project mode row.
   *   { project_ref, actual, desired, mismatch, liveness, mode_label }
   * mode_label is the HONEST actual; on a mismatch it appends
   * "(target: <desired>)" so the unreached target is shown WITHOUT collapsing
   * one onto the other. A stale runner's last actual is NOT promoted — its
   * mode_label reads "stale" so it cannot lie as a live mode (S-1). */
  function deriveModeRow(p) {
    var rs = (p && p.runner_state) || {};
    var liveness = rs.liveness === 'live' ? 'live' : 'stale'; // honest default
    var actual = (typeof rs.actual === 'string' && rs.actual) ? rs.actual : null;
    var desired = (typeof rs.desired === 'string' && rs.desired) ? rs.desired : null;
    var mismatch = rs.desired_actual_mismatch === true;
    var ref = (p && p.project_ref) ? p.project_ref : '(unknown)';

    var modeLabel;
    if (liveness === 'stale') {
      // S-1 — a stale runner is not "currently in" any live mode. Surface the
      // last-reported actual only as muted context inside the honest label.
      modeLabel = actual ? ('stale (last: ' + actual + ')') : 'stale';
    } else {
      var base = actual || 'unknown';
      // Honest desired≠actual (principle 4): show actual, then the target.
      modeLabel = (mismatch && desired) ? (base + ' (target: ' + desired + ')') : base;
    }

    return {
      project_ref: ref,
      actual: actual,
      desired: desired,
      mismatch: mismatch,
      liveness: liveness,
      // A presentational flag the renderer uses to flag a true live mode vs.
      // a stale/unknown one; pure-projection-derived, never fabricated.
      live_mode: liveness === 'live' && actual && ACTUAL_LIVE_MODES[actual] ? true : false,
      mode_label: modeLabel
    };
  }

  /* deriveCapacityView(snapshot, nowMs) → the whole Capacity view model.
   * snapshot is the parsed §4.5 work-snapshot JSON (the /api/board read).
   * On an unknown-HIGHER or missing/non-integer schema_version it returns an
   * ERROR view (§0.3 — refuse, never best-effort-render the future). `nowMs`
   * is accepted for parity with the view-model pattern; this view derives all
   * freshness from the projection's own `fresh`/`age_seconds` (the Board never
   * has to know the TTL), so nowMs is currently unused but kept in the
   * signature so a future age-on-read can read the clock honestly. */
  function deriveCapacityView(snapshot, nowMs) {
    var snap = snapshot && typeof snapshot === 'object' && !Array.isArray(snapshot)
      ? snapshot : {};

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
          ' (this Capacity view binds v' + SUPPORTED_SNAPSHOT_SCHEMA +
          ') — update the app; refusing to best-effort-render (§0.3)'
      };
    }

    // §3.A machines[] — the primary content. §3.C: an empty array is HONEST
    // (no fresh telemetry from any machine); machines_empty drives the app's
    // "no telemetry yet" banner, NEVER a phantom ok.
    var rawMachines = Array.isArray(snap.machines) ? snap.machines : [];
    var machines = rawMachines.map(deriveMachineRow);

    // modes[] — one per project, in projection order.
    var projects = Array.isArray(snap.projects) ? snap.projects : [];
    var modes = projects.map(deriveModeRow);

    return {
      ok: true,
      schema_version: sv,
      principal: (typeof snap.principal === 'string' && snap.principal)
        ? snap.principal : '(unresolved)',
      read_only: snap.read_only === true,
      machines: machines,
      modes: modes,
      machines_empty: machines.length === 0
    };
  }

  return {
    deriveCapacityView: deriveCapacityView,
    deriveMachineRow: deriveMachineRow,
    deriveModeRow: deriveModeRow,
    formatPct: formatPct,
    formatAgeSeconds: formatAgeSeconds,
    SUPPORTED_SNAPSHOT_SCHEMA: SUPPORTED_SNAPSHOT_SCHEMA
  };
});
