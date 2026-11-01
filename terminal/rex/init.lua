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

-- Moestty-style move_split; see terminal/REX.md. Rex has no modifier-release
-- event, so a pause between presses ends the move.
local OPPOSITE = { left = "right", right = "left", up = "down", down = "up" }
local EPS = 1e-6
local MOVE_PAUSE_SECONDS = 2 -- os.time() is whole seconds: effectively 2-3 s
local move_target = nil

local function layer_with(view, block_id)
  local function has(node)
    if node == nil then return false end
    if node.block_id == block_id then return true end
    return node.split ~= nil and (has(node.split.before) or has(node.split.after))
  end
  for _, window in ipairs(view.windows or {}) do
    for _, layer in ipairs(window.layers or {}) do
      if has(layer.layout) then return layer.layout end
    end
  end
end

local function leaves(node, out)
  if node == nil then return out end
  if node.block_id ~= nil then
    out[#out + 1] = node
  elseif node.split ~= nil then
    leaves(node.split.before, out)
    leaves(node.split.after, out)
  end
  return out
end

local function parent_of(node, block_id)
  local split = node and node.split
  if split == nil then return nil end
  for _, side in ipairs({ "before", "after" }) do
    if split[side].block_id == block_id then return split, side end
    local found, found_side = parent_of(split[side], block_id)
    if found ~= nil then return found, found_side end
  end
end

local function edge_on_sibling(layout, block_id)
  local split, side = parent_of(layout, block_id)
  if split == nil then return nil end
  local sibling = split[side == "before" and "after" or "before"]
  if sibling.block_id == nil then return nil end
  local edge
  if split.direction == "vertical" then
    edge = side == "before" and "up" or "down"
  else
    edge = side == "before" and "left" or "right"
  end
  return edge, sibling.block_id
end

local function neighbor(layout, block_id, dir)
  local me
  local all = leaves(layout, {})
  for _, leaf in ipairs(all) do
    if leaf.block_id == block_id then me = leaf.rect end
  end
  if me == nil then return nil end
  local best, best_gap, best_overlap
  for _, leaf in ipairs(all) do
    local r = leaf.rect
    local gap, overlap
    if dir == "left" then gap = me[1] - (r[1] + r[3])
    elseif dir == "right" then gap = r[1] - (me[1] + me[3])
    elseif dir == "up" then gap = me[2] - (r[2] + r[4])
    else gap = r[2] - (me[2] + me[4]) end
    if dir == "left" or dir == "right" then
      overlap = math.min(me[2] + me[4], r[2] + r[4]) - math.max(me[2], r[2])
    else
      overlap = math.min(me[1] + me[3], r[1] + r[3]) - math.max(me[1], r[1])
    end
    if leaf.block_id ~= block_id and gap > -EPS and overlap > EPS then
      if best == nil or gap < best_gap - EPS
          or (math.abs(gap - best_gap) <= EPS and overlap > best_overlap) then
        best, best_gap, best_overlap = leaf.block_id, gap, overlap
      end
    end
  end
  return best
end

local function place(block_id, anchor_id, edge)
  local _, err = rex.session.move_block{
    block_id        = block_id,
    anchor_block_id = anchor_id,
    direction       = (edge == "left" or edge == "right") and "horizontal" or "vertical",
    side            = (edge == "left" or edge == "up") and "before" or "after",
  }
  if err ~= nil then error(err, 0) end
end

rex.action{
  name        = "pane_move_target",
  title       = "Move Pane (Targeted)",
  description = "Move the pane onto an edge of a neighboring pane, walking it around with further presses.",
  args        = { direction = "string" },
  run         = function(ctx, args)
    local me, dir = ctx.block_id, args.direction
    if me == nil then error("no focused pane", 0) end
    if OPPOSITE[dir] == nil then error("direction must be left, right, up, or down", 0) end
    local now = os.time()
    if move_target ~= nil and now - move_target.at > MOVE_PAUSE_SECONDS then
      move_target = nil
    end

    local view, err = rex.session.view{}
    if err ~= nil then error(err, 0) end
    local layout = layer_with(view, me)
    if layout == nil then error("the focused pane isn't in a layout", 0) end
    local edge, sibling = edge_on_sibling(layout, me)

    if move_target ~= nil and move_target.block == me
        and sibling == move_target.anchor and edge ~= dir then
      place(me, sibling, dir)
      move_target.at = now
      return { anchor = sibling, edge = dir }
    end

    local next_pane = neighbor(layout, me, dir)
    if next_pane == nil then return { anchor = sibling, edge = edge } end
    local land = OPPOSITE[dir]
    if sibling == next_pane and edge == land then land = dir end
    place(me, next_pane, land)
    move_target = { block = me, anchor = next_pane, at = now }
    return { anchor = next_pane, edge = land }
  end,
}

for _, dir in ipairs({ "up", "down", "left", "right" }) do
  rex.bind("cmd+alt+shift+" .. dir, "pane_move_target", { direction = dir })
end

rex.bind("cmd+alt+z", "pane.zoom")
rex.bind("cmd+alt+0", "pane.balance")

rex.bind("cmd+up", "client.prompt.previous")
rex.bind("cmd+down", "client.prompt.next")

rex.bind("cmd+shift+pageup", "client.tab.move.backward")
rex.bind("cmd+shift+pagedown", "client.tab.move.forward")
rex.bind("cmd+shift+l", "client.tab.rename")
rex.bind("cmd+shift+b", "client.tab.move_to_new_window")
