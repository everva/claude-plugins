# claude-plugins

Claude Code plugin marketplace by atknatk.

## Install

Inside Claude Code:

```
/plugin marketplace add atknatk/claude-plugins
```

Then install any plugin:

```
/plugin install code-review@atknatk
/reload-plugins
```

## Plugins

| Plugin | Description | Commands |
| --- | --- | --- |
| [code-review](plugins/code-review/) | Multi-session code review with auto-fix loop | `/code-review:review`, `/code-review:review-fix` |

## Adding a New Plugin

1. Create `plugins/your-plugin/.claude-plugin/plugin.json`
2. Add skills, commands, agents, hooks under `plugins/your-plugin/`
3. Add entry to `.claude-plugin/marketplace.json`:
   ```json
   { "name": "your-plugin", "source": "./plugins/your-plugin" }
   ```
4. Push and run `/plugin marketplace update atknatk` in Claude Code

## License

MIT
