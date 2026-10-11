#!/bin/bash

# NOTE: Target Bash 3.2 compatibility (macOS default).
# Avoid: ${var,,}, ${var^^}, local -n, associative arrays, etc.

# Install via the agent-rig installer:
#   bash /path/to/agent-rig/install/claude-installer.sh
#
# Or manually in ~/.claude/settings.json:
# {
#   "statusLine": {
#     "type": "command",
#     "command": "bash /path/to/agent-rig/statusline/statusline-command.sh"
#   }
# }

# Read Claude Code input from stdin and save to temp file
read_claude_input() {
  cat > /tmp/claude-status-input.json
}

# Run plugins from plugins.d/ directory.
# Filename format: <line>.<order>-<name> (e.g., 1.10-project, 2.50-cost)
# Plugins are sorted by filename, so segments group by line naturally.
# Each plugin is an executable that outputs a single segment.
# Empty output = segment skipped.
# Plugins receive env vars: CLAUDE_STATUS_INPUT, CLAUDE_PROJECT_DIR, CLAUDE_CURRENT_DIR
run_plugins() {
  local plugin_dir="${STATUSLINE_PLUGIN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/plugins.d}"
  [[ -d "$plugin_dir" ]] || return

  local current_line=""
  local line_output=""

  for plugin in "$plugin_dir"/*; do
    # Skip subdirectories (e.g., plugins.d/disabled/) and non-executable files.
    [[ -f "$plugin" && -x "$plugin" ]] || continue

    local name
    name=$(basename "$plugin")
    local line_num="${name%%.*}"
    # Skip files that don't follow the <line>.<order>-<name> convention
    if [[ "$line_num" == "$name" ]]; then
      continue
    fi

    local output
    output=$("$plugin" 2>/dev/null)
    [[ -n "$output" ]] || continue

    if [[ "$line_num" != "$current_line" ]]; then
      # Emit previous line
      if [[ -n "$line_output" ]]; then
        printf "%s\n" "$line_output"
      fi
      current_line="$line_num"
      line_output="$output"
    else
      line_output+=" | $output"
    fi
  done

  # Emit last line
  if [[ -n "$line_output" ]]; then
    printf "%s\n" "$line_output"
  fi
}

# Main execution
read_claude_input
export CLAUDE_STATUS_INPUT="/tmp/claude-status-input.json"

# Export commonly-needed values so plugins don't each have to call super
export CLAUDE_PROJECT_DIR=$(super -f line -c 'coalesce(workspace.project_dir, "")' "$CLAUDE_STATUS_INPUT")
export CLAUDE_CURRENT_DIR=$(super -f line -c 'coalesce(workspace.current_dir, "")' "$CLAUDE_STATUS_INPUT")

cd "${CLAUDE_CURRENT_DIR:-$(pwd)}" 2>/dev/null || true

run_plugins
