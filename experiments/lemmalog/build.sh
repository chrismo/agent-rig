#!/usr/bin/env bash
#
# build.sh - emit a lemmalog script for the internals contract
#
# Structure comes from contract.tsv (hand-maintained, mirrors the doc);
# observations come from docs/contract-results.tsv, which bin/contract-record
# writes as bin/claude-contract.bats runs. Nothing here is transcribed by hand
# from a test result — that was the whole flaw in the first version of this
# model, which inherited the doc's staleness and gave it a proof tree.
#
# Usage:
#   ./build.sh | lemmalog                     # one-shot, in memory
#   ./build.sh                                # inspect the facts
#
# Then, in the engine:
#   now <yyyymmdd> ; run ; ? unverified(A) ; ? urgent(A) ; why urgent("C1")
#
# Claude reaches the same store through the lemmalog MCP tools; this path
# exists so a shell can too.

set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd -- "$here/../.." && pwd)
results="${AGENT_RIG_CONTRACT_RESULTS:-$repo/docs/contract-results.tsv}"

# Rules. The REPL reads one line at a time, so a clause wrapped across lines
# has to be folded back into one before the `rule ` prefix goes on — otherwise
# each half is submitted as its own clause and is silently useless. (Silently:
# the halves parse, install, and simply never fire. Found the hard way.)
awk '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ { if (buf == "") { print; next } }
  {
    line = $0
    sub(/^[[:space:]]+/, "", line)
    buf = (buf == "") ? line : buf " " line
    if (buf ~ /\.[[:space:]]*$/) { print "rule " buf; buf = "" }
  }
' "$here/rules.lem"

# Structure: group membership and the consumer edges.
awk -F'\t' '/^[A-Z]/ {
  printf "+ edge(\"%s\",\"group\",\"%s\",20260807,MAX,20260807).\n", $1, $2
  n = split($3, c, ",")
  for (i = 1; i <= n; i++)
    printf "+ edge(\"%s\",\"relies_on\",\"%s\",20260807,MAX,20260807).\n", c[i], $1
}' "$here/contract.tsv"

# Observations: one edge per recorded result, valid from the moment the test
# ran. A pass, a skip and a failure are three different relations, because
# collapsing them is exactly what the old single-version stamp did.
if [[ -r "$results" ]]; then
  awk -F'\t' 'NF >= 4 && $1 ~ /^[A-Z]+[0-9]+$/ {
    rel = ($2 == "pass") ? "confirmed_on" : ($2 == "skip") ? "skipped_on" : "failed_on"
    printf "+ edge(\"%s\",\"%s\",\"%s\",%s,MAX,%s).\n", $1, rel, $3, $4, $4
  }' "$results"
fi

# The build this session is running, resolved the same way the suite resolves
# it. `now` must be at or past these timestamps for `current` to see them.
version=$(basename -- "$("$repo/bin/claude-src" --which 2>/dev/null)" 2>/dev/null || echo unknown)
printf '+ edge("claude_code","running","%s",0,MAX,0).\n' "$version"
