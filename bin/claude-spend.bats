#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for bin/claude-spend.
#
# `.spend` is the usage-credits block, not "current usage". On an account with
# credits enabled it carries a money limit; on an individual plan `limit`, `cap`
# and `balance` are all null and there is no dollar figure anywhere in the
# response. Both shapes have to produce a sane answer, and neither may be
# confused with an actual failure.

S="$BATS_TEST_DIRNAME/claude-spend"

setup() {
  export AGENT_RIG_SPEND_JSON="$BATS_TEST_TMPDIR/usage.json"
  export AGENT_RIG_SPEND_CACHE="$BATS_TEST_TMPDIR/cache.json"
}

# Age a file past any plausible TTL.
stale() { touch -t 200001010000 "$1"; }

# The real payload from an individual Max plan, trimmed to the keys that matter.
individual_plan() {
  cat > "$AGENT_RIG_SPEND_JSON" <<'JSON'
{
  "five_hour": { "utilization": 5.0, "limit_dollars": null, "used_dollars": null },
  "seven_day": { "utilization": 8.0, "limit_dollars": null, "used_dollars": null },
  "extra_usage": { "is_enabled": false, "credits_ever_enabled": false },
  "spend": {
    "used": { "amount_minor": 0, "currency": "USD", "exponent": 2 },
    "limit": null,
    "percent": 0,
    "enabled": false,
    "cap": null,
    "balance": null,
    "can_purchase_credits": false
  },
  "member_dashboard_available": false
}
JSON
}

# Synthetic: what the shape looks like once credits carry a spend limit.
with_spend_limit() {
  local used="$1" limit="$2" percent="$3"
  cat > "$AGENT_RIG_SPEND_JSON" <<JSON
{
  "spend": {
    "used": { "amount_minor": $used, "currency": "USD", "exponent": 2 },
    "limit": { "amount_minor": $limit, "currency": "USD", "exponent": 2 },
    "percent": $percent,
    "enabled": true
  }
}
JSON
}

@test "individual plan: says so instead of crashing" {
  individual_plan
  run "$S"
  [ "$status" -eq 0 ]
  [[ "$output" != *"error("* ]]
}

@test "individual plan: names the account kind and points at the status line" {
  individual_plan
  run "$S"
  [[ "$output" == *"usage credits"* ]] || false
  [[ "$output" == *"status line"* ]]
}

@test "individual plan: reports no dollar figure it does not have" {
  individual_plan
  run "$S"
  [[ "$output" != *'$0'* ]]
}

@test "spend block absent entirely: same answer, still exit 0" {
  echo '{"five_hour":{"utilization":5.0}}' > "$AGENT_RIG_SPEND_JSON"
  run "$S"
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage credits"* ]]
}

@test "credits enabled: reports percent, used, and limit" {
  with_spend_limit 1234 5000 25
  run "$S"
  [ "$status" -eq 0 ]
  [[ "$output" == *"25%"* ]] || false
  [[ "$output" == *'$12'* ]] || false
  [[ "$output" == *'$50'* ]]
}

@test "cents round to the nearest dollar, half up" {
  with_spend_limit 1250 10000 5
  run "$S"
  [[ "$output" == *'$13'* ]] || false
  [[ "$output" == *'$100'* ]] || false
  [[ "$output" != *"."* ]]
}

@test "cents round down below the half" {
  with_spend_limit 1249 10000 5
  run "$S"
  [[ "$output" == *'$12'* ]]
}

@test "non-USD currency keeps its code instead of a dollar sign" {
  cat > "$AGENT_RIG_SPEND_JSON" <<'JSON'
{
  "spend": {
    "used": { "amount_minor": 1234, "currency": "EUR", "exponent": 2 },
    "limit": { "amount_minor": 5000, "currency": "EUR", "exponent": 2 },
    "percent": 25,
    "enabled": true
  }
}
JSON
  run "$S"
  [ "$status" -eq 0 ]
  [[ "$output" == *"12 EUR"* ]] || false
  [[ "$output" != *'$'* ]]
}

@test "a zero limit is still a limit, not an absent one" {
  with_spend_limit 0 0 0
  run "$S"
  [ "$status" -eq 0 ]
  [[ "$output" == *'$0 / $0'* ]]
}

@test "fetch failure is an error, and names the file" {
  export AGENT_RIG_SPEND_JSON="$BATS_TEST_TMPDIR/does-not-exist.json"
  run "$S"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does-not-exist.json"* ]]
}

@test "an empty response is an error, not an account diagnosis" {
  : > "$AGENT_RIG_SPEND_JSON"
  run "$S"
  [ "$status" -ne 0 ]
  [[ "$output" != *"usage credits"* ]]
}

@test "a missing super says so, instead of blaming the API" {
  individual_plan
  PATH="/usr/bin:/bin" run "$S"
  [ "$status" -ne 0 ]
  [[ "$output" == *"super"* ]]
}

@test "an ambient superdb version pin does not decide what this runs" {
  with_spend_limit 1234 5000 25
  ASDF_SUPERDB_VERSION="0.0.0-nonexistent" run "$S"
  [ "$status" -eq 0 ]
  [[ "$output" == *'$12'* ]]
}

@test "malformed response is an error, not a parser spew" {
  echo 'not json' > "$AGENT_RIG_SPEND_JSON"
  run "$S"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not read"* ]]
}


# --- cache -------------------------------------------------------------------
#
# A lot of pods run at once, and every one of them renders a status line. The
# cache is global and shared so they make one request between them, not one
# each.

@test "raw mode emits the payload for the statusline plugin to query" {
  with_spend_limit 1234 5000 25
  run "$S" --raw
  [ "$status" -eq 0 ]
  [[ "$output" == *'"amount_minor"'* ]]
}

@test "a fetch populates the cache" {
  with_spend_limit 1234 5000 25
  run "$S"
  [ -s "$AGENT_RIG_SPEND_CACHE" ]
}

@test "a fresh cache is used instead of fetching again" {
  echo '{"spend":{"used":{"amount_minor":9900,"currency":"USD","exponent":2},"limit":{"amount_minor":9900,"currency":"USD","exponent":2},"percent":99,"enabled":true}}' > "$AGENT_RIG_SPEND_CACHE"
  with_spend_limit 1234 5000 25
  run "$S"
  [[ "$output" == *'$99'* ]] || false
  [[ "$output" != *'$12'* ]]
}

@test "a stale cache is refetched" {
  echo '{"spend":{"used":{"amount_minor":9900,"currency":"USD","exponent":2},"limit":{"amount_minor":9900,"currency":"USD","exponent":2},"percent":99,"enabled":true}}' > "$AGENT_RIG_SPEND_CACHE"
  stale "$AGENT_RIG_SPEND_CACHE"
  with_spend_limit 1234 5000 25
  run "$S"
  [[ "$output" == *'$12'* ]]
}

@test "--fresh ignores a fresh cache" {
  echo '{"spend":{"used":{"amount_minor":9900,"currency":"USD","exponent":2},"limit":{"amount_minor":9900,"currency":"USD","exponent":2},"percent":99,"enabled":true}}' > "$AGENT_RIG_SPEND_CACHE"
  with_spend_limit 1234 5000 25
  run "$S" --fresh
  [[ "$output" == *'$12'* ]]
}

@test "a failed fetch does not clobber a good cache" {
  with_spend_limit 1234 5000 25
  run "$S"
  stale "$AGENT_RIG_SPEND_CACHE"
  export AGENT_RIG_SPEND_JSON="$BATS_TEST_TMPDIR/gone.json"
  run "$S"
  [ "$status" -ne 0 ]
  [ -s "$AGENT_RIG_SPEND_CACHE" ]
}
