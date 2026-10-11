#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for hooks/lemma-brief.sh.
#
# Fires on SessionStart. It is the READ half of the lemmalog loop: without it,
# facts go in and are never seen again, which is how a store quietly dies.
#
# It cannot query the engine — the lemmalog MCP tools are Claude-only, and a
# SessionStart hook is a script. But the snapshot is plain TSV, so it can be
# read directly, which is safe precisely because it is read-only: the MCP server
# rewrites that file after every mutating call.
#
# It must be silent when there is no news. A SessionStart hook that speaks every
# time is a hook people disable.

HOOK="$BATS_TEST_DIRNAME/lemma-brief.sh"

setup() {
  export AGENT_RIG_LEMMA_QUEUE="$BATS_TEST_TMPDIR/pending.tsv"
  # The loop ships OFF (see "the enable gate" below). On for the suite, so every
  # test here goes on exercising the real hook rather than the gate.
  export AGENT_RIG_LEMMA_ENABLED=1
  export AGENT_RIG_LEMMA_SNAPSHOT="$BATS_TEST_TMPDIR/store.snapshot"
  # A real repo: the hook names the repo from `git rev-parse --show-toplevel`,
  # matching how lemma-commit.sh names it. A bare directory would resolve to
  # nothing, which is the correct behaviour but not the case under test here.
  export AGENT_RIG_LEMMA_CWD="$BATS_TEST_TMPDIR/agent-rig"
  mkdir -p "$AGENT_RIG_LEMMA_CWD"
  git -C "$AGENT_RIG_LEMMA_CWD" init -q
}

queue() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" 100 "$3" >> "$AGENT_RIG_LEMMA_QUEUE"; }

# --- silence when there is nothing to say --------------------------------

@test "silent when the queue file does not exist" {
  run "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "silent when the queue is empty" {
  : > "$AGENT_RIG_LEMMA_QUEUE"

  run "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "silent when the queue holds nothing for THIS repo" {
  queue questor abc1234 "unrelated work"

  run "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- reporting -----------------------------------------------------------

@test "reports the pending count for this repo" {
  queue agent-rig abc1234 "first"
  queue agent-rig def5678 "second"

  run "$HOOK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 commits"* ]] || false
  [[ "$output" == *"agent-rig"* ]]
}

@test "counts only this repo, not the whole queue" {
  queue agent-rig abc1234 "mine"
  queue questor   def5678 "theirs"
  queue questor   aaa1111 "theirs too"

  run "$HOOK"
  [[ "$output" == *"1 commit"* ]] || false
  [[ "$output" != *"3 commits"* ]]
}

@test "names the drain command so the queue is actionable" {
  queue agent-rig abc1234 "first"

  run "$HOOK"
  [[ "$output" == *"lemma-drain"* ]]
}

@test "reports how many facts the store already holds for this repo" {
  queue agent-rig abc1234 "first"
  cat > "$AGENT_RIG_LEMMA_SNAPSHOT" <<'EOF'
LEMMALOG-SNAPSHOT-V1
NOW	100
FACT	edge	1	ep1	s:agent-rig s:ruled_out s:per-repo-stores
FACT	edge	1	ep1	s:agent-rig s:uses s:datalog
FACT	edge	1	ep2	s:questor s:uses s:ruby
EOF

  run "$HOOK"
  [[ "$output" == *"Facts on record for agent-rig: 2."* ]]
}

@test "omits the facts line when the store has nothing for this repo" {
  queue agent-rig abc1234 "first"
  cat > "$AGENT_RIG_LEMMA_SNAPSHOT" <<'EOF'
LEMMALOG-SNAPSHOT-V1
FACT	edge	1	ep2	s:questor s:uses s:ruby
EOF

  run "$HOOK"
  [ "$status" -eq 0 ]
  # Still reports the pending commit -- it is only the facts line that is
  # suppressed. "0 facts on record" is discouraging noise on day one.
  [[ "$output" == *"1 commit"* ]] || false
  [[ "$output" != *"Facts on record"* ]]
}

# --- never break session startup ----------------------------------------

@test "exits 0 with no snapshot file at all" {
  queue agent-rig abc1234 "first"

  run "$HOOK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 commit"* ]]
}

@test "a malformed snapshot never breaks startup" {
  queue agent-rig abc1234 "first"
  printf 'this is not a snapshot\n\n\t\t\n' > "$AGENT_RIG_LEMMA_SNAPSHOT"

  run "$HOOK"
  [ "$status" -eq 0 ]
}

@test "a malformed queue never breaks startup" {
  printf 'garbage with no tabs\n' > "$AGENT_RIG_LEMMA_QUEUE"

  run "$HOOK"
  [ "$status" -eq 0 ]
}

@test "exits 0 when the cwd is not a git repository" {
  export AGENT_RIG_LEMMA_CWD="$BATS_TEST_TMPDIR/nowhere"

  run "$HOOK"
  [ "$status" -eq 0 ]
}

# --- repo attribution ----------------------------------------------------
#
# The count must agree with bin/lemma-info, and for the same reason it exists at
# all: /lemma-backfill puts the TOPIC on the left of a fact and ties it to a repo
# with a separate in_repo edge. Matching the repo name literally counted 5 of 45
# facts on a real run — a number that reads as "the store is barely used" when
# the store is fine.

b_edge() { # subj rel obj [valid_to]
  local vt="${4:-9223372036854775807}"
  printf 'FACT\tedge\t0.9\tep1\ts:%s s:%s s:%s i:100 i:%s i:100\n' "$1" "$2" "$3" "$vt" \
    >> "$AGENT_RIG_LEMMA_SNAPSHOT"
}
b_new_store() { printf 'LEMMALOG1\nNOW\t100\nRULES\t\n' > "$AGENT_RIG_LEMMA_SNAPSHOT"; }

@test "counts topic facts tied to the repo by in_repo, not just literal names" {
  queue agent-rig abc1234 "first"
  b_new_store
  b_edge heredocs in_repo agent-rig
  b_edge heredocs because cascading-tool-denials

  run "$HOOK"
  [[ "$output" == *"Facts on record for agent-rig: 2."* ]]
}

@test "does not count another repo's facts" {
  queue agent-rig abc1234 "first"
  b_new_store
  b_edge heredocs in_repo agent-rig
  b_edge sharding in_repo questor
  b_edge sharding uses captain

  run "$HOOK"
  [[ "$output" == *"Facts on record for agent-rig: 1."* ]]
}

@test "excludes superseded facts from the count" {
  queue agent-rig abc1234 "first"
  b_new_store
  b_edge commit-message-file in_repo agent-rig
  b_edge commit-message-file location repo-level-tmp 200
  b_edge commit-message-file location dot-claude-tmp

  run "$HOOK"
  [[ "$output" == *"Facts on record for agent-rig: 2."* ]]
}

# --- the enable gate -----------------------------------------------------
#
# Same gate as hooks/lemma-commit.sh, and it matters more here: the brief is the
# half that SPEAKS. On a machine that never opted in, a SessionStart nag about a
# queue nobody is draining is exactly how a hook gets disabled for good.

@test "silent when the enable marker is absent, even with a full queue" {
  export AGENT_RIG_LEMMA_ENABLED=""
  export AGENT_RIG_LEMMA_MARKER="$BATS_TEST_TMPDIR/absent"
  queue agent-rig abc1234 "first"

  run "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "speaks when the marker file exists" {
  export AGENT_RIG_LEMMA_ENABLED=""
  export AGENT_RIG_LEMMA_MARKER="$BATS_TEST_TMPDIR/on"
  : > "$AGENT_RIG_LEMMA_MARKER"
  queue agent-rig abc1234 "first"

  run "$HOOK"
  [[ "$output" == *"1 commit pending"* ]]
}
