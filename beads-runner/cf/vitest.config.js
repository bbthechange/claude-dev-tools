// CF.1 (claude-tools-7g0.1) — differential conformance runner config.
//
// @cloudflare/vitest-pool-workers (0.16.x) runs the Worker + Coordinator DO +
// D1 under the SAME workerd+miniflare runtime `wrangler dev` uses, with NO
// Cloudflare account. In 0.16.x it is a Vite/Vitest plugin: `cloudflareTest`
// installs the workers pool and wires SELF/DO/D1 bindings straight from
// wrangler.toml, so the test exercises the REAL engine, not a mock. Per-file
// storage isolation is on by default — this single-file linear conformance
// gets a fresh D1 + DO (the bash test's per-run mktemp-store analogue). The DO
// applies its DDL lazily/idempotently, so no migration step is needed locally.

import { defineConfig } from "vitest/config";
import { cloudflareTest } from "@cloudflare/vitest-pool-workers";

export default defineConfig({
  plugins: [
    cloudflareTest({
      main: "./src/index.js",
      wrangler: { configPath: "./wrangler.toml" },
    }),
  ],
});
