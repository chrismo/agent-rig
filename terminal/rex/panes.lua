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

local function neighbor(layout, block_id, dir)
  local along, across = axes(dir)
  local all = leaves(layout, {})
  local me
  for _, leaf in ipairs(all) do
    if leaf.block_id == block_id then me = leaf.rect end
  end
  local best, best_rect, best_gap, best_overlap
  for _, leaf in ipairs(all) do
    local r = leaf.rect
    local gap
    if dir == "left" or dir == "up" then
      gap = me[along] - (r[along] + r[along + 2])
    else
      gap = r[along] - (me[along] + me[along + 2])
    end
    local overlap = math.min(me[across] + me[across + 2], r[across] + r[across + 2])
      - math.max(me[across], r[across])
    if leaf.block_id ~= block_id and gap > -EPS and overlap > EPS then
      if best == nil or gap < best_gap - EPS
          or (math.abs(gap - best_gap) <= EPS and overlap > best_overlap) then
        best, best_rect, best_gap, best_overlap = leaf.block_id, r, gap, overlap
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

-- Aim mode: ⇧⌥+arrow starts moving the focused pane, live, one landing spot at
-- a time; arrows walk, Enter keeps it there, Escape puts it back. Rex shows
-- no preview, so the move itself is the preview.
-- Each other pane offers the middle of each half. An edge facing the source
-- across a matching span would only reshuffle sizes, so skip it.
local function landing_spots(layout, source)
  local spots = {}
  for _, leaf in ipairs(leaves(layout, {})) do
    local id, r = leaf.block_id, leaf.rect
    if id ~= source then
      local x, y, w, h = r[1], r[2], r[3], r[4]
      local points = {
        left = { x + w / 4, y + h / 2 }, right = { x + 3 * w / 4, y + h / 2 },
        up = { x + w / 2, y + h / 4 }, down = { x + w / 2, y + 3 * h / 4 },
      }
      for _, kind in ipairs({ "left", "right", "up", "down" }) do
        local next_id, me, there = neighbor(layout, id, kind)
        local _, across = axes(kind)
        local no_op = next_id == source
          and math.abs(me[across] - there[across]) <= EPS
          and math.abs(me[across + 2] - there[across + 2]) <= EPS
        if not no_op then spots[#spots + 1] = { block_id = id, kind = kind, at = points[kind] } end
      end
    end
  end
  return spots
end

-- The nearest spot that way from a point, favoring spots in line with it.
local function step(spots, from, dir)
  local along, across = axes(dir)
  local sign = (dir == "left" or dir == "up") and -1 or 1
  local best, best_score
  for _, s in ipairs(spots) do
    local ahead = (s.at[along] - from[along]) * sign
    if ahead > EPS then
      local score = ahead + 2 * math.abs(s.at[across] - from[across])
      if best == nil or score < best_score - EPS then best, best_score = s, score end
    end
  end
  return best
end

-- Where to put the pane back: beside its sibling, or beside the pane facing it
-- in its sibling's group, which is as close as move_block can get.
local function origin(layout, source)
  local function find(node)
    if node.split == nil then return nil end
    for _, pair in ipairs({ { node.split.before, node.split.after, "before" }, { node.split.after, node.split.before, "after" } }) do
      local me, sib, side = pair[1], pair[2], pair[3]
      if me.block_id == source then
        local horizontal = node.split.direction == "horizontal"
        local edge = horizontal and (side == "before" and "left" or "right") or (side == "before" and "up" or "down")
        if sib.block_id ~= nil then return { anchor = sib.block_id, edge = edge } end
        return { anchor = (neighbor(layout, source, OPPOSITE[edge])), edge = edge }
      end
    end
    return find(node.split.before) or find(node.split.after)
  end
  return find(layout)
end

-- The pane being aimed and, for each step, where it was before that step.
local aiming

rex.action{
  name        = "pane_aim",
  title       = "Aim Pane",
  description = "Move the focused pane to the nearest edge of another pane that way.",
  args        = { direction = "string", start = "boolean" },
  run         = function(ctx, args)
    if OPPOSITE[args.direction] == nil then error("direction must be left, right, up, or down", 0) end
    local fresh = args.start or aiming == nil
    local source = fresh and ctx.block_id or aiming.source
    if source == nil then error("no focused pane", 0) end
    local layout = current_layout(source)
    local from
    for _, leaf in ipairs(leaves(layout, {})) do
      if leaf.block_id == source then
        local r = leaf.rect
        from = { r[1] + r[3] / 2, r[2] + r[4] / 2 }
      end
    end
    local spot = step(landing_spots(layout, source), from, args.direction)
    if spot == nil then return end
    if fresh then aiming = { source = source, back = {} } end
    aiming.back[#aiming.back + 1] = origin(layout, source)
    place(source, spot.block_id, spot.kind)
    if fresh then rex.client.queue("client.mode.enter", { name = "aim" }) end
  end,
}

rex.action{
  name  = "pane_aim_drop",
  title = "Drop Aimed Pane",
  run   = function()
    aiming = nil
    rex.client.queue("client.mode.exit")
  end,
}

rex.action{
  name  = "pane_aim_cancel",
  title = "Cancel Aiming Pane",
  run   = function()
    local a = aiming
    aiming = nil
    for i = #(a and a.back or {}), 1, -1 do
      place(a.source, a.back[i].anchor, a.back[i].edge)
    end
    rex.client.queue("client.mode.exit")
  end,
}

rex.mode("aim", { exclusive = true })
rex.bind("aim/enter", "pane_aim_drop")
rex.bind("aim/escape", "pane_aim_cancel")

for _, dir in ipairs({ "up", "down", "left", "right" }) do
  rex.bind("shift+alt+cmd+" .. dir, "pane_move_dir", { direction = dir })
  rex.bind("shift+alt+" .. dir, "pane_aim", { direction = dir, start = true })
  rex.bind("aim/" .. dir, "pane_aim", { direction = dir })
  rex.bind("aim/shift+alt+" .. dir, "pane_aim", { direction = dir })
end
