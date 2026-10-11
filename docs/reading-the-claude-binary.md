# Reading the Claude binary

Most of what agent-rig does depends on how Claude Code actually behaves: where
it records running sessions, how peer addressing resolves, what a roster row is
made of. Those questions were being answered by observation — probe a socket,
run `lsof`, compare two sessions, infer a rule. That's slow, and it leaves you
holding a theory.

The answers are in the shipped binary. `bin/claude-src` reads them.

```bash
claude-src 'cc-socks'                # grep the bundle, 2 lines of context
claude-src '[uds-messaging]' 4 2000  # 4 lines of context, 2000 columns wide
claude-src --path                    # where the extracted bundle lives
claude-src --which                   # which binary is being read
```

First run takes ~11s and caches; subsequent searches are ~0.3s. The cache is
keyed to the binary's filename, which is its version, so an upgrade re-extracts
on its own.

## Why it works

`claude` is a bun-compiled Mach-O of ~265MB. It contains a bytecode region — you
can see string constants in it but not structure — and, separately, the **JS
bundle as plain text**. No unpacking, no decompression, no section names.

`claude-src` scans the file in 64KiB blocks and keeps the ones that are >90%
printable ASCII. That's ~32MB of minified-but-readable source out of the 265MB.
Because it's a content heuristic rather than an offset or a section lookup, it
keeps working across version bumps.

Extraction also splits on `;`. The bundle is otherwise one enormous line, which
makes `grep` quadratic and its output unreadable.

## How to search it

The source is minified: identifiers are mangled, and they get *re-mangled every
build* — `tfa` is the session-registry reader in 2.1.224 and will be something
else in 2.1.230. Never search for a mangled name you wrote down last week.

Search for what a minifier cannot rename:

| Anchor | Example |
|---|---|
| Log prefixes | `[uds-messaging]`, `[bridge:peers]`, `[agentObserver]` |
| Env var names | `CLAUDE_CODE_MESSAGING_SOCKET`, `XDG_RUNTIME_DIR` |
| JSON field names | `messagingSocketPath`, `statusUpdatedAt`, `sendMessagePins` |
| Tool prompts | `Send the bare name`, `no "busy" state` |
| Error text | `Socket path too long`, `Refusing non-local socket path` |
| Path fragments | `cc-socks`, `"sessions")` |

Find one of those, then follow the mangled names around it — read the function it
sits in, then grep for that function's name to find its callers. Two or three
hops usually gets you the whole mechanism.

Tool prompts are worth calling out separately: the instructions Claude itself
receives for `SendMessage`, `ListAgents`, and the rest are in there verbatim.
When a skill in this repo documents how a built-in tool behaves, that prompt is
the authority — it's the same text the model is working from.

## What this has settled so far

Established against **2.1.224**. These are version-specific; re-check rather than
assume.

**The session registry.** Claude writes `~/.claude/sessions/<pid>.json` for every
running session and removes it on a clean exit. Fields include `pid`, `cwd`,
`sessionId`, `name`, `kind`, `status`, `statusUpdatedAt`, `startedAt`,
`procStart`, `messagingSocketPath`, `jobId`, `tmux`, `version`, `peerProtocol`.
Claude's own reader filters filenames on `/^\d+\.json$/`, liveness-checks with
`kill(pid, 0)`, and unlinks stale files.

- `kind` is one of `interactive`, `bg`, `daemon`, `daemon-worker`.
- `status` is one of `busy`, `shell`, `idle`, `waiting`.
- `procStart` is written in UTC while `ps -o lstart=` prints local time, so the
  two don't string-compare directly. Claude uses it to guard PID reuse;
  `claude-tabs` deliberately doesn't.

This replaced `pgrep` + `lsof` discovery in `bin/claude-tabs`, which could only
pair a directory's transcripts to its sessions by mtime rank.

**Self-identification needs no discovery.** Every session's environment already
carries `CLAUDE_PID`, `CLAUDE_CODE_SESSION_ID`, and
`CLAUDE_CODE_MESSAGING_SOCKET`.

**Peer messaging.** The socket path is `$XDG_RUNTIME_DIR || tmpdir()` +
`cc-socks/<pid>.sock`, capped at 103 bytes with a `/tmp/cc-socks-<uid>/`
fallback; directory mode `0700`, socket mode `0600`. The wire format is
newline-delimited JSON with a 1MiB line cap. The binary logs its own injection
recipe:

```
echo '{"type":"user","message":{"role":"user","content":"hello"}}' | socat - UNIX-CONNECT:<sock>
```

The `ListAgents` roster counts a session only if it recorded a socket path *and*
still answers a connection on it, so a leftover `.sock` file can't resurrect a
dead session.

**`SendMessage` addressing.** A row's `[ref]` is a hash of `<kind>:<id>`
truncated to 6 hex chars, extended only as far as needed to stay unique on the
roster; for a peer session the id is its socket path. A bare name resolves on its
own only for an in-process agent. For a peer, the first bare-name send returns an
ambiguity error listing candidates *with* their refs; sending once as
`name [ref]` writes a pin (`sendMessagePins`, in-memory, per session) after which
the bare name resolves. Status never rejects a message.

**Delivery receipts exist and nothing here uses them yet.** A sender can be told
`held` / `denied` / `expired` / `delivered` for a message, tied to its
`orig_msg_id` — i.e. you can learn that a peer's human is sitting on your
message. Read from source, not yet observed in practice.

## Scope

This is for understanding behaviour that agent-rig has to integrate with. It
reads a binary already installed on the machine; it doesn't modify, repackage, or
redistribute anything.
