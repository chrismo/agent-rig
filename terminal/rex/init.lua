-- DO NOT MODIFY IN PLACE. Change in agent-rig (terminal/rex/) and run install.sh,
-- then: rex config check && rex config reload

rex.bind("cmd+alt+s", "pane.split", { direction = "right" })
rex.bind("cmd+alt+ctrl+s", "pane.split", { direction = "down" })
rex.bind("cmd+alt+m", "pane.focus_next")

rex.bind("cmd+alt+up", "pane.focus", { direction = "up" })
rex.bind("cmd+alt+down", "pane.focus", { direction = "down" })
rex.bind("cmd+alt+left", "pane.focus", { direction = "left" })
rex.bind("cmd+alt+right", "pane.focus", { direction = "right" })

-- amount is a percentage of the split (default 5), not Ghostty's pixels.
rex.bind("cmd+shift+up", "pane.resize", { direction = "up" })
rex.bind("cmd+shift+down", "pane.resize", { direction = "down" })
rex.bind("cmd+shift+left", "pane.resize", { direction = "left" })
rex.bind("cmd+shift+right", "pane.resize", { direction = "right" })

rex.bind("cmd+alt+shift+up", "pane.move", { direction = "up" })
rex.bind("cmd+alt+shift+down", "pane.move", { direction = "down" })
rex.bind("cmd+alt+shift+left", "pane.move", { direction = "left" })
rex.bind("cmd+alt+shift+right", "pane.move", { direction = "right" })

rex.bind("cmd+alt+z", "pane.zoom")
rex.bind("cmd+alt+0", "pane.balance")

rex.bind("cmd+up", "client.prompt.previous")
rex.bind("cmd+down", "client.prompt.next")

rex.bind("cmd+shift+pageup", "client.tab.move.backward")
rex.bind("cmd+shift+pagedown", "client.tab.move.forward")
rex.bind("cmd+shift+l", "client.tab.rename")
rex.bind("cmd+shift+b", "client.tab.move_to_new_window")
