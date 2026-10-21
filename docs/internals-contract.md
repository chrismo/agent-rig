# The internals contract

agent-rig reads things Claude Code does not expose as a supported API. All of
it can change in a point release, without notice and without a changelog entry.

This file is the inventory of those assumptions. Each has an ID, and the same ID
names a test in [`bin/claude-contract.bats`](../bin/claude-contract.bats). The
suite is the executable half; this file is the half that says *why it matters*
and *what to do when it goes red*.

```bash
bats bin/claude-contract.bats
```

`hooks/internals-drift.sh` fires on SessionStart and tells you to run it
whenever the running version differs from `docs/verified-against`. It never
checks anything itself — Claude Code upgrades without running `install.sh`, so a
version change is simply the moment to look.

## Why a version bump is the trigger, not a failing assertion

An assertion can keep passing while the meaning underneath it changes. During
this work, `SendMessage`'s "there is no busy state" stayed literally true —
messages are never rejected for busyness — while the roster gained a visible
`status` field, which made the documented claim read as "no such field". Nothing
would have gone red. Only re-reading on a version change catches that class.

So: green suite plus a stale stamp means *unverified*, not *fine*.

## The assumptions

### A — peer messaging (source anchors)

Checked by grepping the installed bundle with `bin/claude-src`. Anchors are
string literals, never identifiers: identifiers are re-mangled every build, so
asserting on one would fail for a rename that broke nothing.

| ID | Assumption | Relied on by | If it fails |
|---|---|---|---|
| A1 | The `uds-messaging` subsystem exists | `pod-peer` skill, [protocol doc](inter-claude-protocol.md) | Peer messaging was restructured. Re-read the module before trusting anything in the protocol doc. |
| A2 | Sessions advertise a socket via `messagingSocketPath` | `claude-tabs`, reachability marking | Reachability can no longer be read from the registry. Find the new field. |
| A3 | A session learns its own address from `CLAUDE_CODE_MESSAGING_SOCKET` | self-identification | Self-exclusion from rosters may break; find the new source. |
| A4 | Wire format is newline-delimited JSON (the logged `Inject messages` recipe) | any hand-written socket write | Direct socket injection is unsafe. Stop writing to sockets until re-derived. |
| A5 | Refs are `sha256(...)` cut to 12 (`digest("hex").slice(0,12)`) | offline ref computation | Every computed ref is wrong. Re-derive before using refs anywhere. |
| A6 | The `sendMessagePins` mechanism still exists | `pod-peer` guidance on addressing | Pins are gone; name resolution works some other way entirely. Re-check the skill's addressing section. |
| A7 | Sockets live under `cc-socks` | protocol doc, any socket path building | Socket discovery paths are wrong. |

### B — the session registry

`~/.claude/sessions/<pid>.json`, one file per running session.

| ID | Assumption | Relied on by | If it fails |
|---|---|---|---|
| B1 | The registry directory exists | `claude-tabs`, `agent-read` | Session discovery is gone; `claude-tabs` falls back to nothing. Check whether it moved before rewriting anything. |
| B2 | Files are named `<pid>.json` | `claude-tabs read_registry` | The filename is how the PID is known. A rename breaks liveness checks. |
| B3 | Records carry `pid`, `sessionId`, `cwd`, `kind`, `status`, `startedAt` | `claude-tabs`, `agent-read` name map | Whichever field vanished — `sessionId` is the worst, it's the transcript join. |
| B4 | `kind` ∈ `interactive\|bg\|daemon\|daemon-worker`, `status` ∈ `busy\|shell\|idle\|waiting` | status rendering | A new value renders as garbage rather than crashing. Add it. |

### R — runtime activation

Everything above asserts that a mechanism is *present*. This group asserts it is
**running**, which is not the same thing and was not always true.

On 2026-08-08 cross-session messaging was off for newly started sessions for
part of the morning. Every A-series anchor stayed green the whole time — the
code was all in the bundle, it just wasn't activating. The gate is evaluated at
startup (`tengu_harbor_kite`, overridable with `CLAUDE_CODE_HARBOR_KITE`), so a
session can be on a build that fully supports messaging and still have no inbox.

| ID | Assumption | Relied on by | If it fails |
|---|---|---|---|
| R1 | This session has a live inbox (`CLAUDE_CODE_MESSAGING_SOCKET` set, socket bound) | everything peer-related | Messaging did not activate for this session. Check the startup gate, not the bundle — the A-series will still be green. |
| R2 | Live sessions on the **installed** build are getting inboxes | new sessions | Newly started sessions come up with no inbox, even while this one still works. `CLAUDE_CODE_HARBOR_KITE=1` forces the gate open. |

R1 guards on `CLAUDE_CODE_SESSION_ID`, not on the messaging variable —
deliberately. Guarding on the messaging variable would make the test *skip*
in exactly the case it exists to catch.

R2 looks at the installed build rather than the running one because that is
what the next session will launch: R1 can stay green on a long-lived session
while every new one comes up dead.

### E — addressability (what `claude-send --ask` stands on)

`--ask` gets a reply by telling the peer to answer a `uds:` socket path. That is
the load-bearing assumption. Registration is a *separate*, opt-in capability
(`--register`) that makes the asking process visible on the roster; `--ask`
works without it.

| ID | Assumption | Relied on by | If it fails |
|---|---|---|---|
| E4 | A `uds:` socket path is a valid `SendMessage` target — the tool prompt says to copy a `from` attribute as your `to` | **`claude-send --ask`** | `--ask` is dead: the peer has no way to answer a shell. Fall back to reading the peer's transcript for its reply. |
| E3 | Attribution is a text wrapper inside `message.content`, not a verified field | `--ask` reply parsing | The envelope moved. `--ask` prints protocol furniture, or nothing, instead of the answer. |
| E1 | The registry directory is writable by us | `--ask --register` only | `--register` must fail loudly rather than hang. Plain `--ask` is unaffected. |
| E2 | A roster entry needs only a live pid + an answering socket — no proof of being a real Claude | `--ask --register` only | Registration is being validated (signature, cookie, process identity). Drop `--register`; plain `--ask` keeps working. |

**E4 is the one that matters now.** It is what a reply rides on.

E2 is the one most likely to be *deliberately* closed off, since it is what lets
a non-Claude process pose as a peer — and closing it would be a reasonable
change, not a bug. It used to be load-bearing for `--ask`; it no longer is, so
losing it costs visibility, not function. Do not work around it.

### C — transcripts

The widest blast radius in the repo: seven scripts read these
(`agent-read`, `agent-search`, `claude-tabs`,
`work-context`, and the three `session-*.sh`). It is also the surface most
likely to change quietly, because it is a data format rather than a
mechanism.

| ID | Assumption | Relied on by | If it fails |
|---|---|---|---|
| C1 | The projects dir encodes a worktree as `-Users-name-…` | every transcript reader | No script can find the right directory for a worktree. |
| C2 | Transcript lines are JSON objects with `.type` | every transcript reader | Rendering and filtering break wholesale. |
| C3 | `user`/`assistant` records nest content under `.message.content` | `agent-read` rendering, usage scripts | Conversations render empty. |

### D — the stamp

| ID | Assumption | If it fails |
|---|---|---|
| D1 | `docs/verified-against` matches the running build | Not a breakage. The assumptions were confirmed against a different build. Re-verify — **including the behavioural checks below** — then bump the file. |

## What is automated, and the one thing that isn't

`bin/claude-send` reimplements discovery, ref derivation and sending in the
shell, so most of the behavioural half is now machine-checkable — `bats
bin/claude-send.bats` stands up real unix sockets and exercises the probe and
the send for real:

- **Roster contents** — `claude-send --list` builds its own roster from the
  registry plus a connect probe. Compare it against a Claude session's
  `ListAgents` output; the names and refs should match row for row.
- **Ref derivation** — computed with `shasum -a 256` and asserted in the suite.
- **Reachability** — asserted directly: a socket file with no listener behind it
  must not appear, and a send to it must fail.
- **Delivery** — a full round trip (write to a socket, confirm the bytes land)
  runs against a real listener in the suite.

**The one genuinely manual check is Claude's tool layer**, because bash cannot
call `SendMessage`:

- **The addressing rule.** Send to a peer by bare name with no prior pin: a name
  matching exactly one live row should land. Send to a prefix matching two or
  more rows: it should be rejected with an error naming their refs. Send with
  the ref: it should land. A change here means the `pod-peer` skill's addressing
  guidance is wrong.

  Prefer the ambiguous-prefix probe for the rejection half — it is refused
  sender-side and never reaches anyone, so it costs no peer a turn. Every probe
  that *lands* interrupts a working session, so say in the message that it is a
  contract probe and that no reply is needed.

  A `success` tool result proves only that the socket accepted the bytes. If the
  delivery half is what you are checking, confirm from the receiving end.

That distinction matters: `claude-send` proves the *transport and registry*
still work. It cannot prove that Claude's own resolver, pins and message
envelope are unchanged, because it deliberately bypasses all three.

Recorded in [inter-claude-protocol.md](inter-claude-protocol.md) with the exact
commands and their last observed output.

## When something goes red

1. **Don't rewrite the consumer first.** Find out what the mechanism became —
   `bin/claude-src` with a string literal from the same area is usually two or
   three hops from the answer. See [reading-the-claude-binary.md](reading-the-claude-binary.md).
2. **Update the doc that owns the claim**, not just the test. Each row above
   names one.
3. **Then** fix the consumer, and only then bump `docs/verified-against`.

Bumping the stamp is the last step, and it asserts something specific: that
every A–C assertion passed *and* the four behavioural checks were run. Bumping
it to silence the hook without doing the second half is how this whole thing
quietly stops being true.

## Adding an assumption

When you make something in agent-rig depend on a new Claude Code internal, add
a row here and a matching test. The rule of thumb: if a Claude Code release
could break it and you would not find out until a user hit the bug, it belongs
in the contract.
