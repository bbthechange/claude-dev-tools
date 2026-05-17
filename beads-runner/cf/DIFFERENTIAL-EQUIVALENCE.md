# CF.11 — Differential Equivalence Report

beads: **claude-tools-7g0.11** · Epic: claude-tools-8h4 · Parent: claude-tools-7g0
(CF-BUILD) · seam **(e)** — the integration/verification child

This report is the EXIT-criterion-3 artifact: it shows **every ported surface
behaves identically to its bash oracle + `lib/test-*.sh` on the bound
§-clauses, with zero unexplained divergence**, and that the **4 forward gates
flip GREEN against the REAL CF engine**.

> **System under test:** the real CF engine — Worker → §9.1 chokepoint →
> singleton single-threaded Coordinator DO → D1 — on the SAME
> workerd+miniflare runtime `wrangler dev` / `wrangler pages dev` use, with
> **NO Cloudflare account**.
> **Differential oracle (FROZEN):** `lib/coordinator.sh` & siblings + the full
> `lib/test-*.sh` suite + `conformance/run-conformance.sh` +
> `conformance/assertions/bc-*.sh`.
> **Anti-drift:** CF.11 adapts the DRIVER to target the CF engine. It NEVER
> edits `INTERFACE.md` or a conformance assertion to make a gate pass. An
> interface gap is a BLOCKING §11 escalation (reopen `claude-tools-65z`).

Run it: `bash beads-runner/cf/run-differential-cf11.sh`
(stops at locally-green; the real deploy + the §0.B off-network/asleep proof
are the **a53 DEPLOY GATE**, EXCLUDED).

## How equivalence is established (not asserted)

Each sibling CF.2..CF.9 added a `cf/test/<slice>.spec.js` that **mirrors its
`lib/test-*.sh` oracle clause-for-clause** and drives **the real engine** via
`SELF.fetch` (not a mock); per-file isolated storage is the bash test's
fresh-`mktemp`-store analogue. `npm test` (vitest-pool-workers) runs all of
them; a spec ends `expect(FAIL …).toBe(0)` so any divergent clause fails the
file. CF.1's `run-differential.sh` adds the §0.C "no actor-discriminating
branch" source grep (comments stripped, fail-closed) over **all 11** `src/*.js`
(CF.11 closed the CF.6 `src/dossier.js` omission) + the §6.3/§6.2
capacity-never-measures grep. CF.10's `pages-dev/verify.sh` boots the frozen
Pages proxies via `wrangler pages dev` and round-trips them end-to-end. The
bash oracle baseline is re-run unchanged to prove the engine swap did not
perturb it.

## Per-surface equivalence (bound §-clauses)

| CF child | engine `src/` | bash oracle (`lib/`) | `lib/test-*.sh` + conformance oracle | CF differential | bound INTERFACE.md v1 §-clauses |
|---|---|---|---|---|---|
| **CF.1** substrate | `coordinator.js` `index.js` `schema.js` | `coordinator.sh` | `test-coordinator.sh` (EXIT-1..5 + §2.4) | `test/coordinator.spec.js` | §2.1–§2.4, §4, §9.1, §0.3 |
| **CF.2** lease | `lease.js` | `coordinator.sh` lease ops | `test-coordinator-lease.sh` **+ `bc-ad2-lease-posture.sh`** | `test/lease.spec.js` | §6.1, §6.2, §4.4, §0.5 `LEASE_TTL` |
| **CF.3** reconcile/projection | `reconcile.js` | `coordinator.sh` | `test-coordinator-reconcile.sh` + `test-board.sh` (producer half) | `test/reconcile.spec.js` | §4.2, §4.5, §2.4, §0.5 `STALE_AFTER`, S-1 |
| **CF.4** capacity | `capacity.js` | `coordinator.sh` | `test-coordinator-capacity.sh` + `bc-34-usage-fail-open.sh` | `test/capacity.spec.js` | §6.3, §6.2, §0.5 `USAGE_THRESHOLD` |
| **CF.5** forensic | `forensic.js` | `coordinator.sh` | `test-coordinator-forensic.sh` (+ §10.1/BC-27 cross-check) | `test/forensic.spec.js` | §10.1, §10.3, §0.5 `FORENSIC_BLOB_TTL` |
| **CF.6** dossier/Item | `dossier.js` | `dossier.sh` + `dossier-gen.sh` + `consequence.sh` | `test-dossier.sh` + `test-dossier-gen.sh` + `test-consequence.sh` (incl. the 8-way concurrent race ⇒ applied exactly once) | `test/dossier.spec.js` | §4.1, §4.1.1, §5.1, §5.2, §5.2.1, §5.2.2, §5.3, §7.4 (per-Item) |
| **CF.7** timer | `timer.js` | `timed-fyi.sh` | `test-timed-fyi.sh` (EXIT-1..5) | `test/timer.spec.js` | §2.2, S-6 (§7.4), §5.2.2 |
| **CF.8** STUCK | `stuck.js` | `stuck-routing.sh` | `test-stuck-routing.sh` **+ `bc-stuck-cross-tier.sh`** | `test/stuck.spec.js` | §7.2, §7.3, §7.4 (dossier-level) |
| **CF.9** notification | `notification.js` | `notification.sh` | `test-notification.sh` | `test/notification.spec.js` | §4.3, §4.1 (tier source), §0.3 |
| **CF.10** Pages serve | (frozen proxies → engine) | — | `test-board.sh` + `test-inbox.sh` | `pages-dev/verify.sh` | §4.5, §5, §5.2.2, §7.4, §9.1, §9.2, §10.3 |

## The 4 forward gates — flipped GREEN against the REAL engine

| gate | INTERFACE | realized in (on the REAL engine) | what flips it GREEN |
|---|---|---|---|
| **AD2.1** | §6.1 | `test/lease.spec.js` (CF.2) | a lease acquire is observable + a lease release pairs it — the `bc-ad2-lease-posture.sh` §6.1 acquire-before-`in_progress` OUTCOME, asserted via `SELF.fetch` on the real Worker→DO→D1 |
| **AD2.2** | §6.2 | `test/lease.spec.js` (CF.2) | Coordinator-unreachable + no held lease ⇒ a NEW lease is **denied-unreachable** and the unclaimed task is **never driven** (degraded-CLOSED), on the real engine |
| **STUCK-e2e** | §7.2/§7.3 | `test/stuck.spec.js` (CF.8) | bead **ENDS** blocked-for-human (never reset to open), `bd human` honored, ONE Dossier per fork — for the worker path **and** both backstops — the `bc-stuck-cross-tier.sh` cross-tier OUTCOME on the real engine |
| **BC-38** | §7.6 | **RUNNER / Local-Agent tier — NOT a Coordinator surface** | the engine src ports **no** §7.6 worker-prompt guardrail (porting = drift / §1.1 boundary violation — verified by a comment-stripped, fail-closed grep) **and** the bash `bc-38-worker-prompt` gate stays GREEN on the unchanged bash runner under the engine swap |

`lease.js` and `stuck.js` carry the explicit anti-drift declaration that
**BC-38 §7.6 is the runner surface and is NOT touched here** — the engine owns
only the cross-tier dossier OUTCOME / lease arbitration, never the
classifier/worker-prompt. The `ExitPlanMode` / "Entered plan mode." tokens in
`stuck.js` are the §7.2 backstop **DETECTION** signal (CF.8's STUCK surface),
*not* the §7.6 guardrail — a distinct clause, no drift.

## Divergence ledger

**Zero unexplained divergence.** The only intentional, documented realization
seams (NON-NORMATIVE per §0.2 — neither an INTERFACE gap nor a divergence):

- **Single-writer-by-construction (AD1).** The bash hand-rolled `co__with_lock`
  / per-dossier `mkdir` advisory lock is replaced by the singleton
  single-threaded Coordinator DO running read→decide→write as one critical
  section — same observable exactly-once, *not* a ported lock/CAS (Appendix A).
- **Work plane.** A Worker cannot `exec bd`; the bash tests' PATH-injected
  logging `bd` fake is realized as the `work_plane_ops` D1 table with the same
  space-joined arg shape and `bd-fake-N` id scheme — a documented realisation
  boundary, **not** a §4 record type.
- **Pages transport dialect.** The frozen proxies speak `?op=`; the frozen
  Worker speaks positional `{op,args}`. `pages-dev/adapter.js` re-frames in
  front of the byte-unchanged Worker — Appendix-A non-normative HTTP framing
  (§0.2), reconciled as wiring, no proxy/engine/INTERFACE edit.

No `INTERFACE.md` edit and no conformance-assertion edit were needed or made.
The bash conformance baseline is itself unaffected by pointing the driver at
the CF engine.

<!-- CF11-VERDICT:BEGIN -->
_Last rig run: **2026-05-17T10:14:26Z** — overall **GREEN**._
<!-- CF11-VERDICT:END -->
