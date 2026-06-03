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
  // claude-tools-mqh4 — raise the per-test timeout off vitest's 5s default.
  // These differential specs exercise the REAL engine through workerd+miniflare;
  // the cold/loaded workers-pool import can take tens of seconds under concurrent
  // load (observed ~30s during a parallel close), and the heavier conformance
  // specs (CF.2 lease, CF.6 dossier, CF.7 timer) legitimately need ~6.9s of
  // in-test work. At 5s they intermittently fail with "Test timed out in 5000ms"
  // — an environmental false-RED, NOT an assertion failure — which can red the
  // offline gate for web-only changes that touch no cf/src. 30s restores headroom
  // (~4x the real work) while still failing a genuinely wedged test. hookTimeout
  // is raised in lockstep so any future setup/teardown gets the same headroom.
  test: {
    testTimeout: 30000,
    hookTimeout: 30000,
  },
  plugins: [
    cloudflareTest({
      main: "./src/index.js",
      wrangler: { configPath: "./wrangler.toml" },
    }),
  ],
});
