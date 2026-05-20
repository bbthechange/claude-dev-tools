# dossier-builder fixtures

These illustrate what the `dossier-builder` agent (system prompt:
`../dossier-builder.system.md`) receives on stdin and what it emits on stdout.

## Files

- `sample-input.json` — a representative worker-stuck input. The
  `ask-brian` MCP server (claude-tools-bvj, the B2 task) receives the
  worker's structured ask, attaches the dossier id, the bead ref, the
  trigger, the tier, and the workspace path, and pipes the whole object
  to the agent on stdin.
- `sample-output.json` — what a good run looks like. A four-tier body
  (tldr, sections[], diagrams[] in Mermaid, full_detail) plus one
  `pick-option` item with two real options, each carrying a pre-declared
  consequence block.

## What the dispatcher does, not the agent

Two things the model's output deliberately omits — the dispatcher (B2)
stamps them onto the output before it hands the `{body, items[]}` to
`dg_generate`:

1. `body.dossier_schema_version` and each consequence block's
   `cb_schema_version` are the bound schema version, read from the
   single registry source. The agent does not emit a literal version
   number; the dispatcher reads the bound value and stamps both fields.
   This keeps "the schema is the contract, never the generator" honest:
   if the schema bumps, the dispatcher's stamping picks it up; the agent
   needs no edit.
2. The §4.1 envelope (id, principal, trigger, bead_ref, tier, created_at,
   timer_fire_at, kind, plus per-Item `state`/`response`/`consequence_applied`/
   `applied_at`) is added by `dg_generate` around the `{body, items[]}`
   the agent emits. The agent never writes those.

## Refusal contract

When the agent cannot author a real `context_anchor` for any item, or
when the input + gathered context is too thin to honor the
self-contained-context invariant, the agent emits exactly:

```json
{ "refuse": true, "reason": "<short, structured reason>" }
```

The dispatcher detects `refuse: true` and routes to the `jq dg__author`
fallback, which produces a labeled-degraded dossier from the worker's
raw ask + bead title. The pipeline never silently drops the ask.

## Tone smell-test

If you read `sample-output.json` and any user-facing text mentions
`§5.2`, `AD7`, `BC-34`, "the freeze", "T5.2", or any other internal
contract vocabulary, the prompt is failing its tone rule — that's the
single most common way these agents degrade. The fixture should read
like a clear technical brief, not like a contract excerpt.
