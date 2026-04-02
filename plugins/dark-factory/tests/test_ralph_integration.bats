#!/usr/bin/env bats
# Tests for ralph.sh integration points — dual-exit logic, guard ordering, and slugify

PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  export TEST_TMPDIR="$(mktemp -d)"
  export FACTORY_DIR="$TEST_TMPDIR/.dark-factory"
  mkdir -p "$FACTORY_DIR"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# =============================================================================
# Helper: dual-condition exit logic (extracted from ralph.sh pattern)
# =============================================================================

# Simulates ralph's dual-exit backlog check. Returns 0 to continue, 1 to stop.
# Sets EMPTY_BACKLOG_COUNT in the caller via stdout protocol.
_dual_exit_check() {
  local task="$1"
  local empty_count="$2"
  local threshold="$3"

  if [ "$task" = "EMPTY" ] || [ -z "$task" ]; then
    empty_count=$((empty_count + 1))
    if [ "$empty_count" -ge "$threshold" ]; then
      echo "STOP:$empty_count"
      return 0
    else
      echo "CONTINUE:$empty_count"
      return 0
    fi
  fi
  # Non-empty task resets counter
  echo "CONTINUE:0"
}

# =============================================================================
# Dual-condition exit logic
# =============================================================================

@test "dual-exit: EMPTY_BACKLOG_COUNT=0, empty task -> count becomes 1, should continue" {
  local result
  result=$(_dual_exit_check "EMPTY" 0 2)
  [ "$result" = "CONTINUE:1" ]
}

@test "dual-exit: EMPTY_BACKLOG_COUNT=1, empty task again -> count becomes 2, should stop (threshold=2)" {
  local result
  result=$(_dual_exit_check "EMPTY" 1 2)
  [ "$result" = "STOP:2" ]
}

@test "dual-exit: EMPTY_BACKLOG_COUNT=1, then non-empty task -> count resets to 0" {
  local result
  result=$(_dual_exit_check "docs/specs/add-auth.intent.md" 1 2)
  [ "$result" = "CONTINUE:0" ]
}

@test "dual-exit: custom threshold of 3 needs 3 empty results before stopping" {
  local result

  # First empty
  result=$(_dual_exit_check "EMPTY" 0 3)
  [ "$result" = "CONTINUE:1" ]

  # Second empty
  result=$(_dual_exit_check "EMPTY" 1 3)
  [ "$result" = "CONTINUE:2" ]

  # Third empty — now stop
  result=$(_dual_exit_check "EMPTY" 2 3)
  [ "$result" = "STOP:3" ]
}

@test "dual-exit: empty string task treated same as EMPTY" {
  local result
  result=$(_dual_exit_check "" 1 2)
  [ "$result" = "STOP:2" ]
}

# =============================================================================
# Guard ordering (extracted logic from ralph.sh)
# =============================================================================

# Simulates ralph guard checks. Returns the reason for stopping, or "proceed".
_check_guards() {
  local stop_signal_exists="$1"
  local iteration="$2"
  local max_iterations="$3"
  local consecutive_failures="$4"
  local max_consecutive_failures="$5"

  # Guard 1: Stop signal
  if [ "$stop_signal_exists" = "true" ]; then
    echo "stop-signal"
    return 0
  fi

  # Guard 2: Max iterations
  if [ "$iteration" -ge "$max_iterations" ]; then
    echo "max-iterations"
    return 0
  fi

  # Guard 3: Consecutive failures
  if [ "$consecutive_failures" -ge "$max_consecutive_failures" ]; then
    echo "consecutive-failures"
    return 0
  fi

  echo "proceed"
}

@test "guard: stop signal file exists -> should stop" {
  local result
  result=$(_check_guards "true" 0 10 0 3)
  [ "$result" = "stop-signal" ]
}

@test "guard: iteration >= max -> should stop" {
  local result
  result=$(_check_guards "false" 10 10 0 3)
  [ "$result" = "max-iterations" ]
}

@test "guard: consecutive failures >= max -> should stop" {
  local result
  result=$(_check_guards "false" 2 10 3 3)
  [ "$result" = "consecutive-failures" ]
}

@test "guard: all conditions clear -> should proceed" {
  local result
  result=$(_check_guards "false" 2 10 1 3)
  [ "$result" = "proceed" ]
}

@test "guard: stop signal takes priority over max iterations" {
  local result
  result=$(_check_guards "true" 10 10 3 3)
  [ "$result" = "stop-signal" ]
}

@test "guard: max iterations takes priority over consecutive failures" {
  local result
  result=$(_check_guards "false" 10 10 3 3)
  [ "$result" = "max-iterations" ]
}

# =============================================================================
# Slugify (extracted from import-prd.sh)
# =============================================================================

# Exact slugify function from import-prd.sh
slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//'
}

@test "slugify: Hello World -> hello-world" {
  local result
  result=$(slugify "Hello World")
  [ "$result" = "hello-world" ]
}

@test "slugify: Add User Auth!!! -> add-user-auth" {
  local result
  result=$(slugify "Add User Auth!!!")
  [ "$result" = "add-user-auth" ]
}

@test "slugify: multiple---dashes -> multiple-dashes" {
  local result
  result=$(slugify "multiple---dashes")
  [ "$result" = "multiple-dashes" ]
}

@test "slugify: --leading-trailing-- -> leading-trailing" {
  local result
  result=$(slugify "--leading-trailing--")
  [ "$result" = "leading-trailing" ]
}

@test "slugify: MiXeD CaSe 123 -> mixed-case-123" {
  local result
  result=$(slugify "MiXeD CaSe 123")
  [ "$result" = "mixed-case-123" ]
}

@test "slugify: special chars @#\$%^& -> stripped" {
  local result
  result=$(slugify 'hello@world#test')
  [ "$result" = "hello-world-test" ]
}
