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

-- Pane moves that depend only on the layout on screen; see terminal/REX.md.
local OPPOSITE = { left = "right", right = "left", up = "down", down = "up" }
local EPS = 1e-6

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

local function neighbor(layout, block_id, dir)
  local me
  local all = leaves(layout, {})
  for _, leaf in ipairs(all) do
    if leaf.block_id == block_id then me = leaf.rect end
  end
  if me == nil then return nil end
  local best, best_rect, best_gap, best_overlap
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
        best, best_rect, best_gap, best_overlap = leaf.block_id, r, gap, overlap
      end
    end
  end
  return best, me, best_rect
end

-- Entering a neighbor, keep the pane's row (or column): pick the near edge or
-- one of the two perpendicular halves, whichever span best matches its own.
local function landing_edge(me, there, dir)
  local i, sides = 2, { "up", "down" }
  if dir == "up" or dir == "down" then i, sides = 1, { "left", "right" } end
  local p0, p1 = me[i], me[i] + me[i + 2]
  local n0, n1 = there[i], there[i] + there[i + 2]
  local mid = (n0 + n1) / 2
  local function match(a, b)
    return (math.min(p1, b) - math.max(p0, a)) / (math.max(p1, b) - math.min(p0, a))
  end
  local best, best_score = OPPOSITE[dir], match(n0, n1)
  local same_span = best_score > 1 - EPS
  for k, span in ipairs({ { n0, mid }, { mid, n1 } }) do
    local score = match(span[1], span[2])
    if score > best_score + EPS then best, best_score = sides[k], score end
  end
  return best, same_span
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

local function current_layout(block_id)
  local view, err = rex.session.view{}
  if err ~= nil then error(err, 0) end
  local layout = layer_with(view, block_id)
  if layout == nil then error("the focused pane isn't in a layout", 0) end
  return layout
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

rex.action{
  name        = "pane_move_dir",
  title       = "Move Pane",
  description = "Swap with the neighbor that shares this pane's row or column, or move into a larger neighbor, keeping the row or column.",
  args        = { direction = "string" },
  run         = function(ctx, args)
    local me, dir = ctx.block_id, args.direction
    if me == nil then error("no focused pane", 0) end
    if OPPOSITE[dir] == nil then error("direction must be left, right, up, or down", 0) end
    local next_pane, my_rect, next_rect = neighbor(current_layout(me), me, dir)
    if next_pane == nil then return nil end
    local land, same_span = landing_edge(my_rect, next_rect, dir)
    if same_span then
      -- A move would stretch whatever shared this pane's split; a swap doesn't.
      local _, err = rex.session.swap_blocks{ block_id = me, other_block_id = next_pane }
      if err ~= nil then error(err, 0) end
      return { swapped = next_pane }
    end
    place(me, next_pane, land)
    return { anchor = next_pane, edge = land }
  end,
}

-- After adi's rotate_split in the "Rotate / transpose a split" #feedback thread.
rex.action{
  name        = "pane_rotate_split",
  title       = "Rotate Split",
  description = "Turn this pane and its split partner from side by side to stacked, or back.",
  run         = function(ctx)
    local me = ctx.block_id
    if me == nil then error("no focused pane", 0) end
    local split, side = parent_of(current_layout(me), me)
    if split == nil then error("the focused pane has no split to rotate", 0) end
    local partner = split[side == "before" and "after" or "before"]
    if partner.block_id == nil then
      error("this pane's split partner is a group of panes; rotate from one of those", 0)
    end
    local _, err = rex.session.move_block{
      block_id        = me,
      anchor_block_id = partner.block_id,
      direction       = split.direction == "horizontal" and "vertical" or "horizontal",
      side            = side,
      ratio           = split.ratio,
    }
    if err ~= nil then error(err, 0) end
  end,
}

for _, dir in ipairs({ "up", "down", "left", "right" }) do
  rex.bind("cmd+alt+shift+" .. dir, "pane_move_dir", { direction = dir })
end
rex.bind("cmd+alt+r", "pane_rotate_split")

rex.bind("cmd+alt+z", "pane.zoom")
rex.bind("cmd+alt+0", "pane.balance")

rex.bind("cmd+up", "client.prompt.previous")
rex.bind("cmd+down", "client.prompt.next")

rex.bind("cmd+shift+pageup", "client.tab.move.backward")
rex.bind("cmd+shift+pagedown", "client.tab.move.forward")
rex.bind("cmd+shift+l", "client.tab.rename")
rex.bind("cmd+shift+b", "client.tab.move_to_new_window")
