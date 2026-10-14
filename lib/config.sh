#!/usr/bin/env bash

# Shared config for agent-rig scripts
# Source this file: source "$(dirname "$0")/../lib/config.sh"

# Resolve REPO_DIR from this file's location (lib/ is one level under repo root)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"

PERMISSIONS_DIR="${AGENT_RIG_PERMISSIONS_DIR:-$REPO_DIR/permissions}"
PERMISSIONS_ALLOW="$PERMISSIONS_DIR/allow.sup"
PERMISSIONS_DENY="$PERMISSIONS_DIR/deny.sup"
PERMISSIONS_RETIRED="$PERMISSIONS_DIR/retired.sup"

SANDBOX_ALLOW_WRITE="$REPO_DIR/sandbox/allow-write.sup"

CC_AUDIT_RULES_DEST="${CC_AUDIT_DIR:-$HOME/.cc-audit}/rules"

STATUSLINE_SCRIPT="$REPO_DIR/statusline/statusline-command.sh"
DEDICATED_TOOLS_HOOK="$REPO_DIR/hooks/use-dedicated-tools.sh"
INTERNALS_DRIFT_HOOK="$REPO_DIR/hooks/internals-drift.sh"
LEMMA_COMMIT_HOOK="$REPO_DIR/hooks/lemma-commit.sh"
LEMMA_BRIEF_HOOK="$REPO_DIR/hooks/lemma-brief.sh"

SKILLS_SRC="$REPO_DIR/skills"
AGENTS_SRC="$REPO_DIR/agents"
SKILLS_DEST="$CLAUDE_DIR/skills"
AGENT_SKILLS_DEST="${AGENT_SKILLS_DIR:-$HOME/.agents/skills}"
CODEX_SKILLS_DEST="${CODEX_SKILLS_DIR:-$HOME/.codex/skills}"
AGENTS_DEST="$CLAUDE_DIR/agents"
RULES_SRC="$REPO_DIR/rules"
RULES_DEST="$CLAUDE_DIR/rules"

# pi (@earendil-works/pi-coding-agent) discovers skills under its own agent dir.
# PI_CODING_AGENT_DIR is pi's variable, not ours — a machine that relocates pi's
# config for pi relocates it here too, for free.
PI_AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
PI_SKILLS_DEST="$PI_AGENT_DIR/skills"
PI_AGENTS_DEST="$PI_AGENT_DIR/agents"

# OpenCode discovers markdown agents only under its own config dir (docs/
# agents.md) — it does not read Claude's ~/.claude/agents, so install.sh
# transforms the repo agents into OpenCode format rather than symlinking.
# OPENCODE_CONFIG_DIR is OpenCode's own env var — a machine that relocates
# opencode's config for opencode relocates this install too, for free.
OPENCODE_CONFIG_DIR="${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}"
OPENCODE_AGENTS_DEST="$OPENCODE_CONFIG_DIR/agents"

# The tool-agnostic shared MCP config. pi-mcp-adapter hardcodes
# ~/.config/mcp/mcp.json — it does not honour XDG_CONFIG_HOME — so this path is
# literal, with an override for the test suite.
MCP_SHARED_SRC="$REPO_DIR/pi/mcp.json"
MCP_SHARED_DEST="${AGENT_RIG_MCP_SHARED_CONFIG:-$HOME/.config/mcp/mcp.json}"
