#!/bin/bash
# Dark Factory Plugin — GitHub Issue to Backlog Sync
# Reads GitHub Issues with status:ready, generates intent spec files,
# and populates the backlog.
#
# Usage: ./sync-backlog.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PLUGIN_ROOT/lib/config.sh"
load_project_config

BACKLOG_FILE="$DF_BACKLOG_FILE"
SPECS_DIR="$DF_PROJECT_DIR/docs/specs"
TEMPLATE_FILE="$DF_PROJECT_DIR/docs/templates/intent-spec.md"
DRY_RUN="${1:-}"

if [ -z "$DF_GITHUB_REPO" ]; then
  echo "ERROR: github_repo not configured in .dark-factory/config.yaml"
  exit 1
fi

echo "Syncing GitHub issues to Dark Factory backlog for $DF_PROJECT_NAME..."

mkdir -p "$SPECS_DIR"

ISSUES=$(gh issue list -R "$DF_GITHUB_REPO" \
  --label "${DF_ISSUE_SYNC_LABEL:-status:ready}" \
  --state open \
  --json number,title,body,labels \
  --limit 50 \
  2>/dev/null || echo "[]")

if [ "$ISSUES" = "[]" ]; then
  echo "No ready issues found."
  exit 0
fi

ISSUE_COUNT=$(echo "$ISSUES" | jq '. | length')
echo "Found $ISSUE_COUNT ready issues"

ADDED=0
SKIPPED=0
GENERATED=0

while read -r issue; do
  NUMBER=$(echo "$issue" | jq -r '.number')
  TITLE=$(echo "$issue" | jq -r '.title')
  BODY=$(echo "$issue" | jq -r '.body // ""')
  LABELS=$(echo "$issue" | jq -r '[.labels[].name] | join(",")' 2>/dev/null || echo "")

  LAYER=$(echo "$LABELS" | tr ',' '\n' | grep '^layer:' | head -1 | cut -d: -f2 || true)
  LAYER=${LAYER:-backend}

  PIPELINE=$(echo "$LABELS" | tr ',' '\n' | grep '^pipeline:' | head -1 | cut -d: -f2 || true)
  PIPELINE=${PIPELINE:-standard}

  SAFE_TITLE=$(echo "$TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//' | head -c 50)
  SPEC_FILE="docs/specs/${LAYER}-${SAFE_TITLE}.intent.md"
  SPEC_PATH="$DF_PROJECT_DIR/$SPEC_FILE"

  if grep -q "$SPEC_FILE" "$BACKLOG_FILE" 2>/dev/null; then
    echo "  #$NUMBER: Already in backlog — skipping"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  if [ "$DRY_RUN" = "--dry-run" ]; then
    echo "  [DRY RUN] Would generate: $SPEC_FILE from issue #$NUMBER"
    continue
  fi

  if [ -f "$SPEC_PATH" ]; then
    echo "  #$NUMBER: Spec exists ($SPEC_FILE), adding to backlog"
  else
    echo "  #$NUMBER: Generating intent spec from issue..."

    timeout 120 claude -p "Generate an intent-spec file from this GitHub issue for the $DF_PROJECT_NAME project.

Issue #$NUMBER: $TITLE
Layer: $LAYER
Pipeline: $PIPELINE
Labels: $LABELS

Issue body:
$BODY

## Instructions
1. Read the template from $TEMPLATE_FILE for the expected format (if it exists)
2. Read CLAUDE.md for project context
3. Fill in ALL sections: Intent, Context, Behavior (GIVEN/WHEN/THEN), Constraints, Acceptance Criteria, Not In Scope, Holdout Scenarios, Notes
4. For Holdout Scenarios, generate 2-4 behavioral tests for edge cases and security boundaries
5. Include 'Related Issues: #$NUMBER' in Context

Output ONLY the markdown content for the intent-spec file. No preamble." \
      --max-budget-usd 1 \
      --allowedTools "Read" \
      > "$SPEC_PATH" 2>/dev/null || {
        echo "  ERROR: Failed to generate spec for #$NUMBER"
        continue
      }

    echo "  Generated: $SPEC_FILE"
    GENERATED=$((GENERATED + 1))
  fi

  TIER_EST="T1"
  if echo "$LABELS" | grep -qE 'pipeline:full'; then
    TIER_EST="T2"
  fi

  if sed --version 2>/dev/null | grep -q GNU; then
    sed -i "/^## In Progress/i\\| $NUMBER | \`$SPEC_FILE\` | $LAYER | $PIPELINE | $TIER_EST | pending | — |" "$BACKLOG_FILE" 2>/dev/null
  else
    sed -i '' "/^## In Progress/i\\
| $NUMBER | \`$SPEC_FILE\` | $LAYER | $PIPELINE | $TIER_EST | pending | — |
" "$BACKLOG_FILE" 2>/dev/null
  fi || echo "| $NUMBER | \`$SPEC_FILE\` | $LAYER | $PIPELINE | $TIER_EST | pending | — |" >> "$BACKLOG_FILE"

  echo "  Added to backlog: $SPEC_FILE"
  ADDED=$((ADDED + 1))
done < <(echo "$ISSUES" | jq -c 'sort_by(.number) | .[]' 2>/dev/null)

echo ""
echo "Sync complete. Added: $ADDED, Skipped: $SKIPPED, Specs generated: $GENERATED"
