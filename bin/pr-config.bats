#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for bin/pr-config and lib/pr-config.sh: built-in defaults, the
# global XDG file and the branch file, merged in SuperDB. `step` is what one
# pipeline step runs with; `get` reads any dotted path.

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

# get_field <step> <field> — one field of the step view as raw text ("" when absent).
get_field() { "$PR_CONFIG" step "$1" | jq -r --arg f "$2" '.[$f] // ""'; }

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

@test "step: a step name that could carry query syntax is refused" {
  write_global "$GLOBAL"
  run "$PR_CONFIG" step 'x" | values 1 | values "'
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown step"* ]]
}

@test "step: no config anywhere resolves to the claude default" {
  run "$PR_CONFIG" step address
  [ "$status" -eq 0 ]
  [ "$output" = '{"harness":"claude"}' ]
}

@test "step: the harness block supplies model and effort" {
  write_global "$GLOBAL"
  [ "$(get_field describe model)" = strong ]
  [ "$(get_field describe effort)" = high ]
}

@test "step: a step block on the same harness overrides the harness block" {
  write_global "$GLOBAL"
  [ "$(get_field review effort)" = max ]
  [ "$(get_field review model)" = strong ]
}

@test "step: a step can select another harness and gets that harness's block" {
  write_global "$GLOBAL"
  [ "$(get_field address harness)" = pi ]
  [ "$(get_field address provider)" = openrouter ]
  [ "$(get_field address model)" = cheaper ]
}

@test "step: null in a step block clears the inherited key" {
  write_global "$GLOBAL"
  run "$PR_CONFIG" step address
  [ "$(jq 'has("effort")' <<<"$output")" = false ]
}

@test "step: the branch file overrides the global step block" {
  write_global "$GLOBAL"
  write_branch feat '{"steps":{"address":{"pi":{"model":"branch-model"}}}}'
  [ "$(get_field address model)" = branch-model ]
  [ "$(get_field address provider)" = openrouter ]
}

@test "step: the branch file overrides the global harness block" {
  write_global "$GLOBAL"
  write_branch feat '{"harnesses":{"claude":{"model":"branch-strong"}}}'
  [ "$(get_field describe model)" = branch-strong ]
  [ "$(get_field describe effort)" = high ]
}

@test "step: the branch file can switch a step's harness" {
  write_global "$GLOBAL"
  write_branch feat '{"steps":{"review":{"harness":"pi","pi":{"effort":null,"model":"b2"}}}}'
  run "$PR_CONFIG" step review
  [ "$output" = '{"harness":"pi","model":"b2","provider":"openrouter"}' ]
}

@test "step: the branch file can clear a global value with null" {
  write_global "$GLOBAL"
  write_branch feat '{"harnesses":{"claude":{"effort":null}}}'
  run "$PR_CONFIG" step describe
  [ "$(jq 'has("effort")' <<<"$output")" = false ]
}

@test "step: a branch file with no global file still resolves" {
  write_branch feat '{"harnesses":{"claude":{"model":"only-branch"}}}'
  [ "$(get_field describe model)" = only-branch ]
}

@test "step: another branch's file is not read" {
  write_global "$GLOBAL"
  write_branch other '{"harnesses":{"claude":{"model":"other-model"}}}'
  [ "$(get_field describe model)" = strong ]
}

@test "step: a named branch reads that branch's file" {
  write_global "$GLOBAL"
  write_branch other '{"harnesses":{"claude":{"model":"other-model"}}}'
  run "$PR_CONFIG" step describe other
  [ "$(jq -r .model <<<"$output")" = other-model ]
}

@test "step: a branch name with a slash maps to one flat file" {
  write_global "$GLOBAL"
  git switch -qc topic/sub
  mkdir -p .git/pr-tend
  printf '%s\n' '{"harnesses":{"claude":{"model":"slashed"}}}' > ".git/pr-tend/topic%2Fsub.json"
  [ "$(get_field describe model)" = slashed ]
}

@test "step: a linked worktree reads the same branch file as the main one" {
  write_global "$GLOBAL"
  write_branch wt '{"harnesses":{"claude":{"model":"from-wt"}}}'
  git worktree add -q "$TMP/wt" -b wt
  cd "$TMP/wt"
  [ "$(get_field describe model)" = from-wt ]
}

@test "step: XDG_CONFIG_HOME locates the global file when PR_TEND_CONFIG is unset" {
  unset PR_TEND_CONFIG
  export XDG_CONFIG_HOME="$TMP/xdg"
  mkdir -p "$XDG_CONFIG_HOME/pr-tend"
  printf '%s\n' "$GLOBAL" > "$XDG_CONFIG_HOME/pr-tend/config.json"
  [ "$(get_field describe model)" = strong ]
}

@test "step: invalid JSON names the file and fails" {
  printf '{not json\n' > "$PR_TEND_CONFIG"
  run "$PR_CONFIG" step describe
  [ "$status" -ne 0 ]
  [[ "$output" == *"$PR_TEND_CONFIG"* ]]
}

@test "step: detached HEAD with no branch named reads the global file only" {
  write_global "$GLOBAL"
  write_branch feat '{"harnesses":{"claude":{"model":"branch"}}}'
  git switch -q --detach
  [ "$(get_field describe model)" = strong ]
}

@test "init: writes an empty overrides file and says where" {
  write_global "$GLOBAL"
  run "$PR_CONFIG" init
  [ "$status" -eq 0 ]
  [ "$output" = "wrote $(branch_file feat)" ]
  [ "$(jq -cS . "$(branch_file feat)")" = '{"harnesses":{"claude":{},"pi":{}},"settings":{},"steps":{}}' ]
  [ "$(get_field describe model)" = strong ]
}

@test "init: later edits to the global file still reach the branch" {
  write_global "$GLOBAL"
  "$PR_CONFIG" init
  "$PR_CONFIG" set --global harnesses.claude.model newer
  "$PR_CONFIG" set --global settings.verify "make check"
  [ "$("$PR_CONFIG" get harnesses.claude.model)" = newer ]
  [ "$("$PR_CONFIG" get settings.verify)" = "make check" ]
}

@test "init: from a linked worktree, names the shared file in the main repo" {
  write_global "$GLOBAL"
  git worktree add -q "$TMP/wt" -b wt
  cd "$TMP/wt"
  run "$PR_CONFIG" init
  [ "$status" -eq 0 ]
  [ "$output" = "wrote $(branch_file wt)" ]
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
  [ "$(jq -cS . "$(branch_file feat)")" = '{"harnesses":{"claude":{},"pi":{}},"settings":{},"steps":{}}' ]
}

@test "init: needs no global file" {
  run "$PR_CONFIG" init
  [ "$status" -eq 0 ]
  [ -f "$(branch_file feat)" ]
  [ "$("$PR_CONFIG" get settings.remote)" = origin ]
}

@test "init --global: writes a skeleton that resolves to the defaults" {
  export PR_TEND_CONFIG="$TMP/new/dir/config.json"
  run "$PR_CONFIG" init --global
  [ "$status" -eq 0 ]
  [[ "$output" == *"$PR_TEND_CONFIG"* ]]
  [ "$(jq -c 'keys' "$PR_TEND_CONFIG")" = '["harness","harnesses","settings","steps"]' ]
  [ "$(jq -c '.harnesses | keys' "$PR_TEND_CONFIG")" = '["claude","pi"]' ]
  run "$PR_CONFIG" step address
  [ "$output" = '{"harness":"claude"}' ]
  run "$PR_CONFIG" get settings.remote
  [ "$output" = origin ]
}

@test "init --global: refuses to overwrite, --force overwrites" {
  write_global '{"harness":"pi"}'
  run "$PR_CONFIG" init --global
  [ "$status" -ne 0 ]
  [[ "$output" == *"exists"* ]]
  [ "$(jq -r .harness "$PR_TEND_CONFIG")" = pi ]
  run "$PR_CONFIG" init --global --force
  [ "$status" -eq 0 ]
  [ "$(jq -r .harness "$PR_TEND_CONFIG")" = claude ]
}

@test "init --global: works outside a repo" {
  cd "$TMP"
  run "$PR_CONFIG" init --global
  [ "$status" -eq 0 ]
  [ -f "$PR_TEND_CONFIG" ]
}

@test "--help: every verb is listed" {
  run "$PR_CONFIG" --help
  [ "$status" -eq 0 ]
  [[ "$output" =~ init\ +--global ]]
  [[ "$output" == *"pr-config get"* ]]
  [[ "$output" == *"pr-config step"* ]]
  [[ "$output" == *"pr-config files"* ]]
  [[ "$output" == *"pr-config show"* ]]
  [[ "$output" != *"pr-config setting"* ]]
}

@test "init: a missing branch fails" {
  run "$PR_CONFIG" init nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such branch"* ]]
}

# ── files: where the layers live ────────────────────────────────────────────

@test "files: lists the global and branch paths, marking missing ones" {
  run "$PR_CONFIG" files
  [ "$status" -eq 0 ]
  [ "$output" = "global  $PR_TEND_CONFIG  (missing)
branch  $(branch_file feat)  (missing)" ]
}

@test "files: existing files are listed without a mark" {
  write_global '{}'
  write_branch feat '{}'
  run "$PR_CONFIG" files
  [ "$output" = "global  $PR_TEND_CONFIG
branch  $(branch_file feat)" ]
}

@test "files: a named branch, and a slash in its name" {
  run "$PR_CONFIG" files topic/sub
  [ "$(sed -n 2p <<<"$output")" = "branch  $TMP/repo/.git/pr-tend/topic%2Fsub.json  (missing)" ]
}

@test "files: from a linked worktree, the branch file is in the main repo" {
  git worktree add -q "$TMP/wt" -b wt
  cd "$TMP/wt"
  run "$PR_CONFIG" files
  [ "$(sed -n 2p <<<"$output")" = "branch  $(branch_file wt)  (missing)" ]
}

@test "files: detached HEAD or outside a repo says why there's no branch file" {
  git switch -q --detach
  run "$PR_CONFIG" files
  [ "$status" -eq 0 ]
  [ "$(sed -n 2p <<<"$output")" = "branch  (none: detached HEAD)" ]
  cd "$TMP"
  run "$PR_CONFIG" files
  [ "$status" -eq 0 ]
  [ "$(sed -n 2p <<<"$output")" = "branch  (none: not a git repository)" ]
}

@test "files --no-branch: only the global file" {
  run "$PR_CONFIG" files --no-branch
  [ "$output" = "global  $PR_TEND_CONFIG  (missing)" ]
}

@test "files: an explicit branch outside a repo fails" {
  cd "$TMP"
  run "$PR_CONFIG" files feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a git repository"* ]]
}

# ── show: the whole merged config ───────────────────────────────────────────

@test "show: with no files, the built-in defaults, pretty-printed" {
  run "$PR_CONFIG" show
  [ "$status" -eq 0 ]
  [ "$(jq -r .harness <<<"$output")" = claude ]
  [ "$(jq -r .settings.remote <<<"$output")" = origin ]
  [ "$(wc -l <<<"$output")" -gt 1 ]
}

@test "show: the branch file over the global file over the defaults, nulls applied" {
  write_global '{"harnesses":{"claude":{"model":"opus"}},"settings":{"stepTimeout":900,"verify":"make"}}'
  write_branch feat '{"harnesses":{"claude":{"effort":"max"}},"settings":{"stepTimeout":null}}'
  run "$PR_CONFIG" show
  [ "$status" -eq 0 ]
  [ "$(jq -c .harnesses.claude <<<"$output")" = '{"effort":"max","model":"opus"}' ]
  [ "$(jq -r .settings.stepTimeout <<<"$output")" = 1800 ]
  [ "$(jq -r .settings.verify <<<"$output")" = make ]
}

@test "show: a named branch, and --no-branch" {
  write_global '{"settings":{"verify":"global"}}'
  write_branch other '{"settings":{"verify":"other"}}'
  write_branch feat '{"settings":{"verify":"feat"}}'
  [ "$("$PR_CONFIG" show other | jq -r .settings.verify)" = other ]
  [ "$("$PR_CONFIG" show --no-branch | jq -r .settings.verify)" = global ]
}

@test "show: an unreadable file fails and names it" {
  printf '{not json\n' > "$PR_TEND_CONFIG"
  run "$PR_CONFIG" show
  [ "$status" -eq 1 ]
  [[ "$output" == *"$PR_TEND_CONFIG"* ]]
}

# ── get: any dotted path; built-in defaults under the files ────────────────

@test "get: a number from the global file" {
  write_global '{"settings":{"stepTimeout":900}}'
  run "$PR_CONFIG" get settings.stepTimeout
  [ "$status" -eq 0 ]
  [ "$output" = 900 ]
}

@test "get: a string keeps its emoji and trailing space" {
  write_global '{"settings":{"replyPrefix":"🤖 "}}'
  out=$("$PR_CONFIG" get settings.replyPrefix; echo x)
  [ "$out" = $'🤖 \nx' ]
}

@test "get: a list prints one element per line" {
  write_global '{"settings":{"botLogin":["alice","bob"]}}'
  run "$PR_CONFIG" get settings.botLogin
  [ "$status" -eq 0 ]
  [ "$output" = $'alice\nbob' ]
}

@test "get: an object prints as JSON" {
  write_global "$GLOBAL"
  run "$PR_CONFIG" get harnesses.pi
  [ "$status" -eq 0 ]
  [ "$output" = '{"effort":"medium","model":"cheap","provider":"openrouter"}' ]
}

@test "get --json: lists, strings and numbers as JSON" {
  write_global '{"settings":{"botLogin":["alice","bob"]}}'
  [ "$("$PR_CONFIG" get --json settings.botLogin)" = '["alice","bob"]' ]
  [ "$("$PR_CONFIG" get --json settings.replyPrefix)" = '"🤖 "' ]
  [ "$("$PR_CONFIG" get --json settings.stepTimeout)" = 1800 ]
  [ "$("$PR_CONFIG" get --json settings.botIgnore)" = '[]' ]
}

@test "get: the branch file overrides the global file" {
  write_global '{"settings":{"verify":"make test"}}'
  write_branch feat '{"settings":{"verify":"make quick"}}'
  run "$PR_CONFIG" get settings.verify
  [ "$output" = "make quick" ]
}

@test "get: a named branch reads that branch's file" {
  write_global '{"settings":{"verify":"make test"}}'
  write_branch other '{"settings":{"verify":"make other"}}'
  run "$PR_CONFIG" get settings.verify other
  [ "$output" = "make other" ]
}

@test "get: null in the branch file skips the global file and takes the built-in default" {
  write_global '{"settings":{"stepTimeout":900}}'
  write_branch feat '{"settings":{"stepTimeout":null}}'
  run "$PR_CONFIG" get settings.stepTimeout
  [ "$status" -eq 0 ]
  [ "$output" = 1800 ]
}

@test "get: null on a whole block clears everything under it" {
  write_global "$GLOBAL"
  write_branch feat '{"steps":{"address":null}}'
  run "$PR_CONFIG" get steps.address
  [ "$status" -eq 3 ]
  [ "$(get_field address harness)" = claude ]
}

@test "get: null on a key with no default is unset (exit 3)" {
  write_global '{"harnesses":{"claude":{"model":"global"}}}'
  write_branch feat '{"harnesses":{"claude":{"model":null}}}'
  run "$PR_CONFIG" get harnesses.claude.model
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "get: a plain value where a block belongs is an error" {
  write_global '{"harnesses":{"pi":"oops"}}'
  run "$PR_CONFIG" get harnesses.pi.model
  [ "$status" -eq 1 ]
  [[ "$output" == *"harnesses.pi: cannot cast to"*": oops" ]]
}

@test "get: a path set nowhere exits 3 with no output" {
  run "$PR_CONFIG" get settings.foo
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  run "$PR_CONFIG" get settings.remote.deeper
  [ "$status" -eq 3 ]
}

@test "get: git config pr-tend.<key> is not read" {
  git config pr-tend.verify "from git"
  git config --global pr-tend.remote upstream
  run "$PR_CONFIG" get settings.verify
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$("$PR_CONFIG" get settings.remote)" = origin ]
}

@test "get: works outside a repo from the global file" {
  write_global '{"settings":{"interval":120}}'
  cd "$TMP"
  run "$PR_CONFIG" get settings.interval
  [ "$status" -eq 0 ]
  [ "$output" = 120 ]
}

@test "get: a path that isn't plain dotted names is refused" {
  for p in 'a..b' '.a' 'a.' 'a b' 'a"]|values 1|values this["' '' 'a[0]'; do
    run "$PR_CONFIG" get "$p"
    [ "$status" -eq 1 ] || { echo "accepted: [$p] $status"; false; }
    [[ "$output" == *"invalid path"* ]] || [[ "$output" == *"Usage"* ]]
  done
}

@test "get: invalid JSON names the file and fails" {
  printf '{not json\n' > "$PR_TEND_CONFIG"
  run "$PR_CONFIG" get settings.verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"$PR_TEND_CONFIG"* ]]
}

@test "get: a file that holds more than one JSON value is refused" {
  printf '{}\n{}\n' > "$PR_TEND_CONFIG"
  run "$PR_CONFIG" get settings.verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"$PR_TEND_CONFIG"* ]]
}

@test "get: no path is a usage error" {
  run "$PR_CONFIG" get
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "setting: the old verb is gone" {
  run "$PR_CONFIG" setting verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown verb"* ]]
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
  # A real 0.3.0 binary, not the asdf shim: the shim breaks once HOME or
  # ASDF_DATA_DIR move.
  REAL_SUPER=
  local c
  for c in /opt/homebrew/bin/super "$HOME"/.asdf/installs/superdb/*/bin/super; do
    [[ -x $c && $("$c" -version 2>/dev/null) == "Version: v0.3.0" ]] || continue
    REAL_SUPER=$c
    break
  done
  [[ -n $REAL_SUPER ]] || skip "no real super 0.3.0 binary on this machine"
  fake_super "$TMP/decoy" shim
  PATH="$TMP/decoy:$PATH"
  write_global "$GLOBAL"
}

@test "super: the pinned asdf install is used, not the PATH shim" {
  pin_setup
  fake_super "$ASDF_DATA_DIR/installs/superdb/9.9.9/bin" pinned
  ASDF_SUPERDB_VERSION=9.9.9 run "$PR_CONFIG" step describe
  [ "$status" -eq 0 ]
  [ "$(sort -u "$SUPER_LOG")" = pinned ]
}

@test "super: the version comes from ~/.tool-versions when the env var is unset" {
  pin_setup
  fake_super "$ASDF_DATA_DIR/installs/superdb/9.9.9/bin" pinned
  mkdir -p "$TMP/home"
  printf 'nodejs 1.0.0\nsuperdb 9.9.9\n' > "$TMP/home/.tool-versions"
  HOME="$TMP/home" run "$PR_CONFIG" step describe
  [ "$status" -eq 0 ]
  [ "$(sort -u "$SUPER_LOG")" = pinned ]
}

@test "super: the env var wins over ~/.tool-versions" {
  pin_setup
  fake_super "$ASDF_DATA_DIR/installs/superdb/9.9.9/bin" pinned
  fake_super "$ASDF_DATA_DIR/installs/superdb/1.1.1/bin" wrong
  mkdir -p "$TMP/home"
  printf 'superdb 1.1.1\n' > "$TMP/home/.tool-versions"
  HOME="$TMP/home" ASDF_SUPERDB_VERSION=9.9.9 run "$PR_CONFIG" step describe
  [ "$(sort -u "$SUPER_LOG")" = pinned ]
}

@test "super: no installed pin falls back to super on PATH" {
  pin_setup
  ASDF_SUPERDB_VERSION=9.9.9 run "$PR_CONFIG" step describe
  [ "$status" -eq 0 ]
  [ "$(sort -u "$SUPER_LOG")" = shim ]
}

# old_super <dir> <version> — a super that reports <version>, otherwise the real one.
old_super() {
  mkdir -p "$1"
  printf '#!/usr/bin/env bash\n[[ $1 == -version ]] && { echo "Version: v%s"; exit 0; }\nexec "$REAL_SUPER" "$@"\n' "$2" > "$1/super"
  chmod +x "$1/super"
}

@test "super: any version but 0.3.0 is refused, naming the one found" {
  pin_setup
  old_super "$ASDF_DATA_DIR/installs/superdb/0.2.0/bin" 0.2.0
  ASDF_SUPERDB_VERSION=0.2.0 run "$PR_CONFIG" step describe
  [ "$status" -eq 1 ]
  [ "$output" = "pr-config: needs super 0.3.0, but $ASDF_DATA_DIR/installs/superdb/0.2.0/bin/super is v0.2.0" ]
}

@test "super: one that won't run is refused" {
  pin_setup
  mkdir -p "$TMP/broken"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/broken/super"
  chmod +x "$TMP/broken/super"
  mkdir -p "$TMP/home"
  HOME="$TMP/home" PATH="$TMP/broken:$PATH" run "$PR_CONFIG" step describe
  [ "$status" -eq 1 ]
  [ "$output" = "pr-config: needs super 0.3.0, but super didn't run" ]
}

@test "super: every command checks the version before reading config" {
  pin_setup
  old_super "$ASDF_DATA_DIR/installs/superdb/0.2.0/bin" 0.2.0
  # Nothing real gets installed if pr-watch install gets past the check.
  mkdir -p "$TMP/home" "$TMP/fakebin"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/launchctl-calls"\n' "$TMP" > "$TMP/fakebin/launchctl"
  chmod +x "$TMP/fakebin/launchctl"
  local cmd
  for cmd in "pr-config show" "pr-state" "pr-act address" "pr-watch install"; do
    HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" PR_WATCH_LAUNCH_AGENTS="$TMP/agents" \
      PR_TEND_STATE_DIR="$TMP/state" STATUS_DIR="$TMP/status" ASDF_SUPERDB_VERSION=0.2.0 \
      run "$BATS_TEST_DIRNAME"/$cmd
    [ "$status" -eq 1 ]
    [[ "$output" == *"needs super 0.3.0, but "*" is v0.2.0"* ]]
  done
  [ ! -e "$TMP/launchctl-calls" ]
  [ ! -e "$TMP/agents" ]
}

@test "super: the version is checked once per command, not per query" {
  pin_setup
  fake_super "$ASDF_DATA_DIR/installs/superdb/0.3.0/bin" pinned
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "$SUPER_LOG"\nexec "$REAL_SUPER" "$@"\n' \
    > "$ASDF_DATA_DIR/installs/superdb/0.3.0/bin/super"
  write_branch feat '{"settings":{"verify":"make"}}'
  ASDF_SUPERDB_VERSION=0.3.0 run "$PR_CONFIG" show
  [ "$status" -eq 0 ]
  [ "$(grep -c -- -version "$SUPER_LOG")" -eq 1 ]
  [ "$(wc -l < "$SUPER_LOG")" -gt 3 ]
}

@test "super: help needs no super" {
  pin_setup
  old_super "$ASDF_DATA_DIR/installs/superdb/0.2.0/bin" 0.2.0
  local cmd
  for cmd in pr-config pr-state pr-act pr-watch; do
    ASDF_SUPERDB_VERSION=0.2.0 run "$BATS_TEST_DIRNAME/$cmd" --help
    [ "$status" -eq 0 ]
  done
}

@test "super: no pin at all falls back to super on PATH" {
  pin_setup
  mkdir -p "$TMP/home"
  HOME="$TMP/home" run "$PR_CONFIG" step describe
  [ "$status" -eq 0 ]
  [ "$(sort -u "$SUPER_LOG")" = shim ]
}

# ── step --harness: a forced harness picks its own blocks ───────────────────

@test "step --harness: uses that harness's blocks instead of the configured one" {
  write_global "$GLOBAL"
  run "$PR_CONFIG" step --harness pi describe
  [ "$status" -eq 0 ]
  [ "$output" = '{"harness":"pi","effort":"medium","model":"cheap","provider":"openrouter"}' ]
}

@test "step --harness: the step's block for that harness still applies" {
  write_global "$GLOBAL"
  run "$PR_CONFIG" step --harness claude address
  [ "$output" = '{"harness":"claude","effort":"high","model":"strong"}' ]
  run "$PR_CONFIG" step --harness pi address
  [ "$(jq -r .model <<<"$output")" = cheaper ]
}

@test "step --harness: an empty value means not forced" {
  write_global "$GLOBAL"
  run "$PR_CONFIG" step --harness "" address
  [ "$(jq -r .harness <<<"$output")" = pi ]
}

@test "step --harness: a name that could carry query syntax is refused" {
  run "$PR_CONFIG" step --harness 'x" | values 1 | values "' describe
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown harness"* ]]
}

@test "step --harness: needs a value" {
  run "$PR_CONFIG" step --harness
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
}

# ── get --no-branch: no branch context (the watcher) ────────────────────────

@test "get --no-branch: ignores the branch file" {
  write_global '{"settings":{"verify":"global"}}'
  write_branch feat '{"settings":{"verify":"branch"}}'
  run "$PR_CONFIG" get --no-branch settings.verify
  [ "$status" -eq 0 ]
  [ "$output" = global ]
}

@test "get --no-branch: a null in the branch file does not unset it" {
  write_global '{"settings":{"verify":"global"}}'
  write_branch feat '{"settings":{"verify":null}}'
  run "$PR_CONFIG" get --no-branch settings.verify
  [ "$output" = global ]
}

@test "get --no-branch: needs a path" {
  run "$PR_CONFIG" get --no-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "get: a config error exits 1, never the unset code" {
  printf '{not json\n' > "$PR_TEND_CONFIG"
  run "$PR_CONFIG" get settings.verify
  [ "$status" -eq 1 ]
  run "$PR_CONFIG" get 'a..b'
  [ "$status" -eq 1 ]
}

@test "step: an explicit branch outside a repo fails instead of using the global file alone" {
  write_global "$GLOBAL"
  cd "$TMP"
  run "$PR_CONFIG" step describe somebranch
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a git repository"* ]]
  run "$PR_CONFIG" get settings.verify somebranch
  [ "$status" -eq 1 ]
}

@test "step: an unreadable global file fails" {
  printf '{not json\n' > "$PR_TEND_CONFIG"
  run "$PR_CONFIG" step describe
  [ "$status" -ne 0 ]
  [[ "$output" == *"$PR_TEND_CONFIG"* ]]
}

# ── set / unset ─────────────────────────────────────────────────────────────

@test "set: writes the current branch's file and get sees it" {
  write_global "$GLOBAL"
  run "$PR_CONFIG" set harnesses.claude.model opus
  [ "$status" -eq 0 ]
  [ "$(jq -c . "$(branch_file feat)")" = '{"harnesses":{"claude":{"model":"opus"}}}' ]
  [ "$(get_field describe model)" = opus ]
  [ "$(get_field describe effort)" = high ]
}

@test "set --global: updates the global file and keeps its other keys" {
  write_global "$GLOBAL"
  run "$PR_CONFIG" set --global settings.verify "make test"
  [ "$status" -eq 0 ]
  [ "$(jq -r .settings.verify "$PR_TEND_CONFIG")" = "make test" ]
  [ "$(jq -r .harnesses.pi.provider "$PR_TEND_CONFIG")" = openrouter ]
  [ ! -e "$(branch_file feat)" ]
}

@test "set --global: creates the global file and works outside a repo" {
  cd "$TMP"
  run "$PR_CONFIG" set --global settings.interval 120
  [ "$status" -eq 0 ]
  [ "$(jq -r .settings.interval "$PR_TEND_CONFIG")" = 120 ]
}

@test "set --branch: writes that branch's file" {
  git branch other
  run "$PR_CONFIG" set --branch other steps.address.harness pi
  [ "$status" -eq 0 ]
  [ "$(jq -r .steps.address.harness "$(branch_file other)")" = pi ]
  [ ! -e "$(branch_file feat)" ]
}

@test "set: a missing branch fails" {
  run "$PR_CONFIG" set --branch nope settings.verify x
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such branch"* ]]
}

@test "set: values are strings by default, keeping spaces and emoji" {
  run "$PR_CONFIG" set settings.replyPrefix "🤖 "
  [ "$(jq -c .settings.replyPrefix "$(branch_file feat)")" = '"🤖 "' ]
  run "$PR_CONFIG" set settings.stepTimeout 900
  [ "$(jq -c .settings.stepTimeout "$(branch_file feat)")" = '"900"' ]
}

@test "set --json: numbers, lists and null" {
  "$PR_CONFIG" set --json settings.stepTimeout 900
  "$PR_CONFIG" set --json settings.botLogin '["a","b"]'
  "$PR_CONFIG" set --json steps.address.pi.effort null
  [ "$(jq -c . "$(branch_file feat)")" = '{"settings":{"stepTimeout":900,"botLogin":["a","b"]},"steps":{"address":{"pi":{"effort":null}}}}' ]
}

@test "set --json: more than one value, or one that adds keys, is refused" {
  write_branch feat '{"harness":"pi"}'
  for v in '1 2' '1, "harness": "claude"' ''; do
    run "$PR_CONFIG" set --json settings.x "$v"
    [ "$status" -ne 0 ] || { echo "accepted: [$v]"; false; }
  done
  [ "$(jq -c . "$(branch_file feat)")" = '{"harness":"pi"}' ]
}

@test "set: a string value with quotes, backslashes and a newline round-trips" {
  v=$'say "hi" \\ there\nline two'
  "$PR_CONFIG" set settings.verify "$v"
  [ "$("$PR_CONFIG" get settings.verify)" = "$v" ]
}

@test "set: a value with other control characters is refused" {
  run "$PR_CONFIG" set settings.verify $'a\x01b'
  [ "$status" -eq 1 ]
  [[ "$output" == *"control characters"* ]]
  [ ! -e "$(branch_file feat)" ]
}

@test "set: keeps empty blocks and the other keys in the file" {
  "$PR_CONFIG" init --global
  "$PR_CONFIG" set --global settings.verify make
  [ "$(jq -c '.harnesses' "$PR_TEND_CONFIG")" = '{"claude":{},"pi":{}}' ]
  [ "$(jq -c '.steps' "$PR_TEND_CONFIG")" = '{}' ]
}

@test "set --json: invalid JSON is refused and the file is untouched" {
  write_branch feat '{"harness":"pi"}'
  run "$PR_CONFIG" set --json settings.botLogin '[a'
  [ "$status" -ne 0 ]
  [ "$(jq -c . "$(branch_file feat)")" = '{"harness":"pi"}' ]
}

@test "set: a null set this way clears the inherited value" {
  write_global "$GLOBAL"
  "$PR_CONFIG" set --json harnesses.claude.effort null
  run "$PR_CONFIG" step describe
  [ "$(jq 'has("effort")' <<<"$output")" = false ]
}

@test "set: a path that isn't plain dotted names is refused" {
  for p in 'a..b' '.a' 'a.' 'a b' 'a.$x' '' 'a[0]'; do
    run "$PR_CONFIG" set "$p" v
    [ "$status" -ne 0 ] || { echo "accepted: [$p]"; false; }
  done
  [ ! -e "$(branch_file feat)" ]
}

@test "set: through a value that isn't an object is refused, file untouched" {
  write_branch feat '{"settings":{"verify":"make"}}'
  run "$PR_CONFIG" set settings.verify.x y
  [ "$status" -ne 0 ]
  [ "$(jq -c . "$(branch_file feat)")" = '{"settings":{"verify":"make"}}' ]
}

@test "set: a malformed file is refused, not overwritten" {
  mkdir -p "$(dirname "$(branch_file feat)")"
  printf '{not json\n' > "$(branch_file feat)"
  run "$PR_CONFIG" set settings.verify x
  [ "$status" -ne 0 ]
  [ "$(cat "$(branch_file feat)")" = '{not json' ]
}

@test "set: needs a path and a value" {
  run "$PR_CONFIG" set settings.verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "set: options may follow the path and value" {
  run "$PR_CONFIG" set --global settings.botIgnore --json '["linear-code"]'
  [ "$status" -eq 0 ]
  [ "$(jq -c .settings.botIgnore "$PR_TEND_CONFIG")" = '["linear-code"]' ]
  run "$PR_CONFIG" set settings.verify make --branch feat
  [ "$status" -eq 0 ]
  [ "$(jq -r .settings.verify "$(branch_file feat)")" = make ]
}

@test "get, show and step: options may follow the arguments" {
  "$PR_CONFIG" set --global --json settings.botLogin '["a"]'
  run "$PR_CONFIG" get settings.botLogin --json --no-branch
  [ "$status" -eq 0 ]
  [ "$output" = '["a"]' ]
  run "$PR_CONFIG" show feat --no-branch
  [ "$status" -eq 0 ]
  run "$PR_CONFIG" step address --harness pi
  [ "$status" -eq 0 ]
  [ "$(jq -r .harness <<<"$output")" = pi ]
}

@test "a value starting with -- that isn't an option is a value" {
  run "$PR_CONFIG" set harnesses.claude.args "--model sonnet"
  [ "$status" -eq 0 ]
  run "$PR_CONFIG" set harnesses.pi.args --verbose
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.harnesses.claude.args, .harnesses.pi.args]' "$(branch_file feat)")" = '["--model sonnet","--verbose"]' ]
}

@test "--: ends options, so a value can be an option's name" {
  run "$PR_CONFIG" set harnesses.claude.args -- --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .harnesses.claude.args "$(branch_file feat)")" = --json ]
}

@test "an option the verb doesn't take is named" {
  run "$PR_CONFIG" set settings.verify make --no-branch
  [ "$status" -eq 1 ]
  [[ "$output" == *"set doesn't take --no-branch"* ]]
}

@test "a wrong argument count shows that verb's usage, not the whole help" {
  run "$PR_CONFIG" set settings.verify
  [ "$status" -eq 1 ]
  [[ "${lines[0]}" == "pr-config: set needs <path> <value>" ]] || false
  [[ "$output" == *"pr-config set   [--global"* ]] || false
  [[ "$output" != *"Layers"* ]]
}

@test "unset: removes the key so it inherits again" {
  write_global "$GLOBAL"
  write_branch feat '{"harnesses":{"claude":{"model":"opus","effort":"low"}}}'
  run "$PR_CONFIG" unset harnesses.claude.model
  [ "$status" -eq 0 ]
  [ "$(jq -c . "$(branch_file feat)")" = '{"harnesses":{"claude":{"effort":"low"}}}' ]
  [ "$(get_field describe model)" = strong ]
}

@test "unset --global: removes from the global file" {
  write_global "$GLOBAL"
  run "$PR_CONFIG" unset --global steps.review
  [ "$status" -eq 0 ]
  [ "$(jq -c '.steps | keys' "$PR_TEND_CONFIG")" = '["address"]' ]
}

@test "unset: a key that isn't there is fine" {
  write_branch feat '{}'
  run "$PR_CONFIG" unset settings.verify
  [ "$status" -eq 0 ]
}

@test "--help: set and unset are listed" {
  run "$PR_CONFIG" --help
  [[ "$output" == *"pr-config set"* ]]
  [[ "$output" == *"pr-config unset"* ]]
}

@test "set --json: a number and a list are values" {
  "$PR_CONFIG" set --json settings.stepTimeout 900
  "$PR_CONFIG" set --json settings.botLogin '["marge"]'
  [ "$(jq -c .settings "$(branch_file feat)")" = '{"stepTimeout":900,"botLogin":["marge"]}' ]
}

# ── validation: typed files ─────────────────────────────────────────────────

@test "validate: an unknown key in the global file is an error that names it" {
  write_global '{"settings":{"verfy":"make test"}}'
  run "$PR_CONFIG" get settings.verify
  [ "$status" -eq 1 ]
  [ "$output" = "pr-config: $PR_TEND_CONFIG: settings.verfy: unknown key" ]
}

@test "validate: a wrong type is an error with the bad value" {
  write_global '{"settings":{"stepTimeout":"30m"}}'
  run "$PR_CONFIG" get settings.remote
  [ "$status" -eq 1 ]
  [[ "$output" == *"settings.stepTimeout: cannot cast to uint64: 30m"* ]]
}

@test "validate: a bad effort level in the branch file names the branch file" {
  write_branch feat '{"harnesses":{"claude":{"effort":"hihg"}}}'
  run "$PR_CONFIG" step address
  [ "$status" -eq 1 ]
  [[ "$output" == *"$(branch_file feat): harnesses.claude.effort: no such symbol in enum"*": hihg"* ]]
}

@test "validate: each harness takes its own keys and effort levels" {
  write_global '{"harnesses":{"pi":{"provider":"p","effort":"minimal"},"claude":{"provider":"p"}}}'
  run "$PR_CONFIG" show
  [ "$status" -eq 1 ]
  [ "$output" = "pr-config: $PR_TEND_CONFIG: harnesses.claude.provider: unknown key" ]
}

@test "validate: a misspelled step or harness name is an error" {
  write_global '{"steps":{"adress":{"harness":"pi"}},"harness":"claud"}'
  run "$PR_CONFIG" show
  [ "$status" -eq 1 ]
  [[ "${lines[0]}" == *": harness: no such symbol in enum(claude,pi): claud" ]]
  [[ "${lines[1]}" == *": steps.adress.harness: unknown key" ]]
}

@test "validate: every problem is listed, not just the first" {
  write_global '{"settings":{"verfy":"x","stepTimeout":"30m","botLogin":"marge"}}'
  run "$PR_CONFIG" get settings.remote
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "validate: remote, interval and notify can only be set in the global file" {
  write_global '{"settings":{"remote":"upstream","interval":60,"notify":"say"}}'
  [ "$("$PR_CONFIG" get settings.remote)" = upstream ]
  write_branch feat '{"settings":{"remote":"fork"}}'
  run "$PR_CONFIG" get settings.remote
  [ "$status" -eq 1 ]
  [ "$output" = "pr-config: $(branch_file feat): settings.remote: global file only" ]
}

@test "validate: null is allowed anywhere, to clear an inherited key" {
  write_global "$GLOBAL"
  write_branch feat '{"harness":null,"steps":{"address":null},"settings":{"verify":null},"harnesses":{"pi":{"effort":null}}}'
  run "$PR_CONFIG" show
  [ "$status" -eq 0 ]
}

@test "validate: the built-in defaults pass as a global file" {
  source "$BATS_TEST_DIRNAME/../lib/pr-config.sh"
  printf '%s\n' "$PRC_DEFAULTS" > "$PR_TEND_CONFIG"
  run "$PR_CONFIG" show
  [ "$status" -eq 0 ]
}

@test "validate: set refuses an unknown key and leaves the file alone" {
  write_branch feat '{"settings":{"verify":"make"}}'
  run "$PR_CONFIG" set settings.verfy "make test"
  [ "$status" -eq 1 ]
  [[ "$output" == *"settings.verfy: unknown key"* ]]
  [ "$(jq -c . "$(branch_file feat)")" = '{"settings":{"verify":"make"}}' ]
  run "$PR_CONFIG" set --global settings.verfy x
  [ "$status" -eq 1 ]
  [ ! -e "$PR_TEND_CONFIG" ]
}

@test "validate: set refuses a global-only key in a branch file" {
  run "$PR_CONFIG" set settings.remote fork
  [ "$status" -eq 1 ]
  [[ "$output" == *"settings.remote: global file only"* ]]
  [ ! -e "$(branch_file feat)" ]
  "$PR_CONFIG" set --global settings.remote upstream
  [ "$("$PR_CONFIG" get settings.remote)" = upstream ]
}

@test "validate: unset can remove a bad key from an invalid file" {
  write_global '{"settings":{"verfy":"x","verify":"make"}}'
  run "$PR_CONFIG" unset --global settings.verfy
  [ "$status" -eq 0 ]
  [ "$("$PR_CONFIG" get settings.verify)" = make ]
}

@test "validate: step refuses a step name it doesn't know" {
  run "$PR_CONFIG" step adress
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown step: adress"* ]]
}

# ── built-in defaults ───────────────────────────────────────────────────────

@test "defaults: every pipeline setting has one when nothing is set" {
  [ "$("$PR_CONFIG" get settings.remote)" = origin ]
  [ "$("$PR_CONFIG" get settings.stepTimeout)" = 1800 ]
  [ "$("$PR_CONFIG" get settings.interval)" = 300 ]
  out=$("$PR_CONFIG" get settings.replyPrefix; echo x)
  [ "$out" = $'🤖 \nx' ]
}

@test "defaults: verify, notify and the bot lists default to nothing, exit 0" {
  for k in verify notify botLogin botIgnore botIgnoreBody; do
    run "$PR_CONFIG" get "settings.$k"
    [ "$status" -eq 0 ] || { echo "$k: $status"; false; }
    [ -z "$output" ]
  done
}

@test "defaults: an empty list in a file is a value" {
  write_global '{"settings":{"botLogin":["marge"]}}'
  write_branch feat '{"settings":{"botLogin":[]}}'
  run "$PR_CONFIG" get settings.botLogin
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "defaults: step's harness default is claude, and a null harness falls back to it" {
  run "$PR_CONFIG" step address
  [ "$output" = '{"harness":"claude"}' ]
  write_global '{"harness":"pi"}'
  write_branch feat '{"harness":null}'
  [ "$(get_field address harness)" = claude ]
}

# ── lib/pr-config.sh: sourced by pr-act, pr-watch and pr-state ─────────────

# Callers use `x=$(prc_... ) || die`, where bash turns errexit off inside the
# function, so every failure has to come back as a status. bats can't fail a
# test while errexit is off, so these collect statuses and assert after set -e.
@test "lib: errors come back as status 1 with errexit off" {
  source "$BATS_TEST_DIRNAME/../lib/pr-config.sh"
  local s=()
  set +e
  printf '{not json\n' > "$PR_TEND_CONFIG"
  out=$(prc_get settings.verify feat false); s+=($?)
  out=$(prc_step describe feat ""); s+=($?)
  rm "$PR_TEND_CONFIG"
  cd "$TMP"
  out=$(prc_step describe somebranch ""); s+=($?)
  out=$(prc_get 'a..b' "" true); s+=($?)
  set -e
  [ "${s[*]}" = "1 1 1 1" ]
}

@test "lib: unset is status 3, a value is status 0" {
  source "$BATS_TEST_DIRNAME/../lib/pr-config.sh"
  local s=() remote bots
  set +e
  out=$(prc_get settings.foo feat false); s+=($?)
  remote=$(prc_get settings.remote feat false); s+=($?)
  bots=$(prc_get settings.botLogin feat false json); s+=($?)
  set -e
  [ "${s[*]}" = "3 0 0" ]
  [ "$remote" = origin ]
  [ "$bots" = '[]' ]
}

@test "lib: sourcing it runs nothing and leaves the shell options alone" {
  run bash -c 'set +e; source "$1"; echo "opts=$-"' _ "$BATS_TEST_DIRNAME/../lib/pr-config.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == opts=* ]]
  [[ "${output#opts=}" != *e* ]]
}

@test "step: git config pr-tend.<harness>.args is not read" {
  git config pr-tend.claude.args "--max-turns 3"
  run "$PR_CONFIG" step describe
  [ "$output" = '{"harness":"claude"}' ]
}

@test "step: args come from the files like any other field" {
  write_global '{"harnesses":{"claude":{"args":"--global"}}}'
  write_branch feat '{"steps":{"describe":{"claude":{"args":"--max-turns 3"}}}}'
  [ "$(get_field describe args)" = "--max-turns 3" ]
}
