#!/usr/bin/env bats
# Tests for Dark Factory reactive rate limiter (lib/rate_limiter.sh)

PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  export DF_FACTORY_DIR="$(mktemp -d)"
  source "$PLUGIN_ROOT/lib/rate_limiter.sh"
}

teardown() {
  rm -rf "$DF_FACTORY_DIR"
}

# --- rl_init ---

@test "rl_init creates state file with rate_limited=false" {
  rl_init
  [ -f "$DF_FACTORY_DIR/.rate-limiter.json" ]
  local limited
  limited=$(jq -r '.rate_limited' "$DF_FACTORY_DIR/.rate-limiter.json")
  [ "$limited" = "false" ]
  local total
  total=$(jq -r '.total_hits' "$DF_FACTORY_DIR/.rate-limiter.json")
  [ "$total" -eq 0 ]
}

# --- rl_is_rate_limited ---

@test "rl_is_rate_limited returns 1 for normal output" {
  rl_init
  local file="$DF_FACTORY_DIR/output.txt"
  echo "Implementation complete. All tests pass." > "$file"
  run rl_is_rate_limited "$file"
  [ "$status" -eq 1 ]
}

@test "rl_is_rate_limited returns 0 and wait seconds for limit message" {
  rl_init
  local file="$DF_FACTORY_DIR/output.txt"
  echo "You've hit your limit · resets 11am" > "$file"
  run rl_is_rate_limited "$file"
  [ "$status" -eq 0 ]
  # Output should be a positive number (wait seconds)
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -gt 0 ]
}

@test "rl_is_rate_limited detects partial match" {
  rl_init
  local file="$DF_FACTORY_DIR/output.txt"
  echo "Error: hit your limit for this period, resets 2pm" > "$file"
  run rl_is_rate_limited "$file"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
}

@test "rl_is_rate_limited returns 1 for missing file" {
  rl_init
  run rl_is_rate_limited "$DF_FACTORY_DIR/nonexistent.txt"
  [ "$status" -eq 1 ]
}

@test "rl_is_rate_limited updates state to rate_limited=true" {
  rl_init
  local file="$DF_FACTORY_DIR/output.txt"
  echo "You've hit your limit · resets 3pm" > "$file"
  rl_is_rate_limited "$file" >/dev/null
  local limited
  limited=$(jq -r '.rate_limited' "$DF_FACTORY_DIR/.rate-limiter.json")
  [ "$limited" = "true" ]
  local total
  total=$(jq -r '.total_hits' "$DF_FACTORY_DIR/.rate-limiter.json")
  [ "$total" -eq 1 ]
}

@test "rl_is_rate_limited increments total_hits" {
  rl_init
  local file="$DF_FACTORY_DIR/output.txt"
  echo "You've hit your limit · resets 4pm" > "$file"
  rl_is_rate_limited "$file" >/dev/null
  rl_is_rate_limited "$file" >/dev/null
  local total
  total=$(jq -r '.total_hits' "$DF_FACTORY_DIR/.rate-limiter.json")
  [ "$total" -eq 2 ]
}

@test "rl_is_rate_limited includes 2 minute buffer" {
  rl_init
  local file="$DF_FACTORY_DIR/output.txt"
  # Use a reset time far in the future to get predictable result
  echo "You've hit your limit · resets 11pm" > "$file"
  local wait
  wait=$(rl_is_rate_limited "$file")
  # wait should include 120s buffer
  [ "$wait" -ge 120 ]
}

# --- rl_record_success ---

@test "rl_record_success clears rate limit state" {
  rl_init
  # Set rate limited state
  rl_set '.rate_limited = true | .reset_time = "3pm" | .wait_until = 9999999999'
  rl_record_success
  local limited
  limited=$(jq -r '.rate_limited' "$DF_FACTORY_DIR/.rate-limiter.json")
  [ "$limited" = "false" ]
  local wait_until
  wait_until=$(jq -r '.wait_until' "$DF_FACTORY_DIR/.rate-limiter.json")
  [ "$wait_until" -eq 0 ]
}

# --- rl_check ---

@test "rl_check returns 0 when not rate limited" {
  rl_init
  run rl_check
  [ "$status" -eq 0 ]
}

@test "rl_check returns 1 with remaining seconds when rate limited" {
  rl_init
  local future=$(($(date +%s) + 600))
  rl_set '.rate_limited = true | .wait_until = $w' --argjson w "$future"
  run rl_check
  [ "$status" -eq 1 ]
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -gt 0 ]
  [ "$output" -le 600 ]
}

@test "rl_check clears state when cooldown elapsed" {
  rl_init
  local past=$(($(date +%s) - 60))
  rl_set '.rate_limited = true | .wait_until = $w' --argjson w "$past"
  run rl_check
  [ "$status" -eq 0 ]
  local limited
  limited=$(jq -r '.rate_limited' "$DF_FACTORY_DIR/.rate-limiter.json")
  [ "$limited" = "false" ]
}

# --- rl_status ---

@test "rl_status shows OK when not limited" {
  rl_init
  local result
  result=$(rl_status)
  [[ "$result" == *"OK"* ]]
}

@test "rl_status shows RATE LIMITED when limited" {
  rl_init
  rl_set '.rate_limited = true | .reset_time = "3pm" | .total_hits = 2'
  local result
  result=$(rl_status)
  [[ "$result" == *"RATE LIMITED"* ]]
  [[ "$result" == *"3pm"* ]]
  [[ "$result" == *"2"* ]]
}
