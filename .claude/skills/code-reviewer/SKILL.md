---
name: code-reviewer
description: Review uncommitted code changes for bugs, shell-safety issues, and plugin/skill/hook hygiene. Use this skill after completing a change, before committing.
---

Spawn the `code-reviewer` agent to review your recent changes. Provide a one-sentence summary of what you implemented.

When the reviewer returns feedback, evaluate it critically — don't assume all feedback is valid. Fix the issues that are actually valid and briefly note what you changed.

If no issues found, tell the user the code passed review.
