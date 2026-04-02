#!/usr/bin/env bats
# Tests for Dark Factory circuit breaker (lib/circuit_breaker.sh)

PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  export DF_FACTORY_DIR="$(mktemp -d)"
  export DF_CB_NO_PROGRESS_THRESHOLD=3
  export DF_CB_SAME_ERROR_THRESHOLD=3
  export DF_CB_COOLDOWN_MINUTES=1
  source "$PLUGIN_ROOT/lib/circuit_breaker.sh"
}

teardown() {
  rm -rf "$DF_FACTORY_DIR"
}

# --- cb_init ---

@test "cb_init creates state file with CLOSED state" {
  cb_init
  [ -f "$DF_FACTORY_DIR/.circuit-breaker.json" ]
  local state
  state=$(jq -r '.state' "$DF_FACTORY_DIR/.circuit-breaker.json")
  [ "$state" = "CLOSED" ]
}

# --- cb_state ---

@test "cb_state returns CLOSED initially" {
  cb_init
  local state
  state=$(cb_state)
  [ "$state" = "CLOSED" ]
}

# --- cb_record_success ---

@test "cb_record_success resets all counters" {
  cb_init
  # Bump some counters first
  cb_record_no_progress || true
  cb_record_no_progress || true
  cb_record_error "some-error" || true

  cb_record_success

  [ "$(cb_get no_progress_count)" -eq 0 ]
  [ "$(cb_get same_error_count)" -eq 0 ]
  [ "$(cb_get last_error)" = "" ]
  [ "$(cb_get half_open_probes)" -eq 0 ]
  [ "$(cb_state)" = "CLOSED" ]
}

# --- cb_record_no_progress ---

@test "cb_record_no_progress increments counter" {
  cb_init
  cb_record_no_progress
  [ "$(cb_get no_progress_count)" -eq 1 ]
  cb_record_no_progress
  [ "$(cb_get no_progress_count)" -eq 2 ]
}

@test "cb_record_no_progress trips circuit at threshold" {
  cb_init
  cb_record_no_progress  # 1
  cb_record_no_progress  # 2
  run cb_record_no_progress  # 3 = threshold
  [ "$status" -eq 1 ]
  [ "$(cb_state)" = "OPEN" ]
}

# --- cb_record_error ---

@test "cb_record_error with same signature increments counter" {
  cb_init
  cb_record_error "err-abc"
  [ "$(cb_get same_error_count)" -eq 1 ]
  cb_record_error "err-abc"
  [ "$(cb_get same_error_count)" -eq 2 ]
  [ "$(cb_get last_error)" = "err-abc" ]
}

@test "cb_record_error with different signature resets counter to 1" {
  cb_init
  cb_record_error "err-abc"
  cb_record_error "err-abc"
  [ "$(cb_get same_error_count)" -eq 2 ]

  cb_record_error "err-xyz"
  [ "$(cb_get same_error_count)" -eq 1 ]
  [ "$(cb_get last_error)" = "err-xyz" ]
}

@test "cb_record_error trips circuit at threshold" {
  cb_init
  cb_record_error "same-err"   # 1
  cb_record_error "same-err"   # 2
  run cb_record_error "same-err"  # 3 = threshold
  [ "$status" -eq 1 ]
  [ "$(cb_state)" = "OPEN" ]
}

# --- cb_check ---

@test "cb_check returns 0 when CLOSED" {
  cb_init
  run cb_check
  [ "$status" -eq 0 ]
}

@test "cb_check returns 1 when OPEN within cooldown" {
  cb_init
  # Trip the circuit
  cb_record_no_progress
  cb_record_no_progress
  cb_record_no_progress || true

  run cb_check
  [ "$status" -eq 1 ]
  # Output should be remaining minutes (a non-negative number)
  [[ "$output" =~ ^[0-9]+$ ]]
}

@test "cb_check transitions OPEN to HALF_OPEN after cooldown" {
  cb_init
  # Trip the circuit with opened_at in the past (beyond cooldown)
  local past_ts=$(( $(date +%s) - 120 ))  # 2 minutes ago, cooldown is 1 minute
  cb_set '.state = "OPEN" | .opened_at = $t' --argjson t "$past_ts"

  run cb_check
  [ "$status" -eq 0 ]
  [ "$(cb_state)" = "HALF_OPEN" ]
}

# --- cb_finalize_probe ---

@test "cb_finalize_probe true closes circuit" {
  cb_init
  cb_set '.state = "HALF_OPEN"'
  cb_finalize_probe "true"

  [ "$(cb_state)" = "CLOSED" ]
  [ "$(cb_get no_progress_count)" -eq 0 ]
  [ "$(cb_get same_error_count)" -eq 0 ]
}

@test "cb_finalize_probe false re-opens circuit" {
  cb_init
  cb_set '.state = "HALF_OPEN"'
  cb_finalize_probe "false"

  [ "$(cb_state)" = "OPEN" ]
  local opened_at
  opened_at=$(cb_get "opened_at")
  [ "$opened_at" -gt 0 ]
}

# --- cb_reset ---

@test "cb_reset force-resets everything" {
  cb_init
  # Get into a messy state
  cb_record_no_progress
  cb_record_no_progress
  cb_record_no_progress || true
  cb_record_error "bad" || true

  cb_reset

  [ "$(cb_state)" = "CLOSED" ]
  [ "$(cb_get no_progress_count)" -eq 0 ]
  [ "$(cb_get same_error_count)" -eq 0 ]
  [ "$(cb_get last_error)" = "" ]
  [ "$(cb_get opened_at)" -eq 0 ]
  [ "$(cb_get half_open_probes)" -eq 0 ]
}
