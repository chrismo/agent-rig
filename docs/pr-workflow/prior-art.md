# PR workflow — prior art

> **Working document — not for long-term keeping.** This captures design work
> in progress for the PR workflow pipeline. Once the pipeline is built, the parts
> worth keeping move into the code, its README, or a short decisions record, and
> this file is deleted. Don't treat it as current documentation of anything that
> exists.

Research behind `design.md`. Moved out of the design doc
2026-10-11; section references (A2, O6, J3 …) point there.

## Prior art considered (GitHub API, 2026-10-11)

| Repo | ★ | Notes |
|---|---|---|
| OrchestratorInc/agent-orchestrator (AO) | 13.1k | Only one with an automatic CI/review → agent loop. Desktop app + daemon, telemetry on by default, repo moved 3× (ComposioHQ → AgentWrapper → OrchestratorInc), 827 open issues. No stack mention. Owns agent launch. Its reaction model inspired the watcher. |
| herdrdev/herdr | 43.4k | terminal runtime, no PR loop |
| BloopAI/vibe-kanban | 28.3k | maker shut down |
| superset-sh/superset | 15.1k | PR feedback is manual |
| omnigent-ai/omnigent | 10.7k | meta-harness, young |
| smtg-ai/claude-squad | 8.6k | no PR loop |
| generalaction/emdash | 6.0k | shows PR/CI, user acts |

Babysitter skills (mblode `pr-babysitter`, dlc `babysit`, spencerpauly
`babysitting-pr`) — ideas only; none stack-aware. spencerpauly's "give up after
3 fix-push cycles" is adopted as the cycle cap.

Stacking tools: git-spice (stores base SHA — same approach as our refs),
git-town (stores parent in git config — same as our lineage). Note: `bin/gt`
collides with Graphite's `gt` CLI.

Claude Code Projects beta (coordinator + parallel threads + shared memory) is
cloud-only at launch per reports; not usable for local worktrees and stacks yet.

## Prior art, round 2 (2026-10-11)

Two research passes; metadata via `gh api` the same day. Shallow clones in
`~/modev/pr-workflow-prior-art/`: sortie, av, gh-stack, attractor, symphony, roast.

### Software-factory orchestrators

| Repo | ★ / license | Driver | Notes for us |
|---|---|---|---|
| sortie-ai/sortie | 198, Apache-2.0, Go | orchestrator | **Closest match.** Symphony-derived but pulled control back to the orchestrator (ADR-0007). Claude adapter = `claude -p --output-format stream-json --session-id` then `--resume` — our adapter. SQLite state. ADRs: cancelled CI = inconclusive (0023), retry budget resets per HEAD (0024), self-review before completion (0021), bot-comment fingerprint + handed-off set. Read-only on the forge (never replies/resolves). No stacks. |
| openai/symphony | 27.6k, Apache-2.0, Elixir | **agent** | Created 2026-02-26; v0.0.1 2026-07-18, v0.0.3 2026-09-15. `SPEC.md` + reference impl. Linear polling, per-issue workspace, repo-owned `WORKFLOW.md`. Tracker state is the human lock. Agent does PR/CI/review via prompts + skills — opposite of our principle 2. Worth reading: §7–8 reconcile/retry. |
| strongdm/attractor | 1.3k, Apache-2.0 | pipeline (DOT graph) | Specs only, no code. JSON checkpoint per node, goal gates, per-edge context fidelity (default `compact` = fresh session). "No human code review" philosophy. |
| coleam00/Archon | 23.7k, MIT | pipeline (YAML DAG) | `bash:` + `prompt:` nodes, `loop: until:`, human gates, worktree per run, `fresh_context`. Claude-centric, web UI. Closest to principles 1–2 philosophically. |
| gastownhall/gastown (+ beads, gascity) | 18.3k, MIT | **agent** | Long-lived tmux agents; Bors-style merge queue; integration branches instead of stacks. `docs/design/factory-worker-api.md` lists 28+ fragile tmux/scraping touch points — evidence for headless `-p`. |
| AnandChowdhary/continuous-claude | 1.4k, MIT | bash | Ralph loop, one PR per iteration, `gh pr checks` → merge or discard. |
| Shopify/roast | 1.25k, MIT, Ruby | pipeline (Ruby DSL) | **Closest philosophically after Sortie.** Workflows of "cogs": `cmd`, `agent`, `ruby`, `chat`, `repeat`, `map`, `call` — deterministic + agent steps interleaved by design. Agent cog drives **both Claude and pi** via CLI (`claude -p --output-format stream-json [--resume --fork-session]`, `pi --mode json -p [--fork]`; read in `lib/roast/cogs/agent/providers/`). Forks the session per step by default (see design doc, To verify). Run-to-completion engine: no watcher, no PR lifecycle, no stacks. Could at most run individual steps; mainly a reference for step / session mechanics. |
| Ralph (snarktank/ralph, ghuntley) | 21.9k / 1.8k | bash | Fresh process every loop; state in files + git. |
| Spec Kit / BMAD / Kiro | — | — | Upstream of us (spec → tasks); no CI/review loop. Could feed `pr-act start`. |
| Sculptor, container-use, Nimbalyst, Conductor, Terragon | — | — | Desktop apps / isolation / shut down. Not pipelines. |

### Sortie fit, in detail (from its docs, not run; 2026-10-11)

| Our design | Sortie |
|---|---|
| Pipeline drives every step, incl. push + PR | Orchestrator drives CI / review / merge reactions, but **the agent or a hook pushes and opens the PR**, then writes `.sortie/scm.json` (SHA, PR number) for the orchestrator to read. Its own `WORKFLOW.md` puts `git push` in a hook. |
| Claude + **pi** | Claude Code, Copilot, OpenCode, Codex, Kiro, Gemini, generic ACP. **No pi.** |
| Worktrees, stack-aware restack | Fresh clone per ticket via `after_create` hook (a worktree hook might work). **No stacks.** |
| Git refs + git config | SQLite |
| `pr-act start "<task>"` | Tracker ticket (GitHub, GitLab, Gitea, Linear, Jira); a read-only JSON-file tracker for local tasks. |
| Local review before bot | "Self-review" phase (verification commands + agent review turn) before the completion signal is accepted. Similar idea. |
| Takeover: lock + interactive resume | None. Parking label; remove it or move the ticket to release. |
| Small | 29 architecture docs + 34 ADRs, very detailed. Possibly heavy, like gh-stack. |

Maturity: created 2026-03-17, 198★, 20 forks, commits daily; appears to be one
person or a small team.

**Verdict: design reference, not a base.** Adopting it means giving up (or
writing an adapter for) pi, giving up (or adding) stacks, accepting SQLite, and
letting the agent push. The value is its reaction contracts: architecture docs
12–16 (CI, review, auto-merge, bot review, merge conflict), 19 (failure /
recovery), and the ADRs — these map onto our O5–O7 / J2–J4.

**Direct competitors** (ticket → agent → PR daemons): openai/symphony (Linear +
Codex, agent drives), OasAIStudio/symphony-ts (unofficial TS port, Apache-2.0,
not deeply checked), AO, Archon, Gas Town, continuous-claude. Closed / cloud:
Copilot coding agent, Codex cloud, Cursor background agents, Devin. None is
local + worktree + pi + stack-aware.

### PR feedback loop and stacking

| Repo / product | Notes for us |
|---|---|
| github/gh-stack (1.6k, MIT, v0.20) | Native stacked PRs GA 2026-10-06: server-side restack, approvals survive, base not editable. Squash handled with the same `rebase --onto` as A2. Moved its JSON store from per-worktree to git common dir (`internal/stack/migration.go`) — supports our shared refs. **Not adopted** (see design doc, Decisions). |
| aviator-co/av (508, MIT) | Same A2 algorithm: stores parent + branching-point SHA + merge commit in `.git/av` JSON; falls back to merge-base. Skips rebase when already on new parent; `PrepareWorktrees` handles branches checked out elsewhere. No post-condition. Read `internal/sequencer/`. |
| ezyang/ghstack, spacedentist/spr | Never force-push PR branches (append "base update" commits / merges) — mainly to keep review threads anchored. Informs O7's outdated-thread handling. |
| ejoffe/spr, modular/stack-pr, mergify-cli | One commit per PR, identity in a trailer. Doesn't fit our branch-per-PR model. |
| Gerrit | TRIVIAL_REBASE / NO_CODE_CHANGE via in-memory replay + tree compare — candidate for O6 (design doc). |
| anthropics/claude-code-action | `examples/ci-failure-auto-fix.yml`: script gathers failed logs, agent fixes on a separate branch (name prefix = loop guard), no cycle cap. |
| OpenHands resolver | Post-step LLM check per thread ("incorporated?") + generated reply. |
| Cursor Bugbot autofix (closed) | One comment at a time; reply instead of guessing on design questions; resolve only if fully addressed. Same rules as J3/A7. |
| Copilot coding agent, Graphite Agents, Jules (closed) | User-triggered; no unattended CI-fix loop found. |

**In-house platforms (blog / talk reports, unverified):** Stripe Minions (Slack
/ ticket → one-shot PR, human review; reportedly a Goose fork + 400-tool MCP
server), Ramp Inspect (remote sandboxes, self-verifies frontend + backend),
Spotify Honk (Claude Code harness, fleet migrations, Slack status), Uber,
Harvey. Mostly cloud sandboxes behind Slack at company scale; overlap with us is
step design and readiness checks.

**Wallfacer + Spotify Honk + Stripe Minions part 2** (subagent read via
WebFetch summaries, 2026-10-11 — spot-check quotes before citing):

- Converged shape (Wallfacer): sandbox per task, chat/ticket intake, closed
  feedback loops, PR out, **human merges**.
- **Stripe "Blueprints"** = code-defined workflows mixing deterministic nodes
  (lint, push) with agent nodes (implement, fix CI) — essentially our Lifecycle.
  Lint loops locally before push. **CI capped at 2 rounds** (autofixes applied
  before the agent node), then back to the human: full CI is too expensive to
  iterate on.
- **Spotify Honk:** Fleet Management stays deterministic; agent only replaces
  the transformation script. Agent tools restricted (git tool can't push; bash
  allowlist). Old loop capped at 10 turns/session × 3 retries. **Verifiers**
  activated by repo contents (pom.xml → Maven), callable by the agent as MCP and
  run by the harness via a Claude stop hook before any PR; output regex-trimmed;
  failure → no PR. **LLM judge** gets diff + original prompt, vetoes ~¼ of
  sessions, top reason scope creep. CI after PR-open = future work.
- Ramp opens PRs with the requester's token (no self-approval). Uber uReview =
  deterministic generate → filter → validate → dedupe around the LLM.
- None of the sources describe an agent addressing PR comments — J3/J4 has no
  outside evidence either way.

Candidate changes these suggested (**decided 2026-10-11** — 1–4 adopted, 5 rejected; see design doc Decisions):
1. **Deterministic verify before A8:** `pr-tend.verify` (lint / build / test,
   output trimmed) runs before the LLM reviewer; optionally exposed to the
   agent in J0's step contract.
2. **Split caps:** local loops 3; remote CI rounds 2; deterministic autofix
   (formatters, `lint --fix`) before J2.
3. **Scope judge:** pass `PR_TEND_TASK` to the local review contract so the
   reviewer can flag work outside the task.
4. **Cheap enforcement alongside reconciliation:** per-step tool deny for
   push / PR create (Claude `--disallowedTools`; pi equivalent unchecked).
   Principle 4 stays as the fallback.
5. **Per-step turn cap** next to `--max-budget-usd`, if both harnesses have one.

**Wrong layer, considered and skipped:** OpenHands is a harness (peer of
Claude / pi), not an orchestrator — only its resolver's verify-before-reply idea
applies (design doc, Decisions: "Verify before reply"). LangGraph, CrewAI and Dify build agents from raw model
API calls, so they'd replace Claude / pi rather than drive them (breaks principle
3) and add a Python / server runtime; CrewAI's role-play is the opposite of
principle 1.

**Still distinctive to this design:** stack-aware restack with a post-condition,
local review before the bot, git-native state (refs + config). Nobody else found
does all three.
