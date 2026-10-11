---
name: lemma-info
description: "Report the state of the lemmalog loop — engine, MCP registration, store size by repo, pending queue — and what to do next. Invoked as /lemma-info, or whenever you need to know whether lemmalog is actually working."
allowed-tools: Bash
---

# lemma-info

Run it and show the output:

    ~/modev/agent-rig/bin/lemma-info

That is the whole job. **Do not reimplement any of it** — not the fact count,
not the queue breakdown, not the registration check. The script is the source of
truth and is covered by `bin/lemma-info.bats`; a second implementation here
would drift from it silently, which is the exact failure the snapshot-path test
in `bin/lemma-install.bats` exists to prevent.

## Why the logic lives in a script and not in this file

The moment you most need to know the state of the loop is when the `lemmalog_*`
MCP tools are **not** connected — a fresh machine, a session that started before
`bin/lemma-install` ran, a registration shadowed by an older project-scoped one.
A skill cannot help you there, and neither can the tools. The script works with
nothing installed at all and always exits 0.

This wrapper exists so the answer is also reachable as `/lemma-info`, next to
`/lemma-drain` and `/lemma-backfill`.

## After showing it

Read what came back and say the one thing worth doing, if there is one. Do not
narrate every line — chrismo can see the output.

- **engine or registration missing** → `bin/lemma-install`, then restart. Say
  plainly that the queued commits are not lost: `hooks/lemma-commit.sh` has no
  dependency on the engine, so it has been recording correctly the whole time.
- **a project-scoped entry shadows the global one** → it wins inside that
  project and points wherever it was set, likely at a store nothing writes to.
  `cd` there and `claude mcp remove lemmalog`.
- **store empty, repo has history** → `/lemma-backfill`. An empty store is one
  with no reason to query it, and therefore none to write to. Suggest scoping it
  to whatever chrismo is about to work on rather than sweeping the whole repo.
- **commits pending** → `/lemma-drain`. Most will establish nothing; that is
  expected, and the count dropped is the useful half of the report.
- **everything healthy and the store has facts** → say so in one line and stop.
  Do not invent a next action.

If the numbers look wrong rather than merely empty — a fact count that does not
move after a drain, a registration pointing at a path nothing writes — check
that `LEMMALOG_MCP_PATH` matches the snapshot the script reads. The script flags
that mismatch itself, and it is the one failure in this loop that is invisible
from the inside: the store fills up correctly while every reader reports empty.
