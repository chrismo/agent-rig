#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for bin/pr-state (read-only: where a branch's PR stands).
#
# Real git: a bare origin, a working clone, and a second clone ("other") that
# plays everyone else pushing. GitHub is a fake `gh` that answers the one
# GraphQL query pr-state makes, from $GH_FIXTURES/<branch>.json.

PR_STATE="$BATS_TEST_DIRNAME/pr-state"

setup() {
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export GIT_CONFIG_GLOBAL="$TMP/gitconfig-global"
  export GIT_CONFIG_SYSTEM=/dev/null
  printf '[user]\n\temail = t@example.com\n\tname = Tester\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"

  export GH_FIXTURES="$TMP/gh"
  mkdir -p "$GH_FIXTURES" "$TMP/fakebin"
  cat > "$TMP/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ -n ${GH_FAKE_FAIL:-} ]]; then echo "$GH_FAKE_FAIL" >&2; exit 1; fi
b="" prev=""
for a; do
  case $a in
    branch=*)
      b=${a#branch=}
      # real gh -F turns numbers/booleans/null into JSON types; GitHub then rejects String!
      if [[ $prev == -F && $b =~ ^([0-9]+|true|false|null)$ ]]; then
        echo "gh: Variable \$branch of type String! was provided invalid value" >&2; exit 1
      fi ;;
  esac
  prev=$a
done
[[ -n $b ]] || { echo "fake gh: no branch= field in: $*" >&2; exit 2; }
if [[ ${GH_FAKE_FAIL_FOR:-} == "$b" ]]; then echo "gh: boom for $b" >&2; exit 1; fi
echo "$b" >> "$GH_FIXTURES/calls"
f="$GH_FIXTURES/${b//\//__}.json"
if [[ -f $f ]]; then cat "$f"; else
  echo '{"data":{"viewer":{"login":"me"},"repository":{"defaultBranchRef":{"name":"main"},"pullRequests":{"nodes":[]}}}}'
fi
EOF
  chmod +x "$TMP/fakebin/gh"
  export PATH="$TMP/fakebin:$PATH"

  git init -q --bare "$TMP/origin.git"
  git clone -q "$TMP/origin.git" "$TMP/work" 2>/dev/null
  git clone -q "$TMP/origin.git" "$TMP/other" 2>/dev/null
  cd "$TMP/work"
  printf 'one\ntwo\nthree\n' > file.txt
  git add file.txt && git commit -qm init && git push -q origin main 2>/dev/null
  git -C "$TMP/other" pull -q 2>/dev/null
}

commit() { # commit <file> <content> [repo]
  local repo=${3:-$TMP/work}
  printf '%s\n' "$2" > "$repo/$1"
  git -C "$repo" add "$1" && git -C "$repo" commit -qm "edit $1"
}

# pr_fixture <branch> [jq-assignments...] — the GraphQL answer for <branch>'s PR.
# Defaults: open, base main, head = that branch's tip, no checks, no threads.
pr_fixture() {
  local branch=$1; shift
  local head; head=$(git rev-parse -q --verify "$branch" || echo 0000)
  local node
  node=$(jq -n --arg head "$head" '{
    number: 7, url: "https://example/pr/7", state: "OPEN", isDraft: false, isCrossRepository: false,
    baseRefName: "main", headRefOid: $head, mergeable: "MERGEABLE", mergedAt: null,
    commits: {nodes: [{commit: {oid: $head, statusCheckRollup: null}}]},
    reviewThreads: {nodes: []}
  }')
  local a
  for a; do node=$(jq "$a" <<<"$node"); done
  jq -n --argjson node "$node" \
    '{data: {viewer: {login: "me"}, repository: {defaultBranchRef: {name: "main"}, pullRequests: {nodes: [$node]}}}}' \
    > "$GH_FIXTURES/${branch//\//__}.json"
}

checks() { # checks '<json array of contexts>'
  echo ".commits.nodes[0].commit.statusCheckRollup = {state: \"X\", contexts: {nodes: $1}}"
}

thread() { # thread <first-type> <first-login> <last-type> <last-login> [resolved] [outdated]
  printf '{id: "T-%s-%s", isResolved: %s, isOutdated: %s, path: "file.txt", line: 2,
    first: {nodes: [{author: {__typename: "%s", login: "%s"}}]},
    last: {nodes: [{author: {__typename: "%s", login: "%s"}}]}}' \
    "$2" "$4" "${5:-false}" "${6:-false}" "$1" "$2" "$3" "$4"
}

state() { run "$PR_STATE" --json "$@"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }; }
field() { jq -r "$1" <<<"$output"; }

# ── basics ───────────────────────────────────────────────────────────────────

@test "outside a git repo: fails with a message" {
  cd "$TMP"
  run "$PR_STATE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a git repository"* ]]
}

@test "runs under bash 5 via the bash5 shebang" {
  run head -1 "$PR_STATE"
  [ "$output" = "#!/usr/bin/env bash5" ]
}

@test "branch with no PR: pr is null and parent defaults to the default branch" {
  git switch -qc feat
  commit a.txt a
  state
  [ "$(field .branch)" = feat ]
  [ "$(field .pr)" = null ]
  [ "$(field .parent.name)" = main ]
  [ "$(field .parent.source)" = default ]
}

@test "a branch argument is inspected without switching to it" {
  git switch -qc feat
  commit a.txt a
  git switch -q main
  state feat
  [ "$(field .branch)" = feat ]
  [ "$(field .head)" = "$(git rev-parse feat)" ]
  [ "$(git branch --show-current)" = main ]
}

@test "makes exactly one gh call when the parent is the default branch" {
  git switch -qc feat
  pr_fixture feat
  state
  [ "$(wc -l < "$GH_FIXTURES/calls" | tr -d ' ')" = 1 ]
}

# ── O1 PR lookup ─────────────────────────────────────────────────────────────

@test "PR fields are reported" {
  git switch -qc feat
  commit a.txt a
  pr_fixture feat '.isDraft = true'
  state
  [ "$(field .pr.number)" = 7 ]
  [ "$(field .pr.state)" = OPEN ]
  [ "$(field .pr.draft)" = true ]
  [ "$(field .pr.base)" = main ]
  [ "$(field .pr.mergeable)" = MERGEABLE ]
}

@test "an open PR is preferred over a newer closed one for the same branch" {
  git switch -qc feat
  pr_fixture feat
  jq '.data.repository.pullRequests.nodes |= [(.[0] | .number = 9 | .state = "CLOSED"), .[0]]' \
    "$GH_FIXTURES/feat.json" > "$TMP/x" && mv "$TMP/x" "$GH_FIXTURES/feat.json"
  state
  [ "$(field .pr.number)" = 7 ]
}

@test "gh failing: git facts still reported, error recorded, exit 0" {
  git switch -qc feat
  commit a.txt a
  GH_FAKE_FAIL="gh: could not resolve host" state
  [ "$(field .pr)" = null ]
  [ "$(field .push.ahead)" = 1 ]
  [[ "$(field '.errors[0]')" == *"could not resolve host"* ]]
}

@test "a numeric branch name is sent to gh as a string" {
  git switch -qc 1234 && commit a.txt a
  pr_fixture 1234
  state
  [ "$(field .pr.number)" = 7 ]
  [ "$(field '.errors | length')" = 0 ]
}

@test "a branch name with a slash finds its PR" {
  git switch -qc chrismo/feat && commit a.txt a
  pr_fixture chrismo/feat
  state
  [ "$(field .pr.number)" = 7 ]
}

@test "a fork's PR with the same branch name is ignored" {
  git switch -qc feat && commit a.txt a
  pr_fixture feat
  jq '.data.repository.pullRequests.nodes |= [(.[0] | .number = 99 | .isCrossRepository = true | .headRepositoryOwner = {login: "stranger"}), .[0]]' \
    "$GH_FIXTURES/feat.json" > "$TMP/x" && mv "$TMP/x" "$GH_FIXTURES/feat.json"
  state
  [ "$(field .pr.number)" = 7 ]
}

@test "a PR from our own fork is kept" {
  git switch -qc feat && commit a.txt a
  pr_fixture feat '.isCrossRepository = true' '.headRepositoryOwner = {login: "me"}'
  state
  [ "$(field .pr.number)" = 7 ]
}

@test "gh failing: GitHub-derived answers are unknown, not clean" {
  git switch -qc feat && commit a.txt a
  GH_FAKE_FAIL="gh: down" state
  [ "$(field .fresh)" = null ]
  [ "$(field .threads.owed_bot)" = null ]
  [ "$(field .threads.owed_human)" = null ]
  [ "$(field .parent.merged)" = null ]
}

@test "parent lookup failing: parent merged is unknown" {
  git switch -qc parent && commit p.txt p && git push -q origin parent 2>/dev/null
  git switch -qc feat && commit c.txt c
  git config branch.feat.pr-parent parent
  GH_FAKE_FAIL_FOR=parent state
  [ "$(field .parent.merged)" = null ]
  [ "$(field .fresh)" = null ]
  [[ "$(field '.errors[0]')" == *"boom for parent"* ]]
}

@test "summary: errors are flagged" {
  git switch -qc feat && commit a.txt a
  GH_FAKE_FAIL="gh: down" run "$PR_STATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠ 1 error(s)"* ]]
}

# ── O2 parent ────────────────────────────────────────────────────────────────

@test "parent comes from the PR base when nothing is configured" {
  git switch -qc parent && commit p.txt p && git push -q origin parent 2>/dev/null
  git switch -qc feat && commit c.txt c
  pr_fixture feat '.baseRefName = "parent"'
  state
  [ "$(field .parent.name)" = parent ]
  [ "$(field .parent.source)" = pr ]
}

@test "configured pr-parent wins over the PR base" {
  git switch -qc parent && commit p.txt p && git push -q origin parent 2>/dev/null
  git switch -qc feat && commit c.txt c
  git config branch.feat.pr-parent parent
  pr_fixture feat '.baseRefName = "main"'
  state
  [ "$(field .parent.name)" = parent ]
  [ "$(field .parent.source)" = config ]
}

@test "parent PR state is looked up for a non-default parent" {
  git switch -qc parent && commit p.txt p && git push -q origin parent 2>/dev/null
  git switch -qc feat && commit c.txt c
  git config branch.feat.pr-parent parent
  pr_fixture parent '.number = 3'
  state
  [ "$(field .parent.pr.number)" = 3 ]
  [ "$(field .parent.merged)" = false ]
}

# ── O3 sync vs parent ────────────────────────────────────────────────────────

@test "sync: up to date with the parent" {
  git switch -qc feat && commit a.txt a
  state
  [ "$(field .sync.target)" = main ]
  [ "$(field .sync.behind)" = 0 ]
  [ "$(field .sync.up_to_date)" = true ]
}

@test "sync: parent moved, restack would be clean" {
  git switch -qc feat && commit a.txt a
  commit b.txt b "$TMP/other" && git -C "$TMP/other" push -q origin main 2>/dev/null
  git fetch -q
  state
  [ "$(field .sync.behind)" = 1 ]
  [ "$(field .sync.up_to_date)" = false ]
  [ "$(field .sync.conflict)" = false ]
}

@test "sync: parent moved, restack would conflict" {
  git switch -qc feat && commit file.txt "one
OURS
three"
  commit file.txt "one
THEIRS
three" "$TMP/other" && git -C "$TMP/other" push -q origin main 2>/dev/null
  git fetch -q
  state
  [ "$(field .sync.conflict)" = true ]
}

@test "sync: squash-merged parent retargets to main and replays only our change" {
  git switch -qc parent && commit p.txt p && git push -q origin parent 2>/dev/null
  local parent_sha; parent_sha=$(git rev-parse parent)
  git switch -qc feat && commit c.txt c
  git config branch.feat.pr-parent parent
  # the squash merge lands on main elsewhere (own message, or it hashes identical to parent's commit)
  commit p.txt p "$TMP/other" && git -C "$TMP/other" commit -q --amend -m "Squash parent (#3)"
  git -C "$TMP/other" push -q origin main 2>/dev/null
  git fetch -q
  pr_fixture parent '.state = "MERGED"' ".headRefOid = \"$parent_sha\""
  state
  [ "$(field .parent.merged)" = true ]
  [ "$(field .sync.target)" = main ]
  [ "$(field .sync.old_base)" = "$parent_sha" ]
  [ "$(field .sync.up_to_date)" = false ]
  [ "$(field .sync.conflict)" = false ]
}

@test "sync: the base pin is the old base when it is an ancestor" {
  git switch -qc feat && commit a.txt a
  local pin; pin=$(git rev-parse main)
  git update-ref refs/pr-tend/feat/base "$pin"
  state
  [ "$(field .sync.old_base)" = "$pin" ]
}

@test "sync: no shared history with the parent is reported, not guessed" {
  git switch -q --orphan feat && commit a.txt a
  state
  [ "$(field .sync.conflict)" = null ]
  [[ "$(field '.errors | join(" ")')" == *"no merge base"* ]]
}

# ── O4 local vs remote ───────────────────────────────────────────────────────

@test "push: unpushed branch has no remote" {
  git switch -qc feat && commit a.txt a && commit b.txt b
  state
  [ "$(field .push.remote_sha)" = null ]
  [ "$(field .push.ahead)" = 2 ]
}

@test "push: commits ahead of the pushed remote" {
  git switch -qc feat && commit a.txt a && git push -q -u origin feat 2>/dev/null
  commit b.txt b
  state
  [ "$(field .push.ahead)" = 1 ]
  [ "$(field .push.behind)" = 0 ]
  [ "$(field .push.diverged)" = false ]
}

@test "push: remote rewritten locally (amend after push) is ours" {
  git switch -qc feat && commit a.txt a && git push -q -u origin feat 2>/dev/null
  printf 'a2\n' > a.txt && git commit -qa --amend --no-edit
  state
  [ "$(field .push.diverged)" = true ]
  [ "$(field .push.remote_ours)" = true ]
}

@test "push: someone else's commit on the remote is not ours" {
  git switch -qc feat && commit a.txt a && git push -q -u origin feat 2>/dev/null
  git -C "$TMP/other" fetch -q && git -C "$TMP/other" switch -q feat
  commit x.txt x "$TMP/other" && git -C "$TMP/other" push -q origin feat 2>/dev/null
  git fetch -q
  state
  [ "$(field .push.behind)" = 1 ]
  [ "$(field .push.remote_ours)" = false ]
}

# ── freshness: GitHub's SHAs vs the local remote-tracking refs ──────────────

@test "fresh: remote-tracking refs match GitHub" {
  git switch -qc feat && commit a.txt a && git push -q -u origin feat 2>/dev/null
  pr_fixture feat
  state
  [ "$(field .fresh)" = true ]
}

@test "fresh: PR head moved on GitHub since the last fetch" {
  git switch -qc feat && commit a.txt a && git push -q -u origin feat 2>/dev/null
  git -C "$TMP/other" fetch -q && git -C "$TMP/other" switch -q feat
  commit x.txt x "$TMP/other" && git -C "$TMP/other" push -q origin feat 2>/dev/null
  pr_fixture feat ".headRefOid = \"$(git -C "$TMP/other" rev-parse HEAD)\""
  state
  [ "$(field .fresh)" = false ]
  [[ "$(field '.stale[0]')" == *"origin/feat"* ]]
}

@test "fresh: parent PR head moved on GitHub since the last fetch" {
  git switch -qc parent && commit p.txt p && git push -q origin parent 2>/dev/null
  git switch -qc feat && commit c.txt c
  git config branch.feat.pr-parent parent
  pr_fixture parent '.headRefOid = "1111111111111111111111111111111111111111"'
  state
  [ "$(field .fresh)" = false ]
  [[ "$(field '.stale[0]')" == *"origin/parent"* ]]
}

@test "summary: stale refs say to fetch" {
  git switch -qc feat && commit a.txt a && git push -q -u origin feat 2>/dev/null
  pr_fixture feat '.headRefOid = "1111111111111111111111111111111111111111"'
  run "$PR_STATE"
  [[ "$output" == *"stale: fetch"* ]]
}

# ── O5 CI ────────────────────────────────────────────────────────────────────

@test "ci: no checks reported" {
  git switch -qc feat && commit a.txt a
  pr_fixture feat
  state
  [ "$(field .ci.verdict)" = none ]
}

@test "ci: all success, skipped or neutral is green" {
  git switch -qc feat && commit a.txt a
  pr_fixture feat "$(checks '[{__typename:"CheckRun",name:"a",status:"COMPLETED",conclusion:"SUCCESS"},
    {__typename:"CheckRun",name:"b",status:"COMPLETED",conclusion:"SKIPPED"},
    {__typename:"StatusContext",context:"c",state:"SUCCESS"}]')"
  state
  [ "$(field .ci.verdict)" = green ]
  [ "$(field .ci.for_head)" = true ]
}

@test "ci: any failure is red, and names the failing checks" {
  git switch -qc feat && commit a.txt a
  pr_fixture feat "$(checks '[{__typename:"CheckRun",name:"lint",status:"COMPLETED",conclusion:"FAILURE"},
    {__typename:"StatusContext",context:"ext",state:"ERROR"},
    {__typename:"CheckRun",name:"test",status:"IN_PROGRESS",conclusion:null}]')"
  state
  [ "$(field .ci.verdict)" = red ]
  [ "$(field '.ci.failing | join(",")')" = "lint,ext" ]
}

@test "ci: unfinished checks are pending" {
  git switch -qc feat && commit a.txt a
  pr_fixture feat "$(checks '[{__typename:"CheckRun",name:"a",status:"COMPLETED",conclusion:"SUCCESS"},
    {__typename:"CheckRun",name:"test",status:"QUEUED",conclusion:null},
    {__typename:"StatusContext",context:"ext",state:"PENDING"}]')"
  state
  [ "$(field .ci.verdict)" = pending ]
  [ "$(field '.ci.pending | join(",")')" = "test,ext" ]
}

@test "ci: cancelled is inconclusive, not red" {
  git switch -qc feat && commit a.txt a
  pr_fixture feat "$(checks '[{__typename:"CheckRun",name:"a",status:"COMPLETED",conclusion:"SUCCESS"},
    {__typename:"CheckRun",name:"b",status:"COMPLETED",conclusion:"CANCELLED"}]')"
  state
  [ "$(field .ci.verdict)" = inconclusive ]
}

@test "ci: checks on a SHA other than local HEAD are flagged" {
  git switch -qc feat && commit a.txt a
  pr_fixture feat "$(checks '[{__typename:"CheckRun",name:"a",status:"COMPLETED",conclusion:"SUCCESS"}]')"
  commit b.txt b
  state
  [ "$(field .ci.for_head)" = false ]
}

# ── O6 review pins ───────────────────────────────────────────────────────────

@test "review: no pins" {
  git switch -qc feat && commit a.txt a
  state
  [ "$(field .review.local.status)" = none ]
  [ "$(field .review.bot.status)" = none ]
}

@test "review: pin at HEAD is covered" {
  git switch -qc feat && commit a.txt a
  git update-ref refs/pr-tend/feat/local HEAD
  state
  [ "$(field .review.local.status)" = covered ]
}

@test "review: pin behind HEAD leaves commits uncovered" {
  git switch -qc feat && commit a.txt a
  git update-ref refs/pr-tend/feat/bot HEAD
  commit b.txt b && commit c.txt c
  state
  [ "$(field .review.bot.status)" = uncovered ]
  [ "$(field .review.bot.uncovered)" = 2 ]
}

@test "review: a rebase that keeps the change still counts as covered" {
  git switch -qc feat && commit a.txt a
  git update-ref refs/pr-tend/feat/local HEAD
  commit b.txt b "$TMP/other" && git -C "$TMP/other" push -q origin main 2>/dev/null
  git fetch -q && git rebase -q origin/main
  state
  [ "$(field .review.local.status)" = rewritten-same ]
}

@test "review: a rewrite that changes the change is not covered" {
  git switch -qc feat && commit a.txt a
  git update-ref refs/pr-tend/feat/local HEAD
  printf 'different\n' > a.txt && git commit -qa --amend --no-edit
  state
  [ "$(field .review.local.status)" = rewritten-changed ]
}

@test "review: a rewritten pin that can't be compared is unknown, not covered" {
  git switch -q --orphan feat && commit a.txt a
  git update-ref refs/pr-tend/feat/local HEAD
  printf 'different\n' > a.txt && git commit -qa --amend --no-edit
  state
  [ "$(field .review.local.status)" = unknown ]
}

# ── O7 threads owed a reply ──────────────────────────────────────────────────

@test "threads: unresolved and last word not ours are owed, split bot vs human" {
  git switch -qc feat && commit a.txt a
  git config pr-tend.botLogin marge
  pr_fixture feat ".reviewThreads.nodes = [
    $(thread Bot copilot Bot copilot),
    $(thread User marge User marge),
    $(thread User alice User alice),
    $(thread User bob User me),
    $(thread User carol User carol true),
    $(thread Bot copilot Bot copilot false true)]"
  state
  [ "$(field .threads.owed_bot)" = 3 ]
  [ "$(field .threads.owed_human)" = 1 ]
  [ "$(field .threads.outdated)" = 1 ]
  [ "$(field '.threads.items | length')" = 4 ]
}

# ── O8 session ───────────────────────────────────────────────────────────────

@test "session: enrollment, harness, session and lock come from branch config" {
  git switch -qc feat
  git config branch.feat.pr-tend true
  git config branch.feat.pr-harness pi
  git config branch.feat.pr-session abc-123
  git config branch.feat.pr-lock chrismo
  state
  [ "$(field .session.enrolled)" = true ]
  [ "$(field .session.harness)" = pi ]
  [ "$(field .session.id)" = abc-123 ]
  [ "$(field .session.locked)" = true ]
}

@test "session: unenrolled branch" {
  git switch -qc feat
  state
  [ "$(field .session.enrolled)" = false ]
  [ "$(field .session.locked)" = false ]
}

# ── summary line ─────────────────────────────────────────────────────────────

@test "summary: default output is one line naming the key facts" {
  git switch -qc feat && commit a.txt a
  pr_fixture feat "$(checks '[{__typename:"CheckRun",name:"lint",status:"COMPLETED",conclusion:"FAILURE"}]')" \
    ".reviewThreads.nodes = [$(thread User alice User alice)]"
  run "$PR_STATE"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == feat* ]] || false
  [[ "$output" == *"#7"* ]] || false
  [[ "$output" == *"CI red"* ]] || false
  [[ "$output" == *"1 human"* ]]
}

@test "summary: no PR" {
  git switch -qc feat && commit a.txt a
  run "$PR_STATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no PR"* ]] || false
  [[ "$output" == *"1 unpushed"* ]]
}
