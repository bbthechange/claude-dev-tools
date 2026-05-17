# CF.1 — Coordinator engine substrate (Cloudflare realization)

beads: **claude-tools-7g0.1** · Epic: claude-tools-8h4 · Parent: claude-tools-7g0 (CF-BUILD)

THE foundation child. Every other CF child (CF.2…CF.11) binds onto this
substrate. **Build + LOCAL emulation only** — `wrangler dev` / vitest-pool-workers
run the whole thing under workerd+miniflare with **NO Cloudflare account**. The
real `wrangler deploy` + hosted provisioning is the separate **a53 DEPLOY GATE**,
not this child.

## What this is

The CF realization of the bash `lib/coordinator.sh` **substrate** — the same
INTERFACE.md v1 §-clauses, the Appendix-A (non-normative) primitive map:

| INTERFACE.md v1 | bash oracle | CF realization (here) |
|---|---|---|
| §2.1 small strongly-consistent store | `co__store_put`/`co__store_get` + `co__with_lock` | D1 (`records`), writes serialised by the **singleton** single-threaded Coordinator DO — single-writer-per-`(type,id)` **by construction** (the AD1 payoff; replaces the hand-rolled bash lock) |
| §2.2 durable one-shot timer (surface only) | `co__timer_arm/due/ack` | DO `setAlarm()` capability + the `timer-due` poll-fallback = the **S-6** "missed fire ⇒ fire-on-next-poll" backstop |
| §2.3 authed endpoint + §9.1 the ONE `authenticate→principal` | `co_authenticate` + `co_request` | `src/index.js` Worker middleware — exactly one chokepoint, 401 **before** any DO contact (⇒ before any §4 write) |
| §2.4 deliver-desired-state (transport) | `co__poll` | DO `poll` — returns stored `desired` + lease; **no** liveness, **no** reconcile |
| §4 store owner + §0.3 reject-higher + §9.1 stamp | `co__schema_version` / `validateRecord` precedence | `src/schema.js` + `opPut` — same reject precedence, principal stamped over any use-site literal (C7) |

`§9.1` principal resolves to the **frozen** `PRINCIPAL_V1 = "brian"` (§0.5);
the C4 seam is **captured, not enforced** (`last_desired_actor` recorded, all
actors authorised equally — **no** UI/agent split, **no** §0.C asymmetry).

**Deliberately absent (MUST-NOT-TOUCH siblings):** lease arbitration/fencing
(CF.2), reconcile semantics + §4.5 projection + S-1 liveness (CF.3), capacity
(CF.4), forensic store (CF.5), Dossier body/items + `fire(dossier_id)` +
per-Item latch (CF.6/CF.7), Notification dispatch (CF.9), Pages proxy wiring
(CF.10). This is the substrate and nothing else.

## Run it locally (no account)

```bash
cd beads-runner/cf
npm install          # first run only
./run-differential.sh   # the full CF.1 EXIT proof (behavioral + §0.C source)
# or, individually:
npm test             # vitest-pool-workers behavioral conformance
npx wrangler dev     # stand up Worker + Coordinator DO + local D1 by hand
```

`npx wrangler dev` boots the Worker + Coordinator DO + a local D1 (miniflare
SQLite, no account). The DO applies its DDL lazily + idempotently, so no manual
`d1 migrations apply` is needed locally; `migrations/0001_init.sql` is the
canonical schema for the a53 hosted path.

## Differential oracle

`lib/coordinator.sh` (substrate: §9.1 chokepoint, §0.3 reject-higher,
principal-stamp, get/put §4 round-trip) **+ `lib/test-coordinator.sh`**.
`test/coordinator.spec.js` re-implements every EXIT-1..5 + §2.4 clause of
`test-coordinator.sh` against the real CF engine; `run-differential.sh` adds
the §0.C "no actor-discriminating branch" source assertion with the **same
grep** `test-coordinator.sh` applies to the bash lib. The CF engine MUST
exhibit the SAME INTERFACE.md v1 behavior — it is not a re-spec.

## Anti-drift

Binds **FROZEN** INTERFACE.md v1 §2.1–2.4 / §4 / §9.1 / §0.3 / Appendix A. An
interface gap/contradiction is a **BLOCKING §11 escalation** (reopen
claude-tools-65z, amend + bump + re-freeze) — never a local divergence, never
an INTERFACE edit. None was needed: the bash oracle + Appendix A fully
anticipate this realization. No CF forward gate (CF.2/CF.8/CF.11) is flipped
here.
