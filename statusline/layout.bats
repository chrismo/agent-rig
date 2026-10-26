#!/usr/bin/env bats

# Layout of the real plugins.d/: which segment sits on which line.

SCRIPT="$BATS_TEST_DIRNAME/statusline-command.sh"
PLUGINS="$BATS_TEST_DIRNAME/plugins.d"

render() {
  bash "$SCRIPT" < "$BATS_TEST_DIRNAME/sample-input.json" | sed $'s/\033\\[[0-9;]*m//g'
}

@test "context is the first segment of line 2" {
  line2=$(render | sed -n 2p)
  [[ "$line2" == "ctx:"* ]] || { echo "line 2: $line2"; false; }
}

@test "cost is the last segment of line 2" {
  line2=$(render | sed -n 2p)
  [[ "$line2" =~ \|\ \$[0-9.]+$ ]] || { echo "line 2: $line2"; false; }
}

@test "cost shows no durations" {
  run "$PLUGINS/2.90-cost" < "$BATS_TEST_DIRNAME/sample-input.json"
  [[ "$output" =~ ^\$[0-9.]+$ ]] || { echo "cost: $output"; false; }
}

@test "hud is the only plugin on line 3" {
  run bash -c "ls '$PLUGINS' | grep '^3\.'"
  [[ "$output" == "3.10-hud" ]]
}

@test "no lines-changed segment" {
  [[ ! -e "$PLUGINS/2.60-lines" ]]
}
