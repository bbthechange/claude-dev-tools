# Context: The notification / push delivery pipeline (engine → phone)

> One-liner: the THREAD that turns a "§4.3 Notification that pages no one"
> into a real buzz on Brian's installed Inbox PWA. A cross-tier flow — trigger
> (engine) → Web-Push transport (engine) → daemon delivery clock → service
> worker on the phone. A notification is "done" only when it lands on the
> phone, never when the trigger record is written.

**Read this doc when** your task touches: a notification *trigger* (the §10.2
catalog), the *delivery* path to the phone (Web Push / VAPID), the subscribe /
unsubscribe glue, the deliver-once ledger, the digest cadence, or the
`notif-delivery-poll` daemon sweep. This is a **flow doc**, not exclusive file
ownership — it ties together notification slices that live in four tiers.

**Owns / scope (the flow this doc threads):**
- Engine triggers — `cf/src/notification.js` (the §4.3 record + §10.2
  `notif-fire` catalog + K3 digest engine) and the bash oracle `lib/notification.sh`
  + `lib/timed-fyi.sh` (the timed-fyi auto-proceed window that produces digest-tier work).
- Engine DELIVERY transport — `cf/src/push.js` (subscription store + deliver-once
  ledger + RFC 8291/8292 Web-Push crypto + `notif-deliver` sweep).
- Daemon delivery clock — `daemon/notif-delivery-poll.sh` (rings `notif-deliver`).
- Phone PWA — `web/inbox/{push.js,sw.js,manifest.webmanifest}` + the Pages
  proxies `web/functions/api/push/{subscribe,unsubscribe}.js`.

**Not here (go to the right doc):**
- The engine as a subsystem (substrate, `_writeRecord`, op-dispatch, work-snapshot)
  → `engine-cloudflare.md`. `notification.js`/`push.js` are *part* of that engine;
  this doc is only their notification slice.
- The Inbox *rendering* of the dossier the push deep-links to (Mermaid/dossier
  tolerance, inbox verbs, the same service worker as a PWA) → `web-inbox.md`.
- The daemon as a whole (runner supervision, desired-state poll, registry) →
  `daemon.md`. This doc covers only the delivery-poll sweep it hosts.
- The bash library layer in general (coordinator.sh oracle, HTTP transport) →
  `lib-shared.md`.

---

## Mental model

Notifications were the canonical **"wired but not delivered"** gap — the N-track.
Trace it in two halves:

1. **N1 wired the TRIGGERS, and nothing reached the phone.** A trigger fires
   `notif-fire <trigger> <dossier_id> <scope>` → the engine emits **one terse
   §4.3 Notification per dossier** (`notifFire`, `notification.js:324`), mirrors the
   dossier's §4.1 `tier ∈ {blocking, timed-fyi, digest}`, and for a batchable
   trigger stamps an opaque `channel` so the K3 rollup can group it. The
   `dispatched` latch flips `false→true` and **sends nothing** — by design
   (creation≠dispatch, `notification.js:31-48`). So the attention router collapsed
   to "Brian must remember to open the Inbox."

2. **N2 (claude-tools-uxg1) added DELIVERY.** Three parts in `cf/src/push.js`:
   - a **transient push-subscription store** (`push_subscriptions`) — A.2 storage
     class, **NOT a §4 record**, its own sibling D1 namespace (the
     `forensic.js`/`capacity.js` precedent). One row per browser endpoint.
   - a **deliver-once LEDGER** (`push_deliveries`, keyed by notif id, `INSERT OR
     IGNORE`) — also transient, also NOT a §4 record. This is the real
     "pushed-to-phone-once" guard, *because* the §4.3 `dispatched` latch is
     overloaded across producers and is NOT reliable for that (`push.js:28-36`).
   - the **`notif-deliver` sweep** — reads pending notifications + the dossier's
     §5.1 TL;DR and POSTs a real **Web Push** (RFC 8291 aes128gcm + RFC 8292 VAPID)
     to every stored subscription. Payload is **triage only**:
     `{ tldr, dossier_ref, tier, url }` → "Decision: <TL;DR> — tap to open." It
     **never carries the §5 body** (principle 2, the closed-set discipline extended
     to the wire).

3. **The daemon is the clock.** `daemon/notif-delivery-poll.sh` does no crypto and
   holds no key — it just *rings* `notif-deliver` on the singleton Coordinator on a
   cadence (a Mac that already polls the engine, keeping the VAPID private key
   server-side). Two cadences: `blocking` sweep ~30s (near-immediate), `digest`
   sweep ~daily.

4. **Tier drives cadence.** `blocking` → ONE immediate individual push.
   `timed-fyi`/`digest` → never individual; folded into the **K3 daily rollup**
   (N pending in a channel → 1 push, never N — must-protect #5). N2 reuses the K3
   batching spine VERBATIM (`groupDigests`/`digestCopy` in `notification.js`) and
   adds nothing to it — it is the third consumer of that shared spine.

5. **The phone end.** The installed Inbox PWA registers `sw.js`; on a `push` event
   the service worker shows a triage-only system notification; `notificationclick`
   focuses/opens an Inbox tab at the deep link (`/inbox#/d/<dossier_ref>` for a
   decision, `/inbox` for a digest).

## Key files

| File | Role |
|---|---|
| `cf/src/notification.js` | The §4.3 Notification record + the §10.2 `notif-fire` trigger catalog (`notifFire`, `notifTriggers`) + the **K3 digest engine** (`groupDigests`, `digestCopy`, `DIGEST_CADENCE`). N2 reuses the digest engine; does not edit it. |
| `cf/src/push.js` | The N2 DELIVERY module: `PUSH_OPS` (`push-subscribe`/`push-unsubscribe`/`push-list`/`notif-deliver`), the two transient tables, `handlePushOp`, `deliverBlocking`/`deliverDigest`, Web-Push crypto (`b64urlToBytes`, VAPID JWT), 404/410 endpoint pruning. |
| `lib/notification.sh` | The bash oracle for §4.3 (`no_emit`/`no_dispatch`/`no_for_generation`) — the differential twin of `notification.js`. Creation≠dispatch, one-per-dossier, closed-set validation. |
| `lib/timed-fyi.sh` | §2.2 timed-fyi auto-proceed timer + the S-6 fire-on-next-poll backstop. Produces the timed-fyi/digest-tier flow that the digest cadence batches. |
| `daemon/notif-delivery-poll.sh` | The delivery clock: `daemon_notif_delivery_poll_once` (blocking) + `daemon_notif_digest_sweep_once` (digest). Resolves workspace[0]'s coordinator_url + keychain bearer, sources `co-http-transport.sh`, calls `co_request notif-deliver <mode>`. Always returns 0. Wired in `daemon/daemon.sh:138,366,380`. |
| `web/inbox/push.js` | Browser subscribe glue: registers `sw.js`, captures the Notification permission + `PushSubscription`, POSTs it to `/api/push/subscribe`. Holds the **public** VAPID key (safe); the toggle button is `#notif-toggle`. |
| `web/inbox/sw.js` | The service worker. Two handlers only — `push` (render triage notification) and `notificationclick` (deep-link). **No fetch/offline cache** (the Inbox must never serve a stale projection, S-1). |
| `web/inbox/manifest.webmanifest` | Makes the Inbox installable (`scope:/inbox/`) — iOS 16.4+ Web Push requires the *installed* PWA. |
| `web/functions/api/push/{subscribe,unsubscribe}.js` | Same-origin Pages proxies. Browser bears no secret; proxy hard-codes the op, attaches the server bearer, calls the Coordinator. Mirror the frozen `inbox/respond.js` discipline. |
| `cf/migrations/0007_push.sql` | Deploy-path DDL for the two transient tables (the DO also lazy-DDLs them; the migration is belt-and-suspenders). |

## Contracts & invariants (don't break these)

- **A notification is "done" when it lands on the phone — never when the trigger
  record is written.** This is the whole point of the N-track and the bgw/2dk
  lens. Local-green + committed is not acceptance; a real push on the real
  installed PWA + `verify-pages-deploy.sh mismatches=0` is.
- **The payload is TRIAGE ONLY** (`{tldr, dossier_ref, tier, url}`). The §5 dossier
  body NEVER crosses the wire (UX principle 2). `sw.js` shows only the TL;DR + a
  deep link. Do not widen the payload to carry content. This is pinned ACROSS every
  producer by the cross-producer guard `cf/src/notif-triage.js` +
  `cf/test/notif-triage.spec.js` (claude-tools-n49j): one shared `triageViolations`
  assertion (an independent, hardcoded triage vocabulary — NOT derived from
  `CLOSED_43`, so it also red-flags a §4.3 set that widened to admit content) run
  against EVERY §10.2 trigger's emitted §4.3 record AND both wire payloads
  (`blockingWirePayload`/`digestWirePayload`, now the single exported builders in
  push.js). A canary in the §5 body (never the TL;DR) proves no producer copies the
  body into an allowed field — including a content-bearing `scope`→`channel`.
- **The subscription store and the delivery ledger are transient (A.2), NOT §4
  records.** They are absent from the §4 registry (`schema.js`) and must stay
  absent — N2 makes **no INTERFACE §4.3 change**. The §4.3 record is untouched by
  delivery.
- **`push_deliveries` is the idempotency guard, not `dispatched`.** A notification
  is pushed at most once (immediate OR digest) via `INSERT OR IGNORE` on notif id.
  Do not re-derive "pushed once" from the overloaded §4.3 `dispatched` latch.
- **Tier-keyed cadence is load-bearing (must-protect #5).** `blocking` → one
  immediate. `timed-fyi`/`digest` → the K3 rollup, N→1 per channel, never N pushes.
  Never give a digest-tier notification an individual push.
- **VAPID private key is server-side only.** It is a Worker secret
  (`VAPID_PRIVATE_KEY`), never in the repo; the public half is baked into
  `web/inbox/push.js` (safe — it is the `applicationServerKey`). Rotate both in
  lockstep. Without the keys, `notif-deliver` returns an honest **503** — it never
  fakes a send.
- **One auth chokepoint.** Push ops go through the same §9.1 Worker
  `authenticate→principal`; a no/invalid-token `push-*` op is 401'd before
  `push.js` runs (writes nothing, sends nothing). No second auth path.
- **`channel` stays opaque ⇒ a second transport is a pure add.** An alternate/extra
  transport (`email:`/`telegram:`/`pushover:`) plugs into `notif-deliver` with no
  schema change (DESIGN N §2.4). `push.js` is the single place it slots in.

## Common changes (recipes)

**Adding/changing a notification TRIGGER** (a §10.2 catalog entry → tier →
channel): edit the trigger catalog in `cf/src/notification.js` (`notifTriggers`,
`notifFire`) AND the bash oracle `lib/notification.sh` in lockstep — they are
differentially bound (`run-differential.sh`). The tier you map to decides the
cadence automatically; do not also build a delivery path. The cross-producer
triage guard (`cf/test/notif-triage.spec.js`) auto-sweeps the new trigger — keep
its channel `scope` a SHORT opaque tag, never dossier content, or the guard fails.

**Changing the delivery transport / payload / cadence:** edit `cf/src/push.js`
(`deliverBlocking`/`deliverDigest`/the crypto). Pin behavior in
`cf/test/push.spec.js` (it carries the RFC 8291 §5 known-answer vector + a VAPID
JWT verify + the tier-keyed dry-run). Keep the payload triage-only.

**Adding a push op:** follow the engine's add-an-op checklist (module guard +
Pages proxy + the `cf/pages-dev/adapter.js` mapping — the layer 2dk forgot — see
`engine-cloudflare.md`). The four `PUSH_OPS` already wire `push-subscribe`/
`push-unsubscribe`/`push-list`/`notif-deliver`.

**Gates before close (this flow needs BOTH the offline gate AND live-verify):**
```bash
bash beads-runner/run-tests.sh              # offline gate (cf push.spec + daemon test-notif-delivery.sh)
(cd beads-runner/web && npx wrangler pages deploy . --project-name claude-wrangler)
bash beads-runner/verify-pages-deploy.sh    # MUST print mismatches=0
```
Plus the engine deploy (VAPID secrets + the 0007 migration) and the **device gate**
(DESIGN N §2.5, `design/notifications-N2-deploy.md` Step 4): install the Inbox PWA,
tap 🔔 Enable, `push-list` count ≥ 1, fire a real blocking dossier, confirm the
phone buzzes "Beads — a decision needs you" and the tap deep-links.

## Gotchas / scars

- **"Wired but not live" is the N-track's whole reason for existing.** N1 wired
  triggers and shipped offline-green, but `dispatched` paged no one for an entire
  track. The lesson is baked into the first invariant above: close on the phone,
  not the record.
- **`dispatched` is a trap as a "pushed once" flag.** It is flipped by multiple
  producers (`notifFire` routes timed-fyi to `dispatched=true` but leaves blocking
  PENDING; ask-brian's `emit_and_dispatch` flips it; Flow-F flips it). The delivery
  ledger exists precisely because of this overload (`push.js:28-36`).
- **The service worker is deliberately NOT a cache.** No fetch handler — the Inbox
  reads live liveness/decision state and must never serve a stale projection (S-1).
  Do not add offline caching to `sw.js`.
- **The pages-dev adapter is the forgotten layer.** A `push-*` op that works in
  vitest but 404s on the phone is almost always a missing `cf/pages-dev/adapter.js`
  mapping (the 2dk scar).
- **iOS Web Push needs the *installed* PWA (16.4+).** Subscribing from a Safari tab
  won't deliver; the manifest + Add-to-Home-Screen is mandatory, not cosmetic.
- **503 from `notif-deliver` is honest, not a bug** — VAPID secrets aren't set on
  the Worker. The daemon logs it and retries next cadence (the ledger makes retry
  safe); it never aborts the daemon loop. Blocking latency is bounded by the poll
  interval (~30s, `BEADS_DAEMON_NOTIF_DELIVERY_POLL_INTERVAL`), not literally at dispatch.

## Go deeper

- `beads-runner/design/notifications.md` — DESIGN N, the authoritative design
  (N1 trigger catalog / N2 delivery / N3 ready-to-pair; the one-paragraph shape +
  the flow diagram).
- `beads-runner/design/notifications-N2-deploy.md` — the deploy + real-device
  live-verify runbook (VAPID secrets, the 0007 migration, the §2.5 device gate).
- `beads-runner/UX-DESIGN-V2.md` §10 — the trigger catalog / batching contract.
- `beads-runner/UX-V2-ARCHITECTURE.md` — contracts D.2 (notification tiers), A.2
  (storage class), must-protect #5 (batching is load-bearing).
- `cf/test/push.spec.js` + `daemon/test-notif-delivery.sh` — the offline proofs.
- `cf/test/notif-triage.spec.js` — the cross-producer triage-only guard
  (claude-tools-n49j): every §10.2 trigger + both wire payloads through one
  `triageViolations` assertion; the canary method catches a `scope`→`channel` leak.

## Keeping this doc current

When you finish a task in this flow, append anything a future agent will need and
didn't find here: a new trigger pattern, a new transport, a changed payload field,
a moved file, a fresh scar. This is a **thin thread** across four tiers — keep it
that way; it earns its keep only if agents read all of it, and the tier-internals
belong in the sibling docs (`engine-cloudflare.md`, `web-inbox.md`, `daemon.md`,
`lib-shared.md`), not here. Delete lines that have gone stale. Last substantive
update: 2026-05-31.
