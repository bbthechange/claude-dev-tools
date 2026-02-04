---
name: init-project
description: This skill should be used when the user asks to "initialize a project", "set up Claude Code for this project", "scaffold project config", "create .claude directory", "set up git for this project", "add Claude configuration", or when starting a new project that needs Claude Code integration. Supports iOS, Android, and Backend project types.
---

# Initialize Project

Set up a project with Claude Code configuration, skills, agents, and best practices.

## Overview

This skill initializes projects with:
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
ls *.xcodeproj *.xcworkspace 2>/dev/null  # iOS
ls build.gradle build.gradle.kts 2>/dev/null  # Android
ls package.json 2>/dev/null  # Node.js
```

If no indicators found, ask the user:
- iOS (SwiftUI/UIKit)
- Android (Kotlin/Compose)
- Backend (Node.js, Python, etc.)

### 2. Get Project Details

Ask for project name (use detected name if available) and a one-sentence description.

### 3. Check Existing Setup

Before creating anything, check what exists and ask before overwriting:
- `.git/`
- `.gitignore`
- `.claude/`
- `context/`
- `CLAUDE.md`

### 4. Execute Setup

Follow the detailed steps in `references/setup-steps.md`, which covers:
- Git initialization
- Copying templates from `${CLAUDE_PLUGIN_ROOT}/templates/`
- Creating directory structure
- Platform-specific configuration

### 5. Report Summary

List all created files and provide next steps guidance.

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

## Platform-Specific Notes

### iOS

- Copy preview and write-tests skills
- Add App Store encryption exemption (see `references/setup-steps.md`)
- Replace `{{PROJECT_NAME}}` placeholders in copied files

### Android

- Copy architecture guide to `context/`
- No additional skills beyond shared ones currently

### Backend

- No architecture guide (not yet created)
- Basic settings with curl, docker permissions

## Additional Resources

### Reference Files

- **`references/setup-steps.md`** - Detailed step-by-step setup instructions with all commands and file operations
