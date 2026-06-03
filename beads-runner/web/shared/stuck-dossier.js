/* beads-runner/web/shared/stuck-dossier.js — claude-tools-x949.
 *
 * THE single builder for the I4 "Escalate to decision" worker_stuck dossier
 * generation-input (DESIGN I §4). Extracted so there is ONE template, imported
 * by BOTH:
 *   • the live proxy  web/functions/api/control/escalate.js  (builds the gi it
 *     POSTs to the engine's dossier-generate op), and
 *   • the offline §5 guard  cf/test/escalate-dossier.spec.js  (runs the gi
 *     through the REAL validateDossier under the workers pool).
 *
 * WHY (the drift this closes): before this extraction the spec validated a
 * HAND-COPIED MIRROR of the proxy's inline gi, and lib/test-agent-action-proxy.sh
 * drove the real proxy with a STUBBED fetch (so its gi never reached
 * validateDossier). If the proxy template drifted out of §5, both guards stayed
 * green and only live-verify caught it. One source ⇒ the spec now exercises
 * exactly what the proxy ships, so a §5 drift reds the offline gate.
 *
 * Pure builder: no DOM, no network, no secret (the bearer lives server-side in
 * escalate.js). ESM — like web/functions/api/intake/_presets-catalog.js — so
 * wrangler bundles it into the function, vitest imports it, and node ESM
 * resolves it in the proxy unit test. Inputs are already-trimmed strings; the
 * proxy owns request parsing/validation.
 */

// A minimal §5-valid pick-option (empty consequence_block — the engine's
// author() stamps cb_schema_version). v1 escalate SURFACES the choice; it does
// not auto-apply a work mutation (that is a separate control→work wiring).
function opt(option_id, label, blast_radius) {
  return {
    option_id, label, blast_radius,
    consequence_block: { creates: [], unblocks: [], labels: [], status_changes: [] }
  };
}

// Build the §5-valid worker_stuck / tier:`blocking` generation-input for one
// stuck bead. `beadRef` is required (the one client-supplied identity); the rest
// are optional context the proxy passes through. The `id` is stable per bead so
// re-escalating the same task dedups (§7.4 keys on principal+bead_ref) rather
// than piling up duplicate cards.
export function buildStuckGi({ beadRef, projectRef, title, reason } = {}) {
  const what = title ? (beadRef + ' — ' + title) : beadRef;
  return {
    id: 'stuck-' + beadRef,
    kind: 'decide',
    trigger: 'worker_stuck',
    bead_ref: beadRef,
    tier: 'blocking',
    timer_fire_at: null,
    source: {
      tldr: 'A worker on ' + what + ' looks stuck — what should I do?',
      ask: 'How should this stuck task proceed?',
      sections: [{
        heading: 'Why this surfaced',
        prose: 'The Activity view flagged this worker as maybe-stuck (no progress past the soft window)'
          + (reason ? ('. Note: ' + reason) : '.')
          + ' Escalated from the Activity stuck-actions so the decision lands in the Inbox.'
      }],
      diagrams: [],
      full_detail: 'This is a surfacing-only escalation (DESIGN I §4): the four options below are recorded for the audit trail; act on the chosen one from the Activity/Board controls. Nudge keeps the worker alive; Kill+retry re-dispatches a fresh worker on the same bead; Kill+Gate stops re-dispatch until a gate lifts.'
    },
    items: [{
      id: 'stuck-decision',
      kind: 'pick-option',
      framing: {
        ask: 'What should happen to ' + what + '?',
        why: 'A stuck worker burns budget; the four host actions have different blast radii.'
      },
      context_anchor: {
        where: 'Activity view — workspace ' + (projectRef || '(unknown)') + ', worker on ' + beadRef,
        expansion: 'Flagged maybe-stuck (silence past the soft window). The watchdog will eventually kill it on idle; this asks for an explicit decision first.'
      },
      reversible: 'Reversible — nudge/escalate are pure; kill+retry loses in-flight work but the bead is intact; kill+gate is undone by lifting the gate.',
      options: [
        opt('nudge', 'Nudge (keep alive)', 'extends the watchdog grace one window; no kill'),
        opt('kill-retry', 'Kill + retry', 'terminates the worker; the loop re-dispatches a fresh worker on the same bead'),
        opt('kill-gate', 'Kill + Gate', 'terminates AND gates the bead so it stops being retried until the gate lifts'),
        opt('abandon', 'Leave it / decide later', 'no action now; revisit')
      ],
      recommendation: {
        value: 'kill-retry',
        why: 'A fresh context window most often clears a transient stall; gate only if it is structurally blocked.'
      }
    }]
  };
}
