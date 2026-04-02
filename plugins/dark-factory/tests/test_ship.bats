#!/usr/bin/env bats
# Tests for Dark Factory ship strategies (lib/ship.sh)

PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  export DF_SESSION_DIR="$(mktemp -d)"
  export DF_SESSION_ID="test-session-20260402"
  touch "$DF_SESSION_DIR/run.log"

  # Create a mock gh script that records calls
  export MOCK_GH_LOG="$DF_SESSION_DIR/gh_calls.log"
  export MOCK_GH_DIR="$(mktemp -d)"
  cat > "$MOCK_GH_DIR/gh" <<'MOCK'
#!/bin/bash
echo "$@" >> "${MOCK_GH_LOG}"
MOCK
  chmod +x "$MOCK_GH_DIR/gh"

  # Put mock gh first in PATH
  export ORIGINAL_PATH="$PATH"
  export PATH="$MOCK_GH_DIR:$PATH"

  source "$PLUGIN_ROOT/lib/ship.sh"
}

teardown() {
  export PATH="$ORIGINAL_PATH"
  rm -rf "$DF_SESSION_DIR" "$MOCK_GH_DIR"
}

# --- build_governance_body ---

@test "build_governance_body returns markdown with all parameters" {
  local body
  body=$(build_governance_body "sess-001" "42" "L1" "T0" "auto-ship" "95" "88" "true" "12" "85" "3")

  [[ "$body" == *"## Dark Factory Governance"* ]]
  [[ "$body" == *"| Session | sess-001 |"* ]]
  [[ "$body" == *"| Issue | #42 |"* ]]
  [[ "$body" == *"| Tier | T0 (auto-ship) |"* ]]
  [[ "$body" == *"| Satisfaction | 95 |"* ]]
  [[ "$body" == *"| Holdout | 88 (pass=true) |"* ]]
  [[ "$body" == *"| Risk Score | 12 |"* ]]
  [[ "$body" == *"| Coverage | 85% |"* ]]
  [[ "$body" == *"| Files Changed | 3 |"* ]]
}

@test "build_governance_body includes markdown table header" {
  local body
  body=$(build_governance_body "s1" "1" "L0" "T1" "auto-pr" "80" "90" "true" "5" "70" "1")

  [[ "$body" == *"| Metric | Value |"* ]]
  [[ "$body" == *"|--------|-------|"* ]]
}

@test "build_governance_body includes holdout footer" {
  local body
  body=$(build_governance_body "s1" "1" "L0" "T1" "auto-pr" "80" "90" "true" "5" "70" "1")

  [[ "$body" == *"Holdout validation + satisfaction testing = quality gate."* ]]
}

# --- ship_log ---

@test "ship_log appends formatted message to run.log" {
  ship_log "test message here"

  local content
  content=$(cat "$DF_SESSION_DIR/run.log")
  [[ "$content" == *"[test-session-20260402]"* ]]
  [[ "$content" == *"[ship]"* ]]
  [[ "$content" == *"test message here"* ]]
}

@test "ship_log appends multiple messages" {
  ship_log "first"
  ship_log "second"

  local count
  count=$(wc -l < "$DF_SESSION_DIR/run.log")
  [ "$count" -eq 2 ]
}

# --- gh_optional ---

@test "gh_optional does not error when gh is not in PATH" {
  export PATH="/usr/bin:/bin"
  run gh_optional pr view "https://example.com"
  [ "$status" -eq 0 ]
}

@test "gh_optional logs skip message when gh is unavailable" {
  export PATH="/usr/bin:/bin"
  gh_optional pr view "https://example.com"

  local content
  content=$(cat "$DF_SESSION_DIR/run.log")
  [[ "$content" == *"SKIP: gh not available"* ]]
}

@test "gh_optional calls gh when available" {
  gh_optional issue list -R "owner/repo"

  local calls
  calls=$(cat "$MOCK_GH_LOG")
  [[ "$calls" == *"issue list -R owner/repo"* ]]
}

# --- ship_blocked ---

@test "ship_blocked logs BLOCKED to run.log" {
  ship_blocked "" "10" "owner/repo" "false" "30" "false"

  local content
  content=$(cat "$DF_SESSION_DIR/run.log")
  [[ "$content" == *"BLOCKED"* ]]
}

@test "ship_blocked closes PR when pr_url is provided" {
  ship_blocked "https://github.com/owner/repo/pull/5" "10" "owner/repo" "false" "30" "false"

  local calls
  calls=$(cat "$MOCK_GH_LOG")
  [[ "$calls" == *"pr close https://github.com/owner/repo/pull/5"* ]]
}

@test "ship_blocked labels issue as status:blocked" {
  ship_blocked "" "10" "owner/repo" "false" "30" "false"

  local calls
  calls=$(cat "$MOCK_GH_LOG")
  [[ "$calls" == *"issue edit 10"* ]]
  [[ "$calls" == *"--add-label status:blocked"* ]]
}

# --- ship_noop ---

@test "ship_noop logs NO-OP to run.log" {
  ship_noop "10" "owner/repo"

  local content
  content=$(cat "$DF_SESSION_DIR/run.log")
  [[ "$content" == *"NO-OP"* ]]
}

@test "ship_noop labels issue as status:merged" {
  ship_noop "10" "owner/repo"

  local calls
  calls=$(cat "$MOCK_GH_LOG")
  [[ "$calls" == *"issue edit 10"* ]]
  [[ "$calls" == *"--add-label status:merged"* ]]
}

# --- ship_review ---

@test "ship_review logs DEFERRED to run.log" {
  ship_review "https://github.com/o/r/pull/1" "10" "owner/repo" "review-pr" "governance body"

  local content
  content=$(cat "$DF_SESSION_DIR/run.log")
  [[ "$content" == *"DEFERRED"* ]]
}

@test "ship_review labels PR with needs-review" {
  ship_review "https://github.com/o/r/pull/1" "10" "owner/repo" "review-pr" "body"

  local calls
  calls=$(cat "$MOCK_GH_LOG")
  [[ "$calls" == *"pr edit https://github.com/o/r/pull/1 --add-label needs-review,dark-factory"* ]]
}

@test "ship_review adds architecture-review label for gated decision" {
  ship_review "https://github.com/o/r/pull/1" "10" "owner/repo" "gated" "body"

  local calls
  calls=$(cat "$MOCK_GH_LOG")
  [[ "$calls" == *"needs-review,architecture-review,dark-factory"* ]]
}

@test "ship_review comments governance body on PR" {
  ship_review "https://github.com/o/r/pull/1" "10" "owner/repo" "review-pr" "my governance body"

  local calls
  calls=$(cat "$MOCK_GH_LOG")
  [[ "$calls" == *"pr comment https://github.com/o/r/pull/1 --body my governance body"* ]]
}

@test "ship_review labels issue as status:review" {
  ship_review "https://github.com/o/r/pull/1" "10" "owner/repo" "review-pr" "body"

  local calls
  calls=$(cat "$MOCK_GH_LOG")
  [[ "$calls" == *"issue edit 10"* ]]
  [[ "$calls" == *"--add-label status:review"* ]]
}

# --- ship_auto ---

@test "ship_auto logs AUTO-SHIP to run.log" {
  ship_auto "https://github.com/o/r/pull/1" "10" "owner/repo" "auto-ship" "body" "95" "88"

  local content
  content=$(cat "$DF_SESSION_DIR/run.log")
  [[ "$content" == *"AUTO-SHIP"* ]]
}

@test "ship_auto includes satisfaction and holdout in log" {
  ship_auto "https://github.com/o/r/pull/1" "10" "owner/repo" "auto-pr" "body" "92" "85"

  local content
  content=$(cat "$DF_SESSION_DIR/run.log")
  [[ "$content" == *"satisfaction=92"* ]]
  [[ "$content" == *"holdout=85"* ]]
}

@test "ship_auto labels PR with agent:pipeline and dark-factory" {
  ship_auto "https://github.com/o/r/pull/1" "10" "owner/repo" "auto-pr" "body" "90" "80"

  local calls
  calls=$(cat "$MOCK_GH_LOG")
  [[ "$calls" == *"pr edit https://github.com/o/r/pull/1 --add-label agent:pipeline,dark-factory"* ]]
}

@test "ship_auto enables squash merge" {
  ship_auto "https://github.com/o/r/pull/1" "10" "owner/repo" "auto-ship" "body" "95" "90"

  local calls
  calls=$(cat "$MOCK_GH_LOG")
  [[ "$calls" == *"pr merge https://github.com/o/r/pull/1 --squash --auto"* ]]
}

@test "ship_auto labels issue status:merged for auto-ship" {
  ship_auto "https://github.com/o/r/pull/1" "10" "owner/repo" "auto-ship" "body" "95" "90"

  local calls
  calls=$(cat "$MOCK_GH_LOG")
  [[ "$calls" == *"--add-label status:merged"* ]]
}

@test "ship_auto labels issue status:review for auto-pr" {
  ship_auto "https://github.com/o/r/pull/1" "10" "owner/repo" "auto-pr" "body" "90" "80"

  local calls
  calls=$(cat "$MOCK_GH_LOG")
  [[ "$calls" == *"--add-label status:review"* ]]
}
