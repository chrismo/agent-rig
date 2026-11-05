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

