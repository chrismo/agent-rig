#!/usr/bin/env bats

# Loads init.lua (and what it requires) against a stub rex, then runs the Lua
# assertions in $1. Keys are normalized so modifier order doesn't matter, as in Rex.
check_bindings() {
  run lua - "$BATS_TEST_DIRNAME/rex" "$1" <<'LUA'
local dir, assertions = arg[1], arg[2]
package.path = dir .. "/?.lua;" .. package.path

local ORDER = { ctrl = 1, shift = 2, alt = 3, cmd = 4 }
local function norm(key)
  local mode = key:match("^([%w_-]+/)") or ""
  key = key:sub(#mode + 1)
  local parts = {}
  for p in key:gmatch("[^+]+") do parts[#parts + 1] = p end
  local k = table.remove(parts)
  table.sort(parts, function(a, b) return ORDER[a] < ORDER[b] end)
  parts[#parts + 1] = k
  return mode .. table.concat(parts, "+")
end

bindings, modes, actions = {}, {}, {}
rex = {
  bind = function(key, action, args) bindings[norm(key)] = { action = action, args = args or {} } end,
  action = function(def) actions[def.name] = def end,
  mode = function(name, opts) modes[name] = opts or {} end,
}
dofile(dir .. "/init.lua")

function bound(key, action, dir)
  local b = bindings[norm(key)]
  assert(b, key .. " is unbound")
  assert(b.action == action, key .. " is " .. b.action .. ", want " .. action)
  assert(b.args.direction == dir, key .. " direction " .. tostring(b.args.direction))
end
function unbound(key)
  assert(bindings[norm(key)] == nil, key .. " is bound to " .. tostring((bindings[norm(key)] or {}).action))
end

assert(load(assertions))()
LUA
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "bindings pass every argument their action requires" {
  check_bindings '
    for key, b in pairs(bindings) do
      local def = actions[b.action]
      for name, kind in pairs(def and def.args or {}) do
        assert(kind:sub(-1) == "?" or b.args[name] ~= nil,
          key .. " -> " .. b.action .. " is missing required arg " .. name)
      end
    end'
}

# Arrows act on panes.

@test "opt-cmd arrows focus the pane that way" {
  check_bindings '
    for _, d in ipairs({ "up", "down", "left", "right" }) do
      bound("alt+cmd+" .. d, "pane.focus", d)
    end'
}

@test "shift-opt arrows start aiming the pane that way" {
  check_bindings '
    for _, d in ipairs({ "up", "down", "left", "right" }) do
      bound("shift+alt+" .. d, "pane_aim", d)
      assert(bindings["shift+alt+" .. d].args.start, "shift+alt+" .. d .. " does not start fresh")
    end'
}

@test "the exclusive aim mode walks with arrows, drops on enter, cancels on escape" {
  check_bindings '
    assert(modes.aim and modes.aim.exclusive, "aim mode is not exclusive")
    for _, d in ipairs({ "up", "down", "left", "right" }) do
      bound("aim/" .. d, "pane_aim", d)
      bound("aim/shift+alt+" .. d, "pane_aim", d)
    end
    bound("aim/enter", "pane_aim_drop")
    bound("aim/escape", "pane_aim_cancel")'
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

# PgUp/PgDn act on tabs, m/v on sessions: opt-cmd goes, shift-opt-cmd moves.

@test "opt-cmd page keys select the previous and next tab" {
  check_bindings '
    bound("alt+cmd+pageup", "client.tab.previous")
    bound("alt+cmd+pagedown", "client.tab.next")'
}

@test "opt-cmd m and v select the previous and next session" {
  check_bindings '
    bound("alt+cmd+m", "session.previous")
    bound("alt+cmd+v", "session.next")'
}

@test "shift-opt-cmd page keys move the tab" {
  check_bindings '
    bound("shift+alt+cmd+pageup", "client.tab.move.backward")
    bound("shift+alt+cmd+pagedown", "client.tab.move.forward")'
}

@test "shift-opt-cmd m and v move the session" {
  check_bindings '
    bound("shift+alt+cmd+m", "session_move", "up")
    bound("shift+alt+cmd+v", "session_move", "down")'
}

@test "shift-opt m and v collapse the session, then go up or down" {
  check_bindings '
    bound("shift+alt+m", "session_collapse_previous")
    bound("shift+alt+v", "session_collapse_next")'
}

@test "shift-opt and shift-cmd page keys are unassigned" {
  check_bindings '
    unbound("shift+alt+pageup")
    unbound("shift+alt+pagedown")
    unbound("shift+cmd+pageup")
    unbound("shift+cmd+pagedown")'
}

# Runs session action $1 with direction $2 against stub sessions s1..s4, the
# current one being $3. Prints the queued client actions and any session.move.
run_session_action() {
  run lua - "$BATS_TEST_DIRNAME/rex" "$1" "$2" "$3" <<'LUA'
local dir, name, direction, current = arg[1], arg[2], arg[3], arg[4]
package.path = dir .. "/?.lua;" .. package.path
local actions, out = {}, {}
rex = {
  bind = function() end,
  mode = function() end,
  action = function(def) actions[def.name] = def end,
  client = { queue = function(n) out[#out + 1] = n end },
  -- Like Rex: session.list and session.move are server calls, not rex.session methods.
  call = function(method, args)
    if method == "session.list" then return { sessions = { { session_id = "s1" }, { session_id = "s2" }, { session_id = "s3" }, { session_id = "s4" } } } end
    assert(method == "session.move", method)
    out[#out + 1] = "move " .. tostring(args.session_id) .. " before " .. tostring(args.before_session_id)
    return {}
  end,
}
dofile(dir .. "/init.lua")
actions[name].run({ session_id = current }, { direction = direction })
print(table.concat(out, ", "))
LUA
}

@test "collapse-previous folds this session before moving up" {
  run_session_action session_collapse_previous "" s2
  [ "$status" -eq 0 ]
  [ "$output" = "session.collapse, session.previous" ]
}

@test "collapse-next folds this session before moving down" {
  run_session_action session_collapse_next "" s2
  [ "$status" -eq 0 ]
  [ "$output" = "session.collapse, session.next" ]
}

@test "move session up puts it before the one above" {
  run_session_action session_move up s3
  [ "$status" -eq 0 ]
  [ "$output" = "move s3 before s2" ]
}

@test "move session down puts it before the one two below" {
  run_session_action session_move down s2
  [ "$status" -eq 0 ]
  [ "$output" = "move s2 before s4" ]
}

@test "move session down from next to last sends it to the end" {
  run_session_action session_move down s3
  [ "$status" -eq 0 ]
  [ "$output" = "move s3 before nil" ]
}

@test "move session past either end does nothing" {
  run_session_action session_move up s1
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  run_session_action session_move down s4
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# Runs pane actions on a stub tab with A focused. $LAYOUT picks the tab:
#   row:  A | B | C, side by side
#   grid: D over A on the left, B over C on the right
#   tee:  T across the top, A | C below it
# Each argument is action[:direction[:start]]; the moves and queued client actions
# of each step print on their own line. Swaps change the stub; moves don't.
run_aim() {
  run lua - "$BATS_TEST_DIRNAME/rex" "${LAYOUT:-row}" "$@" <<'LUA'
local dir, which = arg[1], arg[2]
package.path = dir .. "/?.lua;" .. package.path
local actions, out = {}, {}
local function leaf(id, x, y, w, h) return { block_id = id, rect = { x, y, w, h } } end
local function split(d, a, b) return { split = { direction = d, before = a, after = b } } end
local layouts = {
  row = split("horizontal", leaf("A", 0, 0, 1 / 3, 1),
    split("horizontal", leaf("B", 1 / 3, 0, 1 / 3, 1), leaf("C", 2 / 3, 0, 1 / 3, 1))),
  grid = split("horizontal",
    split("vertical", leaf("D", 0, 0, .5, .5), leaf("A", 0, .5, .5, .5)),
    split("vertical", leaf("B", .5, 0, .5, .5), leaf("C", .5, .5, .5, .5))),
  tee = split("vertical", leaf("T", 0, 0, 1, .5),
    split("horizontal", leaf("A", 0, .5, .5, .5), leaf("C", .5, .5, .5, .5))),
}
local layout = layouts[which]
local function each_leaf(node, fn)
  if node.block_id then fn(node) else each_leaf(node.split.before, fn); each_leaf(node.split.after, fn) end
end
rex = {
  bind = function() end,
  mode = function() end,
  action = function(def) actions[def.name] = def end,
  client = { queue = function(n, a) out[#out + 1] = n .. (a and a.name and ("(" .. a.name .. ")") or "") end },
  session = {
    view = function() return { windows = { { layers = { { layout = layout } } } } } end,
    move_block = function(a)
      out[#out + 1] = "move " .. a.block_id .. " " .. a.side .. " " .. a.anchor_block_id .. " " .. a.direction
      return {}
    end,
    swap_blocks = function(a)
      out[#out + 1] = "swap " .. a.block_id .. " " .. a.other_block_id
      each_leaf(layout, function(l)
        if l.block_id == a.block_id then l.block_id = a.other_block_id
        elseif l.block_id == a.other_block_id then l.block_id = a.block_id end
      end)
      return {}
    end,
  },
}
dofile(dir .. "/init.lua")
for k = 3, #arg do
  local name, direction, start = arg[k]:match("^([%w_]+):?(%a*):?(%a*)$")
  out = {}
  actions[name].run({ block_id = "A" }, { direction = direction ~= "" and direction or nil, start = start == "start" or nil })
  print(#out > 0 and table.concat(out, ", ") or "-")
end
LUA
  echo "$output"
}

@test "aiming moves the pane to the nearest edge that way and enters the mode" {
  run_aim pane_aim:right:start
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "move A after B horizontal, client.mode.enter(aim)" ]
}

@test "aiming never swaps: a next-door pane's near edge is skipped, not swapped" {
  LAYOUT=grid run_aim pane_aim:up:start
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "move A before D vertical, client.mode.enter(aim)" ]
  LAYOUT=grid run_aim pane_aim:right:start
  [ "${lines[0]}" = "move A after C horizontal, client.mode.enter(aim)" ]
}

@test "aiming up into a wider pane lands in line with the pane" {
  LAYOUT=tee run_aim pane_aim:up:start
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "move A before T horizontal, client.mode.enter(aim)" ]
}

@test "aiming where there is no landing spot does nothing" {
  run_aim pane_aim:left:start
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "-" ]
}

@test "cancelling puts the pane back beside its old neighbor" {
  LAYOUT=tee run_aim pane_aim:up:start pane_aim_cancel
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "move A before C horizontal, client.mode.exit" ]
  run_aim pane_aim:right:start pane_aim_cancel
  [ "${lines[1]}" = "move A before B horizontal, client.mode.exit" ]
}

@test "dropping keeps the pane where it is, and the next aim starts fresh" {
  run_aim pane_aim:right:start pane_aim_drop pane_aim:right:start pane_aim_cancel
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "client.mode.exit" ]
  [ "${lines[3]}" = "move A before B horizontal, client.mode.exit" ]
}
