# The worktree setup hook

`bin/wt-new` creates a git worktree and then runs a per-clone setup command.
This file explains why that hook exists, where it lives, and what it guarantees.

## The problem

A new worktree of a large compiled project is useless for the first several
minutes of its life. The source is there instantly; the build artifacts are not,
and a cold build in a big Rust or C++ tree is measured in minutes, not seconds.
That cost is paid *every* time a worktree is created, which quietly discourages
creating them — and cheap worktrees are the substrate that `claude-send`,
`agent-read`, and the like run parallel sessions on.

The fix is per-repo and per-machine: some build state can be copied from a
sibling worktree far faster than it can be regenerated, and on a
copy-on-write filesystem it can be shared outright rather than copied at all.
That is a fact about *your* repo and *your* filesystem, not something a general
tool can know. So `wt-new` ships the mechanism and the repo supplies the command.

The shared-directory alternative — pointing every worktree at one build output
directory — is deliberately not what this does. Concurrent builds serialize on
that directory's lock, which defeats the point of running parallel sessions.
Worktrees stay independent here.

## Where the hook lives

After `git worktree add` succeeds, `wt-new` looks in two places, first match wins:

| Order | Location | Form |
|---|---|---|
| 1 | `$(git rev-parse --git-common-dir)/worktree-setup` | an executable script |
| 2 | `git config --get wt.setup` | a command string, run via `sh -c` |

Both are outside the working tree. That is the whole design constraint:

- **Nothing is added to a repo you don't own.** Setting this up on an upstream
  checkout adds no files to its tree and nothing to commit by accident.
- **Every worktree of a clone inherits it.** Both locations are in the git
  *common* dir, not the per-worktree git dir, so a worktree created from another
  worktree still finds the hook. Set it once per clone.
- **`git config --global wt.setup ...` gives a cross-repo default** for free,
  with per-repo config overriding it, by ordinary git config precedence.

Configure a clone once, from inside it:

```sh
git config wt.setup '<your command>'
```

## What the hook receives

Both forms run with the working directory set to the **new** worktree, and with:

| Variable | Meaning |
|---|---|
| `WT_SRC` | absolute path of the worktree `wt-new` was run from |
| `WT_DST` | absolute path of the new worktree |
| `WT_BRANCH` | the branch the new worktree is on |

`WT_SRC` is the worktree you were standing in, which is not necessarily the main
one — chaining a worktree off a worktree copies from the one you were in.

## Failure semantics

**A failing hook does not roll back the worktree.** A half-set-up worktree is
worth more than no worktree, and re-running the hook by hand is cheap while
re-creating the worktree is annoying. So on hook failure `wt-new`:

- keeps the worktree,
- still prints its path (so `new_wt` still lands you in it),
- reports the failure and the hook's exit status on stderr,
- exits nonzero.

The hook's stderr is passed through untouched — a hook that fails says why,
loudly. Its stdout is *relayed to stderr* rather than discarded, so a hook that
reports what it did stays visible.

## The stdout contract

`wt-new` prints **exactly one thing on stdout: the path of the new worktree.**
Everything else — git's own narration, the hook's stdout, the hook's stderr —
goes to stderr.

This is not cosmetic. `wt-new` cannot `cd` its caller's shell, so the shell half
in [`shell/rig.zsh`](../shell/rig.zsh) does `cd "$(wt-new "$@")"`. A single stray
line on stdout would `cd` somewhere nonsensical. `bin/wt-new.bats` pins this.
`bin/wt` follows the same contract for the same reason.
