---
name: code-reviewer
description: Review uncommitted code changes for bugs, architecture violations, and API integration issues. Use this skill after completing a feature or bug fix, before committing. Checks compliance with the project's architecture guide.
---

Spawn the `code-reviewer` agent to review your recent changes. Provide a one-sentence summary of what you implemented.

When the reviewer returns feedback, evaluate it critically - don't assume all feedback is valid. Fix the issues that are actually valid and briefly note what you changed.

If no issues found, tell the user the code passed review.
