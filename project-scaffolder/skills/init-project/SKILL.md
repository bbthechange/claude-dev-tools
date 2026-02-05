---
name: init-project
description: This skill should be used when the user asks to "initialize a project", "create a new iOS project", "start a new project", "set up Claude Code for this project", "create .claude directory", "set up git for this project", "add Claude configuration", or when starting a new project that needs Claude Code integration. Supports iOS, Android, and Backend project types with full project creation for iOS (XcodeGen).
---

# Initialize Project

Set up a project with Claude Code configuration, skills, agents, and best practices.

## Overview

Initialize projects with:
- New project creation (iOS XcodeGen setup, with Android/Backend coming later)
- Git repository and appropriate `.gitignore`
- `.claude/` directory with settings, agents, and skills
- `context/` directory for project documentation
- `CLAUDE.md` with project guidance
- Architecture guide (iOS/Android)
- Platform-specific setup (iOS encryption exemption)

## Workflow

### 1. Detect or Ask Project Type

Check for project indicators:
```bash
ls *.xcodeproj *.xcworkspace project.yml 2>/dev/null  # iOS
ls build.gradle build.gradle.kts 2>/dev/null  # Android
ls package.json 2>/dev/null  # Node.js
```

If no indicators found, ask the user:
- iOS (SwiftUI/UIKit)
- Android (Kotlin/Compose)
- Backend (Node.js, Python, etc.)

### 2. Get Project Details

Ask for project name (use detected name if available), a one-sentence description, and bundle ID prefix (iOS only, e.g., `com.yourcompany`).

### 3. Check Existing Setup

Before creating anything, check what already exists and ask before overwriting. See `references/setup-steps.md` Repair Mode for the full checklist and handling.

For iOS, also check if a project already exists (`project.yml`, `*.xcodeproj`, `*.swift` source files). If no existing project is found, it will be created from scratch in step 4.

### 4. Execute Setup

**For new iOS projects** (no existing source files, project.yml, or .xcodeproj): First follow `references/ios-project-setup.md` to create the Xcode project, verify it builds, and make an initial git commit.

Then follow `references/setup-steps.md` for Claude Code configuration:
- Git initialization (skipped if already done by project setup)
- Copying templates from `${CLAUDE_PLUGIN_ROOT}/templates/`
- Creating directory structure
- Platform-specific configuration

### 5. Report Summary

Use the summary template in `references/setup-steps.md` Step 7 to list all created files and provide next steps guidance.

## Template Locations

All templates are in `${CLAUDE_PLUGIN_ROOT}/templates/`:

| Template | Path |
|----------|------|
| Gitignore | `gitignore/{ios,android,backend}.gitignore` |
| Settings | `settings/{ios,android,backend}.json` |
| Agents | `agents/{code-reviewer,privacy-reviewer}.md` |
| Skills | `skills/{shared,ios}/` |
| Architecture | `architecture/{IOS,ANDROID}_APP_ARCHITECTURE_GUIDE.md` |
| CLAUDE.md | `CLAUDE.md.template` |
| iOS scripts | `scripts/ios/sim.sh` |
| iOS deep links | `deeplink/DeepLinkHandler.swift` |
| iOS Info.plist | `info-plist/ios-Info.plist` |

## Platform-Specific Notes

### iOS

- **New projects**: Follow `references/ios-project-setup.md` for full XcodeGen project creation (includes encryption exemption in `project.yml`)
- Copy preview and write-tests skills
- For existing projects without encryption exemption, add it (see `references/setup-steps.md`)
- Replace `{{PROJECT_NAME}}` and `{{BUNDLE_PREFIX}}` placeholders in copied files

### Android

- Copy architecture guide to `context/`
- No additional skills beyond shared ones currently

### Backend

- No architecture guide (not yet created)
- Basic settings with curl, docker permissions

## Additional Resources

### Reference Files

- **`references/setup-steps.md`** - Detailed step-by-step Claude Code setup instructions
- **`references/ios-project-setup.md`** - iOS XcodeGen project creation from scratch (stack, prerequisites, project.yml, linting, verification)
