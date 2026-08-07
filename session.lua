-- mapamap editing session: a state holder that mixes in the reusable map
-- editor data-op modules (map_ops, editor_neighbors, new_map) so the overlay
-- can paint and expand maps against the same live Data tables the game reads,
-- then persist minimal patches through func.save.
--
-- Unlike the full-screen map_editor scene it derives from, this has no draw,
-- update, or screen-stack lifecycle: main.lua drives it in response to mouse
-- input and render.hud.  The cursor lives in world-cell coordinates (cursorBx /
-- cursorBy) that the Coords module fills each mouse move, and painting converts
-- through the func.op helpers exactly as map_editor does.

local Common = require("mods.mapamap.func.common")
local Snapshot = require("mods.mapamap.func.snapshot")
local Undo = require("mods.mapamap.func.undo")
local Save = require("mods.mapamap.func.save")
local TileRenderer = require("src.render.TileRenderer")
local PaletteFX = require("src.render.PaletteFX")

local Session = {}

-- Mix reusable method tables onto the session.
local function mixin(t, src) for k, v in pairs(src) do t[k] = v end end
mixin(Session, require("mods.mapamap.func.map_ops"))
mixin(Session, require("mods.mapamap.func.editor_neighbors"))

-- Creates a session editing `mapId`.  Returns the session or nil when the
-- map or its tileset cannot be loaded.
function Session.new(mod, game, mapId)
  local data = game.data
  local def = data.maps[mapId]
  if not def then return nil end
  local tileset = data.tilesets[def.tileset]
  if not tileset then return nil end

  local MapLoader = require("src.world.MapLoader")
  local ok, map = pcall(MapLoader.load, data, mapId)
  if not ok or not map or not map.renderer then return nil end

  local self = {
    mod = mod, game = game, data = data,
    mapId = mapId, def = def, tileset = tileset, map = map,
    cursorBx = 0, cursorBy = 0,
    selectedBlock = 1,
    brushSize = 1,
    mapChanged = false,
    undo = Undo.new(),
    _originalSnapshot = nil,
    originalRecipConnections = {},
    originalEncounters = nil,
    font = mod.ui.Font,
    mapW = def.width * Common.BLOCK_PX,
    mapH = def.height * Common.BLOCK_PX,
    neighbors = {},
    neighborMaps = {},
    neighborOriginals = {},
    neighborDirty = {},
    _sessionOriginals = {},
    _sessionEncounters = {},
    _sessionDirty = {},
    paletteList = {},
    spriteList = {},
    paletteColors = nil,
  }

  setmetatable(self, { __index = Session })
  self:rebuildNeighbors()
  self:storeOriginal()
  self.paletteColors = self:mapPaletteColors()
  return self
end

-- Refreshes the editor state after a patch was applied (pin the map renderer
-- to the live world data and re-baseline originals so an unsaved exit only
-- reverts what changed after this point).
function Session:refreshAfterLoad()
  self:rebuildNeighbors()
  self:storeOriginal()
  if self.map and self.map.renderer then self.map.renderer:rebuild() end
end

-- Force the renderers the PLAYER actually sees to rebuild so an edit shows up
-- immediately.  The session mutates the live map `def` records, and rebuild
-- the session's own cached Map instances, but the overworld may be holding a
-- different (pre-walk) Map object for the edited map; rebuilding the live
-- overworld map + neighbor renderers too guarantees the screen updates at
-- once instead of waiting for the next map enter.
function Session:refreshLiveRenderers()
  local ow = self.game and self.game.overworld
  local MapLoader = require("src.world.MapLoader")
  -- Rebuild the instance the overworld is ACTUALLY drawing, not just the
  -- cached one.  After MapLoader.invalidateAll the cached entry may be a
  -- fresh object while ow.map still references the pre-invalidate instance
  -- it sits on, so rebuilding only `cached(id)`'s renderer would miss the
  -- one on screen (edits would wait for a re-enter before showing).
  if ow and ow.map and ow.map.renderer then
    ow.map.renderer:rebuild()
    local live = MapLoader.cached(ow.map.id)
    if live and live ~= ow.map and live.renderer then live.renderer:rebuild() end
  end
  if ow and ow.neighbors then
    for _, nb in ipairs(ow.neighbors) do
      if nb and nb.map and nb.map.renderer then
        nb.map.renderer:rebuild()
        local live = MapLoader.cached(nb.map.id)
        if live and live ~= nb.map and live.renderer then live.renderer:rebuild() end
      end
    end
  end
  if self.map and self.map.renderer then self.map.renderer:rebuild() end
end

-- Reloads the session's map from the live data and rebuilds its renderer.
-- Mirrors map_editor's MapEditor:reloadMap but keeps the mapamap live-data
-- model (the def table is the same one the game draws, so a reload just
-- re-points the Map instance and refreshes originals).  Used by undo/redo
-- restores when the edited map's body changed.
function Session:reloadMap()
  local MapLoader = require("src.world.MapLoader")
  MapLoader.invalidate(self.mapId)
  self.map = MapLoader.load(self.data, self.mapId)
  if self.map and self.map.renderer then self.map.renderer:rebuild() end
  self:storeOriginal()
end

-- Re-runs the overworld's neighbor resolution so a freshly created edge map
-- (which lives in data.maps but not yet in ow.neighbors) shows up on screen
-- without waiting for the player to step off the map and back in.  The
-- session's own neighbor layout is rebuilt first so the new body joins both
-- the editor's hit-testing set and the live drawn set.
function Session:rebuildWorldNeighbors()
  self:rebuildNeighbors()
  local ow = self.game and self.game.overworld
  if not (ow and ow.rebuildNeighbors) then
    self:refreshLiveRenderers()
    return
  end
  -- ow.rebuildNeighbors reloads neighbors via MapLoader.load, which builds a
  -- fresh instance for the brand-new map id (nothing cached it yet), so the
  -- drawn set picks up the new body immediately.
  local ok = pcall(ow.rebuildNeighbors, ow)  if not ok then self:refreshLiveRenderers() end
  self:refreshLiveRenderers()
end

-- Confirms the session's map still resolves (the world may have warped while
-- the overlay was open, or the loader cache dropped the instance).
function Session:assertResolvable()
  if self.map and self.map.def then return true end
  local MapLoader = require("src.world.MapLoader")
  local ok, m = pcall(MapLoader.load, self.data, self.mapId)
  if not ok or not m then return false end
  self.map = m
  return true
end

-- Places a simple NPC object (no script/dialog) at the current cursor cell and
-- marks the map changed.  Returns true when placed.
function Session:placeSprite(spriteId)
  if not spriteId or spriteId == "" then return false end
  if not self.data.sprites or not self.data.sprites[spriteId] then return false end
  -- Object coordinates are walk-grid cells (px = x*16), so the cursor cell
  -- maps 1:1.
  local tx = self.cursorBx
  local ty = self.cursorBy
  local def = self.def
  if tx < 0 or ty < 0 or tx >= def.width * 2 or ty >= def.height * 2 then return false end
  def.objects = def.objects or {}
  local maxIndex = 0
  for _, o in ipairs(def.objects) do
    if (o.index or 0) > maxIndex then maxIndex = o.index end
  end
  table.insert(def.objects, {
    x = tx, y = ty,
    sprite = spriteId,
    index = maxIndex + 1,
    object_type = "NPC",
    isTrainer = false,
    trainerClass = nil,
    script = nil,
    item = nil,
  })
  self.mapChanged = true
  self:refreshLiveRenderers()
  return true
end

-- Places a simple item object (no ball/hidden flag) at the cursor cell and
-- marks the map changed.  Returns true when placed.
function Session:placeItem(itemId)
  if not itemId or itemId == "" then return false end
  if not self.data.items or not self.data.items[itemId] then return false end
  local def = self.def
  local tx = self.cursorBx
  local ty = self.cursorBy
  if tx < 0 or ty < 0 or tx >= def.width * 2 or ty >= def.height * 2 then return false end
  def.objects = def.objects or {}
  local maxIndex = 0
  for _, o in ipairs(def.objects) do
    if (o.index or 0) > maxIndex then maxIndex = o.index end
  end
  table.insert(def.objects, {
    x = tx, y = ty,
    sprite = nil,
    index = maxIndex + 1,
    object_type = "item",
    item = itemId,
    isTrainer = false,
    script = nil,
  })
  self.mapChanged = true
  self:refreshLiveRenderers()
  return true
end

-- Removes an NPC/object at the cursor cell.  Returns true when one was found.
function Session:eraseObjectsAtCell()
  local tx = self.cursorBx
  local ty = self.cursorBy
  local def = self.def
  local list = def.objects or {}
  for i = #list, 1, -1 do
    local o = list[i]
    if o and o.x == tx and o.y == ty then
      table.remove(list, i)
      self.mapChanged = true
      self:refreshLiveRenderers()
      return true
    end
  end
  return false
end

-- Applies the mod's saved patches for the edited map to the live data, then
-- re-baselines the session so originals reflect the last saved state.  Mirrors
-- map_editor's editor enter().
function Session:applySavedPatches()
  local patch = Save.getPatches(self.mod)[self.mapId]
  if not patch then return end
  for key, value in pairs(patch) do
    if key == "blocks" then
      for i, v in ipairs(value) do
        if self.def.blocks[i] ~= nil then self.def.blocks[i] = v end
      end
    elseif key ~= "id" then
      self.def[key] = value
    end
  end
  self:refreshAfterLoad()
end

-- Grows the current map's dimension (width or height) so it matches the map
-- directly opposite `side`, following the expand-vs-create rule.  Draws the
-- grow toward the opposite edge so the source boundary/connection offsets stay
-- anchored at 0 (north/south grow on the width, west/east grow on the height).
-- Returns true when the map was enlarged.
function Session:growToOppositeSide(side)
  local NewMap = require("mods.mapamap.func.new_map")
  local dim = NewMap.parallelDim(side)
  local opp = NewMap.oppositeDef(self, side)
  if not opp then return false end
  local cur = self.def[dim] or 0
  local want = opp[dim] or 0
  if want <= cur then return false end
  local delta = want - cur
  if dim == "width" then
    self:expandMap(0, delta, 0, 0)
  else
    self:expandMap(0, 0, 0, delta)
  end
  return true
end

-- Splits the session onto a freshly created map (from NewMap.createSidedMap):
-- records the source map's pending state, loads the new map, and re-bases the
-- session on it.  Returns the new map id, or nil.
function Session:adoptNewMap(newId)
  local fromId = self.mapId
  self._sessionOriginals = self._sessionOriginals or {}
  self._sessionEncounters = self._sessionEncounters or {}
  self._sessionDirty = self._sessionDirty or {}
  self._sessionOriginals[fromId] = self._originalSnapshot
  self._sessionEncounters[fromId] = self.originalEncounters
  self._sessionDirty[fromId] = true
  self._newMaps = self._newMaps or {}
  self._newMaps[newId] = Common.deepCopy(self.data.maps[newId])
  self:rebuildNeighbors()
  local data = self.data
  local newDef = data.maps[newId]
  local tileset = data.tilesets[newDef.tileset]
  local MapLoader = require("src.world.MapLoader")
  local m = MapLoader.load(data, newId)
  self.mapId = newId
  self.def = newDef
  self.tileset = tileset
  self.map = m
  self.mapW = newDef.width * Common.BLOCK_PX
  self.mapH = newDef.height * Common.BLOCK_PX
  self.undo = Undo.new()
  self.expandShiftL = 0
  self.expandShiftT = 0
  self:rebuildNeighbors()
  self:storeOriginal()
  return newId
end

-- Returns the card edge side that a world cell (in the edited map's local
-- cell frame) lies strictly beyond, or nil when it's inside the body.
function Session:cellEdgeSide(cellX, cellY)
  local w = self.def.width * 2
  local h = self.def.height * 2
  if cellX >= 0 and cellX < w and cellY >= 0 and cellY < h then return nil end
  if cellY < 0 then return "north" end
  if cellY >= h then return "south" end
  if cellX < 0 then return "west" end
  return "east"
end

-- True when the cell falls inside the body of any laid-out neighbor map.
-- A freshly created edge map becomes a neighbor, so this keeps a continuing
-- drag from re-triggering map creation for cells that now have a body.
function Session:cellInsideNeighbor(cellX, cellY)
  local px = cellX * Common.CELL_PX
  local py = cellY * Common.CELL_PX
  for _, nb in ipairs(self.neighbors or {}) do
    local nw = nb.def.width * Common.BLOCK_PX
    local nh = nb.def.height * Common.BLOCK_PX
    if px >= nb.ox and px < nb.ox + nw and py >= nb.oy and py < nb.oy + nh then
      return true
    end
  end
  return false
end

-- Block-paint gate for cells beyond the edited map's body: applies the
-- expand-vs-create rule so a tile off the edge either widens the current map
-- (to match the map on the opposite side) or spawns a fresh, correctly-placed
-- map with 2-way connections to every touching map.
--
-- Returns:
--   "grown"    the current map was enlarged to contain the cell (paint done)
--   "created"  a new map was created at the edge and the block painted on it
--   nil        the cell is inside the map -- normal paintBlock path only
function Session:handleEdgePaint(cellX, cellY)
  local side = self:cellEdgeSide(cellX, cellY)
  if not side then return nil end
  local NewMap = require("mods.mapamap.func.new_map")
  local action = NewMap.expandOrCreate(self, side)
  self.cursorBx = cellX
  self.cursorBy = cellY
  if action == "expand" then
    self:growToOppositeSide(side)
    self:paintBlock()
    return "grown"
  end
  local newId = NewMap.createSidedMap(self, side, 0)
  if not newId then
    self:paintBlock()
    return "grown"
  end
  -- Track the new map whole (like the N-key path) so it survives a reload:
  -- as a neighbor its patch diff would only carry the connection back-edge.
  self._newMaps = self._newMaps or {}
  self._newMaps[newId] = Common.deepCopy(self.data.maps[newId])
  -- The new map is now a laid-out neighbor; rebuild the overworld's drawn
  -- neighbor set so the fresh body appears immediately (not only after a
  -- re-enter), then paint (paintBlock handles the neighbor body).
  self:rebuildWorldNeighbors()
  self:paintBlock()
  return "created"
end

return Session
