#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for bin/gt (Ghostty tab/window fuzzy selector).
#
# Pure helpers plus the native AppleScript boundary (stubbed osascript).

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
# Rows carry a stable tab ID, so duplicate titles remain independently selectable.

@test "gt_parse_menu drops blank lines, keeps id<TAB>title" {
  input=$'tab-36\t⚪ aws (branch-a)\n\ntab-37\tdscout (main)\n'
  run gt_parse_menu <<<"$input"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | sed -n 1p)" == $'tab-36\t⚪ aws (branch-a)' ]] || false
  [[ "$(echo "$output" | sed -n 2p)" == $'tab-37\tdscout (main)' ]] || false
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

@test "gt_dump_tabs includes native window names in a separate field" {
  osascript() {
    local script
    script="$(</dev/stdin)"
    [[ "$script" == *'tell application id "com.mitchellh.ghostty"'* ]] || return 1
    [[ "$script" == *'tabs of w'* ]] || return 1
    [[ "$script" == *'id of t'* ]] || return 1
    [[ "$script" == *'name of t'* ]] || return 1
    [[ "$script" != *'System Events'* ]] || return 1
    [[ "$script" == *'name of w'* ]] || return 1
    [[ "$script" == *'(name of t) & (ASCII character 9) & (name of w)'* ]] || return 1
    printf 'tab-123\t🔵 agent-rig (main)\tWork-Rig\n'
  }
  run gt_dump_tabs
  [ "$status" -eq 0 ]
  [ "$output" = $'tab-123\t🔵 agent-rig (main)\tWork-Rig' ]
}

@test "gt_select_tab locates a stable ID across windows and selects it" {
  osascript() {
    [ "$1" = - ] || return 1
    [ "$2" = tab-123 ] || return 1
    local script
    script="$(</dev/stdin)"
    [[ "$script" == *'id of t'* ]] || return 1
    [[ "$script" == *'select tab t'* ]] || return 1
    [[ "$script" == *'activate'* ]] || return 1
    [[ "$script" != *'System Events'* ]] || return 1
  }
  run gt_select_tab tab-123
  [ "$status" -eq 0 ]
}

@test "gt_main sends the selected stable ID, not its duplicate title" {
  gt_dump_tabs() { printf 'tab-123\tdscout (main)\ntab-456\tdscout (main)\n'; }
  fzf() { tail -1; }
  gt_select_tab() { printf 'selected:%s\n' "$1"; }
  run gt_main
  [ "$status" -eq 0 ]
  [ "$output" = selected:tab-456 ]
}

@test "gt_main displays searchable window names but previews only the tab title" {
  gt_dump_tabs() { printf 'tab-123\tagent-rig (main)\tWork-Rig\n'; }
  fzf() {
    local args="$*"
    [[ "$args" == *'--with-nth=2..'* ]] || return 9
    [[ "$args" == *"--preview '$0' --preview {2}"* ]] || return 9
    command cat
  }
  gt_select_tab() { printf 'selected:%s\n' "$1"; }
  run gt_main
  [ "$status" -eq 0 ]
  [ "$output" = selected:tab-123 ]
}

@test "gt_main preserves AppleScript errors instead of reporting no tabs" {
  fzf() { return 0; }
  gt_dump_tabs() { echo 'Not authorized to send Apple events' >&2; return 7; }
  run gt_main
  [ "$status" -eq 7 ]
  [ "$output" = 'Not authorized to send Apple events' ]
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
