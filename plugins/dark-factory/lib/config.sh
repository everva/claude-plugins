#!/bin/bash
# Dark Factory Plugin — Configuration Loader
# Reads project-specific config from .dark-factory/config.yaml
# Sourced by all scripts.

# Resolve project directory
# Priority: $CLAUDE_PROJECT_DIR > $PROJECT_DIR > git root > pwd
resolve_project_dir() {
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    echo "$CLAUDE_PROJECT_DIR"
  elif [ -n "${PROJECT_DIR:-}" ]; then
    echo "$PROJECT_DIR"
  else
    local git_root
    git_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [ -n "$git_root" ]; then
      echo "$git_root"
    else
      pwd
    fi
  fi
}

# Resolve plugin root
# Priority: $CLAUDE_PLUGIN_ROOT > script location heuristic
resolve_plugin_root() {
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    echo "$CLAUDE_PLUGIN_ROOT"
  else
    # Fallback: assume we're in lib/ or scripts/ under plugin root
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local parent
    parent="$(dirname "$script_dir")"
    if [ -f "$parent/.claude-plugin/plugin.json" ]; then
      echo "$parent"
    else
      echo "$script_dir"
    fi
  fi
}

# Read a YAML value (simple key: value format, no nested support)
# Usage: yaml_val <file> <key> <default>
yaml_val() {
  local file="$1" key="$2" default="${3:-}"
  if [ ! -f "$file" ]; then
    echo "$default"
    return
  fi
  local val
  val=$(grep -E "^${key}:" "$file" 2>/dev/null | head -1 | sed "s/^${key}:[[:space:]]*//" | sed 's/[[:space:]]*$//' | sed 's/^"//' | sed 's/"$//' | sed "s/^'//" | sed "s/'$//")
  echo "${val:-$default}"
}

# Load project config into environment variables
# Sets: DF_PROJECT_NAME, DF_GITHUB_REPO, DF_SHIP_MODEL, DF_HOLDOUT_DIR, DF_BACKLOG_FILE, DF_BACKLOG_FORMAT
load_project_config() {
  local project_dir
  project_dir="$(resolve_project_dir)"
  local config_file="$project_dir/.dark-factory/config.yaml"

  export DF_PROJECT_DIR="$project_dir"
  export DF_FACTORY_DIR="$project_dir/.dark-factory"
  export DF_PLUGIN_ROOT="$(resolve_plugin_root)"

  if [ -f "$config_file" ]; then
    export DF_PROJECT_NAME="$(yaml_val "$config_file" "project_name" "$(basename "$project_dir")")"
    export DF_GITHUB_REPO="$(yaml_val "$config_file" "github_repo" "")"
    export DF_SHIP_MODEL="$(yaml_val "$config_file" "ship_model" "pr-creation")"
    export DF_HOLDOUT_DIR="$project_dir/$(yaml_val "$config_file" "holdout_dir" ".dark-factory/holdouts")"
    export DF_BACKLOG_FILE="$project_dir/$(yaml_val "$config_file" "backlog_file" ".dark-factory/backlog.md")"
    export DF_BACKLOG_FORMAT="$(yaml_val "$config_file" "backlog_format" "issue+spec")"
    export DF_GOVERNANCE_CEILING="$(yaml_val "$config_file" "governance_ceiling" "T1")"
    export DF_HOLDOUT_RUNS="$(yaml_val "$config_file" "holdout_runs" "3")"
    export DF_HOLDOUT_QUORUM="$(yaml_val "$config_file" "holdout_quorum" "2")"
    export DF_HOLDOUT_THRESHOLD="$(yaml_val "$config_file" "holdout_threshold" "90")"
    export DF_MAX_ATTEMPTS_PER_SPEC="$(yaml_val "$config_file" "max_attempts_per_spec" "3")"
    export DF_GUARDRAILS_FILE="$project_dir/$(yaml_val "$config_file" "guardrails_file" ".dark-factory/failure-patterns.md")"
  else
    # Defaults when no config exists (simpler mode: spec-only backlog, no GitHub integration)
    export DF_PROJECT_NAME="$(basename "$project_dir")"
    export DF_GITHUB_REPO=""
    export DF_SHIP_MODEL="pr-creation"
    export DF_HOLDOUT_DIR="$project_dir/.dark-factory/holdouts"
    export DF_BACKLOG_FILE="$project_dir/.dark-factory/backlog.md"
    export DF_BACKLOG_FORMAT="spec-only"
    export DF_GOVERNANCE_CEILING="T1"
    export DF_HOLDOUT_RUNS="3"
    export DF_HOLDOUT_QUORUM="2"
    export DF_HOLDOUT_THRESHOLD="90"
    export DF_MAX_ATTEMPTS_PER_SPEC="3"
    export DF_GUARDRAILS_FILE="$project_dir/.dark-factory/failure-patterns.md"
  fi
}
