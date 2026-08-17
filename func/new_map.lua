-- New map creation for mapamap's direct map editing: creates an adjacent
-- map (unique `_EXT` id) hanging off a chosen edge of the current map, with a
-- traversal connection and a reciprocal connection back on the other map.
--
-- Kept self-contained (no screen/text-input dependencies): mapamap draws its
-- whole UI as an overlay, so creation here is a pure data operation that the
-- input handler can trigger directly.

local NewMap = {}
local Neighbors = require("mods.mapamap.func.neighbors")
local Common = require("mods.mapamap.func.common")
local Connections = require("mods.mapamap.func.connections")
local BLOCK_PX = Common.BLOCK_PX

-- True when `name` is already used as another map's display name (a map's
-- display name is its `name` field, falling back to its id).
function NewMap.isMapNameUsed(data, name, excludeId)
  for id, def in pairs(data.maps or {}) do
    if id ~= excludeId and (def.name or id) == name then return true end
  end
  return false
end

-- Returns a display name based on `base` (default "NEW_MAP") that no map uses
-- yet: "NEW_MAP", "NEW_MAP_2", "NEW_MAP_3", ...
function NewMap.uniqueMapName(data, base)
  base = (base ~= nil and base ~= "") and base or "NEW_MAP"
  local name = base
  local n = 1
  while NewMap.isMapNameUsed(data, name) do
    n = n + 1
    name = base .. "_" .. n
  end
  return name
end

-- A fresh, empty map definition (block grid filled with the current map's
-- border block) with a unique id/name next to this map's, styled after the
-- current map (tileset, palette, zeroed encounters).
function NewMap.buildDef(self, id, w, h)
  local border = self.def.borderBlock or 0
  local blocks = {}
  for i = 1, w * h do blocks[i] = border end
  local name = NewMap.uniqueMapName(self.data, "NEW_MAP")
  local maxIndex = 0
  for _, def in pairs(self.data.maps or {}) do
    if def.index and def.index > maxIndex then maxIndex = def.index end
  end
  return {
    id = id, name = name, width = w, height = h,
    blocks = blocks, borderBlock = border,
    warps = {}, objects = {}, signs = {},
    connections = {},
    tileset = self.def.tileset, palette = self.def.palette,
    index = maxIndex + 1, label = id,
    encounters = {
      grass = { rate = 0, slots = {} },
      water = { rate = 0, slots = {} },
      indoor = { rate = 0, slots = {} },
    },
  }
end

-- Creates a new map connected on `side` at `offset` blocks, and wires a
-- reciprocal connection to EVERY map whose body ends up flush against the
-- new one (not just the source map).  Returns the new id, or nil.
function NewMap.createSidedMap(self, side, offset)
  local data = self.data
  if not data or not data.maps then return nil end
  local width = self.def.width
  local height = self.def.height

  local newId = self.mapId .. "_EXT"
  local n = 1
  while data.maps[newId] do
    n = n + 1
    newId = self.mapId .. "_EXT" .. n
  end

  local kind, probeId = Neighbors.probePlacement(
    data.maps, self.mapId, side, offset, width, height)
  if kind == "overlap" then
    self.mod.log:warn("mapamap: new map would overlap %s", probeId or "?")
    return nil
  end

  local newDef = NewMap.buildDef(self, newId, width, height)
  data.maps[newId] = newDef

  -- Connection from the current map to the new map, plus the reciprocal.
  -- Goes through addConnection so an already-occupied side keeps its primary
  -- and stacks this one as an extra instead of clobbering it.
  Connections.addConnection(self.def, newDef, side, offset or 0, width)

  -- Wire reciprocal connections to every other map flush against the new
  -- body: recompute the world rect of the new map and test every laid-out
  -- map reachable from the source.
  local x0, y0, x1, y1 = Neighbors.mapRectAt(
    self.def, side, offset or 0, width, height)
  for _, nb in ipairs(Neighbors.compute(data.maps, self.mapId, math.huge)) do
    if nb.id ~= newId then
      local nx0, ny0 = nb.ox, nb.oy
      local nx1 = nx0 + nb.def.width * BLOCK_PX
      local ny1 = ny0 + nb.def.height * BLOCK_PX
      local flushSide, flushOff, flushSpan
      if ny1 == y0 and nx0 < x1 and x0 < nx1 then
        flushSide, flushOff = "north", (nx0 - x0) / BLOCK_PX
        flushSpan = (math.min(x1, nx1) - math.max(x0, nx0)) / BLOCK_PX
      elseif y1 == ny0 and nx0 < x1 and x0 < nx1 then
        flushSide, flushOff = "south", (nx0 - x0) / BLOCK_PX
        flushSpan = (math.min(x1, nx1) - math.max(x0, nx0)) / BLOCK_PX
      elseif nx1 == x0 and ny0 < y1 and y0 < ny1 then
        flushSide, flushOff = "west", (ny0 - y0) / BLOCK_PX
        flushSpan = (math.min(y1, ny1) - math.max(y0, ny0)) / BLOCK_PX
      elseif x1 == nx0 and ny0 < y1 and y0 < ny1 then
        flushSide, flushOff = "east", (ny0 - y0) / BLOCK_PX
        flushSpan = (math.min(y1, ny1) - math.max(y0, ny0)) / BLOCK_PX
      end
      if flushSide then
        Connections.addConnection(newDef, nb.def, flushSide, flushOff, flushSpan)
        self.neighborDirty = self.neighborDirty or {}
        self.neighborDirty[nb.id] = true
      end
    end
  end

  self.mapChanged = true
  return newId
end

-- Creates the map definition in data.maps (empty block grid filled with the
-- current map's border block) with a unique id and name next to this map's,
-- connected so the player can walk straight across.  Returns the new id, or
-- nil when the new map's body would overlap an existing laid-out map.
function NewMap.createConnectedMap(self, side)
  return NewMap.createSidedMap(self, side, 0)
end

return NewMap