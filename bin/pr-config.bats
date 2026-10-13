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

# ── setting: scalar and list settings, git config as the fallback ───────────

@test "setting: a number from the global file" {
  write_global '{"settings":{"stepTimeout":900}}'
  run "$PR_CONFIG" setting stepTimeout
  [ "$status" -eq 0 ]
  [ "$output" = 900 ]
}

@test "setting: a string keeps its emoji and trailing space" {
  write_global '{"settings":{"replyPrefix":"🤖 "}}'
  out=$("$PR_CONFIG" setting replyPrefix; echo x)
  [ "$out" = $'🤖 \nx' ]
}

@test "setting: false is a value, not unset" {
  write_global '{"settings":{"autofix":false}}'
  run "$PR_CONFIG" setting autofix
  [ "$status" -eq 0 ]
  [ "$output" = false ]
}

@test "setting: a list prints one element per line" {
  write_global '{"settings":{"botLogin":["alice","bob"]}}'
  run "$PR_CONFIG" setting botLogin
  [ "$status" -eq 0 ]
  [ "$output" = $'alice\nbob' ]
}

@test "setting: the branch file overrides the global file" {
  write_global '{"settings":{"verify":"make test"}}'
  write_branch feat '{"settings":{"verify":"make quick"}}'
  run "$PR_CONFIG" setting verify
  [ "$output" = "make quick" ]
}

@test "setting: a named branch reads that branch's file" {
  write_global '{"settings":{"verify":"make test"}}'
  write_branch other '{"settings":{"verify":"make other"}}'
  run "$PR_CONFIG" setting verify other
  [ "$output" = "make other" ]
}

@test "setting: null in the branch file unsets it and skips git config" {
  write_global '{"settings":{"verify":"make test"}}'
  write_branch feat '{"settings":{"verify":null}}'
  git config pr-tend.verify "from git"
  run "$PR_CONFIG" setting verify
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "setting: absent from the files falls back to git config" {
  git config pr-tend.verify "from git"
  run "$PR_CONFIG" setting verify
  [ "$status" -eq 0 ]
  [ "$output" = "from git" ]
}

@test "setting: the git config fallback returns every value of a multi-valued key" {
  git config --add pr-tend.botLogin alice
  git config --add pr-tend.botLogin bob
  run "$PR_CONFIG" setting botLogin
  [ "$output" = $'alice\nbob' ]
}

@test "setting: a value in the files wins over git config" {
  write_global '{"settings":{"verify":"from file"}}'
  git config pr-tend.verify "from git"
  run "$PR_CONFIG" setting verify
  [ "$output" = "from file" ]
}

@test "setting: set nowhere exits 3 (unset) with no output" {
  run "$PR_CONFIG" setting verify
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "setting: works outside a repo from the global file" {
  write_global '{"settings":{"interval":120}}'
  cd "$TMP"
  run "$PR_CONFIG" setting interval
  [ "$status" -eq 0 ]
  [ "$output" = 120 ]
}

@test "setting: works outside a repo from global git config" {
  git config --global pr-tend.notify "echo hi"
  cd "$TMP"
  run "$PR_CONFIG" setting notify
  [ "$output" = "echo hi" ]
}

@test "setting: a key that could carry git or query syntax is refused" {
  run "$PR_CONFIG" setting 'a.b'
  [ "$status" -ne 0 ]
  [[ "$output" == *"setting key"* ]]
}

@test "setting: invalid JSON names the file and fails" {
  printf '{not json\n' > "$PR_TEND_CONFIG"
  run "$PR_CONFIG" setting verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"$PR_TEND_CONFIG"* ]]
}

@test "setting: no key is a usage error" {
  run "$PR_CONFIG" setting
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
}

# ── the super binary: pinned asdf install, not the shim ─────────────────────

# fake_super <dir> <label> — a super that logs its label, then runs the real one.
fake_super() {
  mkdir -p "$1"
  printf '#!/usr/bin/env bash\nprintf "%s\\n" >> "$SUPER_LOG"\nexec "$REAL_SUPER" "$@"\n' "$2" > "$1/super"
  chmod +x "$1/super"
}

pin_setup() {
  export REAL_SUPER SUPER_LOG="$TMP/super-calls" ASDF_DATA_DIR="$TMP/asdf"
  # A real binary, not the asdf shim: the shim breaks once HOME or ASDF_DATA_DIR move.
  REAL_SUPER=
  local c
  for c in /opt/homebrew/bin/super "$HOME"/.asdf/installs/superdb/*/bin/super; do
    [[ -x $c ]] && REAL_SUPER=$c
  done
  [[ -n $REAL_SUPER ]] || skip "no real super binary on this machine"
  fake_super "$TMP/decoy" shim
  PATH="$TMP/decoy:$PATH"
  write_global "$GLOBAL"
}

@test "super: the pinned asdf install is used, not the PATH shim" {
  pin_setup
  fake_super "$ASDF_DATA_DIR/installs/superdb/9.9.9/bin" pinned
  ASDF_SUPERDB_VERSION=9.9.9 run "$PR_CONFIG" get build
  [ "$status" -eq 0 ]
  [ "$(cat "$SUPER_LOG")" = pinned ]
}

@test "super: the version comes from ~/.tool-versions when the env var is unset" {
  pin_setup
  fake_super "$ASDF_DATA_DIR/installs/superdb/9.9.9/bin" pinned
  mkdir -p "$TMP/home"
  printf 'nodejs 1.0.0\nsuperdb 9.9.9\n' > "$TMP/home/.tool-versions"
  HOME="$TMP/home" run "$PR_CONFIG" get build
  [ "$status" -eq 0 ]
  [ "$(cat "$SUPER_LOG")" = pinned ]
}

@test "super: the env var wins over ~/.tool-versions" {
  pin_setup
  fake_super "$ASDF_DATA_DIR/installs/superdb/9.9.9/bin" pinned
  fake_super "$ASDF_DATA_DIR/installs/superdb/1.1.1/bin" wrong
  mkdir -p "$TMP/home"
  printf 'superdb 1.1.1\n' > "$TMP/home/.tool-versions"
  HOME="$TMP/home" ASDF_SUPERDB_VERSION=9.9.9 run "$PR_CONFIG" get build
  [ "$(cat "$SUPER_LOG")" = pinned ]
}

@test "super: no installed pin falls back to super on PATH" {
  pin_setup
  ASDF_SUPERDB_VERSION=9.9.9 run "$PR_CONFIG" get build
  [ "$status" -eq 0 ]
  [ "$(cat "$SUPER_LOG")" = shim ]
}

@test "super: no pin at all falls back to super on PATH" {
  pin_setup
  mkdir -p "$TMP/home"
  HOME="$TMP/home" run "$PR_CONFIG" get build
  [ "$status" -eq 0 ]
  [ "$(cat "$SUPER_LOG")" = shim ]
}

# ── get --harness: a forced harness picks its own blocks ────────────────────

@test "get --harness: uses that harness's blocks instead of the configured one" {
  write_global "$GLOBAL"
  run "$PR_CONFIG" get --harness pi build
  [ "$status" -eq 0 ]
  [ "$output" = '{"harness":"pi","provider":"openrouter","model":"cheap","effort":"medium"}' ]
}

@test "get --harness: the step's block for that harness still applies" {
  write_global "$GLOBAL"
  run "$PR_CONFIG" get --harness claude address
  [ "$output" = '{"harness":"claude","model":"strong","effort":"high"}' ]
  run "$PR_CONFIG" get --harness pi address
  [ "$(jq -r .model <<<"$output")" = cheaper ]
}

@test "get --harness: an empty value means not forced" {
  write_global "$GLOBAL"
  run "$PR_CONFIG" get --harness "" address
  [ "$(jq -r .harness <<<"$output")" = pi ]
}

@test "get --harness: a name that could carry query syntax is refused" {
  run "$PR_CONFIG" get --harness 'x" | values 1 | values "' build
  [ "$status" -ne 0 ]
  [[ "$output" == *"harness name"* ]]
}

@test "get --harness: needs a value" {
  run "$PR_CONFIG" get --harness
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
}

# ── setting --no-branch: no branch context (the watcher) ────────────────────

@test "setting --no-branch: ignores the branch file" {
  write_global '{"settings":{"verify":"global"}}'
  write_branch feat '{"settings":{"verify":"branch"}}'
  run "$PR_CONFIG" setting --no-branch verify
  [ "$status" -eq 0 ]
  [ "$output" = global ]
}

@test "setting --no-branch: still falls back to git config" {
  git config pr-tend.verify "from git"
  run "$PR_CONFIG" setting --no-branch verify
  [ "$output" = "from git" ]
}

@test "setting --no-branch: a null in the branch file does not unset it" {
  write_global '{"settings":{"verify":"global"}}'
  write_branch feat '{"settings":{"verify":null}}'
  run "$PR_CONFIG" setting --no-branch verify
  [ "$output" = global ]
}

@test "setting --no-branch: needs a key" {
  run "$PR_CONFIG" setting --no-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "setting: a config error exits 1, never the unset code" {
  printf '{not json\n' > "$PR_TEND_CONFIG"
  run "$PR_CONFIG" setting verify
  [ "$status" -eq 1 ]
  run "$PR_CONFIG" setting 'a.b'
  [ "$status" -eq 1 ]
}

@test "get: an explicit branch outside a repo fails instead of using the global file alone" {
  write_global "$GLOBAL"
  cd "$TMP"
  run "$PR_CONFIG" get build somebranch
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a git repository"* ]]
}

@test "get: an unreadable global file fails before super runs" {
  printf '{not json\n' > "$PR_TEND_CONFIG"
  run "$PR_CONFIG" get build
  [ "$status" -ne 0 ]
  [[ "$output" == *"$PR_TEND_CONFIG"* ]]
}
