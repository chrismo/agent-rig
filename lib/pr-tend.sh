# Shared by pr-act and pr-watch. Source it; needs bash 5 and jq.
#
# See docs/pr-workflow/design.md, "Harness adapter".

# with_timeout <seconds> <cmd...>: kills the command's whole process group
# when time runs out (its children would otherwise hold our output pipe open).
with_timeout() {
  perl -e '
    my $t = shift;
    my $pid = fork // die "fork: $!\n";
    if (!$pid) { setpgrp(0, 0); exec @ARGV or die "exec $ARGV[0]: $!\n" }
    $SIG{ALRM} = sub { kill "TERM", -$pid; print STDERR "timed out after ${t}s\n"; exit 124 };
    alarm $t;
    waitpid $pid, 0;
    exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
  ' "$@"
}

# pr_setting <default> [--no-branch] <key> [<branch>]: pr-config's value, or
# <default> when the key is unset (exit 3). Any other pr-config failure returns 1.
pr_setting() {
  local default=$1 out rc=0
  shift
  out=$("$PR_CONFIG" setting "$@") || rc=$?
  case $rc in
    0) printf '%s\n' "$out" ;;
    3) printf '%s' "$default" ;;
    *) return 1 ;;
  esac
}

# Claude may read and edit; the pipeline commits, pushes and talks to GitHub.
HARNESS_CLAUDE_ALLOW="Read,Edit,Write,Grep,Glob,Bash(git diff *),Bash(git log *),Bash(git show *),Bash(git status *)"
HARNESS_CLAUDE_DENY="Bash(git commit *),Bash(git push *),Bash(gh *)"
# pi has no per-command bash rules, so no bash at all.
HARNESS_PI_TOOLS="read,edit,write"

# harness_run <harness> <session-id> <new|resume> <timeout> <prompt> <json-schema> [<settings-json>]
# Runs one headless agent step in $PWD; prints the step's JSON result.
# settings-json is `pr-config get`'s output: model, effort, provider and args
# (git config pr-tend.<harness>.args when the config has none).
harness_run() {
  local h=$1 sid=$2 mode=$3 timeout=$4 prompt=$5 schema=$6 settings=${7:-'{}'} out
  local model effort provider args
  local -a typed=() extra
  jq -e 'type == "object"' <<<"$settings" >/dev/null || return 1
  model=$(jq -r '.model // empty' <<<"$settings")
  effort=$(jq -r '.effort // empty' <<<"$settings")
  provider=$(jq -r '.provider // empty' <<<"$settings")
  args=$(jq -r '.args // empty' <<<"$settings")
  [[ -n $args ]] || args=$(git config --get "pr-tend.$h.args" || true)
  read -ra extra <<<"$args"
  case $h in
    claude)
      if [[ -n $model ]]; then typed+=(--model "$model"); fi
      if [[ -n $effort ]]; then typed+=(--effort "$effort"); fi ;;
    pi)
      if [[ -n $provider ]]; then typed+=(--provider "$provider"); fi
      if [[ -n $model ]]; then typed+=(--model "$model"); fi
      if [[ -n $effort ]]; then typed+=(--thinking "$effort"); fi ;;
  esac
  case $h in
    claude)
      local -a sess=(--session-id "$sid")
      [[ $mode == resume ]] && sess=(--resume "$sid")
      out=$(with_timeout "$timeout" claude -p "${sess[@]}" --output-format json --json-schema "$schema" \
              --permission-mode acceptEdits --allowedTools "$HARNESS_CLAUDE_ALLOW" \
              --disallowedTools "$HARNESS_CLAUDE_DENY" "${typed[@]}" "${extra[@]}" "$prompt" </dev/null) || return
      jq -ce 'select(.is_error | not) | .structured_output // (.result | fromjson?) // empty | objects' <<<"$out" 2>/dev/null
      ;;
    pi)
      # pi has no schema flag: the prompt asks for a final ```json block.
      out=$(with_timeout "$timeout" pi -p --session-id "$sid" --tools "$HARNESS_PI_TOOLS" "${typed[@]}" "${extra[@]}" \
              "$prompt"$'\n\nEnd your reply with the result as one ```json fenced block matching this JSON Schema:\n'"$schema" \
              </dev/null) || return
      awk '/^```json/ { buf = ""; on = 1; next } /^```/ { if (on) last = buf; on = 0; next }
           on { buf = buf $0 "\n" } END { printf "%s", last }' <<<"$out" | jq -ce 'objects' 2>/dev/null
      ;;
    *) echo "unknown harness: $h (claude or pi)" >&2; return 1 ;;
  esac
}
