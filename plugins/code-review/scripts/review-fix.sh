#!/bin/bash
# Multi-session review-fix loop (terminal usage, outside Claude Code)
#
# Usage: review-fix.sh [MAX_ITERATIONS]
#
# Each review runs in a NEW claude -p session (unbiased).
# Each fix runs in a NEW claude -p session (terminal mode can't persist sessions).
# For persistent fixer session, use /review-fix inside Claude Code instead.
#
# Environment:
#   CLAUDE_REVIEW_MODEL    Model for review (default: opus)
#   CLAUDE_FIX_MODEL       Model for fix (default: opus)
#   CLAUDE_REVIEW_SKIP     Set to 1 to skip

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW_PROMPT_FILE="$SCRIPT_DIR/../prompts/review-prompt.md"
FIX_PROMPT_FILE="$SCRIPT_DIR/../prompts/fix-prompt.md"

MAX_ITERATIONS="${1:-3}"
REVIEW_MODEL="${CLAUDE_REVIEW_MODEL:-opus}"
FIX_MODEL="${CLAUDE_FIX_MODEL:-opus}"
ITERATION=0

# Validate
if [[ ! -f "$REVIEW_PROMPT_FILE" ]]; then
  echo "Error: Review prompt not found at $REVIEW_PROMPT_FILE" >&2
  exit 1
fi

if [[ ! -f "$FIX_PROMPT_FILE" ]]; then
  echo "Error: Fix prompt not found at $FIX_PROMPT_FILE" >&2
  exit 1
fi

if ! command -v claude &>/dev/null; then
  echo "Error: claude CLI not found" >&2
  exit 1
fi

# Read templates
REVIEW_PROMPT=$(cat "$REVIEW_PROMPT_FILE")
FIX_PROMPT=$(cat "$FIX_PROMPT_FILE")

# Read project rules
CLAUDE_MD=""
if [[ -f "CLAUDE.md" ]]; then
  CLAUDE_MD=$(cat CLAUDE.md)
fi

echo "================================================"
echo "  Code Review + Fix Loop"
echo "  Max iterations: $MAX_ITERATIONS"
echo "  Review model: $REVIEW_MODEL"
echo "  Fix model: $FIX_MODEL"
echo "================================================"
echo ""

while [[ $ITERATION -lt $MAX_ITERATIONS ]]; do
  ITERATION=$((ITERATION + 1))
  echo "--- Iteration $ITERATION/$MAX_ITERATIONS ---"
  echo ""

  # Get current diff
  DIFF=$(git diff HEAD 2>/dev/null)
  if [[ -z "$DIFF" ]]; then
    DIFF=$(git diff --staged 2>/dev/null)
  fi

  if [[ -z "$DIFF" ]]; then
    echo "STATUS: PASS"
    echo "SUMMARY: No changes to review."
    exit 0
  fi

  # REVIEW SESSION (new, isolated)
  echo "🔍 Running review session..."
  REVIEW_OUTPUT=$(unset ANTHROPIC_API_KEY 2>/dev/null; claude -p "$REVIEW_PROMPT

$CLAUDE_MD

## Git Diff to Review

\`\`\`diff
$DIFF
\`\`\`" --model "$REVIEW_MODEL" 2>/dev/null)

  echo "$REVIEW_OUTPUT"
  echo ""

  # Check result
  if echo "$REVIEW_OUTPUT" | grep -q "STATUS: PASS"; then
    echo "================================================"
    echo "  ✅ Review PASSED at iteration $ITERATION"
    echo "================================================"
    exit 0
  fi

  # Extract issues for fix session
  ISSUES=$(echo "$REVIEW_OUTPUT" | grep -E "^(ISSUE|FIX):" || true)

  if [[ -z "$ISSUES" ]]; then
    echo "⚠️  Review returned FAIL but no parseable issues. Stopping."
    echo "$REVIEW_OUTPUT"
    exit 1
  fi

  if [[ $ITERATION -ge $MAX_ITERATIONS ]]; then
    echo "================================================"
    echo "  ⛔ Max iterations ($MAX_ITERATIONS) reached"
    echo "  Remaining issues:"
    echo "$ISSUES"
    echo "================================================"
    exit 1
  fi

  # FIX SESSION (new session in terminal mode)
  echo "🔧 Running fix session..."
  unset ANTHROPIC_API_KEY 2>/dev/null || true
  claude -p "$FIX_PROMPT

## Review Report

$REVIEW_OUTPUT" --model "$FIX_MODEL" --allowedTools "Edit,Read,Write,Glob,Grep,Bash" 2>/dev/null

  echo ""
  echo "🔧 Fix session completed, re-reviewing..."
  echo ""
done

echo "================================================"
echo "  ⛔ Max iterations ($MAX_ITERATIONS) reached"
echo "================================================"
exit 1
