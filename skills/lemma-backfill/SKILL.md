---
name: lemma-backfill
description: "Mine reasoning out of git history into lemmalog and let the engine validate it — assert chronologically with commit timestamps so supersession resolves itself, and surface only the engine's genuine escalations. Scoped to a path or subsystem when given one; with no scope, measure the repo and ask chrismo what to cover. Invoked as /lemma-backfill."
allowed-tools: Bash, Read
---

# lemma-backfill

`hooks/lemma-commit.sh` only ever sees commits made after it was installed.
Everything decided before that is in the repo, in commit bodies, unreachable by
anything but reading. This reaches back for it.

Named backfill and not init because it is not one-time setup: it is repeatable,
worth scoping, and the most useful moment to run it is when you are about to
work on something and want to know what was already decided about it.

    /lemma-backfill                 measure first, then ask
    /lemma-backfill tf/             scoped to a path
    /lemma-backfill "the runner"    scoped to a subsystem

## Let the engine validate — do not hand-verify

The obvious failure of a backfill is asserting something that was true when
written and is false now. The obvious fix — check every claim against the
current tree — is slow, and it is the wrong fix. **The engine already does this,
deterministically, and it is why supersession is worth asserting rather than
skipping.**

`lemmalog_observe` accepts a `ts`. Assert in commit order with each commit's own
timestamp and the update policy decides:

| situation | engine does |
|---|---|
| no open value for (subject, predicate) | ADD |
| same value re-observed | NOOP — annotations merge |
| different value, predicate `exclusive` | **UPDATE** — closes the old interval |
| different value, predicate not exclusive | ADD + **escalation** |

Verified against this repo's real `tmp/` reversal:

    observe "agent-rig --commit_msg_location--> repo-level-tmp"  ts=1775440109  -> added=1
    observe "agent-rig --commit_msg_location--> dot-claude-tmp"  ts=1775828224  -> updated=1
    query   current("agent-rig","commit_msg_location",O)         -> O=dot-claude-tmp

Two commits eight months apart, the second reversing the first, resolved with no
human in the loop. The superseded fact is interval-closed, not deleted, so
`why()` still traces the history.

**So assert superseded decisions too.** An earlier version of this skill dropped
a three-commit chain (heredocs ruled out, then `-m` flags ruled out) because the
guidance is now inert. That was wrong: asserted chronologically, the chain
*becomes* the record of how the answer moved, and `current()` returns only the
end state. The supersession is the information.

## Declare exclusivity first, or nothing supersedes

Exclusivity is itself a fact the engine queries. The default table is only
`exclusive("works_at")`, so **install one before asserting anything** or every
reversal escalates instead of superseding:

    lemmalog_install_rules, id "backfill-vocab":
      exclusive("approach").      # the current way a thing is done
      exclusive("pins").          # a pinned version
      exclusive("location").      # where something lives
      exclusive("status").

Use those for anything where a later commit *replaces* an earlier answer.

## Escalation noise, and which ones to surface

There is no "multi-valued" declaration — only `exclusive`. So a predicate that
legitimately holds many values escalates on every value after the first:

    observe two depends_on values -> added=2 escalations=1
      "conflict: agent-rig --depends_on--> bats asserted in ep3,
       but depends_on also open (superdb)"

That is a false positive; agent-rig depends on both. The fact is still added —
escalation is advisory, never a rejection.

**Expected-multi predicates** — `ruled_out`, `because`, `requires`, `constrains`,
`depends_on`, `located`, `in_repo`. Escalations naming these are noise. **Filter
them and do not show chrismo.** (`located` earns its place the hard way: a
backfill run escalated on it immediately, because an entity is naturally located
in many commits over its life.)

Surface an escalation only when it names a predicate you expected to be
single-valued and did not declare exclusive. That is a genuine modelling
mistake, and it is the one thing worth a question.

## With no scope: measure, then ask

Do **not** start sweeping. Run the numbers and put the choice to chrismo:

    git rev-list --count HEAD
    git log -i --format='%h %ad %s' --date=short \
      --grep='ruled out' --grep='rejected' --grep='rather than' \
      --grep='instead of' --grep='abandoned' --grep='turned out' \
      --grep='measured' --grep='does not work' | wc -l

Real spread across chrismo's repos, so you know what to expect:

| repo | commits | candidates |
|---|---|---|
| `clabs` | 293 over 13 years | 1 |
| `clwiki` | 213 over 14 years | 3 |
| `brain` | 945 over 9 years | 37 |
| `agent-rig` | 202 | 71 |
| `questor` | 1508 | 220 |

**Age is not the variable; prose density is.** Old repos self-limit — terse
commit messages do not match the grep. The repos that blow up are recent ones,
from the era where commit bodies got long. A 14-year-old repo is the easy case.

Under ~20 candidates: offer to do all of it. More: say the number and offer
scopes — a path, a subsystem, the last N months. A full sweep is chrismo's call
to make knowingly, not your default. Reading is cheap (all 220 questor
candidates are ~85K tokens); it is chrismo's attention that is not.

## Entity names are tokens, not prose — the engine drops the rest

`observe` validates every entity token and **silently drops the lines that
fail**, reporting them but asserting nothing. From `src/agent.rs`: at most 60
characters, at most 8 words, and only letters, digits, `_`, `-`, `'` and spaces.

So this is rejected:

    heredocs --because--> "cascading denial: heredoc, then /tmp, then echo redirect, each blocked by a different rule"
      -> looks like prose (more than 8 words)
    commit-message-mechanism --located--> "agent-rig@bc0e867"
      -> contains punctuation ('@')

and this is the same content, asserted:

    heredocs --because--> cascading-tool-denials
    commit-message-mechanism --located--> agent-rig-bc0e867

**Provenance is `repo-sha`, never `repo@sha`.** Reasons are short kebab-case
entities, not sentences — the sentence lives in the commit, which `located`
points at. Read the `dropped N line(s)` report after every observe; a dropped
line is a fact you think you asserted and did not.

## Mine commit bodies, not docs

Not `docs/`, not `CLAUDE.md`, not READMEs, however much richer they look. A
commit body is *evidence*: a decision someone made, datable, anchorable to a sha.
A doc is a *claim* that may have been stale for a year with nothing to reveal it.
Same split as `bin/contract-record` and `bin/lemma-queue` — exact rows in,
judgement after.

## The bar

Inherited from `/lemma-drain`:

> conclusions, decisions and state changes land in the engine; activity does not

Highest value first: a decision that **rejected** an alternative; a constraint
found the hard way; a load-bearing assumption about something outside your
control; an approach abandoned after real effort. Skip routine fixes, refactors,
dependency bumps, and anything the diff already explains.

The bar still matters even though the engine handles staleness — supersession
solves *wrong*, not *worthless*. A store whose queries return forty rows of
activity is one nobody reads.

## Procedure

1. **Scope.** Argument if given; otherwise measure and ask (above).
2. **Install the exclusivity vocabulary.** Once, before asserting.
3. **Order candidates oldest-first** — `git log --reverse`, with `%at` for each.
   Chronological order is what makes supersession work; out of order, a stale
   fact closes a current one.
4. **Read the bodies in one pass.** `git show -s --format=%B <sha>`.
5. **Assert per commit**, one `lemmalog_observe` per sha with `ts=%at`, so
   provenance maps to a commit. Anchor with `<entity> --located--> <repo>-<sha>`
   and `<entity> --in_repo--> <repo>`. **The repo is a first-class dimension** —
   one global store, so a fact that does not name its repo is unreachable later.
   If a scope would exceed ~40 commits, narrow it rather than issuing 40 calls.

   **Every topic entity needs its own `in_repo`, not just the first.** This is
   operational, not cosmetic: `hooks/lemma-brief.sh` counts facts by matching the
   repo name as a literal token, so a topic with no `in_repo` edge is invisible
   to the SessionStart brief. A run that skipped them reported 5 facts on record
   out of 45 actually asserted.
6. **Collect the engine's counts**, and filter escalations against the
   expected-multi list.
7. **Report one line**: asserted, superseded, read, dropped. Then the genuine
   escalations, if any — one line each, `why` available on request.
8. **Ask it three questions.** Three `lemmalog_query` calls that return
   something real, shown. A store that has never answered anything is one nobody
   writes to again — that is the whole reason to backfill.

## Fixing a bad fact

MCP exposes no retract: the tools are observe, query, query_deep, why, what_if,
context, dump, save, canonicalize, batches, install_rules, uninstall, run. A
wrong fact on an `exclusive` predicate is fixed by observing the right value at
a later `ts` — supersession closes the old one. On a non-exclusive predicate
there is no in-band fix; say so plainly rather than implying it is cheap.

## If the tools are missing

Say so and stop. `bin/lemma-info` reports what is missing, `bin/lemma-install`
fixes it. MCP servers connect at session start, so one registered mid-session is
not available until the next — say which it is rather than reporting a failure.
