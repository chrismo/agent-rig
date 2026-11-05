---
name: issue-upkeep
description: "Keep a repo's GitHub issues current: label the unlabeled from the repo's own label taxonomy, propose closing issues that merged PRs have finished, and report label health. Invoked as /issue-upkeep, roughly weekly or after a burst of merges."
allowed-tools: Bash, Agent
---

# issue-upkeep

Issues drift two ways: new ones get filed without labels, and finished ones
stay open because a PR did the last slice without saying `Closes #N`. The first
labelling pass in sheepdog (2026-11-04) found both: 16 of ~106 open issues were
already done, and two issues filed during the pass itself got no labels.

This skill closes both gaps. Labels are applied without asking; **closes wait
for the human's yes**, because "probably done" was right for 12 of 16 the first
time, not all of them.

## Step 0: read the taxonomy

```bash
gh label list --limit 200 --json name,description --jq '.[] | "\(.name)\t\(.description)"'
```

The repo's taxonomy is its label descriptions: each starts with its axis
(`Reach: …`, `Area: …`, `Origin: …`, `Status: …`, `Kind: …`). Then read the
repo's agent doc (AGENTS.md, else CLAUDE.md) for its "Filing issues" rules:
which axes every issue needs, and the exceptions.

If the descriptions carry no axis prefixes, the repo has no taxonomy yet. Stop
and say so: proposing one is a conversation with the human, not upkeep.

## Step 1: gaps (zero tokens)

List open issues missing a label from each required axis. Build the label
sets from Step 0; for example, with Reach and Area required:

```bash
gh issue list --state open --limit 500 --json number,title,labels --jq '
  ["happy-path","edge-case"] as $reach |
  ["engine","loop","viz","review","config","harness","stack"] as $area |
  .[] | [.labels[].name] as $l
  | select(($l - ($l - $reach) | length) == 0 or ($l - ($l - $area) | length) == 0)
  | "#\(.number) [\($l | join(","))] \(.title)"'
```

Issues the doc exempts (refactors without Reach, docs without Area) will show
up here; skip them if their existing labels already mark them so
(`arch-review`, `documentation`).

For each real gap, read the issue body and apply labels with
`gh issue edit N --add-label a,b`. Many gaps: hand the reading to one subagent
with the taxonomy and the issue numbers, and have it return a proposed table;
apply it yourself.

## Step 2: stale sweep (spends tokens)

Candidates are open issues that a PR merged since the last sweep refers to.
The last sweep's time is kept per repo; default to 14 days ago the first time:

```bash
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
state="${XDG_STATE_HOME:-$HOME/.local/state}/issue-upkeep/${repo//\//-}"
since=$(cat "$state" 2>/dev/null || date -u -v-14d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '14 days ago' +%Y-%m-%dT%H:%M:%SZ)
echo "since $since"
```

```bash
gh api graphql --paginate -F owner="${repo%/*}" -F repo="${repo#*/}" -f query='
query($owner:String!, $repo:String!, $endCursor:String) {
  repository(owner:$owner, name:$repo) {
    issues(states:OPEN, first:100, after:$endCursor) {
      pageInfo { hasNextPage endCursor }
      nodes { number title
        timelineItems(itemTypes:[CROSS_REFERENCED_EVENT], last:20) {
          nodes { ... on CrossReferencedEvent {
            source { ... on PullRequest { number merged mergedAt } } } } } } } } }' \
  --jq '.data.repository.issues.nodes[]
    | {n:.number, t:.title, prs:[.timelineItems.nodes[].source
        | select(.merged == true and .mergedAt > "'"$since"'") | .number]}
    | select(.prs | length > 0) | "#\(.n) \(.t) <- \(.prs | map("#\(.)") | join(" "))"'
```

Also check direct commits to the default branch since then that mention an
issue (docs-only work often lands without a PR). Squash merges end in
`(#PR)` and the query above already covers them, so drop those:

```bash
git fetch -q && git log origin/HEAD --since="$since" --oneline | grep -E '#[0-9]+' | grep -vE '\(#[0-9]+\)$'
```

For each candidate, compare the issue body (and its last comments) against
what the PRs actually merged. Use one subagent for more than a handful. Sort
each into:

- **Done**: everything the issue asks for has merged.
- **Mostly done**: a small, separable piece is left. Propose filing the piece
  as its own issue (labelled, plus `follow-up` if the repo has it) and closing
  the original.
- **Not done**: say nothing about it.

Show the human the Done and Mostly-done lists, one line each with the PR that
finished it. After the yes, close each with a comment naming what finished it
and where any leftover went. Then record the sweep:

```bash
mkdir -p "$(dirname "$state")" && date -u +%Y-%m-%dT%H:%M:%SZ > "$state"
```

Record the sweep only after it finishes; an abandoned sweep leaves `since`
where it was, so the next run sees the same PRs.

## Step 3: label health (zero tokens)

```bash
gh issue list --state open --limit 500 --json labels --jq '[.[].labels[].name] | group_by(.) | map("\(length)\t\(.[0])") | .[]' | sort -rn
```

Report, in a line each, only what's off:

- a label with 0 open issues (retire it?)
- a label on more than half the open issues (too broad to filter by?)
- a label with no axis prefix (a GitHub default crept back, or someone added
  one ad hoc): suggest an axis or deletion
- `needs-decision` issues, by number and name: these wait on the human

## Report

Short. A table of labels applied, the close proposals, and the health lines.
Nothing else unless something was odd.
