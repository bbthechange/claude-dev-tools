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
            waiting_on: c.waiting_on || null,
            // L3 — which live runner is on this bead, if any (null when no
            // live workspace has it as current_task_ref). Presentation-only:
            // we never invent a runner; a stale runner's last task does NOT
            // count (S-1 — stale is not "currently working").
            runner: runnerLabel(beadRef),
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
