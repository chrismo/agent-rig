#!/usr/bin/env bash

set -euo pipefail

# Load shared config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/config.sh"

# A link left by the installer in a checkout moved since the claude-rig rename.
# Ownership checks compare against the current repo path, so these would
# otherwise be read as someone else's. Delete once every machine has re-run.
left_by_rename() {
  [[ -L "$1" ]] && [[ ! -e "$1" ]] && [[ "$(readlink "$1")" == */claude-rig/* ]]
}

# Ensure .claude directory exists
mkdir -p "$CLAUDE_DIR"

# Check if super is installed
if ! command -v super &>/dev/null; then
  echo "Error: 'super' command not found. Please install it first:"
  echo "  brew install super"
  exit 1
fi

# Check if statusline-command.sh exists
if [[ ! -f "$STATUSLINE_SCRIPT" ]]; then
  echo "Error: statusline-command.sh not found at $STATUSLINE_SCRIPT"
  exit 1
fi

# Create default settings.json if it doesn't exist
if [[ ! -f "$SETTINGS_FILE" ]]; then
  echo "{}" > "$SETTINGS_FILE"
  echo "Created new settings.json"
fi

# Backup existing settings
backup_file="$CLAUDE_DIR/settings-bak-$(date +%Y%m%d-%H%M%S).json"
cp "$SETTINGS_FILE" "$backup_file"
echo "Backed up existing settings to: $backup_file"

# Merge the statusLine setting using super
new_settings=$(
  super -J -c "statusLine:={type:'command',command:'bash $STATUSLINE_SCRIPT'}" \
    "$SETTINGS_FILE"
)

# Write the merged settings
echo "$new_settings" > "$SETTINGS_FILE"

echo "✓ Installed statusLine configuration"
echo "  Command: bash $STATUSLINE_SCRIPT"
echo ""

# Merge agent-rig hooks into settings.json.
#
# Pattern: `values {...{hooks:{}}, ...this} | values {...this, hooks: {...this.hooks, Y: [...]}} | drop hooks.X`
#   - `values {...{hooks:{}}, ...this}` defaults hooks to {} only when it is absent:
#     the spread of `this` comes second, so a real hooks record wins. Do NOT use
#     `put hooks := {}` here — put REPLACES the field rather than merging into it,
#     which silently wiped every user-managed hook event on install.
#   - `...this.hooks` preserves any hook event types agent-rig does NOT manage (e.g.,
#     user's own SubagentStop, PreCompact, etc.).
#   - Named keys after the spread (Y, Z, ...) override per-event-type: agent-rig owns
#     those event types entirely, replacing whatever was there.
#   - `drop hooks.X` removes hook event types agent-rig used to manage but no longer
#     does (otherwise stale entries would linger forever — spread can't subtract).
#     It runs LAST, after the named keys above have guaranteed hooks is non-empty:
#     dropping the sole field of a nested record makes super emit no record at all,
#     which would write an empty settings.json.
# When retiring a hook event type from agent-rig, ADD it to the `drop` list so it
# disappears from existing settings.json on next install.
# tab-status --title sets the Ghostty tab title itself (resolves the pane's pts
# and uses Ghostty's set_tab_title action via osascript). It must NOT redirect
# to /dev/tty: hooks run with no controlling terminal, so opening /dev/tty fails
# and the command would never execute.
HOOK_CMD_PREFIX="tab-status --hook"
TITLE_CMD="tab-status --title > /dev/null 2>&1 || true"

new_settings=$(
  super -J -c "values {...{hooks:{}}, ...this} | values {...this, hooks: {...this.hooks,
    UserPromptSubmit: [{
      matcher: '',
      hooks: [{
        type: 'command',
        command: '${HOOK_CMD_PREFIX} engage > /dev/null; ${TITLE_CMD}'
      }]
    }],
    PermissionRequest: [{
      matcher: '',
      hooks: [{
        type: 'command',
        command: '${HOOK_CMD_PREFIX} waiting > /dev/null; ${TITLE_CMD}'
      }]
    }],
    PostToolUse: [{
      matcher: '',
      hooks: [{
        type: 'command',
        command: '${HOOK_CMD_PREFIX} active > /dev/null; ${TITLE_CMD}'
      }]
    }, {
      matcher: 'Bash',
      hooks: [{
        type: 'command',
        command: '${LEMMA_COMMIT_HOOK}',
        timeout: 10
      }]
    }],
    Stop: [{
      matcher: '',
      hooks: [{
        type: 'command',
        command: '${HOOK_CMD_PREFIX} stop > /dev/null; ${TITLE_CMD}'
      }]
    }, {
      matcher: '',
      hooks: [{
        type: 'command',
        command: 'claude-tabs save > /dev/null 2>&1 || true',
        timeout: 5000
      }]
    }],
    PreToolUse: [{
      matcher: 'Bash',
      hooks: [{
        type: 'command',
        command: '${DEDICATED_TOOLS_HOOK}'
      }]
    }],
    SessionStart: [{
      matcher: '',
      hooks: [{
        type: 'command',
        command: '${INTERNALS_DRIFT_HOOK}'
      }]
    }, {
      matcher: '',
      hooks: [{
        type: 'command',
        command: '${LEMMA_BRIEF_HOOK}',
        timeout: 10
      }]
    }]
  }}" "$SETTINGS_FILE"
)

echo "$new_settings" > "$SETTINGS_FILE"

echo "✓ Installed hooks (UserPromptSubmit, PostToolUse, PermissionRequest, Stop, PreToolUse, SessionStart)"
echo ""

# Drop CLAUDE_AUTOCOMPACT_PCT_OVERRIDE, which this installer used to set to 16.
# It is removed rather than left alone because the var still drives when Claude
# Code auto-compacts, so a leftover value would keep acting on any machine that
# ran the old installer. Delete this block once every machine has run it.
# Guarded because `drop` is a compile error when the field is not there.
if grep -q 'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' "$SETTINGS_FILE"; then
  new_settings=$(super -J -c 'drop env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' "$SETTINGS_FILE")
  echo "$new_settings" > "$SETTINGS_FILE"
  echo "✓ Removed env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"
  echo ""
fi


# Merge permissions/allow.sup into settings.json (idempotent via sort | uniq)
if [[ -f "$PERMISSIONS_ALLOW" ]]; then
  if grep -q '"permissions"' "$SETTINGS_FILE"; then
    new_settings=$(
      super -J -c 'values {
        ...this,
        permissions: {
          ...this.permissions,
          allow: (
            unnest [...this.permissions.allow, ...(from "'"$PERMISSIONS_ALLOW"'" | collect(this))]
            | sort this | uniq | collect(this)
          )
        }
      }' "$SETTINGS_FILE"
    )
  else
    new_settings=$(
      super -J -c 'values {
        ...this,
        permissions: {
          allow: (
            unnest (from "'"$PERMISSIONS_ALLOW"'" | collect(this))
            | sort this | uniq | collect(this)
          )
        }
      }' "$SETTINGS_FILE"
    )
  fi
  echo "$new_settings" > "$SETTINGS_FILE"
  echo "✓ Merged permissions from allow.sup"
  echo ""
fi

# Merge permissions/deny.sup into settings.json (idempotent via sort | uniq)
if [[ -f "$PERMISSIONS_DENY" ]] && grep -q '[^[:space:]]' "$PERMISSIONS_DENY"; then
  if grep -q '"deny"' "$SETTINGS_FILE"; then
    new_settings=$(
      super -J -c 'values {
        ...this,
        permissions: {
          ...this.permissions,
          deny: (
            unnest [...this.permissions.deny, ...(from "'"$PERMISSIONS_DENY"'" | collect(this))]
            | sort this | uniq | collect(this)
          )
        }
      }' "$SETTINGS_FILE"
    )
  else
    new_settings=$(
      super -J -c 'values {
        ...this,
        permissions: {
          ...this.permissions,
          deny: (
            unnest (from "'"$PERMISSIONS_DENY"'" | collect(this))
            | sort this | uniq | collect(this)
          )
        }
      }' "$SETTINGS_FILE"
    )
  fi
  echo "$new_settings" > "$SETTINGS_FILE"
  echo "✓ Merged permissions from deny.sup"
  echo ""
fi


# Merge sandbox/allow-write.sup into settings.json (idempotent via sort | uniq)
if [[ -f "$SANDBOX_ALLOW_WRITE" ]]; then
  if grep -q '"sandbox"' "$SETTINGS_FILE"; then
    new_settings=$(
      super -J -c 'values {
        ...this,
        sandbox: {
          ...this.sandbox,
          filesystem: {
            ...this.sandbox.filesystem,
            allowWrite: (
              unnest [...coalesce(this.sandbox.filesystem.allowWrite, []), ...(from "'"$SANDBOX_ALLOW_WRITE"'" | collect(this))]
              | sort this | uniq | collect(this)
            )
          }
        }
      }' "$SETTINGS_FILE"
    )
  else
    new_settings=$(
      super -J -c 'values {
        ...this,
        sandbox: {
          filesystem: {
            allowWrite: (
              unnest (from "'"$SANDBOX_ALLOW_WRITE"'" | collect(this))
              | sort this | uniq | collect(this)
            )
          }
        }
      }' "$SETTINGS_FILE"
    )
  fi
  echo "$new_settings" > "$SETTINGS_FILE"
  echo "✓ Merged sandbox allowWrite from allow-write.sup"
  echo ""
fi

# Clean up deprecated ~/.claude/commands/ entries that agent-rig installed
# (only remove entries matching our skill names, not other tools' files)
LEGACY_COMMANDS_DIR="$CLAUDE_DIR/commands"
if [[ -d "$LEGACY_COMMANDS_DIR" ]] && [[ -d "$SKILLS_SRC" ]]; then
  legacy_count=0
  for cmd_file in "$SKILLS_SRC"/*.md; do
    if [[ -f "$cmd_file" ]]; then
      legacy="$LEGACY_COMMANDS_DIR/$(basename "$cmd_file")"
      if [[ -L "$legacy" ]] || [[ -f "$legacy" ]]; then
        rm "$legacy"
        legacy_count=$((legacy_count + 1))
      fi
    fi
  done
  for subdir in "$SKILLS_SRC"/*/; do
    if [[ -d "$subdir" ]]; then
      legacy="$LEGACY_COMMANDS_DIR/$(basename "$subdir")"
      if [[ -L "$legacy" ]] || [[ -d "$legacy" ]]; then
        rm -rf "$legacy"
        legacy_count=$((legacy_count + 1))
      fi
    fi
  done
  if [[ $legacy_count -gt 0 ]]; then
    echo "✓ Cleaned up $legacy_count entry(s) from deprecated ~/.claude/commands/"
    echo ""
  fi
fi

# Install user-level skills
if [[ -d "$SKILLS_SRC" ]]; then
  mkdir -p "$SKILLS_DEST"
  count=0

  # Install top-level skills (*.md -> /user:<name>)
  for cmd_file in "$SKILLS_SRC"/*.md; do
    if [[ -f "$cmd_file" ]]; then
      filename=$(basename "$cmd_file")
      dest_file="$SKILLS_DEST/$filename"

      if [[ -L "$dest_file" ]] || [[ -f "$dest_file" ]]; then
        rm "$dest_file"
      fi

      ln -s "$cmd_file" "$dest_file"
      count=$((count + 1))
    fi
  done

  # Install namespaced skills by symlinking subdirectories
  for subdir in "$SKILLS_SRC"/*/; do
    if [[ -d "$subdir" ]]; then
      namespace=$(basename "$subdir")
      dest_subdir="$SKILLS_DEST/$namespace"

      # Clean up stale bare-file symlink if skill was restructured into a directory
      stale_md="$SKILLS_DEST/${namespace}.md"
      if [[ -L "$stale_md" ]] || [[ -f "$stale_md" ]]; then
        rm "$stale_md"
      fi

      if [[ -L "$dest_subdir" ]] || [[ -d "$dest_subdir" ]]; then
        rm -rf "$dest_subdir"
      fi

      ln -s "$subdir" "$dest_subdir"
      subcount=$(find "$subdir" -maxdepth 1 -name "*.md" | wc -l | tr -d ' ')
      count=$((count + subcount))
    fi
  done

  # Prune orphaned symlinks for skills deleted from the repo. The loops above
  # only add/update; without this a removed skill lingers as a dangling symlink.
  # Scope to broken links pointing into $SKILLS_SRC so the user's own symlinks
  # (pointing elsewhere) are never touched.
  for dest in "$SKILLS_DEST"/*; do
    if [[ -L "$dest" ]] && [[ ! -e "$dest" ]] && { [[ "$(readlink "$dest")" == "$SKILLS_SRC/"* ]] || left_by_rename "$dest"; }; then
      rm "$dest"
    fi
  done

  if [[ $count -gt 0 ]]; then
    echo "✓ Installed $count user-level skill(s)"
    echo ""
  fi
fi

# Serve the harness-agnostic skills to pi as well
#
# pi discovers any directory containing a SKILL.md under <agent dir>/skills/
# (docs/skills.md in the pi package), so one source can feed both harnesses.
#
# An allowlist, not a glob, and a short one. Most skills here instruct tools that
# exist only in Claude Code — goal-compose drives /goal, pod-peer needs
# SendMessage, the lemma-* skills call lemmalog_* MCP tools by name — and a skill
# that tells pi to use a tool pi does not have is worse than an absent skill.
# When a skill stops depending on Claude-only tools, add it here.
#
# Gated on pi's agent dir already existing: this repo is deployed to machines
# that will never run pi, and an installer that invents ~/.pi on them is
# claiming ownership of a tool that is not installed.
PI_SKILLS=(autopilot dialogue kaomoji simplify work-context)
if [[ -d "$PI_AGENT_DIR" ]]; then
  mkdir -p "$PI_SKILLS_DEST"
  pi_linked=0
  for skill in "${PI_SKILLS[@]}"; do
    src="$SKILLS_SRC/$skill"
    dest="$PI_SKILLS_DEST/$skill"
    if [[ ! -d "$src" ]]; then
      echo "⚠ $skill is on the pi list but not in $SKILLS_SRC — skipped."
      continue
    fi
    # These are ordinary skill names, and the destination is pi's own directory.
    # Anything there that is not a link of ours belongs to someone else — the
    # user, another tool, a pi package — and replacing it destroys their work
    # silently. Same line the cleanup loop below holds, and the MCP block after
    # it. `rm` and not `rm -rf`: once only a symlink is ever removed, the -rf
    # buys nothing and is the part that makes a mistake unrecoverable.
    if [[ -L "$dest" ]]; then
      if [[ "$(readlink "$dest")" != "$SKILLS_SRC/"* ]] && ! left_by_rename "$dest"; then
        echo "⚠ $dest links outside this repo — leaving it alone."
        continue
      fi
      rm "$dest"
    elif [[ -e "$dest" ]]; then
      echo "⚠ $dest already exists and is not a agent-rig symlink — leaving it alone."
      continue
    fi
    ln -s "$src" "$dest"
    pi_linked=$((pi_linked + 1))
  done

  # Retire links this installer made for skills no longer on the allowlist.
  # Scoped to symlinks pointing into $SKILLS_SRC, so pi skills from anywhere
  # else — the user's own, another tool's, a pi package's — are never touched.
  for dest in "$PI_SKILLS_DEST"/*; do
    [[ -L "$dest" ]] || continue
    [[ "$(readlink "$dest")" == "$SKILLS_SRC/"* ]] || left_by_rename "$dest" || continue
    name=$(basename "$dest")
    keep=0
    for skill in "${PI_SKILLS[@]}"; do
      if [[ "$name" == "$skill" ]]; then keep=1; break; fi
    done
    ((keep)) || rm "$dest"
  done

  # The personal footer extension, from the same gate: pi loads
  # <agent dir>/extensions/*.ts. Distinct variable names because the cleanup
  # loop above owns $dest. Same rule as the skills — anything already at this
  # path that is not our own link belongs to someone else and is reported.
  footer_src="$REPO_DIR/pi/extensions/personal-footer.ts"
  footer_dest="$PI_AGENT_DIR/extensions/personal-footer.ts"
  mkdir -p "$(dirname "$footer_dest")"
  if [[ -L "$footer_dest" ]] && [[ "$(readlink "$footer_dest")" == "$footer_src" ]]; then
    :
  elif left_by_rename "$footer_dest"; then
    rm "$footer_dest"
    ln -s "$footer_src" "$footer_dest"
  elif [[ ! -e "$footer_dest" ]] && [[ ! -L "$footer_dest" ]]; then
    ln -s "$footer_src" "$footer_dest"
  else
    echo "⚠ $footer_dest already exists — leaving it alone."
  fi

  echo "✓ Installed $pi_linked skill(s) for pi -> $PI_SKILLS_DEST"
  echo ""
fi

# Share the tracked MCP servers with pi
#
# pi has no native MCP (an explicit "No MCP" stance in its README); pi-mcp-adapter
# supplies it and reads ~/.config/mcp/mcp.json as the LOWEST-precedence source, so
# what this repo tracks acts as a default that ~/.pi/agent/mcp.json, a project
# .mcp.json and .pi/mcp.json can all still override. Claude Code keeps its own
# user-scope registrations in ~/.claude.json, managed by `claude mcp add` — those
# are imported into pi with `pi-mcp-adapter init`, not from here.
#
# A real file is never overwritten: this path is shared with any other tool that
# reads the standard location, and whatever is already there was not ours to
# replace.
if [[ -d "$PI_AGENT_DIR" ]] && [[ -f "$MCP_SHARED_SRC" ]]; then
  if [[ -e "$MCP_SHARED_DEST" ]] && [[ ! -L "$MCP_SHARED_DEST" ]]; then
    echo "⚠ $MCP_SHARED_DEST already exists and is not a symlink — leaving it alone."
    echo "  agent-rig tracks its own copy at $MCP_SHARED_SRC; merge by hand if you want it."
  else
    mkdir -p "$(dirname "$MCP_SHARED_DEST")"
    [[ -L "$MCP_SHARED_DEST" ]] && rm "$MCP_SHARED_DEST"
    ln -s "$MCP_SHARED_SRC" "$MCP_SHARED_DEST"
    echo "✓ Linked shared MCP config -> $MCP_SHARED_DEST"
  fi
  echo ""
fi

# Install the portable simplify skill where Codex, Pi, and OpenCode discover
# Agent Skills. Other skills may depend on Claude-specific tools or behavior.
shared_skill="$SKILLS_SRC/simplify"
if [[ -d "$shared_skill" ]]; then
  mkdir -p "$AGENT_SKILLS_DEST"
  dest_subdir="$AGENT_SKILLS_DEST/simplify"
  if [[ -L "$dest_subdir" ]] && [[ "$(readlink "$dest_subdir")" == "$shared_skill" ]]; then
    :
  elif [[ -L "$dest_subdir" ]] && [[ "$(readlink "$dest_subdir")" == "$SKILLS_SRC/"* ]] || left_by_rename "$dest_subdir"; then
    rm "$dest_subdir"
    ln -s "$shared_skill" "$dest_subdir"
  elif [[ ! -e "$dest_subdir" ]] && [[ ! -L "$dest_subdir" ]]; then
    ln -s "$shared_skill" "$dest_subdir"
  fi
fi

# Codex currently uses its own user skill directory.
if [[ -d "$SKILLS_SRC/simplify" ]]; then
  mkdir -p "$CODEX_SKILLS_DEST"
  dest_subdir="$CODEX_SKILLS_DEST/simplify"
  if [[ -L "$dest_subdir" ]] && [[ "$(readlink "$dest_subdir")" == "$SKILLS_SRC/simplify" ]]; then
    :
  elif [[ -L "$dest_subdir" ]] && [[ "$(readlink "$dest_subdir")" == "$SKILLS_SRC/"* ]] || left_by_rename "$dest_subdir"; then
    rm "$dest_subdir"
    ln -s "$SKILLS_SRC/simplify" "$dest_subdir"
  elif [[ ! -e "$dest_subdir" ]] && [[ ! -L "$dest_subdir" ]]; then
    ln -s "$SKILLS_SRC/simplify" "$dest_subdir"
  fi
fi

# Install user-level agents
if [[ -d "$AGENTS_SRC" ]]; then
  mkdir -p "$AGENTS_DEST"
  count=0

  for agent_file in "$AGENTS_SRC"/*.md; do
    if [[ -f "$agent_file" ]]; then
      filename=$(basename "$agent_file")
      dest_file="$AGENTS_DEST/$filename"

      # Remove existing symlink or file
      if [[ -L "$dest_file" ]] || [[ -f "$dest_file" ]]; then
        rm "$dest_file"
      fi

      # Create symlink
      ln -s "$agent_file" "$dest_file"
      count=$((count + 1))
    fi
  done

  if [[ $count -gt 0 ]]; then
    echo "✓ Installed $count user-level agent(s):"
    for agent_file in "$AGENTS_DEST"/*.md; do
      if [[ -L "$agent_file" ]]; then
        name=$(basename "$agent_file" .md)
        echo "  $name"
      fi
    done
    echo ""
  fi
fi

# The subagent extension discovers <agent dir>/agents/*.md, not Claude's agents.
if [[ -d "$PI_AGENT_DIR" ]] && [[ -d "$AGENTS_SRC" ]]; then
  mkdir -p "$PI_AGENTS_DEST"
  count=0
  for agent_file in "$AGENTS_SRC"/*.md; do
    [[ -f "$agent_file" ]] || continue
    dest_file="$PI_AGENTS_DEST/$(basename "$agent_file")"
    tmp_file=$(mktemp "$PI_AGENTS_DEST/.agent.XXXXXX")
    if awk '
      NR == 1 && /^---$/ { frontmatter = 1; print; next }
      frontmatter && /^---$/ { frontmatter = 0 }
      frontmatter && /^tools:/ {
        sub(/^tools:[[:space:]]*/, "")
        n = split($0, tools, /,[[:space:]]*/)
        line = "tools: "
        for (i = 1; i <= n; i++) {
          tool = tolower(tools[i])
          if (tool == "glob") tool = "find"
          if (tool == "webfetch") tool = "bash"
          line = line (i > 1 ? ", " : "") tool
        }
        print line
        next
      }
      { print }
    ' "$agent_file" > "$tmp_file"; then
      # Replace rather than follow a pre-existing symlink into another source.
      mv -f "$tmp_file" "$dest_file"
    else
      rm -f "$tmp_file"
      exit 1
    fi
    count=$((count + 1))
  done
  echo "✓ Installed $count agent(s) for pi -> $PI_AGENTS_DEST (requires subagent extension)"
  echo ""
fi

# OpenCode discovers markdown agents only under its own config dir (docs/
# agents.md) — it does not read Claude's ~/.claude/agents — so this is a
# transformation, not a symlink like the Claude install:
#
#   name:   dropped; OpenCode names an agent by its file name.
#   mode:   subagent added — the frontmatter default `all` would also list
#           them as primary agents in the Tab-cycling UI. An explicit mode
#           in the repo agent wins.
#   tools:  Claude's `tools:` is a bare allowlist, but OpenCode `permission:`
#           entries only override the user's global defaults (often allow).
#           Keeping "nothing beyond the list" means allowing listed tools and
#           denying the permission-gated action tools that were not listed.
#
# Gated on the config dir existing, like the pi install: don't invent a config
# dir on machines that do not run OpenCode.
if [[ -d "$OPENCODE_CONFIG_DIR" ]] && [[ -d "$AGENTS_SRC" ]]; then
  mkdir -p "$OPENCODE_AGENTS_DEST"
  count=0
  for agent_file in "$AGENTS_SRC"/*.md; do
    [[ -f "$agent_file" ]] || continue
    dest_file="$OPENCODE_AGENTS_DEST/$(basename "$agent_file")"
    tmp_file=$(mktemp "$OPENCODE_AGENTS_DEST/.agent.XXXXXX")
    if awk '
      NR == 1 && /^---$/ { frontmatter = 1; print; next }
      frontmatter && /^---$/ {
        frontmatter = 0
        if (!saw_mode) print "mode: subagent"
        if (tools_seen) {
          print "permission:"
          m = split("read glob grep bash edit webfetch task", order, " ")
          for (i = 1; i <= m; i++)
            if (order[i] in perm) print "  " order[i] ": " perm[order[i]]
        }
        print
        next
      }
      frontmatter && /^name:/ { next }
      frontmatter && /^mode:/ { saw_mode = 1; print; next }
      frontmatter && /^tools:/ {
        sub(/^tools:[[:space:]]*/, "")
        n = split($0, tools, /,[[:space:]]*/)
        for (i = 1; i <= n; i++) {
          tool = tolower(tools[i])
          # write maps to edit: that permission gates write, edit and
          # apply_patch alike.
          if (tool == "edit" || tool == "write") perm["edit"] = "allow"
          else if (tool == "read" || tool == "grep" || tool == "glob" ||
                   tool == "bash" || tool == "webfetch" || tool == "task")
            perm[tool] = "allow"
        }
        if (!("edit" in perm))     perm["edit"] = "deny"
        if (!("bash" in perm))     perm["bash"] = "deny"
        if (!("webfetch" in perm)) perm["webfetch"] = "deny"
        if (!("task" in perm))     perm["task"] = "deny"
        tools_seen = 1
        next
      }
      { print }
    ' "$agent_file" > "$tmp_file"; then
      # Replace rather than follow a pre-existing symlink into another source.
      mv -f "$tmp_file" "$dest_file"
    else
      rm -f "$tmp_file"
      exit 1
    fi
    count=$((count + 1))
  done
  echo "✓ Installed $count agent(s) for OpenCode -> $OPENCODE_AGENTS_DEST"
  echo ""
fi

# Install user-level rules
if [[ -d "$RULES_SRC" ]]; then
  mkdir -p "$RULES_DEST"
  count=0

  for rule_file in "$RULES_SRC"/*.md; do
    if [[ -f "$rule_file" ]]; then
      filename=$(basename "$rule_file")
      dest_file="$RULES_DEST/$filename"

      if [[ -L "$dest_file" ]] || [[ -f "$dest_file" ]]; then
        rm "$dest_file"
      fi

      ln -s "$rule_file" "$dest_file"
      count=$((count + 1))
    fi
  done

  if [[ $count -gt 0 ]]; then
    echo "✓ Installed $count user-level rule(s):"
    for rule_file in "$RULES_DEST"/*.md; do
      if [[ -L "$rule_file" ]]; then
        name=$(basename "$rule_file" .md)
        echo "  $name"
      fi
    done
    echo ""
  fi
fi

# cc-audit is retired. Remove the rules link earlier installs made; anything
# else at that path is not ours. Delete this block once every machine has run it.
if [[ -L "$CC_AUDIT_RULES_DEST" ]] && { [[ "$(readlink "$CC_AUDIT_RULES_DEST")" == "$REPO_DIR/cc-audit-rules" ]] || left_by_rename "$CC_AUDIT_RULES_DEST"; }; then
  rm "$CC_AUDIT_RULES_DEST"
  echo "✓ Removed retired cc-audit rules link $CC_AUDIT_RULES_DEST"
  echo ""
fi

# Install bin/* helper commands as symlinks in ~/.local/bin/
# Explicit allowlist (not a glob) so ad-hoc analysis scripts in bin/
# (harvest.sh, session-*.sh, etc.) don't get installed as user commands.
# When adding a new user-facing command to bin/, add it here.
LOCAL_BIN="${LOCAL_BIN:-$HOME/.local/bin}"
mkdir -p "$LOCAL_BIN"
for cmd in claude-slot claude-tabs claude-search agent-search claude-pod claude-peer claude-src claude-spend work-context gt wt wt-new ticket-sort kaomoji pi-sync pr-state; do
  src="$REPO_DIR/bin/$cmd"
  dest="$LOCAL_BIN/$cmd"
  if [[ -f "$src" ]]; then
    if [[ -L "$dest" ]] || [[ -f "$dest" ]]; then
      rm "$dest"
    fi
    ln -s "$src" "$dest"
    echo "✓ Linked $cmd -> $LOCAL_BIN/"
  fi
done

# tab-status lives in tab-status/ (not bin/) but is a user-facing command used
# by the title hooks. Link it the same way so agent-rig owns
# ~/.local/bin/tab-status — historically this symlink pointed at a stale copy
# in the brain repo, so an existing (possibly cross-repo) symlink is replaced.
ts_src="$REPO_DIR/tab-status/tab-status"
ts_dest="$LOCAL_BIN/tab-status"
if [[ -f "$ts_src" ]]; then
  if [[ -L "$ts_dest" ]] || [[ -f "$ts_dest" ]]; then
    rm "$ts_dest"
  fi
  ln -s "$ts_src" "$ts_dest"
  echo "✓ Linked tab-status -> $LOCAL_BIN/"
fi

# Interpreter for `#!/usr/bin/env bash5` scripts (SIP rules out /usr/bin).
# Homebrew's bin/ path, not the versioned Cellar one, survives upgrades.
BASH5_CANDIDATES="${AGENT_RIG_BASH5_CANDIDATES:-/opt/homebrew/bin/bash /usr/local/bin/bash /bin/bash /usr/bin/bash}"
bash5_src=""
for candidate in $BASH5_CANDIDATES; do
  # shellcheck disable=SC2016
  if [[ -x "$candidate" ]] && (( $("$candidate" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null || echo 0) >= 5 )); then
    bash5_src="$candidate"
    break
  fi
done
if [[ -n "$bash5_src" ]]; then
  ln -sfn "$bash5_src" "$LOCAL_BIN/bash5"
  echo "✓ Linked bash5 -> $bash5_src"
else
  echo "⚠ no bash 5 found (tried: $BASH5_CANDIDATES) — bash5 scripts will not run."
  echo "  On macOS: brew install bash"
fi

# Prune links to commands since deleted from the repo. Dangling and pointing
# into this repo only: everything else in ~/.local/bin belongs to other tools.
for dest in "$LOCAL_BIN"/*; do
  if [[ -L "$dest" ]] && [[ ! -e "$dest" ]] && { [[ "$(readlink "$dest")" == "$REPO_DIR/"* ]] || left_by_rename "$dest"; }; then
    rm "$dest"
    echo "✓ Pruned dangling $(basename "$dest") -> $LOCAL_BIN/"
  fi
done
echo ""

# shell/rig.zsh holds the shell-side halves of `wt` and `new_wt`. Those can't
# live in bin/: a subprocess cannot cd its caller's shell, so bin/wt-new and
# bin/wt print a path and a sourced shell function does the cd.
#
# That file only takes effect if .zshrc sources it — and .zshrc is not ours.
# The installer owns its symlink set and nothing else, the same reason it
# doesn't write to ~/.zshrc for anything else. So: verify and instruct.
ZSHRC="${ZSHRC:-$HOME/.zshrc}"
RIG_ZSH_LINE="source $REPO_DIR/shell/rig.zsh"
# Comment lines don't count — a commented-out source line is not sourcing.
if [[ -f "$ZSHRC" ]] && grep -v '^[[:space:]]*#' "$ZSHRC" | grep -qF "$RIG_ZSH_LINE"; then
  echo "✓ .zshrc sources shell/rig.zsh"
else
  echo "⚠ .zshrc does not source shell/rig.zsh — wt and new_wt will not be defined."
  echo "  Add this to $ZSHRC (the installer will not edit it for you):"
  echo ""
  echo "      $RIG_ZSH_LINE"
fi
echo ""

echo "settings.json:"
cat "$SETTINGS_FILE"
