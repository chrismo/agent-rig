#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for bin/claude-send.
#
# claude-send lists and messages live Claude sessions from a shell, without
# going through Claude's own ListAgents/SendMessage tools. It reimplements what
# the binary does (see docs/inter-claude-protocol.md):
#
#   discovery  ~/.claude/sessions/<pid>.json, kill -0, then a connect probe
#   ref        sha256("session:" + messagingSocketPath), first 6 hex
#   send       one line of JSON on the peer's unix socket
#
# Tests build a fake registry in BATS_TEST_TMPDIR and stand up real unix
# sockets, so the probe and the send are exercised for real rather than mocked.

PEER="$BATS_TEST_DIRNAME/claude-send"

setup() {
  export CLAUDE_SESSIONS_META_DIR="$BATS_TEST_TMPDIR/sessions"
  mkdir -p "$CLAUDE_SESSIONS_META_DIR"
  export CLAUDE_CODE_MESSAGING_SOCKET="$BATS_TEST_TMPDIR/self.sock"
  LISTENERS=()
}

teardown() {
  local p
  for p in "${LISTENERS[@]:-}"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null
  done
  # bats fails a test whose teardown exits non-zero. With no listeners the loop
  # ends on a false [ -n "" ], which would fail every test that never started
  # one — for reasons having nothing to do with the test.
  return 0
}

# A registry record. Uses our own pid so the liveness check passes.
write_session() {
  local pid="$1" name="$2" sock="$3" kind="${4:-interactive}" status="${5:-idle}"
  local sockfield=""
  [ -n "$sock" ] && sockfield="\"messagingSocketPath\":\"$sock\","
  cat > "$CLAUDE_SESSIONS_META_DIR/$pid.json" <<EOF
{"pid":$pid,"sessionId":"11111111-2222-3333-4444-555555555555","cwd":"/tmp/wt",
 "name":"$name","kind":"$kind",$sockfield"status":"$status","startedAt":1786000000000}
EOF
}

# Real listener that appends whatever it receives to a file.
start_listener() {
  local sock="$1" out="$2"
  python3 -c "
import socket, os, sys, threading
p, out = sys.argv[1], sys.argv[2]
try: os.unlink(p)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX); s.bind(p); s.listen(4)
def serve():
    while True:
        c,_ = s.accept()
        d = c.recv(65536)
        if d:
            with open(out,'ab') as f: f.write(d)
        c.close()
threading.Thread(target=serve, daemon=True).start()
import time
time.sleep(30)
" "$sock" "$out" &
  LISTENERS+=($!)
  local i=0
  while [ ! -S "$sock" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
}

expected_ref() {
  printf '%s' "session:$1" | shasum -a 256 | cut -c1-6
}

@test "--list shows a reachable peer with its name, pid and ref" {
  local sock="$BATS_TEST_TMPDIR/peer.sock"
  start_listener "$sock" "$BATS_TEST_TMPDIR/got"
  write_session $$ "alpha" "$sock"

  run "$PEER" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha"* ]] || false
  [[ "$output" == *"$$"* ]] || false
  [[ "$output" == *"$(expected_ref "$sock")"* ]]
}

@test "--list excludes this session itself" {
  local sock="$BATS_TEST_TMPDIR/self.sock"
  start_listener "$sock" "$BATS_TEST_TMPDIR/got"
  write_session $$ "myself" "$sock"

  run "$PEER" --list
  [ "$status" -eq 0 ]
  [[ "$output" != *"myself"* ]]
}

@test "--list excludes sessions that never recorded a socket" {
  write_session $$ "socketless" ""

  run "$PEER" --list
  [ "$status" -eq 0 ]
  [[ "$output" != *"socketless"* ]]
}

@test "--list excludes a session whose socket no longer answers" {
  # A registry file can outlive the process: the socket path is recorded but
  # nothing is listening. Recorded path never implies reachable.
  local sock="$BATS_TEST_TMPDIR/stale.sock"
  python3 -c "
import socket
s = socket.socket(socket.AF_UNIX); s.bind('$sock'); s.close()"
  write_session $$ "ghost" "$sock"

  run "$PEER" --list
  [ "$status" -eq 0 ]
  [[ "$output" != *"ghost"* ]]
}

@test "--list skips registry entries whose pid is dead" {
  write_session 999999 "zombie" "$BATS_TEST_TMPDIR/zombie.sock"

  run "$PEER" --list
  [ "$status" -eq 0 ]
  [[ "$output" != *"zombie"* ]]
}

@test "--all includes an unreachable session, marked as such" {
  local sock="$BATS_TEST_TMPDIR/stale2.sock"
  python3 -c "
import socket
s = socket.socket(socket.AF_UNIX); s.bind('$sock'); s.close()"
  write_session $$ "ghost" "$sock"

  run "$PEER" --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"ghost"* ]] || false
  [[ "$output" == *"unreachable"* ]]
}

@test "--send delivers a well-formed user message, addressed by name" {
  local sock="$BATS_TEST_TMPDIR/peer.sock" got="$BATS_TEST_TMPDIR/got"
  start_listener "$sock" "$got"
  write_session $$ "alpha" "$sock"

  run "$PEER" --send alpha "hello from bash"
  [ "$status" -eq 0 ]

  sleep 0.4
  run python3 -c "
import json
line = open('$got').read().strip().splitlines()[0]
rec = json.loads(line)
assert rec['type'] == 'user', rec
assert rec['message']['role'] == 'user', rec
assert rec['message']['content'] == 'hello from bash', rec
print('ok')
"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "--send addresses a peer by pid" {
  local sock="$BATS_TEST_TMPDIR/peer.sock" got="$BATS_TEST_TMPDIR/got"
  start_listener "$sock" "$got"
  write_session $$ "alpha" "$sock"

  run "$PEER" --send "$$" "by pid"
  [ "$status" -eq 0 ]
  sleep 0.4
  grep -q "by pid" "$got"
}

@test "--send addresses a peer by ref" {
  local sock="$BATS_TEST_TMPDIR/peer.sock" got="$BATS_TEST_TMPDIR/got"
  start_listener "$sock" "$got"
  write_session $$ "alpha" "$sock"

  run "$PEER" --send "$(expected_ref "$sock")" "by ref"
  [ "$status" -eq 0 ]
  sleep 0.4
  grep -q "by ref" "$got"
}

@test "--send reads the body from stdin when given -" {
  local sock="$BATS_TEST_TMPDIR/peer.sock" got="$BATS_TEST_TMPDIR/got"
  start_listener "$sock" "$got"
  write_session $$ "alpha" "$sock"

  run bash -c "echo 'piped body' | '$PEER' --send alpha -"
  [ "$status" -eq 0 ]
  sleep 0.4
  grep -q "piped body" "$got"
}

@test "--send escapes quotes and backslashes rather than emitting broken JSON" {
  local sock="$BATS_TEST_TMPDIR/peer.sock" got="$BATS_TEST_TMPDIR/got"
  start_listener "$sock" "$got"
  write_session $$ "alpha" "$sock"

  run "$PEER" --send alpha 'he said "hi" \ then left'
  [ "$status" -eq 0 ]
  sleep 0.4
  run python3 -c "
import json
line = open('$got').read().strip().splitlines()[0]
rec = json.loads(line)
assert rec['message']['content'] == 'he said \"hi\" \\\\ then left', rec['message']['content']
print('ok')
"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "--send fails loudly for an unknown target" {
  run "$PEER" --send nobody "hello"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nobody"* ]]
}

@test "--send refuses to message this session" {
  local sock="$BATS_TEST_TMPDIR/self.sock"
  start_listener "$sock" "$BATS_TEST_TMPDIR/got"
  write_session $$ "myself" "$sock"

  run "$PEER" --send myself "loop"
  [ "$status" -ne 0 ]
}

@test "--send fails when the target is listed but no longer answers" {
  local sock="$BATS_TEST_TMPDIR/stale3.sock"
  python3 -c "
import socket
s = socket.socket(socket.AF_UNIX); s.bind('$sock'); s.close()"
  write_session $$ "ghost" "$sock"

  run "$PEER" --send ghost "hello"
  [ "$status" -ne 0 ]
}

@test "an empty registry lists nothing and succeeds" {
  run "$PEER" --list
  [ "$status" -eq 0 ]
}

# --- status awareness ----------------------------------------------------
#
# Only `status` and `statusUpdatedAt` are actually written by live sessions.
# tempo / waitingFor / needs / state / detail are parsed by Claude's own reader
# but populated in 0 of 10 observed registry files, so nothing here depends on
# them: a filter built on those would never fire.

set_status() {
  local pid="$1" status="$2" when="${3:-}"
  local f="$CLAUDE_SESSIONS_META_DIR/$pid.json"
  [ -n "$when" ] || when=$(python3 -c 'import time; print(int(time.time()*1000))')
  python3 -c "
import json,sys
f='$f'
d=json.load(open(f))
d['status']='$status'
d['statusUpdatedAt']=$when
json.dump(d, open(f,'w'))
"
}

@test "--list reports how long a peer has held its status" {
  local sock="$BATS_TEST_TMPDIR/peer.sock"
  start_listener "$sock" "$BATS_TEST_TMPDIR/got"
  write_session $$ "alpha" "$sock"
  # 12 minutes ago
  local when
  when=$(python3 -c 'import time; print(int(time.time()*1000) - 12*60*1000)')
  set_status $$ idle "$when"

  run "$PEER" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"12m"* ]]
}

@test "--list tolerates a record with no statusUpdatedAt" {
  local sock="$BATS_TEST_TMPDIR/peer.sock"
  start_listener "$sock" "$BATS_TEST_TMPDIR/got"
  write_session $$ "alpha" "$sock"

  run "$PEER" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha"* ]]
}

@test "--watch exits 0 when a peer's status changes" {
  local sock="$BATS_TEST_TMPDIR/peer.sock"
  start_listener "$sock" "$BATS_TEST_TMPDIR/got"
  write_session $$ "alpha" "$sock"
  set_status $$ busy

  ( sleep 1; set_status $$ idle ) &

  run "$PEER" --watch --interval 0.2 --timeout 15
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha"* ]] || false
  [[ "$output" == *"idle"* ]]
}

@test "--watch --for waits for one specific status and ignores others" {
  local sock="$BATS_TEST_TMPDIR/peer.sock"
  start_listener "$sock" "$BATS_TEST_TMPDIR/got"
  write_session $$ "alpha" "$sock"
  set_status $$ busy

  # A change it should ignore, then the one it wants.
  ( sleep 0.8; set_status $$ shell; sleep 1.2; set_status $$ idle ) &

  run "$PEER" --watch --for idle --interval 0.2 --timeout 15
  [ "$status" -eq 0 ]
  # It fires on the transition INTO idle. The line names the prior status too,
  # so assert on what it fired on, not on the mere presence of the word.
  [[ "$output" == *"-> idle"* ]] || false
  [[ "$output" != *"-> shell"* ]]
}

@test "--watch exits 2 on timeout when nothing changes" {
  local sock="$BATS_TEST_TMPDIR/peer.sock"
  start_listener "$sock" "$BATS_TEST_TMPDIR/got"
  write_session $$ "alpha" "$sock"
  set_status $$ idle

  run "$PEER" --watch --interval 0.2 --timeout 1
  [ "$status" -eq 2 ]
}

@test "--watch ignores this session's own status changes" {
  local sock="$BATS_TEST_TMPDIR/self.sock"
  start_listener "$sock" "$BATS_TEST_TMPDIR/got"
  write_session $$ "myself" "$sock"
  set_status $$ busy

  ( sleep 0.6; set_status $$ idle ) &

  run "$PEER" --watch --interval 0.2 --timeout 2
  [ "$status" -eq 2 ]
}

# --- the reply channel ---------------------------------------------------
#
# Replies do NOT route to a raw `from` address: a message written straight to a
# socket reaches the peer with no sender the model can see, because attribution
# is text embedded in message.content by the SendMessage tool. What DOES work is
# being addressable: rfa() lists any registry entry whose pid is alive and whose
# socket answers, so --ask registers itself for the life of the question.

ASK_SOCK_DIR() { echo "$BATS_TEST_TMPDIR/socks"; }

# A peer that answers by reading the uds: reply address out of the message it
# received — what a real Claude does. Deliberately does NOT consult the
# registry: --ask must work without registering, so a helper that found the
# socket that way would hide a broken default.
start_answering_peer() {
  local sock="$1" reply="$2"
  python3 -c "
import socket, os, sys, json, re, threading, time
sock, reply = sys.argv[1], sys.argv[2]
try: os.unlink(sock)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX); s.bind(sock); s.listen(4)
def serve():
    while True:
        c,_ = s.accept()
        data = c.recv(65536)
        c.close()
        if not data: continue
        m = re.search(r'uds:(\S+?\.sock)', data.decode('utf-8','replace'))
        if not m: continue
        out = socket.socket(socket.AF_UNIX)
        try:
            out.connect(m.group(1))
            out.sendall((json.dumps({'type':'user','message':{'role':'user',
                'content':'<cross-session-message from=\"uds:/x.sock\" from-name=\"peer\">\n'
                           + reply + '\n</cross-session-message>'}})+'\n').encode())
        except OSError: pass
        finally: out.close()
threading.Thread(target=serve, daemon=True).start()
time.sleep(30)
" "$sock" "$reply" &
  LISTENERS+=($!)
  local i=0
  while [ ! -S "$sock" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
}

# Registry entry count, for asserting what --ask does and doesn't leave behind.
reg_count() { ls "$CLAUDE_SESSIONS_META_DIR" 2>/dev/null | wc -l | tr -d ' '; }

@test "--ask prints the peer's reply, envelope stripped" {
  local sock="$BATS_TEST_TMPDIR/peer.sock"
  start_answering_peer "$sock" "migration landed, 8 tables verified"
  write_session $$ "builder" "$sock"

  CLAUDE_SEND_SOCKET_DIR="$(ASK_SOCK_DIR)" run "$PEER" --ask builder "did it land?" --timeout 15
  [ "$status" -eq 0 ]
  [[ "$output" == *"migration landed, 8 tables verified"* ]] || false
  [[ "$output" != *"cross-session-message"* ]]
}

# These two observe state DURING the ask, so they use a peer that never
# answers: an answering peer finishes in ~0.3s and the sampler races it.
@test "--ask does NOT register by default" {
  # Registering puts a non-Claude process on the roster of every live session.
  # That is opt-in: the reply comes back via the uds: address in the prompt,
  # which needs no registry entry at all.
  local sock="$BATS_TEST_TMPDIR/peer.sock"
  start_listener "$sock" "$BATS_TEST_TMPDIR/got"
  write_session $$ "mute" "$sock"

  local before during
  before=$(reg_count)
  ( sleep 1; reg_count > "$BATS_TEST_TMPDIR/during" ) &
  CLAUDE_SEND_SOCKET_DIR="$(ASK_SOCK_DIR)" run "$PEER" --ask mute "hello" --timeout 4
  [ "$status" -eq 2 ]

  during=$(cat "$BATS_TEST_TMPDIR/during")
  [ "$during" -eq "$before" ]
}

@test "--ask --register makes itself visible on the roster while waiting" {
  local sock="$BATS_TEST_TMPDIR/peer.sock"
  start_listener "$sock" "$BATS_TEST_TMPDIR/got"
  write_session $$ "mute" "$sock"

  local before during
  before=$(reg_count)
  ( sleep 1; reg_count > "$BATS_TEST_TMPDIR/during"
    grep -l 'asker' "$CLAUDE_SESSIONS_META_DIR"/*.json > "$BATS_TEST_TMPDIR/named" 2>/dev/null ) &
  CLAUDE_SEND_SOCKET_DIR="$(ASK_SOCK_DIR)" run "$PEER" --ask mute "hello" \
    --register --name asker --timeout 4
  [ "$status" -eq 2 ]

  during=$(cat "$BATS_TEST_TMPDIR/during")
  [ "$during" -gt "$before" ]
  [ -s "$BATS_TEST_TMPDIR/named" ]
}

@test "--ask --register removes its entry afterwards" {
  local sock="$BATS_TEST_TMPDIR/peer.sock"
  start_answering_peer "$sock" "seen"
  write_session $$ "builder" "$sock"

  local before after
  before=$(reg_count)
  CLAUDE_SEND_SOCKET_DIR="$(ASK_SOCK_DIR)" run "$PEER" --ask builder "hello" \
    --register --timeout 15
  [ "$status" -eq 0 ]
  after=$(reg_count)
  [ "$before" -eq "$after" ]
}

@test "--ask removes its registry entry and socket afterwards" {
  local sock="$BATS_TEST_TMPDIR/peer.sock"
  start_answering_peer "$sock" "done"
  write_session $$ "builder" "$sock"

  local before after
  before=$(ls "$CLAUDE_SESSIONS_META_DIR" | wc -l | tr -d ' ')
  CLAUDE_SEND_SOCKET_DIR="$(ASK_SOCK_DIR)" run "$PEER" --ask builder "hi" --timeout 15
  [ "$status" -eq 0 ]
  after=$(ls "$CLAUDE_SESSIONS_META_DIR" | wc -l | tr -d ' ')
  [ "$before" -eq "$after" ]
  [ -z "$(ls -A "$(ASK_SOCK_DIR)" 2>/dev/null)" ]
}

@test "--ask exits 2 and cleans up when no reply comes" {
  local sock="$BATS_TEST_TMPDIR/peer.sock"
  start_listener "$sock" "$BATS_TEST_TMPDIR/got"    # receives, never answers
  write_session $$ "mute" "$sock"

  local before after
  before=$(ls "$CLAUDE_SESSIONS_META_DIR" | wc -l | tr -d ' ')
  CLAUDE_SEND_SOCKET_DIR="$(ASK_SOCK_DIR)" run "$PEER" --ask mute "anyone?" --timeout 2
  [ "$status" -eq 2 ]
  after=$(ls "$CLAUDE_SESSIONS_META_DIR" | wc -l | tr -d ' ')
  [ "$before" -eq "$after" ]
  [ -z "$(ls -A "$(ASK_SOCK_DIR)" 2>/dev/null)" ]
}

@test "--ask names its socket so it cannot be mistaken for a session socket" {
  local sock="$BATS_TEST_TMPDIR/peer.sock"
  start_listener "$sock" "$BATS_TEST_TMPDIR/got"
  write_session $$ "mute" "$sock"

  # Capture the socket name mid-flight, before cleanup removes it.
  ( sleep 1; ls "$(ASK_SOCK_DIR)" > "$BATS_TEST_TMPDIR/names" 2>/dev/null ) &
  CLAUDE_SEND_SOCKET_DIR="$(ASK_SOCK_DIR)" run "$PEER" --ask mute "q" --timeout 4

  run cat "$BATS_TEST_TMPDIR/names"
  [[ "$output" == *"peer-ask-"* ]] || false
  # A session socket is <pid>.sock; ours must never match that shape.
  [[ ! "$output" =~ ^[0-9]+\.sock$ ]]
}

@test "--ask fails for an unknown target without registering anything" {
  local before after
  before=$(ls "$CLAUDE_SESSIONS_META_DIR" | wc -l | tr -d ' ')
  CLAUDE_SEND_SOCKET_DIR="$(ASK_SOCK_DIR)" run "$PEER" --ask nobody "q" --timeout 3
  [ "$status" -ne 0 ]
  [ "$status" -ne 2 ]
  after=$(ls "$CLAUDE_SESSIONS_META_DIR" | wc -l | tr -d ' ')
  [ "$before" -eq "$after" ]
}

@test "--ask tells the peer to reply to a uds: path, not to a name" {
  # Pins are keyed to a ref, and each --ask invocation gets a fresh pid, socket
  # and therefore ref. A bare-name reply would bounce every time; a uds: path
  # needs no pin, no ref and no roster entry.
  local sock="$BATS_TEST_TMPDIR/peer.sock" got="$BATS_TEST_TMPDIR/got"
  start_listener "$sock" "$got"
  write_session $$ "mute" "$sock"

  CLAUDE_SEND_SOCKET_DIR="$(ASK_SOCK_DIR)" run "$PEER" --ask mute "q" --timeout 3
  [ "$status" -eq 2 ]

  run cat "$got"
  [[ "$output" == *"uds:"* ]] || false
  [[ "$output" == *"peer-ask-"* ]]
}
