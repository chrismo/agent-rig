#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for hooks/internals-drift.sh.
#
# The hook fires on SessionStart and compares the Claude Code version that
# agent-rig's internals were last verified against with the version actually
# installed. Claude Code upgrades itself without ever running install.sh, so a
# version bump is the only reliable signal that our unsupported-internals
# assumptions need re-checking.
#
# Version resolution follows claude-src: CLAUDE_SRC_BINARY wins, and the
# binary's FILENAME is its version (~/.local/share/claude/versions/2.1.224).
# Tests point it at a temp file named after whatever version they want.
#
# The hook must never break session startup: every failure path exits 0.

HOOK="$BATS_TEST_DIRNAME/internals-drift.sh"

setup() {
  export AGENT_RIG_VERIFIED_FILE="$BATS_TEST_TMPDIR/verified-against"
  echo "2.1.224" > "$AGENT_RIG_VERIFIED_FILE"

  # A fake installed binary whose filename is the version.
  mkdir -p "$BATS_TEST_TMPDIR/versions"
  export CLAUDE_SRC_BINARY="$BATS_TEST_TMPDIR/versions/2.1.224"
  touch "$CLAUDE_SRC_BINARY"

  # Don't let a real session's env leak in and outrank CLAUDE_SRC_BINARY.
  unset CLAUDE_CODE_EXECPATH
}

@test "silent when the installed version matches the verified one" {
  run "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "warns when the installed version has moved on" {
  export CLAUDE_SRC_BINARY="$BATS_TEST_TMPDIR/versions/2.1.231"
  touch "$CLAUDE_SRC_BINARY"

  run "$HOOK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2.1.224"* ]] || false
  [[ "$output" == *"2.1.231"* ]]
}

@test "the warning names the contract suite to run" {
  export CLAUDE_SRC_BINARY="$BATS_TEST_TMPDIR/versions/2.1.231"
  touch "$CLAUDE_SRC_BINARY"

  run "$HOOK"
  [[ "$output" == *"claude-contract.bats"* ]]
}

@test "a downgrade is drift too, not just an upgrade" {
  export CLAUDE_SRC_BINARY="$BATS_TEST_TMPDIR/versions/2.1.220"
  touch "$CLAUDE_SRC_BINARY"

  run "$HOOK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2.1.220"* ]]
}

@test "exits 0 and stays quiet when the verified-against file is missing" {
  rm -f "$AGENT_RIG_VERIFIED_FILE"

  run "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "exits 0 and stays quiet when the binary cannot be resolved" {
  export CLAUDE_SRC_BINARY="$BATS_TEST_TMPDIR/versions/does-not-exist"
  unset CLAUDE_CODE_EXECPATH
  # Isolate PATH, or the fallback finds the host's real claude and the test
  # passes or fails according to whatever version this machine happens to run.
  # /usr/bin and /bin keep `env` and `bash` reachable; neither carries a
  # `claude`, so the fallback finds nothing. Wiping PATH outright would just
  # make the shebang fail with 127.
  mkdir -p "$BATS_TEST_TMPDIR/emptybin"
  export PATH="$BATS_TEST_TMPDIR/emptybin:/usr/bin:/bin"

  run "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "tolerates surrounding whitespace in the verified-against file" {
  printf '  2.1.224  \n' > "$AGENT_RIG_VERIFIED_FILE"

  run "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "CLAUDE_CODE_EXECPATH names the running build when set" {
  # Real shape: /Users/x/.local/share/claude/versions/2.1.224 — the file's
  # basename IS the version, same as CLAUDE_SRC_BINARY.
  export CLAUDE_CODE_EXECPATH="$BATS_TEST_TMPDIR/versions/2.1.240"
  touch "$CLAUDE_CODE_EXECPATH"
  unset CLAUDE_SRC_BINARY

  run "$HOOK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2.1.240"* ]]
}

@test "reports the RUNNING build, not a newer one the launcher already points at" {
  # Claude Code stages an upgrade by repointing the launcher symlink while
  # existing sessions keep running the old build. SessionStart must judge the
  # build this session is actually executing, or every session would nag about
  # a version it isn't running.
  unset CLAUDE_SRC_BINARY
  export CLAUDE_CODE_EXECPATH="$BATS_TEST_TMPDIR/versions/2.1.224"
  touch "$CLAUDE_CODE_EXECPATH"

  touch "$BATS_TEST_TMPDIR/versions/2.1.299"
  chmod +x "$BATS_TEST_TMPDIR/versions/2.1.299"
  mkdir -p "$BATS_TEST_TMPDIR/fakebin"
  ln -sf "$BATS_TEST_TMPDIR/versions/2.1.299" "$BATS_TEST_TMPDIR/fakebin/claude"
  export PATH="$BATS_TEST_TMPDIR/fakebin:$PATH"

  run "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "falls back to the launcher symlink when no exec path is set" {
  unset CLAUDE_SRC_BINARY
  unset CLAUDE_CODE_EXECPATH

  touch "$BATS_TEST_TMPDIR/versions/2.1.299"
  chmod +x "$BATS_TEST_TMPDIR/versions/2.1.299"
  mkdir -p "$BATS_TEST_TMPDIR/fakebin"
  ln -sf "$BATS_TEST_TMPDIR/versions/2.1.299" "$BATS_TEST_TMPDIR/fakebin/claude"
  export PATH="$BATS_TEST_TMPDIR/fakebin:$PATH"

  run "$HOOK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2.1.299"* ]]
}

@test "ignores a binary whose name is not version-shaped" {
  export CLAUDE_SRC_BINARY="$BATS_TEST_TMPDIR/versions/latest"
  touch "$CLAUDE_SRC_BINARY"

  run "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- the results file ----------------------------------------------------
#
# bin/contract-record leaves a row per test per run. The hook reads it to say
# what the suite actually established about the RUNNING build, which the
# verified-against stamp cannot express: it is one version string, written by
# hand, identical whether every assumption was confirmed or every one skipped.

@test "summarises confirmed assumptions for the running build" {
  export CLAUDE_SRC_BINARY="$BATS_TEST_TMPDIR/versions/2.1.231"
  touch "$CLAUDE_SRC_BINARY"
  export AGENT_RIG_CONTRACT_RESULTS="$BATS_TEST_TMPDIR/results.tsv"
  printf 'A1\tpass\t2.1.231\t100\nA2\tpass\t2.1.231\t100\n' > "$AGENT_RIG_CONTRACT_RESULTS"

  run "$HOOK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 confirmed"* ]]
}

@test "counts a skip separately from a pass" {
  export CLAUDE_SRC_BINARY="$BATS_TEST_TMPDIR/versions/2.1.231"
  touch "$CLAUDE_SRC_BINARY"
  export AGENT_RIG_CONTRACT_RESULTS="$BATS_TEST_TMPDIR/results.tsv"
  printf 'A1\tpass\t2.1.231\t100\nR1\tskip\t2.1.231\t100\n' > "$AGENT_RIG_CONTRACT_RESULTS"

  run "$HOOK"
  [[ "$output" == *"1 confirmed"* ]] || false
  [[ "$output" == *"1 skipped"* ]]
}

@test "reports a failing assumption by ID" {
  export CLAUDE_SRC_BINARY="$BATS_TEST_TMPDIR/versions/2.1.231"
  touch "$CLAUDE_SRC_BINARY"
  export AGENT_RIG_CONTRACT_RESULTS="$BATS_TEST_TMPDIR/results.tsv"
  printf 'A1\tpass\t2.1.231\t100\nB3\tfail\t2.1.231\t100\n' > "$AGENT_RIG_CONTRACT_RESULTS"

  run "$HOOK"
  [[ "$output" == *"B3"* ]] || false
  [[ "$output" == *"failing"* ]]
}

@test "counts assumptions seen on an older build but never on this one" {
  export CLAUDE_SRC_BINARY="$BATS_TEST_TMPDIR/versions/2.1.231"
  touch "$CLAUDE_SRC_BINARY"
  export AGENT_RIG_CONTRACT_RESULTS="$BATS_TEST_TMPDIR/results.tsv"
  printf 'A1\tpass\t2.1.231\t100\nC1\tpass\t2.1.224\t50\nC2\tpass\t2.1.224\t50\n' \
    > "$AGENT_RIG_CONTRACT_RESULTS"

  run "$HOOK"
  [[ "$output" == *"2 never run"* ]]
}

@test "the latest row for an assumption wins over an earlier one" {
  export CLAUDE_SRC_BINARY="$BATS_TEST_TMPDIR/versions/2.1.231"
  touch "$CLAUDE_SRC_BINARY"
  export AGENT_RIG_CONTRACT_RESULTS="$BATS_TEST_TMPDIR/results.tsv"
  # A1 failed, then was fixed and re-run on the same build.
  printf 'A1\tfail\t2.1.231\t100\nA1\tpass\t2.1.231\t200\n' > "$AGENT_RIG_CONTRACT_RESULTS"

  run "$HOOK"
  [[ "$output" == *"1 confirmed"* ]] || false
  [[ "$output" != *"failing"* ]]
}

@test "keeps the old behaviour when no results file exists yet" {
  export CLAUDE_SRC_BINARY="$BATS_TEST_TMPDIR/versions/2.1.231"
  touch "$CLAUDE_SRC_BINARY"
  export AGENT_RIG_CONTRACT_RESULTS="$BATS_TEST_TMPDIR/absent.tsv"

  run "$HOOK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2.1.231"* ]] || false
  [[ "$output" != *"confirmed"* ]]
}

@test "a malformed results file never breaks session startup" {
  export CLAUDE_SRC_BINARY="$BATS_TEST_TMPDIR/versions/2.1.231"
  touch "$CLAUDE_SRC_BINARY"
  export AGENT_RIG_CONTRACT_RESULTS="$BATS_TEST_TMPDIR/results.tsv"
  printf 'this is not a tsv row\n\n\t\t\t\n' > "$AGENT_RIG_CONTRACT_RESULTS"

  run "$HOOK"
  [ "$status" -eq 0 ]
}

@test "stays silent on a matching version even with a results file present" {
  export AGENT_RIG_CONTRACT_RESULTS="$BATS_TEST_TMPDIR/results.tsv"
  printf 'A1\tpass\t2.1.224\t100\n' > "$AGENT_RIG_CONTRACT_RESULTS"

  run "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
