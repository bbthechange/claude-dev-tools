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

---

# CF.6 — Dossier/Item Durable Object (THE AD1 PAYOFF)

beads: **claude-tools-7g0.6** · Epic: claude-tools-8h4 · Parent: claude-tools-7g0
(CF-BUILD) · Depends on **CF.1**

The CF realization of the bash **T5 trio** — `lib/dossier.sh` (T5.1
§4.1/§4.1.1 + state machine + the per-Item latch), `lib/dossier-gen.sh` (T5.2
§5 sole producer) and `lib/consequence.sh` (T5.3 §5.3 apply + §7.4 per-Item +
§5.2.2 routing) — layered onto the CF.1 substrate as `src/dossier.js`
(mirroring how those bash libs source `coordinator.sh` and consume its public
surface). The CF.1 ops/switch are **byte-unchanged** (additive guard only;
CF.1's differential stays GREEN).

| INTERFACE.md v1 | bash oracle | CF realization (here) |
|---|---|---|
| §4.1 envelope + §4.1.1 per-Item state · §0.3 reject-higher (write **and** read) | `dossier.sh` `do_dossier_validate`/`do_dossier_get`/`do_dossier_put` | `validateEnvelope` + `getDossier`/`putDossier`, persisting **THROUGH** CF.1's ONE write path `_writeRecord` (§0.3 re-enforced, §9.1 principal stamped) — binds the §4.1 `dossier` type, **adds NO §4 record type** |
| per-Item state machine (open→answered→applied \| open→expired) | `do_item_state_check`/`do_item_set_state` | `stateCheck` + `item-set-state` op |
| §7.4 per-Item `consequence_applied` latch — false→true **once** | `do_item_latch` + the bash `mkdir` per-dossier advisory lock | `item-latch` + **`co._serialize`**: the singleton single-threaded DO runs the read→decide→write as ONE critical section — exactly-once **BY CONSTRUCTION**, **not** a ported lock/CAS (Appendix A; the AD1 payoff) |
| §5.1 body (4 tiers) · §5.2 items · §5.2.1 profiles · §5.3 ConsequenceBlock | `dossier-gen.sh` `dg__validate_*`/`dg__author`/`dg_generate`/`dg_from_worker_ask` | `validateBody`/`validateItem`/`validateDossier`/`author` + `dossier-generate`/`dossier-from-worker-ask` ops — profiles **emergent**, ONE validator, NO schema branch |
| §5.2.2 deterministic-vs-reconciler routing · §5.3 apply (control→work) | `consequence.sh` `do__is_deterministic`/`do__select_cb`/`do__apply_cb`/`do__emit_followup`/`do_item_apply` | `isDeterministic`/`selectCb`/`applyCb`/`emitFollowup` + the **`item-apply`** entrypoint (CF.7's timer + the CF.10 Pages `respond.js` proxy hit this) |
| §5.3 work plane (`bd`) | the bash tests' PATH-injected logging `bd` fake → `$BD_LOG` | the `work_plane_ops` D1 table — same space-joined arg shape, same `bd-fake-N` create-id scheme (a Worker cannot exec `bd`; documented realisation boundary, **not** a §4 record) |

**Deliberately absent (MUST-NOT-TOUCH siblings):** the dossier-level
`task_ref` dedup (one fork ⇒ one Dossier) is **CF.8**'s DISTINCT
dossier-level key — CF.6 is the **per-Item layer only**. The §2.2
`fire(dossier_id)` timer + S-6 poll-fallback is **CF.7** (CF.6 EXPOSES the
idempotent `item-apply` entrypoint; it owns no timer). Notification = CF.9.
§5 RENDERING (Inbox HTML) = CF.10. The §9.1 chokepoint stays the ONE Worker
step (CF.1) — no second auth path is added (C4).

## Run it locally (no account)

```bash
cd beads-runner/cf
npm test             # runs BOTH specs: CF.1 (coordinator) + CF.6 (dossier)
```

## Differential oracle

`lib/dossier.sh` + `lib/dossier-gen.sh` + `lib/consequence.sh` **+ their
`lib/test-*.sh`**. `test/dossier.spec.js` mirrors every CF.6-owned EXIT clause
of `test-dossier.sh` / `test-dossier-gen.sh` / `test-consequence.sh` against
the real CF engine — **including the 8-way concurrent race ⇒ §5.3 applied
EXACTLY ONCE** that `test-consequence.sh` asserts. PRIMITIVE 2 (the
dossier-level `task_ref` dedup) clauses are **excluded** — that is CF.8's
distinct key, not this child. The CF engine MUST exhibit the SAME behaviour;
it is not a re-spec.

## Anti-drift

Binds **FROZEN** INTERFACE.md v1 §4.1/§4.1.1/§5.1/§5.2/§5.2.1/§5.2.2/§5.3/§7.4
+ Appendix A. The §5 sub-versions (`dossier_schema_version`,
`cb_schema_version`) track the ONE bound source (`schema.js schemaVersion`),
never a competing literal (§0.5). **No §4 record type added** (asserted: a
`dossier_dedup`/`dossier_fu`/`dossier_gen` put is `unknown_type`); CF.1
capabilities still EXACTLY four §2 lines, no CF.6 op advertised. Per-Item
idempotency is **BY CONSTRUCTION** of the single-threaded DO, not a ported
bash latch. No INTERFACE edit was needed: the bash oracle + Appendix A fully
anticipate this realization. No CF forward gate is flipped here.
