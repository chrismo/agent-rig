#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for bin/lemma-info.
#
# The lemmalog loop spans four places that can each be independently broken or
# absent: the engine binary (built per machine, outside this repo), the MCP
# registration (user scope, written by bin/lemma-install), the store itself, and
# the pending queue. Nothing surfaces all four at once — hooks/lemma-brief.sh
# deliberately reports only the queue, and only when non-empty, because a
# SessionStart hook that speaks every time gets disabled.
#
# So there is no way to ask "what state is this in?" without reading four files
# by hand. That is what this answers.
#
# It is a SCRIPT and not a skill on purpose: the moment you most need to know
# the state is when the lemmalog_* MCP tools are NOT connected, which is exactly
# when a skill cannot help. It must work with nothing installed at all.
#
# It always exits 0. "Nothing is installed" is a successful report, not a
# failure — this diagnoses, it does not gate.

I="$BATS_TEST_DIRNAME/lemma-info"

setup() {
  export AGENT_RIG_LEMMA_QUEUE="$BATS_TEST_TMPDIR/pending.tsv"
  export AGENT_RIG_LEMMA_SNAPSHOT="$BATS_TEST_TMPDIR/store.snapshot"
  export AGENT_RIG_CLAUDE_JSON="$BATS_TEST_TMPDIR/claude.json"
  export LEMMALOG_SRC="$BATS_TEST_TMPDIR/lemmalog"

  # The repo the session is in, named the way lemma-commit.sh names it, so the
  # queue breakdown can put the current repo first.
  export AGENT_RIG_LEMMA_CWD="$BATS_TEST_TMPDIR/agent-rig"
  mkdir -p "$AGENT_RIG_LEMMA_CWD"
  git -C "$AGENT_RIG_LEMMA_CWD" init -q
}

queue() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" 100 "$3" >> "$AGENT_RIG_LEMMA_QUEUE"; }

engine_present() {
  mkdir -p "$LEMMALOG_SRC/target/release"
  : > "$LEMMALOG_SRC/target/release/lemmalog-mcp"
  chmod +x "$LEMMALOG_SRC/target/release/lemmalog-mcp"
}

registered() {
  cat > "$AGENT_RIG_CLAUDE_JSON" <<EOF
{"mcpServers":{"lemmalog":{"type":"stdio","env":{"LEMMALOG_MCP_PATH":"$AGENT_RIG_LEMMA_SNAPSHOT"}}},"projects":{}}
EOF
}

store_with() {
  { echo "LEMMALOG-SNAPSHOT-V1"
    for f in "$@"; do printf 'FACT\tedge\t1\tep1\t%s\n' "$f"; done
  } > "$AGENT_RIG_LEMMA_SNAPSHOT"
}

# --- it never fails ------------------------------------------------------

@test "exits 0 with nothing installed at all" {
  run "$I"
  [ "$status" -eq 0 ]
}

@test "exits 0 when every input file is missing" {
  export AGENT_RIG_LEMMA_QUEUE="$BATS_TEST_TMPDIR/nope.tsv"
  export AGENT_RIG_LEMMA_SNAPSHOT="$BATS_TEST_TMPDIR/nope.snapshot"
  export AGENT_RIG_CLAUDE_JSON="$BATS_TEST_TMPDIR/nope.json"

  run "$I"
  [ "$status" -eq 0 ]
}

@test "exits 0 on a malformed store rather than reporting a bad count" {
  printf 'not a snapshot at all\n\x00\x01\n' > "$AGENT_RIG_LEMMA_SNAPSHOT"

  run "$I"
  [ "$status" -eq 0 ]
}

# --- the engine ----------------------------------------------------------

@test "reports the engine as missing when it has not been built" {
  run "$I"
  [[ "$output" == *"engine"* ]] || false
  [[ "$output" == *"not built"* || "$output" == *"missing"* ]]
}

@test "reports the engine as present once built" {
  engine_present
  run "$I"
  [[ "$output" == *"$LEMMALOG_SRC/target/release/lemmalog-mcp"* ]]
}

@test "names bin/lemma-install as the fix when the engine is missing" {
  run "$I"
  [[ "$output" == *"lemma-install"* ]]
}

@test "does not nag about installing once engine and registration are both in place" {
  engine_present
  registered
  run "$I"
  [[ "$output" != *"lemma-install"* ]]
}

# --- the registration ----------------------------------------------------

@test "reports an absent MCP registration" {
  engine_present
  echo '{"projects":{}}' > "$AGENT_RIG_CLAUDE_JSON"

  run "$I"
  [[ "$output" == *"not registered"* || "$output" == *"registered"* ]]
  [[ "$output" == *"lemma-install"* ]]
}

@test "reports a user-scope registration as global" {
  engine_present
  registered

  run "$I"
  [[ "$output" == *"user"* || "$output" == *"global"* ]]
}

@test "flags a project-scoped entry that shadows the global one" {
  engine_present
  cat > "$AGENT_RIG_CLAUDE_JSON" <<EOF
{"mcpServers":{"lemmalog":{"env":{"LEMMALOG_MCP_PATH":"$AGENT_RIG_LEMMA_SNAPSHOT"}}},
 "projects":{"/somewhere/other-repo":{"mcpServers":{"lemmalog":{"type":"stdio"}}}}}
EOF

  run "$I"
  [[ "$output" == *"other-repo"* ]] || false
  [[ "$output" == *"shadow"* ]]
}

# --- the store -----------------------------------------------------------

@test "says the store does not exist yet rather than reporting zero facts" {
  engine_present
  registered

  run "$I"
  # "0 facts" reads like a working empty store; "not created" says nothing has
  # ever been asserted, which is a different and more actionable state.
  [[ "$output" == *"nothing asserted"* || "$output" == *"not created"* ]]
}

@test "counts the facts in the store" {
  engine_present
  registered
  store_with "s:agent-rig s:ruled_out s:per-repo-stores" \
             "s:agent-rig s:uses s:datalog" \
             "s:questor s:uses s:ruby"

  run "$I"
  [[ "$output" == *"3"* ]]
}

@test "breaks facts down by repo, since one global store spans many" {
  engine_present
  registered
  # in_repo is what makes a name a repo. Without it there is no way to tell
  # `agent-rig` (a repo) from `heredocs` (a topic) — they are both just symbols.
  new_store
  edge lemmalog-store in_repo agent-rig
  edge lemmalog-store ruled_out per-repo-stores
  edge sharding in_repo questor

  run "$I"
  [[ "$output" == *"agent-rig"* ]] || false
  [[ "$output" == *"questor"* ]]
}

# --- the queue -----------------------------------------------------------

@test "reports an empty queue as nothing pending" {
  run "$I"
  [[ "$output" == *"0"* || "$output" == *"none"* || "$output" == *"nothing"* ]]
}

@test "counts pending commits and breaks them down by repo" {
  queue agent-rig aaa1111 "first"
  queue agent-rig bbb2222 "second"
  queue home ccc3333 "elsewhere"

  run "$I"
  [[ "$output" == *"3"* ]] || false
  [[ "$output" == *"agent-rig"* ]] || false
  [[ "$output" == *"home"* ]]
}

@test "mentions /lemma-drain when commits are pending" {
  queue agent-rig aaa1111 "first"

  run "$I"
  [[ "$output" == *"lemma-drain"* ]]
}

@test "does not push /lemma-drain when the queue is empty" {
  engine_present
  registered

  run "$I"
  [[ "$output" != *"/lemma-drain"* ]]
}

# --- the reminder --------------------------------------------------------
#
# The stated reason this exists: a reminder of how to get status. Knowing the
# store holds 40 facts is useless without the next move.

@test "names the MCP tools for actually querying the store" {
  engine_present
  registered
  store_with "s:agent-rig s:uses s:datalog"

  run "$I"
  [[ "$output" == *"lemmalog_query"* ]] || false
  [[ "$output" == *"lemmalog_why"* ]]
}

@test "says the tools need a session restart when nothing is connected" {
  engine_present
  registered

  run "$I"
  [[ "$output" == *"restart"* || "$output" == *"session"* ]]
}

# --- repo attribution ----------------------------------------------------
#
# The store is global and keyed by repo, but /lemma-backfill puts the TOPIC on
# the left of a fact (`heredocs --because--> cascading-tool-denials`) and ties it
# to a repo with a separate `in_repo` edge. Counting only facts that literally
# spell the repo name therefore misses almost everything: a real run asserted 45
# facts and the brief reported 5.
#
# So attribution follows in_repo, and the label has to mean what it says.

edge() { # subj rel obj [valid_to]
  local vt="${4:-9223372036854775807}"
  printf 'FACT\tedge\t0.9\tep1\ts:%s s:%s s:%s i:100 i:%s i:100\n' "$1" "$2" "$3" "$vt" \
    >> "$AGENT_RIG_LEMMA_SNAPSHOT"
}

new_store() { printf 'LEMMALOG1\nNOW\t100\nRULES\t\n' > "$AGENT_RIG_LEMMA_SNAPSHOT"; }

@test "attributes a fact to a repo through its in_repo edge, not the literal name" {
  engine_present; registered; new_store
  edge heredocs in_repo agent-rig
  edge heredocs because cascading-tool-denials

  run "$I"
  # both facts belong to agent-rig: one names it, one is a topic tied to it
  [[ "$output" == *"2"*"agent-rig"* ]]
}

@test "keeps repos separate when the store spans several" {
  engine_present; registered; new_store
  edge heredocs in_repo agent-rig
  edge heredocs because cascading-tool-denials
  edge sharding in_repo questor

  run "$I"
  [[ "$output" == *"agent-rig"* ]] || false
  [[ "$output" == *"questor"* ]]
}

@test "reports facts belonging to no repo rather than silently dropping them" {
  engine_present; registered; new_store
  edge orphan uses something

  run "$I"
  [[ "$output" == *"no repo"* || "$output" == *"unattributed"* ]]
}

@test "excludes superseded facts — on record means still true" {
  engine_present; registered; new_store
  edge commit-message-file in_repo agent-rig
  edge commit-message-file location repo-level-tmp 200   # interval closed
  edge commit-message-file location dot-claude-tmp       # open

  run "$I"
  # in_repo + the open location = 2, not 3
  [[ "$output" == *"2"*"agent-rig"* ]] || false
  [[ "$output" != *"3  agent-rig"* ]]
}

# --- the enable gate -----------------------------------------------------
#
# The hooks ship OFF, gated on ~/.claude/lemmalog/enabled. That state has to be
# visible here or the rest of this report misleads: "8 commits pending" reads as
# a live loop when in fact nothing more will ever be queued.

@test "reports the hooks as off when the marker is absent" {
  engine_present; registered
  export AGENT_RIG_LEMMA_MARKER="$BATS_TEST_TMPDIR/absent"

  run "$I"
  [[ "$output" == *"hooks"* ]] || false
  [[ "$output" == *"off"* || "$output" == *"disabled"* ]]
}

@test "names the one-liner that turns them on" {
  engine_present; registered
  export AGENT_RIG_LEMMA_MARKER="$BATS_TEST_TMPDIR/absent"

  run "$I"
  [[ "$output" == *"touch"* ]]
}

@test "reports the hooks as on when the marker exists" {
  engine_present; registered
  export AGENT_RIG_LEMMA_MARKER="$BATS_TEST_TMPDIR/on"
  : > "$AGENT_RIG_LEMMA_MARKER"

  run "$I"
  [[ "$output" == *"hooks"* ]] || false
  [[ "$output" != *"touch"* ]]
}

@test "says a pending queue is frozen while the hooks are off" {
  engine_present; registered
  export AGENT_RIG_LEMMA_MARKER="$BATS_TEST_TMPDIR/absent"
  queue agent-rig aaa1111 "first"

  run "$I"
  # the queue is real and drainable; it just will not grow
  [[ "$output" == *"1 commits pending"* || "$output" == *"1 commit"* ]]
}
