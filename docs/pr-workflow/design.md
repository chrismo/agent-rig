# PR workflow — design (draft, 2026-10-11)

> **Working document — not for long-term keeping.** This captures design work
> in progress for the PR workflow pipeline. Once the pipeline is built, the parts
> worth keeping move into the code, its README, or a short decisions record, and
> this file is deleted. Don't treat it as current documentation of anything that
> exists.

Goal: take the busy work out of getting a branch to a merged PR and keeping it
**current** while it's open, so that with many agents running chrismo can see at
a glance where each one stands:

1. up to date with its parent (stack-aware)
2. CI green on the head SHA
3. review current (local and/or bot)
4. bot comments responded to

**Name: `pr-tend`, for now (2026-10-13).** It's the overarching name for the
pipeline and the namespace for its state: git config `pr-tend.*` and
`branch.<b>.pr-tend`, `refs/pr-tend/`, `~/.config/pr-tend/`,
`~/.local/state/pr-tend/`, `<git dir>/pr-tend/`, `lib/pr-tend.sh`. The commands
stay `pr-state`, `pr-act`, `pr-watch`, `pr-config`. Rename candidates: `sheepdog` (favourite), `tug`, **`pr-op`** (*prop*), and
**`pr-onto`** (*pronto*). The last two keep the `pr-` prefix while reading as
short familiar words; `pr-op` suggests a PR operation, while `pr-onto` suggests
getting a PR moving. Renaming means a pass over every name above, plus migrating
existing state.

## Principles

1. **Deterministic wherever possible.** Scripts observe and act at zero token
   cost; an agent is invoked only for judgment.
2. **The pipeline drives; agents are workers.** The pipeline initiates every
   step — including implementation — and invokes an agent for one bounded task
   at a time. Agents never need to know the pipeline exists.
3. **Harness-agnostic — essential.** Everything works with Claude or pi. The only
   per-harness code is a small adapter (below).
4. **Reconcile, don't rely on enforcement.** The pipeline never assumes it's the
   only writer. Each pass compares observed state to desired state and closes
   the gap; an agent's stray push or PR is just another observed state. Cheap
   per-step denies are used where a harness offers them, but correctness never
   depends on them.
5. **Idempotent, keyed on SHA.** Any step can be rerun safely.

## Decisions so far

| Topic | Decision |
|---|---|
| Scope | One branch at a time. A pass never reaches into another worktree. |
| Initiator | The pipeline: `pr-act start "<task>"` (chrismo) to begin; tickets later |
| Agent invocation | Headless, one step per process, persistent session per branch (`-p` + resume) |
| Done signal | The agent process exiting (or chrismo exiting a takeover). [req-review #5](req-review.md#5-done--process-exit-cant-tell-finished-from-asking) |
| Takeover | `pr-act attach` → lock + interactive resume of the same session |
| Rebase policy | `rebase --onto` + `push --force-with-lease=<branch>:<expected-sha>`; plain push when nothing was rewritten |
| Stacks | First-class. Lineage stored locally; restack is always `rebase --onto`. |
| Local review | Configurable script run by the pipeline; preferred over the PR bot whenever it suffices, and can replace it (`/marge` not required at work) |
| Bot | PR comment slash command, configurable per repo (`/marge` at work; home TBD) |
| Bot staleness | Pin HEAD when triggering; staleness = diff since the pin; rebase-only changes don't count |
| Re-review needed? | Judgment (J5), steered by PR label. Outcomes: none / local / remote |
| Agent replies | **Bot threads only.** Human threads are surfaced to chrismo. |
| Accidental agent push | **Denied where cheap, reconciled always.** Claude steps run with `--disallowedTools "Bash(git push:*)" "Bash(gh pr create:*)"`. pi's `--tools` is whole-tool only (can't deny `git push` and keep bash), so pi relies on reconciliation. Detected pushes are logged so the step prompt can be tightened. |
| Watcher | **One launchd job** across all enrolled branches |
| PR description | A resume step ("write the PR description"); `--json-schema` on Claude |
| Cycle caps | **Per loop run, reset on success; split by cost.** Local loops (verify + local review): 3 attempts. Remote CI rounds: 2 (a CI round is slow and expensive — Stripe's rule). Bot rounds: 2. Cap hit → needs-chrismo. Reaching clean / green resets that loop's count. Not per HEAD — every fix commits, so a per-HEAD reset would never trip. Revisit after use. |
| Session per step | **Resume for every step in v1.** Record per-step token usage (`--output-format json`); switch late steps (CI fix, bot address) to fresh-session + findings if resumes get expensive. *Theory:* prompt cache will have expired after a CI / bot wait, so a long resumed session is re-read at full price. |
| Deterministic verify | **Yes.** `settings.verify` (lint / build / test) runs before the local model review, at zero tokens; failure output (trimmed) goes to the agent's fix step and the model reviewer never sees code that doesn't build. The step contract tells the agent the command exists, so J0 can run it before exiting. |
| Autofix before CI fix | **Yes.** `settings.autofix` (formatters, `lint --fix`) runs first on red CI or failed verify; only what remains goes to J2. |
| Scope check | **Yes.** The task text is recorded at start (`branch.<name>.pr-task`) and passed to the local reviewer as `PR_TEND_TASK`, so it can flag work outside the task (Spotify's top judge veto). |
| Per-step turn cap | **No.** Neither CLI shows a turn-cap flag (`--help`, 2026-10-11); `--max-budget-usd` bounds Claude steps. |
| Verify before reply | **No, for now.** Revisit if we move fix steps to cheaper models (OpenHands-style per-thread "was it incorporated?" check). |
| Handed-off feedback | Multi-valued `branch.<name>.pr-handled <comment-id>` (git config `--add`). Mostly a guard for review bodies and in-flight steps; threads already dedup via "last speaker is us" (O7). |
| Step prompts | Lookup chain, nearest wins: `<scope>/.pr-tend/<step>.md` walking up to the repo root → agent-rig defaults. `scope` = `branch.<name>.pr-scope`, set by `pr-act start --scope <app-dir>` (monorepo: per app); default repo root. |
| Build vs adopt | Self-built. AO evaluated (below), not adopted; round 2 (2026-10-11) found nothing to adopt wholesale — see "Prior art, round 2". |
| Who drives | **Pipeline drives, reaffirmed** after round 2. Symphony / Gas Town (agent drives the PR loop from prompts) are the opposite camp; Sortie / Archon match us. Keeps tokens down; stochastic only where judgment is needed. |
| GitHub native stacks (`gh stack`) | **Not used by the pipeline.** Too heavy for local automation; read only for git tricks. Guard only: chrismo uses `gh stack` at work, so a branch can be in a native stack anyway — then O1 sees the `stack` field and the pipeline skips A2 / A4 (GitHub restacks server-side and refuses base edits) rather than race it. |

## Harness adapter — the only per-agent code

Both harnesses let the caller **choose the session ID up front**, so the
pipeline mints it and never has to discover it.

| Operation | Claude | pi |
|---|---|---|
| First step | `claude -p --session-id $U "<prompt>"` | `pi -p --session-id $U "<prompt>"` |
| Next step | `claude -p --resume $U "<prompt>"` | `pi -p --session $U "<prompt>"` |
| Done | process exits | process exits |
| Take over | `claude --resume $U` | `pi --session $U` |
| Watch | `claude-pod` | `claude-pod --pi` |
| Deny push / PR | `--disallowedTools "Bash(git push:*)" "Bash(gh pr create:*)"` | — (whole-tool `--tools` only) |

Facts (from `--help`, Claude Code 2.1.296, pi 0.99.1): `-p` is **one user
turn, many steps** — the agent loops through tool calls until it ends its turn,
then exits. It can't ask a question mid-run; if it needs input, it ends and
prints the question. Permission prompts go to the host or are auto-denied
(`--permission-prompts none`).

**Auth and billing** (docs read 2026-10-11 by the claude-code-guide agent;
`claude auth status` here = claude.ai, Max):

- `claude -p` on a Max login is officially allowed. Support article 15036540:
  Jun 15 update — `claude -p` "still draw[s] from your subscription limits";
  Oct 7 update — Max now includes monthly API credits that "cover ... `claude
  -p`", and "you can still use ... `claude -p` ... with your subscription
  limits". Which pool a given call draws from is not stated. An in-product
  notice chrismo saw ("headless is API usage only") was not found in docs.
- **An exported `ANTHROPIC_API_KEY` overrides the claude.ai login** (observed:
  "claude.ai connectors are disabled because ANTHROPIC_API_KEY ... takes
  precedence"). chrismo's `~/.zshrc` exports a key with no credit → every
  headless call failed until unset. The adapter runs Claude as
  `env -u ANTHROPIC_API_KEY claude -p ...` unless config says to use the key.
- Never `--bare`: it ignores OAuth and requires an API key.
- **pi cannot use the Claude subscription.** Legal & compliance page: Anthropic
  "does not permit third-party developers to ... route requests through Free,
  Pro, or Max plan credentials". pi steps need their own API key or a
  non-Anthropic provider (fits pi's role: cheaper models).
- Measure: record per-step usage from `--output-format json`
  (`total_cost_usd` is computed for every call and is **not** evidence of how
  it was billed).

Not used: Claude's `--bg` / `claude attach` (Claude-only). `--max-budget-usd`
(Claude) is a per-step cost cap worth using.

## Lifecycle — state machine

```
start → implement* → check → (fail? → [autofix] → fix* → check)          [cap 3]
      → describe* → ship → ci → (red? → autofix → fix-ci* → check → ship)  [cap 2]
      → bot? → (findings? → address* → check → ship) → ready → merged      [cap 2]

check = verify (zero tokens) then local-review (model) — review only runs on
        a tree that verifies
                                                     * = agent step (resume $U)
```

Every arrow is a script decision. Every `*` is one headless agent step in the
branch's session; the process exit advances the machine. Any failure, a cap
hit, or an escalation → **needs-chrismo** (N2).

### Steps 1–4, concretely

1. **chrismo** runs `pr-act start "<task>" [--harness pi] [--parent <branch>]`.
   **Pipeline** creates the worktree (`wt-new`), records `pr-parent` and
   `pr-task`, pins `base`, enrolls the branch, mints `$U`, stores harness +
   session in config.
2. **Pipeline** runs the implement step: `<harness> -p --session-id $U "<task + step contract>"`.
   Step contract: commit when done; don't push or open a PR. **Agent** writes
   code and commits. Exit = done.
3. **Pipeline** checks: exit 0, tree clean, commits ahead of base? (Dirty → one
   resume: "uncommitted changes left"; otherwise → needs-chrismo.) Runs
   `settings.verify`; failure → autofix, then resume `$U` with the trimmed
   output. Verify passes → local review script. Findings → resume `$U` with the
   findings JSON → agent fixes and commits → exit → check again. Cap 3 cycles.
   Clean → pin `local`.
4. **Pipeline** runs the describe step (resume `$U`, structured output), then
   ships: push, `gh pr create` (or reconcile an existing PR, below).

### Happy path, the rest of the way

5. Watcher: CI pending → nothing. Then green, bot not yet triggered.
6. First remote review: **proposed deterministic rule** — after the first ship,
   no label → trigger the bot (A5), pin `bot`. (`review:light` → skip; local
   suffices.)
7. Bot replies; O7 shows an unresolved bot thread → address step (resume `$U`
   with normalized findings): agent fixes + commits → local review → ship →
   pipeline posts the agent's reply (J4) and resolves the thread (A7).
8. CI green; `bot` pin is behind HEAD → J5 step: small fix inside the flagged
   range, local clean → no re-review → pin **`accepted`** (see O6).
9. All four checks hold → tab glyph green → **chrismo** merges.
10. Watcher sees merged → unenroll, delete `refs/pr-tend/<branch>/*`.

### Takeover

`pr-act attach`: take the lock (`branch.<name>.pr-lock`), open the interactive
resume of `$U`. While locked the pipeline runs no agent steps (mechanical
observation continues). chrismo exits → release lock → pipeline resumes at the
local-review check. **chrismo exiting is a done signal too**, so pairing on an
implementation fits the same loop.

## Reconciliation — accommodating an accidental agent push

| Agent did | Pipeline sees | Pipeline does |
|---|---|---|
| `git push`, no PR yet | remote = local HEAD | ship's push is a no-op; `gh pr create` proceeds |
| `git push`, PR exists | remote has commits the local review hasn't covered | nothing breaks: "ready" and the bot trigger both require the `local` pin to cover HEAD. Cost: one early CI run |
| force-push after an amend | remote ≠ expected SHA; our lease would fail | **remote SHA in this branch's reflog?** yes → ours; push with lease = that SHA. No → someone else pushed → escalate. [req-review #9](req-review.md#9-someone-elses-fast-forward-is-treated-as-a-foreign-push) |
| `gh pr create` | PR already exists | ship becomes "find and fix up": `gh pr edit` description **and base** (an agent in a stack will likely target `main`, not its parent). Base edit skipped for a native-stack PR (O1). |
| pushed to the wrong branch (`HEAD:main`) | — | not ours to absorb; that's server-side branch protection |

**Ownership via reflog:** `git reflog show <branch>` lists every SHA this branch
has been at locally. Remote head in that list → we put it there → safe to
overwrite. Deterministic, no extra record. Reflogs are per-worktree, which is
fine: one branch, one worktree.

**Log, don't block:** a detected agent push is recorded and surfaced (N2). A
repeat offender means the step-contract prompt needs tightening.

## Storage — git-native, no JSON file

| What | Where |
|---|---|
| Parent branch name | `git config branch.<name>.pr-parent` |
| Enrolled | `git config branch.<name>.pr-tend true` |
| Harness | `git config branch.<name>.pr-harness claude\|pi` |
| Session ID | `git config branch.<name>.pr-session <uuid>` |
| Takeover lock | `git config branch.<name>.pr-lock` |
| Restack base SHA | `refs/pr-tend/<branch>/base` |
| SHA last locally reviewed clean | `refs/pr-tend/<branch>/local` |
| SHA bot was triggered on | `refs/pr-tend/<branch>/bot` |
| SHA accepted as reviewed enough (J5 "no") | `refs/pr-tend/<branch>/accepted` |
| Bot command / login | `settings.botCommand`, `settings.botLogin` (config files) |
| Local reviewer script | `git config [--global] pr-tend.localReview` |
| Verify / autofix commands | `settings.verify`, `settings.autofix` (config files) (repo-level for a monorepo app: scope lookup below) |
| Task text | `git config branch.<name>.pr-task` |
| Comment IDs handed to the agent | `git config --add branch.<name>.pr-handled <id>` |
| Prompt scope (monorepo app dir) | `git config branch.<name>.pr-scope <path>` |

- Refs (outside `refs/worktree/`) and repo config are **shared across
  worktrees**, so a child's pass can read its parent's records.
- A ref **pins the object** against gc after rebases / force-pushes; a SHA in a
  JSON file would not.
- `refs/pr-tend/*` is not in the default push/fetch refspecs — stays local.
- Lineage must be local because GitHub auto-retargets a child PR to `main` when
  the parent merges with "delete head branches" on (per GitHub docs, untested),
  erasing the parent name from the PR. (GitHub's native stacked PRs, GA
  2026-10-06 per agent-read docs, do keep lineage server-side — but we don't
  use them; see Decisions.)

**Cleanup** (observed, scratch repo, 2026-10-11):

| Event | `branch.<name>.*` config | `refs/pr-tend/<name>/*` |
|---|---|---|
| `git worktree remove` | kept | kept |
| `git branch -D` | **removed by git** | kept |

Config cleans itself up when the branch is deleted; refs never do (they're
repo-wide, not per-worktree). So: step 10 deletes the refs on merge, and every
watcher pass also sweeps `refs/pr-tend/<b>/*` whose branch no longer exists
(abandoned branches).

**Bootstrap:** `pr-act start` records everything at creation. For a branch
enrolled any other way, `pr-state` derives missing records (A2 fallback chain),
verifies ancestry, and writes them.

### Harness, model, effort and provider per step

Modeled on Sortie's per-rule settings blocks (`docs/workflow-reference.md`,
"Rule settings blocks", read 2026-10-12): a step may override model and effort,
and the harness itself. Built as JSON blocks (`harnesses.<h>`, `steps.<step>`,
`steps.<step>.<h>`); see "Config files" below. A git-config draft of the same
keys was dropped. Git only layers the *same* key across scopes, so the
step-to-harness fallback needed our own resolver whichever store held the
values.

`<step>` is a verb name (`address`, `review`, `ci-fix`, `describe`, ...).

Resolution, per key:
- The step-and-harness block replaces the harness block's value whole.
- A key that isn't written is inherited.
- `null` clears the inherited key, so the runtime's own default applies.

The harness command and timeouts can't be overridden per step;
`settings.stepTimeout` is global.

Warn when a step override sets `model` but not `effort` and an `effort` is
inherited, because level names depend on the model (Sortie's
`agent.effort.inherited`).

Each adapter maps these keys to its CLI flags (checked against `--help`,
2026-10-12): claude `--model`, `--effort`; pi `--provider` (needs `--model`),
`--model`, `--thinking` for effort. `args` stays as the escape hatch, split on
whitespace (no argument can contain a space) and appended **after** the typed
flags and the sandbox flags, so it can also override `--allowedTools`,
`--disallowedTools` (claude) or `--tools` (pi). Whether a repeated flag's last
value wins is up to each CLI and untested here.

To verify: whether a resumed session (`pr-session`) accepts a different model
or effort than it started with; Sortie says a change between attempts doesn't
end its session, which is untested here.

### Config files: XDG global + branch-local copy (built 2026-10-13)

The settings live in JSON instead of dotted git-config keys:

- **Global:** `$PR_TEND_CONFIG`, else `${XDG_CONFIG_HOME:-~/.config}/pr-tend/config.json`,
  one per machine (no system layer; single user).
- **Branch:** `<git common dir>/pr-tend/<branch>.json` (`%` and `/` encoded),
  shared by every worktree of the repo.

Shape:

```json
{"harness": "claude",
 "harnesses": {"claude": {"model": "...", "effort": "high"},
               "pi": {"provider": "...", "model": "...", "effort": "medium"}},
 "steps": {"address": {"harness": "pi", "pi": {"model": "...", "effort": null}}},
 "settings": {"verify": "make test", "botLogin": ["marge"]}}
```

**One merge, two readers.** `lib/pr-config.sh` deep-merges the branch file over
the global file in SuperDB. A leaf in the higher layer replaces every leaf at,
above or below its path in the lower one, lists are leaves, and `null` is kept
through the merge. Then:

- `pr-config get <path>` (`prc_get`) reads any dotted path, the same paths
  `set` and `unset` take, over the **built-in defaults** (`PRC_DEFAULTS`).
  A `null` in a file removes the key from the files, so the default applies.
  - **Defaults:** `harness: claude`; settings `remote: origin`,
    `stepTimeout: 1800`, `interval: 300`, `replyPrefix: "🤖 "`, and `verify`,
    `notify`, `botLogin`, `botIgnore`, `botIgnoreBody` empty.
  - **Output:** a string prints raw, a list one element per line, an object as
    JSON; `--json` prints JSON for all of them.
  - **Exit codes:** 3 means no value and no default; 1 is always an error.
- `pr-config step <step>` (`prc_step`) is what one step runs with.
  - **Harness:** `--harness`, else the step's `harness`, else the top-level
    `harness`, else the default.
  - **Settings:** that harness's block, with the step's block for that harness
    laid over it. A step-level `null` clears the harness block's key, so the
    nulls have to survive the merge; that's why the merge keeps them.

Callers can't tell which layer a value came from. `pr-act`, `pr-watch` and
`pr-state` source the lib and only call `prc_get` and `prc_step`. The lib's
functions never exit and check every step (`|| return`), because callers run
them as `x=$(prc_...) || die`, where errexit is off. The CLI calls them the same
way, so its tests cover that path. The watcher has no branch, so it reads with
`--no-branch`. `pr-act address` stops on a config error. `pr-watch` reports the
error on the repo's line in `pr-watch status` and refuses to `install`.
`verify` must be one command; a list is refused before the agent runs.

**No git config fallback.** `pr-tend.<key>` and `pr-tend.<harness>.args` aren't
read any more; nobody had any set (checked 2026-10-13). Per-branch *state* stays
in git config: enrollment, `pr-session`, `pr-harness`, `pr-handled`, and so on,
plus the `pr-tend.repo` registry.

**Writing values:**
- `pr-config init --global` creates the global file as a skeleton of empty
  blocks.
- `pr-config set [--global | --branch <b>] [--json] <path> <value>` writes one
  value at a dotted path, to the current branch's file by default.
  - Values are strings unless `--json` (numbers, lists, `null` to clear an
    inherited key). `--json` takes exactly one JSON value.
  - Each parent on the path must be missing, `null` or an object.
  - Writes go through SuperDB `put`, so the file's empty blocks and other keys
    stay.
- `pr-config unset <path>` removes a key so it inherits again.
- `set` on a branch with no file creates one holding only that key.

**Init is a copy.** Starting (or enrolling) a branch copies the global file to
the branch file. Per-PR differences are overrides written into that copy,
because they're common: some PRs are cheap and easy, others thorough and need a
frontier model. (No command flags are designed for this yet.) The merge works
whether the branch file is a full copy or only overrides. With a full copy,
later edits to the global file don't reach existing branches, and no way to
refresh a branch from global is specified.

**SuperDB notes (0.3.0, observed 2026-10-13):**
- **No here-strings:** `super` reads nothing from `<<<`, so input is always
  piped.
- **No lateral subqueries:** `unnest … into ( … aggregate … )` panicked
  ("context canceled") in 12 of 200 runs. The merge uses plain `unnest` and
  `aggregate … by` instead, with 0 failures in 200 runs, and 0 in 450 calls of
  the finished lib.
- **Key order:** `unflatten` needs keys grouped by prefix, so the merged keys
  come out alphabetical.
- **No JSON encoder:** SuperDB has no to-JSON function, so `get` uses a second
  call to print raw or JSON.
- **Unvalidated names:** a misspelled step or harness still resolves to nothing,
  with no error.

## Atomic actions

### Observe — deterministic, read-only (`pr-state`)

| # | Action | Answers |
|---|---|---|
| O1 | PR lookup | number, base, head SHA, draft/open, mergeable; in a native GitHub stack? (→ hands off) |
| O2 | Parent state | parent from config; parent PR open / merged |
| O3 | Sync vs parent | behind? would restack conflict? |
| O4 | Local vs remote | unpushed commits? remote moved? whose SHA (reflog)? |
| O5 | CI on head SHA | pending / green / red, which checks. **Cancelled = inconclusive, not red**; checks on a non-HEAD SHA give no verdict (Sortie ADR-0023) |
| O6 | Review freshness | bot replied since trigger? Is HEAD covered by `local` / `bot` / `accepted`? |
| O7 | Threads owed a reply | unresolved threads / review bodies where last speaker isn't us; split bot vs human; **outdated-but-unresolved** (anchors lost to a force-push) handled explicitly |
| O8 | Session | harness, session ID, locked (taken over)? step in flight? |

### Act — deterministic, mechanical (`pr-act <verb>`)

| # | Action | Notes |
|---|---|---|
| A0 | start | worktree, lineage, base pin, enroll, mint session |
| A1 | fetch | |
| A2 | restack | algorithm below; stops on conflict |
| A3 | push | plain if fast-forward; else `--force-with-lease=<branch>:<sha>` with the SHA from O4 |
| A4 | retarget / fix base | `gh pr edit --base` to match `pr-parent` (or `main` once the parent merged) |
| A5 | trigger bot | post `pr-tend.botCommand`; pin `bot`; skip if already pinned at HEAD |
| A6 | rerun flaky CI | optional; needs an allowlist |
| A7 | post reply / resolve thread | posts the agent's J4 text; resolves only after replying |
| A8 | local review | run `pr-tend.localReview`; findings → next agent step; clean → pin `local`. **The one Act verb that spends tokens** (the default reviewer is a model call) — exception to principle 1's zero-token rule |
| A9 | attach | lock + interactive resume (takeover) |
| A10 | verify | run `settings.verify`; trim output to errors; zero tokens |
| A11 | autofix | run `settings.autofix`; commit the result if the tree changed |

### Judgment — agent steps (resume `$U` with a step-contract prompt)

| # | Step |
|---|---|
| J0 | implement the task |
| J1 | resolve restack conflicts |
| J2 | diagnose / fix red CI |
| J3 | triage findings (bot or local): change code, reply only, push back, or ask chrismo |
| J4 | write the reply (bot threads only) — the pipeline posts it |
| J5 | does the change since the last review need one? none / local / remote |
| J6 | write the PR description (structured output) |

### Notify — deterministic

| # | Action |
|---|---|
| N2 | surface to chrismo: tab-title glyph; push notification for needs-chrismo (human threads, escalations, caps hit, detected agent pushes) |
| N3 | "seen" markers so a rerun reports only what's new |

(N1, messaging a live session, is no longer needed for the main loop — the
pipeline resumes the session itself. See "pi support in claude-peer" below.)

## A2 — restack algorithm

Squash merges defeat a plain rebase (patch-id skip can't match P1..Pn against
one squash commit S), so there is **one code path for every case**:

```
git rebase --onto <new-base> <old-base-sha> <branch>
```

- parent still open → `<new-base>` = `origin/<parent>`
- parent merged (squash, merge, or rebase-merge) → `<new-base>` = `origin/main`

`<old-base-sha>` resolution, each candidate checked with
`git merge-base --is-ancestor <sha> HEAD`:

1. `refs/pr-tend/<branch>/base`
2. merged parent PR's `headRefOid` (GitHub)
3. `git merge-base --fork-point origin/<parent>`
4. escalate (J1 / chrismo)

**Post-condition** — the branch's own change must be unchanged by the move:

```
before = git diff <old-base-sha> <old-HEAD> | git patch-id --stable
after  = git diff <new-base>     HEAD       | git patch-id --stable
```

Equal → write new `base` pin, done. Not equal → reset to old HEAD, escalate.
[req-review #1](req-review.md#1-a-resolved-restack-conflict-always-escalates)

**Observed (subagent probe, git 2.53, 2026-10-11):** default patch-id includes
context lines, so an upstream edit inside our diff context (line 8 vs our line
10) gave different IDs → needless escalation. `git diff -U0 | git patch-id
--stable` gave equal IDs; `range-diff` also flagged it (`!`, context only).
→ **Use `-U0`.** Untested: whether `-U0` still catches a wrong old-base
(parent commits replayed into ours) — needs a fixture.

Stack cascades are **pulled**: a child notices its parent moved on its own next
pass (O2/O3). No cross-worktree writes.

## O6 / J5 — review staleness and re-review

Shared helper with A2: "same change modulo base?" via `git diff -U0 | git patch-id --stable` (context-free; see A2 observation).

HEAD counts as **reviewed** when covered by the `local`, `bot`, or `accepted`
pin (whichever the label requires):

| Case | Check | Meaning |
|---|---|---|
| pin = HEAD | — | covered |
| pin is ancestor of HEAD | `rev-list --count pin..HEAD` | N commits uncovered → J5 |
| rewritten by rebase | `-U0` patch-id of base..pin vs base..HEAD | equal → covered; else `range-diff` → J5. [req-review #2](req-review.md#2-restacking-breaks-o6s-rewritten-by-rebase-check) |

Timestamps only answer "has the bot replied since the trigger" — never
staleness, because rebase rewrites committer dates.

**Candidate for the "rewritten by rebase" row — Gerrit's TRIVIAL_REBASE**
(`ChangeKindCacheImpl.java`): replay the old change onto the new base and
compare trees:
`git merge-tree --write-tree --merge-base=<old-base> <new-base> <pin>` ==
`HEAD^{tree}` → covered. Stronger than patch-id for O6. (Weak as the A2
post-condition, since after a clean rebase it's ~always true.)

**Caveat — human approvals:** GitHub's "dismiss stale approvals" fires when the
**merge base** changes, not the diff. On repos requiring approval, a restack can
drop "ready" even though our pins say covered. Docs-read, untested.

**J5 inputs** (assembled by script so every decision sees the same evidence):
diff since the pin, the bot's comments, per-hunk "in a range the bot commented
on". J5 "no re-review" → pin `accepted`, so the next pass doesn't ask again.

**Importance via PR label:**

| Label | Iterations | Before merge |
|---|---|---|
| `review:light` | local | local is enough — remote never needed |
| *(none)* | local | first ship → remote (proposed rule); afterwards J5 decides |
| `review:critical` | local | remote on the final SHA, always |

## Local review — the configurable script (A8)

Purpose: catch what the PR bot would catch **before** it costs a PR
interaction — fewer bot round-trips, less PR comment noise, faster loop. Runs
only after `settings.verify` passes (A10), so the model never reviews code that
doesn't build.

```
git config [--global] pr-tend.localReview <command>
```

Any executable. What it does inside (prompt, model, emulating the backend bot
or not) is out of scope; agent-rig defines only the contract, and ships a
default `bin/pr-review-local` (thin `claude -p` wrapper + prompt file). It
invokes Claude through `harness_run` in `lib/pr-tend.sh`, so it gets the same auth handling
(unset `ANTHROPIC_API_KEY`, never `--bare`).

**Contract:**

- input: env `PR_TEND_BASE`, `PR_TEND_HEAD` (SHAs), `PR_TEND_TASK` (the task
  text, so out-of-scope changes can be flagged); cwd = the worktree
- output: JSON findings on stdout — `[{file, line, severity, body}]`
- exit 0 = review completed (findings may be empty); non-zero = reviewer failed
  (escalate; never treated as clean)

**Who runs it, who receives it:** the pipeline runs it after an agent step
exits (so the tree isn't moving — no frozen worktree needed) and hands the
findings to the branch's agent as the next resume step. The agent triages them
in its own context; it already knows why the code looks the way it does.

**Isolation** is the script's job: a separate process (fresh context, never the
authoring conversation) with read-only tools (no `gh`, no edits). The agent
can't steer it — it never even invokes it.

**One findings shape for both reviewers.** Bot comments (O7) are normalized to
the same `{file, line, severity, body}` shape, so the address step handles local
and remote findings identically.

## Ordering — a push invalidates everything downstream

Every push resets CI (O5) and bot freshness (O6). So within any loop:

1. restack (A2)
2. agent step(s); batch all code changes
3. verify, then local review, until clean (no CI run, no PR interaction)
4. push once (A3), fix base if needed (A4)
5. wait for CI green
6. remote bot (A5) only if the label / J5 calls for it

## Watcher — one launchd job

Every few minutes, for each enrolled branch:

1. `pr-state` (zero tokens)
2. compute the next transition of the state machine
3. mechanical transitions → run them (A1–A7, A10, A11); A8 runs only after an
   agent step exits or a takeover ends, never on an idle pass.
   [req-review #3](req-review.md#3-lock--in-flight-gates-only-agent-steps-not-mechanical-ones)
4. agent transitions → run the resume step, **unless locked** (taken over) or a
   step is already in flight for this branch
5. needs-chrismo → N2

**Built so far — observe-only (`bin/pr-watch`, 2026-10-11).** Steps 2–4 are
not built; a pass only observes and reports:

- Enrollment: `pr-act enroll [<branch>]` sets `branch.<name>.pr-tend` and adds
  the main worktree to global `pr-tend.repo` (multi-valued), the watcher's list
  of repos.
- **Fetch first** (decided): one `git fetch --prune` per repo, then `pr-state`
  per enrolled branch. `pr-state` stays read-only, with no `--fetch` option.
- Glyph per worktree in `~/.claude/tab-status/<worktree>.pr` as
  `<branch>\t<glyph>`; `tab-status` appends it to the title only while the
  worktree is still on that branch. ❌ needs chrismo · ⚠️ unknown · 🔧 work for
  later (behind, unpushed, bot threads, review not covered, no PR) · ⏳ CI
  running · ✅ ready · 🏁 merged · 🚫 closed.
- Notifications (N2, macOS by default, `settings.notify` overrides) only for a
  reason that wasn't there last pass (N3): CI red, restack conflict, human
  threads, foreign push, merged, ready to merge.
- `pr-watch status` prints the last pass. `pr-watch install` / `uninstall`
  manage the launchd job, opt-in per machine; interval `settings.interval`,
  default 300 s.
- O7 in `pr-state` (2026-10-12): besides inline threads, bot **review bodies**
  (non-blank) and bot **top-level PR comments** are owed items, typed
  `thread` / `review` / `comment` in `.threads.items`, with per-type counts in
  `.threads.by_type`; all count toward `owed_bot`. A review/comment stays owed
  until its node id is in multi-valued `branch.<name>.pr-handled` (`pr-act
  address` adds it). Human top-level comments are not tracked.
  `settings.botLogin` is a list and matches with or without `[bot]`.
- Marks in `pr-state` (2026-10-13). Every owed item is marked `!` (blocks) or
  `i` (to read), and the one-liner shows `!:<n> i:<n>`.
  - **`!`:** unresolved threads, a bot review in state `CHANGES_REQUESTED`, and
    a person's latest `APPROVED` / `CHANGES_REQUESTED` / `DISMISSED` review
    when it requests changes. A later `COMMENTED` review doesn't clear it,
    matching GitHub.
  - **`i`:** bot review bodies and PR comments not yet in `pr-handled`.
  - **Why the split:** those have no "resolved" state, so they were counted as
    owed alongside real work. The verdict a review bot writes in prose (Merge
    Simpson always submits as `COMMENT`) isn't parsed.
  - **Output:** `--json` items carry `mark`, `author`, `url`, and an `excerpt`
    (first line with text, tags stripped, 100 characters). A `stored` block
    has the `pr-handled` ids and `refs/pr-tend/<b>/*`. `--long` adds one line
    per item.

Rejected alternatives: `/loop` per session (tokens per idle wake, dies with the
session); built-in PR subscriptions (Claude-only, untested); git hooks (blind to
GitHub-side events); PreToolUse / Stop hooks to enforce agent discipline
(Claude-only; replaced by "pipeline drives" + reconciliation).

## pi support in `claude-peer` — no longer on the critical path

The pipeline resumes sessions itself, so it doesn't need to message a live
session. `claude-peer` pi support is still useful for one case: nudging a
session chrismo has taken over ("CI went red while you're in here"). Plan if
wanted:

- `pi/extensions/peer-socket.ts`: on `session_start` listen on
  `/tmp/cc-socks/pi-<pid>.sock`, write a registry entry (`kind: "pi"`) to a
  **separate dir** (e.g. `~/.pi/agent/peers/`, not Claude's unsupported
  `~/.claude/sessions/`); on each line call
  `pi.sendUserMessage(text, { deliverAs: "followUp" })`; clean up on exit.
- `claude-peer` scans the second registry dir; send path unchanged.
- Verified in pi 0.99.1 docs/types; not yet exercised.

## Packaging

| Piece | Kind | Tests |
|---|---|---|
| `bin/pr-state` | O1–O8 → JSON + one-line summary | bats, fake `gh` + git fixtures |
| `bin/pr-act <verb>` | A0–A9 | bats; real git fixtures for A2 (squash case!) and reconciliation (reflog ownership) |
| `lib/pr-tend.sh` | `harness_run` (adapter: claude / pi) + `with_timeout` | bats, stub `claude` / `pi` |
| step-contract prompts | one per J step, versioned in the repo | — |
| `bin/pr-review-local` | default reviewer script | bats for the contract, stub `claude` |
| `pr-act verify` / `autofix` | run configured commands, trim output | bats, stub commands |
| `bin/pr-watch` + launchd plist | state machine driver | bats |
| tab-title glyph | N2 | — |

## Suggested build order

**Manual first (decided 2026-10-12).** Every step is a `pr-act` verb chrismo
runs by hand; the watcher only starts dispatching them once each one behaves.
Each verb checks its own preconditions with `pr-state` and refuses with the
reasons (`--force` overrides the soft ones), so those checks *are* the state
machine's transition guards: the loop later calls the verb and the verb
decides. Verbs are written headless from the start (structured outcome, no
prompts, exit codes) so the watcher can call them unchanged.

1. `pr-state` — done
2. `pr-watch` observe-only + glyph + notifications — done
3. `pr-act address` (bot feedback) + harness adapter — done, see below
4. `pr-act restack` + `push` incl. reconciliation (squash fixtures are the core risk)
5. `pr-act verify` / `check` + `bin/pr-review-local`
6. bot trigger, retarget, describe
7. the loop: watcher dispatches verbs (below, "Process supervision")
8. `pr-act start` + implement; `pr-act attach`

## `pr-act address` — built 2026-10-12

`pr-act address [--force] [--no-publish] [--harness claude|pi] [<branch>]`:

1. Find the worktree that has the branch checked out (refuse if none or
   dirty), fetch, run `pr-state --json`.
2. Gate. Hard (never forced): no PR, PR not open, GitHub unreadable. Soft
   (`--force`): taken over, a restack that would conflict, sync unknown,
   unpushed, remote behind or diverged. Warn: CI still running, behind the
   target (a busy repo's branch is never caught up, so behind alone never
   blocks; [req-review #10](req-review.md)). Nothing owed → exit 0.
3. Fetch the owed bot items' text with one `nodes(ids:)` query; normalize to
   `{id, type, path, line, outdated, conversation}`.
4. Agent step: resume `branch.<b>.pr-session` or mint one (stored with
   `pr-harness` after a successful run), run under `settings.stepTimeout`
   (1800 s). Returns `{outcome, commit_message, summary, items: [{id, action,
   reply}]}`, action ∈ fixed / reply / pushback / ask. Claude: `--json-schema`,
   result in `structured_output`, edit tools only (commit, push, `gh` denied).
   pi: `--tools read,edit,write`, result parsed from a final ```json block.
5. Pipeline commits the edits (`gave-up` → nothing committed or posted), runs
   `settings.verify` (fail → commit kept, nothing pushed), prints the plan.
   `--no-publish` stops here; the agent has already run.
6. Push, then: threads get a reply (prefix `settings.replyPrefix`, default
   "🤖 "); fixed / reply resolve it, pushback stays open. Review bodies and PR
   comments get one combined PR comment and are added to
   `branch.<b>.pr-handled`. The comment links to each item by URL rather than
   quoting it: on 2026-10-13 a quoted Merge Simpson status comment carried its
   avatar URL (`…/merge-simpson.png`), whose `/merge-simpson` matched that
   workflow's `contains(body, ...)` trigger and started a new review. `ask` items (and any the agent skipped) are
   printed under "needs chrismo" and left alone.

**Trust:** a thread is handed over only if every comment in it is from a bot
(GitHub `Bot` type or `settings.botLogin`) or the viewer. Anyone else's text
could steer edits that `settings.verify` then runs and the push publishes, so
such threads go to "needs chrismo" untouched. The agent never runs shell
commands beyond read-only git (Claude) or none at all (pi); `verify` runs repo
code on agent edits, unsandboxed — `--no-publish` lets chrismo look first.

Not in v1: local review before the push, cycle cap, bot re-trigger, the
`accepted` pin, lease / lock. `botIgnore` (logins) keeps bots such as
`github-actions` from ever being owed; `botIgnoreBody` (regexes, matched against
bot review and PR comment bodies in `pr-state`) drops single posts such as a
review bot's "on the job" status without ignoring the account. Both are applied
before the agent sees anything, so ignoring is deterministic, not an
instruction. Inline threads are matched by author only (their bodies aren't
fetched by `pr-state`).

Residual: the agent's reply *text* is posted as written, so a reply could
itself carry a `/command` or `@mention`. Not handled; a deterministic scrub
before posting is the fix if it ever happens.

## Process supervision — plan for the loop (not built)

From Symphony SPEC §7–8 and Sortie (`orchestrator/reconcile.go`, `slot.go`,
`procutil/pgid_unix.go`, ADR-0002): a tick reconciles running work first, then
dispatches into free slots; exits are events with distinct reasons; state is
durable (Sortie's correction to Symphony's in-memory state). Our launchd pass is
short-lived, so it can't own children like their daemons do. Plan:

- The pass never waits on an agent: it launches `pr-act <verb> <branch>`
  detached.
- The verb is the supervisor of its own step: new process group, wall-clock
  deadline, writes an outcome record on exit.
- A lease file per running step (pid, pgid, verb, start, deadline, harness) is
  the claim — the missing "step in flight" record (req-review #4).
- Each pass reconciles leases before dispatching: live → skip the branch; past
  deadline → kill the group, "timed out"; pid gone with no outcome → "crashed".
- Global cap on concurrent steps, counted from live leases (start at 2).
- To verify first: whether launchd kills a finished job's leftover process
  group unless `AbandonProcessGroup` is set (from memory, unverified).

## To verify (spikes before building on them)

- ~~`--resume -p` keeps context across processes~~ observed for Claude (fork
  spike, below); `pi -p --session` still unverified
- resuming a session that's open interactively elsewhere — what breaks? (the
  lock exists to prevent it; confirm it's needed)
- `--json-schema` for the describe step; pi equivalent, or fall back to commit
  messages
- GitHub auto-retarget on parent merge
- ~~patch-id false-escalation rate in A2~~ confirmed real; switch to `-U0` (above)
- **Session ID stability:** Sortie's Claude adapter treats the minted
  `--session-id` as provisional and adopts whatever ID the runtime reports.
  Fork spike: plain `claude -p --resume U` kept U. One short run — keep a
  cheap guard (compare `session_id` in `--output-format json` to the stored ID;
  mismatch → log + adopt).
- **Fork per step instead of plain resume?** Roast resumes with
  `claude -p --resume <id> --fork-session` / `pi -p --fork <id>` by default and
  records the new ID each step emits. The parent session is never mutated, so a
  failed or bad step can be rerun from the same starting point (principle 5),
  and takeover could fork too. Cost: session lineage to track (one ID per step
  vs one per branch). Spike: does a forked step keep full context, and how does
  `pr-session` become "latest good fork"?
  **Claude half observed (2.1.296, haiku, 2026-10-11)** — script
  `spikes/fork-claude.sh`:
  - plain `-p --resume U` keeps session ID U (Sortie's ID-replacement concern
    not observed for plain resume)
  - `--resume U --fork-session` → new random ID; fork has full context
  - `--resume U --fork-session --session-id F` → **ID is F** — the pipeline can
    still mint fork IDs up front, nothing to discover
  - parent U is **unmutated** by forks (resuming U afterwards recalls only the
    pre-fork turns)
  **pi half observed (pi 0.99.1, cloudflare-ai-gateway
  `workers-ai/@cf/zai-org/glm-5.3-flash`, 2026-10-11)** — script
  `spikes/fork-pi.sh` (provider/model via `PI_SPIKE_PROVIDER` /
  `PI_SPIKE_MODEL`). Same four results as Claude:
  - plain `--session U` keeps ID U
  - `--fork U` → new ID (pi's is a UUIDv7) with full context
  - `--fork U --session-id F` → **ID is F**
  - parent U unmutated by forks
  Both harnesses therefore support "mint fork ID up front, parent stays
  clean" with the same shape: Claude `--resume U --fork-session --session-id
  F`, pi `--fork U --session-id F`.

## Known issues

- **`pr-state`: a clone of your own fork may not find the PR (untested).** If
  a repo is cloned from your own fork, gh may query the fork instead of the
  upstream project, so the PR wouldn't be found.
- **Glyph only shows when the title is redrawn.** The watcher writes the glyph
  file; the tab title picks it up the next time `tab-status` runs (a Claude hook).
  A tab with no Claude session never redraws, and the shell-prompt title
  (`set-title.sh`, deployed from the brain repo) doesn't read the glyph at all.
- **Same-named worktrees in two repos share a glyph file.** Glyph files are
  keyed by worktree basename, like `tab-status`'s own files. The branch check
  hides a mismatch unless both enrolled branches also share a name.
- **No command to unregister a repo (low priority).** `pr-act enroll` adds the
  main worktree to global `pr-tend.repo`, but `pr-act unenroll` only clears the
  branch mark, and `pr-watch uninstall` removes the whole launchd job. Nothing
  removes one repo from the list, so a repo you no longer want watched stays
  registered until `git config --global --unset pr-tend.repo <path>`. A
  registered repo with no enrolled branches, or a missing directory, is skipped,
  so the cost is clutter, not wrong behavior.

## Open

- **Scope:** this grew from "keep my PR current" into a small software factory.
  Ship tending first and layer initiation on, or build the full lifecycle?
- First initiator beyond `pr-act start` — Linear tickets via `claude-slot` /
  `ticket-sort`?
- First-remote-review rule for unlabeled PRs (proposed above; unconfirmed)
- Home bot command (TBD; config default handles it)
- Watcher interval (default 300 s; revisit after use)
- N2 channel beyond the tab glyph (PushNotification? `say`?)
- Agent-reply marking, if/when agents reply on human threads (deferred)
- **Fork per step** — spike done, both harnesses fork identically; now just a decision
- **Named harness profiles?** Reusable profiles (harness, provider, model,
  effort, args) that steps reference by name, in the config files. Not built;
  today a step names a harness and its block.
- **CI as a glyph on the one-liner** (tabled 2026-10-13): `✅` / `🔴` instead of
  `CI green` / `CI red`, for agent status lines.
- **Clearing `i` items without a reply** (`pr-act ack`?): held until `--long`
  has been used for a while.
- **TODO: move `pr-state`, `pr-act` and `pr-watch` from `jq` to SuperDB.**
  Decided 2026-10-13: SuperDB, always. `pr-config` is done. The rest still shell
  out to `jq`, including the `CLASSIFY` filter and the GraphQL shaping. Not part
  of the restack work.

## Prior art — summary

Full research (two rounds, 2026-10-11) is in `prior-art.md`;
clones in `~/modev/pr-workflow-prior-art/` (sortie, av, gh-stack, attractor, symphony, roast).

- **Nothing to adopt wholesale.** Sortie (closest: same `claude -p` adapter,
  orchestrator-driven) lacks pi, stacks, git-native state, takeover, and lets
  the agent push. Roast (Shopify) matches principles 1–3 and drives Claude +
  pi, but is a run-to-completion engine with no PR lifecycle.
- **Borrowed:** cancelled CI = inconclusive and the handed-off-comment set
  (Sortie); verify gate, split CI cap, autofix-first (Stripe Minions); scope
  check (Spotify Honk's judge); `-U0` patch-id and the Gerrit tree-compare
  candidate; session forking (Roast, pending).
- **Rejected:** agent-drives designs (Symphony, Gas Town); GitHub native stacks
  (`gh stack`, too heavy); LLM-app frameworks (LangGraph, CrewAI, Dify — wrong
  layer).
- **Still distinctive:** stack-aware restack with a post-condition, local review
  before the bot, git-native state.
