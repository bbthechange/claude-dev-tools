/* beads-runner/web/workspace/gates-view.js — Gates facet (J3,
 * claude-tools-uxvj3; DESIGN J §4 + UX-DESIGN-V2 §7.2/§7.3, Contract C).
 *
 * THE PURE, HEADLESS-TESTABLE CORE of the per-workspace Gates facet — the
 * /ws/<ref>/gates view that answers "what is holding a ready-looking task in
 * THIS workspace, why, and what would release it?". No DOM, no network, no
 * timers, no write path: input is the §4.5 work-snapshot projection JSON (the
 * SAME /api/board read every facet consumes) + the workspace ref + now-ms;
 * output is a deterministic view model of strings. lib/test-gates-view.sh drives
 * THIS module against a hand-crafted fixture — the producer↔renderer seam
 * asserted against the FROZEN Contract B.1 projects[].holds[] shape (the J2
 * unifier in cf/src/reconcile.js buildHolds), never against a faked render.
 *
 * What it renders (DESIGN J §4 / the §7.2 mock, NORMATIVE):
 *   • GATES — our editable hold (holds[].type === "gate"). Each carries name +
 *     task_count + owner + set_at + why + unblocks_when + scope, and exposes the
 *     edit affordances (lift / edit why / edit unblock). A Scheduled hold whose
 *     owning_gate === this gate's label is NESTED under it (§7.2: "shown under
 *     its Gate, so lifting the Gate visibly clears the defers it owns").
 *   • DEPENDENCY — beads-native blocked (holds[].type === "dependency").
 *     READ-ONLY, shown with its native unblock condition + the honest
 *     "(beads-native — read-only)" note.
 *   • SCHEDULED — beads-native defer (holds[].type === "scheduled"). READ-ONLY.
 *     A defer set on behalf of a Gate nests under that Gate (above); a standalone
 *     defer renders in its own list with the honest beads-native note.
 *
 * HONESTY (the binding rules — DESIGN J §4 + the C3 honesty constraint):
 *   • editable IS THE PROJECTION'S CALL, NOT THE VIEW'S. `editable` is copied
 *     VERBATIM from each hold (true only for gate — buildHolds encodes the C3
 *     rule so no UI can fake-edit a beads-native hold). The renderer keys its
 *     edit affordances on this flag; this view NEVER decides editability itself
 *     (must-protect #6 / D.1: Dependency + Scheduled are read, never changed).
 *   • B.4 TOLERANCE. A missing holds[] block ⇒ empty lists + a degraded note; a
 *     malformed hold / missing field ⇒ an honest placeholder + a degraded[]
 *     note, NEVER a thrown exception or a silently-dropped row (the 4xe /
 *     inbox-renderer tolerance — never re-add a render refusal). A gate label
 *     with no metadata row surfaces as missing_meta:true (null why/unblock +
 *     a degraded note), NEVER hidden. An out-of-set hold type lands in other[]
 *     shown raw + a degraded note — never fabricated into one of the three.
 *   • The ONE hard refusal is an unknown-HIGHER (or missing/non-integer)
 *     schema_version (§0.3 — the inbox-view schemaGate pattern). Everything else
 *     degrades.
 *
 * ANTI-DRIFT: presentation derivation ONLY — no write path, no fetch, no DOM.
 * Reads ONLY the keys B.1 promises on projects[].holds[] (must-protect #2, the
 * projection-drop guard). The hold types it labels are the FROZEN D.2 closed set
 * (gate | dependency | scheduled); an out-of-set type degrades rather than being
 * coerced. The WRITE path (lift / edit / add) lives entirely in app.js, routed
 * through the engine-direct gate-meta proxy + the host-effecting agent-action
 * gate-apply/gate-lift proxy (design/agent-action.md §7) — never here.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.GatesView = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // The contract-bound schema version this view understands (§0.3 / §4.5).
  var SUPPORTED_SNAPSHOT_SCHEMA = 1;

  // The D.2 closed hold-type set. An out-of-set type degrades to other[] (B.4),
  // it is NEVER coerced into one of the three (which would fake editability).
  var HOLD_TYPE = { gate: 1, dependency: 1, scheduled: 1 };

  // The full gate-label shape (mirrors GATE_LABEL_RE in reconcile.js / the
  // gate-defer.sh `_is_valid_gate_id` shape with the `gate:` namespace prefix).
  // The BARE id (what agent-action target.gate_id needs — gate-defer.sh builds
  // the `gate:<id>` label itself) is the label minus this prefix.
  var GATE_LABEL_RE = /^gate:[a-z0-9][a-z0-9-]*$/;

  /* relAge(iso, nowMs) → "4d ago" | "3h ago" | "12m ago" | "just now" | null.
   * PRESENTATION of a gate's set_at (NOT a liveness decision). A bad/absent/
   * future timestamp ⇒ null (the renderer omits the age — honest absence). */
  function relAge(iso, nowMs) {
    if (typeof iso !== 'string' || !iso) return null;
    var t = Date.parse(iso);
    if (isNaN(t)) return null;
    if (typeof nowMs !== 'number' || !isFinite(nowMs)) return null;
    var ms = nowMs - t;
    if (ms < 0) return null; // a future set_at is not honestly "ago"
    var s = Math.floor(ms / 1000);
    if (s < 60) return 'just now';
    var m = Math.floor(s / 60);
    if (m < 60) return m + 'm ago';
    var h = Math.floor(m / 60);
    if (h < 24) return h + 'h ago';
    var d = Math.floor(h / 24);
    return d + 'd ago';
  }

  /* ownerLabel(owner) → a human phrase. "you" → "you"; "agent:<hat>" →
   * "agent: <hat>" (so Brian sees AN AGENT PLACED THIS, §7.3 / the thirsty
   * invisible-defer fix); null/empty → "(owner unrecorded)" (honest, B.4). */
  function ownerLabel(owner) {
    if (typeof owner !== 'string' || !owner) return '(owner unrecorded)';
    if (owner === 'you') return 'you';
    if (owner.indexOf('agent:') === 0) {
      var hat = owner.slice('agent:'.length);
      return hat ? 'agent: ' + hat : 'an agent';
    }
    return owner;
  }

  /* countLabel(n) → "3 tasks" | "1 task" | "no tasks". */
  function countLabel(n) {
    if (typeof n !== 'number' || !isFinite(n) || n < 0) return 'tasks: unknown';
    if (n === 0) return 'no tasks';
    return n === 1 ? '1 task' : n + ' tasks';
  }

  /* deriveScheduled(hold) → the read-only Scheduled-hold view model. owning_gate
   * (the gate:<id> label co-present on the bead) decides the honest note + the
   * nesting (§7.2). editable is copied VERBATIM (always false for a beads-native
   * hold). */
  function deriveScheduled(hold) {
    var ref = (typeof hold.task_ref === 'string' && hold.task_ref) ? hold.task_ref : null;
    var deferredUntil = (typeof hold.deferred_until === 'string' && hold.deferred_until)
      ? hold.deferred_until : null;
    var owningGate = (typeof hold.owning_gate === 'string' && hold.owning_gate)
      ? hold.owning_gate : null;
    var unblocks = (typeof hold.unblocks_when === 'string' && hold.unblocks_when)
      ? hold.unblocks_when : deferredUntil;
    return {
      type: 'scheduled',
      task_ref: ref,
      task_ref_label: ref || '(task unrecorded)',
      deferred_until: deferredUntil,
      deferred_until_label: deferredUntil || '(no date recorded)',
      owning_gate: owningGate,
      unblocks_when: unblocks,
      unblocks_when_label: unblocks || '(no unblock condition recorded)',
      // §7.2 mock: a defer set on behalf of a Gate reads "beads-native;
      // gate-owned"; a standalone defer reads "beads-native — read-only". Both
      // honest, both read-only.
      native_note: owningGate ? 'beads-native; gate-owned' : 'beads-native — read-only',
      gate_owned: !!owningGate,
      editable: hold.editable === true // VERBATIM — always false for scheduled
    };
  }

  /* deriveDependency(hold) → the read-only Dependency-hold view model. The
   * unblock condition is the honest native "<blocked_on> closes". editable is
   * copied VERBATIM (always false). */
  function deriveDependency(hold) {
    var ref = (typeof hold.task_ref === 'string' && hold.task_ref) ? hold.task_ref : null;
    var blockedOn = (typeof hold.blocked_on === 'string' && hold.blocked_on)
      ? hold.blocked_on : null;
    var unblocks = (typeof hold.unblocks_when === 'string' && hold.unblocks_when)
      ? hold.unblocks_when : (blockedOn ? blockedOn + ' closes' : null);
    return {
      type: 'dependency',
      task_ref: ref,
      task_ref_label: ref || '(task unrecorded)',
      blocked_on: blockedOn,
      blocked_on_label: blockedOn || '(blocking task unrecorded)',
      unblocks_when: unblocks,
      unblocks_when_label: unblocks || '(no unblock condition recorded)',
      native_note: 'beads-native — read-only',
      editable: hold.editable === true // VERBATIM — always false for dependency
    };
  }

  /* deriveGate(hold, degraded) → the EDITABLE Gate-hold view model, or null if
   * un-addressable (no id — degraded note + dropped from the row list, kept
   * honest via the footnote). missing_meta:true is the B.4 degrade for a gate
   * label placed before its metadata row existed (null why/unblock). */
  function deriveGate(hold, degraded) {
    var id = (typeof hold.id === 'string' && GATE_LABEL_RE.test(hold.id)) ? hold.id : null;
    if (!id) {
      degraded.push('a gate hold had no valid id (gate:<id> shape) — not rendered');
      return null;
    }
    var bareId = id.slice('gate:'.length);
    var why = (typeof hold.why === 'string' && hold.why) ? hold.why : null;
    var unblocks = (typeof hold.unblocks_when === 'string' && hold.unblocks_when)
      ? hold.unblocks_when : null;
    var owner = (typeof hold.owner === 'string' && hold.owner) ? hold.owner : null;
    var scope = (hold.scope === 'task' || hold.scope === 'cohort') ? hold.scope : null;
    var setAt = (typeof hold.set_at === 'string' && hold.set_at) ? hold.set_at : null;
    var taskCount = (typeof hold.task_count === 'number' && isFinite(hold.task_count))
      ? hold.task_count : null;
    // The projection itself flags a metadata-less gate (buildHolds: degraded[]
    // "gate placed before metadata existed"). Trust that flag AND re-derive it
    // from a null why so the view degrades even if a future producer drops the
    // note (defence in depth, B.4).
    var projDegraded = Array.isArray(hold.degraded)
      ? hold.degraded.filter(function (x) { return typeof x === 'string' && x; })
      : [];
    var missingMeta = projDegraded.length > 0 || why === null;
    if (missingMeta) {
      degraded.push('gate ' + id + ': metadata missing — why/unblock shown as unrecorded ' +
        '(gate placed before metadata existed)');
    }
    return {
      type: 'gate',
      id: id,             // full label gate:<id>
      gate_id: bareId,    // BARE id — what agent-action target.gate_id needs
      name: bareId,       // the gate's human name (the §7.2 mock shows the bare id)
      task_count: taskCount,
      task_count_label: countLabel(taskCount),
      owner: owner,
      owner_label: ownerLabel(owner),
      set_at: setAt,
      set_at_age: relAge(setAt, this && typeof this.now === 'number' ? this.now : NaN),
      why: why,
      why_label: why || '(no why recorded)',
      unblocks_when: unblocks,
      unblocks_when_label: unblocks || '(no unblock condition recorded)',
      scope: scope,
      scope_label: scope || 'task', // engine defaults absent scope to "task"
      missing_meta: missingMeta,
      editable: hold.editable === true, // VERBATIM — true only for gate
      scheduled_under: [] // filled in deriveGatesView once all scheduled holds are seen
    };
  }

  /* deriveGatesView(snapshot, ref, nowMs?) → the whole Gates-facet model.
   * On an unknown HIGHER (or missing/non-integer) schema_version it returns an
   * ERROR view (§0.3 — refuse, never best-effort-render). Otherwise:
   *   { ok:true, principal, schema_version, project_ref, found,
   *     gates[], dependencies[], scheduled[], other[], counts, empty, degraded[] }
   * `found:false` (no project for this ref) is NOT a refusal — it degrades to an
   * honest "no runner reported for <ref>" empty state. */
  function deriveGatesView(snapshot, ref, nowMs) {
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
          ' (this Gates facet binds v' + SUPPORTED_SNAPSHOT_SCHEMA +
          ') — refusing to best-effort-render (§0.3)'
      };
    }

    var degraded = [];
    var now = (typeof nowMs === 'number' && isFinite(nowMs)) ? nowMs : NaN;
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

    var holds = (found && Array.isArray(proj.holds)) ? proj.holds : null;
    if (found && proj.holds != null && !Array.isArray(holds)) {
      degraded.push('holds[] malformed — shown empty');
    } else if (found && holds === null) {
      degraded.push('holds[] not reported for this workspace');
    }

    var gates = [];
    var dependencies = [];
    var scheduledAll = [];
    var other = [];
    var ctx = { now: now };

    (holds || []).forEach(function (h, idx) {
      if (!h || typeof h !== 'object' || Array.isArray(h)) {
        degraded.push('hold #' + idx + ' malformed — skipped');
        return;
      }
      var type = (typeof h.type === 'string') ? h.type : '';
      if (!HOLD_TYPE[type]) {
        degraded.push('hold #' + idx + ' has out-of-set type ' + JSON.stringify(type) +
          ' — shown raw (read-only)');
        other.push({
          type: type || '(missing type)',
          raw: h,
          task_ref: (typeof h.task_ref === 'string' && h.task_ref) ? h.task_ref : null,
          editable: false // an unknown hold type is NEVER editable
        });
        return;
      }
      if (type === 'gate') {
        var g = deriveGate.call(ctx, h, degraded);
        if (g) gates.push(g);
      } else if (type === 'dependency') {
        dependencies.push(deriveDependency(h));
      } else { // scheduled
        scheduledAll.push(deriveScheduled(h));
      }
    });

    // §7.2: a Scheduled hold set on behalf of a Gate (owning_gate === the gate's
    // label) is NESTED under that Gate, so lifting the Gate visibly accounts for
    // the defers it owns. A scheduled hold whose owning_gate matches NO gate in
    // this view stays standalone (honest — still flagged gate_owned in its note).
    var gateById = {};
    gates.forEach(function (g) { gateById[g.id] = g; });
    var scheduled = [];
    scheduledAll.forEach(function (s) {
      if (s.owning_gate && gateById[s.owning_gate]) {
        gateById[s.owning_gate].scheduled_under.push(s);
      } else {
        scheduled.push(s);
      }
    });

    var heldTasks = countHeldTasks(gates, dependencies, scheduled, other);
    var total = gates.length + dependencies.length + scheduled.length + other.length;

    return {
      ok: true,
      principal: snap.principal || '(unresolved)',
      schema_version: sv,
      project_ref: wsRef,
      found: found,
      gates: gates,
      dependencies: dependencies,
      scheduled: scheduled,
      other: other,
      counts: {
        gates: gates.length,
        dependencies: dependencies.length,
        scheduled: scheduled.length,
        other: other.length,
        total: total,
        held_tasks: heldTasks
      },
      empty: total === 0,
      degraded: degraded
    };
  }

  /* countHeldTasks — a rollup for the section header ("N held in <ws>"). Gates
   * count by task_count (a cohort holds many); dep/sched/other count one bead
   * each. Best-effort presentation only (never authoritative). */
  function countHeldTasks(gates, deps, sched, other) {
    var n = 0;
    gates.forEach(function (g) {
      n += (typeof g.task_count === 'number' && g.task_count > 0) ? g.task_count : 1;
      n += g.scheduled_under.length; // nested defers are distinct held beads
    });
    n += deps.length + sched.length + other.length;
    return n;
  }

  return {
    deriveGatesView: deriveGatesView,
    deriveGate: deriveGate,
    deriveDependency: deriveDependency,
    deriveScheduled: deriveScheduled,
    relAge: relAge,
    ownerLabel: ownerLabel,
    countLabel: countLabel,
    SUPPORTED_SNAPSHOT_SCHEMA: SUPPORTED_SNAPSHOT_SCHEMA
  };
});
