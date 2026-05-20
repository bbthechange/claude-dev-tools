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
 * UI-side fabrication. (The mock's numeric 5h/7d gauges are such a
 * not-in-producer nicety; per the task NOTES precedence the frozen §4.5
 * coarse `verdict` wins and the gauge is treated as not-yet-updated mock — no
 * escalation, because machine-health is fully answerable from
 * verdict+liveness+mismatch+failure.) MUST NOT render the Inbox/dossier body
 * or the §10 forensic stream (that is T6b) — the WAITING-ON-YOU lane is a
 * pointer, never the dossier content.
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
      ago: ago,
      capacity_verdict:
        (p && p.capacity_strip && p.capacity_strip.verdict) || 'unknown'
    };

    if (liveness === 'stale') {
      // S-1: stale is its OWN state, never the running/idle pill.
      row.state_class = 'stale';
      row.state_label = 'stale (last seen ' + ago + ' ago)';
      row.actual_note = actual ? 'last reported: ' + actual : null;
    } else {
      row.state_class = actual && ACTUAL_HEALTHY_ACTIVE[actual] ? 'live' :
        (actual ? 'attention' : 'unknown');
      var base = actual || 'unknown';
      // Honest desired≠actual (principle 4): show the actual, then the
      // unreached target — never collapse one onto the other.
      row.state_label = mismatch && desired
        ? base + ' (target: ' + desired + ')'
        : base;
      row.actual_note = null;
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

    return row;
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
        inbox_href: w.dossier_ref ? '/inbox#' + w.dossier_ref : null
      };
    });

    // Lifecycle columns — keyed by `stage:` (§4.5), FROZEN order, "" honest.
    var cols = (snap.lifecycle_columns && typeof snap.lifecycle_columns === 'object')
      ? snap.lifecycle_columns : {};
    var lifecycle = STAGE_ORDER.map(function (stage) {
      var cards = Array.isArray(cols[stage]) ? cols[stage] : [];
      return {
        stage: stage,
        label: stage === '' ? 'untracked' : stage,
        count: cards.length,
        cards: cards.map(function (c) {
          var f = c && c.failure ? c.failure : null;
          return {
            bead_ref: c.bead_ref || '',
            title: c.title || '(untitled)',
            stage: c.stage || '',
            priority: (c.priority === 0 || c.priority) ? c.priority : null,
            age: c.age || null,
            waiting_on: c.waiting_on || null,
            // Flow G tiers 1–2 metadata ONLY (class + retry-state). The §10
            // forensic stream is structurally absent from the projection and
            // its on-demand fetch UI is T6b — NOT rendered here.
            failure: f ? {
              class: f.class || 'UNKNOWN_FAILURE',
              retry_state: f.retry_state || null,
              badge: '⚠ ' + (f.class || 'UNKNOWN_FAILURE') +
                (f.retry_state ? ' · ' + f.retry_state : '')
            } : null
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
    var failingCards = 0;
    lifecycle.forEach(function (col) {
      col.cards.forEach(function (c) { if (c.failure) failingCards += 1; });
    });
    var decisionItems = waiting.reduce(function (a, w) {
      return a + (w.open_item_count || 0);
    }, 0);

    var healthy =
      staleRunners.length === 0 &&
      mismatchRunners.length === 0 &&
      failingCards === 0;

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
      // Greppable tag chips for the strip — each is a projection-derived fact.
      tags: [
        { kind: 'runners', text: liveActive.length + ' active' },
        staleRunners.length
          ? { kind: 'bad', text: '⚠ ' + staleRunners.length + ' stale' }
          : null,
        mismatchRunners.length
          ? { kind: 'warn', text: '⚠ ' + mismatchRunners.length + ' state mismatch' }
          : null,
        waiting.length
          ? { kind: 'warn', text: '⚠ ' + waiting.length + ' waiting on you' }
          : null,
        failingCards
          ? { kind: 'bad', text: '⚠ ' + failingCards + ' failing' }
          : null,
        overCapacity.length
          ? { kind: 'warn', text: '⚠ ' + overCapacity.length + ' over capacity' }
          : null
      ].filter(Boolean)
    };

    return {
      ok: true,
      principal: snap.principal || '(unresolved)',
      read_only: snap.read_only === true,
      schema_version: sv,
      health: health,
      runners: runners,
      waiting_on_you: waiting,
      lifecycle: lifecycle
    };
  }

  return {
    deriveBoardView: deriveBoardView,
    deriveRunner: deriveRunner,
    formatAgo: formatAgo,
    STAGE_ORDER: STAGE_ORDER,
    DESIRED_CONTROLS: DESIRED_CONTROLS,
    SUPPORTED_SNAPSHOT_SCHEMA: SUPPORTED_SNAPSHOT_SCHEMA
  };
});
