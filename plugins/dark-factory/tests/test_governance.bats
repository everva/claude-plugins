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

@test "map_holdout_layer: backend maps to api" {
  local result
  result=$(map_holdout_layer "backend")
  [ "$result" = "api" ]
}

@test "map_holdout_layer: frontend passes through" {
  local result
  result=$(map_holdout_layer "frontend")
  [ "$result" = "frontend" ]
}

@test "map_holdout_layer: unknown passes through" {
  local result
  result=$(map_holdout_layer "infra")
  [ "$result" = "infra" ]
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
