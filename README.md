# Claude Code Tools

A collection of plugins and tools for [Claude Code](https://claude.ai/claude-code), Anthropic's AI-powered CLI for software development.

## Plugins

### project-scaffolder

Initialize new projects with Claude Code configuration, skills, agents, and best practices.

**Command**: `/init-project`

**Features**:
- Auto-detects project type (iOS, Android, Backend) or asks
- Initializes git with appropriate `.gitignore`
- Sets up `.claude/` directory with:
  - `settings.json` - Sensible permission defaults for the project type
  - `agents/` - Code reviewer and privacy reviewer agents
  - `skills/` - Project-type-specific skills
- Creates `context/` directory for project documentation
- Copies architecture guide templates (MVVM for iOS, MVI for Android)
- Creates `CLAUDE.md` with project-specific guidance
- iOS: Adds App Store encryption exemption

**Supported Project Types**:
- **iOS** (SwiftUI/UIKit): MVVM architecture, preview skill, test writing skill
- **Android** (Kotlin/Compose): MVI architecture
- **Backend**: Generic setup with API-focused tools

## Installation

The plugins are symlinked into `~/.claude/plugins/` for global availability:

```bash
# Clone this repo
git clone https://github.com/yourusername/claude-tools.git ~/code/claude-tools

# Symlink plugins into Claude's plugin directory
mkdir -p ~/.claude/plugins
ln -s ~/code/claude-tools/project-scaffolder ~/.claude/plugins/project-scaffolder
```

## Usage

In any project directory:

```bash
claude
> /init-project
```

The command will guide you through setup, detecting what exists and asking before overwriting.

## Structure

```
claude-tools/
├── README.md
└── project-scaffolder/
    ├── plugin.json
    ├── commands/
    │   └── init-project.md
    └── templates/
        ├── gitignore/
        │   ├── ios.gitignore
        │   ├── android.gitignore
        │   └── backend.gitignore
        ├── architecture/
        │   ├── IOS_APP_ARCHITECTURE_GUIDE.md
        │   └── ANDROID_APP_ARCHITECTURE_GUIDE.md
        ├── skills/
        │   ├── shared/code-reviewer/
        │   └── ios/{preview,write-tests}/
        ├── agents/
        │   ├── code-reviewer.md
        │   └── privacy-reviewer.md
        ├── settings/
        │   ├── common.json
        │   ├── ios.json
        │   ├── android.json
        │   └── backend.json
        └── CLAUDE.md.template
```

## Philosophy

These tools encode best practices learned from building production apps:

1. **Architecture guides** - Consistent patterns (MVVM/MVI) that Claude can reference and enforce
2. **Code review** - Automated checks for architecture violations before committing
3. **Privacy review** - Catch unintentional data collection/sharing
4. **Context-driven** - The `context/` directory pattern helps Claude understand your codebase
5. **Sensible defaults** - Pre-approved common commands reduce permission friction

## Contributing

Feel free to open issues or PRs for:
- New project type templates
- Additional skills/agents
- Improvements to architecture guides
