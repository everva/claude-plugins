#!/bin/bash
# Dark Factory Plugin — Holdout Guard Hook
# Prevents implementation agents from accessing holdout scenarios.
# This is a PreToolUse hook that runs before Read, Bash, Glob, Grep operations.
# It blocks any attempt to access holdout validation content during development.

INPUT=$(cat)

# Extract ALL relevant fields (command, file_path, pattern, path) and join them
# This prevents bypass via Glob tool where pattern and path are separate fields
CMD=$(echo "$INPUT" | jq -r '
  [.tool_input.command, .tool_input.file_path, .tool_input.pattern, .tool_input.path]
  | map(select(. != null and . != ""))
  | join(" ")' 2>/dev/null)

# Allow directory creation and management (mkdir, ls, touch, chmod)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)
if [ "$TOOL_NAME" = "Bash" ]; then
  if echo "$CMD" | grep -qE '^mkdir |^ls |^touch |^chmod '; then
    echo '{}'
    exit 0
  fi
fi

# Skip non-reading Bash commands (git, etc.) — only block file reads
if [ "$TOOL_NAME" = "Bash" ]; then
  if echo "$CMD" | grep -qE '^git '; then
    echo '{}'
    exit 0
  fi
  if ! echo "$CMD" | grep -qE 'cat |head |tail |less |more |bat |source |\.[ ]'; then
    echo '{}'
    exit 0
  fi
fi

# Block READING holdout scenario content
if echo "$CMD" | grep -qiE '\.dark-factory/holdouts/|dark-factory/holdouts|holdout\.yaml|holdout\.yml|\.holdout\.'; then
  # Only holdout-validator and satisfaction-judge agents can access
  AGENT_NAME=$(echo "$INPUT" | jq -r '.agent_name // ""' 2>/dev/null)
  if [ "$AGENT_NAME" = "holdout-validator" ] || [ "$AGENT_NAME" = "satisfaction-judge" ]; then
    echo '{}'
    exit 0
  fi

  # Allow sub-agents spawned with holdout-related names
  if echo "$AGENT_NAME" | grep -qE '^holdout-'; then
    echo '{}'
    exit 0
  fi

  # Environment variable bypass for run-task.sh validation phase
  if [ "${HOLDOUT_VALIDATOR_MODE:-}" = "true" ]; then
    echo '{}'
    exit 0
  fi

  # Marker file bypass — created before holdout validation, removed after
  if [ -f "/tmp/.dark-factory-holdout-validate" ]; then
    echo '{}'
    exit 0
  fi

  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","reason":"Access to holdout validation scenarios is blocked during development. Holdout scenarios are agent-invisible behavioral tests that run only during validation. This ensures implementation agents cannot game the tests."}}'
  exit 0
fi

# Allow all other operations
echo '{}'
