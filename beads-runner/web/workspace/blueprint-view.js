/* beads-runner/web/workspace/blueprint-view.js — Blueprint MAP renderer (H2,
 * claude-tools-uxvh2; DESIGN H = design/blueprint.md §3 + §4, UX-DESIGN-V2 §6.1,
 * Contract B.2/B.4/C).
 *
 * THE PURE, HEADLESS-TESTABLE CORE of the Blueprint map — the renderer that ports
 * the Diagrammer IP (~/Downloads/HANDOFF.md §3/5/6/7) onto the in-repo schema the
 * design froze. No DOM, no network, no timers, no write path. Input is the
 * blueprint-get RECORD body (B.2 — the one facet that reads its own §4 record, NOT
 * the work-snapshot; §8.1 keeps the map body out of the projection and fetches it
 * on demand) + now-ms + a render-state opts {focus, opened, scale}; output is a
 * deterministic view model. lib/test-blueprint-view.sh drives THIS module against
 * a hand-crafted blueprint record — the record↔renderer seam asserted against the
 * FROZEN B.2 derived:{nodes,edges,apis} shape, never a faked render.
 *
 * WHAT IT PORTS — the model + the two algorithms the bead names ("port
 * model+two algorithms, not the prototype"), plus focus/dim/drill (design §3.4):
 *
 *   MODEL (§3.1–3.3) — the mental-model decomposition: top level is PRODUCT
 *   DOMAINS (not infra), plus the client, the stores, and each external vendor as
 *   its own box; internal CAPABILITIES are children seen on drill-in; queues are
 *   EDGES not nodes; APIs are a separate top-level array rendered as boundary
 *   boxes ("the way in"). Capability labels carry human meaning, never a
 *   Lambda/handler name (must-protect #4). Node `kind` is the FROZEN §3.1 closed
 *   set; edge `kind` the FROZEN §3.2 set.
 *
 *   ALGORITHM 1 — GROW-TO-FIT nested layout (§3.4.2): drill into any box to see
 *   its children; an OPEN parent grows to fit its children laid out in a grid +
 *   padding, and siblings reflow ("room to drill in"). The geometry is [free]
 *   (§3.5 — swap elk/dagre/React-Flow later); the model emits a layout{x,y,w,h}
 *   per visible node so a thin renderer (H3) can draw it, but the COORDINATES are
 *   NOT a contract (the test asserts presence/structure, never geometry).
 *
 *   ALGORITHM 2 — EDGE RESOLUTION + density (§3.2, the legibility IP that "stops
 *   arrows from everywhere to everywhere"): edges store their DEEPEST TRUE
 *   endpoints; the renderer resolves each endpoint to its deepest *visible*
 *   ancestor at draw time, drops edges internal to one visible box, and BUNDLES
 *   duplicates by resolved (from,to,kind). At macro (all collapsed) every edge
 *   resolves to a top-level box ⇒ domain↔domain only; on focus, only edges
 *   touching the focused subtree show. This is derived-data-plus-render-logic:
 *   the data is honest (true endpoints on disk), the geometry is [free].
 *
 *   FOCUS / DIM / DRILL (§3.4.4): focus a node ⇒ zoom-to-fit (open it + its
 *   ancestors) and DIM everything not connected to it; drill-out auto-collapses
 *   what focus opened but PRESERVES manual/pinned state (the autoOpened-vs-manual
 *   distinction §4/§5 relies on — each open node carries open_source).
 *
 * STABLE NODE IDENTITY (§4 — the crux, the seam shared with H4): every
 * customization override is keyed by `node.id`, a STABLE content-derived key
 * (`kind:slug`, e.g. domain:posts-feed / store:postgres / capability:create-post)
 * so the SAME real-world concept keeps the SAME id across regens. The renderer
 * APPLIES the customization layer OVER `derived` at render time (§5.2 — a view
 * transform; `derived` on disk is never mutated): rename → label, regroup →
 * reparent, pin → lock-open, hide → drop. An override whose id is ABSENT from the
 * current `derived` simply does not reattach (a soft degraded[] note) — the
 * renderer never throws and never silently rewrites; the conflicts[] APPEND that
 * turns a non-reattaching override into a keep+FYI is the updater's job (H5/§5.3),
 * and any conflicts[] already on the record are carried through verbatim.
 *
 * HONESTY (B.4 — the 4xe write-gate / render-tolerance line, never re-add a render
 * refusal): a null record ⇒ the honest "no Blueprint yet" empty state; a malformed
 * node/edge/api ⇒ skipped + a degraded[] note, NEVER a thrown error and NEVER a fabricated
 * box; an out-of-set node/edge kind degrades (kept, flagged) rather than coerced.
 * The ONE hard refusal is an unknown-HIGHER (or missing/non-integer)
 * schema_version (§0.3 — the inbox-view schemaGate pattern).
 *
 * ANTI-DRIFT: presentation derivation ONLY — no write path, no fetch, no DOM, no
 * timers. The map is the MAP; the §8.3 narrative PARSE (TL;DR/headings +
 * acronym-expand-on-first-use) lives here as pure, testable model (H3) — its DOM
 * RENDER and the ?focus deep-link WIRING are H3's facet app.js; the blueprint_meta
 * projection is H3's engine seam; the in-place rename/regroup/pin/hide GUI +
 * conflict-FYI keep-default are H4. All share the §4 stable-id contract THIS
 * module encodes (makeNodeId / the reattach-by-id logic).
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.BlueprintView = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // The contract-bound blueprint record schema this renderer understands
  // (B.2 schema_version; the §0.3 / 4xe integer-<=-bound gate).
  var SUPPORTED_BLUEPRINT_SCHEMA = 1;

  // §3.1 FROZEN node-kind closed set (the mental-model taxonomy). Top-level boxes
  // are domain | client | store | vendor | external; capability is the drill-in
  // child. An out-of-set kind degrades (kept + flagged), never coerced (B.4).
  var NODE_KIND = {
    domain: 1, client: 1, store: 1, vendor: 1, capability: 1, external: 1
  };
  // The kinds that live at the TOP level of the mental model (§3.1): product
  // domains, the client, the stores, each vendor, plus a free-standing external.
  // capability is NOT top-level — it is a child you see on drill-in.
  var TOP_LEVEL_KIND = { domain: 1, client: 1, store: 1, vendor: 1, external: 1 };

  // §3.2 FROZEN edge-kind closed set (queues are edges, not nodes).
  var EDGE_KIND = { call: 1, queue: 1, data: 1, depends: 1 };

  // §4 stable node-id shape: `kind:slug` (slug = lower-kebab, content-derived).
  // makeNodeId composes/validates it; the renderer keys customization off it.
  var NODE_ID_RE = /^[a-z][a-z0-9-]*:[a-z0-9][a-z0-9-]*$/;

  // Grow-to-fit geometry constants ([free] — §3.5; not a contract). A CLOSED
  // top-level box is a big readable CARD; a drill-in capability is a smaller LEAF;
  // an open parent packs its children in a near-square grid with padding and grows
  // to fit (siblings reflow). H3 may swap this whole block for elk/dagre without
  // touching the schema or the edge-IP.
  var LEAF_W = 176, LEAF_H = 52;        // a drill-in capability leaf
  var CARD_W = 238, CARD_H = 112;       // a CLOSED top-level box (domain/client/store/vendor/ext)
  var PAD = 16, GAP = 16, HEADER = 46;  // open-container header bar + inner padding/gap
  var MARGIN = 72;                      // first band's left inset (> the §7 api half-overhang so a
                                        // leftmost domain's straddle box lands at a non-negative x)
  var BAND_GAP = 150;                   // left→right gap between bands (room for §7 api straddle + edges)
  var API_PAD = 86;                     // width reserved in the domain lane's column gap for an api straddle

  // §5/§13 BANDING — the macro map is a LEFT→RIGHT band layout (the Diagrammer
  // reference), NOT a 1-D strip and NOT top→bottom rows: the client sits on the
  // LEFT, the product domains pack in the middle (a 2-column grid), then the data
  // stores, vendors, and any free-standing external service march off to the RIGHT
  // — exactly the "caller → domains → stores/vendors" reading order, with each
  // domain's §7 API boxes straddling its LEFT (caller-facing) border in the gap
  // before it. Bands are vertically centered against the tallest lane. This is what
  // makes the macro a true 2-D map (top-level boxes differ in BOTH x and y) so the
  // edges read as traceable left→right arrows, never zero-height slivers hidden
  // behind a column. Geometry stays [free] (§3.5) — the CONTRACT is the 2-D spread
  // + visible edges, not the numbers.
  var BAND_ORDER = ['client', 'domain', 'store', 'vendor', 'ext'];
  function bandOf(kind) {
    if (kind === 'external') return 'ext';
    if (kind === 'client' || kind === 'store' || kind === 'vendor') return kind;
    return 'domain';   // domain + any other/unknown top-level box shares the product lane
  }

  /* makeNodeId(kind, slug) → "kind:slug" (the STABLE §4 key) or null if either
   * part is unusable. The id is content-derived so the same concept keeps the
   * same id across regens — that is what lets a customization reattach (§4). */
  function makeNodeId(kind, slug) {
    if (typeof kind !== 'string' || typeof slug !== 'string') return null;
    var id = kind + ':' + slug;
    return NODE_ID_RE.test(id) ? id : null;
  }

  /* relAge(iso, nowMs) → "4d ago" | "3h ago" | "12m ago" | "just now" | null.
   * PRESENTATION of the blueprint's updated_at (the §6.6 "updated 2h ago"); a
   * bad/absent/future stamp ⇒ null (honest absence). Mirrors gates-view.relAge. */
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

  /* bundleKey(from, to, kind) → the dedup key duplicate edges collapse to (§3.2).
   * Directional (from→to) so a call and its reply don't fold together. */
  function bundleKey(from, to, kind) {
    return from + '→' + to + '|' + kind;
  }

  /* asStrArray(x) → x filtered to non-empty strings, or [] (tolerant of a
   * missing/garbled list — B.4). */
  function asStrArray(x) {
    if (!Array.isArray(x)) return [];
    return x.filter(function (s) { return typeof s === 'string' && s; });
  }

  /* ── §8.3 narrative — TL;DR → headings prose, acronyms expanded on first use ───
   * A small CURATED, domain-correct acronym glossary. Expansion is keyed to the
   * §8.3 "expands acronyms on first use" rule; the glossary is hand-curated (never
   * guessed) so every expansion is factual — a fabricated expansion would break
   * B.4 ("never fabricate"). Only WHOLE-WORD, all-uppercase tokens that are keys
   * here are touched; everything else passes through verbatim. v1 is this built-in
   * set; a future per-workspace glossary (§5.1) could feed it ([free], §11). */
  var ACRONYMS = {
    API: 'Application Programming Interface', UI: 'User Interface',
    UX: 'User Experience', DB: 'Database', SQL: 'Structured Query Language',
    PWA: 'Progressive Web App', CDN: 'Content Delivery Network',
    SDK: 'Software Development Kit', JWT: 'JSON Web Token',
    SSE: 'Server-Sent Events', MCP: 'Model Context Protocol',
    CRUD: 'Create, Read, Update, Delete', HTML: 'HyperText Markup Language',
    CSS: 'Cascading Style Sheets', JSON: 'JavaScript Object Notation',
    HTTP: 'Hypertext Transfer Protocol', URL: 'Uniform Resource Locator',
    REST: 'Representational State Transfer', FYI: 'For Your Information'
  };

  /* expandAcronymsFirstUse(text, seen, expandedOut) → text with each known
   * acronym's FIRST occurrence (across the whole narrative — `seen` is shared, so
   * first-use spans TL;DR then every section in order) rewritten "ACR (Expansion)".
   * WHOLE-WORD + all-uppercase + ≥2 chars (the \b…\b bound keeps "APIs"/substrings
   * untouched); case-sensitive (the glossary is uppercase). Already-seen acronyms
   * pass through. Records each expansion in expandedOut for honest transparency. */
  function expandAcronymsFirstUse(text, seen, expandedOut) {
    if (typeof text !== 'string' || !text) return text || '';
    return text.replace(/\b[A-Z][A-Z0-9]{1,9}\b/g, function (tok) {
      if (!Object.prototype.hasOwnProperty.call(ACRONYMS, tok)) return tok;
      if (seen[tok]) return tok;
      seen[tok] = true;
      expandedOut.push({ acronym: tok, expansion: ACRONYMS[tok] });
      return tok + ' (' + ACRONYMS[tok] + ')';
    });
  }

  /* parseNarrative(raw, degraded) → the §8.3 narrative view model:
   *   { present, tldr, sections:[{heading,prose}], acronyms_expanded:[…] }
   * Tolerant (B.4): a null/garbled narrative ⇒ present:false (the facet simply
   * shows no prose, never an exception); a malformed section is skipped + noted.
   * The acronym pass runs in document order (TL;DR first) so "first use" is honest. */
  function parseNarrative(raw, degraded) {
    var out = { present: false, tldr: null, sections: [], acronyms_expanded: [] };
    if (raw == null) return out;
    if (typeof raw !== 'object' || Array.isArray(raw)) {
      degraded.push('narrative block malformed — no design prose shown'); return out;
    }
    var seen = Object.create(null);
    var expanded = out.acronyms_expanded;
    if (typeof raw.tldr === 'string' && raw.tldr) {
      out.tldr = expandAcronymsFirstUse(raw.tldr, seen, expanded);
      out.present = true;
    } else if (raw.tldr != null) {
      degraded.push('narrative.tldr malformed — skipped');
    }
    var rawSections = Array.isArray(raw.sections) ? raw.sections : [];
    if (raw.sections != null && !Array.isArray(raw.sections)) {
      degraded.push('narrative.sections malformed — shown empty');
    }
    rawSections.forEach(function (s, i) {
      if (!s || typeof s !== 'object' || Array.isArray(s)) {
        degraded.push('narrative.sections[' + i + '] malformed — skipped'); return;
      }
      var heading = (typeof s.heading === 'string' && s.heading) ? s.heading : null;
      var prose = (typeof s.prose === 'string' && s.prose) ? s.prose : null;
      if (!heading && !prose) {
        degraded.push('narrative.sections[' + i + '] has neither heading nor prose — skipped');
        return;
      }
      out.sections.push({
        heading: heading ? expandAcronymsFirstUse(heading, seen, expanded) : null,
        prose: prose ? expandAcronymsFirstUse(prose, seen, expanded) : null
      });
      out.present = true;
    });
    return out;
  }

  /* ── normalizeOverlay(opts) — the §6.4/§8.2 in-flight overlay INPUT, tolerant ───
   * The overlay "lights up the domains currently being worked, so Brian can see
   * where the swarm is" (§6.4) and flags the two-agents-one-domain collision-risk
   * signal (the reason auxiliaries are read-only). The renderer reads its own §4
   * blueprint record; the live work is a CROSS-TRACK READ of Track I's activity
   * (§8.2), passed in via opts — this fn folds whatever the caller has into:
   *   activeIds      : id → true   — every reported active node id (ANY form);
   *                                  drives the lit-up (resolved to a visible box).
   *   touchersByNode : id → int    — how many agents touch THIS exact node.
   *   agentsByNode   : id → {key}  — the DISTINCT agent identities touching it;
   *                                  the ONLY honest basis for a domain-level
   *                                  collision (≥2 DIFFERENT agents resolving into
   *                                  one visible box — NOT one writer touching two).
   *
   * THREE accepted shapes for opts.active_domains (+ an opts.activity alias):
   *   1. ["domain:posts-feed", …]                         the FROZEN B.1 union
   *      (blueprint_meta.active_domains, §8.1). A union lists a domain ONCE and
   *      cannot say how many agents touch it, so it LIGHTS the box but asserts NO
   *      collision (identity unknown — inferring one would be a fabrication, B.4).
   *   2. [{ id|domain|node_id, agents|count|touchers }]    explicit per-node count
   *      (forward-compat / testable): agents≥2 ⇒ that node self-collides.
   *   3. { writer:{…touching[]}, auxiliary:[{…touching[]}] } the B.1 activity
   *      sub-object (§8.2 — what the facet has in hand; the one form carrying agent
   *      IDENTITY, so the one form that can honestly tell two-agents-one-domain
   *      from one-writer-two-domains).
   * Absent/garbled ⇒ an empty overlay (the map is simply dark — never an exception). */
  function normalizeOverlay(opts) {
    var activeIds = Object.create(null);      // null-proto: a hostile "__proto__" id is an honest miss
    var touchersByNode = Object.create(null);
    var agentsByNode = Object.create(null);
    function markActive(id) {
      if (typeof id !== 'string' || !id) return;
      activeIds[id] = true;
      if (!(touchersByNode[id] > 0)) touchersByNode[id] = touchersByNode[id] || 1;
    }
    function setCount(id, n) {
      if (typeof id !== 'string' || !id) return;
      activeIds[id] = true;
      if (n > (touchersByNode[id] || 0)) touchersByNode[id] = n;
    }
    function addAgent(id, key) {            // identity-bearing touch (activity form)
      if (typeof id !== 'string' || !id) return;
      activeIds[id] = true;
      if (!agentsByNode[id]) agentsByNode[id] = Object.create(null);
      agentsByNode[id][key] = true;
      var n = Object.keys(agentsByNode[id]).length;
      if (n > (touchersByNode[id] || 0)) touchersByNode[id] = n;
    }
    function ingestAgent(agent, key) {
      if (!agent || typeof agent !== 'object' || Array.isArray(agent)) return;
      asStrArray(agent.touching).forEach(function (id) { addAgent(id, key); });
    }
    function ingestActivity(act) {           // the {writer, auxiliary} sub-object
      if (!act || typeof act !== 'object' || Array.isArray(act)) return;
      if (act.writer) ingestAgent(act.writer, 'writer');
      if (Array.isArray(act.auxiliary)) {
        act.auxiliary.forEach(function (a, i) { ingestAgent(a, 'aux#' + i); });
      }
    }
    function ingestList(list) {
      list.forEach(function (entry) {
        if (typeof entry === 'string') { markActive(entry); return; }
        if (!entry || typeof entry !== 'object' || Array.isArray(entry)) return;
        var id = (typeof entry.id === 'string' && entry.id) ? entry.id
          : (typeof entry.domain === 'string' && entry.domain) ? entry.domain
          : (typeof entry.node_id === 'string' && entry.node_id) ? entry.node_id : null;
        if (!id) return;
        var n = entry.agents;
        if (typeof n !== 'number') n = entry.count;
        if (typeof n !== 'number') n = entry.touchers;
        n = (typeof n === 'number' && isFinite(n) && n >= 1) ? Math.floor(n) : 1;
        setCount(id, n);
      });
    }
    var o = (opts && typeof opts === 'object') ? opts : {};
    var ad = o.active_domains;
    if (Array.isArray(ad)) ingestList(ad);
    else ingestActivity(ad);                 // active_domains given AS the activity object
    ingestActivity(o.activity);              // explicit alias, folded in
    return { activeIds: activeIds, touchersByNode: touchersByNode, agentsByNode: agentsByNode };
  }

  /* ── parseNodes — derived.nodes → a tolerant id→node index (§3.1) ──────────────
   * Skips a null / id-less / malformed node with a degraded note (never throws,
   * never fabricates). An out-of-set kind is KEPT but flagged (B.4). The node's
   * source_refs are carried (the §5.3 conflict-detection basis + the honest "no
   * longer maps to code" note). Returns { byId, order } so iteration stays the
   * producer's deterministic order. */
  function parseNodes(rawNodes, degraded) {
    // Object.create(null) — id-keyed maps must have NO prototype: a hostile
    // node id / customization key like "__proto__" or "constructor" is truthy on
    // a plain {} (it inherits Object.prototype) and would corrupt lookups and
    // ultimately raise a TypeError (a B.4 degrade-never-refuse violation). A
    // null-proto map makes every id an honest own-key miss.
    var byId = Object.create(null), order = [];
    (Array.isArray(rawNodes) ? rawNodes : []).forEach(function (n, idx) {
      if (!n || typeof n !== 'object' || Array.isArray(n)) {
        degraded.push('node #' + idx + ' malformed — skipped'); return;
      }
      var id = (typeof n.id === 'string' && NODE_ID_RE.test(n.id)) ? n.id : null;
      if (!id) {
        degraded.push('a node had no valid id (kind:slug shape) — not rendered'); return;
      }
      if (byId[id]) { degraded.push('duplicate node id ' + id + ' — first kept'); return; }
      var kind = (typeof n.kind === 'string' && NODE_KIND[n.kind]) ? n.kind : null;
      if (!kind) {
        degraded.push('node ' + id + ' has out-of-set kind ' +
          JSON.stringify(n.kind) + ' — kept, treated as a plain box');
      }
      var label = (typeof n.label === 'string' && n.label) ? n.label : id;
      byId[id] = {
        id: id,
        label: label,                 // default display name (customization.renames overrides)
        derived_label: label,         // the machine's name, kept so a rename is visibly a rename
        kind: kind || 'capability',   // unknown kind ⇒ treat as a drill-in box, but flagged above
        kind_known: !!kind,
        derived_parent: (typeof n.parent === 'string' && n.parent) ? n.parent : null,
        parent: (typeof n.parent === 'string' && n.parent) ? n.parent : null,
        source_refs: asStrArray(n.source_refs),
        auto_opened: n.auto_opened === true, // Diagrammer autoOpened hint; customization wins (§5)
        // filled below:
        children: [], depth: 0, visible: false, open: false, open_source: null,
        pinned: false, focused: false, dimmed: false, renamed: false, regrouped: false
      };
      order.push(id);
    });
    return { byId: byId, order: order };
  }

  /* ── applyCustomization — the §5.2 view transform, keyed by STABLE id (§4) ─────
   * Mutates the node index IN THE VIEW ONLY (derived on disk is never touched).
   * rename → label; regroup → reparent (only if the new parent exists); pin →
   * lock-open; hide → drop the node + its subtree. An override whose id is ABSENT
   * from derived does NOT reattach — a soft degraded[] note, never a thrown error, never
   * a silent rewrite (the conflicts[] keep+FYI append is the updater's job, §5.3;
   * any conflicts[] already present are carried through by the caller). splits /
   * merges are recognised but not yet applied by the renderer (honest note) —
   * the four first-class overrides (§6.3) are what the map experience rides on. */
  function applyCustomization(idx, customization, degraded) {
    var c = (customization && typeof customization === 'object') ? customization : {};
    var byId = idx.byId;

    // renames — node id → human label (§5.1). Applied on the FULL node set, BEFORE
    // the hide cascade, so a rename of a node that is also hidden is simply moot
    // (the node is dropped below) rather than a false "no longer maps to code" note.
    var renames = (c.renames && typeof c.renames === 'object') ? c.renames : {};
    Object.keys(renames).forEach(function (id) {
      var label = renames[id];
      if (typeof label !== 'string' || !label) return;
      if (byId[id]) { byId[id].label = label; byId[id].renamed = true; }
      else degraded.push('customization.renames "' + label + '" for ' + id +
        ' no longer maps to code — not reattached (keep / drop is the updater FYI)');
    });

    // regroups — node id → new parent domain id (§5.1). Only reparent onto a
    // parent that still exists (and is not itself the node) — else a soft note.
    // CRUCIAL ORDER (code-review on H2): regroups run BEFORE the hide cascade so a
    // child regrouped OUT of a to-be-hidden domain is rescued — it is reparented
    // away first, so the cascade no longer reaches it. The reverse order (hide
    // first) destroyed a node the human deliberately kept, over-counted
    // counts.hidden, AND emitted a false "no longer maps to code" note — a
    // principle-9 honesty break. (A regroup INTO a hidden domain is still hidden by
    // the post-regroup cascade — the consistent semantics.)
    var regroups = (c.regroups && typeof c.regroups === 'object') ? c.regroups : {};
    Object.keys(regroups).forEach(function (id) {
      var newParent = regroups[id];
      if (typeof newParent !== 'string' || !newParent) return;
      if (!byId[id]) {
        degraded.push('customization.regroups for ' + id +
          ' no longer maps to code — not reattached'); return;
      }
      if (newParent !== id && byId[newParent]) {
        byId[id].parent = newParent; byId[id].regrouped = true;
      } else {
        degraded.push('customization.regroups target ' + newParent + ' for ' + id +
          ' is not a current node — left in place');
      }
    });

    // hidden LAST of the structural transforms (AFTER regroups — see the order note
    // above). A node suppressed as noise (§5.1); hiding a box hides its whole
    // POST-REGROUP subtree (you hid the domain, not just its shell).
    var hidden = Object.create(null); // null-proto: a "__proto__" id is an honest miss
    asStrArray(c.hidden).forEach(function (id) {
      if (byId[id]) hidden[id] = true;
      else degraded.push('customization.hidden references ' + id +
        ' which no longer maps to code — ignored (kept as a customization)');
    });
    if (Object.keys(hidden).length) {
      var changed = true, guard = 0;
      while (changed && guard < 999) {
        changed = false; guard++;
        idx.order.forEach(function (id) {
          var p = byId[id].parent;
          if (!hidden[id] && p && hidden[p]) { hidden[id] = true; changed = true; }
        });
      }
      idx.order = idx.order.filter(function (id) {
        if (hidden[id]) { delete byId[id]; return false; }
        return true;
      });
    }

    // pins — node ids whose open-state is locked (we interpret a pin as "keep it
    // drilled open"; §5.1 "layout/open-state is locked"). Marked here; the open
    // set in deriveBlueprintView honours it.
    var pins = Object.create(null);
    asStrArray(c.pins).forEach(function (id) {
      if (byId[id]) { byId[id].pinned = true; pins[id] = true; }
      else degraded.push('customization.pins references ' + id +
        ' which no longer maps to code — ignored');
    });

    // splits / merges — recognised, not yet applied by the renderer (§5.4 lists
    // all six; the map rides on the four above). Honest about the gap.
    if (Array.isArray(c.splits) && c.splits.length) {
      degraded.push('customization.splits present (' + c.splits.length +
        ') — not yet applied by the renderer (kept on the record)');
    }
    if (Array.isArray(c.merges) && c.merges.length) {
      degraded.push('customization.merges present (' + c.merges.length +
        ') — not yet applied by the renderer (kept on the record)');
    }

    // hidden_count = nodes the hide-cascade actually removed (NOT inferred from
    // orig-minus-kept, which would conflate malformed-node drops with hides).
    return { pins: pins, hidden_count: Object.keys(hidden).length };
  }

  /* ── linkTree — wire parent/children/depth after customization settled ─────────
   * A node whose parent is missing/unknown is promoted to TOP LEVEL (parent=null)
   * + a degraded note (B.4 — never orphaned off the canvas). A parent cycle is
   * broken defensively. */
  function linkTree(idx, degraded) {
    var byId = idx.byId;
    // (1) a parent that is not a current node ⇒ promote to top level + note.
    idx.order.forEach(function (id) {
      var n = byId[id];
      if (n.parent && !byId[n.parent]) {
        degraded.push('node ' + id + ' parent ' + n.parent +
          ' is not a current node — promoted to top level');
        n.parent = null;
      }
    });
    // (2) a node whose ancestor chain never reaches a root (a self-parent or a
    // parent cycle) would otherwise be invisible forever with no note — a B.4
    // gap. Promote any such node to top level + note (degrade, never vanish).
    idx.order.forEach(function (id) {
      var cur = byId[id].parent, seen = Object.create(null), guard = 0, looped = false;
      seen[id] = 1;
      while (cur && byId[cur] && guard < 9999) {
        if (seen[cur]) { looped = true; break; }
        seen[cur] = 1; cur = byId[cur].parent; guard++;
      }
      if (looped || guard >= 9999) {
        degraded.push('node ' + id + ' is in a parent cycle — promoted to top level');
        byId[id].parent = null;
      }
    });
    idx.order.forEach(function (id) {
      var n = byId[id];
      if (n.parent && byId[n.parent]) byId[n.parent].children.push(id);
    });
    // depth via the parent chain (cycle-guarded).
    idx.order.forEach(function (id) {
      var d = 0, cur = byId[id].parent, seen = {}, guard = 0;
      while (cur && byId[cur] && !seen[cur] && guard < 999) {
        seen[cur] = 1; d++; cur = byId[cur].parent; guard++;
      }
      byId[id].depth = d;
    });
  }

  /* ── openSet — which nodes are drilled OPEN, and WHY (autoOpened-vs-manual) ─────
   * open_source priority pin > manual > focus, because drill-OUT collapses what
   * FOCUS opened but must preserve a manual drill or a pin (§3.4.4). focus opens
   * the focused node itself (zoom INTO it) + all its ancestors (so it is visible).
   */
  function buildOpenSet(idx, manualOpened, pins, focusId, degraded) {
    // NOTE: node.auto_opened (the Diagrammer hint, §3.1) is intentionally NOT
    // seeded into the open set here — the pure model's open state is driven only
    // by explicit opts (focus/opened) + pins, so a render is a deterministic
    // function of its inputs. H3's interactive shell may seed opts.opened from
    // auto_opened on first paint; the hint is parsed + emitted on each node for
    // exactly that. Do not "fix" this to auto-open here without H3.
    var byId = idx.byId, source = Object.create(null);
    // focus: open the focused node + its ancestor chain.
    if (focusId) {
      if (byId[focusId]) {
        source[focusId] = 'focus';
        var cur = byId[focusId].parent, guard = 0;
        while (cur && byId[cur] && guard < 999) { source[cur] = 'focus'; cur = byId[cur].parent; guard++; }
      } else {
        degraded.push('focus target ' + focusId + ' is not a current node — focus ignored');
      }
    }
    // manual drill-ins (override a focus-open with the stickier 'manual').
    asStrArray(manualOpened).forEach(function (id) {
      if (byId[id]) source[id] = 'manual';
      else degraded.push('opened ' + id + ' is not a current node — ignored');
    });
    // pins win outright (locked open).
    Object.keys(pins || {}).forEach(function (id) { if (byId[id]) source[id] = 'pin'; });
    return source;
  }

  /* visibility memo: a node shows iff it is top-level OR its parent is OPEN and
   * itself visible. Edge/api resolution and dimming all read this. */
  function makeVisibility(idx, openSource) {
    var byId = idx.byId, memo = Object.create(null);
    function isVisible(id) {
      if (id == null || !byId[id]) return false;
      if (memo[id] !== undefined) return memo[id];
      memo[id] = false; // cycle guard
      var p = byId[id].parent;
      var v = (p == null) ? true : (!!openSource[p] && isVisible(p));
      memo[id] = v; return v;
    }
    return isVisible;
  }

  /* deepestVisibleAncestor(id) → the deepest node on id's ancestor chain (id
   * included) that is currently VISIBLE — the §3.2 resolution target. Always
   * terminates: a top-level ancestor is always visible. null if id is unknown. */
  function makeResolver(idx, isVisible) {
    var byId = idx.byId;
    return function dva(id) {
      var cur = id, guard = 0;
      while (cur && byId[cur] && !isVisible(cur) && guard < 999) { cur = byId[cur].parent; guard++; }
      return (cur && byId[cur] && isVisible(cur)) ? cur : null;
    };
  }

  /* subtree(id) → {id and all descendants} as a set (for focus density + dim). */
  function subtreeSet(idx, id) {
    var byId = idx.byId, set = Object.create(null), stack = [id], guard = 0;
    while (stack.length && guard < 99999) {
      guard++;
      var cur = stack.pop();
      if (!byId[cur] || set[cur]) continue;
      set[cur] = true;
      byId[cur].children.forEach(function (ch) { stack.push(ch); });
    }
    return set;
  }

  /* ── resolveEdges — ALGORITHM 2: deepest-visible resolution + bundle + density ─
   * Each derived edge resolves both true endpoints to their deepest visible
   * ancestor; an edge that collapses into ONE visible box (rFrom===rTo) is
   * INTERNAL and not drawn; survivors bundle by resolved (from,to,kind). Under
   * focus, only edges whose TRUE endpoints touch the focused subtree are kept
   * (the §3.2 "focused ⇒ touching-subtree-only" density rule). At macro (all
   * collapsed) every endpoint resolves to a top-level box ⇒ domain↔domain only,
   * which falls out of resolution for free. */
  function resolveEdges(rawEdges, idx, dva, focusSet, degraded) {
    var byId = idx.byId, bundles = Object.create(null), order = [];
    (Array.isArray(rawEdges) ? rawEdges : []).forEach(function (e, i) {
      if (!e || typeof e !== 'object' || Array.isArray(e)) {
        degraded.push('edge #' + i + ' malformed — skipped'); return;
      }
      var from = (typeof e.from === 'string') ? e.from : null;
      var to = (typeof e.to === 'string') ? e.to : null;
      if (!from || !to) { degraded.push('edge #' + i + ' missing from/to — skipped'); return; }
      if (!byId[from] || !byId[to]) {
        // an endpoint that isn't a current node (e.g. it was hidden, or never
        // existed) — drop it from the drawing, honestly noted. Not an exception.
        degraded.push('edge ' + from + '→' + to +
          ' has an endpoint that is not a visible node — dropped'); return;
      }
      var kind = (typeof e.kind === 'string' && EDGE_KIND[e.kind]) ? e.kind : null;
      if (!kind) {
        degraded.push('edge ' + from + '→' + to + ' has out-of-set kind ' +
          JSON.stringify(e.kind) + ' — drawn as a plain link');
        kind = 'call';
      }
      // focus density: keep only edges TOUCHING the focused subtree.
      if (focusSet && !(focusSet[from] || focusSet[to])) return;

      var rFrom = dva(from), rTo = dva(to);
      if (!rFrom || !rTo) {
        degraded.push('edge ' + from + '→' + to + ' could not resolve to a visible box — dropped');
        return;
      }
      if (rFrom === rTo) return; // internal to one visible box — not a cross edge (§3.2)

      var key = bundleKey(rFrom, rTo, kind);
      if (!bundles[key]) {
        bundles[key] = { from: rFrom, to: rTo, kind: kind, count: 0, members: [] };
        order.push(key);
      }
      bundles[key].count++;
      bundles[key].members.push((typeof e.bundle_key === 'string' && e.bundle_key)
        ? e.bundle_key : (from + '→' + to));
    });
    return order.map(function (k) { return bundles[k]; });
  }

  /* ── resolveApis — §3.3 boundary boxes ("the way in") ─────────────────────────
   * A route is a small box straddling its domain's border; visible iff the domain
   * node is visible. `calls` are the internal capabilities it invokes (the arrows
   * shown when the domain is open). Dropped (noted) if its domain is gone. */
  function resolveApis(rawApis, idx, isVisible, degraded) {
    var byId = idx.byId, out = [];
    (Array.isArray(rawApis) ? rawApis : []).forEach(function (a, i) {
      if (!a || typeof a !== 'object' || Array.isArray(a)) {
        degraded.push('api #' + i + ' malformed — skipped'); return;
      }
      var id = (typeof a.id === 'string' && a.id) ? a.id : null;
      var domain = (typeof a.domain === 'string' && a.domain) ? a.domain : null;
      var route = (typeof a.route === 'string' && a.route) ? a.route : null;
      if (!id || !domain) { degraded.push('api #' + i + ' missing id/domain — skipped'); return; }
      if (!byId[domain]) {
        degraded.push('api ' + id + ' straddles ' + domain +
          ' which is not a current node — dropped'); return;
      }
      out.push({
        id: id,
        domain: domain,
        route: route,
        route_label: route || '(route unrecorded)',
        calls: asStrArray(a.calls).filter(function (c) { return !!byId[c]; }),
        visible: isVisible(domain)
      });
    });
    return out;
  }

  /* ── layoutGrowToFit — ALGORITHM 1 ([free] geometry; §3.4.2/§3.5/§5) ───────────
   * A bottom-up nested pack: a collapsed box is a leaf; an OPEN box grows to fit
   * its visible children in a near-square grid + padding (siblings reflow). The
   * ROOTS are then placed by §5/§13 BANDING — grouped into lanes by band and laid
   * out LEFT→RIGHT as columns (client | domain | store | vendor | ext), the domain
   * lane a 2-col pack, lanes vertically centered — so the macro view is a 2-D map
   * (distinct x AND y), not a 1-D strip whose
   * center-to-center edges collapse to hidden slivers (claude-tools-bplayout). The
   * coordinates are NOT a contract — the test asserts the 2-D spread + edge
   * legibility, never the numbers. Returns size{w,h} per node and absolute x/y. */
  function layoutGrowToFit(idx, isVisible, openSource, scale) {
    var byId = idx.byId, size = Object.create(null);
    var k = (scale === 'thumb') ? 0.25 : 1;
    function add(a, b) { return a + b; }
    function sizeOf(id) {
      var n = byId[id];
      var kids = n.children.filter(isVisible);
      var isTop = (n.parent == null);
      if (!openSource[id] || kids.length === 0) {
        // CLOSED: a top-level box is a big readable card; a capability is a leaf.
        size[id] = isTop ? { w: CARD_W * k, h: CARD_H * k } : { w: LEAF_W * k, h: LEAF_H * k };
        return size[id];
      }
      // OPEN container: pack visible children in a near-square grid, grow to fit.
      var cols = Math.ceil(Math.sqrt(kids.length));
      var childSizes = kids.map(sizeOf);
      var colW = [], rowH = [];
      kids.forEach(function (ch, i) {
        var col = i % cols, row = Math.floor(i / cols);
        colW[col] = Math.max(colW[col] || 0, childSizes[i].w);
        rowH[row] = Math.max(rowH[row] || 0, childSizes[i].h);
      });
      var innerW = colW.reduce(add, 0) + GAP * k * (colW.length - 1);
      var innerH = rowH.reduce(add, 0) + GAP * k * (rowH.length - 1);
      size[id] = {
        w: Math.max(CARD_W * k, innerW + PAD * k * 2),
        h: innerH + PAD * k * 2 + HEADER * k,
        cols: cols, colW: colW, rowH: rowH, kids: kids
      };
      return size[id];
    }
    // size every visible top-level box, then BAND them into a 2-D layout (§5/§13).
    var roots = idx.order.filter(function (id) { return byId[id].parent == null && isVisible(id); });
    roots.forEach(sizeOf);
    var place = Object.create(null);
    function placeNode(id, x, y) {
      var s = size[id];
      place[id] = { x: x, y: y, w: s.w, h: s.h };
      if (!s.kids) return;
      var startX = x + PAD * k, startY = y + PAD * k + HEADER * k;
      s.kids.forEach(function (ch, i) {
        var col = i % s.cols, row = Math.floor(i / s.cols);
        var cx = startX;
        for (var c = 0; c < col; c++) cx += s.colW[c] + GAP * k;
        var cy = startY;
        for (var r = 0; r < row; r++) cy += s.rowH[r] + GAP * k;
        placeNode(ch, cx, cy);
      });
    }

    // ── §5/§13 BANDING — LEFT→RIGHT lanes (client | domain | store | vendor | ext) ─
    // Group the roots into lanes by band (bandOf(kind)); lay the lanes left→right in
    // BAND_ORDER, each a vertical stack EXCEPT the domain lane, which packs into 2
    // columns (the product domains are the bulk, and a 2-col grid reads better than a
    // tall single file). The domain lane's column gap reserves API_PAD so each
    // right-column domain's §7 api straddle box (which overhangs LEFT by ~half its
    // width — app.js bpApiRects) clears the left column. The first band starts at
    // MARGIN (> the api half-overhang) so a LEFTMOST domain's straddle still lands at
    // a non-negative world x. Each lane is vertically CENTERED against the tallest
    // lane. OPEN-container grow-to-fit (sizeOf/placeNode) is reused verbatim; only the
    // root walk changed (top→bottom rows → left→right bands). Numbers are [free]
    // (§3.5); the binding contract is the 2-D spread (distinct x AND y among
    // top-level boxes) + legible edges.
    var apiPad = API_PAD * k, bandGap = BAND_GAP * k;
    var groups = Object.create(null);
    roots.forEach(function (id) {
      var b = bandOf(byId[id].kind);
      (groups[b] || (groups[b] = [])).push(id);
    });
    // Measure each band first (so a short lane can be centered against the tallest).
    var laid = [];
    BAND_ORDER.forEach(function (band) {
      var ids = groups[band];
      if (!ids || !ids.length) return;
      var cols = (band === 'domain') ? Math.min(2, ids.length) : 1;
      var colW = [], rowH = [];
      ids.forEach(function (id, i) {
        var s = size[id];
        var col = i % cols, row = Math.floor(i / cols);
        colW[col] = Math.max(colW[col] || 0, s.w);
        rowH[row] = Math.max(rowH[row] || 0, s.h);
      });
      var colGap = (band === 'domain') ? (GAP * k + apiPad) : GAP * k;
      var bandW = colW.reduce(add, 0) + colGap * (cols - 1);
      var bandH = rowH.reduce(add, 0) + GAP * k * (rowH.length - 1);
      laid.push({ band: band, ids: ids, cols: cols, colW: colW, rowH: rowH, colGap: colGap, w: bandW, h: bandH });
    });
    var maxH = laid.reduce(function (m, b) { return Math.max(m, b.h); }, 0);
    var cursorX = MARGIN * k;   // ≥ the §7 api half-overhang for the leftmost lane
    laid.forEach(function (b) {
      var top = (maxH - b.h) / 2;            // vertically center this lane
      b.ids.forEach(function (id, i) {
        var col = i % b.cols, row = Math.floor(i / b.cols);
        var x = cursorX;
        for (var c = 0; c < col; c++) x += b.colW[c] + b.colGap;
        var y = top;
        for (var r = 0; r < row; r++) y += b.rowH[r] + GAP * k;
        placeNode(id, x, y);
      });
      cursorX += b.w + bandGap;
    });
    return place;
  }

  /* ── deriveBlueprintView(record, nowMs, opts) → the whole map view model ───────
   * record = the blueprint-get body (B.2); null ⇒ the honest "no Blueprint yet"
   * empty state (found:false, ok:true — never a refusal). opts = {focus, opened[],
   * scale, active_domains, activity}. active_domains / activity drive the §6.4/§8.2
   * IN-FLIGHT OVERLAY (light up worked domains + the two-agents-one-domain
   * collision signal) — see normalizeOverlay; absent ⇒ the overlay is simply dark.
   * An unknown-HIGHER (or missing/non-integer) schema_version is the ONE hard
   * refusal (§0.3). */
  function deriveBlueprintView(record, nowMs, opts) {
    opts = (opts && typeof opts === 'object') ? opts : {};
    var now = (typeof nowMs === 'number' && isFinite(nowMs)) ? nowMs : NaN;

    // null / missing record ⇒ the honest empty state (B.4 — the facet renders
    // "no Blueprint yet, request one"; NOT a refusal).
    if (record == null) {
      return {
        ok: true, found: false, empty: true,
        schema_version: null, project_ref: null,
        updated_at: null, updated_at_age: null,
        nodes: [], edges: [], apis: [], conflicts: [],
        focus: null,
        narrative: { present: false, tldr: null, sections: [], acronyms_expanded: [] },
        overlay: { active_ids: [], lit: [], collisions: [], touchers_by_node: {}, unmapped: [] },
        counts: { nodes: 0, top_level: 0, edges: 0, apis: 0, hidden: 0, conflicts: 0, active: 0, collisions: 0 },
        degraded: ['no Blueprint yet for this workspace — request one']
      };
    }
    var rec = (typeof record === 'object' && !Array.isArray(record)) ? record : {};

    // §0.3 schema gate (4xe): refuse an unknown-higher / missing / non-integer sv.
    var sv = rec.schema_version;
    if (typeof sv !== 'number' || Math.floor(sv) !== sv) {
      return { ok: false, error:
        'blueprint record missing an integer schema_version — refusing to render (§0.3)' };
    }
    if (sv > SUPPORTED_BLUEPRINT_SCHEMA) {
      return { ok: false, error:
        'unsupported blueprint schema_version ' + sv + ' (this renderer binds v' +
        SUPPORTED_BLUEPRINT_SCHEMA + ') — refusing to best-effort-render (§0.3)' };
    }

    var degraded = [];
    var projectRef = (typeof rec.project_ref === 'string' && rec.project_ref) ? rec.project_ref : null;
    var derived = (rec.derived && typeof rec.derived === 'object' && !Array.isArray(rec.derived))
      ? rec.derived : null;
    if (rec.derived != null && !derived) degraded.push('derived block malformed — shown empty');

    var rawNodes = derived ? derived.nodes : null;
    if (derived && rawNodes != null && !Array.isArray(rawNodes)) {
      degraded.push('derived.nodes malformed — shown empty'); rawNodes = null;
    }
    var idx = parseNodes(rawNodes, degraded);

    // §5.2 view transform (customization OVER derived, keyed by stable id §4).
    var cust = applyCustomization(idx, rec.customization, degraded);
    linkTree(idx, degraded);

    // drill / focus state.
    var focusId = (typeof opts.focus === 'string' && opts.focus) ? opts.focus : null;
    var openSource = buildOpenSet(idx, opts.opened, cust.pins, focusId, degraded);
    var isVisible = makeVisibility(idx, openSource);
    var dva = makeResolver(idx, isVisible);

    // focus density set = the focused subtree (true endpoints touching it show).
    var focusSet = null;
    if (focusId && idx.byId[focusId]) focusSet = subtreeSet(idx, focusId);

    var edges = resolveEdges(derived ? derived.edges : null, idx, dva, focusSet, degraded);
    var apis = resolveApis(derived ? derived.apis : null, idx, isVisible, degraded);
    var place = layoutGrowToFit(idx, isVisible, openSource, opts.scale);

    // dim: under focus, every VISIBLE node not in the focused subtree and not an
    // endpoint of a shown edge is dimmed (§3.4.4). connected = focusSubtree ∪
    // the focus-opened ANCESTOR chain of the target ∪ resolved endpoints of the
    // (already density-filtered) shown edges.
    var connected = Object.create(null);
    if (focusSet) {
      Object.keys(focusSet).forEach(function (id) { connected[id] = true; });
      edges.forEach(function (e) { connected[e.from] = true; connected[e.to] = true; });
      // The focus-opened ancestor chain of the target is part of "focus on it"
      // (§3.4.4 — focus opens it + its ancestors "so it is visible"), NOT the
      // unconnected background: a zoom-to-fit must never dim the container path it
      // just opened to reveal the target. subtreeSet walks DOWNWARD (target +
      // descendants), so the ancestors are absent from focusSet — mark them here,
      // cycle-guarded exactly like buildOpenSet's focus walk. Without this, every
      // non-top-level focus (the ?focus=<id> deep-link case, §8.4) greys out the
      // domain it just opened.
      var anc = idx.byId[focusId] ? idx.byId[focusId].parent : null, ancGuard = 0;
      while (anc && idx.byId[anc] && ancGuard < 999) {
        connected[anc] = true; anc = idx.byId[anc].parent; ancGuard++;
      }
    }

    // ── in-flight overlay (§6.4/§8.2): light up worked domains + collision flag ──
    // Each reported active node resolves to its deepest VISIBLE ancestor (the same
    // §3.2 edge-IP: at macro a worked capability lights its domain box; drilled in
    // it lights itself). A visible box is a COLLISION when ≥2 DISTINCT agents'
    // touching resolve into it (two-agents-one-domain) OR a single node it rolls up
    // is itself touched by ≥2 agents — honest only where agent IDENTITY (or an
    // explicit count) is present, so one writer touching two domains never trips it.
    // An active id absent from the (post-customization) map is honestly UNMAPPED —
    // never lit, never fabricated (B.4).
    var overlayIn = normalizeOverlay(opts);
    var litBox = Object.create(null);         // visible box id → true (lit)
    var boxAgents = Object.create(null);      // visible box id → {agentKey: true}
    var boxMaxTouchers = Object.create(null); // visible box id → max per-node touchers rolled up
    var unmapped = [];
    Object.keys(overlayIn.activeIds).forEach(function (id) {
      if (!idx.byId[id]) { unmapped.push(id); return; }   // reported but not a current node
      var box = dva(id);                                  // deepest VISIBLE ancestor
      if (!box) { unmapped.push(id); return; }            // its whole chain is collapsed/hidden away
      litBox[box] = true;
      var ag = overlayIn.agentsByNode[id];
      if (ag) {
        if (!boxAgents[box]) boxAgents[box] = Object.create(null);
        Object.keys(ag).forEach(function (k) { boxAgents[box][k] = true; });
      }
      var t = overlayIn.touchersByNode[id] || 0;
      if (t > (boxMaxTouchers[box] || 0)) boxMaxTouchers[box] = t;
    });
    if (unmapped.length) {
      degraded.push('in-flight overlay: ' + unmapped.length +
        ' active domain id(s) not in the current map (stale or hidden) — not lit (' +
        unmapped.slice(0, 6).join(', ') + ')');
    }
    var collisionBox = Object.create(null);
    Object.keys(litBox).forEach(function (box) {
      var nAgents = boxAgents[box] ? Object.keys(boxAgents[box]).length : 0;
      if (nAgents >= 2 || (boxMaxTouchers[box] || 0) >= 2) collisionBox[box] = true;
    });

    // emit the node list in producer order, visible nodes carrying render state.
    var nodes = idx.order.map(function (id) {
      var n = idx.byId[id];
      var vis = isVisible(id);
      var src = openSource[id] || null;
      var focused = focusSet ? !!focusSet[id] : false;     // the focused SUBTREE (drives dim-exemption)
      var focusedSelf = focusId != null && id === focusId;  // ONLY the exact ?focus target (the ring/scroll anchor)
      var dimmed = (focusSet && vis) ? !connected[id] : false;
      var activeSelf = !!overlayIn.activeIds[id];        // this exact node is being worked
      var selfTouchers = overlayIn.touchersByNode[id] || (activeSelf ? 1 : 0);
      return {
        id: n.id,
        label: n.label,
        derived_label: n.derived_label,
        renamed: n.renamed,
        regrouped: n.regrouped,
        kind: n.kind,
        kind_known: n.kind_known,
        top_level: n.parent == null,
        is_top_kind: !!TOP_LEVEL_KIND[n.kind],
        parent: n.parent,
        children: n.children.slice(),
        depth: n.depth,
        source_refs: n.source_refs,
        visible: vis,
        open: !!src,
        open_source: src,                  // pin | manual | focus | null (drill-out collapses 'focus')
        pinned: n.pinned,
        auto_opened: n.auto_opened,
        focused: focused,            // in the focused subtree (the §3.4.4 dim-exemption set)
        focused_self: focusedSelf,   // IS the exact ?focus target (§8.4 — the ring/scroll anchor)
        dimmed: dimmed,
        // §6.4/§8.2 in-flight overlay. `active`/`collision` are the RENDER flags on
        // a visible box (active resolved to the deepest visible ancestor); `*_self`
        // is the raw truth about THIS exact node id (visibility-independent) so the
        // model is honest about direct-vs-rolled-up work.
        active: !!litBox[id],              // a worked node resolves up to this visible box
        active_self: activeSelf,           // this exact node id is in the active set
        collision: !!collisionBox[id],     // ≥2 distinct agents (or a ≥2-toucher node) here
        collision_self: selfTouchers >= 2, // this exact node is touched by ≥2 agents
        touchers: selfTouchers,            // distinct agents touching this exact node (1 if union-only)
        layout: place[id] || null          // [free] geometry; present only when visible
      };
    });

    var topLevel = nodes.filter(function (n) { return n.top_level; }).length;
    // counts.hidden = nodes the customization.hidden cascade actually removed
    // (from applyCustomization), NOT orig-minus-kept — that would conflate a
    // malformed-node drop with a deliberate hide and make the facet lie.
    var hiddenCount = cust.hidden_count || 0;

    var conflicts = Array.isArray(rec.conflicts)
      ? rec.conflicts.filter(function (c) { return c && typeof c === 'object'; })
      : [];

    // §8.3 narrative (TL;DR → headings → [the map, above] → drill-detail). Parsed
    // here in the pure model (acronym-expand-on-first-use is testable presentation
    // logic, not DOM); the facet paints it ABOVE the map.
    var narrative = parseNarrative(rec.narrative, degraded);

    // overlay summary (deterministic producer order): the active ids that exist in
    // the map, the visible boxes lit, the collision boxes, per-active-node touchers,
    // and the honest unmapped[] (reported-active ids the map doesn't know).
    var activeMapped = idx.order.filter(function (id) { return overlayIn.activeIds[id]; });
    var litList = idx.order.filter(function (id) { return litBox[id]; });
    var collisionList = idx.order.filter(function (id) { return collisionBox[id]; });
    var touchersByNodeOut = {};
    activeMapped.forEach(function (id) {
      // toucher count per active node — a MEASURED distinct-agent count from the
      // identity-bearing activity form, but only a FLOOR-of-1 from the flat union
      // (a union loses identity), so this is named "touchers", never "agents".
      touchersByNodeOut[id] = overlayIn.touchersByNode[id] || 1;
    });
    var overlay = {
      active_ids: activeMapped,     // reported active node ids present in the map (self)
      lit: litList,                 // visible boxes currently lit (active resolved up)
      collisions: collisionList,    // visible boxes flagged two-agents-one-domain
      touchers_by_node: touchersByNodeOut,
      unmapped: unmapped            // reported active ids absent from the map — honestly NOT lit
    };

    return {
      ok: true,
      found: true,
      empty: idx.order.length === 0,
      schema_version: sv,
      project_ref: projectRef,
      updated_by: (typeof rec.updated_by === 'string' && rec.updated_by) ? rec.updated_by : null,
      updated_at: (typeof rec.updated_at === 'string' && rec.updated_at) ? rec.updated_at : null,
      updated_at_age: relAge(rec.updated_at, now),
      focus: (focusId && idx.byId[focusId]) ? focusId : null,
      scale: opts.scale === 'thumb' ? 'thumb' : 'full',
      narrative: narrative,
      nodes: nodes,
      edges: edges,
      apis: apis,
      conflicts: conflicts,
      overlay: overlay,
      counts: {
        nodes: idx.order.length,
        top_level: topLevel,
        edges: edges.length,
        apis: apis.length,
        hidden: hiddenCount,
        conflicts: conflicts.length,
        active: litList.length,        // visible boxes lit by in-flight work
        collisions: collisionList.length
      },
      degraded: degraded
    };
  }

  /* ── deriveBlueprintThumb(record, nowMs, opts) → the MINI-MAP thumbnail model ──
   * The §8.5 `[free]` refinement (claude-tools-wmmc): render `derived` SMALL through
   * this SAME H2 renderer at thumbnail scale — NO server-side image pipeline (§8.5),
   * consistent with the client-side layout choice (§3.5). It does NOT re-implement
   * any map logic: it calls deriveBlueprintView with opts.scale forced to 'thumb'
   * (the overlay/customization/§0.3 refusal all stay the map's) and then REDUCES the
   * full model to the macro view a Workspace card needs — the TOP-LEVEL VISIBLE boxes
   * only (a thumbnail is the coarsest density, §3.2), lit where work is in flight.
   *   record = the blueprint-get body (B.2); null ⇒ found:false (honest "no map yet").
   *   opts.active_domains / opts.activity → the §6.4/§8.2 in-flight overlay so the
   *     right cells light up (the §8.1 blueprint_meta.active_domains union, or the
   *     identity-bearing activity sub-object — same shapes deriveBlueprintView folds).
   * Returns { ok, found, empty, scale, cells:[{id,label,kind,kind_known,active,
   *   collision}], counts:{top_level,nodes,hidden,active,collisions}, updated_at_age }.
   * The ONE hard refusal (unknown-HIGHER schema_version, §0.3) PROPAGATES verbatim as
   * { ok:false, error } — the thumbnail refuses exactly when the full map would. */
  function deriveBlueprintThumb(record, nowMs, opts) {
    opts = (opts && typeof opts === 'object') ? opts : {};
    var view = deriveBlueprintView(record, nowMs, {
      scale: 'thumb',
      active_domains: opts.active_domains,
      activity: opts.activity
      // No focus / no opened: a thumbnail is the MACRO view (top-level only) — the
      // drill-in state is the dedicated facet's, one nav tap away.
    });
    if (!view.ok) return { ok: false, error: view.error };
    var cells = view.nodes
      .filter(function (n) { return n.top_level && n.visible; })
      .map(function (n) {
        return {
          id: n.id,
          label: n.label,
          kind: n.kind,
          kind_known: n.kind_known,
          active: n.active,        // a worked node resolved up to this top-level box
          collision: n.collision   // ≥2 distinct agents under this box (§6.4)
        };
      });
    return {
      ok: true,
      found: !!view.found,                       // null record ⇒ found:false
      empty: view.empty || cells.length === 0,
      scale: 'thumb',
      cells: cells,
      counts: {
        top_level: view.counts.top_level,
        nodes: view.counts.nodes,
        hidden: view.counts.hidden,
        active: view.counts.active,
        collisions: view.counts.collisions
      },
      updated_at_age: view.updated_at_age || null
    };
  }

  return {
    deriveBlueprintView: deriveBlueprintView,
    deriveBlueprintThumb: deriveBlueprintThumb,
    makeNodeId: makeNodeId,
    relAge: relAge,
    bundleKey: bundleKey,
    SUPPORTED_BLUEPRINT_SCHEMA: SUPPORTED_BLUEPRINT_SCHEMA,
    NODE_KIND: NODE_KIND,
    EDGE_KIND: EDGE_KIND
  };
});
