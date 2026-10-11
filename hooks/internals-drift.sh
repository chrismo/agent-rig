#!/usr/bin/env bash
#
# internals-drift - warn when Claude Code's version moves past the one
#                   agent-rig's internals were last verified against
#
# Fires on SessionStart.
#
# agent-rig depends on several things Claude Code does not expose as an API:
# the session registry (~/.claude/sessions/<pid>.json), the transcript .jsonl
# schema, the projects-directory path encoding, and the peer messaging protocol.
# None of that is contract; all of it can change in a point release.
#
# Claude Code upgrades itself and never runs install.sh, so a version bump is
# the only reliable moment to say "re-check the assumptions". This hook is that
# moment. It does not verify anything itself — it points at the suite that does:
#
#   bats bin/claude-contract.bats
#
# See docs/internals-contract.md for what is being asserted and why.
#
# Deliberately NOT `set -e`: a hook that fails must never take session startup
# down with it. Every unresolvable case exits 0 in silence.

set -uo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFIED_FILE="${AGENT_RIG_VERIFIED_FILE:-$REPO_DIR/docs/verified-against}"
RESULTS_FILE="${AGENT_RIG_CONTRACT_RESULTS:-$REPO_DIR/docs/contract-results.tsv}"

# Summarise what the contract suite actually established about a given build.
#
# The stamp file is one hand-written version string: identical whether every
# assumption was confirmed against that build or every one of them skipped for
# want of a live session. bin/contract-record leaves a row per test per run, so
# that difference is finally representable — and the difference between "we
# checked and it holds" and "we never checked on this build" is exactly what
# the contract doc means by "green suite plus a stale stamp means UNVERIFIED".
#
# Prints nothing at all if the file is missing or says nothing about this
# build. Every parse failure is a silent no-op: this runs at SessionStart.
summarise_results() {
  local running="$1"
  [[ -r "$RESULTS_FILE" ]] || return 0

  awk -F'\t' -v running="$running" '
    # Ignore anything that is not a well-formed row. A hand-edited or
    # truncated file must degrade to silence, never to a wrong count.
    NF >= 4 && $1 ~ /^[A-Z]+[0-9]+$/ {
      seen[$1] = 1
      if ($3 == running) {
        ts = $4 + 0
        # Last write wins: an assumption fixed and re-run on the same build
        # is confirmed, not still failing.
        if (!($1 in best) || ts >= best[$1]) { best[$1] = ts; state[$1] = $2 }
      }
    }
    END {
      n = 0
      for (id in seen) {
        if (!(id in state))          { never++ }
        else if (state[id] == "pass") { conf++ }
        else if (state[id] == "skip") { skipped++ }
        else                          { failing[++n] = id }
      }
      if (conf + skipped + never + n == 0) exit 0

      printf "  Suite results for %s: %d confirmed", running, conf + 0
      if (skipped) printf ", %d skipped", skipped
      if (never)   printf ", %d never run on this build", never
      printf ".\n"

      if (n) {
        # Insertion sort: the list is a handful of IDs, and a stable order
        # keeps the message identical between runs.
        for (i = 2; i <= n; i++) {
          v = failing[i]
          for (j = i - 1; j >= 1 && failing[j] > v; j--) failing[j + 1] = failing[j]
          failing[j + 1] = v
        }
        out = failing[1]
        for (i = 2; i <= n; i++) out = out ", " failing[i]
        printf "  %d failing: %s\n", n, out
      }
    }
  ' "$RESULTS_FILE" 2>/dev/null || return 0
}

# Resolve the build this session is RUNNING.
#
# Precedence matches bin/claude-src, with one addition. CLAUDE_SRC_BINARY is the
# explicit override (tests, and anyone pointing at a specific build).
# CLAUDE_CODE_EXECPATH is next and matters most in practice: Claude Code stages
# an upgrade by repointing the launcher symlink while existing sessions keep
# running the old build, so the symlink can already name a version this session
# is not executing. Falling back to the symlink is a last resort.
resolve_running_binary() {
  if [[ -n "${CLAUDE_SRC_BINARY:-}" && -f "${CLAUDE_SRC_BINARY}" ]]; then
    printf '%s\n' "$CLAUDE_SRC_BINARY"
    return 0
  fi

  if [[ -n "${CLAUDE_CODE_EXECPATH:-}" && -f "${CLAUDE_CODE_EXECPATH}" ]]; then
    printf '%s\n' "$CLAUDE_CODE_EXECPATH"
    return 0
  fi

  local launcher
  launcher=$(command -v claude 2>/dev/null) || return 1
  # The launcher is a symlink into versions/<version>; resolve it.
  local target
  target=$(readlink "$launcher" 2>/dev/null) || target="$launcher"
  [[ -f "$target" ]] || return 1
  printf '%s\n' "$target"
}

main() {
  [[ -r "$VERIFIED_FILE" ]] || exit 0

  local verified
  verified=$(tr -d '[:space:]' < "$VERIFIED_FILE" 2>/dev/null) || exit 0
  [[ -n "$verified" ]] || exit 0

  local binary
  binary=$(resolve_running_binary) || exit 0

  # The binary's filename IS its version. Anything else (a "latest" symlink, a
  # dev build) is not something we can compare, so stay quiet rather than nag.
  local running
  running=$(basename -- "$binary")
  [[ "$running" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || exit 0

  [[ "$running" == "$verified" ]] && exit 0

  local summary
  summary=$(summarise_results "$running")

  cat <<EOF
⚠ agent-rig: internals verified against Claude Code $verified, running $running.
${summary:+
$summary}

  agent-rig reads Claude Code internals that are not a supported API (session
  registry, transcript schema, peer messaging). A version change is the cue to
  re-check them:

      bats $REPO_DIR/bin/claude-contract.bats

  What is being asserted, and what to do when one fails:
      $REPO_DIR/docs/internals-contract.md
EOF
  exit 0
}

main "$@"
