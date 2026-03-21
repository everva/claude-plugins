#!/bin/bash
# Install the Claude Code review pre-commit hook
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SOURCE="$SCRIPT_DIR/git-pre-commit-review.sh"

# Find git root
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [[ -z "$GIT_ROOT" ]]; then
  echo "Error: Not in a git repository" >&2
  exit 1
fi

HOOKS_DIR="$GIT_ROOT/.git/hooks"
HOOK_TARGET="$HOOKS_DIR/pre-commit"

# Create hooks directory if it doesn't exist
mkdir -p "$HOOKS_DIR"

# Backup existing hook
if [[ -f "$HOOK_TARGET" ]]; then
  BACKUP="${HOOK_TARGET}.bak.$(date +%Y%m%d%H%M%S)"
  echo "⚠️  Existing pre-commit hook found, backing up to $(basename "$BACKUP")"
  cp "$HOOK_TARGET" "$BACKUP"
fi

# Copy hook
cp "$HOOK_SOURCE" "$HOOK_TARGET"
chmod +x "$HOOK_TARGET"

echo "✅ Installed Claude Code review pre-commit hook"
echo "   Location: $HOOK_TARGET"
echo ""
echo "Usage:"
echo "   git commit ...                        # Review runs automatically"
echo "   CLAUDE_REVIEW_SKIP=1 git commit ...   # Skip review"
echo "   CLAUDE_REVIEW_TIMEOUT=60 git commit   # Custom timeout (default: 120s)"
