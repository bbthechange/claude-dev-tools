/* beads-runner/web/board/board-view.js — T6a (claude-tools-p2m).
 *
 * THE PURE, HEADLESS-TESTABLE CORE of the Board web app. It is the ONLY place
 * the §4.5 work-snapshot projection is turned into what the screen shows. No
 * DOM, no network, no timers — input is the projection JSON, output is a
 * deterministic view model of strings. lib/test-board.sh drives THIS module
 * against the REAL projection emitted by coordinator.sh co__work_snapshot, so
 * the producer↔renderer seam is asserted against the frozen contract, not a
 * hand-faked shape.
 *
 * BINDS — INTERFACE.md v1 (FROZEN), the sections T6a owns per §11:
 *   §4.2  — `liveness` (`live` | `stale`, DERIVED by the Coordinator at read
 *           time, NEVER re-derived here) + the honest desired≠actual surface
 *           (principle 4: the Board shows ACTUAL, never optimistic). A
 *           `stale` runner is rendered as "stale (last seen Nh ago)" and is
 *           structurally INCAPABLE of reading as `actual: running` (S-1).
 *   §4.5  — the read-only projection it RENDERS: per-project RunnerState +
 *           coarse capacity strip, the lifecycle columns (idea→done) keyed by
 *           `stage:`, the WAITING-ON-YOU lane (Dossiers w/ ≥1 open item), and
 *           per-bead failure metadata for Flow G tiers 1–2.
 *   §0.3  — unknown HIGHER schema_version ⇒ REJECT (never best-effort-parse),
 *           exactly as every §4 consumer must.
 *
 * ANTI-DRIFT (task contract): presentation ONLY. This module NEVER invents a
 * field, NEVER re-derives liveness/health *state* (it formats contract
 * fields — a timestamp delta into "Nh ago" is presentation, not derived
 * state), and has NO write path. A field the Board genuinely needs but the
 * §4.5 producer does not emit is a §11 escalation to claude-tools-65z — NOT a
 * UI-side fabrication. MUST NOT render the Inbox/dossier body or the §10
 * forensic stream (that is T6b) — the WAITING-ON-YOU lane is a pointer, never
 * the dossier content.
 *
 * ANTI-DRIFT (sibling): the per-machine capacity strip ALSO binds FROZEN
 * MACHINE-STATE.md v1 (D2). `deriveMachine` consumes `snapshot.machines[]`
 * (the §3.A field set the C3 projection emits) and presents the §4.A strip:
 *   runner_id · 5h <pct>% · 7d <pct>% · ramp <pct>% · <allowed> · observed <age> ago
 * Color bands (§4.B) are driven by `threshold_in_effect` (NEVER hardcoded
 * 70 — moving the env threshold re-bands on the next snapshot tick with no
 * Board redeploy). Staleness (§4.C), gate-disabled (§4.D), and missing-field
 * (§4.E) are degrade-per-field, never all-or-nothing — same render-tolerance
 * discipline as the 4xe write-gate/render-tolerance memory. A D2 gap ⇒
 * reopen D2 and re-freeze; NEVER edit MACHINE-STATE.md silently.
 * Oracle = MACHINE-STATE.md + test-fixtures/machine-state-v1.json + the
 * EXIT-8 clauses in lib/test-board.sh.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.BoardView = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // The contract-bound schema version this renderer understands (§0.3 / §4.5).
  var SUPPORTED_SNAPSHOT_SCHEMA = 1;

  // §4.5 lifecycle columns — the C1-seam stage ladder, FROZEN order. "" is the
  // honest un-staged bucket the producer emits for an unknown/missing stage
  // (never silently folded into impl).
  var STAGE_ORDER = ['idea', 'ux', 'design', 'impl', 'docs', 'tests', 'done', ''];

  // §4.2 `actual` is a CLOSED enum. A live runner reads as its actual; the
  // honest-state rule (principle 4) means we never paint desired over actual.
  var ACTUAL_HEALTHY_ACTIVE = { running: 1, idle: 1, starting: 1 };

  // G1 (claude-tools-b6y) — the "silent" failure classes (UX principle 7:
  // surface silent failures LOUDER than loud ones, because they ROT — they
  // looked green but aren't, or a dependency vanished without a hard fail).
  // Authoritative classification lives in the producer (cf/src/reconcile.js
  // + lib/coordinator.sh); this set is the renderer's BACK-COMPAT FALLBACK,
  // used only when an older producer omits the explicit `silent` boolean.
  // The two MUST stay in sync — if you add a silent class, add it BOTH.
  var SILENT_CLASSES = {
    TASK_NOT_CLOSED: 1,
    SUBAGENT_MISSING: 1,
    MCP_DOWN: 1
  };
  function isSilentClass(cls) {
    if (typeof cls !== 'string') return false;
    if (SILENT_CLASSES[cls]) return true;
    return cls.indexOf('TOOL_ERROR') === 0;
  }

  /* deriveWaitingOn(w) → the J5 (claude-tools-uxvj5) inline "waiting on" reason
   * for a held lifecycle card (DESIGN J §7.5). The projection's cards[].waiting_on
   * is now the holds[]-DERIVED object {type, unblocks_when, gate_id|task_ref,
   * editable, more} (was a runner-stamped free string). This turns it into the
   * one-line view-model the column paints: {type, glyph, text, editable, more}.
   *
   * The §7.5 invariant the renderer must honor: "a held card never renders
   * without a reason." So EVERY recognized hold yields non-empty text — a gate
   * whose unblock_condition is still null (placed before metadata existed, B.4)
   * degrades to "held by <gate_id> · no unblock condition yet", never a blank.
   * An unheld card (waiting_on null) returns null ⇒ no waiting line. Tolerant by
   * construction: a malformed/unknown hold still shows an honest "held" line
   * rather than throwing or rendering "[object Object]". Presentation only —
   * never invents a hold the projection didn't carry. */
  function deriveWaitingOn(w) {
    if (!w || typeof w !== 'object') return null;
    var type = (typeof w.type === 'string' && w.type) ? w.type : 'held';
    var cond = (typeof w.unblocks_when === 'string' && w.unblocks_when) ? w.unblocks_when : null;
    var more = (typeof w.more === 'number' && w.more > 0) ? w.more : 0;
    var glyph, text;
    if (type === 'dependency') {
      glyph = '⛓'; // ⛓ — a hard block (beads-native)
      text = 'blocked' + (cond ? ' · ' + cond
        : (typeof w.blocked_on === 'string' && w.blocked_on ? ' on ' + w.blocked_on : ''));
    } else if (type === 'gate') {
      glyph = '⛔'; // ⛔ — our editable Gate
      var gid = (typeof w.gate_id === 'string' && w.gate_id) ? w.gate_id : 'gate';
      text = 'held by ' + gid + (cond ? ' · unblocks when ' + cond
        : ' · no unblock condition yet');
    } else if (type === 'scheduled') {
      glyph = '⏰'; // ⏰ — a defer date (beads-native)
      text = 'deferred' + (cond ? ' until ' + cond : '');
    } else {
      glyph = '⏸'; // ⏸ — unknown hold shape, still surfaced honestly
      text = 'held' + (cond ? ' · ' + cond : '');
    }
    if (more > 0) text += ' (+' + more + ' more)';
    return { type: type, glyph: glyph, text: text, editable: w.editable === true, more: more };
  }

  // F2 (claude-tools-8fh) — the four FROZEN desired-states the per-workspace
  // toggle row exposes. Pinned in the same order as set-desired.js's
  // ALLOWED_STATES so a UI typo and an engine typo cannot drift apart. The
  // label is presentation; the `state` is the wire value the F1 client sends.
  var DESIRED_CONTROLS = [
    { state: 'running',    label: 'Run' },
    { state: 'paused',     label: 'Pause' },
    { state: 'spare-only', label: 'Spare-only' },
    { state: 'stopped',    label: 'Stop' }
  ];

  // Q1 (claude-tools-uxvq1) — the §9 net-velocity (runaway-expansion) alarm
  // threshold. net_velocity_7d = created − closed over 7 days; POSITIVE means
  // more opened than closed = the queue is GROWING ("8 hours, more open than we
  // started"). The exact cutoff is [free] / UX-DESIGN-V2 Open-Q#3 — a named,
  // tunable constant, NOT a magic number scattered in the logic. The contract
  // intent ("positive trend = runaway alarm") is `> 0`; raise this to require a
  // steeper trend before alarming, with NO change to the producer/projection
  // (the alarm derives from the surfaced number, the contract-test invariant).
  var NET_VELOCITY_ALARM_THRESHOLD = 0;

  /* deriveQueueHealth(qh, opts?) → the §9 / B.1 queue_health view model.
   *
   * Q1 (claude-tools-uxvq1). `qh` is a projects[].queue_health block (per B.1:
   * { ready, held{gate,dependency,scheduled}, hidden_under_deferred_parent,
   * net_velocity_7d, epics_with_zero_ready_children }). The projection always
   * emits a normalized block (zeroed when the runner hasn't published), so this
   * is tolerant-by-construction: a missing/garbage field degrades to 0/[] and
   * the strip still renders (the same render-tolerance discipline as
   * deriveMachine). Presentation ONLY — every number is a projection fact; the
   * alarm BOOLEAN is derived from net_velocity_7d (a presentation threshold,
   * not new state). Reused for BOTH the per-project row and the board-level
   * aggregate strip (deriveBoardView sums the projects into one qh-shaped
   * object and calls this again). */
  function deriveQueueHealth(qh, opts) {
    var q = (qh && typeof qh === 'object' && !Array.isArray(qh)) ? qh : {};
    var held = (q.held && typeof q.held === 'object' && !Array.isArray(q.held)) ? q.held : {};
    function n(v) { return (typeof v === 'number' && isFinite(v)) ? v : 0; }
    var ready = n(q.ready);
    var gate = n(held.gate), dep = n(held.dependency), sched = n(held.scheduled);
    var heldTotal = gate + dep + sched;
    var hidden = n(q.hidden_under_deferred_parent);
    // net_velocity may be NEGATIVE (a draining/healthy queue) — keep the sign.
    var netV = (typeof q.net_velocity_7d === 'number' && isFinite(q.net_velocity_7d))
      ? q.net_velocity_7d : 0;
    var epics = Array.isArray(q.epics_with_zero_ready_children)
      ? q.epics_with_zero_ready_children.filter(function (x) { return typeof x === 'string' && x; })
      : [];
    var threshold = (opts && typeof opts.net_velocity_threshold === 'number' && isFinite(opts.net_velocity_threshold))
      ? opts.net_velocity_threshold : NET_VELOCITY_ALARM_THRESHOLD;
    var velocityAlarm = netV > threshold; // positive trend = runaway (§9)
    // claude-tools-t5ud (§9 row 4) — audit coverage (read/total), OPTIONAL.
    // Present ONLY when an agent audit has reported N items for this workspace
    // (null = no audit ⇒ the strip shows nothing). coverage_complete answers the
    // §9 trust question "did the audit read everything?" — read>=total = yes.
    // Tolerant-by-construction: a malformed block degrades to null (no chip).
    var rawAc = (q.audit_coverage && typeof q.audit_coverage === 'object' && !Array.isArray(q.audit_coverage))
      ? q.audit_coverage : null;
    var ac = (rawAc &&
      typeof rawAc.total === 'number' && isFinite(rawAc.total) && rawAc.total > 0 &&
      typeof rawAc.read === 'number' && isFinite(rawAc.read))
      ? { read: Math.max(0, Math.min(rawAc.read, rawAc.total)), total: rawAc.total }
      : null;
    var coverageComplete = ac ? ac.read >= ac.total : true;
    var coverageText = ac ? (ac.read + '/' + ac.total + ' read') : '';
    // The empty-queue explainer fires only when there is NO ready work AND a
    // REASON to explain it (held/hidden/blocked-by-epic work) — "why is bd ready
    // empty / only epics?" An all-zero queue (no work at all) is NOT an alarm.
    var emptyQueue = ready === 0 && (heldTotal > 0 || hidden > 0 || epics.length > 0);
    var netText = (netV > 0 ? '+' : '') + netV + '/7d net';
    var explainer = ready + ' ready · ' + heldTotal + ' held' +
      (heldTotal ? ' (' + gate + ' gate · ' + dep + ' dep · ' + sched + ' sched)' : '') +
      ' · ' + hidden + ' hidden under deferred parent';
    return {
      ready: ready,
      held: { gate: gate, dependency: dep, scheduled: sched },
      held_total: heldTotal,
      hidden_under_deferred_parent: hidden,
      net_velocity_7d: netV,
      velocity_alarm: velocityAlarm,
      velocity_text: netText,
      epics_with_zero_ready_children: epics,
      epics_zero_ready_count: epics.length,
      empty_queue: emptyQueue,
      explainer: explainer,
      // claude-tools-t5ud (§9 row 4) — audit coverage. `audit_coverage` is
      // null unless an audit reported; coverage_complete/coverage_text are the
      // derived presentation of the read/total ratio.
      audit_coverage: ac,
      coverage_complete: coverageComplete,
      coverage_text: coverageText
    };
  }

  /* formatAgo(fromIso, nowMs?) → "Nm" | "Nh" | "Nd" | "Ns" — a presentation
   * formatting of the §4.2 `last_heartbeat_at` contract datum (NOT a derived
   * liveness decision; that is the Coordinator's, consumed verbatim). Honest
   * when the datum is missing/unparseable: "unknown". */
  function formatAgo(fromIso, nowMs) {
    if (!fromIso) return 'unknown';
    var t = Date.parse(fromIso);
    if (isNaN(t)) return 'unknown';
    var now = typeof nowMs === 'number' ? nowMs : Date.now();
    var s = Math.max(0, Math.floor((now - t) / 1000));
    if (s < 90) return s + 's';
    var m = Math.floor(s / 60);
    if (m < 90) return m + 'm';
    var h = Math.floor(m / 60);
    if (h < 48) return h + 'h';
    return Math.floor(h / 24) + 'd';
  }

  /* deriveRunner(p, nowMs, pendingDesired) → the per-project RunnerState view row.
   *
   * THE S-1 INVARIANT lives here: liveness comes ONLY from the projection
   * (§4.2 Coordinator-derived). A `stale` runner gets state_class="stale" and
   * a label "stale (last seen Nh ago)"; its last-reported `actual` is shown
   * ONLY as muted secondary context and NEVER promoted to the live
   * running/idle pill. A stale runner therefore cannot read as
   * `actual: running` — the lie S-1/C6 forbids. A live runner shows its
   * honest actual, and an honest "→ target: <desired>" when desired≠actual
   * (principle 4 — stopping… is literally true, never optimistic).
   *
   * F2 (claude-tools-8fh) — the per-row CONTROLS view. The four toggle
   * buttons (Run / Pause / Spare-only / Stop) reflect the workspace's current
   * ACTUAL state from the §4.5 projection — NEVER desired (principle 4: the
   * Board shows ACTUAL, never optimistic). `pendingDesired` is a
   * client-side ephemeral capture of "the user just tapped X" — it surfaces
   * as a "desired: X (waiting for runner to honor)" banner UNTIL the next
   * refresh reports actual=X (then app.js clears the pending entry). The
   * pending banner is NEVER allowed to promote actual; it is a separate
   * secondary line. A stale runner's controls are still rendered (the user
   * can request a desired-state change) but flagged "may not apply quickly"
   * so the user is not misled into thinking the tap was honored. */
  function deriveRunner(p, nowMs, pendingDesired) {
    var rs = (p && p.runner_state) || {};
    var liveness = rs.liveness === 'live' ? 'live' : 'stale'; // honest default
    var actual = rs.actual || null;
    var desired = rs.desired || null;
    var mismatch = rs.desired_actual_mismatch === true;
    var ago = formatAgo(rs.last_heartbeat_at, nowMs);

    var row = {
      project_ref: p && p.project_ref ? p.project_ref : '(unknown)',
      liveness: liveness,
      actual: actual,
      desired: desired,
      mismatch: mismatch,
      last_heartbeat_at: rs.last_heartbeat_at || null,
      ago: ago
      // capacity_verdict — REMOVED in claude-tools-zdxd.5 (C4). The §4.5
      // projection no longer carries projects[].capacity_strip (C3 dropped
      // it per MACHINE-STATE.md §3.B); per-machine usage is now surfaced by
      // the top-of-board strip via deriveMachine. The over-capacity warn
      // tag at deriveBoardView is kept as a dormant slot for future §1.1
      // capacity_reports wiring — currently always empty by construction.
    };

    if (liveness === 'stale') {
      // S-1: stale is its OWN state, never the running/idle pill.
      row.state_class = 'stale';
      row.state_label = 'stale (last seen ' + ago + ' ago)';
      row.actual_note = actual ? 'last reported: ' + actual : null;
      // S-1: a stale runner's last-reported current_task_ref is an honest
      // unknown ("we don't know what it's doing now"); do NOT promote it
      // as the "currently working on" secondary line.
      row.current_task = null;
      row.current_task_title = null;
    } else {
      var isActive = actual && ACTUAL_HEALTHY_ACTIVE[actual];
      // g2s — soft 'thinking' visual between 90s and 180s heartbeat age.
      // Purely presentational: wire `liveness` stays binary (§4.2 frozen);
      // the Board still consumes it verbatim for control-button gating
      // (S-1 invariant — `row.controls[].active` below still keys off
      // `liveness === 'live'`, never off state_class). The threshold
      // softens the visual jump caused by a long legitimate stream gap
      // (spelunk report: p99=40–742s tool_result gaps) flipping the pill
      // from live→stale at the 180s STALE_AFTER cliff. Scoped to
      // `actual === 'running'` because idle/starting silence is honest,
      // not "thinking after a big tool_result".
      var nowForAge = typeof nowMs === 'number' ? nowMs : Date.now();
      var hbT = rs.last_heartbeat_at ? Date.parse(rs.last_heartbeat_at) : NaN;
      var ageMs = isNaN(hbT) ? 0 : (nowForAge - hbT);
      var thinking = isActive && actual === 'running' &&
        ageMs >= 90000 && ageMs < 180000;
      var base = actual || 'unknown';
      if (thinking) {
        row.state_class = 'thinking';
        row.state_label = base + ' · last event ' + ago + ' ago';
      } else {
        row.state_class = isActive ? 'live' :
          (actual ? 'attention' : 'unknown');
        // Honest desired≠actual (principle 4): show the actual, then the
        // unreached target — never collapse one onto the other.
        row.state_label = mismatch && desired
          ? base + ' (target: ' + desired + ')'
          : base;
      }
      row.actual_note = null;
      // 8ag — a live runner's current_task_ref is the secondary "currently
      // working on" line on the workspace strip. claude-tools-4g5o — the
      // CF projection now joins the §4.6 workspace_inventory record's
      // in_progress_beads[] to surface a title for the ref; absent record
      // or no match degrades gracefully to ref-only (title=null).
      row.current_task = (typeof rs.current_task_ref === 'string' && rs.current_task_ref)
        ? rs.current_task_ref : null;
      row.current_task_title = (typeof rs.current_task_title === 'string' && rs.current_task_title)
        ? rs.current_task_title : null;
    }

    // F2 — per-row controls. `active` is the button matching CURRENT ACTUAL
    // (NEVER desired). A stale runner has NO active button (S-1: a stale
    // runner has no honest live state to highlight).
    row.controls = DESIRED_CONTROLS.map(function (c) {
      return {
        state: c.state,
        label: c.label,
        active: liveness === 'live' && actual === c.state
      };
    });

    // Pending banner — client-side ephemeral. Only surface if the pending
    // state has NOT yet been observed as actual; honest "waiting" phrasing.
    var pState = pendingDesired && typeof pendingDesired.state === 'string'
      ? pendingDesired.state : null;
    if (pState && pState !== actual) {
      row.pending_desired = pState;
      row.pending_label = 'desired: ' + pState +
        ' (waiting for runner to honor)';
    } else {
      row.pending_desired = null;
      row.pending_label = null;
    }

    // Stale-controls warning. Controls are still tappable (the daemon may
    // wake the workspace), but the user is told outcomes may lag.
    row.stale_controls_note = liveness === 'stale'
      ? 'stale — last seen ' + ago + ' ago, controls may not apply quickly'
      : null;

    // Q1 (claude-tools-uxvq1) — per-project §9 / B.1 queue_health. UNLIKE the
    // runner-state fields above, queue_health is NOT gated by liveness: it is
    // the WORK-TRUTH queue shape (ready/held/hidden/velocity/epics), valid even
    // when the runner is stale or stopped (a paused workspace can still have a
    // runaway backlog Brian needs to see). Always present in the projection
    // (normalized zeroed default), so the row always carries a block.
    row.queue_health = deriveQueueHealth(p && p.queue_health);

    return row;
  }

  /* formatPct(n) → "<n>%" | "—". Defensive: a non-number degrades to em-dash
   * per MACHINE-STATE.md §4.E (per-field degrade, never all-or-nothing). A
   * whole number renders without a decimal; a float keeps one decimal. */
  function formatPct(n) {
    if (typeof n !== 'number' || !isFinite(n)) return '—';
    if (n === Math.floor(n)) return n + '%';
    return n.toFixed(1) + '%';
  }

  /* formatAgeSeconds(s) → "<n>s" | "<n>m" | "<n>h" | "<n>d" | "unknown".
   * Mirrors formatAgo's bucketing for the §4.A "observed <age> ago" slot. */
  function formatAgeSeconds(s) {
    if (typeof s !== 'number' || !isFinite(s) || s < 0) return 'unknown';
    if (s < 90) return Math.floor(s) + 's';
    var m = Math.floor(s / 60);
    if (m < 90) return m + 'm';
    var h = Math.floor(m / 60);
    if (h < 48) return h + 'h';
    return Math.floor(h / 24) + 'd';
  }

  /* deriveMachine(rec) → the per-machine view row for the §4.A top-of-board
   * capacity strip. `rec` is a snapshot.machines[] entry shaped per
   * MACHINE-STATE.md §3.A (the C3 projection adds `fresh` + `age_seconds`).
   *
   * Render-tolerance discipline (4xe memory + MACHINE-STATE §4 head note):
   * the Board NEVER refuses to render a strip. A missing pct degrades to
   * `—` (§4.E); a stale record renders grayed with a 'stale Nm ago' badge
   * (§4.C); gate disabled (threshold=0 or gate_disabled=true) ⇒ neutral
   * palette + 'gate disabled' chip but the strip STAYS (§4.D).
   *
   * The `<allowed>` slot in §4.A re-derives the daemon's gating decision
   * from the wire fields using the SAME formula as
   * daemon/usage-poll.sh:_usage_poll_compute_allowed — the Board never
   * introduces a different gate semantic. */
  function deriveMachine(rec) {
    var r = (rec && typeof rec === 'object' && !Array.isArray(rec)) ? rec : {};
    var t = (typeof r.threshold_in_effect === 'number' && isFinite(r.threshold_in_effect))
      ? r.threshold_in_effect : null;
    var gateDisabled = r.gate_disabled === true || t === 0;

    var has5h = typeof r.pct_5h === 'number' && isFinite(r.pct_5h);
    var has7d = typeof r.pct_7d === 'number' && isFinite(r.pct_7d);
    var hasRamp = typeof r.spare_ramp_today === 'number' && isFinite(r.spare_ramp_today);
    var partial = !has5h || !has7d || !hasRamp;

    // §4.B color bands — driven by threshold_in_effect, NEVER a Board constant.
    // gate disabled ⇒ neutral (un-banded) per §4.D.
    function band(pct, has) {
      if (!has) return 'missing';
      if (gateDisabled || t === null || t <= 0) return 'neutral';
      if (pct >= t) return 'red';
      if (pct >= 0.5 * t) return 'amber';
      return 'green';
    }

    // §4.C staleness: fresh===false ⇒ grayed numbers + stale badge. The
    // projection's `fresh` flag is authoritative (C3 derives it from
    // age_seconds ≤ 2×USAGE_POLL_TTL_SECONDS); the Board does NOT re-derive.
    var fresh = r.fresh !== false;
    var pct5hBand = fresh ? band(r.pct_5h, has5h) : 'stale';
    var pct7dBand = fresh ? band(r.pct_7d, has7d) : 'stale';
    var rampBand = fresh ? 'neutral' : 'stale';

    // <allowed> — mirror of daemon/usage-poll.sh:_usage_poll_compute_allowed.
    // Same formula keeps a single source of truth for the gate semantic; if
    // the daemon's rule changes, both update in lockstep (binding-map drift
    // would surface in the conformance bead, claude-tools-zdxd.6).
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

    var pct5hText = formatPct(r.pct_5h);
    var pct7dText = formatPct(r.pct_7d);
    var rampText = formatPct(r.spare_ramp_today);
    var rid = (typeof r.runner_id === 'string' && r.runner_id) ? r.runner_id : '—';

    // The composite text the §4.A format prescribes — produced here so
    // headless tests can assert against it without walking each slot.
    var stripText = rid +
      ' · 5h ' + pct5hText +
      ' · 7d ' + pct7dText +
      ' · ramp ' + rampText +
      ' · ' + allowedText +
      ' · observed ' + ageStr + ' ago';

    return {
      runner_id: rid,
      pct_5h_text: pct5hText,
      pct_7d_text: pct7dText,
      ramp_text: rampText,
      pct_5h_band: pct5hBand,
      pct_7d_band: pct7dBand,
      ramp_band: rampBand,
      allowed_text: allowedText,
      age_text: ageStr,
      fresh: fresh,
      stale_label: fresh ? null : ('stale ' + ageStr),
      gate_disabled: gateDisabled,
      gate_disabled_chip: gateDisabled ? 'gate disabled' : null,
      keychain_chip: r.keychain_ok === false ? 'keychain unreadable' : null,
      api_chip: r.usage_api_ok === false ? 'usage API failed' : null,
      partial_chip: partial ? 'partial' : null,
      strip_text: stripText
    };
  }

  /* deriveBoardView(snapshot, nowMs?, opts?) → the whole Board view model.
   * snapshot is the parsed §4.5 work-snapshot JSON. On an unknown HIGHER
   * schema_version it returns an ERROR view (§0.3 — refuse, never
   * best-effort-render).
   *
   * F2 (claude-tools-8fh): `opts.pending_desired` is an optional
   * { [project_ref]: { state } } map of client-side ephemeral "user just
   * tapped" captures. It is NOT a contract field — the projection remains
   * authoritative and this overlay can NEVER promote actual; it only
   * supplies the secondary "waiting for runner to honor" banner. */
  function deriveBoardView(snapshot, nowMs, opts) {
    var snap = snapshot && typeof snapshot === 'object' ? snapshot : {};
    var pendingMap = (opts && opts.pending_desired && typeof opts.pending_desired === 'object')
      ? opts.pending_desired : {};

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
          ' (this Board binds v' + SUPPORTED_SNAPSHOT_SCHEMA +
          ') — refusing to best-effort-render (§0.3)'
      };
    }

    var projects = Array.isArray(snap.projects) ? snap.projects : [];
    var runners = projects.map(function (p) {
      var ref = p && p.project_ref ? p.project_ref : '(unknown)';
      return deriveRunner(p, nowMs, pendingMap[ref] || null);
    });

    // WAITING-ON-YOU lane — §4.5: stored Dossiers (this principal) with ≥1
    // still-open item. The producer emits COUNTS only (no dossier content —
    // that is T5/T6b). This lane is a POINTER into the Inbox, never the
    // dossier body (anti-drift: T6a MUST NOT render the dossier UI).
    var rawWoy = Array.isArray(snap.waiting_on_you) ? snap.waiting_on_you : [];
    var waiting = rawWoy.map(function (w) {
      var n = typeof w.open_item_count === 'number' ? w.open_item_count : 0;
      return {
        dossier_ref: w.dossier_ref || '',
        bead_ref: w.bead_ref || '',
        tier: w.tier || '',
        open_item_count: n,
        label: n + (n === 1 ? ' item needs you' : ' items need you'),
        // Deep-link target for T6b's Inbox — the Board does not open it here.
        // Root-relative because Board and Inbox are now routes inside the
        // unified `claude-wrangler` Pages project (UX-DESIGN §2; consolidation
        // in claude-tools-b59) — `/inbox#…` is the cross-route deep link.
        inbox_href: w.dossier_ref ? '/inbox#' + w.dossier_ref : null
      };
    });

    // L3 (claude-tools-2bf): per-card "which workspace is running this bead?"
    // map. The projection's per-project RunnerState carries `current_task_ref`
    // (§4.2) — the bead_ref the runner last reported it was working. We index
    // it bead_ref → project_ref so each card can show its live runner. ONLY
    // a LIVE runner's current_task_ref counts; a stale runner's last-reported
    // task is muted by S-1 (a stale runner is honestly "we don't know what
    // it's doing now"). Multiple live runners on the same bead is structurally
    // possible only as a transient race during a lease handoff (§6.1); we
    // keep the first observed assignment and surface the rest as a "+N more"
    // suffix so the honest plural shape never lies as a single value.
    var beadRunners = {};
    projects.forEach(function (p) {
      var rs = p && p.runner_state ? p.runner_state : {};
      var live = rs.liveness === 'live';
      var task = typeof rs.current_task_ref === 'string' && rs.current_task_ref
        ? rs.current_task_ref : null;
      var ref = p && p.project_ref ? p.project_ref : null;
      if (!live || !task || !ref) return;
      if (!beadRunners[task]) beadRunners[task] = [];
      beadRunners[task].push(ref);
    });
    function runnerLabel(beadRef) {
      var rs = beadRef ? beadRunners[beadRef] : null;
      if (!rs || rs.length === 0) return null;
      if (rs.length === 1) return rs[0];
      return rs[0] + ' (+' + (rs.length - 1) + ' more)';
    }

    // Lifecycle columns — keyed by `stage:` (§4.5), FROZEN order. The seven
    // canonical stages render in the spec's order; the empty-string "unstaged"
    // bucket is appended as a visible eighth lane so legacy beads with no
    // stage label are never hidden (L3 acceptance: legacy unstaged beads are
    // visible). The column key STAYS "" — the producer contract — but the
    // human-facing label is "unstaged" (was the older 'untracked' wording).
    var cols = (snap.lifecycle_columns && typeof snap.lifecycle_columns === 'object')
      ? snap.lifecycle_columns : {};
    var lifecycle = STAGE_ORDER.map(function (stage) {
      var cards = Array.isArray(cols[stage]) ? cols[stage] : [];
      return {
        stage: stage,
        label: stage === '' ? 'unstaged' : stage,
        count: cards.length,
        cards: cards.map(function (c) {
          var f = c && c.failure ? c.failure : null;
          var beadRef = c.bead_ref || '';
          return {
            bead_ref: beadRef,
            title: c.title || '(untitled)',
            stage: c.stage || '',
            priority: (c.priority === 0 || c.priority) ? c.priority : null,
            age: c.age || null,
            // J5 (claude-tools-uxvj5) — the inline hold reason (DESIGN J §7.5).
            // Derived from the holds[]-sourced cards[].waiting_on object into the
            // one-line {type,glyph,text,editable,more} the column paints; null
            // when the bead is not held (no waiting line).
            waiting_on: deriveWaitingOn(c.waiting_on),
            // L3 — which live runner is on this bead, if any (null when no
            // live workspace has it as current_task_ref). Presentation-only:
            // we never invent a runner; a stale runner's last task does NOT
            // count (S-1 — stale is not "currently working").
            runner: runnerLabel(beadRef),
            // GAP G2 (claude-tools-uxg2) — done·code vs done·verified
            // (UX-DESIGN-V2.md §3 / principle 11: the headline defence against
            // 'wired-but-not-live'). The projection carries a per-card
            // `verified` boolean; ONLY the `done` lane splits on it. The
            // sub-state label is the FROZEN §5.2 / enums.js DONE_SUBSTATE
            // vocabulary ('done·code' | 'done·verified') — carried verbatim
            // here the way STAGE_ORDER mirrors the spine (a Contract-D closed
            // set; never widen). Consumed verbatim, never invented: an absent
            // or non-true flag reads as done·code — un-probed is NOT verified,
            // so the un-verified state is what stays VISIBLE (the thirsty
            // lesson: "done" that closed on code-lands-without-integration is
            // the dominant leak). `done_substate` is null off the done lane.
            verified: c.verified === true,
            done_substate: (stage === 'done')
              ? (c.verified === true ? 'done·verified' : 'done·code')
              : null,
            // Flow G tiers 1–2 metadata ONLY — class + retry-state + silent
            // flag + Runner: note count/last-at. The §10 forensic stream is
            // structurally absent from the projection and its on-demand fetch
            // UI is T6b (NOT rendered here). G1 (claude-tools-b6y): a card
            // with a failure deep-links to T6b's Inbox failure-view at
            // /inbox#/f/<bead_ref> (the analysis-task dossier path, G2).
            // `silent` is consumed verbatim from the projection (the producer
            // is authoritative — UX principle 7 "silent failures surface
            // loudest" requires one place of truth); we ONLY derive it as a
            // back-compat fallback when an older producer didn't emit the
            // flag, using the same SILENT_CLASSES set the producer uses.
            failure: f ? (function () {
              var cls = f.class || 'UNKNOWN_FAILURE';
              var silent = (typeof f.silent === 'boolean')
                ? f.silent
                : isSilentClass(cls);
              var notes = Array.isArray(f.runner_notes) ? f.runner_notes : [];
              return {
                class: cls,
                retry_state: f.retry_state || null,
                silent: silent,
                runner_notes_count: notes.length,
                last_runner_note_at: f.last_runner_note_at || null,
                badge: '⚠ ' + cls +
                  (f.retry_state ? ' · ' + f.retry_state : '') +
                  (silent ? ' · silent' : ''),
                // G1 deep-link: T6b's Inbox SPA failure route. Same shape as
                // inbox-view.js's failure_href (`#/f/<bead_ref>`). Root-relative
                // because the unified Pages project (claude-tools-b59) serves
                // /inbox as a sibling route on the same host. Never null when
                // we have a bead_ref (the failure view IS the answer).
                failure_href: beadRef ? '/inbox#/f/' + beadRef : null
              };
            }()) : null
          };
        })
      };
    });

    // The one-screen health answer (Flow E: "is anything waiting on me, and
    // is the machine healthy?"). Every input is a projection field — nothing
    // is fabricated. "Healthy" = no stale runner, no honest desired≠actual
    // mismatch, no failing bead. Capacity `over` is surfaced as its own chip
    // (it is a soft cap state, §6.3 — not the same as "unhealthy").
    var staleRunners = runners.filter(function (r) { return r.liveness === 'stale'; });
    var mismatchRunners = runners.filter(function (r) { return r.mismatch; });
    var liveActive = runners.filter(function (r) {
      return r.liveness === 'live' && r.actual && ACTUAL_HEALTHY_ACTIVE[r.actual];
    });
    var overCapacity = runners.filter(function (r) {
      return r.capacity_verdict === 'over';
    });
    // G1 (claude-tools-b6y) — split the failing count into loud + silent. The
    // status strip surfaces silent SEPARATELY because they rot (UX principle
    // 7): a "⚠ N silent" chip carries the louder visual weight than a
    // "⚠ M failing" chip even when M ≥ N. Strip aggregation reads the same
    // projection field as each card's badge — one source of truth.
    var failingCards = 0;
    var silentCards = 0;
    lifecycle.forEach(function (col) {
      col.cards.forEach(function (c) {
        if (!c.failure) return;
        failingCards += 1;
        if (c.failure.silent) silentCards += 1;
      });
    });
    var loudCards = failingCards - silentCards;
    var decisionItems = waiting.reduce(function (a, w) {
      return a + (w.open_item_count || 0);
    }, 0);

    // Q1 (claude-tools-uxvq1) — the board-level QUEUE-HEALTH strip (§9). Each
    // project owns its own queue_health (B.1, per-project); the board strip is
    // the at-a-glance AGGREGATE across them. We sum the counts and net-velocity
    // and UNION the flagged epics into one queue_health-shaped object, then run
    // it back through deriveQueueHealth so the strip view model is derived by
    // the SAME code path as a per-project row (one source of truth). The
    // net-velocity alarm + empty-queue explainer (the §9 highest-value items)
    // surface as health-strip chips below.
    var qhEpicSet = [];
    // claude-tools-t5ud (§9 row 4) — board-level audit coverage = the SUM of
    // per-project read/total (only projects whose audit reported contribute). If
    // no project has reported, the aggregate stays null ⇒ no strip chip.
    var qhAcRead = 0, qhAcTotal = 0;
    var qhTotals = projects.reduce(function (acc, p) {
      var d = deriveQueueHealth(p && p.queue_health);
      acc.ready += d.ready;
      acc.held.gate += d.held.gate;
      acc.held.dependency += d.held.dependency;
      acc.held.scheduled += d.held.scheduled;
      acc.hidden_under_deferred_parent += d.hidden_under_deferred_parent;
      acc.net_velocity_7d += d.net_velocity_7d;
      d.epics_with_zero_ready_children.forEach(function (e) {
        if (qhEpicSet.indexOf(e) === -1) qhEpicSet.push(e);
      });
      if (d.audit_coverage) { qhAcRead += d.audit_coverage.read; qhAcTotal += d.audit_coverage.total; }
      return acc;
    }, {
      ready: 0,
      held: { gate: 0, dependency: 0, scheduled: 0 },
      hidden_under_deferred_parent: 0,
      net_velocity_7d: 0
    });
    qhTotals.epics_with_zero_ready_children = qhEpicSet;
    qhTotals.audit_coverage = qhAcTotal > 0 ? { read: qhAcRead, total: qhAcTotal } : null;
    var queueHealth = deriveQueueHealth(qhTotals);

    // iz36 (claude-tools-iz36) — the PRECISE machine-attention banner. Consumed
    // VERBATIM from the engine's snapshot.attention (Contract B.1): the alert
    // CONDITION + threshold are decided in workSnapshot()/co__derive_attention,
    // NEVER re-derived here (A.3 — "goes through B.1 first; do not hand-derive it
    // ad hoc in the web"). This is the DELIBERATE complement to the noisy
    // `staleRunners`/`mismatchRunners` tags above: `desired_actual_mismatch` is
    // `true` in the benign desired=running/actual=idle steady state (so the
    // "N state mismatch" chip cries wolf constantly), whereas an `attention`
    // alert fires ONLY on a SUSTAINED wanted-running-but-wedged runner — the
    // incident signature nothing surfaced. Tolerant by construction: an older
    // producer that omits the field ⇒ no banner (graceful, additive — the
    // machines[]/intake[] degrade-to-empty discipline), never a fabricated alarm.
    var rawAttn = (snap.attention && typeof snap.attention === 'object') ? snap.attention : null;
    var attnAlerts = (rawAttn && Array.isArray(rawAttn.alerts)) ? rawAttn.alerts : [];
    var attnActive = !!rawAttn && rawAttn.needs_attention === true && attnAlerts.length > 0;
    var attention = {
      needs_attention: attnActive,
      count: attnActive ? attnAlerts.length : 0,
      // The banner headline + a one-line-per-alert breakdown the painter renders.
      // Presentation only: every string is the engine's field, formatted.
      headline: attnActive
        ? ('⚠ Machine needs attention — ' + attnAlerts.length + ' workspace' +
           (attnAlerts.length === 1 ? '' : 's') +
           ' wanted running but the runner is wedged')
        : null,
      alerts: attnAlerts.map(function (a) {
        var ref = (a && a.project_ref) ? a.project_ref : '(unknown)';
        var ageText = (a && typeof a.heartbeat_age_seconds === 'number')
          ? formatAgeSeconds(a.heartbeat_age_seconds) : null;
        return {
          project_ref: ref,
          kind: (a && a.kind) ? a.kind : 'stale-runner',
          desired: (a && a.desired) ? a.desired : null,
          actual: (a && a.actual) ? a.actual : null,
          heartbeat_age_text: ageText,
          // Prefer the engine's own detail string (single source of phrasing);
          // fall back to a derived one-liner only if the producer omitted it.
          text: (a && typeof a.detail === 'string' && a.detail)
            ? a.detail
            : (ref + ' — heartbeat stale' + (ageText ? ' ' + ageText : ''))
        };
      })
    };

    var healthy =
      staleRunners.length === 0 &&
      mismatchRunners.length === 0 &&
      failingCards === 0 &&
      !attnActive;

    var health = {
      ok: healthy,
      headline: healthy
        ? (decisionItems > 0
            ? decisionItems + (decisionItems === 1 ? ' decision' : ' decisions') +
              ' waiting · machine healthy'
            : 'Nothing waiting on you · machine healthy')
        : (decisionItems > 0
            ? decisionItems + (decisionItems === 1 ? ' decision' : ' decisions') +
              ' waiting · ⚠ machine needs attention'
            : '⚠ machine needs attention'),
      runners_total: runners.length,
      runners_live_active: liveActive.length,
      runners_stale: staleRunners.length,
      runners_mismatch: mismatchRunners.length,
      runners_over_capacity: overCapacity.length,
      decisions_waiting: waiting.length,
      decision_items_waiting: decisionItems,
      silent_or_loud_failures: failingCards,
      // G1 (claude-tools-b6y) — split counts; the strip surfaces silent
      // SEPARATELY (louder color) than loud (standard color).
      silent_failures: silentCards,
      loud_failures: loudCards,
      // Greppable tag chips for the strip — each is a projection-derived fact.
      // The silent chip is rendered as `kind:'bad'` (loudest visual weight,
      // UX principle 7), while the loud-failing chip stays `kind:'warn'` — so
      // even a single silent rotter outweighs many loud retries at a glance.
      tags: [
        { kind: 'runners', text: liveActive.length + ' active' },
        // iz36 — the PRECISE attention chip (loudest weight). Sits FIRST among
        // the warnings because it is the high-signal "a human is needed" fact,
        // unlike the constantly-firing mismatch chip below it.
        attnActive
          ? { kind: 'bad', text: '⚠ ' + attention.count + ' need' +
              (attention.count === 1 ? 's' : '') + ' attention' }
          : null,
        staleRunners.length
          ? { kind: 'bad', text: '⚠ ' + staleRunners.length + ' stale' }
          : null,
        mismatchRunners.length
          ? { kind: 'warn', text: '⚠ ' + mismatchRunners.length + ' state mismatch' }
          : null,
        waiting.length
          ? { kind: 'warn', text: '⚠ ' + waiting.length + ' waiting on you' }
          : null,
        loudCards
          ? { kind: 'warn', text: '⚠ ' + loudCards + ' failing' }
          : null,
        silentCards
          ? { kind: 'bad', text: '⚠ ' + silentCards + ' silent' }
          : null,
        overCapacity.length
          ? { kind: 'warn', text: '⚠ ' + overCapacity.length + ' over capacity' }
          : null,
        // Q1 (claude-tools-uxvq1) — §9 queue-health chips. The net-velocity
        // alarm is the single highest-value signal ("runaway task creation"),
        // so it carries `kind:'bad'` (loudest weight); the empty-queue
        // explainer and zero-ready-children epics are `kind:'warn'`.
        queueHealth.velocity_alarm
          ? { kind: 'bad', text: '⚠ ' + queueHealth.velocity_text + ' (runaway)' }
          : null,
        queueHealth.empty_queue
          ? { kind: 'warn', text: '0 ready · ' + queueHealth.held_total +
              ' held · ' + queueHealth.hidden_under_deferred_parent + ' hidden' }
          : null,
        queueHealth.epics_zero_ready_count
          ? { kind: 'warn', text: '⚠ ' + queueHealth.epics_zero_ready_count +
              (queueHealth.epics_zero_ready_count === 1 ? ' epic' : ' epics') + ' 0-ready' }
          : null,
        // claude-tools-t5ud (§9 row 4) — audit-coverage chip. Surfaced ONLY when
        // an audit has reported (null otherwise). `warn` weight when the audit did
        // NOT read everything (read<total — the §9 "did the audit read everything?"
        // signal); `runners` (neutral mint) when complete — a positive confirmation
        // that the conclusion is backed by full coverage, "not just the conclusion".
        queueHealth.audit_coverage
          ? { kind: (queueHealth.coverage_complete ? 'runners' : 'warn'),
              text: (queueHealth.coverage_complete ? '' : '⚠ ') + 'audit ' + queueHealth.coverage_text }
          : null
      ].filter(Boolean)
    };

    // MACHINE-STATE.md §3.A/§4 — top-of-board per-machine strip. Passed
    // through to the rendered model verbatim from snapshot.machines[] (the
    // C3 projection is authoritative). §3.C: an empty array is honest — the
    // renderer surfaces a "no telemetry yet" banner, NOT a phantom "ok".
    var rawMachines = Array.isArray(snap.machines) ? snap.machines : [];
    var machineRows = rawMachines.map(deriveMachine);

    return {
      ok: true,
      principal: snap.principal || '(unresolved)',
      read_only: snap.read_only === true,
      schema_version: sv,
      health: health,
      // iz36 — the precise machine-attention banner (Contract B.1 surface). app.js
      // paints `attention.headline` + the per-alert breakdown as a prominent
      // banner above the status strip; null/empty when nothing needs attention.
      attention: attention,
      runners: runners,
      waiting_on_you: waiting,
      lifecycle: lifecycle,
      machines: machineRows,
      machines_empty: machineRows.length === 0,
      // Q1 (claude-tools-uxvq1) — the board-level §9 QUEUE-HEALTH strip model
      // (aggregate across projects). Per-project queue_health rides on each
      // runners[].queue_health (B.1, per-project).
      queue_health: queueHealth
    };
  }

  return {
    deriveBoardView: deriveBoardView,
    deriveRunner: deriveRunner,
    deriveMachine: deriveMachine,
    deriveQueueHealth: deriveQueueHealth,
    formatAgo: formatAgo,
    formatAgeSeconds: formatAgeSeconds,
    formatPct: formatPct,
    STAGE_ORDER: STAGE_ORDER,
    DESIRED_CONTROLS: DESIRED_CONTROLS,
    NET_VELOCITY_ALARM_THRESHOLD: NET_VELOCITY_ALARM_THRESHOLD,
    SUPPORTED_SNAPSHOT_SCHEMA: SUPPORTED_SNAPSHOT_SCHEMA
  };
});
