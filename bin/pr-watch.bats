#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for bin/pr-watch (the observe-only watcher pass).
#
# Real git for repos, enrollment and fetch. pr-state is faked: it serves
# $PS_FIXTURES/<branch>.json, so each glyph/notification rule can be driven
# directly. Notifications go to a stub configured as pr-tend.notify.

PR_WATCH="$BATS_TEST_DIRNAME/pr-watch"

setup() {
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export GIT_CONFIG_GLOBAL="$TMP/gitconfig-global"
  export GIT_CONFIG_SYSTEM=/dev/null
  printf '[user]\n\temail = t@example.com\n\tname = Tester\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
  export PR_TEND_STATE_DIR="$TMP/state"
  export STATUS_DIR="$TMP/status"
  export PS_FIXTURES="$TMP/ps"
  export PR_TEND_CONFIG="$TMP/global.json"
  PR_CONFIG="$BATS_TEST_DIRNAME/pr-config"
  mkdir -p "$PS_FIXTURES" "$TMP/fakebin"

  cat > "$TMP/fakebin/pr-state" <<'EOF'
#!/usr/bin/env bash
b=${@: -1}
echo "$PWD $b" >> "$PS_FIXTURES/calls"
f="$PS_FIXTURES/${b//\//__}.json"
[[ -f $f ]] || { echo "pr-state: no fixture for $b" >&2; exit 1; }
cat "$f"
EOF
  cat > "$TMP/fakebin/notify" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "$1" "$2" >> "$PS_FIXTURES/notified"
EOF
  chmod +x "$TMP/fakebin/pr-state" "$TMP/fakebin/notify"
  export PATH="$TMP/fakebin:$PATH"
  # Never the real macOS notifier: every config a test writes keeps this one.
  "$PR_CONFIG" set --global settings.notify "$TMP/fakebin/notify"

  git init -q --bare "$TMP/origin.git"
  git clone -q "$TMP/origin.git" "$TMP/repo" 2>/dev/null
  cd "$TMP/repo"
  git commit -q --allow-empty -m init && git push -q origin main 2>/dev/null
  git switch -qc feat
  enroll feat
}

enroll() { git -C "$TMP/repo" config "branch.$1.pr-tend" true; register "$TMP/repo"; }
register() {
  grep -qxF "$1" <<<"$(git config --global --get-all pr-tend.repo || true)" \
    || git config --global --add pr-tend.repo "$1"
}

# ps_fixture <branch> [jq-assignments...] — pr-state's JSON. Default: ready to merge.
# .next comes from the real lib/pr-next.sh, as in pr-state, unless an assignment sets it.
ps_fixture() {
  local b=$1; shift
  local j
  j=$(jq -n --arg b "$b" '{
    branch: $b, pr: {number: 7, state: "OPEN", draft: false},
    parent: {name: "main", merged: false},
    sync: {target: "main", default: "main", behind: 0, up_to_date: true, conflict: false},
    push: {remote_sha: "abc", ahead: 0, behind: 0, diverged: false, remote_ours: true},
    fresh: true, stale: [],
    ci: {verdict: "green", failing: [], pending: [], for_head: true},
    review: {local: {status: "none"}, bot: {status: "none"}, accepted: {status: "none"}},
    threads: {owed_bot: 0, owed_human: 0, outdated: 0, blocking: 0, info: 0, items: []},
    session: {enrolled: true, locked: false}, errors: []}')
  local a
  for a; do j=$(jq "$a" <<<"$j"); done
  if [[ $(jq 'has("next")' <<<"$j") == false ]]; then
    j=$(jq --argjson n "$(printf '%s\n' "$j" | bash5 -c 'source "$1/../lib/pr-config.sh" && source "$1/../lib/pr-next.sh" && prn_next origin' _ "$BATS_TEST_DIRNAME")" \
          '. + {next: $n}' <<<"$j")
  fi
  printf '%s\n' "$j" > "$PS_FIXTURES/${b//\//__}.json"
}

pass() { (cd "$TMP" && "$PR_WATCH") || { echo "pass failed"; return 1; }; }
glyph() { cut -f2 "$STATUS_DIR/$1.pr"; }
notified() { cat "$PS_FIXTURES/notified" 2>/dev/null || true; }

# ── basics ───────────────────────────────────────────────────────────────────

@test "runs under bash 5 via the bash5 shebang" {
  run head -1 "$PR_WATCH"
  [ "$output" = "#!/usr/bin/env bash5" ]
}

@test "no registered repos: nothing to do, exit 0" {
  git config --global --unset-all pr-tend.repo
  pass
  [ ! -e "$PS_FIXTURES/calls" ]
}

@test "only enrolled branches are checked, from the repo directory" {
  git branch other
  ps_fixture feat
  pass
  [ "$(cat "$PS_FIXTURES/calls")" = "$TMP/repo feat" ]
}

@test "a registered repo that no longer exists is skipped" {
  register "$TMP/gone"
  ps_fixture feat
  pass
  [ "$(cat "$PS_FIXTURES/calls")" = "$TMP/repo feat" ]
}

@test "fetches before checking" {
  git clone -q "$TMP/origin.git" "$TMP/other" 2>/dev/null
  git -C "$TMP/other" commit -q --allow-empty -m moved && git -C "$TMP/other" push -q origin main 2>/dev/null
  ps_fixture feat
  pass
  [ "$(git rev-parse origin/main)" = "$(git -C "$TMP/other" rev-parse main)" ]
}

@test "one branch's pr-state failing doesn't stop the others" {
  git branch other && enroll other
  ps_fixture other
  pass
  [ -f "$PR_TEND_STATE_DIR/last-pass" ]
  grep -q "other" "$PR_TEND_STATE_DIR/last-pass" || false
  grep -q "feat.*pr-state failed" "$PR_TEND_STATE_DIR/last-pass"
}

# ── glyph ────────────────────────────────────────────────────────────────────

@test "glyph is written for the worktree the branch is checked out in, with the branch" {
  ps_fixture feat
  pass
  [ "$(cat "$STATUS_DIR/repo.pr")" = "feat	✅" ]
}

@test "glyph follows a linked worktree" {
  git switch -q main
  git worktree add -q "$TMP/feat-wt" feat
  ps_fixture feat
  pass
  [ "$(glyph feat-wt)" = "✅" ]
  [ ! -e "$STATUS_DIR/repo.pr" ]
}

@test "a branch checked out nowhere gets no glyph but is still checked" {
  git switch -q main
  ps_fixture feat
  pass
  [ ! -e "$STATUS_DIR/repo.pr" ]
  grep -q feat "$PR_TEND_STATE_DIR/last-pass"
}

@test "a glyph left from a branch no longer enrolled is removed" {
  ps_fixture feat
  pass
  git config --unset branch.feat.pr-tend
  pass
  [ ! -e "$STATUS_DIR/repo.pr" ]
}

@test "glyph: CI red, conflict, human items, foreign push are ❌" {
  local a
  for a in '.ci.verdict = "red"' '.sync.up_to_date = false | .sync.conflict = true' \
           '.threads.owed_human = 1' '.push.behind = 1 | .push.remote_ours = false'; do
    ps_fixture feat "$a"
    pass
    [ "$(glyph repo)" = "❌" ] || { echo "for: $a"; return 1; }
  done
}

@test "glyph: work an agent will do later is 🔧" {
  local a
  for a in '.sync.up_to_date = false | .sync.behind = 2 | .sync.target = "base"' \
           '.sync.up_to_date = false | .parent.merged = true' '.threads.owed_bot = 1' \
           '.push.ahead = 1' '.pr = null' '.review.local.status = "uncovered"'; do
    ps_fixture feat "$a"
    pass
    [ "$(glyph repo)" = "🔧" ] || { echo "for: $a"; return 1; }
  done
}

@test "glyph: CI pending is ⏳" {
  ps_fixture feat '.ci.verdict = "pending"'
  pass
  [ "$(glyph repo)" = "⏳" ]
}

@test "glyph: unknown state (errors, not fresh) is ⚠️" {
  ps_fixture feat '.errors = ["gh: down"] | .fresh = null'
  pass
  [ "$(glyph repo)" = "⚠️" ]
}

@test "glyph: merged 🏁, closed 🚫" {
  ps_fixture feat '.pr.state = "MERGED"'
  pass
  [ "$(glyph repo)" = "🏁" ]
  ps_fixture feat '.pr.state = "CLOSED"'
  pass
  [ "$(glyph repo)" = "🚫" ]
}

@test "glyph: only behind the default branch is still ✅" {
  ps_fixture feat '.sync.up_to_date = false | .sync.behind = 40'
  pass
  [ "$(glyph repo)" = "✅" ]
}

@test "glyph: ❌ outranks 🔧" {
  ps_fixture feat '.ci.verdict = "red" | .push.ahead = 3'
  pass
  [ "$(glyph repo)" = "❌" ]
}

@test "glyph: cancelled checks are 🔧, CI for an older commit is ⏳" {
  ps_fixture feat '.ci.verdict = "inconclusive"'
  pass
  [ "$(glyph repo)" = "🔧" ]
  ps_fixture feat '.ci.for_head = false'
  pass
  [ "$(glyph repo)" = "⏳" ]
}

@test "glyph: a repo with no checks at all can be ready" {
  ps_fixture feat '.ci.verdict = "none" | .ci.for_head = true'
  pass
  [ "$(glyph repo)" = "✅" ]
}

@test "glyph: follows pr-state's next steps, not its raw fields" {
  ps_fixture feat '.next = [{key: "ci-wait", who: "wait", say: "CI running", cmd: null}]'
  pass
  [ "$(glyph repo)" = "⏳" ]
  ps_fixture feat '.next = [{key: "bot", who: "agent", say: "address 1 bot item", cmd: null}]'
  pass
  [ "$(glyph repo)" = "🔧" ]
}

@test "glyph: info-only bot items, waiting on chrismo's read, are 🔧" {
  ps_fixture feat '.threads.owed_bot = 1 | .threads.info = 1'
  pass
  [ "$(glyph repo)" = "🔧" ]
  [ -z "$(notified)" ]
}

@test "glyph: pr-state output with no next steps is ⚠️" {
  ps_fixture feat '.next = null'
  pass
  [ "$(glyph repo)" = "⚠️" ]
  grep -q "feat.*no next steps" "$PR_TEND_STATE_DIR/last-pass"
}

@test "glyph: a draft is never ready" {
  ps_fixture feat '.pr.draft = true'
  pass
  [ "$(glyph repo)" = "🔧" ]
  [ -z "$(notified)" ]
}

@test "glyph: pr-state failing shows ⚠️ instead of dropping the glyph" {
  ps_fixture feat
  pass
  rm "$PS_FIXTURES/feat.json"
  pass
  [ "$(glyph repo)" = "⚠️" ]
}

@test "unparseable pr-state output is ⚠️, and the next good pass still notifies" {
  printf 'warning: junk\n{"branch":' > "$PS_FIXTURES/feat.json"
  pass
  [ "$(glyph repo)" = "⚠️" ]
  grep -q "feat.*unparseable" "$PR_TEND_STATE_DIR/last-pass" || false
  ps_fixture feat '.ci.verdict = "red" | .ci.failing = ["lint"]'
  pass
  [ "$(notified)" = "repo feat|fix CI: lint" ]
}

@test "pr-state stderr on success doesn't corrupt its JSON" {
  ps_fixture feat
  cat > "$TMP/fakebin/pr-state" <<'SH'
#!/usr/bin/env bash
echo "warning: something" >&2
cat "$PS_FIXTURES/${@: -1}.json"
SH
  pass
  [ "$(glyph repo)" = "✅" ]
}

@test "a hung pr-state times out instead of stalling the pass" {
  git branch other && enroll other
  ps_fixture other
  cat > "$TMP/fakebin/pr-state" <<'SH'
#!/usr/bin/env bash
[[ ${@: -1} == feat ]] && sleep 30
cat "$PS_FIXTURES/${@: -1}.json"
SH
  SECONDS=0
  PR_WATCH_TIMEOUT=1 pass
  (( SECONDS < 10 )) || false
  grep -q "feat.*pr-state failed" "$PR_TEND_STATE_DIR/last-pass" || false
  grep -q "other.*✅" "$PR_TEND_STATE_DIR/last-pass"
}

@test "a failed fetch keeps git's reason" {
  git remote set-url origin "$TMP/nowhere.git"
  ps_fixture feat
  pass
  grep -q "fetch from origin failed: .*nowhere" "$PR_TEND_STATE_DIR/last-pass"
}

# ── notifications ────────────────────────────────────────────────────────────

@test "notify: ready to merge, once" {
  ps_fixture feat
  pass
  pass
  [ "$(notified)" = "repo feat|ready to merge" ]
}

@test "notify: CI red names the failing checks" {
  ps_fixture feat '.ci.verdict = "red" | .ci.failing = ["lint", "test"]'
  pass
  [ "$(notified)" = "repo feat|fix CI: lint, test" ]
}

@test "notify: a reason that clears and comes back notifies again" {
  ps_fixture feat '.ci.verdict = "red" | .ci.failing = ["lint"]'
  pass
  ps_fixture feat '.ci.verdict = "pending"'
  pass
  ps_fixture feat '.ci.verdict = "red" | .ci.failing = ["lint"]'
  pass
  [ "$(notified | grep -c 'fix CI')" = 2 ]
}

@test "notify: agent-later work and pending CI stay quiet" {
  ps_fixture feat '.ci.verdict = "pending" | .push.ahead = 1 | .threads.owed_bot = 2'
  pass
  [ -z "$(notified)" ]
}

@test "notify: human items, conflict, foreign push, merged" {
  ps_fixture feat '.threads.owed_human = 2'
  pass
  ps_fixture feat '.sync.up_to_date = false | .sync.conflict = true'
  pass
  ps_fixture feat '.push.behind = 1 | .push.remote_ours = false'
  pass
  ps_fixture feat '.pr.state = "MERGED"'
  pass
  run notified
  [ "${lines[0]}" = "repo feat|reply to 2 human items" ]
  [ "${lines[1]}" = "repo feat|restack onto main conflicts: resolve it" ]
  [ "${lines[2]}" = "repo feat|origin/feat has 1 commit that isn't yours" ]
  [ "${lines[3]}" = "repo feat|merged: remove this worktree" ]
}

@test "notify: a notifier that reads stdin doesn't swallow later reasons" {
  cat > "$TMP/fakebin/notify" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '%s|%s\n' "$1" "$2" >> "$PS_FIXTURES/notified"
SH
  ps_fixture feat '.ci.verdict = "red" | .ci.failing = ["lint"] | .threads.owed_human = 1'
  pass
  [ "$(notified | wc -l | tr -d ' ')" = 2 ]
}

@test "notify: notifier output stays out of the pass record" {
  cat > "$TMP/fakebin/notify" <<'SH'
#!/usr/bin/env bash
echo "NOISE"
SH
  ps_fixture feat
  pass
  ! grep -q NOISE "$PR_TEND_STATE_DIR/last-pass"
}

@test "notify: a configured command with a space in its path works" {
  mkdir -p "$TMP/my tools"
  cp "$TMP/fakebin/notify" "$TMP/my tools/notify"
  "$PR_CONFIG" set --global settings.notify "'$TMP/my tools/notify'"
  ps_fixture feat
  pass
  [ "$(notified)" = "repo feat|ready to merge" ]
}

# ── status ───────────────────────────────────────────────────────────────────

@test "status: prints the last pass" {
  ps_fixture feat '.ci.verdict = "red" | .ci.failing = ["lint"]'
  pass
  run "$PR_WATCH" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"repo"*"feat"*"❌"*"fix CI: lint"* ]] || false
  [[ "$output" != *$'\t'* ]]
}

@test "status: before any pass" {
  run "$PR_WATCH" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"no pass yet"* ]]
}

# ── launchd ──────────────────────────────────────────────────────────────────

setup_launchd() {
  export PR_WATCH_LAUNCH_AGENTS="$TMP/LaunchAgents"
  cat > "$TMP/fakebin/launchctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$PS_FIXTURES/launchctl"
EOF
  chmod +x "$TMP/fakebin/launchctl"
  PLIST="$PR_WATCH_LAUNCH_AGENTS/com.agent-rig.pr-watch.plist"
}

@test "install: writes a valid plist and bootstraps it" {
  setup_launchd
  run "$PR_WATCH" install
  [ "$status" -eq 0 ]
  plutil -lint "$PLIST"
  [ "$(plutil -extract StartInterval raw "$PLIST")" = 300 ]
  [[ "$(plutil -extract EnvironmentVariables.PATH raw "$PLIST")" == "$HOME/.local/bin:"* ]]
  grep -q "bootstrap gui/$(id -u) $PLIST" "$PS_FIXTURES/launchctl"
}

@test "uninstall: boots out and removes the plist" {
  setup_launchd
  "$PR_WATCH" install
  run "$PR_WATCH" uninstall
  [ "$status" -eq 0 ]
  [ ! -e "$PLIST" ]
  grep -q "bootout gui/$(id -u)/com.agent-rig.pr-watch" "$PS_FIXTURES/launchctl"
}

@test "install: a non-numeric interval is refused and the old job is kept" {
  setup_launchd
  "$PR_WATCH" install
  : > "$PS_FIXTURES/launchctl"
  write_cfg '{"settings":{"interval":"5m"}}'
  run "$PR_WATCH" install
  [ "$status" -ne 0 ]
  [ "$(plutil -extract StartInterval raw "$PLIST")" = 300 ]
  [ ! -s "$PS_FIXTURES/launchctl" ]
}

@test "install: paths are XML-escaped" {
  setup_launchd
  export PR_TEND_STATE_DIR="$TMP/a&b"
  "$PR_WATCH" install
  plutil -lint "$PLIST"
  [ "$(plutil -extract StandardOutPath raw "$PLIST")" = "$TMP/a&b/launchd.log" ]
}

# ── settings via pr-config: the global file over the defaults ───────────────

# write_cfg <json>: the global file, keeping the stub notifier unless <json> sets one.
write_cfg() {
  jq -n --arg n "$TMP/fakebin/notify" --argjson c "$1" '{settings: {notify: $n}} * $c' > "$PR_TEND_CONFIG"
}

@test "config: git config pr-tend.notify is not read" {
  git config --global pr-tend.notify "$TMP/fakebin/missing"
  ps_fixture feat
  pass
  [ "$(cat "$PS_FIXTURES/notified")" = "repo feat|ready to merge" ]
}

@test "config: a branch file in the working directory does not steer the watcher" {
  write_cfg "{\"settings\":{\"notify\":\"$TMP/fakebin/notify\"}}"
  mkdir -p "$TMP/repo/.git/pr-tend"
  printf '{"settings":{"notify":"%s"}}\n' "$TMP/fakebin/missing" > "$TMP/repo/.git/pr-tend/feat.json"
  ps_fixture feat
  (cd "$TMP/repo" && "$PR_WATCH")
  [ "$(cat "$PS_FIXTURES/notified")" = "repo feat|ready to merge" ]
}

@test "config: remote from the file" {
  write_cfg '{"settings":{"remote":"nowhere"}}'
  ps_fixture feat
  pass
  grep -q "fetch from nowhere failed" "$PR_TEND_STATE_DIR/last-pass"
}

@test "config: install reads interval from the file" {
  setup_launchd
  write_cfg '{"settings":{"interval":120}}'
  "$PR_WATCH" install
  [ "$(plutil -extract StartInterval raw "$PLIST")" = 120 ]
}

@test "config: a non-numeric interval in the file is refused" {
  setup_launchd
  write_cfg '{"settings":{"interval":"5m"}}'
  run "$PR_WATCH" install
  [ "$status" -ne 0 ]
  [ ! -e "$PLIST" ]
}

@test "config: an unreadable config file is reported for the repo, not silently defaulted" {
  printf '{not json\n' > "$PR_TEND_CONFIG"
  ps_fixture feat
  pass
  grep -q "repo.*pr-config failed" "$PR_TEND_STATE_DIR/last-pass"
  [ ! -f "$PS_FIXTURES/calls" ]
}

@test "config: install refuses when the config file is unreadable" {
  setup_launchd
  printf '{not json\n' > "$PR_TEND_CONFIG"
  run "$PR_WATCH" install
  [ "$status" -ne 0 ]
  [ ! -e "$PLIST" ]
}
