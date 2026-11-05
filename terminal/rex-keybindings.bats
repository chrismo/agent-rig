#!/usr/bin/env bats

# Loads init.lua and the real panes.lua against a stub rex, then runs the Lua
# assertions in $1. Keys are normalized so modifier order doesn't matter, as in Rex.
check_bindings() {
  run lua - "$BATS_TEST_DIRNAME/rex" "$1" <<'LUA'
local dir, assertions = arg[1], arg[2]
package.path = dir .. "/?.lua;" .. package.path

local ORDER = { ctrl = 1, shift = 2, alt = 3, cmd = 4 }
local function norm(key)
  local parts = {}
  for p in key:gmatch("[^+]+") do parts[#parts + 1] = p end
  local k = table.remove(parts)
  table.sort(parts, function(a, b) return ORDER[a] < ORDER[b] end)
  parts[#parts + 1] = k
  return table.concat(parts, "+")
end

bindings = {}
rex = {
  bind = function(key, action, args) bindings[norm(key)] = { action = action, args = args or {} } end,
  action = function() end,
}
dofile(dir .. "/init.lua")

function bound(key, action, dir, turn)
  local b = bindings[norm(key)]
  assert(b, key .. " is unbound")
  assert(b.action == action, key .. " is " .. b.action .. ", want " .. action)
  assert(b.args.direction == dir, key .. " direction " .. tostring(b.args.direction))
  assert(b.args.turn == turn, key .. " turn " .. tostring(b.args.turn))
end
function unbound(key)
  assert(bindings[norm(key)] == nil, key .. " is bound to " .. tostring((bindings[norm(key)] or {}).action))
end

assert(load(assertions))()
LUA
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "opt-cmd arrows select the previous and next tab" {
  check_bindings '
    bound("alt+cmd+left", "client.tab.previous")
    bound("alt+cmd+up", "client.tab.previous")
    bound("alt+cmd+right", "client.tab.next")
    bound("alt+cmd+down", "client.tab.next")'
}

@test "opt-cmd page keys move the tab" {
  check_bindings '
    bound("alt+cmd+pageup", "client.tab.move.backward")
    bound("alt+cmd+pagedown", "client.tab.move.forward")'
}

@test "shift-opt arrows focus the pane that way" {
  check_bindings '
    for _, d in ipairs({ "up", "down", "left", "right" }) do
      bound("shift+alt+" .. d, "pane.focus", d)
    end'
}

@test "shift-opt-cmd arrows swap the pane that way" {
  check_bindings '
    for _, d in ipairs({ "up", "down", "left", "right" }) do
      bound("shift+alt+cmd+" .. d, "pane_move_dir", d)
    end'
}

@test "shift-cmd arrows resize the pane" {
  check_bindings '
    for _, d in ipairs({ "up", "down", "left", "right" }) do
      bound("shift+cmd+" .. d, "pane.resize", d)
    end'
}

@test "shift-opt-cmd page keys rotate the pane" {
  check_bindings '
    bound("shift+alt+cmd+pagedown", "pane_rotate", nil, "clockwise")
    bound("shift+alt+cmd+pageup", "pane_rotate", nil, "counterclockwise")'
}

@test "push and the old tab page keys are unassigned" {
  check_bindings '
    for key, b in pairs(bindings) do
      assert(b.action ~= "pane_push_dir", "push is bound to " .. key)
    end
    unbound("shift+alt+pageup")
    unbound("shift+alt+pagedown")
    unbound("shift+cmd+pageup")
    unbound("shift+cmd+pagedown")'
}

# Runs pane_rotate on pane A in the layout $1 (a Lua table), turning $2, and
# checks the one move_block call against $3: "anchor direction side [ratio]",
# or "none" for no move.
check_rotate() {
  run lua - "$BATS_TEST_DIRNAME/rex" "$1" "$2" "$3" <<'LUA'
local dir, layout_src, turn, want = arg[1], arg[2], arg[3], arg[4]
package.path = dir .. "/?.lua;" .. package.path

local actions, moves = {}, {}
local layout = assert(load("return " .. layout_src))()
rex = {
  bind = function() end,
  action = function(def) actions[def.name] = def end,
  session = {
    view = function() return { windows = { { layers = { { layout = layout } } } } } end,
    move_block = function(args) moves[#moves + 1] = args; return {} end,
  },
}
dofile(dir .. "/init.lua")

actions.pane_rotate.run({ block_id = "A" }, { turn = turn })

if want == "none" then
  assert(#moves == 0, "moved")
  return
end
assert(#moves == 1, #moves .. " moves")
local m = moves[1]
local got = table.concat({ m.anchor_block_id, m.direction, m.side, m.ratio and tostring(m.ratio) or nil }, " ")
assert(m.block_id == "A", "moved " .. tostring(m.block_id))
assert(got == want, "got " .. got .. ", want " .. want)
LUA
  echo "$output"
  [ "$status" -eq 0 ]
}

# A│B
TWO='{ rect = {0,0,1,1}, split = { direction = "horizontal", ratio = 0.3,
  before = { rect = {0,0,0.3,1}, block_id = "A" },
  after  = { rect = {0.3,0,0.7,1}, block_id = "B" } } }'

# A beside a B/C stack
STACK='{ rect = {0,0,1,1}, split = { direction = "horizontal", ratio = 0.5,
  before = { rect = {0,0,0.5,1}, block_id = "A" },
  after  = { rect = {0.5,0,0.5,1}, split = { direction = "vertical", ratio = 0.5,
    before = { rect = {0.5,0,0.5,0.5}, block_id = "B" },
    after  = { rect = {0.5,0.5,0.5,0.5}, block_id = "C" } } } } }'

# A│B│C
COLUMNS='{ rect = {0,0,1,1}, split = { direction = "horizontal", ratio = 0.34,
  before = { rect = {0,0,0.34,1}, block_id = "A" },
  after  = { rect = {0.34,0,0.66,1}, split = { direction = "horizontal", ratio = 0.5,
    before = { rect = {0.34,0,0.33,1}, block_id = "B" },
    after  = { rect = {0.67,0,0.33,1}, block_id = "C" } } } } }'

# A above B│C
OVER='{ rect = {0,0,1,1}, split = { direction = "vertical", ratio = 0.5,
  before = { rect = {0,0,1,0.5}, block_id = "A" },
  after  = { rect = {0,0.5,1,0.5}, split = { direction = "horizontal", ratio = 0.5,
    before = { rect = {0,0.5,0.5,0.5}, block_id = "B" },
    after  = { rect = {0.5,0.5,0.5,0.5}, block_id = "C" } } } } }'

# A beside B over a C│D row; D doesn't touch A
NESTED='{ rect = {0,0,1,1}, split = { direction = "horizontal", ratio = 0.5,
  before = { rect = {0,0,0.5,1}, block_id = "A" },
  after  = { rect = {0.5,0,0.5,1}, split = { direction = "vertical", ratio = 0.5,
    before = { rect = {0.5,0,0.5,0.5}, block_id = "B" },
    after  = { rect = {0.5,0.5,0.5,0.5}, split = { direction = "horizontal", ratio = 0.5,
      before = { rect = {0.5,0.5,0.25,0.5}, block_id = "C" },
      after  = { rect = {0.75,0.5,0.25,0.5}, block_id = "D" } } } } } } }'

@test "rotate two panes clockwise keeps the pane's share" {
  check_rotate "$TWO" clockwise "B vertical before 0.3"
}

@test "rotate two panes counterclockwise keeps the pane's share" {
  check_rotate "$TWO" counterclockwise "B vertical after 0.7"
}

@test "rotate beside a stack anchors on its top pane clockwise" {
  check_rotate "$STACK" clockwise "B vertical before"
}

@test "rotate beside a stack anchors on its bottom pane counterclockwise" {
  check_rotate "$STACK" counterclockwise "C vertical after"
}

@test "rotate beside a row anchors on the pane it faces" {
  check_rotate "$COLUMNS" clockwise "B vertical before"
  check_rotate "$COLUMNS" counterclockwise "B vertical after"
}

@test "rotate above a row turns to its right or left end" {
  check_rotate "$OVER" clockwise "C horizontal after"
  check_rotate "$OVER" counterclockwise "B horizontal before"
}

@test "rotate only anchors on panes that touch this one" {
  check_rotate "$NESTED" counterclockwise "C vertical after"
}

@test "rotate a lone pane does nothing" {
  check_rotate '{ rect = {0,0,1,1}, block_id = "A" }' clockwise none
}
