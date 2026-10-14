#!/usr/bin/env bats

# Test suite for install.sh
#
# Overrides CLAUDE_DIR to a temp directory so tests
# don't touch real ~/.claude/ settings. Each test gets a fresh dir.

INSTALLER="$BATS_TEST_DIRNAME/install.sh"

setup() {
  TEST_DIR="$(mktemp -d "$TMPDIR/install-test.XXXXXX")"
  export CLAUDE_DIR="$TEST_DIR/.claude"
  # Keep bin symlinks hermetic — otherwise the installer writes into the real
  # ~/.local/bin during tests.
  export LOCAL_BIN="$TEST_DIR/local-bin"
  # pi's own env var for its config dir. Unset by default here so the pi section
  # is a no-op unless a test opts in by creating the dir - the installer must not
  # invent ~/.pi on a machine that does not run pi.
  export PI_CODING_AGENT_DIR="$TEST_DIR/.pi/agent"
  # opencode's own env var for its config dir; the installer section is a
  # no-op unless a test opts in by creating the dir.
  export OPENCODE_CONFIG_DIR="$TEST_DIR/.config/opencode"
  # The tool-agnostic shared MCP config. pi's adapter hardcodes
  # ~/.config/mcp/mcp.json (it does not honour XDG_CONFIG_HOME), so the seam is
  # an explicit override rather than XDG.
  export AGENT_RIG_MCP_SHARED_CONFIG="$TEST_DIR/.config/mcp/mcp.json"
  export AGENT_SKILLS_DIR="$TEST_DIR/.agents/skills"
  export CODEX_SKILLS_DIR="$TEST_DIR/.codex/skills"
  # Tests seed and harvest into a copy: writing the repo's own .sup files
  # corrupts them when tests run in parallel.
  export AGENT_RIG_PERMISSIONS_DIR="$TEST_DIR/permissions"
  cp -R "$BATS_TEST_DIRNAME/permissions" "$AGENT_RIG_PERMISSIONS_DIR"
  mkdir -p "$CLAUDE_DIR"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# Run the installer, capturing output
run_installer() {
  run bash "$INSTALLER"
}

# Read a key from settings.json using super
settings_get() {
  super -f line -c "$1" "$CLAUDE_DIR/settings.json"
}

# ── Fresh install ──────────────────────────────────────────────────────────────

@test "fresh install: creates settings.json from scratch" {
  run_installer
  [ "$status" -eq 0 ]
  [ -f "$CLAUDE_DIR/settings.json" ]
}

@test "fresh install: statusLine is configured" {
  run_installer
  [ "$status" -eq 0 ]
  local type
  type=$(settings_get 'this.statusLine.type')
  [ "$type" = "command" ]
}

@test "fresh install: PreToolUse hook is configured" {
  run_installer
  [ "$status" -eq 0 ]
  local matcher
  matcher=$(settings_get 'this.hooks.PreToolUse[0].matcher')
  [ "$matcher" = "Bash" ]
}

@test "fresh install: SessionStart carries the drift and lemmalog hooks" {
  # SessionStart was retired once, then brought back by d220e69 for
  # internals-drift.sh. This suite asserted the retirement long after it
  # stopped being true; it now asserts what the installer actually writes.
  run_installer
  [ "$status" -eq 0 ]
  local count drift brief
  count=$(settings_get 'len(this.hooks.SessionStart)')
  [ "$count" -eq 2 ]
  drift=$(settings_get 'this.hooks.SessionStart[0].hooks[0].command')
  [[ "$drift" == *"internals-drift.sh"* ]] || false
  brief=$(settings_get 'this.hooks.SessionStart[1].hooks[0].command')
  [[ "$brief" == *"lemma-brief.sh"* ]]
}

@test "fresh install: all four event hooks are configured" {
  run_installer
  [ "$status" -eq 0 ]
  for event in UserPromptSubmit PermissionRequest PostToolUse Stop; do
    local count
    count=$(settings_get "count(this.hooks.$event)")
    [ "$count" -ge 1 ]
  done
}

@test "hooks: a user's own SessionStart entry is replaced by ours on re-install" {
  cat > "$CLAUDE_DIR/settings.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      {"matcher": "startup", "hooks": [{"type": "command", "command": "/old/ensure-sandbox.sh"}]}
    ]
  }
}
EOF
  run_installer
  [ "$status" -eq 0 ]
  # A named key after the ...this.hooks spread replaces that event's array
  # wholesale, so agent-rig owns SessionStart outright: the stale entry is
  # gone and both of ours are present.
  local count cmd matcher
  count=$(settings_get 'len(this.hooks.SessionStart)')
  [ "$count" -eq 2 ]
  cmd=$(settings_get 'this.hooks.SessionStart[0].hooks[0].command')
  [[ "$cmd" != *"/old/ensure-sandbox.sh"* ]] || false
  # And the rest of the settings survived the replacement.
  matcher=$(settings_get 'this.hooks.PreToolUse[0].matcher')
  [ "$matcher" = "Bash" ]
}

@test "hooks: user-managed hook event types are preserved" {
  cat > "$CLAUDE_DIR/settings.json" <<'EOF'
{
  "hooks": {
    "SubagentStop": [
      {"matcher": "", "hooks": [{"type": "command", "command": "/my/custom-hook.sh"}]}
    ]
  }
}
EOF
  run_installer
  [ "$status" -eq 0 ]
  local cmd
  cmd=$(settings_get 'this.hooks.SubagentStop[0].hooks[0].command')
  [ "$cmd" = "/my/custom-hook.sh" ]
  # And agent-rig's hooks are also installed alongside
  local matcher
  matcher=$(settings_get 'this.hooks.PreToolUse[0].matcher')
  [ "$matcher" = "Bash" ]
}

@test "fresh install: PostToolUse carries the lemmalog commit hook" {
  # Appended alongside the tab-status entry rather than replacing it: the
  # hook queues commits for later assertion into lemmalog.
  run_installer
  [ "$status" -eq 0 ]
  local count cmd matcher
  count=$(settings_get 'len(this.hooks.PostToolUse)')
  [ "$count" -eq 2 ]
  matcher=$(settings_get 'this.hooks.PostToolUse[1].matcher')
  [ "$matcher" = "Bash" ]
  cmd=$(settings_get 'this.hooks.PostToolUse[1].hooks[0].command')
  [[ "$cmd" == *"lemma-commit.sh"* ]]
}

@test "fresh install: the lemmalog commit hook has no if: prefilter" {
  # `if: "Bash(git commit *)"` would stop the hook spawning for non-matching
  # commands, but it is a prefix STRING match with no shell parsing, so it
  # misses `cd <repo> && git commit ...` -- the common shape here. The script
  # filters on tool_input.command instead.
  run_installer
  [ "$status" -eq 0 ]
  run settings_get 'this.hooks.PostToolUse[1].hooks[0].if'
  [ "$status" -ne 0 ] || [ "$output" = "error(\"missing\")" ]
}

@test "fresh install: Stop hook includes claude-tabs save" {
  run_installer
  [ "$status" -eq 0 ]
  local count cmd
  count=$(settings_get 'len(this.hooks.Stop)')
  [ "$count" -eq 2 ]
  cmd=$(settings_get 'this.hooks.Stop[1].hooks[0].command')
  [[ "$cmd" == *"claude-tabs save"* ]]
}

@test "fresh install: Stop hook resolves status via tab-status stop (bg-aware)" {
  run_installer
  [ "$status" -eq 0 ]
  local cmd
  cmd=$(settings_get 'this.hooks.Stop[0].hooks[0].command')
  [[ "$cmd" == *"tab-status --hook stop"* ]]
}

@test "fresh install: UserPromptSubmit engages (clears the bg reminder)" {
  run_installer
  [ "$status" -eq 0 ]
  local cmd
  cmd=$(settings_get 'this.hooks.UserPromptSubmit[0].hooks[0].command')
  [[ "$cmd" == *"tab-status --hook engage"* ]]
}

# ── Permissions merge ──────────────────────────────────────────────────────────

@test "permissions: allow.sup entries are merged" {
  run_installer
  [ "$status" -eq 0 ]
  local allows
  allows=$(settings_get 'this.permissions.allow')
  # Edit(), not Write() - Claude Code warns that Write() rules gate nothing,
  # so 13e56e7 dropped them from allow.sup as pure duplicates.
  [[ "$allows" == *"Edit(.claude/tmp/*)"* ]] || false
  [[ "$allows" == *"Edit(tmp/*)"* ]]
}

@test "permissions: existing allow rules are preserved" {
  cat > "$CLAUDE_DIR/settings.json" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(git add:*)"],
    "defaultMode": "default"
  }
}
EOF
  run_installer
  [ "$status" -eq 0 ]
  local allows
  allows=$(settings_get 'this.permissions.allow')
  [[ "$allows" == *"Bash(git add:*)"* ]] || false
  [[ "$allows" == *"Edit(.claude/tmp/*)"* ]]
}

@test "permissions: existing defaultMode is preserved" {
  cat > "$CLAUDE_DIR/settings.json" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(git add:*)"],
    "defaultMode": "default"
  }
}
EOF
  run_installer
  [ "$status" -eq 0 ]
  local mode
  mode=$(settings_get 'this.permissions.defaultMode')
  [ "$mode" = "default" ]
}

# ── Idempotency ────────────────────────────────────────────────────────────────

@test "idempotent: running twice produces same settings" {
  run_installer
  [ "$status" -eq 0 ]
  local first_run
  first_run=$(cat "$CLAUDE_DIR/settings.json")

  run_installer
  [ "$status" -eq 0 ]
  local second_run
  second_run=$(cat "$CLAUDE_DIR/settings.json")

  [ "$first_run" = "$second_run" ]
}

@test "idempotent: permissions not duplicated on re-run" {
  run_installer
  [ "$status" -eq 0 ]
  run_installer
  [ "$status" -eq 0 ]
  local count
  count=$(settings_get 'unnest this.permissions.allow | where this == "Edit(.claude/tmp/*)" | count()')
  [ "$count" -eq 1 ]
}

# ── Symlinks: skills ──────────────────────────────────────────────────────────

@test "skills: simplify is linked into the shared Agent Skills directory" {
  run_installer
  [ "$status" -eq 0 ]
  [ -L "$AGENT_SKILLS_DIR/simplify" ]
  [ "$(readlink "$AGENT_SKILLS_DIR/simplify")" = "$BATS_TEST_DIRNAME/skills/simplify" ]
  [ -f "$AGENT_SKILLS_DIR/simplify/SKILL.md" ]
  [ -L "$CODEX_SKILLS_DIR/simplify" ]
  [ "$(readlink "$CODEX_SKILLS_DIR/simplify")" = "$BATS_TEST_DIRNAME/skills/simplify" ]
}

@test "skills: simplify shared link is refreshed on re-install" {
  mkdir -p "$AGENT_SKILLS_DIR"
  ln -s "$BATS_TEST_DIRNAME/skills/deleted-skill" "$AGENT_SKILLS_DIR/simplify"
  run_installer
  [ "$status" -eq 0 ]
  [ -L "$AGENT_SKILLS_DIR/simplify" ]
  [ "$(readlink "$AGENT_SKILLS_DIR/simplify")" = "$BATS_TEST_DIRNAME/skills/simplify" ]
}

@test "skills: directory-based skills are symlinked" {
  run_installer
  [ "$status" -eq 0 ]
  # Check that at least one skill directory was installed
  local count
  count=$(find "$CLAUDE_DIR/skills" -maxdepth 1 -type l -not -name ".*" | wc -l | tr -d ' ')
  [ "$count" -gt 0 ]
}

@test "skills: symlinks point to repo source" {
  run_installer
  [ "$status" -eq 0 ]
  for link in "$CLAUDE_DIR/skills"/*/; do
    if [ -L "${link%/}" ]; then
      local target
      target=$(readlink "${link%/}")
      [[ "$target" == "$BATS_TEST_DIRNAME/skills/"* ]] || false
    fi
  done
}

@test "skills: stale bare-file symlinks are cleaned up" {
  mkdir -p "$CLAUDE_DIR/skills"
  # Simulate a stale goal-compose.md symlink from before restructuring
  ln -s "/some/old/path/goal-compose.md" "$CLAUDE_DIR/skills/goal-compose.md"
  run_installer
  [ "$status" -eq 0 ]
  # Stale .md symlink should be gone
  [ ! -e "$CLAUDE_DIR/skills/goal-compose.md" ]
  # Directory symlink should exist instead
  [ -L "$CLAUDE_DIR/skills/goal-compose" ]
}

@test "skills: dangling symlink for a deleted skill is pruned" {
  run_installer
  [ "$status" -eq 0 ]
  # Simulate a skill removed from the repo: a symlink in dest pointing into
  # SKILLS_SRC at a name that no longer has a source directory.
  ln -s "$BATS_TEST_DIRNAME/skills/deleted-skill/" "$CLAUDE_DIR/skills/deleted-skill"
  [ -L "$CLAUDE_DIR/skills/deleted-skill" ]
  run_installer
  [ "$status" -eq 0 ]
  # Prune should remove the orphaned symlink
  [ ! -L "$CLAUDE_DIR/skills/deleted-skill" ]
}

@test "skills: a user's broken symlink pointing outside the repo is left alone" {
  run_installer
  [ "$status" -eq 0 ]
  # A broken symlink the user created, pointing somewhere other than SKILLS_SRC.
  ln -s "/some/other/place/my-skill" "$CLAUDE_DIR/skills/my-skill"
  run_installer
  [ "$status" -eq 0 ]
  # Prune must only touch symlinks pointing into the repo skills dir.
  [ -L "$CLAUDE_DIR/skills/my-skill" ]
}

# ── Symlinks: agents ──────────────────────────────────────────────────────────

@test "agents: .md files are symlinked" {
  run_installer
  [ "$status" -eq 0 ]
  local count
  count=$(find "$CLAUDE_DIR/agents" -maxdepth 1 -name "*.md" -type l | wc -l | tr -d ' ')
  [ "$count" -gt 0 ]
}

@test "agents: symlinks point to repo source" {
  run_installer
  [ "$status" -eq 0 ]
  for link in "$CLAUDE_DIR/agents"/*.md; do
    if [ -L "$link" ]; then
      local target
      target=$(readlink "$link")
      [[ "$target" == "$BATS_TEST_DIRNAME/agents/"* ]] || false
    fi
  done
}

@test "pi agents: all repo agents are installed with Pi tool names" {
  mkdir -p "$PI_CODING_AGENT_DIR"
  run_installer
  [ "$status" -eq 0 ]
  for source in "$BATS_TEST_DIRNAME/agents"/*.md; do
    local dest="$PI_CODING_AGENT_DIR/agents/$(basename "$source")"
    [ -f "$dest" ]
    diff <(awk 'NR > 1 && /^---$/ { body=1; next } body' "$source") \
         <(awk 'NR > 1 && /^---$/ { body=1; next } body' "$dest")
  done
  grep -qx 'tools: read, grep, find' "$PI_CODING_AGENT_DIR/agents/bash-reviewer.md"
  grep -qx 'tools: read, edit, grep' "$PI_CODING_AGENT_DIR/agents/design-reviewer.md"
  grep -qx 'tools: read, grep, find, bash' "$PI_CODING_AGENT_DIR/agents/architecture-reviewer.md"
  grep -qx 'tools: read, grep, bash' "$PI_CODING_AGENT_DIR/agents/superdb-expert.md"
}

@test "pi agents: re-install refreshes definitions and preserves unrelated agents" {
  mkdir -p "$PI_CODING_AGENT_DIR/agents"
  printf 'old definition\n' > "$PI_CODING_AGENT_DIR/agents/bash-reviewer.md"
  printf 'my agent\n' > "$PI_CODING_AGENT_DIR/agents/custom.md"
  run_installer
  [ "$status" -eq 0 ]
  grep -qx 'name: bash-reviewer' "$PI_CODING_AGENT_DIR/agents/bash-reviewer.md"
  [ "$(< "$PI_CODING_AGENT_DIR/agents/custom.md")" = 'my agent' ]
  cp "$PI_CODING_AGENT_DIR/agents/bash-reviewer.md" "$TEST_DIR/first-agent.md"
  run_installer
  [ "$status" -eq 0 ]
  cmp "$TEST_DIR/first-agent.md" "$PI_CODING_AGENT_DIR/agents/bash-reviewer.md"
}

@test "pi agents: replacing a symlink does not modify its source" {
  mkdir -p "$PI_CODING_AGENT_DIR/agents"
  printf 'external agent\n' > "$TEST_DIR/external.md"
  ln -s "$TEST_DIR/external.md" "$PI_CODING_AGENT_DIR/agents/bash-reviewer.md"
  run_installer
  [ "$status" -eq 0 ]
  [ ! -L "$PI_CODING_AGENT_DIR/agents/bash-reviewer.md" ]
  grep -qx 'name: bash-reviewer' "$PI_CODING_AGENT_DIR/agents/bash-reviewer.md"
  [ "$(< "$TEST_DIR/external.md")" = 'external agent' ]
}

# ── OpenCode agents ──────────────────────────────────────────────────────────

@test "opencode agents: not installed unless opencode config dir exists" {
  run_installer
  [ "$status" -eq 0 ]
  [ ! -e "$OPENCODE_CONFIG_DIR" ]
}

@test "opencode agents: installed in opencode format when config dir exists" {
  mkdir -p "$OPENCODE_CONFIG_DIR"
  run_installer
  [ "$status" -eq 0 ]
  for source in "$BATS_TEST_DIRNAME/agents"/*.md; do
    local dest="$OPENCODE_CONFIG_DIR/agents/$(basename "$source")"
    [ -f "$dest" ]
    diff <(awk 'NR > 1 && /^---$/ { body = 1; next } body' "$source") \
         <(awk 'NR > 1 && /^---$/ { body = 1; next } body' "$dest")
  done

  ! grep -qx 'name: bash-reviewer' \
      <(awk '/^---$/ { fm = !fm; next } fm' "$OPENCODE_CONFIG_DIR/agents/bash-reviewer.md")
  grep -qx 'mode: subagent' "$OPENCODE_CONFIG_DIR/agents/bash-reviewer.md"

  grep -qx '  read: allow'    "$OPENCODE_CONFIG_DIR/agents/bash-reviewer.md"
  grep -qx '  grep: allow'    "$OPENCODE_CONFIG_DIR/agents/bash-reviewer.md"
  grep -qx '  glob: allow'    "$OPENCODE_CONFIG_DIR/agents/bash-reviewer.md"
  grep -qx '  bash: deny'     "$OPENCODE_CONFIG_DIR/agents/bash-reviewer.md"
  grep -qx '  edit: deny'     "$OPENCODE_CONFIG_DIR/agents/bash-reviewer.md"
  grep -qx '  webfetch: deny' "$OPENCODE_CONFIG_DIR/agents/bash-reviewer.md"
  grep -qx '  task: deny'     "$OPENCODE_CONFIG_DIR/agents/bash-reviewer.md"

  grep -qx '  webfetch: allow' "$OPENCODE_CONFIG_DIR/agents/architecture-reviewer.md"
  grep -qx '  bash: allow'     "$OPENCODE_CONFIG_DIR/agents/superdb-expert.md"
  grep -qx '  edit: allow'     "$OPENCODE_CONFIG_DIR/agents/design-reviewer.md"
}

@test "opencode agents: re-install refreshes definitions and preserves unrelated agents" {
  mkdir -p "$OPENCODE_CONFIG_DIR/agents"
  printf 'old definition\n' > "$OPENCODE_CONFIG_DIR/agents/bash-reviewer.md"
  printf 'my agent\n' > "$OPENCODE_CONFIG_DIR/agents/custom.md"
  run_installer
  [ "$status" -eq 0 ]
  grep -qx 'mode: subagent' "$OPENCODE_CONFIG_DIR/agents/bash-reviewer.md"
  [ "$(< "$OPENCODE_CONFIG_DIR/agents/custom.md")" = 'my agent' ]
  cp "$OPENCODE_CONFIG_DIR/agents/bash-reviewer.md" "$TEST_DIR/first-agent.md"
  run_installer
  [ "$status" -eq 0 ]
  cmp "$TEST_DIR/first-agent.md" "$OPENCODE_CONFIG_DIR/agents/bash-reviewer.md"
}

@test "opencode agents: replacing a symlink does not modify its source" {
  mkdir -p "$OPENCODE_CONFIG_DIR/agents"
  printf 'external agent\n' > "$TEST_DIR/external.md"
  ln -s "$TEST_DIR/external.md" "$OPENCODE_CONFIG_DIR/agents/bash-reviewer.md"
  run_installer
  [ "$status" -eq 0 ]
  [ ! -L "$OPENCODE_CONFIG_DIR/agents/bash-reviewer.md" ]
  grep -qx 'mode: subagent' "$OPENCODE_CONFIG_DIR/agents/bash-reviewer.md"
  [ "$(< "$TEST_DIR/external.md")" = 'external agent' ]
}

# ── Symlinks: rules ──────────────────────────────────────────────────────────

@test "rules: .md files are symlinked" {
  run_installer
  [ "$status" -eq 0 ]
  local count
  count=$(find "$CLAUDE_DIR/rules" -maxdepth 1 -name "*.md" -type l | wc -l | tr -d ' ')
  [ "$count" -gt 0 ]
}

# ── Symlinks: pi skills ─────────────────────────────────────────────────────
#
# pi discovers any directory containing a SKILL.md under its agent dir's skills/
# (docs/skills.md), so the skills in this repo can serve both harnesses from one
# source. Allowlisted, not globbed: most skills here instruct Claude-only tools
# (goal-compose's /goal, pod-peer's SendMessage, the lemma-* skills' lemmalog_*
# MCP tools) and would be dead weight or actively misleading inside pi.

@test "pi: skills are not installed when pi is not set up on this machine" {
  run_installer
  [ "$status" -eq 0 ]
  [ ! -d "$PI_CODING_AGENT_DIR" ]
}

@test "pi: harness-agnostic skills are symlinked into pi's skills dir" {
  mkdir -p "$PI_CODING_AGENT_DIR"
  run_installer
  [ "$status" -eq 0 ]
  [ -L "$PI_CODING_AGENT_DIR/skills/dialogue" ]
  local target
  target=$(readlink "$PI_CODING_AGENT_DIR/skills/dialogue")
  [[ "$target" == "$BATS_TEST_DIRNAME/skills/dialogue" ]] || false
  # simplify is pure code-style guidance - no tool names, no harness concepts.
  [ -L "$PI_CODING_AGENT_DIR/skills/simplify" ]
}

@test "pi: Claude-only skills are not symlinked into pi" {
  mkdir -p "$PI_CODING_AGENT_DIR"
  run_installer
  [ "$status" -eq 0 ]
  [ ! -e "$PI_CODING_AGENT_DIR/skills/goal-compose" ]
  [ ! -e "$PI_CODING_AGENT_DIR/skills/pod-peer" ]
  [ ! -e "$PI_CODING_AGENT_DIR/skills/lemma-drain" ]
}

@test "pi: a skill dropped from the allowlist is unlinked on the next install" {
  mkdir -p "$PI_CODING_AGENT_DIR/skills"
  ln -s "$BATS_TEST_DIRNAME/skills/lemma-drain" "$PI_CODING_AGENT_DIR/skills/lemma-drain"
  run_installer
  [ "$status" -eq 0 ]
  [ ! -e "$PI_CODING_AGENT_DIR/skills/lemma-drain" ]
}

@test "pi: a real directory with a colliding name is never clobbered" {
  # The allowlist names are ordinary skill names. If pi already has a real
  # skill directory called dialogue - chrismo's own, or one a pi package
  # shipped - replacing it with a symlink deletes their work silently. The
  # cleanup loop below already refuses to touch anything that is not our
  # symlink; the write path has to hold the same line.
  mkdir -p "$PI_CODING_AGENT_DIR/skills/dialogue"
  echo "theirs" > "$PI_CODING_AGENT_DIR/skills/dialogue/SKILL.md"
  run_installer
  [ "$status" -eq 0 ]
  [ -f "$PI_CODING_AGENT_DIR/skills/dialogue/SKILL.md" ]
  grep -q theirs "$PI_CODING_AGENT_DIR/skills/dialogue/SKILL.md"
  [[ "$output" == *"dialogue"* ]] || false
}

@test "pi: a symlink pointing somewhere else is never replaced" {
  mkdir -p "$PI_CODING_AGENT_DIR/skills"
  ln -s "/some/other/repo/skills/dialogue" "$PI_CODING_AGENT_DIR/skills/dialogue"
  run_installer
  [ "$status" -eq 0 ]
  [ "$(readlink "$PI_CODING_AGENT_DIR/skills/dialogue")" = "/some/other/repo/skills/dialogue" ]
}

@test "pi: skills from other sources are left alone" {
  mkdir -p "$PI_CODING_AGENT_DIR/skills/somebody-elses"
  echo "---" > "$PI_CODING_AGENT_DIR/skills/somebody-elses/SKILL.md"
  ln -s "/some/other/repo/skills/theirs" "$PI_CODING_AGENT_DIR/skills/theirs"
  run_installer
  [ "$status" -eq 0 ]
  [ -f "$PI_CODING_AGENT_DIR/skills/somebody-elses/SKILL.md" ]
  [ -L "$PI_CODING_AGENT_DIR/skills/theirs" ]
}

@test "pi: re-running the installer is idempotent" {
  mkdir -p "$PI_CODING_AGENT_DIR"
  run_installer
  [ "$status" -eq 0 ]
  run_installer
  [ "$status" -eq 0 ]
  [ -L "$PI_CODING_AGENT_DIR/skills/dialogue" ]
}

@test "pi: personal footer extension is linked only when pi is set up" {
  run_installer
  [ "$status" -eq 0 ]
  [ ! -e "$PI_CODING_AGENT_DIR/extensions/personal-footer.ts" ]
  mkdir -p "$PI_CODING_AGENT_DIR"
  run_installer
  [ "$status" -eq 0 ]
  [ -L "$PI_CODING_AGENT_DIR/extensions/personal-footer.ts" ]
  [ "$(readlink "$PI_CODING_AGENT_DIR/extensions/personal-footer.ts")" = "$BATS_TEST_DIRNAME/pi/extensions/personal-footer.ts" ]
}

@test "pi: personal footer does not overwrite an unrelated extension" {
  mkdir -p "$PI_CODING_AGENT_DIR/extensions"
  echo 'mine' > "$PI_CODING_AGENT_DIR/extensions/personal-footer.ts"
  run_installer
  [ "$status" -eq 0 ]
  [ "$(< "$PI_CODING_AGENT_DIR/extensions/personal-footer.ts")" = 'mine' ]
}

# ── Migration from the claude-rig checkout path ─────────────────────────────

OLD_CHECKOUT() { echo "$TEST_DIR/old/claude-rig"; }

@test "migration: dangling pi skill link into the old checkout is replaced" {
  mkdir -p "$PI_CODING_AGENT_DIR/skills"
  ln -s "$(OLD_CHECKOUT)/skills/dialogue" "$PI_CODING_AGENT_DIR/skills/dialogue"
  run_installer
  [ "$status" -eq 0 ]
  [ "$(readlink "$PI_CODING_AGENT_DIR/skills/dialogue")" = "$BATS_TEST_DIRNAME/skills/dialogue" ]
}

@test "migration: dangling pi link for a dropped skill is retired" {
  mkdir -p "$PI_CODING_AGENT_DIR/skills"
  ln -s "$(OLD_CHECKOUT)/skills/lemma-drain" "$PI_CODING_AGENT_DIR/skills/lemma-drain"
  run_installer
  [ "$status" -eq 0 ]
  [ ! -L "$PI_CODING_AGENT_DIR/skills/lemma-drain" ]
}

@test "migration: dangling simplify links into the old checkout are replaced" {
  mkdir -p "$AGENT_SKILLS_DIR" "$CODEX_SKILLS_DIR"
  ln -s "$(OLD_CHECKOUT)/skills/simplify" "$AGENT_SKILLS_DIR/simplify"
  ln -s "$(OLD_CHECKOUT)/skills/simplify" "$CODEX_SKILLS_DIR/simplify"
  run_installer
  [ "$status" -eq 0 ]
  [ "$(readlink "$AGENT_SKILLS_DIR/simplify")" = "$BATS_TEST_DIRNAME/skills/simplify" ]
  [ "$(readlink "$CODEX_SKILLS_DIR/simplify")" = "$BATS_TEST_DIRNAME/skills/simplify" ]
}

@test "migration: dangling pi footer link into the old checkout is replaced" {
  mkdir -p "$PI_CODING_AGENT_DIR/extensions"
  ln -s "$(OLD_CHECKOUT)/pi/extensions/personal-footer.ts" "$PI_CODING_AGENT_DIR/extensions/personal-footer.ts"
  run_installer
  [ "$status" -eq 0 ]
  [ "$(readlink "$PI_CODING_AGENT_DIR/extensions/personal-footer.ts")" = "$BATS_TEST_DIRNAME/pi/extensions/personal-footer.ts" ]
}

@test "migration: dangling Claude skill link for a skill deleted since the move is pruned" {
  mkdir -p "$CLAUDE_DIR/skills"
  ln -s "$(OLD_CHECKOUT)/skills/deleted-skill/" "$CLAUDE_DIR/skills/deleted-skill"
  run_installer
  [ "$status" -eq 0 ]
  [ ! -L "$CLAUDE_DIR/skills/deleted-skill" ]
}

@test "migration: a live link into a claude-rig checkout that still exists is left alone" {
  mkdir -p "$(OLD_CHECKOUT)/skills/dialogue" "$PI_CODING_AGENT_DIR/skills"
  ln -s "$(OLD_CHECKOUT)/skills/dialogue" "$PI_CODING_AGENT_DIR/skills/dialogue"
  run_installer
  [ "$status" -eq 0 ]
  [ "$(readlink "$PI_CODING_AGENT_DIR/skills/dialogue")" = "$(OLD_CHECKOUT)/skills/dialogue" ]
}

@test "migration: a dangling link into some other repo is still left alone" {
  mkdir -p "$PI_CODING_AGENT_DIR/skills"
  ln -s "$TEST_DIR/elsewhere/skills/dialogue" "$PI_CODING_AGENT_DIR/skills/dialogue"
  run_installer
  [ "$status" -eq 0 ]
  [ "$(readlink "$PI_CODING_AGENT_DIR/skills/dialogue")" = "$TEST_DIR/elsewhere/skills/dialogue" ]
}

# ── Shared MCP config ───────────────────────────────────────────────────────
#
# pi has no native MCP; pi-mcp-adapter supplies it and reads
# ~/.config/mcp/mcp.json as the lowest-precedence shared source, so a config
# tracked here is a default every pi-owned file can still override.
#
# Only portable servers belong in it. The adapter interpolates ${VAR} in args and
# env values but takes `command` literally, so a server whose command is a
# per-machine build path (lemmalog) cannot be expressed portably and stays out.

@test "mcp: the shared config is not created when pi is not set up" {
  run_installer
  [ "$status" -eq 0 ]
  [ ! -e "$AGENT_RIG_MCP_SHARED_CONFIG" ]
}

@test "mcp: the shared config is symlinked to the repo's copy" {
  mkdir -p "$PI_CODING_AGENT_DIR"
  run_installer
  [ "$status" -eq 0 ]
  [ -L "$AGENT_RIG_MCP_SHARED_CONFIG" ]
  local target
  target=$(readlink "$AGENT_RIG_MCP_SHARED_CONFIG")
  [[ "$target" == "$BATS_TEST_DIRNAME/pi/mcp.json" ]]
}

@test "mcp: a real config file is never clobbered, only reported" {
  mkdir -p "$PI_CODING_AGENT_DIR" "$(dirname "$AGENT_RIG_MCP_SHARED_CONFIG")"
  echo '{"mcpServers":{"theirs":{"command":"foo"}}}' > "$AGENT_RIG_MCP_SHARED_CONFIG"
  run_installer
  [ "$status" -eq 0 ]
  [ ! -L "$AGENT_RIG_MCP_SHARED_CONFIG" ]
  grep -q "theirs" "$AGENT_RIG_MCP_SHARED_CONFIG"
  [[ "$output" == *"$AGENT_RIG_MCP_SHARED_CONFIG"* ]]
}

@test "mcp: re-running the installer keeps the symlink" {
  mkdir -p "$PI_CODING_AGENT_DIR"
  run_installer
  run_installer
  [ "$status" -eq 0 ]
  [ -L "$AGENT_RIG_MCP_SHARED_CONFIG" ]
}

@test "mcp: the tracked config parses and declares servers" {
  run super -f line -c 'values flatten(this.mcpServers) | unnest this | values key[0]' "$BATS_TEST_DIRNAME/pi/mcp.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"superdb"* ]]
}

# ── Symlinks: bin commands ──────────────────────────────────────────────────

@test "bin: claude-tabs is symlinked from bin/" {
  run_installer
  [ "$status" -eq 0 ]
  [ -L "$LOCAL_BIN/claude-tabs" ]
  local target
  target=$(readlink "$LOCAL_BIN/claude-tabs")
  [[ "$target" == "$BATS_TEST_DIRNAME/bin/claude-tabs" ]]
}

@test "bin: ticket-sort is symlinked from bin/" {
  run_installer
  [ "$status" -eq 0 ]
  [ -L "$LOCAL_BIN/ticket-sort" ]
  local target
  target=$(readlink "$LOCAL_BIN/ticket-sort")
  [[ "$target" == "$BATS_TEST_DIRNAME/bin/ticket-sort" ]]
}

@test "bin: pi-sync is symlinked from bin/" {
  run_installer
  [ "$status" -eq 0 ]
  [ -L "$LOCAL_BIN/pi-sync" ]
  local target
  target=$(readlink "$LOCAL_BIN/pi-sync")
  [[ "$target" == "$BATS_TEST_DIRNAME/bin/pi-sync" ]]
}

@test "bin: claude-src is symlinked from bin/" {
  run_installer
  [ "$status" -eq 0 ]
  [ -L "$LOCAL_BIN/claude-src" ]
  local target
  target=$(readlink "$LOCAL_BIN/claude-src")
  [[ "$target" == "$BATS_TEST_DIRNAME/bin/claude-src" ]]
}

# pr-tend moved to its own repo (2026-10-13); its ./install.sh links these now.
@test "bin: pr-* links from an earlier install are removed" {
  mkdir -p "$LOCAL_BIN"
  local cmd
  for cmd in pr-state pr-act pr-watch pr-config; do
    ln -s "$BATS_TEST_DIRNAME/bin/$cmd" "$LOCAL_BIN/$cmd"
  done
  run_installer
  [ "$status" -eq 0 ]
  for cmd in pr-state pr-act pr-watch pr-config; do
    [ ! -L "$LOCAL_BIN/$cmd" ]
  done
}

@test "bin: analysis scripts in bin/ are not installed as commands" {
  # The install list is an allowlist for exactly this reason - adding a
  # user-facing command means adding it there, and a new .sh left in bin/
  # must not silently become a user command.
  run_installer
  [ "$status" -eq 0 ]
  [ ! -e "$LOCAL_BIN/harvest.sh" ]
  [ ! -e "$LOCAL_BIN/ticket-sort.bats" ]
  [ ! -e "$LOCAL_BIN/wt-new.bats" ]
}

@test "bin: wt-new is symlinked from bin/" {
  run_installer
  [ "$status" -eq 0 ]
  [ -L "$LOCAL_BIN/wt-new" ]
  local target
  target=$(readlink "$LOCAL_BIN/wt-new")
  [[ "$target" == "$BATS_TEST_DIRNAME/bin/wt-new" ]]
}

@test "bin: wt is symlinked from bin/" {
  run_installer
  [ "$status" -eq 0 ]
  [ -L "$LOCAL_BIN/wt" ]
  local target
  target=$(readlink "$LOCAL_BIN/wt")
  [[ "$target" == "$BATS_TEST_DIRNAME/bin/wt" ]]
}

@test "bin: tab-status is symlinked from tab-status/" {
  run_installer
  [ "$status" -eq 0 ]
  [ -L "$LOCAL_BIN/tab-status" ]
  local target
  target=$(readlink "$LOCAL_BIN/tab-status")
  [[ "$target" == "$BATS_TEST_DIRNAME/tab-status/tab-status" ]]
}

@test "bin: a stale tab-status symlink (e.g. to another repo) is replaced" {
  # Models the brain takeover: an existing symlink pointing elsewhere must be
  # repointed at agent-rig's copy.
  mkdir -p "$LOCAL_BIN"
  ln -s "/some/other/repo/xdg/.local/bin/tab-status" "$LOCAL_BIN/tab-status"
  run_installer
  [ "$status" -eq 0 ]
  local target
  target=$(readlink "$LOCAL_BIN/tab-status")
  [[ "$target" == "$BATS_TEST_DIRNAME/tab-status/tab-status" ]]
}

@test "bin: dangling link for a command deleted from the repo is pruned" {
  mkdir -p "$LOCAL_BIN"
  ln -s "$BATS_TEST_DIRNAME/bin/deleted-command.sh" "$LOCAL_BIN/deleted-command"
  run_installer
  [ "$status" -eq 0 ]
  [ ! -L "$LOCAL_BIN/deleted-command" ]
}

@test "bin: dangling link into the old claude-rig checkout is pruned" {
  mkdir -p "$LOCAL_BIN"
  ln -s "$(OLD_CHECKOUT)/skills/permission-mode.sh" "$LOCAL_BIN/permission-mode"
  run_installer
  [ "$status" -eq 0 ]
  [ ! -L "$LOCAL_BIN/permission-mode" ]
}

@test "bin: a dangling link into another repo is left alone" {
  mkdir -p "$LOCAL_BIN"
  ln -s "/some/other/repo/bin/theirs" "$LOCAL_BIN/theirs"
  run_installer
  [ "$status" -eq 0 ]
  [ -L "$LOCAL_BIN/theirs" ]
}

@test "bin: a live link into the repo that is not on the allowlist is left alone" {
  mkdir -p "$LOCAL_BIN"
  ln -s "$BATS_TEST_DIRNAME/bin/harvest.sh" "$LOCAL_BIN/harvest"
  run_installer
  [ "$status" -eq 0 ]
  [ -L "$LOCAL_BIN/harvest" ]
}

# ── bash5: the interpreter for `#!/usr/bin/env bash5` scripts ───────────────

# A stand-in bash that reports major version $1 to the installer's probe.
fake_bash() {
  mkdir -p "$TEST_DIR/fake"
  printf '#!/bin/sh\necho %s\n' "$2" > "$TEST_DIR/fake/$1"
  chmod +x "$TEST_DIR/fake/$1"
  echo "$TEST_DIR/fake/$1"
}

@test "bash5: linked to the first candidate that is bash 5+" {
  local old new newer
  old=$(fake_bash old 3)
  new=$(fake_bash new 5)
  newer=$(fake_bash newer 6)
  export AGENT_RIG_BASH5_CANDIDATES="$TEST_DIR/fake/missing $old $new $newer"
  run_installer
  [ "$status" -eq 0 ]
  [ -L "$LOCAL_BIN/bash5" ]
  [[ "$(readlink "$LOCAL_BIN/bash5")" == "$new" ]]
}

@test "bash5: no bash 5 found warns, links nothing, and the install still succeeds" {
  local old
  old=$(fake_bash old 3)
  export AGENT_RIG_BASH5_CANDIDATES="$old"
  run_installer
  [ "$status" -eq 0 ]
  [ ! -e "$LOCAL_BIN/bash5" ]
  [[ "$output" == *"no bash 5"* ]]
}

@test "bash5: an existing link is repointed on re-install" {
  local new
  new=$(fake_bash new 5)
  mkdir -p "$LOCAL_BIN"
  ln -s "/old/homebrew/bin/bash" "$LOCAL_BIN/bash5"
  export AGENT_RIG_BASH5_CANDIDATES="$new"
  run_installer
  [ "$status" -eq 0 ]
  [[ "$(readlink "$LOCAL_BIN/bash5")" == "$new" ]]
}

@test "bash5: default candidates find a real bash 5 that runs" {
  # No override: whatever this machine has. Skips where there is no bash 5.
  run_installer
  [ "$status" -eq 0 ]
  [ -L "$LOCAL_BIN/bash5" ] || skip "no bash 5 on this machine"
  run "$LOCAL_BIN/bash5" -c 'echo ${BASH_VERSINFO[0]}'
  [ "$output" -ge 5 ]
}

# ── shell/rig.zsh entrypoint ────────────────────────────────────────────────
# shell/rig.zsh holds the cd-wrappers for wt-new and wt (a subprocess cannot cd
# its caller's shell, so those halves have to live in a sourced file). It only
# takes effect if .zshrc sources it — but .zshrc is not in the installer's
# symlink set and the installer does not own files outside that set. So it
# VERIFIES and instructs; it must never edit .zshrc itself.

@test "zshrc: instructs the user when the rig.zsh source line is missing" {
  export ZSHRC="$TEST_DIR/zshrc"
  printf 'export PATH=/usr/bin\n' > "$ZSHRC"
  run_installer
  [ "$status" -eq 0 ]
  [[ "$output" == *"shell/rig.zsh"* ]] || false
  [[ "$output" == *"source"* ]]
}

@test "zshrc: does not modify .zshrc when the source line is missing" {
  export ZSHRC="$TEST_DIR/zshrc"
  printf 'export PATH=/usr/bin\n' > "$ZSHRC"
  local before
  before=$(cat "$ZSHRC")
  run_installer
  [ "$status" -eq 0 ]
  [ "$(cat "$ZSHRC")" = "$before" ]
}

@test "zshrc: does not create .zshrc when it does not exist" {
  export ZSHRC="$TEST_DIR/no-such-zshrc"
  run_installer
  [ "$status" -eq 0 ]
  [ ! -e "$ZSHRC" ]
  [[ "$output" == *"shell/rig.zsh"* ]]
}

@test "zshrc: confirms when the source line is already present" {
  export ZSHRC="$TEST_DIR/zshrc"
  printf 'source %s/shell/rig.zsh\n' "$BATS_TEST_DIRNAME" > "$ZSHRC"
  run_installer
  [ "$status" -eq 0 ]
  [[ "$output" == *"rig.zsh"* ]] || false
  [[ "$output" != *"Add this to"* ]]
}

@test "zshrc: a commented-out source line does not count as present" {
  export ZSHRC="$TEST_DIR/zshrc"
  printf '# source %s/shell/rig.zsh\n' "$BATS_TEST_DIRNAME" > "$ZSHRC"
  run_installer
  [ "$status" -eq 0 ]
  [[ "$output" == *"Add this to"* ]]
}

# ── Backup ─────────────────────────────────────────────────────────────────────

@test "backup: creates timestamped backup of settings.json" {
  echo '{"existing": true}' > "$CLAUDE_DIR/settings.json"
  run_installer
  [ "$status" -eq 0 ]
  local count
  count=$(find "$CLAUDE_DIR" -name "settings-bak-*.json" | wc -l | tr -d ' ')
  [ "$count" -ge 1 ]
}

# ── Existing user settings ────────────────────────────────────────────────────

@test "permissions: deny.sup entries are merged when non-empty" {
  echo '"Bash(rm -rf:*)"' > "$AGENT_RIG_PERMISSIONS_DIR/deny.sup"
  run_installer
  [ "$status" -eq 0 ]
  local denys
  denys=$(settings_get 'this.permissions.deny')
  [[ "$denys" == *"Bash(rm -rf:*)"* ]]
}

@test "permissions: empty deny.sup does not add deny key" {
  run_installer
  [ "$status" -eq 0 ]
  # deny key should not exist since deny.sup is empty
  run settings_get 'this.permissions.deny'
  [ "$status" -ne 0 ] || [ -z "$output" ]
}

@test "permissions: existing deny rules are preserved" {
  cat > "$CLAUDE_DIR/settings.json" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(git add:*)"],
    "deny": ["Bash(sudo:*)"],
    "defaultMode": "default"
  }
}
EOF
  echo '"Bash(rm -rf:*)"' > "$AGENT_RIG_PERMISSIONS_DIR/deny.sup"
  run_installer
  [ "$status" -eq 0 ]
  local denys
  denys=$(settings_get 'this.permissions.deny')
  [[ "$denys" == *"Bash(sudo:*)"* ]] || false
  [[ "$denys" == *"Bash(rm -rf:*)"* ]]
}

# ── cc-audit rules (retired) ─────────────────────────────────────────────────

@test "cc-audit: rules link from an earlier install is removed" {
  export CC_AUDIT_DIR="$TEST_DIR/.cc-audit"
  mkdir -p "$CC_AUDIT_DIR"
  ln -s "$BATS_TEST_DIRNAME/cc-audit-rules" "$CC_AUDIT_DIR/rules"
  run_installer
  [ "$status" -eq 0 ]
  [ ! -L "$CC_AUDIT_DIR/rules" ]
}

@test "cc-audit: rules link into the old claude-rig checkout is removed" {
  export CC_AUDIT_DIR="$TEST_DIR/.cc-audit"
  mkdir -p "$CC_AUDIT_DIR"
  ln -s "$(OLD_CHECKOUT)/cc-audit-rules" "$CC_AUDIT_DIR/rules"
  run_installer
  [ "$status" -eq 0 ]
  [ ! -L "$CC_AUDIT_DIR/rules" ]
}

@test "cc-audit: a rules directory that is not our link is left alone" {
  export CC_AUDIT_DIR="$TEST_DIR/.cc-audit"
  mkdir -p "$CC_AUDIT_DIR/rules"
  echo '{"safe":[]}' > "$CC_AUDIT_DIR/rules/mine.json"
  run_installer
  [ "$status" -eq 0 ]
  [ -f "$CC_AUDIT_DIR/rules/mine.json" ]
}

# ── Sandbox allowWrite merge ──────────────────────────────────────────────────

@test "sandbox: allowWrite paths are merged" {
  run_installer
  [ "$status" -eq 0 ]
  local paths
  paths=$(settings_get 'join(this.sandbox.filesystem.allowWrite, ",")')
  [[ "$paths" == *"~/.claude/logs"* ]] || false
  [[ "$paths" == *"~/.claude/contexts"* ]]
}

@test "sandbox: existing allowWrite paths are preserved" {
  cat > "$CLAUDE_DIR/settings.json" <<'EOF'
{
  "sandbox": {
    "filesystem": {
      "allowWrite": ["~/.custom/path"]
    }
  }
}
EOF
  run_installer
  [ "$status" -eq 0 ]
  local paths
  paths=$(settings_get 'join(this.sandbox.filesystem.allowWrite, ",")')
  [[ "$paths" == *"~/.custom/path"* ]] || false
  [[ "$paths" == *"~/.claude/logs"* ]]
}

@test "sandbox: allowWrite not duplicated on re-run" {
  run_installer
  [ "$status" -eq 0 ]
  run_installer
  [ "$status" -eq 0 ]
  local count
  count=$(settings_get 'unnest this.sandbox.filesystem.allowWrite | where this == "~/.claude/logs" | count()')
  [ "$count" -eq 1 ]
}

# ── Env vars ──────────────────────────────────────────────────────────────────

@test "env: fresh install does not set CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" {
  run_installer
  [ "$status" -eq 0 ]
  ! grep -q 'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' "$CLAUDE_DIR/settings.json"
}

# Removed, not merely left unmanaged: the var still changes when Claude Code
# auto-compacts, so a value left behind in settings.json would go on acting on
# every machine that ever ran the old installer.
@test "env: an existing CLAUDE_AUTOCOMPACT_PCT_OVERRIDE is removed" {
  cat > "$CLAUDE_DIR/settings.json" <<'EOF'
{
  "env": {
    "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "64"
  }
}
EOF
  run_installer
  [ "$status" -eq 0 ]
  ! grep -q 'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' "$CLAUDE_DIR/settings.json"
}

@test "env: unrelated env keys are preserved" {
  cat > "$CLAUDE_DIR/settings.json" <<'EOF'
{
  "env": {
    "CLAUDE_CODE_DISABLE_TERMINAL_TITLE": "1",
    "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "64"
  }
}
EOF
  run_installer
  [ "$status" -eq 0 ]
  local val
  val=$(settings_get 'this.env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE')
  [ "$val" = "1" ]
}


# ── Existing user settings ────────────────────────────────────────────────────

@test "existing settings: non-installer keys are preserved" {
  cat > "$CLAUDE_DIR/settings.json" <<'EOF'
{
  "spinnerVerbs": {"mode": "replace", "verbs": ["Jamming"]},
  "alwaysThinkingEnabled": true
}
EOF
  run_installer
  [ "$status" -eq 0 ]
  local thinking
  thinking=$(settings_get 'this.alwaysThinkingEnabled')
  [ "$thinking" = "true" ]
  local verb
  verb=$(settings_get 'this.spinnerVerbs.verbs[0]')
  [ "$verb" = "Jamming" ]
}

# ── Harvest ──────────────────────────────────────────────────────────────────

HARVESTER="$BATS_TEST_DIRNAME/bin/harvest.sh"

@test "harvest: writes into AGENT_RIG_PERMISSIONS_DIR, not the repo" {
  cp "$BATS_TEST_DIRNAME/permissions/allow.sup" "$TEST_DIR/repo-allow.sup"
  echo '{"permissions": {"allow": ["Bash(only-in-test:*)"]}}' > "$CLAUDE_DIR/settings.json"
  run bash "$HARVESTER"
  [ "$status" -eq 0 ]
  grep -qF 'Bash(only-in-test:*)' "$AGENT_RIG_PERMISSIONS_DIR/allow.sup"
  cmp "$BATS_TEST_DIRNAME/permissions/allow.sup" "$TEST_DIR/repo-allow.sup"
}

@test "harvest: extracts allow rules from settings.json" {
  # Start with empty allow.sup so count is predictable
  : > "$AGENT_RIG_PERMISSIONS_DIR/allow.sup"
  cat > "$CLAUDE_DIR/settings.json" <<'EOF'
{
  "permissions": {
    "allow": ["Write(.claude/tmp/*)", "Bash(git add:*)", "Edit(.claude/tmp/*)"]
  }
}
EOF
  run bash "$HARVESTER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"3 allow rules"* ]]
}

@test "harvest: extracts deny rules from settings.json" {
  cat > "$CLAUDE_DIR/settings.json" <<'EOF'
{
  "permissions": {
    "allow": ["Write(.claude/tmp/*)"],
    "deny": ["Bash(sudo:*)", "Bash(rm -rf:*)"]
  }
}
EOF
  run bash "$HARVESTER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 deny rules"* ]]
}

@test "harvest: dry-run does not modify files" {
  cp "$AGENT_RIG_PERMISSIONS_DIR/allow.sup" "$TEST_DIR/allow.sup.orig"
  cat > "$CLAUDE_DIR/settings.json" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(git add:*)", "Write(.claude/tmp/*)"]
  }
}
EOF
  run bash "$HARVESTER" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"=== permissions/allow.sup"* ]] || false
  # File should be unchanged
  diff "$AGENT_RIG_PERMISSIONS_DIR/allow.sup" "$TEST_DIR/allow.sup.orig"
}

@test "harvest: handles missing deny gracefully" {
  cat > "$CLAUDE_DIR/settings.json" <<'EOF'
{
  "permissions": {
    "allow": ["Write(.claude/tmp/*)"]
  }
}
EOF
  run bash "$HARVESTER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No deny rules"* ]]
}

@test "harvest: merges with existing allow.sup entries" {
  # Seed allow.sup with an entry NOT in settings.json
  echo '"Bash(launchctl load:*)"' > "$AGENT_RIG_PERMISSIONS_DIR/allow.sup"
  cat > "$CLAUDE_DIR/settings.json" <<'EOF'
{
  "permissions": {
    "allow": ["Write(.claude/tmp/*)"]
  }
}
EOF
  run bash "$HARVESTER"
  local result
  result=$(cat "$AGENT_RIG_PERMISSIONS_DIR/allow.sup")
  [ "$status" -eq 0 ]
  # Both the existing entry and the harvested entry should be present
  [[ "$result" == *'"Bash(launchctl load:*)"'* ]] || false
  [[ "$result" == *'"Write(.claude/tmp/*)"'* ]]
}

@test "harvest: merges with existing deny.sup entries" {
  # Seed deny.sup with an entry NOT in settings.json
  echo '"Bash(sudo:*)"' > "$AGENT_RIG_PERMISSIONS_DIR/deny.sup"
  cat > "$CLAUDE_DIR/settings.json" <<'EOF'
{
  "permissions": {
    "deny": ["Bash(rm -rf:*)"]
  }
}
EOF
  run bash "$HARVESTER"
  local result
  result=$(cat "$AGENT_RIG_PERMISSIONS_DIR/deny.sup")
  [ "$status" -eq 0 ]
  [[ "$result" == *'"Bash(sudo:*)"'* ]] || false
  [[ "$result" == *'"Bash(rm -rf:*)"'* ]]
}

@test "harvest: deduplicates entries" {
  # Seed allow.sup with an entry that's also in settings.json
  echo '"Write(.claude/tmp/*)"' > "$AGENT_RIG_PERMISSIONS_DIR/allow.sup"
  cat > "$CLAUDE_DIR/settings.json" <<'EOF'
{
  "permissions": {
    "allow": ["Write(.claude/tmp/*)", "Bash(git add:*)"]
  }
}
EOF
  run bash "$HARVESTER"
  local result
  result=$(cat "$AGENT_RIG_PERMISSIONS_DIR/allow.sup")
  [ "$status" -eq 0 ]
  # Write(.claude/tmp/*) should appear exactly once
  local count
  count=$(echo "$result" | grep -c 'Write(.claude/tmp/\*)')
  [ "$count" -eq 1 ]
}
