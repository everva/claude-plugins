#!/usr/bin/env bats
# Tests for Dark Factory dashboard (scripts/dashboard.sh)

PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  export PROJECT_DIR="$(mktemp -d)"
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
  export DF_FACTORY_DIR="$PROJECT_DIR/.dark-factory"
  export DF_PROJECT_DIR="$PROJECT_DIR"
  export DF_PROJECT_NAME="test-project"
  export DF_BACKLOG_FILE="$DF_FACTORY_DIR/backlog.md"

  mkdir -p "$DF_FACTORY_DIR/sessions"
  touch "$DF_BACKLOG_FILE"

  # Create minimal config.yaml so config.sh loads
  cat > "$DF_FACTORY_DIR/config.yaml" <<YAML
project_name: test-project
github_repo: owner/test-repo
ship_model: pr-creation
YAML

  DASHBOARD="$PLUGIN_ROOT/scripts/dashboard.sh"
  chmod +x "$DASHBOARD"
}

teardown() {
  rm -rf "$PROJECT_DIR"
}

# Helper: create a mock session with governance.json
# Usage: create_session <session_name> <decision> <holdout_score> <satisfaction_score>
create_session() {
  local name="$1" decision="$2" holdout="${3:-80}" satisfaction="${4:-85}"
  local dir="$DF_FACTORY_DIR/sessions/$name"
  mkdir -p "$dir"
  cat > "$dir/governance.json" <<JSON
{
  "decision": "$decision",
  "holdout_score": $holdout,
  "satisfaction_score": $satisfaction,
  "tier": "T0",
  "issue_number": "1"
}
JSON
}

# --- Text output mode (no --json) ---

@test "text mode: no sessions shows 0 total" {
  run "$DASHBOARD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Total:      0"* ]]
}

@test "text mode: one auto-ship session shows 1 total and 100% pass rate" {
  create_session "sess-20260402-001" "auto-ship" 90 95

  run "$DASHBOARD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Total:      1"* ]]
  [[ "$output" == *"Passed:     1"* ]]
  [[ "$output" == *"Pass Rate:  100%"* ]]
}

@test "text mode: shows project name in header" {
  run "$DASHBOARD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"test-project Dark Factory Dashboard"* ]]
}

@test "text mode: mixed decisions counted correctly" {
  create_session "sess-20260402-001" "auto-ship" 90 95
  create_session "sess-20260402-002" "blocked" 40 30
  create_session "sess-20260402-003" "review-pr" 70 75

  run "$DASHBOARD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Total:      3"* ]]
  [[ "$output" == *"Passed:     1"* ]]
  [[ "$output" == *"Failed:     1"* ]]
  [[ "$output" == *"Deferred:   1"* ]]
}

@test "text mode: no-op sessions counted" {
  create_session "sess-20260402-001" "no-op" 0 0

  run "$DASHBOARD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No-Op:      1"* ]]
}

# --- JSON output mode (--json) ---

@test "json mode: outputs valid JSON" {
  create_session "sess-20260402-001" "auto-ship" 90 85

  run "$DASHBOARD" --json
  [ "$status" -eq 0 ]
  # Validate JSON by piping through jq
  echo "$output" | jq . > /dev/null
}

@test "json mode: has correct top-level keys" {
  create_session "sess-20260402-001" "auto-ship" 90 85

  run "$DASHBOARD" --json
  [ "$status" -eq 0 ]

  local keys
  keys=$(echo "$output" | jq -r 'keys[]' | sort | tr '\n' ',')
  [[ "$keys" == *"project"* ]]
  [[ "$keys" == *"sessions"* ]]
  [[ "$keys" == *"quality"* ]]
  [[ "$keys" == *"ralph"* ]]
  [[ "$keys" == *"resilience"* ]]
  [[ "$keys" == *"timestamp"* ]]
}

@test "json mode: sessions object has correct counts" {
  create_session "sess-20260402-001" "auto-ship" 90 85
  create_session "sess-20260402-002" "blocked" 40 30

  run "$DASHBOARD" --json
  [ "$status" -eq 0 ]

  local total passed failed
  total=$(echo "$output" | jq '.sessions.total')
  passed=$(echo "$output" | jq '.sessions.passed')
  failed=$(echo "$output" | jq '.sessions.failed')
  [ "$total" -eq 2 ]
  [ "$passed" -eq 1 ]
  [ "$failed" -eq 1 ]
}

@test "json mode: project name is correct" {
  run "$DASHBOARD" --json
  [ "$status" -eq 0 ]

  local project
  project=$(echo "$output" | jq -r '.project')
  [ "$project" = "test-project" ]
}

@test "json mode: resilience shows circuit breaker and rate usage" {
  run "$DASHBOARD" --json
  [ "$status" -eq 0 ]

  local cb rl
  cb=$(echo "$output" | jq -r '.resilience.circuit_breaker')
  rl=$(echo "$output" | jq -r '.resilience.rate_usage')
  [ -n "$cb" ]
  [ -n "$rl" ]
}

@test "json mode: resilience reads circuit breaker state from file" {
  cat > "$DF_FACTORY_DIR/.circuit-breaker.json" <<JSON
{"state": "OPEN", "opened_at": 1234567890}
JSON

  run "$DASHBOARD" --json
  [ "$status" -eq 0 ]

  local cb
  cb=$(echo "$output" | jq -r '.resilience.circuit_breaker')
  [ "$cb" = "OPEN" ]
}

@test "json mode: resilience reads rate limiter usage from file" {
  cat > "$DF_FACTORY_DIR/.rate-limiter.json" <<JSON
{"calls_this_hour": 15, "hour_start": 1234567890}
JSON

  run "$DASHBOARD" --json
  [ "$status" -eq 0 ]

  local rl
  rl=$(echo "$output" | jq -r '.resilience.rate_usage')
  [[ "$rl" == "15/"* ]]
}

@test "json mode: quality metrics averaged correctly" {
  create_session "sess-20260402-001" "auto-ship" 80 90
  create_session "sess-20260402-002" "auto-pr" 60 70

  run "$DASHBOARD" --json
  [ "$status" -eq 0 ]

  local holdout sat
  holdout=$(echo "$output" | jq '.quality.avg_holdout')
  sat=$(echo "$output" | jq '.quality.avg_satisfaction')
  [ "$holdout" -eq 70 ]
  [ "$sat" -eq 80 ]
}

# --- Days filter (--days) ---

@test "days filter: --days 1 excludes old sessions" {
  # Create a session with an old date in the name
  create_session "sess-20240101-001" "auto-ship" 90 85
  # Create a session with today's date
  create_session "sess-$(date +%Y%m%d)-001" "auto-ship" 90 85

  run "$DASHBOARD" --json --days 1
  [ "$status" -eq 0 ]

  local total
  total=$(echo "$output" | jq '.sessions.total')
  [ "$total" -eq 1 ]
}

@test "days filter: --days 7 is the default" {
  run "$DASHBOARD" --json
  [ "$status" -eq 0 ]

  local days
  days=$(echo "$output" | jq '.period_days')
  [ "$days" -eq 7 ]
}

@test "days filter: --days 365 includes old sessions within range" {
  create_session "sess-20260101-001" "auto-ship" 90 85
  create_session "sess-20260402-001" "blocked" 40 30

  run "$DASHBOARD" --json --days 365
  [ "$status" -eq 0 ]

  local total
  total=$(echo "$output" | jq '.sessions.total')
  [ "$total" -eq 2 ]
}
