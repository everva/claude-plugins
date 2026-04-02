#!/usr/bin/env bats
# Tests for Dark Factory rate limiter (lib/rate_limiter.sh)

PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  export DF_FACTORY_DIR="$(mktemp -d)"
  export DF_RATE_LIMIT_CALLS=5
  export DF_RATE_LIMIT_TOKENS=1000
  source "$PLUGIN_ROOT/lib/rate_limiter.sh"
}

teardown() {
  rm -rf "$DF_FACTORY_DIR"
}

# --- rl_init ---

@test "rl_init creates state file" {
  rl_init
  [ -f "$DF_FACTORY_DIR/.rate-limiter.json" ]
  local calls
  calls=$(jq -r '.calls_this_hour' "$DF_FACTORY_DIR/.rate-limiter.json")
  [ "$calls" -eq 0 ]
  local tokens
  tokens=$(jq -r '.tokens_this_hour' "$DF_FACTORY_DIR/.rate-limiter.json")
  [ "$tokens" -eq 0 ]
}

# --- rl_record_call ---

@test "rl_record_call increments call count" {
  rl_init
  rl_record_call
  [ "$(rl_get calls_this_hour)" -eq 1 ]
  rl_record_call
  [ "$(rl_get calls_this_hour)" -eq 2 ]
}

@test "rl_record_call with tokens increments both" {
  rl_init
  rl_record_call 250
  [ "$(rl_get calls_this_hour)" -eq 1 ]
  [ "$(rl_get tokens_this_hour)" -eq 250 ]
  rl_record_call 100
  [ "$(rl_get calls_this_hour)" -eq 2 ]
  [ "$(rl_get tokens_this_hour)" -eq 350 ]
}

# --- rl_check ---

@test "rl_check returns 0 when under limit" {
  rl_init
  rl_record_call 50
  run rl_check
  [ "$status" -eq 0 ]
}

@test "rl_check returns 1 when call limit hit" {
  rl_init
  for i in $(seq 1 5); do
    rl_record_call
  done
  run rl_check
  [ "$status" -eq 1 ]
  # Output should be remaining seconds (positive integer)
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -gt 0 ]
}

@test "rl_check returns 1 when token limit hit" {
  rl_init
  rl_record_call 600
  rl_record_call 500
  # Now at 1100 tokens, limit is 1000
  run rl_check
  [ "$status" -eq 1 ]
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -gt 0 ]
}

@test "rl_check returns remaining seconds that are positive and never negative" {
  rl_init
  # Fill up calls to hit limit
  for i in $(seq 1 5); do
    rl_record_call
  done
  run rl_check
  [ "$status" -eq 1 ]
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -ge 1 ]
}

# --- rl_maybe_reset_hour ---

@test "rl_maybe_reset_hour resets after 3600 seconds" {
  rl_init
  # Record some calls
  rl_record_call 100
  rl_record_call 200
  [ "$(rl_get calls_this_hour)" -eq 2 ]
  [ "$(rl_get tokens_this_hour)" -eq 300 ]

  # Fake hour_start to be over an hour ago
  local old_ts=$(( $(date +%s) - 3700 ))
  rl_set ".hour_start = $old_ts"

  # Trigger reset via rl_maybe_reset_hour
  rl_maybe_reset_hour

  [ "$(rl_get calls_this_hour)" -eq 0 ]
  [ "$(rl_get tokens_this_hour)" -eq 0 ]
}

# --- rl_status ---

@test "rl_status returns formatted string" {
  rl_init
  rl_record_call 150
  rl_record_call 250

  local result
  result=$(rl_status)
  # With token limit enabled, format is: "calls/max calls, tokens/max tokens this hour"
  [[ "$result" == "2/5 calls, 400/1000 tokens this hour" ]]
}
