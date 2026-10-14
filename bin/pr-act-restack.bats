#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for `pr-act restack`: move a branch onto its parent (or the
# default branch once the parent merged) with `rebase --onto`, check that its
# own change came through unchanged, and move refs/pr-tend/<b>/base. Never pushes.
#
# Real git (a bare origin, our clone, and $TMP/other for other people's
# pushes) and the real pr-state. Fake gh: answers from $GH/<branch>.json, else
# "no PR"; GH_FAIL_FOR=<branch> makes that branch's lookup fail.

PR_ACT="$BATS_TEST_DIRNAME/pr-act"

setup() {
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export GIT_CONFIG_GLOBAL="$TMP/gitconfig-global"
  export GIT_CONFIG_SYSTEM=/dev/null
  printf '[user]\n\temail = t@example.com\n\tname = Tester\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
  export PR_TEND_CONFIG="$TMP/global.json"
  export GH="$TMP/gh"
  mkdir -p "$GH" "$TMP/fakebin"
  cat > "$TMP/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
b=""
for a; do [[ $a == branch=* ]] && b=${a#branch=}; done
[[ ${GH_FAIL_FOR:-} == "$b" ]] && { echo "gh: boom for $b" >&2; exit 1; }
if [[ -f $GH/$b.json ]]; then cat "$GH/$b.json"
else echo '{"data":{"viewer":{"login":"me"},"repository":{"defaultBranchRef":{"name":"main"},"pullRequests":{"nodes":[]}}}}'
fi
EOF
  chmod +x "$TMP/fakebin/gh"
  export PATH="$BATS_TEST_DIRNAME:$TMP/fakebin:$PATH"

  git init -q --bare "$TMP/origin.git"
  git clone -q "$TMP/origin.git" "$TMP/repo" 2>/dev/null
  cd "$TMP/repo"
  printf '%s\n' a b c d e f g h > file.txt
  git add file.txt && git commit -qm init && git push -q origin main 2>/dev/null
  git clone -q "$TMP/origin.git" "$TMP/other" 2>/dev/null
  git switch -qc feat
  edit 's/^g$/G/' feat
  git push -q -u origin feat 2>/dev/null
}

# edit <perl-expr> <message>: change file.txt here and commit it.
edit() { perl -pi -e "$1" file.txt && git commit -qam "$2"; }

# upstream <branch> <perl-expr> [message]: someone else commits to <branch> on origin.
upstream() {
  (cd "$TMP/other" && git fetch -q origin && git checkout -q -B "$1" "origin/$1" \
     && perl -pi -e "$2" file.txt && git commit -qam "${3:-upstream}" && git push -q origin "$1" 2>/dev/null)
}

# merged_pr <branch> <head-sha>: gh says <branch>'s PR merged with that head.
merged_pr() {
  jq -n --arg b "$1" --arg h "$2" '{data: {viewer: {login: "me"},
    repository: {defaultBranchRef: {name: "main"},
      pullRequests: {nodes: [{number: 1, state: "MERGED", baseRefName: "main", headRefName: $b,
                              headRefOid: $h, isCrossRepository: false}]}}}}' > "$GH/$1.json"
}

remote_feat() { git ls-remote origin refs/heads/feat | cut -f1; }
base_pin() { git rev-parse -q --verify refs/pr-tend/feat/base || true; }

@test "help lists restack and push" {
  run "$PR_ACT" --help
  [[ "$output" == *"pr-act restack"* ]]
  [[ "$output" == *"pr-act push"* ]]
}

@test "onto the moved default branch: rebased, base pinned, not pushed" {
  upstream main 's/^b$/B/'
  before_remote=$(remote_feat)
  run "$PR_ACT" restack
  [ "$status" -eq 0 ]
  [ "$(git rev-parse feat^)" = "$(git rev-parse origin/main)" ]
  [ "$(git log --format=%s origin/main..feat)" = feat ]
  grep -qx B file.txt && grep -qx G file.txt
  [ "$(base_pin)" = "$(git rev-parse origin/main)" ]
  [ "$(remote_feat)" = "$before_remote" ]
  [[ "$output" == *"restacked feat onto origin/main"* ]]
  [[ "$output" == *"pr-act push"* ]]
}

@test "already on the target: nothing to do" {
  before=$(git rev-parse HEAD)
  run "$PR_ACT" restack
  [ "$status" -eq 0 ]
  [[ "$output" == *"already on origin/main"* ]]
  [ "$(git rev-parse HEAD)" = "$before" ]
  [ -z "$(base_pin)" ]
}

@test "fetches first: a move it hasn't seen yet still counts" {
  upstream main 's/^b$/B/'
  [ "$(git rev-parse origin/main)" != "$(git -C "$TMP/other" rev-parse main)" ]
  run "$PR_ACT" restack
  [ "$status" -eq 0 ]
  [ "$(git rev-parse feat^)" = "$(git -C "$TMP/other" rev-parse main)" ]
}

@test "parent squash-merged: lands on main with only its own commits" {
  git switch -q main
  git switch -qc A
  edit 's/^c$/C/' a1
  edit 's/^d$/D/' a2
  git push -q origin A 2>/dev/null
  a_head=$(git rev-parse A)
  git switch -qc child
  edit 's/^f$/F/' child
  git config branch.child.pr-parent A
  (cd "$TMP/other" && git fetch -q origin && git checkout -q main && git merge -q --squash origin/A \
     && git commit -qm "A (#1)" && git push -q origin main 2>/dev/null)
  merged_pr A "$a_head"
  run "$PR_ACT" restack
  [ "$status" -eq 0 ]
  [ "$(git rev-parse child^)" = "$(git rev-parse origin/main)" ]
  [ "$(git log --format=%s origin/main..child)" = child ]
  grep -qx C file.txt && grep -qx D file.txt && grep -qx F file.txt
  [ "$(git rev-parse refs/pr-tend/child/base)" = "$(git rev-parse origin/main)" ]
}

@test "stacked on an open parent: onto the parent, not main" {
  git switch -q main
  git switch -qc A
  edit 's/^c$/C/' a1
  git push -q origin A 2>/dev/null
  git switch -qc child
  edit 's/^f$/F/' child
  git config branch.child.pr-parent A
  upstream A 's/^d$/D/' a2
  upstream main 's/^b$/B/'
  run "$PR_ACT" restack
  [ "$status" -eq 0 ]
  [ "$(git rev-parse child^)" = "$(git rev-parse origin/A)" ]
  ! grep -qx B file.txt
}

@test "a restack that would conflict is refused; nothing moves" {
  upstream main 's/^g$/X/'
  before=$(git rev-parse HEAD)
  run "$PR_ACT" restack
  [ "$status" -eq 1 ]
  [[ "$output" == *"would conflict"* ]]
  [[ "$output" == *"git rebase --onto origin/main"* ]]
  [ "$(git rev-parse HEAD)" = "$before" ]
  [ -z "$(base_pin)" ]
}

@test "a conflict partway through is rolled back" {
  # Net, feat leaves line e alone, so the merge pr-state predicts is clean;
  # replaying e→E commit by commit still hits main's e→X.
  edit 's/^e$/E/' there
  edit 's/^E$/e/' back
  upstream main 's/^e$/X/'
  before=$(git rev-parse HEAD)
  run "$PR_ACT" restack
  [ "$status" -eq 1 ]
  [[ "$output" == *"rolled back"* ]]
  [ "$(git rev-parse HEAD)" = "$before" ]
  [ "$(git branch --show-current)" = feat ]
  [ -z "$(git status --porcelain)" ]
  [ ! -e "$(git rev-parse --git-path rebase-merge)" ]
  [ ! -e "$(git rev-parse --git-path rebase-apply)" ]
  [ -z "$(base_pin)" ]
}

@test "a change that comes out different is rolled back" {
  # main picks up the same edit as feat's first commit, so the rebase drops it
  # and the branch's diff shrinks.
  edit 's/^b$/B/' second
  upstream main 's/^g$/G/'
  before=$(git rev-parse HEAD)
  run "$PR_ACT" restack
  [ "$status" -eq 1 ]
  [[ "$output" == *"came out different"* ]]
  [[ "$output" == *"rolled back"* ]]
  [ "$(git rev-parse HEAD)" = "$before" ]
  [ -z "$(git status --porcelain)" ]
  [ -z "$(base_pin)" ]
}

@test "uncommitted changes are refused" {
  upstream main 's/^b$/B/'
  echo dirty >> file.txt
  run "$PR_ACT" restack
  [ "$status" -eq 1 ]
  [[ "$output" == *"uncommitted changes"* ]]
}

@test "taken over: refused unless --force" {
  upstream main 's/^b$/B/'
  git config branch.feat.pr-lock chrismo
  run "$PR_ACT" restack
  [ "$status" -eq 1 ]
  [[ "$output" == *"taken over"* ]]
  [[ "$output" == *"--force"* ]]
  run "$PR_ACT" restack --force
  [ "$status" -eq 0 ]
  [ "$(git rev-parse feat^)" = "$(git rev-parse origin/main)" ]
}

@test "a parent that isn't on the remote is refused with pr-state's reason" {
  git config branch.feat.pr-parent nosuch
  run "$PR_ACT" restack
  [ "$status" -eq 1 ]
  [[ "$output" == *"no origin/nosuch ref"* ]]
}

@test "a parent whose merged state is unknown is refused" {
  git switch -q main
  git switch -qc A
  edit 's/^c$/C/' a1
  git push -q origin A 2>/dev/null
  git switch -qc child
  edit 's/^f$/F/' child
  git config branch.child.pr-parent A
  upstream A 's/^d$/D/' a2
  GH_FAIL_FOR=A run "$PR_ACT" restack
  [ "$status" -eq 1 ]
  [[ "$output" == *"can't tell whether A merged"* ]]
}

@test "a branch not checked out anywhere is refused" {
  git switch -q main
  run "$PR_ACT" restack feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"isn't checked out in any worktree"* ]]
}

@test "a named branch is restacked in its own worktree" {
  upstream main 's/^b$/B/'
  git switch -q main
  git worktree add -q "$TMP/wt" feat
  run "$PR_ACT" restack feat
  [ "$status" -eq 0 ]
  [ "$(git rev-parse feat^)" = "$(git rev-parse origin/main)" ]
  grep -qx B "$TMP/wt/file.txt"
  [ "$(git branch --show-current)" = main ]
}
