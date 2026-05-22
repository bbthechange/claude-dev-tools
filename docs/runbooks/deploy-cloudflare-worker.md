# Runbook: deploy the hosted Cloudflare Worker (the engine)

## When

You've edited any file under `beads-runner/cf/src/` — the Worker source, op handlers, the CF.10 Pages-dev adapter, or schema. Committed code does NOT automatically deploy to the live Worker at `coordinator-cf.bbthechange.workers.dev`.

## The two configs

`beads-runner/cf/` contains TWO wrangler configs:

- **`wrangler.toml`** — LOCAL-EMULATION-ONLY. Used by `wrangler dev` for the in-process miniflare. Its D1 binding points at a local placeholder. Per its own file header: **do not edit this for production**.
- **`wrangler.production.toml`** — the real production config. Its `main` field points at the CF.10 adapter (`pages-dev/adapter.js`), which fronts the raw Worker (`src/index.js`). Its D1 binding points at the real hosted database (id: `c80f8fb8-da0c-40b1-8051-70ff4ec5dd51`, name: `coordinator-records`).

## Production deploy

```bash
cd beads-runner/cf
npx wrangler deploy --config wrangler.production.toml
```

This deploys the Worker named `coordinator-cf`. The Worker URL is `https://coordinator-cf.bbthechange.workers.dev`.

Same-name redeploy preserves:

- The Durable Object namespace (DO instances persist)
- The `CO_EXPECTED_TOKEN` secret
- The D1 database binding (data persists)

## Verification

The deploy completes when wrangler prints something like `Deployed coordinator-cf triggers (n ms)`. To live-verify the new code is running:

```bash
TOK=$(security find-generic-password -s "claude-beads-runner.coordinator-token" -w)

# 1. Health check / capabilities — the GET / endpoint
curl -sS https://coordinator-cf.bbthechange.workers.dev/ \
  -H "Authorization: Bearer $TOK"
# Expected: a JSON response with the 4 capability lines (store, timer, authed-endpoint, deliver-desired-state)

# 2. If you added a new op, probe it directly
curl -sS -X POST https://coordinator-cf.bbthechange.workers.dev/ \
  -H "Authorization: Bearer $TOK" \
  -H "content-type: application/json" \
  -d '{"op":"<new-op>","args":[...]}'
# A live deploy of the new op returns the expected JSON. An old deploy returns "co: unknown op (...)".
```

## Common gotcha: the CF.10 adapter

The Worker has a two-dialect architecture:

- The raw Worker (`src/index.js`) speaks POST `/` with `{op, args, principal}` body — positional args. This is what `lib/co-http-transport.sh` and the production MCP server send.
- The CF.10 Pages-dev adapter (`pages-dev/adapter.js`, the `main=` of `wrangler.production.toml`) reconciles between the raw Worker and what the Pages Functions send. Pages Functions sometimes use a different body shape; the adapter normalizes.

If you add a new op handler to `src/coordinator.js` but the Board's API proxy sends the request through the adapter, you may need to ALSO add the op to the adapter's passthrough allowlist. Otherwise you'll see errors like `co: adapter - unsupported POST proxy op '<op-name>'`.

See `claude-tools-2dk` (closed) for an example where `set-desired` was added to the Worker but not the adapter, and the Board's Run button failed for it.

## Token rotation

The Worker's `CO_EXPECTED_TOKEN` secret authenticates incoming requests. To rotate:

```bash
# 1. Rotate on the Worker
cd beads-runner/cf
npx wrangler secret put CO_EXPECTED_TOKEN --config wrangler.production.toml
# Paste the new token

# 2. Rotate the matching client-side token on each Pages project
cd beads-runner/web/board
npx wrangler pages secret put COORDINATOR_TOKEN --project-name claude-wrangler-board
cd ../inbox
npx wrangler pages secret put COORDINATOR_TOKEN --project-name claude-wrangler-inbox

# 3. Update the local Keychain entry
security delete-generic-password -s "claude-beads-runner.coordinator-token"
security add-generic-password -s "claude-beads-runner.coordinator-token" -a brian -w "<new-token>"

# 4. Redeploy all three
npx wrangler deploy --config beads-runner/cf/wrangler.production.toml
cd beads-runner/web/board && npx wrangler pages deploy . --project-name claude-wrangler-board
cd ../inbox && npx wrangler pages deploy . --project-name claude-wrangler-inbox

# 5. Re-register any MCP servers that took the token via -e flag (see register-mcp-tool.md)
# The user-scope MCP config in ~/.claude.json holds the token; it'd need updating too.
```

## Discipline

Same as Pages: do NOT close a task on local-test-pass. Live-verify by curling the deployed Worker URL and confirming the new op handler returns the expected response shape.
