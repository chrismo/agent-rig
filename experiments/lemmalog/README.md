# The internals contract, as a deductive model

An experiment: feed `bin/claude-contract.bats` results into
[lemmalog](https://github.com/JordyZomer/lemmalog) (a Datalog engine for agent
memory, exposed over MCP) and ask questions the suite cannot answer about
itself.

## Why

A test suite asserts one thing at a time. It cannot assert a *relationship*
between two results — and `docs/internals-contract.md` is full of those,
written in English and enforced by nobody:

> An assertion can keep passing while the meaning underneath it changes.

> Every A-series anchor stayed green the whole time — the code was all in the
> bundle, it just wasn't activating.

That second one is 2026-08-08, and no single test could have caught it. Here it
is two lines of Datalog (`present_not_running`), and it fires the moment both
halves are recorded. Replayed against the real results with R1 forced red, it
flags all seven A-series assumptions.

## Layout

| file | what it is |
|---|---|
| `contract.tsv` | **structure** — group and consumers per assumption. Read off the doc, hand-maintained, as stale as that doc ever is. |
| `rules.lem` | ten rules. Everything interesting is derived. |
| `build.sh` | emits a lemmalog script: rules, structure, and **observations** from `docs/contract-results.tsv`. |

The split is the point. The first version of this model hand-transcribed the
doc's verification claims, which inherited the doc's staleness and gave it a
proof tree — worse than the markdown table, because it looked authoritative.
Observations now come only from tests that ran.

## Use

```sh
./build.sh | ~/modev/lemmalog/target/release/lemmalog
# then, in the engine:
#   now <epoch> ; run
#   ? unverified(A)          not confirmed on THIS build: skipped, failed, or never run
#   ? urgent(A)              unverified and depended on by 4+ consumers
#   ? exposed(C)             consumers standing on something unverified
#   why urgent("C1")         proof tree, down to the asserted rows
```

Claude reaches the same engine through the MCP tools. `bin/lemma-install` builds
it and registers the server at user scope:

```sh
~/modev/agent-rig/bin/lemma-install
```

That points the server at `~/.claude/lemmalog/store.snapshot` — one global store
keyed by repo, shared with the commit/drain loop in `hooks/lemma-*.sh`, not a
store private to this experiment.

## Status: experiment, and honestly sized

Twenty assumptions and eight consumers. `unverified` and blast radius are both
reachable in about thirty lines of awk — the engine is not yet earning its
keep on volume. It is kept because the writes are now free (the suite records
itself either way), so the store accumulates without anyone maintaining it, and
the question of whether it tips over into useful can be answered by looking
rather than by guessing.

Nothing in the repo depends on it. `internals-drift.sh` reads the results TSV
directly, never the engine.

### Known engine limitation

`maintain(now)` is `set_now` + `run` (`src/agent.rs`). Moving the clock on an
already-materialised store does **not** re-derive `current(...)`, in either
direction — it reports `+0 facts` and keeps the old projection. The clock is
not the update mechanism; superseding an edge's `valid_to` is. Reproduced, not
theorised.
