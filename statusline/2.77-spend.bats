#!/usr/bin/env bats

# Test suite for the 2.77-spend plugin, which is a shim.
#
# The segment it renders — "36% $121/$333 | 24h [··●··◇··] 7h" — is no longer
# built here. It is built by claude-daily-spend-statusline.sh in the
# claude-plugins marketplace repo, and this plugin shells out to it. So there
# is nothing here about colours, bar glyphs, pace or the UTC countdown: those
# belong to the upstream suite, and asserting them twice would mean this repo
# claims to own behaviour it does not.
#
# What is left to test is the shim's own contract:
#   - upstream's stdout reaches the status line unaltered, both lines and all
#   - every way upstream can be missing or fail is silent, exit 0
#
# The point of the shim is dogfooding: this machine renders its status line
# from the artifact an outside user gets, so a regression upstream shows up
# here first. That only holds if the passthrough is faithful, which is what
# the first few tests pin down.
#
# A status line must never break the prompt: every failure path is silent,
# exit 0.

PLUGIN="$BATS_TEST_DIRNAME/plugins.d/2.77-spend"

setup() {
  export AGENT_RIG_SPEND_STATUSLINE="$BATS_TEST_TMPDIR/upstream.sh"
}

# upstream <body> — stand in for the marketplace script. A stub, not the real
# thing: this suite asserts the shim's plumbing, and a stub is the only way to
# drive the failure modes (nonzero exit, empty output) on demand.
upstream() {
  printf '#!/bin/bash\n%s\n' "$1" > "$AGENT_RIG_SPEND_STATUSLINE"
  chmod +x "$AGENT_RIG_SPEND_STATUSLINE"
}

@test "passes upstream's segment through to the status line" {
  upstream 'echo "36% \$121/\$333 | 24h [··●··◇··] 7h"'
  run "$PLUGIN"
  [ "$status" -eq 0 ]
  [ "$output" = '36% $121/$333 | 24h [··●··◇··] 7h' ]
}

# Upstream owns the whole string, separator included. The shim must not split
# it into two segments and let the runner re-join them, or the two repos would
# disagree about the layout.
@test "leaves upstream's own separator intact" {
  upstream 'echo "36% \$121/\$333 | 24h [··●··◇··] 7h"'
  run "$PLUGIN"
  [[ "$output" == *' | '* ]] || false
}

# Colour codes are upstream's business, but they have to survive the trip: a
# shim that stripped or re-escaped them would render literal escapes.
#
# The `|| false` is not decoration: bash 3.2 does not fail a test on a
# non-terminal [[ ]], and bats runs under macOS 3.2 here.
@test "passes ANSI colour through unmangled" {
  upstream 'printf "\033[2;31m92%% \$4283/\$4640\033[2;37m\n"'
  run "$PLUGIN"
  [[ "$output" == $'\033[2;31m'* ]] || false
  [[ "$output" == *$'\033[2;37m' ]] || false
}

@test "silent when upstream prints nothing" {
  upstream 'exit 0'
  run "$PLUGIN"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# Whitespace-only is not the same as empty: it survives a -n check and would
# render as a blank segment with the runner's " | " joins on either side of
# nothing.
@test "silent when upstream prints only whitespace" {
  upstream 'printf "   \n"'
  run "$PLUGIN"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a nonzero exit from upstream is silent, not a broken prompt" {
  upstream 'echo "half a segment"; exit 1'
  run "$PLUGIN"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "upstream's stderr never reaches the status line" {
  upstream 'echo "curl: (6) could not resolve host" >&2; echo "40% \$1/\$2"'
  run "$PLUGIN"
  [ "$status" -eq 0 ]
  [ "$output" = '40% $1/$2' ]
}

# The checkout is not on every machine this repo deploys to, so a missing
# upstream is an ordinary state, not an error.
@test "a missing upstream script is silent" {
  export AGENT_RIG_SPEND_STATUSLINE="$BATS_TEST_TMPDIR/not-here.sh"
  run "$PLUGIN"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a non-executable upstream script is silent" {
  upstream 'echo "36% \$121/\$333"'
  chmod -x "$AGENT_RIG_SPEND_STATUSLINE"
  run "$PLUGIN"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# A status line renders on every keystroke, so a hung upstream would wedge the
# prompt rather than merely blank a segment. Upstream caps its own curl, but
# the shim cannot assume that of whatever it is pointed at next.
#
# Skipped without timeout(1), which is not in the macOS base system: there the
# shim runs upstream bare and has nothing to assert. The cap is turned down to
# 1s so the suite pays a second for this rather than the default ten.
@test "a hanging upstream is cut off rather than wedging the prompt" {
  command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 \
    || skip "no timeout(1) on this machine"
  export AGENT_RIG_SPEND_TIMEOUT=1
  upstream 'sleep 30; echo "too late"'
  run "$PLUGIN"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# Upstream emits one line today. If it ever emits two, the runner's line
# grouping would mangle them, so the shim flattens to a single segment.
#
# The line count is the assertion that pins this — a `[ ]`, so it propagates
# on bash 3.2 without help. Matching *first*/*second* alone would pass just as
# happily against un-folded two-line output.
@test "collapses multi-line upstream output onto one segment" {
  upstream 'printf "first\nsecond\n"'
  run "$PLUGIN"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *first* ]] || false
  [[ "$output" == *second* ]] || false
}

# A carriage return adds no line, so the line-count check above cannot see it.
# It is the more damaging of the two: the terminal returns the cursor to the
# start of the status line and overwrites whatever was printed to the left.
@test "folds a carriage return that would overwrite the line" {
  upstream 'printf "first\rsecond\n"'
  run "$PLUGIN"
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\r'* ]] || false
  [[ "$output" == *first* ]] || false
  [[ "$output" == *second* ]] || false
}
