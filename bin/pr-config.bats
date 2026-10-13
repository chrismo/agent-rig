#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for bin/pr-config: resolves harness / model / effort / provider for
# one step from the global XDG file, overlaid by the branch-local file.

PR_CONFIG="$BATS_TEST_DIRNAME/pr-config"

setup() {
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export GIT_CONFIG_GLOBAL="$TMP/gitconfig-global"
  export GIT_CONFIG_SYSTEM=/dev/null
  printf '[user]\n\temail = t@example.com\n\tname = Tester\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
  export PR_TEND_CONFIG="$TMP/global.json"
  git init -q "$TMP/repo"
  cd "$TMP/repo"
  git commit -q --allow-empty -m init
  git switch -qc feat
}

# branch_file <branch> — where pr-config keeps a branch's overrides.
branch_file() { echo "$TMP/repo/.git/pr-tend/$1.json"; }

write_global() { printf '%s\n' "$1" > "$PR_TEND_CONFIG"; }
write_branch() { mkdir -p "$(dirname "$(branch_file "$1")")"; printf '%s\n' "$2" > "$(branch_file "$1")"; }

# get_field <step> <field> — one resolved field as raw text ("" when absent).
get_field() { "$PR_CONFIG" get "$1" | jq -r --arg f "$2" '.[$f] // ""'; }

GLOBAL='{"harness":"claude",
  "harnesses":{"claude":{"model":"strong","effort":"high"},
               "pi":{"provider":"openrouter","model":"cheap","effort":"medium"}},
  "steps":{"address":{"harness":"pi","pi":{"model":"cheaper","effort":null}},
           "review":{"claude":{"effort":"max"}}}}'

@test "runs under bash 5 via the bash5 shebang" {
  run head -1 "$PR_CONFIG"
  [ "$output" = "#!/usr/bin/env bash5" ]
}

@test "no verb: usage on stderr, nonzero" {
  run "$PR_CONFIG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "unknown verb fails" {
  run "$PR_CONFIG" frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown verb"* ]]
}

@test "get: a step name that could carry query syntax is refused" {
  write_global "$GLOBAL"
  run "$PR_CONFIG" get 'x" | values 1 | values "'
  [ "$status" -ne 0 ]
  [[ "$output" == *"step name"* ]]
}

@test "get: no config anywhere resolves to the claude default" {
  run "$PR_CONFIG" get address
  [ "$status" -eq 0 ]
  [ "$output" = '{"harness":"claude"}' ]
}

@test "get: the harness block supplies model and effort" {
  write_global "$GLOBAL"
  [ "$(get_field build model)" = strong ]
  [ "$(get_field build effort)" = high ]
}

@test "get: a step block on the same harness overrides the harness block" {
  write_global "$GLOBAL"
  [ "$(get_field review effort)" = max ]
  [ "$(get_field review model)" = strong ]
}

@test "get: a step can select another harness and gets that harness's block" {
  write_global "$GLOBAL"
  [ "$(get_field address harness)" = pi ]
  [ "$(get_field address provider)" = openrouter ]
  [ "$(get_field address model)" = cheaper ]
}

@test "get: null in a step block clears the inherited key" {
  write_global "$GLOBAL"
  run "$PR_CONFIG" get address
  [ "$(jq 'has("effort")' <<<"$output")" = false ]
}

@test "get: the branch file overrides the global step block" {
  write_global "$GLOBAL"
  write_branch feat '{"steps":{"address":{"pi":{"model":"branch-model"}}}}'
  [ "$(get_field address model)" = branch-model ]
  [ "$(get_field address provider)" = openrouter ]
}

@test "get: the branch file overrides the global harness block" {
  write_global "$GLOBAL"
  write_branch feat '{"harnesses":{"claude":{"model":"branch-strong"}}}'
  [ "$(get_field build model)" = branch-strong ]
  [ "$(get_field build effort)" = high ]
}

@test "get: the branch file can switch a step's harness" {
  write_global "$GLOBAL"
  write_branch feat '{"steps":{"review":{"harness":"pi","pi":{"effort":null,"model":"b2"}}}}'
  run "$PR_CONFIG" get review
  [ "$output" = '{"harness":"pi","provider":"openrouter","model":"b2"}' ]
}

@test "get: the branch file can clear a global value with null" {
  write_global "$GLOBAL"
  write_branch feat '{"harnesses":{"claude":{"effort":null}}}'
  run "$PR_CONFIG" get build
  [ "$(jq 'has("effort")' <<<"$output")" = false ]
}

@test "get: a branch file with no global file still resolves" {
  write_branch feat '{"harnesses":{"claude":{"model":"only-branch"}}}'
  [ "$(get_field build model)" = only-branch ]
}

@test "get: another branch's file is not read" {
  write_global "$GLOBAL"
  write_branch other '{"harnesses":{"claude":{"model":"other-model"}}}'
  [ "$(get_field build model)" = strong ]
}

@test "get: a named branch reads that branch's file" {
  write_global "$GLOBAL"
  write_branch other '{"harnesses":{"claude":{"model":"other-model"}}}'
  run "$PR_CONFIG" get build other
  [ "$(jq -r .model <<<"$output")" = other-model ]
}

@test "get: a branch name with a slash maps to one flat file" {
  write_global "$GLOBAL"
  git switch -qc topic/sub
  mkdir -p .git/pr-tend
  printf '%s\n' '{"harnesses":{"claude":{"model":"slashed"}}}' > ".git/pr-tend/topic%2Fsub.json"
  [ "$(get_field build model)" = slashed ]
}

@test "get: a linked worktree reads the same branch file as the main one" {
  write_global "$GLOBAL"
  write_branch wt '{"harnesses":{"claude":{"model":"from-wt"}}}'
  git worktree add -q "$TMP/wt" -b wt
  cd "$TMP/wt"
  [ "$(get_field build model)" = from-wt ]
}

@test "get: XDG_CONFIG_HOME locates the global file when PR_TEND_CONFIG is unset" {
  unset PR_TEND_CONFIG
  export XDG_CONFIG_HOME="$TMP/xdg"
  mkdir -p "$XDG_CONFIG_HOME/pr-tend"
  printf '%s\n' "$GLOBAL" > "$XDG_CONFIG_HOME/pr-tend/config.json"
  [ "$(get_field build model)" = strong ]
}

@test "get: invalid JSON names the file and fails" {
  printf '{not json\n' > "$PR_TEND_CONFIG"
  run "$PR_CONFIG" get build
  [ "$status" -ne 0 ]
  [[ "$output" == *"$PR_TEND_CONFIG"* ]]
}

@test "get: detached HEAD with no branch named fails" {
  git switch -q --detach
  run "$PR_CONFIG" get build
  [ "$status" -ne 0 ]
  [[ "$output" == *"detached"* ]]
}

@test "init: copies the global file to the branch file" {
  write_global "$GLOBAL"
  run "$PR_CONFIG" init
  [ "$status" -eq 0 ]
  cmp "$PR_TEND_CONFIG" "$(branch_file feat)"
}

@test "init: a named branch" {
  write_global "$GLOBAL"
  git branch other
  run "$PR_CONFIG" init other
  [ "$status" -eq 0 ]
  [ -f "$(branch_file other)" ]
  [ ! -e "$(branch_file feat)" ]
}

@test "init: refuses to overwrite an existing branch file" {
  write_global "$GLOBAL"
  write_branch feat '{"harness":"pi"}'
  run "$PR_CONFIG" init
  [ "$status" -ne 0 ]
  [[ "$output" == *"exists"* ]]
  [ "$(jq -r .harness "$(branch_file feat)")" = pi ]
}

@test "init: --force overwrites it" {
  write_global "$GLOBAL"
  write_branch feat '{"harness":"pi"}'
  run "$PR_CONFIG" init --force
  [ "$status" -eq 0 ]
  cmp "$PR_TEND_CONFIG" "$(branch_file feat)"
}

@test "init: no global file writes an empty overlay" {
  run "$PR_CONFIG" init
  [ "$status" -eq 0 ]
  [ "$(jq -c . "$(branch_file feat)")" = '{}' ]
}

@test "init: a missing branch fails" {
  run "$PR_CONFIG" init nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such branch"* ]]
}
