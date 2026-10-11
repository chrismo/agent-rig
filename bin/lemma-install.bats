#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for bin/lemma-install.
#
# The lemmalog engine lives OUTSIDE this repo and is built per machine, so a
# fresh clone of agent-rig has the hooks but no engine. Traced on a simulated
# fresh machine: hooks/lemma-commit.sh queues fine (it has no dependency on
# lemmalog at all) and hooks/lemma-brief.sh nags at every SessionStart — but
# /lemma-drain, the only thing that can clear the queue, cannot run. The result
# is a permanent warning with no in-band fix. This script is that fix.
#
# It is deliberately NOT called from install.sh. The engine needs a Rust
# toolchain and a network clone; install.sh needs to stay a fast, offline,
# settings-merging script that works on a machine that will never use lemmalog.
#
# Note the inverted convention: hooks/lemma-*.sh must fail SILENTLY and exit 0,
# because a failing hook becomes model-visible noise on an unrelated tool call.
# This is a human-invoked installer, so the opposite holds — it fails loudly and
# exits non-zero, because a silent installer that did nothing is worse than one
# that says why.

I="$BATS_TEST_DIRNAME/lemma-install"

setup() {
  export LEMMALOG_SRC="$BATS_TEST_TMPDIR/lemmalog"
  export LEMMALOG_REPO_URL="https://example.invalid/lemmalog.git"
  export AGENT_RIG_LEMMA_SNAPSHOT="$BATS_TEST_TMPDIR/store.snapshot"
  export AGENT_RIG_CLAUDE_JSON="$BATS_TEST_TMPDIR/claude.json"

  # Stubs go first on PATH. Each one logs its argv so a test can assert on how
  # it was called, which is the only observable this script has — everything it
  # does that matters is a call out to cargo, git or claude.
  STUB="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB"
  export PATH="$STUB:$PATH"
  export STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
}

# Write a stub that records its arguments and exits with $2 (default 0).
stub() {
  local name="$1" code="${2:-0}"
  cat > "$STUB/$name" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "$name" "\$*" >> "$STUB_LOG"
exit $code
EOF
  chmod +x "$STUB/$name"
}

# Narrow PATH to the stubs plus the system directories. The script detects a
# missing tool with `command -v`, which an exit-127 stub would still satisfy —
# the file is there and executable — so the only honest simulation of "not
# installed" is a PATH the tool genuinely is not on. cargo lives in ~/.cargo/bin
# and claude in ~/.local/bin, so neither survives this; git does (/usr/bin/git),
# which is what the clone tests need.
only_stubs() {
  export PATH="$STUB:/usr/bin:/bin"
}

# A source tree that looks built: the binary cargo would have produced.
pretend_built() {
  mkdir -p "$LEMMALOG_SRC/target/release"
  : > "$LEMMALOG_SRC/target/release/lemmalog-mcp"
  chmod +x "$LEMMALOG_SRC/target/release/lemmalog-mcp"
}

# A source checkout that already exists, so nothing should clone.
pretend_cloned() {
  mkdir -p "$LEMMALOG_SRC"
  : > "$LEMMALOG_SRC/Cargo.toml"
}

calls() { cat "$STUB_LOG" 2>/dev/null || true; }

# --- refusing to start ---------------------------------------------------

@test "fails loudly when cargo is missing" {
  only_stubs
  stub claude
  pretend_cloned

  run "$I"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cargo"* ]]
}

@test "names the fix when cargo is missing, rather than just the problem" {
  only_stubs
  stub claude
  pretend_cloned

  run "$I"
  [[ "$output" == *"rustup"* || "$output" == *"rust"* ]]
}

@test "fails loudly when the claude CLI is missing" {
  only_stubs
  stub cargo
  pretend_cloned
  pretend_built

  run "$I"
  [ "$status" -ne 0 ]
  [[ "$output" == *"claude"* ]]
}

# --- getting the source --------------------------------------------------

@test "clones the engine when the source tree is absent" {
  stub cargo
  stub claude
  # A clone stub that logs its argv AND leaves behind what a real clone would,
  # so the run reaches the end. pretend_built cannot stand in here: it creates
  # $LEMMALOG_SRC, which is the very condition that suppresses the clone.
  cat > "$STUB/git" <<EOF
#!/usr/bin/env bash
printf 'git %s\n' "\$*" >> "$STUB_LOG"
mkdir -p "$LEMMALOG_SRC/target/release"
: > "$LEMMALOG_SRC/target/release/lemmalog-mcp"
chmod +x "$LEMMALOG_SRC/target/release/lemmalog-mcp"
EOF
  chmod +x "$STUB/git"

  run "$I"
  [[ "$(calls)" == *"git clone"* ]] || false
  [[ "$(calls)" == *"$LEMMALOG_REPO_URL"* ]] || false
  [[ "$(calls)" == *"$LEMMALOG_SRC"* ]]
}

@test "does not clone when the source tree is already present" {
  stub cargo
  stub claude
  stub git
  pretend_cloned
  pretend_built

  run "$I"
  [[ "$(calls)" != *"git clone"* ]]
}

# --- building ------------------------------------------------------------

@test "builds release with the mcp feature, which the binary requires" {
  stub cargo
  stub claude
  pretend_cloned
  pretend_built

  run "$I"
  [ "$status" -eq 0 ]
  [[ "$(calls)" == *"--release"* ]] || false
  [[ "$(calls)" == *"--features mcp"* ]]
}

@test "fails when the build produced no binary" {
  stub cargo
  stub claude
  pretend_cloned
  # deliberately no pretend_built

  run "$I"
  [ "$status" -ne 0 ]
  [[ "$output" == *"lemmalog-mcp"* ]]
}

@test "fails when cargo itself fails" {
  stub cargo 1
  stub claude
  pretend_cloned

  run "$I"
  [ "$status" -ne 0 ]
}

# --- registering ---------------------------------------------------------

@test "registers the MCP server at user scope, not the default local scope" {
  stub cargo
  stub claude
  pretend_cloned
  pretend_built

  run "$I"
  [ "$status" -eq 0 ]
  [[ "$(calls)" == *"mcp add"* ]] || false
  [[ "$(calls)" == *"--scope user"* ]]
}

@test "points the server at the snapshot via LEMMALOG_MCP_PATH" {
  stub cargo
  stub claude
  pretend_cloned
  pretend_built

  run "$I"
  [[ "$(calls)" == *"LEMMALOG_MCP_PATH=$AGENT_RIG_LEMMA_SNAPSHOT"* ]]
}

@test "registers the built binary by absolute path" {
  stub cargo
  stub claude
  pretend_cloned
  pretend_built

  run "$I"
  [[ "$(calls)" == *"$LEMMALOG_SRC/target/release/lemmalog-mcp"* ]]
}

@test "creates the snapshot directory, so the server can write on first assert" {
  stub cargo
  stub claude
  pretend_cloned
  pretend_built
  export AGENT_RIG_LEMMA_SNAPSHOT="$BATS_TEST_TMPDIR/deep/nested/store.snapshot"

  run "$I"
  [ -d "$BATS_TEST_TMPDIR/deep/nested" ]
}

# --- the shadowing registration ------------------------------------------
#
# A project-scoped entry wins over a user-scoped one inside that project. The
# machine this was written on had exactly that: lemmalog registered local to
# agent-rig, pointing at a snapshot that did not exist. Registering at user
# scope without saying so would leave the old entry silently in charge.

@test "warns when a project-scoped registration would shadow the new one" {
  stub cargo
  stub claude
  pretend_cloned
  pretend_built
  cat > "$AGENT_RIG_CLAUDE_JSON" <<'EOF'
{"projects":{"/Users/someone/modev/agent-rig":{"mcpServers":{"lemmalog":{"type":"stdio"}}}}}
EOF

  run "$I"
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-rig"* ]] || false
  [[ "$output" == *"mcp remove"* ]]
}

@test "says nothing about shadowing when there is no project-scoped entry" {
  stub cargo
  stub claude
  pretend_cloned
  pretend_built
  echo '{"projects":{}}' > "$AGENT_RIG_CLAUDE_JSON"

  run "$I"
  [ "$status" -eq 0 ]
  [[ "$output" != *"mcp remove"* ]]
}

@test "survives a missing or unreadable claude.json" {
  stub cargo
  stub claude
  pretend_cloned
  pretend_built
  export AGENT_RIG_CLAUDE_JSON="$BATS_TEST_TMPDIR/nope.json"

  run "$I"
  [ "$status" -eq 0 ]
}

# --- what the user is told next ------------------------------------------

@test "says the session must restart, since MCP servers connect at startup" {
  stub cargo
  stub claude
  pretend_cloned
  pretend_built

  run "$I"
  [[ "$output" == *"restart"* || "$output" == *"next session"* ]]
}

# --- idempotence ---------------------------------------------------------

@test "re-running is safe and does not duplicate the registration" {
  stub cargo
  stub claude
  pretend_cloned
  pretend_built

  run "$I"
  [ "$status" -eq 0 ]
  run "$I"
  [ "$status" -eq 0 ]
  # A second `mcp add` for a name that exists errors; the script must remove
  # first, or ask, rather than let the CLI reject it.
  [[ "$(calls)" == *"mcp remove"* || "$(grep -c 'mcp add' "$STUB_LOG")" -eq 2 ]]
}

# --- agreement with the read half ----------------------------------------
#
# hooks/lemma-brief.sh reads the snapshot directly to count facts, and this
# script tells the MCP server where to write it. Nothing forces those two paths
# to match — they are independent defaults in independent files, and a
# disagreement fails silently in the worst way: the store fills up correctly
# while the SessionStart brief reports it as empty forever. Pin them together.

@test "defaults to the same snapshot path hooks/lemma-brief.sh reads" {
  local brief="$BATS_TEST_DIRNAME/../hooks/lemma-brief.sh"
  local install_default brief_default
  install_default=$(grep -o 'AGENT_RIG_LEMMA_SNAPSHOT:-[^}]*' "$I" | head -1)
  brief_default=$(grep -o 'AGENT_RIG_LEMMA_SNAPSHOT:-[^}]*' "$brief" | head -1)

  [ -n "$install_default" ]
  [ "$install_default" = "$brief_default" ]
}

@test "the default store is not named for the contract experiment" {
  # experiments/lemmalog models one repo's internals contract. The MCP store is
  # a global one keyed by repo, per skills/lemma-drain/SKILL.md — naming it
  # agent-rig-contract implies a per-repo store that does not exist.
  run grep -c 'agent-rig-contract' "$I"
  [ "$output" -eq 0 ]
}
