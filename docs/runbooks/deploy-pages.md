# Runbook: deploy the Board and Inbox to Cloudflare Pages

## When

You've edited any file under `beads-runner/web/board/` or `beads-runner/web/inbox/` (HTML, app.js, board-view.js, inbox-view.js, CSS, or any Pages Functions). The committed code change does NOT automatically reach the deployed Pages site — you must explicitly redeploy.

This is the most common source of "wired but not actually live" bugs in this project. See HANDOFF.md "loose threads" for the pattern.

## Board deploy

```bash
cd beads-runner/web/board
npx wrangler pages deploy . --project-name claude-wrangler-board
```

`wrangler pages deploy` finds Pages Functions relative to CWD, so you MUST `cd` into the project directory and pass `.` as the dir arg. Running from `beads-runner/` with `web/board` as the dir silently misses the `functions/` subdir and ships HTML without the API proxies.

## Inbox deploy

```bash
cd beads-runner/web/inbox
npx wrangler pages deploy . --project-name claude-wrangler-inbox
```

## Verification — DO NOT skip this

Several bugs in this project closed because the agent ran the deploy command but never confirmed the live URL actually serves the new code. Verify with a byte-compare:

```bash
# Compare deployed JS sizes to committed
curl -sS https://claude-wrangler-board.pages.dev/app.js -o /tmp/deployed-app.js -w "deployed: %{size_download} bytes\n"
echo "committed: $(wc -c < beads-runner/web/board/app.js) bytes"

# Diff if you want to see what's different
diff -q beads-runner/web/board/app.js /tmp/deployed-app.js
```

If the deployed bytes match the committed bytes, the deploy landed. If they differ, the deploy either failed silently or you ran from the wrong directory.

For the Inbox, repeat with `claude-wrangler-inbox.pages.dev` and `beads-runner/web/inbox/`.

## When the deploy succeeds but the feature still doesn't work

The Pages site fetches data from the hosted Cloudflare Worker via API proxies under `functions/api/`. If the Worker doesn't support a new op (like `set-desired`), the proxy will get an "adapter - unsupported POST proxy op" error from the Worker even though the Pages deploy was correct.

In that case, the bug is on the Worker side, not Pages. See `deploy-cloudflare-worker.md`.

## When you've edited both the Board/Inbox AND the Worker

Deploy the Worker first, then the Pages. The Pages depend on Worker ops; Worker doesn't depend on Pages. Wrong order can produce transient failures.

## What gets cached

Both Pages sites set `cache-control: no-store` for API proxy responses (so liveness is honest). Static assets may be cached by Cloudflare's CDN; you may need to bust browser cache or open in an incognito tab to see updates.

## Discipline

After every web-track task close, the closing agent MUST run the byte-compare verification before `bd close`. This is documented as the project's standing rule per the `claude-tools-bgw` close-discipline note. Failing to verify is the failure mode that caused 5 separate bugs in 24 hours during the rescue.
