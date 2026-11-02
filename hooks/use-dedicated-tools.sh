#!/usr/bin/env bash

# PreToolUse hook for Bash tool: denies commands that should use dedicated tools,
# and rejects compound commands (pipes, chains) which typically cause permission prompts.

set -euo pipefail
export ASDF_SUPERDB_VERSION=0.4.0

trap 'deny_tool "HOOK CRASH in use-dedicated-tools.sh (line $LINENO). Do NOT retry — the hook code itself is broken. Stop and tell the user."' ERR

LOG_DIR="$HOME/.claude/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/dedicated-tools-hook.sup"
MAX_LINES=200

# Output the deny JSON in the format Claude Code expects
deny_tool() {
  local reason="$1"
  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"$reason"}}
EOF
}

log() {
  local decision="$1" cmd="$2" full="$3"
  echo "$full" | super -s -i line -c "values {ts: now(), cmd: '$cmd', full: this, decision: '$decision'}" - >> "$LOG_FILE"
  tail -n "$MAX_LINES" "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
}

input=$(cat)

# ── DISABLED 2026-06-23: experimenting with newer Claude's auto-mode ──
# All the dedicated-tool / compound-command / redirect checks below are turned
# off to see whether the model self-governs well enough without them. This early
# allow short-circuits the entire hook. To re-enable, delete this block.
exit 0

# Extract the command string from the hook JSON
# Note: use pipe instead of <<< here-string — bash 3.2 (macOS default) mangles <<<
command_str=$(echo "$input" | super -f line -c 'this.tool_input.command' -)

# Always allow commands targeting the repo-level tmp/ directory. This must come
# before all deny checks so it isn't caught by other rules.
if [[ "$command_str" =~ (^|[[:space:]])tmp(/|$) ]]; then
  log "allow" "repo-tmp" "$command_str"
  exit 0
fi

# Catch super CLI early — super queries often contain pipes/semicolons in their
# expression syntax, which would hit the compound-command denial below with a
# misleading message. Redirect to SuperDB MCP tools instead.
_first="${command_str%% *}"
if [[ "${_first##*/}" == "super" ]]; then
  log "deny" "super" "$command_str"
  deny_tool "Use the SuperDB MCP tools instead of the \`super\` CLI in Bash."
  exit 0
fi

# Deny any compound command (pipes, chains, semicolons) — these almost always
# trigger permission prompts, which defeats the goal of keeping things flowing.
if [[ "$command_str" =~ \||(\&\&)|\; ]]; then
  log "deny" "compound" "$command_str"
  deny_tool "Compound commands (pipes, &&, ||, ;) are not allowed. Break this into separate tool calls."
  exit 0
fi

# Deny process substitution <(...) and >(...) — these embed hidden commands
# that bypass the compound command check above.
if [[ "$command_str" =~ \<\(|\>\( ]]; then
  log "deny" "process-substitution" "$command_str"
  deny_tool "Process substitution (<(...) and >(...)) is not allowed. Break this into separate tool calls."
  exit 0
fi

# Carve-out: allow the canonical `git commit -m "$(cat <<'EOF' ... EOF)"`
# pattern that Claude Code's system prompt recommends. Narrow to cat-heredoc
# so we don't open the door to arbitrary $() in commit messages.
if [[ "$command_str" =~ ^git[[:space:]]+commit ]] && [[ "$command_str" =~ \$\(cat[[:space:]]*\<\< ]]; then
  log "allow" "git-commit-heredoc" "$command_str"
  exit 0
fi

# Deny command substitution $(...) — these always trigger permission prompts.
# Run the inner command separately and use the result.
if [[ "$command_str" =~ \$\( ]]; then
  log "deny" "command-substitution" "$command_str"
  if [[ "$command_str" =~ ^git\ commit ]]; then
    deny_tool "Command substitution (\$(...)) is not allowed. Write the commit message to a new file in tmp/ using the Write tool (title ≤50 chars, body wrapped at 72 cols, blank line between title and body), then run: git commit -F tmp/<your-file>"
  else
    deny_tool "Command substitution (\$(...)) is not allowed. Run the inner command separately, then use the result."
  fi
  exit 0
fi

# Deny scripts invoked by absolute path when they're under the working directory —
# absolute paths trigger per-worktree approval prompts; relative paths don't.
cwd=$(pwd)
if [[ "$command_str" == "$cwd"/* ]]; then
  log "deny" "absolute-path" "$command_str"
  deny_tool "Use a relative path instead of an absolute path for scripts under the working directory."
  exit 0
fi

# Deny commands that reference /tmp — these always trigger permission prompts
# because /tmp is outside the project directory. Use a repo-level tmp/ instead.
# Also catch relative traversals like ../../../tmp that resolve to /tmp.
if [[ "$command_str" =~ (^|[[:space:]\"\'=])/tmp(/|$) ]] || [[ "$command_str" =~ (\.\./)+tmp(/|$) ]]; then
  log "deny" "tmp-redirect" "$command_str"
  deny_tool "Do not use /tmp — it is outside the project and triggers permission prompts. Use tmp/ in the repo root instead (mkdir -p tmp first if needed, and add tmp/ to .gitignore)."
  exit 0
fi

# Get the first word (the primary command)
first_word="${command_str%% *}"
# Strip any leading path components (e.g. /usr/bin/grep -> grep, ~/.asdf/.../super -> super)
base_cmd="${first_word##*/}"

message=""

case "$base_cmd" in
  # Note: grep/rg/find are intentionally NOT denied. The native Claude Code
  # binary (2.1.117+) removed the dedicated Grep and Glob tools and routes
  # search through Bash (embedded ripgrep/find), so search must pass through.
  cat|head|tail)
    message="Use the Read tool instead of \`$base_cmd\` in Bash."
    ;;
  sed|awk)
    message="Use the Edit tool instead of \`$base_cmd\` in Bash."
    ;;
  echo|printf)
    # Approximate: any > not followed by & (i.e., not >&). May false-positive on
    # quoted > inside strings, which is acceptable for a deny-with-guidance hook.
    if [[ "$command_str" =~ \>[^\&] ]]; then
      message="Use the Write tool instead of \`$base_cmd\` with file redirection in Bash."
    fi
    ;;
  python|python3)
    # Deny if doing JSON operations — SuperDB MCP handles this better
    if [[ "$command_str" =~ json ]]; then
      message="Use the SuperDB MCP tools instead of Python for JSON operations."
    fi
    ;;
  eval)
    message="\`eval\` is not allowed — it executes arbitrary strings and is never needed for normal tasks."
    ;;
  exec)
    message="\`exec\` is not allowed — it replaces the current process."
    ;;
  source)
    message="\`source\` is not allowed — use the Read tool to inspect files instead."
    ;;
  rm)
    message="\`rm\` is not allowed — destructive filesystem ops need user confirmation. Ask the user to run the command themselves if the file/directory truly needs to be deleted."
    ;;
  git)
    # Match git -C only as the first flag (not buried in commit messages etc.)
    if [[ "$command_str" =~ ^git\ -C\  ]]; then
      message="\`git -C\` is not allowed — run git commands from the correct directory instead."
    fi
    ;;
  bash|sh|zsh)
    if [[ "$command_str" =~ \ -c\  ]]; then
      message="\`$base_cmd -c\` is not allowed — it bypasses compound command restrictions. Run the command directly."
    else
      # Deny `bash script.sh` — run scripts directly so allow rules can match.
      args="${command_str#* }"
      first_arg="${args%% *}"
      if [[ -n "$first_arg" ]] && [[ "$first_arg" != "$command_str" ]] && [[ "$first_arg" != -* ]]; then
        message="Do not invoke scripts via \`$base_cmd\` — run directly (e.g., ./$first_arg instead of $base_cmd $first_arg). Ensure the script has a shebang (#!/usr/bin/env bash) and is executable (chmod +x). Direct invocation allows pre-approved allow rules to match."
      fi
    fi
    ;;
esac

if [[ -n "$message" ]]; then
  log "deny" "$base_cmd" "$command_str"
  deny_tool "$message"
else
  log "allow" "$base_cmd" "$command_str"
  exit 0
fi
