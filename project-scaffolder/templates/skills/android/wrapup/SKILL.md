---
name: wrapup
description: Wrap up a development task — review, risk-check, and commit. Use this skill when the user says "wrap up", "wrapup", "finish this up", "ready to commit", "ship it", or "/wrapup". Runs the code-reviewer, integrates valid feedback, performs an Android-specific production risk analysis (Play Store / rollout / compatibility), and commits the change. Does not push.
---

# Wrap Up a Development Task (Android)

End-of-task checklist: code review, build verification, production risk analysis, commit. Run every step in order — do not skip.

## Step 1: Code Review

Run the `code-reviewer` skill (which spawns the `code-reviewer` agent). Provide a one-sentence summary of what was implemented.

When the reviewer returns feedback:

1. **Evaluate each item critically** — not all feedback is valid. Consider whether it actually applies to the change, matches the architecture guide in `context/`, or would introduce unnecessary scope.
2. **Fix items that are valid** — edit the code directly.
3. **Briefly note items you rejected and why** so the user can redirect if the judgment is off.

If the reviewer reports "No issues found", continue.

## Step 2: Build Verification

Verify the change still compiles cleanly and passes lint / tests. Run each task and check its exit code — don't rely on a truncated tail to judge success:

```bash
./gradlew assembleDebug      # compile
./gradlew lintDebug          # lint (only if configured)
./gradlew testDebugUnitTest  # unit tests (only if tests exist)
```

If output is noisy, re-run the failing task alone to see the full stack. If a task fails because it isn't configured in this project (e.g., no lint baseline yet, no unit tests yet), note it to the user and continue — do not treat "task doesn't exist" or "no tests to run" as a build failure.

If a genuine compile, lint, or test failure occurs, fix it before proceeding. Do not commit a broken build or a regression.

## Step 3: Production Risk Analysis

**This step surfaces real issues that code review misses.** Take it seriously — work through every category below and state "no risk" for ones that don't apply, rather than skipping.

### Play Store / Policy Risks
- New permissions declared in the manifest? Especially runtime-prompted (location, contacts, camera, mic, POST_NOTIFICATIONS on API 33+) or restricted (foreground service type, SMS, CALL_LOG, all files access).
- New foreground service? `foregroundServiceType` has existed since API 29; on API 34+ the service **must** declare a specific type (e.g., `dataSync`, `mediaPlayback`, `location`) both in the manifest and when calling `startForeground()`, and each type has its own permission and policy requirements.
- Any targeting of APIs / features restricted under current Play Store policy (accessibility service, exact alarms, package visibility)?
- Any new data collection requiring a Data Safety form update?

### Compatibility Risks
- Any new API used? Check `@RequiresApi` against `minSdk`. Gate with `Build.VERSION.SDK_INT` checks when needed.
- Any behavior changed by the current `targetSdk`? (Background execution limits, strict scoped storage, foreground service restrictions, predictive back, notification trampolines.)
- Any new dependency added? Does it support `minSdk`? Does it contribute manifest entries / permissions you didn't intend?
- Any Kotlin / Compose / AGP version assumptions?

### User-Facing / Behavior Change Risks
- Any behavior change existing users will see and not expect (login flow, data migration, settings reset, navigation change)?
- Any Room / DataStore / SharedPreferences schema change requiring migration? Is the migration tested on a real pre-change database?
- Any change to deep link intent filters, app links, or URL schemes?
- Any change to notification channels / IDs (renaming a channel breaks user preferences)?

### R8 / Proguard / Release-Only Risks
- Any new code path that relies on reflection, serialization (Gson/Moshi/kotlinx.serialization), or Hilt components? Needs `-keep` rules or `@Keep`.
- Would the change behave differently in a release build vs debug (R8 shrinking, resource shrinking, logging stripped)?
- Any new `BuildConfig` field that must be set for release flavors?

### Rollout / Rollback Risks
- Should this land behind a feature flag or remote config gate before general release?
- Is a staged rollout on Play Console warranted (5% → 20% → 50% → 100%)?
- If this breaks in production, is there a remote kill switch, or will users be stuck until the next Play Store review?
- Any change that can't be rolled back via app update alone (server-side contract, local DB migration)?

### Data / Privacy Risks
- Any new data sent to the network? (New endpoint, payload, PII classification.)
- Any new logging that could leak PII to Crashlytics / Sentry / `Log.d` in release (logs aren't automatically stripped)?
- Any change to what's stored in EncryptedSharedPreferences, Keystore, DataStore, or scoped external storage?

Summarize the findings to the user in 3-6 bullets. **If you find a blocker (undeclared permission, unreviewed migration, missing kill switch for a risky change, missing `-keep` rule), stop and flag it — do not commit.**

## Step 4: Commit

Stage and commit only the files relevant to this change.

First, see what's changed:

```bash
git status
```

Stage only the paths relevant to this change — use the real paths from `git status`, not `git add -A` (which can sweep in stray files):

```bash
git add path/to/file1 path/to/file2
```

Create the commit with a heredoc so the multi-line message is preserved verbatim:

```bash
git commit -m "$(cat <<'EOF'
<subject line — imperative mood, ≤ 72 chars>

<body: why this change exists; the diff shows the what>
EOF
)"
```

Commit message guidelines:
- Subject line ≤ 72 chars, imperative mood ("Add login flow", not "Added login flow").
- Body explains the **why**, not the what (the diff shows the what).
- Reference any linked issue / ticket if the project uses one.

Verify:

```bash
git status     # should be clean
git log -1     # confirm the commit landed
```

Report to the user: one sentence on what was committed, the risk findings from Step 3, and anything that needs follow-up.

## Do NOT

- Push to remote unless the user explicitly asks.
- Use `--no-verify` to skip hooks — fix the hook failure instead.
- Amend a previous commit unless explicitly asked.
- Proceed past Step 2 if the build / lint / tests fail, or past Step 3 if a risk blocker is found.
