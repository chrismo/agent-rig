#!/usr/bin/env bash
#
# lemma-brief - report what lemmalog is holding for this repo
#
# Fires on SessionStart.
#
# This is the READ half of the loop that hooks/lemma-commit.sh writes into.
# Without it, facts go in and are never seen again — which is how a store dies,
# and it dies quietly, because nothing about an unread store looks broken.
#
# It cannot query the engine. The lemmalog MCP tools are reachable only from
# Claude, and this is a script. But the snapshot is plain TSV (FACT rows with
# `s:`/`i:` typed args), so it can be read directly — safe precisely because it
# is read-only, since the MCP server rewrites that file after every mutating
# call and would clobber anything written here.
#
# It stays silent unless there is something to act on. A SessionStart hook that
# speaks every time is a hook that gets disabled, and then the whole loop is
# dead. See hooks/internals-drift.sh, which follows the same rule.
#
# Deliberately NOT `set -e`: a hook that fails must never take session startup
# down with it. Every unresolvable case exits 0 in silence.

set -uo pipefail

QUEUE="${AGENT_RIG_LEMMA_QUEUE:-$HOME/.claude/lemmalog/pending.tsv}"
MARKER="${AGENT_RIG_LEMMA_MARKER:-$HOME/.claude/lemmalog/enabled}"

# One global store, keyed by repo — see skills/lemma-drain/SKILL.md. Must match
# the default in bin/lemma-install, which is what tells the MCP server where to
# write; a disagreement fails silently, with the store filling up correctly
# while this brief reports it empty forever. bin/lemma-install.bats pins them.
SNAPSHOT="${AGENT_RIG_LEMMA_SNAPSHOT:-$HOME/.claude/lemmalog/store.snapshot}"

# The loop ships OFF; opting in is `touch ~/.claude/lemmalog/enabled`. See the
# long note in hooks/lemma-commit.sh for why this is a gate and not an early
# exit in the body — in short, a disabled hook whose suite still "passes" is
# worse than no suite.
#
# It matters more here than there, because this is the half that SPEAKS. On a
# machine that never opted in, a SessionStart nag about a queue nobody is
# draining is exactly how a hook gets disabled for good.
lemma_enabled() {
  case "${AGENT_RIG_LEMMA_ENABLED:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  [[ -e "$MARKER" ]]
}

# Which repo is this session in? SessionStart delivers a JSON payload on stdin
# carrying `cwd`, but reading it is best-effort: if stdin is closed or the
# payload is not what we expect, the session's working directory is a perfectly
# good answer. AGENT_RIG_LEMMA_CWD is the test seam.
resolve_repo() {
  local cwd="${AGENT_RIG_LEMMA_CWD:-}"

  if [[ -z "$cwd" && ! -t 0 ]]; then
    local input
    input=$(cat 2>/dev/null) || input=""
    if [[ -n "$input" ]]; then
      cwd=$(echo "$input" | super -f line -c 'this.cwd' - 2>/dev/null) || cwd=""
    fi
  fi
  [[ -n "$cwd" ]] || cwd="$PWD"
  [[ -d "$cwd" ]] || return 1

  # Attribute to the repository root, matching how lemma-commit.sh names it, or
  # the two halves would disagree about what "this repo" means.
  local root
  root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || return 1
  [[ -n "$root" ]] || return 1
  basename -- "$root"
}

# How many facts does the store already hold for this repo? A count is all a
# hook should offer: the point is to prove the store is not empty, not to dump
# it. Reading it properly is Claude's job, through the MCP tools.
#
# Attribution follows `in_repo`, not a literal name match. /lemma-backfill puts
# the TOPIC on the left of a fact (`heredocs --because--> cascading-tool-denials`)
# and ties it to a repo with a separate edge, so matching the repo name counted
# 5 of 45 facts on a real run — which reads as "barely used" when the store is
# fine. Must stay in step with bin/lemma-info, which reports the same number.
#
# Only OPEN facts count. A superseded fact is interval-closed rather than
# deleted, and "on record" should mean what still holds — otherwise every
# reversal inflates the count it was meant to correct.
count_facts() {
  local repo="$1"
  [[ -r "$SNAPSHOT" ]] || { echo 0; return 0; }

  awk -F'\t' -v repo="$repo" '
    function argn(f, i,   a) { split(f, a, " "); return a[i] }
    function sym(v) { sub(/^s:/, "", v); return v }
    $1 == "FACT" && $2 == "edge" {
      vt = argn($5, 5)
      if (vt != "" && vt != "i:9223372036854775807") next   # superseded
      subj = sym(argn($5, 1)); rel = sym(argn($5, 2)); obj = sym(argn($5, 3))
      rows[++n] = subj SUBSEP obj
      if (rel == "in_repo") repo_of[subj] = obj
    }
    END {
      for (i = 1; i <= n; i++) {
        split(rows[i], p, SUBSEP)
        if (repo_of[p[1]] == repo || p[1] == repo || p[2] == repo) c++
      }
      print c + 0
    }
  ' "$SNAPSHOT" 2>/dev/null || echo 0
}

main() {
  lemma_enabled || exit 0

  local repo
  repo=$(resolve_repo) || exit 0
  [[ -n "$repo" ]] || exit 0

  [[ -r "$QUEUE" ]] || exit 0

  local pending
  pending=$(awk -F'\t' -v repo="$repo" '$1 == repo { n++ } END { print n + 0 }' \
    "$QUEUE" 2>/dev/null) || exit 0
  [[ "$pending" -gt 0 ]] 2>/dev/null || exit 0

  local noun="commits"
  [[ "$pending" -eq 1 ]] && noun="commit"

  local facts
  facts=$(count_facts "$repo")

  # The facts line is omitted when the store knows nothing about this repo —
  # "0 facts on record" is discouraging noise on the day you start.
  local facts_line=""
  if [[ "$facts" -gt 0 ]] 2>/dev/null; then
    facts_line="
  Facts on record for $repo: $facts."
  fi

  cat <<EOF
⚠ lemmalog: $pending $noun pending assertion in $repo.$facts_line
  /lemma-drain to review them — most commits establish nothing worth keeping.
EOF
  exit 0
}

main "$@"
