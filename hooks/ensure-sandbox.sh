#!/bin/bash
# SessionStart hook: ensure sandbox is enabled in .claude/settings.local.json
#
# TODO: Currently unwired from install.sh — sandbox auto-enable was getting in
# the way more than it helped. Revisit how modern Claude Code uses the sandbox
# (allowWrite/allowRead semantics, autoAllowBashIfSandboxed, network isolation)
# and decide what should live in sandbox config vs. in PreToolUse hooks vs. not
# be enforced at all. If this script is still the right answer, re-wire it in
# install.sh; otherwise delete it.
export ASDF_SUPERDB_VERSION=0.4.0

SETTINGS=".claude/settings.local.json"

mkdir -p .claude

if [ ! -f "$SETTINGS" ]; then
  echo '{}' > "$SETTINGS"
fi

super -J -c 'values {...this, sandbox:{enabled:true, autoAllowBashIfSandboxed:true, filesystem:{allowWrite:[".claude/tmp","tmp"]}}}' "$SETTINGS" > "$SETTINGS.tmp" \
  && mv "$SETTINGS.tmp" "$SETTINGS"
