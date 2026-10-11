#!/usr/bin/env bash
#
# Manual integration test for `tab-status` TITLE DELIVERY against REAL Ghostty.
#
# NOT a CI/headless test. Must be run INSIDE a Ghostty pane (it resolves the
# pane's pts from the process tree) on macOS with Ghostty 1.3.1+ and Automation
# permission granted (first run prompts "<terminal> wants to control Ghostty").
#
# Why this exists alongside tab-status.bats:
#   - tab-status.bats covers the pure title-string logic (compute_title) and
#     runs anywhere.
#   - This covers the layer bats can't: actually delivering the title to a live
#     Ghostty tab. Hooks have no controlling terminal, so `> /dev/tty` fails;
#     deliver_title instead resolves the pane pts, marks the surface with a
#     sentinel, and uses Ghostty's `set_tab_title` action via osascript. The
#     most likely future regression is a Ghostty version bump changing the
#     scripting dictionary (e.g. dropping/renaming the set_tab_title action),
#     so keep this as the "does title delivery still work on real Ghostty?" check.
#
# Strategy: call deliver_title with a unique marker, then read back via
# AppleScript whether a tab now carries that exact title. A match proves the
# whole chain: pts resolution -> sentinel OSC -> terminal match -> set_tab_title.
#
# Usage:
#   tab-status.integration-test.sh        run the check in the current pane

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TAB_STATUS="$REPO/tab-status/tab-status"

# Source the functions (guard skips main when sourced).
# shellcheck source=/dev/null
source "$TAB_STATUS"

fail() { echo "FAIL: $*"; exit 1; }

echo "== tab-status title delivery integration test =="

pts=$(resolve_pts) || fail "could not resolve a pane pts — are you running inside a Ghostty pane?"
echo "resolved pts: $pts"

# A unique, recognizable marker title (avoid Date/random; use pid + pts).
marker="tab-status-itest $(basename "$pts") $$"
echo "delivering title: $marker"

deliver_title "$marker"

# Read back: does any Ghostty tab now carry exactly this title?
found=$(osascript - "$marker" <<'OSA'
on run argv
  set want to item 1 of argv
  tell application id "com.mitchellh.ghostty"
    set n to 0
    repeat with w in windows
      repeat with t in tabs of w
        if (name of t) is want then set n to n + 1
      end repeat
    end repeat
    return n as text
  end tell
end run
OSA
)

echo "tabs matching marker: $found"
if [[ "$found" -ge 1 ]]; then
  echo "PASS: set_tab_title delivered to a real Ghostty tab"
  echo "(the current tab title should now read: $marker)"
  exit 0
else
  fail "no tab carried the delivered title — set_tab_title path is broken"
fi
