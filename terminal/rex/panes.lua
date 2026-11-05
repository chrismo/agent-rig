-- DO NOT MODIFY IN PLACE. Change in agent-rig (terminal/rex/) and run install.sh,
-- then: rex config check && rex config reload

local OPPOSITE = { left = "right", right = "left", up = "down", down = "up" }
local EPS = 1e-6

-- Rect index along dir, the index across it, and the edge names across it.
local function axes(dir)
  if dir == "left" or dir == "right" then return 1, 2, { "up", "down" } end
  return 2, 1, { "left", "right" }
end

local function leaves(node, out)
  if node.block_id ~= nil then
    out[#out + 1] = node
  else
    leaves(node.split.before, out)
    leaves(node.split.after, out)
  end
  return out
end

local function current_layout(block_id)
  local view, err = rex.session.view{}
  if err ~= nil then error(err, 0) end
  for _, window in ipairs(view.windows or {}) do
    for _, layer in ipairs(window.layers or {}) do
      if layer.layout ~= nil then
        for _, leaf in ipairs(leaves(layer.layout, {})) do
          if leaf.block_id == block_id then return layer.layout end
        end
      end
    end
  end
  error("the focused pane isn't in a layout", 0)
end

local function gap(me, r, dir)
  local along = axes(dir)
  if dir == "left" or dir == "up" then return me[along] - (r[along] + r[along + 2]) end
  return r[along] - (me[along] + me[along + 2])
end

local function neighbor(layout, block_id, dir)
  local _, across = axes(dir)
  local all = leaves(layout, {})
  local me
  for _, leaf in ipairs(all) do
    if leaf.block_id == block_id then me = leaf.rect end
  end
  local best, best_rect, best_gap, best_overlap
  for _, leaf in ipairs(all) do
    local r = leaf.rect
    local g = gap(me, r, dir)
    local overlap = math.min(me[across] + me[across + 2], r[across] + r[across + 2])
      - math.max(me[across], r[across])
    if leaf.block_id ~= block_id and g > -EPS and overlap > EPS then
      if best == nil or g < best_gap - EPS
          or (math.abs(g - best_gap) <= EPS and overlap > best_overlap) then
        best, best_rect, best_gap, best_overlap = leaf.block_id, r, g, overlap
      end
    end
  end
  return best, me, best_rect
end

local function focused_neighbor(ctx, dir)
  if ctx.block_id == nil then error("no focused pane", 0) end
  if OPPOSITE[dir] == nil then error("direction must be left, right, up, or down", 0) end
  return neighbor(current_layout(ctx.block_id), ctx.block_id, dir)
end

-- Entering a neighbor, keep the pane's row (or column): pick the near edge or
-- one of the two perpendicular halves, whichever span best matches its own.
local function landing_edge(me, there, dir)
  local _, i, sides = axes(dir)
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

local function place(block_id, anchor_id, edge, ratio)
  local _, err = rex.session.move_block{
    block_id        = block_id,
    anchor_block_id = anchor_id,
    direction       = (edge == "left" or edge == "right") and "horizontal" or "vertical",
    side            = (edge == "left" or edge == "up") and "before" or "after",
    ratio           = ratio,
  }
  if err ~= nil then error(err, 0) end
end

rex.action{
  name        = "pane_move_dir",
  title       = "Move Pane",
  description = "Swap with the neighbor that shares this pane's row or column, or move into a larger neighbor, keeping the row or column.",
  args        = { direction = "string" },
  run         = function(ctx, args)
    local next_pane, my_rect, next_rect = focused_neighbor(ctx, args.direction)
    if next_pane == nil then return end
    local land, same_span = landing_edge(my_rect, next_rect, args.direction)
    if same_span then
      -- A move would stretch whatever shared this pane's split; a swap doesn't.
      local _, err = rex.session.swap_blocks{ block_id = ctx.block_id, other_block_id = next_pane }
      if err ~= nil then error(err, 0) end
      return { swapped = next_pane }
    end
    place(ctx.block_id, next_pane, land)
    return { anchor = next_pane, edge = land }
  end,
}

rex.action{
  name        = "pane_push_dir",
  title       = "Push Pane",
  description = "Move the pane into the neighbor that way, joining its row (up/down) or column (left/right).",
  args        = { direction = "string" },
  run         = function(ctx, args)
    local next_pane, my_rect, next_rect = focused_neighbor(ctx, args.direction)
    if next_pane == nil then return end
    local _, i, sides = axes(args.direction)
    local mine = my_rect[i] + my_rect[i + 2] / 2
    local theirs = next_rect[i] + next_rect[i + 2] / 2
    -- On a tie, land nearer the window edge the pane was closer to.
    local after = mine > theirs + EPS or (math.abs(mine - theirs) <= EPS and mine >= 0.5)
    local edge = after and sides[2] or sides[1]
    place(ctx.block_id, next_pane, edge)
    return { anchor = next_pane, edge = edge }
  end,
}

local function parent_of(node, block_id)
  local split = node.split
  if split == nil then return nil end
  for _, side in ipairs({ "before", "after" }) do
    if split[side].block_id == block_id then return split, side end
    local found, found_side = parent_of(split[side], block_id)
    if found ~= nil then return found, found_side end
  end
end

local TURNS = {
  clockwise        = { left = "up", up = "right", right = "down", down = "left" },
  counterclockwise = { left = "down", down = "right", right = "up", up = "left" },
}

-- move_block can't anchor on a group: use its pane touching me, furthest toward target.
local function orbit_anchor(partner, me, facing, target)
  if partner.block_id ~= nil then return partner.block_id end
  local t = axes(target)
  local best, best_edge
  for _, leaf in ipairs(leaves(partner, {})) do
    local r = leaf.rect
    if math.abs(gap(me, r, facing)) <= EPS then
      local edge = (target == "left" or target == "up") and -r[t] or r[t] + r[t + 2]
      if best == nil or edge > best_edge + EPS then best, best_edge = leaf.block_id, edge end
    end
  end
  return best
end

rex.action{
  name        = "pane_rotate",
  title       = "Rotate Pane",
  description = "Move the pane a quarter turn around its split partner, or around the facing pane when the partner is a group.",
  args        = { turn = "string" },
  run         = function(ctx, args)
    local turn = TURNS[args.turn]
    if turn == nil then error("turn must be clockwise or counterclockwise", 0) end
    if ctx.block_id == nil then error("no focused pane", 0) end
    local split, side = parent_of(current_layout(ctx.block_id), ctx.block_id)
    if split == nil then return end
    local at = split.direction == "horizontal"
      and (side == "before" and "left" or "right")
      or (side == "before" and "up" or "down")
    local target = turn[at]
    local partner = split[side == "before" and "after" or "before"]
    local anchor = orbit_anchor(partner, split[side].rect, OPPOSITE[at], target)
    local ratio
    if partner.block_id ~= nil then
      local share = side == "before" and split.ratio or 1 - split.ratio
      ratio = (target == "left" or target == "up") and share or 1 - share
    end
    place(ctx.block_id, anchor, target, ratio)
    return { anchor = anchor, side = target }
  end,
}

for _, dir in ipairs({ "up", "down", "left", "right" }) do
  rex.bind("shift+alt+cmd+" .. dir, "pane_move_dir", { direction = dir })
end
rex.bind("shift+alt+cmd+pagedown", "pane_rotate", { turn = "clockwise" })
rex.bind("shift+alt+cmd+pageup", "pane_rotate", { turn = "counterclockwise" })
