# Runbook: deploy the unified `claude-wrangler` Pages project

## When

You've edited any file under `beads-runner/web/{board,inbox,intake}/` (HTML,
app.js, board-view.js, inbox-view.js, CSS), under
`beads-runner/web/functions/api/{board,inbox,intake}/...`, or the
`beads-runner/web/_redirects` routing config. The committed code change does
NOT automatically reach the deployed Pages site — you must explicitly
redeploy.

This is the most common source of "wired but not actually live" bugs in this
project. See HANDOFF.md "loose threads" for the pattern.

## Shape

Board, Inbox, and Intake are routes inside ONE responsive web app (UX-DESIGN
§2; consolidation in claude-tools-b59):

- `claude-wrangler.pages.dev/`        → rewrite to `/board/` (200, no redirect;
                                         see `beads-runner/web/_redirects`, q6z7)
- `claude-wrangler.pages.dev/board`   → `web/board/`
- `claude-wrangler.pages.dev/inbox`   → `web/inbox/`
- `claude-wrangler.pages.dev/intake`  → `web/intake/`
- `claude-wrangler.pages.dev/api/board/*`  → `web/functions/api/board/...`
- `claude-wrangler.pages.dev/api/inbox/*`  → `web/functions/api/inbox/...`
- `claude-wrangler.pages.dev/api/intake/*` → `web/functions/api/intake/...`

The apex `/` rewrite means `board/index.html` is served at two URLs. For that
to keep working, its asset refs MUST stay absolute (`/board/board.css`,
`/board/board-view.js`, `/board/app.js`) — relative paths break when the same
HTML is served at `/`. There are reminder comments on those lines in
`board/index.html`.

## Deploy

```bash
cd beads-runner/web
npx wrangler pages deploy . --project-name claude-wrangler
```

`wrangler pages deploy` finds Pages Functions relative to CWD, so you MUST
`cd` into `beads-runner/web/` and pass `.` as the dir arg. Running from the
repo root with `beads-runner/web` as the dir silently misses the `functions/`
subdir and ships HTML without the API proxies.

## Verification — DO NOT skip this

Several bugs in this project closed because the agent ran the deploy command
but never confirmed the live URL actually serves the new code. Use the
one-script verifier:

```bash
bash beads-runner/verify-pages-deploy.sh           # verifies all three routes
bash beads-runner/verify-pages-deploy.sh board     # or just one
```

A passing run prints `mismatches=0`. Any `DRIFT` or `MISS` line means the
deploy did not land — re-deploy and re-verify before closing.

## When the deploy succeeds but the feature still doesn't work

The Pages site fetches data from the hosted Cloudflare Worker via API proxies
under `web/functions/api/`. If the Worker doesn't support a new op (like
`set-desired`), the proxy will get an "adapter - unsupported POST proxy op"
error from the Worker even though the Pages deploy was correct.

In that case, the bug is on the Worker side, not Pages. See
`deploy-cloudflare-worker.md`.

## When you've edited both the web/ app AND the Worker

Deploy the Worker first, then the Pages. The Pages depend on Worker ops; the
Worker doesn't depend on Pages. Wrong order can produce transient failures.

## What gets cached

The Pages site sets `cache-control: no-store` for API proxy responses (so
liveness is honest). Static assets may be cached by Cloudflare's CDN; you may
need to bust browser cache or open in an incognito tab to see updates.

## Discipline

After every web-track task close, the closing agent MUST run the byte-compare
verification before `bd close`. This is documented as the project's standing
rule per the `claude-tools-bgw` close-discipline note. Failing to verify is
the failure mode that caused 5 separate bugs in 24 hours during the rescue.

## Decommissioning the old per-app projects

Pre-claude-tools-b59 there were three separate Pages projects
(`claude-wrangler-board`, `claude-wrangler-inbox`, `claude-wrangler-intake`).
Keep them running until `verify-pages-deploy.sh` passes against the unified
URL, then decommission them in the Cloudflare dashboard (or redirect to the
new URL). The repo no longer carries deploy commands for those projects.
