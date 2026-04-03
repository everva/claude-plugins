#!/bin/bash
# Dark Factory Plugin — Circuit Breaker
# Detects stuck/degraded loops and pauses execution with cooldown recovery.
#
# States: CLOSED (normal) -> OPEN (tripped) -> HALF_OPEN (probing) -> CLOSED
#
# Sourced by ralph.sh

# --- State file ---
CB_STATE_FILE="$DF_FACTORY_DIR/.circuit-breaker.json"

# Initialize circuit breaker state file if missing
cb_init() {
  if [ ! -f "$CB_STATE_FILE" ]; then
    cat > "$CB_STATE_FILE" <<'CBJSON'
{"state":"CLOSED","no_progress_count":0,"same_error_count":0,"last_error":"","opened_at":0,"half_open_probes":0}
CBJSON
  fi
}

# Read a field from circuit breaker state
cb_get() {
  local field="$1"
  jq -r "if has(\"$field\") then .$field else empty end" "$CB_STATE_FILE" 2>/dev/null || echo ""
}

# Update circuit breaker state atomically
# Usage: cb_set '<jq filter>' [--arg name val ...]
cb_set() {
  local filter="$1"; shift
  local tmp="${CB_STATE_FILE}.tmp.$$"
  jq "$@" "$filter" "$CB_STATE_FILE" > "$tmp" 2>/dev/null && [ -s "$tmp" ] && mv "$tmp" "$CB_STATE_FILE" || rm -f "$tmp"
}

# Get current circuit breaker state: CLOSED, OPEN, or HALF_OPEN
cb_state() {
  cb_get "state"
}

# Record a successful iteration — resets counters, closes circuit
cb_record_success() {
  cb_set '.state = "CLOSED" | .no_progress_count = 0 | .same_error_count = 0 | .last_error = "" | .half_open_probes = 0'
}

# Record a no-progress iteration (task ran but nothing useful happened)
# Returns 0 if circuit is still closed, 1 if circuit just tripped
cb_record_no_progress() {
  local threshold="${DF_CB_NO_PROGRESS_THRESHOLD:-5}"
  local current
  current=$(cb_get "no_progress_count")
  current=$((current + 1))

  local now_ts
  now_ts=$(date +%s)

  if [ "$current" -ge "$threshold" ]; then
    cb_set '.no_progress_count = $c | .state = "OPEN" | .opened_at = $t' \
      --argjson c "$current" --argjson t "$now_ts"
    return 1
  else
    cb_set '.no_progress_count = $c' --argjson c "$current"
    return 0
  fi
}

# Record a repeated error — trips circuit if same error keeps happening
# Returns 0 if circuit is still closed, 1 if circuit just tripped
cb_record_error() {
  local error_sig="${1:-unknown}"
  local threshold="${DF_CB_SAME_ERROR_THRESHOLD:-3}"
  local last_error
  last_error=$(cb_get "last_error")
  local count

  if [ "$error_sig" = "$last_error" ]; then
    count=$(cb_get "same_error_count")
    count=$((count + 1))
  else
    count=1
  fi

  local now_ts
  now_ts=$(date +%s)

  if [ "$count" -ge "$threshold" ]; then
    cb_set '.same_error_count = $c | .last_error = $e | .state = "OPEN" | .opened_at = $t' \
      --arg e "$error_sig" --argjson c "$count" --argjson t "$now_ts"
    return 1
  else
    cb_set '.same_error_count = $c | .last_error = $e' \
      --arg e "$error_sig" --argjson c "$count"
    return 0
  fi
}

# Check if cooldown has elapsed and transition OPEN -> HALF_OPEN
# Returns 0 if loop should proceed (CLOSED or HALF_OPEN probe), 1 if still OPEN
cb_check() {
  local state
  state=$(cb_state)

  case "$state" in
    CLOSED)
      return 0
      ;;
    HALF_OPEN)
      # Allow one probe iteration
      return 0
      ;;
    OPEN)
      local cooldown_minutes="${DF_CB_COOLDOWN_MINUTES:-30}"
      local cooldown_seconds=$((cooldown_minutes * 60))
      local opened_at
      opened_at=$(cb_get "opened_at")
      local now
      now=$(date +%s)
      local elapsed=$((now - opened_at))

      if [ "$elapsed" -ge "$cooldown_seconds" ]; then
        cb_set '.state = "HALF_OPEN" | .half_open_probes = 0'
        return 0
      else
        local remaining=$(( (cooldown_seconds - elapsed) / 60 ))
        echo "$remaining"
        return 1
      fi
      ;;
  esac
}

# After a HALF_OPEN probe completes, decide: close or re-open
cb_finalize_probe() {
  local success="$1"  # "true" or "false"
  if [ "$success" = "true" ]; then
    cb_record_success
  else
    # Re-open with fresh cooldown
    local now_ts
    now_ts=$(date +%s)
    cb_set '.state = "OPEN" | .opened_at = $t' --argjson t "$now_ts"
  fi
}

# Force reset circuit breaker (manual override)
cb_reset() {
  cb_set '.state = "CLOSED" | .no_progress_count = 0 | .same_error_count = 0 | .last_error = "" | .opened_at = 0 | .half_open_probes = 0'
}
