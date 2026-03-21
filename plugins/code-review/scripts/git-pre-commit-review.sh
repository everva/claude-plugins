#!/bin/bash
# Git pre-commit hook: review staged changes with claude -p
#
# Install: ./install-git-hook.sh
# Skip:    CLAUDE_REVIEW_SKIP=1 git commit ...
#
# Environment:
#   CLAUDE_REVIEW_SKIP      Set to 1 to skip review
#   CLAUDE_REVIEW_MODEL     Model to use (default: opus)

set -euo pipefail

# Allow skipping
if [[ "${CLAUDE_REVIEW_SKIP:-0}" == "1" ]]; then
  exit 0
fi

# Check if claude is available
if ! command -v claude &>/dev/null; then
  echo "Warning: claude CLI not found, skipping review" >&2
  exit 0
fi

# Get staged changes (only added, copied, modified, renamed files)
DIFF=$(git diff --staged --diff-filter=ACMR)

if [[ -z "$DIFF" ]]; then
  exit 0
fi

MODEL="${CLAUDE_REVIEW_MODEL:-opus}"
STAGED_FILES=$(git diff --staged --name-only --diff-filter=ACMR)

echo "🔍 Running Claude Code review on staged changes..."

# Read CLAUDE.md if exists
CLAUDE_MD=""
if [[ -f "CLAUDE.md" ]]; then
  CLAUDE_MD="
## Project Rules (from CLAUDE.md)

$(cat CLAUDE.md)"
fi

REVIEW_PROMPT="You are a code reviewer. Review the following staged git diff for CRITICAL issues ONLY.

Only report issues with confidence >= 90. Focus exclusively on:
- Security vulnerabilities (hardcoded secrets, injection, auth bypass)
- Bugs that WILL crash or cause data loss
- Breaking changes to public APIs

Do NOT flag: style issues, minor improvements, anything a linter catches, type hints.

Output format (use EXACTLY this format):

If no critical issues:
STATUS: PASS
SUMMARY: Brief confirmation.

If critical issues found:
STATUS: FAIL
SUMMARY: Brief assessment.

ISSUE: [CRITICAL] confidence:N file:line - Description
FIX: How to fix
$CLAUDE_MD

## Staged Files
$STAGED_FILES

## Diff
\`\`\`diff
$DIFF
\`\`\`"

# Run review (unset API key to use subscription)
RESULT=$(unset ANTHROPIC_API_KEY 2>/dev/null; claude -p "$REVIEW_PROMPT" --model "$MODEL" 2>/dev/null)

if echo "$RESULT" | grep -q "STATUS: FAIL"; then
  echo ""
  echo "============================================"
  echo "  Claude Code Review: CRITICAL ISSUES FOUND"
  echo "============================================"
  echo ""
  echo "$RESULT"
  echo ""
  echo "Commit blocked. Fix issues or skip with:"
  echo "  CLAUDE_REVIEW_SKIP=1 git commit ..."
  echo "============================================"
  exit 1
fi

echo "✅ Claude review: PASS"
exit 0
