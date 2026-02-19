# Claude Code Tools

A collection of plugins and tools for [Claude Code](https://claude.ai/claude-code), Anthropic's AI-powered CLI for software development.

## Tools

### beads-runner

Process [beads](https://github.com/anthropics/beads) tasks sequentially, each in a fresh Claude Code session with clean 200k context.

**Features**:
- Fresh session per task (no autocompact drift)
- Per-task retry + systemic failure abort (stops on quota exhaustion)
- Stream parser with timestamped progress output
- Watchdog kills stuck sessions after 10 min idle
- Graceful stop: `touch .stop-beads` to finish current task then exit
- Model selection via beads labels (`bd label add <id> model:sonnet`)

**Per-project config**: Place a `.beads/runner.sh` in your project root to customize permissions, claude flags, prompt additions, and setup/teardown hooks. See `beads-runner/examples/` for iOS and Android configs.

**Usage**:
```bash
# From your project directory:
run-beads-tasks            # scoped permissions (default)
run-beads-tasks --yolo     # skip all permission prompts
```

**Installation**:
```bash
ln -s ~/code/claude-tools/beads-runner/run-beads-tasks.sh /usr/local/bin/run-beads-tasks
```

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
├── beads-runner/
│   ├── run-beads-tasks.sh
│   └── examples/
│       ├── ios.sh
│       └── android.sh
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
