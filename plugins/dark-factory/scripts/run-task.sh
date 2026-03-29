#!/bin/bash
# Dark Factory Plugin — Non-Interactive Task Executor
# Executes a single task through the project's pipeline,
# then validates via holdout + satisfaction + governance layers.
#
# Usage: ./run-task.sh <intent-spec-path>
#        ./run-task.sh --issue <number>
#
# This script:
# 1. Reads intent spec + strips holdout scenarios
# 2. Reads GitHub Issue metadata for labels (optional)
# 3. Launches claude -p to run the existing pipeline
# 4. Runs holdout validation separately (agent cannot see holdout content)
# 5. Runs satisfaction testing
# 6. Applies governance tier decision
# 7. Ships based on configured ship model

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source shared libraries
source "$PLUGIN_ROOT/lib/config.sh"
source "$PLUGIN_ROOT/lib/governance.sh"
source "$PLUGIN_ROOT/lib/ship.sh"

load_project_config

# --- Arguments ---
INPUT="${1:?Usage: run-task.sh <intent-spec-path> OR run-task.sh --issue <number>}"
if [ "$INPUT" = "--issue" ]; then
  ISSUE_NUMBER="${2:?Usage: run-task.sh --issue <number>}"
  SPEC_FILE=""
else
  SPEC_FILE="$INPUT"
  ISSUE_NUMBER=""
fi

SESSION_ID="task-$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 4)"
SESSION_DIR="$DF_FACTORY_DIR/sessions/$SESSION_ID"
export DF_SESSION_ID="$SESSION_ID"
export DF_SESSION_DIR="$SESSION_DIR"

# --- Setup ---
START_TIME=$(date +%s)
mkdir -p "$SESSION_DIR"
echo "[$SESSION_ID] Starting task: ${SPEC_FILE:-Issue #$ISSUE_NUMBER}" | tee "$SESSION_DIR/run.log"
echo "[$SESSION_ID] Project: $DF_PROJECT_NAME" >> "$SESSION_DIR/run.log"
echo "[$SESSION_ID] Started at: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$SESSION_DIR/run.log"

# --- Step 1: Read intent spec + issue metadata ---
if [ -n "$SPEC_FILE" ]; then
  SPEC_PATH="$DF_PROJECT_DIR/$SPEC_FILE"
  if [ ! -f "$SPEC_PATH" ]; then
    echo "[$SESSION_ID] ERROR: Spec file not found: $SPEC_FILE" | tee -a "$SESSION_DIR/run.log"
    echo '<!-- DARK_FACTORY_RESULT:{"success":false,"layer":"unknown","files_changed":0,"tests_passed":0,"tests_total":0,"coverage":0,"pr_url":null,"error":"spec_not_found"} -->' > "$SESSION_DIR/implementation-result.txt"
    echo "blocked"
    exit 1
  fi

  # Strip holdout scenarios section (agent must not see these)
  SPEC_CONTENT=$(awk '/^## Holdout Scenarios/{skip=1;next} /^## /{skip=0} !skip' "$SPEC_PATH")
  echo "$SPEC_CONTENT" > "$SESSION_DIR/spec.md"

  # Save full spec (with holdouts) for holdout validator
  cp "$SPEC_PATH" "$SESSION_DIR/spec-full.md"

  if [ -z "$ISSUE_NUMBER" ]; then
    ISSUE_NUMBER=$(grep -oE '#[0-9]+' "$SPEC_PATH" | head -1 | tr -d '#')
  fi
fi

# Read GitHub Issue metadata (optional)
ISSUE_LABELS=""
ISSUE_TITLE=""
if [ -n "$ISSUE_NUMBER" ] && [ -n "$DF_GITHUB_REPO" ] && command -v gh &>/dev/null; then
  echo "[$SESSION_ID] Reading issue #$ISSUE_NUMBER metadata..." >> "$SESSION_DIR/run.log"
  ISSUE_JSON=$(gh issue view "$ISSUE_NUMBER" -R "$DF_GITHUB_REPO" --json title,body,labels,state 2>/dev/null || echo '{}')

  if [ "$ISSUE_JSON" != "{}" ]; then
    ISSUE_TITLE=$(echo "$ISSUE_JSON" | jq -r '.title // ""')
    ISSUE_LABELS=$(echo "$ISSUE_JSON" | jq -r '[.labels[].name] | join(",")' 2>/dev/null || echo "")
    echo "$ISSUE_JSON" > "$SESSION_DIR/issue.json"
  fi
fi

# Extract layer
LAYER=$(extract_layer "$ISSUE_LABELS" "$SPEC_FILE")

# Extract pipeline type
PIPELINE=$(echo "$ISSUE_LABELS" | tr ',' '\n' | grep '^pipeline:' | head -1 | cut -d: -f2)
PIPELINE=${PIPELINE:-standard}

echo "[$SESSION_ID] Spec: ${SPEC_FILE:-none}" >> "$SESSION_DIR/run.log"
echo "[$SESSION_ID] Issue: ${ISSUE_NUMBER:-none} ${ISSUE_TITLE}" >> "$SESSION_DIR/run.log"

if [ -z "$ISSUE_NUMBER" ] && [ -z "$SPEC_FILE" ]; then
  echo "[$SESSION_ID] ERROR: No issue number and no spec file — cannot proceed" | tee -a "$SESSION_DIR/run.log"
  echo "blocked"
  exit 1
fi
echo "[$SESSION_ID] Layer: $LAYER | Pipeline: $PIPELINE" >> "$SESSION_DIR/run.log"

# --- Step 2: Execute implementation ---
echo "[$SESSION_ID] Launching claude -p for implementation..." >> "$SESSION_DIR/run.log"

IMPL_TIMEOUT=2700   # 45 minutes
IMPL_BUDGET=10      # $10 max per implementation agent
HOLDOUT_BUDGET=2    # $2 max per holdout validation
SAT_BUDGET=2        # $2 max per satisfaction judge

SPEC_SECTION=""
if [ -f "$SESSION_DIR/spec.md" ]; then
  SPEC_SECTION="## Intent Spec (holdout scenarios stripped)
$(cat "$SESSION_DIR/spec.md")"
fi

ISSUE_REF=""
if [ -n "$ISSUE_NUMBER" ]; then
  ISSUE_REF="This implements GitHub Issue #$ISSUE_NUMBER."
fi

timeout "$IMPL_TIMEOUT" claude -p "You are the $DF_PROJECT_NAME Dark Factory executor running in non-interactive mode.
Session: $SESSION_ID

## Instructions

1. Read CLAUDE.md for project context and coding standards
2. Execute this task through the SDD+TDD pipeline:
   - Analyze task (size, affected areas, dependencies)
   - Write tests FIRST (TDD)
   - Implement code to pass tests
   - Run build, lint, typecheck verification
   - Run all tests (coverage >= 80%)
   - If any step fails, attempt self-heal (max 2 retries)
3. Use worktree isolation for implementation (git worktree)
4. Commit with [agent:dark-factory] suffix
5. Create PR targeting the default development branch (NEVER target 'main' directly)
6. Follow the pipeline type: $PIPELINE
${ISSUE_REF}

$SPEC_SECTION

## Important
- ALWAYS create a PR. Do NOT merge the PR yourself — governance will handle merge decisions.
- If the spec references a GitHub Issue, link it in the PR body with 'Closes #N'.
- Add label 'dark-factory' to the PR.

## Output — CRITICAL
At the very end of your response, you MUST write a machine-readable result block in EXACTLY this format:
<!-- DARK_FACTORY_RESULT:{\"success\":true,\"layer\":\"$LAYER\",\"files_changed\":5,\"tests_passed\":10,\"tests_total\":10,\"coverage\":85,\"pr_url\":\"https://github.com/$DF_GITHUB_REPO/pull/123\",\"error\":null} -->

Fields:
- success: boolean — did implementation + tests + build all pass?
- layer: string — the component/layer that was modified
- files_changed: number — count of files created or modified
- tests_passed: number
- tests_total: number
- coverage: number — coverage percentage
- pr_url: string or null — the PR URL if created
- error: string or null — error description if failed

This marker is parsed by automation. Do NOT omit it.

Also write the result JSON to the file $SESSION_DIR/agent-result.json as a backup." \
  --max-budget-usd "$IMPL_BUDGET" \
  --allowedTools "Read,Write,Edit,Grep,Glob,Bash,Agent" \
  2>"$SESSION_DIR/implementation-stderr.log" \
  >"$SESSION_DIR/implementation-result.txt"
IMPL_EXIT=$?

if [ "$IMPL_EXIT" -eq 124 ]; then
  echo "[$SESSION_ID] TIMEOUT: Implementation agent killed after ${IMPL_TIMEOUT}s" >> "$SESSION_DIR/run.log"
  echo '<!-- DARK_FACTORY_RESULT:{"success":false,"layer":"'"$LAYER"'","files_changed":0,"tests_passed":0,"tests_total":0,"coverage":0,"pr_url":null,"error":"timeout after '"${IMPL_TIMEOUT}"'s"} -->' > "$SESSION_DIR/implementation-result.txt"
fi

echo "[$SESSION_ID] Implementation complete (exit=$IMPL_EXIT)" >> "$SESSION_DIR/run.log"

# --- Step 3: Run holdout validation ---
echo "[$SESSION_ID] Running holdout validation..." >> "$SESSION_DIR/run.log"

HOLDOUT_LAYER=$(map_holdout_layer "$LAYER")
HOLDOUT_DIR="$DF_HOLDOUT_DIR/$HOLDOUT_LAYER"
HAS_YAML_HOLDOUTS=false
HAS_INLINE_HOLDOUTS=false

if [ -d "$HOLDOUT_DIR" ] && [ "$(ls -A "$HOLDOUT_DIR" 2>/dev/null)" ]; then
  HAS_YAML_HOLDOUTS=true
fi
if [ -f "$SESSION_DIR/spec-full.md" ] && grep -q "^## Holdout Scenarios" "$SESSION_DIR/spec-full.md" 2>/dev/null; then
  HAS_INLINE_HOLDOUTS=true
  awk '/^## Holdout Scenarios/{found=1;next} /^## /{if(found)exit} found' "$SESSION_DIR/spec-full.md" > "$SESSION_DIR/inline-holdouts.md"
fi

if [ "$HAS_YAML_HOLDOUTS" = "true" ] || [ "$HAS_INLINE_HOLDOUTS" = "true" ]; then
  HOLDOUT_PROMPT="You are the holdout-validator agent for the $DF_PROJECT_NAME Dark Factory.
Session: $SESSION_ID

Read the agent instructions from the holdout-validator agent definition.

Run holdout validation for layer: $LAYER"

  if [ "$HAS_YAML_HOLDOUTS" = "true" ]; then
    HOLDOUT_PROMPT="$HOLDOUT_PROMPT

## Layer-wide holdout scenarios
Directory: $HOLDOUT_DIR
Read each .holdout.yaml file and validate the current implementation."
  fi

  if [ "$HAS_INLINE_HOLDOUTS" = "true" ]; then
    HOLDOUT_PROMPT="$HOLDOUT_PROMPT

## Inline holdout scenarios (from intent spec)
File: $SESSION_DIR/inline-holdouts.md
Read this file and validate each scenario against the implementation."
  fi

  HOLDOUT_PROMPT="$HOLDOUT_PROMPT

Output results as JSON with fields: overall_pass (boolean), overall_score (number 0-100), scenarios (array)."

  HOLDOUT_VALIDATOR_MODE=true timeout 300 claude -p "$HOLDOUT_PROMPT" \
    --max-budget-usd "$HOLDOUT_BUDGET" \
    --allowedTools "Read,Grep,Glob,Bash" \
    2>"$SESSION_DIR/holdout-stderr.log" \
    >"$SESSION_DIR/holdout-result.json" || true
else
  echo '{"overall_pass": true, "overall_score": 100, "note": "No holdout scenarios found"}' > "$SESSION_DIR/holdout-result.json"
fi

echo "[$SESSION_ID] Holdout validation complete" >> "$SESSION_DIR/run.log"

# --- Step 4: Run satisfaction testing ---
echo "[$SESSION_ID] Running satisfaction testing..." >> "$SESSION_DIR/run.log"

SAT_SPEC_REF=""
if [ -f "$SESSION_DIR/spec.md" ]; then
  SAT_SPEC_REF="Read the intent spec (stripped) from $SESSION_DIR/spec.md for requirements."
elif [ -f "$SESSION_DIR/issue.json" ]; then
  SAT_SPEC_REF="Read the issue body from $SESSION_DIR/issue.json for requirements."
fi

timeout 300 claude -p "You are the satisfaction-judge agent for the $DF_PROJECT_NAME Dark Factory.
Session: $SESSION_ID

Read the agent instructions from the satisfaction-judge agent definition.

Evaluate the implementation for ${SPEC_FILE:-Issue #$ISSUE_NUMBER} (layer: $LAYER).

1. $SAT_SPEC_REF
2. Find all implementation files related to this feature
3. Perform Pass 1 evaluation (5 dimensions: correctness, completeness, code quality, test quality, architecture)
4. Perform Pass 2 adversarial review
5. Output final score and decision as JSON with fields: final_score (number), composite_score (number), dimensions (object), verdict (string)
6. Also write the result JSON to $SESSION_DIR/satisfaction-parsed.json as a backup" \
  --max-budget-usd "$SAT_BUDGET" \
  --allowedTools "Read,Grep,Glob" \
  2>"$SESSION_DIR/satisfaction-stderr.log" \
  >"$SESSION_DIR/satisfaction-result.json" || true

echo "[$SESSION_ID] Satisfaction testing complete" >> "$SESSION_DIR/run.log"

# --- Step 5: Governance decision ---
echo "[$SESSION_ID] Applying governance..." >> "$SESSION_DIR/run.log"

IMPL_RESULT_FILE="$SESSION_DIR/implementation-result.txt"

IMPL_JSON=$(parse_impl_result "$IMPL_RESULT_FILE" "$SESSION_DIR" || echo "{}")
echo "[$SESSION_ID] Parsed implementation result: $IMPL_JSON" >> "$SESSION_DIR/run.log"
echo "$IMPL_JSON" > "$SESSION_DIR/implementation-parsed.json"

IMPL_SUCCESS=$(echo "$IMPL_JSON" | jq -r '.success // false')
FILES_CHANGED=$(echo "$IMPL_JSON" | jq -r '.files_changed // 0')
IMPL_PR_URL=$(echo "$IMPL_JSON" | jq -r '.pr_url // empty')
IMPL_COVERAGE=$(echo "$IMPL_JSON" | jq -r '.coverage // 0')

[ "$IMPL_SUCCESS" = "null" ] && IMPL_SUCCESS="false"
[ "$FILES_CHANGED" = "null" ] && FILES_CHANGED="0"
[ "$IMPL_PR_URL" = "null" ] && IMPL_PR_URL=""
[ "$IMPL_COVERAGE" = "null" ] && IMPL_COVERAGE="0"

if [ -z "$IMPL_PR_URL" ]; then
  IMPL_PR_URL=$(grep -oE 'https://github.com/[^ )"]+/pull/[0-9]+' "$IMPL_RESULT_FILE" 2>/dev/null | head -1 || echo "")
fi

# Parse holdout + satisfaction results
HOLDOUT_PASS=$(parse_json_field "$SESSION_DIR/holdout-result.json" "overall_pass" "true")
HOLDOUT_SCORE=$(parse_json_field "$SESSION_DIR/holdout-result.json" "overall_score" "0")

SATISFACTION_SCORE="0"
for sat_file in "$SESSION_DIR/satisfaction-parsed.json" "$SESSION_DIR/satisfaction-result.json"; do
  [ -f "$sat_file" ] || continue
  for field in final_score composite_score score; do
    val=$(parse_json_field "$sat_file" "$field" "0")
    if [ "$val" != "0" ] && [ "$val" != "null" ]; then
      SATISFACTION_SCORE="$val"
      break 2
    fi
  done
done

SAT_INT=$(safe_int "$SATISFACTION_SCORE")
HOLDOUT_INT=$(safe_int "$HOLDOUT_SCORE")
FILES_INT=$(safe_int "$FILES_CHANGED")

# Sanitize boolean values for jq --argjson
[[ "$IMPL_SUCCESS" =~ ^(true|false)$ ]] || IMPL_SUCCESS="false"
[[ "$HOLDOUT_PASS" =~ ^(true|false)$ ]] || HOLDOUT_PASS="true"
ISSUE_NUMBER=$(safe_int "${ISSUE_NUMBER:-0}")

# Compute risk score (reads risk_factors from project config)
RISK_RESULT=$(compute_risk_score "$ISSUE_LABELS" "$LAYER" "$FILES_INT" "$PIPELINE")
RISK_SCORE=$(safe_int "$(echo "$RISK_RESULT" | cut -d'|' -f1)")
RISK_FACTORS=$(echo "$RISK_RESULT" | cut -d'|' -f2-)
echo "[$SESSION_ID] Risk score: $RISK_SCORE (factors: $RISK_FACTORS)" >> "$SESSION_DIR/run.log"

# Determine governance tier
TIER_RESULT=$(determine_tier "$IMPL_SUCCESS" "$FILES_INT" "$HOLDOUT_PASS" "$SAT_INT" "$RISK_SCORE")
TIER=$(echo "$TIER_RESULT" | cut -d'|' -f1)
DECISION=$(echo "$TIER_RESULT" | cut -d'|' -f2)

if [ "$DECISION" = "no-op" ]; then
  echo "[$SESSION_ID] NO-OP: 0 files changed — feature already exists or nothing to do" >> "$SESSION_DIR/run.log"
fi

# Write governance result
jq -n \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg sid "$SESSION_ID" \
  --argjson issue "${ISSUE_NUMBER:-0}" \
  --arg layer "$LAYER" \
  --argjson impl "${IMPL_SUCCESS:-false}" \
  --argjson hp "${HOLDOUT_PASS:-true}" \
  --argjson hs "${HOLDOUT_INT:-0}" \
  --argjson ss "${SAT_INT:-0}" \
  --argjson rs "$RISK_SCORE" \
  --arg rf "$RISK_FACTORS" \
  --arg tier "$TIER" \
  --arg dec "$DECISION" \
  '{timestamp:$ts, session_id:$sid, issue_number:$issue, layer:$layer, implementation_success:$impl, holdout_pass:$hp, holdout_score:$hs, satisfaction_score:$ss, risk_score:$rs, risk_factors:$rf, tier:$tier, decision:$dec}' \
  > "$SESSION_DIR/governance.json"
echo "[$SESSION_ID] Governance: tier=$TIER decision=$DECISION sat=$SAT_INT holdout=$HOLDOUT_INT risk=$RISK_SCORE" >> "$SESSION_DIR/run.log"

# --- Step 6: Ship ---
echo "[$SESSION_ID] Applying ship decision..." >> "$SESSION_DIR/run.log"

PR_URL="${IMPL_PR_URL:-}"
GOVERNANCE_BODY=$(build_governance_body "$SESSION_ID" "${ISSUE_NUMBER:-0}" "$LAYER" "$TIER" "$DECISION" "$SAT_INT" "$HOLDOUT_INT" "$HOLDOUT_PASS" "$RISK_SCORE" "$IMPL_COVERAGE" "$FILES_INT")

case "$DECISION" in
  "blocked")
    ship_blocked "$PR_URL" "${ISSUE_NUMBER:-}" "$DF_GITHUB_REPO" "$HOLDOUT_PASS" "$SAT_INT" "$IMPL_SUCCESS"
    ;;
  "no-op")
    ship_noop "${ISSUE_NUMBER:-}" "$DF_GITHUB_REPO"
    ;;
  "review-pr"|"gated")
    ship_review "$PR_URL" "${ISSUE_NUMBER:-}" "$DF_GITHUB_REPO" "$DECISION" "$GOVERNANCE_BODY"
    ;;
  "auto-ship"|"auto-pr")
    ship_auto "$PR_URL" "${ISSUE_NUMBER:-}" "$DF_GITHUB_REPO" "$DECISION" "$GOVERNANCE_BODY" "$SAT_INT" "$HOLDOUT_INT"
    ;;
  *)
    ship_log "UNKNOWN decision: $DECISION"
    ;;
esac

ship_log "Ship complete"

# --- Summary ---
ELAPSED=$(( $(date +%s) - START_TIME ))
echo "" >> "$SESSION_DIR/run.log"
echo "[$SESSION_ID] === SESSION SUMMARY ===" >> "$SESSION_DIR/run.log"
echo "[$SESSION_ID] Project: $DF_PROJECT_NAME" >> "$SESSION_DIR/run.log"
echo "[$SESSION_ID] Issue: #${ISSUE_NUMBER:-none} ($ISSUE_TITLE)" >> "$SESSION_DIR/run.log"
echo "[$SESSION_ID] Layer: $LAYER | Pipeline: $PIPELINE" >> "$SESSION_DIR/run.log"
echo "[$SESSION_ID] Implementation: $IMPL_SUCCESS" >> "$SESSION_DIR/run.log"
echo "[$SESSION_ID] Holdout: $HOLDOUT_PASS (score: $HOLDOUT_SCORE)" >> "$SESSION_DIR/run.log"
echo "[$SESSION_ID] Satisfaction: $SATISFACTION_SCORE" >> "$SESSION_DIR/run.log"
echo "[$SESSION_ID] Tier: $TIER | Decision: $DECISION" >> "$SESSION_DIR/run.log"
echo "[$SESSION_ID] PR: ${PR_URL:-none}" >> "$SESSION_DIR/run.log"
echo "[$SESSION_ID] Duration: ${ELAPSED}s" >> "$SESSION_DIR/run.log"
echo "[$SESSION_ID] Completed at: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$SESSION_DIR/run.log"

# Output for Ralph loop consumption
echo "$DECISION"
