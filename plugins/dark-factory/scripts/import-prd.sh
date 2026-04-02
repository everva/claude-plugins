#!/usr/bin/env bash
# Dark Factory — PRD Import: parses a PRD file and populates the backlog.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/config.sh"

usage() {
  echo "Usage: $0 <prd-file> [--format issue+spec|spec-only] [--dry-run]"
  exit 1
}

# --- Parse args ---
PRD_FILE="" FORMAT="" DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --format)  FORMAT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage ;;
    *)         PRD_FILE="$1"; shift ;;
  esac
done
[[ -z "$PRD_FILE" ]] && usage
[[ ! -r "$PRD_FILE" ]] && { echo "Error: cannot read '$PRD_FILE'"; exit 1; }

load_project_config
FORMAT="${FORMAT:-$DF_BACKLOG_FORMAT}"
BACKLOG="$DF_BACKLOG_FILE"
SPEC_DIR="$DF_PROJECT_DIR/docs/specs"

log() { echo "[import-prd] $*"; }

# --- Slugify helper ---
slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//'
}

# --- Extract tasks via claude -p ---
log "Parsing PRD: $PRD_FILE (format=$FORMAT)"
PROMPT="You are a requirements analyst. Read this PRD and extract discrete implementation tasks.
Output ONLY a JSON array. Each element: {\"title\": \"short title\", \"spec_summary\": \"1-3 sentence spec\", \"governance_tier\": \"T0\" or \"T1\", \"complexity\": \"low\"|\"medium\"|\"high\"}
No markdown fences, no commentary — just the JSON array."

TASKS_JSON=$(claude -p "$PROMPT" < "$PRD_FILE")

# Validate JSON (use jq — already a dependency of the plugin)
if ! echo "$TASKS_JSON" | jq empty 2>/dev/null; then
  # Try extracting JSON array from markdown fences
  EXTRACTED=$(echo "$TASKS_JSON" | sed -n '/^\[/,/^\]/p')
  if [ -z "$EXTRACTED" ]; then
    EXTRACTED=$(echo "$TASKS_JSON" | sed -n '/```/,/```/p' | sed '1d;$d')
  fi
  if echo "$EXTRACTED" | jq empty 2>/dev/null; then
    TASKS_JSON="$EXTRACTED"
  else
    echo "Error: failed to parse JSON from claude output"; exit 1
  fi
fi

COUNT=$(echo "$TASKS_JSON" | jq 'length')
log "Extracted $COUNT tasks"

# --- Determine next row number for issue+spec ---
if [[ "$FORMAT" == "issue+spec" ]]; then
  NEXT_NUM=$(grep -cE '^\| [0-9]' "$BACKLOG" 2>/dev/null || echo 0)
  NEXT_NUM=$((NEXT_NUM + 1))
fi

# --- Create specs and append rows ---
mkdir -p "$SPEC_DIR"

while IFS='|' read -r title summary tier complexity; do
  slug=$(slugify "$title")
  spec_path="docs/specs/${slug}.intent.md"
  full_spec="$DF_PROJECT_DIR/$spec_path"

  if $DRY_RUN; then
    log "[dry-run] Would create spec: $spec_path"
    if [[ "$FORMAT" == "issue+spec" ]]; then
      log "[dry-run] Would add row: #${NEXT_NUM:-?} | $title | $spec_path | $tier | pending"
    else
      log "[dry-run] Would add row: $spec_path | pending"
    fi
  else
    # Write intent spec
    cat > "$full_spec" <<SPEC
# $title

**Complexity**: $complexity | **Governance**: $tier

## Intent

$summary
SPEC
    log "Created spec: $spec_path"

    # Append to backlog (insert before "## In Progress" line, or append to end)
    if [[ "$FORMAT" == "issue+spec" ]]; then
      ROW="| ${NEXT_NUM} | $title | \`$spec_path\` | $tier | pending | |"
      NEXT_NUM=$((NEXT_NUM + 1))
    else
      ROW="| \`$spec_path\` | pending |"
    fi

    if grep -q "^## In Progress" "$BACKLOG" 2>/dev/null; then
      # Insert before "## In Progress" — portable sed (no -i)
      tmp_bl="${BACKLOG}.tmp"
      awk -v row="$ROW" '/^## In Progress/{print row}1' "$BACKLOG" > "$tmp_bl" && mv "$tmp_bl" "$BACKLOG"
    else
      echo "$ROW" >> "$BACKLOG"
    fi
    log "Added backlog row: $title"
  fi
done < <(echo "$TASKS_JSON" | jq -r '.[] | [.title, .spec_summary, .governance_tier, .complexity] | join("|")')

log "Done. $COUNT tasks imported ($( $DRY_RUN && echo 'dry-run' || echo 'written'))."
