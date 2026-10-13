#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for `pr-act ack`: mark owed bot reviews and comments as read
# (branch.<b>.pr-handled) without replying. A fake pr-state answers from
# $FX/state.json.

PR_ACT="$BATS_TEST_DIRNAME/pr-act"

setup() {
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export GIT_CONFIG_GLOBAL="$TMP/gitconfig-global"
  export GIT_CONFIG_SYSTEM=/dev/null
  export PR_TEND_CONFIG="$TMP/global.json"
  printf '[user]\n\temail = t@example.com\n\tname = Tester\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
  export FX="$TMP/fx"
  mkdir -p "$FX" "$TMP/fakebin"
  cat > "$TMP/fakebin/pr-state" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FX/pr-state.calls"
cat "$FX/state.json"
EOF
  chmod +x "$TMP/fakebin/pr-state"
  export PATH="$TMP/fakebin:$PATH"
  git init -q "$TMP/repo"
  cd "$TMP/repo"
  git commit -q --allow-empty -m init
  git switch -qc feat
}

item() { # item <id> <type> <kind> <mark>
  jq -nc --arg id "$1" --arg t "$2" --arg k "$3" --arg m "$4" \
    '{id: $id, type: $t, kind: $k, mark: $m, author: "bot1", last: "bot1", url: "https://example/\($id)", excerpt: "about \($id)"}'
}
state() { # state <item-json...>
  jq -n '{branch: "feat", pr: {number: 7, state: "OPEN"}, threads: {owed_bot: 0, items: $ARGS.positional}}
         | .threads.owed_bot = ([.threads.items[] | select(.kind == "bot")] | length)' \
    --jsonargs "$@" > "$FX/state.json"
}
handled() { git config --get-all branch.feat.pr-handled || true; }

@test "ack: marks every owed info item handled and lists them" {
  state "$(item R1 review bot i)" "$(item C1 comment bot i)" "$(item T1 thread bot '!')"
  run "$PR_ACT" ack
  [ "$status" -eq 0 ]
  [ "$(handled | sort | tr '\n' ' ')" = "C1 R1 " ]
  [[ "${lines[0]}" == "acked 2 on feat:" ]] || false
  [[ "$output" == *"review"*"bot1"*"about R1"*"https://example/R1"* ]] || false
  [[ "$output" == *"https://example/C1"* ]]
}

@test "ack: asks pr-state about the named branch" {
  git branch other
  state "$(item R1 review bot i)"
  run "$PR_ACT" ack other
  [ "$status" -eq 0 ]
  [ "$(cat "$FX/pr-state.calls")" = "--json other" ]
  [ "$(git config --get-all branch.other.pr-handled)" = R1 ]
}

@test "ack: nothing owed is fine and writes nothing" {
  state "$(item T1 thread bot '!')"
  run "$PR_ACT" ack
  [ "$status" -eq 0 ]
  [[ "$output" == "nothing to ack on feat"* ]] || false
  [ -z "$(handled)" ]
}

@test "ack --id: only the named items" {
  state "$(item R1 review bot i)" "$(item C1 comment bot i)" "$(item R2 review bot '!')"
  run "$PR_ACT" ack --id C1 --id R2
  [ "$status" -eq 0 ]
  [ "$(handled | sort | tr '\n' ' ')" = "C1 R2 " ]
}

@test "ack --id: a thread is refused; it gets resolved on GitHub" {
  state "$(item T1 thread bot '!')"
  run "$PR_ACT" ack --id T1
  [ "$status" -eq 1 ]
  [[ "$output" == *"T1 is a thread"* ]] || false
  [ -z "$(handled)" ]
}

@test "ack --id: a human item is refused" {
  state "$(item H1 review human '!')"
  run "$PR_ACT" ack --id H1
  [ "$status" -eq 1 ]
  [[ "$output" == *"H1"*"human"* ]] || false
  [ -z "$(handled)" ]
}

@test "ack --id: an id that isn't owed is refused and nothing is written" {
  state "$(item R1 review bot i)"
  run "$PR_ACT" ack --id R1 --id NOPE
  [ "$status" -eq 1 ]
  [[ "$output" == *"NOPE isn't owed"* ]] || false
  [ -z "$(handled)" ]
}

@test "ack: GitHub unreadable is refused" {
  jq -n '{branch: "feat", pr: null, threads: {owed_bot: null, items: []}, errors: ["gh: boom"]}' > "$FX/state.json"
  run "$PR_ACT" ack
  [ "$status" -eq 1 ]
  [[ "$output" == *"can't read the PR"*"gh: boom"* ]]
}

@test "ack: pr-state failing is an error" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/fakebin/pr-state"
  run "$PR_ACT" ack
  [ "$status" -eq 1 ]
  [[ "$output" == *"pr-state failed"* ]]
}
