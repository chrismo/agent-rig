#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# The internals contract.
#
# agent-rig reads several things Claude Code does not expose as a supported
# API. None of it is guaranteed to survive a point release. This suite asserts
# that each load-bearing assumption still holds against the CURRENTLY INSTALLED
# build, so a breaking change surfaces here instead of as a mysteriously empty
# claude-tabs or a claude-pod that renders nothing.
#
# Each test is prefixed with an assumption ID (A1, B2, …). Those IDs are the
# join to docs/internals-contract.md, which says what each one is for, who
# depends on it, and what to do when it fails. Keep them in sync: an ID here
# with no entry there is a dead end for whoever hits the failure.
#
# Run it after any Claude Code version change:
#     bats bin/claude-contract.bats
# hooks/internals-drift.sh nags you to when the version moves.
#
# Two deliberate limits:
#   - Anchors are plain string literals. Identifiers are re-mangled every build
#     (see docs/reading-the-claude-binary.md), so asserting on `tfa` would fail
#     for a rename that broke nothing.
#   - Tests that need live artifacts (a running session, a transcript) `skip`
#     when none exist rather than fail. A machine with no sessions should be
#     able to run this suite green.

SRC="$BATS_TEST_DIRNAME/claude-src"
SESSIONS_DIR="${CLAUDE_SESSIONS_META_DIR:-$HOME/.claude/sessions}"
PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

# Record every result, so a run leaves behind what it actually established
# rather than a single version string that cannot tell a pass from a skip.
# See bin/contract-record for the format and the reasoning.
#
# The version comes from `claude-src --which`, not from a second copy of the
# hook's resolution logic — the binary's filename IS its version, and this way
# the row names the same build the anchors were read from.
teardown() {
  local status version
  if [[ -n "${BATS_TEST_SKIPPED:-}" ]]; then
    status=skip
  elif [[ -n "${BATS_TEST_COMPLETED:-}" ]]; then
    status=pass
  else
    status=fail
  fi

  version=$(basename -- "$("$SRC" --which 2>/dev/null)" 2>/dev/null) || version=""

  "$BATS_TEST_DIRNAME/contract-record" \
    "$BATS_TEST_DESCRIPTION" "$status" "$version" 2>/dev/null || true
}

# Assert a literal appears in the installed bundle. claude-src exits 0 on a
# miss (by design), so presence is judged from the output, not the status.
assert_anchor() {
  local pattern="$1" out
  out=$("$SRC" "$pattern" 0 200 2>&1)
  if [[ "$out" == *"no match for"* || -z "$out" ]]; then
    echo "MISSING ANCHOR: '$pattern'" >&2
    echo "$out" >&2
    return 1
  fi
}

# --- A: the peer messaging mechanism -------------------------------------

@test "A1: the uds-messaging subsystem still exists" {
  assert_anchor 'uds-messaging'
}

@test "A2: sessions still advertise a socket via messagingSocketPath" {
  assert_anchor 'messagingSocketPath'
}

@test "A3: a session still learns its own address from the environment" {
  assert_anchor 'CLAUDE_CODE_MESSAGING_SOCKET'
}

@test "A4: the wire format is still newline-delimited JSON on a unix socket" {
  # The binary logs its own injection recipe; if this text is gone, the
  # hand-written socket writes in docs/inter-claude-protocol.md are suspect.
  assert_anchor 'Inject messages'
}

@test "A5: refs are still a truncated sha256" {
  # docs/inter-claude-protocol.md 1: sha256("session:"+sock), cut to 12, then
  # to 6 by the roster. If this changes, every computed ref is wrong.
  assert_anchor 'digest("hex").slice(0,12)'
}

# Anchor only. This asserts the pin mechanism exists — NOT that bare names are
# gated by it. A6 stayed green across 2.1.226 → 2.1.251 while the addressing
# rule itself changed underneath it, which is why the behavioural half is the
# manual check in docs/internals-contract.md and not this test.
@test "A6: the sendMessagePins mechanism still exists" {
  assert_anchor 'sendMessagePins'
}

@test "A7: the socket directory is still cc-socks" {
  assert_anchor 'cc-socks'
}

# --- B: the session registry ---------------------------------------------

@test "B1: the registry directory exists" {
  [ -d "$SESSIONS_DIR" ] || skip "no registry at $SESSIONS_DIR"
}

@test "B2: registry files are named <pid>.json" {
  [ -d "$SESSIONS_DIR" ] || skip "no registry at $SESSIONS_DIR"
  local found=0 f
  for f in "$SESSIONS_DIR"/*.json; do
    [ -e "$f" ] || continue
    found=1
    [[ "$(basename "$f")" =~ ^[0-9]+\.json$ ]] || {
      echo "unexpected registry filename: $f" >&2; return 1; }
  done
  [ "$found" -eq 1 ] || skip "no live sessions to check"
}

@test "B3: registry records still carry the fields claude-tabs and claude-pod read" {
  [ -d "$SESSIONS_DIR" ] || skip "no registry at $SESSIONS_DIR"
  local f
  f=$(ls -t "$SESSIONS_DIR"/*.json 2>/dev/null | head -1) || true
  [ -n "$f" ] || skip "no live sessions to check"

  run python3 -c "
import json,sys
d=json.load(open('$f'))
need=['pid','sessionId','cwd','kind','status','startedAt']
missing=[k for k in need if k not in d]
print('missing:', missing)
sys.exit(1 if missing else 0)
"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "B4: kind and status still use the documented vocabularies" {
  [ -d "$SESSIONS_DIR" ] || skip "no registry at $SESSIONS_DIR"
  local f
  f=$(ls -t "$SESSIONS_DIR"/*.json 2>/dev/null | head -1) || true
  [ -n "$f" ] || skip "no live sessions to check"

  run python3 -c "
import json,sys
d=json.load(open('$f'))
kinds={'interactive','bg','daemon','daemon-worker'}
stats={'busy','shell','idle','waiting'}
bad=[]
if d.get('kind') not in kinds: bad.append(('kind', d.get('kind')))
if d.get('status') not in stats: bad.append(('status', d.get('status')))
print('unexpected:', bad)
sys.exit(1 if bad else 0)
"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

# --- C: transcripts, the widest-blast-radius surface ---------------------

@test "C1: the projects directory encodes a worktree path as -Users-name-…" {
  [ -d "$PROJECTS_DIR" ] || skip "no projects dir at $PROJECTS_DIR"
  local d found=0
  for d in "$PROJECTS_DIR"/*/; do
    [ -d "$d" ] || continue
    [[ "$(basename "$d")" == -* ]] && { found=1; break; }
  done
  [ "$found" -eq 1 ] || {
    echo "no directory using the leading-dash path encoding" >&2; return 1; }
}

@test "C2: transcript lines are JSON objects carrying .type" {
  local f
  f=$(ls -t "$PROJECTS_DIR"/*/*.jsonl 2>/dev/null | head -1) || true
  [ -n "$f" ] || skip "no transcripts to check"

  run python3 -c "
import json,sys
ok=0
for i,line in enumerate(open('$f')):
    if i>200: break
    line=line.strip()
    if not line: continue
    try: rec=json.loads(line)
    except Exception: continue
    if isinstance(rec,dict) and 'type' in rec: ok+=1
print('records with .type:', ok)
sys.exit(0 if ok else 1)
"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "C3: user and assistant records still nest content under .message" {
  local f
  f=$(ls -t "$PROJECTS_DIR"/*/*.jsonl 2>/dev/null | head -1) || true
  [ -n "$f" ] || skip "no transcripts to check"

  run python3 -c "
import json,sys
ok=0
for i,line in enumerate(open('$f')):
    if i>400: break
    line=line.strip()
    if not line: continue
    try: rec=json.loads(line)
    except Exception: continue
    if rec.get('type') in ('user','assistant') and isinstance(rec.get('message'),dict) \
       and 'content' in rec['message']: ok+=1
print('records with .message.content:', ok)
sys.exit(0 if ok else 1)
"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

# --- D: the stamp --------------------------------------------------------

@test "D1: verified-against matches the running build" {
  # Not a failure of any mechanism — a reminder that the assumptions above were
  # confirmed against a different build than the one running. Re-verify (the
  # behavioural checks in docs/internals-contract.md included), then bump
  # docs/verified-against.
  local stamp_file="$BATS_TEST_DIRNAME/../docs/verified-against"
  [ -r "$stamp_file" ] || skip "no docs/verified-against"
  local stamp running binary
  stamp=$(tr -d '[:space:]' < "$stamp_file")

  binary="${CLAUDE_CODE_EXECPATH:-}"
  [ -n "$binary" ] || binary=$(readlink "$(command -v claude)" 2>/dev/null) || true
  [ -n "$binary" ] || skip "cannot resolve the running build"
  running=$(basename "$binary")

  [ "$stamp" = "$running" ] || {
    echo "verified against $stamp, running $running — re-verify, then bump docs/verified-against" >&2
    return 1; }
}

# --- E: addressability, what claude-peer --ask stands on -----------------

@test "E1: the session registry directory is writable" {
  [ -d "$SESSIONS_DIR" ] || skip "no registry at $SESSIONS_DIR"
  local probe="$SESSIONS_DIR/.agent-rig-write-probe"
  echo x > "$probe" 2>/dev/null || {
    echo "cannot write $SESSIONS_DIR — claude-peer --ask cannot register" >&2
    return 1; }
  rm -f "$probe"
}

@test "E2: a roster entry needs only a live pid and an answering socket" {
  # The assumption most likely to be closed off deliberately. Asserted the same
  # way claude-peer relies on it: register a plain process, confirm claude-peer
  # (which reimplements rfa) lists it, then clean up.
  local peer="$BATS_TEST_DIRNAME/claude-peer"
  command -v python3 >/dev/null || skip "python3 required"

  run python3 -c '
import socket, os, json, sys, time, subprocess, tempfile
regdir = os.path.expanduser(os.environ.get("CLAUDE_SESSIONS_META_DIR", "~/.claude/sessions"))
regdir = os.path.expanduser(regdir)
sockdir = tempfile.mkdtemp()
pid = os.getpid()
sock = os.path.join(sockdir, "peer-ask-%d.sock" % pid)
reg = os.path.join(regdir, "%d.json" % pid)
srv = socket.socket(socket.AF_UNIX); srv.bind(sock); srv.listen(2)
now = int(time.time()*1000)
try:
    json.dump({"pid": pid, "name": "contract-probe", "kind": "interactive",
               "status": "waiting", "startedAt": now, "statusUpdatedAt": now,
               "messagingSocketPath": sock}, open(reg, "w"))
    out = subprocess.run([sys.argv[1], "--list"], capture_output=True, text=True).stdout
    print("LISTED" if "contract-probe" in out else "NOT-LISTED")
finally:
    for p in (sock, reg):
        try: os.unlink(p)
        except FileNotFoundError: pass
' "$peer"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [[ "$output" == *"LISTED"* ]] || {
    echo "a registered process was NOT listed — registration may now be validated" >&2
    echo "$output" >&2; return 1; }
}

@test "E3: attribution is a text wrapper inside message.content" {
  assert_anchor 'cross-session-message'
}

@test "E4: a uds: socket path is still a valid SendMessage target" {
  # What claude-peer --ask stands on: it hands the peer a uds: path to answer.
  # The tool's own prompt is the authority — "To reply to an incoming message,
  # copy its `from` attribute as your `to`." If that guidance is gone, a shell
  # process has no way to receive a reply.
  assert_anchor 'reply to an incoming message'
}

# --- R: runtime activation -----------------------------------------------
#
# Why this group exists. On 2026-08-08 cross-session messaging was off for
# newly started sessions for part of the morning, and every A-series anchor
# stayed green throughout: the code was all present in the bundle, it simply
# was not running. Asserting code presence is a proxy; this asserts the
# feature actually activated.
#
# The gate is evaluated at startup — nt("tengu_harbor_kite", false), with a
# CLAUDE_CODE_HARBOR_KITE env override — so a session can be on a build that
# supports messaging and still have no inbox.
#
# Note the skip guard below is CLAUDE_CODE_SESSION_ID, deliberately. Guarding
# on CLAUDE_CODE_MESSAGING_SOCKET would skip precisely when messaging failed
# to activate, which is the one case worth catching.

@test "R1: this session actually has a live messaging inbox" {
  [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || skip "not running inside a Claude session"

  [ -n "${CLAUDE_CODE_MESSAGING_SOCKET:-}" ] || {
    echo "This session has no CLAUDE_CODE_MESSAGING_SOCKET: cross-session" >&2
    echo "messaging did not activate. The code may still be present (see the" >&2
    echo "A-series) — check the startup gate rather than the bundle." >&2
    return 1; }

  [ -S "$CLAUDE_CODE_MESSAGING_SOCKET" ] || {
    echo "socket path advertised but nothing is bound: $CLAUDE_CODE_MESSAGING_SOCKET" >&2
    return 1; }
}

@test "R2: sessions on the installed build are getting inboxes" {
  # The installed build is what the NEXT session will run, so this is the
  # early warning: R1 can stay green on a long-lived session while every newly
  # started one comes up without an inbox.
  local launcher installed
  launcher=$(command -v claude 2>/dev/null) || skip "no claude on PATH"
  installed=$(readlink "$launcher" 2>/dev/null) || installed="$launcher"
  installed=$(basename "$installed")
  [[ "$installed" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || skip "cannot resolve the installed build"

  [ -d "$SESSIONS_DIR" ] || skip "no registry at $SESSIONS_DIR"

  local f pid total=0 withsock=0 ver sock
  for f in "$SESSIONS_DIR"/*.json; do
    [ -e "$f" ] || continue
    pid=$(basename "$f" .json)
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    kill -0 "$pid" 2>/dev/null || continue

    ver=$(super -f line -c 'values {...{version:""}, ...this} | values version' "$f" 2>/dev/null)
    [ "$ver" = "$installed" ] || continue
    total=$((total + 1))

    sock=$(super -f line -c 'values {...{messagingSocketPath:""}, ...this} | values messagingSocketPath' "$f" 2>/dev/null)
    [ -n "$sock" ] && withsock=$((withsock + 1))
  done

  [ "$total" -gt 0 ] || skip "no live sessions on the installed build ($installed)"

  [ "$withsock" -gt 0 ] || {
    echo "$total live session(s) on $installed and NONE has a messagingSocketPath." >&2
    echo "New sessions are coming up without an inbox — the startup gate is off." >&2
    echo "Workaround: CLAUDE_CODE_HARBOR_KITE=1 forces it open." >&2
    return 1; }
}
