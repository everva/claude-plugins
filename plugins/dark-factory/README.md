# Dark Factory Plugin

Autonomous AI development pipeline for [Claude Code](https://claude.ai/code). Ships code autonomously with governance tiers, holdout validation, and satisfaction testing.

## Installation

### Prerequisites

- [Claude Code](https://claude.ai/code) CLI, VS Code extension, or JetBrains extension
- `jq` installed (`brew install jq` on macOS)
- `gh` CLI installed and authenticated (optional, for GitHub integration)

### Install the Plugin

```bash
# Step 1: Add the Everva marketplace (one-time)
/plugin marketplace add everva/claude-plugins

# Step 2: Install the dark-factory plugin
/plugin install dark-factory@everva

# Step 3: Reload plugins
/reload-plugins
```

### Verify Installation

After installing, these skills should be available:

```bash
/dark-factory:factory status    # Should show the dashboard
/dark-factory:init              # Initialize in your project
```

## Setup in Your Project

### Step 1: Initialize

Run inside your project directory:

```bash
/dark-factory:init MyProject owner/repo
```

This creates the `.dark-factory/` directory:

```text
.dark-factory/
  config.yaml          # Project-specific configuration
  backlog.md           # Task queue
  governance.md        # Governance tier rules
  failure-patterns.md  # Known failure patterns
  holdouts/            # Holdout scenario directory
    example.holdout.yaml
  sessions/            # Session artifacts (auto-created)
```

### Step 2: Configure Risk Factors

Edit `.dark-factory/config.yaml` to customize for your project:

```yaml
# Project identity
project_name: "MyProject"
github_repo: "owner/repo"

# Ship strategy
ship_model: "pr-creation"      # direct-commit | pr-creation | pr-label

# Backlog
backlog_format: "issue+spec"   # spec-only | issue+spec
governance_ceiling: "T1"       # Ralph loop only processes T0 and T1

# Risk factors — add patterns specific to your project
risk_factors:
  - pattern: "auth|login|session|jwt|token"
    score: 30
    label: "Auth/Security code"
  - pattern: "payment|stripe|billing"
    score: 30
    label: "Payment processing"
  - pattern: "migration|ALTER TABLE|CREATE TABLE"
    score: 20
    label: "Database migration"
  - pattern: "api-contract|shared-types"
    score: 20
    label: "API contract change"
  - pattern: "dependency|package.json|Podfile|build.gradle"
    score: 15
    label: "New dependency"
```

### Step 3: Write Holdout Scenarios

Holdout scenarios are agent-invisible behavioral tests. The implementation agent **never** sees them — only the holdout-validator reads them during validation. This prevents "teaching to the test."

Create YAML files in `.dark-factory/holdouts/<layer>/`:

```yaml
# .dark-factory/holdouts/api/auth-flow.holdout.yaml
name: auth-flow-validation
description: Verify authentication is properly enforced
priority: critical    # critical | high | medium

preconditions:
  - "Authentication middleware exists"

behaviors:
  - id: auth-required
    type: deterministic
    description: "Protected endpoints return 401 without valid token"
    assertion: "Route handlers check authentication before processing"

  - id: invalid-token-rejected
    type: unit-behavioral
    description: "Invalid tokens are rejected with proper error response"
    assertion: "Test exists that sends invalid token and asserts 401"

anti_patterns:
  - id: hardcoded-token
    description: "No hardcoded auth tokens in source code"
    grep_pattern: "Bearer [A-Za-z0-9._-]{20,}"
```

### Step 4: Check Readiness

```bash
/dark-factory:readiness
```

This scores your project across 8 axes:

| Axis | Weight | What It Checks |
| --- | --- | --- |
| Build Determinism | 15% | Build exits 0 without warnings |
| Test Coverage | 15% | Tests pass, coverage >= 80% |
| Lint Strictness | 10% | Lint passes with zero warnings |
| Type Safety | 10% | Type check passes, no `any` |
| Instruction Quality | 15% | CLAUDE.md, ADRs, agents, skills |
| Structure Clarity | 10% | Consistent naming, clear boundaries |
| CI/CD Maturity | 15% | CI with build+lint+test, PR trigger |
| Self-Heal History | 10% | Pipeline doctor, retry infrastructure |

**Score >= 75**: Eligible for Dark Factory autonomous execution.

## Usage

### Skills Reference

| Skill | Description | Example |
| --- | --- | --- |
| `/dark-factory:factory start [N] [H]` | Start Ralph Wiggum loop (N tasks, H hours) | `/dark-factory:factory start 10 8` |
| `/dark-factory:factory stop` | Gracefully stop the loop | `/dark-factory:factory stop` |
| `/dark-factory:factory status` | Show observability dashboard | `/dark-factory:factory status` |
| `/dark-factory:factory sync` | Sync GitHub Issues to backlog | `/dark-factory:factory sync` |
| `/dark-factory:factory run <spec>` | Run single task through pipeline | `/dark-factory:factory run docs/specs/my-feature.intent.md` |
| `/dark-factory:factory validate <id>` | Inspect a session | `/dark-factory:factory validate task-20260330-...` |
| `/dark-factory:factory backlog` | Show current backlog | `/dark-factory:factory backlog` |
| `/dark-factory:task <desc>` | Run task with analysis | `/dark-factory:task "Add user avatar upload"` |
| `/dark-factory:readiness` | Evaluate project readiness | `/dark-factory:readiness` |
| `/dark-factory:satisfaction <spec>` | Run quality evaluation | `/dark-factory:satisfaction docs/specs/feature.intent.md` |
| `/dark-factory:dashboard` | Show metrics | `/dark-factory:dashboard --json --days 30` |
| `/dark-factory:validate <id>` | Validate a session | `/dark-factory:validate task-20260330-...` |
| `/dark-factory:init [name] [repo]` | Initialize in project | `/dark-factory:init MyProject owner/repo` |

### Running a Single Task

```bash
# By intent spec file (recommended)
/dark-factory:factory run docs/specs/backend-notifications.intent.md

# By GitHub issue number
/dark-factory:factory run --issue 42

# Quick task from natural language
/dark-factory:task "Add email verification to the signup flow"
```

### Starting the Autonomous Loop

```bash
# Default: 5 tasks, 6 hours max
/dark-factory:factory start

# Custom: 10 tasks, 8 hours max
/dark-factory:factory start 10 8
```

The Ralph Wiggum loop:

1. Syncs GitHub Issues with `status:ready` label to backlog (if `gh` configured)
2. Picks the next pending task (respects governance ceiling)
3. Runs `run-task.sh` with fresh `claude -p` context (prevents drift)
4. Validates with holdout scenarios + satisfaction judge
5. Applies governance tier decision (auto-ship, PR, review, or block)
6. Updates backlog and GitHub Issue labels
7. Repeats until: max iterations, max duration, 3 consecutive failures, or `.stop-signal`

### Stopping the Loop

```bash
# Graceful stop (completes current task first)
/dark-factory:factory stop

# This creates .dark-factory/.stop-signal which the loop checks
```

### Viewing the Dashboard

```bash
# Human-readable format
/dark-factory:dashboard

# JSON format (for programmatic use)
/dark-factory:dashboard --json

# Last 30 days
/dark-factory:dashboard --days 30
```

## Governance Tiers

Every task gets a governance tier based on risk score, holdout validation, and satisfaction score:

| Tier | Risk Score | Holdout | Satisfaction | Action |
| --- | --- | --- | --- | --- |
| **T0: Auto-Ship** | < 15 | Pass | >= 80 | Auto-merge immediately |
| **T1: Auto-PR** | 15-40 | Pass | >= 75 | PR + auto-merge after CI |
| **T2: Review-PR** | 40-60 | Pass | >= 70 | PR + 1 human review required |
| **T3: Gated** | > 60 | Any | Any | PR + 2 reviews + architect |
| **T4: Blocked** | Any | Fail | < 50 | Stopped, human action required |

### Risk Score Calculation

Risk score = sum of matching risk factor scores from `config.yaml`.

Built-in factors (always active):

- **Cross-layer change** (multiple layers): +15
- **Large change** (> 15 files): +10
- **Full pipeline**: +10

Custom factors from `config.yaml` are added when the pattern matches issue labels or layer name.

## Agents

The plugin provides 6 agents:

| Agent | Role | Tools |
| --- | --- | --- |
| `holdout-validator` | Validates implementation against hidden behavioral scenarios | Read, Grep, Glob, Bash |
| `satisfaction-judge` | Two-pass adversarial quality evaluation (5 dimensions) | Read, Grep, Glob |
| `readiness-auditor` | Scores project readiness across 8 axes | Read, Grep, Glob, Bash, Write, Edit |
| `pipeline-doctor` | Self-healing: diagnoses and fixes pipeline failures | Read, Grep, Glob, Bash, Write, Edit |
| `task-analyzer` | Classifies task size, detects dependencies, computes risk | Read, Grep, Glob, Bash |
| `regression-runner` | Runs all test suites to catch regressions | Read, Bash, Glob |

## Hooks

### Holdout Guard (PreToolUse)

The plugin installs a `PreToolUse` hook that blocks implementation agents from reading holdout scenarios during development. This ensures agents cannot "teach to the test."

**Blocked**: Any `Read`, `Bash`, `Grep`, or `Glob` operation accessing `.dark-factory/holdouts/` or `*.holdout.yaml` files.

**Allowed**: `holdout-validator` agent, `satisfaction-judge` agent, and validation phases (via `HOLDOUT_VALIDATOR_MODE=true` env var).

## Architecture

```text
GitHub Issues --> sync-backlog --> backlog.md --> ralph.sh (loop)
                                                     |
                                               run-task.sh
                                                     |
                                    +------------------------------+
                                    | 1. Implementation (SDD+TDD)  |
                                    | 2. Holdout validation         |
                                    | 3. Satisfaction judge          |
                                    | 4. Governance tier             |
                                    | 5. Ship (PR/merge/label)      |
                                    +------------------------------+
                                                     |
                                    GitHub Issue + PR labels updated
```

### Session Artifacts

Each task execution creates a session directory in `.dark-factory/sessions/<id>/`:

```text
task-20260330-123456-abc12345/
  spec.md                      # Intent spec (holdouts stripped)
  spec-full.md                 # Full spec (for holdout validator)
  issue.json                   # GitHub issue metadata
  implementation-result.txt    # Agent output
  implementation-stderr.log    # Build/test errors
  agent-result.json            # Structured implementation result
  holdout-result.json          # Holdout validation results
  holdout-stderr.log           # Holdout errors
  satisfaction-result.json     # Satisfaction judge output
  satisfaction-parsed.json     # Parsed satisfaction JSON
  governance.json              # Final governance decision
  run.log                      # Session execution log
```

## Updating the Plugin

```bash
/plugin marketplace update everva
/reload-plugins
```

## Uninstalling

```bash
/plugin uninstall dark-factory@everva
```

This removes the plugin but keeps session data in `.dark-factory/`.

## License

MIT
