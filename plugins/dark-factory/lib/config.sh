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
# Also: DF_RATE_LIMIT_*, DF_CB_*, DF_EXIT_*
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

    # Governance tier thresholds
    export DF_TIER_T0_MAX_RISK="$(yaml_val "$config_file" "tier_t0_max_risk" "15")"
    export DF_TIER_T0_MIN_SAT="$(yaml_val "$config_file" "tier_t0_min_sat" "80")"
    export DF_TIER_T1_MAX_RISK="$(yaml_val "$config_file" "tier_t1_max_risk" "40")"
    export DF_TIER_T1_MIN_SAT="$(yaml_val "$config_file" "tier_t1_min_sat" "75")"
    export DF_TIER_T2_MAX_RISK="$(yaml_val "$config_file" "tier_t2_max_risk" "60")"
    export DF_TIER_T2_MIN_SAT="$(yaml_val "$config_file" "tier_t2_min_sat" "70")"
    export DF_TIER_BLOCKED_MIN_SAT="$(yaml_val "$config_file" "tier_blocked_min_sat" "50")"

    # Agent budgets and timeouts
    export DF_IMPL_TIMEOUT="$(yaml_val "$config_file" "impl_timeout" "2700")"
    export DF_IMPL_BUDGET="$(yaml_val "$config_file" "impl_budget" "10")"
    export DF_HOLDOUT_BUDGET="$(yaml_val "$config_file" "holdout_budget" "2")"
    export DF_SAT_BUDGET="$(yaml_val "$config_file" "sat_budget" "2")"
    export DF_HOLDOUT_TIMEOUT="$(yaml_val "$config_file" "holdout_timeout" "300")"
    export DF_SAT_TIMEOUT="$(yaml_val "$config_file" "sat_timeout" "300")"

    # Tool allowlists
    export DF_IMPL_TOOLS="$(yaml_val "$config_file" "impl_tools" "Read,Write,Edit,Grep,Glob,Bash,Agent")"
    export DF_HOLDOUT_TOOLS="$(yaml_val "$config_file" "holdout_tools" "Read,Grep,Glob,Bash")"
    export DF_SAT_TOOLS="$(yaml_val "$config_file" "sat_tools" "Read,Grep,Glob")"

    # Custom implementation prompt/agent
    export DF_IMPL_PROMPT_FILE="$(yaml_val "$config_file" "impl_prompt_file" "")"
    export DF_IMPL_AGENT="$(yaml_val "$config_file" "impl_agent" "")"

    # Layer → holdout directory mapping (comma-separated key=value pairs)
    # Example: "backend=api,shared=mobile,ios=mobile,android=mobile"
    # Empty = identity mapping (layer name = holdout dir name)
    export DF_LAYER_MAPPING="$(yaml_val "$config_file" "layer_mapping" "")"

    # Holdout guard agent whitelist
    export DF_HOLDOUT_ALLOWED_AGENTS="$(yaml_val "$config_file" "holdout_allowed_agents" "holdout-validator,satisfaction-judge")"

    # PR labels
    export DF_PR_LABEL_REVIEW="$(yaml_val "$config_file" "pr_label_review" "needs-review")"
    export DF_PR_LABEL_ARCH_REVIEW="$(yaml_val "$config_file" "pr_label_arch_review" "architecture-review")"
    export DF_PR_LABEL_PIPELINE="$(yaml_val "$config_file" "pr_label_pipeline" "agent:pipeline")"
    export DF_PR_LABEL_FACTORY="$(yaml_val "$config_file" "pr_label_factory" "dark-factory")"

    # Issue sync label
    export DF_ISSUE_SYNC_LABEL="$(yaml_val "$config_file" "issue_sync_label" "status:ready")"

    # Commit & Git
    export DF_COMMIT_SUFFIX="$(yaml_val "$config_file" "commit_suffix" "[agent:dark-factory]")"
    export DF_BASE_BRANCH="$(yaml_val "$config_file" "base_branch" "")"

    # Task selection budget (ralph loop)
    export DF_SELECTION_TIMEOUT="$(yaml_val "$config_file" "selection_timeout" "60")"
    export DF_SELECTION_BUDGET="$(yaml_val "$config_file" "selection_budget" "0.50")"

    # Rate limiting
    export DF_RATE_LIMIT_CALLS="$(yaml_val "$config_file" "rate_limit_calls_per_hour" "60")"
    export DF_RATE_LIMIT_TOKENS="$(yaml_val "$config_file" "rate_limit_tokens_per_hour" "0")"

    # Circuit breaker
    export DF_CB_NO_PROGRESS_THRESHOLD="$(yaml_val "$config_file" "cb_no_progress_threshold" "5")"
    export DF_CB_SAME_ERROR_THRESHOLD="$(yaml_val "$config_file" "cb_same_error_threshold" "3")"
    export DF_CB_COOLDOWN_MINUTES="$(yaml_val "$config_file" "cb_cooldown_minutes" "30")"

    # Dual-condition exit
    export DF_EXIT_EMPTY_BACKLOG_CONFIRMATIONS="$(yaml_val "$config_file" "exit_empty_backlog_confirmations" "2")"
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

    # Governance tier thresholds (defaults)
    export DF_TIER_T0_MAX_RISK="15"
    export DF_TIER_T0_MIN_SAT="80"
    export DF_TIER_T1_MAX_RISK="40"
    export DF_TIER_T1_MIN_SAT="75"
    export DF_TIER_T2_MAX_RISK="60"
    export DF_TIER_T2_MIN_SAT="70"
    export DF_TIER_BLOCKED_MIN_SAT="50"

    # Agent budgets and timeouts (defaults)
    export DF_IMPL_TIMEOUT="2700"
    export DF_IMPL_BUDGET="10"
    export DF_HOLDOUT_BUDGET="2"
    export DF_SAT_BUDGET="2"
    export DF_HOLDOUT_TIMEOUT="300"
    export DF_SAT_TIMEOUT="300"

    # Tool allowlists (defaults)
    export DF_IMPL_TOOLS="Read,Write,Edit,Grep,Glob,Bash,Agent"
    export DF_HOLDOUT_TOOLS="Read,Grep,Glob,Bash"
    export DF_SAT_TOOLS="Read,Grep,Glob"

    # Custom implementation prompt/agent (defaults: empty = use built-in)
    export DF_IMPL_PROMPT_FILE=""
    export DF_IMPL_AGENT=""

    # Layer mapping (defaults: empty = identity)
    export DF_LAYER_MAPPING=""

    # Holdout guard agent whitelist (defaults)
    export DF_HOLDOUT_ALLOWED_AGENTS="holdout-validator,satisfaction-judge"

    # PR labels (defaults)
    export DF_PR_LABEL_REVIEW="needs-review"
    export DF_PR_LABEL_ARCH_REVIEW="architecture-review"
    export DF_PR_LABEL_PIPELINE="agent:pipeline"
    export DF_PR_LABEL_FACTORY="dark-factory"

    # Issue sync label (defaults)
    export DF_ISSUE_SYNC_LABEL="status:ready"

    # Commit & Git (defaults)
    export DF_COMMIT_SUFFIX="[agent:dark-factory]"
    export DF_BASE_BRANCH=""

    # Task selection budget (defaults)
    export DF_SELECTION_TIMEOUT="60"
    export DF_SELECTION_BUDGET="0.50"

    # Rate limiting (defaults)
    export DF_RATE_LIMIT_CALLS="60"
    export DF_RATE_LIMIT_TOKENS="0"

    # Circuit breaker (defaults)
    export DF_CB_NO_PROGRESS_THRESHOLD="5"
    export DF_CB_SAME_ERROR_THRESHOLD="3"
    export DF_CB_COOLDOWN_MINUTES="30"

    # Dual-condition exit (defaults)
    export DF_EXIT_EMPTY_BACKLOG_CONFIRMATIONS="2"
  fi
}
