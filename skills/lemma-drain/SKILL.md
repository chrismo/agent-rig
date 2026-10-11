---
name: lemma-drain
description: "Review commits queued by the lemma-commit hook and assert the few that established something durable into lemmalog. Invoked as /lemma-drain, or when the SessionStart brief reports pending commits."
allowed-tools: Bash, Read
---

# lemma-drain

`hooks/lemma-commit.sh` queues every commit. Most of them established nothing
worth keeping. Your job is to tell the difference, and it is the only part of
this loop that needs judgement — which is exactly why a script does the
queueing and you do this.

## The bar

From lemmalog's own skill: **conclusions, decisions and state changes land in
the engine; activity does not.**

The failure mode is not volume. Re-asserting a fact merges annotations rather
than duplicating, so the store will not bloat. The failure mode is *low-value*
facts — every query returning forty rows you have to read past, and `why` trees
padded with noise. A store nobody wants to read is a store that dies.

So the default answer for a commit is **no fact**. Assert when the commit
records something a future session would otherwise re-derive or re-litigate:

- a decision, especially one that **rejected** an alternative — "ruled out X
  because Y" is the highest-value shape there is, because it is what gets
  re-proposed in six months
- a constraint discovered the hard way (a limitation, a gotcha, an incompatibility)
- a load-bearing assumption about something outside your control
- an approach abandoned after real effort

Do **not** assert: routine fixes, refactors, typos, dependency bumps, formatting,
"add tests for X", or a restatement of what the diff already shows. If the commit
message is fully explained by its own diff, there is no fact in it.

## Procedure

1. **Read the queue.** `${AGENT_RIG_LEMMA_QUEUE:-~/.claude/lemmalog/pending.tsv}`
   — TSV: repo, short sha, epoch, subject. Work only on rows for the current repo
   unless asked otherwise.

2. **Read the commits.** `git show --stat <sha>` and the full message. The
   message body is usually where the reasoning lives; the subject rarely is.
   A commit whose body argues for a choice is the one worth asserting.

3. **Propose, don't assume.** Show the user the handful you think carry a fact,
   with the fact you would assert, and say plainly how many you are dropping.
   Let them correct you — early on, your bar is the thing being calibrated.

4. **Assert via `lemmalog_observe`.** Line protocol, `S --rel[conf]--> O`, one
   per line. **The repo is a first-class dimension** — this is one global store,
   so a fact that does not name its repo is unreachable later:

       lemmalog-store --ruled_out--> per-repo-stores
       per-repo-stores --because--> mcp-path-read-once-at-startup
       lemmalog-store --in_repo--> agent-rig
       lemmalog-store --located--> agent-rig-61fd789

   Note the subject is the *topic*, not the repo. Putting the repo on the left of
   every fact collides: `ruled_out` is not exclusive, so a second
   `agent-rig --ruled_out--> ...` escalates against the first.

   Anchor provenance with `<entity> --located--> <repo>-<sha>` so the proof tree
   leads back to something readable. **Not `repo@sha`** — `observe` validates
   entity tokens (max 60 chars, max 8 words, only letters, digits, `_`, `-`, `'`
   and spaces) and silently drops what fails, so an `@` means the provenance you
   think you wrote does not exist. Reasons are short kebab-case entities too, not
   sentences; the sentence is in the commit that `located` points at. Read the
   `dropped N line(s)` report after every observe. Tag inferences `[0.4]`–`[0.7]`;
   leave read-and-verified facts untagged.

   **Pass `ts` = the commit's `%at`**, not the default clock. The engine's update
   policy is temporal: a later value on an `exclusive` predicate closes the
   earlier one's interval, so `current()` returns what still holds. Asserting at
   "now" instead breaks that ordering against anything `/lemma-backfill` put in
   from history — a fact from 2026-04 would land after one from 2026-08 and
   supersede it backwards. `/lemma-backfill` documents the policy and the
   exclusivity vocabulary; use the same relations here.

5. **Drain what you asserted.** Remove those rows from the queue — and only
   those. A row you decided against is still drained (the decision was made);
   a row you did not reach is not. Never truncate the file wholesale.

6. **Report in one line.** "3 of 11 asserted, 8 were routine." The count of
   what you dropped is the useful half — it tells the user whether the bar is
   set right.

## The neighbours

- `/lemma-info` — what state the loop is in: engine, registration, store size by
  repo, queue depth. The logic lives in `bin/lemma-info`, a script, so it still
  answers when the `lemmalog_*` tools are not connected — which is when you most
  need it; the skill is a thin wrapper so it is reachable as a slash command too.
- `/lemma-backfill` — reaches backwards into git history, scoped to a path or
  subsystem. This skill only ever sees commits made after the hook was installed;
  without a backfill the store is empty for months, which is how stores die.

## If the tools are missing

If `lemmalog_*` is not available, say so, name the fix, and stop — do not
half-drain into a file nobody reads. The fix is one command:

    ~/modev/agent-rig/bin/lemma-install

It clones and builds the engine (a Rust binary, `--features mcp`) and registers
the MCP server at **user scope**, so the tools are there in every repo — which
matters, because `hooks/lemma-commit.sh` queues commits from every repo, and a
registration scoped to one project leaves the rest permanently undrainable.

The engine lives outside this repo and is built per machine, so a clone of
agent-rig on another machine has the hooks but no engine. That is the expected
state on a new machine, not a fault: the queue fills correctly and the
SessionStart brief keeps reporting it until the engine exists.

`bin/lemma-install` is deliberately not run by `install.sh` — it needs a Rust
toolchain and a network clone, which every other install would pay for and
almost none would use.

MCP servers connect at session start, so a server registered mid-session is not
available until the next one. That is not a failure — say which it is.
