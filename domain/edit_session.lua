-- EditSession: Pure domain state & mutators for map editing.
-- Holds raw data (mapDef, undo stack, dirty flags) and exposes clean
-- operations (paintBlock, addObject, removeWarp).
-- Does NOT touch LÖVE rendering, fonts, or engine canvas rebaking.

local Common = require("mods.mapamap.common")
local Snapshot = require("mods.mapamap.domain.snapshot")
local Undo = require("mods.mapamap.domain.undo")
local EditOps = require("mods.mapamap.domain.edit_ops")
local MapOps = require("mods.mapamap.domain.map_ops")
local EditorNeighbors = require("mods.mapamap.domain.editor_neighbors")
local Warps = require("mods.mapamap.domain.warps")
local Encounters = require("mods.mapamap.domain.encounters")
local Objects = require("mods.mapamap.domain.objects")
local Signs = require("mods.mapamap.domain.signs")
local TrainerParty = require("mods.mapamap.domain.trainer_party")
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
mixin(EditSession, TrainerParty)

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
  Gen.invalidateMap(self.data, self.mapId, self.game)
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

-- The laid-out map owning a WORLD cell, resolved for placements / moves /
-- erases: the edited map itself (neighbor = false, world == local cells) or
-- a laid-out neighbor (neighbor = true, cellX/cellY converted into the
-- owner's local walk grid).  Nil over open void.  Shape:
--   { def, mapId, cellX, cellY, neighbor }
function EditSession:targetAt(cellX, cellY)
  if not cellX or not cellY then return nil end
  local Neighbors = require("mods.mapamap.domain.neighbors")
  local mapId, def, ox, oy = Neighbors.mapAt(self.def, self.neighbors,
    cellX, cellY)
  if not def then return nil end
  if def == self.def then
    return { def = def, mapId = self.mapId, cellX = cellX, cellY = cellY,
             neighbor = false }
  end
  local lx = math.floor((cellX * Common.CELL_PX - (ox or 0)) / Common.CELL_PX)
  local ly = math.floor((cellY * Common.CELL_PX - (oy or 0)) / Common.CELL_PX)
  return { def = def, mapId = mapId, cellX = lx, cellY = ly,
           neighbor = true }
end

-- Runs fn with the placement context (def / mapId / cursor cell) pointed at
-- `target` -- the CURRENT map passes straight through; a laid-out NEIGHBOR
-- is swapped in for the duration so the whole place*/move*/erase* family
-- (all reading self.def and self.cursorBx) serves both targets unchanged.
-- The context is always restored; fn receives the target's local cell.
function EditSession:withTargetDef(target, fn)
  if not target then return nil end
  if not target.neighbor then
    return fn(target.cellX, target.cellY)
  end
  local oDef, oMapId = self.def, self.mapId
  local oCx, oCy = self.cursorBx, self.cursorBy
  self.def, self.mapId = target.def, target.mapId
  self.cursorBx, self.cursorBy = target.cellX, target.cellY
  local ok, res = pcall(fn, target.cellX, target.cellY)
  self.def, self.mapId = oDef, oMapId
  self.cursorBx, self.cursorBy = oCx, oCy
  if not ok then error(res, 0) end
  return res
end

-- Runtime refresh after an edit to a NEIGHBOR map's def: neighbor strips
-- (gen 1 NPC pooling) and ghost entities (gen 2 rebuildPeople) are rebuilt
-- from defs, so flag the diff for persistence and nudge the runtime caches.
function EditSession:refreshNeighborMap(mapId)
  self.neighborDirty[mapId] = true
  WorldAdapter.rebuildRuntimeNeighbors(self)
  self:refreshObjects()
end

-- Removes an entity from whichever LAID-OUT map owns it (the edited map or
-- a neighbor).  The kind-specific remove* ops run their own scan first and
-- fall back here, so Details behaves IDENTICALLY for entities on other
-- maps.  Captures the OWNER def for undo (routed by snap.mapId) and flags/
-- refreshes appropriately.  kind is "warps" | "objects" | "signs".
function EditSession:removeEntityFromOwner(entity, kind)
  if not entity then return false end
  local candidates = { { def = self.def, id = nil } }
  for _, nb in ipairs(self.neighbors or {}) do
    candidates[#candidates + 1] = nb
  end
  for _, o in ipairs(candidates) do
    local list = o.def[kind]
    if list then
      for i, e in ipairs(list) do
        if e == entity then
          if self.undo then
            self.undo:capture(o.def, nil, nil, o.id)
          end
          table.remove(list, i)
          if o.id and o.id ~= self.mapId then
            self:refreshNeighborMap(o.id)
          else
            self.mapChanged = true
            self:refreshLiveRenderers()
            self:refreshObjects()
          end
          return true
        end
      end
    end
  end
  return false
end

-- Returns the warp, object, or sign occupying a walk-grid cell on the edited
-- map plus its type tag ("object" | "warp" | "sign"), or nil.  Priority is
-- object > warp > sign (the order every pick/erase chain used).  `exclude`
-- skips one entity (move operations let an entity revisit its own cell).
function EditSession:entityAt(cellX, cellY, exclude)
  local def = self.def
  local lists = {
    { list = def.objects, type = "object" },
    { list = def.warps,   type = "warp" },
    { list = def.signs,   type = "sign" },
  }
  for _, l in ipairs(lists) do
    for _, ent in ipairs(l.list or {}) do
      if ent ~= exclude and (ent.x or -1) == cellX and (ent.y or -1) == cellY then
        return ent, l.type
      end
    end
  end
  return nil
end

-- True when a warp, object, or sign already occupies this cell on the edited
-- map.  `exclude` is an optional entity table to skip.
function EditSession:cellOccupied(cellX, cellY, exclude)
  return self:entityAt(cellX, cellY, exclude) ~= nil
end

-- World-wide entity lookup: like entityAt, but when the current map has
-- nothing at the cell the laid-out NEIGHBOR owning that cell is scanned too
-- (the same rule the overlay's hover markers follow), including gen-2
-- readable bgEvents as signs.  Returns
--   entity, type, ownerDef, localCellX, localCellY, isNeighbor
-- or nil.  Callers that MUTATE should check isNeighbor: the session's
-- placement/removal ops are bound to the current map's def.
function EditSession:entityAtWorld(cellX, cellY)
  local ent, et = self:entityAt(cellX, cellY)
  if ent then
    return ent, et, self.def, cellX, cellY, false
  end
  local Neighbors = require("mods.mapamap.domain.neighbors")
  local _, def, ox, oy = Neighbors.mapAt(self.def, self.neighbors,
    cellX, cellY)
  if not def or def == self.def then return nil end
  local lx = math.floor((cellX * Common.CELL_PX - (ox or 0)) / Common.CELL_PX)
  local ly = math.floor((cellY * Common.CELL_PX - (oy or 0)) / Common.CELL_PX)
  local lists = {
    { list = def.objects,  type = "object" },
    { list = def.warps,    type = "warp" },
    { list = def.signs,    type = "sign" },
    -- Gen 2 keeps readable background events (kinds 0-6) instead of signs.
    { list = def.bgEvents, type = "sign", bgOnly = true },
  }
  for _, l in ipairs(lists) do
    for _, ent2 in ipairs(l.list or {}) do
      local kindOk = (not l.bgOnly) or ((ent2.kind or 0) <= 6)
      if kindOk and (ent2.x or -1) == lx and (ent2.y or -1) == ly then
        return ent2, l.type, def, lx, ly, true
      end
    end
  end
  return nil
end

-- Moves a placed entity to a WORLD cell, following whichever laid-out map
-- owns the destination: same-owner moves run the plain mutator under the
-- target context; a seam-crossing drag lifts the entity out of its owner
-- list and re-inserts it (fresh index) on the destination map.  Both defs
-- are captured first so Ctrl+Z restores the pair -- restoreSnapshot routes
-- each step by its snap.mapId.
function EditSession:relocateEntityWorld(entity, entityType, worldX, worldY)
  if not entity then return false end
  local target = self:targetAt(worldX, worldY)
  if not target then return false end
  local mover = (entityType == "warp" and self.moveWarp)
    or (entityType == "object" and self.moveObject)
    or (entityType == "sign" and self.moveSign)
  if not mover then return false end

  -- Find the laid-out map whose lists currently hold the entity.
  local owners = { { def = self.def, id = nil } }
  for _, nb in ipairs(self.neighbors or {}) do
    owners[#owners + 1] = nb
  end
  local ownerKey, ownerDef, ownerMapId
  for _, o in ipairs(owners) do
    for _, key in ipairs({ "objects", "warps", "signs" }) do
      for _, e in ipairs(o.def[key] or {}) do
        if e == entity then
          ownerKey, ownerDef, ownerMapId = key, o.def, o.id
          break
        end
      end
      if ownerKey then break end
    end
    if ownerKey then break end
  end
  if not ownerKey then return false end

  -- Same owner: plain move under the target context (covers neighbor-local
  -- drags as well as current-map ones).
  if ownerDef == target.def then
    return self:withTargetDef(target, function(cx, cy)
      return mover(self, entity, cx, cy)
    end)
  end

  -- Seam-crossing relocation.
  if self.undo then
    self.undo:capture(ownerDef, nil, nil, ownerMapId)
    self.undo:capture(target.def, nil, nil,
      target.neighbor and target.mapId or nil)
  end
  local list = ownerDef[ownerKey]
  for i, e in ipairs(list) do
    if e == entity then table.remove(list, i) break end
  end
  entity.x, entity.y = target.cellX, target.cellY
  local destList = target.def[ownerKey] or {}
  entity.index = EditOps.nextIndex(destList)
  target.def[ownerKey] = destList
  table.insert(destList, entity)
  if ownerMapId and ownerMapId ~= self.mapId then
    self:refreshNeighborMap(ownerMapId)
  elseif target.neighbor then
    self:refreshNeighborMap(target.mapId)
  else
    self:refreshLiveRenderers()
    self:refreshObjects()
  end
  self.selectedItem = entity
  return true
end

return EditSession