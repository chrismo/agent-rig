-- DO NOT MODIFY IN PLACE. Change in agent-rig (terminal/rex/) and run install.sh,
-- then: rex config check && rex config reload

-- TODO: go to the previous/next *expanded* session, wrapping around. Rex exposes
-- no collapse state (no API field, no event), so track it in this file: record
-- what these keys collapse, then session.select the target from session.list.
-- Sidebar clicks, ⌘K and auto-expand on entering a session go unseen.
for _, go in ipairs({ "previous", "next" }) do
  rex.action{
    name  = "session_collapse_" .. go,
    title = "Collapse Session and Go to " .. go:sub(1, 1):upper() .. go:sub(2),
    run   = function()
      rex.client.queue("session.collapse")
      rex.client.queue("session." .. go)
    end,
  }
end

rex.action{
  name        = "session_move",
  title       = "Move Session",
  description = "Move the session up or down one place in the sidebar.",
  args        = { direction = "string" },
  run         = function(ctx, args)
    if args.direction ~= "up" and args.direction ~= "down" then
      error("direction must be up or down", 0)
    end
    local list, err = rex.call("session.list", {})
    if err ~= nil then error(err, 0) end
    local ids = {}
    for i, s in ipairs(list.sessions) do ids[i] = s.session_id end
    local at
    for i, id in ipairs(ids) do
      if id == ctx.session_id then at = i end
    end
    if at == nil then error("the current session isn't in the session list", 0) end
    if (args.direction == "up" and at == 1) or (args.direction == "down" and at == #ids) then return end
    -- session.move places a session before another; no before means the end.
    local before = args.direction == "up" and ids[at - 1] or ids[at + 2]
    local _, merr = rex.call("session.move", { session_id = ctx.session_id, before_session_id = before })
    if merr ~= nil then error(merr, 0) end
  end,
}

rex.bind("alt+cmd+m", "session.previous")
rex.bind("alt+cmd+v", "session.next")
rex.bind("shift+alt+cmd+m", "session_move", { direction = "up" })
rex.bind("shift+alt+cmd+v", "session_move", { direction = "down" })
rex.bind("shift+alt+m", "session_collapse_previous")
rex.bind("shift+alt+v", "session_collapse_next")
