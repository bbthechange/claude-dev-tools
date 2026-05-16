---
name: wrapup
description: Wrap up a development task — review, risk-check, and commit. Use this skill when the user says "wrap up", "wrapup", "finish this up", "ready to commit", "ship it", or "/wrapup". Runs the code-reviewer, integrates valid feedback, performs an iOS-specific production risk analysis (App Store / TestFlight / compatibility), and commits the change. Does not push.
---

# Wrap Up a Development Task (iOS)

End-of-task checklist: code review, build verification, production risk analysis, commit. Run every step in order — do not skip.

## Step 1: Code Review

Run the `code-reviewer` skill (which spawns the `code-reviewer` agent). Provide a one-sentence summary of what was implemented.

When the reviewer returns feedback:

1. **Evaluate each item critically** — not all feedback is valid. Consider whether it actually applies to the change, matches the architecture guide in `context/`, or would introduce unnecessary scope.
2. **Fix items that are valid** — edit the code directly.
3. **Briefly note items you rejected and why** so the user can redirect if the judgment is off.

If the reviewer reports "No issues found", continue.

## Step 1b: Security Review (conditional)

Decide whether this change has meaningful **security surface**: authentication or authorization, sessions/tokens, crypto, parsing or deserialization of untrusted input, file or network I/O, secrets handling, SQL/command construction, deep links / IPC, or anything reachable by an untrusted caller.

- **If it does:** spawn the `security-reviewer` agent with a one-sentence summary of the change. Do **not** run the built-in `/security-review` skill — it injects the full diff into *this* conversation, which both bloats the working context and makes the review non-independent. The `security-reviewer` agent reviews in an isolated context (like `code-reviewer`) and is the correct tool here.
- **If it doesn't** (docs, tests, pure refactor, config with no secret/permission impact): state "no security surface — skipped" and continue.

Evaluate returned findings exactly as in Step 1: fix valid ones (re-run Step 2 after), briefly note rejected ones with a reason. Treat a HIGH finding as a commit blocker — do not commit until it is resolved or explicitly accepted by the user.

## Step 2: Build Verification

Verify the change still compiles cleanly. Prefer the project's helper if it exists:

```bash
# Preferred (if the scaffolder installed it):
./scripts/sim.sh build

# Fallback if scripts/sim.sh is absent:
xcodebuild build -project {{PROJECT_NAME}}.xcodeproj -scheme {{PROJECT_NAME}} \
  -destination 'generic/platform=iOS Simulator' 2>&1 | tail -60
```

If this project doesn't use `{{PROJECT_NAME}}.xcodeproj` (e.g., `.xcworkspace`, SwiftPM-only, or a different scheme), adjust `-project`/`-workspace` and `-scheme` accordingly.

If the build fails, fix it before proceeding. Do not commit a broken build.

If the project has tests and the change touched testable code, run them. See the `write-tests` skill for details. Pattern that captures the real exit code (don't let a `| grep` filter hide failures):

```bash
# Capture a simulator UDID:
SIM_ID=$(xcrun simctl list devices available | grep -Eo '\([A-F0-9-]{36}\)' | head -1 | tr -d '()')

# Run tests; pipefail makes the pipeline exit non-zero if xcodebuild fails:
set -o pipefail
xcodebuild test -project {{PROJECT_NAME}}.xcodeproj -scheme {{PROJECT_NAME}} \
  -destination "platform=iOS Simulator,id=$SIM_ID" 2>&1 \
  | grep -E "(Test Case|passed|failed|error:|Executed)"
# $? reflects the xcodebuild result, not grep.
```

If the project has no tests configured, note this to the user and continue — do not fabricate a test suite.

## Step 3: Production Risk Analysis

**This step surfaces real issues that code review misses.** Take it seriously — work through every category below and state "no risk" for ones that don't apply, rather than skipping.

### App Store Review Risks
- New entitlements, capabilities, or background modes introduced?
- New `NSUsageDescription` strings needed (camera, photos, location, contacts, tracking, etc.)?
- New SDKs or APIs requiring `PrivacyInfo.xcprivacy` manifest updates (required reason APIs)?
- Any use of private / undocumented APIs that could trigger rejection?

### Compatibility Risks
- Any new API used? Check availability against the project's minimum deployment target. Wrap in `if #available` when needed.
- Any new Swift language features that require a specific Xcode / Swift version?
- Any third-party dependency added? Does it support the minimum deployment target?

### User-Facing / Behavior Change Risks
- Any behavior change existing users will see and not expect (login flow, data migration, settings reset, navigation change)?
- Any Core Data / SwiftData / local storage schema change requiring migration? Is it lightweight or does it need a mapping model?
- Any change to push notification handling, deep link routes, or URL schemes?
- Any change to biometric / Keychain prompts that could confuse returning users?

### TestFlight / Rollout Risks
- Should this land behind a feature flag or remote config gate before general release?
- If this breaks in production, is there a remote kill switch, or will users be stuck until the next submission?
- Is a staged TestFlight rollout warranted before submitting to App Store Review?

### Data / Privacy Risks
- Any new data sent to the network? (New endpoint, payload, PII classification.)
- Any new logging that could leak PII to Crashlytics / Sentry / `os_log` in release builds?
- Any change to what's stored in Keychain, UserDefaults, App Group containers, or the file system?

Summarize the findings to the user in 3-6 bullets. **If you find a blocker (missing privacy string, unreviewed migration, missing kill switch for a risky change), stop and flag it — do not commit.**

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
- Proceed past Step 2 if the build is broken, or past Step 3 if a risk blocker is found.
