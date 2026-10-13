#!/usr/bin/env bats

# Test suite for lib/pr-next.sh: pr-state JSON in, the ordered next steps out.
# Pure policy, so no git or gh: each test edits a "ready to merge" state.
#
# Needs bash 5 first on PATH (the lib is sourced):
#   PATH="/opt/homebrew/opt/bash/bin:$PATH" bats lib/pr-next.bats

setup() {
  source "$BATS_TEST_DIRNAME/pr-config.sh"
  source "$BATS_TEST_DIRNAME/pr-next.sh"
  READY='{"branch": "feat", "head": "h1",
    "pr": {"number": 7, "url": "u", "state": "OPEN", "draft": false, "base": "main", "head_sha": "h1", "mergeable": "MERGEABLE",
           "merge_state": "CLEAN", "review_decision": null, "review_requests": []},
    "parent": {"name": "main", "source": "pr", "merged": false, "pr": null},
    "sync": {"target": "main", "default": "main", "behind": 0, "up_to_date": true, "old_base": "b0b0b0b0b0b0b0b0", "conflict": false},
    "push": {"remote_sha": "h1", "ahead": 0, "behind": 0, "diverged": false, "remote_ours": true},
    "fresh": true, "stale": [],
    "ci": {"sha": "h1", "for_head": true, "verdict": "green", "failing": [], "pending": []},
    "review": {"local": {"sha": "h1", "status": "covered"}, "bot": {"sha": null, "status": "none"},
               "accepted": {"sha": null, "status": "none"}},
    "threads": {"owed_bot": 0, "owed_human": 0, "outdated": 0, "blocking": 0, "info": 0, "items": []},
    "session": {"enrolled": true, "harness": null, "id": null, "locked": false},
    "errors": []}'
}

# next <jq-assignment...>: the next steps for READY with the edits applied.
next() {
  local s=$READY a
  for a; do s=$(jq -c "$a" <<<"$s"); done
  printf '%s\n' "$s" | prn_next origin
}
keys() { next "$@" | jq -r '[.[].key] | join(" ")'; }
step() { # step <key> <field> <jq-assignment...>
  local k=$1 f=$2; shift 2
  next "$@" | jq -r --arg k "$k" ".[] | select(.key == \$k) | .$f"
}

@test "ready: the only step is to merge, by chrismo" {
  [ "$(keys)" = ready ]
  [ "$(step ready who)" = you ]
  [ "$(step ready cmd)" = "gh pr merge" ]
}

@test "ready: only when GitHub would merge it (clean, unstable or has hooks)" {
  [ "$(keys '.pr.merge_state = "UNSTABLE"')" = ready ]
  [ "$(keys '.pr.merge_state = "HAS_HOOKS"')" = ready ]
  [ "$(keys '.pr.merge_state = "BLOCKED"')" = blocked ]
  [ "$(keys '.pr.merge_state = "UNKNOWN"')" = merge-wait ]
  [ "$(keys 'del(.pr.merge_state)')" = merge-wait ]
}

@test "review required: wait on the requested reviewers, never ready" {
  local req=('.pr.merge_state = "BLOCKED"' '.pr.review_decision = "REVIEW_REQUIRED"')
  [ "$(keys "${req[@]}" '.pr.review_requests = ["alice", "core-team"]')" = review-wait ]
  [ "$(step review-wait who "${req[@]}")" = wait ]
  [ "$(step review-wait say "${req[@]}" '.pr.review_requests = ["alice", "core-team"]')" \
    = "waiting on review from alice, core-team" ]
  [ "$(step review-wait say "${req[@]}")" = "waiting on a required review" ]
}

@test "review required stays listed behind other steps; ready-like ends don't" {
  [ "$(keys '.ci.verdict = "pending"' '.pr.merge_state = "BLOCKED"' '.pr.review_decision = "REVIEW_REQUIRED"')" \
    = "ci-wait review-wait" ]
  [ "$(keys '.ci.verdict = "pending"' '.pr.merge_state = "BLOCKED"')" = ci-wait ]
  [ "$(keys '.ci.verdict = "pending"' '.pr.merge_state = "UNKNOWN"')" = ci-wait ]
}

@test "blocked for another reason: chrismo looks on GitHub" {
  [ "$(step blocked who '.pr.merge_state = "BLOCKED"' '.pr.review_decision = "APPROVED"')" = you ]
  [ "$(step blocked say '.pr.merge_state = "BLOCKED"')" = "GitHub says the merge is blocked: see why" ]
  [ "$(step blocked say '.pr.merge_state = "BEHIND"')" = "GitHub says the branch is behind: see why" ]
  [ "$(step blocked cmd '.pr.merge_state = "BLOCKED"')" = "gh pr view --web" ]
}

@test "every step has key, who, say and cmd" {
  run next '.push.ahead = 2' '.threads.owed_bot = 1' '.ci.verdict = "pending"'
  [ "$status" -eq 0 ]
  [ "$(jq '[.[] | keys == ["cmd", "key", "say", "who"]] | all' <<<"$output")" = true ]
  [ "$(jq '[.[].who | IN("you", "agent", "run", "wait")] | all' <<<"$output")" = true ]
}

@test "merged: only the cleanup step, whatever else is true" {
  [ "$(keys '.pr.state = "MERGED"' '.push.ahead = 3' '.ci.verdict = "red"' '.errors = ["x"]')" = merged ]
}

@test "closed: only the closed step" {
  [ "$(keys '.pr.state = "CLOSED"' '.threads.owed_bot = 2')" = closed ]
}

@test "errors come first and point at --json" {
  [ "$(keys '.errors = ["gh: boom"]' '.push.ahead = 1')" = "errors push" ]
  [ "$(step errors say '.errors = ["a", "b"]')" = "2 errors: the steps below may be wrong" ]
  [ "$(step errors cmd '.errors = ["a"]')" = "pr-state --json" ]
}

@test "stale refs: fetch, mechanically" {
  [ "$(step stale who '.fresh = false')" = run ]
  [ "$(step stale cmd '.fresh = false')" = "git fetch --prune origin" ]
  [ "$(step stale say '.fresh = false')" = "fetch: GitHub is ahead of your remote refs, so the steps below may be wrong" ]
}

@test "a push that isn't ours: chrismo looks, and no push is suggested" {
  [ "$(keys '.push.remote_ours = false' '.push.behind = 2' '.push.ahead = 1' '.push.diverged = true')" = foreign ]
  [ "$(step foreign cmd '.push.remote_ours = false' '.push.behind = 2')" = "git log HEAD..origin/feat" ]
  [ "$(step foreign say '.push.remote_ours = false' '.push.behind = 2')" = "origin/feat has 2 commits that aren't yours" ]
  [ "$(step foreign say '.push.remote_ours = false' '.push.behind = 1')" = "origin/feat has 1 commit that isn't yours" ]
}

@test "human items: chrismo replies, via the --long list" {
  [ "$(step human who '.threads.owed_human = 2')" = you ]
  [ "$(step human say '.threads.owed_human = 2')" = "reply to 2 human items" ]
  [ "$(step human say '.threads.owed_human = 1')" = "reply to 1 human item" ]
  [ "$(step human cmd '.threads.owed_human = 1')" = "pr-state --long" ]
}

# A stacked branch: its parent is another branch, not the default.
STACKED=('.parent.name = "base"' '.sync.target = "base"' '.sync.up_to_date = false' '.sync.behind = 3')

@test "behind a stacked parent: restack onto it from the old base" {
  [ "$(step behind who "${STACKED[@]}")" = run ]
  [ "$(step behind say "${STACKED[@]}")" = "restack onto base (3 behind)" ]
  [ "$(step behind cmd "${STACKED[@]}")" = "git rebase --onto origin/base b0b0b0b0b0b0" ]
}

@test "behind with no old base: a plain rebase" {
  [ "$(step behind cmd "${STACKED[@]}" '.sync.old_base = null')" = "git rebase origin/base" ]
}

@test "only behind the default branch: no step; main moves too often to chase" {
  [ "$(keys '.sync.up_to_date = false' '.sync.behind = 40')" = ready ]
}

@test "behind the default branch with a conflict: the agent resolves it" {
  [ "$(keys '.sync.up_to_date = false' '.sync.behind = 40' '.sync.conflict = true')" = conflict ]
}

@test "parent merged, retargeted to the default branch: restack" {
  [ "$(keys '.parent.name = "base"' '.parent.merged = true' '.sync.up_to_date = false' '.sync.behind = 2')" = behind ]
}

@test "a conflicting restack is the agent's, instead of a plain restack" {
  [ "$(keys "${STACKED[@]}" '.sync.conflict = true')" = conflict ]
  [ "$(step conflict who "${STACKED[@]}" '.sync.conflict = true')" = agent ]
}

@test "red CI: the agent fixes it; names the failing checks" {
  [ "$(step ci-red who '.ci.verdict = "red"' '.ci.failing = ["lint", "test"]')" = agent ]
  [ "$(step ci-red say '.ci.verdict = "red"' '.ci.failing = ["lint", "test"]')" = "fix CI: lint, test" ]
}

@test "bot items: pr-act address" {
  [ "$(step bot who '.threads.owed_bot = 3')" = agent ]
  [ "$(step bot say '.threads.owed_bot = 3')" = "address 3 bot items" ]
  [ "$(step bot cmd '.threads.owed_bot = 3')" = "pr-act address" ]
}

@test "bot items that are only info: chrismo reads them, then acks" {
  [ "$(keys '.threads.owed_bot = 2' '.threads.info = 2')" = read ]
  [ "$(step read who '.threads.owed_bot = 2' '.threads.info = 2')" = you ]
  [ "$(step read say '.threads.owed_bot = 2' '.threads.info = 2')" = "read 2 bot items in pr-state --long, then ack" ]
  [ "$(step read cmd '.threads.owed_bot = 2' '.threads.info = 2')" = "pr-act ack" ]
}

@test "blocking and info bot items together: address takes them all" {
  [ "$(keys '.threads.owed_bot = 3' '.threads.info = 1')" = bot ]
  [ "$(step bot say '.threads.owed_bot = 3' '.threads.info = 1')" = "address 3 bot items" ]
}

@test "unpushed commits: push" {
  [ "$(step push say '.push.ahead = 2')" = "push 2 commits" ]
  [ "$(step push cmd '.push.ahead = 2')" = "git push" ]
}

@test "rewritten history of our own: force-push with lease" {
  [ "$(step push cmd '.push.ahead = 2' '.push.behind = 2' '.push.diverged = true')" = "git push --force-with-lease" ]
}

@test "never pushed: push and set upstream" {
  [ "$(step push cmd '.push.remote_sha = null' '.push.ahead = 1' '.pr = null')" = "git push -u origin feat" ]
}

@test "no PR: push first, then open one" {
  [ "$(keys '.pr = null' '.push.remote_sha = null' '.push.ahead = 1')" = "push open-pr" ]
  [ "$(step open-pr cmd '.pr = null')" = "gh pr create" ]
}

@test "no PR because gh failed: don't suggest opening one" {
  [ "$(keys '.pr = null' '.threads.blocking = null' '.errors = ["gh: boom"]')" = errors ]
}

@test "draft: mark it ready" {
  [ "$(step draft cmd '.pr.draft = true')" = "gh pr ready" ]
}

@test "review behind HEAD: local review by the agent" {
  [ "$(step review who '.review.local = {sha: "x", status: "uncovered", uncovered: 2}')" = agent ]
  [ "$(keys '.review.local = {sha: "x", status: "rewritten-changed"}')" = review ]
  [ "$(keys '.review.local = {sha: "x", status: "unknown"}')" = review ]
}

@test "review: a pin that covers HEAD means no review step" {
  [ "$(keys '.review.local = {sha: "x", status: "uncovered", uncovered: 2}' \
           '.review.accepted = {sha: "h1", status: "covered"}')" = ready ]
  [ "$(keys '.review.local = {sha: "x", status: "rewritten-same"}')" = ready ]
  [ "$(keys '.review.bot = {sha: "x", status: "uncovered", uncovered: 2}')" = ready ]
}

@test "inconclusive CI: rerun it" {
  [ "$(step ci-rerun who '.ci.verdict = "inconclusive"')" = run ]
}

@test "CI pending or not yet on HEAD: wait" {
  [ "$(step ci-wait who '.ci.verdict = "pending"')" = wait ]
  [ "$(keys '.ci.verdict = "pending"')" = ci-wait ]
  [ "$(keys '.ci.for_head = false')" = ci-wait ]
}

@test "unpushed commits: push, not wait for CI that can't run yet" {
  [ "$(keys '.push.ahead = 1' '.ci.for_head = false')" = push ]
  [ "$(keys '.push.ahead = 1' '.ci.verdict = "pending"')" = push ]
}

@test "no PR: no CI wait" {
  [ "$(keys '.pr = null' '.ci.for_head = null' '.ci.verdict = "none"')" = open-pr ]
}

@test "order follows design.md's Ordering: restack, agent fixes, push, then waiting" {
  [ "$(keys '.fresh = false' '.threads.owed_human = 1' "${STACKED[@]}" \
           '.ci.verdict = "red"' '.threads.owed_bot = 1' '.push.ahead = 1' '.pr.draft = true' \
           '.review.local = {sha: "x", status: "uncovered", uncovered: 1}')" \
    = "stale human behind ci-red bot push draft review" ]
}

@test "a state that isn't a record fails" {
  run bash -c 'source "$1/pr-config.sh"; source "$1/pr-next.sh"; echo "[]" | prn_next origin' _ "$BATS_TEST_DIRNAME"
  [ "$status" -ne 0 ]
}

@test "the remote and branch reach commands as data" {
  [ "$(printf '%s\n' "$READY" | jq -c '.push.remote_sha = null | .push.ahead = 1 | .branch = "a\"b"' \
        | prn_next 'up"x' | jq -r '.[] | select(.key == "push") | .cmd')" = 'git push -u up"x a"b' ]
}

# ── prn_lines: the NEXT line(s) ──────────────────────────────────────────────

lines_for() { # lines_for <one|all> <jq-assignment...>
  local mode=$1; shift
  next "$@" | prn_lines "$mode"
}

@test "lines: one NEXT line with who, say, command and a count of the rest" {
  run lines_for one '.push.ahead = 1' '.threads.owed_bot = 1'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$output" = "NEXT  agent  address 1 bot item  → pr-act address  (+1 more)" ]
}

@test "lines: a step with no command has no arrow" {
  run lines_for one '.pr.state = "MERGED"'
  [ "$output" = "NEXT  you    merged: remove this worktree" ]
}

@test "lines: all lists every step, the rest as then" {
  run lines_for all '.push.ahead = 1' '.threads.owed_bot = 1'
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "NEXT  agent  address 1 bot item  → pr-act address" ]
  [ "${lines[1]}" = "then  run    push 1 commit  → git push" ]
}
