# Detailed Setup Steps

Complete step-by-step instructions for project initialization.

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

Check if using XcodeGen:

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

## Step 7: Summary Output

After completing all steps, print a summary:

```
Project initialized successfully!

Created:
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
