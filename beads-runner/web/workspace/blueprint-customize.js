/* beads-runner/web/workspace/blueprint-customize.js — Blueprint CUSTOMIZATION
 * controller (H4, claude-tools-uxvh4; DESIGN H = design/blueprint.md §5 + §4,
 * UX-DESIGN-V2 §6.3/§14.2, Contract B.2/B.4).
 *
 * THE PURE, HEADLESS-TESTABLE WRITE-SIDE of the Blueprint customization layer —
 * the sibling of H2's read-side `blueprint-view.js`. No DOM, no network, no
 * timers. It turns a tap-gesture on the map (rename / regroup / pin / hide /
 * split / merge) into the NEXT `customization` sub-object the facet POSTs through
 * `/api/ws/blueprint-put` (section:"customization"), and it resolves the
 * `conflicts[]` FYI channel (keep / drop). `lib/test-blueprint-customize.sh`
 * drives THIS module against a hand-crafted blueprint-get record.
 *
 * ── THE THREE NEVER-CLOBBER GUARANTEES, AND WHICH ONE LIVES HERE ──────────────
 * design/blueprint.md §2.3 names three layers of "customization is never
 * clobbered": (1) FIELD SEPARATION (the schema — derived vs customization are
 * distinct keys); (2) SECTIONED READ-MERGE-WRITE in the engine's _serialize (a
 * racing derived-write and customization-write each merge over the other, H1);
 * (3) STABLE NODE IDENTITY (§4 — every override is keyed by node.id so the same
 * concept keeps the same id across regens, blueprint-view.js + the H5 hat).
 *
 * This module adds the SHAPE the GUI seam writes: every builder below is PURE and
 * returns a *brand-new* customization object — it never mutates the one passed in.
 * The facet always POSTs the WHOLE merged customization sub-object (small, bounded
 * by the map), and the sectioned engine op replaces ONLY that one layer. So a
 * concurrent `derived` regen by the updater hat physically cannot eat the edit
 * (§2.3, must-protect #3, principle 9) — and because the builder is pure, the
 * facet's in-memory copy is never half-mutated by a failed write either.
 *
 * ── CONFLICTS: keep + FYI, never silent revert (§5.3 / §14.2 assumed default) ──
 * The updater hat APPENDS a `conflicts[]` entry (keep+FYI) for each override whose
 * node_id is absent from a fresh `derived` and could not reattach (§4). It NEVER
 * deletes the human override. The facet resolves a conflict by RE-WRITING
 * customization (the GUI seam cannot write `conflicts[]` — that is the updater's
 * append-only honesty log; ws/blueprint-put.js refuses a GUI `conflicts-append`):
 *
 *   • DROP  — Brian decides the orphaned custom value can go. We remove the
 *             BACKING OVERRIDE for that (kind, node_id) from customization and
 *             re-write the layer. The conflict then stops being LIVE because its
 *             backing override is gone (deriveLiveConflicts, rule c).
 *   • KEEP  — Brian confirms the §14.2 default (the customization persists). We
 *             record a persisted acknowledgement in `customization.acked` so the
 *             actionable FYI stops nagging — but the override is KEPT, and the
 *             still-orphaned fact stays honest in the renderer's degraded[] note
 *             (blueprint-view.js applyCustomization). KEEP is the safe default:
 *             absent any tap, nothing is dropped (never a silent revert).
 *
 * `customization.acked` is an ADDITIVE H4 channel over the B.2 §5.1 six-kind
 * shape (renames/regroups/pins/hidden/splits/merges) — an array of stable
 * "<kind>:<node_id>" conflict keys. Additive + tolerant by construction: the H2
 * renderer ignores unknown customization keys; the engine's freshEmptyBlueprint
 * carries it; a record written before this field reads as "nothing acknowledged"
 * (every live conflict surfaced — honest). It is H4's, inside the §5.3 conflict
 * policy this module owns (A.4 — a within-flow field, documented, not silent).
 *
 * ── LIVE CONFLICTS are DERIVED, not the raw log (the load-bearing read) ────────
 * The updater APPENDS each regen and never prunes, so `conflicts[]` accumulates
 * duplicates and stale entries. deriveLiveConflicts() is the honest projection the
 * facet renders: dedup by (kind,node_id), and DROP an entry that is no longer
 * actionable because it was acknowledged (keep), its backing override was removed
 * (drop), or its node_id reappeared in `derived` (the §4 auto-reattach — the
 * concept came back, so the override is honest again with no churn). This is why
 * "keep / drop" can be terminal and why a burst of regens never multiplies the FYI.
 *
 * HONESTY (B.4): every input is tolerated. A garbled customization normalizes to
 * the empty six-kind shape; a malformed conflict entry is skipped; a hostile
 * "__proto__" id is an honest miss (null-proto maps). Nothing here throws.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.BlueprintCustomize = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // The §4 stable node-id shape (must match blueprint-view.js NODE_ID_RE — the
  // shared seam): kind:slug. A gesture/override key outside this shape is refused
  // so the GUI can never write a positional/garbage key the renderer can't anchor.
  var NODE_ID_RE = /^[a-z][a-z0-9-]*:[a-z0-9][a-z0-9-]*$/;

  // The §5.3 conflict kinds (closed set), each mapping to ONE override family.
  // kind → the customization key whose entry for node_id backs the conflict.
  var CONFLICT_FAMILY = {
    'rename-orphan': 'renames',
    'regroup-orphan': 'regroups',
    'pin-orphan': 'pins',
    'hide-orphan': 'hidden',
    'split-orphan': 'splits',
    'merge-orphan': 'merges'
  };

  function isPlainObject(v) {
    return v !== null && typeof v === 'object' && !Array.isArray(v);
  }
  function isNonEmptyStr(v) { return typeof v === 'string' && v.length > 0; }

  // asIdArray(x) → x filtered to valid stable node ids, deduped, order-preserved.
  function asIdArray(x) {
    var seen = Object.create(null), out = [];
    (Array.isArray(x) ? x : []).forEach(function (s) {
      if (isNonEmptyStr(s) && !seen[s]) { seen[s] = 1; out.push(s); }
    });
    return out;
  }
  // asStrArray(x) → x filtered to non-empty strings, deduped (for `acked` keys).
  function asStrArray(x) {
    var seen = Object.create(null), out = [];
    (Array.isArray(x) ? x : []).forEach(function (s) {
      if (isNonEmptyStr(s) && !seen[s]) { seen[s] = 1; out.push(s); }
    });
    return out;
  }
  // asMap(x) → a null-proto {id:label} map, tolerant of garbage / hostile keys.
  // renames/regroups are keyed by NODE ID (§5.1), so we keep ONLY keys that match
  // the §4 stable-id shape with a non-empty string value — a non-id key (including
  // a hostile "__proto__"/"constructor") could never reattach to a real node, so
  // it is an honest miss here AND on serialize (the null-proto + id-filter make the
  // "hostile id is an honest miss" guarantee total, never a silent prototype set).
  function asMap(x) {
    var out = Object.create(null);
    if (!isPlainObject(x)) return out;
    Object.keys(x).forEach(function (k) {
      if (NODE_ID_RE.test(k) && isNonEmptyStr(x[k])) out[k] = x[k];
    });
    return out;
  }
  // asEntryArray(x) → an array of plain-object entries (splits/merges), garbage
  // skipped. The renderer recognises but does not yet apply these (§5.4); we keep
  // the data model complete + honest so a later render of split/merge is a pure
  // renderer change, no migration.
  function asEntryArray(x) {
    return (Array.isArray(x) ? x : []).filter(isPlainObject);
  }
  // deepCopyEntries(arr) → a deep copy of [free]-shape entry objects (split/merge),
  // so a serialized customization shares no entry reference with its input. A
  // non-serialisable entry degrades to {} (B.4 — never throws).
  function deepCopyEntries(arr) {
    return (Array.isArray(arr) ? arr : []).map(function (e) {
      try { return JSON.parse(JSON.stringify(e)); } catch (_) { return {}; }
    });
  }

  /* normalizeCustomization(c) → the canonical six-kind shape + the H4 `acked`
   * channel, with null-proto maps. The SINGLE place the tolerant read of a
   * customization sub-object lives — every builder starts from this so a garbled
   * prior never corrupts the next write (B.4). Returns a FRESH object each call
   * (the builders below mutate THIS copy, never the caller's input). */
  function normalizeCustomization(c) {
    c = isPlainObject(c) ? c : {};
    return {
      renames: asMap(c.renames),
      regroups: asMap(c.regroups),
      pins: asIdArray(c.pins),
      hidden: asIdArray(c.hidden),
      splits: asEntryArray(c.splits),
      merges: asEntryArray(c.merges),
      acked: asStrArray(c.acked) // H4 additive conflict-ack channel (§5.3)
    };
  }

  /* serializeCustomization(c) → a plain-object, POST-ready copy (null-proto maps
   * become plain {} so JSON.stringify emits them as objects, not Object.create
   * weirdness). This is exactly the `body` the facet sends as the customization
   * section. An empty `acked` is omitted so an unedited record stays B.2-shaped. */
  function serializeCustomization(c) {
    var n = normalizeCustomization(c);
    var renames = {}; Object.keys(n.renames).forEach(function (k) { renames[k] = n.renames[k]; });
    var regroups = {}; Object.keys(n.regroups).forEach(function (k) { regroups[k] = n.regroups[k]; });
    var out = {
      renames: renames,
      regroups: regroups,
      pins: n.pins.slice(),
      hidden: n.hidden.slice(),
      // split/merge entries are [free]-shape data objects — DEEP-copy them so the
      // returned customization shares NO reference with the input (a total purity
      // guarantee, not just a fresh array). Entries are prompt-built plain data,
      // so a JSON round-trip is faithful; a non-serialisable entry degrades to {}.
      splits: deepCopyEntries(n.splits),
      merges: deepCopyEntries(n.merges)
    };
    if (n.acked.length) out.acked = n.acked.slice();
    return out;
  }

  // ── membership reads (the facet uses these to show the current toggle state) ──
  function isPinned(c, nodeId) { return normalizeCustomization(c).pins.indexOf(nodeId) >= 0; }
  function isHidden(c, nodeId) { return normalizeCustomization(c).hidden.indexOf(nodeId) >= 0; }
  // currentLabel(c, nodeId, derivedLabel) → the human-facing label after renames.
  function currentLabel(c, nodeId, derivedLabel) {
    var r = normalizeCustomization(c).renames;
    return isNonEmptyStr(r[nodeId]) ? r[nodeId] : (derivedLabel || nodeId);
  }

  // ── the six override builders — each PURE, returns a fresh customization ──────
  // CONTRACT: builders never mutate their input and always emit a serializable
  // (plain-object) customization — exactly the `body` the facet POSTs. An out-of-
  // shape node id is REFUSED (returns the input unchanged + ok:false) so the GUI
  // never writes a key the renderer can't anchor to a stable node (§4).
  function refuse(c, why) {
    return { ok: false, error: why, customization: serializeCustomization(c) };
  }
  function accept(n) { return { ok: true, customization: serializeCustomization(n) }; }

  /* rename(c, nodeId, label) — set renames[nodeId]=label; an EMPTY label clears
   * the rename (revert to the derived label). §5.1 "node id → human label". */
  function rename(c, nodeId, label) {
    if (!NODE_ID_RE.test(nodeId)) return refuse(c, 'rename: ' + nodeId + ' is not a stable node id (kind:slug)');
    var n = normalizeCustomization(c);
    if (isNonEmptyStr(label)) n.renames[nodeId] = label;
    else delete n.renames[nodeId];
    return accept(n);
  }

  /* regroup(c, nodeId, parentId) — set regroups[nodeId]=parentId; an EMPTY
   * parentId clears the regroup. §5.1 "node id → new parent domain id". The
   * renderer only reparents onto a parent that still exists (else a soft note);
   * we record Brian's intent faithfully and let the renderer resolve. */
  function regroup(c, nodeId, parentId) {
    if (!NODE_ID_RE.test(nodeId)) return refuse(c, 'regroup: ' + nodeId + ' is not a stable node id');
    var n = normalizeCustomization(c);
    if (isNonEmptyStr(parentId)) {
      if (!NODE_ID_RE.test(parentId)) return refuse(c, 'regroup: target ' + parentId + ' is not a stable node id');
      if (parentId === nodeId) return refuse(c, 'regroup: a node cannot be its own parent');
      n.regroups[nodeId] = parentId;
    } else {
      delete n.regroups[nodeId];
    }
    return accept(n);
  }

  /* setPinned(c, nodeId, pinned) — add/remove nodeId in pins[] (§5.1 "open-state
   * locked"). togglePin is the convenience the tap uses. */
  function setPinned(c, nodeId, pinned) {
    if (!NODE_ID_RE.test(nodeId)) return refuse(c, 'pin: ' + nodeId + ' is not a stable node id');
    var n = normalizeCustomization(c);
    var i = n.pins.indexOf(nodeId);
    if (pinned && i < 0) n.pins.push(nodeId);
    else if (!pinned && i >= 0) n.pins.splice(i, 1);
    return accept(n);
  }
  function togglePin(c, nodeId) { return setPinned(c, nodeId, !isPinned(c, nodeId)); }

  /* setHidden(c, nodeId, hidden) — add/remove nodeId in hidden[] (§5.1 "suppressed
   * as noise"). toggleHide is the convenience the tap uses. */
  function setHidden(c, nodeId, hidden) {
    if (!NODE_ID_RE.test(nodeId)) return refuse(c, 'hide: ' + nodeId + ' is not a stable node id');
    var n = normalizeCustomization(c);
    var i = n.hidden.indexOf(nodeId);
    if (hidden && i < 0) n.hidden.push(nodeId);
    else if (!hidden && i >= 0) n.hidden.splice(i, 1);
    return accept(n);
  }
  function toggleHide(c, nodeId) { return setHidden(c, nodeId, !isHidden(c, nodeId)); }

  /* addSplit / addMerge — record a split (one domain → two) / merge (two → one)
   * intent (§5.1). The renderer recognises but does not yet APPLY these (§5.4 —
   * the map rides on the four first-class overrides); we keep the data model
   * complete so the customization survives regen and a later render is a pure
   * renderer change. Each entry is a free-shape object (the gesture ergonomics are
   * [free], §11) — we only require it to name the node(s) it concerns so a
   * conflict/drop can find it. */
  function addSplit(c, entry) {
    if (!isPlainObject(entry)) return refuse(c, 'split: need an entry object');
    var n = normalizeCustomization(c);
    n.splits.push(entry);
    return accept(n);
  }
  function addMerge(c, entry) {
    if (!isPlainObject(entry)) return refuse(c, 'merge: need an entry object');
    var n = normalizeCustomization(c);
    n.merges.push(entry);
    return accept(n);
  }

  // ── conflict resolution (§5.3 keep / drop) ───────────────────────────────────

  /* conflictKey(conflict) → the stable "<kind>:<node_id>" key used for dedup and
   * the `acked` channel, or null for a malformed entry. */
  function conflictKey(conflict) {
    if (!isPlainObject(conflict)) return null;
    var kind = conflict.kind, nodeId = conflict.node_id;
    if (!isNonEmptyStr(kind) || !isNonEmptyStr(nodeId)) return null;
    return kind + ':' + nodeId;
  }

  // Does customization still carry the backing override for this (kind,node_id)?
  // The "is this conflict still actionable?" test rule (c). For split/merge an
  // entry "references" node_id if any of its string values equals it (the entry
  // shape is [free], so we match structurally, tolerantly).
  function entryReferences(entry, nodeId) {
    if (!isPlainObject(entry)) return false;
    var hit = false;
    Object.keys(entry).forEach(function (k) {
      var v = entry[k];
      if (v === nodeId) hit = true;
      else if (Array.isArray(v) && v.indexOf(nodeId) >= 0) hit = true;
    });
    return hit;
  }
  function hasBackingOverride(n, kind, nodeId) {
    var fam = CONFLICT_FAMILY[kind];
    if (!fam) return false; // unrecognised kind ⇒ no known backing override
    if (fam === 'renames' || fam === 'regroups') return isNonEmptyStr(n[fam][nodeId]);
    if (fam === 'pins' || fam === 'hidden') return n[fam].indexOf(nodeId) >= 0;
    if (fam === 'splits' || fam === 'merges') {
      return n[fam].some(function (e) { return entryReferences(e, nodeId); });
    }
    return false;
  }

  /* dropConflict(c, conflict) — Brian drops the orphaned custom value. Remove the
   * BACKING OVERRIDE for (kind, node_id) and clear any stale ack for it. Once the
   * override is gone the conflict is no longer LIVE (rule c). A NO-OP for an
   * unrecognised kind (nothing to remove) — the facet offers drop only for the
   * known kinds; we still strip a matching ack so the FYI clears. */
  function dropConflict(c, conflict) {
    var key = conflictKey(conflict);
    if (!key) return refuse(c, 'drop: malformed conflict (need kind + node_id)');
    var n = normalizeCustomization(c);
    var kind = conflict.kind, nodeId = conflict.node_id, fam = CONFLICT_FAMILY[kind];
    if (fam === 'renames' || fam === 'regroups') {
      delete n[fam][nodeId];
    } else if (fam === 'pins' || fam === 'hidden') {
      var i = n[fam].indexOf(nodeId);
      if (i >= 0) n[fam].splice(i, 1);
    } else if (fam === 'splits' || fam === 'merges') {
      n[fam] = n[fam].filter(function (e) { return !entryReferences(e, nodeId); });
    }
    // strip any "keep" ack for this conflict (the override is gone — start clean
    // if the same concept ever orphans again).
    var ai = n.acked.indexOf(key);
    if (ai >= 0) n.acked.splice(ai, 1);
    return accept(n);
  }

  /* keepConflict(c, conflict) — Brian confirms the §14.2 default: keep the custom
   * value. Persist the acknowledgement (so the actionable FYI stops nagging) WHILE
   * KEEPING the override. Never a revert. Idempotent. */
  function keepConflict(c, conflict) {
    var key = conflictKey(conflict);
    if (!key) return refuse(c, 'keep: malformed conflict (need kind + node_id)');
    var n = normalizeCustomization(c);
    if (n.acked.indexOf(key) < 0) n.acked.push(key);
    return accept(n);
  }

  /* deriveLiveConflicts(record) → the actionable conflict FYIs the facet renders.
   * record = the blueprint-get body (B.2); null/garbled ⇒ []. The honest
   * projection over the append-only `conflicts[]` log (§5.3):
   *   • dedup by (kind, node_id) — repeated regens append the same orphan;
   *   • DROP if acknowledged (keep), the §14.2 terminal default;
   *   • DROP if node_id reappeared in `derived` — the §4 auto-reattach (concept
   *     came back; the override is honest again, no FYI, no churn);
   *   • DROP if a recognised kind's backing override is gone (drop already applied).
   * Each survivor carries {key, kind, node_id, custom, note, resolvable} —
   * resolvable=true iff the kind is a recognised family (so the facet shows a
   * "drop" affordance; an out-of-set kind is keep/dismiss-only, B.4). */
  function deriveLiveConflicts(record) {
    if (!isPlainObject(record)) return [];
    var conflicts = Array.isArray(record.conflicts) ? record.conflicts : [];
    var n = normalizeCustomization(record.customization);

    // ids present in the current derived (the §4 reattach check).
    var derivedIds = Object.create(null);
    var derived = isPlainObject(record.derived) ? record.derived : null;
    var nodes = derived && Array.isArray(derived.nodes) ? derived.nodes : [];
    nodes.forEach(function (nd) {
      if (isPlainObject(nd) && isNonEmptyStr(nd.id)) derivedIds[nd.id] = true;
    });
    var acked = Object.create(null);
    n.acked.forEach(function (k) { acked[k] = true; });

    var seen = Object.create(null), out = [];
    conflicts.forEach(function (cf) {
      var key = conflictKey(cf);
      if (!key || seen[key]) return;       // malformed or duplicate
      seen[key] = true;
      if (acked[key]) return;              // kept/acknowledged (§14.2)
      var nodeId = cf.node_id, kind = cf.kind;
      if (derivedIds[nodeId]) return;      // reattached (§4 auto-resolve)
      var recognised = !!CONFLICT_FAMILY[kind];
      // a recognised kind whose backing override is gone was already DROPPED.
      if (recognised && !hasBackingOverride(n, kind, nodeId)) return;
      out.push({
        key: key,
        kind: kind,
        node_id: nodeId,
        custom: isNonEmptyStr(cf.custom) ? cf.custom : null,
        note: isNonEmptyStr(cf.note) ? cf.note : null,
        resolvable: recognised
      });
    });
    return out;
  }

  return {
    NODE_ID_RE: NODE_ID_RE,
    CONFLICT_FAMILY: CONFLICT_FAMILY,
    normalizeCustomization: normalizeCustomization,
    serializeCustomization: serializeCustomization,
    isPinned: isPinned,
    isHidden: isHidden,
    currentLabel: currentLabel,
    rename: rename,
    regroup: regroup,
    setPinned: setPinned,
    togglePin: togglePin,
    setHidden: setHidden,
    toggleHide: toggleHide,
    addSplit: addSplit,
    addMerge: addMerge,
    conflictKey: conflictKey,
    dropConflict: dropConflict,
    keepConflict: keepConflict,
    deriveLiveConflicts: deriveLiveConflicts
  };
});
