#!/bin/bash
# Dark Factory Plugin — Ship Strategies
# Functions for different shipping models: direct-commit, pr-creation, pr-label
# Sourced by run-task.sh

# --- Helper ---

ship_log() {
  local session_dir="${DF_SESSION_DIR:-/tmp}"
  echo "[${DF_SESSION_ID:-unknown}] [ship] $1" >> "$session_dir/run.log"
}

# GitHub CLI helper — runs gh commands only if gh is available
gh_optional() {
  if command -v gh &>/dev/null; then
    gh "$@" 2>>"${DF_SESSION_DIR:-/tmp}/run.log" || true
  else
    ship_log "SKIP: gh not available — $1 $2 (standalone mode)"
  fi
}

# Build governance PR comment body
build_governance_body() {
  local session_id="$1" issue_number="$2" layer="$3" tier="$4" decision="$5"
  local sat_int="$6" holdout_int="$7" holdout_pass="$8" risk_score="$9"
  local coverage="${10}" files_int="${11}"

  cat <<EOF
## Dark Factory Governance

| Metric | Value |
|--------|-------|
| Session | $session_id |
| Issue | #$issue_number |
| Layer | $layer |
| Tier | $tier ($decision) |
| Satisfaction | $sat_int |
| Holdout | $holdout_int (pass=$holdout_pass) |
| Risk Score | $risk_score |
| Coverage | ${coverage}% |
| Files Changed | $files_int |

> Holdout validation + satisfaction testing = quality gate.
EOF
}

# --- Ship: Blocked ---
ship_blocked() {
  local pr_url="$1" issue_number="$2" github_repo="$3"
  local holdout_pass="$4" sat_int="$5" impl_success="$6"

  ship_log "BLOCKED — closing PR if exists, marking issue"
  if [ -n "$pr_url" ]; then
    gh_optional pr close "$pr_url" --comment "[Dark Factory] Blocked by governance (holdout=$holdout_pass, satisfaction=$sat_int, impl=$impl_success)"
    ship_log "Closed PR: $pr_url"
  fi
  if [ -n "$issue_number" ] && [ -n "$github_repo" ]; then
    gh_optional issue edit "$issue_number" -R "$github_repo" --remove-label "status:ready,status:in-progress" --add-label "status:blocked"
    ship_log "Issue #$issue_number marked status:blocked"
  fi
}

# --- Ship: No-Op ---
ship_noop() {
  local issue_number="$1" github_repo="$2"

  ship_log "NO-OP — skipping ship (0 files changed)"
  if [ -n "$issue_number" ] && [ -n "$github_repo" ]; then
    gh_optional issue edit "$issue_number" -R "$github_repo" --remove-label "status:ready,status:in-progress" --add-label "status:merged"
    ship_log "Issue #$issue_number marked status:merged (no-op)"
  fi
}

# --- Ship: Review/Gated ---
ship_review() {
  local pr_url="$1" issue_number="$2" github_repo="$3"
  local decision="$4" governance_body="$5"

  local label="needs-review"
  [ "$decision" = "gated" ] && label="needs-review,architecture-review"

  ship_log "DEFERRED decision=$decision — PR labeled for human review"
  if [ -n "$pr_url" ]; then
    gh_optional pr edit "$pr_url" --add-label "$label,dark-factory"
    gh_optional pr edit "$pr_url" --remove-label "agent:pipeline"
    gh_optional pr comment "$pr_url" --body "$governance_body"
    ship_log "Labeled PR for review: $pr_url (labels: $label)"
  else
    ship_log "No PR found for deferred task"
  fi
  if [ -n "$issue_number" ] && [ -n "$github_repo" ]; then
    gh_optional issue edit "$issue_number" -R "$github_repo" --remove-label "status:ready,status:in-progress" --add-label "status:review"
  fi
}

# --- Ship: Auto-Ship/Auto-PR ---
ship_auto() {
  local pr_url="$1" issue_number="$2" github_repo="$3"
  local decision="$4" governance_body="$5" sat_int="$6" holdout_int="$7"

  ship_log "AUTO-SHIP decision=$decision satisfaction=$sat_int holdout=$holdout_int"

  local merged=false
  if [ -n "$pr_url" ]; then
    gh_optional pr edit "$pr_url" --add-label "agent:pipeline,dark-factory"
    gh_optional pr comment "$pr_url" --body "$governance_body"

    if [ "$decision" = "auto-ship" ]; then
      ship_log "T0: Attempting immediate squash merge..."
      gh_optional pr merge "$pr_url" --squash --auto
      sleep 3
      local t0_state="UNKNOWN"
      if command -v gh &>/dev/null; then
        t0_state=$(gh pr view "$pr_url" --json state -q '.state' 2>/dev/null || echo "UNKNOWN")
      fi
      if [ "$t0_state" = "MERGED" ]; then
        ship_log "T0: PR merged successfully"
        merged=true
      else
        ship_log "T0: PR not yet merged (state=$t0_state) — CI will handle"
      fi
    else
      ship_log "T1: Enabling auto-merge — GitHub will merge after CI passes"
      gh_optional pr merge "$pr_url" --squash --auto
      # No polling — gh pr merge --auto enables GitHub's auto-merge feature.
      # GitHub will merge the PR automatically once CI passes.
    fi
  fi

  if [ -n "$issue_number" ] && [ -n "$github_repo" ]; then
    if [ "$decision" = "auto-ship" ] || [ "$merged" = "true" ]; then
      gh_optional issue edit "$issue_number" -R "$github_repo" --remove-label "status:ready,status:in-progress" --add-label "status:merged"
    else
      gh_optional issue edit "$issue_number" -R "$github_repo" --remove-label "status:ready,status:in-progress" --add-label "status:review"
    fi
  fi
}
