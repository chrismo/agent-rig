# Messaging running Pi sessions

Research notes, 2026-11-04. `claude-send` can send from Pi to Claude Code,
but currently only Claude sessions are addressable. These are candidates for
delivering messages into a **running Pi session**, including waking it when idle.
None has been tested in this rig; popularity is not proof of reliability or
compatibility with our installed Pi build.

## Candidates

### [pi-messenger](https://github.com/nicobailon/pi-messenger)

The strongest adoption signal for Pi-to-Pi messaging: approximately 730 GitHub
stars and 294 npm downloads in the last week when checked. Agents join a
file-based mesh, discover peers and send direct messages; recipients wake and
receive messages as steering prompts. Also includes task orchestration, file
reservations and a chat overlay. Primarily a Pi mesh, not a drop-in target for
`claude-send`.

### [inter-agent](https://github.com/arcanemachine/inter-agent)

Most directly suited to Claude Code ↔ Pi: each connects to a shared message bus
through a host adapter. The [Pi adapter](https://github.com/arcanemachine/inter-agent-pi)
queues messages by default; immediate delivery puts them in follow-up context
and wakes an idle Pi. Requires a local server and Python helper. The Pi adapter
had 11 stars when checked; promising, but not evidence of broad adoption.

### [pi-rpc-socket](https://github.com/lukastk/pi-rpc-socket)

A per-session Unix socket inside interactive Pi. Any local process can send a
JSON message, query state or subscribe to responses. Messages wake an idle Pi
or steer a busy one. This is closest mechanically to the existing
`claude-send` approach and could be a building block for a rig-specific bridge,
but it is not a drop-in replacement. It had no stars when checked and also
exposes powerful operations, including abort and system-prompt injection;
review its security and access controls before use.

### [agent-mailbox](https://github.com/a3harva/pi-mailbox)

A shared durable mailbox with Claude Code hooks and a Pi extension. Its docs
say normal and urgent mail wake idle Pi sessions; message obligations persist
until closed or deferred. Very limited adoption (one star when checked). Its
installer edits home-directory configuration directly, conflicting with this
repo's install workflow; integration would need to be managed through the repo.

## Next step

For Pi-to-Pi, evaluate **pi-messenger** first. For Claude ↔ Pi, evaluate
**inter-agent** first, or investigate a socket-based bridge if retaining the
existing `claude-send` workflow matters more than adopting a separate bus.
Verify compatibility with our Pi build, delivery while idle and busy,
discovery, replies, and security before adopting any of them.
