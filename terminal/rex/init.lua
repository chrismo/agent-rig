-- DO NOT MODIFY IN PLACE. Change in agent-rig (terminal/rex/) and run install.sh,
-- then: rex config check && rex config reload

-- Modifiers in caps-layer home-row order: ctrl, shift, alt, cmd. Layout: terminal/REX.md.

rex.bind("alt+cmd+s", "pane.split", { direction = "right" })
rex.bind("ctrl+alt+cmd+s", "pane.split", { direction = "down" })
rex.bind("alt+cmd+m", "pane.focus_next")

for _, dir in ipairs({ "up", "down", "left", "right" }) do
  rex.bind("shift+alt+" .. dir, "pane.focus", { direction = dir })
  -- amount is a percentage of the split (default 5), not Ghostty's pixels.
  rex.bind("shift+cmd+" .. dir, "pane.resize", { direction = dir })
end

require("panes")

rex.bind("alt+cmd+z", "pane.zoom")
rex.bind("alt+cmd+0", "pane.balance")

rex.bind("cmd+up", "client.prompt.previous")
rex.bind("cmd+down", "client.prompt.next")

rex.bind("alt+cmd+up", "client.tab.previous")
rex.bind("alt+cmd+down", "client.tab.next")
rex.bind("alt+cmd+left", "session.previous")
rex.bind("alt+cmd+right", "session.next")
-- TODO: go to the previous *expanded* session, wrapping around. Rex exposes no
-- collapse state (no API field, no event), so track it in this file: record what
-- these keys collapse/expand, then session.select the target from session.list.
-- Sidebar clicks, ⌘K and auto-expand on entering a session go unseen.
rex.action{
  name  = "session_collapse_previous",
  title = "Collapse Session and Go to Previous",
  run   = function()
    rex.client.queue("session.collapse")
    rex.client.queue("session.previous")
  end,
}
rex.bind("shift+alt+pageup", "session_collapse_previous")
rex.bind("shift+alt+pagedown", "session.expand")
rex.bind("alt+cmd+pageup", "client.tab.move.backward")
rex.bind("alt+cmd+pagedown", "client.tab.move.forward")
rex.bind("shift+cmd+r", "client.tab.rename")
rex.bind("shift+cmd+b", "client.tab.move_to_new_window")
