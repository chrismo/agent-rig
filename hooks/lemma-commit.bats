#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for hooks/lemma-commit.sh.
#
# Fires on PostToolUse for Bash. When the command was a commit, it records the
# resulting commit as a candidate for assertion into lemmalog (bin/lemma-queue)
# and says nothing at all.
#
# The silence is the design, not an oversight: chrismo chose a silent queue over
# a nag, so the habit costs nothing at commit time. It is also free — plain
# stdout from a PostToolUse hook never reaches the model anyway (the renderer
# allowlists only SessionStart / UserPromptSubmit / UserPromptExpansion), so
# anything printed here would be transcript-only noise.
#
# Why the script filters instead of a settings-level `if:` — a hook entry can
# carry `if: "Bash(git commit *)"` and never even spawn on other commands, but
# that is a prefix STRING match with no shell parsing. Real commits in this repo
# look like `cd ~/modev/agent-rig && git commit ...`, which it would miss
# entirely. Hence the `cd x && git commit` test below: it is the common case,
# not an edge case.

HOOK="$BATS_TEST_DIRNAME/lemma-commit.sh"

setup() {
  export AGENT_RIG_LEMMA_QUEUE="$BATS_TEST_TMPDIR/pending.tsv"
  # The loop ships OFF (see "the enable gate" below). Turn it on for the suite
  # so every test here goes on exercising the real hook rather than the gate.
  export AGENT_RIG_LEMMA_ENABLED=1

  # A real repo with one real commit, so `git log -1` has something to read.
  REPO="$BATS_TEST_TMPDIR/demo-repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name  Tester
  echo hello > "$REPO/file.txt"
  git -C "$REPO" add file.txt
  git -C "$REPO" commit -q -m "the subject line"
}

# Feed a PostToolUse payload. Piped, never a <<< here-string: bash 3.2 (the
# macOS default) mangles those, as hooks/use-dedicated-tools.sh:37 warns.
fire() {
  local cmd="$1" cwd="${2:-$REPO}"
  run bash -c "printf '%s' '{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"cwd\":\"$cwd\",\"tool_input\":{\"command\":\"$cmd\"},\"tool_response\":{}}' | '$HOOK'"
}

# --- it fires on a commit ------------------------------------------------

@test "queues the commit after a bare git commit" {
  fire 'git commit -m wip'
  [ "$status" -eq 0 ]

  run cut -f1,4 "$AGENT_RIG_LEMMA_QUEUE"
  [ "$output" = "demo-repo"$'\t'"the subject line" ]
}

@test "queues the commit when git commit is inside a compound command" {
  # The case a settings-level `if: Bash(git commit *)` prefilter would miss,
  # and the shape chrismo actually uses.
  fire "cd $REPO && git commit -q -F -"
  [ "$status" -eq 0 ]

  run cut -f1 "$AGENT_RIG_LEMMA_QUEUE"
  [ "$output" = "demo-repo" ]
}

@test "records the short sha of the resulting commit" {
  fire 'git commit -m wip'

  local expected
  expected=$(git -C "$REPO" log -1 --format=%h)
  run cut -f2 "$AGENT_RIG_LEMMA_QUEUE"
  [ "$output" = "$expected" ]
}

@test "names the repo by its root directory, not the cwd" {
  # Committing from a subdirectory must still attribute to the repo.
  mkdir -p "$REPO/sub/deeper"
  fire 'git commit -m wip' "$REPO/sub/deeper"

  run cut -f1 "$AGENT_RIG_LEMMA_QUEUE"
  [ "$output" = "demo-repo" ]
}

# --- it stays out of the way ---------------------------------------------

@test "produces no output on a commit" {
  fire 'git commit -m wip'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ignores a Bash call that is not a commit" {
  fire 'ls -la'
  [ "$status" -eq 0 ]
  [ ! -s "$AGENT_RIG_LEMMA_QUEUE" ]
}

@test "ignores read-only git commands that merely mention commits" {
  fire 'git log --format=%H'
  [ "$status" -eq 0 ]
  [ ! -s "$AGENT_RIG_LEMMA_QUEUE" ]
}

@test "does not queue twice when a commit fails and leaves HEAD unmoved" {
  fire 'git commit -m first'
  fire 'git commit -m "nothing staged"'

  run wc -l < "$AGENT_RIG_LEMMA_QUEUE"
  [ "${output// /}" -eq 1 ]
}

# --- it never breaks the session ----------------------------------------

@test "exits 0 and stays silent on malformed JSON" {
  run bash -c "printf '%s' 'not json at all' | '$HOOK'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "exits 0 on empty stdin" {
  run bash -c "printf '' | '$HOOK'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "exits 0 when the cwd is not a git repository" {
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  fire 'git commit -m wip' "$BATS_TEST_TMPDIR/plain"
  [ "$status" -eq 0 ]
  [ ! -s "$AGENT_RIG_LEMMA_QUEUE" ]
}

@test "exits 0 when the cwd does not exist" {
  fire 'git commit -m wip' "$BATS_TEST_TMPDIR/gone"
  [ "$status" -eq 0 ]
}

# --- the enable gate -----------------------------------------------------
#
# The loop is OFF unless ~/.claude/lemmalog/enabled exists. A clone of
# agent-rig on another machine gets the hooks and does nothing with them until
# someone opts in — the right default for a repo deployed to several machines
# with different appetites for automation.
#
# Gated rather than short-circuited with an early exit, deliberately. The last
# hook here disabled that way (abd6962) left 67 tests exercising unreachable
# code, 22 of which passed vacuously — "a suite that cannot fail for the right
# reason is worse than none" (ee9ffa8). A gate keeps every test above live: the
# suite turns it on explicitly and goes on testing the real behaviour.

@test "queues nothing when the enable marker is absent" {
  export AGENT_RIG_LEMMA_ENABLED=""
  export AGENT_RIG_LEMMA_MARKER="$BATS_TEST_TMPDIR/absent"

  fire "git commit -m x"
  [ "$status" -eq 0 ]
  [ ! -s "$AGENT_RIG_LEMMA_QUEUE" ]
}

@test "queues when the marker file exists" {
  export AGENT_RIG_LEMMA_ENABLED=""
  export AGENT_RIG_LEMMA_MARKER="$BATS_TEST_TMPDIR/on"
  : > "$AGENT_RIG_LEMMA_MARKER"

  fire "git commit -m x"
  [ -s "$AGENT_RIG_LEMMA_QUEUE" ]
}

@test "an explicit env 0 beats the marker, so one session can opt out" {
  export AGENT_RIG_LEMMA_ENABLED=0
  export AGENT_RIG_LEMMA_MARKER="$BATS_TEST_TMPDIR/on"
  : > "$AGENT_RIG_LEMMA_MARKER"

  fire "git commit -m x"
  [ ! -s "$AGENT_RIG_LEMMA_QUEUE" ]
}
