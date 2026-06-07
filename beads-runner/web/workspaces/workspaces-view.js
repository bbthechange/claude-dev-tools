/* beads-runner/web/workspaces/workspaces-view.js — Workspaces Hub
 * (label: workspaces-hub; Brian ask B6; UX-DESIGN-V2 §2.1/§2.2).
 *
 * THE PURE, HEADLESS-TESTABLE CORE of the Workspaces hub — the NEW global view
 * that answers "Which workspaces are healthy / busy / stuck / need me?" in one
 * glance, then routes into a workspace's Board. No DOM, no network, no timers:
 * input is the §4.5 work-snapshot projection JSON (the same /api/board
 * projection the Board reads), output is a deterministic view model of strings.
 * lib/test-workspaces-view.sh drives THIS module against a hand-crafted
 * fixture snapshot — the producer↔renderer seam asserted against the frozen
 * Contract B.1 shape (UX-V2-ARCHITECTURE §3), never against a faked render.
 *
 * BINDS the same projection invariants the Board binds (.cshell-brief §"read-
 * model" + Honesty discipline):
 *   • §0.3 — an unknown HIGHER schema_version (sv > 1) is REFUSED with an error
 *     view; a missing / non-integer schema_version is ALSO refused. Never
 *     best-effort-render a future schema (the 4xe / §0.3 rule).
 *   • §4.2 / S-1 — liveness comes ONLY from the projection (Coordinator-derived
 *     at read time). A `stale` runner is NOT "currently working"; its
 *     last-reported actual is never promoted to a live state, and its
 *     `current_task_ref` is dropped (a stale runner is honestly "we don't know
 *     what it's doing now").
 *   • principle 4 — honest desired≠actual: show the ACTUAL, then the unreached
 *     target, never collapse one onto the other.
 *   • derived/inferred values are LABELED as derived. `stage_counts` is INFERRED
 *     by bead_ref prefix (the per-workspace lifecycle tally) — it is NOT an
 *     authoritative per-project projection, so it carries `derived:true` and the
 *     UI must label it "derived from board". Q1's queue_health supersedes it.
 *
 * ANTI-DRIFT: presentation derivation ONLY — no write path, no fetch, no DOM.
 * Local helpers only (does NOT depend on board-view.js). A field the hub needs
 * but the projection lacks degrades to a labeled placeholder; the only hard
 * refusal is the unknown-HIGHER schema_version.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.WorkspacesView = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // The contract-bound schema version this view understands (§0.3 / §4.5).
  var SUPPORTED_SNAPSHOT_SCHEMA = 1;

  // §4.5 lifecycle stage ladder — FROZEN order. "" is the honest un-staged
  // bucket the producer emits for an unknown/missing stage. We tally the
  // per-workspace slice across exactly these keys (label-honest below).
  var STAGE_ORDER = ['idea', 'ux', 'design', 'impl', 'docs', 'tests', 'done', ''];

  // §4.2 `actual` — the closed set of healthy-active live states. A live runner
  // in one of these reads as "busy/working"; anything else (paused, stopped,
  // spare-only, unknown) is honestly NOT active even when live.
  var ACTUAL_HEALTHY_ACTIVE = { running: 1, idle: 1, starting: 1 };

  // claude-tools-758l — the four FROZEN desired-states the per-workspace toggle
  // row exposes (UX-DESIGN-V2 §2 "one tap from the workspace card"; §4 Flow D).
  // Pinned in the SAME order as board-view.js's DESIRED_CONTROLS and
  // set-desired.js's ALLOWED_STATES so a UI typo and an engine typo cannot drift
  // apart (a local copy by design — the hub does NOT depend on board-view.js).
  // The label is presentation; `state` is the wire value the F1 client sends.
  var DESIRED_CONTROLS = [
    { state: 'running',    label: 'Run' },
    { state: 'paused',     label: 'Pause' },
    { state: 'spare-only', label: 'Spare-only' },
    { state: 'stopped',    label: 'Stop' }
  ];

  // L3 (claude-tools-uxvl3; inbox-lifecycle §9.5 #4) — the intake state thread
  // the §4.5 producer surfaces in the top-level `intake[]` lane. FROZEN order:
  // received → enriching → created  /  failing → gave-up. `failing`/`gave-up`
  // are the ATTENTION states (the 19-silent-retry leak); `received`/`enriching`
  // are in-flight; `created` is terminal-success.
  var INTAKE_STATE_ORDER = ['gave-up', 'failing', 'enriching', 'received', 'created'];
  var INTAKE_ATTENTION = { 'gave-up': 1, failing: 1 };
  // A terminal-success (`created`) intake's bead is already on the Board — we
  // show it only briefly as a thread-completion confirmation, then let it age
  // off the hub (the record persists in the engine; the hub is not its grave).
  var INTAKE_CREATED_RECENT_MS = 6 * 60 * 60 * 1000; // 6h

  // Stale-enriching honesty (claude-tools-t956). `enriching` is set from the
  // daemon's in-flight marker (intake-dispatch-poll.sh writes it right before
  // each SYNCHRONOUS enricher spawn). If the daemon dies mid-enrich the marker
  // freezes — never re-dispatched, never moved to a terminal state — so the
  // phone would show a confident "enriching" forever. The engine projection
  // stays honest about the marker; THIS view applies a freshness heuristic (the
  // S-1 "liveness derived at read time" posture): an enriching record whose
  // last_attempt_at is older than this window has almost certainly lost its
  // daemon (a healthy synchronous enrich is minutes, never this long), so we
  // flip it to attention without lying about the state. 15m is comfortably past
  // any normal enrich + the 30s INTAKE_POLL_INTERVAL, yet surfaces a dead daemon
  // promptly. A fresh enriching record (seconds–minutes old) is untouched.
  var INTAKE_ENRICHING_STALE_MS = 15 * 60 * 1000; // 15m

  /* formatAgo(fromIso, nowMs?) → "Ns" | "Nm" | "Nh" | "Nd" | "unknown" — a
   * PRESENTATION formatting of the §4.2 `last_heartbeat_at` datum (NOT a
   * liveness decision — that is the Coordinator's, consumed verbatim). Honest
   * "unknown" when the datum is missing/unparseable. Mirrors board-view.js's
   * bucketing so the two surfaces format the same number identically (local
   * copy by design — the hub does NOT depend on board-view.js). */
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

  /* prefixMatch(beadRef, projectRef) → does this bead belong to this project?
   * The hub slices the GLOBAL queues (waiting_on_you + lifecycle_columns) per
   * workspace by bead_ref prefix: a bead "claude-tools-99" belongs to project
   * "claude-tools". The separator is enforced ("claude-tools-" not just
   * "claude-tools") so "claude-tools-web" does not greedily swallow
   * "claude-tools-web-extra"'s beads. This is an INFERENCE — see stage_counts'
   * `derived:true` flag and the UI's "derived from board" label. */
  function prefixMatch(beadRef, projectRef) {
    if (typeof beadRef !== 'string' || typeof projectRef !== 'string') return false;
    if (!projectRef) return false;
    return beadRef.indexOf(projectRef + '-') === 0;
  }

  /* deriveIntakeForWorkspace(rawIntake, ref, now) → the per-workspace slice of
   * the global §4.5 `intake[]` lane (L3). intake-request records carry
   * `project_ref` DIRECTLY (the Flow A submitter chose the workspace), so this
   * is an EXACT match — not the ref-prefix inference stage_counts/decisions use.
   * Returns { counts, items, attention_count, total }:
   *   • counts — a tally per thread state (received/enriching/created/failing/gave-up).
   *   • items  — the ones worth rendering on the hub: every in-flight/attention
   *     intake (received/enriching/failing/gave-up) ALWAYS, plus a `created` one
   *     only while it is recent (a brief "→ became <bead>" confirmation that ages
   *     out). Sorted by INTAKE_STATE_ORDER (gave-up first — surface the leak).
   *   • attention_count — failing + gave-up + STALE-enriching (claude-tools-t956:
   *     an enriching record whose last_attempt_at is older than
   *     INTAKE_ENRICHING_STALE_MS has lost its daemon mid-enrich). Drives card
   *     health + the global total.
   * Honest: an unknown/missing state buckets as `received` (never silently a
   * success); a record with no project_ref is dropped from every workspace. A
   * stale enriching item keeps its honest `state:'enriching'` but carries
   * `stale:true` + `attention:true`. */
  function deriveIntakeForWorkspace(rawIntake, ref, now) {
    var counts = { received: 0, enriching: 0, created: 0, failing: 0, 'gave-up': 0 };
    var items = [];
    var staleEnriching = 0;
    rawIntake.forEach(function (i) {
      if (!i || typeof i !== 'object') return;
      if (typeof i.project_ref !== 'string' || i.project_ref !== ref) return;
      var st = (typeof i.state === 'string' && counts[i.state] !== undefined) ? i.state : 'received';
      counts[st] += 1;
      // Which timestamp is the relevant "age" for this state.
      var ts = st === 'created' ? i.processed_at
             : (st === 'gave-up' ? i.gave_up_at : i.last_attempt_at) || i.submitted_at;
      var show = st !== 'created';
      if (st === 'created') {
        var pat = Date.parse(i.processed_at || '');
        show = !isNaN(pat) && (now - pat) <= INTAKE_CREATED_RECENT_MS;
      }
      if (!show) return;
      // Stale-enriching flip (claude-tools-t956): an `enriching` record older
      // than the window has almost certainly lost its daemon. Measure against
      // the same age datum the chip shows (last_attempt_at, then submitted_at).
      // Honest: if neither timestamp parses we CANNOT prove staleness ⇒ not stale.
      var stale = false;
      if (st === 'enriching') {
        var eat = Date.parse(i.last_attempt_at || i.submitted_at || '');
        stale = !isNaN(eat) && (now - eat) > INTAKE_ENRICHING_STALE_MS;
        if (stale) staleEnriching += 1;
      }
      items.push({
        intake_id: typeof i.intake_id === 'string' ? i.intake_id : '',
        state: st,
        attempts: (typeof i.attempts === 'number' && i.attempts > 0) ? i.attempts : 0,
        idea_excerpt: typeof i.idea_excerpt === 'string' ? i.idea_excerpt : '',
        preset: typeof i.preset === 'string' ? i.preset : '',
        last_error: typeof i.last_error === 'string' ? i.last_error : '',
        bd_ref: typeof i.bd_ref === 'string' ? i.bd_ref : '',
        ago: formatAgo(ts, now),
        stale: stale,
        attention: !!INTAKE_ATTENTION[st] || stale
      });
    });
    items.sort(function (a, b) {
      var wa = INTAKE_STATE_ORDER.indexOf(a.state);
      var wb = INTAKE_STATE_ORDER.indexOf(b.state);
      if (wa !== wb) return wa - wb;
      return a.intake_id < b.intake_id ? -1 : (a.intake_id > b.intake_id ? 1 : 0);
    });
    return {
      counts: counts,
      items: items,
      attention_count: counts.failing + counts['gave-up'] + staleEnriching,
      total: counts.received + counts.enriching + counts.created + counts.failing + counts['gave-up']
    };
  }

  /* deriveWorkspacesView(snapshot, nowMs?, opts?) → the whole hub view model.
   * On an unknown HIGHER (or missing/non-integer) schema_version it returns an
   * ERROR view (§0.3 — refuse, never best-effort-render). Otherwise:
   *   { ok:true, principal, schema_version, cards:[…], decisions_total }
   * one card per snapshot.projects[].
   *
   * claude-tools-758l: `opts.pending_desired` is an optional
   * { [project_ref]: { state } } map of client-side ephemeral "user just tapped"
   * captures (the F2 desired-state controls now live ON the workspace card). It
   * is NOT a contract field — the projection stays authoritative and this overlay
   * can NEVER promote actual; it only supplies the per-card "waiting for runner to
   * honor" banner (same discipline as board-view.js's pending_desired). */
  function deriveWorkspacesView(snapshot, nowMs, opts) {
    var snap = snapshot && typeof snapshot === 'object' ? snapshot : {};
    var pendingMap = (opts && opts.pending_desired && typeof opts.pending_desired === 'object'
      && !Array.isArray(opts.pending_desired)) ? opts.pending_desired : {};

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
          ' (this Workspaces hub binds v' + SUPPORTED_SNAPSHOT_SCHEMA +
          ') — refusing to best-effort-render (§0.3)'
      };
    }

    var now = typeof nowMs === 'number' ? nowMs : Date.now();
    var projects = Array.isArray(snap.projects) ? snap.projects : [];
    var rawWoy = Array.isArray(snap.waiting_on_you) ? snap.waiting_on_you : [];
    // L3 — the top-level intake-state lane (additive at v1; absent on an old
    // producer ⇒ honest empty, no intake strip rendered).
    var rawIntake = Array.isArray(snap.intake) ? snap.intake : [];

    // decisions_total — total OPEN items across the GLOBAL decision queue. Each
    // waiting_on_you entry carries open_item_count (the §4.5 producer emits
    // COUNTS only; the body is the Inbox's, never the hub's). The Inbox is
    // still the product — this is the number the hub surfaces prominently.
    var decisionsTotal = rawWoy.reduce(function (a, w) {
      var n = (w && typeof w.open_item_count === 'number') ? w.open_item_count : 0;
      return a + (n > 0 ? n : 0);
    }, 0);

    // Lifecycle columns keyed by stage (§4.5). We flatten to a list of
    // { bead_ref, stage } so the per-workspace tally can slice it by prefix.
    var cols = (snap.lifecycle_columns && typeof snap.lifecycle_columns === 'object')
      ? snap.lifecycle_columns : {};

    var cards = projects.map(function (p) {
      var ref = (p && typeof p.project_ref === 'string' && p.project_ref)
        ? p.project_ref : '(unknown)';
      var rs = (p && p.runner_state) || {};
      var liveness = rs.liveness === 'live' ? 'live' : 'stale'; // honest default
      var isStale = liveness === 'stale';
      var actual = (typeof rs.actual === 'string' && rs.actual) ? rs.actual : null;
      var desired = (typeof rs.desired === 'string' && rs.desired) ? rs.desired : null;
      var mismatch = rs.desired_actual_mismatch === true;
      var ago = formatAgo(rs.last_heartbeat_at, now);

      // state_label (honest mode):
      //   stale          → "stale (last seen Nh ago)"  (S-1: its own state)
      //   live, mismatch → "actual (target: desired)"  (principle 4)
      //   live           → "actual"
      var stateLabel;
      if (isStale) {
        stateLabel = 'stale (last seen ' + ago + ' ago)';
      } else if (mismatch && desired) {
        stateLabel = (actual || 'unknown') + ' (target: ' + desired + ')';
      } else {
        stateLabel = actual || 'unknown';
      }

      // current_task — a LIVE runner's current_task_ref (+ optional title). S-1:
      // a stale runner's last-reported task is honestly unknown ⇒ NULL.
      var currentTask = null;
      var currentTaskTitle = null;
      if (!isStale) {
        if (typeof rs.current_task_ref === 'string' && rs.current_task_ref) {
          currentTask = rs.current_task_ref;
        }
        if (currentTask && typeof rs.current_task_title === 'string' && rs.current_task_title) {
          currentTaskTitle = rs.current_task_title;
        }
      }

      // decisions — the per-workspace slice of the GLOBAL Inbox: open items on
      // waiting_on_you entries whose bead_ref is prefixed by this project_ref.
      var decisions = rawWoy.reduce(function (a, w) {
        if (!w || !prefixMatch(w.bead_ref, ref)) return a;
        var n = typeof w.open_item_count === 'number' ? w.open_item_count : 0;
        return a + (n > 0 ? n : 0);
      }, 0);

      // stage_counts — DERIVED per-workspace lifecycle tally. For each stage we
      // count the lifecycle cards whose bead_ref is prefixed by this project.
      // INFERRED by ref-prefix, NOT an authoritative per-project projection —
      // hence `derived:true` and the UI's mandatory "derived from board" label
      // (Q1's queue_health supersedes this later).
      var stageCounts = {};
      var stageTotal = 0;
      STAGE_ORDER.forEach(function (stage) {
        var list = Array.isArray(cols[stage]) ? cols[stage] : [];
        var n = 0;
        list.forEach(function (c) {
          if (c && prefixMatch(c.bead_ref, ref)) n += 1;
        });
        stageCounts[stage] = n;
        stageTotal += n;
      });

      // L3 — the per-workspace intake-state slice (exact project_ref match on
      // the global intake[] lane). A failing/gave-up intake is the 19-silent-
      // retry leak surfacing — it bumps health to 'attention' so the card sorts
      // up next to runner trouble.
      var intake = deriveIntakeForWorkspace(rawIntake, ref, now);

      // H3 (claude-tools-uxvh3) — the §6.6/§8.5 Blueprint card chip, read from the
      // §8.1 `blueprint_meta` projection (thumbnail-sized — this VIEW-MODEL adds NO
      // per-card blueprint fetch; the hub keeps its "one /api/board read" discipline
      // in the pure core). present is honest (a map exists iff updated_at or thumb_ref
      // is set); updated_ago is the "updated 2h ago" freshness; active_count is the
      // §8.2 in-flight overlay size. Absent block ⇒ present:false (an older producer /
      // no map yet — the chip is simply omitted). wmmc (claude-tools-wmmc) layers the
      // §8.5 live mini-MAP render ON TOP of this chip: app.js LAZILY (IntersectionObserver,
      // after first paint) fetches /api/ws/blueprint per visible card and renders the
      // map body at thumb scale via deriveBlueprintThumb — the meta chip here stays the
      // honest first-paint + fallback. The one-read posture is preserved (the lazy fetch
      // is a post-paint enhancement, never part of the hub's first render).
      var bm = (p && p.blueprint_meta && typeof p.blueprint_meta === 'object' &&
        !Array.isArray(p.blueprint_meta)) ? p.blueprint_meta : {};
      var bpUpdatedAt = (typeof bm.updated_at === 'string' && bm.updated_at) ? bm.updated_at : null;
      var bpActive = Array.isArray(bm.active_domains)
        ? bm.active_domains.filter(function (x) { return typeof x === 'string' && x; }) : [];
      var blueprint = {
        present: !!(bpUpdatedAt || (typeof bm.thumb_ref === 'string' && bm.thumb_ref)),
        thumb_ref: (typeof bm.thumb_ref === 'string' && bm.thumb_ref) ? bm.thumb_ref : null,
        updated_at: bpUpdatedAt,
        updated_ago: bpUpdatedAt ? formatAgo(bpUpdatedAt, now) : null,
        active_count: bpActive.length,
        // The §8.2 active-domain ids (NOT just the count) — wmmc's lazy mini-MAP
        // render passes these to deriveBlueprintThumb so the RIGHT cells light up.
        // The hub still carries only the thumbnail-sized meta from /api/board; the
        // map BODY for the thumb is fetched lazily per card (app.js), never inlined.
        active_domains: bpActive,
        href: '/ws/' + encodeURIComponent(ref) + '/blueprint'
      };

      // health — 'stale' when liveness stale; 'attention' when a live mismatch
      // OR a failing lifecycle card attributable to this workspace by prefix OR
      // a failing/gave-up intake; otherwise 'ok'. Every input is a projection
      // fact — nothing fabricated.
      var hasFailure = false;
      STAGE_ORDER.forEach(function (stage) {
        var list = Array.isArray(cols[stage]) ? cols[stage] : [];
        list.forEach(function (c) {
          if (c && c.failure && prefixMatch(c.bead_ref, ref)) hasFailure = true;
        });
      });
      var health;
      if (isStale) health = 'stale';
      else if (mismatch || hasFailure || intake.attention_count > 0) health = 'attention';
      else health = 'ok';

      // claude-tools-758l — the F2 desired-state CONTROL row on the card (the
      // four Run/Pause/Spare-only/Stop buttons). `active` is the button matching
      // the CURRENT ACTUAL (NEVER desired — principle 4); a stale runner has NO
      // active button (S-1: no honest live state to highlight). Same derivation
      // as board-view.js deriveRunner so the three surfaces agree.
      var controls = DESIRED_CONTROLS.map(function (c) {
        return {
          state: c.state,
          label: c.label,
          active: liveness === 'live' && actual === c.state
        };
      });
      // Pending banner — client-side ephemeral (the tap capture). Only surfaced
      // until the projection's actual catches up; NEVER promotes actual.
      var pend = pendingMap[ref] || null;
      var pState = (pend && typeof pend.state === 'string') ? pend.state : null;
      var pendingDesired = (pState && pState !== actual) ? pState : null;
      var pendingLabel = pendingDesired
        ? 'desired: ' + pendingDesired + ' (waiting for runner to honor)'
        : null;

      return {
        project_ref: ref,
        liveness: liveness,
        mode: actual,                       // the ACTUAL runner state (§4.2)
        is_stale: isStale,
        mismatch: mismatch,
        desired: desired,
        ago: ago,
        state_label: stateLabel,
        current_task: currentTask,
        current_task_title: currentTaskTitle,
        health: health,
        decisions: decisions,
        // L3 — the intake-state thread for this workspace (counts + the
        // renderable items + the attention tally).
        intake: intake,
        // H3 — the Blueprint card chip (thumbnail freshness + in-flight count).
        blueprint: blueprint,
        // claude-tools-758l — the F2 desired-state controls (consumed by
        // RunnerCard.renderControls in the card) + the ephemeral pending banner.
        controls: controls,
        pending_desired: pendingDesired,
        pending_label: pendingLabel,
        // DERIVED — labeled. The UI MUST surface this as "derived from board".
        stage_counts: stageCounts,
        stage_total: stageTotal,
        derived: true,
        href: '/ws/' + encodeURIComponent(ref) + '/board'
      };
    });

    // Sort: attention/stale first (surface what needs you), then live, then by
    // project_ref. We rank by a health weight, falling back to a stable
    // alphabetic tiebreak so the order is deterministic for the test harness.
    function weight(card) {
      if (card.health === 'stale') return 0;
      if (card.health === 'attention') return 1;
      if (card.liveness === 'live') return 2;
      return 3;
    }
    cards.sort(function (a, b) {
      var wa = weight(a), wb = weight(b);
      if (wa !== wb) return wa - wb;
      return a.project_ref < b.project_ref ? -1 : (a.project_ref > b.project_ref ? 1 : 0);
    });

    // L3 — the global intake-attention total: failing + gave-up across every
    // workspace. This is the leak counter — the number that, if it were ever
    // silently >0, meant Brian's ideas were dying unseen (the 19-retry night).
    var intakeAttentionTotal = cards.reduce(function (a, c) {
      return a + (c.intake ? c.intake.attention_count : 0);
    }, 0);

    return {
      ok: true,
      principal: snap.principal || '(unresolved)',
      schema_version: sv,
      cards: cards,
      decisions_total: decisionsTotal,
      intake_attention_total: intakeAttentionTotal
    };
  }

  return {
    deriveWorkspacesView: deriveWorkspacesView,
    deriveIntakeForWorkspace: deriveIntakeForWorkspace,
    formatAgo: formatAgo,
    prefixMatch: prefixMatch,
    STAGE_ORDER: STAGE_ORDER,
    INTAKE_STATE_ORDER: INTAKE_STATE_ORDER,
    DESIRED_CONTROLS: DESIRED_CONTROLS,
    SUPPORTED_SNAPSHOT_SCHEMA: SUPPORTED_SNAPSHOT_SCHEMA
  };
});
