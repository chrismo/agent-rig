#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

REX_STATUS="$BATS_TEST_DIRNAME/rex-status"

setup() {
  TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rex-status-test.XXXXXX")"
  OUT="$TEST_DIR/tty"
  : > "$OUT"
  export REX_STATUS_TTY="$OUT"
  export TERM_PROGRAM=rex
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "working sends state=working tagged claude-code" {
  run "$REX_STATUS" working </dev/null
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT")" = $'\e]7501;state=working:app=claude-code\a' ]
}

@test "done sends state=done" {
  run "$REX_STATUS" done </dev/null
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT")" = $'\e]7501;state=done:app=claude-code\a' ]
}

@test "idle sends state=idle" {
  run "$REX_STATUS" idle </dev/null
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT")" = $'\e]7501;state=idle:app=claude-code\a' ]
}

@test "blocked sends kind=permission and a base64 msg" {
  run "$REX_STATUS" blocked </dev/null
  [ "$status" -eq 0 ]
  local body msg
  body="$(cat "$OUT")"
  [[ "$body" == $'\e]7501;state=blocked:kind=permission:app=claude-code:msg='*$'\a' ]]
  msg="${body#*msg=}"
  msg="${msg%$'\a'}"
  [ "$(printf '%s' "$msg" | base64 -d)" = "Claude needs permission" ]
}

@test "outside Rex it writes nothing" {
  TERM_PROGRAM=ghostty run "$REX_STATUS" working </dev/null
  [ "$status" -eq 0 ]
  [ ! -s "$OUT" ]
}

@test "unknown state is rejected and writes nothing" {
  run "$REX_STATUS" bogus </dev/null
  [ "$status" -eq 2 ]
  [ ! -s "$OUT" ]
}

@test "no state argument is rejected" {
  run "$REX_STATUS" </dev/null
  [ "$status" -eq 2 ]
  [ ! -s "$OUT" ]
}

@test "an unwritable tty still exits 0, so it cannot fail a hook" {
  REX_STATUS_TTY="$TEST_DIR/no-such-dir/tty" run "$REX_STATUS" working </dev/null
  [ "$status" -eq 0 ]
}
