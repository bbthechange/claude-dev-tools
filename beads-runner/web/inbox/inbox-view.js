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
 *
 * ANTI-DRIFT (task contract): presentation ONLY. This module NEVER invents a
 * §5 field and NEVER best-effort-renders a malformed Dossier. A MANDATORY §5
 * field that is absent (a `body` tier, or a per-Item `context_anchor`) is a
 * §11 BLOCKING escalation to claude-tools-65z — surfaced as an honest refusal
 * view, NOT a UI-side fabrication. It owns NO control logic: consequence
 * application + the per-Item idempotency latch + the S-2 control→work
 * reconcile are T5's; this module maps a form to the §5.2 `response` and
 * derives the ack from the CONTROL-PLANE record the Coordinator reconciles
 * into beads (so the ack carries no Dolt-lag lie — S-2).
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.InboxView = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // Contract-bound schema versions this renderer understands (§0.3).
  var SUPPORTED_SNAPSHOT_SCHEMA = 1; // §4.5 work-snapshot
  var SUPPORTED_DOSSIER_SCHEMA = 1;  // §4.1 Dossier envelope
  var SUPPORTED_BODY_SCHEMA = 1;     // §5.1 body (dossier_schema_version)

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

  /* deriveInboxList(snapshot, nowMs?) → the ranked Inbox + Flow-G glance.
   *
   * Reads ONLY the §4.5 projection (EXIT crit 3). The WAITING-ON-YOU lane is
   * Dossier POINTERS (counts only — §4.5 carries no body); each row deep-links
   * to the dossier render. Flow-G tiers 1–2 = per-bead failure metadata that
   * IS in §4.5 (class + retry-state + Runner: notes). The §10 forensic stream
   * is structurally absent here (anti-drift). §0.3: an unknown HIGHER
   * snapshot schema_version is refused. */
  function deriveInboxList(snapshot) {
    var snap = snapshot && typeof snapshot === 'object' ? snapshot : {};
    var err = schemaGate(snap.schema_version, SUPPORTED_SNAPSHOT_SCHEMA,
      'work-snapshot schema_version', '§4.5');
    if (err) return { ok: false, error: err };

    var rawWoy = asArray(snap.waiting_on_you);
    var items = rawWoy.map(function (w) {
      var n = typeof w.open_item_count === 'number' ? w.open_item_count : 0;
      var tier = w.tier || 'blocking';
      return {
        dossier_ref: w.dossier_ref || '',
        bead_ref: w.bead_ref || '',
        tier: tier,
        open_item_count: n,
        // Notification triage line ONLY — the dossier body is NOT here
        // (principle 2: notifications never carry content; §4.5 carries none).
        label: n + (n === 1 ? ' thing needs you' : ' things need you'),
        auto_proceeds: tier === 'timed-fyi',
        // Deep-link target this app opens (the dossier render fetches the §4
        // record separately — the lane itself stays a pointer).
        dossier_href: w.dossier_ref ? '#/d/' + w.dossier_ref : null
      };
    });
    // tier rank: blocking first, then timed-fyi, then digest; stable within.
    var rank = { blocking: 0, 'timed-fyi': 1, digest: 2 };
    items = items.map(function (it, i) { return { it: it, i: i }; })
      .sort(function (a, b) {
        var ra = rank[a.it.tier] == null ? 1 : rank[a.it.tier];
        var rb = rank[b.it.tier] == null ? 1 : rank[b.it.tier];
        return ra - rb || a.i - b.i;
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

  /* deriveItem(it) → one rendered Item row. The affordance is derived FROM
   * `kind` (§5.2 — the doc IS the form). `context_anchor` is MANDATORY (AD7
   * self-contained-context invariant): a missing/empty one is a §11
   * escalation, NOT a silently-dropped field — the caller refuses the whole
   * dossier. Returns { item } or { missing: '<§-cited reason>' }. */
  function deriveItem(it) {
    if (!it || typeof it !== 'object') return { missing: '§5.2 item is not an object' };
    var id = it.id;
    if (!nonEmptyStr(id)) return { missing: '§5.2 item missing a non-empty id (the per-Item idempotency key, §0.4)' };
    var kind = it.kind;
    if (!ITEM_KINDS[kind]) {
      return { missing: '§5.2 item ' + id + ' has kind "' + kind +
        '" outside the closed enum (approve-reject|pick-option|approve-recommendation|freeform-edit|fyi-objectable)' };
    }
    var ca = it.context_anchor;
    if (!ca || typeof ca !== 'object' || !nonEmptyStr(ca.where) || !nonEmptyStr(ca.expansion)) {
      // AD7: "an item whose ask is not understandable without external
      // context is a contract violation, not a wording nit." T6b MUST render
      // it inline; a producer that omitted it is the escalation, not a thing
      // the UI papers over.
      return { missing: '§5.2 item ' + id + ' missing the MANDATORY context_anchor{where,expansion} (the AD7 self-contained-context invariant)' };
    }
    var st = it.state || 'open';

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
        framing: (it.framing && typeof it.framing === 'object') ? it.framing : {},
        context_anchor: {
          where: ca.where,
          link: nonEmptyStr(ca.link) ? ca.link : null,
          expansion: ca.expansion
        },
        options: asArray(it.options).map(function (o) {
          return {
            option_id: o.option_id || '',
            label: o.label || '(option)',
            blast_radius: o.blast_radius || ''
          }; // consequence_block intentionally NOT surfaced (machine-only §5.3)
        }),
        recommendation: (it.recommendation && typeof it.recommendation === 'object')
          ? { value: it.recommendation.value, why: it.recommendation.why } : null,
        reversible: nonEmptyStr(it.reversible) ? it.reversible : '(reversibility unstated)',
        state: st,
        terminal: isTerminal(st),
        // A read-back of an already-resolved Item (partial resolution — AD7).
        response_summary: it.response && typeof it.response === 'object'
          ? summarizeResponse(it.response) : null
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

  /* deriveDossierView(dossier, nowMs?) → the full §5 render model.
   *
   * §0.3 first (reject unknown-higher envelope AND body version). Then EVERY
   * mandatory §5.1 body tier and EVERY per-Item §5.2 field is enforced: a
   * gap returns ok:false WITH escalation:true (§11 → claude-tools-65z) — the
   * renderer refuses rather than fabricate (the task's ANTI-DRIFT line). The
   * profile (decision / mixed review / all-fyi overview) is EMERGENT from the
   * body+item mix — there is ONE render path, no per-profile branch (§5.2.1). */
  function deriveDossierView(dossier) {
    var d = dossier && typeof dossier === 'object' ? dossier : {};

    var envErr = schemaGate(d.schema_version, SUPPORTED_DOSSIER_SCHEMA,
      'Dossier schema_version', '§4.1');
    if (envErr) return { ok: false, error: envErr };

    var body = d.body && typeof d.body === 'object' ? d.body : null;
    if (!body) {
      return refuse('Dossier ' + (d.id || '?') +
        ' has no §5.1 body object — the progressive-disclosure body is mandatory (AD7)');
    }
    var bodyErr = schemaGate(body.dossier_schema_version, SUPPORTED_BODY_SCHEMA,
      'Dossier body', '§5.1');
    if (bodyErr) return { ok: false, error: bodyErr };

    // §5.1 — ALL FOUR tiers mandatory; none optional. A missing tier is the
    // decision-singular AD7 regression and is REFUSED, never fabricated.
    var bErr = [];
    if (!nonEmptyStr(body.tldr)) bErr.push('§5.1 body.tldr (the skim entry point) is missing/empty');
    var sections = asArray(body.sections);
    if (sections.length === 0) bErr.push('§5.1 body.sections[] is empty (the decision-singular AD7 regression)');
    sections.forEach(function (s, i) {
      if (!s || !nonEmptyStr(s.heading) || !nonEmptyStr(s.prose)) {
        bErr.push('§5.1 body.sections[' + i + '] needs non-empty {heading,prose}');
      }
    });
    if (!Array.isArray(body.diagrams)) {
      bErr.push('§5.1 body.diagrams[] must be an array ([] only when genuinely non-structural)');
    } else {
      body.diagrams.forEach(function (g, i) {
        if (!g || !nonEmptyStr(g.caption) || !nonEmptyStr(g.content)) {
          bErr.push('§5.1 body.diagrams[' + i + '] needs non-empty {caption,content}');
        }
      });
    }
    if (!nonEmptyStr(body.full_detail)) bErr.push('§5.1 body.full_detail (the stand-alone full picture) is missing/empty — NOT optional');
    if (bErr.length) return refuse(bErr.join(' · '));

    // §5.2 items — each enforced; a missing context_anchor is the escalation.
    var rawItems = asArray(d.items);
    var items = [], iErr = [];
    rawItems.forEach(function (raw) {
      var r = deriveItem(raw);
      if (r.missing) iErr.push(r.missing);
      else items.push(r.item);
    });
    if (iErr.length) return refuse(iErr.join(' · '));

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
      body: {
        tldr: body.tldr,
        sections: sections.map(function (s) {
          return { heading: s.heading, prose: s.prose };
        }),
        diagrams: asArray(body.diagrams).map(function (g) {
          return { caption: g.caption, content: g.content };
        }),
        full_detail: body.full_detail
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
      // the header copy: a deep body + all-fyi-objectable/zero items reads as
      // the Flow-F proactive overview; mixed items read as a review).
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

    function refuse(reason) {
      return {
        ok: false,
        escalation: true,
        error: 'REFUSING to render Dossier ' + (d.id || '?') +
          ' — a MANDATORY §5 field is absent: ' + reason +
          '. Per the task ANTI-DRIFT this is a §11 BLOCKING escalation to ' +
          'claude-tools-65z (reopen → amend+bump+re-freeze), NOT a UI-side ' +
          'fabrication. The Inbox presents the contract; it never invents it.'
      };
    }
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
    ITEM_KINDS: ITEM_KINDS
  };
});
