# Detailed Setup Steps

Complete step-by-step instructions for Claude Code configuration. For new iOS projects, `references/ios-project-setup.md` runs first to create the Xcode project, then these steps add Claude Code configuration on top.

## Step 0: Create Project (if needed)

**iOS**: If no existing project is detected (no `project.yml`, `*.xcodeproj`, or `*.swift` source files), follow `references/ios-project-setup.md` to create the full XcodeGen project first. That guide handles directory structure, source files, `project.yml`, linting config, `.gitignore`, build verification, and an initial git commit.

**Android**: If no existing project is detected (no `build.gradle.kts`, `settings.gradle.kts`, or `*.kt` source files), follow `references/android-project-setup.md` to create the full Gradle/Compose project first. That guide handles directory structure, source files, `build.gradle.kts`, `libs.versions.toml`, Hilt setup, deep links, linting config, `.gitignore`, build verification, and an initial git commit.

After project creation, continue with the steps below. Steps 1-2 will be skipped since git and gitignore already exist from the project setup.

## Step 1: Initialize Git

If `.git/` does not exist:

```bash
git init
```

## Step 2: Create .gitignore

Copy the appropriate template:

```bash
# iOS
cp ${CLAUDE_PLUGIN_ROOT}/templates/gitignore/ios.gitignore .gitignore

# Android
cp ${CLAUDE_PLUGIN_ROOT}/templates/gitignore/android.gitignore .gitignore

# Backend
cp ${CLAUDE_PLUGIN_ROOT}/templates/gitignore/backend.gitignore .gitignore
```

## Step 3: Create .claude/ Directory Structure

```bash
mkdir -p .claude/agents .claude/skills
```

### Copy Settings

```bash
# iOS
cp ${CLAUDE_PLUGIN_ROOT}/templates/settings/ios.json .claude/settings.json

# Android
cp ${CLAUDE_PLUGIN_ROOT}/templates/settings/android.json .claude/settings.json

# Backend
cp ${CLAUDE_PLUGIN_ROOT}/templates/settings/backend.json .claude/settings.json
```

### Copy Agents

Copy both agents for all project types:

```bash
cp ${CLAUDE_PLUGIN_ROOT}/templates/agents/code-reviewer.md .claude/agents/
cp ${CLAUDE_PLUGIN_ROOT}/templates/agents/privacy-reviewer.md .claude/agents/
```

After copying `code-reviewer.md`, replace `{{ARCHITECTURE_GUIDE}}` placeholder:
- iOS: Replace with `IOS_APP_ARCHITECTURE_GUIDE.md`
- Android: Replace with `ANDROID_APP_ARCHITECTURE_GUIDE.md`
- Backend: Remove the architecture guide reference or use generic text

### Copy Skills

**All projects** - Copy shared code-reviewer skill:

```bash
cp -r ${CLAUDE_PLUGIN_ROOT}/templates/skills/shared/code-reviewer .claude/skills/
```

**iOS only** - Copy iOS-specific skills:

```bash
cp -r ${CLAUDE_PLUGIN_ROOT}/templates/skills/ios/preview .claude/skills/
cp -r ${CLAUDE_PLUGIN_ROOT}/templates/skills/ios/write-tests .claude/skills/
```

After copying iOS skills, replace `{{PROJECT_NAME}}` with the actual project name in:
- `.claude/skills/preview/SKILL.md`
- `.claude/skills/write-tests/SKILL.md`

## Step 4: Create context/ Directory

```bash
mkdir -p context
```

### Copy Architecture Guide

**iOS:**
```bash
cp ${CLAUDE_PLUGIN_ROOT}/templates/architecture/IOS_APP_ARCHITECTURE_GUIDE.md context/
```

**Android:**
```bash
cp ${CLAUDE_PLUGIN_ROOT}/templates/architecture/ANDROID_APP_ARCHITECTURE_GUIDE.md context/
```

**Backend:** No architecture guide to copy (not yet created).

## Step 5: Create CLAUDE.md

Read the template from `${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE.md.template` and create `CLAUDE.md` with these replacements:

| Placeholder | Replacement |
|-------------|-------------|
| `{{PROJECT_NAME}}` | Actual project name |
| `{{PROJECT_DESCRIPTION}}` | User-provided description |
| `{{ARCHITECTURE_GUIDE}}` | `IOS_APP_ARCHITECTURE_GUIDE.md` or `ANDROID_APP_ARCHITECTURE_GUIDE.md` |

Include appropriate sections based on project type (remove iOS-specific sections for Android/Backend, etc.).

### CLAUDE.md Content Structure

The template file at `${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE.md.template` is the source of truth. The structure below is illustrative:

```markdown
# {{PROJECT_NAME}}

{{PROJECT_DESCRIPTION}}

## Architecture

This project follows the patterns defined in `context/{{ARCHITECTURE_GUIDE}}`. Read this document before making changes.

## Context Directory

The `context/` directory contains documentation that helps Claude understand specific parts of the codebase:

[Include appropriate bullet points based on project type - see template]

## Skills Available

[List skills based on project type]

## Agents Available

- `code-reviewer` - Detailed code review for architecture compliance
- `privacy-reviewer` - Check for unintentional data collection/sharing
```

## Step 6: iOS-Specific Setup

### App Store Encryption Exemption

**Note**: If the project was just created via `references/ios-project-setup.md`, the encryption exemption is already included in `project.yml` under `settings.base.INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO`. Skip this step in that case.

For existing projects, check if using XcodeGen:

```bash
ls project.yml 2>/dev/null
```

**If XcodeGen (project.yml exists):**

Add to `project.yml` under `settings.base`:

```yaml
settings:
  base:
    INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO
```

**If standard Xcode project:**

Inform the user to add one of these:

Option 1 - Build setting:
```
INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO
```

Option 2 - Info.plist:
```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

This declares the app uses no custom encryption (HTTPS/TLS is exempt). Only set to YES if using proprietary or non-standard encryption algorithms.

## Step 7: Beads Task Runner Config

If [beads](https://github.com/anthropics/beads) is used for task tracking (or likely to be), set up the task runner config so `run-beads-tasks` works out of the box.

```bash
mkdir -p .beads
```

Copy the appropriate template:

```bash
# iOS
cp ${CLAUDE_PLUGIN_ROOT}/templates/beads-runner/ios.sh .beads/runner.sh

# Android
cp ${CLAUDE_PLUGIN_ROOT}/templates/beads-runner/android.sh .beads/runner.sh

# Backend
cp ${CLAUDE_PLUGIN_ROOT}/templates/beads-runner/backend.sh .beads/runner.sh
```

This config file is sourced by `run-beads-tasks` (from [claude-tools](https://github.com/anthropics/claude-tools)) to set platform-appropriate permissions, claude flags, and setup hooks. Without it, the runner uses minimal defaults (git + bd only).

## Step 8: Summary Output

After completing all steps, print a summary:

```
Project initialized successfully!

Created:
[iOS new project only:]
- project.yml (XcodeGen spec)
- {{PROJECT_NAME}}/ (source directories)
- {{PROJECT_NAME}}Tests/ (test directory)
- Mintfile, .swiftlint.yml, .swiftformat (linting)
[All projects:]
- .git/ (initialized)
- .gitignore ({type} template)
- .claude/settings.json (with sensible defaults)
- .claude/agents/code-reviewer.md
- .claude/agents/privacy-reviewer.md
- .claude/skills/code-reviewer/
[iOS only:]
- .claude/skills/preview/
- .claude/skills/write-tests/
[iOS/Android only:]
- context/{ARCHITECTURE_GUIDE}
- CLAUDE.md
[All projects:]
- .beads/runner.sh (task runner config)

Next steps:
1. Review CLAUDE.md and customize for your project
2. Add context docs for each major feature/page in context/
3. Run /code-reviewer after making changes
[iOS only:]
4. Run /preview to test UI changes
```

## Repair Mode

When files already exist, ask before overwriting each one:

- "`.gitignore` already exists. Overwrite with {type} template?"
- "`.claude/settings.json` already exists. Overwrite?"
- etc.

For partial setups (repair mode), only create missing components.
