---
description: 'Dark Factory — start/stop/status of the Ralph Wiggum autonomous loop, sync backlog, run single task, or validate sessions.'
user-invocable: true
---

# /dark-factory:factory

Dark Factory — AI-driven autonomous development pipeline.

## Usage

```
/dark-factory:factory start [count] [hours]            — Start Ralph Wiggum loop (default: 5 tasks, 6h)
/dark-factory:factory start --monitor [count] [hours]  — Start with tmux live monitoring
/dark-factory:factory status                            — Show factory dashboard
/dark-factory:factory sync                              — Sync GitHub Issues → backlog
/dark-factory:factory run <spec-or-issue>               — Run single task through full pipeline
/dark-factory:factory backlog                           — Show current backlog
/dark-factory:factory validate <session-id>             — Validate a completed session
/dark-factory:factory import-prd <file> [--dry-run]     — Import PRD/requirements into backlog
/dark-factory:factory stop                              — Gracefully stop the Ralph loop
```

## Commands

### `start [--monitor] [count] [hours]`
Launch the Ralph Wiggum autonomous loop. With `--monitor`, opens a tmux session with live log tailing and dashboard.
```bash
# Without monitoring:
bash "${CLAUDE_PLUGIN_ROOT}/scripts/ralph.sh" ${count:-5} ${hours:-6}

# With tmux monitoring (recommended for long runs):
bash "${CLAUDE_PLUGIN_ROOT}/scripts/ralph.sh" --monitor ${count:-5} ${hours:-6}
```

### `status`
Show the observability dashboard.
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/dashboard.sh"
```

### `sync`
Sync GitHub Issues with `status:ready` label into the backlog.
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sync-backlog.sh"
```

### `run <spec-path-or-issue>`
Run a single task through the full Dark Factory pipeline.
```bash
# By intent spec file:
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-task.sh" docs/specs/backend-something.intent.md

# By issue number:
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-task.sh" --issue 42
```

### `backlog`
Display the current backlog.
```bash
cat .dark-factory/backlog.md
```

### `validate <session-id>`
Validate and inspect a completed session.
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/validate-session.sh" <session-id>
```

### `import-prd <file> [--format issue+spec|spec-only] [--dry-run]`
Import a PRD/requirements document into the backlog. Creates intent spec files and appends backlog rows.
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/import-prd.sh" <file> [--format issue+spec] [--dry-run]
```

### `stop`
Gracefully stop the Ralph loop (completes current task, then exits).
```bash
touch .dark-factory/.stop-signal
```

## Governance Tiers

| Tier | Action | Condition |
|------|--------|-----------|
| T0 | Auto-merge | Risk < 15, Satisfaction >= 80, Holdout pass |
| T1 | Auto-PR (CI gate) | Risk 15-40, Satisfaction >= 75, Holdout pass |
| T2 | PR + 1 review | Risk 40-60, Satisfaction >= 70 |
| T3 | PR + 2 reviews | Risk > 60 |
| T4 | Blocked | Holdout fail, Satisfaction < 50, or impl fail |
