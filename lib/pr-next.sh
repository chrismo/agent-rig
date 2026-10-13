# What to do next on a branch, from its pr-state JSON. Source it after
# lib/pr-config.sh; needs bash 5 and SuperDB.
#
# A step is {key, who, say, cmd}. who is who does it once it's automated:
#   you    chrismo's judgment     agent  a model step
#   run    mechanical             wait   nothing to do yet
# cmd is what to run by hand meanwhile (null: no command yet).
#
# See docs/pr-workflow/design.md, "Watcher" step 2 and "Ordering".

# Behind the default branch alone is no step: it moves too often to chase.
# A conflict with it is, and so is a restack after the parent merged.
# Only bot items are ever marked i, so owed_bot - info is the blocking bot count.
# null and missing fields compare as errors in SuperDB; on() and n() make them false and 0.
PRN_QUERY='fn on(x): coalesce(x, false)
fn n(x): coalesce(x, 0)
fn plural(k, w): f"{k} {w}{k == 1 ? "" : "s"}"
fn step(key, who, say, cmd): {key: key, who: who, say: say, cmd: cmd}
fn covers(p): on(p.status in ["covered", "rewritten-same"])
fn trails(p): on(p.status in ["uncovered", "rewritten-changed", "unknown"])
values {...s, remote}
| put open:=(pr is null or on(pr.state == "OPEN")), has_pr:=on(pr.state == "OPEN"),
      foreign:=(on(push.remote_ours == false) and n(push.behind) > 0),
      bot_blocking:=(n(threads.owed_bot) - n(threads.info)),
      to_push:=(push.remote_sha is null or n(push.ahead) > 0),
      chase:=(on(sync.target != sync.default) or on(parent.merged)),
      restack:=(sync.old_base is null ? f"git rebase {remote}/{sync.target}"
                : f"git rebase --onto {remote}/{sync.target} {sync.old_base[0:12]}"),
      need_review:=((trails(review.local) or trails(review.bot) or trails(review.accepted))
                    and not (covers(review.local) or covers(review.bot) or covers(review.accepted)))
| unnest [
    on(pr.state == "MERGED") ? step("merged", "you", "merged: remove this worktree", null) : null,
    on(pr.state == "CLOSED") ? step("closed", "you", "PR closed without merging", null) : null,
    open and len(errors) > 0
      ? step("errors", "you", f"{plural(len(errors), "error")}: the steps below may be wrong", "pr-state --json") : null,
    open and on(fresh == false)
      ? step("stale", "run", "fetch: GitHub is ahead of your remote refs", f"git fetch --prune {remote}") : null,
    open and foreign
      ? step("foreign", "you", f"{remote}/{branch} has {plural(push.behind, "commit")} that aren'"'"'t yours",
             f"git log HEAD..{remote}/{branch}") : null,
    open and n(threads.owed_human) > 0
      ? step("human", "you", f"reply to {plural(threads.owed_human, "human item")}", "pr-state --long") : null,
    open and on(sync.up_to_date == false) and on(sync.conflict)
      ? step("conflict", "agent", f"restack onto {sync.target} conflicts: resolve it", restack) : null,
    open and on(sync.up_to_date == false) and not on(sync.conflict) and chase
      ? step("behind", "run", f"restack onto {sync.target} ({sync.behind} behind)", restack) : null,
    has_pr and on(ci.verdict == "red")
      ? step("ci-red", "agent", f"fix CI: {join(ci.failing, ", ")}", "gh pr checks") : null,
    open and bot_blocking > 0
      ? step("bot", "agent", f"address {plural(threads.owed_bot, "bot item")}", "pr-act address") : null,
    open and bot_blocking == 0 and n(threads.info) > 0
      ? step("read", "you", f"read {plural(threads.info, "bot item")} in pr-state --long, then ack", "pr-act ack") : null,
    open and not foreign and to_push
      ? (push.remote_sha is null ? step("push", "run", f"push: not on {remote} yet", f"git push -u {remote} {branch}")
         : on(push.diverged) ? step("push", "run", f"force-push {plural(push.ahead, "commit")} (rewritten)", "git push --force-with-lease")
         : step("push", "run", f"push {plural(push.ahead, "commit")}", "git push")) : null,
    pr is null and threads.blocking is not null ? step("open-pr", "you", "open a PR", "gh pr create") : null,
    has_pr and on(pr.draft) ? step("draft", "you", "mark the PR ready for review", "gh pr ready") : null,
    open and need_review ? step("review", "agent", "review the changes since the last review", null) : null,
    has_pr and on(ci.verdict == "inconclusive") ? step("ci-rerun", "run", "rerun cancelled CI", "gh pr checks") : null,
    has_pr and not to_push and (on(ci.verdict == "pending") or on(ci.for_head == false))
      ? step("ci-wait", "wait", on(ci.verdict == "pending") ? "CI running" : "CI hasn'"'"'t reported on HEAD yet",
             "gh pr checks --watch") : null,
    has_pr ? step("ready", "you", "ready to merge", "gh pr merge") : null
  ]
| where this is not null
| aggregate steps:=collect(this)
| values coalesce(steps, [])
| values (len(this) > 1 and this[len(this)-1].key == "ready") ? this[0:len(this)-1] : this'

# prn_next <remote>: pr-state JSON on stdin; prints the steps as a JSON array, first is next.
prn_next() {
  local state remote kind
  state=$(cat)
  remote=$(prc_json_string "$1") || return
  kind=$(printf '%s\n' "$state" | prc_super -i json -f line -c 'values kind(this)' -) || return
  [[ $kind == record ]] || { echo "pr-next: pr-state JSON must be one record" >&2; return 1; }
  printf '{"remote":%s,"s":%s}\n' "$remote" "$state" | prc_super -i json -j -c "$PRN_QUERY" -
}

# prn_lines [one|all]: steps on stdin; one adds a count of the rest, all lists them as "then".
prn_lines() {
  local mode=${1:-one} out more=""
  local -a ls
  out=$(prc_super -i json -f line -c 'unnest this
    | values f"{who}{"     "[0:5-len(who)]}  {say}{cmd is null ? "" : f"  → {cmd}"}"' -) || return
  [[ -n $out ]] || return 0
  mapfile -t ls <<<"$out"
  if [[ $mode == all ]]; then
    printf 'NEXT  %s\n' "${ls[0]}"
    (( ${#ls[@]} == 1 )) || printf 'then  %s\n' "${ls[@]:1}"
  else
    (( ${#ls[@]} == 1 )) || more="  (+$(( ${#ls[@]} - 1 )) more)"
    printf 'NEXT  %s%s\n' "${ls[0]}" "$more"
  fi
}
