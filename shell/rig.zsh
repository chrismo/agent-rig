# agent-rig shell entrypoint — source this from ~/.zshrc:
#
#     source ~/modev/agent-rig/shell/rig.zsh
#
# Everything here exists for one reason: a subprocess cannot cd its caller's
# shell. The real work lives in bin/wt-new and bin/wt, which are ordinary
# tested executables that PRINT a worktree path; these functions are the thin
# halves that have to be sourced in order to cd to it.
#
# Keep them thin. Logic worth testing belongs in bin/, where bats can reach it.

# zsh expands aliases at PARSE time, so if an alias named `wt` is live when
# this file is read, `wt() {` below parses as `<alias body>() {` — a syntax
# error, not a redefinition. That is the normal path into this file, not an
# edge case: anyone migrating off the old `alias wt="source .../worktrees.sh"`
# re-sources .zshrc from a shell that still has the alias loaded, and gets
# "defining function based on alias `wt'" plus a parse error.
#
# Dropping the aliases first fixes it, because zsh parses a sourced file
# command by command — this has already run by the time the definitions below
# are parsed. Errors are suppressed since normally there is nothing to remove.
unalias new_wt wt 2>/dev/null || true

# new_wt <branch> — create a worktree beside this one and cd into it.
#
# The exit status is passed through, so a wt.setup hook that failed still
# reports failure. The cd happens anyway: wt-new deliberately keeps a worktree
# whose setup hook failed, and landing in it is the point.
new_wt() {
  local dst rc=0
  dst=$(command wt-new "$@") || rc=$?
  [[ -n $dst && -d $dst ]] && cd "$dst"
  return $rc
}

# wt — fuzzy-select a worktree of this repo and cd into it.
#
# Cancelling the picker exits 0 with no path, which lands here as "stay put".
wt() {
  local dst rc=0
  dst=$(command wt) || rc=$?
  (( rc != 0 )) && return $rc
  [[ -n $dst ]] && cd "$dst"
  return 0
}
