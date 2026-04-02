#!/usr/bin/env bats
# Tests for Dark Factory config loader (lib/config.sh)

PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  export TEST_TMPDIR="$(mktemp -d)"
  source "$PLUGIN_ROOT/lib/config.sh"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# =============================================================================
# yaml_val
# =============================================================================

@test "yaml_val reads simple key: value" {
  cat > "$TEST_TMPDIR/test.yaml" <<'EOF'
project_name: my-cool-project
github_repo: owner/repo
EOF
  local val
  val=$(yaml_val "$TEST_TMPDIR/test.yaml" "project_name" "")
  [ "$val" = "my-cool-project" ]
}

@test "yaml_val reads double-quoted value" {
  cat > "$TEST_TMPDIR/test.yaml" <<'EOF'
project_name: "quoted-project"
EOF
  local val
  val=$(yaml_val "$TEST_TMPDIR/test.yaml" "project_name" "")
  [ "$val" = "quoted-project" ]
}

@test "yaml_val reads single-quoted value" {
  cat > "$TEST_TMPDIR/test.yaml" <<'EOF'
project_name: 'single-quoted'
EOF
  local val
  val=$(yaml_val "$TEST_TMPDIR/test.yaml" "project_name" "")
  [ "$val" = "single-quoted" ]
}

@test "yaml_val returns default for missing key" {
  cat > "$TEST_TMPDIR/test.yaml" <<'EOF'
project_name: exists
EOF
  local val
  val=$(yaml_val "$TEST_TMPDIR/test.yaml" "nonexistent_key" "fallback")
  [ "$val" = "fallback" ]
}

@test "yaml_val returns default for missing file" {
  local val
  val=$(yaml_val "$TEST_TMPDIR/no-such-file.yaml" "anything" "default-val")
  [ "$val" = "default-val" ]
}

@test "yaml_val handles key with spaces in value" {
  cat > "$TEST_TMPDIR/test.yaml" <<'EOF'
project_name: my cool project with spaces
EOF
  local val
  val=$(yaml_val "$TEST_TMPDIR/test.yaml" "project_name" "")
  [ "$val" = "my cool project with spaces" ]
}

@test "yaml_val takes first match if multiple keys" {
  cat > "$TEST_TMPDIR/test.yaml" <<'EOF'
project_name: first
project_name: second
project_name: third
EOF
  local val
  val=$(yaml_val "$TEST_TMPDIR/test.yaml" "project_name" "")
  [ "$val" = "first" ]
}

# =============================================================================
# load_project_config — with config file
# =============================================================================

@test "load_project_config sets DF_PROJECT_NAME from config.yaml" {
  local proj="$TEST_TMPDIR/myproject"
  mkdir -p "$proj/.dark-factory"
  cat > "$proj/.dark-factory/config.yaml" <<'EOF'
project_name: test-project
github_repo: org/test-project
ship_model: auto-merge
EOF
  export CLAUDE_PROJECT_DIR="$proj"
  # Re-source to pick up fresh env
  source "$PLUGIN_ROOT/lib/config.sh"
  load_project_config

  [ "$DF_PROJECT_NAME" = "test-project" ]
  [ "$DF_GITHUB_REPO" = "org/test-project" ]
  [ "$DF_SHIP_MODEL" = "auto-merge" ]
  [ "$DF_PROJECT_DIR" = "$proj" ]
}

@test "load_project_config loads defaults when no config file exists" {
  local proj="$TEST_TMPDIR/bare-project"
  mkdir -p "$proj"
  export CLAUDE_PROJECT_DIR="$proj"
  source "$PLUGIN_ROOT/lib/config.sh"
  load_project_config

  [ "$DF_PROJECT_NAME" = "bare-project" ]
  [ "$DF_GITHUB_REPO" = "" ]
  [ "$DF_SHIP_MODEL" = "pr-creation" ]
  [ "$DF_BACKLOG_FORMAT" = "spec-only" ]
  [ "$DF_GOVERNANCE_CEILING" = "T1" ]
  [ "$DF_HOLDOUT_RUNS" = "3" ]
  [ "$DF_HOLDOUT_QUORUM" = "2" ]
  [ "$DF_HOLDOUT_THRESHOLD" = "90" ]
  [ "$DF_MAX_ATTEMPTS_PER_SPEC" = "3" ]
}

@test "load_project_config loads resilience config fields" {
  local proj="$TEST_TMPDIR/resilience-project"
  mkdir -p "$proj/.dark-factory"
  cat > "$proj/.dark-factory/config.yaml" <<'EOF'
project_name: resilience-test
rate_limit_calls_per_hour: 120
rate_limit_tokens_per_hour: 500000
cb_no_progress_threshold: 10
cb_same_error_threshold: 5
cb_cooldown_minutes: 60
exit_empty_backlog_confirmations: 4
EOF
  export CLAUDE_PROJECT_DIR="$proj"
  source "$PLUGIN_ROOT/lib/config.sh"
  load_project_config

  [ "$DF_RATE_LIMIT_CALLS" = "120" ]
  [ "$DF_RATE_LIMIT_TOKENS" = "500000" ]
  [ "$DF_CB_NO_PROGRESS_THRESHOLD" = "10" ]
  [ "$DF_CB_SAME_ERROR_THRESHOLD" = "5" ]
  [ "$DF_CB_COOLDOWN_MINUTES" = "60" ]
  [ "$DF_EXIT_EMPTY_BACKLOG_CONFIRMATIONS" = "4" ]
}

@test "load_project_config resilience defaults when config has no resilience keys" {
  local proj="$TEST_TMPDIR/minimal-project"
  mkdir -p "$proj/.dark-factory"
  cat > "$proj/.dark-factory/config.yaml" <<'EOF'
project_name: minimal
EOF
  export CLAUDE_PROJECT_DIR="$proj"
  source "$PLUGIN_ROOT/lib/config.sh"
  load_project_config

  [ "$DF_RATE_LIMIT_CALLS" = "60" ]
  [ "$DF_RATE_LIMIT_TOKENS" = "0" ]
  [ "$DF_CB_NO_PROGRESS_THRESHOLD" = "5" ]
  [ "$DF_CB_SAME_ERROR_THRESHOLD" = "3" ]
  [ "$DF_CB_COOLDOWN_MINUTES" = "30" ]
  [ "$DF_EXIT_EMPTY_BACKLOG_CONFIRMATIONS" = "2" ]
}

# =============================================================================
# resolve_project_dir
# =============================================================================

@test "resolve_project_dir: CLAUDE_PROJECT_DIR takes priority" {
  export CLAUDE_PROJECT_DIR="/tmp/override-dir"
  export PROJECT_DIR="/tmp/fallback-dir"
  source "$PLUGIN_ROOT/lib/config.sh"
  local result
  result=$(resolve_project_dir)
  [ "$result" = "/tmp/override-dir" ]
}

@test "resolve_project_dir: falls back to git root in a git repo" {
  unset CLAUDE_PROJECT_DIR
  unset PROJECT_DIR
  # Create a fake git repo
  local fake_repo="$TEST_TMPDIR/fakerepo"
  mkdir -p "$fake_repo"
  git -C "$fake_repo" init --quiet
  # Run resolve_project_dir from inside the fake repo
  # Resolve real path to handle macOS /private/var symlinks
  local real_repo
  real_repo="$(cd "$fake_repo" && pwd -P)"
  local result
  result=$(cd "$fake_repo" && source "$PLUGIN_ROOT/lib/config.sh" && resolve_project_dir)
  local real_result
  real_result="$(cd "$result" && pwd -P)"
  [ "$real_result" = "$real_repo" ]
}

@test "resolve_project_dir: falls back to pwd when not in git repo" {
  unset CLAUDE_PROJECT_DIR
  unset PROJECT_DIR
  # Use a temp dir that is definitely not a git repo
  local noGit="$TEST_TMPDIR/nogit"
  mkdir -p "$noGit"
  local result
  result=$(cd "$noGit" && GIT_CEILING_DIRECTORIES="$noGit" source "$PLUGIN_ROOT/lib/config.sh" && resolve_project_dir)
  [ "$result" = "$noGit" ]
}
