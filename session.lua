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
local Graft = require("mods.mapamap.func.graft")
local TileRenderer = require("src.render.TileRenderer")
local PaletteFX = require("src.render.PaletteFX")

local Session = {}

local function fallbackFont()
  return {
    draw = function() end,
    width = function(str) return #tostring(str) * 8 end,
    getWidth = function(str) return #tostring(str) * 8 end,
  }
end

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
  local font = fallbackFont()
  ui.Font = font
  if mod then mod.ui = ui end
  return font
end

-- Mix reusable method tables onto the session.
local function mixin(t, src) for k, v in pairs(src) do t[k] = v end end
mixin(Session, require("mods.mapamap.func.map_ops"))
mixin(Session, require("mods.mapamap.func.editor_neighbors"))
mixin(Session, require("mods.mapamap.func.warps"))

-- Creates a session editing `mapId`.  Returns the session or nil when the
-- map or its tileset cannot be loaded.
function Session.new(mod, game, mapId)
  local data = game.data
  activeData = data
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

-- Rebuilds the overworld's live NPC list for the current map from def.objects
-- (the same source the engine reads on map enter), so a just-placed or removed
-- object appears immediately instead of waiting for the next map enter.  No-op
-- when the visible map isn't the session's, or the world has no npc pool
-- helper.
function Session:refreshObjects()
  local ow = self.game and self.game.overworld
  if not (ow and ow.map and ow.map.id == self.mapId) then return false end
  local fn = ow.pooledNPC
  if not fn then return false end
  ow.npcs = {}
  for _, obj in ipairs(self.def.objects or {}) do
    local npc = fn(ow.npcPool, self.data, self.mapId, obj)
    npc.frozen = false
    table.insert(ow.npcs, npc)
  end
  if ow.player then
    ow.entities = { ow.player }
    for _, n in ipairs(ow.npcs) do table.insert(ow.entities, n) end
  end
  return true
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

-- Full renderer reload for the tileset whose grown atlas a graft just
-- changed.  rebuild() only drops the cached window; a new grown image needs
-- fresh TileRenderers for every map that uses the tileset (the edited map
-- and any overworld instance / neighbor strips) so the grown atlas is
-- re-derived from the updated defs on the next build.
function Session:reloadGraftedRenderers()
  local MapLoader = require("src.world.MapLoader")
  Graft.invalidateTileset(self.data, self.tileset.id)
  Graft.materialize(self.data, self.tileset.id)
  self._thumbBundles = {}
  -- The session's own cached Map is reloaded so its TileRenderer is rebuilt
  -- against the new grown atlas.
  if self.map then
    MapLoader.invalidate(self.mapId)
    self.map = MapLoader.load(self.data, self.mapId)
    if self.map and self.map.renderer then self.map.renderer:rebuild() end
  end
  -- The overworld may hold a different Map instance for this tileset; swap it
  -- for a fresh one right away so the player sees the graft immediately.
  local ow = self.game and self.game.overworld
  if ow and ow.map and ow.map.tileset == self.tileset then
    local m = MapLoader.load(self.data, ow.map.id)
    if m and m.renderer then
      ow.map = m
      ow.map.renderer:rebuild()
    end
  end
  self:refreshLiveRenderers()
end

-- Lazily builds (and caches) a renderer bundle for a non-current tileset so the
-- picker can thumbnail its blocks against that tileset's OWN atlas -- not the
-- live map's tileset.  Building a real TileRenderer (via a 1x1 dummy map) makes
-- the thumbnails go through the same palette / GBC-atlas bake as the world, so a
-- non-current tileset is colored instead of rendering in grayscale.  Returns
-- { image, quads, aliasMap, blocks } or nil when the tileset has no drawable
-- image.  The cache is keyed by tileset id + current lighting (darkKey) so a
-- cave/light toggle rebuilds the bake; warping swaps the whole session, so it
-- starts unpopulated each map.
function Session:thumbnailBundle(tsDef)
  if not tsDef then return nil end
  local tid = tsDef.id or "?"
  local key = tid .. PaletteFX.darkKey()
  if not self._thumbBundles then self._thumbBundles = {} end
  local b = self._thumbBundles[key]
  if b ~= nil then return b end
  local mini = { tileset = tsDef, def = { width = 1, height = 1 }, id = tid }
  local ok, r = pcall(TileRenderer.new, mini, self.data)
  if not ok or not r or not r.image or not r.quads then
    self._thumbBundles[key] = false
    return nil
  end
  b = { image = r.image, quads = r.quads, aliasMap = r.aliasMap, blocks = tsDef.blocks }
  self._thumbBundles[key] = b
  return b
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
  self:refreshObjects()
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
  self:refreshObjects()
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
      self:refreshObjects()
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
  -- A patch may carry graftBlocks (imported foreign blocks) -- grow the atlas
  -- from the freshly applied defs and rebuild the session's renderer so the
  -- grafted blocks draw immediately.
  Graft.invalidateTileset(self.data, self.tileset.id)
  Graft.materialize(self.data, self.tileset.id)
  self._thumbBundles = {}
  self:reloadGraftedRenderers()
  self:rebuildNeighbors()
  self:storeOriginal()
end

-- Imports a foreign tileset block into the edited map: reserves the map-local
-- block id in def.graftBlocks (deduped across the tileset's grafts) and marks
-- the map changed.  Does NOT reload renderers; the caller is responsible for
-- calling reloadGraftedRenderers when the new block must be drawable.
-- Returns the map-local block id, or nil on failure.
function Session:importBlock(srcTileset, srcBlock)
  local id = Graft.importBlock(self.data, self.tileset.id, self.def,
                               srcTileset, srcBlock)
  if id then
    self.mapChanged = true
  end
  return id
end

-- Imports a foreign tileset block into the edited map: reserves the map-local
-- block id in def.graftBlocks (deduped across the tileset's grafts), grows
-- the atlas, and reloads renderers so the new block is drawable immediately.
-- Returns the map-local block id, or nil on failure.  The id is what the
-- caller stores into def.blocks / the paint brush.
function Session:graftBlock(srcTileset, srcBlock)
  local id = Graft.importBlock(self.data, self.tileset.id, self.def,
                               srcTileset, srcBlock)
  if id then
    self.mapChanged = true
    self:reloadGraftedRenderers()
  end
  return id
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

-- Attempts to create a map on the void at the cursor position (single block)
-- or covering the given block rect.  Returns the new map id or nil when no
-- flush connection is possible.  The new map is wired with reciprocal
-- connections and added to the neighbor set immediately.
function Session:createMapAtCursor(bx0, by0, bw, bh)
  local MapGrid = require("mods.mapamap.func.map_grid")
  if bx0 and by0 and bw and bh then
    return MapGrid.createForBlocks(self, bx0, by0, bw, bh)
  end
  local bx = math.floor(self.cursorBx / 2)
  local by = math.floor(self.cursorBy / 2)
  return MapGrid.createForPaint(self, bx, by)
end

-- --- object editing (mirrors the warp helpers) ------------------------------
--
-- Objects live in `def.objects` (the same table the engine reads on map
-- enter) as { x, y, sprite|item, object_type, index, ... } records.

-- Bounds check for a walk-grid cell against a map def.
local function cellIn(def, x, y)
  return x >= 0 and y >= 0 and x < def.width * 2 and y < def.height * 2
end

-- The object at a walk-grid cell on the edited map, or nil.
function Session:objectAt(cellX, cellY)
  for _, o in ipairs(self.def.objects or {}) do
    if (o.x or -1) == cellX and (o.y or -1) == cellY then return o end
  end
  return nil
end

-- A display name for an object (the item id, sprite id, or its label).
function Session:objectName(obj)
  if not obj then return "" end
  if obj.label and obj.label ~= "" then return obj.label end
  if obj.object_type == "item" then return obj.item or "item" end
  return obj.sprite or "object"
end

-- Places a deep copy of `sample` at the cell as a new object (the "copy an
-- object from the map" tool).  Returns the new object or nil.
function Session:placeObjectCopy(cellX, cellY, sample)
  if not cellIn(self.def, cellX, cellY) then return nil end
  if not (sample and sample.object_type) then return nil end
  if self.undo then self.undo:capture(self.def) end
  self.def.objects = self.def.objects or {}
  local maxIndex = 0
  for _, o in ipairs(self.def.objects) do
    if (o.index or 0) > maxIndex then maxIndex = o.index end
  end
  local copy = {}
  for k, v in pairs(sample) do copy[k] = v end
  copy.x, copy.y = cellX, cellY
  copy.index = maxIndex + 1
  table.insert(self.def.objects, copy)
  self.mapChanged = true
  self:refreshLiveRenderers()
  self:refreshObjects()
  return copy
end

-- Places a fresh simple NPC at the cell (the "New Object" template tool),
-- using the first sprite in the engine's sprite table so the object is
-- immediately visible; the name is editable via the Details panel.  Returns
-- the new object or nil when no sprite exists to render with.
function Session:placeNewObject(cellX, cellY)
  if not cellIn(self.def, cellX, cellY) then return nil end
  local spriteId
  for id in pairs(self.data.sprites or {}) do spriteId = id; break end
  if not spriteId then return nil end
  if self.undo then self.undo:capture(self.def) end
  self.def.objects = self.def.objects or {}
  local maxIndex = 0
  for _, o in ipairs(self.def.objects) do
    if (o.index or 0) > maxIndex then maxIndex = o.index end
  end
  table.insert(self.def.objects, {
    x = cellX, y = cellY,
    sprite = spriteId,
    index = maxIndex + 1,
    object_type = "NPC",
    isTrainer = false,
    trainerClass = nil,
    script = nil,
    item = nil,
    label = "New Object",
  })
  self.mapChanged = true
  self:refreshLiveRenderers()
  self:refreshObjects()
  return self.def.objects[#self.def.objects]
end

-- Moves an existing object to a cell.
function Session:moveObject(obj, cellX, cellY)
  if not obj then return false end
  if not cellIn(self.def, cellX, cellY) then return false end
  if self.undo then self.undo:capture(self.def) end
  obj.x, obj.y = cellX, cellY
  self.mapChanged = true
  self:refreshObjects()
  return true
end

-- Sets an object's display label.
function Session:setObjectLabel(obj, label)
  if not obj then return false end
  if self.undo then self.undo:capture(self.def) end
  obj.label = label
  self.mapChanged = true
  return true
end

-- Removes an object from the edited map.
function Session:removeObject(obj)
  local list = self.def.objects or {}
  for i = #list, 1, -1 do
    if list[i] == obj then
      if self.undo then self.undo:capture(self.def) end
      table.remove(list, i)
      self.mapChanged = true
      self:refreshLiveRenderers()
      self:refreshObjects()
      return true
    end
  end
  return false
end

-- Every unique block id painted on the edited map as placement-tool cells
-- (native ids map to the map's tileset, grafted ids resolve to their source
-- tileset + source block so the tool can re-import them).  Used as the
-- "current map" section of the Tiles inventory tab.
function Session:paintedBlocks()
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

return Session
