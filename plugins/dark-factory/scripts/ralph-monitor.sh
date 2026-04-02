#!/bin/bash
# Dark Factory Plugin — Ralph Wiggum tmux Monitor
# Launches ralph.sh in a tmux session with live log tailing and dashboard.
#
# Usage: ./ralph-monitor.sh [max-iterations] [max-hours]
#        (same positional args as ralph.sh)

set -euo pipefail

SESSION_NAME="dark-factory-ralph"

# --- Require tmux ---
if ! command -v tmux &>/dev/null; then
  echo "ERROR: tmux is required for monitor mode but was not found."
  echo "Install it with: brew install tmux (macOS) or apt install tmux (Linux)"
  exit 1
fi

# --- Attach if session already exists ---
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  echo "Attaching to existing tmux session '$SESSION_NAME'..."
  exec tmux attach-session -t "$SESSION_NAME"
fi

# --- Resolve paths ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source config to get FACTORY_DIR
source "$PLUGIN_ROOT/lib/config.sh"
load_project_config

FACTORY_DIR="$DF_FACTORY_DIR"
RALPH_LOG="$FACTORY_DIR/ralph.log"

# Ensure log file exists for tail -f
mkdir -p "$FACTORY_DIR"
touch "$RALPH_LOG"

# --- Build ralph.sh command with forwarded args ---
RALPH_CMD="$SCRIPT_DIR/ralph.sh"
if [ $# -gt 0 ]; then
  RALPH_CMD="$RALPH_CMD $*"
fi

# --- Create tmux session ---
# Main pane (left, 70%): ralph.sh
tmux new-session -d -s "$SESSION_NAME" -x "$(tput cols)" -y "$(tput lines)" "$RALPH_CMD"

# Right pane (30%): will be split into log + dashboard
tmux split-window -h -t "$SESSION_NAME" -p 30 "tail -f '$RALPH_LOG'"

# Split right pane horizontally: bottom half for dashboard
tmux split-window -v -t "$SESSION_NAME" "watch -n30 '$SCRIPT_DIR/dashboard.sh'"

# Select the main (left) pane
tmux select-pane -t "$SESSION_NAME:.0"

# Attach
exec tmux attach-session -t "$SESSION_NAME"
