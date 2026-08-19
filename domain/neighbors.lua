-- Neighbor layout for the map editor's MAP mode: the maps connected to
-- the edited one, placed at their real connection offsets so the editor
-- can draw and edit across the seams like the runtime survey zoom.
--
-- The placement math mirrors OverworldState.computeNeighbors (BFS over the
-- connection graph, composing strip offsets in world pixels) but without
-- the reach-inflation: the editor always shows the fixed two-hop set, the
-- same set the runtime keeps resident around the current map.

local Neighbors = {}
local Common = require("mods.mapamap.common")
local Connections = require("mods.mapamap.domain.connections")
local DIRS = Common.DIRS

local CELL_PX = 16
local BLOCK_PX = 32

-- Default hop count (matches the runtime NEIGHBOR_HOPS=2, which also
-- covers corner-adjacent maps at the diagonals).
local DEFAULT_HOPS = 2

-- Walks the connection graph `hops` connections out from rootId, composing
-- the strip offsets (north/south offsets are horizontal shifts in blocks,
-- west/east offsets vertical), deduped by map id (BFS, so a direct
-- connection always wins over a two-hop path).  Traverses the full
-- connection union per side (the engine primary plus the editor-only extras
-- in `connectionsExtra`), so every map the grid laid out shows up here at its
-- real offset.  Returns
--   { { id = mapId, ox = worldX, oy = worldY, def = mapDef }, ... }
-- with offsets in world pixels relative to the root map's top-left corner
-- and def the connected map's live data record (same table the game uses,
-- so edits across a seam hit the real data).
function Neighbors.compute(maps, rootId, hops)
  local out = {}
  local rootDef = maps and maps[rootId]
  if not rootDef then return out end
  hops = hops or DEFAULT_HOPS
  local placed = { [rootId] = true }
  local queue = { { def = rootDef, ox = 0, oy = 0, hops = 0 } }
  local qi = 1
  while queue[qi] do
    local cur = queue[qi]
    qi = qi + 1
    for _, dir in ipairs(DIRS) do
      for _, conn in ipairs(Connections.connectionsOn(cur.def, dir)) do
        local destDef = maps[conn.map]
        if destDef and not placed[conn.map] then
          placed[conn.map] = true
          local ox, oy
          if dir == "north" then
            ox, oy = conn.offset * BLOCK_PX, -destDef.height * BLOCK_PX
          elseif dir == "south" then
            ox, oy = conn.offset * BLOCK_PX, cur.def.height * BLOCK_PX
          elseif dir == "west" then
            ox, oy = -destDef.width * BLOCK_PX, conn.offset * BLOCK_PX
          else
            ox, oy = cur.def.width * BLOCK_PX, conn.offset * BLOCK_PX
          end
          ox, oy = cur.ox + ox, cur.oy + oy
          if cur.hops + 1 <= hops then
            table.insert(out, { id = conn.map, ox = ox, oy = oy, def = destDef })
            if cur.hops + 1 < hops then
              table.insert(queue, { def = destDef, ox = ox, oy = oy,
                                    hops = cur.hops + 1 })
            end
          end
        end
      end
    end
  end
  return out
end

-- Union bounds (world pixels) of the root map plus every neighbor: the
-- scrollable world of the editor in MAP mode.
function Neighbors.bounds(rootDef, neighbors)
  local minX, minY = 0, 0
  local maxX, maxY = rootDef.width * BLOCK_PX, rootDef.height * BLOCK_PX
  for _, nb in ipairs(neighbors or {}) do
    minX = math.min(minX, nb.ox)
    minY = math.min(minY, nb.oy)
    maxX = math.max(maxX, nb.ox + nb.def.width * BLOCK_PX)
    maxY = math.max(maxY, nb.oy + nb.def.height * BLOCK_PX)
  end
  return minX, minY, maxX, maxY
end

-- World rect (x0, y0, x1, y1) that a map of block dims (w, h) would occupy
-- if connected to rootDef's `side` at `offset` blocks, in world pixels
-- relative to the root map's top-left corner.  Mirrors the offset math in
-- compute() (north/south offsets shift horizontally, west/east vertically).
function Neighbors.mapRectAt(rootDef, side, offset, w, h)
  local off = (offset or 0) * BLOCK_PX
  local x0, y0
  if side == "north" then
    x0, y0 = off, -h * BLOCK_PX
  elseif side == "south" then
    x0, y0 = off, rootDef.height * BLOCK_PX
  elseif side == "west" then
    x0, y0 = -w * BLOCK_PX, off
  else
    x0, y0 = rootDef.width * BLOCK_PX, off
  end
  return x0, y0, x0 + w * BLOCK_PX, y0 + h * BLOCK_PX
end

-- Checks where a new map of block dims (w, h) would land if the root map
-- connected to it on `side` at `offset` blocks.  Every existing map
-- reachable from root is laid out (BFS, matching compute()) and the new
-- map's body is tested against each.  Returns
--   "overlap", mapId        the new map's body overlaps another map's body
--   "flush", mapId, side, offset  the new map's body sits flush (0 gap)
--                            against another map; `side` is the side of the
--                            NEW map that touches and `offset` the block
--                            offset of that connection from the new map's
--                            perspective (the reciprocal on the other map is
--                            the opposite side at -offset)
--   nil                      the new map lands in open space
function Neighbors.probePlacement(maps, rootId, side, offset, w, h)
  local rootDef = maps and maps[rootId]
  if not rootDef then return nil end
  local nx0, ny0, nx1, ny1 = Neighbors.mapRectAt(rootDef, side, offset, w, h)

  local rects = {
    { id = nil, x0 = 0, y0 = 0,
      x1 = rootDef.width * BLOCK_PX, y1 = rootDef.height * BLOCK_PX },
  }
  for _, nb in ipairs(Neighbors.compute(maps, rootId, math.huge)) do
    table.insert(rects, {
      id = nb.id,
      x0 = nb.ox, y0 = nb.oy,
      x1 = nb.ox + nb.def.width * BLOCK_PX,
      y1 = nb.oy + nb.def.height * BLOCK_PX,
    })
  end

  -- Strict interior overlap (a shared edge is adjacency, not a collision).
  for _, r in ipairs(rects) do
    if nx0 < r.x1 and r.x0 < nx1 and ny0 < r.y1 and r.y0 < ny1 then
      return "overlap", r.id
    end
  end

  -- Flush (0 gap) contact against a map that is not the root (the root's own
  -- connection already covers that shared edge).
  for _, r in ipairs(rects) do
    if r.id ~= nil then
      local flushSide, flushOff
      if ny1 == r.y0 and nx0 < r.x1 and r.x0 < nx1 then
        flushSide, flushOff = "south", (r.x0 - nx0) / BLOCK_PX
      elseif r.y1 == ny0 and nx0 < r.x1 and r.x0 < nx1 then
        flushSide, flushOff = "north", (r.x0 - nx0) / BLOCK_PX
      elseif nx1 == r.x0 and ny0 < r.y1 and r.y0 < ny1 then
        flushSide, flushOff = "east", (r.y0 - ny0) / BLOCK_PX
      elseif r.x1 == nx0 and ny0 < r.y1 and r.y0 < ny1 then
        flushSide, flushOff = "west", (r.y0 - ny0) / BLOCK_PX
      end
      if flushSide then
        return "flush", r.id, flushSide, flushOff
      end
    end
  end
  return nil
end

-- The map whose body contains a world-cell coordinate, or nil when the
-- cell is not covered by any laid-out map.  The edited map (nil id) wins
-- over a neighbor at an overlapping corner.  Returns mapId, def, ox, oy.
function Neighbors.mapAt(rootDef, neighbors, cellX, cellY)
  local px = cellX * CELL_PX
  local py = cellY * CELL_PX
  local rw = rootDef.width * BLOCK_PX
  local rh = rootDef.height * BLOCK_PX
  if px >= 0 and px < rw and py >= 0 and py < rh then
    return nil, rootDef, 0, 0
  end
  for _, nb in ipairs(neighbors or {}) do
    local nw = nb.def.width * BLOCK_PX
    local nh = nb.def.height * BLOCK_PX
    if px >= nb.ox and px < nb.ox + nw and py >= nb.oy and py < nb.oy + nh then
      return nb.id, nb.def, nb.ox, nb.oy
    end
  end
  return nil
end

return Neighbors
