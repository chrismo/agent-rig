#!/usr/bin/env bats

# Test suite for the 2.10-context plugin.
#
# Renders "ctx: <N>k" — absolute tokens in context, not a percentage — colored
# on a gradient: green up to 100k, yellow at 150k, red from 200k, linear
# between. The color depends on tokens only, so it is the same on a 200k and
# a 1M window. Tokens are the sum of current_usage's input-side counts, falling
# back to context_window_size * used_percentage when current_usage is absent.

PLUGIN="$BATS_TEST_DIRNAME/plugins.d/2.10-context"

GREEN=$'\033[22;38;2;80;180;80m'
YELLOW=$'\033[22;38;2;200;170;60m'
RED=$'\033[22;38;2;210;70;70m'
RESET=$'\033[2;37m'

setup() {
  TEST_DIR="$(mktemp -d "$TMPDIR/context-test.XXXXXX")"
  export CLAUDE_STATUS_INPUT="$TEST_DIR/input.json"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# write_usage <input_tokens> [window_size]
write_usage() {
  local tokens=$1 size=${2:-1000000}
  cat > "$CLAUDE_STATUS_INPUT" <<JSON
{"context_window": {"context_window_size": $size,
  "current_usage": {"input_tokens": $tokens, "output_tokens": 999,
    "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0},
  "used_percentage": 1}}
JSON
}

render() { "$PLUGIN"; }

@test "shows tokens in k, not a percentage" {
  write_usage 77227
  run render
  [[ "$output" == "${GREEN}ctx: 77k${RESET}" ]] || { printf '%q\n' "$output"; false; }
}

@test "sums input, cache creation and cache read; ignores output" {
  cat > "$CLAUDE_STATUS_INPUT" <<JSON
{"context_window": {"context_window_size": 1000000,
  "current_usage": {"input_tokens": 2000, "output_tokens": 50000,
    "cache_creation_input_tokens": 30000, "cache_read_input_tokens": 28000}}}
JSON
  run render
  [[ "$output" == *"ctx: 60k"* ]] || { printf '%q\n' "$output"; false; }
}

@test "green at and below 100k" {
  write_usage 100000
  run render
  [[ "$output" == "${GREEN}ctx: 100k${RESET}" ]] || { printf '%q\n' "$output"; false; }
}

@test "yellow at 150k" {
  write_usage 150000
  run render
  [[ "$output" == "${YELLOW}ctx: 150k${RESET}" ]] || { printf '%q\n' "$output"; false; }
}

@test "red at 200k" {
  write_usage 200000
  run render
  [[ "$output" == "${RED}ctx: 200k${RESET}" ]] || { printf '%q\n' "$output"; false; }
}

@test "stays red past 200k" {
  write_usage 640000
  run render
  [[ "$output" == "${RED}ctx: 640k${RESET}" ]] || { printf '%q\n' "$output"; false; }
}

@test "between green and yellow is interpolated" {
  write_usage 125000
  run render
  # halfway green(80,180,80) -> yellow(200,170,60)
  [[ "$output" == $'\033[22;38;2;140;175;70m'"ctx: 125k${RESET}" ]] || { printf '%q\n' "$output"; false; }
}

@test "between yellow and red is interpolated" {
  write_usage 175000
  run render
  # halfway yellow(200,170,60) -> red(210,70,70)
  [[ "$output" == $'\033[22;38;2;205;120;65m'"ctx: 175k${RESET}" ]] || { printf '%q\n' "$output"; false; }
}

@test "color ignores window size" {
  write_usage 200000 200000
  run render
  [[ "$output" == "${RED}ctx: 200k${RESET}" ]] || { printf '%q\n' "$output"; false; }
}

@test "falls back to window size times used_percentage" {
  cat > "$CLAUDE_STATUS_INPUT" <<JSON
{"context_window": {"context_window_size": 1000000, "used_percentage": 8}}
JSON
  run render
  [[ "$output" == "${GREEN}ctx: 80k${RESET}" ]] || { printf '%q\n' "$output"; false; }
}

@test "empty context shows 0k" {
  echo '{}' > "$CLAUDE_STATUS_INPUT"
  run render
  [[ "$output" == "${GREEN}ctx: 0k${RESET}" ]] || { printf '%q\n' "$output"; false; }
}
