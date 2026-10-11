#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for bin/gt (Ghostty tab/window fuzzy selector).
#
# Most of gt is integration-level (System Events + Ghostty's Window menu),
# but the title-parsing and preview-resolution helpers are pure text
# functions — we lock in their shape so future edits don't regress how
# titles map back to worktree paths.

GT="$BATS_TEST_DIRNAME/gt"

setup() {
  # Source the script so we can call its functions directly.
  # The script's guard at the bottom skips main when sourced.
  source "$GT"
}

# ── gt_title_leaf ─────────────────────────────────────────────────────────────
# Titles look like "<emoji> <dir> (<branch>)" or "<dir>" (no branch, no emoji).
# The leaf is the <dir>, used to resolve ~/dev/<leaf>.

@test "gt_title_leaf strips status emoji and branch suffix" {
  run gt_title_leaf "🔵 agent-rig (main)"
  [ "$status" -eq 0 ]
  [[ "$output" == "agent-rig" ]]
}

@test "gt_title_leaf handles a title with no emoji" {
  run gt_title_leaf "dscout (main)"
  [ "$status" -eq 0 ]
  [[ "$output" == "dscout" ]]
}

@test "gt_title_leaf handles a title with no branch suffix" {
  run gt_title_leaf "devops-2081-aws-pen-test-remediation"
  [ "$status" -eq 0 ]
  [[ "$output" == "devops-2081-aws-pen-test-remediation" ]]
}

@test "gt_title_leaf handles emoji but no branch" {
  run gt_title_leaf "⚪ dscout-finance-platform"
  [ "$status" -eq 0 ]
  [[ "$output" == "dscout-finance-platform" ]]
}

@test "gt_title_leaf keeps hyphens/dots in the dir name" {
  run gt_title_leaf "⚪ ds5 (devops-1776-infra-observability-enhancements)"
  [ "$status" -eq 0 ]
  [[ "$output" == "ds5" ]]
}

# ── gt_parse_menu ─────────────────────────────────────────────────────────────
# The AppleScript dump is "<index><TAB><title>" lines. gt_parse_menu is the
# identity/passthrough filter that drops blank lines so fzf gets clean input.
# (Selection is by index, carried in the first field, to survive duplicate
# titles like two "dscout (main)" entries.)

@test "gt_parse_menu drops blank lines, keeps index<TAB>title" {
  input=$'36\t⚪ aws (branch-a)\n\n37\tdscout (main)\n'
  run gt_parse_menu <<<"$input"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | sed -n 1p)" == $'36\t⚪ aws (branch-a)' ]] || false
  [[ "$(echo "$output" | sed -n 2p)" == $'37\tdscout (main)' ]] || false
  [ "$(echo "$output" | grep -c .)" -eq 2 ]
}

@test "gt_parse_menu succeeds (not exit 1) on all-blank input" {
  # grep -v exits 1 when nothing matches; under set -e/pipefail that would
  # abort the caller before the empty-dump check. gt_parse_menu must swallow it.
  run gt_parse_menu <<<$'\n  \n\n'
  [ "$status" -eq 0 ]
  [[ -z "$output" ]]
}

@test "gt_parse_menu succeeds on empty input" {
  run gt_parse_menu </dev/null
  [ "$status" -eq 0 ]
  [[ -z "$output" ]]
}

# ── gt_preview ────────────────────────────────────────────────────────────────
# gt_preview takes a title, resolves ~/dev/<leaf>, and prints a preview.
# We drive it against a fake DEV_ROOT so the test is hermetic.

@test "gt_preview shows the resolved path for a known worktree" {
  DEV_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gt-dev.XXXXXX")"
  mkdir -p "$DEV_ROOT/agent-rig"

  run gt_preview "🔵 agent-rig (main)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$DEV_ROOT/agent-rig"* ]] || false

  rm -rf "$DEV_ROOT"
}

@test "gt_preview falls back gracefully when the dir does not resolve" {
  DEV_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gt-dev-empty.XXXXXX")"

  run gt_preview "🔵 nonexistent-thing (main)"
  [ "$status" -eq 0 ]
  # Must not crash, and must surface the title/leaf so the pane isn't blank.
  [[ "$output" == *"nonexistent-thing"* ]] || false

  rm -rf "$DEV_ROOT"
}
