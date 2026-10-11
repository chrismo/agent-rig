#!/usr/bin/env bash
#
# lemma-commit - queue a commit as a candidate for assertion into lemmalog
#
# Fires on PostToolUse for Bash.
#
# lemmalog is only as good as what gets asserted into it, and asserting is a
# step you have to remember. That is the adoption risk, not the engine: a
# half-populated deductive store is worse than a prose note, because it looks
# authoritative. So assertion gets attached to a boundary that already recurs
# many times a session — the commit.
#
# Other boundaries were measured and rejected. PreCompact is elegant (the
# harness announcing it is about to forget) but fired roughly never when this
# was measured: the last manual /compact was 2026-07-25, and 1 of 101 recent
# sessions reached the automatic threshold. That threshold then sat near 640K,
# because this rig set CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=64 — removed 2026-08-31,
# so it is now Claude Code's default and lower. PreCompact may therefore fire
# more often than that measurement implies; the count is worth redoing before
# anyone leans on it. SubagentStop covered 4 sessions out of 108.
#
# This hook does NOT assert. It cannot: the lemmalog MCP tools are reachable
# only from Claude, and the MCP server rewrites its snapshot after every
# mutating call, so anything a script wrote there would be clobbered. It records
# a candidate; /lemma-drain applies judgement later, with the reasoning still in
# context. Most commits establish nothing worth keeping.
#
# It is silent by design — chrismo chose a queue over a nag, so the habit costs
# nothing at commit time. Silence is also free: plain stdout from a PostToolUse
# hook never reaches the model (the renderer allowlists only SessionStart,
# UserPromptSubmit and UserPromptExpansion), so printing here would be
# transcript-only noise.
#
# Deliberately NOT `set -e`: a hook that fails becomes model-visible noise
# attached to an unrelated tool call. Every unresolvable case exits 0 in silence.

set -uo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
QUEUE_CMD="${AGENT_RIG_LEMMA_QUEUE_CMD:-$REPO_DIR/bin/lemma-queue}"
MARKER="${AGENT_RIG_LEMMA_MARKER:-$HOME/.claude/lemmalog/enabled}"

# The loop ships OFF. agent-rig is deployed to several machines and not all of
# them want a hook queueing every commit, so opting in is a per-machine `touch`
# rather than a config edit — a clone gets the hooks and they do nothing.
#
# A gate, NOT an early exit inside the body. abd6962 disabled a hook that way
# and left 67 tests exercising unreachable code, 22 of them passing vacuously;
# ee9ffa8 had to replace the suite, recording that "a suite that cannot fail for
# the right reason is worse than none". Gating at the top keeps every existing
# test live — the suite sets AGENT_RIG_LEMMA_ENABLED=1 and tests real behaviour.
#
#   enable:  touch ~/.claude/lemmalog/enabled
#   disable: rm   ~/.claude/lemmalog/enabled
lemma_enabled() {
  case "${AGENT_RIG_LEMMA_ENABLED:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  [[ -e "$MARKER" ]]
}

main() {
  lemma_enabled || exit 0

  local input
  input=$(cat) || exit 0
  [[ -n "$input" ]] || exit 0

  # Why the filtering happens here rather than in settings.json: a hook entry
  # can carry `if: "Bash(git commit *)"` and never even spawn for other
  # commands, but that is a prefix STRING match with no shell parsing. Real
  # commits in this repo look like `cd ~/modev/agent-rig && git commit ...`,
  # which such a filter would miss entirely. Cheap to spawn; correct to filter.
  #
  # Pipe, never a <<< here-string — bash 3.2 (the macOS default) mangles those.
  # See hooks/use-dedicated-tools.sh:37.
  local command_str
  command_str=$(echo "$input" | super -f line -c 'this.tool_input.command' - 2>/dev/null) || exit 0
  [[ "$command_str" == *"git commit"* ]] || exit 0

  # `git log` and friends mention commits without making one. Requiring the
  # subcommand to be `commit` proper keeps read-only git out of the queue.
  [[ "$command_str" =~ (^|[^a-zA-Z-])git[[:space:]]+([^|;&]*[[:space:]])?commit([[:space:]]|$) ]] || exit 0

  local cwd
  cwd=$(echo "$input" | super -f line -c 'this.cwd' - 2>/dev/null) || exit 0
  [[ -n "$cwd" && -d "$cwd" ]] || exit 0

  # Attribute to the repository, not to whatever subdirectory the command ran
  # in — a commit from `src/deeper/` is still a commit to this repo.
  local root
  root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0
  [[ -n "$root" ]] || exit 0

  local sha subject
  sha=$(git -C "$root" log -1 --format=%h 2>/dev/null) || exit 0
  [[ -n "$sha" ]] || exit 0
  subject=$(git -C "$root" log -1 --format=%s 2>/dev/null) || subject=""

  # lemma-queue owns the dedupe: a commit with nothing staged fails and leaves
  # HEAD unmoved, and we would otherwise re-queue the previous commit.
  "$QUEUE_CMD" "$(basename -- "$root")" "$sha" "$subject" 2>/dev/null || true

  exit 0
}

main "$@"
