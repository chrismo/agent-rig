#!/usr/bin/env bats

@test "shift-alt page keys select the previous and next tab" {
  run lua - "$BATS_TEST_DIRNAME/rex/init.lua" <<'LUA'
local bindings = {}
rex = { bind = function(key, action) bindings[key] = action end }
package.preload.panes = function() end
dofile(arg[1])
assert(bindings["alt+shift+pageup"] == "client.tab.previous")
assert(bindings["alt+shift+pagedown"] == "client.tab.next")
LUA
  [ "$status" -eq 0 ]
}
