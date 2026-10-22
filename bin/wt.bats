#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for bin/wt (fzf worktree selector), migrated from
# brain/git/worktrees.sh.
#
# The parse is the part worth pinning. `git worktree list --porcelain` emits
# variable-length blocks, and the super pipeline pairs the "worktree" and
# "branch" lines by line COUNT — so any block that doesn't contribute exactly
# one of each desynchronizes every worktree after it. Detached and bare
# worktrees are exactly those blocks. Several tests below are regressions for
# observed corruption, not hypotheticals.
#
# As with wt-new, stdout is EXACTLY the selected path so `wt()` can cd to it.

WT="$BATS_TEST_DIRNAME/wt"

setup() {
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export CLAUDE_PROJECTS_DIR="$TMP/claude"
  export AGENT_READ_PI_DIR="$TMP/pi"
  export AGENT_READ_CODEX_DIR="$TMP/codex"
  source "$WT"
}

# Porcelain for: main repo on main, a detached worktree IN THE MIDDLE, and a
# normal branch worktree after it.
porcelain_with_detached_middle() {
  cat <<'EOF'
worktree /x/r
HEAD abc123
branch refs/heads/main

worktree /x/d
HEAD abc123
detached

worktree /x/b
HEAD abc123
branch refs/heads/feat
EOF
}

# ── wt_parse_worktrees ───────────────────────────────────────────────────────

@test "parses dir and branch for ordinary worktrees" {
  run bash -c 'source "$1"; printf "%s\n" "worktree /x/r" "HEAD abc" "branch refs/heads/main" | wt_parse_worktrees' _ "$WT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"dir":"/x/r"'* ]] || false
  [[ "$output" == *'"branch":"main"'* ]] || false
  [[ "$output" == *'"leaf":"r"'* ]]
}

@test "a detached worktree gets a readable branch label, not an error value" {
  run bash -c 'source "$1"; printf "%s\n" "worktree /x/d" "HEAD abc" "detached" | wt_parse_worktrees' _ "$WT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'(detached)'* ]] || false
  [[ "$output" != *'error'* ]]
}

@test "a bare worktree gets a readable branch label" {
  run bash -c 'source "$1"; printf "%s\n" "worktree /x/bare" "HEAD abc" "bare" | wt_parse_worktrees' _ "$WT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'(bare)'* ]] || false
  [[ "$output" != *'error'* ]]
}

@test "a detached worktree in the middle does not desync the ones after it" {
  # Regression: with count-based pairing and no handling for the odd block,
  # /x/b was emitted with dir:null and became unreachable from the selector.
  run bash -c 'source "$1"; wt_parse_worktrees' _ "$WT" <<< "$(porcelain_with_detached_middle)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 3 ]
  [[ "$output" == *'"dir":"/x/b","branch":"feat"'* ]] || false
  [[ "$output" != *'null'* ]]
}

@test "preserves the order git reported" {
  run bash -c 'source "$1"; wt_parse_worktrees' _ "$WT" <<< "$(porcelain_with_detached_middle)"
  [ "$status" -eq 0 ]
  [[ "$(printf '%s\n' "$output" | sed -n 1p)" == *'/x/r'* ]] || false
  [[ "$(printf '%s\n' "$output" | sed -n 2p)" == *'/x/d'* ]] || false
  [[ "$(printf '%s\n' "$output" | sed -n 3p)" == *'/x/b'* ]]
}

@test "handles paths containing spaces" {
  run bash -c 'source "$1"; printf "%s\n" "worktree /x/my project" "HEAD abc" "branch refs/heads/main" | wt_parse_worktrees' _ "$WT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"dir":"/x/my project"'* ]] || false
  [[ "$output" == *'"leaf":"my project"'* ]]
}

@test "a branch literally named 'detached' is not mangled into the placeholder" {
  run bash -c 'source "$1"; printf "%s\n" "worktree /x/w" "HEAD abc" "branch refs/heads/detached" | wt_parse_worktrees' _ "$WT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"branch":"detached"'* ]] || false
  [[ "$output" != *'(detached)'* ]]
}

@test "keeps slashes in nested branch names" {
  run bash -c 'source "$1"; printf "%s\n" "worktree /x/w" "HEAD abc" "branch refs/heads/feature/nested-name" | wt_parse_worktrees' _ "$WT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"branch":"feature/nested-name"'* ]]
}

@test "ignores locked and prunable annotations" {
  run bash -c 'source "$1"; printf "%s\n" "worktree /x/w" "HEAD abc" "branch refs/heads/main" "locked" "prunable gitdir file points nowhere" | wt_parse_worktrees' _ "$WT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
  [[ "$output" == *'"branch":"main"'* ]]
}

# ── wt_display_lines ─────────────────────────────────────────────────────────
# "<dir>\t<leaf> [<branch>]" — fzf shows field 2+, the path rides along hidden
# in field 1 so duplicate leaf names still resolve to the right worktree.

@test "display lines are dir TAB 'leaf [branch]'" {
  run bash -c 'source "$1"; wt_parse_worktrees | wt_display_lines' _ "$WT" \
    <<< "$(porcelain_with_detached_middle)"
  [ "$status" -eq 0 ]
  [[ "$(printf '%s\n' "$output" | sed -n 1p)" == $'/x/r\tr [main]' ]] || false
  [[ "$(printf '%s\n' "$output" | sed -n 2p)" == $'/x/d\td [(detached)]' ]] || false
  [[ "$(printf '%s\n' "$output" | sed -n 3p)" == $'/x/b\tb [feat]' ]]
}

# ── Transcript recency ───────────────────────────────────────────────────────

session_file() {
  local source="$1" dir="$2" name="$3" stamp="$4" encoded file
  case "$source" in
    claude)
      encoded=$(printf '%s' "$dir" | sed 's/[^a-zA-Z0-9]/-/g')
      file="$CLAUDE_PROJECTS_DIR/$encoded/$name.jsonl" ;;
    pi)
      encoded="${dir#/}"
      file="$AGENT_READ_PI_DIR/--${encoded//\//-}--/$name.jsonl" ;;
  esac
  mkdir -p "${file%/*}"
  printf 'transcript need not be parsed\n' > "$file"
  touch -t "$stamp" "$file"
}

@test "default picker sorts by newest Claude or pi transcript, not session creation" {
  mkdir -p "$TMP/old" "$TMP/recent"
  session_file claude "$TMP/old" newer-name 202201010000
  session_file pi "$TMP/recent" old-name 202001010000
  session_file pi "$TMP/recent" oldest-name 202301010000
  wt_worktree_porcelain() {
    printf 'worktree %s\nbranch refs/heads/old\n\nworktree %s\nbranch refs/heads/recent\n' "$TMP/old" "$TMP/recent"
  }
  wt_select() { head -1; }
  run --separate-stderr wt_main
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP/recent" ]
}

@test "session directory encodings handle spaces punctuation and underscores" {
  local dir="$TMP/my project_name.v2"
  session_file claude "$dir" session 202201010000
  run wt_sort_recent <<< "$(printf '/x/none\tnone\n%s\tchosen\n' "$dir")"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$dir"$'\t'"chosen" ]
  session_file pi "$dir" session 202301010000
  run wt_sort_recent <<< "$(printf '/x/none\tnone\n%s\tchosen\n' "$dir")"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$dir"$'\t'"chosen" ]
}

codex_file() {
  local name="$1" cwd="$2" source="$3" stamp="$4"
  mkdir -p "$AGENT_READ_CODEX_DIR/2026/10/22"
  local file="$AGENT_READ_CODEX_DIR/2026/10/22/$name.jsonl"
  printf '{"type":"session_meta","payload":{"cwd":"%s","source":%s}}\nnot json transcript\n' "$cwd" "$source" > "$file"
  touch -t "$stamp" "$file"
}

@test "Codex reads cwd from header and ignores malformed and subagent sessions" {
  session_file claude /x/claude session 202201010000
  codex_file valid /x/codex '"cli"' 202301010000
  codex_file child /x/subagent '{"subagent":{"thread_spawn":{}}}' 202401010000
  printf 'bad json\n' > "$AGENT_READ_CODEX_DIR/2026/10/22/broken.jsonl"
  run wt_sort_recent <<< $'/x/subagent\tsubagent\n/x/claude\tclaude\n/x/codex\tcodex'
  [ "$status" -eq 0 ]
  [ "$output" = $'/x/codex\tcodex\n/x/claude\tclaude\n/x/subagent\tsubagent' ]
}

@test "equal timestamps and missing sessions preserve input order" {
  session_file claude /x/z session 202201010000
  session_file pi /x/a session 202201010000
  run wt_sort_recent <<< $'/x/missing-z\tmissing-z\n/x/z\tz\n/x/missing-a\tmissing-a\n/x/a\ta'
  [ "$status" -eq 0 ]
  [ "$output" = $'/x/z\tz\n/x/a\ta\n/x/missing-z\tmissing-z\n/x/missing-a\tmissing-a' ]
}

@test "executed wt resolves its helper through an installed symlink" {
  git init -q "$TMP/repo"
  git -C "$TMP/repo" -c user.name=Test -c user.email=test@example.com commit -qm initial --allow-empty
  git -C "$TMP/repo" worktree add -qb recent "$TMP/recent"
  session_file pi "$TMP/recent" session 202301010000
  mkdir -p "$TMP/fakebin"
  printf '#!/bin/sh\nhead -1\n' > "$TMP/fakebin/fzf"
  chmod +x "$TMP/fakebin/fzf"
  ln -s "$WT" "$TMP/fakebin/wt"
  cd "$TMP/repo"
  run --separate-stderr env PATH="$TMP/fakebin:$PATH" "$TMP/fakebin/wt"
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP/recent" ]
}

@test "fzf filters without reordering the recency-sorted input" {
  fzf() { printf '%s\n' "$@"; }
  run wt_select
  [ "$status" -eq 0 ]
  [[ "$output" == *"--no-sort"* ]]
}

# ── wt_main ──────────────────────────────────────────────────────────────────
# wt_select is the fzf seam; tests replace it so nothing interactive runs.

@test "prints the selected worktree path, and nothing else, on stdout" {
  mkdir -p "$TMP/chosen"
  wt_select() { printf '%s\t%s\n' "$TMP/chosen" "chosen [main]"; }
  wt_worktree_porcelain() { printf 'worktree %s\nHEAD abc\nbranch refs/heads/main\n' "$TMP/chosen"; }
  run --separate-stderr wt_main
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP/chosen" ]
}

@test "resolves the right worktree when two share a leaf name" {
  mkdir -p "$TMP/a/dup" "$TMP/b/dup"
  wt_worktree_porcelain() {
    printf 'worktree %s\nHEAD abc\nbranch refs/heads/one\n\nworktree %s\nHEAD abc\nbranch refs/heads/two\n' \
      "$TMP/a/dup" "$TMP/b/dup"
  }
  # Pick the SECOND line — under leaf-name matching this returned the first.
  wt_select() { sed -n 2p; }
  run --separate-stderr wt_main
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP/b/dup" ]
}

@test "cancelling the selector is a quiet success with no output" {
  wt_worktree_porcelain() { printf 'worktree /x/r\nHEAD abc\nbranch refs/heads/main\n'; }
  wt_select() { return 130; }   # fzf's ESC / Ctrl-C status
  run --separate-stderr wt_main
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an empty selection is a quiet success with no output" {
  wt_worktree_porcelain() { printf 'worktree /x/r\nHEAD abc\nbranch refs/heads/main\n'; }
  wt_select() { printf ''; }
  run --separate-stderr wt_main
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a selected path that no longer exists fails loudly" {
  wt_worktree_porcelain() { printf 'worktree /x/gone\nHEAD abc\nbranch refs/heads/main\n'; }
  wt_select() { printf '%s\t%s\n' "/x/gone" "gone [main]"; }
  run --separate-stderr wt_main
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"/x/gone"* ]]
}

@test "outside a git repo it fails and prints nothing on stdout" {
  cd "$TMP"
  run --separate-stderr wt_main
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}
