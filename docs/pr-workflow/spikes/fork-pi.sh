#!/usr/bin/env bash
# Spike: pi -p session forking. Prints session id + final text per step.
cd "$1"; ERR="$1/../err.log"
run() { local label=$1; shift
  out=$(env -u ANTHROPIC_API_KEY pi -p --mode json --model anthropic/claude-haiku-4-5 "$@" </dev/null 2>"$ERR")
  sid=$(jq -r 'select(.type=="session") | .id' <<<"$out" 2>/dev/null | head -1)
  txt=$(jq -r 'select(.type=="agent_end") | .messages[-1].content[]? | select(.type=="text") | .text' <<<"$out" 2>/dev/null | tr '\n' ' ' | cut -c1-100)
  printf '%-30s sid=%s | %s\n' "$label" "$sid" "$txt"
  [ -z "$sid" ] && echo "RAW: $(head -c 400 <<<"$out") ERR: $(tail -c 300 "$ERR")"
}
U=$(uuidgen | tr A-Z a-z); F=$(uuidgen | tr A-Z a-z)
echo "U=$U"; echo "F=$F"
run "1 new --session-id U"        --session-id "$U" "Remember the word ALPHA. Reply only OK."
run "2 plain --session U"         --session "$U" "Also remember the word BRAVO. Reply only OK."
run "3 --fork U (auto id)"        --fork "$U" "Remember the word CHARLIE. List every word I asked you to remember, comma-separated, nothing else."
run "4 --fork U --session-id F"   --fork "$U" --session-id "$F" "Remember the word DELTA. List every word I asked you to remember, comma-separated, nothing else."
run "5 parent --session U"        --session "$U" "List every word I asked you to remember, comma-separated, nothing else."
run "6 --session F"               --session "$F" "List every word I asked you to remember, comma-separated, nothing else."
