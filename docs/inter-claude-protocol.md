# The inter-Claude messaging protocol

How one Claude Code session addresses and talks to another on the same machine.
Established against **2.1.224** and re-verified unchanged on **2.1.226** —
including all four behavioural checks in
[internals-contract.md](internals-contract.md) — by reading the shipped bundle with
`bin/claude-src` and verifying against live sessions. See
[reading-the-claude-binary.md](reading-the-claude-binary.md) for the extraction
method and its caveats — most importantly that identifiers are re-mangled every
build, so every citation below is a **string literal**, not a function name.

Two claims here are verified empirically, not just read. They're marked
**VERIFIED**. Everything else is read from source; where a claim is neither
verified nor directly read, it says so.

## 1. How the `[ref]` is derived — VERIFIED

`ListAgents` prints each row as `name [ref]`. The ref is a **SHA-256 of
`<kind>:<id>`, hex, truncated to 6 characters**, lengthened only as far as
needed to stay unique on the current roster.

The rendering is a one-liner:

```js
function zLe(e){return `${e.name} [${e.ref}]`}
```

The computation, and the collision walk that decides the length:

```js
function kLp(e,t){ return String(uu(`${e}:${t}`)) }   // hash of `kind:id`
var RLp = 6                                           // base length
// inside the roster builder:
let t = e.map(r => kLp(r.kind, r.id))
return e.map((r,n) => {
  let o = t[n], i = RLp
  while (i < o.length && t.some(s => s !== o && s.slice(0,i) === o.slice(0,i))) i++
  return {...r, ref: o.slice(0,i)}
})
```

For a peer session, `kind` is the literal `session` and `id` is that session's
`messagingSocketPath`. So:

```
ref = sha256("session:" + messagingSocketPath).hexdigest()[:6]
```

`uu` is the bundle's hash helper:

```js
function uu(e){ return yp(V_u.createHash("sha256").update(e).digest("hex").slice(0,12)) }
var V_u = require("crypto")
```

Note the **`.slice(0,12)`**: the digest is cut to 12 hex characters before the
ref logic ever sees it. So the collision walk above can lengthen a ref to at
most 12 characters, not 64 — with enough colliding sessions the loop exits on
`i < o.length` and returns a ref that is *not* unique. Nothing on a normal
machine will get near that.

This was also confirmed independently by result, before the definition was
found: of md5, sha1, sha256, sha512, blake2b, blake2s and sha3-256, only sha256
reproduced the observed refs, and it reproduced all four.

**Verification.** Computed from `~/.claude/sessions/*.json` and compared against
a live `ListAgents` roster:

```
name                   pid  computed ListAgents match
q-chat-rooms         21797  b58096   q-chat-rooms   OK
agent-rig-two       30571  1f4a1e   agent-rig-two OK
agent-rig-one       30739  2ee790   agent-rig-one OK
q-chat-rooms-6f      81153  3ca88e   q-chat-rooms-6f OK
```

Two consequences worth knowing. A ref is a function of the **socket path**, so
it is stable for a session's whole life and changes when the session restarts
(new PID → new path → new ref). And it is *not* derived from the session UUID —
searching `~/.claude/projects` for a transcript whose name starts with a ref
will never match.

## 2. The message envelope

The wire format is **newline-delimited JSON**, one message per line, 1MiB line
cap. The binary logs its own injection recipe at startup:

```
[uds-messaging] Inject messages: echo '{"type":"user","message":{"role":"user","content":"hello"}}' | socat - UNIX-CONNECT:<sock>
```

**VERIFIED** — a raw `AF_UNIX` write of exactly that shape (plus `\n`) into
another session's socket appeared in its conversation as a genuine user turn,
which it then answered. The write is fire-and-forget: nothing is returned on the
same connection.

### `type: "user"` — a message for the peer's conversation

What a real send puts on the wire:

```js
{...c, type:"user", message:{role:"user", content:l}, priority:"next", from:a,
 ...(n?.length ?? 0) > 0 && {file_attachments:n}}
```

`c` carries the generated `msg_id`. `priority` is `next` for an ordinary send;
`now` exists and is dispatched differently (below). `file_attachments` is
omitted entirely when empty.

A capture of a real `SendMessage`, taken by having a non-Claude process receive
one (below), shows what actually goes on the wire:

```json
{"msgV":1,
 "msg_id":"14292e75-85cb-4548-b368-b1258f2cc43c",
 "type":"user",
 "message":{"role":"user","content":
   "<cross-session-message from=\"uds:/tmp/cc-socks/98880.sock\" from-name=\"agent-rig\" from-mode=\"prompting\">\n…\n</cross-session-message>"},
 "priority":"next",
 "from":"uds:/tmp/cc-socks/98880.sock"}
```

Two things there are easy to get wrong.

**`msgV` is a protocol version field.** Worth checking on an upgrade; a bump is
the clearest possible signal that the envelope changed.

**The envelope's `from` field is not what the model sees.** It is on the wire
and it is load-bearing — the hold-receipt path reads it to route
`peer_message_status` back, and refuses an address outside its own socket
directory. But nothing surfaces it to the receiving *model*, which reads only
`message.content`. Setting it on a hand-written message gives the peer nothing
to answer; writing the address into the content does.

### `type: "control"` — out-of-band actions

Two actions are handled; anything else is logged and dropped
(`Unhandled control action`):

- `rename` — carries a `name` string, renames the receiving session.
- `peer_message_status` — a delivery receipt (below).

### Delivery receipts

A sender is told what happened to a message it sent:

```js
{action:"peer_message_status", status:a, reason:tES(a), from:i,
 ...typeof l?.msg_id === "string" && {orig_msg_id: l.msg_id}}
```

`status` is one of `held`, `denied`, `expired`, `delivered`. The sender keeps a
bounded ring buffer of outstanding sends and matches receipts by `orig_msg_id`;
an unmatched receipt is dropped with:

```
[uds-messaging] peer_message_status dropped: no outstanding send matches orig_msg_id=…
```

Practically: **you can learn that a peer's human is sitting on your message**
(`held`) or refused it (`denied`). Nothing in agent-rig uses this yet.

### Dispatch ordering

A message that is `control`, or is `user` with `priority:"now"` and no
attachments, is processed immediately. Everything else is appended to a promise
chain and processed in order — so ordinary sends queue behind whatever the
receiver is already draining.

### What the receiver rejects

The server's own log lines enumerate its validation, and they're the cheapest
map of what it will refuse:

```
[uds-messaging] Ignoring message without valid type field
[uds-messaging] Ignoring user message with missing or non-string content
[uds-messaging] Dropping ${e.type} message: session_id mismatch
[uds-messaging] Buffer exceeded 1 MiB without newline
[uds-messaging] Failed to parse JSON line: …
[uds-messaging] Failed to materialize file_attachments: …
[uds-messaging] Routed user message to queue (priority=${i}): …
[uds-messaging] Skipped: cross-session messaging gate off
[uds-messaging] Skipped: remote thin client
[uds-messaging] Refusing non-local socket …
```

Two of these matter for anyone writing to a socket by hand. Malformed input is
**silently discarded** — the server logs and moves on rather than replying or
closing, so a probe with the wrong shape looks identical to a probe that was
ignored for any other reason. And a `session_id` mismatch drops the message, so
a wrong `session_id` fails quietly.

There are also two conditions under which a session never opens a socket at all
— the cross-session messaging gate being off, and running as a remote thin
client. Either produces a live session with no `messagingSocketPath`.

Sending has its own guards: a 5s timeout, and a refusal to connect anywhere
non-local (`Refusing to connect to non-local IPC path`). On macOS the writer
delays `end()` briefly after writing rather than closing immediately.

### Sender attribution is advisory, not enforced

The `<cross-session-message from=… from-name=… from-mode=…>` wrapper a receiving
Claude sees is constructed by the **`SendMessage` tool**, not by the socket, the
daemon, or anything in the transport.

Established by comparing four deliveries into one session:

| sender | envelope seen by receiver |
|---|---|
| raw `AF_UNIX` write | none |
| `bin/claude-send` | none |
| `SendMessage` with a ref | present, populated |
| `SendMessage` with a bare name | present, identical |

The mechanism is visible in the capture above: the wrapper is **text inside
`message.content`**, not a field on the envelope. The receiving model reads
message content; it never sees `from`.

That single fact explains all of it:

- A raw socket write arrives **bare**. Asked directly, a receiving session
  reported: *"I cannot see a sender address on this message. It arrived bare —
  no `<cross-session-message>` wrapper, no `from`, no `from-name`."*
- Setting the envelope's `from` **field** changes nothing the model can act on:
  the receiver reads content, and the sender never wrote the address into it.
- Attribution is **forgeable by writing the wrapper text yourself**. A
  `from-name` is a claim, not proof.

**This is not the same as "you cannot reply to a `from` address."** A `uds:`
path is a perfectly valid `SendMessage` target:

```json
{"to": "uds:/tmp/cc-socks/30739.sock", "message": "…"}   // accepted
```

Verified both directions: a peer copied a `from` attribute out of a message and
replied to it, and a send addressed straight at a `uds:` path was accepted. The
tool's own prompt says to do this — *"To reply to an incoming message, copy its
`from` attribute as your `to`."*

So the accurate statement is about **what the receiver was given**, not about
routing: a raw write that omits the wrapper leaves the receiver nothing to copy.
Write the address into the message and a reply comes back. Routing was never the
problem.

The security boundary is filesystem permission on `/tmp/cc-socks` (mode `0700`,
owner only), not anything in the message.

The harness's own framing — the "this came from another Claude session" preamble
and the permission-laundering warning — is attached on ingest regardless of how
the bytes arrived, including for a raw write.

## Three things only visible from the receiving end

These came from a peer session watching messages arrive while this document's
author was sending them. A sender cannot observe any of them.

### A failed send discloses more than it should

Addressing a peer by a name that does not resolve returns an error naming the
correct ref, plus the session's type, locality and idle time:

```
'agent-rig-one' is not an agent in this conversation. Re-send with the ref to confirm you mean:
  agent-rig-one [2ee790] — Claude session, on this machine, active 17m ago
```

That is a **disclosure oracle**: guessing names yields valid refs and liveness
information for sessions that were never listed to you. A peer used it to
harvest three refs it had no other way to learn. Nothing here exploits it; it is
recorded because it is the kind of thing that changes quietly, and because
anyone reasoning about the trust boundary should know the roster is not the only
way to enumerate.

### The receiver-added preamble is the one part a forger cannot touch

Attribution is forgeable (above). The harness's own framing — the "this came
from another Claude session" preamble and the permission-laundering warning — is
**not**: it is attached on ingest and appeared identically on raw socket writes
that carried no wrapper at all.

So if anything ever builds trust logic on peer messages, that framing is the
only part with integrity. The `<cross-session-message>` wrapper, including
`from-name`, is attacker-controlled. `from-mode` rides along inside the wrapper
too, so it leaks sender *state*, not just identity, and is equally forgeable.

### Reachable and listed are not the same snapshot

A registered process is reachable the moment its socket answers, but a roster is
built on demand. A short-lived registration — `--ask` holds one for seconds —
is typically gone before anyone runs `ListAgents`, while a longer-lived one is
visible: a 120-second probe appeared as `ask-probe [f17ed5]`, and the
`--ask`-duration entries never showed up on a peer's roster at all.

Do not treat absence from a roster as evidence a peer cannot be reached, or
presence as evidence it still can. Both are snapshots of a probe that ran once.

## Making a non-Claude process addressable

Since `from` is not a reply path, a shell process that wants an *answer* has to
become something the peer can address. It can: the roster is built from the
registry, and the requirements are all satisfiable by any process.

Write `~/.claude/sessions/<pid>.json` with at least `pid`, `name`, `kind`,
`status` and `messagingSocketPath`, and listen on that socket. The roster
requires only that the pid is alive (`kill -0`) and that the socket answers a
connect probe. Confirmed by registering a plain Python process, which then
appeared on another session's roster:

```
ask-probe [f17ed5]  ·  interactive  ·  waiting  ·  started 2s ago
```

`SendMessage` to that name then delivered the bytes shown in the capture above.
This is what `bin/claude-send --ask` does: register, ask, block for the reply,
deregister.

**Two obligations if you do this.** Name the socket so it cannot be confused
with a session's own (`peer-ask-<pid>.sock`, never `<pid>.sock`). And remove
both the socket and the registry file on every exit path — a leftover entry is
exactly the stale row the roster garbage-collects, and until it does, the entry
sits on every other session's roster as a peer that never answers.

### Reply-address guard

Before sending a hold receipt, the reply address is checked to be in the same
socket directory and to end in `.sock`:

```
[uds-messaging] hold-receipt skipped: reply address outside our socket namespace (…)
```

So a peer cannot use the `from` field to redirect receipts at an arbitrary path.

## 3. Name resolution and pins — partial

Pins are ordinary session state, written through `setSendMessagePin(r, n)` and
reset to `{}` when the session's state is cleared. They are **in-memory and per
session**: a pin one session holds does nothing for another, and a restart drops
them.

**This section was rewritten for 2.1.251. The rule changed.** What it said
before — bare names never resolve for a peer, so the first send to any peer must
carry its ref — was true and verified on 2.1.226. It is no longer true, and the
[internals contract](internals-contract.md) caught it on the version bump.

The resolver SendMessage goes through now returns a richer ambiguity:

```js
function D(e, s) { return {kind:"ambiguous", candidates: e.slice(0, be), total: e.length, matchedBy: s} }
```

`total` and `matchedBy` (`"name"` or `"prefix"`) are the new part, and they are
what the rule now turns on. A target that names exactly one live row resolves to
that row and sends. Ambiguity is reserved for cases that are actually ambiguous.

The older resolver the previous version of this section quoted:

```js
let o = r === void 0 ? [] : n.filter((a) => a.name === r), s = (o.length > 0 ? o : n)[0]
if (s.where === "in-process") return {kind:"one", candidate:s}
return {kind:"ambiguous"}                       // ← everything not in-process
```

is **still in the binary** (around line 128496 of the extracted bundle) but is no
longer on SendMessage's path. Grepping for it and reading it as current is the
trap this section walked into; match on the tool's own error strings instead.

A send is now refused when:

- the name or prefix matches **two or more** live rows — the error lists the
  candidates with their refs;
- a **prefix** matches exactly one row and wants one confirmation before
  committing (`degradedClass: "confirm_required"`);
- part of the roster **could not be listed** — local, cloud and Remote Control
  fail independently, so a unique local match can still be refused on the
  grounds that the name might also exist in an unchecked half;
- a pinned identity is now **claimed by a local session**, which the tool treats
  as suspicious and surfaces rather than resolving.

Every one of those names the ref to re-send with, so recovery is in the error.

The pin is consulted in two places. On the **send** path it guards against a
name that has quietly re-pointed at a different session:

```js
let s = $B(i.name), a = Object.hasOwn(n.sendMessagePins, s) ? n.sendMessagePins[s] : void 0
if (a !== void 0 && a.id === i.id) return {kind:"proceed", pin:a}   // pin matches → send
if (a !== void 0) { let c = Vxr(e) !== null                          // explicit ref typed?
  if (!c && e === i.name && e !== a.name) return {kind:"proceed", pin:void 0}
  if (!c) { /* re-resolve against a freshly fetched roster */ } }
```

On the **resolve** path it turns a pinned name back into a target, and drops
itself when the target is gone or the name has moved:

```js
let s = r.find((a) => (i ? a.kind==="cloud-session" : a.kind==="session")
                       && a.where !== "in-process" && a.id === o.id)
if (s === void 0) { Oe("send_message_pin","stale"); return }         // pinned session gone
if (n !== void 0 && s.name !== n && r.some((a) => a.name === n)) return  // name now someone else's
return Se("send_message_pin"), s
```

That second guard is the interesting one: if the session you pinned has been
renamed *and* some other agent has since taken the old name, the pin refuses to
resolve rather than silently delivering to the wrong session.

**VERIFIED on 2.1.251.** Four sends, in order:

| # | `to` | result |
|---|---|---|
| 1 | `agent-rig-e1` — bare, no pin held | **delivered** |
| 2 | `agent-rig-e` — prefix, pin now held | delivered |
| 3 | `questor-` — prefix, two live rows | rejected, error named both refs |
| 4 | `agent-rig-e1 [47e788]` — ref | delivered |

So the rule is now **bare name whenever it is unique; the ref is for when the
error asks for it**. Row 1 is the one that changed: on 2.1.226 the identical
send was rejected.

Two limits on that table, recorded rather than smoothed over. Row 2 is
**confounded** — row 1 wrote a pin, so it does not establish that a unique
prefix resolves on its own; row 3 is the clean evidence that the ambiguity gate
still exists at all. And nothing here re-establishes what 2.1.226 did; that
build's rejection in row 1 is taken from this document's own prior observation,
which cannot be re-run.

Row 1 was confirmed **from the receiving end** as well: a `success` tool result
only proves the socket accepted the bytes, so the peer was asked, and reported
both probes arriving in its model context in full.

**RE-VERIFIED unchanged on 2.1.269.** Three sends, chosen to cover the rule
without repeating row 2's confound:

| # | `to` | result |
|---|---|---|
| 1 | `Review` — prefix, three live rows | rejected sender-side, error named all three refs |
| 2 | `agent-rig-64` — bare, unique, no pin held | **delivered** |
| 3 | `agent-rig-64 [0c4a0f]` — ref | delivered |

Rows 2 and 3 were confirmed from the receiving end rather than from their own
`success` results: both probes appear in agent-rig-64's transcript, and it
described the first one back correctly. Row 1 went first on purpose — a refused
send never reaches anyone, so the ambiguity gate is the half that costs no peer
a turn.

Worth knowing from the receiving end: the peer cannot tell which of these it
got. Addressing is resolved entirely sender-side, so a bare-name send and a ref
send arrive byte-identical.

**RE-VERIFIED unchanged on 2.1.296** (2026-10-11). Four sends, no pins held:

| # | `to` | result |
|---|---|---|
| 1 | `agent-rig` — prefix, one live row | rejected sender-side, error named that row's ref |
| 2 | `agent-rig-e0` — bare, unique | **delivered** |
| 3 | `agent-rig-e0 [4576bf]` — ref | delivered |
| 4 | `agent-rig` — prefix, two live rows | rejected sender-side, error named both refs |

Row 1 settles the 2.1.251 row-2 confound: with no pin held, a unique prefix does
**not** resolve on its own — it is the `confirm_required` refusal. Rows 2 and 3
were confirmed from the receiving end: both tokens appear in agent-rig-e0's
transcript as cross-session messages, and it described each back correctly.
Rows 1 and 4 appear in no receiver's transcript.

## 4. Where roster metadata comes from — partial

The `name`, `kind`, `status` and uptime on a roster row are **not fetched from
the peer over the socket**. They are read from the peer's registry file,
`~/.claude/sessions/<pid>.json`, which every session writes about itself:

```js
Ie({pid: process.pid, sessionId: …, cwd: …, startedAt: Date.now(),
    procStart: …, version: …, peerProtocol: …, kind: r,
    entrypoint: …, ...s && {tmux: s},
    ...{messagingSocketPath: EPe.CLAUDE_CODE_MESSAGING_SOCKET},
    ...{name: …, nameSource: "derived", logPath: …, agent: …, jobId: …}})
```

The directory is created with mode `448` (octal `0700`). `messagingSocketPath`
is copied straight from the session's own `CLAUDE_CODE_MESSAGING_SOCKET`
environment variable — a session needs no discovery to know its own address.

Each file is parsed back into a peer record carrying `sock`, `cwd`, `startedAt`,
`procStart`, `name`, `kind`, `sessionId`, `jobId`, `parkedJobId`,
`bridgeSessionId`, `logPath`, `status`, `waitingFor`, `updatedAt`,
`statusUpdatedAt`, `entrypoint`, `agent`, `state`, `detail`, `tempo`, `needs`
and `peerProtocol`. The row is then rendered as:

```
name [ref]  ·  kind  ·  status  ·  [tmux <name>]  ·  started <n> ago
```

`kind` ∈ `interactive | bg | daemon | daemon-worker`;
`status` ∈ `busy | shell | idle | waiting`.

### The roster does connect-probe

Listing live peers reads the registry *and* probes every socket:

```js
async function rfa(){
  let e = WXo()                                               // own socket path
  let t = (await tfa()).filter((i) => i.sock && i.sock !== e) // has a socket, and isn't me
  let r = await Promise.all(t.map((i) => p1p(i.sock)))        // probe all, concurrently
  let n = Wt() !== "wsl", o = []
  for (let i = 0; i < t.length; i++){ let {file:s, ...a} = t[i]
    if (r[i]) o.push(a)                                       // probe answered → on the roster
    else if (n && !zC(a.pid)) nIr.unlink(s).catch(()=>{}) }   // no answer + dead pid → delete file
  return o }
```

The probe is a 250ms connect that never sends anything:

```js
function p1p(e){ return new Promise((t)=>{
  if(!Z_e(e)){ t(!1); return }
  let r = Qpa.connect({path:e}), n = (o)=>{ r.destroy(); t(o) }
  r.on("connect", ()=>n(!0))
  r.on("error", (o)=>n(zt(o)==="EBUSY"))    // EBUSY counts as alive
  r.setTimeout(250, ()=>n(!1)) }) }
```

Three consequences. A registry file whose socket no longer answers **and** whose
PID is dead is deleted as a side effect of listing — the roster garbage-collects
itself (skipped on WSL). `EBUSY` is treated as reachable, since a listener too
busy to accept is still a listener. And self-exclusion is by socket path
compared against `CLAUDE_CODE_MESSAGING_SOCKET`, which is why you never see
yourself on your own roster.

So `messagingSocketPath` present does **not** imply reachable: it means the
session claimed an address, not that anything still answers there. Any tool
marking sessions "messageable" from the field alone will disagree with
`ListAgents` on a session that died without cleaning up.

This also corrects an earlier guess of mine. A decoy socket placed in
`/tmp/cc-socks` was never contacted — not because of any process-identity check,
but because enumeration starts from `~/.claude/sessions/*.json` and the decoy had
no registry file. It was never a candidate to probe.

The registry read underneath it:

```js
async function tfa(){ let e = Xpa.join(Tn(), "sessions"), t
  try { t = await nIr.readdir(e) } catch { return [] }
  return (await Promise.all(t.filter((n) => /^\d+\.json$/.test(n)).map(async (n) => {
    let o = n.replace(/\.json$/, ""), i = parseInt(o, 10) …
```

The filename is the PID and is the only thing trusted to identify the file;
anything not matching `/^\d+\.json$/` is ignored.

## What this means for agent-rig

- A ref can be computed offline from a registry file — no roster call needed.
- `sessionId` in the registry is the transcript UUID, so a PID maps to a
  `.jsonl` without the mtime-rank guessing `claude-tabs` used to do.
- Any tool marking a session "messageable" from `messagingSocketPath` alone is
  making the optimistic claim above, and may disagree with `ListAgents`.
- Delivery receipts are an unused capability: a sender can find out that a
  message was held rather than read.
