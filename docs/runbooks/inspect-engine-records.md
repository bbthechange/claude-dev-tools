# Runbook: inspect records on the hosted Cloudflare engine

## When

You want to see what's in the engine's D1 database — dossiers, runner_state, blocked-for-human records, notifications, intake requests, lease records, etc. Useful for debugging why a bead is in an unexpected state, finding stale records, or just exploring.

## Auth

All ops require the bearer token:

```bash
TOK=$(security find-generic-password -s "claude-beads-runner.coordinator-token" -w)
```

## Reads — `op=get`

```bash
# Fetch a single record by type + id
curl -sS -X POST https://coordinator-cf.bbthechange.workers.dev/ \
  -H "Authorization: Bearer $TOK" \
  -H "content-type: application/json" \
  -d '{"op":"get","args":["<type>","<id>"]}'
```

Common record types:

| Type | ID shape | What it is |
|---|---|---|
| `dossier` | `dossier-<task_ref>-<hash>` or whatever the generator produced | A full dossier with body+items |
| `runner_state` | `<project_ref>` | Desired/actual/heartbeat for a workspace |
| `blocked-for-human` | `<task_ref>` | The S-2 control record marking a fork pending |
| `dossier-dedup` | `<task_ref>` | The one-fork-one-dossier dedup record |
| `notification` | `<dossier-id>-notif` | The push notification record |
| `intake-request` | `<intake-id>` | A phone-submitted idea pending enricher dispatch |
| `lease` | `<task_ref>` | The global exclusivity lease |

A successful read returns the record JSON. A miss returns `{"ok":false,"found":false}`.

## Snapshot — `op=work-snapshot`

The work-snapshot is the read projection used by the Board. It includes runner_state for all workspaces and the inbox items.

```bash
curl -sS -X POST https://coordinator-cf.bbthechange.workers.dev/ \
  -H "Authorization: Bearer $TOK" \
  -H "content-type: application/json" \
  -d '{"op":"work-snapshot","args":[]}'
```

Returns:

```json
{
  "schema_version": <int>,
  "principal": "brian",
  "read_only": true,
  "projects": [ { ... per workspace ... } ],
  "lifecycle_columns": { ... grouped beads ... },
  "waiting_on_you": [ { dossier-summary objects } ]
}
```

`waiting_on_you` is what the Inbox renders. Post-`56h` fix, each item includes `tldr`, `created_at`, `dossier_id`, `kind`, `item_count`, sorted newest-first.

## Listing dossiers for a workspace

The engine doesn't have a "list all dossiers" op directly. Use `work-snapshot.waiting_on_you` to see pending ones, or iterate through known dossier_ids.

To find all dossier records for a specific bead, you can compute the deterministic dossier id pattern (from `lib/stuck-routing.sh sr_dossier_id_for`) — but multiple dossiers can exist on one bead. The easiest sanity check is:

```bash
# Snapshot the inbox + filter to a specific bead
curl -sS -X POST https://coordinator-cf.bbthechange.workers.dev/ \
  -H "Authorization: Bearer $TOK" \
  -H "content-type: application/json" \
  -d '{"op":"work-snapshot","args":[]}' \
  | jq '.waiting_on_you | map(select(.bead_ref == "<bead-id>"))'
```

## Writes — never do these casually

Writes are namespaced under specific ops:

- `op=put` — generic put (writes a record of a given type by id).
- `op=item-apply` — applies a response to a dossier item (the "tap response" on the Inbox).
- `op=set-desired` — sets a workspace's desired-state.
- `op=timer-arm` / `timer-ack` — durable timer plumbing.

Most writes should go through the higher-level paths (the bash libs, the MCP server, the Pages Functions). Direct curl writes are for emergencies (clearing stale state, manual probe verification).

## Example: clearing a stale `blocked-for-human` record

```bash
# Check current state
curl -sS -X POST https://coordinator-cf.bbthechange.workers.dev/ \
  -H "Authorization: Bearer $TOK" \
  -H "content-type: application/json" \
  -d '{"op":"get","args":["blocked-for-human","claude-tools-240"]}'

# If it's pending and you want to mark resolved, apply a response to the dossier item.
# (See manual-dossier-upload.md or reset-stuck-bead.md.)
```

## Example: probing engine capabilities

```bash
# GET / returns the four-capability health check
curl -sS https://coordinator-cf.bbthechange.workers.dev/ -H "Authorization: Bearer $TOK"
```

Expected output:
```
§2.1 store                       : POST / put|get   (Coordinator DO + D1)
§2.2 durable one-shot timer      : POST / timer-arm|timer-due|timer-ack  (DO setAlarm + S-6 poll-fallback)
§2.3 authed endpoint (§9.1 choke): the Worker  (the ONE authenticate->principal step)
§2.4 deliver-desired-state       : POST / poll      (transport; set-desired captures C4 actor)
```

(Yes, the live engine prints the `§` symbol in its capabilities. That's an internal-contract concession, not user-facing.)

## Debugging the production MCP server's writes

If the `ask-brian` flow seems broken, you can call `engine-bridge.sh` directly to test the write path:

```bash
# See manual-dossier-upload.md for the full pattern
bash beads-runner/agents/specialist.sh --kind=dossier-builder ...
```

## Where the schemas are defined

The Worker's record schemas + op validation lives in `beads-runner/cf/src/schema.js`. The bash twins are in `beads-runner/lib/coordinator.sh`. Both are kept in lockstep — when one changes, the other must too (the "single source registry" rule in the design docs).
