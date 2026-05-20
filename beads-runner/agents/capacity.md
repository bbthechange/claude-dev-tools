# Capacity Gates — Spare-Only Daily Ramp (C2 / claude-tools-oil)

The daemon's `/capacity` response (the atomic `capacity.json` published by
`daemon/usage-poll.sh`) carries a `spare_ramp_today` field computed from
the UX 0.A formula `100% / 7 days = 14.2%/day`: on day N of the rolling 7-day
window low-priority work is allowed up to `N × SPARE_RAMP_PER_DAY`% of the
7-day budget — day 1 ≤ 14.2%, day 2 ≤ 28.4%, …, day 7 = 100%. The math
itself lives in `daemon/usage-poll.sh:_usage_poll_spare_ramp_pct` (mirrored
from `lib/local-agent.sh:la__spare_ramp_pct`, with `SPARE_DAY_INDEX` as a
test pin) and is logged every cycle as
`ramp=<pct>% (day=<N> × <SPARE_RAMP_PER_DAY>%)` so the formula is verifiable
from the daemon's own logs without re-reading code.

**UI ↔ wire vocabulary.** The Board's per-workspace toggle row uses the UI
label `spare-only` (UX-DESIGN Flow D); the §4.2 RunnerState.desired enum,
the daemon's M3 reconciler, and the gate below all key on the canonical
wire value `spare-cycles`. The `web/board/functions/api/set-desired.js`
proxy normalises UI→wire on write (`WIRE_STATE['spare-only'] =
'spare-cycles'`, F3 / claude-tools-6mx) so the engine always stores
`spare-cycles` and downstream consumers never see the UI synonym. An
unnormalised `spare-only` write WOULD be dropped by the daemon's enum
filter (no-op) and the gate (case-arm key-miss) — the test-flow-d.sh
PART B8 / C6 cases assert that exact silent-break shape.

The gate that consumes the math lives in the workspace runner's
`daemon_ask_capacity` (`run-beads-tasks.sh`). It is invoked per pickup AFTER
the lease is held and BEFORE the bead is written `in_progress`, with two
inputs derived per task: the task's cost-class (priority ≥ 3 ⇒
`low_priority`, else `standard`) and the workspace's current desired-state
(`workspace_desired_state`, fetched via `co_request poll` and cached for
`DESIRED_STATE_CACHE_SECONDS`). When the desired-state is `spare-cycles`
the gate refuses any non-`low_priority` pickup with reason
`spare_only_standard_disallowed`; an allowed `low_priority` pickup is then
additionally bounded by the global ramp — when `pct_7d ≥ spare_ramp_today`
the daemon drops `low_priority` from `allowed_cost_classes`, and the
runner's denied branch surfaces `spare_cycles_today_exhausted`. Either way
the lease is released cleanly and the bead stays open for another env /
another moment.
