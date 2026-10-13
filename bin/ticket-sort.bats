#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for bin/ticket-sort (interactive quicksort over Linear tickets).
#
# The interesting parts are pure: the quicksort itself (with an injected
# comparator) and the ticket rendering. The only genuinely interactive bit
# is the prompt, which reads from an auto-allocated FD so tests can feed it
# a file instead of a tty.

TS="$BATS_TEST_DIRNAME/ticket-sort"

setup() {
  # Point the comparison cache at this test's tmpdir before sourcing, so no test
  # can read or write the real one beside the script.
  export TS_COMPARISONS_FILE="${BATS_TEST_TMPDIR:-/dev/null}/comparisons.json"
  source "$TS"
}

# ── interpreter ───────────────────────────────────────────────────────────────
# The script needs bash 4.1+ (associative arrays, {fd} allocation, mapfile) but
# macOS still ships 3.2 as /bin/bash, so it re-execs itself under a newer bash.
# Invoking it with an old interpreter must work, not die on `declare -gA`.

@test "runs when invoked by a bash too old for its own syntax" {
  run /bin/bash "$TS" --help
  [ "$status" -eq 0 ]
  [[ "$output" != *'invalid option'* ]]
  [[ "$output" == *'prune    forget comparisons for input tickets with finished statuses.'* ]]
}

# ── quicksort ─────────────────────────────────────────────────────────────────
# ts_sort operates in place on TS_ARR, delegating every comparison to the
# function named in TS_COMPARE. Tests inject a numeric comparator so the
# sort's correctness is checked without a human in the loop.

numeric_before() {
  # "a sorts before b" == a is numerically smaller
  (( $1 < $2 ))
}

sort_nums() {
  TS_COMPARE=numeric_before
  TS_COMPARISONS=0
  TS_ARR=("$@")
  ts_sort 0 $(( ${#TS_ARR[@]} - 1 ))
  echo "${TS_ARR[*]}"
}

@test "ts_sort sorts a shuffled list" {
  run sort_nums 5 3 9 1 7
  [ "$status" -eq 0 ]
  [ "$output" = "1 3 5 7 9" ]
}

@test "ts_sort handles an already-sorted list" {
  run sort_nums 1 2 3 4 5
  [ "$output" = "1 2 3 4 5" ]
}

@test "ts_sort handles a reverse-sorted list" {
  run sort_nums 5 4 3 2 1
  [ "$output" = "1 2 3 4 5" ]
}

@test "ts_sort handles duplicates" {
  run sort_nums 3 1 3 1 2
  [ "$output" = "1 1 2 3 3" ]
}

@test "ts_sort handles a single element" {
  run sort_nums 42
  [ "$output" = "42" ]
}

@test "ts_sort handles an empty list" {
  TS_COMPARE=numeric_before
  TS_ARR=()
  run ts_sort 0 -1
  [ "$status" -eq 0 ]
}

@test "ts_sort counts each comparison" {
  TS_COMPARE=numeric_before
  TS_COMPARISONS=0
  TS_ARR=(5 3 9 1 7)
  ts_sort 0 4
  # n log n-ish; the exact count depends on pivot choice, but it must be
  # non-zero and never exceed the n(n-1)/2 worst case.
  [ "$TS_COMPARISONS" -gt 0 ]
  [ "$TS_COMPARISONS" -le 10 ]
}

@test "ts_sort never compares the same pair twice" {
  TS_COMPARE=recording_before
  TS_COMPARISONS=0
  TS_SEEN=()
  TS_DUPES=0
  TS_ARR=(8 3 5 1 9 2 7 4 6)
  ts_sort 0 8
  [ "$TS_DUPES" -eq 0 ]
  [ "${TS_ARR[*]}" = "1 2 3 4 5 6 7 8 9" ]
}

recording_before() {
  local key
  if (( $1 < $2 )); then key="$1:$2"; else key="$2:$1"; fi
  if [[ " ${TS_SEEN[*]} " == *" $key "* ]]; then
    TS_DUPES=$(( TS_DUPES + 1 ))
  fi
  TS_SEEN+=("$key")
  (( $1 < $2 ))
}

# ── quickselect ───────────────────────────────────────────────────────────────
# ts_select only drives the partition far enough to fill positions 0..kidx
# with the top k; the tail is left in whatever order partitioning left it.

select_nums() {
  local kidx="$1"; shift
  TS_COMPARE=numeric_before
  TS_COMPARISONS=0
  TS_ARR=("$@")
  ts_select 0 $(( ${#TS_ARR[@]} - 1 )) "$kidx"
  ts_sort 0 "$kidx"
  echo "${TS_ARR[*]}"
}

@test "ts_select puts the top k in front, in order" {
  run select_nums 2 8 3 5 1 9 2 7 4 6
  [ "$status" -eq 0 ]
  [[ "$output" == "1 2 3 "* ]]
}

@test "ts_select leaves the tail as the exact complement" {
  # Inlined rather than via select_nums, whose echo would need discarding -
  # and which cannot run in a subshell without losing TS_ARR.
  TS_COMPARE=numeric_before
  TS_ARR=(8 3 5 1 9 2 7 4 6)
  ts_select 0 8 1
  ts_sort 0 1

  # First two are the top two; the remaining seven must be the other seven
  # values, in any order - no duplicates, nothing dropped.
  local tail_sorted
  tail_sorted=$(printf '%s\n' "${TS_ARR[@]:2}" | sort -n | tr '\n' ' ')
  [ "$tail_sorted" = "3 4 5 6 7 8 9 " ]
}

@test "ts_select handles k of 1" {
  run select_nums 0 8 3 5 1 9
  [[ "$output" == "1 "* ]]
}

@test "ts_select handles k equal to the list length" {
  run select_nums 4 5 3 9 1 7
  [ "$output" = "1 3 5 7 9" ]
}

@test "ts_select handles a single element" {
  run select_nums 0 42
  [ "$output" = "42" ]
}

@test "ts_select asks fewer questions than a full sort" {
  # Averaged over several pivot draws so a single unlucky run can't flake it.
  local sel=0 full=0 i
  for (( i = 0; i < 12; i++ )); do
    TS_COMPARE=numeric_before TS_COMPARISONS=0
    TS_ARR=(8 3 5 1 9 2 7 4 6 12 11 10)
    ts_select 0 11 1; ts_sort 0 1
    sel=$(( sel + TS_COMPARISONS ))

    TS_COMPARE=numeric_before TS_COMPARISONS=0
    TS_ARR=(8 3 5 1 9 2 7 4 6 12 11 10)
    ts_sort 0 11
    full=$(( full + TS_COMPARISONS ))
  done
  [ "$sel" -lt "$full" ]
}

# ── comparison memo ───────────────────────────────────────────────────────────
# Selection and the final sort can revisit a pair. A human must never be
# asked the same question twice.

@test "ts_ask remembers an answer instead of re-asking" {
  TS_TICKETS=('{"id":"A","title":"alpha"}' '{"id":"B","title":"bravo"}')
  TS_MEMO=()
  TS_ASKED=0
  printf '2\n' > "$BATS_TEST_TMPDIR/one-answer"
  # Auto-allocated FD, not a hardcoded 3 - bats owns 3 for its own reporting.
  exec {TS_FD}< "$BATS_TEST_TMPDIR/one-answer"

  # Called directly, not through `run` - `run` uses a subshell, and the memo
  # would not survive it. The prompt UI is captured rather than discarded so
  # it can be asserted on below.
  local ui="$BATS_TEST_TMPDIR/ui"
  local r1 r2 r3
  ts_ask 0 1 2> "$ui" && r1=0 || r1=1
  [ "$r1" -eq 1 ]     # answered "2" - right ticket wins
  grep -q "Which should be worked next" "$ui"
  # The blocked-work rule sits with the question, not in the docs: it is only
  # needed at the moment you are looking at a paused ticket.
  grep -q "blocked/waiting, rank them as if you COULD work them today" "$ui"

  # Same pair again, and the reversed pair: both must come from the memo.
  # There is no second line of input, so a real prompt would abort here.
  : > "$ui"
  ts_ask 0 1 2>> "$ui" && r2=0 || r2=1
  [ "$r2" -eq 1 ]
  ts_ask 1 0 2>> "$ui" && r3=0 || r3=1
  [ "$r3" -eq 0 ]     # inverse is implied
  # Memoized answers render nothing at all.
  [ ! -s "$ui" ]
  exec {TS_FD}<&-
}

@test "ts_ask counts only the questions it actually asks" {
  TS_TICKETS=('{"id":"A","title":"alpha"}' '{"id":"B","title":"bravo"}')
  TS_MEMO=()
  TS_ASKED=0
  printf '1\n' > "$BATS_TEST_TMPDIR/one-answer"
  # Auto-allocated FD, not a hardcoded 3 - bats owns 3 for its own reporting.
  exec {TS_FD}< "$BATS_TEST_TMPDIR/one-answer"
  ts_ask 0 1 2>> "$BATS_TEST_TMPDIR/ui" || true
  ts_ask 0 1 2>> "$BATS_TEST_TMPDIR/ui" || true
  ts_ask 1 0 2>> "$BATS_TEST_TMPDIR/ui" || true
  exec {TS_FD}<&-
  [ "$TS_ASKED" -eq 1 ]
}

# ── opening tickets ───────────────────────────────────────────────────────────

@test "ts_ticket_url prefers the url the API gave us" {
  run ts_ticket_url '{"id":"DEVOPS-1","url":"https://linear.app/acme/issue/DEVOPS-1/x"}'
  [ "$status" -eq 0 ]
  [ "$output" = "https://linear.app/acme/issue/DEVOPS-1/x" ]
}

@test "ts_ticket_url builds one from the workspace when the API gave none" {
  TS_WORKSPACE=acme
  run ts_ticket_url '{"id":"DEVOPS-1"}'
  [ "$status" -eq 0 ]
  [ "$output" = "https://linear.app/acme/issue/DEVOPS-1" ]
}

@test "ts_ticket_url fails when it has neither a url nor a workspace" {
  TS_WORKSPACE=
  run ts_ticket_url '{"id":"DEVOPS-1"}'
  [ "$status" -ne 0 ]
}

@test "ts_ask opens the left ticket and still asks the question" {
  local opened="$BATS_TEST_TMPDIR/opened"
  printf '#!/bin/sh\necho "$1" >> %s\n' "$opened" > "$BATS_TEST_TMPDIR/opener"
  chmod +x "$BATS_TEST_TMPDIR/opener"
  TS_OPEN="$BATS_TEST_TMPDIR/opener"

  TS_TICKETS=('{"id":"A","title":"alpha","url":"https://x/A"}'
              '{"id":"B","title":"bravo","url":"https://x/B"}')
  TS_MEMO=()
  TS_ASKED=0
  printf 'ol\nr\n' > "$BATS_TEST_TMPDIR/answers"
  exec {TS_FD}< "$BATS_TEST_TMPDIR/answers"

  local r
  ts_ask 0 1 2>> "$BATS_TEST_TMPDIR/ui" && r=0 || r=1
  exec {TS_FD}<&-

  [ "$(cat "$opened")" = "https://x/A" ]
  [ "$r" -eq 1 ]          # the "2" after the open still decided it
  [ "$TS_ASKED" -eq 1 ]   # opening is not a second question
}

@test "ts_ask opens the right ticket" {
  local opened="$BATS_TEST_TMPDIR/opened"
  printf '#!/bin/sh\necho "$1" >> %s\n' "$opened" > "$BATS_TEST_TMPDIR/opener"
  chmod +x "$BATS_TEST_TMPDIR/opener"
  TS_OPEN="$BATS_TEST_TMPDIR/opener"

  TS_TICKETS=('{"id":"A","title":"alpha","url":"https://x/A"}'
              '{"id":"B","title":"bravo","url":"https://x/B"}')
  TS_MEMO=()
  TS_ASKED=0
  printf 'or\nl\n' > "$BATS_TEST_TMPDIR/answers"
  exec {TS_FD}< "$BATS_TEST_TMPDIR/answers"

  local r
  ts_ask 0 1 2>> "$BATS_TEST_TMPDIR/ui" && r=0 || r=1
  exec {TS_FD}<&-

  [ "$(cat "$opened")" = "https://x/B" ]
  [ "$r" -eq 0 ]
}

@test "ts_ask survives a ticket with no openable url" {
  TS_OPEN=/bin/true
  TS_WORKSPACE=
  TS_TICKETS=('{"id":"A","title":"alpha"}' '{"id":"B","title":"bravo"}')
  TS_MEMO=()
  TS_ASKED=0
  printf 'ol\nl\n' > "$BATS_TEST_TMPDIR/answers"
  exec {TS_FD}< "$BATS_TEST_TMPDIR/answers"

  local ui="$BATS_TEST_TMPDIR/ui-nourl" r
  ts_ask 0 1 2> "$ui" && r=0 || r=1
  exec {TS_FD}<&-

  [ "$r" -eq 0 ]
  grep -qi "no url" "$ui"
}

# ── standing preview ──────────────────────────────────────────────────────────
# A position is only numbered once a pivot has landed there, which is the one
# thing quicksort actually guarantees mid-run. Everything else shows a null
# rank and is listed alphabetically, so the display does not imply an order
# that has not been established - and does not churn as partitions shuffle.

preview_fixture() {
  TS_TICKETS=('{"id":"DEV-3","title":"charlie"}'
              '{"id":"DEV-1","title":"alpha"}'
              '{"id":"DEV-4","title":"delta"}'
              '{"id":"DEV-2","title":"bravo"}')
  TS_ARR=(0 1 2 3)
  TS_SETTLED=()
}

@test "ts_preview numbers nothing before any pivot lands" {
  preview_fixture
  run ts_preview 4
  [ "$status" -eq 0 ]
  [[ "$output" != *"1."* ]]
}

@test "ts_preview lists unplaced tickets alphabetically" {
  preview_fixture
  run ts_preview 4
  # Alphabetical by id, regardless of where they sit in TS_ARR.
  local ids
  ids=$(grep -o 'DEV-[0-9]' <<< "$output" | tr '\n' ' ')
  [ "$ids" = "DEV-1 DEV-2 DEV-3 DEV-4 " ]
}

@test "ts_preview numbers a settled position and holds it in place" {
  preview_fixture
  TS_SETTLED=([1]=1)     # position 1 is final, holding DEV-1
  run ts_preview 4
  # Line 1 is the header, so rank 2 lands on line 3.
  [[ "$(sed -n 3p <<< "$output")" == *"DEV-1"* ]] || false
  [[ "$(sed -n 3p <<< "$output")" == *"2."* ]]
}

@test "ts_preview fills unsettled slots alphabetically around settled ones" {
  preview_fixture
  TS_SETTLED=([1]=1)     # DEV-1 pinned at rank 2; DEV-2/3/4 fill the rest
  run ts_preview 4
  local ids
  ids=$(grep -o 'DEV-[0-9]' <<< "$output" | tr '\n' ' ')
  [ "$ids" = "DEV-2 DEV-1 DEV-3 DEV-4 " ]
}

@test "ts_preview honors the row limit" {
  preview_fixture
  run ts_preview 2
  [ "$(grep -c 'DEV-' <<< "$output")" -eq 2 ]
}

@test "ts_preview copes with a limit larger than the list" {
  preview_fixture
  run ts_preview 99
  [ "$status" -eq 0 ]
  [ "$(grep -c 'DEV-' <<< "$output")" -eq 4 ]
}

@test "ts_partition marks the pivot position as settled" {
  TS_COMPARE=numeric_before
  TS_SETTLED=()
  TS_ARR=(5 3 9 1 7)
  ts_partition 0 4
  [ -n "${TS_SETTLED[$TS_PIVOT]:-}" ]
}

@test "a settled position holds the value a full sort agrees on" {
  TS_COMPARE=numeric_before
  TS_SETTLED=()
  TS_ARR=(8 3 5 1 9 2 7 4 6)
  ts_sort 0 8
  # After a full sort every position is settled and correct.
  local i
  for (( i = 0; i < 9; i++ )); do
    [ -n "${TS_SETTLED[$i]:-}" ]
  done
  [ "${TS_ARR[*]}" = "1 2 3 4 5 6 7 8 9" ]
}

@test "no settled row is ever wrong at the moment the preview draws" {
  # The preview renders from inside ts_ask, which the sort calls mid-partition.
  # An auditing comparator runs at exactly that moment, so this reproduces
  # what a human would actually see - including the select-then-sort overlap,
  # where the head gets re-partitioned after selection already settled part
  # of it.
  TS_COMPARE=auditing_before
  local trial
  for (( trial = 0; trial < 30; trial++ )); do
    TS_ARR=( $(printf '%s\n' 8 3 5 1 9 2 7 4 6 12 11 10 | sort -R) )
    mapfile -t AUDIT_EXPECTED < <(printf '%s\n' "${TS_ARR[@]}" | sort -n)
    TS_SETTLED=()
    AUDIT_BAD=0
    ts_select 0 11 3
    ts_sort 0 3
    [ "$AUDIT_BAD" -eq 0 ]
  done
}

auditing_before() {
  local p
  for p in "${!TS_SETTLED[@]}"; do
    [[ "${AUDIT_EXPECTED[$p]}" != "${TS_ARR[$p]}" ]] && AUDIT_BAD=$(( AUDIT_BAD + 1 ))
  done
  (( $1 < $2 ))
}

@test "the prompt shows the standing list" {
  three_tickets
  run --separate-stderr run_sort $'l\nl\nl\nl\nl'
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"standing"* ]]
}

@test "show widens the standing list, not just the final report" {
  cat > "$BATS_TEST_TMPDIR/tickets" <<'EOF'
{"id":"A","title":"alpha"}
{"id":"B","title":"bravo"}
{"id":"C","title":"charlie"}
{"id":"D","title":"delta"}
{"id":"E","title":"echo"}
EOF
  # --top 2 alone would preview 2 rows; --show 5 is the point of asking.
  run --separate-stderr run_sort $'l\nl\nl\nl\nl\nl\nl\nl\nl\nl' --top 2 --show 5
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"standing top 5"* ]]
}

@test "TS_PREVIEW still overrides --show" {
  three_tickets
  export TS_PREVIEW=1
  run --separate-stderr run_sort $'l\nl\nl\nl\nl' --show 3
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"standing top 1"* ]]
}

@test "TS_PREVIEW=0 turns the standing list off" {
  three_tickets
  # Exported, not just assigned - run_sort launches a separate bash.
  export TS_PREVIEW=0
  run --separate-stderr run_sort $'l\nl\nl\nl\nl'
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"standing"* ]]
}

# ── progress ──────────────────────────────────────────────────────────────────
# The up-front "~N questions" is a projection, and t/b can invalidate it
# wholesale. Per-question progress reports settled positions instead, which
# is an observed fact and matches the numbered rows in the preview.

@test "ts_placed counts settled positions inside the window" {
  TS_SETTLED=([0]=1 [2]=1 [7]=1)
  run ts_placed 4
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "ts_placed counts nothing when nothing is settled" {
  TS_SETTLED=()
  run ts_placed 5
  [ "$output" = "0" ]
}

@test "ts_placed reaches the full window after a sort" {
  TS_COMPARE=numeric_before
  TS_SETTLED=()
  TS_ARR=(5 3 9 1 7)
  ts_sort 0 4
  run ts_placed 5
  [ "$output" = "5" ]
}

@test "the estimate counts only what the store does not already know" {
  # n log n ignores the memo entirely: 40 cached + 5 new predicted ~247
  # questions for a run that asked 29. A wildly wrong number up front is what
  # stops you running this daily.
  local cache="$BATS_TEST_TMPDIR/e.json"
  cat > "$cache" <<'EOF'
{"A|B":{"w":"A","at":"2026-07-01T00:00:00Z"},
 "A|C":{"w":"A","at":"2026-07-01T00:00:00Z"},
 "B|C":{"w":"B","at":"2026-07-01T00:00:00Z"}}
EOF
  printf '%s\n' '[{"id":"A","title":"a"},{"id":"B","title":"b"},{"id":"C","title":"c"},{"id":"D","title":"d"}]' \
    > "$BATS_TEST_TMPDIR/tickets"
  printf 'l\nl\nl\nl\nl\nl\n' > "$BATS_TEST_TMPDIR/answers"
  run --separate-stderr env TS_COMPARISONS_FILE="$cache" TS_INPUT="$BATS_TEST_TMPDIR/answers" \
    bash "$TS" full < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  # A, B, C are fully ordered already; only D is unknown. A 4-ticket n log n
  # would say ~8; the honest answer is at most 3.
  local est
  est=$(grep -oE '~[0-9]+ question' <<< "$stderr" | head -1 | tr -dc '0-9')
  [ -n "$est" ]
  [ "$est" -le 3 ]
}

@test "the estimate says how many tickets are already placed" {
  local cache="$BATS_TEST_TMPDIR/e.json"
  cat > "$cache" <<'EOF'
{"A|B":{"w":"A","at":"2026-07-01T00:00:00Z"},
 "A|C":{"w":"A","at":"2026-07-01T00:00:00Z"},
 "B|C":{"w":"B","at":"2026-07-01T00:00:00Z"}}
EOF
  printf '%s\n' '[{"id":"A","title":"a"},{"id":"B","title":"b"},{"id":"C","title":"c"},{"id":"D","title":"d"}]' \
    > "$BATS_TEST_TMPDIR/tickets"
  printf 'l\nl\nl\nl\nl\nl\n' > "$BATS_TEST_TMPDIR/answers"
  run --separate-stderr env TS_COMPARISONS_FILE="$cache" TS_INPUT="$BATS_TEST_TMPDIR/answers" \
    bash "$TS" full < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"already placed"* ]] || false
  [[ "$stderr" == *"1 new"* ]]
}

@test "a cold run still estimates from n log n" {
  # With nothing known there is nothing to subtract, so the old projection is
  # still the right one.
  printf '%s\n' '[{"id":"A","title":"a"},{"id":"B","title":"b"},{"id":"C","title":"c"},{"id":"D","title":"d"}]' \
    > "$BATS_TEST_TMPDIR/tickets"
  printf 'l\nl\nl\nl\nl\nl\n' > "$BATS_TEST_TMPDIR/answers"
  run --separate-stderr env TS_COMPARISONS_FILE=none TS_INPUT="$BATS_TEST_TMPDIR/answers" \
    bash "$TS" full < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  local est
  est=$(grep -oE '~[0-9]+ question' <<< "$stderr" | head -1 | tr -dc '0-9')
  [ "$est" -ge 3 ]
  [[ "$stderr" != *"already placed"* ]]
}

@test "the question line reports placed progress, not a stale estimate" {
  three_tickets
  run --separate-stderr run_sort $'l\nl\nl\nl\nl'
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"placed"* ]]
}

@test "placed progress counts up as the sort proceeds" {
  cat > "$BATS_TEST_TMPDIR/tickets" <<'EOF'
{"id":"A","title":"alpha"}
{"id":"B","title":"bravo"}
{"id":"C","title":"charlie"}
{"id":"D","title":"delta"}
{"id":"E","title":"echo"}
EOF
  run --separate-stderr run_sort $'l\nr\nl\nr\nl\nr\nl\nr\nl\nr'
  [ "$status" -eq 0 ]
  # The last question must report more placed than the first one did.
  local first last
  first=$(grep -o '[0-9]* of [0-9]* placed' <<< "$stderr" | head -1 | cut -d' ' -f1)
  last=$(grep -o '[0-9]* of [0-9]* placed' <<< "$stderr" | tail -1 | cut -d' ' -f1)
  [ "$last" -gt "$first" ]
}

@test "placed progress is scoped to --top" {
  cat > "$BATS_TEST_TMPDIR/tickets" <<'EOF'
{"id":"A","title":"alpha"}
{"id":"B","title":"bravo"}
{"id":"C","title":"charlie"}
{"id":"D","title":"delta"}
{"id":"E","title":"echo"}
EOF
  run --separate-stderr run_sort $'l\nr\nl\nr\nl\nr\nl\nr\nl\nr' --top 2
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"of 2 placed"* ]]
}

# ── bulk comparisons (t / b) ─────────────────────────────────────────────────────
# The right-hand ticket is the partition pivot, so it stays put for a whole
# pass. "t"/"b" settle it against every remaining ticket in that pass at once.

bulk_fixture() {
  TS_TICKETS=('{"id":"A","title":"alpha"}' '{"id":"B","title":"bravo"}'
              '{"id":"C","title":"charlie"}' '{"id":"D","title":"delta"}')
  TS_MEMO=()
  TS_ASKED=0
  TS_BULK=''
  TS_BULK_PIVOT=3       # D is the standing pivot
  TS_BULK_RESOLVED=0
}

@test "rb is b - the right ticket drops below the rest" {
  bulk_fixture
  printf 'rb\n' > "$BATS_TEST_TMPDIR/answers"
  exec {TS_FD}< "$BATS_TEST_TMPDIR/answers"
  local r1 r2
  ts_ask 0 3 2>> "$BATS_TEST_TMPDIR/ui" && r1=0 || r1=1
  ts_ask 1 3 2>> "$BATS_TEST_TMPDIR/ui" && r2=0 || r2=1
  exec {TS_FD}<&-
  [ "$r1" -eq 0 ]
  [ "$r2" -eq 0 ]
  [ "$TS_ASKED" -eq 1 ]
}

@test "rt and rb auto-answer without a partition pivot" {
  for answer in rt rb; do
    bulk_fixture
    TS_BULK_PIVOT=''
    printf '%s\n' "$answer" > "$BATS_TEST_TMPDIR/answers"
    exec {TS_FD}< "$BATS_TEST_TMPDIR/answers"
    local r1 r2
    ts_ask 0 3 2>> "$BATS_TEST_TMPDIR/ui" && r1=0 || r1=1
    ts_ask 1 3 2>> "$BATS_TEST_TMPDIR/ui" && r2=0 || r2=1
    exec {TS_FD}<&-
    [ "$r1" -eq "$r2" ]
    [ "$TS_ASKED" -eq 1 ]
    [ "$TS_BULK_RESOLVED" -eq 1 ]
  done
}

@test "rt is t - the right ticket rises above the rest" {
  bulk_fixture
  printf 'rt\n' > "$BATS_TEST_TMPDIR/answers"
  exec {TS_FD}< "$BATS_TEST_TMPDIR/answers"
  local r1 r2
  ts_ask 0 3 2>> "$BATS_TEST_TMPDIR/ui" && r1=0 || r1=1
  ts_ask 1 3 2>> "$BATS_TEST_TMPDIR/ui" && r2=0 || r2=1
  exec {TS_FD}<&-
  [ "$r1" -eq 1 ]
  [ "$r2" -eq 1 ]
  [ "$TS_ASKED" -eq 1 ]
}

@test "lt sends the LEFT ticket above the rest of the pass" {
  # The mirror image, which t/b could never express: the interesting ticket is
  # sometimes the one on the left, and saying so took a plain l plus repeating
  # yourself for every remaining comparison.
  bulk_fixture
  printf 'lt\n' > "$BATS_TEST_TMPDIR/answers"
  exec {TS_FD}< "$BATS_TEST_TMPDIR/answers"
  local r1
  ts_ask 0 3 2>> "$BATS_TEST_TMPDIR/ui" && r1=0 || r1=1
  exec {TS_FD}<&-
  [ "$r1" -eq 0 ]              # left won this comparison
  [ "$TS_ASKED" -eq 1 ]
  [ "$TS_BULK" = "lefttop" ]   # and a standing comparison is now in force
}

@test "lb sends the LEFT ticket below the rest of the pass" {
  bulk_fixture
  printf 'lb\n' > "$BATS_TEST_TMPDIR/answers"
  exec {TS_FD}< "$BATS_TEST_TMPDIR/answers"
  local r1
  ts_ask 0 3 2>> "$BATS_TEST_TMPDIR/ui" && r1=0 || r1=1
  exec {TS_FD}<&-
  [ "$r1" -eq 1 ]              # left lost
  [ "$TS_ASKED" -eq 1 ]
  [ "$TS_BULK" = "leftbottom" ]
}

@test "b sends the pivot to the bottom for the rest of the pass" {
  bulk_fixture
  printf 'b\n' > "$BATS_TEST_TMPDIR/answers"
  exec {TS_FD}< "$BATS_TEST_TMPDIR/answers"

  local r1 r2 r3
  ts_ask 0 3 2>> "$BATS_TEST_TMPDIR/ui" && r1=0 || r1=1
  # No further input: the rest must resolve from the bulk comparison alone.
  ts_ask 1 3 2>> "$BATS_TEST_TMPDIR/ui" && r2=0 || r2=1
  ts_ask 2 3 2>> "$BATS_TEST_TMPDIR/ui" && r3=0 || r3=1
  exec {TS_FD}<&-

  [ "$r1" -eq 0 ]       # every other ticket beats the pivot
  [ "$r2" -eq 0 ]
  [ "$r3" -eq 0 ]
  [ "$TS_ASKED" -eq 1 ] # one keystroke settled three comparisons
  [ "$TS_BULK_RESOLVED" -eq 2 ]
}

@test "t sends the pivot to the top for the rest of the pass" {
  bulk_fixture
  printf 't\n' > "$BATS_TEST_TMPDIR/answers"
  exec {TS_FD}< "$BATS_TEST_TMPDIR/answers"

  local r1 r2
  ts_ask 0 3 2>> "$BATS_TEST_TMPDIR/ui" && r1=0 || r1=1
  ts_ask 1 3 2>> "$BATS_TEST_TMPDIR/ui" && r2=0 || r2=1
  exec {TS_FD}<&-

  [ "$r1" -eq 1 ]       # the pivot beats every other ticket
  [ "$r2" -eq 1 ]
}

@test "a bulk comparison is memoized both ways" {
  bulk_fixture
  printf 'b\n' > "$BATS_TEST_TMPDIR/answers"
  exec {TS_FD}< "$BATS_TEST_TMPDIR/answers"
  local r fwd
  ts_ask 0 3 2>> "$BATS_TEST_TMPDIR/ui" && fwd=0 || fwd=1
  ts_ask 3 0 2>> "$BATS_TEST_TMPDIR/ui" && r=0 || r=1
  exec {TS_FD}<&-
  [ "$fwd" -ne "$r" ]
}

@test "a bulk comparison does not apply to a different pivot" {
  bulk_fixture
  printf 'b\nr\n' > "$BATS_TEST_TMPDIR/answers"
  exec {TS_FD}< "$BATS_TEST_TMPDIR/answers"

  local r1 r2
  ts_ask 0 3 2>> "$BATS_TEST_TMPDIR/ui" && r1=0 || r1=1
  # Pivot 2 is not the pivot the comparison was about, so this must be asked.
  ts_ask 0 2 2>> "$BATS_TEST_TMPDIR/ui" && r2=0 || r2=1
  exec {TS_FD}<&-

  [ "$r1" -eq 0 ]
  [ "$r2" -eq 1 ]       # answered "r" from the input, not by the comparison
  [ "$TS_ASKED" -eq 2 ]
}

@test "a bulk comparison never overrides an answer already given" {
  bulk_fixture
  # First say C beats the pivot outright, then bottom the pivot. The explicit
  # answer must stand rather than being restated by the blanket comparison.
  printf 'r\nb\n' > "$BATS_TEST_TMPDIR/answers"
  exec {TS_FD}< "$BATS_TEST_TMPDIR/answers"

  local first second
  ts_ask 2 3 2>> "$BATS_TEST_TMPDIR/ui" && first=0 || first=1
  ts_ask 0 3 2>> "$BATS_TEST_TMPDIR/ui" && second=0 || second=1
  # Re-asking the first pair must return the original answer, not the comparison.
  local recheck
  ts_ask 2 3 2>> "$BATS_TEST_TMPDIR/ui" && recheck=0 || recheck=1
  exec {TS_FD}<&-

  [ "$first" -eq 1 ]
  [ "$recheck" -eq 1 ]
}

@test "t after some l answers leaves those l tickets ranked above the pivot" {
  # Answer l a couple of times, then top the pivot. The pivot must still land
  # below the tickets already said to beat it, and above everything the
  # comparison swept up. Checked against the actual partition result, for
  # whichever element the random pivot happened to be.
  TS_TICKETS=('{"id":"A"}' '{"id":"B"}' '{"id":"C"}'
              '{"id":"D"}' '{"id":"E"}' '{"id":"F"}')
  TS_MEMO=(); TS_SETTLED=(); TS_ASKED=0
  TS_BULK=''; TS_BULK_RESOLVED=0
  TS_COMPARE=ts_ask
  TS_ARR=(0 1 2 3 4 5)

  printf 'l\nl\nt\n' > "$BATS_TEST_TMPDIR/answers"
  exec {TS_FD}< "$BATS_TEST_TMPDIR/answers"
  ts_partition 0 5 2>> "$BATS_TEST_TMPDIR/ui"
  exec {TS_FD}<&-

  local p=$TS_PIVOT pivot="${TS_ARR[$TS_PIVOT]}" i x
  for (( i = 0; i < 6; i++ )); do
    x="${TS_ARR[$i]}"
    [[ "$x" == "$pivot" ]] && continue
    if [[ "${TS_MEMO[$x:$pivot]}" == 0 ]]; then
      [ "$i" -lt "$p" ]     # said it beats the pivot, so it sits above it
    else
      [ "$i" -gt "$p" ]     # swept below by the comparison
    fi
  done

  [ "$TS_ASKED" -eq 3 ]           # two l answers plus the t keystroke
  [ "$TS_BULK_RESOLVED" -gt 0 ]   # and the comparison did settle the remainder
}

@test "ts_partition clears a stale bulk comparison" {
  TS_COMPARE=numeric_before
  TS_SETTLED=()
  TS_BULK=bottom
  TS_ARR=(5 3 9 1 7)
  ts_partition 0 4
  [ -z "$TS_BULK" ]
}

@test "end to end accepts a bulk comparison" {
  cat > "$BATS_TEST_TMPDIR/tickets" <<'EOF'
{"id":"A","title":"alpha"}
{"id":"B","title":"bravo"}
{"id":"C","title":"charlie"}
{"id":"D","title":"delta"}
{"id":"E","title":"echo"}
EOF
  run --separate-stderr run_sort $'b\nb\nb\nb\nb\nb\nb\nb'
  [ "$status" -eq 0 ]
  [ "$(grep -c . <<< "$output")" -eq 5 ]
}

# ── meh ───────────────────────────────────────────────────────────────────────

@test "ts_ask decides a meh by coin flip and sticks to it" {
  TS_TICKETS=('{"id":"A","title":"alpha"}' '{"id":"B","title":"bravo"}')
  TS_MEMO=()
  TS_ASKED=0
  TS_MEHS=0
  printf 'm\n' > "$BATS_TEST_TMPDIR/answers"
  exec {TS_FD}< "$BATS_TEST_TMPDIR/answers"

  local flip inverse
  ts_ask 0 1 2>> "$BATS_TEST_TMPDIR/ui" && flip=0 || flip=1
  # No second line of input: the reverse pair must come from the memo, and
  # must not contradict the flip.
  ts_ask 1 0 2>> "$BATS_TEST_TMPDIR/ui" && inverse=0 || inverse=1
  exec {TS_FD}<&-

  [ "$flip" -ne "$inverse" ]
  [ "$TS_MEHS" -eq 1 ]
}

@test "meh flips both ways over enough runs" {
  # Guards against a coin that always lands the same way.
  local lefts=0 i r
  for (( i = 0; i < 40; i++ )); do
    TS_TICKETS=('{"id":"A"}' '{"id":"B"}')
    TS_MEMO=(); TS_ASKED=0; TS_MEHS=0
    printf 'm\n' > "$BATS_TEST_TMPDIR/answers"
    exec {TS_FD}< "$BATS_TEST_TMPDIR/answers"
    ts_ask 0 1 2>> "$BATS_TEST_TMPDIR/ui" && r=0 || r=1
    exec {TS_FD}<&-
    (( r == 0 )) && lefts=$(( lefts + 1 ))
  done
  [ "$lefts" -gt 5 ]
  [ "$lefts" -lt 35 ]
}

@test "end to end accepts meh for every comparison" {
  three_tickets
  run --separate-stderr run_sort $'m\nm\nm\nm\nm'
  [ "$status" -eq 0 ]
  [ "$(grep -c . <<< "$output")" -eq 3 ]
  [[ "$stderr" == *"coin flip"* ]]
}

# ── comparison cache ─────────────────────────────────────────────────────────────
# Comparisons persist between runs keyed by ticket id pair, so a backlog you have
# already ranked does not re-ask what it already knows. TS_MEMO is keyed by
# array index, so load/save translate id <-> index.

@test "ts_comparisons_save writes the comparisons it was given" {
  TS_COMPARISONS_FILE="$BATS_TEST_TMPDIR/v.json"
  ts_load <<< '[{"id":"A-1","title":"one"},{"id":"A-2","title":"two"}]'
  TS_MEMO[0:1]=0
  TS_MEMO[1:0]=1
  ts_comparisons_save
  [ -f "$TS_COMPARISONS_FILE" ]
  run jq -r '.["A-1|A-2"].w' "$TS_COMPARISONS_FILE"
  [ "$output" = "A-1" ]
}

@test "ts_comparisons_load restores a comparison as a memo hit" {
  TS_COMPARISONS_FILE="$BATS_TEST_TMPDIR/v.json"
  cat > "$TS_COMPARISONS_FILE" <<'EOF'
{"A-1|A-2":{"w":"A-1","at":"2026-07-01T00:00:00Z"}}
EOF
  ts_load <<< '[{"id":"A-1","title":"one"},{"id":"A-2","title":"two"}]'
  ts_comparisons_load
  [ "${TS_MEMO[0:1]}" -eq 0 ]
  [ "${TS_MEMO[1:0]}" -eq 1 ]
}

@test "ts_comparisons_load survives a missing cache file" {
  TS_COMPARISONS_FILE="$BATS_TEST_TMPDIR/does-not-exist.json"
  ts_load <<< '[{"id":"A-1","title":"one"}]'
  run ts_comparisons_load
  [ "$status" -eq 0 ]
}

@test "ts_comparisons_load derives a pair you never answered" {
  # A > B and B > C means A > C. The sort would otherwise ask, and at 50
  # tickets that re-asking dominates: a warm re-run of the same list costs
  # ~144 questions without this, and 0 with it.
  TS_COMPARISONS_FILE="$BATS_TEST_TMPDIR/v.json"
  cat > "$TS_COMPARISONS_FILE" <<'EOF'
{"A|B":{"w":"A","at":"2026-07-01T00:00:00Z"},
 "B|C":{"w":"B","at":"2026-07-02T00:00:00Z"}}
EOF
  ts_load <<< '[{"id":"A","title":"a"},{"id":"B","title":"b"},{"id":"C","title":"c"}]'
  ts_comparisons_load
  # A|C was never stored, but it follows.
  [ "${TS_MEMO[0:2]}" -eq 0 ]
  [ "${TS_MEMO[2:0]}" -eq 1 ]
}

@test "ts_comparisons_load derives across a longer chain" {
  TS_COMPARISONS_FILE="$BATS_TEST_TMPDIR/v.json"
  cat > "$TS_COMPARISONS_FILE" <<'EOF'
{"A|B":{"w":"A","at":"2026-07-01T00:00:00Z"},
 "B|C":{"w":"B","at":"2026-07-01T00:00:00Z"},
 "C|D":{"w":"C","at":"2026-07-01T00:00:00Z"},
 "D|E":{"w":"D","at":"2026-07-01T00:00:00Z"}}
EOF
  ts_load <<< '[{"id":"A","title":"a"},{"id":"B","title":"b"},{"id":"C","title":"c"},{"id":"D","title":"d"},{"id":"E","title":"e"}]'
  ts_comparisons_load
  # A beats everything downstream of it, four links away included.
  [ "${TS_MEMO[0:4]}" -eq 0 ]
  [ "${TS_MEMO[1:4]}" -eq 0 ]
}

@test "the newest comparison wins a contradiction" {
  # Priorities drift: today's call must beat the older one it contradicts.
  # A>B and B>C are old; C>A is today. Keeping all three would be a cycle, so
  # the oldest edge in it yields.
  TS_COMPARISONS_FILE="$BATS_TEST_TMPDIR/v.json"
  cat > "$TS_COMPARISONS_FILE" <<'EOF'
{"A|B":{"w":"A","at":"2026-07-01T00:00:00Z"},
 "B|C":{"w":"B","at":"2026-07-02T00:00:00Z"},
 "A|C":{"w":"C","at":"2026-07-28T00:00:00Z"}}
EOF
  ts_load <<< '[{"id":"A","title":"a"},{"id":"B","title":"b"},{"id":"C","title":"c"}]'
  ts_comparisons_load
  # Today's comparison stands: C beats A.
  [ "${TS_MEMO[2:0]}" -eq 0 ]
}

@test "a contradiction leaves a usable order, not a cycle" {
  TS_COMPARISONS_FILE="$BATS_TEST_TMPDIR/v.json"
  cat > "$TS_COMPARISONS_FILE" <<'EOF'
{"A|B":{"w":"A","at":"2026-07-01T00:00:00Z"},
 "B|C":{"w":"B","at":"2026-07-02T00:00:00Z"},
 "A|C":{"w":"C","at":"2026-07-28T00:00:00Z"}}
EOF
  printf '%s\n' '[{"id":"A","title":"a"},{"id":"B","title":"b"},{"id":"C","title":"c"}]' \
    > "$BATS_TEST_TMPDIR/tickets"
  : > "$BATS_TEST_TMPDIR/empty"
  # No answers available, so every comparison must come from the store. A cycle
  # would make the sort ask, and asking aborts.
  run --separate-stderr env TS_COMPARISONS_FILE="$TS_COMPARISONS_FILE" TS_INPUT="$BATS_TEST_TMPDIR/empty" \
    bash "$TS" full < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  [ "$(grep -c . <<< "$output")" -eq 3 ]
  # Today's comparison is the one that survived, so C outranks A.
  [[ "$output" == *"C"* && "$output" == *"A"* ]] || false
  local c_line a_line
  c_line=$(grep -n ' C ' <<< "$output" | cut -d: -f1)
  a_line=$(grep -n ' A ' <<< "$output" | cut -d: -f1)
  [ "$c_line" -lt "$a_line" ]
}

@test "a direct reversal replaces the older comparison" {
  # The plainest drift case: same pair, answered the other way later.
  TS_COMPARISONS_FILE="$BATS_TEST_TMPDIR/v.json"
  cat > "$TS_COMPARISONS_FILE" <<'EOF'
{"A|B":{"w":"B","at":"2026-07-28T00:00:00Z"}}
EOF
  ts_load <<< '[{"id":"A","title":"a"},{"id":"B","title":"b"}]'
  ts_comparisons_load
  [ "${TS_MEMO[1:0]}" -eq 0 ]
  [ "${TS_MEMO[0:1]}" -eq 1 ]
}

@test "derived pairs are not written back to the store" {
  # The store stays a record of what you answered. Persisting derivations would
  # bloat it and freeze inferences that a later comparison should be free to undo.
  TS_COMPARISONS_FILE="$BATS_TEST_TMPDIR/v.json"
  cat > "$TS_COMPARISONS_FILE" <<'EOF'
{"A|B":{"w":"A","at":"2026-07-01T00:00:00Z"},
 "B|C":{"w":"B","at":"2026-07-02T00:00:00Z"}}
EOF
  ts_load <<< '[{"id":"A","title":"a"},{"id":"B","title":"b"},{"id":"C","title":"c"}]'
  ts_comparisons_load
  ts_comparisons_save
  [ "$(jq 'length' "$TS_COMPARISONS_FILE")" -eq 2 ]
  [ "$(jq -r '.["A|C"] // "absent"' "$TS_COMPARISONS_FILE")" = "absent" ]
}

@test "ts_comparisons_load ignores pairs whose tickets are absent" {
  TS_COMPARISONS_FILE="$BATS_TEST_TMPDIR/v.json"
  cat > "$TS_COMPARISONS_FILE" <<'EOF'
{"GONE-1|GONE-2":{"w":"GONE-1","at":"2026-07-01T00:00:00Z"}}
EOF
  ts_load <<< '[{"id":"A-1","title":"one"},{"id":"A-2","title":"two"}]'
  ts_comparisons_load
  [ -z "${TS_MEMO[0:1]:-}" ]
}

@test "ts_comparisons_load tolerates a corrupt cache file" {
  TS_COMPARISONS_FILE="$BATS_TEST_TMPDIR/v.json"
  printf 'not json at all' > "$TS_COMPARISONS_FILE"
  ts_load <<< '[{"id":"A-1","title":"one"},{"id":"A-2","title":"two"}]'
  run ts_comparisons_load
  [ "$status" -eq 0 ]
}

@test "an answer is on disk before the next question is asked" {
  # The EXIT trap covers q and a clean finish, but not SIGKILL, a closed
  # terminal, or a dead battery - all of which lost the whole session.
  local cache="$BATS_TEST_TMPDIR/live.json"
  TS_COMPARISONS_FILE="$cache"
  TS_TICKETS=('{"id":"A","title":"alpha"}' '{"id":"B","title":"bravo"}')
  TS_ARR=(0 1)
  TS_MEMO=()
  TS_FROM_STORE=()
  TS_ASKED=0
  printf 'l\n' > "$BATS_TEST_TMPDIR/one"
  exec {TS_FD}< "$BATS_TEST_TMPDIR/one"
  ts_ask 0 1 2>/dev/null || true
  exec {TS_FD}<&-
  # No exit, no trap - the file must already hold the answer.
  [ -f "$cache" ]
  [ "$(jq -r '.["A|B"].w' "$cache")" = "A" ]
}

@test "a killed run keeps the answers it already had" {
  local cache="$BATS_TEST_TMPDIR/killed.json"
  printf '%s\n' '[{"id":"A","title":"a"},{"id":"B","title":"b"},{"id":"C","title":"c"},{"id":"D","title":"d"}]' \
    > "$BATS_TEST_TMPDIR/tickets"
  mkfifo "$BATS_TEST_TMPDIR/feed"
  # Answer twice, then stall so the process is alive to be killed.
  ( printf 'l\n'; sleep 0.3; printf 'l\n'; sleep 30 ) > "$BATS_TEST_TMPDIR/feed" &
  local feeder=$!
  TS_COMPARISONS_FILE="$cache" TS_INPUT="$BATS_TEST_TMPDIR/feed" \
    bash "$TS" full < "$BATS_TEST_TMPDIR/tickets" >/dev/null 2>&1 &
  local sorter=$!
  sleep 1.5
  kill -9 "$sorter" 2>/dev/null || true
  kill "$feeder" 2>/dev/null || true
  wait 2>/dev/null || true
  # SIGKILL runs no trap, so anything on disk got there per-answer.
  [ -f "$cache" ]
  [ "$(jq 'length' "$cache")" -ge 1 ]
}

@test "a re-run reuses cached comparisons instead of asking" {
  local cache="$BATS_TEST_TMPDIR/reuse.json"
  printf '%s\n' '[{"id":"A-1","title":"one"},{"id":"A-2","title":"two"}]' \
    > "$BATS_TEST_TMPDIR/tickets"
  printf 'l\n' > "$BATS_TEST_TMPDIR/answers"

  # first run answers the single pair and caches it
  TS_COMPARISONS_FILE="$cache" TS_INPUT="$BATS_TEST_TMPDIR/answers" \
    bash "$TS" full < "$BATS_TEST_TMPDIR/tickets" >/dev/null 2>&1

  # second run gets no answers at all - it must not need any
  : > "$BATS_TEST_TMPDIR/empty"
  run env TS_COMPARISONS_FILE="$cache" TS_INPUT="$BATS_TEST_TMPDIR/empty" \
    bash "$TS" full < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  [[ "$output" == *"A-1"* ]]
}

@test "a hand-edited comparison is honored on the next run" {
  # Cached pairs are never re-asked, so editing the file is how you change your
  # mind about one. Flipping "w" must flip the ranking.
  local cache="$BATS_TEST_TMPDIR/edited.json"
  printf '%s\n' '[{"id":"X-1","title":"one"},{"id":"X-2","title":"two"}]' \
    > "$BATS_TEST_TMPDIR/tickets"
  cat > "$cache" <<'EOF'
{"X-1|X-2":{"w":"X-2","at":"2026-07-01T00:00:00Z"}}
EOF
  : > "$BATS_TEST_TMPDIR/empty"
  run --separate-stderr env TS_COMPARISONS_FILE="$cache" TS_INPUT="$BATS_TEST_TMPDIR/empty" \
    bash "$TS" full < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  # X-2 was declared the winner, so it ranks first without any question asked.
  [[ "$(head -1 <<< "$output")" == *"X-2"* ]] || false
  [[ "$stderr" == *"1 answer reused"* ]]
}

@test "the cache defaults to the XDG state dir" {
  # setup() exports TS_COMPARISONS_FILE so tests cannot touch the real one; drop it here to
  # see what the script picks on its own.
  run env -u TS_COMPARISONS_FILE XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" \
    bash -c 'source "'"$TS"'"; printf "%s\n" "$TS_COMPARISONS_FILE"'
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/state/ticket-sort/comparisons.json" ]
}

@test "the cache falls back to ~/.local/state without XDG_STATE_HOME" {
  run env -u TS_COMPARISONS_FILE -u XDG_STATE_HOME HOME="$BATS_TEST_TMPDIR/home" \
    bash -c 'source "'"$TS"'"; printf "%s\n" "$TS_COMPARISONS_FILE"'
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/home/.local/state/ticket-sort/comparisons.json" ]
}

@test "the cache is not written inside the repo" {
  # It used to live beside the script, which meant generated state in a git
  # repo and a .gitignore line to keep it out of commits.
  run env -u TS_COMPARISONS_FILE XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" \
    bash -c 'source "'"$TS"'"; printf "%s\n" "$TS_COMPARISONS_FILE"'
  [ "$status" -eq 0 ]
  [[ "$output" != *"$BATS_TEST_DIRNAME"* ]]
}

@test "ts_comparisons_save creates the state dir when it does not exist" {
  TS_COMPARISONS_FILE="$BATS_TEST_TMPDIR/deep/nested/state/ticket-sort/comparisons.json"
  ts_load <<< '[{"id":"A-1","title":"one"},{"id":"A-2","title":"two"}]'
  TS_MEMO[0:1]=0
  ts_comparisons_save
  [ -f "$TS_COMPARISONS_FILE" ]
}

@test "TS_COMPARISONS_FILE=none disables persistence" {
  TS_COMPARISONS_FILE=none
  ts_load <<< '[{"id":"A-1","title":"one"},{"id":"A-2","title":"two"}]'
  TS_MEMO[0:1]=0
  run ts_comparisons_save
  [ "$status" -eq 0 ]
  [ ! -e none ]
}

# ── ticket parsing ────────────────────────────────────────────────────────────

@test "ts_load reads a JSON array" {
  ts_load <<< '[{"id":"A-1","title":"one"},{"id":"A-2","title":"two"}]'
  [ "${#TS_TICKETS[@]}" -eq 2 ]
  [[ "${TS_TICKETS[0]}" == *'"A-1"'* ]]
}

@test "ts_load reads NDJSON" {
  ts_load <<'EOF'
{"id":"A-1","title":"one"}
{"id":"A-2","title":"two"}
EOF
  [ "${#TS_TICKETS[@]}" -eq 2 ]
}

@test "ts_load refuses a terminal instead of blocking on it" {
  # jq -s against a tty blocks until EOF, so `ticket-sort` with no pipe and no
  # -f just sat there looking hung - three Ctrl-Cs in a real session. Reading
  # from a terminal is never what was meant, so say what is missing.
  #
  # /dev/tty rather than script(1): script feeds an EOF, so the child gets
  # clean input and the test passes without exercising the guard at all.
  ( exec < /dev/tty ) 2>/dev/null || skip "no controlling terminal in this environment"
  run timeout 10 ts_load < /dev/tty
  [ "$status" -ne 0 ]
  [ "$status" -ne 124 ]           # 124 is timeout, i.e. it hung
  [[ "$output" == *"terminal"* ]]
}

@test "ts_load errors on empty input" {
  run ts_load < /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"no tickets"* ]]
}

# ── rendering ─────────────────────────────────────────────────────────────────

FULL_TICKET='{"id":"ENG-412","title":"Fix checkout timeout","priority":"Urgent","due":"2026-08-03","sla":"P1 - 2 business days","labels":["bug","customer"],"project":"Checkout Revamp"}'

@test "ts_render shows every field" {
  TS_TODAY=2026-07-27
  run ts_render "$FULL_TICKET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ENG-412"* ]] || false
  [[ "$output" == *"Fix checkout timeout"* ]] || false
  [[ "$output" == *"Urgent"* ]] || false
  [[ "$output" == *"2026-08-03"* ]] || false
  [[ "$output" == *"P1 - 2 business days"* ]] || false
  [[ "$output" == *"bug, customer"* ]] || false
  [[ "$output" == *"Checkout Revamp"* ]]
}

@test "ts_render marks a future due date with days remaining" {
  TS_TODAY=2026-07-27
  run ts_render "$FULL_TICKET"
  [[ "$output" == *"in 7d"* ]]
}

@test "ts_render marks a past due date as overdue" {
  TS_TODAY=2026-08-10
  run ts_render "$FULL_TICKET"
  [[ "$output" == *"OVERDUE"* ]] || false
  [[ "$output" == *"7d"* ]]
}

# SLA is a breach deadline in Linear, stored like any other datetime - only
# its behavior differs. So it renders on the same clock as the due date.

@test "ts_days_until parses a plain date" {
  TS_TODAY=2026-07-27
  run ts_days_until 2026-08-03
  [ "$status" -eq 0 ]
  [ "$output" = "7" ]
}

@test "ts_days_until parses an ISO datetime" {
  TS_TODAY=2026-07-27
  run ts_days_until "2026-08-03T17:00:00.000Z"
  [ "$status" -eq 0 ]
  [ "$output" = "7" ]
}

@test "ts_days_until rejects something that is not a date" {
  TS_TODAY=2026-07-27
  run ts_days_until "P1 - 2 business days"
  [ "$status" -ne 0 ]
}

@test "ts_render counts down an SLA the way it counts down a due date" {
  TS_TODAY=2026-07-27
  run ts_render '{"id":"E-1","title":"t","sla":"2026-08-03T17:00:00.000Z"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"in 7d"* ]]
}

@test "ts_render flags a breached SLA" {
  TS_TODAY=2026-08-10
  run ts_render '{"id":"E-1","title":"t","sla":"2026-08-03T17:00:00.000Z"}'
  [[ "$output" == *"OVERDUE"* ]] || false
  [[ "$output" == *"7d"* ]]
}

@test "ts_render flags an SLA breaching today" {
  TS_TODAY=2026-08-03
  run ts_render '{"id":"E-1","title":"t","sla":"2026-08-03T17:00:00.000Z"}'
  [[ "$output" == *"DUE TODAY"* ]]
}

@test "ts_render shows a parsed datetime as a plain date" {
  # An SLA and a due date should read the same; the time component adds
  # nothing at day granularity.
  TS_TODAY=2026-07-27
  run ts_render '{"id":"E-1","title":"t","sla":"2026-08-03T17:00:00.000Z"}'
  [[ "$output" == *"2026-08-03"* ]] || false
  [[ "$output" != *"T17:00:00"* ]]
}

@test "ts_render leaves a non-date SLA as written" {
  # Some sources put free text here; show it rather than dropping it.
  TS_TODAY=2026-07-27
  run ts_render '{"id":"E-1","title":"t","sla":"P1 - 2 business days"}'
  [[ "$output" == *"P1 - 2 business days"* ]]
}

@test "ts_render counts down a due date given as an ISO datetime" {
  TS_TODAY=2026-07-27
  run ts_render '{"id":"E-1","title":"t","due":"2026-07-30T00:00:00.000Z"}'
  [[ "$output" == *"in 3d"* ]]
}

@test "demo tickets carry SLA dates that render as deadlines" {
  TS_TODAY=2026-07-27
  local sla_dates
  sla_dates=$(ts_demo_data | jq -r '.sla // empty' | grep -c 'T')
  [ "$sla_dates" -gt 3 ]
}

@test "ts_render shows status" {
  TS_TODAY=2026-07-27
  run ts_render '{"id":"ENG-9","title":"bare","status":"In Progress"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Status"* ]] || false
  [[ "$output" == *"In Progress"* ]]
}

@test "demo tickets carry a status" {
  local with_status
  with_status=$(ts_demo_data | jq -r '.status // empty' | grep -c .)
  [ "$with_status" -gt 3 ]
}

@test "ts_render tolerates missing fields" {
  TS_TODAY=2026-07-27
  run ts_render '{"id":"ENG-9","title":"bare"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ENG-9"* ]] || false
  [[ "$output" == *"bare"* ]] || false
  [[ "$output" == *"—"* ]]
}

@test "ts_render tolerates explicit nulls" {
  TS_TODAY=2026-07-27
  run ts_render '{"id":"ENG-9","title":"bare","priority":null,"due":null,"labels":null,"status":null}'
  [ "$status" -eq 0 ]
  [[ "$output" != *"null"* ]]
}

@test "ts_render accepts a numeric priority" {
  TS_TODAY=2026-07-27
  run ts_render '{"id":"ENG-9","title":"bare","priority":1}'
  [[ "$output" == *"1"* ]]
}

# ── end to end ────────────────────────────────────────────────────────────────
# Answers are fed through TS_INPUT, which the script opens on FD 3 in place
# of /dev/tty. The UI goes to stderr, the ranking to stdout.

run_sort() {
  local answers="$1"; shift
  printf '%s\n' "$answers" > "$BATS_TEST_TMPDIR/answers"
  # TS_COMPARISONS_FILE per test dir: the real cache lives beside the script, and a test
  # that inherited it would answer from previous runs instead of asking.
  TS_INPUT="$BATS_TEST_TMPDIR/answers" TS_TODAY=2026-07-27 \
    TS_COMPARISONS_FILE="$BATS_TEST_TMPDIR/comparisons.json" \
    bash "$TS" full "$@" < "$BATS_TEST_TMPDIR/tickets"
}

three_tickets() {
  cat > "$BATS_TEST_TMPDIR/tickets" <<'EOF'
{"id":"A","title":"alpha"}
{"id":"B","title":"bravo"}
{"id":"C","title":"charlie"}
EOF
}

@test "end to end ranks by the answers given" {
  three_tickets
  # Whatever the pivot order, answering "1" every time keeps the left-hand
  # ticket ahead; the result must still be a complete ranking of all three.
  run --separate-stderr run_sort $'1\n1\n1\n1\n1'
  [ "$status" -eq 0 ]
  [[ "$output" == *"A"* ]] || false
  [[ "$output" == *"B"* ]] || false
  [[ "$output" == *"C"* ]] || false
  [ "$(grep -c . <<< "$output")" -eq 3 ]
}

@test "end to end emits JSON with --json" {
  three_tickets
  run --separate-stderr run_sort $'1\n1\n1\n1\n1' --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 3' > /dev/null
  echo "$output" | jq -e '.[0].rank == 1' > /dev/null
}

@test "end to end quits cleanly on q" {
  three_tickets
  run --separate-stderr run_sort $'q'
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"aborted"* ]]
}

@test "--demo runs without external input" {
  run --separate-stderr env TS_COMPARISONS_FILE=none bash "$TS" report --demo
  [ "$status" -eq 0 ]
  [ "$(grep -c . <<< "$output")" -gt 3 ]
}

@test "--top prints only the ranked head" {
  cat > "$BATS_TEST_TMPDIR/tickets" <<'EOF'
{"id":"A","title":"alpha"}
{"id":"B","title":"bravo"}
{"id":"C","title":"charlie"}
{"id":"D","title":"delta"}
{"id":"E","title":"echo"}
EOF
  run --separate-stderr run_sort $'1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1' --top 2
  [ "$status" -eq 0 ]
  [ "$(grep -c . <<< "$output")" -eq 2 ]
}

@test "show lists more rows than --top ranked" {
  cat > "$BATS_TEST_TMPDIR/tickets" <<'EOF'
{"id":"A","title":"alpha"}
{"id":"B","title":"bravo"}
{"id":"C","title":"charlie"}
{"id":"D","title":"delta"}
{"id":"E","title":"echo"}
EOF
  run --separate-stderr run_sort $'1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1' --top 2 --show 5
  [ "$status" -eq 0 ]
  [ "$(grep -c . <<< "$output")" -gt 2 ]
}

@test "show marks unranked rows instead of numbering them" {
  cat > "$BATS_TEST_TMPDIR/tickets" <<'EOF'
{"id":"A","title":"alpha"}
{"id":"B","title":"bravo"}
{"id":"C","title":"charlie"}
{"id":"D","title":"delta"}
{"id":"E","title":"echo"}
EOF
  # Driven through ts_report rather than a full run: which positions settle
  # depends on pivot luck, and with a degenerate answer stream every position
  # settles and nothing is left to dot. Here only the head is settled, so the
  # rows past it must not claim a rank.
  TS_TICKETS=('{"id":"A","title":"alpha"}' '{"id":"B","title":"bravo"}'
              '{"id":"C","title":"charlie"}' '{"id":"D","title":"delta"}'
              '{"id":"E","title":"echo"}')
  TS_ARR=(0 1 2 3 4)
  TS_SETTLED=()
  TS_SETTLED[0]=1
  TS_SETTLED[1]=1
  run ts_report no 2 5
  [ "$status" -eq 0 ]
  [ "$(grep -cE '^ *[0-9]+\.' <<< "$output")" -eq 2 ]
  [ "$(grep -c '·' <<< "$output")" -eq 3 ]
}

@test "show numbers positions a pivot settled past the ranked head" {
  # A settled position is final - quicksort guarantees a landed pivot never
  # moves - so the report must number it rather than dot it. Driven through
  # ts_report directly: which positions settle in a real run depends on pivot
  # luck, and this asserts the reporting rule, not the sort.
  TS_TICKETS=('{"id":"A","title":"alpha"}' '{"id":"B","title":"bravo"}'
              '{"id":"C","title":"charlie"}' '{"id":"D","title":"delta"}')
  TS_ARR=(0 1 2 3)
  TS_SETTLED=()
  TS_SETTLED[0]=1   # ranked head
  TS_SETTLED[2]=1   # settled past the head - must be numbered
  run ts_report no 1 4
  [ "$status" -eq 0 ]
  [[ "$output" == *" 1. A"* ]] || false
  [[ "$output" == *" 3. C"* ]] || false
  # B and D were never settled, so they stay dotted.
  [[ "$output" == *"·  B"* ]] || false
  [[ "$output" == *"·  D"* ]]
}

@test "show with --json gives settled positions their rank number" {
  TS_TICKETS=('{"id":"A","title":"alpha"}' '{"id":"B","title":"bravo"}'
              '{"id":"C","title":"charlie"}')
  TS_ARR=(0 1 2)
  TS_SETTLED=()
  TS_SETTLED[0]=1
  TS_SETTLED[2]=1
  run ts_report yes 1 3
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].rank' <<< "$output")" = "1" ]
  [ "$(jq -r '.[1].rank' <<< "$output")" = "null" ]
  [ "$(jq -r '.[2].rank' <<< "$output")" = "3" ]
}

@test "show smaller than --top does not shrink the ranked head" {
  three_tickets
  run --separate-stderr run_sort $'1\n1\n1\n1\n1\n1' --top 2 --show 1
  [ "$status" -eq 0 ]
  [ "$(grep -cE '^ *[0-9]+\.' <<< "$output")" -eq 2 ]
}

@test "show rejects a non-positive count" {
  three_tickets
  run run_sort $'1' --show 0
  [ "$status" -eq 2 ]
}

@test "show with --json marks unranked rows with a null rank" {
  cat > "$BATS_TEST_TMPDIR/tickets" <<'EOF'
{"id":"A","title":"alpha"}
{"id":"B","title":"bravo"}
{"id":"C","title":"charlie"}
{"id":"D","title":"delta"}
{"id":"E","title":"echo"}
EOF
  run --separate-stderr run_sort $'1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1' --top 2 --show 5 --json
  [ "$status" -eq 0 ]
  # End to end, whatever the pivots did: five rows out, every rank is either
  # null or its own 1-based position - never a renumbering that would promote a
  # ticket into a rank nothing established.
  [ "$(jq 'length' <<< "$output")" -eq 5 ]
  [ "$(jq '[to_entries[] | select(.value.rank != null and .value.rank != .key + 1)] | length' <<< "$output")" -eq 0 ]
  # The head is always ranked, whatever else happened.
  [ "$(jq -r '.[0].rank' <<< "$output")" = "1" ]
  [ "$(jq -r '.[1].rank' <<< "$output")" = "2" ]
}

# ── place ─────────────────────────────────────────────────────────────────────
# `place` answers one question per newcomer: does it beat the cut? Above, it is
# placed precisely within the head. Below, it goes to the tail and is not asked
# about again. Measured over 30 simulated days that is 250 questions against 673
# for full placement, with a MORE accurate top ten - because every question
# lands on the boundary that decides membership.

place_fixture() {
  # A, B, C fully ordered (A > B > C). D and E are newcomers.
  PLACE_STORE="$BATS_TEST_TMPDIR/pl.json"
  cat > "$PLACE_STORE" <<'EOF'
{"A|B":{"w":"A","at":"2026-07-01T00:00:00Z"},
 "A|C":{"w":"A","at":"2026-07-01T00:00:00Z"},
 "B|C":{"w":"B","at":"2026-07-01T00:00:00Z"}}
EOF
  printf '%s\n' '[{"id":"A","title":"a"},{"id":"B","title":"b"},{"id":"C","title":"c"},{"id":"D","title":"d"}]' \
    > "$BATS_TEST_TMPDIR/tickets"
}

@test "place refuses to run without stored comparisons" {
  printf '%s\n' '[{"id":"A","title":"a"},{"id":"B","title":"b"}]' \
    > "$BATS_TEST_TMPDIR/tickets"
  run --separate-stderr env TS_COMPARISONS_FILE="$BATS_TEST_TMPDIR/none.json" \
    bash "$TS" place < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"full"* ]]     # points at the command that does work
}

@test "place asks one question per newcomer when they lose the cut" {
  place_fixture
  # D loses to the cut ticket, so one question settles it.
  printf 'r\n' > "$BATS_TEST_TMPDIR/answers"
  run --separate-stderr env TS_COMPARISONS_FILE="$PLACE_STORE" \
    TS_INPUT="$BATS_TEST_TMPDIR/answers" \
    bash "$TS" place --top 2 < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"1 question"* ]]
}

@test "place rt settles subsequent newcomers against the same cut" {
  place_fixture
  jq '. + [{"id":"E","title":"e"}]' "$BATS_TEST_TMPDIR/tickets" \
    > "$BATS_TEST_TMPDIR/more-tickets"
  printf 'rt\n' > "$BATS_TEST_TMPDIR/answers"
  run --separate-stderr env TS_COMPARISONS_FILE="$PLACE_STORE" \
    TS_INPUT="$BATS_TEST_TMPDIR/answers" \
    bash "$TS" place --top 2 < "$BATS_TEST_TMPDIR/more-tickets"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"1 question"* ]]
  [ "$(jq -r '.["B|D"].w' "$PLACE_STORE")" = "B" ]
  [ "$(jq -r '.["B|E"].w' "$PLACE_STORE")" = "B" ]
}

@test "place does not disturb the tickets already ranked" {
  place_fixture
  printf 'r\n' > "$BATS_TEST_TMPDIR/answers"
  run --separate-stderr env TS_COMPARISONS_FILE="$PLACE_STORE" \
    TS_INPUT="$BATS_TEST_TMPDIR/answers" \
    bash "$TS" place --top 2 < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  # A still beats B - place must not re-open settled pairs.
  [ "$(jq -r '.["A|B"].w' "$PLACE_STORE")" = "A" ]
}

@test "place records a losing newcomer as below the whole head" {
  place_fixture
  printf 'r\n' > "$BATS_TEST_TMPDIR/answers"
  run --separate-stderr env TS_COMPARISONS_FILE="$PLACE_STORE" \
    TS_INPUT="$BATS_TEST_TMPDIR/answers" \
    bash "$TS" place --top 2 < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  # One question said D loses to the cut; closure or explicit writes must leave
  # D below every ticket in the head, or it would be asked again next run.
  run env TS_COMPARISONS_FILE="$PLACE_STORE" bash "$TS" report --json < /dev/null
  [ "$status" -eq 0 ]
  local d_rank
  d_rank=$(jq -r '.[] | select(.id=="D") | .beats' <<< "$output")
  [ "$d_rank" = "0" ]
}

@test "place puts a winning newcomer into the head" {
  place_fixture
  # D beats the cut, then beats A too - it should land first.
  printf 'l\nl\nl\n' > "$BATS_TEST_TMPDIR/answers"
  run --separate-stderr env TS_COMPARISONS_FILE="$PLACE_STORE" \
    TS_INPUT="$BATS_TEST_TMPDIR/answers" \
    bash "$TS" place --top 2 < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  [[ "$(head -1 <<< "$output")" == *"D"* ]]
}

@test "place asks nothing when there are no newcomers" {
  place_fixture
  printf '%s\n' '[{"id":"A","title":"a"},{"id":"B","title":"b"},{"id":"C","title":"c"}]' \
    > "$BATS_TEST_TMPDIR/tickets"
  : > "$BATS_TEST_TMPDIR/empty"
  run --separate-stderr env TS_COMPARISONS_FILE="$PLACE_STORE" \
    TS_INPUT="$BATS_TEST_TMPDIR/empty" \
    bash "$TS" place --top 2 < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"nothing new"* ]]
}

@test "place says how many newcomers it found before asking" {
  place_fixture
  printf 'r\n' > "$BATS_TEST_TMPDIR/answers"
  run --separate-stderr env TS_COMPARISONS_FILE="$PLACE_STORE" \
    TS_INPUT="$BATS_TEST_TMPDIR/answers" \
    bash "$TS" place --top 2 < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"1 new"* ]]
}

@test "place asks at most one question per newcomer below the cut" {
  # The whole justification: 1 question per newcomer that loses the cut, versus
  # binary-searching it against everything.
  local store_a="$BATS_TEST_TMPDIR/a.json"
  python3 - "$store_a" <<'PY'
import json,sys
ids=[f"R-{i:02d}" for i in range(12)]
d={}
for i in range(12):
    for j in range(i+1,12):
        a,b=sorted([ids[i],ids[j]])
        d[f"{a}|{b}"]={"w":ids[i],"at":"2026-07-01T00:00:00Z"}
json.dump(d,open(sys.argv[1],"w"))
PY
  python3 -c '
import json
ids=[f"R-{i:02d}" for i in range(12)]+["NEW-1","NEW-2","NEW-3"]
print(json.dumps([{"id":i,"title":i} for i in ids]))' > "$BATS_TEST_TMPDIR/tickets"
  # all newcomers lose
  printf 'r\nr\nr\nr\nr\nr\nr\nr\nr\nr\nr\nr\nr\nr\nr\nr\nr\nr\nr\nr\n' \
    > "$BATS_TEST_TMPDIR/answers"

  run --separate-stderr env TS_COMPARISONS_FILE="$store_a" \
    TS_INPUT="$BATS_TEST_TMPDIR/answers" \
    bash "$TS" place --top 5 < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  local place_q
  place_q=$(grep -oE 'Done - [0-9]+ question' <<< "$stderr" | tr -dc '0-9')

  # Deliberately NOT raced against `full`: its pivots are random, so it
  # occasionally gets lucky and ties this - the test failed 1 run in 3 that way.
  # What place actually guarantees is one question per newcomer that loses the
  # cut, which is the claim worth pinning down.
  [ "$place_q" -le 3 ]
}

# ── prune ─────────────────────────────────────────────────────────────────────
# Prune drops comparisons only for tickets the input SAYS are finished. Absence is
# never evidence: the input is usually a scoped query, so a ticket missing from
# it is far more likely out of scope than closed.

prune_fixture() {
  PRUNE_STORE="$BATS_TEST_TMPDIR/p.json"
  cat > "$PRUNE_STORE" <<'EOF'
{"A|B":{"w":"A","at":"2026-07-01T00:00:00Z"},
 "A|C":{"w":"A","at":"2026-07-01T00:00:00Z"},
 "B|C":{"w":"B","at":"2026-07-01T00:00:00Z"},
 "C|D":{"w":"C","at":"2026-07-01T00:00:00Z"}}
EOF
}

@test "prune drops comparisons for Done tickets" {
  prune_fixture
  printf '%s\n' '[{"id":"A","title":"a","status":"Done"},{"id":"B","title":"b","status":"In Progress"}]' \
    > "$BATS_TEST_TMPDIR/tickets"
  run --separate-stderr env TS_COMPARISONS_FILE="$PRUNE_STORE" \
    bash "$TS" prune --apply < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  # A|B and A|C mention A, which is Done.
  [ "$(jq 'length' "$PRUNE_STORE")" -eq 2 ]
  [ "$(jq -r '.["A|B"] // "gone"' "$PRUNE_STORE")" = "gone" ]
  [ "$(jq -r '.["B|C"].w' "$PRUNE_STORE")" = "B" ]
}

@test "prune drops Canceled and Duplicated too" {
  prune_fixture
  printf '%s\n' '[{"id":"A","title":"a","status":"Canceled"},{"id":"D","title":"d","status":"Duplicated"}]' \
    > "$BATS_TEST_TMPDIR/tickets"
  run --separate-stderr env TS_COMPARISONS_FILE="$PRUNE_STORE" \
    bash "$TS" prune --apply < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  # A|B, A|C (A canceled) and C|D (D duplicated) go; B|C stays.
  [ "$(jq 'length' "$PRUNE_STORE")" -eq 1 ]
  [ "$(jq -r '.["B|C"].w' "$PRUNE_STORE")" = "B" ]
}

@test "prune NEVER drops a ticket merely absent from the input" {
  # The whole point: `linear.sh json active 7d` does not mention closed work OR
  # anything out of scope, and guessing between those would delete real calls.
  prune_fixture
  printf '%s\n' '[{"id":"A","title":"a","status":"Done"}]' \
    > "$BATS_TEST_TMPDIR/tickets"
  run --separate-stderr env TS_COMPARISONS_FILE="$PRUNE_STORE" \
    bash "$TS" prune --apply < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  # B, C and D were never mentioned - every comparison not involving A survives.
  [ "$(jq -r '.["B|C"].w' "$PRUNE_STORE")" = "B" ]
  [ "$(jq -r '.["C|D"].w' "$PRUNE_STORE")" = "C" ]
}

@test "prune keeps unfinished and unrecognised statuses" {
  prune_fixture
  printf '%s\n' '[{"id":"A","title":"a","status":"In Review"},{"id":"B","title":"b","status":"Won'"'"'t Do"},{"id":"C","title":"c","status":"Almost Done"}]' \
    > "$BATS_TEST_TMPDIR/tickets"
  run --separate-stderr env TS_COMPARISONS_FILE="$PRUNE_STORE" \
    bash "$TS" prune --apply < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  # "Almost Done" contains "Done" but is not Done - exact match only.
  [ "$(jq 'length' "$PRUNE_STORE")" -eq 4 ]
}

@test "prune is case-insensitive on the status name" {
  prune_fixture
  printf '%s\n' '[{"id":"A","title":"a","status":"done"}]' \
    > "$BATS_TEST_TMPDIR/tickets"
  run --separate-stderr env TS_COMPARISONS_FILE="$PRUNE_STORE" \
    bash "$TS" prune --apply < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  [ "$(jq 'length' "$PRUNE_STORE")" -eq 2 ]
}

@test "prune without --apply changes nothing" {
  prune_fixture
  local before
  before=$(cat "$PRUNE_STORE")
  printf '%s\n' '[{"id":"A","title":"a","status":"Done"}]' \
    > "$BATS_TEST_TMPDIR/tickets"
  run --separate-stderr env TS_COMPARISONS_FILE="$PRUNE_STORE" \
    bash "$TS" prune < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  [ "$(cat "$PRUNE_STORE")" = "$before" ]
  [[ "$stderr" == *"dry run"* ]] || false
  [[ "$stderr" == *"--apply"* ]]
}

@test "prune rejects the old --force spelling rather than writing" {
  prune_fixture
  local before
  before=$(cat "$PRUNE_STORE")
  printf '%s\n' '[{"id":"A","title":"a","status":"Done"}]' \
    > "$BATS_TEST_TMPDIR/tickets"
  run --separate-stderr env TS_COMPARISONS_FILE="$PRUNE_STORE" \
    bash "$TS" prune --force < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"unknown option"* ]] || false
  [ "$(cat "$PRUNE_STORE")" = "$before" ]
}

@test "prune dry run reports what it would drop" {
  prune_fixture
  printf '%s\n' '[{"id":"A","title":"a","status":"Done"}]' \
    > "$BATS_TEST_TMPDIR/tickets"
  run --separate-stderr env TS_COMPARISONS_FILE="$PRUNE_STORE" \
    bash "$TS" prune < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"A"* ]] || false
  [[ "$stderr" == *"Done"* ]]
}

@test "prune backs the store up before writing" {
  prune_fixture
  printf '%s\n' '[{"id":"A","title":"a","status":"Done"}]' \
    > "$BATS_TEST_TMPDIR/tickets"
  run env TS_COMPARISONS_FILE="$PRUNE_STORE" \
    bash "$TS" prune --apply < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  [ -f "$PRUNE_STORE.bak" ]
  [ "$(jq 'length' "$PRUNE_STORE.bak")" -eq 4 ]
}

@test "prune with nothing to drop leaves the store alone" {
  prune_fixture
  local before
  before=$(cat "$PRUNE_STORE")
  printf '%s\n' '[{"id":"A","title":"a","status":"In Progress"}]' \
    > "$BATS_TEST_TMPDIR/tickets"
  run --separate-stderr env TS_COMPARISONS_FILE="$PRUNE_STORE" \
    bash "$TS" prune --apply < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  [ "$(cat "$PRUNE_STORE")" = "$before" ]
}

@test "prune requires input rather than reading the store" {
  # Unlike report, prune has nothing to say without a ticket list: statuses
  # live in the input, never in the store.
  prune_fixture
  run --separate-stderr env TS_COMPARISONS_FILE="$PRUNE_STORE" \
    bash "$TS" prune < /dev/null
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"no tickets"* ]]
}

@test "TS_PRUNE_STATES overrides which statuses count as finished" {
  prune_fixture
  printf '%s\n' '[{"id":"A","title":"a","status":"Shipped"}]' \
    > "$BATS_TEST_TMPDIR/tickets"
  run --separate-stderr env TS_COMPARISONS_FILE="$PRUNE_STORE" TS_PRUNE_STATES="Shipped" \
    bash "$TS" prune --apply < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  [ "$(jq 'length' "$PRUNE_STORE")" -eq 2 ]
}

# ── comparison-only report ───────────────────────────────────────────────────────
# report ranks from the store alone and never asks. The closure gives a
# partial order, so tickets the store cannot separate are marked, not numbered.
# The store IS the input: it already knows every ticket you have ranked, so a
# report needs no ticket list and works with Linear unreachable.

@test "report needs no input at all" {
  local cache="$BATS_TEST_TMPDIR/r.json"
  cat > "$cache" <<'EOF'
{"A|B":{"w":"A","at":"2026-07-01T00:00:00Z"},
 "B|C":{"w":"B","at":"2026-07-01T00:00:00Z"}}
EOF
  # No pipe, no -f. bats leaves its own pipe on stdin even with <&-, so
  # /dev/null is how a test says "nothing was piped in".
  run --separate-stderr env TS_COMPARISONS_FILE="$cache" bash "$TS" report < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"A"* ]] || false
  [[ "$output" == *"C"* ]]
}

@test "report ranks every ticket the store knows about" {
  local cache="$BATS_TEST_TMPDIR/r.json"
  cat > "$cache" <<'EOF'
{"A|B":{"w":"A","at":"2026-07-01T00:00:00Z"},
 "B|C":{"w":"B","at":"2026-07-01T00:00:00Z"}}
EOF
  run --separate-stderr env TS_COMPARISONS_FILE="$cache" bash "$TS" report < /dev/null
  [ "$status" -eq 0 ]
  [ "$(grep -c . <<< "$output")" -eq 3 ]
  [[ "$(sed -n '1p' <<< "$output")" == *"A"* ]] || false
  [[ "$(sed -n '3p' <<< "$output")" == *"C"* ]]
}

@test "report on an empty store says so rather than printing nothing" {
  run --separate-stderr env TS_COMPARISONS_FILE="$BATS_TEST_TMPDIR/missing.json" \
    bash "$TS" report < /dev/null
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"no comparisons"* ]]
}

@test "report uses piped tickets for titles and scope" {
  local cache="$BATS_TEST_TMPDIR/r.json"
  cat > "$cache" <<'EOF'
{"A|B":{"w":"A","at":"2026-07-01T00:00:00Z"},
 "B|C":{"w":"B","at":"2026-07-01T00:00:00Z"}}
EOF
  # Only A and B piped in, so C - though known to the store - is out of scope.
  printf '%s\n' '[{"id":"A","title":"alpha title"},{"id":"B","title":"bravo title"}]' \
    > "$BATS_TEST_TMPDIR/tickets"
  run --separate-stderr env TS_COMPARISONS_FILE="$cache" \
    bash "$TS" report < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha title"* ]] || false
  [ "$(grep -c . <<< "$output")" -eq 2 ]
  [[ "$output" != *"C"* ]]
}

@test "report asks nothing" {
  local cache="$BATS_TEST_TMPDIR/r.json"
  cat > "$cache" <<'EOF'
{"A|B":{"w":"A","at":"2026-07-01T00:00:00Z"},
 "B|C":{"w":"B","at":"2026-07-01T00:00:00Z"}}
EOF
  printf '%s\n' '[{"id":"A","title":"a"},{"id":"B","title":"b"},{"id":"C","title":"c"}]' \
    > "$BATS_TEST_TMPDIR/tickets"
  : > "$BATS_TEST_TMPDIR/empty"
  run --separate-stderr env TS_COMPARISONS_FILE="$cache" TS_INPUT="$BATS_TEST_TMPDIR/empty" \
    bash "$TS" report < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"Which should be worked next"* ]]
}

@test "report orders by what the comparisons prove" {
  local cache="$BATS_TEST_TMPDIR/r.json"
  cat > "$cache" <<'EOF'
{"A|B":{"w":"A","at":"2026-07-01T00:00:00Z"},
 "B|C":{"w":"B","at":"2026-07-01T00:00:00Z"}}
EOF
  printf '%s\n' '[{"id":"C","title":"c"},{"id":"A","title":"a"},{"id":"B","title":"b"}]' \
    > "$BATS_TEST_TMPDIR/tickets"
  : > "$BATS_TEST_TMPDIR/empty"
  run --separate-stderr env TS_COMPARISONS_FILE="$cache" TS_INPUT="$BATS_TEST_TMPDIR/empty" \
    bash "$TS" report < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  # A beats B and (transitively) C; B beats C. Input order is C,A,B - the
  # report must reorder.
  [[ "$(sed -n '1p' <<< "$output")" == *"A"* ]] || false
  [[ "$(sed -n '2p' <<< "$output")" == *"B"* ]] || false
  [[ "$(sed -n '3p' <<< "$output")" == *"C"* ]]
}

@test "report marks tickets the store cannot separate" {
  # D is in the list but no comparison mentions it, so it cannot be placed.
  local cache="$BATS_TEST_TMPDIR/r.json"
  cat > "$cache" <<'EOF'
{"A|B":{"w":"A","at":"2026-07-01T00:00:00Z"}}
EOF
  printf '%s\n' '[{"id":"A","title":"a"},{"id":"B","title":"b"},{"id":"C","title":"c"},{"id":"D","title":"d"}]' \
    > "$BATS_TEST_TMPDIR/tickets"
  : > "$BATS_TEST_TMPDIR/empty"
  run --separate-stderr env TS_COMPARISONS_FILE="$cache" TS_INPUT="$BATS_TEST_TMPDIR/empty" \
    bash "$TS" report < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  [[ "$output" == *"·"* ]]
}

@test "report respects --top" {
  local cache="$BATS_TEST_TMPDIR/r.json"
  cat > "$cache" <<'EOF'
{"A|B":{"w":"A","at":"2026-07-01T00:00:00Z"},
 "B|C":{"w":"B","at":"2026-07-01T00:00:00Z"}}
EOF
  printf '%s\n' '[{"id":"A","title":"a"},{"id":"B","title":"b"},{"id":"C","title":"c"}]' \
    > "$BATS_TEST_TMPDIR/tickets"
  : > "$BATS_TEST_TMPDIR/empty"
  run --separate-stderr env TS_COMPARISONS_FILE="$cache" TS_INPUT="$BATS_TEST_TMPDIR/empty" \
    bash "$TS" report --top 2 < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  [ "$(grep -c . <<< "$output")" -eq 2 ]
}

@test "report writes nothing to the store" {
  local cache="$BATS_TEST_TMPDIR/r.json"
  cat > "$cache" <<'EOF'
{"A|B":{"w":"A","at":"2026-07-01T00:00:00Z"}}
EOF
  local before
  before=$(cat "$cache")
  printf '%s\n' '[{"id":"A","title":"a"},{"id":"B","title":"b"}]' \
    > "$BATS_TEST_TMPDIR/tickets"
  : > "$BATS_TEST_TMPDIR/empty"
  run env TS_COMPARISONS_FILE="$cache" TS_INPUT="$BATS_TEST_TMPDIR/empty" \
    bash "$TS" report < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  [ "$(cat "$cache")" = "$before" ]
}

@test "report emits JSON with --json" {
  local cache="$BATS_TEST_TMPDIR/r.json"
  cat > "$cache" <<'EOF'
{"A|B":{"w":"A","at":"2026-07-01T00:00:00Z"}}
EOF
  printf '%s\n' '[{"id":"A","title":"a"},{"id":"B","title":"b"}]' \
    > "$BATS_TEST_TMPDIR/tickets"
  : > "$BATS_TEST_TMPDIR/empty"
  run --separate-stderr env TS_COMPARISONS_FILE="$cache" TS_INPUT="$BATS_TEST_TMPDIR/empty" \
    bash "$TS" report --json < "$BATS_TEST_TMPDIR/tickets"
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<< "$output")" -eq 2 ]
  [ "$(jq -r '.[0].id' <<< "$output")" = "A" ]
}

@test "show without --top is just a longer ranked list" {
  three_tickets
  run --separate-stderr run_sort $'1\n1\n1\n1\n1\n1' --show 3
  [ "$status" -eq 0 ]
  [ "$(grep -cE '^ *[0-9]+\.' <<< "$output")" -eq 3 ]
}

@test "--top with --json emits only the ranked head" {
  three_tickets
  run --separate-stderr run_sort $'1\n1\n1\n1\n1' --top 1 --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1' > /dev/null
  echo "$output" | jq -e '.[0].rank == 1' > /dev/null
}

@test "--top larger than the list falls back to a full ranking" {
  three_tickets
  run --separate-stderr run_sort $'1\n1\n1\n1\n1' --top 99
  [ "$status" -eq 0 ]
  [ "$(grep -c . <<< "$output")" -eq 3 ]
}

@test "--top rejects a non-positive count" {
  three_tickets
  run --separate-stderr run_sort $'1' --top 0
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"--top"* ]]
}

@test "--top never asks the same question twice" {
  cat > "$BATS_TEST_TMPDIR/tickets" <<'EOF'
{"id":"A","title":"alpha"}
{"id":"B","title":"bravo"}
{"id":"C","title":"charlie"}
{"id":"D","title":"delta"}
{"id":"E","title":"echo"}
{"id":"F","title":"foxtrot"}
EOF
  # Only as many answers as there are distinct pairs; a repeated question
  # would run the input dry and abort.
  run --separate-stderr run_sort "$(printf '1\n%.0s' {1..15})" --top 3
  [ "$status" -eq 0 ]
  [ "$(grep -c . <<< "$output")" -eq 3 ]
}

@test "single ticket needs no comparisons" {
  echo '{"id":"A","title":"alpha"}' > "$BATS_TEST_TMPDIR/tickets"
  run --separate-stderr run_sort ''
  [ "$status" -eq 0 ]
  [[ "$output" == *"A"* ]]
}
