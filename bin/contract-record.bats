#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for bin/contract-record.
#
# claude-contract.bats calls this from teardown(), once per test, to turn a
# test result into a durable row. The point is the distinction the old
# docs/verified-against file could not make: a suite that ran green because
# twenty-one of its tests SKIPPED is not the same as one that confirmed them,
# and both used to write the same single version string.
#
# Two hard rules, both about never breaking what calls it:
#   - it always exits 0. It runs inside a bats teardown, and a teardown that
#     fails marks the test failed. A recording bug must never invent a
#     contract failure.
#   - anything it cannot parse is dropped silently. The suite has helper
#     tests with no assumption ID; they are not contract rows.

REC="$BATS_TEST_DIRNAME/contract-record"

setup() {
  export AGENT_RIG_CONTRACT_RESULTS="$BATS_TEST_TMPDIR/results.tsv"
}

# --- the happy path ------------------------------------------------------

@test "records a pass as a row keyed by the assumption ID" {
  run "$REC" "A1: the uds-messaging subsystem still exists" pass 2.1.251
  [ "$status" -eq 0 ]

  run cat "$AGENT_RIG_CONTRACT_RESULTS"
  [[ "$output" == "A1"$'\t'"pass"$'\t'"2.1.251"$'\t'* ]]
}

@test "records a skip as skip, not as a pass" {
  "$REC" "R2: live sessions on the installed build get inboxes" skip 2.1.251

  run cat "$AGENT_RIG_CONTRACT_RESULTS"
  [[ "$output" == "R2"$'\t'"skip"* ]] || false
  [[ "$output" != *"pass"* ]]
}

@test "records a failure" {
  "$REC" "B3: records carry pid, sessionId, cwd" fail 2.1.251

  run cat "$AGENT_RIG_CONTRACT_RESULTS"
  [[ "$output" == "B3"$'\t'"fail"* ]]
}

@test "stamps each row with an epoch timestamp" {
  "$REC" "A1: whatever" pass 2.1.251

  run cut -f4 "$AGENT_RIG_CONTRACT_RESULTS"
  [[ "$output" =~ ^[0-9]{10}$ ]]
}

@test "appends rather than truncating, so runs accumulate" {
  "$REC" "A1: whatever" pass 2.1.226
  "$REC" "A1: whatever" fail 2.1.251

  run wc -l < "$AGENT_RIG_CONTRACT_RESULTS"
  [ "${output// /}" -eq 2 ]
}

@test "creates the results file and its directory when absent" {
  export AGENT_RIG_CONTRACT_RESULTS="$BATS_TEST_TMPDIR/nested/deeper/results.tsv"

  run "$REC" "A1: whatever" pass 2.1.251
  [ "$status" -eq 0 ]
  [ -f "$AGENT_RIG_CONTRACT_RESULTS" ]
}

# --- ID extraction -------------------------------------------------------

@test "takes the ID from the description prefix, before the colon" {
  "$REC" "C12: transcript lines are JSON objects" pass 2.1.251

  run cut -f1 "$AGENT_RIG_CONTRACT_RESULTS"
  [ "$output" = "C12" ]
}

@test "drops a description with no assumption ID" {
  run "$REC" "assert_anchor reports a miss loudly" pass 2.1.251
  [ "$status" -eq 0 ]
  [ ! -s "$AGENT_RIG_CONTRACT_RESULTS" ]
}

@test "drops a lowercase prefix — assumption IDs are uppercase" {
  run "$REC" "a1: not a real assumption" pass 2.1.251
  [ "$status" -eq 0 ]
  [ ! -s "$AGENT_RIG_CONTRACT_RESULTS" ]
}

@test "drops a prefix with no digits" {
  run "$REC" "NOTE: this is prose, not an assumption" pass 2.1.251
  [ "$status" -eq 0 ]
  [ ! -s "$AGENT_RIG_CONTRACT_RESULTS" ]
}

# --- never break the caller ----------------------------------------------

@test "exits 0 and writes nothing on an unknown status" {
  run "$REC" "A1: whatever" exploded 2.1.251
  [ "$status" -eq 0 ]
  [ ! -s "$AGENT_RIG_CONTRACT_RESULTS" ]
}

@test "exits 0 and writes nothing when called with no arguments" {
  run "$REC"
  [ "$status" -eq 0 ]
  [ ! -s "$AGENT_RIG_CONTRACT_RESULTS" ]
}

@test "exits 0 when the version is unresolvable, recording it as unknown" {
  run "$REC" "A1: whatever" pass ""
  [ "$status" -eq 0 ]

  run cut -f3 "$AGENT_RIG_CONTRACT_RESULTS"
  [ "$output" = "unknown" ]
}

@test "exits 0 when the results path is unwritable" {
  export AGENT_RIG_CONTRACT_RESULTS="/dev/null/impossible/results.tsv"

  run "$REC" "A1: whatever" pass 2.1.251
  [ "$status" -eq 0 ]
}
