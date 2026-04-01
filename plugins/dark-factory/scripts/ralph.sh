#!/bin/bash
# Dark Factory Plugin — Ralph Wiggum Loop
# Autonomous backlog consumption with fresh context per iteration.
#
# Named after the Ralph Wiggum technique: each iteration is a fresh
# claude -p invocation, preventing context drift over long sessions.
#
# Usage: ./ralph.sh [max-iterations] [max-hours]
# Example: ./ralph.sh 10 8    (max 10 tasks, max 8 hours)
#          ./ralph.sh          (defaults: 5 tasks, 6 hours)

set -euo pipefail

# --- Resolve paths ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source config loader
source "$PLUGIN_ROOT/lib/config.sh"
load_project_config

FACTORY_DIR="$DF_FACTORY_DIR"
BACKLOG_FILE="$DF_BACKLOG_FILE"
RALPH_LOG="$FACTORY_DIR/ralph.log"

# --- Configuration ---
MAX_ITERATIONS="${1:-5}"
MAX_DURATION_HOURS="${2:-6}"
MAX_DURATION_SECONDS=$((MAX_DURATION_HOURS * 3600))
MAX_CONSECUTIVE_FAILURES=3
GOVERNANCE_CEILING="$DF_GOVERNANCE_CEILING"
MAX_ATTEMPTS_PER_SPEC="${DF_MAX_ATTEMPTS_PER_SPEC:-3}"
ATTEMPTS_FILE="$FACTORY_DIR/.ralph-attempts.json"

# --- State ---
START_TIME=$(date +%s)
ITERATION=0
CONSECUTIVE_FAILURES=0
TASKS_COMPLETED=0
TASKS_FAILED=0

# --- Retry Tracking ---
# Initialize attempts file if missing
if [ ! -f "$ATTEMPTS_FILE" ]; then
  echo '{}' > "$ATTEMPTS_FILE"
fi

# Get attempt count for a spec
get_attempts() {
  local spec="$1"
  jq -r --arg s "$spec" '.[$s] // 0' "$ATTEMPTS_FILE" 2>/dev/null || echo "0"
}

# Increment attempt count for a spec
inc_attempts() {
  local spec="$1"
  local tmp="${ATTEMPTS_FILE}.tmp"
  jq --arg s "$spec" '.[$s] = ((.[$s] // 0) + 1)' "$ATTEMPTS_FILE" > "$tmp" 2>/dev/null \
    && [ -s "$tmp" ] && mv "$tmp" "$ATTEMPTS_FILE" || rm -f "$tmp"
}

# --- Functions ---
log() {
  local msg="[ralph $(date +%H:%M:%S)] $1"
  echo "$msg" | tee -a "$RALPH_LOG"
}

elapsed_seconds() {
  echo $(( $(date +%s) - START_TIME ))
}

get_next_task() {
  local prompt=""
  if [ "$DF_BACKLOG_FORMAT" = "issue+spec" ]; then
    prompt="Read the file $BACKLOG_FILE.
Find the FIRST row in the 'Queue' table that meets ALL of these criteria:
1. Status column is 'pending'
2. Governance column is T0 or T1 (skip T2, T3, T4 — these need human review)

Output ONLY in this exact format: ISSUE_NUMBER|SPEC_PATH
For example: 42|docs/specs/backend-something.intent.md
The issue number is the # column, the spec path is the Intent Spec column (without backticks).
If no eligible pending tasks exist, output exactly: EMPTY
Do not output anything else."
  else
    prompt="Read the file $BACKLOG_FILE.
Find the FIRST pending task.
Output ONLY the spec file path (no backticks, no extra text).
If no pending tasks exist, output exactly: EMPTY"
  fi

  timeout 60 claude -p "$prompt" \
    --max-budget-usd 0.50 \
    --allowedTools "Read" \
    2>/dev/null || echo "EMPTY"
}

update_backlog_status() {
  local task_label="$1"
  local new_status="$2"
  local session_id="$3"

  timeout 60 claude -p "Edit the file $BACKLOG_FILE.
Find the row containing '$task_label' in the Queue table.
Change its Status from 'pending' to '$new_status'.
If status is 'completed', 'rejected', or 'no-op', move the row to the appropriate section (Completed or Rejected).
Add session ID '$session_id' to the Session column." \
    --max-budget-usd 0.50 \
    --allowedTools "Read,Edit" \
    2>/dev/null || true
}

# --- Banner ---
log "========================================="
log "  $DF_PROJECT_NAME Dark Factory — Ralph Wiggum Loop"
log "========================================="
log "Max iterations: $MAX_ITERATIONS"
log "Max duration: ${MAX_DURATION_HOURS}h"
log "Governance ceiling: $GOVERNANCE_CEILING"
log "Max attempts per spec: $MAX_ATTEMPTS_PER_SPEC"
log "Started at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log ""

# --- Pre-flight: Sync backlog (optional) ---
if [ -n "$DF_GITHUB_REPO" ] && command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
  log "Syncing backlog from GitHub Issues..."
  "$SCRIPT_DIR/sync-backlog.sh" 2>>"$RALPH_LOG" || log "WARNING: Backlog sync failed (continuing with existing backlog)"
else
  log "GitHub CLI not configured or no repo set — using existing backlog.md (manual mode)"
fi
log ""

# --- Main Loop ---
while true; do
  # --- Guard: Stop signal ---
  if [ -f "$FACTORY_DIR/.stop-signal" ]; then
    log "STOP: Stop signal received (.stop-signal file found)"
    rm -f "$FACTORY_DIR/.stop-signal"
    break
  fi

  # --- Guard: Max iterations ---
  if [ "$ITERATION" -ge "$MAX_ITERATIONS" ]; then
    log "STOP: Reached max iterations ($MAX_ITERATIONS)"
    break
  fi

  # --- Guard: Max duration ---
  if [ "$(elapsed_seconds)" -ge "$MAX_DURATION_SECONDS" ]; then
    log "STOP: Reached max duration (${MAX_DURATION_HOURS}h)"
    break
  fi

  # --- Guard: Consecutive failures ---
  if [ "$CONSECUTIVE_FAILURES" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
    log "STOP: ${MAX_CONSECUTIVE_FAILURES} consecutive failures — something systemic may be wrong"
    "$SCRIPT_DIR/alert.sh" critical "Ralph Loop Stopped" "${MAX_CONSECUTIVE_FAILURES} consecutive failures" 2>/dev/null || true
    break
  fi

  ITERATION=$((ITERATION + 1))
  log "--- Iteration $ITERATION / $MAX_ITERATIONS ---"

  # --- Step 1: Pick next task ---
  log "Selecting next task from backlog..."
  RAW_TASK_FULL=$(get_next_task)

  if [ "$DF_BACKLOG_FORMAT" = "issue+spec" ]; then
    RAW_TASK=$(echo "$RAW_TASK_FULL" | grep -E '^[0-9]+\|' | head -1 | tr -d '`' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -z "$RAW_TASK" ]; then
      RAW_TASK=$(echo "$RAW_TASK_FULL" | grep -oE '[0-9]+\|[^ ]+\.intent\.md' | head -1)
    fi
    if [ -z "$RAW_TASK" ] && echo "$RAW_TASK_FULL" | grep -q "EMPTY"; then
      RAW_TASK="EMPTY"
    fi
  else
    RAW_TASK=$(echo "$RAW_TASK_FULL" | grep -v "^$" | tail -1 | tr -d '`' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if echo "$RAW_TASK" | grep -qi "EMPTY"; then
      RAW_TASK="EMPTY"
    fi
  fi

  if [ "$RAW_TASK" = "EMPTY" ] || [ -z "$RAW_TASK" ]; then
    log "STOP: No pending tasks in backlog"
    break
  fi

  # Parse task based on format
  if [ "$DF_BACKLOG_FORMAT" = "issue+spec" ]; then
    TASK_ISSUE=$(echo "$RAW_TASK" | cut -d'|' -f1 | tr -d '[:space:]')
    TASK_SPEC=$(echo "$RAW_TASK" | cut -d'|' -f2- | tr -d '[:space:]')
    TASK_LABEL="${TASK_SPEC:-$TASK_ISSUE}"

    if [ -n "$TASK_SPEC" ] && [ "$TASK_SPEC" != "$TASK_ISSUE" ]; then
      RUN_ARGS="$TASK_SPEC"
      log "Selected: #$TASK_ISSUE $TASK_SPEC"
    elif [ -n "$TASK_ISSUE" ]; then
      RUN_ARGS="--issue $TASK_ISSUE"
      log "Selected: Issue #$TASK_ISSUE (no spec file)"
    else
      log "STOP: Could not parse task from backlog"
      break
    fi
  else
    TASK_LABEL="$RAW_TASK"
    RUN_ARGS="$RAW_TASK"
    log "Selected: $RAW_TASK"
  fi

  # --- Guard: Max attempts per spec ---
  TASK_ATTEMPTS=$(get_attempts "$TASK_LABEL")
  if [ "$TASK_ATTEMPTS" -ge "$MAX_ATTEMPTS_PER_SPEC" ]; then
    log "SKIP: $TASK_LABEL has reached max attempts ($TASK_ATTEMPTS/$MAX_ATTEMPTS_PER_SPEC) — marking exhausted"
    update_backlog_status "$TASK_LABEL" "exhausted" "n/a"
    "$SCRIPT_DIR/alert.sh" warning "Spec Exhausted" "$TASK_LABEL failed $MAX_ATTEMPTS_PER_SPEC times" 2>/dev/null || true
    continue
  fi
  log "Attempt $((TASK_ATTEMPTS + 1))/$MAX_ATTEMPTS_PER_SPEC for $TASK_LABEL"

  # --- Step 2: Execute task (fresh context) ---
  log "Executing task..."
  # shellcheck disable=SC2086
  DECISION=$("$SCRIPT_DIR/run-task.sh" $RUN_ARGS 2>>"$RALPH_LOG" || echo "blocked")
  DECISION=$(echo "$DECISION" | tail -1 | tr -d '[:space:]')

  SESSION_ID=$(ls -t "$FACTORY_DIR/sessions/" 2>/dev/null | head -1)

  # --- Step 3: Apply result ---
  case "$DECISION" in
    "auto-ship"|"auto-pr")
      log "SUCCESS: $TASK_LABEL → $DECISION (session: $SESSION_ID)"
      update_backlog_status "$TASK_LABEL" "completed" "$SESSION_ID"
      TASKS_COMPLETED=$((TASKS_COMPLETED + 1))
      CONSECUTIVE_FAILURES=0
      ;;
    "no-op")
      log "NO-OP: $TASK_LABEL → already implemented (session: $SESSION_ID)"
      update_backlog_status "$TASK_LABEL" "no-op" "$SESSION_ID"
      CONSECUTIVE_FAILURES=0
      ;;
    "review-pr"|"gated")
      log "DEFERRED: $TASK_LABEL → $DECISION (needs human review)"
      update_backlog_status "$TASK_LABEL" "deferred:$DECISION" "$SESSION_ID"
      CONSECUTIVE_FAILURES=0
      ;;
    "blocked")
      log "FAILED: $TASK_LABEL → blocked (session: $SESSION_ID)"
      inc_attempts "$TASK_LABEL"
      TASKS_FAILED=$((TASKS_FAILED + 1))
      CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
      # Check if spec is now exhausted
      TASK_ATTEMPTS_NOW=$(get_attempts "$TASK_LABEL")
      if [ "$TASK_ATTEMPTS_NOW" -ge "$MAX_ATTEMPTS_PER_SPEC" ]; then
        log "EXHAUSTED: $TASK_LABEL reached max attempts ($MAX_ATTEMPTS_PER_SPEC) — no more retries"
        update_backlog_status "$TASK_LABEL" "exhausted" "$SESSION_ID"
        # Record failure for guardrails
        "$SCRIPT_DIR/record-failure.sh" "$TASK_LABEL" "$SESSION_ID" "exhausted after $MAX_ATTEMPTS_PER_SPEC attempts" 2>>"$RALPH_LOG" || true
      else
        update_backlog_status "$TASK_LABEL" "pending" "$SESSION_ID"
        log "RETRY: $TASK_LABEL back to pending (attempt $TASK_ATTEMPTS_NOW/$MAX_ATTEMPTS_PER_SPEC)"
      fi
      ;;
    *)
      log "UNKNOWN: $TASK_LABEL → $DECISION"
      CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
      ;;
  esac

  log "Progress: $TASKS_COMPLETED completed, $TASKS_FAILED failed, $CONSECUTIVE_FAILURES consecutive failures"
  log ""
done

# --- Summary ---
TOTAL_ELAPSED=$(elapsed_seconds)
HOURS=$((TOTAL_ELAPSED / 3600))
MINUTES=$(( (TOTAL_ELAPSED % 3600) / 60 ))

log "========================================="
log "  Ralph Wiggum Loop — Summary"
log "========================================="
log "Iterations:     $ITERATION"
log "Completed:      $TASKS_COMPLETED"
log "Failed:         $TASKS_FAILED"
log "Duration:       ${HOURS}h ${MINUTES}m"
log "Finished at:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "========================================="

# Alert on completion
"$SCRIPT_DIR/alert.sh" info "Ralph Loop Complete" "$TASKS_COMPLETED completed, $TASKS_FAILED failed in ${HOURS}h ${MINUTES}m" 2>/dev/null || true
