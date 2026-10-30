#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for bin/agent-read.
#
# agent-read reads ~/.claude/projects/<encoded-path>/*.jsonl files and renders
# session conversations. Tests run with CLAUDE_PROJECTS_DIR and
# CLAUDE_SESSIONS_META_DIR redirected into BATS_TEST_TMPDIR so they don't
# touch the real ~/.claude.
#
# Requires `super` (SuperDB) — same as the script itself.

POD="$BATS_TEST_DIRNAME/agent-read"

setup() {
  export CLAUDE_PROJECTS_DIR="$BATS_TEST_TMPDIR/.claude/projects"
  export CLAUDE_SESSIONS_META_DIR="$BATS_TEST_TMPDIR/.claude/sessions"
  export AGENT_READ_CURSOR_DIR="$BATS_TEST_TMPDIR/.claude/agent-read/cursors"
  export AGENT_READ_CODEX_DIR="$BATS_TEST_TMPDIR/.codex/sessions"
  export AGENT_READ_PI_DIR="$BATS_TEST_TMPDIR/.pi/agent/sessions"
  mkdir -p "$CLAUDE_PROJECTS_DIR" "$CLAUDE_SESSIONS_META_DIR"
  # Many tests want a clean baseline; --peers behavior depends on this.
  unset CLAUDE_CODE_SESSION_ID
  # The gitignore assertions ask "is this path ignored?", and the developer's own
  # global excludes file can answer yes — the recommended `.*console*.log` line
  # lives there. Point git at an empty config so the tests judge only what the
  # test repo itself declares.
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  : > "$GIT_CONFIG_GLOBAL"
}

# ── Fixture helpers ────────────────────────────────────────────────────────────

# encode_path /tmp/foo/bar → -tmp-foo-bar (mirrors agent-read's encode_path).
# Claude Code replaces EVERY non-alphanumeric character, not just '/'.
encode_path() {
  printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'
}

# make_worktree NAME
#   Creates BATS_TEST_TMPDIR/NAME plus its encoded ~/.claude/projects/ dir.
#   Echoes the canonical worktree path.
make_worktree() {
  local name="$1"
  local wt="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$wt"
  local canonical
  canonical=$(cd "$wt" && pwd)
  mkdir -p "$CLAUDE_PROJECTS_DIR/$(encode_path "$canonical")"
  echo "$canonical"
}

# session_dir_for WORKTREE → encoded projects subdir
session_dir_for() {
  echo "$CLAUDE_PROJECTS_DIR/$(encode_path "$(cd "$1" && pwd)")"
}

# write_session WORKTREE SID
#   Writes a minimal user+assistant jsonl, plus one meta record — the shape a
#   real session takes once it has produced any system record. The bare
#   variant below covers a transcript that declares neither isMeta nor
#   subtype, which the filters must also handle.
write_session() {
  local wt="$1" sid="$2"
  local dir
  dir=$(session_dir_for "$wt")
  local file="$dir/$sid.jsonl"
  cat > "$file" <<EOF
{"type":"system","sessionId":"$sid","subtype":"info","timestamp":"2026-05-17T00:00:00Z","content":"meta-record-for-schema-inference","isMeta":true}
{"type":"user","sessionId":"$sid","timestamp":"2026-05-17T00:00:01Z","message":{"content":"hello"}}
{"type":"assistant","sessionId":"$sid","timestamp":"2026-05-17T00:00:02Z","message":{"content":[{"type":"text","text":"hi"}]}}
EOF
  echo "$file"
}

# write_session_bare WORKTREE SID
#   A session whose records declare neither isMeta nor subtype — the shape of
#   a real transcript that has not yet produced a meta or system record. The
#   filters must not name a field no record in the file declares.
write_session_bare() {
  local wt="$1" sid="$2"
  local dir
  dir=$(session_dir_for "$wt")
  local file="$dir/$sid.jsonl"
  cat > "$file" <<EOF
{"type":"user","sessionId":"$sid","timestamp":"2026-05-17T00:00:01Z","message":{"content":"bare-hello"}}
{"type":"assistant","sessionId":"$sid","timestamp":"2026-05-17T00:00:02Z","message":{"content":[{"type":"text","text":"bare-hi"}]}}
EOF
  echo "$file"
}

# rename_event WORKTREE SID NAME
#   Appends a real /rename system event.
rename_event() {
  local wt="$1" sid="$2" name="$3"
  local file
  file="$(session_dir_for "$wt")/$sid.jsonl"
  cat >> "$file" <<EOF
{"type":"system","sessionId":"$sid","subtype":"local_command","timestamp":"2026-05-17T00:00:02Z","content":"<local-command-stdout>Session renamed to: $name</local-command-stdout>"}
EOF
}

# tool_result_with_rename_text WORKTREE SID
#   Appends a user message whose content quotes the rename pattern — exercises
#   the name_from_jsonl false-positive guard.
tool_result_with_rename_text() {
  local wt="$1" sid="$2"
  local file
  file="$(session_dir_for "$wt")/$sid.jsonl"
  cat >> "$file" <<EOF
{"type":"user","sessionId":"$sid","timestamp":"2026-05-17T00:00:03Z","message":{"content":"comment: # Session renamed to: NAME — survives after exit"}}
EOF
}

# live_session SID NAME PID PROJECTPATH
#   Writes a fake ~/.claude/sessions/<pid>.json metadata file.
live_session() {
  local sid="$1" name="$2" pid="$3" path="$4"
  cat > "$CLAUDE_SESSIONS_META_DIR/$pid.json" <<EOF
{"sessionId":"$sid","name":"$name","pid":$pid,"projectPath":"$path"}
EOF
}

# write_console WORKTREE [NAME]
#   Writes a fake `script` typescript: header line, ANSI-colored output, an OSC
#   title-set escape, a carriage-return progress redraw, and a blank-line run.
#   Echoes the log path.
write_console() {
  local wt="$1" name="${2:-.main-console.log}"
  local file="$wt/$name"
  printf 'Script started on Sun Jul 12 09:00:00 2026\n' > "$file"
  printf '\033]0;zsh\007\033[32mPASS\033[0m first-test\n' >> "$file"
  printf 'progress 10%%\rprogress 50%%\rprogress 100%%\n' >> "$file"
  printf '\n\n\n' >> "$file"
  printf 'boom: NoMethodError in widget.rb\n' >> "$file"
  echo "$file"
}

# ── Usage / exit codes ─────────────────────────────────────────────────────────

@test "no args → prints usage, exit 0" {
  run "$POD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: agent-read"* ]]
}

@test "--help → prints usage, exit 0" {
  run "$POD" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: agent-read"* ]]
}

@test "unknown flag → exit 2" {
  run "$POD" --bogus
  [ "$status" -eq 2 ]
}

@test "--turns with non-number → exit 2" {
  run "$POD" --turns abc /tmp
  [ "$status" -eq 2 ]
}

@test "--turns with --all → exit 2" {
  wt=$(make_worktree wt1)
  run "$POD" --all --turns 5 "$wt"
  [ "$status" -eq 2 ]
}

# ── Path resolution ────────────────────────────────────────────────────────────

@test "bad path → exit 1" {
  run "$POD" /does/not/exist
  [ "$status" -eq 1 ]
}

# Issue #17: a worktree under a Google Drive path — dots, an @, and a space —
# resolved to a project dir that doesn't exist, so agent-read reported "no
# sessions" while peers were actively running. A silent false negative.
#
# The expected name here is derived independently (the sanitizer from the issue),
# NOT from this file's encode_path helper — otherwise the test would pass by
# mirroring whatever bug the helper shares with the script.
@test "project dir encoding replaces every non-alphanumeric char, not just / (issue #17)" {
  wt="$BATS_TEST_TMPDIR/GoogleDrive-chris.morris@dscout.com/My Drive/work-rig"
  mkdir -p "$wt"
  local canonical encoded sid
  canonical="$(cd "$wt" && pwd)"
  encoded="$(printf '%s' "$canonical" | sed 's/[^a-zA-Z0-9]/-/g')"
  mkdir -p "$CLAUDE_PROJECTS_DIR/$encoded"
  sid="c0ffee00-1111-2222-3333-444444444444"
  cat > "$CLAUDE_PROJECTS_DIR/$encoded/$sid.jsonl" <<EOF
{"type":"system","sessionId":"$sid","subtype":"info","timestamp":"2026-07-14T00:00:00Z","content":"meta","isMeta":true}
{"type":"user","sessionId":"$sid","timestamp":"2026-07-14T00:00:01Z","message":{"content":"hello from google drive"}}
EOF
  run "$POD" --all "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$sid"* ]]
}

@test "valid worktree, --all matches nothing in window → exit 0, message on stderr" {
  wt=$(make_worktree wt1)
  file=$(write_session "$wt" "11111111-2222-3333-4444-555555555555")
  # Age the file so --since 1s excludes it (mtime-based filter).
  touch -t 202401010000 "$file"
  run --separate-stderr "$POD" --all --since 1s "$wt"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"no matching sessions"* ]]
}

@test "valid worktree, render mode no match → exit 0" {
  wt=$(make_worktree wt1)
  file=$(write_session "$wt" "11111111-2222-3333-4444-555555555555")
  touch -t 202401010000 "$file"
  run "$POD" --since 1s "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" != *"hello"* ]] || false
  # Same session, no window: proves the silence above is the filter and not a
  # reader that renders nothing either way.
  run "$POD" "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello"* ]]
}

# ── --all listing ──────────────────────────────────────────────────────────────

@test "--all with sessions → table header + row" {
  wt=$(make_worktree wt1)
  write_session "$wt" "11111111-2222-3333-4444-555555555555" >/dev/null
  run "$POD" --all "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"modified"* ]] || false
  [[ "$output" == *"harness"* ]] || false
  [[ "$output" == *"claude"* ]] || false
  [[ "$output" == *"11111111"* ]]
}

# ── --peers semantics ──────────────────────────────────────────────────────────

@test "--peers without CLAUDE_CODE_SESSION_ID → exit 2" {
  wt=$(make_worktree wt1)
  run "$POD" --peers "$wt"
  [ "$status" -eq 2 ]
}

@test "--peers excludes \$CLAUDE_CODE_SESSION_ID, includes others" {
  wt=$(make_worktree wt1)
  write_session "$wt" "11111111-2222-3333-4444-555555555555" >/dev/null
  write_session "$wt" "22222222-3333-4444-5555-666666666666" >/dev/null
  export CLAUDE_CODE_SESSION_ID="11111111-2222-3333-4444-555555555555"
  run "$POD" --peers "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" != *"11111111-2222"* ]] || false
  [[ "$output" == *"22222222-3333"* ]]
}

# ── --session resolution ───────────────────────────────────────────────────────

@test "--session bogus-name → exit 1" {
  run "$POD" --session not-a-session
  [ "$status" -eq 1 ]
}

@test "--session by UUID renders" {
  wt=$(make_worktree wt1)
  sid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  write_session "$wt" "$sid" >/dev/null
  # No --turns 0 here: that skips rendering entirely, leaving nothing but the
  # exit status to assert on.
  run "$POD" --session "$sid" "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello"* ]] || false
  [[ "$output" == *"hi"* ]]
}

@test "--session by name from live sessions metadata" {
  wt=$(make_worktree wt1)
  sid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  write_session "$wt" "$sid" >/dev/null
  live_session "$sid" "merlin" 99999 "$wt"
  run "$POD" --session merlin --turns 0
  [ "$status" -eq 0 ]
}

@test "--session by name still resolves when another live session has no name" {
  # ~/.claude/sessions/<pid>.json only carries `name` once a session has been
  # renamed, so the everyday state is files with no name field at all — what
  # the live-session map's filter has to tolerate. Like the disk-map test
  # above, this pins the mixed case; the old form's failure needed every file
  # to lack the field, and load_sid_name_map swallows the error either way.
  wt=$(make_worktree wt1)
  sid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  write_session "$wt" "$sid" >/dev/null
  printf '%s\n' "{\"sessionId\":\"ffffffff-0000-0000-0000-000000000000\",\"pid\":88888,\"projectPath\":\"$wt\"}" \
    > "$CLAUDE_SESSIONS_META_DIR/88888.json"
  live_session "$sid" "merlin" 99999 "$wt"
  run "$POD" --session merlin "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello"* ]]
}

@test "--session by name resolves cross-worktree from disk rename event" {
  wt=$(make_worktree wt1)
  wt2=$(make_worktree wt2)
  sid="ccccdddd-1111-2222-3333-444444444444"
  write_session "$wt2" "$sid" >/dev/null
  rename_event "$wt2" "$sid" "lancelot"
  # Invoke from a DIFFERENT worktree — proves the disk map is global.
  cd "$wt"
  run "$POD" --session lancelot --turns 0
  [ "$status" -eq 0 ]
}

# ── Name extraction false-positive guard ───────────────────────────────────────

@test "name column empty when session has no real rename event (tool-result text doesn't false-match)" {
  wt=$(make_worktree wt1)
  sid="ffff0000-1111-2222-3333-444444444444"
  write_session "$wt" "$sid" >/dev/null
  tool_result_with_rename_text "$wt" "$sid"
  run "$POD" --all "$wt"
  [ "$status" -eq 0 ]
  # Garbage indicators that would appear under the old loose grep.
  [[ "$output" != *"survives after"* ]] || false
  [[ "$output" != *"NAME"* ]]
}

@test "real rename event resolves to its name in the listing" {
  wt=$(make_worktree wt1)
  sid="aaaaaaaa-1234-1234-1234-aaaaaaaaaaaa"
  write_session "$wt" "$sid" >/dev/null
  rename_event "$wt" "$sid" "galahad"
  run "$POD" --all "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"galahad"* ]]
}

# ── Optional-field filters against a transcript that lacks them ────────────────

@test "renders a session whose records declare neither isMeta nor subtype" {
  wt=$(make_worktree wt1)
  sid="dddd0000-1111-2222-3333-555555555555"
  write_session_bare "$wt" "$sid" >/dev/null
  run "$POD" --session "$sid" "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bare-hello"* ]] || false
  [[ "$output" == *"bare-hi"* ]]
}

@test "--all resolves a name while a bare transcript sits in the same dir" {
  # Asserts the name, not just the sid: --all prints the sid whether or not
  # load_sid_name_disk_map survived, so a sid-only assertion can't see that
  # query die. It still can't force the old failure — super resolves fields
  # against the types it has read, and the renamed session's own record
  # declares subtype — so what this pins is that a bare transcript sharing the
  # directory doesn't disturb name resolution. The old form only broke when
  # NO transcript anywhere declared subtype, and its single visible effect was
  # an empty name column, indistinguishable from "nothing was renamed".
  wt=$(make_worktree wt1)
  write_session_bare "$wt" "dddd0000-1111-2222-3333-666666666666" >/dev/null
  named="eeee0000-1111-2222-3333-777777777777"
  write_session "$wt" "$named" >/dev/null
  rename_event "$wt" "$named" "percival"
  run "$POD" --all "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dddd0000"* ]] || false
  [[ "$output" == *"percival"* ]]
}

@test "--new advances the cursor on a bare transcript (last_turn_ts survives it)" {
  # last_turn_ts runs the unfiltered stream through its own isMeta filter and
  # swallows errors, so a broken query reads as "no cursor" and --new hands
  # back the same turns forever. Reading twice is what makes that visible.
  wt=$(make_worktree wt1)
  sid="dddd0000-1111-2222-3333-888888888888"
  write_session_bare "$wt" "$sid" >/dev/null
  export CLAUDE_CODE_SESSION_ID="aaaaaaaa-9999-9999-9999-aaaaaaaaaaaa"
  run "$POD" --session "$sid" --new "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bare-hello"* ]] || false

  run "$POD" --session "$sid" --new "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" != *"bare-hello"* ]]
}

# ── SuperDB content-coercion quirk regression ──────────────────────────────────

@test "renders session whose only turn has string-typed message.content (SuperDB switch+unnest quirk)" {
  wt=$(make_worktree wt1)
  sid="bbbbcccc-1111-2222-3333-444444444444"
  local dir
  dir=$(session_dir_for "$wt")
  # Include the schema-seeding meta record (see write_session helper notes).
  cat > "$dir/$sid.jsonl" <<EOF
{"type":"system","sessionId":"$sid","subtype":"info","timestamp":"2026-05-17T00:00:00Z","content":"meta","isMeta":true}
{"type":"user","sessionId":"$sid","timestamp":"2026-05-17T00:00:01Z","message":{"content":"hello-string-only"}}
EOF
  run "$POD" --session "$sid" "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello-string-only"* ]]
}

# ── bash 3.2 + set -u: empty EXCLUDES doesn't crash ────────────────────────────

@test "/bin/bash (3.2): --all with no --exclude doesn't trigger 'unbound variable' on EXCLUDES" {
  wt=$(make_worktree wt1)
  write_session "$wt" "aaaa1111-bbbb-cccc-dddd-eeeeeeeeeeee" >/dev/null
  # Force macOS's bash 3.2 so the EXCLUDES[@] regression is actually exercised.
  # On other systems /bin/bash may be a newer build — that's fine; this just
  # additionally validates portability.
  run /bin/bash "$POD" --all "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" != *"unbound variable"* ]] || false
  [[ "$output" != *"EXCLUDES"* ]]
}

# ── --console: the human's terminal as a peer stream ───────────────────────────

@test "--console with no recording → exit 1, points at --record" {
  wt=$(make_worktree wt1)
  run --separate-stderr "$POD" --console "$wt"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"no console recording"* ]] || false
  [[ "$stderr" == *"--record"* ]]
}

@test "--console renders the recording with ANSI escapes stripped" {
  wt=$(make_worktree wt1)
  write_console "$wt" >/dev/null
  run "$POD" --console "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS first-test"* ]] || false
  [[ "$output" == *"boom: NoMethodError"* ]] || false
  # No raw escape bytes survive.
  [[ "$output" != *$'\033'* ]]
}

@test "--console drops the 'Script started on' header" {
  wt=$(make_worktree wt1)
  write_console "$wt" >/dev/null
  run "$POD" --console "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Script started on"* ]]
}

@test "--console collapses carriage-return redraws to the final segment" {
  wt=$(make_worktree wt1)
  write_console "$wt" >/dev/null
  run "$POD" --console "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"progress 100%"* ]] || false
  [[ "$output" != *"progress 10%"* ]] || false
  [[ "$output" != *"progress 50%"* ]]
}

@test "--console squeezes blank-line runs" {
  wt=$(make_worktree wt1)
  write_console "$wt" >/dev/null
  run "$POD" --console "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\n\n\n'* ]]
}

@test "--console --tail N renders only the last N lines" {
  wt=$(make_worktree wt1)
  write_console "$wt" >/dev/null
  run "$POD" --console --tail 1 "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"boom: NoMethodError"* ]] || false
  [[ "$output" != *"PASS first-test"* ]]
}

@test "--tail with non-number → exit 2" {
  wt=$(make_worktree wt1)
  run "$POD" --console --tail abc "$wt"
  [ "$status" -eq 2 ]
}

@test "--turns with --console → exit 2 (session render flag)" {
  wt=$(make_worktree wt1)
  write_console "$wt" >/dev/null
  run "$POD" --console --turns 5 "$wt"
  [ "$status" -eq 2 ]
}

@test "\$CLAUDE_CONSOLE_LOG overrides discovery" {
  wt=$(make_worktree wt1)
  write_console "$wt" >/dev/null
  printf 'from-the-override\n' > "$wt/elsewhere.log"
  export CLAUDE_CONSOLE_LOG="$wt/elsewhere.log"
  run "$POD" --console "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"from-the-override"* ]] || false
  [[ "$output" != *"boom: NoMethodError"* ]]
}

@test "--console -f with several panes → exit 2 (no way to attribute an interleaved stream)" {
  wt=$(make_worktree wt1)
  two_consoles "$wt"
  run "$POD" --console -f "$wt"
  [ "$status" -eq 2 ]
}

# ── Multiple consoles: one pane per concern ────────────────────────────────────

# two_consoles WORKTREE
#   A server pane (older) and a tests pane (newer) — the everyday shape.
two_consoles() {
  local wt="$1"
  printf 'listening on :3000\n' > "$wt/.server-console.log"
  touch -t 202601010000 "$wt/.server-console.log"
  printf '3 failures, 0 errors\n' > "$wt/.tests-console.log"
}

@test "--console-list lists every recording by tag" {
  wt=$(make_worktree wt1)
  two_consoles "$wt"
  run "$POD" --console-list "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"server"* ]] || false
  [[ "$output" == *"tests"* ]]
}

@test "--console-list with no recordings → exit 0, message on stderr" {
  wt=$(make_worktree wt1)
  run --separate-stderr "$POD" --console-list "$wt"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"no console recording"* ]]
}

@test "--console reads every pane, each under a heading naming it" {
  wt=$(make_worktree wt1)
  two_consoles "$wt"
  run "$POD" --console "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"listening on :3000"* ]] || false
  [[ "$output" == *"3 failures"* ]] || false
  [[ "$output" == *"server"* ]] || false
  [[ "$output" == *"tests"* ]]
}

@test "--console orders panes oldest-written first, so the freshest reads last" {
  wt=$(make_worktree wt1)
  two_consoles "$wt"
  run "$POD" --console "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"listening on :3000"*"3 failures"* ]]
}

@test "--console --tag narrows to one pane" {
  wt=$(make_worktree wt1)
  two_consoles "$wt"
  run "$POD" --console --tag server "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"listening on :3000"* ]] || false
  [[ "$output" != *"3 failures"* ]]
}

@test "--console names the pane even when there's only one" {
  wt=$(make_worktree wt1)
  write_console "$wt" >/dev/null
  run "$POD" --console "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"main"* ]] || false
  [[ "$output" == *"boom: NoMethodError"* ]]
}

@test "a legacy .my-console.log is still discovered, tagged 'my'" {
  wt=$(make_worktree wt1)
  write_console "$wt" .my-console.log >/dev/null
  run "$POD" --console "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"my"* ]] || false
  [[ "$output" == *"boom: NoMethodError"* ]]
}

@test "--console --tag for an unknown tag → exit 1, lists what does exist" {
  wt=$(make_worktree wt1)
  two_consoles "$wt"
  run --separate-stderr "$POD" --console --tag nope "$wt"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"nope"* ]] || false
  [[ "$stderr" == *"server"* ]] || false
  [[ "$stderr" == *"tests"* ]]
}

@test "--tail bounds each pane independently, not the whole output" {
  wt=$(make_worktree wt1)
  printf 'server-old\nlistening on :3000\n' > "$wt/.server-console.log"
  touch -t 202601010000 "$wt/.server-console.log"
  printf 'tests-old\n3 failures, 0 errors\n' > "$wt/.tests-console.log"
  run "$POD" --console --tail 1 "$wt"
  [ "$status" -eq 0 ]
  # Last line of BOTH panes survives; the earlier line of each is dropped.
  [[ "$output" == *"listening on :3000"* ]] || false
  [[ "$output" == *"3 failures"* ]] || false
  [[ "$output" != *"server-old"* ]] || false
  [[ "$output" != *"tests-old"* ]]
}

@test "--tag outside --console/--record → exit 2" {
  wt=$(make_worktree wt1)
  run "$POD" --all --tag tests "$wt"
  [ "$status" -eq 2 ]
}

# ── Staleness: a log left behind looks exactly like a log being written ────────

@test "--console-list marks a recording nobody is holding open as ended" {
  wt=$(make_worktree wt1)
  two_consoles "$wt"
  run "$POD" --console-list "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ended"* ]] || false
  [[ "$output" != *"live"* ]]
}

@test "--console-list reports how long ago each pane was last written" {
  wt=$(make_worktree wt1)
  printf 'ancient\n' > "$wt/.server-console.log"
  touch -t 202601010000 "$wt/.server-console.log"
  run "$POD" --console-list "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ago"* ]] || false
  # Aged well over a year — must read in days, not minutes.
  [[ "$output" == *"d ago"* ]]
}

@test "--console-list marks a pane a live script process holds open as live" {
  wt=$(make_worktree wt1)
  cd "$wt"
  # A genuine script(1) recording, kept open. python gives it the tty it needs.
  python3 -c "import pty; pty.spawn(['script','-F','-q','.main-console.log','bash','-c','echo hi; sleep 20'])" \
    >/dev/null 2>&1 &
  local pid=$!
  # Wait for script to actually create and hold the file open.
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [[ -s "$wt/.main-console.log" ]] && break
    sleep 0.3
  done
  run "$POD" --console-list "$wt"
  kill "$pid" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ "$output" == *"live"* ]]
}

@test "--console heading says whether the pane is still live and how old it is" {
  wt=$(make_worktree wt1)
  printf 'ancient\n' > "$wt/.server-console.log"
  touch -t 202601010000 "$wt/.server-console.log"
  run "$POD" --console "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ended"* ]] || false
  [[ "$output" == *"ago"* ]] || false
  [[ "$output" == *"ancient"* ]]
}

# ── --new: read only what arrived since this reader last looked ────────────────
#
# Catching up with --tail/--turns re-reads lines already seen, so the more often
# Claude checks, the more it pays to re-read its own history. --new is the cursor
# that fixes that, and these tests pin the edges that make it trustworthy: a first
# read must not dump the world, an empty delta must SAY it's empty, and a
# re-recorded pane must not go silent forever.

@test "--console --new with no cursor yet falls back to the window, doesn't dump everything" {
  wt=$(make_worktree wt1)
  write_console "$wt" >/dev/null
  run "$POD" --console --new --tail 1 "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"boom: NoMethodError"* ]] || false
  [[ "$output" != *"PASS first-test"* ]]
}

@test "--console --new returns only what was appended since the last read" {
  wt=$(make_worktree wt1)
  write_console "$wt" >/dev/null
  run "$POD" --console --new "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"boom: NoMethodError"* ]] || false

  printf 'freshly-appended-line\n' >> "$wt/.main-console.log"
  run "$POD" --console --new "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"freshly-appended-line"* ]] || false
  [[ "$output" != *"boom: NoMethodError"* ]]
}

@test "--console --new with nothing appended says so, rather than printing nothing" {
  wt=$(make_worktree wt1)
  write_console "$wt" >/dev/null
  run "$POD" --console --new "$wt"
  [ "$status" -eq 0 ]

  run "$POD" --console --new "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no new output"* ]]
}

@test "--console --new recovers when the pane is re-recorded (script truncates)" {
  wt=$(make_worktree wt1)
  write_console "$wt" >/dev/null
  run "$POD" --console --new "$wt"
  [ "$status" -eq 0 ]

  # `rec` again → script truncates the log. The cursor now points past EOF.
  printf 'a brand new session\n' > "$wt/.main-console.log"
  run "$POD" --console --new "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"a brand new session"* ]] || false
  [[ "$output" == *"re-recorded"* ]]
}

@test "--console --new caps an oversized delta with --tail" {
  wt=$(make_worktree wt1)
  write_console "$wt" >/dev/null
  run "$POD" --console --new "$wt"
  [ "$status" -eq 0 ]

  # The pane exploded while we weren't looking.
  local i
  for i in $(seq 1 500); do printf 'flood-line-%s\n' "$i"; done >> "$wt/.main-console.log"
  run "$POD" --console --new --tail 5 "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"flood-line-500"* ]] || false
  [[ "$output" != *"flood-line-1"$'\n'* ]] || false
  [[ "$output" != *"flood-line-100"* ]]
}

@test "cursors are per reader session — two Claudes each get their own 'what's new'" {
  wt=$(make_worktree wt1)
  write_console "$wt" >/dev/null

  export CLAUDE_CODE_SESSION_ID="aaaaaaaa-1111-1111-1111-aaaaaaaaaaaa"
  run "$POD" --console --new "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"boom: NoMethodError"* ]] || false

  # A different reader has never looked; it must still see the content.
  export CLAUDE_CODE_SESSION_ID="bbbbbbbb-2222-2222-2222-bbbbbbbbbbbb"
  run "$POD" --console --new "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"boom: NoMethodError"* ]]
}

@test "--session --new returns only turns added since the last read" {
  wt=$(make_worktree wt1)
  sid="dddddddd-1111-2222-3333-444444444444"
  write_session "$wt" "$sid" >/dev/null
  run "$POD" --session "$sid" --new "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello"* ]] || false

  local file
  file="$(session_dir_for "$wt")/$sid.jsonl"
  cat >> "$file" <<EOF
{"type":"assistant","sessionId":"$sid","timestamp":"2026-05-17T00:05:00Z","message":{"content":[{"type":"text","text":"a-brand-new-turn"}]}}
EOF
  run "$POD" --session "$sid" --new "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"a-brand-new-turn"* ]] || false
  [[ "$output" != *"hello"* ]]
}

@test "--session --new with no new turns says so" {
  wt=$(make_worktree wt1)
  sid="eeeeeeee-1111-2222-3333-444444444444"
  write_session "$wt" "$sid" >/dev/null
  run "$POD" --session "$sid" --new "$wt"
  [ "$status" -eq 0 ]

  run "$POD" --session "$sid" --new "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no new"* ]]
}

@test "--peers --new renders each peer's new turns, headed by session" {
  wt=$(make_worktree wt1)
  write_session "$wt" "11111111-2222-3333-4444-555555555555" >/dev/null
  write_session "$wt" "22222222-3333-4444-5555-666666666666" >/dev/null
  export CLAUDE_CODE_SESSION_ID="11111111-2222-3333-4444-555555555555"
  run "$POD" --peers --new "$wt"
  [ "$status" -eq 0 ]
  # The peer's turns, not our own.
  [[ "$output" == *"hi"* ]] || false
  [[ "$output" == *"22222222"* ]] || false
  [[ "$output" != *"11111111"* ]]
}

# ── --record: hand the human a command to start recording ──────────────────────

@test "--record prints a script(1) command for the default log path" {
  wt=$(make_worktree wt1)
  run "$POD" --record "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"script -F -q"* ]] || false
  [[ "$output" == *".main-console.log"* ]]
}

@test "--record warns when the log path isn't gitignored" {
  wt=$(make_worktree wt1)
  git -C "$wt" init -q
  run "$POD" --record "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gitignore"* ]]
}

@test "--record stays quiet about gitignore when the path is already ignored" {
  wt=$(make_worktree wt1)
  git -C "$wt" init -q
  printf '.*console*.log\n' > "$wt/.gitignore"
  run "$POD" --record "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" != *"gitignore"* ]]
}

@test "--record notes a recording is already in progress" {
  wt=$(make_worktree wt1)
  write_console "$wt" >/dev/null
  run "$POD" --record "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already"* ]]
}

@test "--record --tag names a per-pane log" {
  wt=$(make_worktree wt1)
  run "$POD" --record --tag tests "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *".tests-console.log"* ]]
}

@test "--record --tag doesn't warn about an unrelated pane's existing log" {
  wt=$(make_worktree wt1)
  printf 'listening on :3000\n' > "$wt/.server-console.log"
  run "$POD" --record --tag tests "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" != *"already"* ]]
}

# ── Codex source (--codex) ──────────────────────────────────────────────────────
#
# Codex (the OpenAI CLI) stores sessions under ~/.codex/sessions/YYYY/MM/DD/ with
# no per-worktree directory: the worktree is recorded as payload.cwd in a
# session_meta header line. Turns are response_item/message lines. These fixtures
# and tests exercise the --codex source (issue #18). AGENT_READ_CODEX_DIR is
# redirected into BATS_TEST_TMPDIR by setup().

# write_codex_session CWD SID [ROLE:TEXT ...]
#   Writes a Codex rollout file whose session_meta header records CWD, followed by
#   one response_item/message turn per ROLE:TEXT pair (default: a user + assistant
#   turn). Filename ends in the SID, mirroring Codex's rollout-<ts>-<uuid>.jsonl.
#   Echoes the file path.
write_codex_session() {
  local cwd="$1" sid="$2"; shift 2
  local day="$AGENT_READ_CODEX_DIR/2026/07/15"
  mkdir -p "$day"
  local file="$day/rollout-2026-07-15T10-00-00-$sid.jsonl"
  {
    printf '{"timestamp":"2026-07-15T10:00:00.000Z","type":"session_meta","payload":{"id":"%s","cwd":"%s","cli_version":"0.38.0"}}\n' "$sid" "$cwd"
    if [[ $# -eq 0 ]]; then
      set -- "user:hello from codex" "assistant:hi from codex"
    fi
    local i=1 pair role text ct
    for pair in "$@"; do
      role="${pair%%:*}"; text="${pair#*:}"
      if [[ "$role" == user ]]; then ct=input_text; else ct=output_text; fi
      printf '{"timestamp":"2026-07-15T10:00:0%d.000Z","type":"response_item","payload":{"type":"message","role":"%s","content":[{"type":"%s","text":"%s"}]}}\n' "$i" "$role" "$ct" "$text"
      i=$((i + 1))
    done
  } > "$file"
  echo "$file"
}

# write_codex_subagent CWD SID
#   Like write_codex_session but tags the header as a subagent rollout, which
#   --codex discovery must exclude.
write_codex_subagent() {
  local cwd="$1" sid="$2"
  local day="$AGENT_READ_CODEX_DIR/2026/07/15"
  mkdir -p "$day"
  local file="$day/rollout-2026-07-15T10-00-00-$sid.jsonl"
  {
    printf '{"timestamp":"2026-07-15T10:00:00.000Z","type":"session_meta","payload":{"id":"%s","cwd":"%s","source":{"subagent":{"other":"guardian"}}}}\n' "$sid" "$cwd"
    printf '{"timestamp":"2026-07-15T10:00:01.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"subagent output"}]}}\n'
  } > "$file"
  echo "$file"
}

@test "--codex renders the most-recent codex session in a worktree" {
  wt=$(make_worktree cwt1)
  write_codex_session "$wt" "aaaaaaaa-1111-2222-3333-444444444444" >/dev/null
  run "$POD" --codex "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello from codex"* ]] || false
  [[ "$output" == *"hi from codex"* ]]
}

@test "--codex matches on the header cwd, not a per-worktree directory" {
  wt1=$(make_worktree cwt1)
  wt2=$(make_worktree cwt2)
  write_codex_session "$wt1" "aaaaaaaa-1111-2222-3333-444444444444" "user:in wt1" >/dev/null
  write_codex_session "$wt2" "bbbbbbbb-1111-2222-3333-444444444444" "user:in wt2" >/dev/null
  run "$POD" --codex "$wt1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"in wt1"* ]] || false
  [[ "$output" != *"in wt2"* ]]
}

@test "--codex --all lists codex sessions for the worktree" {
  wt=$(make_worktree cwt1)
  write_codex_session "$wt" "aaaaaaaa-1111-2222-3333-444444444444" >/dev/null
  run "$POD" --codex --all "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"harness"* ]] || false
  [[ "$output" == *"codex"* ]] || false
  [[ "$output" == *"aaaaaaaa-1111-2222-3333-444444444444"* ]]
}

@test "--codex --all excludes subagent rollouts" {
  wt=$(make_worktree cwt1)
  write_codex_session "$wt" "aaaaaaaa-1111-2222-3333-444444444444" >/dev/null
  write_codex_subagent "$wt" "99999999-1111-2222-3333-444444444444" >/dev/null
  run "$POD" --codex --all "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"aaaaaaaa-1111-2222-3333-444444444444"* ]] || false
  [[ "$output" != *"99999999-1111-2222-3333-444444444444"* ]]
}

@test "--codex --session renders a codex session by UUID, cross-worktree" {
  wt=$(make_worktree cwt1)
  write_codex_session "$wt" "aaaaaaaa-1111-2222-3333-444444444444" "user:find me by id" >/dev/null
  # Run from a different directory to prove the lookup isn't worktree-scoped.
  run "$POD" --codex --session "aaaaaaaa-1111-2222-3333-444444444444" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"find me by id"* ]]
}

@test "--codex --session rejects a /rename name (unsupported for codex)" {
  wt=$(make_worktree cwt1)
  write_codex_session "$wt" "aaaaaaaa-1111-2222-3333-444444444444" >/dev/null
  run "$POD" --codex --session some-name "$wt"
  [ "$status" -ne 0 ]
}

@test "--codex with no matching sessions → exit 0, message on stderr" {
  wt=$(make_worktree cwt1)
  run --separate-stderr "$POD" --codex --all "$wt"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"no matching"* ]]
}

@test "--codex with --console → exit 2" {
  wt=$(make_worktree cwt1)
  run "$POD" --codex --console "$wt"
  [ "$status" -eq 2 ]
}

@test "--codex --since filters by timestamp" {
  wt=$(make_worktree cwt1)
  write_codex_session "$wt" "aaaaaaaa-1111-2222-3333-444444444444" \
    "user:ancient turn" "assistant:ancient reply" >/dev/null
  # The fixture's turns are dated 2026-07-15; a 1s window excludes them.
  file="$AGENT_READ_CODEX_DIR/2026/07/15/rollout-2026-07-15T10-00-00-aaaaaaaa-1111-2222-3333-444444444444.jsonl"
  touch -t 202401010000 "$file"
  run "$POD" --codex --since 1s "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ancient turn"* ]] || false
  # Same fixture, no window: the exclusion above has to be the window, not a
  # reader that renders nothing at all.
  run "$POD" --codex "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ancient turn"* ]]
}

@test "--codex --all --new renders each codex session's new turns" {
  wt=$(make_worktree cwt1)
  write_codex_session "$wt" "aaaaaaaa-1111-2222-3333-444444444444" \
    "user:fresh codex turn" "assistant:fresh codex reply" >/dev/null
  run "$POD" --codex --all --new "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fresh codex turn"* ]]
}

@test "--codex --peers -f (firehose) → exit 2, points at --new" {
  wt=$(make_worktree cwt1)
  write_codex_session "$wt" "aaaaaaaa-1111-2222-3333-444444444444" >/dev/null
  export CLAUDE_CODE_SESSION_ID=observer-session
  run "$POD" --codex --peers -f "$wt"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--new"* ]]
}

# Regression: render_session_new keys its filter on the global CURSOR_TS. In the
# --all/--peers --new loop it's called once per session; if a session that HAS a
# cursor is processed before one that has NONE, the first session's cursor must
# not leak into the second and filter away its first read.
@test "--codex --all --new: a read peer's cursor doesn't suppress an unread peer's first read" {
  wt=$(make_worktree cwt1)
  A=aaaaaaaa-1111-2222-3333-444444444444
  B=bbbbbbbb-1111-2222-3333-444444444444
  write_codex_session "$wt" "$B" "user:unread peer turn" >/dev/null
  fA=$(write_codex_session "$wt" "$A" "user:read peer turn")
  # Make A the newest so --all iterates it first (and it carries a cursor).
  touch "$fA"
  # Give A a cursor by reading it alone; B stays unread.
  run "$POD" --codex --session "$A" --new "$wt"
  [ "$status" -eq 0 ]
  # Now catch up on every peer. B has never been read, so its turn must appear
  # even though A (processed first) advanced CURSOR_TS.
  run "$POD" --codex --all --new "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unread peer turn"* ]]
}

# A worktree reached through a symlink has a logical path (the symlink) and a
# physical one (the target). Codex may record either; discovery must match a
# session recorded under the physical path when queried via the logical one.
@test "--codex matches a worktree whose recorded cwd is the physical path" {
  realwt="$BATS_TEST_TMPDIR/realdir"
  mkdir -p "$realwt"
  link="$BATS_TEST_TMPDIR/linkdir"
  ln -s "$realwt" "$link"
  phys="$(cd "$realwt" && pwd -P)"
  write_codex_session "$phys" "aaaaaaaa-1111-2222-3333-444444444444" "user:via symlink" >/dev/null
  run "$POD" --codex "$link"
  [ "$status" -eq 0 ]
  [[ "$output" == *"via symlink"* ]]
}

# ── Auto source detection (no --codex/--claude flag) ────────────────────────────
#
# With neither flag, agent-read picks the source that has sessions for the
# worktree; when both do, the more recently active one wins and a hint on stderr
# names the quiet source so a mixed worktree's other half isn't hidden.

@test "auto source: renders Codex when only Codex has sessions here" {
  wt=$(make_worktree awt)
  # make_worktree created an (empty) Claude project dir; only Codex has turns.
  write_codex_session "$wt" "aaaaaaaa-1111-2222-3333-444444444444" "user:codex only" >/dev/null
  run "$POD" "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex only"* ]]
}

@test "auto source: still renders Claude when only Claude has sessions here" {
  wt=$(make_worktree awt)
  write_session "$wt" "11111111-1111-1111-1111-111111111111" >/dev/null
  run "$POD" "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello"* ]]
}

@test "--all merges Claude and Codex sessions without a source-selection hint" {
  wt=$(make_worktree awt)
  cf=$(write_session "$wt" "11111111-1111-1111-1111-111111111111")
  write_codex_session "$wt" "aaaaaaaa-1111-2222-3333-444444444444" "user:codex is fresher" >/dev/null
  xf="$AGENT_READ_CODEX_DIR/2026/07/15/rollout-2026-07-15T10-00-00-aaaaaaaa-1111-2222-3333-444444444444.jsonl"
  touch -t 202001010000 "$cf"
  touch "$xf"
  run --separate-stderr "$POD" --all "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"harness"* ]] || false
  [[ "$output" == *"codex"* ]] || false
  [[ "$output" == *"aaaaaaaa-1111-2222-3333-444444444444"* ]] || false
  [[ "$output" == *"11111111-1111-1111-1111-111111111111"* ]]
  [[ -z "$stderr" ]]
}

@test "auto source: with both, Claude wins when it's fresher, hint points at --codex" {
  wt=$(make_worktree awt)
  cf=$(write_session "$wt" "11111111-1111-1111-1111-111111111111")
  write_codex_session "$wt" "aaaaaaaa-1111-2222-3333-444444444444" "user:codex here too" >/dev/null
  xf="$AGENT_READ_CODEX_DIR/2026/07/15/rollout-2026-07-15T10-00-00-aaaaaaaa-1111-2222-3333-444444444444.jsonl"
  touch -t 202001010000 "$xf"
  touch "$cf"
  run --separate-stderr "$POD" "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello"* ]] || false
  [[ "$stderr" == *"--codex"* ]]
}

@test "--claude forces the Claude source even when Codex is more recent" {
  wt=$(make_worktree awt)
  cf=$(write_session "$wt" "11111111-1111-1111-1111-111111111111")
  write_codex_session "$wt" "aaaaaaaa-1111-2222-3333-444444444444" "user:codex fresher" >/dev/null
  xf="$AGENT_READ_CODEX_DIR/2026/07/15/rollout-2026-07-15T10-00-00-aaaaaaaa-1111-2222-3333-444444444444.jsonl"
  touch -t 202001010000 "$cf"
  touch "$xf"
  run "$POD" --claude "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello"* ]] || false
  [[ "$output" != *"codex fresher"* ]]
}

@test "--session with no source flag resolves a Codex-only UUID" {
  wt=$(make_worktree awt)
  write_codex_session "$wt" "aaaaaaaa-1111-2222-3333-444444444444" "user:codex by uuid auto" >/dev/null
  run "$POD" --session "aaaaaaaa-1111-2222-3333-444444444444" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex by uuid auto"* ]]
}

# ── pi source (--pi) ─────────────────────────────────────────────────────────────
#
# pi (pi.dev) stores sessions under ~/.pi/agent/sessions/<encoded-cwd>/, one
# directory per worktree like Claude — but the path encoding differs from
# Claude's encode_path (issue: verified against real ~/.pi/agent/sessions data).
# pi replaces ONLY '/' with '-' (not every non-alphanumeric char — an
# underscore in a real cwd survived untouched), and wraps the whole thing in a
# DOUBLE leading and trailing '-': encode_pi_path() below reproduces exactly
# that, confirmed byte-for-byte against 13 real directories.
#
# Filenames are <timestamp>_<uuid>.jsonl (the uuid is the tail after the last
# underscore) — unlike Claude's bare <uuid>.jsonl, so sid extraction needs a
# tail-of-filename approach like Codex's, not a bare `${f%.jsonl}`.
#
# pi has no /rename mechanism and no live-session registry (no analogue to
# ~/.claude/sessions/<pid>.json or $CLAUDE_CODE_SESSION_ID), so --session by
# name is unsupported (like Codex) and --peers cannot self-exclude (documented
# limitation, not an error).

# encode_pi_path /Users/x/y → --Users-x-y-- (mirrors agent-read's pi encoding)
encode_pi_path() {
  printf -- '--%s--' "$(printf '%s' "${1#/}" | sed 's/\//-/g')"
}

# pi_session_dir_for WORKTREE → encoded ~/.pi/agent/sessions subdir
pi_session_dir_for() {
  echo "$AGENT_READ_PI_DIR/$(encode_pi_path "$(cd "$1" && pwd)")"
}

# write_pi_session WORKTREE SID [ROLE:TEXT ...]
#   Writes a pi session file: a type=session header record (carrying id + cwd),
#   followed by one type=message turn per ROLE:TEXT pair (default: a user +
#   assistant turn). Filename is <timestamp>_<uuid>.jsonl, mirroring pi's
#   real naming. Echoes the file path.
write_pi_session() {
  local wt="$1" sid="$2"; shift 2
  local dir cwd
  dir=$(pi_session_dir_for "$wt")
  cwd=$(cd "$wt" && pwd)
  mkdir -p "$dir"
  local file="$dir/2026-07-15T10-00-00-000Z_$sid.jsonl"
  {
    printf '{"type":"session","version":3,"id":"%s","timestamp":"2026-07-15T10:00:00.000Z","cwd":"%s"}\n' "$sid" "$cwd"
    if [[ $# -eq 0 ]]; then
      set -- "user:hello from pi" "assistant:hi from pi"
    fi
    local i=1 pair role text
    for pair in "$@"; do
      role="${pair%%:*}"; text="${pair#*:}"
      printf '{"type":"message","id":"m%d","parentId":null,"timestamp":"2026-07-15T10:00:0%d.000Z","message":{"role":"%s","content":[{"type":"text","text":"%s"}]}}\n' "$i" "$i" "$role" "$text"
      i=$((i + 1))
    done
  } > "$file"
  echo "$file"
}

@test "--all merges all three sources newest first, with one header" {
  wt=$(make_worktree mixed)
  cf=$(write_session "$wt" "11111111-1111-1111-1111-111111111111")
  xf=$(write_codex_session "$wt" "aaaaaaaa-1111-2222-3333-444444444444" "user:codex mixed")
  pf=$(write_pi_session "$wt" "bbbbbbbb-1111-2222-3333-444444444444")
  touch -t 202001010000 "$cf"
  touch -t 202101010000 "$xf"
  touch -t 202201010000 "$pf"
  run --separate-stderr "$POD" --all "$wt"
  [ "$status" -eq 0 ]
  [[ "${lines[1]}" == *"bbbbbbbb"* ]]
  [[ "${lines[2]}" == *"aaaaaaaa"* ]]
  [[ "${lines[3]}" == *"11111111-1111"* ]]
  [ "${#lines[@]}" -eq 4 ]
  [[ -z "$stderr" ]]

  run "$POD" --claude --all "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"11111111-1111"* ]]
  [[ "$output" != *"aaaaaaaa"* && "$output" != *"bbbbbbbb"* ]]
}

@test "--all --new renders every source with its own parser and cursor" {
  wt=$(make_worktree mixed)
  write_session "$wt" "11111111-1111-1111-1111-111111111111" >/dev/null
  write_codex_session "$wt" "aaaaaaaa-1111-2222-3333-444444444444" "user:codex mixed" >/dev/null
  write_pi_session "$wt" "bbbbbbbb-1111-2222-3333-444444444444" >/dev/null
  run "$POD" --all --new "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello"* && "$output" == *"codex mixed"* && "$output" == *"hello from pi"* ]]
  run "$POD" --all --new "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" != *"hello"* && "$output" != *"codex mixed"* ]]
}

@test "--all includes pi even without a Claude project directory" {
  wt=$(make_worktree mixed)
  rmdir "$(session_dir_for "$wt")"
  write_pi_session "$wt" "bbbbbbbb-1111-2222-3333-444444444444" >/dev/null
  run "$POD" --all "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bbbbbbbb"* ]]
}

@test "--all follow refuses to silently hide non-Claude sessions" {
  wt=$(make_worktree mixed)
  write_session "$wt" "11111111-1111-1111-1111-111111111111" >/dev/null
  write_pi_session "$wt" "bbbbbbbb-1111-2222-3333-444444444444" >/dev/null
  run "$POD" --all -f "$wt"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--new"* && "$output" == *"--claude"* ]]
}

@test "--peers merges sources while excluding the observing Claude" {
  wt=$(make_worktree mixed)
  export CLAUDE_CODE_SESSION_ID=11111111-1111-1111-1111-111111111111
  write_session "$wt" "$CLAUDE_CODE_SESSION_ID" >/dev/null
  write_pi_session "$wt" "bbbbbbbb-1111-2222-3333-444444444444" >/dev/null
  run "$POD" --peers "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bbbbbbbb"* && "$output" != *"$CLAUDE_CODE_SESSION_ID"* ]]
}

@test "--all with only filtered-out Codex sessions is an empty success" {
  wt=$(make_worktree mixed)
  rmdir "$(session_dir_for "$wt")"
  xf=$(write_codex_session "$wt" "aaaaaaaa-1111-2222-3333-444444444444" "user:old codex")
  touch -t 202001010000 "$xf"
  run --separate-stderr "$POD" --all --since 1h "$wt"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"no matching sessions"* ]]
}

@test "--all applies since and exclude across sources" {
  wt=$(make_worktree mixed)
  cf=$(write_session "$wt" "11111111-1111-1111-1111-111111111111")
  write_pi_session "$wt" "bbbbbbbb-1111-2222-3333-444444444444" >/dev/null
  write_pi_session "$wt" "cccccccc-1111-2222-3333-444444444444" >/dev/null
  touch -t 202001010000 "$cf"
  run "$POD" --all --since 1h --exclude bbbbbbbb-1111-2222-3333-444444444444 "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cccccccc"* ]]
  [[ "$output" != *"bbbbbbbb"* && "$output" != *"11111111-1111-1111-1111-111111111111"* ]]
}

@test "--pi renders the most-recent pi session in a worktree" {
  wt=$(make_worktree pwt1)
  write_pi_session "$wt" "01a08278-fc36-778e-8e2e-72bdb768aad2" >/dev/null
  run "$POD" --pi "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello from pi"* ]] || false
  [[ "$output" == *"hi from pi"* ]] || false
}

@test "--pi encodes the worktree path the way pi actually does (double-dash wrap)" {
  wt=$(make_worktree pwt1)
  write_pi_session "$wt" "01a08278-fc36-778e-8e2e-72bdb768aad2" "user:findable" >/dev/null
  run "$POD" --pi "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"findable"* ]] || false
}

@test "--pi --all lists pi sessions for the worktree" {
  wt=$(make_worktree pwt1)
  write_pi_session "$wt" "01a08278-fc36-778e-8e2e-72bdb768aad2" >/dev/null
  run "$POD" --pi --all "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"harness"* ]] || false
  [[ "$output" == *"pi"* ]] || false
  [[ "$output" == *"01a08278-fc36-778e-8e2e-72bdb768aad2"* ]] || false
}

@test "--pi --session renders a pi session by UUID, cross-worktree" {
  wt=$(make_worktree pwt1)
  write_pi_session "$wt" "01a08278-fc36-778e-8e2e-72bdb768aad2" "user:find me by id" >/dev/null
  run "$POD" --pi --session "01a08278-fc36-778e-8e2e-72bdb768aad2" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"find me by id"* ]] || false
}

@test "--pi --session rejects a /rename name (unsupported for pi)" {
  wt=$(make_worktree pwt1)
  write_pi_session "$wt" "01a08278-fc36-778e-8e2e-72bdb768aad2" >/dev/null
  run "$POD" --pi --session some-name "$wt"
  [ "$status" -ne 0 ]
}

@test "--pi with a pi dir that exists but has no sessions → exit 0, message on stderr" {
  wt=$(make_worktree pwt1)
  mkdir -p "$(pi_session_dir_for "$wt")"
  run --separate-stderr "$POD" --pi --all "$wt"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"no matching"* ]] || false
}

# pi's directory is worktree-scoped like Claude's, so a worktree pi has never
# run in is the same "bad path" case Claude's own bad-path test covers — not
# Codex's "exit 0" (Codex has no per-worktree directory to be missing).
@test "--pi with a worktree pi has never used → exit 1" {
  wt=$(make_worktree pwt1)
  run --separate-stderr "$POD" --pi --all "$wt"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"no pi sessions"* ]] || false
}

@test "--pi with --console → exit 2" {
  wt=$(make_worktree pwt1)
  run "$POD" --pi --console "$wt"
  [ "$status" -eq 2 ]
}

@test "--pi --since filters by timestamp" {
  wt=$(make_worktree pwt1)
  f=$(write_pi_session "$wt" "01a08278-fc36-778e-8e2e-72bdb768aad2" \
    "user:ancient turn" "assistant:ancient reply")
  touch -t 202401010000 "$f"
  run "$POD" --pi --since 1s "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ancient turn"* ]] || false
  run "$POD" --pi "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ancient turn"* ]]
}

@test "--pi --all --new renders each pi session's new turns" {
  wt=$(make_worktree pwt1)
  write_pi_session "$wt" "01a08278-fc36-778e-8e2e-72bdb768aad2" \
    "user:fresh pi turn" "assistant:fresh pi reply" >/dev/null
  run "$POD" --pi --all --new "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fresh pi turn"* ]] || false
}

@test "--pi --peers -f (firehose) → exit 2, points at --new" {
  wt=$(make_worktree pwt1)
  write_pi_session "$wt" "01a08278-fc36-778e-8e2e-72bdb768aad2" >/dev/null
  export CLAUDE_CODE_SESSION_ID=observer-session
  run "$POD" --pi --peers -f "$wt"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--new"* ]] || false
}

# pi has no live-session registry to resolve $CLAUDE_CODE_SESSION_ID against, so
# --peers can't actually exclude "this session" for pi — it behaves like --all.
# This is a documented limitation (see usage() and resolve_render_file), not a
# bug: the session id passed to --peers is a Claude session id, which simply
# never matches a pi UUID, exactly like Codex's --peers-is-really---all behavior.
@test "--pi --peers behaves like --all (no self-exclusion is possible for pi)" {
  wt=$(make_worktree pwt1)
  write_pi_session "$wt" "01a08278-fc36-778e-8e2e-72bdb768aad2" "user:peer turn" >/dev/null
  export CLAUDE_CODE_SESSION_ID=observer-session
  run "$POD" --pi --peers "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"01a08278-fc36-778e-8e2e-72bdb768aad2"* ]] || false
}

@test "--pi --all --new: a read peer's cursor doesn't suppress an unread peer's first read" {
  wt=$(make_worktree pwt1)
  A=01a08278-fc36-778e-8e2e-72bdb768aad2
  B=01a08279-fc36-778e-8e2e-72bdb768aad3
  write_pi_session "$wt" "$B" "user:unread peer turn" >/dev/null
  fA=$(write_pi_session "$wt" "$A" "user:read peer turn")
  touch "$fA"
  run "$POD" --pi --session "$A" --new "$wt"
  [ "$status" -eq 0 ]
  run "$POD" --pi --all --new "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unread peer turn"* ]] || false
}

@test "--pi filters out non-message records (model_change, thinking_level_change)" {
  wt=$(make_worktree pwt1)
  dir=$(pi_session_dir_for "$wt")
  mkdir -p "$dir"
  sid=01a08278-fc36-778e-8e2e-72bdb768aad2
  cwd=$(cd "$wt" && pwd)
  file="$dir/2026-07-15T10-00-00-000Z_$sid.jsonl"
  {
    printf '{"type":"session","version":3,"id":"%s","timestamp":"2026-07-15T10:00:00.000Z","cwd":"%s"}\n' "$sid" "$cwd"
    printf '{"type":"model_change","id":"m0","parentId":null,"timestamp":"2026-07-15T10:00:01.000Z","provider":"x","modelId":"y"}\n'
    printf '{"type":"message","id":"m1","parentId":null,"timestamp":"2026-07-15T10:00:02.000Z","message":{"role":"user","content":[{"type":"text","text":"real turn"}]}}\n'
  } > "$file"
  run "$POD" --pi "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"real turn"* ]] || false
  [[ "$output" != *"model_change"* ]] || false
}

@test "--pi filters assistant content blocks to type=text (drops thinking/toolCall)" {
  wt=$(make_worktree pwt1)
  dir=$(pi_session_dir_for "$wt")
  mkdir -p "$dir"
  sid=01a08278-fc36-778e-8e2e-72bdb768aad2
  cwd=$(cd "$wt" && pwd)
  file="$dir/2026-07-15T10-00-00-000Z_$sid.jsonl"
  # thinking/toolCall blocks have no .text field at all, so they're dropped by
  # simply not surviving `values this.text` regardless of the type=='text'
  # guard — that alone wouldn't prove the guard does anything. A toolResult
  # block that (like a real tool result might) DOES carry a .text field is
  # what actually exercises the guard: without it, this leaks into the output.
  {
    printf '{"type":"session","version":3,"id":"%s","timestamp":"2026-07-15T10:00:00.000Z","cwd":"%s"}\n' "$sid" "$cwd"
    printf '{"type":"message","id":"m1","parentId":null,"timestamp":"2026-07-15T10:00:01.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"pondering"},{"type":"toolCall","id":"c1","name":"bash","arguments":{}},{"type":"toolResult","text":"tool output leaked"},{"type":"text","text":"the real reply"}]}}\n'
  } > "$file"
  run "$POD" --pi "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"the real reply"* ]] || false
  [[ "$output" != *"pondering"* ]] || false
  [[ "$output" != *"tool output leaked"* ]] || false
  [[ "$output" != *"bash"* ]] || false
}

# ── Auto source detection with pi ────────────────────────────────────────────────

@test "auto source: renders pi when only pi has sessions here" {
  wt=$(make_worktree awt)
  write_pi_session "$wt" "01a08278-fc36-778e-8e2e-72bdb768aad2" "user:pi only" >/dev/null
  run "$POD" "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pi only"* ]] || false
}

@test "auto source: with claude and pi both present, the more recent wins (pi), hint names claude" {
  wt=$(make_worktree awt)
  cf=$(write_session "$wt" "11111111-1111-1111-1111-111111111111")
  pf=$(write_pi_session "$wt" "01a08278-fc36-778e-8e2e-72bdb768aad2" "user:pi is fresher")
  touch -t 202001010000 "$cf"
  touch "$pf"
  run --separate-stderr "$POD" "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pi is fresher"* ]] || false
  [[ "$stderr" == *"claude"* ]] || false
}

@test "--pi forces the pi source even when Claude is more recent" {
  wt=$(make_worktree awt)
  cf=$(write_session "$wt" "11111111-1111-1111-1111-111111111111")
  pf=$(write_pi_session "$wt" "01a08278-fc36-778e-8e2e-72bdb768aad2" "user:pi older")
  touch "$cf"
  touch -t 202001010000 "$pf"
  run "$POD" --pi "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pi older"* ]] || false
  [[ "$output" != *"hello"* ]] || false
}

@test "--session with no source flag resolves a pi-only UUID" {
  wt=$(make_worktree awt)
  write_pi_session "$wt" "01a08278-fc36-778e-8e2e-72bdb768aad2" "user:pi by uuid auto" >/dev/null
  run "$POD" --session "01a08278-fc36-778e-8e2e-72bdb768aad2" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pi by uuid auto"* ]] || false
}
