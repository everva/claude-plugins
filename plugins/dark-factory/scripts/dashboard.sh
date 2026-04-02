#!/bin/bash
# Dark Factory Plugin — Observability Dashboard
# Aggregates session data and produces a report
#
# Usage: ./dashboard.sh [--json] [--days N]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PLUGIN_ROOT/lib/config.sh"
load_project_config

SESSIONS_DIR="$DF_FACTORY_DIR/sessions"
RALPH_LOG="$DF_FACTORY_DIR/ralph.log"

OUTPUT_FORMAT="text"
DAYS=7
while [ $# -gt 0 ]; do
  case "$1" in
    --json) OUTPUT_FORMAT="json"; shift ;;
    --days) DAYS="${2:-7}"; shift 2 ;;
    *) shift ;;
  esac
done

# --- Collect metrics ---
TOTAL_SESSIONS=0
PASSED_SESSIONS=0
FAILED_SESSIONS=0
DEFERRED_SESSIONS=0
NOOP_SESSIONS=0
TOTAL_HOLDOUT_SCORE=0
TOTAL_SATISFACTION_SCORE=0
SCORED_SESSIONS=0

CUTOFF_DATE=$(date -v-${DAYS}d +%Y%m%d 2>/dev/null || date -d "${DAYS} days ago" +%Y%m%d 2>/dev/null || echo "00000000")

if [ -d "$SESSIONS_DIR" ]; then
  for session_dir in "$SESSIONS_DIR"/*/; do
    [ -d "$session_dir" ] || continue
    gov_file="$session_dir/governance.json"
    [ -f "$gov_file" ] || continue

    dir_name=$(basename "$session_dir")
    session_date=$(echo "$dir_name" | grep -oE '[0-9]{8}' | head -1)
    if [ -n "$session_date" ] && [ "$session_date" -lt "$CUTOFF_DATE" ] 2>/dev/null; then
      continue
    fi

    TOTAL_SESSIONS=$((TOTAL_SESSIONS + 1))
    decision=$(jq -r '.decision // "unknown"' "$gov_file" 2>/dev/null || echo "unknown")
    holdout_score=$(jq -r '.holdout_score // 0' "$gov_file" 2>/dev/null || echo "0")
    satisfaction_score=$(jq -r '.satisfaction_score // 0' "$gov_file" 2>/dev/null || echo "0")

    case "$decision" in
      "auto-ship"|"auto-pr") PASSED_SESSIONS=$((PASSED_SESSIONS + 1)) ;;
      "review-pr"|"gated") DEFERRED_SESSIONS=$((DEFERRED_SESSIONS + 1)) ;;
      "blocked") FAILED_SESSIONS=$((FAILED_SESSIONS + 1)) ;;
      "no-op") NOOP_SESSIONS=$((NOOP_SESSIONS + 1)) ;;
    esac

    if [ "$satisfaction_score" != "0" ] && [ "$satisfaction_score" != "null" ]; then
      TOTAL_SATISFACTION_SCORE=$((TOTAL_SATISFACTION_SCORE + ${satisfaction_score%.*}))
      SCORED_SESSIONS=$((SCORED_SESSIONS + 1))
    fi
    if [ "$holdout_score" != "0" ] && [ "$holdout_score" != "null" ]; then
      TOTAL_HOLDOUT_SCORE=$((TOTAL_HOLDOUT_SCORE + ${holdout_score%.*}))
    fi
  done
fi

if [ "$SCORED_SESSIONS" -gt 0 ]; then
  AVG_HOLDOUT=$((TOTAL_HOLDOUT_SCORE / SCORED_SESSIONS))
  AVG_SATISFACTION=$((TOTAL_SATISFACTION_SCORE / SCORED_SESSIONS))
else
  AVG_HOLDOUT=0
  AVG_SATISFACTION=0
fi

RALPH_RUNS=0
RALPH_LAST_RUN="never"
if [ -f "$RALPH_LOG" ]; then
  RALPH_RUNS=$(grep -c "Ralph Wiggum Loop — Summary" "$RALPH_LOG" 2>/dev/null || echo "0")
  RALPH_LAST_RUN=$(grep "Finished at:" "$RALPH_LOG" 2>/dev/null | tail -1 | sed 's/.*Finished at: *//' || echo "never")
fi

# Resilience state
CB_CURRENT_STATE="N/A"
RL_CURRENT_STATUS="N/A"
if [ -f "$DF_FACTORY_DIR/.circuit-breaker.json" ]; then
  CB_CURRENT_STATE=$(jq -r '.state // "N/A"' "$DF_FACTORY_DIR/.circuit-breaker.json" 2>/dev/null || echo "N/A")
fi
if [ -f "$DF_FACTORY_DIR/.rate-limiter.json" ]; then
  RL_CALLS=$(jq -r '.calls_this_hour // 0' "$DF_FACTORY_DIR/.rate-limiter.json" 2>/dev/null || echo "0")
  RL_CURRENT_STATUS="${RL_CALLS}/${DF_RATE_LIMIT_CALLS:-60}"
fi

if [ "$TOTAL_SESSIONS" -gt 0 ]; then
  PASS_RATE=$(( (PASSED_SESSIONS * 100) / TOTAL_SESSIONS ))
else
  PASS_RATE=0
fi

if [ "$OUTPUT_FORMAT" = "json" ]; then
  jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg project "$DF_PROJECT_NAME" \
    --argjson days "$DAYS" \
    --argjson total "$TOTAL_SESSIONS" \
    --argjson passed "$PASSED_SESSIONS" \
    --argjson failed "$FAILED_SESSIONS" \
    --argjson deferred "$DEFERRED_SESSIONS" \
    --argjson noop "$NOOP_SESSIONS" \
    --argjson rate "$PASS_RATE" \
    --argjson holdout "$AVG_HOLDOUT" \
    --argjson sat "$AVG_SATISFACTION" \
    --argjson runs "$RALPH_RUNS" \
    --arg last "$RALPH_LAST_RUN" \
    --arg cb "$CB_CURRENT_STATE" \
    --arg rl "$RL_CURRENT_STATUS" \
    '{timestamp:$ts, project:$project, period_days:$days, sessions:{total:$total, passed:$passed, failed:$failed, deferred:$deferred, noop:$noop, pass_rate:$rate}, quality:{avg_holdout:$holdout, avg_satisfaction:$sat}, ralph:{runs:$runs, last_run:$last}, resilience:{circuit_breaker:$cb, rate_usage:$rl}}'
else
  cat <<EOF

  $DF_PROJECT_NAME Dark Factory Dashboard — $(date +%Y-%m-%d)
  ═══════════════════════════════════════════

  Sessions (last ${DAYS} days)
  ────────────────────────────
  Total:      $TOTAL_SESSIONS
  Passed:     $PASSED_SESSIONS (auto-ship + auto-PR)
  Failed:     $FAILED_SESSIONS (blocked)
  Deferred:   $DEFERRED_SESSIONS (needs human review)
  No-Op:      $NOOP_SESSIONS (already implemented)
  Pass Rate:  ${PASS_RATE}%

  Quality Metrics
  ────────────────────────────
  Avg Holdout Score:       ${AVG_HOLDOUT}%
  Avg Satisfaction Score:  ${AVG_SATISFACTION}%

  Ralph Wiggum Loop
  ────────────────────────────
  Total Runs:    $RALPH_RUNS
  Last Run:      $RALPH_LAST_RUN
$(if [ -f "$DF_FACTORY_DIR/.rate-limiter.json" ]; then
  source "$PLUGIN_ROOT/lib/rate_limiter.sh" 2>/dev/null
  rl_init 2>/dev/null
  echo "  Rate Usage:    $(rl_status 2>/dev/null || echo 'N/A')"
fi)
$(if [ -f "$DF_FACTORY_DIR/.circuit-breaker.json" ]; then
  source "$PLUGIN_ROOT/lib/circuit_breaker.sh" 2>/dev/null
  echo "  Circuit State:  $(cb_state 2>/dev/null || echo 'N/A')"
fi)

  Backlog
  ────────────────────────────
$(grep -c "pending" "$DF_BACKLOG_FILE" 2>/dev/null || echo "0") pending tasks
$(grep -c "completed" "$DF_BACKLOG_FILE" 2>/dev/null || echo "0") completed tasks

EOF

  if [ "$TOTAL_SESSIONS" -gt 0 ]; then
    echo "  Recent Sessions"
    echo "  ────────────────────────────"
    for session_dir in $(ls -dt "$SESSIONS_DIR"/*/ 2>/dev/null | head -5); do
      gov_file="$session_dir/governance.json"
      [ -f "$gov_file" ] || continue
      sid=$(basename "$session_dir")
      decision=$(jq -r '.decision' "$gov_file" 2>/dev/null)
      tier=$(jq -r '.tier' "$gov_file" 2>/dev/null)
      sat=$(jq -r '.satisfaction_score' "$gov_file" 2>/dev/null)
      issue=$(jq -r '.issue_number' "$gov_file" 2>/dev/null)
      echo "  $sid  #$issue  $tier  $decision  sat:$sat"
    done
    echo ""
  fi
fi
