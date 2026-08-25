-- Warp editing operations for the mapamap overlay.  Mixed into Session so
-- every method receives the session as `self`.

local WorldAdapter = require("mods.mapamap.engine.world_adapter")

local Warps = {}

-- Bounds check for a walk-grid cell against a map def.
local function cellIn(def, x, y)
  return x >= 0 and y >= 0 and x < def.width * 2 and y < def.height * 2
end

-- The warp wired at a walk-grid cell on the edited map, or nil.  Coordinates
-- are walk-grid cells (px = x*16), like objects.
function Warps.warpAt(self, cellX, cellY)
  for _, w in ipairs(self.def.warps or {}) do
    if (w.x or -1) == cellX and (w.y or -1) == cellY then return w end
  end
  return nil
end

-- Every warp on every visible laid-out map (the edited map plus the neighbor
-- set), flattened with its map's world-pixel offset so the overlay can project
-- them all onto the shared world.  Returns { { warp, ox, oy }, ... }; only the
-- edited map's warps (ox = 0, oy = 0) can ever be the live selection.
function Warps.visibleWarps(self)
  local out = {}
  local function collect(def, ox, oy)
    for _, w in ipairs(def and def.warps or {}) do
      out[#out + 1] = { warp = w, ox = ox, oy = oy }
    end
  end
  collect(self.def, 0, 0)
  for _, nb in ipairs(self.neighbors or {}) do
    collect(nb.def, nb.ox, nb.oy)
  end
  return out
end

-- The 1-based position of `warp` in the edited map's warps array (the engine
-- numbers warps by array index), or nil.
function Warps.warpIndex(self, warp)
  for i, w in ipairs(self.def.warps or {}) do
    if w == warp then return i end
  end
  return nil
end

-- Places a new warp at `cellX, cellY` leading to `destMap` warp number
-- `destWarp` (0-based, the engine's numbering).  Returns the warp or nil.
function Warps.placeWarp(self, cellX, cellY, destMap, destWarp)
  if not cellIn(self.def, cellX, cellY) then return nil end
  if self:cellOccupied(cellX, cellY) then return nil end
  if self.undo then self.undo:capture(self.def) end
  self.def.warps = self.def.warps or {}
  local w = { x = cellX, y = cellY,
              destMap = destMap or self.mapId, destWarp = destWarp or 1 }
  table.insert(self.def.warps, w)
  self.mapChanged = true
  WorldAdapter.refreshWarps(self)
  return w
end

-- Moves an existing warp to a cell and marks the map changed.
function Warps.moveWarp(self, warp, cellX, cellY)
  if not warp then return false end
  if not cellIn(self.def, cellX, cellY) then return false end
  if warp.x == cellX and warp.y == cellY then return true end
  if self:cellOccupied(cellX, cellY, warp) then return false end
  if self.undo then self.undo:capture(self.def) end
  warp.x, warp.y = cellX, cellY
  self.mapChanged = true
  return true
end

-- Re-points a warp's destination (destMap and/or destWarp, 0-based).
-- destWarp is VALIDATED against the target map's warp list: the engine
-- lands you on def.warps[destWarp + 1], so an out-of-range number would
-- crash on take.  Returns false when the number doesn't exist.
function Warps.setWarpDest(self, warp, destMap, destWarp)
  if not warp then return false end
  if self.undo then self.undo:capture(self.def) end
  if destMap then warp.destMap = destMap end
  if destWarp ~= nil then
    -- The engine indexes the destination list 1-BASED (Warp.resolve /
    -- World.takeWarp both do warps[n]), so valid numbers are 1..count.
    local n = math.floor(tonumber(destWarp) or 1)
    local tdef = self.data.maps and self.data.maps[warp.destMap]
    local count = tdef and tdef.warps and #tdef.warps or 0
    if n < 1 or n > count then return false end
    warp.destWarp = n
  end
  WorldAdapter.refreshWarps(self)
  return true
end

-- Sets a warp's display label.
function Warps.setWarpLabel(self, warp, label)
  if not warp then return false end
  if self.undo then self.undo:capture(self.def) end
  warp.label = label
  self.mapChanged = true
  return true
end

-- Removes a warp from the edited map.
function Warps.removeWarp(self, warp)
  local list = self.def.warps or {}
  for i = #list, 1, -1 do
    if list[i] == warp then
      if self.undo then self.undo:capture(self.def) end
      table.remove(list, i)
      self.mapChanged = true
      WorldAdapter.refreshWarps(self)
      return true
    end
  end
  -- Not on the edited map: it may live on a laid-out neighbor.
  return self:removeEntityFromOwner(warp, "warps")
end

-- Graphically wires `warp` to land on `destMapId` at `cellX, cellY` (walk-grid
-- cells on the destination map): the destination map gets a warp there (reused
-- when one already sits at the cell) whose reciprocal points back at the edited
-- warp, so the pair is traversable both ways.  The destination map is marked
-- dirty so its warps are diff-persisted when it's a loaded neighbor.
function Warps.connectWarpToCell(self, warp, destMapId, cellX, cellY)
  if not warp then return false end
  local destDef = self.data.maps[destMapId]
  if not destDef or not cellIn(destDef, cellX, cellY) then return false end
  if self.undo then self.undo:capture(self.def) end
  destDef.warps = destDef.warps or {}
  local idx
  for i, dw in ipairs(destDef.warps) do
    if (dw.x or -1) == cellX and (dw.y or -1) == cellY then idx = i; break end
  end
  local destWarp
  if idx then
    destWarp = destDef.warps[idx]
  else
    destWarp = { x = cellX, y = cellY, destMap = self.mapId }
    table.insert(destDef.warps, destWarp)
    idx = #destDef.warps
  end
  local srcIdx = self:warpIndex(warp) or 1
  warp.destMap = destMapId
  warp.destWarp = idx
  destWarp.destMap = self.mapId
  destWarp.destWarp = srcIdx
  if destDef ~= self.def then
    self.neighborDirty = self.neighborDirty or {}
    self.neighborDirty[destMapId] = true
  end
  self.mapChanged = true
  WorldAdapter.refreshWarps(self)
  return true
end

-- Resolves where a warp points, for the overlay's edit-time preview:
--   { def, ox, oy, cellX, cellY, laidOut, label }
-- `def` is the destination map's def (nil for unknown ids); ox/oy are its
-- world-pixel offsets when it is one of the LAID-OUT maps (root or a
-- neighbor -- laidOut=true), else nil; the cell is the destination warp
-- entry's own position (warp # is 1-BASED -- both engines index
-- warps[destWarp] directly), falling back to the map center.
function Warps.destPreview(self, destMap, destWarp)
  if not destMap then return nil end
  local def = self.data.maps and self.data.maps[destMap]
  if not def then return nil end
  local ox, oy, laidOut
  if destMap == self.mapId then
    ox, oy, laidOut = 0, 0, true
  else
    for _, nb in ipairs(self.neighbors or {}) do
      if nb.id == destMap then ox, oy, laidOut = nb.ox, nb.oy, true break end
    end
  end
  local idx = math.floor(tonumber(destWarp) or 1)
  local target = def.warps and def.warps[idx] or nil
  local cellX, cellY
  if target then
    cellX, cellY = target.x or -1, target.y or -1
  else
    cellX = math.floor((def.width or 2) / 2)
    cellY = math.floor((def.height or 2) / 2)
  end
  return {
    def = def,
    ox = ox, oy = oy, laidOut = laidOut and true or false,
    cellX = cellX, cellY = cellY,
    label = tostring(destMap) .. " #" .. tostring(math.floor(tonumber(destWarp) or 1)),
  }
end

return Warps
