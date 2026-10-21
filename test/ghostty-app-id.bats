#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# AppleScript must find Ghostty by bundle id, never by name. chrismo's fork
# installs as Moestty.app with the same bundle id (com.mitchellh.ghostty), so
# a name lookup ("Ghostty") breaks there while an id lookup works for both.

ROOT="$BATS_TEST_DIRNAME/.."

scripts() {
  printf '%s\n' \
    "$ROOT/bin/claude-tabs" \
    "$ROOT/bin/claude-tabs.integration-test.sh" \
    "$ROOT/bin/gt" \
    "$ROOT/tab-status/tab-status" \
    "$ROOT/tab-status/tab-status.integration-test.sh"
}

@test "no AppleScript names the Ghostty application" {
  run -1 grep -n 'application "Ghostty"' $(scripts)
  [ -z "$output" ]
}

@test "no System Events lookup names the Ghostty process" {
  run -1 grep -n 'process "Ghostty"' $(scripts)
  [ -z "$output" ]
}

@test "each script that scripts Ghostty targets its bundle id" {
  local f
  for f in $(scripts); do
    grep -q 'com\.mitchellh\.ghostty' "$f" || { echo "missing bundle id: $f"; return 1; }
  done
}
