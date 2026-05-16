# beads-runner conformance harness (T1a — claude-tools-ooc)

The shared regression gate for the beads-runner overhaul (epic
`claude-tools-glk`). It runs the **current** `run-beads-tasks.sh` under stubbed
`claude`/`bd`/`security`/`curl` and asserts each **SCAR** behaviorally
(black-box), per BC id, citing the frozen `INTERFACE.md v1` sections.

## Run it

```bash
bash beads-runner/conformance/run-conformance.sh            # all rigs
bash beads-runner/conformance/run-conformance.sh bc-21 bc-35 # subset (substring)
```

Exit `0` ⇔ **HARNESS GREEN**: every regression assertion passes against the
current script and every forward gate is in its documented pre-rewrite state.
Exit `1` ⇔ a regression assertion failed (harness bug **or** a real SCAR
regression).

Wall time: most rigs are sub-second; `bc-22` (watchdog) and `bc-35`
(interrupt) are timing rigs (~15–30 s each) because the watchdog poll cadence
(15 s) and the 180 s soft-warn tier are hardcoded SCAR values (BC-22) and are
**not** env-tunable.

## What this owns vs. what it does not (anti-overlap)

**T1a (this task) owns** the harness *framework* (`lib/`, `run-conformance.sh`)
and the **runner/local-side** SCAR assertions:

| Rig | BCs | INTERFACE binding |
|---|---|---|
| `bc-09-exit0-not-success` | BC-09 | §8.2, §6.1 |
| `bc-10-11-classification-precedence` | BC-10, BC-11 | **§7.1** |
| `bc-13-14-retry-asymmetry` | BC-13, BC-14 | **§7.5** |
| `bc-15-release-to-open` | BC-15 | §6.1 |
| `bc-21-exit-codes` | BC-21 | **§8.1**, §8.2/§3 job 6 |
| `bc-22-watchdog` | BC-22 | §8.2/§3 job 6 |
| `bc-29-timestamped-artifacts` | BC-29 | §8.2 |
| `bc-34-usage-fail-open` | BC-34 | §6.2, §6.3 |
| `bc-35-interrupt-cleanup` | BC-35 | §8.1, §6.1 |
| `bc-38-worker-prompt` | BC-38 | §7.6 |

**T1b (`claude-tools-crq`) owns** — and reuses this framework, not
re-implements it — the coordinator/observability/security SCARs. Delivered
rigs (all `source ../lib/harness.sh`, same `RESULT|` protocol):

| Rig | BCs / surface | INTERFACE binding | Kind |
|---|---|---|---|
| `bc-23-greppable-notes` | BC-23 | §8.2 | regression (PASS) |
| `bc-24-incidents-log` | BC-24 | §8.2 | regression (PASS) |
| `bc-25-scan-tool-errors` | BC-25 | §8.2 | regression (PASS) |
| `bc-27-logdir-security` | BC-27 | **§10** | regression (PASS) |
| `bc-28-selective-preservation` | BC-28 | §8.2 | regression (PASS) |
| `bc-30-rotation-once` | BC-30 | §8.2 | regression (PASS) |
| `bc-31-preflight-nonaborting` | BC-31 | §8.2 | regression (PASS) |
| `bc-stuck-cross-tier` | STUCK_NEEDS_HUMAN e2e | **§7.2 / §7.3** | forward GATE (gates **T5**/T2) |
| `bc-ad2-lease-posture` | AD2.1 / AD2.2 | **§6.1 / §6.2** | forward GATE (gates **T4**) |

ANTI-OVERLAP (binding, honored): T1b does **not** re-implement any T1a
runner-local assertion. Where a class is touched by both, the surfaces are
disjoint and the rig header states it — e.g. T1a/bc-09 asserts the note
*exists* for `TASK_NOT_CLOSED`; **bc-23** asserts the *uniform shape across
classes* + the `— log:` ↔ `— no stream preserved` dichotomy. T1a/bc-22
asserts the watchdog *mechanism*; **bc-28** asserts the *preservation policy
by class* (incl. the watchdog-fired-but-`SERVER_ERROR`-wins ⇒ proc-snapshot-
deleted edge). T1a/bc-10-11 (§7.1 slot) and bc-13-14 (§7.5 exemption) own the
STUCK *classification string*; **bc-stuck-cross-tier** owns the cross-tier
*outcome* (§7.2 two triggers + §7.3 the backstop itself drives the bead to
blocked-for-human) — it does not re-assert §7.1/§7.5.

**`lib/fake-bin/lease`** is the new observable control-plane seam for the
AD2.1/AD2.2 forward gates. The current single-process script has no
lease/Coordinator concept and never invokes it, so those gates are correctly
`GATE-PENDING` pre-rewrite — the literal close-criteria **T4** must flip to
`GATE-MET` (it does not prescribe transport, exactly as T1a's gates do not
prescribe the classifier internals).

Harness-mechanism fix during T1b bring-up (NOT an expected-behavior change —
same latitude as T1a's three documented driver fixes, no §11 escalation):
`bc-28-selective-preservation` assigned `ld="$WORKDIR/.beads/runner-logs"`
once but referenced it from later sub-rigs whose `H_init_test` had created a
*new* `WORKDIR` — a stale-path driver bug (not a SCAR regression: T1a/bc-22
independently proves watchdog stream/proc preservation). Fixed by computing
`ld` per sub-rig. Every `_expect`/`_need` line is byte-identical.

**BC-36 / BC-40 — empirically reproduced here; formal assertion is T1b's.**
The current `run-beads-tasks.sh` leaks one `tail -f`+parser subshell **per
task iteration even on its normal exit** (its `kill TAIL_PID; pkill -P
TAIL_PID` reaping is racy — once the parser subshell dies, `tail -f`
reparents to PID 1 *before* `pkill -P` runs). That is concrete repro for
**BC-40** ("`tail -f` not reaped") and **BC-36** ("no clean exit on parent
death") — and it is exactly the orphaned-runner / leaked-`tail -f` pileup
that saturated the machine in the first T1a attempt. T1a's response is
**containment, not assertion**: every runner is launched as a process-group
leader and the whole group is swept after it exits (`lib/harness.sh`
`_reap_runner_pg`), so the suite cannot self-saturate regardless of the
runner's own (non-)reaping. The **formal BC-36/BC-40 assertion rig is
deliberately left to T1b** (it owns the observability/scaffolding SCARs);
scoping it here would violate the non-overlap contract. The containment
mechanism + this note ARE the captured repro the task notes asked for
"where feasible".

**Update (T1b, `claude-tools-crq`):** the *frozen* T1b description's OWNS list
does **not** enumerate BC-36/BC-40 (it owns BC-23/24/25/27/28/30/31 + STUCK
cross-tier + AD2.1/AD2.2). Per epic ANTI-DRIFT rule 3 (ownership is
non-overlapping; each task names the **exact** BCs it owns) T1b did **not**
unilaterally expand its owned surface to absorb them — that would itself be a
drift. The formal BC-36/BC-40 rig + the T1a-vs-T1b ownership-gap escalation
is tracked in **`claude-tools-sdj`** (recommended: a forward GATE
characterizing the current hazard, mirroring the T1a/T1b gate model, with the
no-process-pileup constraint from the incident notes). The captured repro
above is unchanged and remains the input for that follow-up.

## O-1 headless version probe (T1c — `claude-tools-0vt`, upgrade-gated canary)

`probes/o1-headless-version-probe.sh` is **referenced by this gate but is NOT
in the `assertions/bc-*.sh` regression set** that `run-conformance.sh` runs:
those rigs are offline (stubbed `claude`); the O-1 probe deliberately invokes
the **live, networked `claude` binary** to re-assert the undocumented,
version-pinned behavior all of AD3 / `INTERFACE.md v1 §7.2/§7.6` rests on
(`research/headless-stuck-signal.md`, baseline claude 2.1.142):

- **A1** AskUserQuestion → exit-0/`success`/`is_error:false` **with**
  `permission_denials[AskUserQuestion]` (the §7.2 primary backstop hook).
- **A2** EnterPlanMode → silent exit-0, **no** denial, stream carries
  `"Entered plan mode."` (the *only* backstop for this residual gap).
- **A3** ExitPlanMode (out of plan) → exit-0 soft-fail (`not in plan mode`).
- **A4** `--disallowedTools` removes all three from the advertised `init`
  tool list (the §7.6 guardrail).

```bash
bash beads-runner/conformance/probes/o1-headless-version-probe.sh
# exit 0 = AD3 backstops safe on this claude
# exit 1 = DRIFT (BLOCKING escalation → claude-tools-65z; do not weaken the probe)
# exit 2 = probe could not run (no claude/jq, auth/network) — not drift, still non-zero
```

**MUST RE-RUN ON EVERY `claude` UPGRADE.** A red probe blocks trusting the AD3
backstops (it is the canary `claude-tools-kqn`/T2.5 cross-links). It is kept
out of the offline exit-code so a network/auth outage cannot RED the
regression gate, while the gate still documents and points at it here.

## The four result statuses

- **PASS** — regression green: the current script exhibits the SCAR. This is
  EXIT-criterion-1 ("GREEN for every listed BC … proves the harness before it
  gates the rewrite").
- **FAIL** — regression red: harness bug **or** the script regressed a SCAR.
- **GATE-PENDING** — a forward criterion (the new `INTERFACE.md v1` behavior:
  STUCK_NEEDS_HUMAN slot/exemption §7.1/§7.5, terminal-reason re-home §8.2,
  worker guardrail §7.6) that the **current** script cannot satisfy yet. This
  is the **literal close-criterion T2/T3 cite by BC id** — it is *expected*
  PENDING pre-rewrite and does **not** fail the current-script verdict. When
  T2/T3 land, these flip to **GATE-MET** and become their close gate.
- **GATE-MET** — a forward criterion already satisfied (informational).

## ANTI-DRIFT (binding)

The assertions ARE the close-criteria T2/T3 cite. An assertion encodes an
*expected behavior* sourced from `BEHAVIORAL-CONTRACT.md` (SCARs) and
`INTERFACE.md v1` (§3/§7.1/§7.5/§8.1/§8.2). **Changing an expected behavior is
a §11 escalation to `claude-tools-65z`** (reopen → amend → bump version →
re-freeze) — you do **not** edit the harness to make a rig pass. A red
regression rig means either the harness is wrong (fix the harness to match the
frozen contract) or the script regressed a SCAR (fix the script) — never
"adjust the expectation."

## Harness-mechanism fixes (T1a bring-up — NOT expected-behavior changes)

Bringing the harness GREEN against the current script required three
**driver-mechanism** fixes. None changes an asserted behavior — every
`_expect`/`_need`/`_gate` line is byte-identical; only the *staging* that
feeds the runner was corrected so each rig actually exercises the scenario
its assertions always described. Per ANTI-DRIFT this is "fix the harness to
match the frozen contract", **not** "adjust the expectation" — so no §11
escalation to `claude-tools-65z` was triggered:

1. **Process-group containment (`lib/harness.sh`).** `run_runner` /
   `run_runner_bg` now launch the runner as a process-group leader (`set -m`)
   and `_reap_runner_pg` SIGKILLs the whole group on every exit path. Without
   this the BC-40 leak (above) compounded across 20+ rigs into machine
   saturation — the harness could not run to completion. Containment only;
   the runner's leak is characterized, not fixed here (T2 owns the rewrite).
2. **`claude` stub `hang` → `exec sleep` (`lib/fake-bin/claude`).** A
   `sleep N; exit 0` stub let the wrapper bash defer the watchdog's SIGINT
   until the sleep finished, then exit **0** — and `classify_failure`
   short-circuits on exit 0 (never reads the signal file), masking the kill
   as `TASK_NOT_CLOSED`. `exec sleep` makes the process a pure, signal-honest
   stuck agent so the watchdog's staged kill is what ends it (BC-22).
3. **bc-22 hang 20s→60s; bc-14 storm driver → bead-keyed
   (`overflow_then_fixed`).** bc-22's hang was shorter than the watchdog's
   own SIGINT(≤15s)+10s→SIGKILL sequence, so the stub self-exited 0 before
   the kill. bc-14's positional `overflow overflow overflow success` plan was
   unsound because the fake `bd ready` interleaves analysis children into the
   queue (a child ate an `overflow` slot, BC-17-guarded ⇒ no grandchild, a
   real task never overflowed) — re-keyed on the bead's attempts file so it
   deterministically drives 3 distinct overflows. Both are driver knobs, not
   contract.

## How the black-box driving works

`lib/fake-bin/` shadows the runner's external dependencies on `PATH`:

- **`bd`** — a file-backed issue store (`$BD_STORE`) so status transitions,
  notes, deps, and analysis-child creation are observable; every status
  change is appended to `$BD_AUDIT` (the BC-15/BC-35 release evidence).
- **`claude`** — scripted per-invocation via `$HARNESS_CLAUDE_PLAN` (one
  behavior per line; the last line repeats). It emits exactly the stream-json
  the runner's parser consumes and exits with a controlled code. End a plan
  with `success` so the queue drains to the BC-21 exit-0 terminal.
- **`security` / `curl`** — drive the BC-34 fail-open matrix
  (`HARNESS_KEYCHAIN`, `HARNESS_USAGE`).
- **`osascript`** — silenced (BC-26 notification mechanism is T1b's).

Each rig runs in an isolated `mktemp -d` workspace; nothing touches the real
repo or `.beads/`.
