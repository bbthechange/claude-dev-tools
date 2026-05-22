/* beads-runner/web/inbox/inbox-view.js — T6b (claude-tools-xre).
 *
 * THE PURE, HEADLESS-TESTABLE CORE of the Inbox + Flow-G web app. It is the
 * ONLY place the §5 Dossier (`body`⊃`items[]`) and the §4.5 projection's
 * Flow-G failure metadata are turned into what the screen shows, and the ONLY
 * place a UI form-state is turned into the §5.2 `response` payload. No DOM, no
 * network, no timers — input is JSON, output is a deterministic view model.
 * lib/test-inbox.sh drives THIS module against the REAL T5 producer
 * (dossier-gen.sh `dg_generate`) and the REAL idempotent applier
 * (consequence.sh `do_item_apply`), so the producer↔renderer↔applier seam is
 * asserted against the frozen contract, not a hand-faked shape.
 *
 * BINDS — INTERFACE.md v1 (FROZEN), the sections T6b owns per §11:
 *   §5   — SOLE RENDERER of the Dossier. §5.1 `body` (tldr · sections[] ·
 *          diagrams[] · full_detail — ALL mandatory, AD7 progressive
 *          disclosure: skim → full). §5.2 per-Item affordance: "the Item's
 *          `kind` IS its response affordance — the doc IS the form" (Flow B
 *          step 4); the MANDATORY `context_anchor` is rendered INLINE
 *          (self-contained-context invariant — AD7). §5.2.1 profiles
 *          (decision / mixed review / all-`fyi-objectable` overview) are
 *          EMERGENT from body+item-mix — one render path, no profile branch.
 *          §5.2.2 deterministic-vs-reconciler is mirrored so the UI can
 *          HONESTLY preview "applied instantly" vs "reconciler reads this"
 *          (it never APPLIES — that is T5).
 *   §4.5 — reads ONLY the read-only projection: the WAITING-ON-YOU lane
 *          (Dossier pointers — counts only, never body) and Flow-G tiers 1–2
 *          per-bead failure metadata (class + retry-state + Runner: notes).
 *   §10.3 — the forensic tier-3 is an explicit, authed, ON-DEMAND fetch; it is
 *          NEVER in the projection and is NEVER auto-fetched here. This module
 *          models only the AFFORDANCE + a blob the app supplies post-fetch.
 *   §0.3  — an unknown HIGHER `schema_version`/`dossier_schema_version` ⇒
 *          REJECT (never best-effort-parse), exactly as every §4/§5 consumer.
 *          This is the renderer's ONE refusal (claude-tools-4xe).
 *
 * CONTRACT — TOLERANT RENDERING (claude-tools-4xe; supersedes the prior
 * "refuse a malformed Dossier" anti-drift line, which was the bug). The
 * §5.1-core conformance gate now lives at the engine's ONE dossier WRITE path
 * (cf/src/coordinator.js _writeRecord + lib/coordinator.sh co__store_put):
 * a non-conformant dossier is REJECTED before storage — the agent gets a
 * hard, loud failure, never a false-success put. Therefore this renderer's
 * invariant is the COMPLEMENT: a dossier the engine ACCEPTED (incl. legacy
 * pre-gate records) is ALWAYS readable AND answerable. It NEVER blank-refuses
 * an accepted dossier; the ONLY refusal is §0.3 unknown-HIGHER (a vN renderer
 * cannot honor a v(N+1) artifact), shown as a plain human message — no
 * §/contract/§11 jargon on the phone. Every other gap degrades to a clearly-
 * LABELED best-effort fallback (`.degraded[]`), never a silent fabrication
 * and never a wall. This is NOT a §11 change: INTERFACE §5.1 mandates the
 * GENERATOR reject + the renderer render Mermaid as SVG; it never mandated a
 * render-time REFUSAL of a non-conformant dossier. It owns NO control logic:
 * consequence application + the per-Item idempotency latch + the S-2
 * control→work reconcile are T5's; this module maps a form to the §5.2
 * `response` and derives the ack from the CONTROL-PLANE record the
 * Coordinator reconciles into beads (so the ack carries no Dolt-lag lie — S-2).
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.InboxView = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // Contract-bound schema versions this renderer understands (§0.3).
  // v2 (§11 Mermaid amendment): the Dossier artifact tracks ONE registry
  // source — §4.1 envelope + §5.1 body bumped 1→2 in lockstep. work-snapshot
  // (§4.5) is a SEPARATE record type and did NOT bump — still 1.
  var SUPPORTED_SNAPSHOT_SCHEMA = 1; // §4.5 work-snapshot (unchanged)
  var SUPPORTED_DOSSIER_SCHEMA = 2;  // §4.1 Dossier envelope (v2)
  var SUPPORTED_BODY_SCHEMA = 2;     // §5.1 body (dossier_schema_version, v2)

  // §5.1 v2: diagrams[].content MUST be Mermaid source (prose/ASCII is a
  // contract violation — the §5.2 contextless-anchor discipline). This is a
  // byte-for-byte port of dossier-gen.sh dg__is_mermaid AND cf/src/dossier.js
  // looksLikeMermaid (the §8bm differential-equivalence requirement): split
  // on \n only (strip a trailing \r), whitespace is ASCII space+tab ONLY
  // (never \s / [[:space:]] — those diverge on Unicode/locale), and the
  // keyword must be a FULL token followed by an ASCII sp/tab/colon OR
  // end-of-line (no open wildcard ⇒ no `.` vs `.*` divergence on
  // U+2028/U+2029). The authoritative parse is the SVG render (app.js).
  var MERMAID_KW = '(graph|flowchart|sequenceDiagram|classDiagram|stateDiagram(-v2)?|erDiagram|journey|gantt|pie|mindmap|timeline|gitGraph|quadrantChart|requirementDiagram|C4Context|C4Container|C4Component|C4Dynamic|C4Deployment|sankey-beta|xychart-beta|block-beta|zenuml|architecture-beta|packet-beta)';
  var MM_BLANK = /^[ \t]*$/, MM_FM = /^[ \t]*---[ \t]*$/, MM_CMT = /^[ \t]*%%/;
  var MM_HEAD = new RegExp('^[ \\t]*' + MERMAID_KW + '([ \\t:]|$)');
  function looksLikeMermaid(s) {
    if (typeof s !== 'string' || s === '') return false;
    var lines = s.split('\n'), inFm = false, seenFm = false;
    for (var i = 0; i < lines.length; i++) {
      var ln = lines[i].replace(/\r$/, '');
      if (MM_BLANK.test(ln)) continue;
      if (!seenFm && !inFm && MM_FM.test(ln)) { inFm = true; seenFm = true; continue; }
      if (inFm) { if (MM_FM.test(ln)) inFm = false; continue; }
      if (MM_CMT.test(ln)) continue; // %% comment / %%{init}%% directive
      return MM_HEAD.test(ln);
    }
    return false;
  }

  // §5.2 the CLOSED Item-kind enum. "The Item's kind IS its response
  // affordance" — T6b renders the control FROM this, never invents one.
  var ITEM_KINDS = {
    'approve-reject': 1, 'pick-option': 1, 'approve-recommendation': 1,
    'freeform-edit': 1, 'fyi-objectable': 1
  };

  // §5.2.2 deterministic-vs-reconciler — the EXACT mirror of consequence.sh
  // `do__is_deterministic` (T5, the AUTHORITY). The renderer only PREVIEWS
  // this; it must never diverge from the producer (a false-instant promise is
  // the principle 4/5 violation this module's header forbids). Deterministic
  // IFF: kind ∈ this closed set AND no `edited_value` AND
  // decision ∈ {approve,reject,pick}. NOTE `fyi-objectable` is in the kind
  // set BUT an explicit `object` decision is NOT in {approve,reject,pick} ⇒
  // an objection is the RECONCILER path (consequence.sh:287 + the documented
  // object→reconciler routing); only an un-objected timer auto-proceed is the
  // deterministic fyi path, which is T5.4's, never a human submit here.
  var DETERMINISTIC_KINDS = {
    'approve-reject': 1, 'pick-option': 1,
    'approve-recommendation': 1, 'fyi-objectable': 1
  };
  function isDeterministicResponse(kind, resp) {
    if (!DETERMINISTIC_KINDS[kind]) return false;
    if (resp && resp.edited_value != null) return false;
    var d = resp && resp.decision;
    return d === 'approve' || d === 'reject' || d === 'pick';
  }

  // §4.1 an Item is terminal (no longer "needs you") iff applied|expired.
  function isTerminal(state) { return state === 'applied' || state === 'expired'; }

  // Flow G tier-2: the runner's BC-10/AD3 class → one honest plain sentence.
  // Presentation of a contract datum (the class string), NOT a re-derivation
  // of state. Unknown classes pass through verbatim (never masked).
  var CLASS_PLAIN = {
    AUTH_FAILURE: 'Auth is broken — the runner is dead until you fix it.',
    BILLING_ERROR: 'Billing failed — the runner is dead until you fix it.',
    STUCK_NEEDS_HUMAN: 'A worker hit a fork it must not decide — it needs you.',
    CONTEXT_OVERFLOW: 'Ran out of context — self-heals via an analysis task.',
    MAX_OUTPUT_TOKENS: 'Hit the output ceiling — self-heals via an analysis task.',
    SERVER_ERROR: 'Upstream server error — retried.',
    WATCHDOG_KILL: 'Stuck with no output — the watchdog killed it.',
    RATE_LIMIT: 'Rate-limited — routine; it backs off and retries.',
    UNKNOWN_FAILURE: 'Failed for an unclassified reason.',
    TASK_NOT_CLOSED: 'Exited clean but left the bead open — looked green, isn’t.'
  };

  function asArray(x) { return Array.isArray(x) ? x : []; }
  function nonEmptyStr(x) { return typeof x === 'string' && x.trim().length > 0; }

  /* timeAgo(isoStr, nowMs) → short human relative time ("3m", "2h", "5d").
   * claude-tools-56h: the WAITING-ON-YOU lane was unskimmable without dates —
   * Brian saw 9 identical "claude-tools-txj · 1 thing needs you" rows and
   * could not tell which dossier was which. Returns '' for missing / unparseable
   * input so the renderer can just skip the slot (never fabricate a time). */
  function timeAgo(isoStr, nowMs) {
    if (!nonEmptyStr(isoStr)) return '';
    var t = Date.parse(isoStr);
    if (!isFinite(t)) return '';
    var now = typeof nowMs === 'number' && isFinite(nowMs) ? nowMs : Date.now();
    var s = Math.round((now - t) / 1000);
    if (s < 0) return 'just now';
    if (s < 60) return s + 's ago';
    var m = Math.round(s / 60);
    if (m < 60) return m + 'm ago';
    var h = Math.round(m / 60);
    if (h < 24) return h + 'h ago';
    var d = Math.round(h / 24);
    if (d < 30) return d + 'd ago';
    var mo = Math.round(d / 30);
    if (mo < 12) return mo + 'mo ago';
    return Math.round(d / 365) + 'y ago';
  }

  /* ── §0.3 shared schema gate ──────────────────────────────────────────────
   * Returns null when the integer version is present and ≤ bound; otherwise
   * an honest error string. Never best-effort-parses an unknown higher
   * version (the lie §0.3 forbids). */
  function schemaGate(v, bound, label, clause) {
    if (typeof v !== 'number' || Math.floor(v) !== v) {
      return label + ' missing an integer ' +
        (clause === '§5.1' ? 'dossier_schema_version' : 'schema_version') +
        ' — refusing to render (' + clause + '/§0.3)';
    }
    if (v < 1) {
      // A non-positive version is not a version this renderer can claim to
      // understand; rendering it would be a best-effort parse of an
      // out-of-contract record — the lie §0.3 forbids.
      return label + ' has a non-positive version ' + v +
        ' — not a valid schema_version, refusing to best-effort-render (' +
        clause + '/§0.3)';
    }
    if (v > bound) {
      return 'unsupported ' + label + ' version ' + v + ' (this Inbox binds v' +
        bound + ') — refusing to best-effort-render (§0.3)';
    }
    return null;
  }

  /* §0.3 unknown-HIGHER test (claude-tools-4xe). TRUE only when `v` is a clean
   * integer STRICTLY greater than `bound` — a vN renderer genuinely cannot
   * honor a v(N+1) artifact (e.g. a diagram form it does not know), so
   * best-effort would be a lie (§0.3). A missing / non-integer / ≤bound
   * version is NOT unknown-higher: it renders (tolerantly). This is the ONLY
   * condition under which deriveDossierView refuses. */
  function unknownHigher(v, bound) {
    return typeof v === 'number' && isFinite(v) && Math.floor(v) === v && v > bound;
  }

  /* deriveInboxList(snapshot, nowMs?) → the ranked Inbox + Flow-G glance.
   *
   * Reads ONLY the §4.5 projection (EXIT crit 3). The WAITING-ON-YOU lane is
   * Dossier POINTERS (counts only — §4.5 carries no body); each row deep-links
   * to the dossier render. Flow-G tiers 1–2 = per-bead failure metadata that
   * IS in §4.5 (class + retry-state + Runner: notes). The §10 forensic stream
   * is structurally absent here (anti-drift). §0.3: an unknown HIGHER
   * snapshot schema_version is refused. */
  function deriveInboxList(snapshot, nowMs) {
    var snap = snapshot && typeof snapshot === 'object' ? snapshot : {};
    var err = schemaGate(snap.schema_version, SUPPORTED_SNAPSHOT_SCHEMA,
      'work-snapshot schema_version', '§4.5');
    if (err) return { ok: false, error: err };

    var rawWoy = asArray(snap.waiting_on_you);
    var items = rawWoy.map(function (w) {
      var n = typeof w.open_item_count === 'number' ? w.open_item_count : 0;
      var itemTotal = typeof w.item_count === 'number' ? w.item_count : n;
      var tier = w.tier || 'blocking';
      // claude-tools-56h — the producer now joins skim fields onto each lane
      // entry (tldr / created_at / kind / item_count). The renderer prefers
      // the dossier's own tldr as the row title; if the producer is older or
      // the dossier is body-less, we honestly fall back to the count phrase.
      var tldr = nonEmptyStr(w.tldr) ? w.tldr.trim() : '';
      var label = tldr || (n + (n === 1 ? ' thing needs you' : ' things need you'));
      var dossierId = w.dossier_id || w.dossier_ref || '';
      // claude-tools-56h — short dossier-id badge so duplicate-on-same-bead
      // dossiers stay distinguishable (Brian's 9 i1-live-* rows had identical
      // tldr/created_at/bead_ref; only the id told them apart). Tail after
      // the last '-' captures the random/sequence suffix kebab-cased ids
      // already encode; for an id with no dash we fall back to the last 8 chars.
      var dossierShort = '';
      if (dossierId) {
        var dash = dossierId.lastIndexOf('-');
        dossierShort = dash >= 0 && dash < dossierId.length - 1
          ? dossierId.slice(dash + 1)
          : dossierId.slice(-8);
      }
      return {
        dossier_ref: w.dossier_ref || dossierId,
        dossier_id: dossierId,
        dossier_short: dossierShort,
        bead_ref: w.bead_ref || '',
        tier: tier,
        kind: typeof w.kind === 'string' ? w.kind : '',
        tldr: tldr,
        created_at: typeof w.created_at === 'string' ? w.created_at : '',
        time_ago: timeAgo(w.created_at, nowMs),
        item_count: itemTotal,
        open_item_count: n,
        // Triage-line fallback kept for back-compat with anything that still
        // reads `.label` (principle 2: this carries no dossier body content).
        label: label,
        count_badge: itemTotal > 1 ? String(itemTotal) : '',
        auto_proceeds: tier === 'timed-fyi',
        dossier_href: dossierId ? '#/d/' + dossierId : null
      };
    });
    // Sort: tier rank first (blocking, timed-fyi, digest), then NEWEST-FIRST
    // by created_at within each tier (claude-tools-56h — previously stable
    // insertion order, which buried fresh asks under stale ones). Items with
    // no created_at sink to the bottom of their tier.
    var rank = { blocking: 0, 'timed-fyi': 1, digest: 2 };
    items = items.map(function (it, i) { return { it: it, i: i }; })
      .sort(function (a, b) {
        var ra = rank[a.it.tier] == null ? 1 : rank[a.it.tier];
        var rb = rank[b.it.tier] == null ? 1 : rank[b.it.tier];
        if (ra !== rb) return ra - rb;
        var ax = a.it.created_at || '';
        var bx = b.it.created_at || '';
        if (ax !== bx) {
          if (!ax) return 1;
          if (!bx) return -1;
          return bx < ax ? -1 : 1;
        }
        return a.i - b.i;
      })
      .map(function (x) { return x.it; });

    // Flow-G tiers 1–2 GLANCE: every failing bead in the lifecycle columns.
    var cols = (snap.lifecycle_columns && typeof snap.lifecycle_columns === 'object')
      ? snap.lifecycle_columns : {};
    var failures = [];
    Object.keys(cols).forEach(function (stage) {
      asArray(cols[stage]).forEach(function (c) {
        var f = c && c.failure;
        if (!f) return;
        var cls = f.class || 'UNKNOWN_FAILURE';
        failures.push({
          bead_ref: c.bead_ref || '',
          title: c.title || '(untitled)',
          stage: c.stage || stage || '',
          class: cls,
          class_plain: CLASS_PLAIN[cls] || ('Failed: ' + cls + '.'),
          retry_state: f.retry_state || null,
          // Tier-2 synced-metadata timeline — always remote-available (§4.5).
          runner_notes: asArray(f.runner_notes),
          badge: '⚠ ' + cls + (f.retry_state ? ' · ' + f.retry_state : ''),
          failure_href: c.bead_ref ? '#/f/' + c.bead_ref : null
        });
      });
    });

    return {
      ok: true,
      principal: snap.principal || '(unresolved)',
      read_only: snap.read_only === true,
      schema_version: snap.schema_version,
      items: items,
      open_total: items.reduce(function (a, it) {
        return a + (it.open_item_count || 0);
      }, 0),
      failures: failures
    };
  }

  /* deriveItem(it, idx?) → one rendered Item row. The affordance is derived
   * FROM `kind` (§5.2 — the doc IS the form).
   *
   * claude-tools-4xe — TOLERANT, never a wall. The conformance gate now lives
   * at WRITE (cf/src/coordinator.js _writeRecord + lib/coordinator.sh
   * co__store_put): a non-conformant dossier is REJECTED before it is ever
   * stored, so the agent gets a hard failure — not a false-success the Inbox
   * then walls. The renderer's job is the OPPOSITE: every dossier that WAS
   * accepted (incl. legacy pre-gate records) MUST stay readable AND answerable.
   * So deriveItem ALWAYS returns { item } — never { missing }. A
   * malformed/absent field degrades to a clearly-LABELED best-effort fallback
   * (recorded in item.degraded[]), never a dropped answer control. Returns
   * { item }. */
  function deriveItem(it, idx) {
    var src = (it && typeof it === 'object') ? it : {};
    var degraded = [];
    var id = src.id;
    if (!nonEmptyStr(id)) {
      // No idempotency key on an accepted record (legacy/pre-gate). Synthesize
      // a stable per-position key so the human can still answer it; flag it.
      id = 'item-' + (typeof idx === 'number' ? idx : 0);
      degraded.push('This item had no id; a temporary one was assigned so you can still respond.');
    }
    var kind = src.kind;
    if (!ITEM_KINDS[kind]) {
      // Unknown/absent kind ⇒ fall back to a freeform answer so the human is
      // never blocked from responding (principle 3: a "no" stays cheap).
      degraded.push('This item’s type was unrecognized; showing a free-text response.');
      kind = 'freeform-edit';
    }
    var ca = (src.context_anchor && typeof src.context_anchor === 'object') ? src.context_anchor : {};
    var where = nonEmptyStr(ca.where) ? ca.where : null;
    var expansion = nonEmptyStr(ca.expansion) ? ca.expansion : null;
    if (!where || !expansion) {
      degraded.push('Some context for this item was missing; showing what was provided.');
      if (!where) where = '(where this sits was not provided)';
      if (!expansion) expansion = '(no extra context was provided)';
    }
    var st = src.state || 'open';

    // §5.2 the response affordance set, derived from kind. Each action is a
    // SINGLE first-class control — reject/edit/object are NOT a penalty path
    // (principle 3: "your no as cheap as your yes"; EXIT crit 2).
    var affordances;
    switch (kind) {
      case 'approve-reject':
        affordances = ['approve', 'reject', 'freeform']; break;
      case 'pick-option':
        affordances = ['pick', 'edit', 'freeform']; break;
      case 'approve-recommendation':
        affordances = ['approve', 'edit', 'freeform']; break;
      case 'freeform-edit':
        affordances = ['edit', 'freeform']; break;
      case 'fyi-objectable':
        // Silence auto-proceeds (the consequence). Acting = object.
        affordances = ['object']; break;
    }

    return {
      item: {
        id: id,
        kind: kind,
        affordances: affordances,
        framing: (src.framing && typeof src.framing === 'object') ? src.framing : {},
        context_anchor: {
          where: where,
          link: nonEmptyStr(ca.link) ? ca.link : null,
          expansion: expansion
        },
        options: asArray(src.options).map(function (o) {
          o = (o && typeof o === 'object') ? o : {};
          return {
            option_id: o.option_id || '',
            label: o.label || '(option)',
            blast_radius: o.blast_radius || ''
          }; // consequence_block intentionally NOT surfaced (machine-only §5.3)
        }),
        recommendation: (src.recommendation && typeof src.recommendation === 'object')
          ? { value: src.recommendation.value, why: src.recommendation.why } : null,
        reversible: nonEmptyStr(src.reversible) ? src.reversible : '(reversibility unstated)',
        state: st,
        terminal: isTerminal(st),
        // Honest, labeled best-effort notes (claude-tools-4xe) — the UI shows
        // these so a degraded item is never silently papered over.
        degraded: degraded,
        // A read-back of an already-resolved Item (partial resolution — AD7).
        response_summary: src.response && typeof src.response === 'object'
          ? summarizeResponse(src.response) : null
      }
    };
  }

  function summarizeResponse(r) {
    var d = r.decision || '';
    if (d === 'pick') return 'picked: ' + (r.selected_option_id || '(option)');
    if (d === 'edit') return 'edited the recommendation';
    if (d === 'freeform') return 'left freeform feedback';
    if (d === 'object') return 'objected';
    if (d === 'approve') return 'approved the recommendation';
    if (d === 'reject') return 'rejected';
    return d || 'responded';
  }

  /* deriveDossierView(dossier) → the §5 render model.
   *
   * claude-tools-4xe — TOLERANT BY CONTRACT. The §5.1-core conformance gate
   * was moved to the RIGHT boundary: the engine's ONE dossier WRITE path
   * (cf/src/coordinator.js _writeRecord + lib/coordinator.sh co__store_put
   * → dossierWriteBodyOk / co__dossier_write_body_ok). A non-conformant
   * dossier is now REJECTED before it is ever stored — the agent gets a hard,
   * loud failure, never a false-success put. The renderer's job is the EXACT
   * COMPLEMENT: a dossier the engine ACCEPTED (including legacy records stored
   * before the write gate existed) MUST ALWAYS be readable AND answerable.
   *
   * So this NEVER blank-refuses an accepted dossier. The ONE permitted refusal
   * is §0.3 unknown-HIGHER schema (a vN renderer genuinely cannot honor a
   * v(N+1) artifact) — and even that is a plain, human-meaningful message, no
   * contract/§/§11 jargon on the phone. Every other gap degrades to a clearly-
   * LABELED best-effort fallback (recorded in `.degraded[]` / per-diagram
   * `.degraded`): tldr/sections/full_detail always render; a non-Mermaid or
   * empty diagram becomes a labeled warning block (NOT a silent <pre>); items
   * stay answerable; the §5.2.2 opaque reconcile-pointer renders a best-effort
   * summary. This is NOT a §11 change: INTERFACE §5.1 mandates the GENERATOR
   * reject and the renderer render Mermaid as SVG — it never mandates a
   * render-time REFUSAL of a non-conformant dossier; that was an
   * implementation choice and it was the bug (claude-tools-4xe). The profile
   * (decision / overview) stays EMERGENT — one render path (§5.2.1). */
  function deriveDossierView(dossier) {
    var d = dossier && typeof dossier === 'object' ? dossier : {};
    var bodyRaw = (d.body && typeof d.body === 'object') ? d.body : null;

    // ── THE ONLY REFUSAL (§0.3 unknown-HIGHER) — human-meaningful, no jargon.
    if (unknownHigher(d.schema_version, SUPPORTED_DOSSIER_SCHEMA) ||
        (bodyRaw && unknownHigher(bodyRaw.dossier_schema_version, SUPPORTED_BODY_SCHEMA))) {
      return {
        ok: false,
        too_new: true,
        error: 'This decision was prepared by a newer version of the app than ' +
          'the one on your phone, so it can’t be shown here safely. Update the ' +
          'Inbox app to open it — nothing was lost and your answer is still needed.'
      };
    }

    var degraded = [];

    // §5.2.2 opaque reconcile-pointer — a best-effort summary, never a wall.
    // It is a follow-up the reconciler will read; surface what it is and keep
    // any carried item answerable.
    var isReconcilePtr = bodyRaw && nonEmptyStr(bodyRaw.reconcile_of);

    var tldr, sections, diagrams, fullDetail;
    if (isReconcilePtr) {
      degraded.push('This is a follow-up the system raised after an earlier answer; showing a summary.');
      tldr = 'Follow-up needed' +
        (nonEmptyStr(bodyRaw.reconcile_item) ? ' on “' + bodyRaw.reconcile_item + '”' : '');
      sections = [{
        heading: 'Why you’re seeing this',
        prose: nonEmptyStr(bodyRaw.reason)
          ? bodyRaw.reason
          : 'An earlier response needs another look before it can be applied.'
      }];
      if (nonEmptyStr(bodyRaw.reconcile_of)) {
        sections.push({ heading: 'Original decision', prose: bodyRaw.reconcile_of });
      }
      diagrams = [];
      fullDetail = nonEmptyStr(bodyRaw.reason)
        ? bodyRaw.reason
        : 'This dossier points back at an earlier decision; respond to the item below to move it forward.';
    } else {
      var body = bodyRaw || {};
      if (!bodyRaw) degraded.push('This decision had no detail body; showing what was available.');

      tldr = nonEmptyStr(body.tldr) ? body.tldr : '(no short summary was provided)';
      if (!nonEmptyStr(body.tldr)) degraded.push('No summary line was provided.');

      var rawSecs = asArray(body.sections).filter(function (s) {
        return s && nonEmptyStr(s.heading) && nonEmptyStr(s.prose);
      }).map(function (s) { return { heading: s.heading, prose: s.prose }; });
      if (rawSecs.length === 0) {
        degraded.push('No detail sections were provided; showing the full write-up instead.');
        rawSecs = [{
          heading: 'Details',
          prose: nonEmptyStr(body.full_detail) ? body.full_detail
            : (nonEmptyStr(body.tldr) ? body.tldr : '(no detail was provided for this decision)')
        }];
      }
      sections = rawSecs;

      // A diagram that is empty or not Mermaid stays VISIBLE as a clearly-
      // labeled warning block (criterion 2) — never dropped, never a silent
      // <pre> masquerading as a rendered diagram (the §5.1 anti-pattern).
      diagrams = asArray(body.diagrams).map(function (g) {
        g = (g && typeof g === 'object') ? g : {};
        var caption = nonEmptyStr(g.caption) ? g.caption : '(untitled diagram)';
        var content = typeof g.content === 'string' ? g.content : '';
        if (!nonEmptyStr(content)) {
          degraded.push('A diagram was empty.');
          return { caption: caption, content: '', degraded: true,
            note: 'This diagram was empty.' };
        }
        if (!looksLikeMermaid(content)) {
          degraded.push('A diagram was not in the supported (Mermaid) format; showing its text.');
          return { caption: caption, content: content, degraded: true,
            note: 'This diagram isn’t in the supported diagram format — showing its raw text.' };
        }
        return { caption: caption, content: content, degraded: false };
      });

      fullDetail = nonEmptyStr(body.full_detail) ? body.full_detail
        : (nonEmptyStr(body.tldr) ? body.tldr : '(no additional detail was provided)');
      if (!nonEmptyStr(body.full_detail)) degraded.push('No full write-up was provided.');
    }

    // B3 (claude-tools-95m) — DEGRADED-AUTHOR badge. dg__author stamps
    // `body.authored_by` ("agent" | "fallback") + `body.authored_by_reason`
    // when it runs. A "fallback" stamp means the dossier-builder agent was
    // unavailable / errored / timed out / produced invalid output, and the
    // jq deterministic shape-coercer ran instead. The Inbox surfaces this
    // distinctly (not just as a generic .degraded note) so Brian sees at a
    // glance that this dossier is lower-quality — never just rendered as if
    // it were normal. An ABSENT field is treated as "unknown" (legacy /
    // pre-B3 dossiers), NOT as fallback, so old records render cleanly.
    var bodyForAuthor = bodyRaw || {};
    var authoredBy = nonEmptyStr(bodyForAuthor.authored_by) ? bodyForAuthor.authored_by : 'unknown';
    var authoredByReason = nonEmptyStr(bodyForAuthor.authored_by_reason) ? bodyForAuthor.authored_by_reason : null;
    var authoredByNote = null;
    if (authoredBy === 'fallback') {
      var reasonPhrase;
      switch (authoredByReason) {
        case 'no_DG_AUTHOR_CMD':     reasonPhrase = 'the dossier-builder agent wasn’t configured for this run'; break;
        case 'agent_unavailable':    reasonPhrase = 'the dossier-builder agent errored'; break;
        case 'agent_timeout':        reasonPhrase = 'the dossier-builder agent timed out'; break;
        case 'agent_invalid_output': reasonPhrase = 'the dossier-builder agent returned malformed output'; break;
        default:                     reasonPhrase = 'the dossier-builder agent did not run';
      }
      authoredByNote = 'Authored by the deterministic fallback (' + reasonPhrase +
        ') — this dossier is lower-quality than usual; the answer affordance is unchanged.';
    }

    // §5.2 items — ALWAYS answerable (deriveItem never refuses; claude-tools-4xe).
    var items = asArray(d.items).map(function (raw, i) { return deriveItem(raw, i).item; });
    items.forEach(function (x) {
      if (x.degraded && x.degraded.length) {
        degraded.push('An item (' + x.id + ') was incomplete; showing a best-effort version.');
      }
    });

    var open = items.filter(function (x) { return !x.terminal; }).length;
    var total = items.length;

    return {
      ok: true,
      id: d.id || '',
      kind: d.kind || 'decide',
      trigger: d.trigger || '',
      bead_ref: d.bead_ref || '',
      tier: d.tier || 'blocking',
      timer_fire_at: d.timer_fire_at || null,
      // Honest, human-readable best-effort notes — the UI shows these so a
      // degraded-but-readable dossier is never silently papered over.
      degraded: degraded,
      reconcile_pointer: !!isReconcilePtr,
      body: {
        tldr: tldr,
        sections: sections,
        diagrams: diagrams,
        full_detail: fullDetail,
        // B3 (claude-tools-95m) — passthrough so the app's badge renderer can
        // distinguish "agent" from "fallback" without re-reading `dossier`.
        authored_by: authoredBy,
        authored_by_reason: authoredByReason,
        authored_by_note: authoredByNote
      },
      items: items,
      rollup: {
        total: total,
        open: open,
        resolved: total - open,
        // §4.1 derived rollup — INFORMATIONAL, never a pipeline gate (AD7).
        all_resolved: total > 0 && open === 0
      },
      // §5.2.1 EMERGENT profile (no schema/render branch — just a label for
      // the header copy: zero/all-fyi items read as the Flow-F overview;
      // mixed items read as a review).
      profile: items.length === 0 ||
        items.every(function (x) { return x.kind === 'fyi-objectable'; })
          ? 'overview' : 'decision',
      // §0.B / D5 — a timed-fyi auto-proceeds on silence (principle 6: silence
      // is a valid input). Surfaced honestly so "no" is genuinely cheap.
      auto_proceeds: d.tier === 'timed-fyi',
      timer_note: d.tier === 'timed-fyi'
        ? (d.timer_fire_at
            ? 'Auto-proceeds at ' + d.timer_fire_at + ' if you do nothing (reversible)'
            : 'Auto-proceeds on its timer if you do nothing (reversible)')
        : 'Untouched items hard-block this gate until resolved (§0.B blocking tier)'
    };
  }

  /* buildItemResponse(item, input, nowMs?) → the §5.2 `response` payload.
   *
   * PURE presentation→payload map. It does NOT apply anything: consequence
   * application + the per-Item idempotency latch + the S-2 reconcile are T5's
   * (`do_item_apply`). It mirrors §5.2.2 / do__is_deterministic so the UI can
   * HONESTLY tell the human, before they submit, whether this resolves
   * "instantly, deterministically" or "the reconciler will read this" — never
   * a false-instant promise (principle 4/5).
   *
   * principle 3 / EXIT crit 2: `reject`, `edit`, `object`, `freeform` are each
   * ONE action producing ONE payload — symmetric with `approve`. There is no
   * extra confirm/penalty step for a "no".
   *
   * input = { action, option_id?, edited_value?, text? }
   *   action ∈ approve | reject | pick | edit | freeform | object
   * The principal is NOT set here — §9.1 resolves it at the ONE chokepoint
   * (the client never picks the principal). responded_at is stamped from the
   * injected clock so the function stays pure/testable. */
  function buildItemResponse(item, input, nowMs) {
    if (!item || typeof item !== 'object') {
      return { ok: false, error: 'buildItemResponse: no item' };
    }
    if (!input || typeof input !== 'object' || !input.action) {
      return { ok: false, error: 'buildItemResponse: no action' };
    }
    var kind = item.kind;
    if (!ITEM_KINDS[kind]) {
      return { ok: false, error: 'buildItemResponse: item kind "' + kind + '" outside the §5.2 enum' };
    }
    var action = input.action;
    var now = typeof nowMs === 'number' ? new Date(nowMs).toISOString()
      : new Date().toISOString();
    var resp = { responded_at: now };

    switch (action) {
      case 'approve':
        if (kind !== 'approve-reject' && kind !== 'approve-recommendation') {
          return legalErr(action, kind);
        }
        resp.decision = 'approve';
        break;
      case 'reject':
        if (kind !== 'approve-reject') return legalErr(action, kind);
        // §5.2.2: a pure reject is STILL deterministic (its pre-declared block
        // applies). Reject is not a slow path — principle 3.
        resp.decision = 'reject';
        break;
      case 'pick':
        if (kind !== 'pick-option') return legalErr(action, kind);
        if (!nonEmptyStr(input.option_id)) {
          return { ok: false, error: 'pick requires an option_id (§5.2 selected_option_id)' };
        }
        resp.decision = 'pick';
        resp.selected_option_id = input.option_id;
        break;
      case 'object':
        if (kind !== 'fyi-objectable') return legalErr(action, kind);
        // An explicit objection halts the auto-proceed and is the §5.2.2
        // RECONCILER path (consequence.sh `do__is_deterministic`: `object` is
        // NOT in {approve,reject,pick}). Only an UN-objected timer
        // auto-proceed is the deterministic fyi path, and that is T5.4's, not
        // a human submit. mode is computed below from the shared predicate so
        // this preview can never lie "instant" about an objection.
        resp.decision = 'object';
        if (nonEmptyStr(input.text)) resp.freeform_text = input.text;
        break;
      case 'edit':
        // An edited recommendation ⇒ §5.2.2 RECONCILER (interpreted, may emit
        // a scoped follow-up). Legal wherever a recommendation/option exists
        // or the item is freeform-edit.
        if (kind === 'approve-reject' || kind === 'fyi-objectable') {
          return legalErr(action, kind);
        }
        if (!nonEmptyStr(input.edited_value)) {
          return { ok: false, error: 'edit requires a non-empty edited_value (§5.2)' };
        }
        resp.decision = 'edit';
        resp.edited_value = input.edited_value;
        break;
      case 'freeform':
        // Freeform reaction ⇒ §5.2.2 RECONCILER. Available on any non-fyi kind
        // as the escape hatch (principle 3 — react instead of approve).
        if (kind === 'fyi-objectable') return legalErr(action, kind);
        if (!nonEmptyStr(input.text)) {
          return { ok: false, error: 'freeform requires non-empty text (§5.2 freeform_text)' };
        }
        resp.decision = 'freeform';
        resp.freeform_text = input.text;
        break;
      default:
        return { ok: false, error: 'buildItemResponse: unknown action "' + action + '"' };
    }

    // The ONE source of the deterministic/reconciler split — the exact mirror
    // of the T5 producer (never a per-branch hand-set that could drift).
    var deterministic = isDeterministicResponse(kind, resp);

    return {
      ok: true,
      response: resp,
      // The HONEST preview (§5.2.2): "applied the instant you submit" vs
      // "a reconciler reads this and may re-surface a scoped follow-up".
      mode: deterministic ? 'deterministic' : 'reconciler',
      preview: deterministic
        ? 'Applied deterministically on submit — pre-declared, instantly trustworthy (§5.2.2/principle 5).'
        : 'A reconciler reads this; it re-surfaces only if it conflicts or opens a new question (§5.2.2). Resolved siblings are untouched.'
    };

    function legalErr(a, k) {
      return { ok: false, error: 'action "' + a +
        '" is not a §5.2 affordance of a "' + k + '" item' };
    }
  }

  /* deriveConfirm(dossier, nowMs?) → the Flow-B step-6 ack receipt.
   *
   * EXIT crit 1 / S-2 — THE NO-DOLT-LAG-LIE GUARANTEE. The ack is derived
   * STRICTLY from the re-fetched §4 Dossier record: each Item's
   * `state`/`consequence_applied`/`applied_at` — the CONTROL-PLANE truth the
   * Coordinator owns and reconciles into beads. It is NEVER a beads/Dolt read,
   * so it cannot show a stale "still blocked" while control already applied.
   * "You don't need to go check" (UX confirm) is honest precisely because
   * this reads the latch, not Dolt. */
  function deriveConfirm(dossier) {
    var v = deriveDossierView(dossier);
    if (!v.ok) return { ok: false, error: v.error, escalation: v.escalation === true };
    var raw = asArray(dossier.items);
    var applied = [], still_open = 0;
    raw.forEach(function (it) {
      if (it.consequence_applied === true || it.state === 'applied') {
        var dec = (it.response && it.response.decision) || '';
        applied.push({
          item_id: it.id,
          decision: dec,
          // §5.2.2 — the SAME shared predicate the producer uses: a pure
          // approve/reject/pick went deterministic; an edit/freeform/object
          // went the reconciler. Honest per-Item, cannot drift from T5.
          mode: isDeterministicResponse(it.kind, it.response) ? 'deterministic' : 'reconciler',
          applied_at: it.applied_at || null
        });
      } else if (it.state === 'expired') {
        applied.push({ item_id: it.id, decision: 'auto-proceeded', mode: 'timed-fyi', applied_at: it.applied_at || null });
      } else {
        still_open += 1; // partial resolution is first-class — never a failure
      }
    });
    var det = applied.filter(function (a) { return a.mode === 'deterministic'; }).length;
    var rec = applied.filter(function (a) { return a.mode === 'reconciler'; }).length;
    return {
      ok: true,
      bead_ref: v.bead_ref,
      receipt: {
        applied: applied,
        deterministic_count: det,
        reconciler_count: rec,
        still_open: still_open
      },
      all_resolved: v.rollup.all_resolved,
      honest_note: still_open > 0
        ? still_open + ' item' + (still_open === 1 ? '' : 's') +
          ' left open — that is fine, partial resolution is first-class (AD7); ' +
          'they block no sibling and you can return later.'
        : 'Every item resolved. ' + v.bead_ref +
          ' is reconciled by the Coordinator (control→work, S-2) — the bead ' +
          'unblocks without a Dolt-lag lie; you don’t need to go check.'
    };
  }

  /* deriveFailureView(snapshot, beadRef) → Flow-G tiers 1–2 for one bead.
   *
   * Tier-1 glance + tier-2 human-worded summary, BOTH from §4.5 synced
   * metadata (always remote-available). Tier-3 forensic is NOT here: it is an
   * explicit, authed, on-demand pull (§10.3) — this only models the
   * affordance and, when the app passes one post-fetch, the redacted blob.
   * "Surface the silent failures loudest" (principle 7) — a TASK_NOT_CLOSED /
   * tool-error class is flagged as silent. */
  function deriveFailureView(snapshot, beadRef, fetchedBlob) {
    var list = deriveInboxList(snapshot);
    if (!list.ok) return { ok: false, error: list.error };
    var f = list.failures.filter(function (x) { return x.bead_ref === beadRef; })[0];
    if (!f) return { ok: false, error: 'no Flow-G failure metadata for ' + beadRef + ' in the projection' };
    var silent = f.class === 'TASK_NOT_CLOSED';
    return {
      ok: true,
      bead_ref: f.bead_ref,
      title: f.title,
      glance: { class: f.class, class_plain: f.class_plain, retry_state: f.retry_state, badge: f.badge },
      summary: {
        runner_notes: f.runner_notes,
        silent: silent,
        silent_note: silent
          ? 'A SILENT failure — it looked green but isn’t. Surfaced louder than a loud one (principle 7).'
          : null
      },
      forensic: {
        // §10.3: an explicit authed on-demand pull. NEVER auto-fetched, NEVER
        // in the projection, NEVER in a notify/digest body (principle 2).
        available: true,
        note: 'Tier-3 raw stream-json is across a security boundary. Pull it ' +
          'on demand — redacted at the runner (tool seq + errors + last turn; ' +
          'file bodies stripped), encrypted in transit, server-side hard-' +
          'deleted at the earlier of its TTL or your dismiss (§10.2/§10.3).',
        fetched: !!fetchedBlob,
        blob: fetchedBlob || null
      }
    };
  }

  return {
    deriveInboxList: deriveInboxList,
    deriveDossierView: deriveDossierView,
    deriveItem: deriveItem,
    buildItemResponse: buildItemResponse,
    deriveConfirm: deriveConfirm,
    deriveFailureView: deriveFailureView,
    SUPPORTED_SNAPSHOT_SCHEMA: SUPPORTED_SNAPSHOT_SCHEMA,
    SUPPORTED_DOSSIER_SCHEMA: SUPPORTED_DOSSIER_SCHEMA,
    SUPPORTED_BODY_SCHEMA: SUPPORTED_BODY_SCHEMA,
    looksLikeMermaid: looksLikeMermaid,
    ITEM_KINDS: ITEM_KINDS
  };
});
