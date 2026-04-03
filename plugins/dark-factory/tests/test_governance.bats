#!/usr/bin/env bats
# Tests for Dark Factory governance library (lib/governance.sh)

PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  export TMPDIR_TEST="$(mktemp -d)"
  source "$PLUGIN_ROOT/lib/governance.sh"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

# ============================================================
# safe_int
# ============================================================

@test "safe_int: integer string returns integer" {
  local result
  result=$(safe_int "42")
  [ "$result" = "42" ]
}

@test "safe_int: decimal is truncated" {
  local result
  result=$(safe_int "3.7")
  [ "$result" = "3" ]
}

@test "safe_int: empty string returns 0" {
  local result
  result=$(safe_int "")
  [ "$result" = "0" ]
}

@test "safe_int: non-numeric string returns 0" {
  local result
  result=$(safe_int "abc")
  [ "$result" = "0" ]
}

@test "safe_int: negative integer preserved" {
  local result
  result=$(safe_int "-5")
  [ "$result" = "-5" ]
}

# ============================================================
# determine_tier
# ============================================================

@test "determine_tier: impl_success=false yields T4|blocked" {
  local result
  result=$(determine_tier "false" 5 "true" 80 10)
  [ "$result" = "T4|blocked" ]
}

@test "determine_tier: holdout_pass=false yields T4|blocked" {
  local result
  result=$(determine_tier "true" 5 "false" 80 10)
  [ "$result" = "T4|blocked" ]
}

@test "determine_tier: sat_int < 50 (nonzero) yields T4|blocked" {
  local result
  result=$(determine_tier "true" 5 "true" 30 10)
  [ "$result" = "T4|blocked" ]
}

@test "determine_tier: sat_int=0 does NOT block (not scored)" {
  local result
  result=$(determine_tier "true" 5 "true" 0 10)
  # sat_int=0, risk_score=10 => falls through to default T3|gated
  [ "$result" != "T4|blocked" ]
}

@test "determine_tier: impl_success=true files_int=0 yields NOOP|no-op" {
  local result
  result=$(determine_tier "true" 0 "true" 80 10)
  [ "$result" = "NOOP|no-op" ]
}

@test "determine_tier: risk_score > 60 yields T3|gated" {
  local result
  result=$(determine_tier "true" 5 "true" 80 65)
  [ "$result" = "T3|gated" ]
}

@test "determine_tier: risk_score 41-60 yields T2|review-pr" {
  local result
  result=$(determine_tier "true" 5 "true" 80 50)
  [ "$result" = "T2|review-pr" ]
}

@test "determine_tier: sat>=80 risk<15 yields T0|auto-ship" {
  local result
  result=$(determine_tier "true" 5 "true" 85 10)
  [ "$result" = "T0|auto-ship" ]
}

@test "determine_tier: sat>=75 risk<40 yields T1|auto-pr" {
  local result
  result=$(determine_tier "true" 5 "true" 76 20)
  [ "$result" = "T1|auto-pr" ]
}

@test "determine_tier: sat>=70 risk 15-40 yields T2|review-pr" {
  local result
  result=$(determine_tier "true" 5 "true" 72 20)
  [ "$result" = "T2|review-pr" ]
}

@test "determine_tier: low sat low risk yields T3|gated (default)" {
  local result
  result=$(determine_tier "true" 5 "true" 50 10)
  [ "$result" = "T3|gated" ]
}

@test "determine_tier: sat=49 (nonzero, below 50) yields T4|blocked" {
  local result
  result=$(determine_tier "true" 5 "true" 49 10)
  [ "$result" = "T4|blocked" ]
}

# ============================================================
# determine_tier: config-driven thresholds
# ============================================================

@test "determine_tier: custom T0 thresholds widen auto-ship window" {
  export DF_TIER_T0_MAX_RISK=25
  export DF_TIER_T0_MIN_SAT=70
  local result
  result=$(determine_tier "true" 5 "true" 75 20)
  [ "$result" = "T0|auto-ship" ]
  unset DF_TIER_T0_MAX_RISK DF_TIER_T0_MIN_SAT
}

@test "determine_tier: custom blocked threshold raises floor" {
  export DF_TIER_BLOCKED_MIN_SAT=60
  local result
  result=$(determine_tier "true" 5 "true" 55 10)
  [ "$result" = "T4|blocked" ]
  unset DF_TIER_BLOCKED_MIN_SAT
}

@test "determine_tier: custom T2 risk threshold changes gating boundary" {
  export DF_TIER_T2_MAX_RISK=80
  export DF_TIER_T1_MAX_RISK=50
  local result
  # risk=65 is now T2 (not T3) because T2 boundary raised to 80
  result=$(determine_tier "true" 5 "true" 80 65)
  [ "$result" = "T2|review-pr" ]
  unset DF_TIER_T2_MAX_RISK DF_TIER_T1_MAX_RISK
}

@test "determine_tier: defaults match original hardcoded values" {
  # Ensure no DF_TIER_* vars are set
  unset DF_TIER_T0_MAX_RISK DF_TIER_T0_MIN_SAT DF_TIER_T1_MAX_RISK DF_TIER_T1_MIN_SAT DF_TIER_T2_MAX_RISK DF_TIER_T2_MIN_SAT DF_TIER_BLOCKED_MIN_SAT 2>/dev/null || true
  local result
  # T0: risk<15 AND sat>=80
  result=$(determine_tier "true" 5 "true" 85 10)
  [ "$result" = "T0|auto-ship" ]
  # T1: risk<40 AND sat>=75
  result=$(determine_tier "true" 5 "true" 78 25)
  [ "$result" = "T1|auto-pr" ]
  # T2: sat>=70
  result=$(determine_tier "true" 5 "true" 72 20)
  [ "$result" = "T2|review-pr" ]
}

# ============================================================
# compute_risk_score
# ============================================================

@test "compute_risk_score: simple case scores 0" {
  local result
  result=$(compute_risk_score "priority:high" "backend" 3 "lite" "/nonexistent")
  local score="${result%%|*}"
  [ "$score" = "0" ]
}

@test "compute_risk_score: cross-layer labels add 15" {
  local result
  result=$(compute_risk_score "layer:frontend,layer:backend" "backend" 3 "lite" "/nonexistent")
  local score="${result%%|*}"
  [ "$score" = "15" ]
}

@test "compute_risk_score: explicit cross-layer label adds 15" {
  local result
  result=$(compute_risk_score "layer:cross-layer" "backend" 3 "lite" "/nonexistent")
  local score="${result%%|*}"
  [ "$score" = "15" ]
}

@test "compute_risk_score: >15 files adds 10" {
  local result
  result=$(compute_risk_score "priority:high" "backend" 20 "lite" "/nonexistent")
  local score="${result%%|*}"
  [ "$score" = "10" ]
}

@test "compute_risk_score: full pipeline adds 10" {
  local result
  result=$(compute_risk_score "priority:high" "backend" 3 "full" "/nonexistent")
  local score="${result%%|*}"
  [ "$score" = "10" ]
}

@test "compute_risk_score: combined factors accumulate" {
  local result
  result=$(compute_risk_score "layer:frontend,layer:backend" "backend" 20 "full" "/nonexistent")
  local score="${result%%|*}"
  # cross-layer(15) + large-change(10) + full-pipeline(10) = 35
  [ "$score" = "35" ]
}

@test "compute_risk_score: factors string contains cross-layer" {
  local result
  result=$(compute_risk_score "layer:frontend,layer:backend" "backend" 3 "lite" "/nonexistent")
  local factors="${result#*|}"
  [[ "$factors" == *"cross-layer"* ]]
}

@test "compute_risk_score: factors string contains large-change" {
  local result
  result=$(compute_risk_score "priority:high" "backend" 20 "lite" "/nonexistent")
  local factors="${result#*|}"
  [[ "$factors" == *"large-change"* ]]
}

@test "compute_risk_score: factors string contains full-pipeline" {
  local result
  result=$(compute_risk_score "priority:high" "backend" 3 "full" "/nonexistent")
  local factors="${result#*|}"
  [[ "$factors" == *"full-pipeline"* ]]
}

# ============================================================
# extract_layer
# ============================================================

@test "extract_layer: layer label present" {
  local result
  result=$(extract_layer "layer:frontend,priority:high")
  [ "$result" = "frontend" ]
}

@test "extract_layer: no layer label, spec file present" {
  local result
  result=$(extract_layer "priority:high" "backend-auth.intent.md")
  [ "$result" = "backend" ]
}

@test "extract_layer: no label, no spec defaults to backend" {
  local result
  result=$(extract_layer "priority:high")
  [ "$result" = "backend" ]
}

@test "extract_layer: empty labels, empty spec defaults to backend" {
  local result
  result=$(extract_layer "" "")
  [ "$result" = "backend" ]
}

# ============================================================
# map_holdout_layer
# ============================================================

@test "map_holdout_layer: no mapping config — identity passthrough" {
  unset DF_LAYER_MAPPING 2>/dev/null || true
  local result
  result=$(map_holdout_layer "backend")
  [ "$result" = "backend" ]
}

@test "map_holdout_layer: no mapping config — any layer passes through" {
  unset DF_LAYER_MAPPING 2>/dev/null || true
  local result
  result=$(map_holdout_layer "frontend")
  [ "$result" = "frontend" ]
}

@test "map_holdout_layer: config mapping — backend=api" {
  export DF_LAYER_MAPPING="backend=api"
  local result
  result=$(map_holdout_layer "backend")
  [ "$result" = "api" ]
  unset DF_LAYER_MAPPING
}

@test "map_holdout_layer: config mapping — multiple mappings" {
  export DF_LAYER_MAPPING="backend=api,shared=mobile,ios=mobile,android=mobile"
  [ "$(map_holdout_layer "backend")" = "api" ]
  [ "$(map_holdout_layer "shared")" = "mobile" ]
  [ "$(map_holdout_layer "ios")" = "mobile" ]
  [ "$(map_holdout_layer "android")" = "mobile" ]
  unset DF_LAYER_MAPPING
}

@test "map_holdout_layer: config mapping — unmapped layer passes through" {
  export DF_LAYER_MAPPING="backend=api,shared=mobile"
  local result
  result=$(map_holdout_layer "frontend")
  [ "$result" = "frontend" ]
  unset DF_LAYER_MAPPING
}

@test "map_holdout_layer: empty mapping string — identity" {
  export DF_LAYER_MAPPING=""
  local result
  result=$(map_holdout_layer "infra")
  [ "$result" = "infra" ]
  unset DF_LAYER_MAPPING
}

# ============================================================
# parse_impl_result
# ============================================================

@test "parse_impl_result: reads agent-result.json from session dir" {
  local session="$TMPDIR_TEST/session1"
  mkdir -p "$session"
  echo '{"success": true, "files_changed": 3}' > "$session/agent-result.json"
  echo "some output" > "$TMPDIR_TEST/output.txt"

  local result
  result=$(parse_impl_result "$TMPDIR_TEST/output.txt" "$session")
  local success
  success=$(echo "$result" | jq -r '.success')
  [ "$success" = "true" ]
}

@test "parse_impl_result: extracts DARK_FACTORY_RESULT marker" {
  local outfile="$TMPDIR_TEST/output.txt"
  echo 'Some log output' > "$outfile"
  echo 'DARK_FACTORY_RESULT:{"success": true, "files_changed": 2}' >> "$outfile"
  echo 'More output' >> "$outfile"

  local result
  result=$(parse_impl_result "$outfile")
  local success
  success=$(echo "$result" | jq -r '.success')
  [ "$success" = "true" ]
  local files
  files=$(echo "$result" | jq -r '.files_changed')
  [ "$files" = "2" ]
}

@test "parse_impl_result: finds embedded JSON with success field" {
  local outfile="$TMPDIR_TEST/output.txt"
  echo 'Blah blah {"success": true, "files_changed": 1} end' > "$outfile"

  local result
  result=$(parse_impl_result "$outfile")
  local success
  success=$(echo "$result" | jq -r '.success')
  [ "$success" = "true" ]
}

@test "parse_impl_result: missing file returns {} and exit 1" {
  run parse_impl_result "$TMPDIR_TEST/nonexistent.txt"
  [ "$status" -eq 1 ]
  [ "$output" = "{}" ]
}

@test "parse_impl_result: agent-result.json takes priority over marker" {
  local session="$TMPDIR_TEST/session2"
  mkdir -p "$session"
  echo '{"success": true, "files_changed": 10}' > "$session/agent-result.json"
  local outfile="$TMPDIR_TEST/output2.txt"
  echo 'DARK_FACTORY_RESULT:{"success": false, "files_changed": 0}' > "$outfile"

  local result
  result=$(parse_impl_result "$outfile" "$session")
  local files
  files=$(echo "$result" | jq -r '.files_changed')
  [ "$files" = "10" ]
}

# ============================================================
# parse_json_field
# ============================================================

@test "parse_json_field: direct field returns value" {
  local jsonfile="$TMPDIR_TEST/data.json"
  echo '{"name": "test", "count": 42}' > "$jsonfile"

  local result
  result=$(parse_json_field "$jsonfile" "name" "default")
  [ "$result" = "test" ]
}

@test "parse_json_field: numeric field returns value" {
  local jsonfile="$TMPDIR_TEST/data.json"
  echo '{"name": "test", "count": 42}' > "$jsonfile"

  local result
  result=$(parse_json_field "$jsonfile" "count" "0")
  [ "$result" = "42" ]
}

@test "parse_json_field: missing field returns default" {
  local jsonfile="$TMPDIR_TEST/data.json"
  echo '{"name": "test"}' > "$jsonfile"

  local result
  result=$(parse_json_field "$jsonfile" "missing_field" "fallback")
  [ "$result" = "fallback" ]
}

@test "parse_json_field: missing file returns default" {
  local result
  result=$(parse_json_field "$TMPDIR_TEST/nope.json" "field" "safe_default")
  [ "$result" = "safe_default" ]
}
