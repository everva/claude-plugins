#!/bin/bash
# Single review using an isolated claude -p session
# Usage: review.sh [--staged] [--model MODEL]
#
# Environment:
#   CLAUDE_REVIEW_MODEL   Model to use (default: opus)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_FILE="$SCRIPT_DIR/../prompts/review-prompt.md"

# Parse arguments
STAGED_ONLY=false
MODEL="${CLAUDE_REVIEW_MODEL:-opus}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --staged) STAGED_ONLY=true; shift ;;
    --model) MODEL="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Get diff
if [[ "$STAGED_ONLY" == "true" ]]; then
  DIFF=$(git diff --staged 2>/dev/null)
else
  DIFF=$(git diff HEAD 2>/dev/null)
  # Include staged changes if no HEAD diff
  if [[ -z "$DIFF" ]]; then
    DIFF=$(git diff --staged 2>/dev/null)
  fi
fi

if [[ -z "$DIFF" ]]; then
  echo "STATUS: PASS"
  echo "SUMMARY: No changes to review."
  exit 0
fi

# Read review prompt template
if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "Error: Review prompt not found at $PROMPT_FILE" >&2
  exit 1
fi
REVIEW_PROMPT=$(cat "$PROMPT_FILE")

# Read CLAUDE.md if it exists (project-specific rules)
CLAUDE_MD=""
if [[ -f "CLAUDE.md" ]]; then
  CLAUDE_MD=$(cat CLAUDE.md)
fi

# Build full prompt
FULL_PROMPT="$REVIEW_PROMPT

$CLAUDE_MD

## Git Diff to Review

\`\`\`diff
$DIFF
\`\`\`"

# Run review in isolated session (unset API key to use subscription)
unset ANTHROPIC_API_KEY 2>/dev/null || true
claude -p "$FULL_PROMPT" --model "$MODEL"
