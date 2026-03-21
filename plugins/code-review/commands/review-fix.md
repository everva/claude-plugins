---
description: "Review changes in isolated session, fix issues, re-review until clean (max N iterations)"
argument-hint: "[max_iterations (default: 3)]"
---

Start a review-fix loop where:
- **Reviewer** = new `claude -p` session each time (unbiased, clean context)
- **Fixer** = this current session (preserves project context)
- Loop until review passes or max iterations reached

## Setup

Parse max iterations from arguments (default: 3):
```
MAX_ITERATIONS = $ARGUMENTS or 3
```

## Loop (repeat for each iteration)

### Step 1: Get Current Diff

```bash
git diff HEAD
```

If no changes exist, report "No changes to review" and stop.

### Step 2: Run Review in Isolated Session

Read the review prompt template:
```bash
cat "${CLAUDE_PLUGIN_ROOT}/prompts/review-prompt.md"
```

Read project rules if available:
```bash
cat CLAUDE.md 2>/dev/null || echo "No CLAUDE.md found"
```

Run the review in a NEW, isolated `claude -p` session:
```bash
unset ANTHROPIC_API_KEY && claude -p "<review-prompt>

<CLAUDE.md content>

## Git Diff to Review

<diff content>" --model sonnet
```

### Step 3: Parse Review Result

Check the output for `STATUS: PASS` or `STATUS: FAIL`.

- If `STATUS: PASS` → Report success to user, show summary, STOP the loop.
- If `STATUS: FAIL` → Continue to Step 4.

### Step 4: Fix Issues (in THIS session)

For each `ISSUE:` line in the review output:
1. Read the file at the specified line number
2. Understand the surrounding context
3. Apply the minimal fix suggested in the `FIX:` line
4. Do NOT make any changes beyond what the review asks for
5. Do NOT refactor, improve, or change style

### Step 5: Confirm and Continue

After fixing all issues:
- Show the user what was fixed
- Report the current iteration number: "Iteration N/MAX completed, re-reviewing..."
- Go back to Step 1 (new review session)

## Completion

When the loop ends, report:
- **If PASS**: "Review clean after N iteration(s)"
- **If max iterations reached**: "Max iterations (N) reached. Remaining issues: ..." and list any unfixed issues from the last review

## Safety Rules

- Never fix issues with confidence < 80
- Never change functionality while fixing
- If the same issue persists after 2 fix attempts, skip it and report
- Maximum iterations: respect the limit, never exceed it
