/* beads-runner/web/shared/enums.js — Contract D single source of truth
 * (UX-V2-ARCHITECTURE.md §5 "Contract D — Vocabulary & enums", created by
 *  claude-tools-rznj.2; the C-shell extraction did net/dom/shell/tokens but
 *  deliberately NOT enums — this module fills that gap).
 *
 * THE closed sets both tiers share VERBATIM. Drift here is "the gate collision
 * all over again" (§5 / §1 table row D): the producer (engine) and the consumer
 * (a view-model) disagree on a closed set, and a value one side emits the other
 * silently drops or mis-buckets. The antidote is ONE authoritative list, frozen,
 * imported by the UI — and a conformance test (cf/test/conformance-contract-v2.sh,
 * Contract D) that asserts this file is byte-equivalent to:
 *   (a) the FROZEN §5.2 closed-enum spec in UX-V2-ARCHITECTURE.md, and
 *   (b) the matching engine constant wherever one already exists
 *       (today: notification.js `TIERS` ≡ NOTIFICATION_TIER; the activity /
 *        hold-type / liveness mirrors are added by their tracks — I1 / J2 —
 *        and the test promotes each to an enforced byte-equivalence row then).
 *
 * ANTI-DRIFT: binds FROZEN UX-V2-ARCHITECTURE.md §5.2. A §5.2 gap ⇒ reopen the
 * spine doc and re-freeze (explicit section + rationale + date, per its footer)
 * — NEVER edit this file silently to make a test pass, and NEVER add a value
 * here that §5.2 does not list.
 *
 * These are CLOSED sets: ordered, exhaustive, lower-kebab string members (or the
 * measured integer thresholds). `Object.freeze` makes a stray push throw in
 * strict mode rather than silently widen the set.
 *
 * UMD so a Node conformance test can `require()` it and the browser can read
 * `window.Enums`. Pure data — no DOM, no network, no state (mirrors net.js/dom.js). */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.Enums = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // §5.2 "Activity state" — derived from the log stream; state_confidence is
  // ALWAYS "derived", NEVER "asserted" (principle 10). The detector regex set
  // that FEEDS this is [free] to grow; the ENUM it maps onto is [spine] — fixed.
  var ACTIVITY_STATE = Object.freeze([
    'writing-code',     // Edit/Write/MultiEdit
    'running-tests',    // test-runner Bash
    'exploring',        // Read/Grep/Glob
    'thinking',         // no events 90–180s
    'waiting-on-you',   // in an ask-brian call
    'rate-limited',     // rate_limit_event
    'maybe-stuck'       // no events >180s
  ]);

  // §5.2 "Liveness dot" — separate from activity state, deliberately blunt.
  // The 90/180 windows are MEASURED (60s false-fires ~56×); [spine — the number].
  // Do NOT tighten without re-measuring (UX-V2-ARCHITECTURE.md §7 item 8).
  var LIVENESS_DOT = Object.freeze(['green', 'amber', 'red']); // <90s | 90–180s | >180s
  var LIVENESS_WINDOWS = Object.freeze({
    AMBER_AFTER_S: 90,  // green below this
    RED_AFTER_S: 180    // amber up to this, red above
  });

  // §5.2 "Done sub-state" (display only, §3) — NOT a new lifecycle stage.
  var DONE_SUBSTATE = Object.freeze([
    'done·code',     // committed + local green  (done·code)
    'done·verified'  // production/contract probe passed  (done·verified)
  ]);

  // §5.2 "Notification tier" (carried). Engine mirror: cf/src/notification.js
  // `const TIERS` — the Contract-D test asserts these two are byte-equal.
  var NOTIFICATION_TIER = Object.freeze(['blocking', 'timed-fyi', 'digest']);

  // §5.2 "Hold type" (B.1 holds[].type). The umbrella over the 3 mechanisms.
  var HOLD_TYPE = Object.freeze(['gate', 'dependency', 'scheduled']);

  // §5.2 "Gate object" scope — { id, why, unblock_condition, owner, scope }.
  var GATE_SCOPE = Object.freeze(['task', 'cohort']);

  // §3 "state_confidence" — the closed set a derived status may carry. The
  // producer NEVER stamps "asserted" for activity (principle 10); the value is
  // here so a renderer can gate on the closed set rather than a bare string.
  var STATE_CONFIDENCE = Object.freeze(['derived']);

  return Object.freeze({
    ACTIVITY_STATE: ACTIVITY_STATE,
    LIVENESS_DOT: LIVENESS_DOT,
    LIVENESS_WINDOWS: LIVENESS_WINDOWS,
    DONE_SUBSTATE: DONE_SUBSTATE,
    NOTIFICATION_TIER: NOTIFICATION_TIER,
    HOLD_TYPE: HOLD_TYPE,
    GATE_SCOPE: GATE_SCOPE,
    STATE_CONFIDENCE: STATE_CONFIDENCE
  });
});
