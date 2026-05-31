# N2 deploy + live-verify runbook (claude-tools-uxg1)

> The **delivery transport** (DESIGN N §2) is built and **offline-green**. This
> runbook is the **deploy + real-device verify** that closes the §2.5 gate —
> the steps that need **Brian's Cloudflare credentials + a real phone**, which
> the implementing agent could not perform (`wrangler` was not logged in and
> there is no device/browser automation in that session). Local-green is **not**
> acceptance (the bgw/2dk lens); this runbook is.

## What was built (all committed, all offline-verified)

| Layer | File(s) | Verified offline by |
|---|---|---|
| Engine — push crypto + store + delivery | `cf/src/push.js`, dispatch in `cf/src/coordinator.js`, `cf/migrations/0007_push.sql` | `cf/test/push.spec.js` — RFC 8291 §5 **known-answer** vector (byte-for-byte) + RFC 8292 VAPID JWT verify + store + tier-keyed delivery (dry-run) + anti-drift |
| Production op routing | `cf/pages-dev/adapter.js` (`push-subscribe`/`push-unsubscribe` mapping) | adapter is dumb plumbing; ops covered by the spec |
| Web proxies | `web/functions/api/push/{subscribe,unsubscribe}.js` | mirror the frozen `inbox/respond.js` proxy discipline |
| PWA | `web/inbox/{manifest.webmanifest,sw.js,push.js,icon.svg}`, `index.html`, `inbox.css`, `web/_headers` | **deploy + device gated** (browser-only) |
| Delivery clock | `daemon/notif-delivery-poll.sh`, registration in `daemon/daemon.sh` | `daemon/test-notif-delivery.sh` |

**Transport:** Web Push (VAPID) to the installed Inbox PWA — zero new vendor,
rings the one push surface (ARCH line 283). Payload is **triage only**
(`{tldr, dossier_ref, tier, url}`) — never the §5 body (principle 2). Tier-keyed
cadence: `blocking` → one immediate push; `timed-fyi`/`digest` → the K3 daily
rollup as one push per channel group (must-protect #5).

## Step 1 — Worker secrets (engine: `coordinator-cf`)

The VAPID **private** key is in `beads-runner/.vapid-private.local` (gitignored).
The matching **public** key is already baked into `web/inbox/push.js` and is safe.

```bash
cd beads-runner/cf
echo -n 'mMqKU6xTkgDk8RJLwXym1S8UagR62CkuScP63hZmv9k' \
  | npx wrangler secret put VAPID_PRIVATE_KEY --config wrangler.production.toml
echo -n 'BFP6x3cxQPGjFJHTW3xqjW9IMDfJByLm4znvSxejYT4kgaJ59K_wcA7-tFDJsUlvPvsEHUvX6L1SNFaGJbzZA38' \
  | npx wrangler secret put VAPID_PUBLIC_KEY --config wrangler.production.toml
echo -n 'mailto:bbthechange@gmail.com' \
  | npx wrangler secret put VAPID_SUBJECT --config wrangler.production.toml
```

Without `VAPID_PUBLIC_KEY`/`VAPID_PRIVATE_KEY`, `notif-deliver` returns an honest
**503** (it never fakes a send). Leave `PUSH_DRY_RUN` unset in production.

## Step 2 — apply the D1 migration + deploy the engine

```bash
cd beads-runner/cf
npx wrangler d1 migrations apply coordinator-records --remote   # applies 0007_push.sql
npx wrangler deploy --config wrangler.production.toml            # redeploy the adapter-front Worker
```

(The DO also lazy-DDLs `push_subscriptions`/`push_deliveries`, so the migration
is belt-and-suspenders.)

## Step 3 — Pages bindings + deploy the unified app

The push proxies need the same server-side bindings the Inbox read proxy uses
(`COORDINATOR_URL`, `COORDINATOR_TOKEN`) on the **`claude-wrangler`** Pages
project — they should already be set (the Inbox already reads through them). Then:

```bash
(cd beads-runner/web && npx wrangler pages deploy . --project-name claude-wrangler)
bash beads-runner/verify-pages-deploy.sh        # MUST print mismatches=0
```

`verify-pages-deploy.sh` checks the committed bytes match the live host. New
assets (`/inbox/sw.js`, `/inbox/push.js`, `/inbox/manifest.webmanifest`,
`/inbox/icon.svg`) ship in the same deploy. If that script doesn't yet probe the
new files, also spot-check them with `curl -sI https://<host>/inbox/sw.js`
(expect `200` + a JS content-type) and `/inbox/manifest.webmanifest` (expect
`application/manifest+json`).

## Step 4 — LIVE-VERIFY on a real device (the §2.5 gate)

1. On the iPhone, open the Inbox URL in Safari → **Share → Add to Home Screen**
   (iOS Web Push requires the *installed* PWA, 16.4+).
2. Open the installed app → tap **🔔 Enable notifications** (top of the Inbox) →
   **Allow**. (This stores a `PushSubscription` via `/api/push/subscribe`.)
   - Sanity: `curl` the engine `push-list` op (native dialect, with the bearer)
     should report `count >= 1`.
3. Fire a real **blocking** notification end-to-end. Easiest: trigger any
   blocking dossier (e.g. an `ask-brian` dossier, or any `new_dossier`). Within
   one delivery-poll interval (~30s, or run `notif-deliver blocking` once by
   hand against the engine) the phone should buzz with **"Beads — a decision
   needs you"** + the TL;DR. Tap it → it deep-links to `/inbox#/d/<dossier_ref>`.
4. Digest: accumulate a couple of `timed-fyi` notifications, then run
   `notif-deliver digest` (or wait for the daily sweep) → expect **one** push
   per channel group, never one-per-notification.

Only when a real push lands on the real installed PWA **and**
`verify-pages-deploy.sh` is `mismatches=0` is the §2.5 gate met and uxg1 closeable.

## Notes / known limits handed off

- **iOS icon:** the manifest uses a scalable `icon.svg`. If iOS install is fussy
  about the home-screen icon, add a 180×180 + 192/512 PNG and reference them in
  the manifest + `apple-touch-icon` (cosmetic; does not affect push).
- **Blocking latency** is bounded by the delivery-poll cadence
  (`BEADS_DAEMON_NOTIF_DELIVERY_POLL_INTERVAL`, default 30s) — near-immediate,
  not literally at dispatch. Tighten the interval if needed; it's [free].
- **Reversibility:** the opaque §4.3 `channel` keeps an alternate transport
  (`email:`/`telegram:`/`pushover:`) a pure plug-in in `notif-deliver` — no
  schema change (DESIGN N §2.4).
