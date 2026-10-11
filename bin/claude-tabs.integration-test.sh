#!/usr/bin/env bash
#
# Manual integration test for `claude-tabs restore` against REAL Ghostty.
#
# NOT a CI/headless test. It requires a Mac running Ghostty 1.3+ and macOS
# Automation permission (the first run prompts "<terminal> wants to control
# Ghostty" — allow it). It opens windows and tabs on your desktop.
#
# Why this exists alongside claude-tabs.bats:
#   - claude-tabs.bats covers the pure AppleScript *generator* (text shape) and
#     runs anywhere.
#   - This covers the layer bats can't: the generated script hitting a live
#     Ghostty. The bugs that motivated it were invisible to bats —
#     `activate` not opening a window on cold start, and `send key "return"`
#     being rejected (the key name is "enter"). The most likely future
#     regression is a Ghostty version bump changing the scripting dictionary,
#     so keep this as the "does restore still work on real Ghostty?" check.
#
# Strategy: read back each tab's terminal `working directory` via AppleScript
# and assert it matches the expected order. A correct working directory proves
# new-tab routing (the original focus race), `input text` delivery, AND that
# `send key "enter"` submitted (else the `cd` never ran and the wd is unchanged).
#
# Usage:
#   claude-tabs.integration-test.sh routing [N] [cold|running] [--close]
#   claude-tabs.integration-test.sh real <manifest.json> [--close]
#
#   routing   N fake sessions (default 4) that just `cd` into distinct temp
#             dirs — no real `claude` launched. Verifies each command landed in
#             its own tab.
#               cold (default): quit Ghostty first, exercising the
#                 wasRunning=false path that reuses the fresh window's tab 1.
#               running: reset, open one window, then add tabs to it —
#                 exercises the all-new-tabs path without reusing the user's tab.
#   real      drive the genuine `claude-tabs restore <manifest>`, launching real
#             `claude --resume` per tab. Verifies each tab's cwd matches the
#             manifest's path order. Build a manifest from ~/.claude/tab-history/.
#
#   --close   close the test window automatically when done (default: leave open)

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TABS="$REPO/bin/claude-tabs"

# ── shared helpers ──────────────────────────────────────────────────────────

reset_ghostty_cold() {
  echo "Quitting Ghostty for a clean cold slate..."
  osascript -e 'tell application id "com.mitchellh.ghostty" to quit' 2>/dev/null || true
  sleep 1.5
}

# Echo "index: working_directory" for every tab in the front window.
read_back_working_dirs() {
  osascript <<'AS'
tell application id "com.mitchellh.ghostty"
    set theWindow to front window
    set out to ""
    repeat with t in tabs of theWindow
        set wd to ""
        try
            set wd to working directory of (terminal 1 of t)
        end try
        set out to out & (index of t) & ": " & wd & linefeed
    end repeat
    return out
end tell
AS
}

# verify_order <read_back> <expected-path-0> <expected-path-1> ...
# Compares tab i's working directory to expected path i (loose suffix match to
# tolerate /private prefixes and trailing slashes). Returns non-zero on any miss.
verify_order() {
  local read_back="$1"; shift
  local expected=("$@")
  local pass=0 fail=0 i got want
  for ((i = 0; i < ${#expected[@]}; i++)); do
    want="${expected[i]}"
    got=$(echo "$read_back" | grep "^$((i + 1)): " | sed "s/^$((i + 1)): //" | tr -d ' ')
    if [[ "$got" == "$want" || "$got" == "$want/" || "$got" == *"$want" ]]; then
      echo "  PASS  tab $((i + 1)): $got"
      ((pass++)) || true
    else
      echo "  FAIL  tab $((i + 1)): got '$got', want '$want'"
      ((fail++)) || true
    fi
  done
  echo
  echo "Result: $pass passed, $fail failed (of ${#expected[@]})"
  [[ "$fail" -eq 0 ]]
}

show_window() {
  local read_back="$1"
  echo
  echo "=== Tabs in front window (index: working directory) ==="
  echo "$read_back"
  echo "========================================================"
  echo
}

teardown_note() {
  local close="$1"
  if [[ "$close" -eq 1 ]]; then
    echo "Closing test window..."
    osascript -e 'tell application id "com.mitchellh.ghostty" to close front window' 2>/dev/null || true
  else
    echo "Test window left open for inspection."
    echo "  close: osascript -e 'tell application \"Ghostty\" to close front window'"
  fi
}

# ── routing mode (no real claude) ─────────────────────────────────────────────

run_routing() {
  # shellcheck disable=SC1090
  source "$TABS"

  local n=4 submode=cold close=0 arg
  for arg in "$@"; do
    case "$arg" in
      cold|running) submode="$arg" ;;
      --close)      close=1 ;;
      [0-9]*)       n="$arg" ;;
      *) echo "unknown routing arg: $arg" >&2; exit 2 ;;
    esac
  done

  local work cmd_dir i
  work="$(mktemp -d "${TMPDIR:-/tmp}/claude-tabs-test.XXXXXX")"
  cmd_dir="$work/cmd"
  mkdir -p "$cmd_dir"

  echo "Mode: routing/$submode   Tabs: $n   Test root: $work"
  echo

  local expected=()
  for ((i = 0; i < n; i++)); do
    mkdir -p "$work/d$i"
    expected+=("$work/d$i")
    # cd into the unique dir, set a recognizable title, then idle so the tab
    # stays alive for inspection.
    printf "cd %q && printf '\\\\033]0;CTTEST-%d\\\\007' && exec sleep 600" "$work/d$i" "$i" \
      > "$cmd_dir/cmd-$i.txt"
  done

  if [[ "$submode" == "cold" ]]; then
    reset_ghostty_cold
  else
    # Simulate "Ghostty already running with the user's window": reset, then
    # open exactly one window for restore to add tabs to (it must NOT reuse
    # this window's default tab, so we expect 1 default + N restored tabs).
    echo "Resetting Ghostty, then opening one window to restore into..."
    osascript -e 'tell application id "com.mitchellh.ghostty" to quit' 2>/dev/null || true
    sleep 1.5
    osascript -e 'tell application id "com.mitchellh.ghostty" to activate' \
              -e 'tell application id "com.mitchellh.ghostty" to new window' >/dev/null
    sleep 1
  fi

  echo "Running restore AppleScript ($n tabs)..."
  build_restore_applescript "$cmd_dir" "$n" | osascript

  echo "Waiting for shells to settle..."
  sleep 3

  local read_back
  read_back="$(read_back_working_dirs)"
  show_window "$read_back"

  local rc=0
  verify_order "$read_back" "${expected[@]}" || rc=1
  echo
  teardown_note "$close"
  echo "Cleanup temp: rm -rf $work"
  return "$rc"
}

# ── real mode (genuine claude-tabs restore) ───────────────────────────────────

run_real() {
  local manifest="" close=0 arg
  for arg in "$@"; do
    case "$arg" in
      --close) close=1 ;;
      *)       manifest="$arg" ;;
    esac
  done
  [[ -n "$manifest" ]] || { echo "usage: $0 real <manifest.json> [--close]" >&2; exit 2; }

  echo "Mode: real   Manifest: $manifest"
  echo

  local expected=()
  while IFS= read -r _line; do
    expected+=("$_line")
  done < <(super -f line -c 'unnest this | values path' "$manifest")

  echo "Expected tab order (by manifest path):"
  local i
  for ((i = 0; i < ${#expected[@]}; i++)); do
    echo "  tab $((i + 1)): ${expected[i]}"
  done
  echo

  reset_ghostty_cold

  echo "Running REAL claude-tabs restore..."
  "$TABS" restore "$manifest"

  echo "Waiting for claude sessions to boot..."
  sleep 8

  local read_back
  read_back="$(read_back_working_dirs)"
  show_window "$read_back"

  local rc=0
  verify_order "$read_back" "${expected[@]}" || rc=1
  echo
  echo "Eyeball the tabs: each should be a RESUMED claude session (prior"
  echo "history visible), not a fresh one — the cwd check can't prove that."
  teardown_note "$close"
  return "$rc"
}

# ── dispatch ──────────────────────────────────────────────────────────────────

mode="${1:-}"
shift || true
case "$mode" in
  routing) run_routing "$@" ;;
  real)    run_real "$@" ;;
  *)
    echo "usage:" >&2
    echo "  $0 routing [N] [cold|running] [--close]" >&2
    echo "  $0 real <manifest.json> [--close]" >&2
    exit 2
    ;;
esac
