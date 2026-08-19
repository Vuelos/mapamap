-- EditSession: Pure domain state & mutators for map editing.
-- Holds raw data (mapDef, undo stack, dirty flags) and exposes clean
-- operations (paintBlock, addObject, removeWarp).
-- Does NOT touch LÖVE rendering, fonts, or engine canvas rebaking.

local Common = require("mods.mapamap.common")
local Snapshot = require("mods.mapamap.domain.snapshot")
local Undo = require("mods.mapamap.domain.undo")
local MapOps = require("mods.mapamap.domain.map_ops")
local EditorNeighbors = require("mods.mapamap.domain.editor_neighbors")
local Warps = require("mods.mapamap.domain.warps")
local Encounters = require("mods.mapamap.domain.encounters")
local Objects = require("mods.mapamap.domain.objects")
local Signs = require("mods.mapamap.domain.signs")
local MapGrid = require("mods.mapamap.domain.map_grid")
local Graft = require("mods.mapamap.engine.graft")
local Gen = require("mods.mapamap.engine.gen")
local WorldAdapter = require("mods.mapamap.engine.world_adapter")

local EditSession = {}

local function mixin(t, src) for k, v in pairs(src) do t[k] = v end end
mixin(EditSession, MapOps)
mixin(EditSession, EditorNeighbors)
mixin(EditSession, Warps)
mixin(EditSession, Encounters)
mixin(EditSession, Objects)
mixin(EditSession, Signs)

-- Resolves the UI font the overlay draws labels with.  Prefers the mod's
-- ui.Font (set by map_editor or another mod), falls back to the active LOVE
-- font wrapped for the `draw`/`width` calls the panels make, and finally to a
-- no-op fallback so headless tests (no love.graphics) still construct sessions.
local function resolveFont(mod)
  local ui = mod and mod.ui or {}
  if ui.Font and type(ui.Font) == "table" then return ui.Font end
  if love and love.graphics and love.graphics.getFont then
    local font = love.graphics.getFont()
    if font then
      local wrapped = {
        draw = function(str, x, y)
          if font.draw then return font.draw(str, x, y) end
          if font.print then return font:print(str, x, y) end
          return nil
        end,
        width = function(str)
          if font.getWidth then return font:getWidth(str) end
          if font.width then return font.width(str) end
          return #tostring(str) * 8
        end,
        getWidth = function(str)
          if font.getWidth then return font:getWidth(str) end
          if font.width then return font.width(str) end
          return #tostring(str) * 8
        end,
      }
      ui.Font = wrapped
      if mod then mod.ui = ui end
      return wrapped
    end
  end
  local font = {
    draw = function() end,
    width = function(str) return #tostring(str) * 8 end,
    getWidth = function(str) return #tostring(str) * 8 end,
  }
  ui.Font = font
  if mod then mod.ui = ui end
  return font
end

-- Creates a session editing `mapId`. Returns the session or nil when the
-- map or its tileset cannot be loaded.
function EditSession.new(mod, game, mapId, data)
  if not data and game then data = game.data end
  if not (data and data.maps) then return nil end
  local def = data.maps[mapId]
  if not def then return nil end
  local tileset = data.tilesets[def.tileset]
  if not tileset then return nil end

  local map = Gen.loadMap(data, mapId)
  if not map then return nil end

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
    font = resolveFont(mod),
    mapW = def.width * Common.BLOCK_PX,
    mapH = def.height * Common.BLOCK_PX,
    neighbors = {},
    neighborMaps = {},
    neighborOriginals = {},
    neighborDirty = {},
    _sessionOriginals = {},
    _sessionEncounters = {},
    _sessionDirty = {},
    _thumbBundles = {},
    paletteList = {},
    spriteList = {},
    paletteColors = nil,
  }

  setmetatable(self, { __index = EditSession })
  self:rebuildNeighbors()
  self:storeOriginal()
  self.paletteColors = self:mapPaletteColors()
  return self
end

-- Refreshes the editor state after a patch was applied.
function EditSession:refreshAfterLoad()
  self:rebuildNeighbors()
  self:storeOriginal()
  Gen.rebuildRenderer(self.map)
end

-- Engine/rendering side-effects (renderer rebuild, canvas re-bake, NPC pool
-- sync) live in engine/world_adapter.lua; the session delegates to it so the
-- domain stays a pure data/state holder and the generation nuances have one
-- home.  These are used by paint/objects/map_grid through `session:*`.

function EditSession:refreshLiveRenderers()
  return WorldAdapter.refreshLiveRenderers(self)
end

function EditSession:flushLiveRebuild()
  return WorldAdapter.flushLiveRebuild(self)
end

-- Full renderer reload for the tileset whose grown atlas a graft just changed.
function EditSession:reloadGraftedRenderers()
  return WorldAdapter.reloadGraftedRenderers(self)
end

-- Lazily builds a renderer bundle for a non-current tileset.
function EditSession:thumbnailBundle(tsDef)
  if not tsDef then return nil end
  local tid = tsDef.id or "?"
  local key = tid .. (require("src.render.PaletteFX").darkKey() or "")
  if not self._thumbBundles then self._thumbBundles = {} end
  local b = self._thumbBundles[key]
  if b ~= nil then return b end
  b = Gen.thumbnailBundle(self, tsDef)
  self._thumbBundles[key] = b or false
  return b
end

-- Reloads the session's map from the live data and rebuilds its renderer.
function EditSession:reloadMap()
  Gen.invalidateMap(self.data, self.mapId)
  self.map = Gen.loadMap(self.data, self.mapId)
  Gen.rebuildRenderer(self.map)
  self:storeOriginal()
end

-- Re-runs the overworld's neighbor resolution so a freshly created edge map
-- shows up on screen without waiting for the player to step off the map.
function EditSession:rebuildWorldNeighbors()
  self:rebuildNeighbors()
  WorldAdapter.rebuildRuntimeNeighbors(self)
  self:refreshLiveRenderers()
end

-- Confirms the session's map still resolves.
function EditSession:assertResolvable()
  if self.map and self.map.def then return true end
  local m = Gen.loadMap(self.data, self.mapId)
  if not m then return false end
  self.map = m
  return true
end

-- Applies the mod's saved patches for the edited map to the live data.
function EditSession:applySavedPatches()
  local Save = require("mods.mapamap.storage.patch_saver")
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
  Graft.invalidateTileset(self.data, self.tileset.id)
  Graft.materialize(self.data, self.tileset.id)
  self._thumbBundles = {}
  self:reloadGraftedRenderers()
  self:rebuildNeighbors()
  self:storeOriginal()
end

-- Imports a foreign tileset block into the edited map.
function EditSession:importBlock(srcTileset, srcBlock)
  local id = Graft.importBlock(self.data, self.tileset.id, self.def,
                               srcTileset, srcBlock)
  if id then
    self.mapChanged = true
  end
  return id
end

-- Imports a foreign tileset block and reloads renderers.
function EditSession:graftBlock(srcTileset, srcBlock)
  local id = Graft.importBlock(self.data, self.tileset.id, self.def,
                               srcTileset, srcBlock)
  if id then
    self.mapChanged = true
    self:reloadGraftedRenderers()
  end
  return id
end

-- Splits the session onto a freshly created map.
function EditSession:adoptNewMap(newId)
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
  local m = Gen.loadMap(data, newId)
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

-- Attempts to create a map on the void at the cursor position.
function EditSession:createMapAtCursor(bx0, by0, bw, bh)
  if bx0 and by0 and bw and bh then
    return MapGrid.createForBlocks(self, bx0, by0, bw, bh)
  end
  local bx = math.floor(self.cursorBx / 2)
  local by = math.floor(self.cursorBy / 2)
  return MapGrid.createForPaint(self, bx, by)
end

-- Renames a laid-out map.
function EditSession:setMapName(mapId, name)
  if not mapId then return false end
  local def = (mapId == self.mapId) and self.def or (self.data.maps[mapId])
  if not def then return false end
  if self.undo then self.undo:capture(def) end
  def.name = name
  self.mapChanged = true
  if mapId ~= self.mapId then
    self.neighborDirty = self.neighborDirty or {}
    self.neighborDirty[mapId] = true
  end
  return true
end

-- Every unique block id painted on the edited map as placement-tool cells.
function EditSession:paintedBlocks()
  local native = self.tileset and #self.tileset.blocks or 0
  local seen, out = {}, {}
  for _, bid in ipairs(self.def.blocks or {}) do
    if bid and not seen[bid] then
      seen[bid] = true
      if bid < native then
        out[#out + 1] = { kind = "block", id = bid, tileset = self.tileset.id }
      else
        local _, entry = Graft.graftFor(self.def, native, bid)
        if entry then
          out[#out + 1] = { kind = "block", id = entry.srcBlock,
            srcTileset = entry.srcTileset }
        end
      end
    end
  end
  return out
end

-- Returns the card edge side that a world cell lies strictly beyond.
function EditSession:cellEdgeSide(cellX, cellY)
  local w = self.def.width * 2
  local h = self.def.height * 2
  if cellX >= 0 and cellX < w and cellY >= 0 and cellY < h then return nil end
  if cellY < 0 then return "north" end
  if cellY >= h then return "south" end
  if cellX < 0 then return "west" end
  return "east"
end

-- True when the cell falls inside the body of any laid-out neighbor map.
function EditSession:cellInsideNeighbor(cellX, cellY)
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

-- True when a warp, object, or sign already occupies this cell on the edited
-- map.  `exclude` is an optional entity table to skip (used by move operations
-- so an entity can return to its own cell).
function EditSession:cellOccupied(cellX, cellY, exclude)
  for _, w in ipairs(self.def.warps or {}) do
    if w ~= exclude and (w.x or -1) == cellX and (w.y or -1) == cellY then return true end
  end
  for _, o in ipairs(self.def.objects or {}) do
    if o ~= exclude and (o.x or -1) == cellX and (o.y or -1) == cellY then return true end
  end
  for _, s in ipairs(self.def.signs or {}) do
    if s ~= exclude and (s.x or -1) == cellX and (s.y or -1) == cellY then return true end
  end
  return false
end

return EditSession