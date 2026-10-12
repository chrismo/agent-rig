#!/usr/bin/env bash
# Spike: claude -p session forking. Prints session_id + result per step.
set -u
cd "$1"
run() { local label=$1; shift
  out=$(env -u ANTHROPIC_API_KEY claude -p --model haiku --max-budget-usd 0.20 --output-format json "$@" </dev/null 2>/dev/null)
  printf '%-28s sid=%s | %s\n' "$label" "$(jq -r .session_id <<<"$out" 2>/dev/null)" "$(jq -r .result <<<"$out" 2>/dev/null | tr '\n' ' ' | cut -c1-120)"
  sid=$(jq -r .session_id <<<"$out" 2>/dev/null)
  if [[ $sid == null || -z $sid ]]; then echo "RAW: $out" | head -5; fi
}
U=$(uuidgen | tr A-Z a-z); F=$(uuidgen | tr A-Z a-z)
echo "U=$U"; echo "F(chosen fork id)=$F"
run "1 new --session-id U"  --session-id "$U" "Remember the word ALPHA. Reply only OK."
run "2 plain resume U"      --resume "$U" "Also remember the word BRAVO. Reply only OK."
run "3 fork U (auto id)"    --resume "$U" --fork-session "Remember the word CHARLIE. List every word I asked you to remember, comma-separated, nothing else."
run "4 fork U, --session-id F" --resume "$U" --fork-session --session-id "$F" "Remember the word DELTA. List every word I asked you to remember, comma-separated, nothing else."
run "5 resume parent U"     --resume "$U" "List every word I asked you to remember, comma-separated, nothing else."
run "6 resume fork F"       --resume "$F" "List every word I asked you to remember, comma-separated, nothing else."
