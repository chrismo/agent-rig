# PR workflow — requirements review (acceptance walk-through)

> **Working document — not for long-term keeping.** This captures design work
> in progress for the PR workflow pipeline. Once the pipeline is built, the parts
> worth keeping move into the code, its README, or a short decisions record, and
> this file is deleted. Don't treat it as current documentation of anything that
> exists.

Acceptance cases played through `design.md` on paper, 2026-10-11. Nothing was
run: every item below is a **theory** reasoned from the doc, not an observed
failure. Section references (A2, O6, J3 …) point to `design.md`.

Scenarios walked: happy path (single branch, Claude); stack with parent open,
parent squash-merged, parent unpushed, parent closed; restack conflict;
takeover mid-step; foreign / GitHub-UI pushes; red CI incl. flaky; human
comments; local-review and bot pushback; bot never replying; many branches at
once; merge while a step runs.

Fix in the doc before building: **1, 2, 3, 5, 9**. Each one changes the stored
state or the state machine itself, not just its details.

## Would break the loop

### 1. A resolved restack conflict always escalates

*Case: stack, parent moved, rebase conflicts.* A2 stops on the conflict, J1
fixes it, and then the A2 post-condition compares patch-ids before and after.
A conflict resolution changes the branch's diff by definition, so the patch-ids
never match. The pipeline resets to the old HEAD and escalates: J1 can never
succeed.

Fix: apply the post-condition only to a clean rebase. After J1, the branch goes
through `check` (verify, then local review) instead.

### 2. Restacking breaks O6's "rewritten by rebase" check

*Case: clean restack after the `local` pin was set.* O6 compares `base..pin`
with `base..HEAD`, but A2 has just overwritten the one `base` ref. The old pin
was taken against the old base, so `new-base..old-pin` brings in upstream
commits and the comparison fails → needless J5 after every restack. Using
`merge-base` instead doesn't help after a squash merge. The Gerrit
tree-compare candidate needs the old base too.

Fix: record the base each pin was taken against (e.g.
`refs/pr-tend/<b>/local-base`, `bot-base`, `accepted-base`).

### 3. Lock / in-flight gates only agent steps, not mechanical ones

*Case: parent merges while a child's agent step runs, or while chrismo is
attached.* Watcher step 3 runs A2, A3 and A11 with no in-flight or lock check.
A restack between two of the agent's commits rewrites history under it. During
a takeover, "mechanical observation continues" doesn't say whether mechanical
*acts* continue.

Fix: anything that writes to the worktree or pushes is gated exactly like agent
steps.

### 4. "Step in flight" has no storage, and launchd may kill steps

O8 asks whether a step is in flight, but the storage table has no record for it
(pid, start time). Agent steps take minutes, so a watcher pass must detach
them. From memory, unverified: launchd kills a job's leftover process group
when the job exits unless `AbandonProcessGroup` is set — if so, steps die at
the end of each pass. A step also needs a wall-clock timeout:
`--max-budget-usd` doesn't catch a hang.

### 5. "Done = process exit" can't tell finished from asking

*Case: unclear task; agent commits partial work, then asks a question.* Exit 0,
clean tree, commits ahead → pipeline proceeds to review and the question is
lost.

Fix: the step contract returns an explicit outcome (done / needs-input / gave
up). Claude via `--json-schema`; pi via a parsed sentinel.

### 6. Pushback with no code change loops until the cap

- **Local review:** J3 rejects a finding, nothing changes, check reruns on the
  same HEAD, the reviewer raises the same finding, repeat until cap 3. Needs a
  record of dismissed findings — passed back to the reviewer, or used to pin
  `local`.
- **CI (J2):** "flaky, not ours" → no commit → same red SHA burns both CI
  rounds. A J2 "no change" outcome should go to A6 (rerun) or straight to
  chrismo.

## Gaps in the scenarios

### 7. Child started before its parent is pushed

*Case: `--parent A` while A is still in implement.* `origin/A` doesn't exist,
so A2's `<new-base>` has nothing to point at and `gh pr create --base A` fails.
Either the child waits for the parent's first ship, or the restack target falls
back to local `A`.

### 8. Parent closed without merging

O2 only knows open / merged; a child of abandoned work should escalate.
Related: after a child restacks onto `main`, should `pr-parent` be rewritten to
`main`? Otherwise every later pass looks up a dead PR.

### 9. Someone else's fast-forward is treated as a foreign push

GitHub's "Commit suggestion" and "Update branch", and fixer bots
(pre-commit.ci etc.), add commits on top of ours. Those SHAs aren't in our
reflog → escalate. A3 would also be rejected, because nothing ever pulls.

Fix: a reconciliation row "local is an ancestor of remote → `merge --ff-only`".

### 10. Root branches restack every time main moves

*Case: busy repo at work.* Goal 1 for a branch off `main` means restack → push
→ CI rerun → staleness check on every merge to main; it never settles. Root
branches need a policy: restack only on conflict, `mergeable` false, or when
branch protection requires up-to-date.

### 11. Nothing waits on a bot that never replies

O6's "bot replied since trigger?" has no timeout. A bot that's down leaves the
branch at ⏳ indefinitely.

### 12. Takeover while a step is running

`pr-act attach` would open an interactive resume of `$U` while a headless
resume of `$U` is still writing the same session. Attach must wait for or kill
the step. The lock also needs a pid + liveness check: a closed terminal skips
the release and stalls the branch silently.

## Smaller items

- **Non-draft PR at ship** triggers CODEOWNERS review requests before CI or the
  bot have run. Open as draft; `gh pr ready` at ✅.
- **Human threads have no verb.** "Agent, deal with this human comment" is
  likely the most common request and only works through attach. ✅ also ignores
  "changes requested" and missing required approvals.
- **J5 runs in the author's session** — the agent judges whether its own fix
  needs re-review. Better in the isolated reviewer process, like A8.
- **A7 resolves pushback threads.** It resolves after any reply; Cursor's rule
  (cited in prior art) is to resolve only when fully addressed.
- **Describe step has tools and could commit.** Ship doesn't recheck that
  `local` covers HEAD.
- **Takeover section contradicts the state machine.** It resumes "at the
  local-review check", but `check` runs verify first. And if chrismo answered a
  question and there are still no commits, it should re-run implement, not check.
- **`pr-tend.verify` per monorepo app doesn't fit git config** — keys can't vary
  by subdirectory. Needs a file under `.pr-tend/`.
- **No global concurrency cap.** With many enrolled branches, one pass could
  start N `claude -p` at once against one Max subscription.
- **Merge while a step runs.** Step 10 unenrolls, but the agent keeps working on
  a merged branch. Kill the step first.
