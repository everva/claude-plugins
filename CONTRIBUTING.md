# Contributing to Everva Claude Plugins

## Adding a New Plugin

### 1. Create the Plugin Directory

```bash
mkdir -p plugins/my-plugin/.claude-plugin
mkdir -p plugins/my-plugin/agents
mkdir -p plugins/my-plugin/skills/my-skill
mkdir -p plugins/my-plugin/hooks
mkdir -p plugins/my-plugin/scripts
```

### 2. Write the Plugin Manifest

Create `plugins/my-plugin/.claude-plugin/plugin.json`:

```json
{
  "name": "my-plugin",
  "version": "1.0.0",
  "description": "What this plugin does",
  "author": { "name": "everva" },
  "repository": "https://github.com/everva/claude-plugins",
  "keywords": ["keyword1", "keyword2"]
}
```

### 3. Add Agents (optional)

Create markdown files in `plugins/my-plugin/agents/`:

```markdown
---
name: my-agent
description: 'What this agent does'
tools: Read, Grep, Glob, Bash
model: opus
---

You are the my-agent. Your job is to...
```

### 4. Add Skills (optional)

Create `plugins/my-plugin/skills/my-skill/SKILL.md`:

```markdown
---
description: 'What this skill does'
user-invocable: true
---

# /my-plugin:my-skill

Instructions for the skill...
```

### 5. Add Hooks (optional)

Create `plugins/my-plugin/hooks/hooks.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/scripts/my-hook.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

### 6. Register in Marketplace

Add an entry to `.claude-plugin/marketplace.json`:

```json
{
  "name": "my-plugin",
  "source": "./plugins/my-plugin",
  "description": "What this plugin does",
  "version": "1.0.0",
  "category": "automation",
  "tags": ["tag1", "tag2"]
}
```

### 7. Write Documentation

- `plugins/my-plugin/README.md` — Installation, usage, configuration
- `plugins/my-plugin/CLAUDE.md` — Instructions that get merged into Claude's context

### 8. Test Locally

```bash
claude --plugin-dir ./plugins/my-plugin
```

### 9. Submit

Commit and push. The plugin is immediately available via:

```bash
/plugin marketplace update everva
/plugin install my-plugin@everva
```

## Plugin Environment Variables

| Variable | Description |
| --- | --- |
| `${CLAUDE_PLUGIN_ROOT}` | Path to the installed plugin directory (changes on update) |
| `${CLAUDE_PLUGIN_DATA}` | Persistent data directory (survives updates) |
| `${CLAUDE_PROJECT_DIR}` | Current project directory |

## Conventions

- All agents use `model: opus`
- All shell scripts must have `set -euo pipefail`
- All scripts must be executable (`chmod +x`)
- Use `${CLAUDE_PLUGIN_ROOT}` for referencing plugin files in hooks and scripts
- Use `${CLAUDE_PROJECT_DIR}` for referencing project files from scripts
- Plugin names: kebab-case
- Skill names: kebab-case
- Agent names: kebab-case
