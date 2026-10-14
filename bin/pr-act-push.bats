#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for `pr-act push`: publish a branch. A fast-forward is a plain
# push; rewritten history is force-pushed with a lease on the remote head,
# only when that head is in the branch's reflog (we put it there).
#
# Real git: a bare origin, our clone, and $TMP/other for other people's
# pushes. gh is a stub that fails: push never talks to GitHub.

PR_ACT="$BATS_TEST_DIRNAME/pr-act"

setup() {
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export GIT_CONFIG_GLOBAL="$TMP/gitconfig-global"
  export GIT_CONFIG_SYSTEM=/dev/null
  printf '[user]\n\temail = t@example.com\n\tname = Tester\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
  export PR_TEND_CONFIG="$TMP/global.json"
  mkdir -p "$TMP/fakebin"
  printf '#!/usr/bin/env bash\necho "gh called: $*" >&2\nexit 1\n' > "$TMP/fakebin/gh"
  chmod +x "$TMP/fakebin/gh"
  export PATH="$TMP/fakebin:$PATH"

  git init -q --bare "$TMP/origin.git"
  git clone -q "$TMP/origin.git" "$TMP/repo" 2>/dev/null
  cd "$TMP/repo"
  printf '%s\n' a b c > file.txt
  git add file.txt && git commit -qm init && git push -q origin main 2>/dev/null
  git clone -q "$TMP/origin.git" "$TMP/other" 2>/dev/null
  git switch -qc feat
  commit feat
  git push -q -u origin feat 2>/dev/null
}

commit() { echo "$1" >> file.txt && git commit -qam "$1"; }

# upstream <message>: someone else commits to feat on origin.
upstream() {
  (cd "$TMP/other" && git fetch -q origin && git checkout -q -B feat origin/feat \
     && echo "$1" >> other.txt && git add other.txt && git commit -qm "$1" && git push -q origin feat 2>/dev/null)
}

remote() { git ls-remote origin "refs/heads/$1" | cut -f1; }

@test "nothing to push: says so" {
  run "$PR_ACT" push
  [ "$status" -eq 0 ]
  [ "$output" = "nothing to push on feat" ]
}

@test "new commits: a plain push" {
  commit two
  run "$PR_ACT" push
  [ "$status" -eq 0 ]
  [ "$(remote feat)" = "$(git rev-parse feat)" ]
  [ "$output" = "pushed feat to origin (1 commit)" ]
}

@test "not on the remote yet: pushed, with the upstream set" {
  git switch -qc fresh
  commit fresh
  run "$PR_ACT" push
  [ "$status" -eq 0 ]
  [ "$(remote fresh)" = "$(git rev-parse fresh)" ]
  [ "$(git config branch.fresh.remote)" = origin ]
  [ "$output" = "pushed fresh to origin (new branch)" ]
}

@test "rewritten, and the remote head is ours: force-pushed with a lease" {
  git commit -q --amend -m "feat, reworded"
  run "$PR_ACT" push
  [ "$status" -eq 0 ]
  [ "$(remote feat)" = "$(git rev-parse feat)" ]
  [[ "$output" == "force-pushed feat to origin (rewritten; the remote head "*" was ours)" ]]
}

@test "rewritten, with someone else's commit on the remote: refused, even with --force" {
  upstream theirs
  theirs=$(remote feat)
  git commit -q --amend -m "feat, reworded"
  run "$PR_ACT" push
  [ "$status" -eq 1 ]
  [[ "$output" == *"origin/feat has 1 commit that isn't yours; not pushing over it"* ]]
  [[ "$output" == *"git log feat..origin/feat"* ]]
  [ "$(remote feat)" = "$theirs" ]
  run "$PR_ACT" push --force
  [ "$status" -eq 1 ]
  [ "$(remote feat)" = "$theirs" ]
}

@test "the remote is only ahead: refused, says how to take its commits" {
  upstream theirs
  run "$PR_ACT" push
  [ "$status" -eq 1 ]
  [[ "$output" == *"origin/feat has 1 commit you don't"* ]]
  [[ "$output" == *"git merge --ff-only origin/feat"* ]]
}

@test "the lease holds when the remote moves after the fetch" {
  # The hook runs after pr-act has fetched and chosen its lease, before the
  # push lands: someone else's push sneaks in between.
  cat > "$(git rev-parse --git-path hooks)/pre-push" <<EOF
#!/usr/bin/env bash
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
cd "$TMP/other" && git fetch -q origin && git checkout -q -B feat origin/feat \\
  && echo sneaky > sneaky.txt && git add sneaky.txt && git commit -qm sneaky && git push -q origin feat 2>/dev/null
EOF
  chmod +x "$(git rev-parse --git-path hooks)/pre-push"
  git commit -q --amend -m "feat, reworded"
  run "$PR_ACT" push
  [ "$status" -eq 1 ]
  [[ "$output" == *"origin/feat moved while pushing; nothing pushed"* ]]
  [ "$(git -C "$TMP/other" log -1 --format=%s origin/feat)" = sneaky ]
}

@test "taken over: refused unless --force" {
  commit two
  git config branch.feat.pr-lock chrismo
  run "$PR_ACT" push
  [ "$status" -eq 1 ]
  [[ "$output" == *"taken over"* ]]
  run "$PR_ACT" push --force
  [ "$status" -eq 0 ]
  [ "$(remote feat)" = "$(git rev-parse feat)" ]
}

@test "a named branch is pushed from wherever you are" {
  commit two
  git switch -q main
  run "$PR_ACT" push feat
  [ "$status" -eq 0 ]
  [ "$(remote feat)" = "$(git rev-parse feat)" ]
}

@test "the remote comes from settings.remote" {
  git remote rename origin up
  commit two
  printf '{"settings":{"remote":"up"}}\n' > "$PR_TEND_CONFIG"
  run "$PR_ACT" push
  [ "$status" -eq 0 ]
  [ "$output" = "pushed feat to up (1 commit)" ]
}
