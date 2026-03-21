---
description: "Review code changes for bugs, security, and quality issues"
argument-hint: "[staged|files path/to/file]"
---

Review current code changes using an isolated `claude -p` session for unbiased review.

## Determine Scope

Based on `$ARGUMENTS`:
- No args: review all uncommitted changes (`git diff HEAD`)
- `staged`: review only staged changes (`git diff --staged`)
- `files <path>`: review specific file(s) (`git diff HEAD -- <path>`)

## Process

1. Get the diff based on scope:

```bash
# Default: all changes
git diff HEAD

# Or staged only
git diff --staged

# Or specific files
git diff HEAD -- <path>
```

2. If there are no changes, tell the user "No changes to review" and stop.

3. Read `CLAUDE.md` if it exists (for project-specific rules).

4. Run the review in an isolated `claude -p` session. This ensures the reviewer has no bias from the current conversation:

```bash
unset ANTHROPIC_API_KEY && claude -p "<review prompt with diff>" --model sonnet
```

The review prompt should include:
- The full content of the review-prompt.md template from this plugin's prompts/ directory
- Project rules from CLAUDE.md (if exists)
- The git diff

5. Present the review output to the user. If issues are found, group by severity (Critical > Important) with file:line references and fix suggestions.
