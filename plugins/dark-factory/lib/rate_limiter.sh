#!/bin/bash
# Dark Factory Plugin — Reactive Rate Limiter
# Detects "You've hit your limit · resets Xam/pm" from claude -p output.
# Parses the reset time and waits until then.
# No manual counting — reacts to actual subscription limits.
#
# Sourced by ralph.sh and run-task.sh

# --- State file ---
RL_STATE_FILE="$DF_FACTORY_DIR/.rate-limiter.json"

# Initialize rate limiter state
rl_init() {
  if [ ! -f "$RL_STATE_FILE" ]; then
    cat > "$RL_STATE_FILE" <<RLJSON
{"rate_limited":false,"reset_time":"","wait_until":0,"total_hits":0}
RLJSON
  fi
}

# Update rate limiter state atomically
rl_set() {
  local filter="$1"; shift
  local tmp="${RL_STATE_FILE}.tmp.$$"
  jq "$@" "$filter" "$RL_STATE_FILE" > "$tmp" 2>/dev/null && [ -s "$tmp" ] && mv "$tmp" "$RL_STATE_FILE" || rm -f "$tmp"
}

# Check if claude -p output indicates rate limit
# Usage: rl_is_rate_limited <result_file_or_stderr>
# Returns 0 if rate limited, 1 if not
# If rate limited, outputs wait seconds to stdout
rl_is_rate_limited() {
  local file="$1"
  [ -f "$file" ] || return 1

  # Check for the subscription limit message
  local limit_msg=""
  limit_msg=$(grep -o "You've hit your limit.*resets [0-9]*[ap]m" "$file" 2>/dev/null | head -1)
  [ -z "$limit_msg" ] && limit_msg=$(grep -o "hit your limit.*resets [0-9]*[ap]m" "$file" 2>/dev/null | head -1)
  [ -z "$limit_msg" ] && return 1

  # Extract reset time (e.g., "11am", "2pm")
  local reset_str=""
  reset_str=$(echo "$limit_msg" | grep -oE '[0-9]+[ap]m' | head -1)
  [ -z "$reset_str" ] && { echo "3600"; return 0; }  # fallback: 1 hour

  # Parse hour
  local hour=""
  hour=$(echo "$reset_str" | grep -oE '[0-9]+')
  local ampm=""
  ampm=$(echo "$reset_str" | grep -oE '[ap]m')

  # Convert to 24h
  if [ "$ampm" = "pm" ] && [ "$hour" -ne 12 ]; then
    hour=$((hour + 12))
  elif [ "$ampm" = "am" ] && [ "$hour" -eq 12 ]; then
    hour=0
  fi

  # Calculate seconds until reset time
  local now_epoch
  now_epoch=$(date +%s)
  local now_hour
  now_hour=$(date +%H | sed 's/^0//')
  local now_min
  now_min=$(date +%M | sed 's/^0//')
  local now_sec
  now_sec=$(date +%S | sed 's/^0//')

  local now_in_seconds=$((now_hour * 3600 + now_min * 60 + now_sec))
  local reset_in_seconds=$((hour * 3600))

  local wait_seconds=$((reset_in_seconds - now_in_seconds))
  # If reset is tomorrow (negative), add 24h
  [ "$wait_seconds" -le 0 ] && wait_seconds=$((wait_seconds + 86400))
  # Add 2 minute buffer
  wait_seconds=$((wait_seconds + 120))

  # Record in state
  local total
  total=$(jq -r '.total_hits // 0' "$RL_STATE_FILE" 2>/dev/null || echo "0")
  local wait_until=$((now_epoch + wait_seconds))
  rl_set '.rate_limited = true | .reset_time = $r | .wait_until = $w | .total_hits = $t' \
    --arg r "$reset_str" \
    --argjson w "$wait_until" \
    --argjson t "$((total + 1))"

  echo "$wait_seconds"
  return 0
}

# Record successful call (clear rate limit state)
rl_record_success() {
  rl_set '.rate_limited = false | .reset_time = "" | .wait_until = 0'
}

# Check if we're in a rate limit cooldown period
# Returns 0 if OK to proceed, 1 if should wait. Outputs remaining seconds.
rl_check() {
  local wait_until
  wait_until=$(jq -r '.wait_until // 0' "$RL_STATE_FILE" 2>/dev/null || echo "0")

  [ "$wait_until" -eq 0 ] && return 0

  local now
  now=$(date +%s)
  local remaining=$((wait_until - now))

  if [ "$remaining" -gt 0 ]; then
    echo "$remaining"
    return 1
  fi

  # Cooldown elapsed — clear state
  rl_record_success
  return 0
}

# Get current status summary (for logging)
rl_status() {
  local limited
  limited=$(jq -r '.rate_limited // false' "$RL_STATE_FILE" 2>/dev/null || echo "false")
  local reset
  reset=$(jq -r '.reset_time // ""' "$RL_STATE_FILE" 2>/dev/null || echo "")
  local total
  total=$(jq -r '.total_hits // 0' "$RL_STATE_FILE" 2>/dev/null || echo "0")

  if [ "$limited" = "true" ]; then
    echo "RATE LIMITED (resets $reset, ${total} total hits)"
  else
    echo "OK (${total} total rate limit hits)"
  fi
}
