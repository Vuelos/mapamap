-- Grid-based map expansion for mapamap.
--
-- Map creation is owned by the grid and runs on map load, not on paint: a
-- BFS over the connection graph derives each reachable map's block-space rect
-- relative to the root (0,0), open edges are the sides with no map flush
-- against them, and autofill closes the voids -- always the cell with the most
-- flush neighbours first, bounded by a hop-depth limit so the world cannot
-- grow unboundedly from a single load.  The old paint-time edge creation
-- (NewMap.createEdgeMap / growToOppositeSide / handleEdgePaint) is removed.
--
-- Fill maps reuse the engine's connection convention (reciprocal offsets
-- mirror; flush maps get wired both ways), so a walked seam lands correctly.

local MapGrid = {}
local Neighbors = require("mods.mapamap.func.neighbors")
local NewMap = require("mods.mapamap.func.new_map")
local Common = require("mods.mapamap.func.common")
local BLOCK_PX = Common.BLOCK_PX

MapGrid.DEFAULT_DEPTH = 1   -- autofill fills voids one ring beyond the loaded map

local DIRS = { "north", "south", "west", "east" }

-- Opposite connection side for reciprocal links.
local RECIP = { north = "south", south = "north", east = "west", west = "east" }

-- BFS layout: every map reachable from `rootId` within `hops` connections,
-- with its world rect in BLOCK coords relative to the root (0,0) and its
-- hop depth.  Mirrors Neighbors.compute's offset composition so the rects
-- line up with the positions the editor/runtime actually draw.
-- Returns { { id, x, y, w, h, def, hop }, ... } (root first, hop 0).
function MapGrid.layout(maps, rootId, hops)
  local rootDef = maps and maps[rootId]
  if not rootDef then return {} end
  local out = {}
  local placed = { [rootId] = true }
  local queue = { { id = rootId, x = 0, y = 0,
                    w = rootDef.width, h = rootDef.height,
                    def = rootDef, hop = 0 } }
  local qi = 1
  while queue[qi] do
    local cur = queue[qi]
    qi = qi + 1
    table.insert(out, cur)
    if cur.hop < (hops or MapGrid.DEFAULT_DEPTH) then
      for dir, conn in pairs(cur.def.connections or {}) do
        local destDef = maps[conn.map]
        if destDef and not placed[conn.map] then
          placed[conn.map] = true
          local x, y = cur.x, cur.y
          local off = conn.offset or 0
          if dir == "north" then
            x = cur.x + off
            y = cur.y - destDef.height
          elseif dir == "south" then
            x = cur.x + off
            y = cur.y + cur.h
          elseif dir == "west" then
            x = cur.x - destDef.width
            y = cur.y + off
          else -- east
            x = cur.x + cur.w
            y = cur.y + off
          end
          if cur.hop + 1 <= (hops or MapGrid.DEFAULT_DEPTH) then
            table.insert(queue, { id = conn.map, x = x, y = y,
                                  w = destDef.width, h = destDef.height,
                                  def = destDef, hop = cur.hop + 1 })
          end
        end
      end
    end
  end
  return out
end

-- True when the rect (x,y,w,h) interior-overlaps any rect in `layout`.
function MapGrid.overlaps(layout, x, y, w, h)
  for _, r in ipairs(layout or {}) do
    if x < r.x + r.w and r.x < x + w and y < r.y + r.h and r.y < y + h then
      return true
    end
  end
  return false
end

-- True when `a` (x0,y0,x1,y1) sits flush against `b` (bx,by,bw,bh) sharing a
-- seam segment (edges touch; bodies do not overlap).
function MapGrid.flushOf(x0, y0, x1, y1, bx, by, bw, bh)
  local north = (by + bh == y0) and x0 < bx + bw and bx < x1
  local south = (y1 == by) and x0 < bx + bw and bx < x1
  local west = (bx + bw == x0) and y0 < by + bh and by < y1
  local east = (x1 == bx) and y0 < by + bh and by < y1
  return north or south or west or east
end

-- Every laid-out map whose body sits flush against the void (bx,by,w,h), with
-- the connection it would need: `side` is the side of the VOID it touches and
-- `recip` the reciprocal side that must stay free on the map (the engine's
-- connection model allows one connection per side).  Returns
-- { { id, def, side, off, recip }, ... }.
function MapGrid.flushAgainst(full, bx, by, w, h)
  local x0, y0, x1, y1 = bx, by, bx + w, by + h
  local out = {}
  for _, nb in ipairs(full or {}) do
    if nb.id then
      local a0, b0 = nb.x, nb.y
      local a1, b1 = a0 + nb.w, b0 + nb.h
      local side, off
      if b1 == y0 and a0 < x1 and x0 < a1 then
        side, off = "north", (a0 - x0)
      elseif y1 == b0 and a0 < x1 and x0 < a1 then
        side, off = "south", (a0 - x0)
      elseif a1 == x0 and b0 < y1 and y0 < b1 then
        side, off = "west", (b0 - y0)
      elseif x1 == a0 and b0 < y1 and y0 < b1 then
        side, off = "east", (b0 - y0)
      end
      if side then
        out[#out + 1] = { id = nb.id, def = nb.def,
                          side = side, off = off, recip = RECIP[side] }
      end
    end
  end
  return out
end

-- Every open-edge candidate cell: for each map in `layout` (within `depth`
-- hops of the root), a same-footprint void sitting flush on each side, scored
-- by the number of laid-out maps already flush against it.  A void is only
-- usable when every flush contact has its reciprocal connection side still
-- free (the engine allows one connection per side), so creating it can never
-- clobber an existing connection.  Overlap and connectivity are measured
-- against the FULL reachable layout, not just the depth-capped one.  Deduped
-- by position (a void can be reachable from two sides).  Returns
-- { { bx, by, w, h, dir, from, conns }, ... }.
function MapGrid.candidates(self, depth)
  local full = MapGrid.layout(self.data.maps, self.mapId, math.huge)
  local capped = MapGrid.layout(self.data.maps, self.mapId,
                                depth or MapGrid.DEFAULT_DEPTH)
  local best = {}
  for _, r in ipairs(capped) do
    for _, dir in ipairs(DIRS) do
      local bx, by = r.x, r.y
      local w, h = r.w, r.h
      if dir == "north" then
        by = r.y - h
      elseif dir == "south" then
        by = r.y + h
      elseif dir == "west" then
        bx = r.x - w
      else -- east
        bx = r.x + w
      end
      if not MapGrid.overlaps(full, bx, by, w, h) then
        local flush = MapGrid.flushAgainst(full, bx, by, w, h)
        if #flush > 0 then
          local blocked = false
          for _, f in ipairs(flush) do
            local conns = f.def.connections or {}
            if conns[f.recip] then blocked = true break end
          end
          if not blocked then
            local key = bx .. "," .. by .. "," .. w .. "," .. h
            local prev = best[key]
            if not prev or #flush > prev.conns then
              best[key] = { bx = bx, by = by, w = w, h = h, dir = dir,
                            from = r.id, conns = #flush }
            end
          end
        end
      end
    end
  end
  local out = {}
  for _, c in pairs(best) do out[#out + 1] = c end
  return out
end

-- The highest-connectivity open void, or nil.
function MapGrid.bestVoid(self, depth)
  local best
  for _, c in ipairs(MapGrid.candidates(self, depth)) do
    if not best or c.conns > best.conns
       or (c.conns == best.conns and (c.bx < best.bx
           or (c.bx == best.bx and c.by < best.by))) then
      best = c
    end
  end
  return best
end

-- Creates a map of `w` x `h` blocks at block (bx,by), wired with reciprocal
-- connections to every laid-out map flush against it whose reciprocal side is
-- still free.  Returns the new id, or nil when the body would interior-overlap
-- an existing map.
function MapGrid.createMap(self, bx, by, w, h)
  if not (self and self.data and self.data.maps) then return nil end
  if w <= 0 or h <= 0 then return nil end
  local full = MapGrid.layout(self.data.maps, self.mapId, math.huge)
  if MapGrid.overlaps(full, bx, by, w, h) then return nil end

  local flush = MapGrid.flushAgainst(full, bx, by, w, h)
  local free = {}
  for _, f in ipairs(flush) do
    local conns = f.def.connections or {}
    if not conns[f.recip] then free[#free + 1] = f end
  end

  local newId = self.mapId .. "_EXT"
  local n = 1
  while self.data.maps[newId] do
    n = n + 1
    newId = self.mapId .. "_EXT" .. n
  end
  local newDef = NewMap.buildDef(self, newId, w, h)
  self.data.maps[newId] = newDef

  local wired = {}
  for _, f in ipairs(free) do
    newDef.connections = newDef.connections or {}
    newDef.connections[f.side] = { map = f.id, offset = f.off }
    f.def.connections = f.def.connections or {}
    f.def.connections[f.recip] = { map = newId, offset = -f.off }
    self.neighborDirty = self.neighborDirty or {}
    self.neighborDirty[f.id] = true
    wired[#wired + 1] = f.id
  end

  -- Snapshot AFTER wiring so the persisted new map carries its connections.
  self._newMaps = self._newMaps or {}
  self._newMaps[newId] = Common.deepCopy(newDef)

  -- rebuildWorldNeighbors() re-baselines the neighbor originals, which would
  -- otherwise drop the reciprocal connections just added to laid-out maps
  -- from the close-time patch diff.  Keep the pre-mutation originals for the
  -- wired maps so their new connection edges survive a reload.
  local keptOriginal = {}
  if self.neighborOriginals then
    for _, id in ipairs(wired) do
      if self.neighborOriginals[id] then keptOriginal[id] = self.neighborOriginals[id] end
    end
  end

  self.mapChanged = true
  self:rebuildWorldNeighbors()
  if self.neighborOriginals then
    for id, orig in pairs(keptOriginal) do self.neighborOriginals[id] = orig end
  end
  return newId
end

-- Fills the single highest-connectivity open void within `depth` hops of the
-- loaded map.  Returns the new map id or nil when no void remains.
function MapGrid.fillNextVoid(self, depth)
  local void = MapGrid.bestVoid(self, depth)
  if not void then return nil end
  return MapGrid.createMap(self, void.bx, void.by, void.w, void.h)
end

-- Creates maps at every open void flush on `direction` (north/south/west/east)
-- within `depth` hops.  Returns how many were created.
function MapGrid.expandInDirection(self, direction, depth)
  local created = 0
  for _, c in ipairs(MapGrid.candidates(self, depth)) do
    if c.dir == direction then
      if MapGrid.createMap(self, c.bx, c.by, c.w, c.h) then
        created = created + 1
      end
    end
  end
  return created
end

-- The load-time fill: repeatedly closes the highest-connectivity void while
-- any remains within `depth` hops, bounded by a safety cap.  Returns the
-- number of maps created.
function MapGrid.autofill(self, depth)
  local created = 0
  local limit = 64
  while created < limit do
    local id = MapGrid.fillNextVoid(self, depth)
    if not id then break end
    created = created + 1
  end
  return created
end

return MapGrid