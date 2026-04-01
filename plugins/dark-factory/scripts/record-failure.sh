#!/bin/bash
# Dark Factory Plugin — Failure Recorder
# Appends failure patterns to failure-patterns.md for future iterations to learn from.
# Called by ralph.sh when a task fails or is exhausted.
#
# Usage: ./record-failure.sh <task-label> <session-id> <reason>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PLUGIN_ROOT/lib/config.sh"
load_project_config

TASK_LABEL="${1:?Usage: record-failure.sh <task-label> <session-id> <reason>}"
SESSION_ID="${2:?Missing session-id}"
REASON="${3:-unknown}"

GUARDRAILS_FILE="${DF_GUARDRAILS_FILE:-$DF_FACTORY_DIR/failure-patterns.md}"
SESSION_DIR="$DF_FACTORY_DIR/sessions/$SESSION_ID"
DATE=$(date +%Y-%m-%d)

# Extract layer from session log if available (POSIX-compatible, no grep -P)
LAYER="unknown"
if [ -f "$SESSION_DIR/run.log" ]; then
  LAYER=$(grep -o 'Layer: [^ |]*' "$SESSION_DIR/run.log" 2>/dev/null | head -1 | sed 's/Layer: //' || true)
  LAYER="${LAYER:-unknown}"
fi

# Extract error details from session artifacts
ERROR_SUMMARY=""
if [ -f "$SESSION_DIR/implementation-stderr.log" ]; then
  ERROR_SUMMARY=$(tail -5 "$SESSION_DIR/implementation-stderr.log" 2>/dev/null | head -3 || true)
fi
if [ -z "$ERROR_SUMMARY" ] && [ -f "$SESSION_DIR/implementation-result.txt" ]; then
  ERROR_SUMMARY=$({ grep -i 'error\|fail\|exception' "$SESSION_DIR/implementation-result.txt" 2>/dev/null || true; } | tail -3)
fi

# Extract holdout/satisfaction failures if relevant
HOLDOUT_NOTE=""
if [ -f "$SESSION_DIR/holdout-result.json" ]; then
  HOLDOUT_PASS=$(jq -r '.overall_pass // "unknown"' "$SESSION_DIR/holdout-result.json" 2>/dev/null || echo "unknown")
  HOLDOUT_SCORE=$(jq -r '.overall_score // "?"' "$SESSION_DIR/holdout-result.json" 2>/dev/null || echo "?")
  if [ "$HOLDOUT_PASS" = "false" ]; then
    HOLDOUT_NOTE="Holdout failed (score: $HOLDOUT_SCORE)"
  fi
fi

SAT_NOTE=""
for sat_file in "$SESSION_DIR/satisfaction-parsed.json" "$SESSION_DIR/satisfaction-result.json"; do
  [ -f "$sat_file" ] || continue
  SAT_SCORE=$(jq -r '.final_score // .composite_score // .score // empty' "$sat_file" 2>/dev/null || echo "")
  if [ -n "$SAT_SCORE" ] && [ "$SAT_SCORE" != "null" ]; then
    SAT_INT=$(echo "$SAT_SCORE" | cut -d. -f1)
    SAT_INT="${SAT_INT:-0}"
    if [ "$SAT_INT" -lt 50 ]; then
      SAT_NOTE="Satisfaction low ($SAT_INT)"
    fi
    break
  fi
done

# Append to guardrails file
{
  echo ""
  echo "### [$DATE] [$LAYER] $REASON: $TASK_LABEL"
  echo "- **Root Cause**: ${ERROR_SUMMARY:-No error details captured}"
  if [ -n "$HOLDOUT_NOTE" ]; then
    echo "- **Holdout**: $HOLDOUT_NOTE"
  fi
  if [ -n "$SAT_NOTE" ]; then
    echo "- **Satisfaction**: $SAT_NOTE"
  fi
  echo "- **Prevention**: (to be filled by pipeline-doctor or human)"
  echo "- **Session**: $SESSION_ID"
} >> "$GUARDRAILS_FILE"

echo "[record-failure] Appended failure pattern for $TASK_LABEL to $GUARDRAILS_FILE"
