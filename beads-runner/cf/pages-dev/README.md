# CF.10 — Pages local serve (claude-tools-7g0.10)

beads: **claude-tools-7g0.10** · Epic: claude-tools-8h4 · Parent: claude-tools-7g0
(CF-BUILD) · Depends on **CF.3** (§4.5 work-snapshot), **CF.5** (forensic
fetch/dismiss), **CF.6** (§4 dossier read + the item-apply entrypoint)

Stands up the **already-written, FROZEN** Pages proxies (`web/board` +
`web/inbox` `/functions/api/*.js`, T6a/T6b) **locally** against the **FROZEN**
CF.1 Coordinator engine — `wrangler pages dev` + `wrangler dev`, workerd +
miniflare, **NO Cloudflare account**. Production Pages deploy / off-network /
asleep proof is the **separate a53 DEPLOY GATE**, EXCLUDED from this parent.

## What this child OWNS — and what it does NOT touch

This is **the local wiring, not the proxy logic**. Nothing frozen is edited:

| | |
|---|---|
| **Untouched** | the T6a/T6b proxies (`web/**`), the CF.1/CF.3/CF.5/CF.6 engine (`cf/src/**`, `cf/wrangler.toml`), `INTERFACE.md` |
| **Added** (CF.10) | `pages-dev/adapter.js`, `pages-dev/seed.mjs`, `pages-dev/serve.sh`, `pages-dev/verify.sh`, `cf/wrangler.pages-dev.toml` |

### The one real seam: two NON-NORMATIVE transport dialects

The frozen proxies speak `GET|POST {COORDINATOR_URL}/request?op=<op>&…` (op +
params in the query / a named JSON body). The frozen CF.1 Worker speaks
`POST / {op,args:[…]}` (positional). **Both framings are Appendix-A
NON-NORMATIVE** (§0.2; the T6b debrief explicitly recorded the
`/request?op=` shape as "untested live"). Reconciling two sibling
realizations' non-normative HTTP framing is **realization wiring**, *not* an
INTERFACE.md gap — so **no `claude-tools-65z` escalation, no INTERFACE edit,
no proxy/engine rewrite**.

`adapter.js` is that wiring: a thin re-frame in **front of** the byte-unchanged
`../src/index.js` Worker (which it `import`s, and whose `Coordinator` DO class
it re-exports — the **same** single-threaded singleton; AD1 intact). It:

- maps each frozen `?op=` to the engine's positional `args` **verbatim from
  what the proxy transmits** (the `co_request <bearer> <op> <args…>` order);
- **never chooses an op** (read from the proxy's hard-coded `?op=`; an unmapped
  op is a 400, never a guess);
- **copies the `Authorization` header THROUGH untouched** — it never reads,
  holds, injects, or fabricates the bearer. The **§9.1 chokepoint stays the
  FROZEN Worker's `authenticate()`**: a credential-less `/request` is rejected
  **401 before any §4 write**, exactly as a native hit is. The client bears no
  secret (§9.2); `COORDINATOR_TOKEN` is a **server-side pages binding** only.

So `COORDINATOR_URL` points at **the local CF Worker** — this module *is* that
Worker, with a non-normative REST front in front of the unmodified `fetch()`.

## Run it locally (no account)

```bash
cd beads-runner/cf
npm install                       # first run only (CF.1 devDeps incl. wrangler)

# headless EXIT proof (boots all 3, seeds, drives the proxies e2e, tears down):
bash pages-dev/verify.sh

# OR the human/demo serve (stays up; open the URLs it prints):
bash pages-dev/serve.sh
```

Ports default to adapter `8787`, Board `8788`, Inbox `8789`
(`CF10_ADAPTER_PORT` / `CF10_BOARD_PORT` / `CF10_INBOX_PORT` to override).

## EXIT criteria (asserted by `verify.sh`)

1. `wrangler pages dev` serves Board + Inbox locally; **Board renders the live
   §4.5 projection**; the **WAITING-ON-YOU lane shows a partly-answered
   dossier** (2 items; answer one ⇒ the lane keeps showing it at 1 open, AD7).
2. Inbox loads a Dossier (`dossier.js` op `get`) and submits **ONE per-Item
   response** (`respond.js` op `item-apply`) end-to-end; a **double-tap of the
   same Item is exactly-once** (`applied_at` unchanged — the §7.4 latch) —
   behaviour-identical to `lib/test-inbox.sh` / `lib/test-board.sh` against the
   bash oracle.
3. `forensic.js` fetch/dismiss is **authed-only via the proxy**; the shipped
   assets hold no token and a credential-less `/request` is 401 (§9.1).
4. **No proxy/engine/INTERFACE edit**; stops at locally-green (no prod deploy).

## Differential oracle

`lib/test-board.sh` + `lib/test-inbox.sh` + the frozen proxies' `?op=`
contracts. The proxies' ops here reach the **real CF engine** and round-trip
identically to `co_request work-snapshot` / `get dossier` / `item-apply` /
`forensic-fetch` / `forensic-dismiss` — same INTERFACE.md v1 §4.5 / §5 / §5.2.2
/ §7.4 / §9.1 / §9.2 / §10.3 behaviour, not a re-spec.

## Anti-drift

Binds **FROZEN** INTERFACE.md v1 §9.1/§9.2/§2.3/§4.5/§5.2/§10.3 + the frozen
proxy op contracts. No INTERFACE edit was needed (§0.2 makes the transport
non-normative; the bash oracle + Appendix A fully anticipate this serve). No
CF forward gate is flipped here — that is CF.11 (the differential conformance
rig) and the a53 deploy gate.
