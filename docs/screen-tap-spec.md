# Screen-Tap Spec

**Status:** future idea, not built. Captured from conversation 2026-05-13.

## Problem

The user often needs Claude to see what's happening on their terminal screen without giving Claude direct access to the underlying system. Concrete example: SSM'ing into an EC2, running `psql` against a prod database — Claude shouldn't have a connection, but it should be able to follow along so the user doesn't have to copy/paste output back.

The general shape: read-only shoulder-surfing. Universal across whatever app the user runs.

## The raw recipe

`script(1)` is a BSD-era utility that records every byte that hits the PTY. Wrap whatever command owns the terminal:

```
script -q -F ~/session.log <command>
```

Works at the PTY layer, so it's app-agnostic — psql, vim, an SSM session, a remote tmux. Doesn't matter. If it's on screen, it's in the log.

For SSM specifically, wrap the **local** SSM client, not the remote shell:

```
script -q -F ~/ssm.log aws ssm start-session --target i-xxxxx
```

`script` doesn't know or care that the shell is on EC2 — it's capturing bytes on your laptop's PTY.

### Flag differences (macOS vs Linux)

Classic foot-gun: the BSD and util-linux versions disagree.

| | macOS / BSD | Linux (util-linux) |
|---|---|---|
| flush on write | `-F` | `-f` |
| quiet | `-q` | `-q` |
| output file | positional | `-a` / positional |
| run a command | trailing args | `-c "cmd"` |

Mac: `script -q -F ~/log.log psql ...`
Linux: `script -f -q -c "psql ..." ~/log.log`

### Gotchas

- **TUIs are noisy.** Line-oriented tools (psql, shells, kubectl) log cleanly. Full-screen tools (vim, htop, less) dump alt-screen redraws and cursor-movement escapes — ugly but technically usable with an ANSI strip.
- **psql wants `\pset pager off`** to avoid `less` taking over and producing alt-screen junk.
- **`tee` is not a substitute.** `psql | tee` puts psql on a pipe instead of a TTY, killing readline and the pretty table formatting. `script` keeps the PTY.
- **Log grows forever.** Truncate between sessions or rotate.
- **SSM sends keepalive/heartbeat noise** that shows up as escape sequences — the ANSI strip matters more there than for plain local psql.

### Quick ANSI strip

```
sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' < session.log
# or
col -bx < session.log
```

## Automation surfaces

What's worth productizing in this repo:

### 1. A `bin/` wrapper

A small helper — call it `screen-tap` or similar — that:
- Picks the right `script` flags for the current OS.
- Defaults the log path to something predictable (e.g. `~/.claude/screen-tap/<timestamp>-<command>.log`).
- Rotates / truncates old logs.
- Optionally applies `\pset pager off`-style nudges when it detects psql in the wrapped command.

```
screen-tap psql ...
screen-tap aws ssm start-session --target i-xxx
```

Symlinked into `~/.local/bin/` by `install.sh` like the rest of `bin/`.

### 2. A companion skill for the consumer Claude

Skill at `skills/watch-screen/` that:
- Knows the default log location.
- Reads the latest log on demand.
- Applies the ANSI strip transparently.
- Surfaces a clean, line-oriented view to the Claude reading it.

Pairs naturally with `agent-read` (see `bin/agent-read` and the `consult` skill) — same pull-on-demand read model, different substrate (PTY log vs. Claude transcript JSONL).

### 3. Integration ideas

- **`/screen-tap start <cmd>`** — skill kicks off the wrapped command in a Ghostty split / new tab via Ghostty's keybind config or `ghostty +new-window`.
- **Multi-tap discovery.** Like `agent-read --peers --all --since <window>` lists recently-active Claude sessions, `/watch-screen` with no args could list `screen-tap` log files modified in the last N minutes.
- **Tail-mode for live updates.** v1 stays pull-on-demand; if a use case emerges for streaming, the Monitor tool over a `tail -F` is the natural fit.

## Open questions

- **Where to store logs.** `~/.claude/screen-tap/` keeps it self-contained; `/tmp` is more disposable. Probably the former so the consumer skill has a fixed search path.
- **Log lifecycle.** Truncate on each `screen-tap` invocation? Append with rotation? Keep last N sessions?
- **Should the wrapper auto-strip ANSI into a parallel `.txt` log,** or leave stripping to the consumer? Auto-strip is friendlier for Claude; raw `.log` is friendlier for `scriptreplay`.
- **Does any of this matter enough to build,** or is `script -q -F <path> <cmd>` short enough as a shell alias that the wrapper is over-engineering? The OS-flag-difference foot-gun is the strongest argument for a wrapper.

## How it's used in practice (2026-10-21)

Recording is rarely the path chrismo takes. The everyday options are:

- **A few lines:** copy/paste between the two Ghostty splits.
- **A long section:** Cmd+Shift+J has Ghostty write the whole terminal to a file and print the filename; chrismo pastes that filename into the Claude pane.

Both are instant and retroactive, and chrismo chooses what Claude sees. Recording has to be started before the pane's work begins, and the effort of pasting a filename is about the same either way.

Anything long-running that Claude can run itself, Claude runs directly, so an unattended *human* terminal is rare. The case recording exists for is a pane Claude must not touch, such as a connection to prod running a `/watch` in psql, with Claude monitoring the log. That's a back-pocket tool, not a daily one. Don't read its rarity as a reason to remove it.

## Out of scope

- Cross-host log shipping. v1 assumes consumer and producer are on the same machine.
- Sensitive-output redaction (passwords, secrets in psql output). Caller's responsibility.
- Replay (`scriptreplay`). The goal is live observation, not playback.

## Related

- `bin/agent-read` (+ `skills/consult/`) — sibling tool for Claude↔Claude observation via JSONL transcripts. Originally spec'd in `docs/follow-claude-spec.md`; spec was deleted once realized.
- `script(1)` man page — note the BSD/util-linux flag divergence.
