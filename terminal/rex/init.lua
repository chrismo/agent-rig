-- DO NOT MODIFY IN PLACE. Change in agent-rig (terminal/rex/) and run install.sh,
-- then: rex config check && rex config reload

-- Modifiers in caps-layer home-row order: ctrl, shift, alt, cmd. Layout: terminal/REX.md.

rex.bind("alt+cmd+s", "pane.split", { direction = "right" })
rex.bind("ctrl+alt+cmd+s", "pane.split", { direction = "down" })

for _, dir in ipairs({ "up", "down", "left", "right" }) do
  rex.bind("alt+cmd+" .. dir, "pane.focus", { direction = dir })
  -- amount is a percentage of the split (default 5), not Ghostty's pixels.
  rex.bind("shift+cmd+" .. dir, "pane.resize", { direction = dir })
end

require("panes")
require("sessions")

rex.bind("alt+cmd+z", "pane.zoom")
rex.bind("alt+cmd+0", "pane.balance")

rex.bind("cmd+up", "client.prompt.previous")
rex.bind("cmd+down", "client.prompt.next")

rex.bind("alt+cmd+pageup", "client.tab.previous")
rex.bind("alt+cmd+pagedown", "client.tab.next")
rex.bind("shift+alt+cmd+pageup", "client.tab.move.backward")
rex.bind("shift+alt+cmd+pagedown", "client.tab.move.forward")
rex.bind("shift+cmd+r", "client.tab.rename")
rex.bind("shift+cmd+b", "client.tab.move_to_new_window")
