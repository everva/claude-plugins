#!/bin/bash
# Dark Factory Plugin — Rate Limiter
# Enforces hourly call and token limits to prevent API overuse.
#
# Sourced by ralph.sh

# --- State files ---
RL_STATE_FILE="$DF_FACTORY_DIR/.rate-limiter.json"

# Initialize rate limiter state
rl_init() {
  if [ ! -f "$RL_STATE_FILE" ]; then
    cat > "$RL_STATE_FILE" <<RLJSON
{"calls_this_hour":0,"tokens_this_hour":0,"hour_start":$(date +%s)}
RLJSON
  fi
}

# Read a field from rate limiter state
rl_get() {
  local field="$1"
  jq -r ".$field // 0" "$RL_STATE_FILE" 2>/dev/null || echo "0"
}

# Update rate limiter state atomically
# Usage: rl_set '<jq filter>' [--arg name val ...]
rl_set() {
  local filter="$1"; shift
  local tmp="${RL_STATE_FILE}.tmp.$$"
  jq "$@" "$filter" "$RL_STATE_FILE" > "$tmp" 2>/dev/null && [ -s "$tmp" ] && mv "$tmp" "$RL_STATE_FILE" || rm -f "$tmp"
}

# Reset counters if the hour has rolled over
rl_maybe_reset_hour() {
  local hour_start
  hour_start=$(rl_get "hour_start")
  local now
  now=$(date +%s)
  local elapsed=$((now - hour_start))

  if [ "$elapsed" -ge 3600 ]; then
    rl_set '.calls_this_hour = 0 | .tokens_this_hour = 0 | .hour_start = $t' --argjson t "$now"
  fi
}

# Record a call (and optionally tokens consumed)
# Usage: rl_record_call [token_count]
rl_record_call() {
  local tokens="${1:-0}"
  rl_maybe_reset_hour
  # Atomic increment — single jq read-modify-write
  local tmp="${RL_STATE_FILE}.tmp.$$"
  jq --argjson t "$tokens" '.calls_this_hour += 1 | .tokens_this_hour += $t' \
    "$RL_STATE_FILE" > "$tmp" 2>/dev/null && [ -s "$tmp" ] && mv "$tmp" "$RL_STATE_FILE" || rm -f "$tmp"
}

# Check if we're within limits. Returns 0 if OK, 1 if rate limited.
# Outputs wait time in seconds if rate limited.
rl_check() {
  rl_maybe_reset_hour

  local max_calls="${DF_RATE_LIMIT_CALLS:-60}"
  local max_tokens="${DF_RATE_LIMIT_TOKENS:-0}"
  local calls
  calls=$(rl_get "calls_this_hour")
  local tokens
  tokens=$(rl_get "tokens_this_hour")
  local hour_start
  hour_start=$(rl_get "hour_start")
  local now
  now=$(date +%s)
  local elapsed=$((now - hour_start))
  local remaining=$((3600 - elapsed))

  # Clamp to minimum 1 second to avoid sleep errors
  [ "$remaining" -le 0 ] && remaining=1

  # Check call limit
  if [ "$calls" -ge "$max_calls" ]; then
    echo "$remaining"
    return 1
  fi

  # Check token limit (0 = disabled)
  if [ "$max_tokens" -gt 0 ] && [ "$tokens" -ge "$max_tokens" ]; then
    echo "$remaining"
    return 1
  fi

  return 0
}

# Get current usage summary (for logging)
rl_status() {
  rl_maybe_reset_hour
  local calls
  calls=$(rl_get "calls_this_hour")
  local tokens
  tokens=$(rl_get "tokens_this_hour")
  local max_calls="${DF_RATE_LIMIT_CALLS:-60}"
  local max_tokens="${DF_RATE_LIMIT_TOKENS:-0}"

  if [ "$max_tokens" -gt 0 ]; then
    echo "${calls}/${max_calls} calls, ${tokens}/${max_tokens} tokens this hour"
  else
    echo "${calls}/${max_calls} calls this hour"
  fi
}
