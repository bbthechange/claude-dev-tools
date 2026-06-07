/* beads-runner/web/cross-ws/cross-ws-view.js — K5 (claude-tools-uxvk5).
 * The /cross-ws global view's PURE, headless-testable core (DESIGN K §6;
 * UX-DESIGN-V2 §8.4). Contract C.1: no DOM, no network, no timers, no write
 * path — input is the two reads the surface binds, output is a deterministic
 * view model. cross-ws/app.js drives this; lib/test-cross-ws-view.sh asserts it
 * via a Node require (mirroring lib/test-capacity-view.sh).
 *
 * THE TWO PANES (DESIGN K §6, A.3 — the view reads ONLY relay-log-tail (B.3) +
 * blueprint-get (B.2), never a field off a table directly):
 *   1. COUPLING MAP — a FEDERATED Blueprint slice handed to the H2 renderer
 *      verbatim (DESIGN K §6.1). The federation is the ONLY K5-specific code:
 *      it joins the cross-WS exchanges + each workspace's blueprint into ONE
 *      Diagrammer record (each workspace = a top-level `domain` box; each
 *      from→to relay = a `call` coupling edge; each workspace's own top-level
 *      domains ride along as drill-in `capability` children — the "slice").
 *      `federateCoupling()` emits a B.2-shaped record; cross-ws/app.js (and the
 *      test) feed it to `BlueprintView.deriveBlueprintView()` — the H2 layout +
 *      edge IP, reused, never re-spec'd (the deriveBlueprintThumb precedent on
 *      the Workspaces hub).
 *   2. RELAY LOG — the auditable trail of exchanges from `relay-log-tail`
 *      (B.3), reshaped to display rows. The auditable detail behind the batched
 *      FYIs (K3); resolved shows the answer, escalated shows the decision
 *      pointer (dossier_ref).
 *
 * COUPLING FROM THE RELAY LOG (the grounded, A.3-conformant federation source):
 *   The set of workspaces and the edges between them come from the relay log
 *   itself — the exchanges ARE the coupling (who asked whom). blueprint-get is
 *   the ENRICHMENT (each workspace box's drill-in domains), best-effort. So the
 *   map needs NO work-snapshot read (A.3) and directly reflects real cross-WS
 *   activity; an empty relay log ⇒ an honest "no cross-workspace coupling yet".
 *
 * TOLERANCE (B.4, the 4xe write-gate/render-tolerance line): every field
 * degrades to an honest placeholder with a `degraded[]` note — never raises,
 * never fabricates, never re-adds a render refusal. The single sanctioned
 * refusal point is the integer schema gate (§0.3): SUPPORTED_BLUEPRINT_SCHEMA
 * bounds the per-workspace blueprint (B.2) this view reads — an unknown-HIGHER
 * one has its drill-in children omitted (noted), the workspace box still shown
 * from the relay log. The relay log itself carries no schema_version to gate.
 * The federated record this module stamps is always schema_version:1, so the H2
 * deriveBlueprintView gate never fires on it by construction.
 *
 * ANTI-DRIFT: binds DESIGN K §6 + Contract B.3 (relay-log-tail shape) + B.2
 * (the blueprint record shape the federation emits) + A.3 (read-only-projection
 * sources). The B.3 `outcome` is the FROZEN closed enum {resolved,escalated}.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.CrossWsView = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // B.3 `outcome` — the FROZEN closed enum (mirrors cf/src/relay.js outcomeOk).
  var OUTCOME = { resolved: 1, escalated: 1 };

  // The blueprint record schema this view binds (B.2 / §0.3 — the 4xe integer
  // gate). The single sanctioned refusal point: a per-workspace blueprint whose
  // schema_version is unknown-HIGHER than this bound has its drill-in slice
  // omitted (degraded + noted), never best-effort-rendered past the bound. The
  // workspace box itself still shows (it comes from the relay log, not the
  // blueprint), so a newer sibling never blanks the coupling map or the log.
  var SUPPORTED_BLUEPRINT_SCHEMA = 1;

  // §3.1 top-level node kinds we lift from a workspace blueprint as the drill-in
  // children of its federated box (capability is NOT top-level — it is the child
  // we synthesize). Mirrors blueprint-view.js TOP_LEVEL_KIND (kept local so this
  // module stays dependency-free + Node-testable on its own).
  var TOP_KIND = { domain: 1, client: 1, store: 1, vendor: 1, external: 1 };

  // §4 stable node-id shape `kind:slug` — mirror blueprint-view.js NODE_ID_RE so
  // the federated ids we emit are exactly what the H2 renderer accepts.
  var NODE_ID_RE = /^[a-z][a-z0-9-]*:[a-z0-9][a-z0-9-]*$/;

  function strOr(v, d) { return typeof v === 'string' ? v : d; }

  /* slug(s) → a lower-kebab content slug (the §4 id slug part). Non-alnum runs
   * collapse to one '-'; leading/trailing '-' trimmed. May return '' (an
   * unusable slug — the caller degrades). */
  function slug(s) {
    return String(s == null ? '' : s)
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-+|-+$/g, '');
  }

  /* nodeId(kind, sl) → "kind:slug" if it passes NODE_ID_RE, else null. */
  function nodeId(kind, sl) {
    if (!sl) return null;
    var id = kind + ':' + sl;
    return NODE_ID_RE.test(id) ? id : null;
  }

  /* relAge(iso, nowMs) — PRESENTATION of an RFC-3339 stamp ("3h ago" / "just
   * now"); a bad/absent/future stamp ⇒ null (honest absence). Same idiom as
   * blueprint-view.js / gates-view.js relAge. */
  function relAge(iso, nowMs) {
    if (typeof iso !== 'string' || !iso) return null;
    var t = Date.parse(iso);
    if (isNaN(t)) return null;
    if (typeof nowMs !== 'number' || !isFinite(nowMs)) return null;
    var ms = nowMs - t;
    if (ms < 0) return null;
    var s = Math.floor(ms / 1000);
    if (s < 60) return 'just now';
    var m = Math.floor(s / 60);
    if (m < 60) return m + 'm ago';
    var h = Math.floor(m / 60);
    if (h < 24) return h + 'h ago';
    var d = Math.floor(h / 24);
    return d + 'd ago';
  }

  /* relayWorkspaceRefs(relayTail) → the unique workspace refs that appear in the
   * relay log, in first-seen order (from_ws then to_ws per row). This is the
   * federation's workspace set AND the list cross-ws/app.js fetches blueprints
   * for. Tolerant of a missing/garbled exchanges[]. */
  function relayWorkspaceRefs(relayTail) {
    var seen = Object.create(null), order = [];
    var raw = relayTail && Array.isArray(relayTail.exchanges) ? relayTail.exchanges : [];
    raw.forEach(function (e) {
      if (!e || typeof e !== 'object' || Array.isArray(e)) return;
      [e.from_ws, e.to_ws].forEach(function (w) {
        if (typeof w === 'string' && w && !seen[w]) { seen[w] = 1; order.push(w); }
      });
    });
    return order;
  }

  /* topLevelDomainsOf(rec, ref, degraded) → the workspace blueprint's top-level
   * boxes ({label, slug}) lifted as the federated box's drill-in children. Pure,
   * tolerant: a null/error/unparseable/newer-schema record degrades to [] with a
   * note — the workspace box still appears (from the relay log), just without its
   * drill-in slice. */
  function topLevelDomainsOf(rec, ref, degraded) {
    if (rec == null) return [];
    if (typeof rec !== 'object' || Array.isArray(rec)) return [];
    if (rec.ok === false) {
      degraded.push('blueprint for ' + ref + ' unavailable' +
        (typeof rec.error === 'string' && rec.error ? ' (' + rec.error + ')' : '') +
        ' — drill-in domains omitted');
      return [];
    }
    var sv = rec.schema_version;
    if (typeof sv === 'number' && sv > SUPPORTED_BLUEPRINT_SCHEMA) {
      degraded.push('blueprint for ' + ref + ' is schema v' + sv +
        ' (newer than this view) — drill-in domains omitted, box still shown');
      return [];
    }
    var d = rec.derived;
    var nodes = d && Array.isArray(d.nodes) ? d.nodes : [];
    var out = [];
    nodes.forEach(function (n) {
      if (!n || typeof n !== 'object' || Array.isArray(n)) return;
      if (n.parent != null) return;          // top-level only — the macro slice
      if (!TOP_KIND[n.kind]) return;         // skip capabilities / out-of-set kinds
      var label = (typeof n.label === 'string' && n.label)
        ? n.label
        : (typeof n.id === 'string' ? n.id : null);
      if (!label) return;
      var sl = (typeof n.id === 'string' && n.id.indexOf(':') > 0)
        ? n.id.split(':')[1]
        : slug(label);
      out.push({ label: label, slug: sl });
    });
    return out;
  }

  /* federateCoupling(relayTail, blueprintsByRef) → the FEDERATED B.2 record (+
   * meta) for the coupling map (DESIGN K §6.1). The ONLY K5-specific code: join
   * the relay log (workspaces + edges) with each workspace's blueprint (drill-in
   * children) into ONE Diagrammer record. Returns:
   *   { record, degraded[], workspace_count, workspace_refs[],
   *     coupling_edges_raw, empty }
   * The caller hands `record` to BlueprintView.deriveBlueprintView() — the H2
   * layout + edge IP, reused verbatim. Best-effort + degradable (§9): no
   * workspaces in the relay log ⇒ empty:true ("no coupling detected"). */
  function federateCoupling(relayTail, blueprintsByRef) {
    var degraded = [];
    var bps = (blueprintsByRef && typeof blueprintsByRef === 'object') ? blueprintsByRef : {};
    var refs = relayWorkspaceRefs(relayTail);

    var nodes = [], edges = [];
    var refToId = Object.create(null), idSeen = Object.create(null);

    refs.forEach(function (ref) {
      var id = nodeId('domain', slug(ref));
      if (!id) {
        degraded.push('workspace ref ' + JSON.stringify(ref) +
          ' has no usable slug — not placed on the map');
        return;
      }
      if (idSeen[id]) {
        // two refs slugify to the same id — keep the first, route edges to it.
        degraded.push('workspace ref ' + JSON.stringify(ref) +
          ' collides with an earlier ref on the map — merged');
        refToId[ref] = id;
        return;
      }
      idSeen[id] = 1;
      refToId[ref] = id;
      nodes.push({ id: id, parent: null, kind: 'domain', label: ref });

      // attach the workspace's own top-level domains as drill-in capabilities.
      var children = topLevelDomainsOf(bps[ref], ref, degraded);
      var childSeen = Object.create(null);
      children.forEach(function (cd) {
        var cid = nodeId('capability', slug(ref) + '--' + slug(cd.slug));
        if (!cid || childSeen[cid]) return;
        childSeen[cid] = 1;
        nodes.push({ id: cid, parent: id, kind: 'capability', label: cd.label });
      });
    });

    // coupling edges — one raw edge per from→to exchange; deriveBlueprintView
    // bundles them by (from,to,kind) so the rendered edge `count` = #exchanges.
    var raw = relayTail && Array.isArray(relayTail.exchanges) ? relayTail.exchanges : [];
    raw.forEach(function (e) {
      if (!e || typeof e !== 'object' || Array.isArray(e)) return;
      var f = typeof e.from_ws === 'string' ? e.from_ws : null;
      var t = typeof e.to_ws === 'string' ? e.to_ws : null;
      if (!f || !t || f === t) return;       // a self-ask is not a coupling edge
      var fid = refToId[f], tid = refToId[t];
      if (!fid || !tid) return;              // an endpoint that did not place
      edges.push({ from: fid, to: tid, kind: 'call', bundle_key: fid + '->' + tid });
    });

    var topCount = nodes.filter(function (n) { return n.parent == null; }).length;
    var record = {
      schema_version: 1,
      project_ref: 'cross-ws',
      derived: { nodes: nodes, edges: edges, apis: [] },
      customization: {},
      narrative: null,
      conflicts: []
    };
    return {
      record: record,
      degraded: degraded,
      workspace_count: topCount,
      workspace_refs: refs,
      coupling_edges_raw: edges.length,
      empty: topCount === 0
    };
  }

  /* deriveRelayView(relayTail, nowMs) → the RELAY LOG pane model (B.3 → display
   * rows, B.4 tolerant). `relayTail` is the `{exchanges:[...]}` projection, OR a
   * proxy `{ok:false,error}` envelope (the engine/proxy was unreachable), OR
   * null. NEVER refuses (B.4) — an error envelope surfaces as an honest
   * `unavailable` banner, a missing array degrades to empty + a note. */
  function deriveRelayView(relayTail, nowMs) {
    var degraded = [];

    // a proxy/engine error envelope — honest "unavailable", not a fabricated log.
    if (relayTail && typeof relayTail === 'object' && relayTail.ok === false) {
      return {
        ok: true,
        unavailable: true,
        error: typeof relayTail.error === 'string' ? relayTail.error : 'relay log unavailable',
        exchanges: [],
        empty: true,
        counts: { resolved: 0, escalated: 0, unknown: 0, total: 0 },
        degraded: degraded
      };
    }

    var raw = relayTail && Array.isArray(relayTail.exchanges) ? relayTail.exchanges : [];
    if (relayTail && !Array.isArray(relayTail.exchanges)) {
      degraded.push('relay-log-tail response had no exchanges[] array — treated as empty');
    }

    var resolved = 0, escalated = 0, unknown = 0;
    var exchanges = raw.map(function (e, i) {
      var ex = (e && typeof e === 'object' && !Array.isArray(e)) ? e : {};
      var from = strOr(ex.from_ws, '');
      var to = strOr(ex.to_ws, '');
      var outcome = OUTCOME[ex.outcome] ? ex.outcome : null;
      if (ex.outcome != null && !outcome) {
        degraded.push('exchange #' + i + ' outcome ' + JSON.stringify(ex.outcome) +
          ' not in {resolved,escalated} — shown as unknown');
      }
      var isEscalated = outcome === 'escalated';
      var isResolved = outcome === 'resolved';
      if (isResolved) resolved++;
      else if (isEscalated) escalated++;
      else unknown++;

      var dossier = (typeof ex.dossier_ref === 'string' && ex.dossier_ref) ? ex.dossier_ref : null;
      var answer = strOr(ex.answer, '');
      var atRaw = strOr(ex.at, '');

      return {
        id: strOr(ex.id, ''),
        from_ws: from || '(unknown)',
        to_ws: to || '(unknown)',
        pair_label: (from || '?') + ' → ' + (to || '?'),   // FE → BE
        at: atRaw,
        at_label: relAge(atRaw, nowMs) || (atRaw || 'time unknown'),
        question: strOr(ex.question, '') || '(no question recorded)',
        answer: answer,
        outcome: outcome || 'unknown',
        escalated: isEscalated,
        resolved: isResolved,
        dossier_ref: dossier,
        // the body line: resolved shows the answer; escalated shows the decision
        // pointer; an unknown/blank degrades honestly (never fabricated).
        body: isEscalated
          ? ('escalated to a decision' + (dossier ? ' — ' + dossier : ''))
          : (answer || (isResolved ? '(answered — no text recorded)' : '(no answer recorded)'))
      };
    });

    return {
      ok: true,
      unavailable: false,
      exchanges: exchanges,
      empty: exchanges.length === 0,
      counts: { resolved: resolved, escalated: escalated, unknown: unknown, total: exchanges.length },
      degraded: degraded
    };
  }

  /* deriveCrossWsView(relayTail, blueprintsByRef, nowMs) → the whole page model.
   * Convenience wrapper: the relay pane (deriveRelayView) + the coupling
   * federation (federateCoupling). The H2 render step
   * (BlueprintView.deriveBlueprintView on coupling.record) stays in
   * cross-ws/app.js (and the lib test) so THIS module is dependency-free and
   * Node-testable on its own. Always ok:true — B.4 tolerance, no refusal. */
  function deriveCrossWsView(relayTail, blueprintsByRef, nowMs) {
    return {
      ok: true,
      relay: deriveRelayView(relayTail, nowMs),
      coupling: federateCoupling(relayTail, blueprintsByRef)
    };
  }

  return {
    deriveCrossWsView: deriveCrossWsView,
    deriveRelayView: deriveRelayView,
    federateCoupling: federateCoupling,
    relayWorkspaceRefs: relayWorkspaceRefs,
    topLevelDomainsOf: topLevelDomainsOf,
    relAge: relAge,
    slug: slug,
    OUTCOME: OUTCOME,
    SUPPORTED_BLUEPRINT_SCHEMA: SUPPORTED_BLUEPRINT_SCHEMA
  };
});
