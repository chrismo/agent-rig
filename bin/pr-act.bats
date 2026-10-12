#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for bin/pr-act (mechanical pipeline verbs). Only enroll/unenroll
# so far: the config the watcher reads.

PR_ACT="$BATS_TEST_DIRNAME/pr-act"

setup() {
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export GIT_CONFIG_GLOBAL="$TMP/gitconfig-global"
  export GIT_CONFIG_SYSTEM=/dev/null
  printf '[user]\n\temail = t@example.com\n\tname = Tester\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
  git init -q "$TMP/repo"
  cd "$TMP/repo"
  git commit -q --allow-empty -m init
  git switch -qc feat
}

repos() { git config --global --get-all pr-tend.repo || true; }

@test "runs under bash 5 via the bash5 shebang" {
  run head -1 "$PR_ACT"
  [ "$output" = "#!/usr/bin/env bash5" ]
}

@test "no verb: usage on stderr, nonzero" {
  run "$PR_ACT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "unknown verb fails" {
  run "$PR_ACT" frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown verb"* ]]
}

@test "enroll: marks the current branch and registers the repo" {
  run "$PR_ACT" enroll
  [ "$status" -eq 0 ]
  [ "$(git config branch.feat.pr-tend)" = true ]
  [ "$(repos)" = "$TMP/repo" ]
}

@test "enroll: a named branch" {
  git branch other
  run "$PR_ACT" enroll other
  [ "$status" -eq 0 ]
  [ "$(git config branch.other.pr-tend)" = true ]
  [ -z "$(git config branch.feat.pr-tend || true)" ]
}

@test "enroll: a missing branch fails" {
  run "$PR_ACT" enroll nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such branch"* ]]
}

@test "enroll: registers the repo only once" {
  "$PR_ACT" enroll
  git branch other
  "$PR_ACT" enroll other
  [ "$(repos | wc -l | tr -d ' ')" = 1 ]
}

@test "enroll: from a linked worktree, registers the main worktree" {
  git switch -q main
  git worktree add -q "$TMP/wt" feat
  cd "$TMP/wt"
  run "$PR_ACT" enroll
  [ "$status" -eq 0 ]
  [ "$(repos)" = "$TMP/repo" ]
}

@test "unenroll: clears the mark" {
  "$PR_ACT" enroll
  run "$PR_ACT" unenroll
  [ "$status" -eq 0 ]
  [ -z "$(git config branch.feat.pr-tend || true)" ]
}

@test "unenroll: a branch that was never enrolled is fine" {
  run "$PR_ACT" unenroll
  [ "$status" -eq 0 ]
}

@test "--help works outside a repo" {
  cd "$TMP"
  run "$PR_ACT" --help
  [[ "$output" == *"Usage"* ]]
}

@test "unenroll: a real config error is not swallowed" {
  "$PR_ACT" enroll
  touch .git/config.lock
  run "$PR_ACT" unenroll
  rm -f .git/config.lock
  [ "$status" -ne 0 ]
}
