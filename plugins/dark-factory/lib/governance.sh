#!/bin/bash
# Dark Factory Plugin — Governance Library
# Pure functions for risk scoring, tier calculation, and JSON parsing.
# Sourced by run-task.sh and test suites.

# --- JSON Parsing ---

# Parse implementation result from DARK_FACTORY_RESULT marker or agent-result.json
# Usage: parse_impl_result <output-file> [session-dir]
parse_impl_result() {
  local file="$1"
  local session_dir="${2:-}"

  # Try 1: Read agent-result.json (written directly by the agent)
  if [ -n "$session_dir" ] && [ -f "$session_dir/agent-result.json" ]; then
    local agent_json=""
    agent_json=$(jq '.' "$session_dir/agent-result.json" 2>/dev/null)
    if [ -n "$agent_json" ] && [ "$agent_json" != "null" ]; then
      echo "$agent_json"
      return 0
    fi
  fi

  [ ! -f "$file" ] && { echo "{}"; return 1; }

  # Try 2: Extract DARK_FACTORY_RESULT marker (handles nested JSON)
  local json=""
  json=$(sed -n 's/.*DARK_FACTORY_RESULT://p' "$file" 2>/dev/null | head -1 | sed 's/[[:space:]]*-->.*//')
  if [ -n "$json" ] && echo "$json" | jq . >/dev/null 2>&1; then
    echo "$json"
    return 0
  fi

  # Try 3: Find any JSON with "success" field (progressive trim, max 500 iterations)
  json=$(grep -o '{"success":.*' "$file" 2>/dev/null | head -1)
  local trim_count=0
  while [ -n "$json" ] && [ "$trim_count" -lt 500 ]; do
    if echo "$json" | jq . >/dev/null 2>&1; then
      echo "$json"
      return 0
    fi
    json="${json%?}"
    trim_count=$((trim_count + 1))
  done

  echo "{}"
  return 1
}

# Extract a field from a JSON file with fallbacks
# Usage: parse_json_field <file> <field> <default>
parse_json_field() {
  local file="$1" field="$2" default="$3"
  [ ! -f "$file" ] && { echo "$default"; return; }

  # Try 1: Direct JSON field
  local val=""
  val=$(jq -r ".$field // empty" "$file" 2>/dev/null)
  if [ -n "$val" ] && [ "$val" != "null" ]; then echo "$val"; return; fi

  # Try 1b: Extract JSON from markdown code blocks (```json ... ```)
  local md_json=""
  md_json=$(sed -n '/^```json *$/,/^```$/p' "$file" 2>/dev/null | sed '1d;$d')
  if [ -n "$md_json" ]; then
    val=$(echo "$md_json" | jq -r ".$field // empty" 2>/dev/null)
    if [ -n "$val" ] && [ "$val" != "null" ]; then echo "$val"; return; fi
  fi

  # Try 1c: Search raw text for JSON object containing the field
  local raw_json=""
  raw_json=$(grep -oE "\{[^}]*\"$field\"[[:space:]]*:[^}]*\}" "$file" 2>/dev/null | head -1)
  if [ -n "$raw_json" ]; then
    val=$(echo "$raw_json" | jq -r ".$field // empty" 2>/dev/null)
    if [ -n "$val" ] && [ "$val" != "null" ]; then echo "$val"; return; fi
  fi

  # Try 2: Extract from claude -p wrapper JSON (.result field)
  val=$(jq -r '.result // empty' "$file" 2>/dev/null)
  if [ -n "$val" ]; then
    # Look for DARK_FACTORY_RESULT marker inside .result
    local marker_json=""
    marker_json=$(echo "$val" | grep -oE 'DARK_FACTORY_RESULT:\{[^}]+\}' | head -1 | sed 's/^DARK_FACTORY_RESULT://')
    if [ -n "$marker_json" ]; then
      local fval=""
      fval=$(echo "$marker_json" | jq -r ".$field // empty" 2>/dev/null)
      if [ -n "$fval" ] && [ "$fval" != "null" ]; then echo "$fval"; return; fi
    fi
    # Look for JSON block containing the field
    local block=""
    block=$(echo "$val" | grep -oE "\{[^}]*\"$field\"[^}]*\}" | head -1)
    if [ -n "$block" ]; then
      fval=$(echo "$block" | jq -r ".$field // empty" 2>/dev/null)
      if [ -n "$fval" ] && [ "$fval" != "null" ]; then echo "$fval"; return; fi
    fi
  fi

  echo "$default"
}

# --- Numeric Helpers ---

# Safely convert a value to integer (truncate decimal, default 0 for non-numeric)
# Usage: safe_int <value>
safe_int() {
  local val="${1%.*}"  # Truncate decimal
  val="${val:-0}"
  if [[ "$val" =~ ^-?[0-9]+$ ]]; then
    echo "$val"
  else
    echo "0"
  fi
}

# --- Risk Score Calculation ---

# Compute risk score from config-defined patterns and context
# Usage: compute_risk_score <issue_labels> <layer> <files_changed> <pipeline> [config_file]
# Output: SCORE|FACTORS (e.g. "25|cross-layer,large-change,")
compute_risk_score() {
  local issue_labels="$1"
  local layer="$2"
  local files_int="$3"
  local pipeline="$4"
  local config_file="${5:-${DF_PROJECT_DIR:-.}/.dark-factory/config.yaml}"

  local risk_score=0
  local risk_factors=""

  # Cross-layer detection (multiple layer labels or explicit cross-layer)
  local layer_count
  layer_count=$(echo "$issue_labels" | tr ',' '\n' | grep -c '^layer:' 2>/dev/null || true)
  layer_count=$(echo "$layer_count" | tr -d '[:space:]')
  layer_count=${layer_count:-0}
  if [ "$layer_count" -gt 1 ] || echo "$issue_labels" | grep -q 'layer:cross-layer'; then
    risk_score=$((risk_score + 15))
    risk_factors="${risk_factors}cross-layer,"
  fi

  # Large change detection
  if [ "$files_int" -gt 15 ]; then
    risk_score=$((risk_score + 10))
    risk_factors="${risk_factors}large-change,"
  fi

  # Full pipeline is riskier
  if [ "$pipeline" = "full" ]; then
    risk_score=$((risk_score + 10))
    risk_factors="${risk_factors}full-pipeline,"
  fi

  # Config-based risk factors (read from project config if available)
  # Reads lines like:   - pattern: "auth|login|session"
  #                       score: 30
  #                       label: "Auth/Security code"
  # This is a simplified parser — for complex configs, use yq
  if [ -f "$config_file" ]; then
    local in_risk_factors=false
    local current_pattern="" current_score="" current_label=""
    while IFS= read -r line; do
      if echo "$line" | grep -q "^risk_factors:"; then
        in_risk_factors=true
        continue
      fi
      if [ "$in_risk_factors" = "true" ]; then
        # Stop at next top-level key
        if echo "$line" | grep -qE '^[a-z]' && ! echo "$line" | grep -qE '^\s'; then
          in_risk_factors=false
          continue
        fi
        if echo "$line" | grep -q 'pattern:'; then
          current_pattern=$(echo "$line" | sed 's/.*pattern:[[:space:]]*//' | sed 's/^"//' | sed 's/"$//')
        fi
        if echo "$line" | grep -q 'score:'; then
          current_score=$(echo "$line" | sed 's/.*score:[[:space:]]*//')
        fi
        if echo "$line" | grep -q 'label:'; then
          current_label=$(echo "$line" | sed 's/.*label:[[:space:]]*//' | sed 's/^"//' | sed 's/"$//')
          # Apply the pattern check against labels + layer
          if [ -n "$current_pattern" ] && [ -n "$current_score" ]; then
            if echo "$issue_labels $layer" | grep -qiE "$current_pattern" 2>/dev/null; then
              risk_score=$((risk_score + current_score))
              risk_factors="${risk_factors}${current_label:-custom},"
            fi
          fi
          current_pattern="" current_score="" current_label=""
        fi
      fi
    done < "$config_file"
  fi

  echo "${risk_score}|${risk_factors}"
}

# --- Governance Tier Determination ---

# Determine governance tier from implementation results
# Usage: determine_tier <impl_success> <files_int> <holdout_pass> <sat_int> <risk_score>
# Output: TIER|DECISION (e.g. "T0|auto-ship")
determine_tier() {
  local impl_success="$1" files_int="$2" holdout_pass="$3" sat_int="$4" risk_score="$5"

  # Thresholds from config (DF_TIER_* set by config.sh, defaults match original values)
  local t0_max_risk="${DF_TIER_T0_MAX_RISK:-15}"
  local t0_min_sat="${DF_TIER_T0_MIN_SAT:-80}"
  local t1_max_risk="${DF_TIER_T1_MAX_RISK:-40}"
  local t1_min_sat="${DF_TIER_T1_MIN_SAT:-75}"
  local t2_max_risk="${DF_TIER_T2_MAX_RISK:-60}"
  local t2_min_sat="${DF_TIER_T2_MIN_SAT:-70}"
  local blocked_min_sat="${DF_TIER_BLOCKED_MIN_SAT:-50}"

  # No-op detection
  if [ "$impl_success" = "true" ] && [ "$files_int" -eq 0 ]; then
    echo "NOOP|no-op"
    return
  fi

  # Blocked conditions
  if [ "$impl_success" = "false" ]; then
    echo "T4|blocked"
    return
  fi
  if [ "$holdout_pass" = "false" ]; then
    echo "T4|blocked"
    return
  fi
  if [ "$sat_int" -lt "$blocked_min_sat" ] && [ "$sat_int" -ne 0 ]; then
    echo "T4|blocked"
    return
  fi

  # Risk-based tiers
  if [ "$risk_score" -gt "$t2_max_risk" ]; then
    echo "T3|gated"
    return
  fi
  if [ "$risk_score" -gt "$t1_max_risk" ]; then
    echo "T2|review-pr"
    return
  fi

  # Satisfaction-based tiers
  if [ "$sat_int" -ge "$t0_min_sat" ] && [ "$risk_score" -lt "$t0_max_risk" ]; then
    echo "T0|auto-ship"
    return
  fi
  if [ "$sat_int" -ge "$t1_min_sat" ] && [ "$risk_score" -lt "$t1_max_risk" ]; then
    echo "T1|auto-pr"
    return
  fi
  if [ "$sat_int" -ge "$t2_min_sat" ]; then
    echo "T2|review-pr"
    return
  fi

  # Default: gated
  echo "T3|gated"
}

# --- Layer Helpers ---

# Map layer name to holdout directory name
# Uses DF_LAYER_MAPPING from config (comma-separated key=value pairs)
# Example: DF_LAYER_MAPPING="backend=api,shared=mobile,ios=mobile"
# If no mapping found, returns the layer name as-is (identity mapping)
map_holdout_layer() {
  local layer="$1"
  local mapping="${DF_LAYER_MAPPING:-}"

  if [ -n "$mapping" ]; then
    local mapped
    mapped=$(echo ",$mapping," | grep -oE ",${layer}=[^,]+" | head -1 | cut -d= -f2 || true)
    if [ -n "$mapped" ]; then
      echo "$mapped"
      return
    fi
  fi

  echo "$layer"
}

# Extract layer from issue labels or spec filename
# Usage: extract_layer <issue_labels> [spec_file]
extract_layer() {
  local labels="$1"
  local spec_file="${2:-}"

  local layer=""
  layer=$(echo "$labels" | tr ',' '\n' | grep '^layer:' | head -1 | cut -d: -f2 || true)

  if [ -z "$layer" ] && [ -n "$spec_file" ]; then
    # Extract layer from directory path: docs/specs/{layer}/M-xxx.intent.md → layer
    layer=$(echo "$spec_file" | sed -n 's|.*/specs/\([^/]*\)/.*|\1|p')
    # Fallback: try basename prefix (for flat paths like backend-auth.intent.md)
    if [ -z "$layer" ]; then
      layer=$(basename "$spec_file" | sed 's/-.*//')
    fi
  fi

  echo "${layer:-backend}"
}
