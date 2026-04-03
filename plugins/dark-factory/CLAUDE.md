# Dark Factory Plugin

This plugin provides the **Dark Factory** autonomous AI development pipeline.

## What It Provides

- **Agents**: holdout-validator, satisfaction-judge, readiness-auditor, pipeline-doctor, regression-runner, task-analyzer
- **Skills**: `/dark-factory:factory`, `/dark-factory:task`, `/dark-factory:readiness`, `/dark-factory:satisfaction`, `/dark-factory:dashboard`, `/dark-factory:validate`, `/dark-factory:init`
- **Hooks**: holdout-guard (PreToolUse) — blocks implementation agents from reading holdout scenarios
- **Scripts**: ralph.sh, ralph-monitor.sh, run-task.sh, validate-session.sh, alert.sh, dashboard.sh, sync-backlog.sh, record-failure.sh, import-prd.sh
- **Libs**: config.sh, governance.sh, ship.sh, circuit_breaker.sh, rate_limiter.sh

## Project Configuration

Each project must have a `.dark-factory/config.yaml` file. Run `/dark-factory:init` to set up.

## Governance Tiers

| Tier | Action | Condition |
|------|--------|-----------|
| T0 | Auto-merge | Risk < 15, Satisfaction >= 80, Holdout pass |
| T1 | Auto-PR (CI gate) | Risk 15-40, Satisfaction >= 75, Holdout pass |
| T2 | PR + 1 review | Risk 40-60, Satisfaction >= 70 |
| T3 | PR + 2 reviews | Risk > 60 |
| T4 | Blocked | Holdout fail, Satisfaction < 50, or impl fail |

## Quality Gates

- **Multi-run holdout**: Runs holdout validation N times (default: 3), requires quorum passes (default: 2/3) with score >= threshold (default: 90)
- **Per-spec retry tracking**: Failed tasks retry up to `max_attempts_per_spec` (default: 3) before being marked `exhausted`
- **Automatic guardrails**: Failures are recorded to `failure-patterns.md`; subsequent implementation agents read these to avoid repeating mistakes

## Loop Resilience

- **Circuit breaker**: Detects stuck loops (repeated errors or no progress). States: CLOSED → OPEN → HALF_OPEN → CLOSED. Configurable thresholds and cooldown via `config.yaml`
- **Rate limiter**: Enforces hourly call and token limits. Automatically waits for hour reset when limit is hit. State persisted in `.rate-limiter.json`
- **Dual-condition exit**: Backlog must report "empty" multiple times (default: 2) before stopping — prevents premature exit from transient parse failures

### Config Options (config.yaml)

```yaml
rate_limit_calls_per_hour: 60     # Max claude invocations per hour (0 = unlimited)
rate_limit_tokens_per_hour: 0     # Max tokens per hour (0 = disabled)
cb_no_progress_threshold: 5       # Trip circuit after N iterations with unknown results
cb_same_error_threshold: 3        # Trip circuit after N identical errors
cb_cooldown_minutes: 30           # Wait time before HALF_OPEN probe
exit_empty_backlog_confirmations: 2  # Confirm empty backlog N times before stopping
```
# test
